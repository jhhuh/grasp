# Roadmap

Grasp's MVP demonstrates that a dynamic Lisp can construct closures on GHC's heap and evaluate them through the STG machine. This page outlines where the project goes from here.

## Current Status: Phase 2 Complete (Dynamic Function Lookup)

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
- Legacy `haskell-call` backward compatibility
- REPL with error recovery
- 99 tests passing

What the project proves: a dynamic Lisp can inhabit GHC's heap as a native tenant and call arbitrary Haskell functions at runtime. Grasp integers ARE `I#` closures, booleans ARE `True`/`False`, and the GHC API compiles Haskell expressions to closures on the same heap.

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

## Phase 3: Opt-in Laziness

**Goal**: Grasp expressions can be lazy, using real GHC thunks.

Grasp is strict by default, but some expressions could be lazily evaluated using GHC's own thunk mechanism:

```lisp
(define xs (lazy (expensive-computation)))  ; creates a THUNK
(force xs)                                   ; evaluates the THUNK via rts_eval
```

The `lazy` form would allocate a `THUNK` closure on the GHC heap with a code pointer that calls back into Grasp's evaluator. When GHC's scheduler forces the thunk, it enters Grasp's evaluation, producing a result that's written back as an STG closure. The thunk then updates itself (becoming an `IND`) so subsequent accesses return the cached result.

This is where the "native tenant" concept gets interesting: GHC's own evaluation mechanism would be forcing Grasp computations, and Grasp's computations would be producing GHC closures.

## Phase 4: Concurrency

**Goal**: Grasp programs can use GHC's green threads and STM.

GHC's RTS provides lightweight threads (created with `forkIO`) and software transactional memory (STM). The RTS C API exposes:

```c
void rts_evalLazyIO(Capability** cap, HaskellObj p, HaskellObj* ret);
```

This would enable:
```lisp
(spawn (lambda () (do-work)))     ; creates a green thread
(with-stm (lambda ()
  (read-tvar x)))                  ; STM transaction
```

Grasp threads would be real GHC threads, scheduled by the same scheduler that runs Haskell threads. They'd share the same heap and GC.

## Phase 5: Macro System

**Goal**: User-defined macros that transform S-expressions before evaluation.

A `defmacro` form that receives unevaluated arguments and returns a transformed expression:

```lisp
(defmacro when (cond body)
  (list 'if cond body '()))

(when (> x 0) (print "positive"))
; expands to: (if (> x 0) (print "positive") ())
```

Since Grasp is a Lisp, macros operate on the same data structures as the rest of the language. Code is data.

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
