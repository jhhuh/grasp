# Native STG Closures Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the `LispVal` Haskell ADT with native GHC heap closures so every Grasp runtime value is a raw `StgClosure` — integers ARE `I#`, booleans ARE `True`/`False`, and Grasp-specific types use Haskell ADTs whose info tables GHC generates automatically.

**Architecture:** `GraspVal = Any` (from `GHC.Exts`). Type discrimination via `unpackClosure#` reading info-table addresses. GHC-equivalent types (Int, Double, Bool) reuse GHC's existing closures. Grasp-specific types (Sym, Str, Cons, Nil, Lambda, Prim) are defined as Haskell data types so GHC generates info tables.

**Tech Stack:** GHC 9.8, `GHC.Exts` (unpackClosure#, Any), `Unsafe.Coerce`, Cabal + Nix flake

**Design doc:** `docs/plans/2026-03-06-native-stg-closures-design.md`

---

### Task 1: Create `Grasp.NativeTypes` module with standalone tests

This is the foundation module. It compiles independently from the rest of the codebase and can be tested without changing existing code.

**Files:**
- Create: `src/Grasp/NativeTypes.hs`
- Create: `test/NativeTypesSpec.hs`
- Modify: `grasp.cabal:36-47` (add module + test module)

**Step 1: Write the test file**

Create `test/NativeTypesSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module NativeTypesSpec (spec) where

import Test.Hspec
import GHC.Exts (Any)
import Unsafe.Coerce (unsafeCoerce)
import Grasp.NativeTypes

spec :: Spec
spec = describe "NativeTypes" $ do
  describe "type discrimination" $ do
    it "identifies Int" $
      graspTypeOf (mkInt 42) `shouldBe` GTInt

    it "identifies Double" $
      graspTypeOf (mkDouble 3.14) `shouldBe` GTDouble

    it "identifies True" $
      graspTypeOf (mkBool True) `shouldBe` GTBoolTrue

    it "identifies False" $
      graspTypeOf (mkBool False) `shouldBe` GTBoolFalse

    it "identifies Sym" $
      graspTypeOf (mkSym "foo") `shouldBe` GTSym

    it "identifies Str" $
      graspTypeOf (mkStr "hello") `shouldBe` GTStr

    it "identifies Cons" $
      graspTypeOf (mkCons (mkInt 1) mkNil) `shouldBe` GTCons

    it "identifies Nil" $
      graspTypeOf mkNil `shouldBe` GTNil

  describe "constructors and extractors" $ do
    it "round-trips Int" $
      toInt (mkInt 42) `shouldBe` 42

    it "round-trips negative Int" $
      toInt (mkInt (-7)) `shouldBe` (-7)

    it "round-trips Double" $
      toDouble (mkDouble 3.14) `shouldBe` 3.14

    it "round-trips Bool True" $
      toBool (mkBool True) `shouldBe` True

    it "round-trips Bool False" $
      toBool (mkBool False) `shouldBe` False

    it "round-trips Sym" $
      toSym (mkSym "foo") `shouldBe` "foo"

    it "round-trips Str" $
      toStr (mkStr "hello") `shouldBe` "hello"

    it "round-trips Cons car" $
      toInt (toCar (mkCons (mkInt 1) (mkInt 2))) `shouldBe` 1

    it "round-trips Cons cdr" $
      toInt (toCdr (mkCons (mkInt 1) (mkInt 2))) `shouldBe` 2

    it "identifies nil" $
      isNil mkNil `shouldBe` True

    it "identifies non-nil" $
      isNil (mkInt 42) `shouldBe` False

  describe "graspEq" $ do
    it "equal ints" $
      graspEq (mkInt 42) (mkInt 42) `shouldBe` True

    it "unequal ints" $
      graspEq (mkInt 1) (mkInt 2) `shouldBe` False

    it "equal bools" $
      graspEq (mkBool True) (mkBool True) `shouldBe` True

    it "equal nil" $
      graspEq mkNil mkNil `shouldBe` True

    it "equal cons" $
      graspEq (mkCons (mkInt 1) mkNil) (mkCons (mkInt 1) mkNil) `shouldBe` True

    it "different types" $
      graspEq (mkInt 1) (mkBool True) `shouldBe` False

    it "equal strings" $
      graspEq (mkStr "a") (mkStr "a") `shouldBe` True

    it "equal symbols" $
      graspEq (mkSym "x") (mkSym "x") `shouldBe` True
```

**Step 2: Write the implementation**

Create `src/Grasp/NativeTypes.hs`:

```haskell
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE OverloadedStrings #-}
module Grasp.NativeTypes
  ( -- * Grasp-specific ADTs
    GraspSym(..)
  , GraspStr(..)
  , GraspCons(..)
  , GraspNil(..)
  , GraspLambda(..)
  , GraspPrim(..)
  -- * Type discrimination
  , GraspType(..)
  , graspTypeOf
  -- * Constructors
  , mkInt, mkDouble, mkBool
  , mkSym, mkStr
  , mkCons, mkNil
  , mkLambda, mkPrim
  -- * Extractors
  , toInt, toDouble, toBool
  , toSym, toStr
  , toCar, toCdr
  , toLambdaParts, toPrimFn, toPrimName
  -- * Predicates
  , isNil, isCons
  -- * Equality
  , graspEq
  -- * Display
  , showGraspType
  ) where

import GHC.Exts (Any, unpackClosure#)
import Foreign.Ptr (Ptr(Ptr))
import Unsafe.Coerce (unsafeCoerce)
import Data.Text (Text)
import qualified Data.Text as T
import Data.IORef (IORef)

-- Forward-declare the types we need from Grasp.Types
-- to avoid circular imports. GraspLambda uses LispExpr and Env.
-- We import them from Grasp.Types.
import Grasp.Types (LispExpr, Env)

-- ─── Grasp-specific ADTs ──────────────────────────────────
-- GHC generates info tables for these automatically.
-- Fields are lazy to allow dummy construction for info-pointer caching.

data GraspSym    = GraspSym Text
data GraspStr    = GraspStr Text
data GraspCons   = GraspCons Any Any
data GraspNil    = GraspNil
data GraspLambda = GraspLambda [Text] LispExpr Env
data GraspPrim   = GraspPrim Text ([Any] -> IO Any)

-- ─── Type tags ────────────────────────────────────────────

data GraspType
  = GTInt | GTDouble | GTBoolTrue | GTBoolFalse
  | GTSym | GTStr | GTCons | GTNil
  | GTLambda | GTPrim
  deriving (Eq, Show)

showGraspType :: GraspType -> String
showGraspType GTInt       = "Int"
showGraspType GTDouble    = "Double"
showGraspType GTBoolTrue  = "Bool"
showGraspType GTBoolFalse = "Bool"
showGraspType GTSym       = "Symbol"
showGraspType GTStr       = "String"
showGraspType GTCons      = "Cons"
showGraspType GTNil       = "Nil"
showGraspType GTLambda    = "Lambda"
showGraspType GTPrim      = "Primitive"

-- ─── Info pointer cache ───────────────────────────────────
-- Each closure type has a unique info-table address.
-- We cache them from reference closures and compare at runtime.

getInfoPtr :: a -> Ptr ()
getInfoPtr x = case unpackClosure# x of (# info, _, _ #) -> Ptr info

{-# NOINLINE intInfoPtr #-}
intInfoPtr :: Ptr ()
intInfoPtr = getInfoPtr (0 :: Int)

{-# NOINLINE doubleInfoPtr #-}
doubleInfoPtr :: Ptr ()
doubleInfoPtr = getInfoPtr (0.0 :: Double)

{-# NOINLINE trueInfoPtr #-}
trueInfoPtr :: Ptr ()
trueInfoPtr = getInfoPtr True

{-# NOINLINE falseInfoPtr #-}
falseInfoPtr :: Ptr ()
falseInfoPtr = getInfoPtr False

{-# NOINLINE symInfoPtr #-}
symInfoPtr :: Ptr ()
symInfoPtr = getInfoPtr (GraspSym T.empty)

{-# NOINLINE strInfoPtr #-}
strInfoPtr :: Ptr ()
strInfoPtr = getInfoPtr (GraspStr T.empty)

{-# NOINLINE consInfoPtr #-}
consInfoPtr :: Ptr ()
consInfoPtr = getInfoPtr (GraspCons (unsafeCoerce ()) (unsafeCoerce ()))

{-# NOINLINE nilInfoPtr #-}
nilInfoPtr :: Ptr ()
nilInfoPtr = getInfoPtr GraspNil

{-# NOINLINE lambdaInfoPtr #-}
lambdaInfoPtr :: Ptr ()
lambdaInfoPtr = getInfoPtr (GraspLambda undefined undefined undefined)

{-# NOINLINE primInfoPtr #-}
primInfoPtr :: Ptr ()
primInfoPtr = getInfoPtr (GraspPrim undefined undefined)

-- ─── Type discrimination ─────────────────────────────────

graspTypeOf :: Any -> GraspType
graspTypeOf v = let p = getInfoPtr v in
  if      p == intInfoPtr    then GTInt
  else if p == doubleInfoPtr then GTDouble
  else if p == trueInfoPtr   then GTBoolTrue
  else if p == falseInfoPtr  then GTBoolFalse
  else if p == symInfoPtr    then GTSym
  else if p == strInfoPtr    then GTStr
  else if p == consInfoPtr   then GTCons
  else if p == nilInfoPtr    then GTNil
  else if p == lambdaInfoPtr then GTLambda
  else if p == primInfoPtr   then GTPrim
  else error $ "unknown closure type at " ++ show p

-- ─── Constructors ─────────────────────────────────────────

mkInt :: Int -> Any
mkInt = unsafeCoerce

mkDouble :: Double -> Any
mkDouble = unsafeCoerce

mkBool :: Bool -> Any
mkBool = unsafeCoerce

mkSym :: Text -> Any
mkSym s = unsafeCoerce (GraspSym s)

mkStr :: Text -> Any
mkStr s = unsafeCoerce (GraspStr s)

mkCons :: Any -> Any -> Any
mkCons car cdr = unsafeCoerce (GraspCons car cdr)

mkNil :: Any
mkNil = unsafeCoerce GraspNil

mkLambda :: [Text] -> LispExpr -> Env -> Any
mkLambda params body env = unsafeCoerce (GraspLambda params body env)

mkPrim :: Text -> ([Any] -> IO Any) -> Any
mkPrim name f = unsafeCoerce (GraspPrim name f)

-- ─── Extractors ───────────────────────────────────────────

toInt :: Any -> Int
toInt = unsafeCoerce

toDouble :: Any -> Double
toDouble = unsafeCoerce

toBool :: Any -> Bool
toBool v = graspTypeOf v == GTBoolTrue

toSym :: Any -> Text
toSym v = let GraspSym s = unsafeCoerce v in s

toStr :: Any -> Text
toStr v = let GraspStr s = unsafeCoerce v in s

toCar :: Any -> Any
toCar v = let GraspCons car _ = unsafeCoerce v in car

toCdr :: Any -> Any
toCdr v = let GraspCons _ cdr = unsafeCoerce v in cdr

toLambdaParts :: Any -> ([Text], LispExpr, Env)
toLambdaParts v = let GraspLambda p b e = unsafeCoerce v in (p, b, e)

toPrimFn :: Any -> ([Any] -> IO Any)
toPrimFn v = let GraspPrim _ f = unsafeCoerce v in f

toPrimName :: Any -> Text
toPrimName v = let GraspPrim n _ = unsafeCoerce v in n

-- ─── Predicates ───────────────────────────────────────────

isNil :: Any -> Bool
isNil v = graspTypeOf v == GTNil

isCons :: Any -> Bool
isCons v = graspTypeOf v == GTCons

-- ─── Equality ─────────────────────────────────────────────

graspEq :: Any -> Any -> Bool
graspEq a b = case (graspTypeOf a, graspTypeOf b) of
  (GTInt, GTInt)           -> toInt a == toInt b
  (GTDouble, GTDouble)     -> toDouble a == toDouble b
  (GTSym, GTSym)           -> toSym a == toSym b
  (GTStr, GTStr)           -> toStr a == toStr b
  (GTBoolTrue, GTBoolTrue) -> True
  (GTBoolFalse, GTBoolFalse) -> True
  (GTNil, GTNil)           -> True
  (GTCons, GTCons)         -> graspEq (toCar a) (toCar b)
                              && graspEq (toCdr a) (toCdr b)
  _                        -> False
```

**Step 3: Update `grasp.cabal`**

Add `Grasp.NativeTypes` to both `other-modules` lists (exe line 11, test line 43), and add `NativeTypesSpec` to the test `other-modules` (after line 47).

**Step 4: Run new tests to verify they pass**

Run: `nix develop -c cabal test`
Expected: All existing 50 tests pass + ~25 new NativeTypes tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/NativeTypes.hs test/NativeTypesSpec.hs grasp.cabal
git commit -m "feat: add NativeTypes module with type discrimination via unpackClosure#"
```

---

### Task 2: Replace `LispVal` in `Grasp.Types`

Remove the `LispVal` data type and replace it with `type GraspVal = Any`. Update `EnvData` and `HsFuncEntry`.

**WARNING**: After this task, the project will NOT compile until Tasks 3–7 are also complete. Tasks 2–7 are a single atomic change — do them all, then compile and test.

**Files:**
- Modify: `src/Grasp/Types.hs`

**Step 1: Rewrite `src/Grasp/Types.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Grasp.Types where

import Data.IORef
import Data.Text (Text)
import qualified Data.Map.Strict as Map
import GHC.Exts (Any)

-- | Source-level expression (what the parser produces)
data LispExpr
  = EInt Integer
  | EDouble Double
  | ESym Text
  | EStr Text
  | EList [LispExpr]
  | EBool Bool
  deriving (Show, Eq)

-- | Runtime value — an untyped pointer to a GHC heap closure.
-- Integers are I# closures, booleans are True/False,
-- Grasp-specific types use ADTs from Grasp.NativeTypes.
type GraspVal = Any

-- | Environment: bindings + Haskell function registry
data EnvData = EnvData
  { envBindings   :: Map.Map Text GraspVal
  , envHsRegistry :: HsFuncRegistry
  }

type Env = IORef EnvData

-- | Haskell type tags for the interop boundary
data HsType = HsInt | HsListInt | HsBool | HsString
  deriving (Show, Eq)

-- | A registered Haskell function with type metadata
data HsFuncEntry = HsFuncEntry
  { hfArgTypes :: [HsType]
  , hfRetType  :: HsType
  , hfInvoke   :: [GraspVal] -> IO GraspVal
  }

-- | Registry of available Haskell functions
type HsFuncRegistry = Map.Map Text HsFuncEntry
```

Key changes from current file:
- Removed `LispVal` data type (and its `Show`/`Eq` instances)
- Added `import GHC.Exts (Any)`
- Added `type GraspVal = Any`
- Changed `envBindings` from `Map Text LispVal` to `Map Text GraspVal`
- Changed `hfInvoke` from `[LispVal] -> IO LispVal` to `[GraspVal] -> IO GraspVal`

---

### Task 3: Rewrite `Grasp.Eval`

Replace all `LispVal` pattern matching with `graspTypeOf` + extractors from `NativeTypes`. `Integer` arithmetic becomes `Int` arithmetic.

**Files:**
- Modify: `src/Grasp/Eval.hs`

**Step 1: Rewrite `src/Grasp/Eval.hs`**

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Grasp.Eval
  ( eval
  , defaultEnv
  ) where

import Data.IORef
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import GHC.Exts (Any)

import Grasp.Types
import Grasp.NativeTypes
import Grasp.HsRegistry (dispatchRegistered)

defaultEnv :: IO Env
defaultEnv = newIORef $ EnvData
  { envBindings = Map.fromList
      [ ("+", mkPrim "+" (numBinOp (+)))
      , ("-", mkPrim "-" (numBinOp (-)))
      , ("*", mkPrim "*" (numBinOp (*)))
      , ("div", mkPrim "div" (numBinOp div))
      , ("=", mkPrim "=" eqOp)
      , ("<", mkPrim "<" (cmpOp (<)))
      , (">", mkPrim ">" (cmpOp (>)))
      , ("list", mkPrim "list" listOp)
      , ("cons", mkPrim "cons" consOp)
      , ("car", mkPrim "car" carOp)
      , ("cdr", mkPrim "cdr" cdrOp)
      , ("null?", mkPrim "null?" nullOp)
      ]
  , envHsRegistry = Map.empty
  }

numBinOp :: (Int -> Int -> Int) -> [Any] -> IO Any
numBinOp op [a, b] = pure $ mkInt (op (toInt a) (toInt b))
numBinOp _ args = error $ "expected two integers, got: " <> show (length args) <> " args"

eqOp :: [Any] -> IO Any
eqOp [a, b] = pure $ mkBool (graspEq a b)
eqOp _ = error "= expects two arguments"

cmpOp :: (Int -> Int -> Bool) -> [Any] -> IO Any
cmpOp op [a, b] = pure $ mkBool (op (toInt a) (toInt b))
cmpOp _ _ = error "comparison expects two integers"

listOp :: [Any] -> IO Any
listOp = pure . foldr mkCons mkNil

consOp :: [Any] -> IO Any
consOp [a, b] = pure $ mkCons a b
consOp _ = error "cons expects two arguments"

carOp :: [Any] -> IO Any
carOp [v] | isCons v = pure $ toCar v
carOp _ = error "car expects a cons cell"

cdrOp :: [Any] -> IO Any
cdrOp [v] | isCons v = pure $ toCdr v
cdrOp _ = error "cdr expects a cons cell"

nullOp :: [Any] -> IO Any
nullOp [v] = pure $ mkBool (isNil v)
nullOp _ = error "null? expects one argument"

eval :: Env -> LispExpr -> IO GraspVal
eval _ (EInt n)    = pure $ mkInt (fromInteger n)
eval _ (EDouble d) = pure $ mkDouble d
eval _ (EStr s)    = pure $ mkStr s
eval _ (EBool b)   = pure $ mkBool b
eval env (ESym s)  = do
  ed <- readIORef env
  case Map.lookup s (envBindings ed) of
    Just v  -> pure v
    Nothing -> error $ "unbound symbol: " <> T.unpack s
eval env (EList [ESym "quote", e]) = evalQuote e
eval env (EList [ESym "if", cond, then_, else_]) = do
  c <- eval env cond
  if graspTypeOf c == GTBoolFalse
    then eval env else_
    else eval env then_
eval env (EList [ESym "define", ESym name, body]) = do
  val <- eval env body
  modifyIORef' env $ \ed -> ed { envBindings = Map.insert name val (envBindings ed) }
  pure val
eval env (EList (ESym "lambda" : EList params : body)) = do
  let paramNames = map (\case ESym s -> s; _ -> error "lambda params must be symbols") params
  case body of
    [expr] -> pure $ mkLambda paramNames expr env
    _      -> error "lambda body must be a single expression"
-- hs: prefix dispatches to the Haskell function registry
eval env (EList (ESym name : args))
  | Just hsName <- T.stripPrefix "hs:" name = do
      ed <- readIORef env
      vals <- mapM (eval env) args
      dispatchRegistered (envHsRegistry ed) hsName vals
eval env (EList (fn : args)) = do
  f <- eval env fn
  vals <- mapM (eval env) args
  apply f vals
eval _ e = error $ "cannot eval: " <> show e

apply :: Any -> [Any] -> IO Any
apply v args = case graspTypeOf v of
  GTPrim -> toPrimFn v $ args
  GTLambda -> do
    let (params, body, closure) = toLambdaParts v
    let bindings = Map.fromList (zip params args)
    parentEd <- readIORef closure
    childEnv <- newIORef $ parentEd { envBindings = Map.union bindings (envBindings parentEd) }
    eval childEnv body
  t -> error $ "not a function: " <> showGraspType t

evalQuote :: LispExpr -> IO GraspVal
evalQuote (EInt n)    = pure $ mkInt (fromInteger n)
evalQuote (EDouble d) = pure $ mkDouble d
evalQuote (ESym s)    = pure $ mkSym s
evalQuote (EStr s)    = pure $ mkStr s
evalQuote (EBool b)   = pure $ mkBool b
evalQuote (EList xs)  = do
  vals <- mapM evalQuote xs
  pure $ foldr mkCons mkNil vals
```

Key changes:
- `LInt n` → `mkInt (fromInteger n)` (Integer→Int via fromInteger)
- `LBool b` → `mkBool b`
- `LCons a b` → `mkCons a b`
- `LNil` → `mkNil`
- `LFun params body env` → `mkLambda params body env`
- `LPrimitive name f` → `mkPrim name f`
- Pattern matching on `LispVal` → `graspTypeOf` + extractors
- `LBool False` check → `graspTypeOf c == GTBoolFalse`
- `(a == b)` on LispVal → `graspEq a b`
- `Integer` arithmetic → `Int` arithmetic

---

### Task 4: Rewrite `Grasp.Printer`

Replace `LispVal` pattern matching with `graspTypeOf` dispatch.

**Files:**
- Modify: `src/Grasp/Printer.hs`

**Step 1: Rewrite `src/Grasp/Printer.hs`**

```haskell
module Grasp.Printer (printVal) where

import qualified Data.Text as T
import GHC.Exts (Any)
import Unsafe.Coerce (unsafeCoerce)
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
  GTLambda    -> "<lambda>"
  GTPrim      -> "<primitive:" <> T.unpack (toPrimName v) <> ">"
  GTCons      -> "(" <> printCons (toCar v) (toCdr v) <> ")"

printCons :: Any -> Any -> String
printCons x d
  | isNil d   = printVal x
  | isCons d  = printVal x <> " " <> printCons (toCar d) (toCdr d)
  | otherwise = printVal x <> " . " <> printVal d
```

Key changes:
- No longer imports `Grasp.Types` (doesn't need `LispVal`)
- Pattern matching on constructors → `graspTypeOf` dispatch
- `printCons` uses `isNil`/`isCons` predicates + extractors

---

### Task 5: Update `Grasp.HsRegistry`

Replace `LispVal` pattern matching in type validation with `graspTypeOf`.

**Files:**
- Modify: `src/Grasp/HsRegistry.hs`

**Step 1: Rewrite `src/Grasp/HsRegistry.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Grasp.HsRegistry
  ( dispatchRegistered
  ) where

import Data.Text (Text)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import GHC.Exts (Any)

import Grasp.Types
import Grasp.NativeTypes

dispatchRegistered :: HsFuncRegistry -> Text -> [GraspVal] -> IO GraspVal
dispatchRegistered reg name args =
  case Map.lookup name reg of
    Nothing -> error $ "unknown Haskell function: " <> T.unpack name
    Just entry -> do
      let expected = hfArgTypes entry
      if length args /= length expected
        then error $ T.unpack name <> ": expected "
                   <> show (length expected) <> " argument(s), got "
                   <> show (length args)
        else do
          mapM_ (uncurry (checkType name)) (zip expected args)
          hfInvoke entry args

matchesType :: HsType -> Any -> Bool
matchesType HsInt     v = graspTypeOf v == GTInt
matchesType HsBool    v = graspTypeOf v == GTBoolTrue || graspTypeOf v == GTBoolFalse
matchesType HsString  v = graspTypeOf v == GTStr
matchesType HsListInt v
  | isNil v   = True
  | isCons v  = graspTypeOf (toCar v) == GTInt && matchesType HsListInt (toCdr v)
  | otherwise = False

checkType :: Text -> HsType -> Any -> IO ()
checkType name expected val
  | matchesType expected val = pure ()
  | otherwise = error $ T.unpack name <> ": expected "
                      <> showHsType expected <> ", got "
                      <> valTypeName val

showHsType :: HsType -> String
showHsType HsInt     = "Int"
showHsType HsListInt = "List[Int]"
showHsType HsBool    = "Bool"
showHsType HsString  = "String"

valTypeName :: Any -> String
valTypeName = showGraspType . graspTypeOf
```

Key changes:
- Pattern matching on `LispVal` → `graspTypeOf` checks
- `matchesType HsListInt` uses `isNil`/`isCons` + recursive check
- `valTypeName` delegates to `showGraspType . graspTypeOf`

---

### Task 6: Update `Grasp.HaskellInterop`

Update for `Any` types. The Int interop simplifies slightly since values are already native `Int` closures.

**Files:**
- Modify: `src/Grasp/HaskellInterop.hs`

**Step 1: Rewrite `src/Grasp/HaskellInterop.hs`**

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Grasp.HaskellInterop
  ( defaultEnvWithInterop
  , defaultRegistry
  ) where

import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Foreign.StablePtr
import GHC.Exts (Any)

import Grasp.Types
import Grasp.NativeTypes
import Grasp.Eval (defaultEnv)
import Grasp.RtsBridge (bridgeSafeApplyIntInt)
import Grasp.HsRegistry (dispatchRegistered)

-- | Default environment extended with haskell-call and hs: registry
defaultEnvWithInterop :: IO Env
defaultEnvWithInterop = do
  env <- defaultEnv
  reg <- defaultRegistry
  modifyIORef' env $ \ed -> ed
    { envBindings = Map.insert "haskell-call"
        (mkPrim "haskell-call" (haskellCall reg))
        (envBindings ed)
    , envHsRegistry = reg
    }
  pure env

haskellCall :: HsFuncRegistry -> [Any] -> IO Any
haskellCall reg (nameVal : args)
  | graspTypeOf nameVal == GTStr = dispatchRegistered reg (toStr nameVal) args
haskellCall _ _ = error "haskell-call expects (haskell-call \"name\" args...)"

-- | Build the default registry of Haskell functions
defaultRegistry :: IO HsFuncRegistry
defaultRegistry = do
  succEntry <- mkIntIntEntry "succ" (succ :: Int -> Int)
  negEntry  <- mkIntIntEntry "negate" (negate :: Int -> Int)
  pure $ Map.fromList
    [ ("succ",    succEntry)
    , ("negate",  negEntry)
    , ("reverse", HsFuncEntry [HsListInt] HsListInt hsReverse)
    , ("length",  HsFuncEntry [HsListInt] HsInt     hsLength)
    ]

-- | Create a registry entry for an (Int -> Int) function via the C bridge
mkIntIntEntry :: Text -> (Int -> Int) -> IO HsFuncEntry
mkIntIntEntry name f = do
  sp <- newStablePtr f
  pure $ HsFuncEntry [HsInt] HsInt $ \case
    [v] -> do
      result <- bridgeSafeApplyIntInt sp (toInt v)
      case result of
        Right r -> pure $ mkInt r
        Left err -> error $ T.unpack name <> ": " <> err
    _ -> error $ "internal: " <> T.unpack name <> " called with invalid args after validation"

hsReverse :: [Any] -> IO Any
hsReverse [listVal] = pure $ fromHaskellListInt (reverse (toHaskellListInt listVal))
hsReverse args = error $ "internal: reverse called with " <> show (length args) <> " args after validation"

hsLength :: [Any] -> IO Any
hsLength [listVal] = pure $ mkInt (length (toHaskellListInt listVal))
hsLength args = error $ "internal: length called with " <> show (length args) <> " args after validation"

-- | Marshal GraspVal cons list to Haskell [Int]
toHaskellListInt :: Any -> [Int]
toHaskellListInt v
  | isNil v   = []
  | isCons v  = toInt (toCar v) : toHaskellListInt (toCdr v)
  | otherwise = error "expected list of integers"

-- | Marshal Haskell [Int] to GraspVal cons list
fromHaskellListInt :: [Int] -> Any
fromHaskellListInt = foldr (\x acc -> mkCons (mkInt x) acc) mkNil
```

Key changes:
- `LStr name` pattern match → `graspTypeOf nameVal == GTStr` + `toStr`
- `LInt (fromIntegral n)` → `toInt v` (already an Int, no conversion needed)
- `LInt (fromIntegral v)` → `mkInt r`
- `LNil`/`LCons` pattern matches → `isNil`/`isCons` + extractors
- `fromIntegral` calls removed — values are already `Int`

---

### Task 7: Update `Main.hs` and `grasp.cabal`

**Files:**
- Modify: `src/Main.hs`
- Modify: `grasp.cabal`

**Step 1: Update `src/Main.hs`**

The REPL just needs to import `Grasp.NativeTypes` and stop importing `Grasp.Types`
(it doesn't use `LispVal` directly — `eval` returns `Any`, `printVal` takes `Any`).

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import System.IO (hFlush, stdout, hSetBuffering, stdin, BufferMode(..), isEOF)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Control.Exception (catch, SomeException, displayException)

import Grasp.Types (Env)
import Grasp.Parser
import Grasp.Eval
import Grasp.Printer
import Grasp.HaskellInterop (defaultEnvWithInterop)

main :: IO ()
main = do
  hSetBuffering stdin LineBuffering
  putStrLn "grasp v0.1 — a Lisp on GHC's runtime"
  putStrLn "Type (quit) to exit."
  env <- defaultEnvWithInterop
  repl env

repl :: Env -> IO ()
repl env = do
  putStr "λ> "
  hFlush stdout
  eof <- isEOF
  if eof
    then putStrLn "\nBye."
    else do
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

Only change: `import Grasp.Types` → `import Grasp.Types (Env)` (only need `Env` type).

**Step 2: Ensure `grasp.cabal` has `Grasp.NativeTypes`**

This was done in Task 1. Verify both `other-modules` lists include `Grasp.NativeTypes`.

---

### Task 8: Update test files

`ParserSpec.hs` and `RtsBridgeSpec.hs` do NOT change (Parser produces `LispExpr`, not `LispVal`; RtsBridge tests use `Int` directly).

`EvalSpec.hs` and `InteropSpec.hs` need minor updates.

**Files:**
- Modify: `test/EvalSpec.hs`
- Modify: `test/InteropSpec.hs`

**Step 1: Update `test/EvalSpec.hs`**

The `run` helper calls `eval` then `printVal` — both now work with `Any`. The only
change needed is updating imports and the `define` test which directly inspects `printVal val`.

```haskell
{-# LANGUAGE OverloadedStrings #-}
module EvalSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Grasp.Types
import Grasp.Eval
import Grasp.Parser
import Grasp.Printer

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

This file is actually identical to the current version — the `run` helper just calls `eval` and `printVal`, which have the same signatures at the API level. No changes needed unless imports break.

**Step 2: Update `test/InteropSpec.hs`**

```haskell
module InteropSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Control.Exception (evaluate, try, SomeException)
import Data.List (isInfixOf)
import Grasp.Types
import Grasp.Eval
import Grasp.Parser
import Grasp.Printer
import Grasp.HaskellInterop

-- Helper: parse + eval with interop, return printed result
run :: String -> IO String
run input = do
  env <- defaultEnvWithInterop
  case parseLisp (T.pack input) of
    Left err -> error (show err)
    Right expr -> do
      val <- eval env expr
      pure (printVal val)

-- Helper: parse + eval, expect error
runError :: String -> IO (Either SomeException String)
runError input = try (run input >>= evaluate)

isLeftContaining :: String -> Either SomeException a -> Bool
isLeftContaining needle (Left e) = needle `isInfixOf` show e
isLeftContaining _ (Right _) = False

spec :: Spec
spec = describe "Haskell Interop" $ do
  describe "haskell-call (backward compat)" $ do
    it "calls succ on an Int" $
      run "(haskell-call \"succ\" 41)" `shouldReturn` "42"

    it "calls negate on an Int" $
      run "(haskell-call \"negate\" 10)" `shouldReturn` "-10"

    it "calls reverse on a list of Ints" $
      run "(haskell-call \"reverse\" (list 1 2 3))" `shouldReturn` "(3 2 1)"

    it "calls length on a list" $
      run "(haskell-call \"length\" (list 10 20 30))" `shouldReturn` "3"

  describe "hs: syntax" $ do
    it "calls hs:succ" $
      run "(hs:succ 41)" `shouldReturn` "42"

    it "calls hs:negate" $
      run "(hs:negate 5)" `shouldReturn` "-5"

    it "calls hs:reverse on a list" $
      run "(hs:reverse (list 1 2 3))" `shouldReturn` "(3 2 1)"

    it "calls hs:length on a list" $
      run "(hs:length (list 10 20 30))" `shouldReturn` "3"

  describe "type validation" $ do
    it "rejects type mismatch (string to Int function)" $ do
      result <- runError "(haskell-call \"succ\" \"hello\")"
      result `shouldSatisfy` isLeftContaining "expected Int"

    it "rejects unknown function" $ do
      result <- runError "(haskell-call \"nonexistent\" 42)"
      result `shouldSatisfy` isLeftContaining "unknown Haskell function"

    it "rejects hs: type mismatch" $ do
      result <- runError "(hs:succ \"hello\")"
      result `shouldSatisfy` isLeftContaining "expected Int"

    it "rejects hs: unknown function" $ do
      result <- runError "(hs:nonexistent 42)"
      result `shouldSatisfy` isLeftContaining "unknown Haskell function"
```

Same as current — the `run` helper API is unchanged. Only imports might need updating.

---

### Task 9: Compile and run all tests

**Step 1: Compile**

Run: `nix develop -c cabal build all`
Expected: Clean compilation. If errors occur, fix type mismatches (most likely
missing imports of `Grasp.NativeTypes` or `GHC.Exts`).

**Step 2: Run all tests**

Run: `nix develop -c cabal test`
Expected: 75+ tests pass (50 existing + ~25 new NativeTypes tests).

Common failure modes to watch for:
- **`Integer` vs `Int` overflow**: `EInt` still parses as `Integer`. `fromInteger` in eval
  truncates to `Int`. Values > 2^63 will wrap. This is expected — document as known limitation.
- **Error message format**: InteropSpec checks error strings with `isInfixOf`. If
  `valTypeName` output changed, tests will fail. Fix by ensuring `showGraspType` returns
  the same strings ("Int", "String", etc.).
- **`haskell-call` name argument**: Old code matched `LStr name`. New code checks
  `graspTypeOf nameVal == GTStr`. The `haskell-call` form passes string arguments, so
  they're `GraspStr` closures. Make sure `toStr` extracts from `GraspStr`, not `GHC String`.

**Step 3: Spot-check in REPL**

Run: `nix develop -c cabal run grasp`

```lisp
λ> 42
42
λ> (+ 1 2)
3
λ> (list 1 2 3)
(1 2 3)
λ> (hs:succ 41)
42
λ> (define square (lambda (x) (* x x)))
<lambda>
λ> (square 5)
25
λ> (cons 1 2)
(1 . 2)
λ> '(a b c)
(a b c)
λ> (quit)
```

**Step 4: Commit**

```bash
git add -A
git commit -m "feat: replace LispVal ADT with native GHC heap closures

GraspVal = Any from GHC.Exts. Every runtime value is a raw StgClosure:
- Integers are I# closures (zero-cost interop with Haskell)
- Booleans are True/False static closures
- Grasp-specific types (Sym, Str, Cons, Lambda, Prim) use Haskell
  ADTs whose info tables GHC generates automatically
- Type discrimination via unpackClosure# reading info-table addresses
- Integer precision: Integer -> Int (64-bit fixed-width)"
```

---

### Task 10: Update documentation

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/language.md`
- Modify: `docs/roadmap.md`

Update docs to reflect:
- `LispVal` is gone, replaced by `GraspVal = Any`
- New `Grasp.NativeTypes` module
- Type discrimination via `unpackClosure#`
- `Integer` → `Int` change
- Phase 1 status in roadmap

Run: `nix run .#mkdoc` (if doc builder exists)

Commit:
```bash
git add docs/
git commit -m "docs: update for native STG closures"
```

---

## Summary of changes

| File | Action | Lines (approx) |
|------|--------|----------------|
| `src/Grasp/NativeTypes.hs` | CREATE | ~180 |
| `src/Grasp/Types.hs` | REWRITE | 40 (was 72) |
| `src/Grasp/Eval.hs` | REWRITE | ~100 (was 119) |
| `src/Grasp/Printer.hs` | REWRITE | ~20 (was 19) |
| `src/Grasp/HsRegistry.hs` | REWRITE | ~45 (was ~45) |
| `src/Grasp/HaskellInterop.hs` | REWRITE | ~75 (was 77) |
| `src/Main.hs` | MINOR | 1 line changed |
| `test/NativeTypesSpec.hs` | CREATE | ~80 |
| `test/EvalSpec.hs` | NO CHANGE | — |
| `test/InteropSpec.hs` | NO CHANGE | — |
| `test/ParserSpec.hs` | NO CHANGE | — |
| `test/RtsBridgeSpec.hs` | NO CHANGE | — |
| `grasp.cabal` | MINOR | 2 lines added |
| `docs/*.md` | UPDATE | ~50 lines |
