{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TemplateHaskell #-}

module Data.Argonaut.Parser
  (
      Parser(..)
    , parse
    , parseText
    , parseByteString
    , ParseResult(..)
) where

import Data.List
import Data.Bits
import Data.Word
import Data.Maybe
import Data.Monoid
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Builder as BSB
import Data.Argonaut
import Data.Argonaut.Templates
import Control.Monad.Identity
import Text.Read
import Data.Typeable(Typeable)
import qualified Data.Vector as V
import qualified Data.HashMap.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Argonaut.Templates()
import Debug.Trace

$(buildWord8s [
    ("forwardSlash", 47)
  , ("backSlash", 92)
  , ("closeCurly", 125)
  , ("closeSquare", 93)
  , ("comma", 44)
  , ("doubleQuote", 34)
  , ("openCurly", 123)
  , ("openSquare", 91)
  , ("plus", 43)
  , ("hyphen", 45)
  , ("fullStop", 46)
  , ("zero", 48)
  , ("one", 49)
  , ("two", 50)
  , ("three", 51)
  , ("four", 52)
  , ("five", 53)
  , ("six", 54)
  , ("seven", 55)
  , ("eight", 56)
  , ("nine", 57)
  , ("upperA", 65)
  , ("upperE", 69)
  , ("upperF", 70)
  , ("lowerA", 97)
  , ("lowerB", 98)
  , ("lowerE", 101)
  , ("lowerF", 102)
  , ("lowerN", 110)
  , ("lowerR", 114)
  , ("lowerT", 116)
  , ("lowerU", 117)
  , ("tab", 9)
  , ("space", 32)
  , ("carriageReturn", 13)
  , ("newLine", 10)
  , ("colon", 58)])

skipChars :: [Word8]
skipChars = [spaceChar, tabChar, carriageReturnChar, newLineChar]

escapeCharMappings :: M.HashMap Word8 BSB.Builder
escapeCharMappings = 
    let mappings = [(lowerRChar, '\r'), (lowerNChar, '\n'), (lowerTChar, '\t'), (lowerBChar, '\b'), (lowerFChar, '\f'), (backSlashChar, '\\'), (forwardSlashChar, '/'), (doubleQuoteChar, '"')]
    in  foldl' (\mappingsMap -> \(char, mappedChar) -> M.insert char (BSB.charUtf8 mappedChar) mappingsMap) M.empty mappings

lookupEscapeCharMapping :: Word8 -> Maybe BSB.Builder
lookupEscapeCharMapping char = M.lookup char escapeCharMappings

trueByteString :: B.ByteString
trueByteString = TE.encodeUtf8 "true"

falseByteString :: B.ByteString
falseByteString = TE.encodeUtf8 "false"

nullByteString :: B.ByteString
nullByteString = TE.encodeUtf8 "null"

class Parser m n a | m a -> n where
  parseJson :: m a -> n Json

parse :: Parser m n a => m a -> n Json
parse = parseJson

data ParseError = UnexpectedTermination !Int
                | InvalidSuffixContent !T.Text
                | UnexpectedContent !Int
                | InvalidNumberText !Int
                | InvalidEscapeSequence !T.Text
                | ExpectedToken !T.Text !T.Text
                deriving (Eq, Show, Typeable)

newtype ParserInputByteString = ParserInputByteString {runInputByteString :: B.ByteString} deriving (Eq, Ord, Show)

newtype ParserInputText = ParserInputText {runInputText :: T.Text} deriving (Eq, Ord, Show)

data ParseResult a = ParseFailure !ParseError | ParseSuccess !a deriving (Eq, Show)

instance Functor ParseResult where
  fmap _ (ParseFailure x)  = ParseFailure x
  fmap f (ParseSuccess y)  = ParseSuccess (f y)

instance Monad ParseResult where
  return = ParseSuccess
  ParseFailure l >>= _ = ParseFailure l
  ParseSuccess r >>= k = k r

instance Parser Identity ParseResult ParserInputByteString where
  parseJson (Identity json) = parseByteString $ runInputByteString json

instance Parser Identity ParseResult ParserInputText where
  parseJson (Identity json) = parseText $ runInputText json

ifValidIndex :: (Word8 -> ParseResult a) -> Int -> B.ByteString -> ParseResult a 
ifValidIndex wordLookup index bytestring = 
  let parseError  = ParseFailure $ UnexpectedTermination index
      success     = wordLookup $ BU.unsafeIndex bytestring index
      result      = if index < B.length bytestring then success else parseError
  in  result
{-# INLINE ifValidIndex #-}

excerpt :: B.ByteString -> Int -> B.ByteString
excerpt bytestring index = B.take 30 $ B.drop index bytestring
{-# INLINE excerpt #-}

unexpectedContent :: B.ByteString -> Int -> ParseResult a
unexpectedContent _ index = ParseFailure $ UnexpectedContent index
{-# INLINE unexpectedContent #-}

singleCharAtIndex :: Word8 -> B.ByteString -> Int -> Bool
singleCharAtIndex char bytestring index = 
  let result = charAtIndex [char] bytestring index
  in  {-# SCC singleCharAtIndex #-} result
{-# INLINE singleCharAtIndex #-}

charAtIndex :: [Word8] -> B.ByteString -> Int -> Bool
charAtIndex chars bytestring index = {-# SCC charAtIndex #-} case (ifValidIndex (fmap ParseSuccess (`elem` chars)) index bytestring) of
                                                                                                                                        ParseSuccess result  -> result
                                                                                                                                        _                             -> False
{-# INLINE charAtIndex #-}

skipSkipChars :: B.ByteString -> Int -> (B.ByteString -> Int -> a) -> a
skipSkipChars bytestring index action = 
  --let newIndex = skipWhile bytestring index (`elem` skipChars)
  --in  {-# SCC skipSkipChars #-} action bytestring newIndex
  let newByteString = B.dropWhile (`elem` skipChars) $ B.drop index bytestring
  in  {-# SCC skipSkipChars #-} trace ("skipSkipChars: bytestring = " ++ (show bytestring) ++ " index = " ++ (show index)) $ action newByteString 0
{-# INLINE skipSkipChars #-}

validSuffixContent :: B.ByteString -> Int -> Bool
validSuffixContent bytestring index | index == B.length bytestring  = True
validSuffixContent bytestring index                                 = charAtIndex [spaceChar, carriageReturnChar, newLineChar, tabChar] bytestring index && validSuffixContent bytestring (index + 1)
{-# INLINE validSuffixContent #-}

parseByteString :: B.ByteString -> ParseResult Json
parseByteString bytestring =
  let value       = expectValue bytestring 0
      result      = value >>= (\(index, json) -> if validSuffixContent bytestring index then ParseSuccess json else ParseFailure $ InvalidSuffixContent $ T.pack $ show $ excerpt bytestring index)
  in  {-# SCC parseByteString #-} result

parseText :: T.Text -> ParseResult Json
parseText text = parseByteString $ TE.encodeUtf8 text

isPrefix :: Json -> B.ByteString -> B.ByteString -> Int -> ParseResult (Int, Json)
isPrefix value possiblePrefix bytestring index | B.isPrefixOf possiblePrefix $ B.drop index bytestring  = ParseSuccess ((index + (B.length possiblePrefix)), value)
isPrefix _ _ bytestring index                                                                           = unexpectedContent bytestring index
{-# INLINE isPrefix #-}

expectValue :: B.ByteString -> Int -> ParseResult (Int, Json)
expectValue bytestring index = 
  let validIndex            = index < B.length bytestring
      unexpectedTermination = ParseFailure $ UnexpectedTermination index
      word                  = BU.unsafeIndex bytestring index
      indexResult           = case () of _
                                            | word == openSquareChar        -> expectArray True bytestring (index + 1) V.empty
                                            | word == openCurlyChar         -> expectObject True bytestring (index + 1) M.empty
                                            | word == doubleQuoteChar       -> fmap (\(ind, text) -> (ind, fromText text)) $ expectStringNoStartBounds bytestring (index + 1)
                                            | word == lowerTChar            -> isPrefix jsonTrue trueByteString bytestring index
                                            | word == lowerFChar            -> isPrefix jsonFalse falseByteString bytestring index
                                            | word == lowerNChar            -> isPrefix jsonNull nullByteString bytestring index
                                            | word == spaceChar             -> expectValue bytestring (index + 1)
                                            | word == carriageReturnChar    -> expectValue bytestring (index + 1)
                                            | word == newLineChar           -> expectValue bytestring (index + 1)
                                            | word == tabChar               -> expectValue bytestring (index + 1)
                                            | otherwise                     -> expectNumber bytestring index
  in  {-# SCC expectValue #-} if (validIndex) then indexResult else unexpectedTermination

expectArray :: Bool -> B.ByteString -> Int -> V.Vector Json -> ParseResult (Int, Json)
expectArray first bytestring index elements = {-# SCC expectArray #-} trace "expectArray" $ skipSkipChars bytestring index (\bytes -> \ind -> 
                                                                       if singleCharAtIndex closeSquareChar bytes ind 
                                                                       then ParseSuccess (ind + 1, fromArray $ JArray elements) 
                                                                       else do afterSeparator <- if first then ParseSuccess ind else expectEntrySeparator bytes ind
                                                                               (afterValue, value) <- expectValue bytes afterSeparator
                                                                               expectArray False bytes afterValue (V.snoc elements value)
                                                                       )


expectObject :: Bool -> B.ByteString -> Int -> M.HashMap JString Json -> ParseResult (Int, Json)
expectObject first bytestring index elements = {-# SCC expectObject #-} trace "expectObject" $ skipSkipChars bytestring index (\bytes -> \ind -> 
                                                                       if singleCharAtIndex closeCurlyChar bytes ind 
                                                                       then ParseSuccess (ind + 1, fromObject $ JObject elements) 
                                                                       else do afterEntrySeparator <- if first then ParseSuccess ind else expectEntrySeparator bytes ind
                                                                               (afterKey, key) <- expectString bytes afterEntrySeparator
                                                                               afterFieldSeparator <- expectFieldSeparator bytes afterKey
                                                                               (afterValue, value) <- expectValue bytes afterFieldSeparator
                                                                               expectObject False bytes afterValue (M.insert (JString key) value elements)
                                                                       )

expectString :: B.ByteString -> Int -> ParseResult (Int, T.Text)
expectString bytestring index = {-# SCC expectString #-} trace "expectObject" $ do afterOpen <- expectStringBounds bytestring index
                                                                                   expectStringNoStartBounds bytestring afterOpen

expectStringNoStartBounds :: B.ByteString -> Int -> ParseResult (Int, T.Text)
expectStringNoStartBounds = collectStringParts (BSB.byteString B.empty)
{-# INLINE expectStringNoStartBounds #-}

expectSpacerToken :: Word8 -> T.Text -> B.ByteString -> Int -> ParseResult Int
expectSpacerToken expectedToken failMessage bytestring index = skipSkipChars bytestring index (\bytes -> \ind -> 
  if singleCharAtIndex expectedToken bytes ind 
  then ParseSuccess (ind + 1)
  else ParseFailure (ExpectedToken (T.pack $ show expectedToken) failMessage)
  )
{-# INLINE expectSpacerToken #-}

expectEntrySeparator :: B.ByteString -> Int -> ParseResult Int
expectEntrySeparator = expectSpacerToken commaChar "Expected entry separator."
{-# INLINE expectEntrySeparator #-}

expectStringBounds :: B.ByteString -> Int -> ParseResult Int
expectStringBounds = expectSpacerToken doubleQuoteChar "Expected string bounds."
{-# INLINE expectStringBounds #-}

expectFieldSeparator :: B.ByteString -> Int -> ParseResult Int
expectFieldSeparator = expectSpacerToken colonChar "Expected field separator."
{-# INLINE expectFieldSeparator #-}

collectStringParts :: BSB.Builder -> B.ByteString -> Int -> ParseResult (Int, T.Text)
collectStringParts _     bytestring index | B.length bytestring <= index                  = ParseFailure $ UnexpectedTermination index
collectStringParts parts bytestring index | BU.unsafeIndex bytestring index == doubleQuoteChar   = ParseSuccess (index + 1, TE.decodeUtf8 $ LB.toStrict $ BSB.toLazyByteString parts)
collectStringParts parts bytestring index | BU.unsafeIndex bytestring index == backSlashChar     = case (B.unpack $ B.take 5 $ B.drop (index + 1) bytestring) of 
                                                                                            escapeSeq@(possibleUChar : first : second : third : fourth : []) | possibleUChar == lowerUChar ->
                                                                                               let validHex = validUnicodeHex first second third fourth
                                                                                                   invalidEscapeSequence = ParseFailure (InvalidEscapeSequence $ T.pack $ show escapeSeq)
                                                                                                   escapeSequenceValue = unicodeEscapeSequenceValue first second third fourth
                                                                                                   isSurrogateLead = escapeSequenceValue >= 0xD800 && escapeSequenceValue <= 0xDBFF
                                                                                                   escapedChar = toEnum escapeSequenceValue
                                                                                                   surrogateResult = case (B.unpack $ B.take 6 $ B.drop (index + 6) bytestring) of
                                                                                                      possibleBackSlash : possibleU : trailFirst : trailSecond : trailThird : trailFourth : [] | possibleBackSlash == backSlashChar && possibleU == lowerUChar ->
                                                                                                        let validTrailHex = validUnicodeHex trailFirst trailSecond trailThird trailFourth
                                                                                                            trailEscapeSequenceValue = unicodeEscapeSequenceValue trailFirst trailSecond trailThird trailFourth
                                                                                                            isSurrogateTrail = trailEscapeSequenceValue >= 0xDC00 && trailEscapeSequenceValue <= 0xDFFF
                                                                                                            surrogatePairChar = toEnum ((shiftL 10 escapeSequenceValue - 0xD800) + (trailEscapeSequenceValue - 0xDC00))
                                                                                                        in if validTrailHex && isSurrogateTrail then (collectStringParts (parts `mappend` BSB.charUtf8 surrogatePairChar) bytestring (index + 12)) else invalidEscapeSequence
                                                                                                      _ -> invalidEscapeSequence
                                                                                                   validResult = if isSurrogateLead then surrogateResult else collectStringParts (parts `mappend` BSB.charUtf8 escapedChar) bytestring (index + 6)
                                                                                               in if validHex then validResult else invalidEscapeSequence
                                                                                            (lookupEscapeCharMapping -> Just char) : _ -> collectStringParts (parts `mappend` char) bytestring (index + 2)
                                                                                            invalidSeq -> ParseFailure (InvalidEscapeSequence $ T.pack $ show invalidSeq)
collectStringParts parts bytestring index                                                 =
                                                                                          let text = B.takeWhile isNormalStringElement $ B.drop index bytestring
                                                                                          in  collectStringParts (parts `mappend` BSB.byteString text) bytestring (index + B.length text)


isNormalStringElement :: Word8 -> Bool
isNormalStringElement word = word /= doubleQuoteChar && word /= backSlashChar
{-# INLINE isNormalStringElement #-}

isHexDigit :: Word8 -> Bool
isHexDigit word = 
  let result = (word >= lowerAChar && word <= lowerFChar) || (word >= upperAChar && word <= upperFChar) || (word >= zeroChar && word <= nineChar)
  in  result
{-# INLINE isHexDigit #-}

shiftToHexDigit :: Word8 -> Int
shiftToHexDigit word | word >= upperAChar && word <= upperFChar   = fromIntegral (word - upperAChar + 10)
shiftToHexDigit word | word >= lowerAChar && word <= lowerFChar   = fromIntegral (word - lowerAChar + 10)
shiftToHexDigit word | word >= zeroChar && word <= nineChar       = fromIntegral (word - zeroChar)
shiftToHexDigit _                                                 = error "shiftToHexDigit used incorrectly."
{-# INLINE shiftToHexDigit #-}

validUnicodeHex :: Word8 -> Word8 -> Word8 -> Word8 -> Bool
validUnicodeHex !first !second !third !fourth = isHexDigit first && isHexDigit second && isHexDigit third && isHexDigit fourth
{-# INLINE validUnicodeHex #-}

unicodeEscapeSequenceValue :: Word8 -> Word8 -> Word8 -> Word8 -> Int
unicodeEscapeSequenceValue first second third fourth =
    let firstValue    = (shiftToHexDigit first) `shiftL` 12
        secondValue   = (shiftToHexDigit second) `shiftL` 8
        thirdValue    = (shiftToHexDigit third) `shiftL` 4
        fourthValue   = shiftToHexDigit fourth
    in  firstValue .|. secondValue .|. thirdValue .|. fourthValue
{-# INLINE unicodeEscapeSequenceValue #-}

isNumberChar :: Word8 -> Bool
isNumberChar !word = wordIsNumber word || word == plusChar || word == hyphenChar || word == lowerEChar || word == upperEChar || word == fullStopChar
{-# INLINE isNumberChar #-}

mapWordNumberCharToChar :: Word8 -> Char
mapWordNumberCharToChar !word | word == zeroChar      = '0'
mapWordNumberCharToChar !word | word == oneChar       = '1'
mapWordNumberCharToChar !word | word == twoChar       = '2'
mapWordNumberCharToChar !word | word == threeChar     = '3'
mapWordNumberCharToChar !word | word == fourChar      = '4'
mapWordNumberCharToChar !word | word == fiveChar      = '5'
mapWordNumberCharToChar !word | word == sixChar       = '6'
mapWordNumberCharToChar !word | word == sevenChar     = '7'
mapWordNumberCharToChar !word | word == eightChar     = '8'
mapWordNumberCharToChar !word | word == nineChar      = '9'
mapWordNumberCharToChar !word | word == plusChar      = '+'
mapWordNumberCharToChar !word | word == hyphenChar    = '-'
mapWordNumberCharToChar !word | word == lowerEChar    = 'e'
mapWordNumberCharToChar !word | word == upperEChar    = 'e'
mapWordNumberCharToChar !word | word == fullStopChar  = '.'
mapWordNumberCharToChar _                             = error "mapWordNumberCharToChar used incorrectly."
{-# INLINE mapWordNumberCharToChar #-}

wordNumberToInteger :: Word8 -> Integer
wordNumberToInteger word = fromIntegral $ word - 48
{-# INLINE wordNumberToInteger #-}

wordIsNumber :: Word8 -> Bool
wordIsNumber word = word >= zeroChar && word <= nineChar
{-# INLINE wordIsNumber #-}

wordIsHyphen :: Word8 -> Bool
wordIsHyphen word = word == hyphenChar
{-# INLINE wordIsHyphen #-}

wordIsHyphenOrPlus :: Word8 -> Bool
wordIsHyphenOrPlus word = word == hyphenChar || word == plusChar
{-# INLINE wordIsHyphenOrPlus #-}

wordIsFullStop :: Word8 -> Bool
wordIsFullStop word = word == fullStopChar
{-# INLINE wordIsFullStop #-}

wordIsE :: Word8 -> Bool
wordIsE word = word == lowerEChar || word == upperEChar
{-# INLINE wordIsE #-}

collectSign :: Bool -> B.ByteString -> Maybe (Bool, B.ByteString)
collectSign plusAllowed bytestring =
  let (signChars, remainder)  = B.span (if plusAllowed then wordIsHyphenOrPlus else wordIsHyphen) bytestring
      signCharsLength         = B.length signChars
  in  case () of _
                  | signCharsLength == 1 && not plusAllowed -> Just (False, remainder)
                  | signCharsLength == 1 && plusAllowed     -> Just (not (B.any wordIsHyphen signChars), remainder)
                  | signCharsLength == 0                    -> Just (True, remainder)
                  | otherwise                               -> Nothing

collectNumber :: B.ByteString -> Maybe (Integer, B.ByteString)
collectNumber bytestring =
  let (numberWords, remainder)  = B.span wordIsNumber bytestring
      numberResult              = B.foldl' (\number -> \word -> (number * 10) + (wordNumberToInteger word)) 0 numberWords
  in  case (B.length numberWords) of
                                      0 -> Nothing
                                      _ -> Just (numberResult, remainder)

collectFractionalPrefix :: B.ByteString -> Maybe (Bool, B.ByteString)
collectFractionalPrefix bytestring =
  let (fractionalPrefix, remainder) = B.span wordIsFullStop bytestring
  in  case (B.length fractionalPrefix) of
                                          0 -> Just (False, remainder)
                                          1 -> Just (True, remainder)
                                          _ -> Nothing

collectExponentialPrefix :: B.ByteString -> Maybe (Bool, B.ByteString)
collectExponentialPrefix bytestring =
  let (exponentialPrefix, remainder) = B.span wordIsE bytestring
  in  case (B.length exponentialPrefix) of 
                                            0 -> Just (False, remainder)
                                            1 -> Just (True, remainder)
                                            _ -> Nothing

collectSignedNumber :: Bool -> B.ByteString -> Maybe (Integer, Bool, B.ByteString)
collectSignedNumber plusAllowed bytestring = do (positive, postSign)  <- collectSign plusAllowed bytestring
                                                (number, postNumber)  <- collectNumber postSign
                                                return ((if positive then number else number * (-1)), positive, postNumber)

expectNumber :: B.ByteString -> Int -> ParseResult (Int, Json)
expectNumber bytestring index = 
  let parsedNumber = {-# SCC expectNumber #-}  do (mantissa, positive, postMantissa)  <-  collectSignedNumber False $ B.drop index bytestring
                                                  (isFractional, postPoint)           <-  collectFractionalPrefix postMantissa
                                                  (fractional, postFractional)        <-  if isFractional then collectNumber postPoint else return (0, postPoint)
                                                  let fractionalDigits                =   B.length postPoint - B.length postFractional
                                                  (isExponential, postE)              <-  collectExponentialPrefix postFractional
                                                  (exponential, _, postExponential)   <-  if isExponential then collectSignedNumber True postE else return (0, True, postE)
                                                  let mantissaAsScientific            =   fromIntegral mantissa
                                                  let fractionalAsScientific          =   (fromIntegral fractional) / (10 ^ fractionalDigits) * (if positive then 1 else -1)
                                                  let mantissaPlusFractional          =   mantissaAsScientific + fractionalAsScientific
                                                  let numberResult                    =   mantissaPlusFractional * (10 ^^ exponential)
                                                  numberJson                          <-  fromScientific $ numberResult
                                                  return                              (B.length bytestring - B.length postExponential, numberJson)
  in  maybe (ParseFailure (InvalidNumberText index)) (\(newIndex, number) -> ParseSuccess (newIndex, number)) parsedNumber