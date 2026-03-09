# Phase 9: Unified Quoter System & STM

## Thesis

Grasp already has implicit quoters — `quote`, `lazy`, `lambda`, `with-handler` —
each suspending evaluation in a different context. Phase 9 makes this pattern
explicit with a unified quoter syntax `(name| body |)`, and introduces STM as
the first new quoter. This surfaces GHC's STM runtime as a native Grasp feature,
and establishes the foundation for extensible evaluation contexts.

## The Quoter Model

### Core Insight

A **quoter** is a triple: (name, binding form, composition mode). It creates a
first-class opaque value representing a suspended computation in a named context.

```
(name| (bindings...) body |)
```

- **name** — selects the evaluation context (STM, lazy, quote, etc.)
- **bindings** — values captured from the outer context (like lambda parameters)
- **body** — evaluated in the named context when the value is "run"

A quoter with no bindings can omit the binding list:

```lisp
(stm| (tvar-set! x 42) |)           ;; closed — no outer deps
(stm| ((v ,(read-file "f")))
  (tvar-set! x v) |)                ;; open — v captured from IO
```

### Existing Forms as Sugar

| Sugar | Desugars to | Runner |
|---|---|---|
| `'expr` | `(quote\| expr \|)` | `eval` |
| `` `expr `` | `(quote\| expr \|)` with `,` allowed | `eval` |
| `(lazy expr)` | `(lazy\| expr \|)` | `force` |
| `(with-handler h body)` | `(handled\| (h) body \|)` | implicit |
| — | `(stm\| body \|)` | `grip` |

`lambda` stays as a distinct primitive — it introduces parameter bindings from
the caller, not from an outer evaluation context.

### Antiquoters (Named Escape)

Inside a quoter, `,name(expr)` evaluates `expr` in the context named `name`
and splices the result into the current body:

```lisp
(stm|
  (lazy|
    ,stm(tvar-get x)             ;; evaluate in STM (one level up)
    ,io(read-file "config.txt")  ;; evaluate in IO (two levels up)
  |)
|)
```

Bare `,expr` escapes one level to the parent context.

This mirrors delimited continuations at the syntax level:

| Concept | Runtime | Syntax |
|---|---|---|
| Enter context | `prompt tag` | `(name\| ... \|)` |
| Escape to context | `control0 tag` | `,name(expr)` |
| Run/commit | runner fn | `grip`, `force`, `eval` |

### Binding Form

The binding list declares the context boundary — what crosses from outside
to inside. This makes dependencies explicit:

```lisp
;; Scattered antiquoting (implicit boundary):
(stm| (tvar-set! tv1 ,(read-file "a"))
      (tvar-set! tv2 ,(read-file "b")) |)

;; Binding list (explicit boundary):
(stm| ((a ,(read-file "a"))
       (b ,(read-file "b")))
  (tvar-set! tv1 a)
  (tvar-set! tv2 b) |)
```

Both forms are valid. The binding list is preferred for clarity when multiple
values cross the boundary.

### Composition: Auto-Flatten

When a quoter expression appears inside another of the same type, the inner
block flattens into the outer (monadic bind):

```lisp
;; These are equivalent:
(stm| (stm| (tvar-set! x 1) |)
      (stm| (tvar-set! y 2) |) |)

(stm| (tvar-set! x 1)
      (tvar-set! y 2) |)
```

This means reusable STM procedures compose naturally:

```lisp
(define (transfer from to n)
  (stm| (tvar-set! from (- (tvar-get from) n))
        (tvar-set! to   (+ (tvar-get to)   n)) |))

;; Two transfers in one transaction:
(grip (stm| (transfer a b 100)
            (transfer c d 50) |))
```

## STM Design

### Why STM Distinguishes Grasp

In Clojure, `dosync` + refs are a separate mechanism — `ref-set` is always a
ref operation. You can't take an ordinary function and run it transactionally.

In Grasp, **any lambda is STM-capable by default**. Because `eval` is
polymorphic over IO/STM, the same `(define (transfer ...))` works in IO or
inside `(stm| ... |)`. The evaluator adapts. No annotations, no separate API.

This is the thesis in action: Grasp doesn't just call GHC's STM — it inhabits
it. Procedures are native tenants of both IO and STM.

### Polymorphic Eval via `GraspM`

```haskell
class Monad m => GraspM m where
  liftG   :: IO a -> m a
  readTV  :: TVar a -> m a
  writeTV :: TVar a -> a -> m ()
  newTV   :: a -> m (TVar a)

instance GraspM IO where
  liftG   = id
  readTV  = readTVarIO
  writeTV tv v = atomically (writeTVar tv v)
  newTV   = newTVarIO

instance GraspM STM where
  liftG   = unsafeIOToSTM
  readTV  = readTVar
  writeTV = writeTVar
  newTV   = newTVar
```

Key signatures:

```haskell
eval  :: GraspM m => Env -> LispExpr -> m GraspVal
apply :: GraspM m => Any -> [Any]    -> m Any
```

IORef operations in eval (`readIORef env`, `modifyIORef' env`) go through
`liftG` — safe because env reads are idempotent and in-memory.

### `unsafeIOToSTM` Safety Argument

Environment bindings (IORef contents) are never modified by STM transactions in
a way that conflicts with retry semantics. `define` inside `atomically` writes
to the IORef, but re-running the transaction re-defines (idempotent). Real
danger is non-idempotent IO (network, files) — those should be captured via
antiquoter bindings, not run inside STM.

### Primitives

**New NativeType:**

```haskell
data GraspTVar = GraspTVar (TVar Any)
-- GTTVar type tag, "<tvar>" in printer
```

**New eval clauses:**

| Form | Semantics |
|---|---|
| `(new-tvar val)` | Create TVar, works in IO and STM |
| `(tvar-get tv)` | Read TVar via `readTV` |
| `(tvar-set! tv val)` | Write TVar via `writeTV` |
| `(grip expr)` | `atomically (eval @STM)` — commit transaction |
| `(stm-retry)` | `retry` — block until TVar changes |
| `(stm-or tx1 tx2)` | `orElse` — try tx1, on retry try tx2 |

**`grip` implementation:**

```haskell
eval env (SList [SAtom "grip", expr]) = do
  action <- eval env expr   -- evaluate to get STM action value
  -- extract env and body from the action, run in STM:
  liftG $ atomically (evalSTMAction action)
```

### User-Facing API

```lisp
;; Create TVars
(define counter (new-tvar 0))
(define balance (new-tvar 1000))

;; Read/write (outside STM — individual operations)
(tvar-get counter)       ;; => 0
(tvar-set! counter 42)

;; Atomic transaction
(grip (stm| (tvar-set! counter (+ (tvar-get counter) 1)) |))

;; Reusable STM procedure
(define (withdraw tv n)
  (stm|
    (let ((b (tvar-get tv)))
      (if (< b n)
        (stm-retry)                ;; block until balance changes
        (tvar-set! tv (- b n)))) |))

;; Compose transactions
(grip (stm| (withdraw balance 100)
            (tvar-set! counter (+ (tvar-get counter) 1)) |))

;; orElse: try primary, fall back to secondary
(grip (stm-or (withdraw checking 100)
              (withdraw savings 100)))

;; Antiquote: capture IO value into STM
(grip (stm| ((config ,(read-file "rates.txt")))
  (tvar-set! rate-tv config) |))

;; Concurrent correctness
(define c (new-tvar 0))
(spawn (lambda () (grip (stm| (tvar-set! c (+ (tvar-get c) 1)) |))))
(spawn (lambda () (grip (stm| (tvar-set! c (+ (tvar-get c) 1)) |))))
;; Both complete: (tvar-get c) => 2
```

## Implementation Scope

### What Changes

| Component | Change |
|---|---|
| Parser (megaparsec) | Add `(name\| ... \|)` syntax, antiquoter `,name(expr)` |
| AST (`LispExpr`) | Add `SQuoter Text [(Text, LispExpr)] [LispExpr]` node |
| NativeTypes | Add `GraspTVar`, `GraspSTMAction`, `GTTVar`, `GTSTMAction` |
| Eval.hs | Generalize to `GraspM m =>`, add TVar/grip/stm-retry/stm-or clauses |
| New module | `Grasp.GraspM` — typeclass + instances |
| Printer | Add `GTTVar -> "<tvar>"`, `GTSTMAction -> "<stm>"` |
| grasp.cabal | Add `stm` to build-depends (likely already transitive) |

### What Doesn't Change

- `Env = IORef EnvData` — stays as IORef, accessed via `liftG`
- `Continuations.hs` — IO actions, called via `liftG`
- `lambda`, `define`, `if`, etc. — work unchanged, just polymorphic now
- Existing tests — must all pass (polymorphic eval is transparent)

### Parser Design

```
(name| body |)        →  SQuoter "name" [] [body]
(name| (binds) body |) → SQuoter "name" binds [body]
,name(expr)           →  SAntiquote "name" expr
,expr                 →  SAntiquote "" expr   (escape one level)
```

The parser recognizes `identifier|` immediately after `(` as a quoter open.
`|)` closes it. Inside, `,` followed by `identifier(` is a named antiquote.

### Desugar Existing Forms

Phase 9 introduces the quoter syntax and STM. Desugaring existing forms
(`lazy`, `quote`) into quoters is a follow-up — the infrastructure supports
it but the sugar remains for backward compatibility.

## Test Plan

1. `new-tvar`, `tvar-get`, `tvar-set!` — basic operations
2. `grip` runs STM action and returns result
3. `(stm| ... |)` creates first-class STM action
4. Auto-flatten: nested `(stm| ... |)` compose into one transaction
5. Antiquoter: `,expr` and `,io(expr)` capture outer values
6. Binding form: `(stm| ((x ,io(expr))) body |)` binds correctly
7. `stm-retry` blocks until TVar changes (concurrent test with `spawn`)
8. `stm-or` tries alternative on retry
9. Concurrent increments via `spawn` + `grip` produce correct result
10. `type-of` returns `"tvar"` for TVars, `"stm"` for STM actions
11. All 223 existing tests still pass
12. Reusable STM procedures (define + call inside `stm|`)

## Future Work (Not Phase 9)

- **Protocols/interfaces** — formalize the quoter contract as a Grasp-level feature
- **First-class types** — `(t| Int -> Int |)` as typed quoter with custom parser
- **Extensible quoters** — user-defined `(name| ... |)` via protocol implementation
- **Desugar existing forms** — `lazy`, `quote`, `with-handler` as quoter sugar
- **`lambda` as quoter** — investigate whether binder quoters are a coherent concept
