# Opt-in Laziness — Design

## Goal

Add `(lazy expr)` and `(force x)` forms that create real GHC THUNK closures on
the heap. Thunks participate in GHC's standard update mechanism: first force
evaluates and replaces the thunk with an indirection (IND); subsequent accesses
return the cached value instantly.

## Architecture

Grasp is strict by default. `(lazy expr)` defers evaluation by wrapping the
computation in a GHC thunk via `unsafeInterleaveIO`. The thunk is stored in a
`GraspLazy` ADT wrapper so `graspTypeOf` can discriminate it. Primitives and
Haskell interop auto-force lazy arguments at their boundaries.

### Why `unsafeInterleaveIO`

Research into three approaches:

1. **Custom C info tables** — Requires Cmm (GHC's assembly language) because
   `TABLES_NEXT_TO_CODE` on x86-64 means the info pointer IS the code address.
   C compilers can't guarantee struct-code adjacency. Fragile across GHC versions.

2. **`rts_apply` chain from C** — Builds AP thunks using GHC's `stg_ap_N_upd_info`.
   Works, but requires StablePtr management and packaging the evaluator as a C
   callback.

3. **`unsafeInterleaveIO`** — Creates real GHC THUNK closures via the standard
   `let r = ...` binding in `unsafeDupableInterleaveIO`. Same mechanism Haskell's
   lazy I/O has used for 25 years. Participates in the standard update cycle
   (THUNK → BLACKHOLE → IND). Zero C code.

Approach 3 is correct: it gives real GHC thunks with automatic memoization,
is GC-safe, and requires no knowledge of info table layouts.

## Syntax

```lisp
(lazy expr)   ; creates a THUNK — does NOT evaluate expr
(force x)     ; enters the thunk, triggers update (THUNK → IND)
```

## Thunk Representation

```haskell
data GraspLazy = GraspLazy Any  -- lazy field: holds a GHC THUNK
```

The field MUST be lazy (no `!` bang). Storing an `unsafeInterleaveIO` result in
a lazy field preserves the thunk. A strict field would force it immediately.

`GraspLazy` is a Grasp ADT like `GraspCons` or `GraspLambda`. GHC generates
its info table automatically. `graspTypeOf` discriminates it via the cached
info pointer, returning `GTLazy`.

## Creating Thunks

```haskell
eval env (EList [ESym "lazy", body]) = do
  thunk <- unsafeInterleaveIO (eval env body)
  pure (mkLazy (unsafeCoerce thunk))
```

`unsafeInterleaveIO` defers `eval env body` into a real GHC THUNK. The thunk
is wrapped in `GraspLazy` so `graspTypeOf` can identify it. The thunk captures
`env` and `body` as free variables in its closure.

## Forcing Thunks

```haskell
forceLazy :: Any -> IO Any
forceLazy v = let GraspLazy inner = unsafeCoerce v in inner `seq` pure inner
```

`seq` enters the closure. If it's a thunk, GHC's scheduler:
1. Pushes an update frame
2. Replaces the thunk with BLACKHOLE (prevents double-evaluation)
3. Runs the deferred computation
4. Replaces the BLACKHOLE with IND pointing to the result
5. Returns the result

Second `force` on the same value follows the indirection directly to the cached
result — O(1).

## Auto-Forcing at Boundaries

Primitives and Haskell interop auto-force lazy arguments:

```haskell
forceIfLazy :: Any -> IO Any
forceIfLazy v = case graspTypeOf v of
  GTLazy -> forceLazy v
  _      -> pure v
```

Inserted before:
- Arithmetic and comparison (before `toInt`)
- List operations (before `isCons`/`isNil` checks)
- Function application (before `graspTypeOf` dispatch in `apply`)
- Haskell interop marshaling (before `marshalGraspToHaskell`)

This means lazy values are transparent to most code:

```lisp
(+ (lazy 10) (lazy 20))     ; => 30 (auto-forced)
(hs:succ (lazy 41))          ; => 42 (auto-forced)
```

`(force x)` is only needed when you want to control evaluation timing or
verify that a value has been computed.

## Printing

```haskell
GTLazy -> "<lazy>"
```

A lazy value prints as `<lazy>` without forcing it. To see the value, force
first: `(force x)`.

## Error Handling

If the deferred expression throws, the exception propagates through `force`
(or through auto-force at a boundary). The REPL catches it as usual. GHC's
blackhole mechanism handles the thunk state: on exception, the thunk reverts
from BLACKHOLE so it can be retried.

## Files Changed

| Module | Status | Changes |
|--------|--------|---------|
| `Grasp.NativeTypes` | MODIFY | Add `GraspLazy`, `GTLazy`, info ptr, mkLazy, forceLazy, forceIfLazy |
| `Grasp.Eval` | MODIFY | Add `lazy` and `force` special forms, auto-force in primitives and apply |
| `Grasp.Printer` | MODIFY | Add `GTLazy -> "<lazy>"` |
| `Grasp.DynDispatch` | MODIFY | Add forceIfLazy before marshaling |
| Test files | MODIFY | Add laziness tests |

## Dependencies

No new dependencies. `unsafeInterleaveIO` is in `System.IO.Unsafe` (base).

## Risk: `unsafeInterleaveIO` safety

`unsafeInterleaveIO` is "unsafe" because the IO side effects happen at
unpredictable times (when the thunk is first demanded). For Grasp, this is
exactly the desired behavior — the user explicitly opted into lazy evaluation
with `(lazy ...)`. The combination with `noDuplicate` (via `unsafeInterleaveIO`
vs `unsafeDupableInterleaveIO`) prevents double-evaluation in concurrent
scenarios.
