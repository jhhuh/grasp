{-# LANGUAGE OverloadedStrings #-}
module EvalSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Control.Concurrent (threadDelay)
import Control.Exception (evaluate, try, SomeException)
import Data.List (isInfixOf, isPrefixOf)
import Data.IORef (readIORef, modifyIORef')
import qualified Data.Map.Strict as Map
import System.Directory (removeFile)
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

    it "multi-body lambda returns last" $
      run "((lambda (x) 1 2 (+ x 3)) 10)" `shouldReturn` "13"

    it "multi-body lambda with define" $ do
      env <- defaultEnv
      case parseLisp "(define f (lambda (x) (define y (+ x 1)) (+ x y)))" of
        Right expr -> do
          _ <- eval env expr
          case parseLisp "(f 10)" of
            Right e -> do
              val <- eval env e
              printVal val `shouldBe` "21"
            Left err -> error (show err)
        Left err -> error (show err)

  describe "apply" $ do
    it "applies a function to a list of arguments" $
      run "(apply + (list 1 2))" `shouldReturn` "3"

    it "applies a lambda to a list" $
      run "(apply (lambda (x y) (+ x y)) (list 10 20))" `shouldReturn` "30"

    it "applies with empty args" $
      run "(apply list (list))" `shouldReturn` "()"

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

  describe "begin" $ do
    it "returns last expression" $
      run "(begin 1 2 3)" `shouldReturn` "3"

    it "returns nil for empty begin" $
      run "(begin)" `shouldReturn` "()"

    it "evaluates side effects" $ do
      env <- defaultEnv
      case parseLisp "(begin (define x 10) (+ x 5))" of
        Right expr -> do
          val <- eval env expr
          printVal val `shouldBe` "15"
        Left err -> error (show err)

    it "single expression" $
      run "(begin 42)" `shouldReturn` "42"

  describe "let" $ do
    it "binds and evaluates body" $
      run "(let ((x 1) (y 2)) (+ x y))" `shouldReturn` "3"

    it "sequential bindings reference earlier ones" $
      run "(let ((x 10) (y (+ x 5))) y)" `shouldReturn` "15"

    it "body has begin semantics" $
      run "(let ((x 1)) (define y 2) (+ x y))" `shouldReturn` "3"

    it "does not leak bindings to outer scope" $ do
      env <- defaultEnv
      case parseLisp "(let ((x 99)) x)" of
        Right expr -> do
          _ <- eval env expr
          result <- try (evaluate =<< do
            case parseLisp "x" of
              Right e -> printVal <$> eval env e
              Left err -> error (show err)) :: IO (Either SomeException String)
          case result of
            Left e -> show e `shouldSatisfy` isInfixOf "unbound symbol"
            Right _ -> expectationFailure "x should not be visible outside let"
        Left err -> error (show err)

    it "empty body returns nil" $
      run "(let ((x 1)))" `shouldReturn` "()"

  describe "loop/recur" $ do
    it "sum 0..99" $
      run "(loop ((i 0) (sum 0)) (if (= i 100) sum (recur (+ i 1) (+ sum i))))"
        `shouldReturn` "4950"

    it "factorial" $ do
      env <- defaultEnv
      case parseLisp "(define fact (lambda (n) (loop ((i n) (acc 1)) (if (= i 0) acc (recur (- i 1) (* acc i))))))" of
        Right expr -> do
          _ <- eval env expr
          case parseLisp "(fact 10)" of
            Right e -> do
              val <- eval env e
              printVal val `shouldBe` "3628800"
            Left err -> error (show err)
        Left err -> error (show err)

    it "loop without recur returns body value" $
      run "(loop ((x 42)) x)" `shouldReturn` "42"

    it "loop with sequential init bindings" $
      run "(loop ((x 10) (y (+ x 5))) y)" `shouldReturn` "15"

    it "recur arity mismatch errors" $ do
      result <- try (evaluate =<< run "(loop ((x 0)) (recur 1 2))") :: IO (Either SomeException String)
      case result of
        Left e -> show e `shouldSatisfy` isInfixOf "recur: expected 1"
        Right _ -> expectationFailure "should have thrown"

    it "loop with multi-body" $
      run "(loop ((i 0) (sum 0)) (define next (+ i 1)) (if (= i 10) sum (recur next (+ sum i))))"
        `shouldReturn` "45"

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

    it "import loads a module file" $ do
      TIO.writeFile "/tmp/testmod.gsp"
        "(module testmod (export x) (define x 42))"
      env <- defaultEnv
      case parseLisp "(import \"/tmp/testmod.gsp\")" of
        Right expr -> do
          _ <- eval env expr
          case parseLisp "x" of
            Right e -> do
              val <- eval env e
              printVal val `shouldBe` "42"
            Left err -> error (show err)
        Left err -> error (show err)

    it "import creates qualified bindings" $ do
      TIO.writeFile "/tmp/qualmod.gsp"
        "(module qualmod (export val) (define val 99))"
      env <- defaultEnv
      case parseLisp "(import \"/tmp/qualmod.gsp\")" of
        Right expr -> do
          _ <- eval env expr
          case parseLisp "qualmod.val" of
            Right e -> do
              val <- eval env e
              printVal val `shouldBe` "99"
            Left err -> error (show err)
        Left err -> error (show err)

    it "import caches modules" $ do
      TIO.writeFile "/tmp/cachemod.gsp"
        "(module cachemod (export x) (define x 1))"
      env <- defaultEnv
      case parseLisp "(import \"/tmp/cachemod.gsp\")" of
        Right e1 -> do
          _ <- eval env e1
          case parseLisp "(import \"/tmp/cachemod.gsp\")" of
            Right e2 -> do
              _ <- eval env e2
              ed <- readIORef env
              Map.size (envModules ed) `shouldBe` 1
            Left err -> error (show err)
        Left err -> error (show err)

    it "import detects circular dependency" $ do
      TIO.writeFile "/tmp/circ_a.gsp"
        "(module circ_a (export) (import \"/tmp/circ_b.gsp\"))"
      TIO.writeFile "/tmp/circ_b.gsp"
        "(module circ_b (export) (import \"/tmp/circ_a.gsp\"))"
      env <- defaultEnv
      result <- try (evaluate =<< do
        case parseLisp "(import \"/tmp/circ_a.gsp\")" of
          Right e -> printVal <$> eval env e
          Left err -> error (show err)) :: IO (Either SomeException String)
      case result of
        Left e -> show e `shouldSatisfy` isInfixOf "circular"
        Right _ -> expectationFailure "should have thrown"

    it "dot-qualified lookup works for modules defined inline" $ do
      env <- defaultEnv
      case parseLisp "(module m (export val) (define val 7))" of
        Right expr -> do
          _ <- eval env expr
          case parseLisp "m.val" of
            Right e -> do
              val <- eval env e
              printVal val `shouldBe` "7"
            Left err -> error (show err)
        Left err -> error (show err)

    it "dot-qualified lookup falls back to envModules" $ do
      env <- defaultEnv
      case parseLisp "(module ns (export a) (define a 55))" of
        Right expr -> do
          _ <- eval env expr
          -- Remove the flat binding to test the dot-split path
          modifyIORef' env $ \ed -> ed
            { envBindings = Map.delete "ns.a" (envBindings ed) }
          case parseLisp "ns.a" of
            Right e -> do
              val <- eval env e
              printVal val `shouldBe` "55"
            Left err -> error (show err)
        Left err -> error (show err)

    it "import by name looks for .gsp file" $ do
      TIO.writeFile "namemod.gsp"
        "(module namemod (export greeting) (define greeting 42))"
      env <- defaultEnv
      case parseLisp "(import namemod)" of
        Right expr -> do
          _ <- eval env expr
          case parseLisp "greeting" of
            Right e -> do
              val <- eval env e
              printVal val `shouldBe` "42"
            Left err -> error (show err)
        Left err -> error (show err)
      removeFile "namemod.gsp"

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

  describe "prelude" $ do
    let runPrelude exprs = do
          env <- defaultEnv
          case parseLisp "(import \"lib/prelude.gsp\")" of
            Right importExpr -> do
              _ <- eval env importExpr
              results <- mapM (\src -> case parseLisp (T.pack src) of
                Right e -> eval env e
                Left err -> error (show err)) exprs
              pure $ printVal (last results)
            Left err -> error (show err)

    it "not" $ do
      runPrelude ["(not #t)"] `shouldReturn` "#f"
      runPrelude ["(not #f)"] `shouldReturn` "#t"

    it "and" $ do
      runPrelude ["(and #t #t)"] `shouldReturn` "#t"
      runPrelude ["(and #t #f)"] `shouldReturn` "#f"

    it "or" $ do
      runPrelude ["(or #f #t)"] `shouldReturn` "#t"
      runPrelude ["(or #f #f)"] `shouldReturn` "#f"

    it "abs" $ do
      runPrelude ["(abs (- 0 5))"] `shouldReturn` "5"
      runPrelude ["(abs 3)"] `shouldReturn` "3"

    it "min and max" $ do
      runPrelude ["(min 3 7)"] `shouldReturn` "3"
      runPrelude ["(max 3 7)"] `shouldReturn` "7"

    it "length" $ do
      runPrelude ["(length '())"] `shouldReturn` "0"
      runPrelude ["(length (list 1 2 3))"] `shouldReturn` "3"

    it "reverse" $
      runPrelude ["(reverse (list 1 2 3))"] `shouldReturn` "(3 2 1)"

    it "append" $
      runPrelude ["(append (list 1 2) (list 3 4))"] `shouldReturn` "(1 2 3 4)"

    it "map" $
      runPrelude ["(map (lambda (x) (+ x 1)) (list 1 2 3))"] `shouldReturn` "(2 3 4)"

    it "filter" $
      runPrelude ["(filter (lambda (x) (> x 2)) (list 1 2 3 4))"] `shouldReturn` "(3 4)"

    it "fold-left" $
      runPrelude ["(fold-left + 0 (list 1 2 3 4))"] `shouldReturn` "10"

    it "fold-right" $
      runPrelude ["(fold-right cons '() (list 1 2 3))"] `shouldReturn` "(1 2 3)"

    it "nth" $
      runPrelude ["(nth 1 (list 10 20 30))"] `shouldReturn` "20"

    it "range" $
      runPrelude ["(range 0 5)"] `shouldReturn` "(0 1 2 3 4)"

  describe "condition system" $ do
    it "with-handler returns body value on no signal" $
      run "(with-handler (lambda (c r) c) 42)" `shouldReturn` "42"

    it "signal invokes handler" $
      run "(with-handler (lambda (c r) (+ c 100)) (signal 1))" `shouldReturn` "101"

    it "handler can restart" $
      run "(with-handler (lambda (c r) (r 0)) (+ 1 (signal 99)))" `shouldReturn` "1"

    it "nested handlers" $
      run "(with-handler (lambda (c r) (+ c 1000)) (with-handler (lambda (c r) (r (+ c 10))) (+ 1 (signal 5))))" `shouldReturn` "16"

    it "handler without restart abandons body" $
      run "(+ 1 (with-handler (lambda (c r) 99) (+ (signal 1) 1000)))" `shouldReturn` "100"

    it "catches Haskell errors" $
      run "(with-handler (lambda (c r) \"caught\") (car 42))" `shouldReturn` "\"caught\""
