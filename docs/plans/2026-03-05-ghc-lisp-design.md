# ghc-lisp Design

A REPL-based dynamic Lisp that lives on GHC's runtime, using native GHC closures as its value representation.

## Goals

- **Live-coding / hot-reload**: Redefine functions in a running system interactively
- **Scripting GHC-linked libraries**: Call compiled Haskell functions dynamically from a Lisp REPL
- **Exploratory runtime research**: Understand what a non-Haskell language can do on GHC's heap/GC/scheduler
- **Embeddable extension language**: A Lisp that Haskell applications can embed for user scripting

## Architecture: RTS-Native Interpreter

**Approach**: Lisp values are native GHC heap closures with custom info tables. Evaluation happens in a Haskell-side interpreter. Haskell interop uses the RTS C API (`rts_apply`, `rts_eval`, etc.).

**Implementation language**: Haskell + C FFI hybrid. Haskell for parser, evaluator, REPL. C for info table construction and RTS heap interaction.

## Value Representation

Every Lisp value is a `StgClosure` on GHC's heap. Each value type has one info table (allocated at startup); individual values are closures pointing to the appropriate info table.

```
GHC Heap Object Layout:
┌──────────────┬───────────────────────┐
│ Info Pointer │ Payload words...      │
│ (→ InfoTable)│                       │
└──────────────┴───────────────────────┘

Lisp Value Types:

LispInt:    [info_ptr | Int64]
LispDouble: [info_ptr | Double]
LispSymbol: [info_ptr | ptr → symbol table entry]
LispCons:   [info_ptr | car_closure, cdr_closure]
LispNil:    [info_ptr]  (singleton, no payload)
LispFun:    [info_ptr | arity, env_closure, body_code_ptr]
LispString: [info_ptr | ptr → ByteArray#]
```

Info tables use GHC's `CONSTR` closure type for data values. GHC's GC traverses them using the pointer/non-pointer counts from the info table. No GC modifications needed.

## Evaluation Model

**Strict core (call-by-value)**: Arguments evaluated before application. The evaluator constructs result values as `CONSTR` closures — already evaluated, no thunks.

**Opt-in laziness via `(delay expr)`**: Creates a real GHC `THUNK` closure whose entry code calls the Haskell evaluator. `(force x)` enters the closure; GHC's RTS evaluates and self-updates it (standard thunk update mechanism). Lazy Lisp values participate in GHC's update mechanism — they self-memoize like Haskell thunks.

## Haskell Interop

Calling Haskell functions from the Lisp REPL:

1. Look up function closure by fully-qualified name via RTS linker
2. Marshal Lisp values → Haskell values using `rts_mk*` functions
3. Apply: `rts_apply(fun_closure, arg_closure)`
4. Evaluate: `rts_eval(application, &result)`
5. Unmarshal Haskell result → Lisp value using `rts_get*` functions

MVP marshaling types:
- `Int` ↔ `LispInt` (via `rts_mkInt` / `rts_getInt`)
- `[a]` ↔ `LispCons` chain
- `String` ↔ `LispString`

## REPL Architecture

```
User input → [Parser] → [Macro Expand] → [Eval] → [Print] → output
                                            │
                                       [C FFI layer]
                                            │
                                      [GHC RTS Heap]
```

- Parser: S-expression parser (megaparsec or hand-written)
- Eval: Strict evaluator, constructs closures via FFI
- Haskell interop: Marshaling + `rts_apply` / `rts_eval`

## Project Structure

```
ghc-lisp/
├── flake.nix                    # Nix flake (GHC, cabal)
├── ghc-lisp.cabal               # Cabal project
├── cbits/
│   ├── rts_bridge.c             # Info table construction, heap alloc
│   └── rts_bridge.h             # C API exposed to Haskell via FFI
├── src/
│   ├── GhcLisp/
│   │   ├── Types.hs             # LispVal, LispExpr AST, Env
│   │   ├── Parser.hs            # S-expression parser
│   │   ├── Eval.hs              # Evaluator (strict core)
│   │   ├── RtsBridge.hs         # FFI bindings to cbits/
│   │   ├── HaskellInterop.hs    # Marshaling, function lookup
│   │   └── Printer.hs           # LispVal → String
│   └── Main.hs                  # REPL entry point
├── artifacts/
├── docs/plans/
└── Procfile
```

Build: Cabal project with `c-sources: cbits/rts_bridge.c`. Links against GHC's RTS. Nix flake provides GHC with RTS headers.

## MVP Success Criterion

A REPL where the user can:
1. Evaluate arithmetic: `(+ 1 2)` → `3`
2. Define bindings: `(define x 42)`
3. Create lambdas: `(lambda (x) (+ x 1))`
4. **Call a compiled Haskell function**: `(haskell-call "GHC.List.reverse" (list 1 2 3))` → `(3 2 1)`

The last point is the key milestone — it proves the Lisp can bridge into the Haskell ecosystem dynamically.

## Open Questions (for later)

- Exact info table ABI across GHC versions (may need version-specific `#if` guards)
- How to handle polymorphic Haskell functions (monomorphize at call site?)
- Whether to support calling Haskell typeclassed functions (need dictionary passing)
- Macro system design beyond basic `define-syntax`
- Concurrency: exposing `forkIO` to Lisp (create a Lisp thunk, fork a GHC thread to evaluate it)
