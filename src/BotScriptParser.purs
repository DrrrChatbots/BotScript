module BotScriptParser where

import BotScript
import Control.Lazy
import Data.Array
import Data.Foldable
import Data.Function
import Data.Functor
import Data.Identity
import Data.Int
import Data.Maybe
import Data.String
import Data.Tuple.Nested
import Prelude
import Text.Parsing.Parser
import Text.Parsing.Parser.Combinators
import Text.Parsing.Parser.Expr

import Control.Alt ((<|>))
import Data.Array as A
import Data.Either (Either(..))
import Data.List (List)
import Data.List as L
import Data.String.CodeUnits (fromCharArray, singleton)
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (name)
import Text.Parsing.Parser (runParser)
import Text.Parsing.Parser as P
import Text.Parsing.Parser.Combinators as P
import Text.Parsing.Parser.Expr as P
import Text.Parsing.Parser.Language (emptyDef)
import Text.Parsing.Parser.String (anyChar, char, eof, satisfy, string)
import Text.Parsing.Parser.String (char, oneOf)
import Text.Parsing.Parser.Token (LanguageDef, TokenParser, GenLanguageDef(..), unGenLanguageDef, makeTokenParser, alphaNum, letter)
import Text.Parsing.Parser.Token (makeTokenParser)

customStyle :: LanguageDef
customStyle = LanguageDef (unGenLanguageDef emptyDef)
                { commentStart    = "/*"
                , commentEnd      = "*/"
                , commentLine     = "//"
                , nestedComments  = true
                , identStart      = letter <|> oneOf ['_', '$']
                , identLetter     = alphaNum <|> oneOf ['_', '$']
                , reservedNames   =
                    ["state", "true", "false", "event"
                    , "delay", "going", "if", "else"
                    -- , "title", "descr" , "print" ,"order"
                    ]
                , reservedOpNames = [":", ","]
                , caseSensitive   = false
                }

tokParser = makeTokenParser customStyle
whiteSpace = tokParser.whiteSpace
parens p = whiteSpace *> tokParser.parens p
braces p = whiteSpace *> tokParser.braces p
brackets p = whiteSpace *> tokParser.brackets p
parseIdentifier = whiteSpace *> tokParser.identifier
parseStringLiteral = whiteSpace *> tokParser.stringLiteral
symbol xs = whiteSpace *> tokParser.symbol xs
reserved xs = whiteSpace *> tokParser.reserved xs
reservedOp xs = whiteSpace *> tokParser.reservedOp xs

parseBoolean = whiteSpace *>
    (reserved "true" *> pure true)
    <|> (reserved "false" *> pure false)

parseNumber = whiteSpace *>
    (try tokParser.float)
    <|> (toNumber <$> tokParser.integer)

parseArray = fix $ \self ->
  (brackets $ fromFoldable >>> Arr <$>
      parseExpr `sepBy` (string ","))

event'types =
    [ "join"
    , "left"
    , "play"
    , "over"
    , "milk"
    , "talk"
    , "priv"
    ]

parseEtype = choice $ map (\n ->
    symbol n)
    event'types

parsePattern = do
    var <- parseIdentifier
    maybe <- optionMaybe (reserved ":" *> parseStringLiteral)
    case maybe of
         Just pattern -> pure $ var /\ pattern
         Nothing -> pure $ var /\ ""

parseRules = fix $ \self ->
  (parens $ fromFoldable <$>
      parsePattern `sepBy` (reserved ","))

parseTerm p = choice
    [ parseArray
    , (Trm <<< toTerm "String" <$> parseStringLiteral)
    , (Trm <<< toTerm "Number" <$> parseNumber)
    , (Trm <<< toTerm "Boolean" <$> parseBoolean)
    , (Var <$> parseIdentifier)
    ,  parens p
    ]

neg = (Una "-" <$ reservedOp "-")
not = (Una "!" <$ reservedOp "!")

inc's = (Una "_++" <$ reservedOp "++")
dec's = (Una "_--" <$ reservedOp "--")
inc'p = (Una "++_" <$ reservedOp "++")
dec'p = (Una "--_" <$ reservedOp "--")

dot = (reservedOp "." *>
       parseIdentifier >>= \attr ->
       pure $ \expr -> Dot expr attr)

sub exprP = (brackets $ exprP >>= \sub ->
       pure $ \expr -> Sub expr sub)

call exprP = (parens $ exprP `sepBy` (string ",") >>=
    \args -> pure $ \expr -> Fun expr (fromFoldable args))

binary name assoc =
    Infix ((Bin name) <$ reservedOp name) assoc

op'tab exprP =
    [ [prefix $ choice [neg, not, inc'p, dec'p]]
    , [postfix $ choice
      [call exprP, dot, sub exprP, inc's, dec's]]
    , [binary "<" AssocLeft]
    , [binary "<=" AssocLeft]
    , [binary ">" AssocLeft]
    , [binary ">=" AssocLeft]
    , [binary "in" AssocLeft]
    , [binary "===" AssocLeft]
    , [binary "==" AssocLeft]
    , [binary "!==" AssocLeft]
    , [binary "!=" AssocLeft]
    , [binary "/" AssocLeft]
    , [binary "%" AssocLeft]
    , [binary "*" AssocLeft]
    , [binary "-" AssocLeft]
    , [binary "+" AssocLeft]
    , [binary "&&" AssocRight]
    , [binary "||" AssocRight]
    ]

prefix  p = Prefix  <<< chainl1 p $ pure       (<<<)
postfix p = Postfix <<< chainl1 p $ pure (flip (<<<))

-- try to prevent consume input
parseExpr :: ParserT String Identity Expr
parseExpr = fix $ \self ->
    let exprP = buildExprParser
                    (op'tab self)
                    (parseTerm self) in
        whiteSpace *> (
        exprP
    ) <?> "Expression"

expr'action = ["title", "descr", "print" ,"order"]

mustLval lval =
    case lval of
        Sub _ _ -> pure lval
        Var _ -> pure lval
        Dot _ _ -> pure lval
        _ -> fail "Expected left value"

parseBinding = do
    var <- try parseExpr
    whiteSpace
    op <- symbol "="
        <|> symbol "+="
        <|> symbol "-="
        <|> symbol "*="
        <|> symbol "/="
        <|> symbol "%="
    lval <- mustLval var
    expr <- parseExpr <?> "Binding Expression"
    case op of
         "+=" -> pure $ Renew lval (Bin "+" lval expr)
         "-=" -> pure $ Renew lval (Bin "-" lval expr)
         "*=" -> pure $ Renew lval (Bin "*" lval expr)
         "/=" -> pure $ Renew lval (Bin "/" lval expr)
         "%=" -> pure $ Renew lval (Bin "%" lval expr)
         _ -> pure $ Renew lval expr

parseArgument = fix $ \self ->
  (parens $ fromFoldable <$>
      parseExpr `sepBy` (string ","))
  -- <|> (flip (:) []) <$> parseExpr

parseAction :: ParserT String Identity Action
parseAction = fix $ \self -> (do
  action <- (parseBinding
      <|> Delay <$> (reserved "delay" *> parseExpr)
      <|> (do
          reserved "event"
          name <- parseEtype
          rules <- parseRules
          action <- parseAction
          pure $ Event name rules action)
      <|> (do
          reserved "if"
          prd <- parseExpr <?> "If Pred"
          thn <- parseAction <?> "Then Action"
          maybe <- optionMaybe (reserved "else")
          case maybe of
             Just _ -> (do
               els <- parseAction <?> "Else Action"
               pure $ Ifels prd thn els)
             Nothing -> pure $ Ifels prd thn (Group L.Nil))
      <|> (let
          desc = do
             init <- self <?> "For Init Action"
             cond <- parseExpr <?> "For Cond Expr"
             P.optional (reserved ";")
             step <- self <?> "For Step Action"
             pure $ init /\ cond /\ step in do
                reserved "for"
                init /\ cond /\ step <- (parens desc <|> desc)
                body <- self <?> "For Body Action"
                pure $ Group (L.fromFoldable
                 [init, While cond
                 (Group (L.fromFoldable [body, step]))])
            )
      <|> (do
          reserved "while"
          prd <- parseExpr <?> "Pred"
          act <- parseAction <?> "While Action"
          pure $ While prd act)
      <|> (braces $ Group <$> L.many self)
      <|> (reserved "going" *> (Going <$> parseIdentifier))
      <|> Value <$> parseExpr
      -- Timer
      -- visit
  ) -- may consume, need restore
  P.optional (reserved ";")
  pure action)
  <|> ((Group L.Nil) <$ reserved ";")

parseState = do
  reserved "state"
  name <- (parseIdentifier <?> "State Name")
  action <- parseAction
  pure $ BotState name action

testParseStates = do
    lookAhead (reserved "state")
    (some parseState >>= \states -> pure (true /\ states))
    <|> pure (false /\ [])

testParseActions =
    (some parseAction >>= \actions ->
        pure (true /\ actions))
    <|> pure (false /\ [])

parseScript' = do
        whiteSpace
        (sr /\ states) <- testParseStates
        whiteSpace
        (ar /\ actions) <- testParseActions
        if sr || ar then
            pure $ states /\ actions
        else fail "Expected State or Action"

parseScript = do
    xs <- some parseScript' <?> "check"
    eof
    pure let s /\ a = unzip xs in
        BotScript (L.fromFoldable $ concat a) (concat s)

parse p str = runParser str $ p

parseShow p ctx = case parse p ctx of
  Right actual ->
      log (show actual)
  Left err -> log ("error: " <> show err)
