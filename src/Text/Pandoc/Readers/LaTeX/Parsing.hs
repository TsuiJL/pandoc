{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{- |
   Module      : Text.Pandoc.Readers.LaTeX.Parsing
   Copyright   : Copyright (C) 2006-2021 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

General parsing types and functions for LaTeX.
-}
module Text.Pandoc.Readers.LaTeX.Parsing
  ( DottedNum(..)
  , renderDottedNum
  , incrementDottedNum
  , TheoremSpec(..)
  , TheoremStyle(..)
  , LaTeXState(..)
  , defaultLaTeXState
  , LP
  , withVerbatimMode
  , rawLaTeXParser
  , applyMacros
  , tokenize
  , tokenizeSources
  , getInputTokens
  , untokenize
  , untoken
  , totoks
  , toksToString
  , satisfyTok
  , parseFromToks
  , disablingWithRaw
  , doMacros
  , doMacros'
  , setpos
  , anyControlSeq
  , anySymbol
  , isNewlineTok
  , isWordTok
  , isArgTok
  , spaces
  , spaces1
  , tokTypeIn
  , controlSeq
  , symbol
  , symbolIn
  , sp
  , whitespace
  , newlineTok
  , comment
  , anyTok
  , singleChar
  , tokWith
  , specialChars
  , endline
  , blankline
  , primEscape
  , bgroup
  , egroup
  , grouped
  , braced
  , braced'
  , bracedUrl
  , bracedOrToken
  , bracketed
  , bracketedToks
  , parenWrapped
  , dimenarg
  , ignore
  , withRaw
  , keyvals
  , verbEnv
  , begin_
  , end_
  , getRawCommand
  , skipopts
  , rawopt
  , overlaySpecification
  , getNextNumber
  , label
  , setCaption
  , resetCaption
  , env
  , addMeta
  ) where

import Control.Applicative (many, (<|>))
import Control.Monad
import Control.Monad.Except (throwError)
import Control.Monad.Trans (lift)
import Data.Char (chr, isAlphaNum, isDigit, isLetter, ord)
import Data.Default
import Data.List (intercalate)
import qualified Data.IntMap as IntMap
import qualified Data.Map as M
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Text.Pandoc.Builder
import Text.Pandoc.Class.PandocMonad (PandocMonad, report)
import Text.Pandoc.Error
         (PandocError (PandocMacroLoop,PandocShouldNeverHappenError))
import Text.Pandoc.Logging
import Text.Pandoc.Options
import Text.Pandoc.Parsing hiding (blankline, many, mathDisplay, mathInline,
                            space, spaces, withRaw, (<|>))
import Text.Pandoc.Readers.LaTeX.Types (ExpansionPoint (..), Macro (..),
                                        ArgSpec (..), Tok (..), TokType (..))
import Text.Pandoc.Shared
import Text.Parsec.Pos

newtype DottedNum = DottedNum [Int]
  deriving (Show, Eq)

renderDottedNum :: DottedNum -> T.Text
renderDottedNum (DottedNum xs) = T.pack $
  intercalate "." (map show xs)

incrementDottedNum :: Int -> DottedNum -> DottedNum
incrementDottedNum level (DottedNum ns) = DottedNum $
  case reverse (take level (ns ++ repeat 0)) of
       (x:xs) -> reverse (x+1 : xs)
       []     -> []  -- shouldn't happen

data TheoremStyle =
  PlainStyle | DefinitionStyle | RemarkStyle
  deriving (Show, Eq)

data TheoremSpec =
  TheoremSpec
    { theoremName    :: Inlines
    , theoremStyle   :: TheoremStyle
    , theoremSeries  :: Maybe Text
    , theoremSyncTo  :: Maybe Text
    , theoremNumber  :: Bool
    , theoremLastNum :: DottedNum }
    deriving (Show, Eq)

data LaTeXState = LaTeXState{ sOptions       :: ReaderOptions
                            , sMeta          :: Meta
                            , sQuoteContext  :: QuoteContext
                            , sMacros        :: M.Map Text Macro
                            , sContainers    :: [Text]
                            , sLogMessages   :: [LogMessage]
                            , sIdentifiers   :: Set.Set Text
                            , sVerbatimMode  :: Bool
                            , sCaption       :: Maybe Inlines
                            , sInListItem    :: Bool
                            , sInTableCell   :: Bool
                            , sLastHeaderNum :: DottedNum
                            , sLastFigureNum :: DottedNum
                            , sLastTableNum  :: DottedNum
                            , sTheoremMap    :: M.Map Text TheoremSpec
                            , sLastTheoremStyle :: TheoremStyle
                            , sLastLabel     :: Maybe Text
                            , sLabels        :: M.Map Text [Inline]
                            , sHasChapters   :: Bool
                            , sToggles       :: M.Map Text Bool
                            , sFileContents  :: M.Map Text Text
                            , sEnableWithRaw :: Bool
                            , sRawTokens     :: IntMap.IntMap [Tok]
                            }
     deriving Show

defaultLaTeXState :: LaTeXState
defaultLaTeXState = LaTeXState{ sOptions       = def
                              , sMeta          = nullMeta
                              , sQuoteContext  = NoQuote
                              , sMacros        = M.empty
                              , sContainers    = []
                              , sLogMessages   = []
                              , sIdentifiers   = Set.empty
                              , sVerbatimMode  = False
                              , sCaption       = Nothing
                              , sInListItem    = False
                              , sInTableCell   = False
                              , sLastHeaderNum = DottedNum []
                              , sLastFigureNum = DottedNum []
                              , sLastTableNum  = DottedNum []
                              , sTheoremMap    = M.empty
                              , sLastTheoremStyle = PlainStyle
                              , sLastLabel     = Nothing
                              , sLabels        = M.empty
                              , sHasChapters   = False
                              , sToggles       = M.empty
                              , sFileContents  = M.empty
                              , sEnableWithRaw = True
                              , sRawTokens     = IntMap.empty
                              }

instance PandocMonad m => HasQuoteContext LaTeXState m where
  getQuoteContext = sQuoteContext <$> getState
  withQuoteContext context parser = do
    oldState <- getState
    let oldQuoteContext = sQuoteContext oldState
    setState oldState { sQuoteContext = context }
    result <- parser
    newState <- getState
    setState newState { sQuoteContext = oldQuoteContext }
    return result

instance HasLogMessages LaTeXState where
  addLogMessage msg st = st{ sLogMessages = msg : sLogMessages st }
  getLogMessages st = reverse $ sLogMessages st

instance HasIdentifierList LaTeXState where
  extractIdentifierList     = sIdentifiers
  updateIdentifierList f st = st{ sIdentifiers = f $ sIdentifiers st }

instance HasIncludeFiles LaTeXState where
  getIncludeFiles = sContainers
  addIncludeFile f s = s{ sContainers = f : sContainers s }
  dropLatestIncludeFile s = s { sContainers = drop 1 $ sContainers s }

instance HasMacros LaTeXState where
  extractMacros  st  = sMacros st
  updateMacros f st  = st{ sMacros = f (sMacros st) }

instance HasReaderOptions LaTeXState where
  extractReaderOptions = sOptions

instance HasMeta LaTeXState where
  setMeta field val st =
    st{ sMeta = setMeta field val $ sMeta st }
  deleteMeta field st =
    st{ sMeta = deleteMeta field $ sMeta st }

instance Default LaTeXState where
  def = defaultLaTeXState

type LP m = ParserT [Tok] LaTeXState m

withVerbatimMode :: PandocMonad m => LP m a -> LP m a
withVerbatimMode parser = do
  alreadyVerbatimMode <- sVerbatimMode <$> getState
  if alreadyVerbatimMode
     then parser
     else do
       updateState $ \st -> st{ sVerbatimMode = True }
       result <- parser
       updateState $ \st -> st{ sVerbatimMode = False }
       return result

rawLaTeXParser :: (PandocMonad m, HasMacros s, HasReaderOptions s, Show a)
               => [Tok] -> Bool -> LP m a -> LP m a
               -> ParserT Sources s m (a, Text)
rawLaTeXParser toks retokenize parser valParser = do
  pstate <- getState
  let lstate = def{ sOptions = extractReaderOptions pstate }
  let lstate' = lstate { sMacros = extractMacros pstate }
  let setStartPos = case toks of
                      Tok pos _ _ : _ -> setPosition pos
                      _ -> return ()
  let preparser = setStartPos >> parser
  let rawparser = (,) <$> withRaw valParser <*> getState
  res' <- lift $ runParserT (withRaw (preparser >> getPosition))
                            lstate "chunk" toks
  case res' of
       Left _    -> mzero
       Right (endpos, toks') -> do
         res <- lift $ runParserT (do when retokenize $ do
                                        -- retokenize, applying macros
                                        ts <- many anyTok
                                        setInput ts
                                      rawparser)
                        lstate' "chunk" toks'
         case res of
              Left _    -> mzero
              Right ((val, raw), st) -> do
                updateState (updateMacros (sMacros st <>))
                let skipTilPos stopPos = do
                      anyChar
                      pos <- getPosition
                      if pos >= stopPos
                         then return ()
                         else skipTilPos stopPos
                skipTilPos endpos
                let result = untokenize raw
                -- ensure we end with space if input did, see #4442
                let result' =
                      case reverse toks' of
                        (Tok _ (CtrlSeq _) t : _)
                         | " " `T.isSuffixOf` t
                         , not (" " `T.isSuffixOf` result)
                          -> result <> " "
                        _ -> result
                return (val, result')

applyMacros :: (PandocMonad m, HasMacros s, HasReaderOptions s)
            => Text -> ParserT Sources s m Text
applyMacros s = (guardDisabled Ext_latex_macros >> return s) <|>
   do let retokenize = untokenize <$> many anyTok
      pstate <- getState
      let lstate = def{ sOptions = extractReaderOptions pstate
                      , sMacros  = extractMacros pstate }
      res <- runParserT retokenize lstate "math" (tokenize "math" s)
      case res of
           Left e   -> Prelude.fail (show e)
           Right s' -> return s'

{-
When tokenize or untokenize change, test with this
QuickCheck property:

> tokUntokRoundtrip :: String -> Bool
> tokUntokRoundtrip s =
>   let t = T.pack s in untokenize (tokenize "random" t) == t
-}

tokenizeSources :: Sources -> [Tok]
tokenizeSources = concatMap tokenizeSource . unSources
 where
   tokenizeSource (pos, t) = totoks pos t

-- Return tokens from input sources. Ensure that starting position is
-- correct.
getInputTokens :: PandocMonad m => ParserT Sources s m [Tok]
getInputTokens = do
  pos <- getPosition
  ss <- getInput
  return $
    case ss of
      Sources [] -> []
      Sources ((_,t):rest) -> tokenizeSources $ Sources ((pos,t):rest)

tokenize :: SourceName -> Text -> [Tok]
tokenize sourcename = totoks (initialPos sourcename)

totoks :: SourcePos -> Text -> [Tok]
totoks pos t =
  case T.uncons t of
       Nothing        -> []
       Just (c, rest)
         | c == '\n' ->
           Tok pos Newline "\n"
           : totoks (setSourceColumn (incSourceLine pos 1) 1) rest
         | isSpaceOrTab c ->
           let (sps, rest') = T.span isSpaceOrTab t
           in  Tok pos Spaces sps
               : totoks (incSourceColumn pos (T.length sps))
                 rest'
         | isAlphaNum c ->
           let (ws, rest') = T.span isAlphaNum t
           in  Tok pos Word ws
               : totoks (incSourceColumn pos (T.length ws)) rest'
         | c == '%' ->
           let (cs, rest') = T.break (== '\n') rest
           in  Tok pos Comment ("%" <> cs)
               : totoks (incSourceColumn pos (1 + T.length cs)) rest'
         | c == '\\' ->
           case T.uncons rest of
                Nothing -> [Tok pos (CtrlSeq " ") "\\"]
                Just (d, rest')
                  | isLetterOrAt d ->
                      -- \makeatletter is common in macro defs;
                      -- ideally we should make tokenization sensitive
                      -- to \makeatletter and \makeatother, but this is
                      -- probably best for now
                      let (ws, rest'') = T.span isLetterOrAt rest
                          (ss, rest''') = T.span isSpaceOrTab rest''
                      in  Tok pos (CtrlSeq ws) ("\\" <> ws <> ss)
                          : totoks (incSourceColumn pos
                               (1 + T.length ws + T.length ss)) rest'''
                  | isSpaceOrTab d || d == '\n' ->
                      let (w1, r1) = T.span isSpaceOrTab rest
                          (w2, (w3, r3)) = case T.uncons r1 of
                                          Just ('\n', r2)
                                                  -> (T.pack "\n",
                                                        T.span isSpaceOrTab r2)
                                          _ -> (mempty, (mempty, r1))
                          ws = "\\" <> w1 <> w2 <> w3
                      in  case T.uncons r3 of
                               Just ('\n', _) ->
                                 Tok pos (CtrlSeq " ") ("\\" <> w1)
                                 : totoks (incSourceColumn pos (T.length ws))
                                   r1
                               _ ->
                                 Tok pos (CtrlSeq " ") ws
                                 : totoks (incSourceColumn pos (T.length ws))
                                   r3
                  | otherwise  ->
                      Tok pos (CtrlSeq (T.singleton d)) (T.pack [c,d])
                      : totoks (incSourceColumn pos 2) rest'
         | c == '#' ->
           let (t1, t2) = T.span (\d -> d >= '0' && d <= '9') rest
           in  case safeRead t1 of
                    Just i ->
                       Tok pos (Arg i) ("#" <> t1)
                       : totoks (incSourceColumn pos (1 + T.length t1)) t2
                    Nothing ->
                       Tok pos Symbol "#"
                       : totoks (incSourceColumn pos 1) t2
         | c == '^' ->
           case T.uncons rest of
                Just ('^', rest') ->
                  case T.uncons rest' of
                       Just (d, rest'')
                         | isLowerHex d ->
                           case T.uncons rest'' of
                                Just (e, rest''') | isLowerHex e ->
                                  Tok pos Esc2 (T.pack ['^','^',d,e])
                                  : totoks (incSourceColumn pos 4) rest'''
                                _ ->
                                  Tok pos Esc1 (T.pack ['^','^',d])
                                  : totoks (incSourceColumn pos 3) rest''
                         | d < '\128' ->
                                  Tok pos Esc1 (T.pack ['^','^',d])
                                  : totoks (incSourceColumn pos 3) rest''
                       _ -> Tok pos Symbol "^" :
                            Tok (incSourceColumn pos 1) Symbol "^" :
                            totoks (incSourceColumn pos 2) rest'
                _ -> Tok pos Symbol "^"
                     : totoks (incSourceColumn pos 1) rest
         | otherwise ->
           Tok pos Symbol (T.singleton c) : totoks (incSourceColumn pos 1) rest

isSpaceOrTab :: Char -> Bool
isSpaceOrTab ' '  = True
isSpaceOrTab '\t' = True
isSpaceOrTab _    = False

isLetterOrAt :: Char -> Bool
isLetterOrAt '@' = True
isLetterOrAt c   = isLetter c

isLowerHex :: Char -> Bool
isLowerHex x = x >= '0' && x <= '9' || x >= 'a' && x <= 'f'

untokenize :: [Tok] -> Text
untokenize = foldr untokenAccum mempty

untokenAccum :: Tok -> Text -> Text
untokenAccum (Tok _ (CtrlSeq _) t) accum =
  -- insert space to prevent breaking a control sequence; see #5836
  case (T.unsnoc t, T.uncons accum) of
    (Just (_,c), Just (d,_))
      | isLetter c
      , isLetter d
      -> t <> " " <> accum
    _ -> t <> accum
untokenAccum (Tok _ _ t) accum = t <> accum

untoken :: Tok -> Text
untoken t = untokenAccum t mempty

toksToString :: [Tok] -> String
toksToString = T.unpack . untokenize

parseFromToks :: PandocMonad m => LP m a -> [Tok] -> LP m a
parseFromToks parser toks = do
  oldInput <- getInput
  setInput toks
  oldpos <- getPosition
  case toks of
     Tok pos _ _ : _ -> setPosition pos
     _ -> return ()
  result <- disablingWithRaw parser
  setInput oldInput
  setPosition oldpos
  return result

disablingWithRaw :: PandocMonad m => LP m a -> LP m a
disablingWithRaw parser = do
  oldEnableWithRaw <- sEnableWithRaw <$> getState
  updateState $ \st -> st{ sEnableWithRaw = False }
  result <- parser
  updateState $ \st -> st{ sEnableWithRaw = oldEnableWithRaw }
  return result

satisfyTok :: PandocMonad m => (Tok -> Bool) -> LP m Tok
satisfyTok f = do
    doMacros -- apply macros on remaining input stream
    res <- tokenPrim (T.unpack . untoken) updatePos matcher
    updateState $ \st ->
      if sEnableWithRaw st
         then st{ sRawTokens = IntMap.map (res:) $ sRawTokens st }
         else st
    return $! res
  where matcher t | f t       = Just t
                  | otherwise = Nothing
        updatePos :: SourcePos -> Tok -> [Tok] -> SourcePos
        updatePos _spos _ (Tok pos _ _ : _) = pos
        updatePos spos (Tok _ _ t)  []      = incSourceColumn spos (T.length t)

doMacros :: PandocMonad m => LP m ()
doMacros = do
  st <- getState
  unless (sVerbatimMode st) $
    getInput >>= doMacros' 1 >>= setInput

doMacros' :: PandocMonad m => Int -> [Tok] -> LP m [Tok]
doMacros' n inp =
  case inp of
     Tok spos (CtrlSeq "begin") _ : Tok _ Symbol "{" :
      Tok _ Word name : Tok _ Symbol "}" : ts
        -> handleMacros n spos name ts <|> return inp
     Tok spos (CtrlSeq "end") _ : Tok _ Symbol "{" :
      Tok _ Word name : Tok _ Symbol "}" : ts
        -> handleMacros n spos ("end" <> name) ts <|> return inp
     Tok _ (CtrlSeq "expandafter") _ : t : ts
        -> combineTok t <$> doMacros' n ts
     Tok spos (CtrlSeq name) _ : ts
        -> handleMacros n spos name ts <|> return inp
     _ -> return inp

  where
    combineTok (Tok spos (CtrlSeq name) x) (Tok _ Word w : ts)
      | T.all isLetterOrAt w =
        Tok spos (CtrlSeq (name <> w)) (x1 <> w <> x2) : ts
          where (x1, x2) = T.break isSpaceOrTab x
    combineTok t ts = t:ts

    matchTok (Tok _ toktype txt) =
      satisfyTok (\(Tok _ toktype' txt') ->
                    toktype == toktype' &&
                    txt == txt')

    matchPattern toks = try $ mapM_ matchTok toks

    getargs argmap [] = return argmap
    getargs argmap (Pattern toks : rest) = try $ do
       matchPattern toks
       getargs argmap rest
    getargs argmap (ArgNum i : Pattern toks : rest) =
      try $ do
        x <- mconcat <$> manyTill (braced <|> ((:[]) <$> anyTok))
                  (matchPattern toks)
        getargs (M.insert i x argmap) rest
    getargs argmap (ArgNum i : rest) = do
      x <- try $ spaces >> bracedOrToken
      getargs (M.insert i x argmap) rest

    addTok False args spos (Tok _ (Arg i) _) acc =
       case M.lookup i args of
            Nothing -> mzero
            Just xs -> foldr (addTok True args spos) acc xs
    -- see #4007
    addTok _ _ spos (Tok _ (CtrlSeq x) txt)
           acc@(Tok _ Word _ : _)
      | not (T.null txt)
      , isLetter (T.last txt) =
        Tok spos (CtrlSeq x) (txt <> " ") : acc
    addTok _ _ spos t acc = setpos spos t : acc

    handleMacros n' spos name ts = do
      when (n' > 20)  -- detect macro expansion loops
        $ throwError $ PandocMacroLoop name
      macros <- sMacros <$> getState
      case M.lookup name macros of
           Nothing -> trySpecialMacro name ts
           Just (Macro expansionPoint argspecs optarg newtoks) -> do
             let getargs' = do
                   args <-
                     (case expansionPoint of
                        ExpandWhenUsed    -> withVerbatimMode
                        ExpandWhenDefined -> id)
                     $ case optarg of
                             Nothing -> getargs M.empty argspecs
                             Just o  -> do
                                x <- option o bracketedToks
                                getargs (M.singleton 1 x) $ drop 1 argspecs
                   rest <- getInput
                   return (args, rest)
             lstate <- getState
             res <- lift $ runParserT getargs' lstate "args" ts
             case res of
               Left _ -> Prelude.fail $ "Could not parse arguments for " ++
                                T.unpack name
               Right (args, rest) -> do
                 -- first boolean param is true if we're tokenizing
                 -- an argument (in which case we don't want to
                 -- expand #1 etc.)
                 let result = foldr (addTok False args spos) rest newtoks
                 case expansionPoint of
                   ExpandWhenUsed    -> doMacros' (n' + 1) result
                   ExpandWhenDefined -> return result

-- | Certain macros do low-level tex manipulations that can't
-- be represented in our Macro type, so we handle them here.
trySpecialMacro :: PandocMonad m => Text -> [Tok] -> LP m [Tok]
trySpecialMacro "xspace" ts = do
  ts' <- doMacros' 1 ts
  case ts' of
    Tok pos Word t : _
      | startsWithAlphaNum t -> return $ Tok pos Spaces " " : ts'
    _ -> return ts'
trySpecialMacro "iftrue" ts = handleIf True ts
trySpecialMacro "iffalse" ts = handleIf False ts
trySpecialMacro _ _ = mzero

handleIf :: PandocMonad m => Bool -> [Tok] -> LP m [Tok]
handleIf b ts = do
  res' <- lift $ runParserT (ifParser b) defaultLaTeXState "tokens" ts
  case res' of
    Left _ -> Prelude.fail "Could not parse conditional"
    Right ts' -> return ts'

ifParser :: PandocMonad m => Bool -> LP m [Tok]
ifParser b = do
  ifToks <- many (notFollowedBy (controlSeq "else" <|> controlSeq "fi")
                    *> anyTok)
  elseToks <- (controlSeq "else" >> manyTill anyTok (controlSeq "fi"))
                 <|> ([] <$ controlSeq "fi")
  rest <- getInput
  return $ (if b then ifToks else elseToks) ++ rest

startsWithAlphaNum :: Text -> Bool
startsWithAlphaNum t =
  case T.uncons t of
       Just (c, _) | isAlphaNum c -> True
       _           -> False

setpos :: SourcePos -> Tok -> Tok
setpos spos (Tok _ tt txt) = Tok spos tt txt

anyControlSeq :: PandocMonad m => LP m Tok
anyControlSeq = satisfyTok isCtrlSeq

isCtrlSeq :: Tok -> Bool
isCtrlSeq (Tok _ (CtrlSeq _) _) = True
isCtrlSeq _                     = False

anySymbol :: PandocMonad m => LP m Tok
anySymbol = satisfyTok isSymbolTok

isSymbolTok :: Tok -> Bool
isSymbolTok (Tok _ Symbol _) = True
isSymbolTok _                = False

isWordTok :: Tok -> Bool
isWordTok (Tok _ Word _) = True
isWordTok _              = False

isArgTok :: Tok -> Bool
isArgTok (Tok _ (Arg _) _) = True
isArgTok _                 = False

spaces :: PandocMonad m => LP m ()
spaces = skipMany (satisfyTok (tokTypeIn [Comment, Spaces, Newline]))

spaces1 :: PandocMonad m => LP m ()
spaces1 = skipMany1 (satisfyTok (tokTypeIn [Comment, Spaces, Newline]))

tokTypeIn :: [TokType] -> Tok -> Bool
tokTypeIn toktypes (Tok _ tt _) = tt `elem` toktypes

controlSeq :: PandocMonad m => Text -> LP m Tok
controlSeq name = satisfyTok isNamed
  where isNamed (Tok _ (CtrlSeq n) _) = n == name
        isNamed _                     = False

symbol :: PandocMonad m => Char -> LP m Tok
symbol c = satisfyTok isc
  where isc (Tok _ Symbol d) = case T.uncons d of
                                    Just (c',_) -> c == c'
                                    _           -> False
        isc _ = False

symbolIn :: PandocMonad m => [Char] -> LP m Tok
symbolIn cs = satisfyTok isInCs
  where isInCs (Tok _ Symbol d) = case T.uncons d of
                                       Just (c,_) -> c `elem` cs
                                       _          -> False
        isInCs _ = False

sp :: PandocMonad m => LP m ()
sp = do
  optional $ skipMany (whitespace <|> comment)
  optional $ endline  *> skipMany (whitespace <|> comment)

whitespace :: PandocMonad m => LP m ()
whitespace = () <$ satisfyTok isSpaceTok

isSpaceTok :: Tok -> Bool
isSpaceTok (Tok _ Spaces _) = True
isSpaceTok _                = False

newlineTok :: PandocMonad m => LP m ()
newlineTok = () <$ satisfyTok isNewlineTok

isNewlineTok :: Tok -> Bool
isNewlineTok (Tok _ Newline _) = True
isNewlineTok _                 = False

comment :: PandocMonad m => LP m ()
comment = () <$ satisfyTok isCommentTok

isCommentTok :: Tok -> Bool
isCommentTok (Tok _ Comment _) = True
isCommentTok _                 = False

anyTok :: PandocMonad m => LP m Tok
anyTok = satisfyTok (const True)

singleCharTok :: PandocMonad m => LP m Tok
singleCharTok =
  satisfyTok $ \case
     Tok _ Word  t   -> T.length t == 1
     Tok _ Symbol t  -> not (T.any (`Set.member` specialChars) t)
     _               -> False

singleChar :: PandocMonad m => LP m Tok
singleChar = singleCharTok <|> singleCharFromWord
 where
  singleCharFromWord = do
    Tok pos toktype t <- disablingWithRaw $ satisfyTok isWordTok
    let (t1, t2) = (T.take 1 t, T.drop 1 t)
    inp <- getInput
    setInput $ Tok pos toktype t1 : Tok (incSourceColumn pos 1) toktype t2 : inp
    anyTok

specialChars :: Set.Set Char
specialChars = Set.fromList "#$%&~_^\\{}"

endline :: PandocMonad m => LP m ()
endline = try $ do
  newlineTok
  lookAhead anyTok
  notFollowedBy blankline

blankline :: PandocMonad m => LP m ()
blankline = try $ skipMany whitespace *> newlineTok

primEscape :: PandocMonad m => LP m Char
primEscape = do
  Tok _ toktype t <- satisfyTok (tokTypeIn [Esc1, Esc2])
  case toktype of
       Esc1 -> case T.uncons (T.drop 2 t) of
                    Just (c, _)
                      | c >= '\64' && c <= '\127' -> return (chr (ord c - 64))
                      | otherwise                 -> return (chr (ord c + 64))
                    Nothing -> Prelude.fail "Empty content of Esc1"
       Esc2 -> case safeRead ("0x" <> T.drop 2 t) of
                    Just x  -> return (chr x)
                    Nothing -> Prelude.fail $ "Could not read: " ++ T.unpack t
       _    -> Prelude.fail "Expected an Esc1 or Esc2 token" -- should not happen

bgroup :: PandocMonad m => LP m Tok
bgroup = try $ do
  optional sp
  symbol '{' <|> controlSeq "bgroup" <|> controlSeq "begingroup"

egroup :: PandocMonad m => LP m Tok
egroup = symbol '}' <|> controlSeq "egroup" <|> controlSeq "endgroup"

grouped :: (PandocMonad m,  Monoid a) => LP m a -> LP m a
grouped parser = try $ do
  bgroup
  -- first we check for an inner 'grouped', because
  -- {{a,b}} should be parsed the same as {a,b}
  try (grouped parser <* egroup) <|> (mconcat <$> manyTill parser egroup)

braced' :: PandocMonad m => LP m Tok -> LP m [Tok]
braced' getTok = symbol '{' *> go (1 :: Int)
 where
  go n = do
    t <- getTok
    case t of
      Tok _ Symbol "}"
        | n > 1     -> (t:) <$> go (n - 1)
        | otherwise -> return []
      Tok _ Symbol "{" -> (t:) <$> go (n + 1)
      _ -> (t:) <$> go n

braced :: PandocMonad m => LP m [Tok]
braced = braced' anyTok

-- URLs require special handling, because they can contain %
-- characters.  So we retonenize comments as we go...
bracedUrl :: PandocMonad m => LP m [Tok]
bracedUrl = braced' (retokenizeComment >> anyTok)

-- For handling URLs, which allow literal % characters...
retokenizeComment :: PandocMonad m => LP m ()
retokenizeComment = (do
  Tok pos Comment txt <- satisfyTok isCommentTok
  let updPos (Tok pos' toktype' txt') =
        Tok (incSourceColumn (incSourceLine pos' (sourceLine pos - 1))
             (sourceColumn pos)) toktype' txt'
  let newtoks = map updPos $ tokenize (sourceName pos) $ T.tail txt
  getInput >>= setInput . ((Tok pos Symbol "%" : newtoks) ++))
    <|> return ()

bracedOrToken :: PandocMonad m => LP m [Tok]
bracedOrToken = braced <|> ((:[]) <$> (anyControlSeq <|> singleChar))

bracketed :: PandocMonad m => Monoid a => LP m a -> LP m a
bracketed parser = try $ do
  symbol '['
  mconcat <$> manyTill parser (symbol ']')

bracketedToks :: PandocMonad m => LP m [Tok]
bracketedToks = do
  symbol '['
  concat <$> manyTill ((snd <$> withRaw (try braced)) <|> count 1 anyTok)
                      (symbol ']')

parenWrapped :: PandocMonad m => Monoid a => LP m a -> LP m a
parenWrapped parser = try $ do
  symbol '('
  mconcat <$> manyTill parser (symbol ')')

dimenarg :: PandocMonad m => LP m Text
dimenarg = try $ do
  optional sp
  ch  <- option False $ True <$ symbol '='
  minus <- option "" $ "-" <$ symbol '-'
  Tok _ _ s1 <- satisfyTok isWordTok
  s2 <- option "" $ try $ do
          symbol '.'
          Tok _ _ t <-  satisfyTok isWordTok
          return ("." <> t)
  let s = s1 <> s2
  let (num, rest) = T.span (\c -> isDigit c || c == '.') s
  guard $ T.length num > 0
  guard $ rest `elem` ["", "pt","pc","in","bp","cm","mm","dd","cc","sp"]
  return $ T.pack ['=' | ch] <> minus <> s

ignore :: (Monoid a, PandocMonad m) => Text -> ParserT s u m a
ignore raw = do
  pos <- getPosition
  report $ SkippedContent raw pos
  return mempty

withRaw :: PandocMonad m => LP m a -> LP m (a, [Tok])
withRaw parser = do
  rawTokensMap <- sRawTokens <$> getState
  let key = case IntMap.lookupMax rawTokensMap of
               Nothing     -> 0
               Just (n,_)  -> n + 1
  -- insert empty list at key
  updateState $ \st -> st{ sRawTokens =
                             IntMap.insert key [] $ sRawTokens st }
  result <- parser
  mbRevToks <- IntMap.lookup key . sRawTokens <$> getState
  raw <- case mbRevToks of
           Just revtoks -> do
             updateState $ \st -> st{ sRawTokens =
                                        IntMap.delete key $ sRawTokens st}
             return $ reverse revtoks
           Nothing      ->
             throwError $ PandocShouldNeverHappenError $
                "sRawTokens has nothing at key " <> T.pack (show key)
  return (result, raw)

keyval :: PandocMonad m => LP m (Text, Text)
keyval = try $ do
  key <- untokenize <$> many1 (notFollowedBy (symbol '=') >>
                         (symbol '-' <|> symbol '_' <|> satisfyTok isWordTok))
  sp
  val <- option mempty $ do
           symbol '='
           sp
           (untokenize <$> braced) <|>
             (mconcat <$> many1 (
                 (untokenize . snd <$> withRaw braced)
                 <|>
                 (untokenize <$> many1
                      (satisfyTok
                         (\case
                                Tok _ Symbol "]" -> False
                                Tok _ Symbol "," -> False
                                Tok _ Symbol "{" -> False
                                Tok _ Symbol "}" -> False
                                _                -> True)))))
  optional (symbol ',')
  sp
  return (key, T.strip val)

keyvals :: PandocMonad m => LP m [(Text, Text)]
keyvals = try $ symbol '[' >> manyTill keyval (symbol ']') <* sp

verbEnv :: PandocMonad m => Text -> LP m Text
verbEnv name = withVerbatimMode $ do
  optional blankline
  res <- manyTill anyTok (end_ name)
  return $ stripTrailingNewline
         $ untokenize res

-- Strip single final newline and any spaces following it.
-- Input is unchanged if it doesn't end with newline +
-- optional spaces.
stripTrailingNewline :: Text -> Text
stripTrailingNewline t =
  let (b, e) = T.breakOnEnd "\n" t
  in  if T.all (== ' ') e
         then T.dropEnd 1 b
         else t

begin_ :: PandocMonad m => Text -> LP m ()
begin_ t = try (do
  controlSeq "begin"
  spaces
  txt <- untokenize <$> braced
  guard (t == txt)) <?> ("\\begin{" ++ T.unpack t ++ "}")

end_ :: PandocMonad m => Text -> LP m ()
end_ t = try (do
  controlSeq "end"
  spaces
  txt <- untokenize <$> braced
  guard $ t == txt) <?> ("\\end{" ++ T.unpack t ++ "}")

getRawCommand :: PandocMonad m => Text -> Text -> LP m Text
getRawCommand name txt = do
  (_, rawargs) <- withRaw $
      case name of
           "write" -> do
             void $ many $ satisfyTok isDigitTok -- digits
             void braced
           "titleformat" -> do
             void braced
             skipopts
             void $ count 4 braced
           "def" ->
             void $ manyTill anyTok braced
           _ | isFontSizeCommand name -> return ()
             | otherwise -> do
               skipopts
               option "" (try dimenarg)
               void $ many braced
  return $ txt <> untokenize rawargs

isDigitTok :: Tok -> Bool
isDigitTok (Tok _ Word t) = T.all isDigit t
isDigitTok _              = False

skipopts :: PandocMonad m => LP m ()
skipopts = skipMany (void overlaySpecification <|> void rawopt)

-- opts in angle brackets are used in beamer
overlaySpecification :: PandocMonad m => LP m Text
overlaySpecification = try $ do
  symbol '<'
  t <- untokenize <$> manyTill overlayTok (symbol '>')
  -- see issue #3368
  guard $ not (T.all isLetter t) ||
          t `elem` ["beamer","presentation", "trans",
                    "handout","article", "second"]
  return $ "<" <> t <> ">"

overlayTok :: PandocMonad m => LP m Tok
overlayTok =
  satisfyTok (\case
                    Tok _ Word _       -> True
                    Tok _ Spaces _     -> True
                    Tok _ Symbol c     -> c `elem` ["-","+","@","|",":",","]
                    _                  -> False)

rawopt :: PandocMonad m => LP m Text
rawopt = try $ do
  sp
  inner <- untokenize <$> bracketedToks
  sp
  return $ "[" <> inner <> "]"

isFontSizeCommand :: Text -> Bool
isFontSizeCommand "tiny" = True
isFontSizeCommand "scriptsize" = True
isFontSizeCommand "footnotesize" = True
isFontSizeCommand "small" = True
isFontSizeCommand "normalsize" = True
isFontSizeCommand "large" = True
isFontSizeCommand "Large" = True
isFontSizeCommand "LARGE" = True
isFontSizeCommand "huge" = True
isFontSizeCommand "Huge" = True
isFontSizeCommand _ = False

getNextNumber :: Monad m
              => (LaTeXState -> DottedNum) -> LP m DottedNum
getNextNumber getCurrentNum = do
  st <- getState
  let chapnum =
        case sLastHeaderNum st of
             DottedNum (n:_) | sHasChapters st -> Just n
             _                                 -> Nothing
  return . DottedNum $
    case getCurrentNum st of
       DottedNum [m,n]  ->
         case chapnum of
              Just m' | m' == m   -> [m, n+1]
                      | otherwise -> [m', 1]
              Nothing             -> [1]
                                      -- shouldn't happen
       DottedNum [n]   ->
         case chapnum of
              Just m  -> [m, 1]
              Nothing -> [n + 1]
       _               ->
         case chapnum of
               Just n  -> [n, 1]
               Nothing -> [1]

label :: PandocMonad m => LP m ()
label = do
  controlSeq "label"
  t <- braced
  updateState $ \st -> st{ sLastLabel = Just $ untokenize t }

setCaption :: PandocMonad m => LP m Inlines -> LP m ()
setCaption inline = try $ do
  skipopts
  ils <- tokWith inline
  optional $ try $ spaces *> label
  updateState $ \st -> st{ sCaption = Just ils }

resetCaption :: PandocMonad m => LP m ()
resetCaption = updateState $ \st -> st{ sCaption   = Nothing
                                      , sLastLabel = Nothing }

env :: PandocMonad m => Text -> LP m a -> LP m a
env name p = p <* end_ name

tokWith :: PandocMonad m => LP m Inlines -> LP m Inlines
tokWith inlineParser = try $ spaces >>
                                 grouped inlineParser
                            <|> (lookAhead anyControlSeq >> inlineParser)
                            <|> singleChar'
  where singleChar' = do
          Tok _ _ t <- singleChar
          return $ str t

addMeta :: PandocMonad m => ToMetaValue a => Text -> a -> LP m ()
addMeta field val = updateState $ \st ->
   st{ sMeta = addMetaField field val $ sMeta st }
