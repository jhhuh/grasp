# Concurrency — Design

## Goal

Add green thread spawning and channel-based communication to Grasp, using
GHC's native `forkIO` and `Chan`. Spawned threads are real GHC green threads,
scheduled by the same scheduler that runs Haskell threads.

## Architecture

Four new primitives (`spawn`, `make-chan`, `chan-put`, `chan-get`) and one new
ADT (`GraspChan`). No special forms. Threads are fire-and-forget — no thread
ID tracking, no join, no kill. Communication happens through explicit channels.

### Primitives

| Primitive | Args | Returns | Implementation |
|-----------|------|---------|----------------|
| `spawn` | `fn` (zero-arg function) | `()` | `forkIO`, apply fn, catch all exceptions silently |
| `make-chan` | none | Chan | `newChan`, wrap in `GraspChan` |
| `chan-put` | `ch`, `val` | `()` | `writeChan` |
| `chan-get` | `ch` | val | `readChan` (blocks until value available) |

### `GraspChan` ADT

```haskell
data GraspChan = GraspChan (Chan Any)
```

Follows the existing NativeTypes pattern: info pointer sentinel, `GTChan` type
tag, `mkChan`/`toChan` constructor/extractor, `showGraspType GTChan = "Chan"`,
printer output `"<chan>"`.

### Data Flow

```
(define ch (make-chan))
(spawn (lambda () (chan-put ch (* 6 7))))
(chan-get ch)  ; => 42
```

1. `make-chan` creates a `Chan Any`, wraps it as `GraspChan`
2. `spawn` receives a lambda closure (already captures its env)
3. `forkIO` applies the lambda in a new green thread
4. The lambda evaluates `(* 6 7)` and writes `42` to the channel
5. `chan-get` blocks the main thread until the value arrives

### Thread Environment

Lambdas passed to `spawn` already close over their defining environment via
the `Env` (IORef) captured at lambda creation time. No special env copying
is needed — the lambda's closure IS the thread's environment.

Since `Env = IORef EnvData` and `define` uses `modifyIORef'`, concurrent
definitions from parent and child threads that share the same IORef are
atomic per-operation. For true isolation, users create lambdas in a local
scope (which creates a child env via the lambda mechanism).

### Error Handling

Exceptions in spawned threads are caught and silently discarded:

```haskell
forkIO $ void (apply f []) `catch` \(_ :: SomeException) -> pure ()
```

This prevents a crashed thread from bringing down the REPL. There is no
mechanism to observe thread failures — this is intentional for the minimal
implementation. Users who need error reporting can catch errors in the lambda
body and send them through a channel.

### REPL

No changes. Spawned threads run silently. Output from threads (if any) goes
to stdout unsynchronized — this is acceptable for the minimal implementation.

### Printing

`GTChan -> "<chan>"`

A channel value prints as `<chan>` without revealing contents.

## What's NOT Included

- **Thread IDs** — `spawn` returns `()`, not a `ThreadId`. Add later if
  `thread-wait` or `thread-kill` is needed.
- **STM / TVar** — deferred to a future phase.
- **MVar** — channels cover the communication use case. MVars add
  complexity without clear benefit at this stage.
- **Synchronized output** — threads can interleave stdout. Not worth the
  infrastructure for fire-and-forget semantics.
- **Thread-safe env** — no TVar conversion. IORef is sufficient given
  that lambdas create child environments naturally.

## `apply` Export

The `spawn` primitive needs to call `apply` (currently internal to `Eval.hs`).
`apply` will be added to the `Grasp.Eval` export list.

## Files Changed

| Module | Status | Changes |
|--------|--------|---------|
| `Grasp.NativeTypes` | MODIFY | Add `GraspChan`, `GTChan`, info ptr, mkChan, toChan |
| `Grasp.Eval` | MODIFY | Add 4 primitives to defaultEnv, export `apply` |
| `Grasp.Printer` | MODIFY | Add `GTChan -> "<chan>"` |
| Test files | MODIFY | Add concurrency + channel tests |

## Dependencies

- `Control.Concurrent` (forkIO) — already available via `base`
- `Control.Concurrent.Chan` — already available via `base`
- `Control.Exception` (catch, SomeException) — already used in Main.hs
- `Control.Monad` (void) — already available via `base`

No new package dependencies.
