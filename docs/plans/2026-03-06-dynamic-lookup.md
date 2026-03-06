# Dynamic Function Lookup — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Call any compiled Haskell function by name at runtime via GHC API, with automatic type inference for monomorphic functions and explicit annotation for polymorphic ones.

**Architecture:** A lazy-initialized GHC API session provides `exprType` (type inference) and `compileExpr` (compilation to `Any`). The existing static registry is checked first; on miss, the GHC API looks up and caches the function. A new `hs@` special form handles polymorphic functions with explicit type annotations.

**Tech Stack:** GHC 9.8 API (`ghc` package), `ghc-paths` for libdir resolution, existing Grasp evaluator and type system.

---

### Task 1: Add `ghc` and `ghc-paths` dependencies

**Files:**
- Modify: `grasp.cabal:22-27` (executable build-depends)
- Modify: `grasp.cabal:56-63` (test build-depends)
- Modify: `flake.nix:22-26` (add `ghc-paths` to shellFor)

**Step 1: Modify `grasp.cabal`**

Add `ghc` and `ghc-paths` to both `build-depends` sections:

```cabal
  build-depends:
    , base        >= 4.18 && < 5
    , ghc-prim
    , ghc
    , ghc-paths
    , text
    , megaparsec
    , containers
    , mtl
```

Apply the same to the `test-suite` section.

**Step 2: Verify the flake resolves the new deps**

Run: `nix develop -c cabal build --dry-run 2>&1 | head -20`

Expected: `ghc` and `ghc-paths` appear as resolved dependencies (they're boot/bundled packages in nixpkgs GHC 9.8).

If `ghc-paths` is not found, modify `flake.nix` to add it:

```nix
devShells.${system}.default = hsPkgs.shellFor {
  packages = p: [ ];
  nativeBuildInputs = [
    hsPkgs.cabal-install
    hsPkgs.ghc-paths
    pkgs.overmind
    pkgs.tmux
  ];
};
```

**Step 3: Build to confirm no breakage**

Run: `nix develop -c cabal build 2>&1 | tail -5`

Expected: Build succeeds, no errors.

**Step 4: Run existing tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: 77 tests pass.

**Step 5: Commit**

```bash
git add grasp.cabal flake.nix
git commit -m "build: add ghc and ghc-paths dependencies for dynamic lookup"
```

---

### Task 2: Create `Grasp.DynLookup` — GHC session + type classification

This is the core module. It isolates all GHC API usage.

**Files:**
- Create: `src/Grasp/DynLookup.hs`
- Create: `test/DynLookupSpec.hs`
- Modify: `grasp.cabal` (add module to both sections)

**Step 1: Add module to `grasp.cabal`**

Add `Grasp.DynLookup` to both `other-modules` lists. Add `DynLookupSpec` to the test `other-modules`.

**Step 2: Write the failing test**

Create `test/DynLookupSpec.hs`:

```haskell
module DynLookupSpec (spec) where

import Test.Hspec
import Control.Exception (try, evaluate, SomeException)
import Data.List (isInfixOf)
import GHC.Exts (Any)
import Unsafe.Coerce (unsafeCoerce)

import Grasp.DynLookup
import Grasp.NativeTypes

-- Helper: check error message
isLeftContaining :: String -> Either SomeException a -> Bool
isLeftContaining needle (Left e) = needle `isInfixOf` show e
isLeftContaining _ (Right _) = False

spec :: Spec
spec = describe "DynLookup" $ do
  describe "GHC session" $ do
    it "initializes a GHC session" $ do
      state <- initGhcState
      -- If we got here without exception, it worked
      state `seq` pure () :: IO ()

  describe "type classification" $ do
    it "classifies Int -> Int" $ do
      state <- initGhcState
      info <- lookupFunc state "succ :: Int -> Int"
      funcArity info `shouldBe` 1
      funcArgs info `shouldBe` [NativeInt]
      funcReturn info `shouldBe` NativeInt

    it "classifies [Int] -> [Int]" $ do
      state <- initGhcState
      info <- lookupFunc state "reverse :: [Int] -> [Int]"
      funcArity info `shouldBe` 1
      funcArgs info `shouldBe` [ListOf NativeInt]
      funcReturn info `shouldBe` (ListOf NativeInt)

    it "classifies [Int] -> Int" $ do
      state <- initGhcState
      info <- lookupFunc state "length :: [Int] -> Int"
      funcArity info `shouldBe` 1
      funcArgs info `shouldBe` [ListOf NativeInt]
      funcReturn info `shouldBe` NativeInt

    it "classifies Int -> Int -> Int" $ do
      state <- initGhcState
      info <- lookupFunc state "(+) :: Int -> Int -> Int"
      funcArity info `shouldBe` 2
      funcArgs info `shouldBe` [NativeInt, NativeInt]
      funcReturn info `shouldBe` NativeInt

    it "classifies Bool -> Bool" $ do
      state <- initGhcState
      info <- lookupFunc state "not :: Bool -> Bool"
      funcArity info `shouldBe` 1
      funcArgs info `shouldBe` [NativeBool]
      funcReturn info `shouldBe` NativeBool

  describe "compilation + application" $ do
    it "compiles and calls succ" $ do
      state <- initGhcState
      result <- dynCall state "succ :: Int -> Int" [mkInt 41]
      graspTypeOf result `shouldBe` GTInt
      toInt result `shouldBe` 42

    it "compiles and calls negate" $ do
      state <- initGhcState
      result <- dynCall state "negate :: Int -> Int" [mkInt 5]
      graspTypeOf result `shouldBe` GTInt
      toInt result `shouldBe` (-5)

    it "compiles and calls not" $ do
      state <- initGhcState
      result <- dynCall state "not :: Bool -> Bool" [mkBool True]
      graspTypeOf result `shouldBe` GTBoolFalse

    it "compiles and calls reverse on list" $ do
      state <- initGhcState
      let lst = mkCons (mkInt 3) (mkCons (mkInt 1) (mkCons (mkInt 2) mkNil))
      result <- dynCall state "reverse :: [Int] -> [Int]" [lst]
      -- result should be (2 1 3)
      graspTypeOf result `shouldBe` GTCons
      toInt (toCar result) `shouldBe` 2

    it "compiles and calls sort" $ do
      state <- initGhcState
      let lst = mkCons (mkInt 3) (mkCons (mkInt 1) (mkCons (mkInt 2) mkNil))
      result <- dynCall state "Data.List.sort :: [Int] -> [Int]" [lst]
      graspTypeOf result `shouldBe` GTCons
      toInt (toCar result) `shouldBe` 1

    it "compiles and calls (+) with two args" $ do
      state <- initGhcState
      result <- dynCall state "(+) :: Int -> Int -> Int" [mkInt 10, mkInt 32]
      toInt result `shouldBe` 42

  describe "error handling" $ do
    it "rejects unsupported types" $ do
      state <- initGhcState
      result <- try $ evaluate =<< dynCall state "Data.Char.ord :: Char -> Int" [mkInt 65]
      result `shouldSatisfy` isLeftContaining "unsupported"
```

**Step 3: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Compilation fails (module not found).

**Step 4: Write the implementation**

Create `src/Grasp/DynLookup.hs`:

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Grasp.DynLookup
  ( -- * Types
    GraspArgType(..)
  , GraspFuncInfo(..)
  , GhcState
    -- * Session management
  , initGhcState
    -- * Lookup and call
  , lookupFunc
  , dynCall
  ) where

import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Exts (Any)
import Unsafe.Coerce (unsafeCoerce)
import Control.Exception (try, evaluate, SomeException)

-- GHC API imports
import GHC
import GHC.Paths (libdir)
import GHC.Driver.Session (GeneralFlag(..), gopt_set)
import GHC.Driver.Backend (interpreterBackend)
import GHC.Unit.Module (mkModuleName)
import GHC.Hs.ImpExp (simpleImportDecl)
import GHC.Core.Type (splitFunTys, expandTypeSynonyms)
import GHC.Core.TyCon (tyConName)
import GHC.Types.Name (getOccString)
import GHC.Builtin.Types (intTyCon, doubleTyCon, boolTyCon, listTyCon, charTyCon)
import GHC.Tc.Utils.TcType (tcSplitTyConApp_maybe)

import Grasp.NativeTypes

-- ─── Types ──────────────────────────────────────────────

data GraspArgType
  = NativeInt
  | NativeDouble
  | NativeBool
  | ListOf GraspArgType
  | HaskellString     -- String = [Char]
  | HaskellText       -- Data.Text.Text
  deriving (Eq, Show)

data GraspFuncInfo = GraspFuncInfo
  { funcArity  :: Int
  , funcArgs   :: [GraspArgType]
  , funcReturn :: GraspArgType
  } deriving (Eq, Show)

data CachedFunc = CachedFunc
  { cfInfo    :: GraspFuncInfo
  , cfClosure :: Any
  }

data GhcState = GhcState
  { ghcSession :: HscEnv
  , ghcCache   :: IORef (Map.Map Text CachedFunc)
  }

-- ─── Session management ─────────────────────────────────

initGhcState :: IO GhcState
initGhcState = runGhc (Just libdir) $ do
  dflags <- getSessionDynFlags
  let dflags' = dflags
        { backend = interpreterBackend
        , ghcLink = LinkInMemory
        }
  _ <- setSessionDynFlags (gopt_set dflags' Opt_ImplicitImportQualified)
  -- Import Prelude and Data.List by default
  setContext
    [ IIDecl (simpleImportDecl (mkModuleName "Prelude"))
    , IIDecl (simpleImportDecl (mkModuleName "Data.List"))
    ]
  hscEnv <- getSession
  cache <- liftIO $ newIORef Map.empty
  pure $ GhcState hscEnv cache

-- ─── Type classification ────────────────────────────────

-- | Classify a GHC Type into our type system
classifyType :: Type -> Either String GraspArgType
classifyType ty =
  let ty' = expandTypeSynonyms ty
  in case tcSplitTyConApp_maybe ty' of
    Just (tc, args)
      | tc == intTyCon    -> Right NativeInt
      | tc == doubleTyCon -> Right NativeDouble
      | tc == boolTyCon   -> Right NativeBool
      | tc == listTyCon, [elemTy] <- args ->
          case tcSplitTyConApp_maybe elemTy of
            Just (elemTc, _)
              | elemTc == charTyCon -> Right HaskellString
            _ -> ListOf <$> classifyType elemTy
      | otherwise -> Left $ "unsupported type: " <> getOccString (tyConName tc)
    Nothing -> Left $ "unsupported type (not a TyCon application)"

-- | Parse a function type into arg types + return type
decomposeFuncType :: Type -> Either String GraspFuncInfo
decomposeFuncType ty =
  let (argTys, retTy) = splitFunTys (expandTypeSynonyms ty)
      -- splitFunTys returns (Scaled Type) in GHC 9.8
      argTys' = map scaledThing argTys
  in do
    classifiedArgs <- mapM classifyType argTys'
    classifiedRet  <- classifyType retTy
    pure $ GraspFuncInfo
      { funcArity  = length classifiedArgs
      , funcArgs   = classifiedArgs
      , funcReturn = classifiedRet
      }

-- ─── Lookup and compilation ─────────────────────────────

-- | Look up a function by expression string, return its type info.
-- The expression should include a type annotation for polymorphic functions.
lookupFunc :: GhcState -> Text -> IO GraspFuncInfo
lookupFunc gs expr = do
  cached <- Map.lookup expr <$> readIORef (ghcCache gs)
  case cached of
    Just cf -> pure (cfInfo cf)
    Nothing -> do
      (info, closure) <- compileAndClassify gs expr
      modifyIORef' (ghcCache gs) $ Map.insert expr (CachedFunc info closure)
      pure info

-- | Compile a function and classify its type
compileAndClassify :: GhcState -> Text -> IO (GraspFuncInfo, Any)
compileAndClassify gs expr = runGhcWithState gs $ do
  -- Import module if the expression is qualified
  ensureModuleImported expr
  let exprStr = T.unpack expr
  -- Get the type
  ty <- exprType TM_Inst exprStr
  info <- case decomposeFuncType ty of
    Right i  -> pure i
    Left err -> liftIO $ error $ T.unpack expr <> ": " <> err
  -- Compile to closure
  hval <- compileExpr exprStr
  let closure = unsafeCoerce hval :: Any
  pure (info, closure)

-- | Run a GHC action reusing an existing session
runGhcWithState :: GhcState -> Ghc a -> IO a
runGhcWithState gs action = runGhc (Just libdir) $ do
  setSession (ghcSession gs)
  action

-- | If expression contains qualified name, import that module
ensureModuleImported :: Text -> Ghc ()
ensureModuleImported expr = do
  let -- Strip type annotation: "Data.List.sort :: [Int] -> [Int]" → "Data.List.sort"
      funcPart = T.strip $ case T.splitOn "::" expr of
        (f:_) -> f
        _     -> expr
      -- Extract module: "Data.List.sort" → "Data.List"
      parts = T.splitOn "." funcPart
  case parts of
    -- Qualified name like "Data.List.sort" (3+ parts where first is capitalized)
    (p:_) | length parts >= 3, T.head p >= 'A', T.head p <= 'Z' ->
      let modName = T.intercalate "." (init parts)
      in do
        ctx <- getContext
        let newImport = IIDecl (simpleImportDecl (mkModuleName (T.unpack modName)))
        setContext (newImport : ctx)
    -- Qualified name like "Mod.func" (2 parts, first capitalized)
    [modPart, _funcPart] | not (T.null modPart), T.head modPart >= 'A', T.head modPart <= 'Z' ->
      do
        ctx <- getContext
        let newImport = IIDecl (simpleImportDecl (mkModuleName (T.unpack modPart)))
        setContext (newImport : ctx)
    _ -> pure ()

-- ─── Dynamic call ───────────────────────────────────────

-- | Look up, compile, marshal, apply, and marshal back
dynCall :: GhcState -> Text -> [Any] -> IO Any
dynCall gs expr graspArgs = do
  cached <- Map.lookup expr <$> readIORef (ghcCache gs)
  (info, closure) <- case cached of
    Just cf -> pure (cfInfo cf, cfClosure cf)
    Nothing -> do
      result <- compileAndClassify gs expr
      modifyIORef' (ghcCache gs) $ Map.insert expr (CachedFunc (fst result) (snd result))
      pure result
  -- Validate arity
  let expectedArity = funcArity info
  if length graspArgs /= expectedArity
    then error $ T.unpack expr <> ": expected "
               <> show expectedArity <> " argument(s), got "
               <> show (length graspArgs)
    else do
      -- Marshal arguments: Grasp → Haskell
      marshaledArgs <- zipWithM marshalArg (funcArgs info) graspArgs
      -- Apply function to arguments
      result <- applyN closure marshaledArgs
      -- Marshal result: Haskell → Grasp
      marshalResult (funcReturn info) result

-- | Apply a function closure to arguments one at a time
applyN :: Any -> [Any] -> IO Any
applyN f []     = pure f
applyN f (x:xs) = applyN (unsafeCoerce f x) xs

-- | Marshal a Grasp value to a Haskell value for function application
marshalArg :: GraspArgType -> Any -> IO Any
marshalArg NativeInt    v = pure v  -- Int is native, no marshaling
marshalArg NativeDouble v = pure v  -- Double is native
marshalArg NativeBool   v = pure v  -- Bool is native
marshalArg (ListOf elemType) v = unsafeCoerce <$> marshalListToHaskell elemType v
marshalArg HaskellString v = pure $ unsafeCoerce (T.unpack (toStr v) :: String)
marshalArg HaskellText   v = pure v  -- Text is native (GraspStr wraps Text)

-- | Marshal a Haskell result back to a Grasp value
marshalResult :: GraspArgType -> Any -> IO Any
marshalResult NativeInt    v = pure v
marshalResult NativeDouble v = pure v
marshalResult NativeBool   v = pure v
marshalResult (ListOf elemType) v = marshalListFromHaskell elemType v
marshalResult HaskellString v = pure $ mkStr (T.pack (unsafeCoerce v :: String))
marshalResult HaskellText   v = pure v

-- | Marshal a Grasp cons list to a Haskell list for the given element type
marshalListToHaskell :: GraspArgType -> Any -> IO [Any]
marshalListToHaskell elemType v
  | isNil v   = pure []
  | isCons v  = do
      hd <- marshalArg elemType (toCar v)
      tl <- marshalListToHaskell elemType (toCdr v)
      pure (hd : tl)
  | otherwise = error "expected a list"

-- | Marshal a Haskell list back to a Grasp cons list
marshalListFromHaskell :: GraspArgType -> Any -> IO Any
marshalListFromHaskell elemType v = do
  let hsList = unsafeCoerce v :: [Any]
  elems <- mapM (marshalResult elemType) hsList
  pure $ foldr mkCons mkNil elems

-- | Zip with monadic action
zipWithM :: Monad m => (a -> b -> m c) -> [a] -> [b] -> m [c]
zipWithM f xs ys = sequence (zipWith f xs ys)
```

**Step 5: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: All tests pass (77 existing + new DynLookup tests).

**Step 6: Commit**

```bash
git add src/Grasp/DynLookup.hs test/DynLookupSpec.hs grasp.cabal
git commit -m "feat: add DynLookup module — GHC API session, type inference, compilation"
```

---

### Task 3: Add `envGhcSession` to `EnvData` and wire up lazy initialization

**Files:**
- Modify: `src/Grasp/Types.hs`
- Modify: `src/Grasp/HaskellInterop.hs`
- Modify: `src/Grasp/Eval.hs`

**Step 1: Add `envGhcSession` field to `EnvData`**

In `src/Grasp/Types.hs`, add `Data.IORef` import (already there) and the field:

```haskell
import Grasp.DynLookup (GhcState)

data EnvData = EnvData
  { envBindings   :: Map.Map Text GraspVal
  , envHsRegistry :: HsFuncRegistry
  , envGhcSession :: IORef (Maybe GhcState)  -- lazy init
  }
```

**Step 2: Update `defaultEnv` in `Eval.hs`**

```haskell
defaultEnv :: IO Env
defaultEnv = do
  ghcRef <- newIORef Nothing
  newIORef $ EnvData
    { envBindings = Map.fromList [ ... ]
    , envHsRegistry = Map.empty
    , envGhcSession = ghcRef
    }
```

**Step 3: Update `defaultEnvWithInterop` in `HaskellInterop.hs`**

No change needed — it calls `defaultEnv` which now initializes `envGhcSession`.

**Step 4: Build and test**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: 77+ tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/Types.hs src/Grasp/Eval.hs
git commit -m "feat: add envGhcSession to EnvData for lazy GHC session init"
```

---

### Task 4: Update `hs:` dispatch to fall back to GHC API

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `src/Grasp/HaskellInterop.hs` (add helper)

**Step 1: Write a failing integration test**

Add to `test/InteropSpec.hs`:

```haskell
  describe "hs: dynamic lookup" $ do
    it "calls a Prelude function not in registry" $
      run "(hs:abs -5)" `shouldReturn` "5"

    it "calls a qualified function" $
      run "(hs:Data.List.sort (list 3 1 2))" `shouldReturn` "(1 2 3)"

    it "calls not (Bool -> Bool)" $
      run "(hs:not #f)" `shouldReturn` "#t"
```

**Step 2: Run to verify failure**

Run: `nix develop -c cabal test 2>&1 | grep -A2 "FAIL\|dynamic"`

Expected: Tests fail with "unknown Haskell function".

**Step 3: Update `hs:` dispatch in `Eval.hs`**

Replace the current `hs:` handler:

```haskell
-- hs: prefix dispatches to the Haskell function registry, falling back to GHC API
eval env (EList (ESym name : args))
  | Just hsName <- T.stripPrefix "hs:" name = do
      ed <- readIORef env
      vals <- mapM (eval env) args
      case Map.lookup hsName (envHsRegistry ed) of
        Just entry -> do
          -- Static registry hit — validate types and call
          let expected = hfArgTypes entry
          if length vals /= length expected
            then error $ T.unpack hsName <> ": expected "
                       <> show (length expected) <> " argument(s), got "
                       <> show (length vals)
            else hfInvoke entry vals
        Nothing -> do
          -- Fall back to dynamic GHC API lookup
          dynDispatch (envGhcSession ed) hsName vals
```

**Step 4: Add `dynDispatch` helper in `HaskellInterop.hs`**

```haskell
import Grasp.DynLookup (GhcState, initGhcState, dynCall)

-- | Dynamic dispatch via GHC API (lazy session init)
dynDispatch :: IORef (Maybe GhcState) -> Text -> [Any] -> IO Any
dynDispatch gsRef name args = do
  gs <- readIORef gsRef
  state <- case gs of
    Just s  -> pure s
    Nothing -> do
      s <- initGhcState
      writeIORef gsRef (Just s)
      pure s
  -- For unqualified names, try with type annotation from GHC
  dynCall state name args
```

Wait — `dynCall` currently expects a typed expression like `"succ :: Int -> Int"`. For the auto-inferred `hs:` path, we need to infer the type first via `exprType`. Let me adjust.

Add to `Grasp.DynLookup`:

```haskell
-- | Look up an untyped function name, infer its type, compile, and call.
-- For the hs: auto-inferred path.
dynCallInferred :: GhcState -> Text -> [Any] -> IO Any
dynCallInferred gs name graspArgs = do
  cached <- Map.lookup name <$> readIORef (ghcCache gs)
  (info, closure) <- case cached of
    Just cf -> pure (cfInfo cf, cfClosure cf)
    Nothing -> do
      result <- inferAndCompile gs name
      modifyIORef' (ghcCache gs) $ Map.insert name (CachedFunc (fst result) (snd result))
      pure result
  -- Same application logic as dynCall
  let expectedArity = funcArity info
  if length graspArgs /= expectedArity
    then error $ T.unpack name <> ": expected "
               <> show expectedArity <> " argument(s), got "
               <> show (length graspArgs)
    else do
      marshaledArgs <- zipWithM marshalArg (funcArgs info) graspArgs
      result <- applyN closure marshaledArgs
      marshalResult (funcReturn info) result

-- | Infer type and compile for an untyped function name
inferAndCompile :: GhcState -> Text -> IO (GraspFuncInfo, Any)
inferAndCompile gs name = runGhcWithState gs $ do
  ensureModuleImported name
  let nameStr = T.unpack name
  -- Get type (instantiated — monomorphic)
  ty <- exprType TM_Inst nameStr
  info <- case decomposeFuncType ty of
    Right i  -> pure i
    Left err -> liftIO $ error $ T.unpack name <> ": " <> err
  -- Compile
  hval <- compileExpr nameStr
  let closure = unsafeCoerce hval :: Any
  pure (info, closure)
```

Export `dynCallInferred` from `Grasp.DynLookup`.

Then `dynDispatch` becomes:

```haskell
dynDispatch :: IORef (Maybe GhcState) -> Text -> [Any] -> IO Any
dynDispatch gsRef name args = do
  gs <- readIORef gsRef
  state <- case gs of
    Just s  -> pure s
    Nothing -> do
      s <- initGhcState
      writeIORef gsRef (Just s)
      pure s
  dynCallInferred state name args
```

**Step 5: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: All tests pass (77 existing + DynLookup + new interop tests).

**Step 6: Commit**

```bash
git add src/Grasp/Eval.hs src/Grasp/HaskellInterop.hs src/Grasp/DynLookup.hs test/InteropSpec.hs
git commit -m "feat: hs: prefix falls back to GHC API on registry miss"
```

---

### Task 5: Add `hs@` special form for annotated polymorphic functions

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `test/InteropSpec.hs`

**Step 1: Write failing tests**

Add to `test/InteropSpec.hs`:

```haskell
  describe "hs@ annotated form" $ do
    it "calls sort with explicit type" $
      run "(hs@ \"Data.List.sort :: [Int] -> [Int]\" (list 3 1 2))" `shouldReturn` "(1 2 3)"

    it "calls reverse with explicit type" $
      run "(hs@ \"reverse :: [Int] -> [Int]\" (list 1 2 3))" `shouldReturn` "(3 2 1)"

    it "calls (+) with explicit type and two args" $
      run "(hs@ \"(+) :: Int -> Int -> Int\" 10 32)" `shouldReturn` "42"
```

**Step 2: Run to verify failure**

Run: `nix develop -c cabal test 2>&1 | grep -A2 "FAIL\|annotated"`

Expected: Tests fail.

**Step 3: Add `hs@` handler in `Eval.hs`**

Add a new pattern match before the generic function application:

```haskell
-- hs@ annotated form: (hs@ "expr :: Type" args...)
eval env (EList (ESym "hs@" : args))
  | (exprArg : funcArgs) <- args = do
      exprVal <- eval env exprArg
      if graspTypeOf exprVal /= GTStr
        then error "hs@: first argument must be a string (type-annotated expression)"
        else do
          ed <- readIORef env
          vals <- mapM (eval env) funcArgs
          let expr = toStr exprVal
          gs <- readIORef (envGhcSession ed)
          state <- case gs of
            Just s  -> pure s
            Nothing -> do
              s <- initGhcState
              writeIORef (envGhcSession ed) (Just s)
              pure s
          dynCall state expr vals
  | otherwise = error "hs@: expects (hs@ \"expr :: Type\" args...)"
```

Add `import Grasp.DynLookup (initGhcState, dynCall)` to `Eval.hs`.

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/Eval.hs test/InteropSpec.hs
git commit -m "feat: add hs@ special form for annotated polymorphic function calls"
```

---

### Task 6: Extract `getOrInitGhcSession` helper to reduce duplication

**Files:**
- Modify: `src/Grasp/HaskellInterop.hs`
- Modify: `src/Grasp/Eval.hs`

**Step 1: Create shared helper**

In `HaskellInterop.hs`, export a helper:

```haskell
-- | Get or lazily initialize the GHC session
getOrInitGhc :: IORef (Maybe GhcState) -> IO GhcState
getOrInitGhc gsRef = do
  gs <- readIORef gsRef
  case gs of
    Just s  -> pure s
    Nothing -> do
      s <- initGhcState
      writeIORef gsRef (Just s)
      pure s
```

Export it. Use it in both `dynDispatch` and the `hs@` handler in `Eval.hs`.

**Step 2: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 3: Commit**

```bash
git add src/Grasp/Eval.hs src/Grasp/HaskellInterop.hs
git commit -m "refactor: extract getOrInitGhc helper for lazy session init"
```

---

### Task 7: Update documentation

**Files:**
- Modify: `docs/language.md`
- Modify: `docs/architecture.md`
- Modify: `docs/roadmap.md`

**Step 1: Update `language.md`**

Add section documenting `hs@` form and dynamic lookup:

- Under "Haskell Interop", add subsection for dynamic lookup explaining that any Haskell function can be called by name
- Document `hs@` form with examples
- Update the "Supported functions" table to note that the registry is a fast path and any function is available via GHC API
- Document supported types for dynamic lookup

**Step 2: Update `architecture.md`**

- Add `Grasp.DynLookup` module description
- Update the architecture diagram to show GHC API session path
- Update `EnvData` documentation

**Step 3: Update `roadmap.md`**

- Mark Phase 2 as complete
- Update current status section

**Step 4: Commit**

```bash
git add docs/language.md docs/architecture.md docs/roadmap.md
git commit -m "docs: update for Phase 2 dynamic function lookup"
```

---

### Task 8: REPL smoke test and final verification

**Step 1: Run full test suite**

Run: `nix develop -c cabal test 2>&1`

Expected: All tests pass.

**Step 2: REPL smoke test**

Run `nix develop -c cabal run grasp` and test:

```lisp
(hs:succ 41)                           ;; static registry → 42
(hs:abs -5)                             ;; dynamic lookup → 5
(hs:Data.List.sort (list 3 1 2))        ;; qualified + dynamic → (1 2 3)
(hs:not #f)                             ;; Bool → #t
(hs@ "reverse :: [Int] -> [Int]" (list 1 2 3))  ;; annotated → (3 2 1)
(hs@ "Data.List.sort :: [Int] -> [Int]" (list 5 3 1))  ;; → (1 3 5)
```

**Step 3: Update devlog**

Append Phase 2 completion entry to `artifacts/devlog.md`.

**Step 4: Commit**

```bash
git add artifacts/devlog.md
git commit -m "docs: update devlog for Phase 2 completion"
```
