# Macro System — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `(defmacro name (params) body)` that defines user macros receiving unevaluated arguments as quoted runtime values, returning code as data for re-evaluation.

**Architecture:** Macros are a new `GraspMacro` ADT stored in regular env bindings. At eval time, when a call resolves to a macro, arguments are quoted (not evaluated), the macro body runs, and the result is converted back to `LispExpr` via `anyToExpr` and evaluated in the caller's environment.

**Tech Stack:** Existing `NativeTypes` infrastructure, `evalQuote` for quoting args, new `anyToExpr` for the reverse conversion.

---

### Task 1: Add `GraspMacro` ADT and type discrimination

**Files:**
- Modify: `src/Grasp/NativeTypes.hs`
- Modify: `test/NativeTypesSpec.hs`

**Step 1: Write failing tests**

Add to `test/NativeTypesSpec.hs` in the type discrimination section:

```haskell
    it "identifies Macro" $ do
      env <- newIORef undefined
      let macro = mkMacro ["x"] (ESym "x") env
      graspTypeOf macro `shouldBe` GTMacro
```

Add these imports at the top of `NativeTypesSpec.hs`:

```haskell
import Data.IORef
import Grasp.Types (LispExpr(..))
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Compilation fails — `GTMacro`, `mkMacro` not defined.

**Step 3: Implement**

In `src/Grasp/NativeTypes.hs`:

1. Add the ADT (after `GraspLazy`):

```haskell
data GraspMacro  = GraspMacro [Text] LispExpr Env
```

2. Add `GTMacro` to `GraspType`:

```haskell
data GraspType
  = GTInt | GTDouble | GTBoolTrue | GTBoolFalse
  | GTSym | GTStr | GTCons | GTNil
  | GTLambda | GTPrim | GTLazy | GTMacro
  deriving (Eq, Show)
```

3. Add `showGraspType`:

```haskell
showGraspType GTMacro     = "Macro"
```

4. Add info pointer sentinel:

```haskell
{-# NOINLINE macroInfoPtr #-}
macroInfoPtr :: Ptr ()
macroInfoPtr = getInfoPtr (GraspMacro undefined undefined undefined)
```

5. Add to `graspTypeOf` chain (before the `else error` fallthrough):

```haskell
  else if p == macroInfoPtr then GTMacro
```

6. Add constructor and extractor:

```haskell
mkMacro :: [Text] -> LispExpr -> Env -> Any
mkMacro params body env = unsafeCoerce (GraspMacro params body env)

toMacroParts :: Any -> ([Text], LispExpr, Env)
toMacroParts v = let GraspMacro p b e = unsafeCoerce v in (p, b, e)
```

7. Add exports: `GraspMacro(..)`, `mkMacro`, `toMacroParts` (GTMacro is already in `GraspType`).

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/NativeTypes.hs test/NativeTypesSpec.hs
git commit -m "feat: add GraspMacro ADT, type discrimination, mkMacro, toMacroParts"
```

---

### Task 2: Add `anyToExpr` conversion function

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `test/EvalSpec.hs`

**Step 1: Write failing tests**

Add a new `describe` section to `test/EvalSpec.hs`. These tests exercise `anyToExpr`
indirectly through macros (added in Task 3), but we need `anyToExpr` to exist first.
For now, add a direct unit test by exporting `anyToExpr`.

Add to `test/EvalSpec.hs` imports:

```haskell
import Grasp.NativeTypes (graspTypeOf, GraspType(..), forceIfLazy, toInt, mkInt, mkSym, mkCons, mkNil, mkBool, mkStr)
```

(Expand the existing import to include `mkInt`, `mkSym`, `mkCons`, `mkNil`, `mkBool`, `mkStr`.)

Add to `test/EvalSpec.hs`:

```haskell
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
```

Also add `anyToExpr` to the `EvalSpec` import of `Grasp.Eval`.

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Compilation fails — `anyToExpr` not defined/exported.

**Step 3: Implement**

In `src/Grasp/Eval.hs`, add `anyToExpr` to the export list:

```haskell
module Grasp.Eval
  ( eval
  , defaultEnv
  , anyToExpr
  ) where
```

Add `anyToExpr` and helper (at the bottom, after `evalQuote`):

```haskell
-- | Convert a runtime value back to a LispExpr for macro expansion.
anyToExpr :: Any -> LispExpr
anyToExpr v = case graspTypeOf v of
  GTInt       -> EInt (fromIntegral (toInt v))
  GTDouble    -> EDouble (toDouble v)
  GTBoolTrue  -> EBool True
  GTBoolFalse -> EBool False
  GTSym       -> ESym (toSym v)
  GTStr       -> EStr (toStr v)
  GTNil       -> EList []
  GTCons      -> EList (consToExprList v)
  t           -> error $ "cannot use " <> showGraspType t <> " as code in macro expansion"

-- | Walk a cons chain, converting each element to LispExpr.
consToExprList :: Any -> [LispExpr]
consToExprList v
  | isNil v   = []
  | isCons v  = anyToExpr (toCar v) : consToExprList (toCdr v)
  | otherwise = error "improper list in macro expansion"
```

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/Eval.hs test/EvalSpec.hs
git commit -m "feat: add anyToExpr for converting runtime values to LispExpr"
```

---

### Task 3: Add `defmacro` special form and macro expansion

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `src/Grasp/Printer.hs`
- Modify: `test/EvalSpec.hs`

**Step 1: Write failing tests**

Add to `test/EvalSpec.hs`:

```haskell
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
      -- Define two macros, one uses the other
      mapM_ (\src -> case parseLisp src of
        Right e -> eval env e >> pure ()
        Left err -> error (show err))
        [ "(defmacro when (cond body) (list 'if cond body '()))"
        , "(defmacro unless (cond body) (list 'when (list 'not cond) body))"
        ]
      case parseLisp "(unless #f 99)" of
        Right callExpr -> do
          val <- eval env callExpr
          printVal val `shouldBe` "99"
        Left err -> error (show err)

    it "macro prints as <macro>" $
      run "(defmacro foo (x) x)" `shouldReturn` "<macro>"
```

Note: The `unless` test requires `not` to be available. Since `hs:not` would work but the
test uses `run` with `defaultEnv` (no interop), we should either use `defaultEnvWithInterop`
or add a simpler test. Actually, looking at the test: `(list 'when (list 'not cond) body)` —
the `not` would need to be defined. Let's simplify this test to avoid the dependency:

Replace the "macro expands into macro call" test with:

```haskell
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
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Tests fail — `defmacro` not recognized as a special form.

**Step 3: Implement**

In `src/Grasp/Printer.hs`, add to the `graspTypeOf` dispatch:

```haskell
  GTMacro     -> "<macro>"
```

In `src/Grasp/Eval.hs`:

1. Add `defmacro` special form (after the `lambda` handler, before `lazy`):

```haskell
-- defmacro: define a macro
eval env (EList [ESym "defmacro", ESym name, EList params, body]) = do
  let paramNames = map (\case ESym s -> s; _ -> error "macro params must be symbols") params
  let macro = mkMacro paramNames body env
  modifyIORef' env $ \ed -> ed { envBindings = Map.insert name macro (envBindings ed) }
  pure macro
```

2. Modify the function application clause to check for macros:

Change:

```haskell
eval env (EList (fn : args)) = do
  f <- eval env fn
  vals <- mapM (eval env) args
  apply f vals
```

To:

```haskell
eval env (EList (fn : args)) = do
  f <- eval env fn
  f' <- forceIfLazy f
  case graspTypeOf f' of
    GTMacro -> do
      quotedArgs <- mapM evalQuote args
      let (params, body, closure) = toMacroParts f'
      let bindings = Map.fromList (zip params quotedArgs)
      parentEd <- readIORef closure
      childEnv <- newIORef $ parentEd { envBindings = Map.union bindings (envBindings parentEd) }
      expansion <- eval childEnv body
      eval env (anyToExpr expansion)
    _ -> do
      vals <- mapM (eval env) args
      apply f' vals
```

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/Eval.hs src/Grasp/Printer.hs test/EvalSpec.hs
git commit -m "feat: add defmacro special form and macro expansion"
```

---

### Task 4: Update documentation

**Files:**
- Modify: `docs/language.md`
- Modify: `docs/roadmap.md`
- Modify: `docs/architecture.md`

**Step 1: Update `language.md`**

Add a "Macros" section after "Opt-in Laziness" in the Special Forms area (or create
a new top-level section after Special Forms):

```markdown
### `defmacro`

Defines a macro — a function that receives unevaluated arguments and returns code:

\`\`\`lisp
(defmacro when (cond body)
  (list 'if cond body '()))

(when (> x 0) (print "positive"))
; expands to: (if (> x 0) (print "positive") ())
\`\`\`

Macro arguments are **not evaluated** before being passed to the macro body. Instead,
they are quoted — converted to runtime data (cons cells, symbols, literals) that the
macro body can inspect and rearrange using standard list operations (`list`, `cons`,
`car`, `cdr`).

The macro body returns a value (typically built with `list` and `quote`), which is
then converted back to an expression and evaluated in the caller's environment.

\`\`\`lisp
(defmacro double (x) (list '+ x x))
(double (+ 1 2))  ; expands to (+ (+ 1 2) (+ 1 2)) => 6
\`\`\`

A macro value prints as `<macro>`.
```

Add `GraspMacro` to the types table:

```markdown
| `GraspMacro` | Macro | `<macro>` |
```

**Step 2: Update `roadmap.md`**

Mark Phase 5 as complete, update status and test count.

**Step 3: Update `architecture.md`**

Add `defmacro` to the Eval special forms list. Add `GraspMacro` to the NativeTypes ADT list.

**Step 4: Commit**

```bash
git add docs/language.md docs/roadmap.md docs/architecture.md
git commit -m "docs: update for macro system"
```
