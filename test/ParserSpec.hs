{-# LANGUAGE OverloadedStrings #-}
module ParserSpec (spec) where

import Test.Hspec
import Test.Hspec.Megaparsec
import Grasp.Types
import Grasp.Parser

spec :: Spec
spec = describe "Parser" $ do
  describe "integers" $ do
    it "parses positive integer" $
      parseLisp "42" `shouldParse` EInt 42

    it "parses negative integer" $
      parseLisp "-7" `shouldParse` EInt (-7)

  describe "doubles" $ do
    it "parses double" $
      parseLisp "3.14" `shouldParse` EDouble 3.14

  describe "strings" $ do
    it "parses string" $
      parseLisp "\"hello\"" `shouldParse` EStr "hello"

  describe "booleans" $ do
    it "parses true" $
      parseLisp "#t" `shouldParse` EBool True

    it "parses false" $
      parseLisp "#f" `shouldParse` EBool False

  describe "symbols" $ do
    it "parses symbol" $
      parseLisp "foo" `shouldParse` ESym "foo"

    it "parses operator symbol" $
      parseLisp "+" `shouldParse` ESym "+"

  describe "lists" $ do
    it "parses empty list" $
      parseLisp "()" `shouldParse` EList []

    it "parses simple list" $
      parseLisp "(+ 1 2)" `shouldParse` EList [ESym "+", EInt 1, EInt 2]

    it "parses nested list" $
      parseLisp "(+ (* 2 3) 4)" `shouldParse`
        EList [ESym "+", EList [ESym "*", EInt 2, EInt 3], EInt 4]

  describe "quote" $ do
    it "parses quote shorthand" $
      parseLisp "'foo" `shouldParse` EList [ESym "quote", ESym "foo"]

    it "parses quoted list" $
      parseLisp "'(1 2 3)" `shouldParse`
        EList [ESym "quote", EList [EInt 1, EInt 2, EInt 3]]

  describe "parseFile" $ do
    it "parses multiple expressions" $
      parseFile "(define x 1)\n(+ x 2)" `shouldParse`
        [ EList [ESym "define", ESym "x", EInt 1]
        , EList [ESym "+", ESym "x", EInt 2]
        ]

  describe "comments" $ do
    it "skips line comments" $
      parseLisp "; this is a comment\n42" `shouldParse` EInt 42
