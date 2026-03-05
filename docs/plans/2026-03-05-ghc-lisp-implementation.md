# ghc-lisp MVP Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A Lisp REPL that evaluates expressions and can call compiled Haskell functions via GHC's RTS C API.

**Architecture:** Haskell evaluator (parser + eval + REPL) with a C FFI bridge layer that wraps GHC's `rts_mkInt`, `rts_apply`, `rts_eval` for calling Haskell functions. Values start as Haskell ADTs; the C bridge enables RTS-level interop. Nix flake + Cabal build.

**Tech Stack:** GHC 9.8, Cabal, megaparsec, mtl, containers, text, GHC RTS C API

---

### Task 1: Project Scaffolding

**Files:**
- Create: `flake.nix`
- Create: `ghc-lisp.cabal`
- Create: `src/Main.hs`
- Create: `.gitignore`
- Create: `cbits/.gitkeep`
- Create: `test/Spec.hs`

**Step 1: Create flake.nix**

```nix
{
  description = "ghc-lisp — a dynamic Lisp on GHC's runtime";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      hsPkgs = pkgs.haskell.packages.ghc98;
    in
    {
      devShells.${system}.default = hsPkgs.shellFor {
        packages = p: [ ];
        nativeBuildInputs = [
          hsPkgs.cabal-install
          pkgs.overmind
          pkgs.tmux
        ];
      };
    };
}
```

**Step 2: Create ghc-lisp.cabal**

```cabal
cabal-version:   3.0
name:            ghc-lisp
version:         0.1.0.0
build-type:      Simple

executable ghc-lisp
  default-language: GHC2021
  hs-source-dirs:   src
  main-is:          Main.hs
  build-depends:
    , base        >= 4.18 && < 5
    , text
    , megaparsec
    , containers
    , mtl
  ghc-options:
    -threaded
    -rtsopts
    -with-rtsopts=-N

test-suite ghc-lisp-test
  default-language: GHC2021
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test, src
  main-is:          Spec.hs
  build-depends:
    , base        >= 4.18 && < 5
    , text
    , megaparsec
    , containers
    , mtl
    , hspec
    , hspec-megaparsec
  ghc-options:
    -threaded
    -rtsopts
```

**Step 3: Create src/Main.hs**

```haskell
module Main where

main :: IO ()
main = putStrLn "ghc-lisp: hello from GHC RTS"
```

**Step 4: Create test/Spec.hs**

```haskell
module Main where

main :: IO ()
main = putStrLn "No tests yet"
```

**Step 5: Create .gitignore**

```
dist-newstyle/
result
.direnv/
*.hi
*.o
*.dyn_hi
*.dyn_o
```

**Step 6: Create cbits/.gitkeep**

Empty file.

**Step 7: Verify build**

Run: `nix develop -c cabal build`
Expected: Builds successfully, produces `ghc-lisp` executable.

Run: `nix develop -c cabal run ghc-lisp`
Expected: Prints "ghc-lisp: hello from GHC RTS"

**Step 8: Commit**

```bash
git add flake.nix ghc-lisp.cabal src/Main.hs test/Spec.hs .gitignore cbits/.gitkeep
git commit -m "feat: project scaffolding with nix flake and cabal"
```

---

### Task 2: S-Expression Parser (TDD)

**Files:**
- Create: `src/GhcLisp/Types.hs`
- Create: `src/GhcLisp/Parser.hs`
- Create: `test/ParserSpec.hs`
- Modify: `test/Spec.hs`
- Modify: `ghc-lisp.cabal` (add modules)

**Step 1: Write the AST types**

Create `src/GhcLisp/Types.hs`:

```haskell
module GhcLisp.Types where

import Data.Text (Text)

-- | Source-level expression (what the parser produces)
data LispExpr
  = EInt Integer
  | EDouble Double
  | ESym Text
  | EStr Text
  | EList [LispExpr]
  | EBool Bool
  deriving (Show, Eq)
```

**Step 2: Write the failing parser tests**

Create `test/ParserSpec.hs`:

```haskell
module ParserSpec (spec) where

import Test.Hspec
import Test.Hspec.Megaparsec
import Text.Megaparsec
import Data.Text (Text)
import GhcLisp.Types
import GhcLisp.Parser

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
```

Update `test/Spec.hs`:

```haskell
{-# OPTIONS_GHC -F -pgmF hspec-discover #-}
```

**Step 3: Run tests to verify they fail**

Run: `nix develop -c cabal test`
Expected: Compilation fails (GhcLisp.Parser doesn't exist yet)

**Step 4: Write the parser**

Create `src/GhcLisp/Parser.hs`:

```haskell
module GhcLisp.Parser
  ( pExpr
  , parseLisp
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

import GhcLisp.Types

type Parser = Parsec Void Text

sc :: Parser ()
sc = L.space space1 (L.skipLineComment ";") empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

pInt :: Parser LispExpr
pInt = EInt <$> lexeme (L.signed empty L.decimal)

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
```

**Step 5: Update cabal file with new modules**

Add to the `executable` section:
```
  other-modules:
    GhcLisp.Types
    GhcLisp.Parser
```

Add to the `test-suite` section:
```
  other-modules:
    GhcLisp.Types
    GhcLisp.Parser
    ParserSpec
```

**Step 6: Run tests to verify they pass**

Run: `nix develop -c cabal test`
Expected: All parser tests pass.

**Step 7: Commit**

```bash
git add src/GhcLisp/Types.hs src/GhcLisp/Parser.hs test/ParserSpec.hs test/Spec.hs ghc-lisp.cabal
git commit -m "feat: s-expression parser with megaparsec (TDD)"
```

---

### Task 3: Core Evaluator (TDD)

**Files:**
- Create: `src/GhcLisp/Eval.hs`
- Create: `src/GhcLisp/Printer.hs`
- Create: `test/EvalSpec.hs`
- Modify: `ghc-lisp.cabal` (add modules)

**Step 1: Write the failing eval tests**

Create `test/EvalSpec.hs`:

```haskell
module EvalSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import GhcLisp.Types
import GhcLisp.Eval
import GhcLisp.Parser
import GhcLisp.Printer

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
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test`
Expected: Compilation fails (Eval, Printer don't exist)

**Step 3: Define runtime value types**

Add to `src/GhcLisp/Types.hs`:

```haskell
import Data.IORef
import qualified Data.Map.Strict as Map

-- | Runtime values
data LispVal
  = LInt Integer
  | LDouble Double
  | LSym Text
  | LStr Text
  | LBool Bool
  | LCons LispVal LispVal
  | LNil
  | LFun [Text] LispExpr Env   -- params, body, captured env
  | LPrimitive Text ([LispVal] -> IO LispVal)

instance Show LispVal where
  show (LInt n) = show n
  show (LDouble d) = show d
  show (LSym s) = show s
  show (LStr s) = show s
  show (LBool b) = if b then "#t" else "#f"
  show LNil = "()"
  show (LCons _ _) = "(...)"
  show (LFun{}) = "<lambda>"
  show (LPrimitive name _) = "<primitive:" <> show name <> ">"

instance Eq LispVal where
  LInt a == LInt b = a == b
  LDouble a == LDouble b = a == b
  LSym a == LSym b = a == b
  LStr a == LStr b = a == b
  LBool a == LBool b = a == b
  LNil == LNil = True
  LCons a b == LCons c d = a == c && b == d
  _ == _ = False

-- | Environment: mutable bindings
type Env = IORef (Map.Map Text LispVal)
```

**Step 4: Write the printer**

Create `src/GhcLisp/Printer.hs`:

```haskell
module GhcLisp.Printer (printVal) where

import qualified Data.Text as T
import GhcLisp.Types

printVal :: LispVal -> String
printVal (LInt n)    = show n
printVal (LDouble d) = show d
printVal (LSym s)    = T.unpack s
printVal (LStr s)    = "\"" <> T.unpack s <> "\""
printVal (LBool b)   = if b then "#t" else "#f"
printVal LNil        = "()"
printVal (LFun{})    = "<lambda>"
printVal (LPrimitive name _) = "<primitive:" <> T.unpack name <> ">"
printVal (LCons a d) = "(" <> printCons a d <> ")"
  where
    printCons x LNil        = printVal x
    printCons x (LCons y z) = printVal x <> " " <> printCons y z
    printCons x y           = printVal x <> " . " <> printVal y
```

**Step 5: Write the evaluator**

Create `src/GhcLisp/Eval.hs`:

```haskell
module GhcLisp.Eval
  ( eval
  , defaultEnv
  ) where

import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as Map

import GhcLisp.Types

defaultEnv :: IO Env
defaultEnv = newIORef $ Map.fromList
  [ ("+", LPrimitive "+" (numBinOp (+)))
  , ("-", LPrimitive "-" (numBinOp (-)))
  , ("*", LPrimitive "*" (numBinOp (*)))
  , ("div", LPrimitive "div" (numBinOp div))
  , ("=", LPrimitive "=" eqOp)
  , ("<", LPrimitive "<" (cmpOp (<)))
  , (">", LPrimitive ">" (cmpOp (>)))
  , ("list", LPrimitive "list" listOp)
  , ("cons", LPrimitive "cons" consOp)
  , ("car", LPrimitive "car" carOp)
  , ("cdr", LPrimitive "cdr" cdrOp)
  , ("null?", LPrimitive "null?" nullOp)
  ]

numBinOp :: (Integer -> Integer -> Integer) -> [LispVal] -> IO LispVal
numBinOp op [LInt a, LInt b] = pure $ LInt (op a b)
numBinOp _ args = error $ "expected two integers, got: " <> show (length args) <> " args"

eqOp :: [LispVal] -> IO LispVal
eqOp [a, b] = pure $ LBool (a == b)
eqOp _ = error "= expects two arguments"

cmpOp :: (Integer -> Integer -> Bool) -> [LispVal] -> IO LispVal
cmpOp op [LInt a, LInt b] = pure $ LBool (op a b)
cmpOp _ _ = error "comparison expects two integers"

listOp :: [LispVal] -> IO LispVal
listOp = pure . foldr LCons LNil

consOp :: [LispVal] -> IO LispVal
consOp [a, b] = pure $ LCons a b
consOp _ = error "cons expects two arguments"

carOp :: [LispVal] -> IO LispVal
carOp [LCons a _] = pure a
carOp _ = error "car expects a cons cell"

cdrOp :: [LispVal] -> IO LispVal
cdrOp [LCons _ d] = pure d
cdrOp _ = error "cdr expects a cons cell"

nullOp :: [LispVal] -> IO LispVal
nullOp [LNil] = pure $ LBool True
nullOp [_]    = pure $ LBool False
nullOp _      = error "null? expects one argument"

eval :: Env -> LispExpr -> IO LispVal
eval _ (EInt n)    = pure $ LInt n
eval _ (EDouble d) = pure $ LDouble d
eval _ (EStr s)    = pure $ LStr s
eval _ (EBool b)   = pure $ LBool b
eval env (ESym s)  = do
  bindings <- readIORef env
  case Map.lookup s bindings of
    Just v  -> pure v
    Nothing -> error $ "unbound symbol: " <> T.unpack s
eval env (EList [ESym "quote", e]) = evalQuote e
eval env (EList [ESym "if", cond, then_, else_]) = do
  c <- eval env cond
  case c of
    LBool False -> eval env else_
    _           -> eval env then_
eval env (EList [ESym "define", ESym name, body]) = do
  val <- eval env body
  modifyIORef' env (Map.insert name val)
  pure val
eval env (EList (ESym "lambda" : EList params : body)) = do
  let paramNames = map (\case ESym s -> s; _ -> error "lambda params must be symbols") params
  -- For single-expression body
  case body of
    [expr] -> pure $ LFun paramNames expr env
    _      -> error "lambda body must be a single expression"
eval env (EList (fn : args)) = do
  f <- eval env fn
  vals <- mapM (eval env) args
  apply f vals
eval _ e = error $ "cannot eval: " <> show e

apply :: LispVal -> [LispVal] -> IO LispVal
apply (LPrimitive _ f) args = f args
apply (LFun params body closure) args = do
  let bindings = Map.fromList (zip params args)
  parentBindings <- readIORef closure
  childEnv <- newIORef (Map.union bindings parentBindings)
  eval childEnv body
apply v _ = error $ "not a function: " <> show v

evalQuote :: LispExpr -> IO LispVal
evalQuote (EInt n)    = pure $ LInt n
evalQuote (EDouble d) = pure $ LDouble d
evalQuote (ESym s)    = pure $ LSym s
evalQuote (EStr s)    = pure $ LStr s
evalQuote (EBool b)   = pure $ LBool b
evalQuote (EList xs)  = foldr LCons LNil <$> mapM evalQuote xs
```

**Step 6: Update cabal with new modules**

Add `GhcLisp.Eval`, `GhcLisp.Printer` to both `other-modules` lists. Add `EvalSpec` to test `other-modules`.

**Step 7: Run tests**

Run: `nix develop -c cabal test`
Expected: All eval tests pass.

**Step 8: Commit**

```bash
git add src/GhcLisp/Types.hs src/GhcLisp/Eval.hs src/GhcLisp/Printer.hs test/EvalSpec.hs ghc-lisp.cabal
git commit -m "feat: core evaluator with arithmetic, lambda, list ops (TDD)"
```

---

### Task 4: REPL Loop

**Files:**
- Modify: `src/Main.hs`

**Step 1: Write the REPL**

```haskell
module Main where

import System.IO (hFlush, stdout, hSetBuffering, stdin, BufferMode(..))
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Control.Exception (catch, SomeException, displayException)

import GhcLisp.Types
import GhcLisp.Parser
import GhcLisp.Eval
import GhcLisp.Printer

main :: IO ()
main = do
  hSetBuffering stdin LineBuffering
  putStrLn "ghc-lisp v0.1 — a Lisp on GHC's runtime"
  putStrLn "Type (quit) to exit."
  env <- defaultEnv
  repl env

repl :: Env -> IO ()
repl env = do
  putStr "λ> "
  hFlush stdout
  line <- TIO.getLine
  if T.strip line == "(quit)"
    then putStrLn "Bye."
    else do
      case parseLisp line of
        Left err -> putStrLn $ "parse error: " <> show err
        Right expr -> do
          result <- (Right <$> eval env expr)
            `catch` \(e :: SomeException) -> pure (Left (displayException e))
          case result of
            Right val -> putStrLn (printVal val)
            Left err  -> putStrLn $ "error: " <> err
      repl env
```

**Step 2: Test manually**

Run: `nix develop -c cabal run ghc-lisp`

Try:
```
λ> (+ 1 2)
3
λ> (define x 10)
10
λ> (* x x)
100
λ> ((lambda (x y) (+ x y)) 3 4)
7
λ> (list 1 2 3)
(1 2 3)
λ> (car (list 1 2 3))
1
λ> (quit)
Bye.
```

**Step 3: Commit**

```bash
git add src/Main.hs
git commit -m "feat: interactive REPL loop"
```

---

### Task 5: C Bridge — RTS API Wrappers

This is the core of the project: calling GHC's RTS from C, invoked via Haskell FFI.

**Files:**
- Create: `cbits/rts_bridge.h`
- Create: `cbits/rts_bridge.c`
- Create: `src/GhcLisp/RtsBridge.hs`
- Create: `test/RtsBridgeSpec.hs`
- Modify: `ghc-lisp.cabal`

**Step 1: Write the failing bridge test**

Create `test/RtsBridgeSpec.hs`:

```haskell
module RtsBridgeSpec (spec) where

import Test.Hspec
import Foreign.StablePtr
import GhcLisp.RtsBridge

spec :: Spec
spec = describe "RtsBridge" $ do
  describe "rts_mkInt roundtrip" $ do
    it "creates a Haskell Int on the heap and reads it back" $ do
      val <- bridgeRoundtripInt 42
      val `shouldBe` 42

    it "handles negative ints" $ do
      val <- bridgeRoundtripInt (-7)
      val `shouldBe` (-7)

  describe "rts_apply + rts_eval" $ do
    it "applies a Haskell function via the RTS" $ do
      -- Pass (succ :: Int -> Int) as a StablePtr, apply to 41
      sp <- newStablePtr (succ :: Int -> Int)
      result <- bridgeApplyIntInt sp 41
      freeStablePtr sp
      result `shouldBe` 42

    it "applies negate via the RTS" $ do
      sp <- newStablePtr (negate :: Int -> Int)
      result <- bridgeApplyIntInt sp 10
      freeStablePtr sp
      result `shouldBe` (-10)
```

**Step 2: Write the C bridge**

Create `cbits/rts_bridge.h`:

```c
#ifndef GHCLISP_RTS_BRIDGE_H
#define GHCLISP_RTS_BRIDGE_H

#include "HsFFI.h"

/* Round-trip: create an Int on the GHC heap, read it back */
HsInt ghclisp_roundtrip_int(HsInt val);

/* Apply a Haskell (Int -> Int) function (given as StablePtr) to an Int arg,
   evaluate, and return the Int result. */
HsInt ghclisp_apply_int_int(HsStablePtr fn_sp, HsInt arg);

#endif
```

Create `cbits/rts_bridge.c`:

```c
#include "Rts.h"
#include "rts_bridge.h"

HsInt ghclisp_roundtrip_int(HsInt val)
{
    Capability *cap = rts_lock();
    HaskellObj obj = rts_mkInt(cap, val);
    HsInt result = rts_getInt(obj);
    rts_unlock(cap);
    return result;
}

HsInt ghclisp_apply_int_int(HsStablePtr fn_sp, HsInt arg)
{
    Capability *cap = rts_lock();

    /* Dereference the StablePtr to get the function closure */
    HaskellObj fn = (HaskellObj)deRefStablePtr(fn_sp);

    /* Create the argument */
    HaskellObj harg = rts_mkInt(cap, arg);

    /* Apply function to argument (creates a thunk) */
    HaskellObj app = rts_apply(cap, fn, harg);

    /* Evaluate the application */
    HaskellObj result;
    rts_eval(&cap, app, &result);

    /* Extract the Int result */
    HsInt ret = rts_getInt(result);

    rts_unlock(cap);
    return ret;
}
```

**Step 3: Write the Haskell FFI bindings**

Create `src/GhcLisp/RtsBridge.hs`:

```haskell
module GhcLisp.RtsBridge
  ( bridgeRoundtripInt
  , bridgeApplyIntInt
  ) where

import Foreign.StablePtr (StablePtr)
import Foreign.C.Types (CInt(..))

foreign import ccall safe "ghclisp_roundtrip_int"
  c_roundtrip_int :: CInt -> IO CInt

foreign import ccall safe "ghclisp_apply_int_int"
  c_apply_int_int :: StablePtr (Int -> Int) -> CInt -> IO CInt

bridgeRoundtripInt :: Int -> IO Int
bridgeRoundtripInt n = fromIntegral <$> c_roundtrip_int (fromIntegral n)

bridgeApplyIntInt :: StablePtr (Int -> Int) -> Int -> IO Int
bridgeApplyIntInt sp n = fromIntegral <$> c_apply_int_int sp (fromIntegral n)
```

**Step 4: Update cabal file**

Add to `executable ghc-lisp`:
```
  c-sources:    cbits/rts_bridge.c
  include-dirs: cbits
  other-modules:
    ...
    GhcLisp.RtsBridge
```

Add to `test-suite ghc-lisp-test`:
```
  c-sources:    cbits/rts_bridge.c
  include-dirs: cbits
  other-modules:
    ...
    GhcLisp.RtsBridge
    RtsBridgeSpec
```

**Step 5: Run tests**

Run: `nix develop -c cabal test`
Expected: RtsBridge tests pass — we can create Haskell values and apply functions via the RTS C API.

**Step 6: Commit**

```bash
git add cbits/rts_bridge.h cbits/rts_bridge.c src/GhcLisp/RtsBridge.hs test/RtsBridgeSpec.hs ghc-lisp.cabal
git commit -m "feat: C bridge to GHC RTS — rts_mkInt, rts_apply, rts_eval working"
```

---

### Task 6: Haskell Function Interop

**Files:**
- Create: `src/GhcLisp/HaskellInterop.hs`
- Modify: `cbits/rts_bridge.h` (add list marshaling)
- Modify: `cbits/rts_bridge.c`
- Modify: `src/GhcLisp/RtsBridge.hs` (add new FFI imports)
- Modify: `src/GhcLisp/Eval.hs` (add haskell-call)
- Create: `test/InteropSpec.hs`

**Step 1: Write the failing interop test**

Create `test/InteropSpec.hs`:

```haskell
module InteropSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import GhcLisp.Types
import GhcLisp.Eval
import GhcLisp.Parser
import GhcLisp.Printer
import GhcLisp.HaskellInterop

-- Helper: parse + eval with interop, return printed result
run :: String -> IO String
run input = do
  env <- defaultEnvWithInterop
  case parseLisp (T.pack input) of
    Left err -> error (show err)
    Right expr -> do
      val <- eval env expr
      pure (printVal val)

spec :: Spec
spec = describe "Haskell Interop" $ do
  it "calls succ on an Int" $
    run "(haskell-call \"succ\" 41)" `shouldReturn` "42"

  it "calls negate on an Int" $
    run "(haskell-call \"negate\" 10)" `shouldReturn` "-10"

  it "calls reverse on a list of Ints" $
    run "(haskell-call \"reverse\" (list 1 2 3))" `shouldReturn` "(3 2 1)"

  it "calls length on a list" $
    run "(haskell-call \"length\" (list 10 20 30))" `shouldReturn` "3"
```

**Step 2: Extend the C bridge for list marshaling**

Add to `cbits/rts_bridge.h`:

```c
/* Apply a Haskell function (StablePtr) to a Haskell list object,
   evaluate, and return the result as a HaskellObj (via StablePtr). */
HsStablePtr ghclisp_apply_and_eval(HsStablePtr fn_sp, HsStablePtr arg_sp);

/* Create a Haskell cons cell: (:) x xs */
HsStablePtr ghclisp_cons(HsStablePtr head_sp, HsStablePtr tail_sp);

/* Create Haskell [] (empty list) */
HsStablePtr ghclisp_nil(void);

/* Create a Haskell Int, return as StablePtr */
HsStablePtr ghclisp_mk_int(HsInt val);

/* Extract Int from a StablePtr'd HaskellObj */
HsInt ghclisp_get_int(HsStablePtr sp);

/* Check if a HaskellObj (via StablePtr) is [] */
HsBool ghclisp_is_nil(HsStablePtr sp);

/* Get head of a Haskell list (via StablePtr) */
HsStablePtr ghclisp_head(HsStablePtr sp);

/* Get tail of a Haskell list (via StablePtr) */
HsStablePtr ghclisp_tail(HsStablePtr sp);
```

Add to `cbits/rts_bridge.c`:

```c
/* Externs for well-known GHC closures */
extern StgClosure ZCzezulistzulistzh_con_info;  /* (:) constructor */
/* We use rts_apply to build lists instead of manual construction */

extern StgClosure ghczmprim_GHCziTypes_ZMZN_closure;  /* [] */

HsStablePtr ghclisp_apply_and_eval(HsStablePtr fn_sp, HsStablePtr arg_sp)
{
    Capability *cap = rts_lock();
    HaskellObj fn = (HaskellObj)deRefStablePtr(fn_sp);
    HaskellObj arg = (HaskellObj)deRefStablePtr(arg_sp);
    HaskellObj app = rts_apply(cap, fn, arg);
    HaskellObj result;
    rts_eval(&cap, app, &result);
    HsStablePtr ret = getStablePtr((StgPtr)result);
    rts_unlock(cap);
    return ret;
}

HsStablePtr ghclisp_mk_int(HsInt val)
{
    Capability *cap = rts_lock();
    HaskellObj obj = rts_mkInt(cap, val);
    HsStablePtr sp = getStablePtr((StgPtr)obj);
    rts_unlock(cap);
    return sp;
}

HsInt ghclisp_get_int(HsStablePtr sp)
{
    HaskellObj obj = (HaskellObj)deRefStablePtr(sp);
    return rts_getInt(obj);
}
```

**Note:** The list manipulation functions (cons, nil, head, tail, is_nil) are tricky to implement purely in C because they require access to GHC's list constructors. A simpler approach is to implement marshaling in Haskell using StablePtrs:

**Step 3: Write the Haskell interop module**

Create `src/GhcLisp/HaskellInterop.hs`:

```haskell
module GhcLisp.HaskellInterop
  ( defaultEnvWithInterop
  , registerBuiltins
  ) where

import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Foreign.StablePtr
import Foreign.C.Types (CInt(..))
import GhcLisp.Types
import GhcLisp.Eval (defaultEnv, eval)

-- FFI imports for the C bridge
foreign import ccall safe "ghclisp_apply_and_eval"
  c_apply_and_eval :: StablePtr a -> StablePtr b -> IO (StablePtr c)

foreign import ccall safe "ghclisp_mk_int"
  c_mk_int :: CInt -> IO (StablePtr a)

foreign import ccall safe "ghclisp_get_int"
  c_get_int :: StablePtr a -> IO CInt

-- | Registered Haskell functions: name -> (StablePtr to function, type signature info)
data HsFnEntry = HsFnEntry
  { fnPtr    :: StablePtr ()
  , fnType   :: HsFnType
  }

data HsFnType = IntToInt | ListIntToListInt | ListIntToInt

-- | Build the function registry
builtinRegistry :: IO (Map.Map Text HsFnEntry)
builtinRegistry = do
  succSp  <- newStablePtr (succ :: Int -> Int)
  negSp   <- newStablePtr (negate :: Int -> Int)
  revSp   <- newStablePtr (reverse :: [Int] -> [Int])
  lenSp   <- newStablePtr (length :: [Int] -> Int)
  pure $ Map.fromList
    [ ("succ",    HsFnEntry (castStablePtrToPtr succSp) IntToInt)
    , ("negate",  HsFnEntry (castStablePtrToPtr negSp) IntToInt)
    , ("reverse", HsFnEntry (castStablePtrToPtr revSp) ListIntToListInt)
    , ("length",  HsFnEntry (castStablePtrToPtr lenSp) ListIntToInt)
    ]
  where
    castStablePtrToPtr = error "placeholder — see actual impl"

-- Actually, simpler approach: just use Haskell directly for the MVP,
-- and route through the C bridge for Int->Int functions as proof of concept.

-- | Marshal a LispVal list to a Haskell [Int] via StablePtr chain
marshalListInt :: LispVal -> IO (StablePtr [Int])
marshalListInt val = newStablePtr (toHaskellListInt val)
  where
    toHaskellListInt LNil = []
    toHaskellListInt (LCons (LInt n) rest) = fromIntegral n : toHaskellListInt rest
    toHaskellListInt _ = error "expected list of integers"

-- | Unmarshal a Haskell [Int] from StablePtr back to LispVal
unmarshalListInt :: StablePtr [Int] -> IO LispVal
unmarshalListInt sp = do
  xs <- deRefStablePtr sp
  freeStablePtr sp
  pure $ foldr (\x acc -> LCons (LInt (fromIntegral x)) acc) LNil xs

-- | The haskell-call primitive
haskellCallPrim :: Map.Map Text HsFnEntry -> [LispVal] -> IO LispVal
haskellCallPrim registry [LStr name, arg] = do
  case Map.lookup name registry of
    Nothing -> error $ "unknown Haskell function: " <> T.unpack name
    Just entry -> callHsFn entry arg
haskellCallPrim _ _ = error "haskell-call expects (haskell-call \"name\" arg)"

callHsFn :: HsFnEntry -> LispVal -> IO LispVal
callHsFn = error "TODO: implement based on fnType dispatch"

-- Simpler MVP: just use Haskell's type system directly
-- The C bridge proves RTS integration; marshaling uses Haskell for now.

defaultEnvWithInterop :: IO Env
defaultEnvWithInterop = do
  env <- defaultEnv
  modifyIORef' env $ Map.insert "haskell-call" $
    LPrimitive "haskell-call" haskellCall
  pure env

haskellCall :: [LispVal] -> IO LispVal
haskellCall [LStr name, arg] = dispatchHaskellCall name arg
haskellCall _ = error "haskell-call expects (haskell-call \"name\" arg)"

dispatchHaskellCall :: Text -> LispVal -> IO LispVal
dispatchHaskellCall "succ" (LInt n) = do
  -- Route through C bridge to prove RTS integration
  sp <- newStablePtr (succ :: Int -> Int)
  result <- bridgeApplyIntIntSp sp (fromIntegral n)
  freeStablePtr sp
  pure $ LInt (fromIntegral result)
dispatchHaskellCall "negate" (LInt n) = do
  sp <- newStablePtr (negate :: Int -> Int)
  result <- bridgeApplyIntIntSp sp (fromIntegral n)
  freeStablePtr sp
  pure $ LInt (fromIntegral result)
dispatchHaskellCall "reverse" listVal = do
  -- Marshal LispVal list -> Haskell [Int], call reverse, unmarshal back
  let hs = toHaskellListInt listVal
  let result = reverse hs
  pure $ fromHaskellListInt result
dispatchHaskellCall "length" listVal = do
  let hs = toHaskellListInt listVal
  pure $ LInt (fromIntegral (length hs))
dispatchHaskellCall name _ = error $ "unknown function: " <> T.unpack name

-- Use C bridge for Int -> Int functions
foreign import ccall safe "ghclisp_apply_int_int"
  c_bridge_apply :: StablePtr (Int -> Int) -> CInt -> IO CInt

bridgeApplyIntIntSp :: StablePtr (Int -> Int) -> Int -> IO Int
bridgeApplyIntIntSp sp n = fromIntegral <$> c_bridge_apply sp (fromIntegral n)

-- Pure marshaling helpers
toHaskellListInt :: LispVal -> [Int]
toHaskellListInt LNil = []
toHaskellListInt (LCons (LInt n) rest) = fromIntegral n : toHaskellListInt rest
toHaskellListInt _ = error "expected list of integers"

fromHaskellListInt :: [Int] -> LispVal
fromHaskellListInt = foldr (\x acc -> LCons (LInt (fromIntegral x)) acc) LNil
```

**Step 4: Update cabal file**

Add `GhcLisp.HaskellInterop` and `InteropSpec` to the appropriate module lists.

**Step 5: Run tests**

Run: `nix develop -c cabal test`
Expected: All interop tests pass. `succ` and `negate` route through the C bridge (rts_apply/rts_eval). `reverse` and `length` use Haskell-side marshaling for now.

**Step 6: Commit**

```bash
git add src/GhcLisp/HaskellInterop.hs test/InteropSpec.hs cbits/rts_bridge.h cbits/rts_bridge.c ghc-lisp.cabal
git commit -m "feat: haskell-call interop — Int->Int via RTS C bridge, list ops via marshaling"
```

---

### Task 7: Wire Interop Into REPL + End-to-End Test

**Files:**
- Modify: `src/Main.hs` (use `defaultEnvWithInterop`)

**Step 1: Update Main.hs**

Change `defaultEnv` to `defaultEnvWithInterop`:

```haskell
import GhcLisp.HaskellInterop (defaultEnvWithInterop)

main = do
  ...
  env <- defaultEnvWithInterop
  repl env
```

**Step 2: Manual end-to-end test**

Run: `nix develop -c cabal run ghc-lisp`

```
λ> (haskell-call "succ" 41)
42
λ> (haskell-call "negate" 10)
-10
λ> (haskell-call "reverse" (list 1 2 3))
(3 2 1)
λ> (haskell-call "length" (list 10 20 30 40))
4
λ> (+ (haskell-call "succ" 99) 1)
101
λ> (quit)
```

**Step 3: Commit**

```bash
git add src/Main.hs
git commit -m "feat: wire haskell-call into REPL — MVP complete"
```

---

## Post-MVP: Next Steps (not in this plan)

1. **Native closures** — Replace LispVal ADT with GHC heap objects (custom info tables in C)
2. **Dynamic function lookup** — Use `lookupSymbol` or `dlsym` to find any Haskell function by name
3. **List marshaling via RTS** — Build/traverse Haskell lists in C using (:) and [] closures
4. **Opt-in laziness** — `(delay expr)` creates real GHC thunks, `(force x)` enters them
5. **Concurrency** — Expose `forkIO` to Lisp
6. **Macro system** — `define-syntax` / `syntax-rules`
