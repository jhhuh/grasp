{-# LANGUAGE OverloadedStrings #-}
module EvalSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Data.IORef
import Grasp.Types
import Grasp.Eval
import Grasp.Parser
import Grasp.Printer
import Grasp.NativeTypes (graspTypeOf, GraspType(..))

-- Helper: parse + eval, return printed result
run :: String -> IO String
run input = do
  env <- defaultEnv
  case parseLisp (T.pack input) of
    Left err -> error (show err)
    Right expr -> do
      val <- eval env expr
      pure (printVal val)

spec :: Spec
spec = describe "Evaluator" $ do
  describe "literals" $ do
    it "evaluates integers" $
      run "42" `shouldReturn` "42"

    it "evaluates strings" $
      run "\"hello\"" `shouldReturn` "\"hello\""

    it "evaluates booleans" $
      run "#t" `shouldReturn` "#t"

  describe "arithmetic" $ do
    it "adds" $
      run "(+ 1 2)" `shouldReturn` "3"

    it "subtracts" $
      run "(- 10 3)" `shouldReturn` "7"

    it "multiplies" $
      run "(* 4 5)" `shouldReturn` "20"

    it "nests arithmetic" $
      run "(+ (* 2 3) (- 10 4))" `shouldReturn` "12"

  describe "define and lookup" $ do
    it "defines and retrieves a value" $ do
      env <- defaultEnv
      case parseLisp "(define x 42)" of
        Right expr -> do
          _ <- eval env expr
          case parseLisp "x" of
            Right expr2 -> do
              val <- eval env expr2
              printVal val `shouldBe` "42"
            Left _ -> error "parse fail"
        Left _ -> error "parse fail"

  describe "lambda and apply" $ do
    it "applies a lambda" $
      run "((lambda (x) (+ x 1)) 10)" `shouldReturn` "11"

    it "applies a lambda with two args" $
      run "((lambda (x y) (+ x y)) 3 4)" `shouldReturn` "7"

  describe "conditionals" $ do
    it "evaluates if true branch" $
      run "(if #t 1 2)" `shouldReturn` "1"

    it "evaluates if false branch" $
      run "(if #f 1 2)" `shouldReturn` "2"

  describe "list operations" $ do
    it "constructs a list" $
      run "(list 1 2 3)" `shouldReturn` "(1 2 3)"

    it "takes car" $
      run "(car (list 1 2 3))" `shouldReturn` "1"

    it "takes cdr" $
      run "(cdr (list 1 2 3))" `shouldReturn` "(2 3)"

    it "cons onto a list" $
      run "(cons 0 (list 1 2))" `shouldReturn` "(0 1 2)"

  describe "quote" $ do
    it "quotes a list" $
      run "'(1 2 3)" `shouldReturn` "(1 2 3)"

    it "quotes a symbol" $
      run "'foo" `shouldReturn` "foo"

  describe "lazy evaluation" $ do
    it "lazy creates a lazy value" $
      run "(force (lazy 42))" `shouldReturn` "42"

    it "lazy defers computation" $
      run "(force (lazy (+ 1 2)))" `shouldReturn` "3"

    it "force on non-lazy is identity" $
      run "(force 42)" `shouldReturn` "42"

    it "lazy value prints as <lazy>" $
      run "(lazy 42)" `shouldReturn` "<lazy>"

    it "nested force works" $
      run "(force (lazy (force (lazy 99))))" `shouldReturn` "99"

    it "auto-forces in arithmetic" $
      run "(+ (lazy 10) (lazy 20))" `shouldReturn` "30"

    it "auto-forces in comparison" $
      run "(< (lazy 1) (lazy 2))" `shouldReturn` "#t"

    it "auto-forces in equality" $
      run "(= (lazy 42) (lazy 42))" `shouldReturn` "#t"

    it "auto-forces in car" $
      run "(car (lazy (list 1 2 3)))" `shouldReturn` "1"

    it "auto-forces in cdr" $
      run "(cdr (lazy (list 1 2 3)))" `shouldReturn` "(2 3)"

    it "auto-forces in null?" $
      run "(null? (lazy '()))" `shouldReturn` "#t"

    it "auto-forces in function application" $
      run "((lazy (lambda (x) (+ x 1))) 5)" `shouldReturn` "6"

    it "lazy captures environment" $ do
      env <- defaultEnv
      case parseLisp "(define x 10)" of
        Right defExpr -> do
          _ <- eval env defExpr
          case parseLisp "(force (lazy (+ x 5)))" of
            Right expr -> do
              val <- eval env expr
              printVal val `shouldBe` "15"
            Left err -> error (show err)
        Left err -> error (show err)
