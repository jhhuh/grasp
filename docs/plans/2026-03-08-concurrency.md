# Concurrency — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add green thread spawning and channel-based communication using GHC's native `forkIO` and `Chan`.

**Architecture:** Four new primitives (`spawn`, `make-chan`, `chan-put`, `chan-get`) added to `defaultEnv`. One new `GraspChan` ADT in `NativeTypes` following the existing info-pointer pattern. `apply` exported from `Eval` so `spawn` can call it.

**Tech Stack:** `Control.Concurrent` (forkIO), `Control.Concurrent.Chan`, existing `NativeTypes` infrastructure.

---

### Task 1: Add `GraspChan` ADT and type discrimination

**Files:**
- Modify: `src/Grasp/NativeTypes.hs`
- Modify: `test/NativeTypesSpec.hs`

**Step 1: Write failing test**

Add to `test/NativeTypesSpec.hs` in the type discrimination section:

```haskell
    it "identifies Chan" $ do
      ch <- newChan
      graspTypeOf (mkChan ch) `shouldBe` GTChan
```

Add this import at the top of `NativeTypesSpec.hs`:

```haskell
import Control.Concurrent.Chan (newChan)
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Compilation fails — `GTChan`, `mkChan` not defined.

**Step 3: Implement**

In `src/Grasp/NativeTypes.hs`:

1. Add import at the top (after the existing imports):

```haskell
import Control.Concurrent.Chan (Chan)
```

2. Add the ADT (after `GraspMacro`):

```haskell
data GraspChan = GraspChan (Chan Any)
```

3. Add `GTChan` to `GraspType`:

```haskell
data GraspType
  = GTInt | GTDouble | GTBoolTrue | GTBoolFalse
  | GTSym | GTStr | GTCons | GTNil
  | GTLambda | GTPrim | GTLazy | GTMacro | GTChan
  deriving (Eq, Show)
```

4. Add `showGraspType`:

```haskell
showGraspType GTChan      = "Chan"
```

5. Add info pointer sentinel:

```haskell
{-# NOINLINE chanInfoPtr #-}
chanInfoPtr :: Ptr ()
chanInfoPtr = getInfoPtr (GraspChan undefined)
```

6. Add to `graspTypeOf` chain (before the `else error` fallthrough):

```haskell
  else if p == chanInfoPtr then GTChan
```

7. Add constructor and extractor:

```haskell
mkChan :: Chan Any -> Any
mkChan ch = unsafeCoerce (GraspChan ch)

toChan :: Any -> Chan Any
toChan v = let GraspChan ch = unsafeCoerce v in ch
```

8. Add exports: `GraspChan(..)`, `mkChan`, `toChan` (GTChan is already in `GraspType(..)`).

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/NativeTypes.hs test/NativeTypesSpec.hs
git commit -m "feat: add GraspChan ADT, type discrimination, mkChan, toChan"
```

---

### Task 2: Add channel primitives and `spawn`

**Files:**
- Modify: `src/Grasp/Eval.hs`
- Modify: `src/Grasp/Printer.hs`
- Modify: `test/EvalSpec.hs`

**Step 1: Write failing tests**

Add to `test/EvalSpec.hs`:

```haskell
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
      -- Give the spawned thread a moment to run
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
```

Add this import at the top of `EvalSpec.hs`:

```haskell
import Control.Concurrent (threadDelay)
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test 2>&1 | tail -20`

Expected: Tests fail — `spawn`, `make-chan`, `chan-put`, `chan-get` not defined as primitives.

**Step 3: Implement**

In `src/Grasp/Printer.hs`, add to the `graspTypeOf` dispatch (after GTMacro):

```haskell
  GTChan      -> "<chan>"
```

In `src/Grasp/Eval.hs`:

1. Add to module export list:

```haskell
module Grasp.Eval
  ( eval
  , defaultEnv
  , anyToExpr
  , apply
  ) where
```

2. Add imports at the top:

```haskell
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (newChan, writeChan, readChan)
import Control.Exception (SomeException, catch)
import Control.Monad (void)
```

3. Add 4 primitives to `defaultEnv` bindings (after `null?`):

```haskell
        , ("spawn", mkPrim "spawn" spawnOp)
        , ("make-chan", mkPrim "make-chan" makeChanOp)
        , ("chan-put", mkPrim "chan-put" chanPutOp)
        , ("chan-get", mkPrim "chan-get" chanGetOp)
```

4. Add primitive implementations (after `nullOp`):

```haskell
spawnOp :: [Any] -> IO Any
spawnOp [f] = do
  _ <- forkIO $ void (apply f []) `catch` \(_ :: SomeException) -> pure ()
  pure mkNil
spawnOp _ = error "spawn expects one argument (a zero-arg function)"

makeChanOp :: [Any] -> IO Any
makeChanOp [] = mkChan <$> newChan
makeChanOp _ = error "make-chan expects no arguments"

chanPutOp :: [Any] -> IO Any
chanPutOp [ch, val] = do
  writeChan (toChan ch) val
  pure mkNil
chanPutOp _ = error "chan-put expects two arguments (channel, value)"

chanGetOp :: [Any] -> IO Any
chanGetOp [ch] = readChan (toChan ch)
chanGetOp _ = error "chan-get expects one argument (channel)"
```

**Step 4: Run tests**

Run: `nix develop -c cabal test 2>&1 | tail -10`

Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Grasp/Eval.hs src/Grasp/Printer.hs test/EvalSpec.hs
git commit -m "feat: add spawn, make-chan, chan-put, chan-get primitives"
```

---

### Task 3: Update documentation

**Files:**
- Modify: `docs/language.md`
- Modify: `docs/roadmap.md`
- Modify: `docs/architecture.md`

**Step 1: Update `language.md`**

Add a "Concurrency" section after "Macros" (before "Evaluation Model"):

```markdown
## Concurrency

Grasp provides green threads and channels for concurrent programming. Threads are real GHC green threads scheduled by GHC's native scheduler.

### `spawn`

Spawns a new green thread running the given zero-argument function:

\`\`\`lisp
(spawn (lambda () (+ 1 2)))  ; runs in background, returns ()
\`\`\`

`spawn` returns `()` immediately. The spawned thread runs concurrently. Exceptions in spawned threads are silently caught — use channels to communicate results or errors back.

### `make-chan`, `chan-put`, `chan-get`

Channels provide typed, blocking communication between threads:

\`\`\`lisp
(define ch (make-chan))
(spawn (lambda () (chan-put ch (* 6 7))))
(chan-get ch)  ; => 42 (blocks until value is available)
\`\`\`

| Function | Signature | Description |
|----------|-----------|-------------|
| `make-chan` | `() -> Chan` | Create a new channel |
| `chan-put` | `Chan -> a -> ()` | Write a value to the channel |
| `chan-get` | `Chan -> a` | Read a value (blocks until available) |

A channel value prints as `<chan>`.
```

Add `GraspChan` to the types table:

```markdown
| `GraspChan` | Channel | `<chan>` |
```

**Step 2: Update `roadmap.md`**

Mark Phase 4 as complete, update status line and test count.

**Step 3: Update `architecture.md`**

Add `GraspChan` to the NativeTypes ADT list. Add `spawn` to the Eval primitives description. Note that `apply` is now exported.

**Step 4: Commit**

```bash
git add docs/language.md docs/roadmap.md docs/architecture.md
git commit -m "docs: update for concurrency"
```
