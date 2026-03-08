# Phase 8: Conditions, Pattern Matching, REPL, Debugging — Design

## Goal

Four feature areas that deepen Grasp as a language and showcase the STG machine:
a delimited-continuation-based condition system, pattern matching with `apply`,
an isocline-powered REPL, and heap introspection tools.

## Feature 1: Condition System (with-handler / signal)

### Lisp-level forms

```lisp
;; Establish a handler
(with-handler
  (lambda (condition restart)
    ;; condition: the signaled value
    ;; restart: a function — calling it resumes from the signal point
    (if (= condition 'division-by-zero)
      (restart 0)        ;; (signal ...) returns 0, body continues
      condition))        ;; don't restart, with-handler returns this
  body)

;; Signal a condition (captures continuation via control0#)
(signal value)
```

### Semantics

1. `with-handler handler body` — creates a `PromptTag#`, pushes it onto a
   global handler stack (`IORef`), runs `body` inside `prompt#`. On normal
   completion, returns body's value.
2. `signal value` — reads the top tag from the global stack, calls `control0#`
   to capture the continuation, wraps the continuation as a Grasp lambda
   (`restart`), calls the handler with `(value, restart)`.
3. If the handler calls `(restart v)`, the captured continuation resumes —
   `(signal ...)` returns `v` and the body continues.
4. If the handler returns without calling restart, `with-handler` returns the
   handler's return value (body is abandoned).
5. Haskell `error` calls are also caught (via `catch SomeException` around
   the `prompt#` call). Handler gets `(error-message-string, non-resumable-restart)`.
   The non-resumable restart errors if called.

### try/catch as prelude functions

```lisp
(define try (lambda (thunk)
  (with-handler (lambda (c r) (list 'error c)) (thunk))))

(define catch (lambda (thunk handler)
  (with-handler (lambda (c r) (handler c r)) (thunk))))
```

### Implementation

- **Mechanism**: GHC's delimited continuation primops (`newPromptTag#`,
  `prompt#`, `control0#` from `GHC.Exts`). Available in GHC 9.6+.
- **New module**: `Grasp.Continuations` — IO-level wrappers around the unboxed
  primops. Provides `newPromptTag`, `prompt`, `control0` as regular IO functions.
- **Dynamic scoping**: A global `handlerStack :: IORef [Any]` holds boxed
  `PromptTag#` values. `with-handler` pushes, `signal` reads the top.
  This gives dynamic (call-stack) scoping — signals propagate to the nearest
  handler on the call stack, not the lexical scope.
- **New ADT**: `GraspPromptTag` in NativeTypes for boxing the unlifted
  `PromptTag#`.
- **Restart function**: The captured continuation (from `control0#`) is wrapped
  as a `GraspPrim` that, when called with a value, invokes the continuation.
- **Two new eval clauses**: `with-handler` and `signal` in Eval.hs.

### Why delimited continuations (not exceptions)

The condition system uses GHC's native continuation primitives rather than
exception-based control flow. This is more novel and aligns with the project
thesis — Grasp uses the STG machine's own mechanisms. The captured continuation
is a real GHC closure on the heap, traced by GHC's GC. Resuming it re-enters
the STG machine's evaluation at the exact point where the signal was raised.

## Feature 2: Pattern Matching + Apply

### `apply`

```lisp
(apply + (list 1 2 3))    ;; => 6
(apply f args)             ;; call f with args from a list
```

The internal `apply :: Any -> [Any] -> IO Any` already exists. New primitive
in `defaultEnv` that converts a Grasp list to `[Any]` and calls it.

### `match`

```lisp
(match expr
  (0 "zero")                          ;; literal match
  ((cons h t) (list 'head h))         ;; destructure cons
  (() "empty")                        ;; nil match
  (#t "true")                         ;; boolean match
  (x (list 'other x)))               ;; variable bind (catchall)
```

**Pattern language:**
- Literal: `0`, `"hello"`, `#t`, `#f` — match by equality
- `()` — match nil
- `(cons head tail)` — destructure a cons cell, bind `head` and `tail`
- `_` — wildcard (match anything, don't bind)
- Bare symbol — bind the value to this name (catchall)
- No nested patterns initially (YAGNI)

**Semantics:**
1. Evaluate the scrutinee once
2. Try each clause top-to-bottom
3. First matching pattern: bind variables in a child env, evaluate the body
4. No match: error

**Implementation**: A `matchPattern :: Any -> LispExpr -> Maybe (Map Text Any)`
function that returns bindings on match. The `match` eval clause iterates
clauses, calling `matchPattern` until one succeeds.

## Feature 3: REPL with isocline

Replace the manual `getLine` REPL with [isocline](https://hackage.haskell.org/package/isocline)
— a portable readline alternative bundled as a single C file with zero runtime
dependencies.

**Key API:**
```haskell
readline :: String -> IO String
readlineEx :: String -> Maybe completer -> Maybe highlighter -> IO String
setHistory :: FilePath -> Int -> IO ()
setPromptMarker :: String -> String -> IO ()
```

**Features:**
- **Line editing** — arrow keys, ctrl-a/e/k, undo/redo (built-in)
- **History** — persisted to `~/.grasp_history`, auto-managed
- **Multi-line** — `setPromptMarker "λ> " ".. "`, paren-balancing drives
  continuation (count open/close parens; if unbalanced, isocline continues
  reading on the next line)
- **Tab completion** — `readlineEx` with a completer that reads env bindings
  from the `IORef`, includes built-ins and `hs:` prefix
- **No Haskell deps** — isocline bundles its C library

**Changes:**
- Add `isocline` to cabal `build-depends`
- Add `isocline` to flake.nix
- Rewrite `repl` in Main.hs using `readlineEx`

## Feature 4: Debugging / Heap Tools

New primitives for runtime introspection:

```lisp
(type-of 42)              ;; => "Int"
(type-of (lambda (x) x))  ;; => "Lambda"

(inspect x)               ;; => (list 'type "Cons" 'pointers 2 'fields 0)
                           ;; uses unpackClosure# payload counts

(gc-stats)                 ;; => (list 'collections 5 'bytes-allocated 1048576 ...)
                           ;; reads GHC.Stats.getRTSStats
```

- **`type-of`** — calls `graspTypeOf`, returns the type name as a string
- **`inspect`** — calls `unpackClosure#`, returns info pointer address,
  number of pointer fields, number of non-pointer fields as a Grasp list
- **`gc-stats`** — calls `GHC.Stats.getRTSStats`, returns key metrics as
  a Grasp association list

Read-only introspection. No new ADTs needed — returns existing Grasp types
(strings, ints, lists).

## Ordering

1. `apply` (trivial, no dependencies)
2. Condition system (core feature, most complex)
3. Pattern matching (complements conditions)
4. REPL improvements (independent, quality-of-life)
5. Debugging tools (independent, showcase)

## Files Changed

| Module | Changes |
|--------|---------|
| `Grasp.Continuations` | New: IO wrappers for `prompt#`/`control0#`, global handler stack |
| `Grasp.NativeTypes` | Add `GraspPromptTag` ADT (box PromptTag#) |
| `Grasp.Eval` | Add `with-handler`, `signal`, `match` special forms; `apply`, `type-of`, `inspect`, `gc-stats` primitives |
| `Grasp.Printer` | Add `GTPromptTag` case |
| `Main.hs` | Rewrite REPL with isocline |
| `grasp.cabal` | Add `isocline` dependency, `Grasp.Continuations` module |
| `flake.nix` | Add `isocline` to build inputs |
| `lib/prelude.gsp` | Add `try`, `catch` functions |
| Test files | Tests for all new features |

## Dependencies

- `isocline` — readline alternative (C library bundled, no runtime deps)
- `GHC.Stats` — already in `base`
- `GHC.Exts` (`PromptTag#`, `prompt#`, `control0#`) — already in `ghc-prim`
