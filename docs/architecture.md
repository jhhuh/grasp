# Architecture

Grasp is structured as a pipeline: **parser → evaluator → printer**, with a **C bridge** connecting the evaluator to GHC's runtime system.

```
┌──────────────────────────────────────────────┐
│                    REPL                       │
│          read → eval → print → loop          │
└──────┬───────────────┬───────────────┬───────┘
       │               │               │
  ┌────▼────┐   ┌──────▼──────┐  ┌─────▼─────┐
  │ Parser  │   │  Evaluator  │  │  Printer  │
  │ (Mega-  │   │  (Haskell)  │  │           │
  │ parsec) │   └──────┬──────┘  └───────────┘
  └─────────┘          │
                 ┌─────▼──────┐
                 │  Haskell   │
                 │  Interop   │
                 └─────┬──────┘
                       │ StablePtr + FFI
                 ┌─────▼──────┐
                 │  C Bridge  │
                 │ (rts_bridge │
                 │    .c/.h)  │
                 └─────┬──────┘
                       │ rts_apply, rts_eval
                 ┌─────▼──────┐
                 │  GHC RTS   │
                 │ (STG heap, │
                 │  GC, sched)│
                 └────────────┘
```

## Modules

### `Main.hs` — REPL loop

The entry point. Reads a line, parses it, evaluates it, prints the result, and loops. Handles `(quit)` and EOF (Ctrl-D). Catches all exceptions with `SomeException` to prevent crashes.

### `Grasp.Types` — Core type definitions

Defines two type layers:

- **`LispExpr`** — the parser's output. A plain algebraic data type representing S-expression syntax: `EInt`, `EDouble`, `ESym`, `EStr`, `EBool`, `EList`. No closures, no environments — just syntax.

- **`GraspVal = Any`** — the evaluator's output. An untyped pointer to a GHC heap closure. Integers are real `I#` closures, booleans are `True`/`False` static closures, and Grasp-specific types (symbols, strings, cons cells, lambdas, primitives) use Haskell ADTs defined in `Grasp.NativeTypes`.

- **`EnvData`** — contains `envBindings :: Map Text GraspVal` (symbol table), `envHsRegistry :: HsFuncRegistry` (registered Haskell functions with type metadata), `envGhcSession :: IORef (Maybe Any)` (lazy-initialized GHC API session for dynamic lookup, stored as `Any` to avoid circular imports), `envModules :: Map Text GraspVal` (cached loaded modules by name), and `envLoading :: [Text]` (circular dependency detection stack). `Env = IORef EnvData`. New bindings from `define` mutate `envBindings` in place. Lambda closures capture the `Env` reference, inheriting access to the registry, GHC session, and module cache.

The two-type design keeps parsing pure and separates syntax from semantics.

### `Grasp.NativeTypes` — Value representation and type discrimination

Defines the Grasp-specific ADTs (`GraspSym`, `GraspStr`, `GraspCons`, `GraspNil`, `GraspLambda`, `GraspPrim`, `GraspLazy`, `GraspMacro`, `GraspChan`, `GraspModule`) whose info tables GHC generates automatically. Provides:

- **Type discrimination** — `graspTypeOf :: Any -> GraspType` reads the info-table address from a closure header via `unpackClosure#` and compares against cached reference addresses. Zero FFI overhead.
- **Constructors** — `mkInt`, `mkBool`, `mkCons`, `mkLambda`, etc. wrap Haskell values as `Any` via `unsafeCoerce`.
- **Extractors** — `toInt`, `toCar`, `toLambdaParts`, etc. unwrap `Any` back to concrete types.
- **Equality** — `graspEq` performs structural equality with recursive cons comparison, auto-forcing lazy values.
- **Laziness** — `mkLazy`, `forceLazy`, `forceIfLazy` create and enter GHC THUNKs via `unsafeInterleaveIO`.

### `Grasp.Parser` — S-expression parser

Built with [megaparsec](https://hackage.haskell.org/package/megaparsec). Handles:

- **Integers** — `L.signed (pure ()) L.decimal`. The `pure ()` is important: `empty` (the Alternative failure) would make the parser reject negative numbers. `pure ()` consumes nothing, allowing the sign to parse.
- **Doubles** — not yet parsed (planned)
- **Strings** — `"..."` with `L.charLiteral` for escape sequences
- **Booleans** — `#t` and `#f`
- **Symbols** — any sequence of non-reserved characters
- **Lists** — `(...)` containing zero or more expressions
- **Quote** — `'expr` desugars to `(quote expr)` in the parser
- **Comments** — `;` to end of line

Parser precedence in `pExpr`: `pBool | pStr | pQuote | pList | try pInt | pSym`. The `try` on `pInt` is needed because `-foo` should parse as a symbol, not a failed negative number.

### `Grasp.Eval` — Core evaluator

A tree-walking interpreter. `eval :: Env -> LispExpr -> IO GraspVal` pattern-matches on expression constructors:

- **Atoms** — integers, doubles, strings, booleans evaluate to themselves (via `mkInt`, `mkBool`, etc.)
- **Symbols** — looked up in `envBindings`; if not found and contains `.`, splits on first dot and looks up module in `envModules` then export in module's export map; error if unbound
- **`(quote e)`** — converts expression to value without evaluation
- **`(if c t e)`** — evaluates condition (auto-forces lazy values); only `#f` is falsy
- **`(define s e)`** — evaluates `e`, inserts binding into env
- **`(lambda (params) body)`** — creates a `GraspLambda` closure capturing current env
- **`(lazy expr)`** — defers evaluation via `unsafeInterleaveIO`, wraps in `GraspLazy`
- **`(force expr)`** — enters the lazy thunk via `forceIfLazy`; identity on non-lazy values
- **`(defmacro name (params) body)`** — creates a `GraspMacro` and binds it in the environment
- **`(module name (export sym...) body...)`** — creates a `GraspModule`: evaluates body in a child env, validates all exports are defined, stores module in `envModules`
- **`(import name)` / `(import "path")`** — loads a `.gsp` file, parses it with `parseFile`, evaluates the `(module ...)` form, caches in `envModules`, detects circular dependencies via `envLoading`, binds exports both qualified (`mod.sym`) and unqualified
- **`(f args...)`** — evaluates `f`; if macro, quotes args, runs body, converts result via `anyToExpr`, re-evals in caller's env; otherwise evaluates args and calls `apply`

Concurrency primitives (`spawn`, `make-chan`, `chan-put`, `chan-get`) are registered in `defaultEnv` alongside arithmetic and list operations. `spawn` uses `forkIO` to create real GHC green threads. `apply` is exported so `spawn` can invoke it from the primitive.

`apply` dispatches on `graspTypeOf v` (auto-forces lazy functions):
- `GTPrim` — extracts the function via `toPrimFn` and calls it
- `GTLambda` — extracts params/body/closure via `toLambdaParts`, creates child environment with param bindings, evaluates body

The evaluator is strict by default: all arguments are evaluated before `apply`. Primitives auto-force lazy arguments at their boundaries via `forceIfLazy`.

### `Grasp.Printer` — Value pretty-printer

Converts `Any` to `String` via `graspTypeOf` dispatch. The interesting case is cons cells: `printCons` uses `isNil`/`isCons` predicates to walk the cdr chain, printing proper lists as `(1 2 3)` and improper lists as `(1 . 2)`.

### `Grasp.RtsBridge` — FFI bindings

Haskell-side FFI declarations for the C bridge functions. Three FFI imports:

- `c_roundtrip_int` — round-trip test (mkInt + getInt)
- `c_apply_int_int` — **unsafe**: builds thunk and evaluates via `rts_eval` (aborts on exception)
- `c_build_int_app` — **safe**: builds thunk via `rts_apply`, returns `StablePtr` without evaluating

The safe evaluation wrapper `bridgeSafeApplyIntInt` builds the thunk in C, then forces it in Haskell with `try`/`evaluate`:

```haskell
bridgeSafeApplyIntInt :: StablePtr (Int -> Int) -> Int -> IO (Either String Int)
```

Key design choices:

- **`safe` not `unsafe`**: The C functions call `rts_lock()`, which acquires a GHC capability. A `safe` FFI call causes the Haskell thread to release its capability before entering C, so `rts_lock()` can acquire one. An `unsafe` call would deadlock because the calling thread still holds the capability.

- **`Int` not `CInt`**: GHC's `HsInt` is `int64_t` on 64-bit platforms. Haskell's `Int` is the same size. `CInt` is `int32_t` — using it would silently truncate values.

- **Split build/eval**: `rts_eval` aborts the process on unhandled Haskell exceptions. By building the thunk in C and forcing it in Haskell, exceptions are caught safely via `try`.

### `Grasp.HsRegistry` — Type-safe dispatch

Validates arity and argument types before invoking a registered Haskell function. Each `HsFuncEntry` carries `[HsType]` arg types and a return type. On mismatch, produces clear errors like "succ: expected Int, got String".

### `Grasp.HaskellInterop` — Haskell function registry

Builds the `HsFuncRegistry` and extends the default environment with both `haskell-call` (legacy) and the `hs:` prefix dispatch (via the registry stored in `EnvData`).

### `Grasp.DynLookup` — GHC API session and type inference

Isolates all GHC API usage. A lazy-initialized GHC session (`initGhcState`) provides `exprType` (type inference) and `compileExpr` (compilation to `Any`). Key components:

- **`classifyType`** — maps GHC `Type` to `GraspArgType` (NativeInt, ListOf, etc.) using `tcSplitTyConApp_maybe` against builtin TyCons
- **`decomposeFuncType`** — splits function types via `tcSplitFunTys` into args + return
- **`dynCall`** / **`dynCallInferred`** — compile and apply functions via `unsafeCoerce` on closures
- **`applyN`** — curried closure application: `f a b c` via sequential `unsafeCoerce`

Uses `reifyGhc`/`reflectGhc` to persist the GHC session across calls without re-initializing.

### `Grasp.DynDispatch` — Marshaling and dynamic dispatch

Bridges between Grasp values and the GHC API. Handles:

- **`getOrInitGhc`** — lazy GHC session initialization from `envGhcSession`
- **`marshalGraspToHaskell`** / **`marshalHaskellToGrasp`** — convert between Grasp cons chains and Haskell lists, Grasp strings and Haskell `String`, etc.
- **Re-boxing** — values returned by the GHC bytecode interpreter have different info table pointers than statically compiled closures; `reboxInt`/`reboxBool`/`reboxDouble` force fresh allocation with the current binary's constructors
- **`dynDispatch`** — full cycle: type inference → marshaling → application → marshaling back. Falls back to type inference from actual arguments for polymorphic functions.
- **`dynDispatchAnnotated`** — same but for `hs@` form with explicit type annotations

**RTS bridge path** (`succ`, `negate`):
1. `StablePtr` created once at registry construction
2. Each call: `grasp_build_int_app` builds thunk in C via `rts_apply`
3. Thunk forced safely in Haskell via `try`/`evaluate`
4. Exception → error message; success → `mkInt` result

**Haskell marshaling path** (`reverse`, `length`):
1. Marshal Grasp cons list to `[Int]`
2. Call the Haskell function directly
3. Marshal the result back to Grasp values

## The C Bridge

The C bridge (`cbits/rts_bridge.c`) is the layer that touches GHC's RTS directly. It includes `Rts.h` (GHC's internal RTS header) and uses the following RTS functions:

### `rts_lock()` / `rts_unlock()`

Acquires/releases a GHC **Capability**. A Capability is a token that grants permission to allocate on the GHC heap and run Haskell code. The RTS has a fixed number of capabilities (one per `-N` thread). `rts_lock()` blocks until one is available.

```c
Capability *cap = rts_lock();
// ... use RTS functions that need a capability ...
rts_unlock(cap);
```

### `rts_mkInt(cap, val)`

Allocates a boxed `Int` on the GHC heap. Returns a `HaskellObj` (pointer to an `StgClosure`). This is the same representation GHC uses for Haskell `Int` values.

### `rts_apply(cap, fn, arg)`

Creates an application thunk: `fn arg`. Does not evaluate — just builds the closure on the heap. The result is a `HaskellObj` pointing to an unevaluated application node.

### `rts_eval(&cap, expr, &result)`

Forces an expression to weak head normal form (WHNF) by entering GHC's scheduler. The STG machine evaluates the closure: enters thunks, applies functions, updates indirections. This is the same evaluation mechanism GHC uses for compiled Haskell code.

**Warning**: If the Haskell function throws an exception during evaluation, `rts_eval` calls `barf()` and aborts the process. Grasp avoids this by using `grasp_build_int_app` (thunk construction only) + Haskell-side `try`/`evaluate` for safe forcing.

**Warning**: `rts_eval` must not be called from code already executing under `rts_lock()` on the same thread — that would deadlock, since the thread already holds the capability.

### `rts_getInt(obj)`

Extracts the `Int` value from a boxed `Int` closure. Assumes the closure is already evaluated to WHNF.

### `deRefStablePtr(sp)`

Dereferences a `StablePtr` to get the underlying `HaskellObj`. StablePtrs are GC roots — they prevent the garbage collector from moving or collecting the pointed-to closure, giving C code a stable handle.

## Data Flow: `(hs:succ 41)`

Here is the complete path a Haskell interop call takes:

```
1. Parser:   "(hs:succ 41)"
             → EList [ESym "hs:succ", EInt 41]

2. Eval:     eval sees "hs:" prefix, strips it → "succ"
             → looks up registry in EnvData
             → validates: graspTypeOf arg == GTInt matches [HsInt]
             → calls hfInvoke [arg]

3. Registry: bridgeSafeApplyIntInt sp 41
             (StablePtr created once at registry construction)

4. FFI:      foreign import ccall safe "grasp_build_int_app"
             → Haskell releases capability, enters C

5. C bridge: Capability *cap = rts_lock();
             HaskellObj fn = deRefStablePtr(fn_sp);   // get succ closure
             HaskellObj arg = rts_mkInt(cap, 41);      // box 41 on GHC heap
             HaskellObj app = rts_apply(cap, fn, arg); // build: succ 41
             StablePtr result_sp = getStablePtr(app);  // anchor thunk
             rts_unlock(cap);
             return result_sp;                         // no eval in C!

6. Haskell:  thunk <- deRefStablePtr result_sp
             result <- try (evaluate thunk)            // safe forcing
             freeStablePtr result_sp
             → Right 42

7. Back:     → mkInt 42 (a real I# closure on the GHC heap)
             → printVal → "42"
```

Step 5 is where Grasp's values live on GHC's heap. The `41` is a real `StgClosure`. The application `succ 41` is a real thunk. Step 6 forces it safely in Haskell — if the function throws, `try` catches the exception instead of aborting the process.

## Build System

Grasp uses [Cabal](https://www.haskell.org/cabal/) with a [Nix](https://nixos.org/) flake for reproducible builds:

- **`flake.nix`** — provides GHC 9.8, cabal-install, overmind, tmux
- **`grasp.cabal`** — defines the executable and test suite
- **`c-sources: cbits/rts_bridge.c`** — Cabal compiles the C bridge alongside Haskell code. GHC automatically provides the include paths for `Rts.h` and `HsFFI.h`.
- **`-threaded -rtsopts`** — links with the threaded RTS (required for `rts_lock`)

The test suite currently compiles sources twice (via `hs-source-dirs: test, src`) rather than extracting a library. This is a known simplification for the MVP.
