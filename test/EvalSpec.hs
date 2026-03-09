{-# LANGUAGE OverloadedStrings #-}
module EvalSpec (spec) where

import Test.Hspec
import Grasp.Types
import Grasp.Eval (eval, defaultEnv, EvalMode(..))
import Grasp.Printer
import Grasp.Parser (parseLisp)
import qualified Data.Text as T

-- | Helper: evaluate an expression in a fresh default environment, return printed result.
evalPrint :: LispExpr -> IO String
evalPrint expr = do
  env <- defaultEnv
  val <- eval ModeComputation env expr
  pure (printVal val)

-- | Parse a string, eval in given env, return printed result.
run :: Env -> String -> IO String
run env input = case parseLisp (T.pack input) of
  Left err -> error (show err)
  Right expr -> do
    val <- eval ModeComputation env expr
    pure (printVal val)

-- | Run in a fresh env.
runFresh :: String -> IO String
runFresh input = defaultEnv >>= \env -> run env input

spec :: Spec
spec = describe "Eval" $ do
  describe "literals" $ do
    it "evaluates an integer" $
      evalPrint (EInt 42) `shouldReturn` "42"

    it "evaluates a double" $
      evalPrint (EDouble 3.14) `shouldReturn` "3.14"

    it "evaluates a string" $
      evalPrint (EStr "hello") `shouldReturn` "\"hello\""

    it "evaluates true" $
      evalPrint (EBool True) `shouldReturn` "#t"

    it "evaluates false" $
      evalPrint (EBool False) `shouldReturn` "#f"

  describe "define + lookup" $ do
    it "defines and retrieves a value" $ do
      env <- defaultEnv
      _ <- eval ModeComputation env (EList [ESym "define", ESym "x", EInt 99])
      val <- eval ModeComputation env (ESym "x")
      printVal val `shouldBe` "99"

    it "errors on unbound symbol" $
      evalPrint (ESym "nope") `shouldThrow` anyErrorCall

  describe "if" $ do
    it "takes then branch on #t" $
      evalPrint (EList [ESym "if", EBool True, EInt 1, EInt 2])
        `shouldReturn` "1"

    it "takes else branch on #f" $
      evalPrint (EList [ESym "if", EBool False, EInt 1, EInt 2])
        `shouldReturn` "2"

  describe "quote" $ do
    it "quotes a symbol" $
      evalPrint (EList [ESym "quote", ESym "foo"])
        `shouldReturn` "foo"

    it "quotes a list" $
      evalPrint (EList [ESym "quote", EList [EInt 1, EInt 2, EInt 3]])
        `shouldReturn` "(1 2 3)"

  describe "primitives" $ do
    it "adds two integers" $
      evalPrint (EList [ESym "+", EInt 3, EInt 4])
        `shouldReturn` "7"

    it "subtracts" $
      evalPrint (EList [ESym "-", EInt 10, EInt 3])
        `shouldReturn` "7"

    it "multiplies" $
      evalPrint (EList [ESym "*", EInt 6, EInt 7])
        `shouldReturn` "42"

    it "divides" $
      evalPrint (EList [ESym "div", EInt 10, EInt 3])
        `shouldReturn` "3"

    it "compares with <" $
      evalPrint (EList [ESym "<", EInt 1, EInt 2])
        `shouldReturn` "#t"

    it "compares with >" $
      evalPrint (EList [ESym ">", EInt 1, EInt 2])
        `shouldReturn` "#f"

    it "checks equality" $
      evalPrint (EList [ESym "=", EInt 5, EInt 5])
        `shouldReturn` "#t"

    it "builds a list" $
      evalPrint (EList [ESym "list", EInt 1, EInt 2, EInt 3])
        `shouldReturn` "(1 2 3)"

    it "takes car of a cons" $
      evalPrint (EList [ESym "car", EList [ESym "cons", EInt 1, EInt 2]])
        `shouldReturn` "1"

    it "takes cdr of a cons" $
      evalPrint (EList [ESym "cdr", EList [ESym "cons", EInt 1, EInt 2]])
        `shouldReturn` "2"

    it "null? on nil" $
      evalPrint (EList [ESym "null?", EList [ESym "quote", EList []]])
        `shouldReturn` "#t"

    it "null? on non-nil" $
      evalPrint (EList [ESym "null?", EInt 1])
        `shouldReturn` "#f"

  describe "lambda" $ do
    it "applies a simple lambda" $
      evalPrint (EList [EList [ESym "lambda", EList [ESym "x"],
                               EList [ESym "+", ESym "x", EInt 1]],
                        EInt 10])
        `shouldReturn` "11"

    it "captures closure" $ do
      env <- defaultEnv
      _ <- eval ModeComputation env (EList [ESym "define", ESym "y", EInt 100])
      val <- eval ModeComputation env (EList [EList [ESym "lambda", EList [ESym "x"],
                                      EList [ESym "+", ESym "x", ESym "y"]],
                              EInt 5])
      printVal val `shouldBe` "105"

  describe "nested application" $ do
    it "evaluates nested arithmetic" $
      evalPrint (EList [ESym "+", EList [ESym "*", EInt 2, EInt 3],
                                  EList [ESym "-", EInt 10, EInt 4]])
        `shouldReturn` "12"

  describe "begin" $ do
    it "returns the last expression" $
      evalPrint (EList [ESym "begin", EInt 1, EInt 2, EInt 3])
        `shouldReturn` "3"

    it "sequences side effects" $ do
      env <- defaultEnv
      _ <- eval ModeComputation env (EList [ESym "begin",
                            EList [ESym "define", ESym "a", EInt 10],
                            EList [ESym "define", ESym "b", EInt 20],
                            EList [ESym "+", ESym "a", ESym "b"]])
      -- a and b should be defined
      va <- eval ModeComputation env (ESym "a")
      printVal va `shouldBe` "10"

  describe "let" $ do
    it "binds local variables" $
      evalPrint (EList [ESym "let",
        EList [ESym "x", EInt 10, ESym "y", EInt 20],
        EList [ESym "+", ESym "x", ESym "y"]])
        `shouldReturn` "30"

    it "sequential binding (later sees earlier)" $
      evalPrint (EList [ESym "let",
        EList [ESym "x", EInt 5, ESym "y", EList [ESym "+", ESym "x", EInt 1]],
        ESym "y"])
        `shouldReturn` "6"

  describe "loop/recur" $ do
    it "loops with recur" $
      evalPrint (EList [ESym "loop",
        EList [ESym "i", EInt 0, ESym "sum", EInt 0],
        EList [ESym "if", EList [ESym "=", ESym "i", EInt 5],
          ESym "sum",
          EList [ESym "recur",
            EList [ESym "+", ESym "i", EInt 1],
            EList [ESym "+", ESym "sum", ESym "i"]]]])
        `shouldReturn` "10"

  describe "lazy/force" $ do
    it "delays and forces evaluation" $ do
      env <- defaultEnv
      _ <- eval ModeComputation env (EList [ESym "define", ESym "x",
              EList [ESym "lazy", EList [ESym "+", EInt 1, EInt 2]]])
      val <- eval ModeComputation env (EList [ESym "force", ESym "x"])
      printVal val `shouldBe` "3"

  describe "empty list" $ do
    it "evaluates () to nil" $
      evalPrint (EList []) `shouldReturn` "()"

  describe "integration (parse + eval + print)" $ do
    it "arithmetic" $
      runFresh "(+ (* 3 4) 2)" `shouldReturn` "14"

    it "lambda and application" $
      runFresh "((lambda (x) (+ x 1)) 10)" `shouldReturn` "11"

    it "recursive fibonacci via loop" $ do
      env <- defaultEnv
      _ <- run env "(define fib (lambda (n) (loop (i 0 a 0 b 1) (if (= i n) a (recur (+ i 1) b (+ a b))))))"
      run env "(fib 10)" `shouldReturn` "55"

    it "higher-order functions" $ do
      env <- defaultEnv
      _ <- run env "(define apply-twice (lambda (f x) (f (f x))))"
      _ <- run env "(define inc (lambda (x) (+ x 1)))"
      run env "(apply-twice inc 5)" `shouldReturn` "7"

    it "list operations" $
      runFresh "(car (cdr (list 1 2 3)))" `shouldReturn` "2"

    it "nested let" $
      runFresh "(let (x 10) (let (y (+ x 5)) (+ x y)))" `shouldReturn` "25"

    it "quote and list structure" $
      runFresh "(car '(a b c))" `shouldReturn` "a"

    it "boolean logic" $
      runFresh "(if (> 5 3) (if (< 1 2) 42 0) 0)" `shouldReturn` "42"
