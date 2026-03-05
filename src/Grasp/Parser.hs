{-# LANGUAGE OverloadedStrings #-}
module Grasp.Parser
  ( pExpr
  , parseLisp
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

import Grasp.Types

type Parser = Parsec Void Text

sc :: Parser ()
sc = L.space space1 (L.skipLineComment ";") empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

pInt :: Parser LispExpr
pInt = EInt <$> lexeme (L.signed (pure ()) L.decimal)

pStr :: Parser LispExpr
pStr = EStr . T.pack <$> lexeme (char '"' *> manyTill L.charLiteral (char '"'))

pBool :: Parser LispExpr
pBool = lexeme $ do
  _ <- char '#'
  (EBool True <$ char 't') <|> (EBool False <$ char 'f')

pSym :: Parser LispExpr
pSym = ESym . T.pack <$> lexeme (some (satisfy symChar))
  where
    symChar c = c `notElem` ("()\"#; \t\n\r" :: String)

pList :: Parser LispExpr
pList = EList <$> (lexeme (char '(') *> many pExpr <* lexeme (char ')'))

pQuote :: Parser LispExpr
pQuote = do
  _ <- lexeme (char '\'')
  e <- pExpr
  pure $ EList [ESym "quote", e]

pExpr :: Parser LispExpr
pExpr = pBool <|> pStr <|> pQuote <|> pList <|> try pInt <|> pSym

parseLisp :: Text -> Either (ParseErrorBundle Text Void) LispExpr
parseLisp = parse (sc *> pExpr <* eof) "<repl>"
