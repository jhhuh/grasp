{-# LANGUAGE OverloadedStrings #-}
module EvalSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Control.Concurrent (threadDelay)
import Control.Exception (evaluate, try, SomeException)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as Map
import Grasp.Types
import Grasp.Eval (eval, defaultEnv, anyToExpr)
import Grasp.Parser (parseLisp, parseFile)
import Grasp.Printer
import Grasp.NativeTypes (graspTypeOf, GraspType(..), forceIfLazy, toInt, mkInt, mkSym, mkCons, mkNil, mkBool, mkStr, toModuleExports)

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

    it "auto-forces in if condition" $
      run "(if (lazy #f) 1 2)" `shouldReturn` "2"

    it "equality forces lazy values in cons cells" $
      run "(= (list (lazy 1) (lazy 2)) (list (lazy 1) (lazy 2)))" `shouldReturn` "#t"

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

    it "memoizes after first force (thunk update)" $ do
      env <- defaultEnv
      case parseLisp "(lazy (+ 1 2))" of
        Right expr -> do
          lazyVal <- eval env expr
          r1 <- forceIfLazy lazyVal
          r2 <- forceIfLazy lazyVal
          toInt r1 `shouldBe` 3
          toInt r2 `shouldBe` 3
        Left err -> error (show err)

  describe "anyToExpr" $ do
    it "converts int" $
      anyToExpr (mkInt 42) `shouldBe` EInt 42

    it "converts symbol" $
      anyToExpr (mkSym "foo") `shouldBe` ESym "foo"

    it "converts bool" $
      anyToExpr (mkBool True) `shouldBe` EBool True

    it "converts nil to empty list" $
      anyToExpr mkNil `shouldBe` EList []

    it "converts cons chain to list" $
      anyToExpr (mkCons (mkInt 1) (mkCons (mkInt 2) mkNil)) `shouldBe` EList [EInt 1, EInt 2]

    it "converts nested list" $
      anyToExpr (mkCons (mkCons (mkInt 1) mkNil) mkNil) `shouldBe` EList [EList [EInt 1]]

    it "converts string" $
      anyToExpr (mkStr "hello") `shouldBe` EStr "hello"

  describe "macros" $ do
    it "defmacro creates a macro" $ do
      env <- defaultEnv
      case parseLisp "(defmacro my-id (x) x)" of
        Right expr -> do
          val <- eval env expr
          printVal val `shouldBe` "<macro>"
        Left err -> error (show err)

    it "simple macro expansion" $ do
      env <- defaultEnv
      case parseLisp "(defmacro my-id (x) x)" of
        Right defExpr -> do
          _ <- eval env defExpr
          case parseLisp "(my-id 42)" of
            Right callExpr -> do
              val <- eval env callExpr
              printVal val `shouldBe` "42"
            Left err -> error (show err)
        Left err -> error (show err)

    it "when macro" $ do
      env <- defaultEnv
      case parseLisp "(defmacro when (cond body) (list 'if cond body '()))" of
        Right defExpr -> do
          _ <- eval env defExpr
          case parseLisp "(when #t 42)" of
            Right callExpr -> do
              val <- eval env callExpr
              printVal val `shouldBe` "42"
            Left err -> error (show err)
        Left err -> error (show err)

    it "when macro false branch returns nil" $ do
      env <- defaultEnv
      case parseLisp "(defmacro when (cond body) (list 'if cond body '()))" of
        Right defExpr -> do
          _ <- eval env defExpr
          case parseLisp "(when #f 42)" of
            Right callExpr -> do
              val <- eval env callExpr
              printVal val `shouldBe` "()"
            Left err -> error (show err)
        Left err -> error (show err)

    it "macro with arithmetic in expansion" $ do
      env <- defaultEnv
      case parseLisp "(defmacro double (x) (list '+ x x))" of
        Right defExpr -> do
          _ <- eval env defExpr
          case parseLisp "(double 5)" of
            Right callExpr -> do
              val <- eval env callExpr
              printVal val `shouldBe` "10"
            Left err -> error (show err)
        Left err -> error (show err)

    it "macro expands into macro call" $ do
      env <- defaultEnv
      mapM_ (\src -> case parseLisp src of
        Right e -> eval env e >> pure ()
        Left err -> error (show err))
        [ "(defmacro my-id (x) x)"
        , "(defmacro my-id2 (x) (list 'my-id x))"
        ]
      case parseLisp "(my-id2 42)" of
        Right callExpr -> do
          val <- eval env callExpr
          printVal val `shouldBe` "42"
        Left err -> error (show err)

    it "macro prints as <macro>" $
      run "(defmacro foo (x) x)" `shouldReturn` "<macro>"

  describe "arity errors" $ do
    it "lambda rejects too few args" $ do
      result <- try (evaluate =<< run "((lambda (x y) (+ x y)) 1)") :: IO (Either SomeException String)
      case result of
        Left e -> show e `shouldSatisfy` isInfixOf "expects 2 args, got 1"
        Right _ -> expectationFailure "should have thrown"

    it "lambda rejects too many args" $ do
      result <- try (evaluate =<< run "((lambda (x) x) 1 2 3)") :: IO (Either SomeException String)
      case result of
        Left e -> show e `shouldSatisfy` isInfixOf "expects 1 args, got 3"
        Right _ -> expectationFailure "should have thrown"

    it "macro rejects too few args" $ do
      env <- defaultEnv
      case parseLisp "(defmacro m (a b) (list '+ a b))" of
        Right e -> eval env e >> pure ()
        Left err -> error (show err)
      result <- try (evaluate =<< do
        case parseLisp "(m 1)" of
          Right e -> printVal <$> eval env e
          Left err -> error (show err)) :: IO (Either SomeException String)
      case result of
        Left e -> show e `shouldSatisfy` isInfixOf "expects 2 args, got 1"
        Right _ -> expectationFailure "should have thrown"

    it "macro rejects too many args" $ do
      env <- defaultEnv
      case parseLisp "(defmacro m (a) a)" of
        Right e -> eval env e >> pure ()
        Left err -> error (show err)
      result <- try (evaluate =<< do
        case parseLisp "(m 1 2 3)" of
          Right e -> printVal <$> eval env e
          Left err -> error (show err)) :: IO (Either SomeException String)
      case result of
        Left e -> show e `shouldSatisfy` isInfixOf "expects 1 args, got 3"
        Right _ -> expectationFailure "should have thrown"

  describe "concurrency" $ do
    it "make-chan creates a channel" $
      run "(make-chan)" `shouldReturn` "<chan>"

    it "chan-put and chan-get round-trip" $ do
      env <- defaultEnv
      mapM_ (\src -> case parseLisp src of
        Right e -> eval env e >> pure ()
        Left err -> error (show err))
        [ "(define ch (make-chan))"
        , "(chan-put ch 42)"
        ]
      case parseLisp "(chan-get ch)" of
        Right expr -> do
          val <- eval env expr
          printVal val `shouldBe` "42"
        Left err -> error (show err)

    it "chan-get blocks until value available" $ do
      env <- defaultEnv
      mapM_ (\src -> case parseLisp src of
        Right e -> eval env e >> pure ()
        Left err -> error (show err))
        [ "(define ch (make-chan))"
        , "(spawn (lambda () (chan-put ch 99)))"
        ]
      threadDelay 10000
      case parseLisp "(chan-get ch)" of
        Right expr -> do
          val <- eval env expr
          printVal val `shouldBe` "99"
        Left err -> error (show err)

    it "spawn runs a function in a new thread" $ do
      env <- defaultEnv
      mapM_ (\src -> case parseLisp src of
        Right e -> eval env e >> pure ()
        Left err -> error (show err))
        [ "(define ch (make-chan))"
        , "(spawn (lambda () (chan-put ch (+ 6 7))))"
        ]
      threadDelay 10000
      case parseLisp "(chan-get ch)" of
        Right expr -> do
          val <- eval env expr
          printVal val `shouldBe` "13"
        Left err -> error (show err)

    it "spawn returns nil" $
      run "(spawn (lambda () 42))" `shouldReturn` "()"

    it "multiple spawned threads communicate via channel" $ do
      env <- defaultEnv
      mapM_ (\src -> case parseLisp src of
        Right e -> eval env e >> pure ()
        Left err -> error (show err))
        [ "(define ch (make-chan))"
        , "(spawn (lambda () (chan-put ch 1)))"
        , "(spawn (lambda () (chan-put ch 2)))"
        ]
      threadDelay 10000
      case parseLisp "(+ (chan-get ch) (chan-get ch))" of
        Right expr -> do
          val <- eval env expr
          printVal val `shouldBe` "3"
        Left err -> error (show err)

  describe "modules" $ do
    it "module creates a module value" $ do
      env <- defaultEnv
      case parseLisp "(module mymod (export x) (define x 42))" of
        Right expr -> do
          val <- eval env expr
          printVal val `shouldSatisfy` isPrefixOf "<module:"
        Left err -> error (show err)

    it "module exports only listed bindings" $ do
      env <- defaultEnv
      case parseLisp "(module mymod (export x) (define x 42) (define y 99))" of
        Right expr -> do
          val <- eval env expr
          let exports = toModuleExports val
          Map.member "x" exports `shouldBe` True
          Map.member "y" exports `shouldBe` False
        Left err -> error (show err)

    it "module body can use internal bindings" $ do
      env <- defaultEnv
      case parseLisp "(module mymod (export result) (define helper (lambda (x) (+ x 1))) (define result (helper 41)))" of
        Right expr -> do
          val <- eval env expr
          let exports = toModuleExports val
          case Map.lookup "result" exports of
            Just v -> printVal v `shouldBe` "42"
            Nothing -> expectationFailure "result not exported"
        Left err -> error (show err)

    it "module errors on undefined export" $ do
      env <- defaultEnv
      result <- try (evaluate =<< do
        case parseLisp "(module mymod (export missing) (define x 1))" of
          Right e -> printVal <$> eval env e
          Left err -> error (show err)) :: IO (Either SomeException String)
      case result of
        Left e -> show e `shouldSatisfy` isInfixOf "exported symbol"
        Right _ -> expectationFailure "should have thrown"

    it "module prints as <module:name>" $
      run "(module foo (export) )" `shouldReturn` "<module:foo>"

  describe "parseFile" $ do
    it "parses multiple expressions" $ do
      let input = "(define x 1)\n(define y 2)"
      case parseFile (T.pack input) of
        Right exprs -> length exprs `shouldBe` 2
        Left err -> error (show err)

    it "parses single expression" $ do
      let input = "(module foo (export x) (define x 1))"
      case parseFile (T.pack input) of
        Right exprs -> length exprs `shouldBe` 1
        Left err -> error (show err)
