{-# LANGUAGE OverloadedStrings #-}
module ParserSpec (spec) where

import Test.Hspec
import Test.Hspec.Megaparsec
import Text.Megaparsec
import Data.Text (Text)
import Grasp.Types
import Grasp.Parser

spec :: Spec
spec = describe "Parser" $ do
  describe "atoms" $ do
    it "parses integers" $
      parse pExpr "" "42" `shouldParse` EInt 42

    it "parses negative integers" $
      parse pExpr "" "-7" `shouldParse` EInt (-7)

    it "parses symbols" $
      parse pExpr "" "foo" `shouldParse` ESym "foo"

    it "parses operator symbols" $
      parse pExpr "" "+" `shouldParse` ESym "+"

    it "parses hyphenated symbols" $
      parse pExpr "" "haskell-call" `shouldParse` ESym "haskell-call"

    it "parses strings" $
      parse pExpr "" "\"hello\"" `shouldParse` EStr "hello"

    it "parses #t and #f" $ do
      parse pExpr "" "#t" `shouldParse` EBool True
      parse pExpr "" "#f" `shouldParse` EBool False

  describe "lists" $ do
    it "parses empty list" $
      parse pExpr "" "()" `shouldParse` EList []

    it "parses flat list" $
      parse pExpr "" "(+ 1 2)" `shouldParse`
        EList [ESym "+", EInt 1, EInt 2]

    it "parses nested list" $
      parse pExpr "" "(+ (* 2 3) 4)" `shouldParse`
        EList [ESym "+", EList [ESym "*", EInt 2, EInt 3], EInt 4]

    it "parses quote shorthand" $
      parse pExpr "" "'(1 2 3)" `shouldParse`
        EList [ESym "quote", EList [EInt 1, EInt 2, EInt 3]]
