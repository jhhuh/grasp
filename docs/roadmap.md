# Roadmap

Grasp's MVP demonstrates that a dynamic Lisp can construct closures on GHC's heap and evaluate them through the STG machine. This page outlines where the project goes from here.

## Current Status: Phase 8 Complete (Conditions, Pattern Matching, REPL, Debugging)

What works:
- S-expression parser (integers, strings, booleans, symbols, lists, quoting)
- Tree-walking evaluator (define, lambda, if, quote, begin, let, loop/recur, match, closures)
- 22 built-in primitives (arithmetic, comparison, list operations, apply, debugging)
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
- **isocline REPL** — line editing, persistent history, tab completion of env bindings
- **`defmacro`** — user-defined macros that receive unevaluated arguments as quoted data, return code for re-evaluation
- **`spawn`** — green threads via `forkIO`, channels via `Chan` for inter-thread communication
- **`module` / `import`** — file-based module system with qualified access, caching, and circular dependency detection
- **`begin` / `let`** — sequential evaluation and sequential let-bindings with implicit begin
- **Multi-expression lambda** — lambda bodies support multiple expressions via implicit begin
- **`loop` / `recur`** — Clojure-style explicit tail recursion with `GraspRecur` sentinel
- **`with-handler` / `signal`** — delimited-continuation condition system using GHC's `prompt#`/`control0#`
- **`match`** — structural pattern matching with literal, cons, nil, wildcard, and variable patterns
- **`apply`** — call a function with a list of arguments
- **`type-of` / `inspect` / `gc-stats`** — runtime introspection and GC statistics
- **File execution** — `cabal run grasp -- file.gsp` runs a script, prints the last result
- **Standard library** — `lib/prelude.gsp` with map, filter, fold, try, catch, etc.
- ~223 tests passing

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

## Phase 6: Module System ✓

**Status**: Complete.

`(module name (export sym...) body...)` defines modules with explicit exports. `(import name)` loads module files (`.gsp`) with caching and circular dependency detection. Qualified access via dot notation (`math.square`) splits symbols at eval time.

```lisp
;; math.gsp
(module math
  (export square cube)
  (define square (lambda (x) (* x x)))
  (define cube (lambda (x) (* x (square x)))))
```

```lisp
(import math)
(square 5)       ; => 25
(math.square 5)  ; => 25 (qualified)
```

Modules evaluate their bodies in a child environment inheriting primitives. Only exported symbols are accessible. Import binds exports both qualified and unqualified. The `GraspModule` ADT uses the same info-pointer type discrimination as all other Grasp types.

## Phase 7: Control Flow & Standard Library ✓

**Status**: Complete (2026-03-08). ~196 tests.

Added essential control flow constructs and a standard library:

- **`begin`** — `(begin e1 e2 ... en)` evaluates forms sequentially, returns the last result. `(begin)` returns nil.
- **`let`** — `(let ((x 1) (y 2)) body...)` creates sequential bindings (like Scheme's `let*`). Later bindings can reference earlier ones. Body uses implicit begin.
- **Multi-expression lambda** — `(lambda (params) e1 e2 ... en)` wraps multiple body forms in an implicit `begin`.
- **`loop` / `recur`** — Clojure-style explicit tail recursion. `loop` establishes bindings and a restart point; `recur` re-binds and jumps back. Implemented via the `GraspRecur` sentinel ADT — `recur` returns a `GraspRecur` value, and `loop`'s iteration checks for `GTRecur` to decide whether to re-bind and continue or return.
- **File execution** — `cabal run grasp -- file.gsp` parses and evaluates a `.gsp` file, printing the last result. Dispatched via `getArgs` in `Main.hs`.
- **Standard library** — `lib/prelude.gsp` provides common list utilities (map, filter, fold, length, append, etc.) implemented in Grasp itself using `loop`/`recur`.

```lisp
(loop ((i 0) (sum 0))
  (if (> i 10)
    sum
    (recur (+ i 1) (+ sum i))))   ; => 55
```

## Phase 8: Conditions, Pattern Matching, REPL, Debugging ✓

**Status**: Complete (2026-03-08). ~223 tests.

Four feature areas that deepen Grasp as a language and showcase the STG machine:

- **Condition system** — `(with-handler handler body)` and `(signal value)` using GHC's delimited continuation primops (`prompt#`, `control0#`). The handler receives the signaled value and a restart function. Calling restart resumes from the signal point; returning without restart abandons the body. Haskell exceptions (`error`) are also caught and forwarded to the handler.
- **Pattern matching** — `(match expr (pattern body) ...)` with integer/string/boolean literals, nil `()`, cons destructuring `(cons h t)`, wildcard `_`, and variable binding. Clauses are tried top-to-bottom.
- **`apply`** — `(apply f (list 1 2 3))` calls a function with arguments from a list.
- **isocline REPL** — line editing, persistent history (`.grasp_history`), tab completion of env bindings. Replaces the raw `getLine` REPL.
- **Debugging primitives** — `(type-of x)` returns the type name, `(inspect x)` returns closure payload info via `unpackClosure#`, `(gc-stats)` reads `GHC.Stats.getRTSStats`.
- **Prelude additions** — `try` and `catch` as condition system wrappers.

```lisp
;; Condition system
(with-handler
  (lambda (c r) (r 0))           ; restart with 0
  (+ 1 (signal 'division-by-zero)))  ; => 1

;; Pattern matching
(match (list 1 2 3)
  (() "empty")
  ((cons h t) h))               ; => 1
```

## Future Possibilities

These are more speculative directions:

- **JIT compilation**: Compile hot Grasp functions to native code through GHC's code generator
- **Type annotations**: Optional type hints that generate STG closures matching Haskell types
- **Package integration**: Load compiled Haskell packages (`.hi` + `.o` files) and call their functions
- **Editor integration**: SLIME/CIDER-style interactive development with an Emacs or VS Code extension
