# Roadmap

Grasp's MVP demonstrates that a dynamic Lisp can construct closures on GHC's heap and evaluate them through the STG machine. This page outlines where the project goes from here.

## Current Status: Phase 1 Complete (Native STG Closures)

What works:
- S-expression parser (integers, strings, booleans, symbols, lists, quoting)
- Tree-walking evaluator (define, lambda, if, quote, closures)
- 12 built-in primitives (arithmetic, comparison, list operations)
- **Native GHC closures** — every runtime value is a real `StgClosure` on the GHC heap (`GraspVal = Any`)
- **Type discrimination via `unpackClosure#`** — reads info-table addresses with zero FFI overhead
- C bridge to GHC RTS (`rts_apply`, `rts_mkInt`, `rts_getInt`)
- **`hs:` syntax** for calling Haskell functions: `(hs:succ 41)` → `42`
- **Type-safe function registry** with arity and type validation at the Grasp-Haskell boundary
- **Safe evaluation** — Haskell exceptions are caught, not process-aborting
- Legacy `haskell-call` backward compatibility
- REPL with error recovery
- 77 tests passing

What the project proves: a dynamic Lisp can inhabit GHC's heap as a native tenant — Grasp integers ARE `I#` closures, booleans ARE `True`/`False`, and Grasp-specific types use Haskell ADTs whose info tables GHC generates automatically. Zero marshaling overhead for Haskell interop.

## Phase 1: Native STG Closures ✓

**Status**: Complete.

Grasp values ARE STG closures. `GraspVal = Any` from `GHC.Exts` — every runtime value is an untyped pointer to a GHC heap closure:

- GHC-equivalent types (Int, Double, Bool) reuse GHC's own closures directly
- Grasp-specific types (Sym, Str, Cons, Nil, Lambda, Prim) use Haskell ADTs whose info tables GHC generates automatically
- Type discrimination via `unpackClosure#` reading info-table addresses (no FFI round-trip)
- Integer precision changed from arbitrary (`Integer`) to 64-bit fixed-width (`Int`)

The approach uses Haskell ADTs instead of hand-written C info tables, avoiding `TABLES_NEXT_TO_CODE` complexity while achieving the same goal: Grasp values are genuine GHC heap objects traced by the GC with zero marshaling overhead for Haskell interop.

## Phase 2: Dynamic Function Lookup

**Goal**: Call any Haskell function by name at runtime.

Currently, `hs:` dispatches through a static registry of known functions. Phase 2 would look up Haskell functions dynamically using GHC's linker API:

```c
#include "Rts.h"
#include "Linker.h"

// Look up a symbol in loaded object files
void* lookupSymbol(const char* name);
```

Combined with GHC's symbol naming conventions (Z-encoding), this would let Grasp call any Haskell function that's been compiled and linked into the executable — without enumerating them in advance.

This would enable:
```lisp
(hs:Data.List.sort (list 3 1 2))  ; => (1 2 3)
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
