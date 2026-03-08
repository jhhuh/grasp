# Module System — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a module system with `(module name (export ...) body...)`, `(import name)` / `(import "path")`, qualified dot access (`math.square`), module caching, and circular dependency detection.

**Architecture:** `GraspModule` ADT in NativeTypes, two new `EnvData` fields (`envModules`, `envLoading`), `module` and `import` special forms in Eval, dot-split in symbol lookup. Module files are `.gsp` files parsed with a new `parseFile` that handles multiple top-level expressions.

**Tech Stack:** Existing `NativeTypes` infrastructure, `System.Directory` for file existence, `Data.Text.IO` for file reading.

---

### Task 1: Add `envModules` and `envLoading` to `EnvData`

**Files:**
- Modify: `src/Grasp/Types.hs`
- Modify: `src/Grasp/Eval.hs`
- Modify: `src/Grasp/HaskellInterop.hs`

**Step 1: Implement**

In `src/Grasp/Types.hs`, add two fields to `EnvData`:

```haskell
data EnvData = EnvData
  { envBindings   :: Map.Map Text GraspVal
  , envHsRegistry :: HsFuncRegistry
  , envGhcSession :: IORef (Maybe Any)
  , envModules    :: Map.Map Text GraspVal  -- cached modules by name
  , envLoading    :: [Text]                 -- circular dep detection stack
  }
```

In `src/Grasp/Eval.hs`, update `defaultEnv` to initialize the new fields:

```haskell
defaultEnv :: IO Env
defaultEnv = do
  ghcRef <- newIORef Nothing
  newIORef $ EnvData
    { envBindings = Map.fromList [...]  -- existing bindings unchanged
    , envHsRegistry = Map.empty
    , envGhcSession = ghcRef
    , envModules = Map.empty
    , envLoading = []
    }
```

In `src/Grasp/HaskellInterop.hs`, the `defaultEnvWithInterop` function modifies
`EnvData` records via `modifyIORef'`. Since Haskell record updates only touch
specified fields, the new fields are untouched — no changes needed here, but
verify compilation succeeds.

**Step 2: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All 147 tests pass (no behavioral change).

**Step 3: Commit**

```bash
git add src/Grasp/Types.hs src/Grasp/Eval.hs
git commit -m "feat: add envModules and envLoading to EnvData"
```

---

### Task 2: Add `GraspModule` ADT and type discrimination

**Files:**
- Modify: `src/Grasp/NativeTypes.hs`
- Modify: `src/Grasp/Printer.hs`
- Modify: `test/NativeTypesSpec.hs`

**Step 1: Write failing test**

Add to `test/NativeTypesSpec.hs` in the type discrimination section:

```haskell
    it "identifies Module" $
      graspTypeOf (mkModule "test" Map.empty) `shouldBe` GTModule
```

Add this import at the top of `NativeTypesSpec.hs`:

```haskell
import qualified Data.Map.Strict as Map
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Compilation fails — `GTModule`, `mkModule` not defined.

**Step 3: Implement**

In `src/Grasp/NativeTypes.hs`:

1. Add import at the top:

```haskell
import qualified Data.Map.Strict as Map
```

2. Add the ADT (after `GraspChan`):

```haskell
data GraspModule = GraspModule Text (Map.Map Text Any)
```

3. Add `GTModule` to `GraspType`:

```haskell
data GraspType
  = GTInt | GTDouble | GTBoolTrue | GTBoolFalse
  | GTSym | GTStr | GTCons | GTNil
  | GTLambda | GTPrim | GTLazy | GTMacro | GTChan | GTModule
  deriving (Eq, Show)
```

4. Add `showGraspType`:

```haskell
showGraspType GTModule    = "Module"
```

5. Add info pointer sentinel:

```haskell
{-# NOINLINE moduleInfoPtr #-}
moduleInfoPtr :: Ptr ()
moduleInfoPtr = getInfoPtr (GraspModule undefined undefined)
```

6. Add to `graspTypeOf` chain (before the `else error` fallthrough):

```haskell
  else if p == moduleInfoPtr then GTModule
```

7. Add constructor and extractors:

```haskell
mkModule :: Text -> Map.Map Text Any -> Any
mkModule name exports = unsafeCoerce (GraspModule name exports)

toModuleName :: Any -> Text
toModuleName v = let GraspModule n _ = unsafeCoerce v in n

toModuleExports :: Any -> Map.Map Text Any
toModuleExports v = let GraspModule _ e = unsafeCoerce v in e
```

8. Add exports: `GraspModule(..)`, `mkModule`, `toModuleName`, `toModuleExports`.

In `src/Grasp/Printer.hs`, add to the `graspTypeOf` dispatch:

```haskell
  GTModule    -> "<module:" <> T.unpack (toModuleName v) <> ">"
```

Also add `import qualified Data.Text as T` to Printer.hs if not already present (check — it currently uses `T.unpack` for sym/str, so it should already have this import).

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/NativeTypes.hs src/Grasp/Printer.hs test/NativeTypesSpec.hs
git commit -m "feat: add GraspModule ADT, type discrimination, mkModule, extractors"
```

---

### Task 3: Add `parseFile` for multi-expression files

**Files:**
- Modify: `src/Grasp/Parser.hs`
- Modify: `test/ParserSpec.hs` (if it exists, otherwise `test/EvalSpec.hs`)

**Step 1: Write failing test**

Check if `test/ParserSpec.hs` exists. If not, add this test to `test/EvalSpec.hs`.

Add to tests:

```haskell
  describe "parseFile" $ do
    it "parses multiple expressions" $ do
      let input = "(define x 1)\n(define y 2)"
      case parseFile input of
        Right exprs -> length exprs `shouldBe` 2
        Left err -> error (show err)

    it "parses single expression" $ do
      let input = "(module foo (export x) (define x 1))"
      case parseFile input of
        Right exprs -> length exprs `shouldBe` 1
        Left err -> error (show err)
```

Add `parseFile` to the import of `Grasp.Parser`:

```haskell
import Grasp.Parser (parseLisp, parseFile)
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Compilation fails — `parseFile` not defined.

**Step 3: Implement**

In `src/Grasp/Parser.hs`, add `parseFile` to the export list:

```haskell
module Grasp.Parser
  ( pExpr
  , parseLisp
  , parseFile
  ) where
```

Add the function:

```haskell
parseFile :: Text -> Either (ParseErrorBundle Text Void) [LispExpr]
parseFile = parse (sc *> many pExpr <* eof) "<file>"
```

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/Parser.hs test/EvalSpec.hs
git commit -m "feat: add parseFile for multi-expression file parsing"
```

---

### Task 4: Add `module` special form

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `test/EvalSpec.hs`

**Step 1: Write failing tests**

Add to `test/EvalSpec.hs`:

```haskell
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
```

Add these imports to `EvalSpec.hs`:

```haskell
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as Map
import Grasp.NativeTypes (..., toModuleExports)
```

Expand the existing `Data.List` import to include `isPrefixOf`, and add the
`Map` import. Add `toModuleExports` to the `NativeTypes` import.

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Tests fail — `module` not recognized as a special form.

**Step 3: Implement**

In `src/Grasp/Eval.hs`, add the `module` special form (after `defmacro`, before `lazy`):

```haskell
-- module: define a module with exports
eval env (EList (ESym "module" : ESym name : EList exports : body)) = do
  let exportNames = map (\case ESym s -> s; _ -> error "export list must contain symbols") exports
  -- Create child env inheriting parent's bindings (primitives, etc.)
  parentEd <- readIORef env
  childEnv <- newIORef parentEd
  -- Evaluate body forms sequentially in child env
  mapM_ (eval childEnv) body
  -- Collect exports
  childEd <- readIORef childEnv
  let exportMap = Map.fromList
        [ (s, v)
        | s <- exportNames
        , let v = case Map.lookup s (envBindings childEd) of
                Just val -> val
                Nothing  -> error $ "module " <> T.unpack name
                                 <> ": exported symbol '" <> T.unpack s
                                 <> "' is not defined"
        ]
  let modVal = mkModule name exportMap
  -- Store module in parent's envModules
  modifyIORef' env $ \ed -> ed { envModules = Map.insert name modVal (envModules ed) }
  pure modVal
```

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/Eval.hs test/EvalSpec.hs
git commit -m "feat: add module special form"
```

---

### Task 5: Add `import` special form

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `test/EvalSpec.hs`

**Step 1: Write failing tests**

These tests need temporary `.gsp` files. Add to `test/EvalSpec.hs`:

```haskell
    it "import loads a module file" $ do
      -- Write a temp module file
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
          -- Import again — should use cache
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

    it "import by name looks for .gsp file" $ do
      -- Write file in cwd (need to know cwd)
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
      -- Clean up
      removeFile "namemod.gsp"
```

Add these imports to `EvalSpec.hs`:

```haskell
import qualified Data.Text.IO as TIO
import System.Directory (removeFile)
import Data.IORef (readIORef)
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Tests fail — `import` not recognized.

**Step 3: Implement**

In `src/Grasp/Eval.hs`, add imports:

```haskell
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist)
import Grasp.Parser (parseLisp, parseFile)
```

Note: `parseLisp` is already imported via `Grasp.Parser` — check and add `parseFile`
to the existing import if needed. Actually, looking at the current imports, `Grasp.Parser`
is NOT imported in `Eval.hs`. So add the full import.

Add the `import` special form (after `module`, before `lazy`):

```haskell
-- import: load a module from file
eval env (EList [ESym "import", moduleRef]) = do
  -- Resolve file path and module name
  (filePath, expectedName) <- case moduleRef of
    EStr path -> pure (T.unpack path, Nothing)         -- explicit path
    ESym name -> pure (T.unpack name <> ".gsp", Just name)  -- name-based
    _ -> error "import expects a symbol or string"
  -- Check file exists
  exists <- doesFileExist filePath
  if not exists
    then error $ "import: file not found: " <> filePath
    else do
      -- Read and parse file
      content <- TIO.readFile filePath
      case parseFile content of
        Left err -> error $ "import: parse error in " <> filePath <> ": " <> show err
        Right exprs -> do
          -- Find the module form (first expression should be a module)
          case exprs of
            [] -> error $ "import: no module definition in " <> filePath
            (modExpr:rest) -> do
              -- Check for circular dependency
              ed <- readIORef env
              let modName = case modExpr of
                    EList (ESym "module" : ESym n : _) -> n
                    _ -> error $ "import: no module definition in " <> filePath
              if modName `elem` envLoading ed
                then error $ "import: circular dependency: "
                          <> T.unpack (T.intercalate " -> " (envLoading ed <> [modName]))
                else do
                  -- Check cache
                  case Map.lookup modName (envModules ed) of
                    Just cached -> do
                      -- Bind cached module's exports
                      bindModuleExports env modName cached
                      pure cached
                    Nothing -> do
                      -- Push loading stack
                      modifyIORef' env $ \ed' -> ed' { envLoading = envLoading ed' <> [modName] }
                      -- Create child env inheriting primitives
                      childEnv <- newIORef ed { envLoading = envLoading ed <> [modName] }
                      -- Eval all expressions (module + any top-level forms)
                      results <- mapM (eval childEnv) (modExpr : rest)
                      -- Find the module result
                      let modVal = case filter (\v -> graspTypeOf v == GTModule) results of
                            (m:_) -> m
                            []    -> error $ "import: no module definition in " <> filePath
                      -- Pop loading stack and cache
                      modifyIORef' env $ \ed' -> ed'
                        { envLoading = filter (/= modName) (envLoading ed')
                        , envModules = Map.insert modName modVal (envModules ed')
                        }
                      -- Bind exports
                      bindModuleExports env modName modVal
                      pure modVal
```

Add the helper function (after `apply`):

```haskell
-- | Bind a module's exports into the environment (qualified + unqualified).
bindModuleExports :: Env -> Text -> Any -> IO ()
bindModuleExports env modName modVal = do
  let exports = toModuleExports modVal
  modifyIORef' env $ \ed -> ed
    { envBindings = Map.union qualifiedBindings (Map.union exports (envBindings ed)) }
  where
    qualifiedBindings = Map.mapKeys (\k -> modName <> "." <> k) (toModuleExports modVal)
```

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/Eval.hs test/EvalSpec.hs
git commit -m "feat: add import special form with caching and circular dep detection"
```

---

### Task 6: Add dot-qualified symbol lookup

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `test/EvalSpec.hs`

**Step 1: Write failing test**

Add to `test/EvalSpec.hs` in the modules section:

```haskell
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
      -- Define a module, then look up qualified name via dot-split
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
```

Add `modifyIORef'` to the `Data.IORef` import if not already there.

**Step 2: Run tests to verify they fail**

The first test should actually pass already (since `module` creates `m.val` bindings).
The second test specifically tests the dot-split fallback by removing the flat binding.

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Second test fails — dot-split not implemented yet.

**Step 3: Implement**

In `src/Grasp/Eval.hs`, modify the symbol lookup clause. Change:

```haskell
eval env (ESym s)  = do
  ed <- readIORef env
  case Map.lookup s (envBindings ed) of
    Just v  -> pure v
    Nothing -> error $ "unbound symbol: " <> T.unpack s
```

To:

```haskell
eval env (ESym s)  = do
  ed <- readIORef env
  case Map.lookup s (envBindings ed) of
    Just v  -> pure v
    Nothing
      | Just (prefix, suffix) <- splitQualified s -> do
          case Map.lookup prefix (envModules ed) of
            Just modVal -> do
              let exports = toModuleExports modVal
              case Map.lookup suffix exports of
                Just v  -> pure v
                Nothing -> error $ "unbound symbol: " <> T.unpack s
            Nothing -> error $ "unbound symbol: " <> T.unpack s
      | otherwise -> error $ "unbound symbol: " <> T.unpack s
```

Add the helper:

```haskell
-- | Split a qualified symbol on the first dot: "foo.bar" -> Just ("foo", "bar")
splitQualified :: Text -> Maybe (Text, Text)
splitQualified s = case T.break (== '.') s of
  (prefix, rest)
    | T.null rest -> Nothing           -- no dot
    | T.null prefix -> Nothing         -- starts with dot
    | otherwise -> Just (prefix, T.tail rest)  -- drop the dot
```

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/Eval.hs test/EvalSpec.hs
git commit -m "feat: add dot-qualified symbol lookup via envModules"
```

---

### Task 7: Update documentation

**Files:**
- Modify: `docs/language.md`
- Modify: `docs/roadmap.md`
- Modify: `docs/architecture.md`

**Step 1: Update `language.md`**

Add a "Modules" section after "Concurrency" (before "Evaluation Model"):

```markdown
## Modules

### `module`

Defines a module with explicit exports:

\`\`\`lisp
(module math
  (export square cube)

  (define square (lambda (x) (* x x)))
  (define cube (lambda (x) (* x (square x))))
  (define helper (lambda (x) (+ x 1)))  ; not exported
)
\`\`\`

The module body is evaluated in a fresh environment inheriting the caller's
primitives. Only symbols listed in `(export ...)` are accessible from outside.
A module value prints as `<module:name>`.

### `import`

Loads a module from a file:

\`\`\`lisp
(import math)              ; loads math.gsp from current directory
(import "./lib/utils.gsp") ; explicit path
\`\`\`

Import binds all exported symbols both qualified and unqualified:

\`\`\`lisp
(import math)
(square 5)       ; => 25 (unqualified)
(math.square 5)  ; => 25 (qualified)
\`\`\`

Modules are cached after first load — importing the same module twice reuses
the cached version. Circular dependencies are detected and produce an error.
```

Add `GraspModule` to the types table:

```markdown
| `GraspModule` | Module | `<module:name>` |
```

**Step 2: Update `roadmap.md`**

Update status line, mark Phase 6 complete, update test count.

**Step 3: Update `architecture.md`**

Add `GraspModule` to the NativeTypes ADT list. Add `module`/`import` to the
Eval special forms description. Note the `envModules`/`envLoading` fields
in `EnvData`.

**Step 4: Commit**

```bash
git add docs/language.md docs/roadmap.md docs/architecture.md
git commit -m "docs: update for module system"
```
