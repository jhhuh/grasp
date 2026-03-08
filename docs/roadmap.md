# Roadmap

Grasp's MVP demonstrates that a dynamic Lisp can construct closures on GHC's heap and evaluate them through the STG machine. This page outlines where the project goes from here.

## Current Status: Phase 4 Complete (Concurrency)

What works:
- S-expression parser (integers, strings, booleans, symbols, lists, quoting)
- Tree-walking evaluator (define, lambda, if, quote, closures)
- 12 built-in primitives (arithmetic, comparison, list operations)
- **Native GHC closures** — every runtime value is a real `StgClosure` on the GHC heap (`GraspVal = Any`)
- **Type discrimination via `unpackClosure#`** — reads info-table addresses with zero FFI overhead
- C bridge to GHC RTS (`rts_apply`, `rts_mkInt`, `rts_getInt`)
- **`hs:` syntax** for calling any Haskell function: `(hs:Data.List.sort (list 3 1 2))` → `(1 2 3)`
- **`hs@` syntax** for annotated polymorphic functions: `(hs@ "reverse :: [Int] -> [Int]" (list 1 2 3))`
- **Dynamic GHC API lookup** — auto-infers types for monomorphic functions, caches compiled closures
- **Type-safe function registry** with arity and type validation at the Grasp-Haskell boundary
- **Safe evaluation** — Haskell exceptions are caught, not process-aborting
- **`(lazy expr)` / `(force x)`** — opt-in laziness via real GHC THUNK closures with automatic memoization
- **Auto-forcing** — lazy values are transparently forced at primitive, interop, and control flow boundaries
- Legacy `haskell-call` backward compatibility
- REPL with error recovery
- **`defmacro`** — user-defined macros that receive unevaluated arguments as quoted data, return code for re-evaluation
- **`spawn`** — green threads via `forkIO`, channels via `Chan` for inter-thread communication
- 147 tests passing

What the project proves: a dynamic Lisp can inhabit GHC's heap as a native tenant, call arbitrary Haskell functions, and create real GHC thunks with standard update semantics. Grasp integers ARE `I#` closures, lazy values ARE GHC THUNKs, and the RTS's own evaluation machinery forces them.

## Phase 1: Native STG Closures ✓

**Status**: Complete.

Grasp values ARE STG closures. `GraspVal = Any` from `GHC.Exts` — every runtime value is an untyped pointer to a GHC heap closure:

- GHC-equivalent types (Int, Double, Bool) reuse GHC's own closures directly
- Grasp-specific types (Sym, Str, Cons, Nil, Lambda, Prim) use Haskell ADTs whose info tables GHC generates automatically
- Type discrimination via `unpackClosure#` reading info-table addresses (no FFI round-trip)
- Integer precision changed from arbitrary (`Integer`) to 64-bit fixed-width (`Int`)

The approach uses Haskell ADTs instead of hand-written C info tables, avoiding `TABLES_NEXT_TO_CODE` complexity while achieving the same goal: Grasp values are genuine GHC heap objects traced by the GC with zero marshaling overhead for Haskell interop.

## Phase 2: Dynamic Function Lookup ✓

**Status**: Complete.

Any Haskell function can be called by name at runtime via the GHC API:

- **`hs:` prefix** checks the static registry first (zero overhead), then falls back to GHC API lookup
- **`hs@` form** handles polymorphic functions with explicit type annotations
- The GHC API session is lazy-initialized on first dynamic lookup
- Compiled closures and type info are cached after first call
- Automatic type inference via `exprType` for monomorphic functions
- Grasp↔Haskell marshaling for lists and strings
- Re-boxing of bytecode interpreter values to match statically compiled info tables

```lisp
(hs:Data.List.sort (list 3 1 2))  ; => (1 2 3)
(hs:abs -5)                       ; => 5
(hs@ "reverse :: [Int] -> [Int]" (list 1 2 3))  ; => (3 2 1)
```

## Phase 3: Opt-in Laziness ✓

**Status**: Complete.

`(lazy expr)` creates a real GHC THUNK closure via `unsafeInterleaveIO`. The thunk participates in GHC's standard update mechanism: first force evaluates and replaces the thunk with an indirection (IND); subsequent accesses return the cached value instantly.

```lisp
(define x (lazy (+ 1 2)))  ; x is a THUNK, not 3
(force x)                   ; => 3 (evaluated, result cached)
(+ (lazy 10) (lazy 20))    ; => 30 (auto-forced at primitive boundary)
(hs:succ (lazy 41))         ; => 42 (auto-forced at interop boundary)
```

The `GraspLazy` ADT wrapper provides type discrimination via the info-pointer cache. Lazy values are transparent at all boundaries — primitives, `if`, `=`, and Haskell interop auto-force before operating.

## Phase 4: Concurrency ✓

**Status**: Complete.

`(spawn fn)` forks a green thread via `forkIO`. Channels (`make-chan`, `chan-put`, `chan-get`) provide blocking inter-thread communication. Spawned threads are real GHC green threads scheduled by the same scheduler that runs Haskell threads. They share the same heap and GC.

```lisp
(define ch (make-chan))
(spawn (lambda () (chan-put ch (* 6 7))))
(chan-get ch)  ; => 42
```

Threads are fire-and-forget — exceptions are silently caught. STM/TVar support is deferred to future work.

## Phase 5: Macro System ✓

**Status**: Complete.

`(defmacro name (params) body)` defines user macros that receive unevaluated arguments as quoted runtime values. The macro body runs in the macro's closure environment, and the result is converted back to a `LispExpr` via `anyToExpr` and re-evaluated in the caller's environment.

```lisp
(defmacro when (cond body)
  (list 'if cond body '()))

(when (> x 0) (print "positive"))
; expands to: (if (> x 0) (print "positive") ())
```

Macros compose naturally — a macro can expand into another macro call, which is expanded during eval. The `GraspMacro` ADT mirrors `GraspLambda` and uses the same info-pointer type discrimination.

## Phase 6: Module System

**Goal**: Split Grasp programs across files with a module system.

```lisp
(module math
  (export square cube)

  (define square (lambda (x) (* x x)))
  (define cube (lambda (x) (* x (square x)))))
```

```lisp
(import math)
(square 5)  ; => 25
```

## Future Possibilities

These are more speculative directions:

- **JIT compilation**: Compile hot Grasp functions to native code through GHC's code generator
- **Type annotations**: Optional type hints that generate STG closures matching Haskell types
- **Debugging tools**: Inspect the GHC heap from the REPL — see closures, thunks, GC stats
- **Package integration**: Load compiled Haskell packages (`.hi` + `.o` files) and call their functions
- **Editor integration**: SLIME/CIDER-style interactive development with an Emacs or VS Code extension
