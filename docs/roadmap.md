# Roadmap

Grasp's MVP demonstrates that a dynamic Lisp can construct closures on GHC's heap and evaluate them through the STG machine. This page outlines where the project goes from here.

## Current Status: MVP + Safe Interop

What works:
- S-expression parser (integers, strings, booleans, symbols, lists, quoting)
- Tree-walking evaluator (define, lambda, if, quote, closures)
- 12 built-in primitives (arithmetic, comparison, list operations)
- C bridge to GHC RTS (`rts_apply`, `rts_mkInt`, `rts_getInt`)
- **`hs:` syntax** for calling Haskell functions: `(hs:succ 41)` → `42`
- **Type-safe function registry** with arity and type validation at the Grasp-Haskell boundary
- **Safe evaluation** — Haskell exceptions are caught, not process-aborting
- Legacy `haskell-call` backward compatibility
- REPL with error recovery
- 48 tests passing

What the MVP proves: you can use the RTS C API to construct values on GHC's heap, apply Haskell functions to them, evaluate the result safely, and extract the answer — all from a dynamic language with no compilation step.

## Phase 1: Native STG Closures

**Goal**: Grasp values ARE STG closures, not Haskell ADTs.

Currently, a Grasp integer like `42` is represented as `LInt 42` — a Haskell data constructor. This works, but it's still a Haskell value that happens to represent a Lisp integer.

In Phase 1, Grasp would construct its own closures on the GHC heap using `allocate()` from the RTS, writing info pointers and payloads directly. A Grasp integer would be an `StgClosure` with a custom info table — indistinguishable from a GHC-compiled boxed `Int`.

This requires:
- Writing custom info tables in C (or generating them)
- Using `allocate(cap, n)` to allocate raw closure space
- Using `SET_HDR(closure, info_ptr, ccs)` to set the info pointer
- Ensuring the GC can trace these closures (correct pointer/non-pointer layout in the info table)

This is the critical step toward "native tenant" status. Once Grasp values are raw closures, they can be passed to Haskell functions without any marshaling.

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
