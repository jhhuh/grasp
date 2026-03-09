# Grasp v2 Core Interpreter Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a minimal working Grasp interpreter with CBPV-aware evaluation, STM transactions as first-class, and a REPL — the foundation for gradual compilation.

**Architecture:** Tree-walking evaluator over S-expressions, strict by default (CBV). Three CBPV modes tracked in the type system: Value (data), Transaction (STM), Computation (IO). Parser reuses megaparsec approach from v1. Built on the existing v2 skeleton (Types, NativeTypes, RuntimeCheck, RtsBridge — 43 tests passing).

**Tech Stack:** GHC 9.8.4, megaparsec (parser), stm (transactions), isocline (REPL), hspec (tests)

**v1 Reference:** Full working interpreter archived at `v1/`. Consult but don't copy verbatim — v2 has different architectural goals.

---

### Task 1: Parser

The parser is straightforward and nearly identical to v1. S-expressions, booleans, strings, integers, doubles, symbols, quote shorthand.

**Files:**
- Create: `src/Grasp/Parser.hs`
- Create: `test/ParserSpec.hs`
- Modify: `grasp.cabal` (add `Grasp.Parser` to both `other-modules`, add `ParserSpec` to test modules)

**Step 1: Write the failing tests**

```haskell
-- test/ParserSpec.hs
{-# LANGUAGE OverloadedStrings #-}
module ParserSpec (spec) where

import Test.Hspec
import Test.Hspec.Megaparsec
import Text.Megaparsec (parse)
import Grasp.Types
import Grasp.Parser

spec :: Spec
spec = describe "Parser" $ do
  describe "atoms" $ do
    it "parses integers" $
      parseLisp "42" `shouldParse` EInt 42

    it "parses negative integers" $
      parseLisp "-7" `shouldParse` EInt (-7)

    it "parses doubles" $
      parseLisp "3.14" `shouldParse` EDouble 3.14

    it "parses strings" $
      parseLisp "\"hello\"" `shouldParse` EStr "hello"

    it "parses booleans" $ do
      parseLisp "#t" `shouldParse` EBool True
      parseLisp "#f" `shouldParse` EBool False

    it "parses symbols" $
      parseLisp "foo" `shouldParse` ESym "foo"

    it "parses operator symbols" $
      parseLisp "+" `shouldParse` ESym "+"

  describe "lists" $ do
    it "parses empty list" $
      parseLisp "()" `shouldParse` EList []

    it "parses simple list" $
      parseLisp "(+ 1 2)" `shouldParse` EList [ESym "+", EInt 1, EInt 2]

    it "parses nested list" $
      parseLisp "(if #t (+ 1 2) 0)" `shouldParse`
        EList [ESym "if", EBool True, EList [ESym "+", EInt 1, EInt 2], EInt 0]

  describe "quote" $ do
    it "parses quote shorthand" $
      parseLisp "'foo" `shouldParse` EList [ESym "quote", ESym "foo"]

    it "parses quoted list" $
      parseLisp "'(1 2 3)" `shouldParse`
        EList [ESym "quote", EList [EInt 1, EInt 2, EInt 3]]

  describe "parseFile" $ do
    it "parses multiple expressions" $
      parseFile "(define x 1) (+ x 2)" `shouldParse`
        [EList [ESym "define", ESym "x", EInt 1],
         EList [ESym "+", ESym "x", EInt 2]]

  describe "comments" $ do
    it "skips line comments" $
      parseLisp "; comment\n42" `shouldParse` EInt 42
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -5`
Expected: Compilation failure — `Grasp.Parser` module not found

**Step 3: Write the parser**

```haskell
-- src/Grasp/Parser.hs
{-# LANGUAGE OverloadedStrings #-}
module Grasp.Parser
  ( pExpr
  , parseLisp
  , parseFile
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

pDouble :: Parser LispExpr
pDouble = EDouble <$> lexeme (L.signed (pure ()) L.float)

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
pExpr = pBool <|> pStr <|> pQuote <|> pList <|> try pDouble <|> try pInt <|> pSym

parseLisp :: Text -> Either (ParseErrorBundle Text Void) LispExpr
parseLisp = parse (sc *> pExpr <* eof) "<repl>"

parseFile :: Text -> Either (ParseErrorBundle Text Void) [LispExpr]
parseFile = parse (sc *> many pExpr <* eof) "<file>"
```

**Step 4: Update cabal file**

Add `Grasp.Parser` to `other-modules` in both executable and test-suite sections.
Add `ParserSpec` to `other-modules` in test-suite section.

**Step 5: Run tests to verify they pass**

Run: `nix develop -c cabal test 2>&1 | tail -10`
Expected: All parser tests PASS, existing 43 tests still PASS

**Step 6: Commit**

```bash
git add src/Grasp/Parser.hs test/ParserSpec.hs grasp.cabal
git commit -m "feat: add S-expression parser with tests"
```

---

### Task 2: Printer

Pretty-print Grasp values for REPL output. Straight port from v1.

**Files:**
- Create: `src/Grasp/Printer.hs`
- Create: `test/PrinterSpec.hs`
- Modify: `grasp.cabal`

**Step 1: Write the failing tests**

```haskell
-- test/PrinterSpec.hs
{-# LANGUAGE OverloadedStrings #-}
module PrinterSpec (spec) where

import Test.Hspec
import Grasp.NativeTypes
import Grasp.Printer

spec :: Spec
spec = describe "Printer" $ do
  it "prints integers" $
    printVal (mkInt 42) `shouldBe` "42"

  it "prints doubles" $
    printVal (mkDouble 3.14) `shouldBe` "3.14"

  it "prints booleans" $ do
    printVal (mkBool True) `shouldBe` "#t"
    printVal (mkBool False) `shouldBe` "#f"

  it "prints strings" $
    printVal (mkStr "hello") `shouldBe` "\"hello\""

  it "prints symbols" $
    printVal (mkSym "foo") `shouldBe` "foo"

  it "prints nil as ()" $
    printVal mkNil `shouldBe` "()"

  it "prints proper lists" $
    printVal (mkCons (mkInt 1) (mkCons (mkInt 2) mkNil))
      `shouldBe` "(1 2)"

  it "prints dotted pairs" $
    printVal (mkCons (mkInt 1) (mkInt 2))
      `shouldBe` "(1 . 2)"

  it "prints nested lists" $
    printVal (mkCons (mkCons (mkInt 1) mkNil) mkNil)
      `shouldBe` "((1))"

  it "prints lambda" $
    printVal (mkPrim "+" undefined) `shouldBe` "<primitive:+>"
```

**Step 2: Run tests — expect failure**

**Step 3: Write the printer**

```haskell
-- src/Grasp/Printer.hs
module Grasp.Printer (printVal) where

import qualified Data.Text as T
import GHC.Exts (Any)
import Grasp.NativeTypes

printVal :: Any -> String
printVal v = case graspTypeOf v of
  GTInt       -> show (toInt v)
  GTDouble    -> show (toDouble v)
  GTBoolTrue  -> "#t"
  GTBoolFalse -> "#f"
  GTSym       -> T.unpack (toSym v)
  GTStr       -> "\"" <> T.unpack (toStr v) <> "\""
  GTNil       -> "()"
  GTCons      -> "(" <> printCons (toCar v) (toCdr v) <> ")"
  GTLambda    -> "<lambda>"
  GTPrim      -> "<primitive:" <> T.unpack (toPrimName v) <> ">"
  GTLazy      -> "<lazy>"
  GTMacro     -> "<macro>"
  GTChan      -> "<chan>"
  GTModule    -> "<module:" <> T.unpack (toModuleName v) <> ">"
  GTRecur     -> error "recur used outside of loop"
  GTPromptTag -> "<prompt-tag>"

printCons :: Any -> Any -> String
printCons x d
  | isNil d   = printVal x
  | isCons d  = printVal x <> " " <> printCons (toCar d) (toCdr d)
  | otherwise = printVal x <> " . " <> printVal d
```

**Step 4: Update cabal, run tests — expect PASS**

**Step 5: Commit**

```bash
git add src/Grasp/Printer.hs test/PrinterSpec.hs grasp.cabal
git commit -m "feat: add value printer with tests"
```

---

### Task 3: Core Evaluator — Literals, Env, Define, If

The evaluator is the heart of v2. Start minimal: literals, symbol lookup, define, if.

**Files:**
- Create: `src/Grasp/Eval.hs`
- Create: `test/EvalSpec.hs`
- Modify: `grasp.cabal`

**Step 1: Write the failing tests**

```haskell
-- test/EvalSpec.hs
{-# LANGUAGE OverloadedStrings #-}
module EvalSpec (spec) where

import Test.Hspec
import Grasp.Types
import Grasp.NativeTypes
import Grasp.Eval
import Grasp.Printer

-- Helper: eval a LispExpr in a fresh env, return printed result
evalPrint :: LispExpr -> IO String
evalPrint expr = do
  env <- defaultEnv
  val <- eval env expr
  pure (printVal val)

-- Helper: eval a string (parse + eval + print)
run :: String -> IO String
run = evalPrint . read'
  where read' _ = error "not yet — use LispExpr directly for now"

spec :: Spec
spec = describe "Eval" $ do
  describe "literals" $ do
    it "evaluates integers" $
      evalPrint (EInt 42) `shouldReturn` "42"

    it "evaluates doubles" $
      evalPrint (EDouble 3.14) `shouldReturn` "3.14"

    it "evaluates strings" $
      evalPrint (EStr "hello") `shouldReturn` "\"hello\""

    it "evaluates booleans" $
      evalPrint (EBool True) `shouldReturn` "#t"

  describe "define and lookup" $ do
    it "defines and retrieves a variable" $ do
      env <- defaultEnv
      _ <- eval env (EList [ESym "define", ESym "x", EInt 42])
      val <- eval env (ESym "x")
      printVal val `shouldBe` "42"

  describe "if" $ do
    it "takes then branch on #t" $
      evalPrint (EList [ESym "if", EBool True, EInt 1, EInt 2])
        `shouldReturn` "1"

    it "takes else branch on #f" $
      evalPrint (EList [ESym "if", EBool False, EInt 1, EInt 2])
        `shouldReturn` "2"

  describe "quote" $ do
    it "returns symbol unevaluated" $
      evalPrint (EList [ESym "quote", ESym "foo"]) `shouldReturn` "foo"

    it "returns list unevaluated" $
      evalPrint (EList [ESym "quote", EList [EInt 1, EInt 2]])
        `shouldReturn` "(1 2)"

  describe "built-in primitives" $ do
    it "adds integers" $
      evalPrint (EList [ESym "+", EInt 2, EInt 3]) `shouldReturn` "5"

    it "compares integers" $
      evalPrint (EList [ESym "<", EInt 1, EInt 2]) `shouldReturn` "#t"

    it "builds and destructures lists" $ do
      env <- defaultEnv
      _ <- eval env (EList [ESym "define", ESym "xs",
              EList [ESym "list", EInt 1, EInt 2, EInt 3]])
      val <- eval env (EList [ESym "car", ESym "xs"])
      printVal val `shouldBe` "1"
```

**Step 2: Run tests — expect compilation failure**

**Step 3: Write the evaluator**

```haskell
-- src/Grasp/Eval.hs
{-# LANGUAGE OverloadedStrings #-}
module Grasp.Eval
  ( eval
  , apply
  , defaultEnv
  ) where

import Data.IORef
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import GHC.Exts (Any)

import Grasp.Types
import Grasp.NativeTypes

defaultEnv :: IO Env
defaultEnv = do
  ghcRef <- newIORef Nothing
  newIORef $ EnvData
    { envBindings = Map.fromList
        [ ("+",     mkPrim "+"     (numBinOp (+)))
        , ("-",     mkPrim "-"     (numBinOp (-)))
        , ("*",     mkPrim "*"     (numBinOp (*)))
        , ("div",   mkPrim "div"   (numBinOp div))
        , ("=",     mkPrim "="     eqOp)
        , ("<",     mkPrim "<"     (cmpOp (<)))
        , (">",     mkPrim ">"     (cmpOp (>)))
        , ("list",  mkPrim "list"  listOp)
        , ("cons",  mkPrim "cons"  consOp)
        , ("car",   mkPrim "car"   carOp)
        , ("cdr",   mkPrim "cdr"   cdrOp)
        , ("null?", mkPrim "null?" nullOp)
        ]
    , envHsRegistry = Map.empty
    , envGhcSession = ghcRef
    , envModules = Map.empty
    , envLoading = []
    }

-- Primitives

numBinOp :: (Int -> Int -> Int) -> [Any] -> IO Any
numBinOp op [a, b] = do
  a' <- forceIfLazy a
  b' <- forceIfLazy b
  pure $ mkInt (op (toInt a') (toInt b'))
numBinOp _ _ = error "expected two integers"

eqOp :: [Any] -> IO Any
eqOp [a, b] = mkBool <$> graspEq a b
eqOp _ = error "= expects two arguments"

cmpOp :: (Int -> Int -> Bool) -> [Any] -> IO Any
cmpOp op [a, b] = do
  a' <- forceIfLazy a
  b' <- forceIfLazy b
  pure $ mkBool (op (toInt a') (toInt b'))
cmpOp _ _ = error "comparison expects two integers"

listOp :: [Any] -> IO Any
listOp = pure . foldr mkCons mkNil

consOp :: [Any] -> IO Any
consOp [a, b] = pure $ mkCons a b
consOp _ = error "cons expects two arguments"

carOp :: [Any] -> IO Any
carOp [v] = do { v' <- forceIfLazy v; pure (toCar v') }
carOp _ = error "car expects one argument"

cdrOp :: [Any] -> IO Any
cdrOp [v] = do { v' <- forceIfLazy v; pure (toCdr v') }
cdrOp _ = error "cdr expects one argument"

nullOp :: [Any] -> IO Any
nullOp [v] = do { v' <- forceIfLazy v; pure (mkBool (isNil v')) }
nullOp _ = error "null? expects one argument"

-- Evaluator

eval :: Env -> LispExpr -> IO GraspVal
eval _ (EInt n)    = pure $ mkInt (fromInteger n)
eval _ (EDouble d) = pure $ mkDouble d
eval _ (EStr s)    = pure $ mkStr s
eval _ (EBool b)   = pure $ mkBool b

eval env (ESym s) = do
  ed <- readIORef env
  case Map.lookup s (envBindings ed) of
    Just v  -> pure v
    Nothing -> error $ "unbound symbol: " <> T.unpack s

eval _ (EList [ESym "quote", e]) = evalQuote e

eval env (EList [ESym "if", cond, then_, else_]) = do
  c <- eval env cond
  c' <- forceIfLazy c
  if graspTypeOf c' /= GTBoolFalse
    then eval env then_
    else eval env else_

eval env (EList [ESym "define", ESym name, body]) = do
  val <- eval env body
  modifyIORef' env $ \ed ->
    ed { envBindings = Map.insert name val (envBindings ed) }
  pure mkNil

eval env (EList (ESym "lambda" : EList params : body)) = do
  let paramNames = map (\(ESym s) -> s) params
      bodyExpr = case body of
        [single] -> single
        multiple -> EList (ESym "begin" : multiple)
  pure $ mkLambda paramNames bodyExpr env

eval env (EList (ESym "begin" : exprs)) = case exprs of
  []     -> pure mkNil
  [e]    -> eval env e
  (e:es) -> eval env e >> eval env (EList (ESym "begin" : es))

eval env (EList (fn : args)) = do
  f <- eval env fn
  vals <- mapM (eval env) args
  apply f vals

eval _ (EList []) = pure mkNil

-- catch-all for unhandled EQuoter/EAntiquote
eval _ e = error $ "cannot eval: " <> show e

-- Quote

evalQuote :: LispExpr -> IO Any
evalQuote (EInt n)    = pure $ mkInt (fromInteger n)
evalQuote (EDouble d) = pure $ mkDouble d
evalQuote (EStr s)    = pure $ mkStr s
evalQuote (EBool b)   = pure $ mkBool b
evalQuote (ESym s)    = pure $ mkSym s
evalQuote (EList es)  = foldr (\e acc -> mkCons <$> evalQuote e <*> pure acc) (pure mkNil) es
evalQuote e           = error $ "cannot quote: " <> show e

-- Apply

apply :: Any -> [Any] -> IO Any
apply f args = do
  f' <- forceIfLazy f
  case graspTypeOf f' of
    GTPrim -> toPrimFn f' args
    GTLambda -> do
      let (params, body, closureEnv) = toLambdaParts f'
      childEnv <- readIORef closureEnv >>= newIORef
      let bindings = zip params args
      modifyIORef' childEnv $ \ed ->
        ed { envBindings = foldr (uncurry Map.insert) (envBindings ed) bindings }
      eval childEnv body
    _ -> error "not a function"
```

**Step 4: Update cabal, run tests — expect PASS**

**Step 5: Commit**

```bash
git add src/Grasp/Eval.hs test/EvalSpec.hs grasp.cabal
git commit -m "feat: add core evaluator with literals, define, if, lambda, primitives"
```

---

### Task 4: Evaluator — Let, Loop/Recur, Lazy/Force

Add control flow: `let`, `begin` (already done), `loop`/`recur`, `lazy`/`force`.

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `test/EvalSpec.hs`

**Step 1: Add failing tests to EvalSpec.hs**

```haskell
  describe "let" $ do
    it "binds local variables" $
      evalPrint (EList [ESym "let",
        EList [ESym "x", EInt 10, ESym "y", EInt 20],
        EList [ESym "+", ESym "x", ESym "y"]])
        `shouldReturn` "30"

  describe "loop/recur" $ do
    it "loops with recur" $
      -- (loop (i 0 sum 0) (if (= i 5) sum (recur (+ i 1) (+ sum i))))
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
      _ <- eval env (EList [ESym "define", ESym "x",
              EList [ESym "lazy", EList [ESym "+", EInt 1, EInt 2]]])
      val <- eval env (EList [ESym "force", ESym "x"])
      printVal val `shouldBe` "3"
```

**Step 2: Run tests — expect failure for let/loop/lazy**

**Step 3: Add eval clauses**

Add to `src/Grasp/Eval.hs` before the catch-all `(fn : args)` clause:

```haskell
eval env (EList (ESym "let" : EList bindings : body)) = do
  childEnv <- readIORef env >>= newIORef
  let pairs = toPairs bindings
  mapM_ (\(ESym name, expr) -> do
    val <- eval childEnv expr
    modifyIORef' childEnv $ \ed ->
      ed { envBindings = Map.insert name val (envBindings ed) }
    ) pairs
  eval childEnv (case body of [e] -> e; es -> EList (ESym "begin" : es))
  where
    toPairs [] = []
    toPairs (k:v:rest) = (k,v) : toPairs rest
    toPairs _ = error "let: odd number of binding forms"

eval env (EList [ESym "lazy", body]) = do
  thunk <- unsafeInterleaveIO (eval env body)
  pure $ mkLazy thunk

eval env (EList [ESym "force", expr]) = do
  val <- eval env expr
  forceIfLazy val

eval env (EList (ESym "recur" : args)) = do
  vals <- mapM (eval env) args
  pure $ mkRecur vals

eval env (EList (ESym "loop" : EList bindings : body)) = do
  childEnv <- readIORef env >>= newIORef
  let pairs = toPairs bindings
      names = map (\(ESym s, _) -> s) pairs
  mapM_ (\(ESym name, expr) -> do
    val <- eval childEnv expr
    modifyIORef' childEnv $ \ed ->
      ed { envBindings = Map.insert name val (envBindings ed) }
    ) pairs
  let loopBody = case body of [e] -> e; es -> EList (ESym "begin" : es)
  let go = do
        result <- eval childEnv loopBody
        if graspTypeOf result == GTRecur
          then do
            let newVals = toRecurArgs result
            modifyIORef' childEnv $ \ed ->
              ed { envBindings = foldr (uncurry Map.insert) (envBindings ed)
                                       (zip names newVals) }
            go
          else pure result
  go
  where
    toPairs [] = []
    toPairs (k:v:rest) = (k,v) : toPairs rest
    toPairs _ = error "loop: odd number of binding forms"
```

Also add `import System.IO.Unsafe (unsafeInterleaveIO)` to the imports.

**Step 4: Run tests — expect PASS**

**Step 5: Commit**

```bash
git add src/Grasp/Eval.hs test/EvalSpec.hs
git commit -m "feat: add let, loop/recur, lazy/force to evaluator"
```

---

### Task 5: STM Transactions — First-Class Mode

This is where v2 diverges from v1. STM transactions are a first-class CBPV mode. Add `TVar` as a native type, plus primitives: `make-tvar`, `read-tvar`, `write-tvar`, `atomically`, `retry`.

**Files:**
- Modify: `src/Grasp/NativeTypes.hs` (add GraspTVar ADT + type discrimination)
- Modify: `src/Grasp/Printer.hs` (print TVars)
- Modify: `src/Grasp/Eval.hs` (STM primitives + atomically)
- Create: `test/StmSpec.hs`
- Modify: `grasp.cabal`

**Step 1: Write the failing tests**

```haskell
-- test/StmSpec.hs
{-# LANGUAGE OverloadedStrings #-}
module StmSpec (spec) where

import Test.Hspec
import Grasp.Types
import Grasp.NativeTypes
import Grasp.Eval
import Grasp.Printer

evalPrint :: LispExpr -> IO String
evalPrint expr = do
  env <- defaultEnv
  val <- eval env expr
  pure (printVal val)

spec :: Spec
spec = describe "STM" $ do
  describe "TVar basics" $ do
    it "creates and reads a TVar" $ do
      env <- defaultEnv
      -- (atomically (let (tv (make-tvar 42)) (read-tvar tv)))
      val <- eval env
        (EList [ESym "atomically",
          EList [ESym "let",
            EList [ESym "tv", EList [ESym "make-tvar", EInt 42]],
            EList [ESym "read-tvar", ESym "tv"]]])
      printVal val `shouldBe` "42"

    it "writes and reads back" $ do
      env <- defaultEnv
      -- (let (tv (atomically (make-tvar 0)))
      --   (atomically (begin (write-tvar tv 99) (read-tvar tv))))
      val <- eval env
        (EList [ESym "let",
          EList [ESym "tv",
            EList [ESym "atomically", EList [ESym "make-tvar", EInt 0]]],
          EList [ESym "atomically",
            EList [ESym "begin",
              EList [ESym "write-tvar", ESym "tv", EInt 99],
              EList [ESym "read-tvar", ESym "tv"]]]])
      printVal val `shouldBe` "99"

  describe "transaction composability" $ do
    it "composes two TVar operations atomically" $ do
      env <- defaultEnv
      -- Two TVars, transfer between them in one transaction
      val <- eval env
        (EList [ESym "let",
          EList [
            ESym "a", EList [ESym "atomically", EList [ESym "make-tvar", EInt 100]],
            ESym "b", EList [ESym "atomically", EList [ESym "make-tvar", EInt 0]]],
          EList [ESym "begin",
            EList [ESym "atomically",
              EList [ESym "begin",
                EList [ESym "write-tvar", ESym "a",
                  EList [ESym "-",
                    EList [ESym "atomically", EList [ESym "read-tvar", ESym "a"]],
                    EInt 30]],
                EList [ESym "write-tvar", ESym "b",
                  EList [ESym "+",
                    EList [ESym "atomically", EList [ESym "read-tvar", ESym "b"]],
                    EInt 30]]]],
            EList [ESym "atomically", EList [ESym "read-tvar", ESym "b"]]]])
      printVal val `shouldBe` "30"
```

**Step 2: Run tests — expect failure**

**Step 3: Add TVar native type**

In `src/Grasp/NativeTypes.hs`, add:

```haskell
-- Add to imports:
import Control.Concurrent.STM (TVar)

-- Add new ADT (near other ADTs around line 30):
data GraspTVar = GraspTVar (TVar Any)

-- Add to GraspType enum:
-- GTTVar  (add after GTPromptTag)

-- Add info pointer sentinel:
-- {-# NOINLINE tvarInfoPtr #-}
-- tvarInfoPtr :: Ptr ()
-- tvarInfoPtr = getInfoPtr (GraspTVar undefined)

-- Add to graspTypeOf: compare against tvarInfoPtr -> GTTVar

-- Add constructor/extractor:
-- mkTVar :: TVar Any -> Any
-- mkTVar tv = unsafeCoerce (GraspTVar tv)
-- toTVar :: Any -> TVar Any
-- toTVar v = let GraspTVar tv = unsafeCoerce v in tv
```

Also update `showGraspType` and `Printer.hs`.

**Step 4: Add STM primitives to evaluator**

In `src/Grasp/Eval.hs`, add STM primitives:

```haskell
-- Add to imports:
import Control.Concurrent.STM

-- Add to defaultEnv bindings:
-- ("make-tvar", mkPrim "make-tvar" makeTVarOp)
-- ("read-tvar", mkPrim "read-tvar" readTVarOp)
-- ("write-tvar", mkPrim "write-tvar" writeTVarOp)

-- Add primitive implementations:
makeTVarOp :: [Any] -> IO Any
makeTVarOp [v] = mkTVar <$> newTVarIO v
makeTVarOp _ = error "make-tvar expects one argument"

readTVarOp :: [Any] -> IO Any
readTVarOp [v] = readTVarIO (toTVar v)
readTVarOp _ = error "read-tvar expects one argument"

writeTVarOp :: [Any] -> IO Any
writeTVarOp [tv, val] = do
  atomically $ writeTVar (toTVar tv) val
  pure mkNil
writeTVarOp _ = error "write-tvar expects two arguments"

-- Add eval clause for atomically:
eval env (EList [ESym "atomically", body]) = do
  -- For now, just eval the body. True STM transaction wrapping
  -- comes when we have the STM monad threading.
  eval env body
```

**Note:** The initial `atomically` is a thin wrapper. The full CBPV mode distinction (preventing IO inside STM) is Task 8. Here we establish the surface syntax and TVar operations.

**Step 5: Run tests — expect PASS**

**Step 6: Commit**

```bash
git add src/Grasp/NativeTypes.hs src/Grasp/Eval.hs src/Grasp/Printer.hs test/StmSpec.hs grasp.cabal
git commit -m "feat: add TVar native type and STM primitives"
```

---

### Task 6: REPL

Minimal interactive REPL with isocline.

**Files:**
- Modify: `src/Main.hs`
- Modify: `grasp.cabal` (ensure isocline dependency)

**Step 1: No separate test — REPL is tested interactively**

**Step 2: Write Main.hs**

```haskell
-- src/Main.hs
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.Text as T
import System.Isocline

import Grasp.Types
import Grasp.Parser (parseLisp)
import Grasp.Eval (eval, defaultEnv)
import Grasp.Printer (printVal)

main :: IO ()
main = do
  setHistory "grasp_history" 200
  env <- defaultEnv
  putStrLn "grasp v2 — a programmable GHC RTS interface"
  repl env

repl :: Env -> IO ()
repl env = do
  mline <- readlineExMaybe "grasp> " Nothing
  case mline of
    Nothing -> putStrLn "bye."
    Just line
      | null (trim line) -> repl env
      | otherwise -> do
          case parseLisp (T.pack line) of
            Left err -> putStrLn $ "parse error: " <> show err
            Right expr -> do
              result <- eval env expr
              putStrLn (printVal result)
          repl env
  where
    trim = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse
```

**Step 3: Test manually**

Run: `nix develop -c cabal run grasp`
Try: `(+ 1 2)` → should print `3`
Try: `(define x 42)` then `x` → should print `42`
Try: Ctrl-D → should print `bye.`

**Step 4: Commit**

```bash
git add src/Main.hs
git commit -m "feat: add minimal REPL with isocline"
```

---

### Task 7: Parse-Eval Integration Tests

Now that we have parser + eval + printer, add end-to-end tests that parse strings.

**Files:**
- Modify: `test/EvalSpec.hs`

**Step 1: Add helper and integration tests**

Add this helper at the top of EvalSpec:

```haskell
import Grasp.Parser (parseLisp)
import qualified Data.Text as T

-- Parse a string, eval, print the result
run :: Env -> String -> IO String
run env input = case parseLisp (T.pack input) of
  Left err -> error (show err)
  Right expr -> do
    val <- eval env expr
    pure (printVal val)

-- Run in a fresh env
runFresh :: String -> IO String
runFresh input = defaultEnv >>= \env -> run env input
```

Add integration tests:

```haskell
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
```

**Step 2: Run tests — expect PASS**

**Step 3: Commit**

```bash
git add test/EvalSpec.hs
git commit -m "test: add parse-eval integration tests"
```

---

### Task 8: STM Mode Enforcement (CBPV 3-Mode)

This is the key v2 architectural task. Enforce the Transaction mode: inside `atomically`, only STM-safe operations are allowed. IO operations (spawn, chan-put, chan-get) are forbidden.

**Files:**
- Modify: `src/Grasp/Eval.hs` (add eval mode parameter)
- Modify: `test/StmSpec.hs` (add mode violation tests)

**Step 1: Write failing tests**

```haskell
  describe "mode enforcement" $ do
    it "rejects IO operations inside atomically" $ do
      env <- defaultEnv
      -- (atomically (spawn (lambda () 42))) should fail
      eval env
        (EList [ESym "atomically",
          EList [ESym "spawn", EList [ESym "lambda", EList [], EInt 42]]])
        `shouldThrow` anyErrorCall
```

**Step 2: Run tests — expect it to NOT throw (current eval doesn't enforce)**

**Step 3: Add mode tracking to evaluator**

Add an `EvalMode` type and thread it through eval:

```haskell
-- In Eval.hs:
data EvalMode = ModeComputation | ModeTransaction
  deriving (Eq, Show)

-- Change eval signature:
-- eval :: EvalMode -> Env -> LispExpr -> IO GraspVal

-- In atomically clause: switch mode to ModeTransaction
-- In IO primitives (spawn, chan-put, chan-get): check mode, reject if ModeTransaction
```

This is a larger refactor. The key principle: `eval` carries the current mode. Primitives that perform IO check the mode and fail with a clear error if called in Transaction mode. STM primitives (`make-tvar`, `read-tvar`, `write-tvar`) work in both modes (in Computation mode they use `*IO` variants, in Transaction mode they would use real STM — but for now both use IO).

**Step 4: Run tests — expect PASS (mode violation correctly rejected)**

**Step 5: Commit**

```bash
git add src/Grasp/Eval.hs test/StmSpec.hs
git commit -m "feat: enforce CBPV 3-mode distinction in evaluator"
```

---

### Task 9: Concurrency Primitives

Add spawn, channels, borrowed from v1 but now mode-aware (rejected in Transaction mode).

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `test/EvalSpec.hs`

**Step 1: Add tests**

```haskell
  describe "concurrency" $ do
    it "spawn and channels" $ do
      env <- defaultEnv
      _ <- run env "(define ch (make-chan))"
      _ <- run env "(spawn (lambda () (chan-put ch 42)))"
      -- Small delay for spawn to complete
      run env "(chan-get ch)" `shouldReturn` "42"
```

**Step 2: Add primitives**

```haskell
-- Add to imports:
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (newChan, writeChan, readChan)
import Control.Exception (SomeException, catch)
import Control.Monad (void)

-- Add to defaultEnv:
-- ("spawn",     mkPrim "spawn"    spawnOp)
-- ("make-chan",  mkPrim "make-chan" makeChanOp)
-- ("chan-put",   mkPrim "chan-put"  chanPutOp)
-- ("chan-get",   mkPrim "chan-get"  chanGetOp)
```

These primitives check `EvalMode` and error in `ModeTransaction`.

**Step 3: Run tests — expect PASS**

**Step 4: Commit**

```bash
git add src/Grasp/Eval.hs test/EvalSpec.hs
git commit -m "feat: add mode-aware concurrency primitives"
```

---

### Task 10: Defmacro

Add `defmacro` for syntactic abstraction — needed for writing expressive Grasp code.

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `test/EvalSpec.hs`

**Step 1: Add tests**

```haskell
  describe "macros" $ do
    it "defmacro and expand" $ do
      env <- defaultEnv
      _ <- run env "(defmacro when (test body) (list 'if test body #f))"
      run env "(when #t 42)" `shouldReturn` "42"
      run env "(when #f 42)" `shouldReturn` "#f"
```

**Step 2: Add eval clauses for defmacro and macro expansion**

```haskell
eval mode env (EList [ESym "defmacro", ESym name, EList params, body]) = do
  let paramNames = map (\(ESym s) -> s) params
  let macro = mkMacro paramNames body env
  modifyIORef' env $ \ed ->
    ed { envBindings = Map.insert name macro (envBindings ed) }
  pure mkNil
```

In the function application clause, check if the head is a macro before treating as function call. If so, expand then eval.

**Step 3: Run tests — expect PASS**

**Step 4: Commit**

```bash
git add src/Grasp/Eval.hs test/EvalSpec.hs
git commit -m "feat: add defmacro with expansion"
```

---

### Task 11: Error Handling and File Loading

Add basic error handling (`try`/`catch` as Grasp functions, not special forms) and `load` for executing files.

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `src/Main.hs` (add file argument handling)

**Step 1: Add error handling primitive + load**

```haskell
-- Error handling: wrap Haskell exceptions
-- ("error", mkPrim "error" errorOp)
-- In Main.hs: check for command-line file argument, load + eval
```

**Step 2: Test with prelude**

Run: `nix develop -c cabal run grasp -- lib/prelude.gsp`
Then test prelude functions in REPL.

**Step 3: Commit**

```bash
git add src/Grasp/Eval.hs src/Main.hs
git commit -m "feat: add error primitive and file loading"
```

---

## Summary

| Task | What | Tests Added | Key Concept |
|------|------|-------------|-------------|
| 1 | Parser | ~15 | S-expressions |
| 2 | Printer | ~10 | Value display |
| 3 | Core Eval | ~10 | Literals, define, if, lambda, begin |
| 4 | Control Flow | ~3 | let, loop/recur, lazy/force |
| 5 | STM Transactions | ~3 | TVar, first-class transactions |
| 6 | REPL | manual | Interactive interface |
| 7 | Integration Tests | ~4 | Parse + eval + print roundtrip |
| 8 | Mode Enforcement | ~1+ | CBPV 3-mode (Value/Transaction/Computation) |
| 9 | Concurrency | ~1 | spawn, channels (mode-aware) |
| 10 | Macros | ~2 | defmacro |
| 11 | Error/Load | manual | Error handling, file execution |

After these 11 tasks: a working REPL with CBPV-aware evaluation, STM transactions as first-class, and the foundation for gradual compilation.
