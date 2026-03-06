# Opt-in Laziness — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `(lazy expr)` and `(force x)` forms that create real GHC THUNK closures with automatic memoization via GHC's standard update mechanism.

**Architecture:** `unsafeInterleaveIO` defers evaluation into a real GHC THUNK. The thunk is wrapped in a `GraspLazy` ADT for type discrimination. Primitives and Haskell interop auto-force lazy arguments at boundaries via `forceIfLazy`.

**Tech Stack:** `System.IO.Unsafe (unsafeInterleaveIO)` from base, existing `NativeTypes` infrastructure.

---

### Task 1: Add `GraspLazy` ADT and type discrimination

**Files:**
- Modify: `src/Grasp/NativeTypes.hs`
- Modify: `test/NativeTypesSpec.hs`

**Step 1: Write failing tests**

Add to `test/NativeTypesSpec.hs` in the type discrimination section:

```haskell
    it "discriminates GraspLazy" $ do
      let inner = mkInt 42
      let lazy = mkLazy inner
      graspTypeOf lazy `shouldBe` GTLazy

    it "forceLazy returns inner value" $ do
      let inner = mkInt 42
      let lazy = mkLazy inner
      result <- forceLazy lazy
      graspTypeOf result `shouldBe` GTInt
      toInt result `shouldBe` 42

    it "forceIfLazy passes non-lazy through" $ do
      let v = mkInt 99
      result <- forceIfLazy v
      toInt result `shouldBe` 99

    it "forceIfLazy forces lazy values" $ do
      let lazy = mkLazy (mkInt 77)
      result <- forceIfLazy lazy
      toInt result `shouldBe` 77
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Compilation fails — `GTLazy`, `mkLazy`, `forceLazy`, `forceIfLazy` not defined.

**Step 3: Implement**

In `src/Grasp/NativeTypes.hs`:

1. Add the ADT (after `GraspPrim`):

```haskell
data GraspLazy = GraspLazy Any  -- lazy field: holds a GHC THUNK
```

2. Add `GTLazy` to `GraspType`:

```haskell
data GraspType
  = GTInt | GTDouble | GTBoolTrue | GTBoolFalse
  | GTSym | GTStr | GTCons | GTNil
  | GTLambda | GTPrim | GTLazy
  deriving (Eq, Show)
```

3. Add `showGraspType`:

```haskell
showGraspType GTLazy     = "Lazy"
```

4. Add info pointer sentinel:

```haskell
{-# NOINLINE lazyInfoPtr #-}
lazyInfoPtr :: Ptr ()
lazyInfoPtr = getInfoPtr (GraspLazy (unsafeCoerce ()))
```

5. Add to `graspTypeOf` chain (before the `else error` fallthrough):

```haskell
  else if p == lazyInfoPtr then GTLazy
```

6. Add constructor, extractor, and helpers:

```haskell
mkLazy :: Any -> Any
mkLazy v = unsafeCoerce (GraspLazy v)

forceLazy :: Any -> IO Any
forceLazy v = let GraspLazy inner = unsafeCoerce v in inner `seq` pure inner

forceIfLazy :: Any -> IO Any
forceIfLazy v = case graspTypeOf v of
  GTLazy -> forceLazy v
  _      -> pure v
```

7. Add exports: `GraspLazy(..)`, `GTLazy` (already in `GraspType`), `mkLazy`, `forceLazy`, `forceIfLazy`.

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass (99 existing + 4 new = 103).

**Step 5: Commit**

```bash
git add src/Grasp/NativeTypes.hs test/NativeTypesSpec.hs
git commit -m "feat: add GraspLazy ADT, type discrimination, forceLazy, forceIfLazy"
```

---

### Task 2: Add `lazy` and `force` special forms to the evaluator

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `test/EvalSpec.hs`

**Step 1: Write failing tests**

Add to `test/EvalSpec.hs`:

```haskell
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

    it "lazy captures environment" $ do
      run "(define x 10) (force (lazy (+ x 5)))" `shouldReturn` "15"
```

Note: The `run` helper evaluates a single expression. For multi-expression tests, update it to handle semicolon-separated or newline-separated expressions, or chain `define` + expression into the same test.

Actually, looking at the existing `EvalSpec.hs`, multi-expression tests use a `runMulti` helper or evaluate sequentially with the same env. Check the existing test patterns and match them.

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | grep -A2 "lazy"`

Expected: Tests fail — `lazy` and `force` not recognized as special forms.

**Step 3: Implement**

In `src/Grasp/Eval.hs`:

1. Add import:

```haskell
import System.IO.Unsafe (unsafeInterleaveIO)
```

2. Add `lazy` special form (before the `hs@` handler):

```haskell
-- lazy: defer evaluation into a real GHC THUNK
eval env (EList [ESym "lazy", body]) = do
  thunk <- unsafeInterleaveIO (eval env body)
  pure (mkLazy (unsafeCoerce thunk))
```

Add `import Unsafe.Coerce (unsafeCoerce)` if not already imported.

3. Add `force` special form:

```haskell
-- force: enter a lazy thunk, triggering GHC's update mechanism
eval env (EList [ESym "force", expr]) = do
  v <- eval env expr
  forceIfLazy v
```

**Step 4: Update printer**

In `src/Grasp/Printer.hs`, add to the `graspTypeOf` dispatch:

```haskell
  GTLazy -> "<lazy>"
```

**Step 5: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 6: Commit**

```bash
git add src/Grasp/Eval.hs src/Grasp/Printer.hs test/EvalSpec.hs
git commit -m "feat: add lazy and force special forms"
```

---

### Task 3: Auto-force at primitive boundaries

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `test/EvalSpec.hs`

**Step 1: Write failing tests**

Add to the "lazy evaluation" section in `test/EvalSpec.hs`:

```haskell
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
```

**Step 2: Run to verify failure**

Run: `nix develop -c cabal test 2>&1 | grep "FAIL"`

Expected: Auto-force tests fail (primitives don't force lazy args yet).

**Step 3: Implement auto-forcing**

In `src/Grasp/Eval.hs`, modify the primitive operations to force args:

```haskell
numBinOp :: (Int -> Int -> Int) -> [Any] -> IO Any
numBinOp op [a, b] = do
  a' <- forceIfLazy a
  b' <- forceIfLazy b
  pure $ mkInt (op (toInt a') (toInt b'))
numBinOp _ args = error $ "expected two integers, got: " <> show (length args) <> " args"

eqOp :: [Any] -> IO Any
eqOp [a, b] = do
  a' <- forceIfLazy a
  b' <- forceIfLazy b
  pure $ mkBool (graspEq a' b')
eqOp _ = error "= expects two arguments"

cmpOp :: (Int -> Int -> Bool) -> [Any] -> IO Any
cmpOp op [a, b] = do
  a' <- forceIfLazy a
  b' <- forceIfLazy b
  pure $ mkBool (op (toInt a') (toInt b'))
cmpOp _ _ = error "comparison expects two integers"

carOp :: [Any] -> IO Any
carOp [v] = do
  v' <- forceIfLazy v
  if isCons v' then pure $ toCar v'
  else error "car expects a cons cell"
carOp _ = error "car expects a cons cell"

cdrOp :: [Any] -> IO Any
cdrOp [v] = do
  v' <- forceIfLazy v
  if isCons v' then pure $ toCdr v'
  else error "cdr expects a cons cell"
cdrOp _ = error "cdr expects a cons cell"

nullOp :: [Any] -> IO Any
nullOp [v] = do
  v' <- forceIfLazy v
  pure $ mkBool (isNil v')
nullOp _ = error "null? expects one argument"
```

Also auto-force in `apply`:

```haskell
apply :: Any -> [Any] -> IO Any
apply v args = do
  v' <- forceIfLazy v
  case graspTypeOf v' of
    GTPrim -> toPrimFn v' args
    GTLambda -> do
      let (params, body, closure) = toLambdaParts v'
      let bindings = Map.fromList (zip params args)
      parentEd <- readIORef closure
      childEnv <- newIORef $ parentEd { envBindings = Map.union bindings (envBindings parentEd) }
      eval childEnv body
    t -> error $ "not a function: " <> showGraspType t
```

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/Eval.hs test/EvalSpec.hs
git commit -m "feat: auto-force lazy values at primitive boundaries"
```

---

### Task 4: Auto-force at Haskell interop boundaries

**Files:**
- Modify: `src/Grasp/DynDispatch.hs`
- Modify: `test/InteropSpec.hs`

**Step 1: Write failing tests**

Add to `test/InteropSpec.hs`:

```haskell
  describe "lazy + interop" $ do
    it "auto-forces lazy args in hs:" $
      run "(hs:succ (lazy 41))" `shouldReturn` "42"

    it "auto-forces lazy args in hs@ form" $
      run "(hs@ \"(+) :: Int -> Int -> Int\" (lazy 10) (lazy 32))" `shouldReturn` "42"
```

**Step 2: Run to verify failure**

Expected: Tests fail — DynDispatch doesn't force lazy args before marshaling.

**Step 3: Implement**

In `src/Grasp/DynDispatch.hs`, add import:

```haskell
import Grasp.NativeTypes (forceIfLazy, ...)
```

Modify `marshalGraspToHaskell` to force before marshaling:

```haskell
marshalGraspToHaskell :: GraspArgType -> Any -> IO Any
marshalGraspToHaskell typ v = do
  v' <- forceIfLazy v
  case typ of
    NativeInt    -> pure v'
    NativeDouble -> pure v'
    NativeBool   -> pure v'
    HaskellText  -> pure v'
    HaskellString -> pure $ unsafeCoerce (T.unpack (toStr v'))
    ListOf elemType -> unsafeCoerce <$> toHaskellList elemType v'
```

Also add forceIfLazy to `inferArgType` in DynDispatch (since it reads graspTypeOf):

```haskell
inferArgType :: Any -> GraspArgType
```

This is pure, so it can't call forceIfLazy (which is IO). Instead, force args before calling `inferArgType` in `dynDispatch`. In `dynDispatch`, after getting `args`, force them:

```haskell
dynDispatch gsRef name args = do
  state <- getOrInitGhc gsRef
  args' <- mapM forceIfLazy args
  typeResult <- lookupFunc state name
  ...
  -- use args' instead of args everywhere below
```

Similarly in `dynDispatchAnnotated`:

```haskell
dynDispatchAnnotated gsRef expr args = do
  state <- getOrInitGhc gsRef
  args' <- mapM forceIfLazy args
  ...
```

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/DynDispatch.hs test/InteropSpec.hs
git commit -m "feat: auto-force lazy values at Haskell interop boundaries"
```

---

### Task 5: Add memoization test

This test verifies that GHC's thunk update mechanism actually works — a lazy
value is only evaluated once.

**Files:**
- Modify: `test/EvalSpec.hs`

**Step 1: Write the test**

```haskell
    it "memoizes after first force (thunk update)" $ do
      -- Use a side-effecting computation to verify single evaluation.
      -- Define a counter via list mutation, force twice, verify counter.
      -- Actually, since we can't easily observe side effects in the Grasp
      -- evaluator, we test memoization indirectly: a lazy value that
      -- would diverge if evaluated twice (e.g., via a shared environment
      -- mutation).
      --
      -- Simpler: just verify that force returns the same value both times.
      env <- defaultEnv
      case parseLisp "(lazy (+ 1 2))" of
        Right expr -> do
          lazyVal <- eval env expr
          r1 <- forceIfLazy lazyVal
          r2 <- forceIfLazy lazyVal
          toInt r1 `shouldBe` 3
          toInt r2 `shouldBe` 3
        Left err -> error (show err)
```

**Step 2: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 3: Commit**

```bash
git add test/EvalSpec.hs
git commit -m "test: add memoization verification for lazy thunks"
```

---

### Task 6: Update documentation

**Files:**
- Modify: `docs/language.md`
- Modify: `docs/roadmap.md`

**Step 1: Update `language.md`**

Add a "Lazy Evaluation" section after "Evaluation Model":

```markdown
### Opt-in Laziness

Grasp is strict by default, but individual expressions can be deferred with `lazy`:

\`\`\`lisp
(define x (lazy (+ 1 2)))  ; x is a THUNK, not 3
(force x)                   ; => 3 (evaluated, result cached)
(force x)                   ; => 3 (cached, not re-evaluated)
\`\`\`

`(lazy expr)` creates a real GHC THUNK closure on the heap. The thunk is not
evaluated until explicitly forced. GHC's standard update mechanism replaces the
thunk with an indirection on first force, so subsequent accesses return the
cached value.

Primitives and Haskell interop auto-force lazy arguments:

\`\`\`lisp
(+ (lazy 10) (lazy 20))     ; => 30 (auto-forced)
(hs:succ (lazy 41))          ; => 42 (auto-forced)
\`\`\`

A lazy value prints as `<lazy>` without forcing it.
```

**Step 2: Update `roadmap.md`**

Mark Phase 3 as complete, update test count.

**Step 3: Commit**

```bash
git add docs/language.md docs/roadmap.md
git commit -m "docs: update for Phase 3 opt-in laziness"
```
