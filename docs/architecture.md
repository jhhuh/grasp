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

Defines two parallel type hierarchies:

- **`LispExpr`** — the parser's output. A plain algebraic data type representing S-expression syntax: `EInt`, `EDouble`, `ESym`, `EStr`, `EBool`, `EList`. No closures, no environments — just syntax.

- **`LispVal`** — the evaluator's output. Runtime values that include everything `LispExpr` has, plus cons cells (`LCons`/`LNil`), lambda closures (`LFun` with captured environment), and primitive functions (`LPrimitive` wrapping `[LispVal] -> IO LispVal`).

- **`EnvData`** — contains `envBindings :: Map Text LispVal` (symbol table) and `envHsRegistry :: HsFuncRegistry` (registered Haskell functions with type metadata). `Env = IORef EnvData`. New bindings from `define` mutate `envBindings` in place. Lambda closures capture the `Env` reference, inheriting access to the registry.

The two-type design keeps parsing pure and separates syntax from semantics.

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

A tree-walking interpreter. `eval :: Env -> LispExpr -> IO LispVal` pattern-matches on expression constructors:

- **Atoms** — integers, doubles, strings, booleans evaluate to themselves
- **Symbols** — looked up in the environment; error if unbound
- **`(quote e)`** — converts expression to value without evaluation
- **`(if c t e)`** — evaluates condition; only `#f` is falsy
- **`(define s e)`** — evaluates `e`, inserts binding into env
- **`(lambda (params) body)`** — creates `LFun` capturing current env
- **`(f args...)`** — evaluates `f` and all `args`, then calls `apply`

`apply` dispatches on function type:
- `LPrimitive` — calls the wrapped `[LispVal] -> IO LispVal`
- `LFun` — creates child environment with param bindings layered over the closure's environment, then evaluates the body

The evaluator is strict: all arguments are evaluated before `apply` is called.

### `Grasp.Printer` — Value pretty-printer

Converts `LispVal` to `String`. The interesting case is cons cells: `printCons` walks the cdr chain to print proper lists as `(1 2 3)` and improper lists as `(1 . 2)`.

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

**RTS bridge path** (`succ`, `negate`):
1. `StablePtr` created once at registry construction
2. Each call: `grasp_build_int_app` builds thunk in C via `rts_apply`
3. Thunk forced safely in Haskell via `try`/`evaluate`
4. Exception → error message; success → `LInt` result

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
             → validates: [LInt 41] matches [HsInt]
             → calls hfInvoke [LInt 41]

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

7. Back:     → LInt 42
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
