# Architecture

Grasp v2 is structured as a pipeline: **parser -> evaluator -> printer**, with a minimal C bridge for closure type inspection.

```
┌──────────────────────────────────────────────┐
│                    REPL                       │
│          read → eval → print → loop          │
└──────┬───────────────┬───────────────┬───────┘
       │               │               │
  ┌────▼────┐   ┌──────▼──────┐  ┌─────▼─────┐
  │ Parser  │   │  Evaluator  │  │  Printer  │
  │ (Mega-  │   │ (CBPV-aware │  │ (info-ptr │
  │ parsec) │   │  tree-walk) │  │  dispatch) │
  └─────────┘   └──────┬──────┘  └───────────┘
                       │
                 ┌─────▼──────┐
                 │  C Bridge  │
                 │ (closure   │
                 │  type only)│
                 └─────┬──────┘
                       │ unpackClosure# + StgInfoTable.type
                 ┌─────▼──────┐
                 │  GHC RTS   │
                 │ (STG heap, │
                 │  GC, sched)│
                 └────────────┘
```

v2 eliminates the C bridge for function calls. v1 used `rts_apply`/`rts_mkInt`/`rts_eval` through C FFI to call Haskell functions. v2 calls Haskell functions directly — the evaluator is Haskell, so no FFI round-trip is needed. The only remaining C code (`cbits/rts_bridge.c`) reads the `StgInfoTable.type` field from an info pointer for closure type inspection.

## Modules

### `Main.hs` -- Entry point

REPL or file execution. With no arguments, starts the isocline REPL (`readlineExMaybe` with history and line editing). With a file argument, parses and evaluates the file. Dispatches eval with `ModeComputation` (unrestricted IO).

### `Grasp.Types` -- Core type definitions

Two type layers:

- **`LispExpr`** -- the parser's output. A plain ADT representing S-expression syntax: `EInt`, `EDouble`, `ESym`, `EStr`, `EBool`, `EList`, plus `EQuoter`/`EAntiquote` for future QuasiQuoter support.

- **`GraspVal = Any`** -- the evaluator's output. An untyped pointer to a GHC heap closure. Integers are real `I#` closures, booleans are `True`/`False` static closures. Grasp-specific types use Haskell ADTs from `NativeTypes`.

- **`EnvData`** -- `envBindings` (symbol table), `envHsRegistry` (Haskell function registry, currently empty in v2), `envGhcSession` (reserved for future GHC API use), `envModules` (cached modules), `envLoading` (circular dependency detection). `Env = IORef EnvData`.

### `Grasp.NativeTypes` -- Value representation and type discrimination

Defines 14 Grasp-specific ADTs whose info tables GHC generates automatically:

`GraspSym`, `GraspStr`, `GraspCons`, `GraspNil`, `GraspLambda`, `GraspPrim`, `GraspLazy`, `GraspMacro`, `GraspChan`, `GraspModule`, `GraspRecur`, `GraspPromptTag`, `GraspTVar`.

Provides:

- **Type discrimination** -- `graspTypeOf :: Any -> GraspType` reads the info-table address from a closure header via `unpackClosure#` and compares against cached reference addresses. Uses `RuntimeCheck.readRepTag` under the hood.
- **Constructors** -- `mkInt`, `mkBool`, `mkCons`, `mkLambda`, `mkTVar`, etc. wrap Haskell values as `Any` via `unsafeCoerce`.
- **Extractors** -- `toInt`, `toCar`, `toLambdaParts`, `toTVar`, etc. unwrap `Any` back to concrete types.
- **Equality** -- `graspEq` performs structural equality with recursive cons comparison and lazy auto-forcing.
- **Laziness** -- `mkLazy`, `forceLazy`, `forceIfLazy` for GHC THUNK creation and entry.

### `Grasp.RuntimeCheck` -- Low-level closure inspection

Reads info-table pointers via `unpackClosure#` and closure type via the C bridge. `RepTag` bundles the info pointer (type identity) with the closure type category (CONSTR, FUN, THUNK, etc.). `getInfoPtr` forces to WHNF with `seq` before reading.

### `Grasp.RtsBridge` -- FFI binding

Single FFI import: `graspClosureType :: Ptr () -> IO Word`. Reads `StgInfoTable.type` from an info pointer. This is the only remaining C FFI in v2.

### `Grasp.Parser` -- S-expression parser

Built with megaparsec. Handles integers, doubles, strings, booleans (`#t`/`#f`), symbols, lists, quote (`'expr` -> `(quote expr)`), and line comments (`;`). Parser precedence: `pBool | pStr | pQuote | pList | try pDouble | try pInt | pSym`.

### `Grasp.Eval` -- Core evaluator

A CBPV-aware tree-walking interpreter. `eval :: EvalMode -> Env -> LispExpr -> IO GraspVal` pattern-matches on expression constructors.

Two modes enforce the CBPV effect discipline:

- **`ModeComputation`** -- unrestricted IO. All primitives available.
- **`ModeTransaction`** -- STM only. IO-only primitives (`spawn`, `make-chan`, `chan-put`, `chan-get`) are rejected at call time. Entered via `(atomically body)`.

Special forms: `quote`, `if`, `define`, `lambda`, `begin`, `let`, `loop`/`recur`, `lazy`/`force`, `atomically`, `defmacro`.

Built-in primitives (22): arithmetic (`+`, `-`, `*`, `div`), comparison (`=`, `<`, `>`), list operations (`list`, `cons`, `car`, `cdr`, `null?`), STM (`make-tvar`, `read-tvar`, `write-tvar`), concurrency (`spawn`, `make-chan`, `chan-put`, `chan-get`), IO (`error`, `display`, `newline`).

`apply` dispatches on `graspTypeOf`: `GTPrim` calls the primitive function, `GTLambda` creates a child environment with parameter bindings and evaluates the body.

The evaluator is strict by default: all arguments are evaluated before `apply`. Primitives auto-force lazy arguments at their boundaries.

### `Grasp.Printer` -- Value pretty-printer

Converts `Any` to `String` via `graspTypeOf` dispatch. Cons cells are printed as proper lists `(1 2 3)` or improper lists `(1 . 2)` by walking the cdr chain.

## 18 Native Types

| GHC closure | Grasp type | Printed as |
|-------------|------------|------------|
| `I# n` | Int | `42` |
| `D# d` | Double | `3.14` |
| `True` | Bool | `#t` |
| `False` | Bool | `#f` |
| `GraspSym s` | Symbol | `foo` |
| `GraspStr s` | String | `"hello"` |
| `GraspCons a d` | Cons | `(1 2 3)` or `(1 . 2)` |
| `GraspNil` | Nil | `()` |
| `GraspLambda` | Lambda | `<lambda>` |
| `GraspPrim` | Primitive | `<primitive:+>` |
| `GraspLazy` | Lazy | `<lazy>` |
| `GraspMacro` | Macro | `<macro>` |
| `GraspChan` | Chan | `<chan>` |
| `GraspModule` | Module | `<module:name>` |
| `GraspRecur` | Recur | (internal) |
| `GraspPromptTag` | PromptTag | `<prompt-tag>` |
| `GraspTVar` | TVar | `<tvar>` |

GHC-equivalent types (Int, Double, Bool) reuse GHC's own closures -- a Grasp integer IS a Haskell `Int`. Grasp-specific types use Haskell ADTs whose info tables GHC generates automatically. Type discrimination is by info-pointer comparison, not constructor tag matching.

Note: `True` and `False` have distinct info pointers, giving 18 discriminable types from 17 ADTs.

## CBPV Effect Discipline

The evaluator tracks a `EvalMode` that enforces the CBPV mode separation:

```
Value  ───pure───→  Transaction  ───atomically───→  Computation
  A                     T̲                              B̲
                   (STM effects only)           (unrestricted IO)
```

`(atomically body)` switches from `ModeComputation` to `ModeTransaction`. Inside a transaction, IO-only primitives are rejected. Nested `atomically` is an error. STM primitives (`make-tvar`, `read-tvar`, `write-tvar`) work in both modes. This matches GHC's own STM discipline.

## Dual Interface Vision

**REPL (current)**: All values start as `?` (`Any`). Interpreter dispatch via info-pointer checks. Interactive exploration of the RTS.

**Haskell QuasiQuoter (future)**: `[grasp| ... |]` in Haskell source. Types inferred from Haskell context. Grasp code compiled to native closures at Haskell compile time. The `EQuoter`/`EAntiquote` AST nodes are already in the parser types.

Both interfaces target the same RTS objects.

## RTS Citizenship Levels

Grasp's relationship with the RTS deepens over time:

**Level 0 -- Read-only tenant (current)**: Read info pointers via `unpackClosure#`. Store values via `unsafeCoerce` to `Any`. Force thunks via `seq`. Guest using Haskell ADTs as closures.

**Level 1 -- Raw closure allocation**: Allocate heap objects with specific payload layouts. Control pointer vs non-pointer fields. Still using existing Haskell info tables.

**Level 2 -- Custom info tables**: Create info tables at runtime with custom GC layout bitmaps and entry code pointers. GHC's GC traces them natively.

**Level 3 -- Custom entry code (JIT)**: Emit machine code for closure entry. Compiled Grasp lambdas run generated native instructions calling primops directly.

**Level 4 -- RTS extension (far horizon)**: Custom GC behavior per closure type. Grasp as a programmable GC policy language.

## Build System

Cabal + Nix flake (GHC 9.8.4):

- **`flake.nix`** -- provides GHC 9.8, cabal-install, overmind, tmux
- **`grasp.cabal`** -- defines executable and test suite
- **`c-sources: cbits/rts_bridge.c`** -- Cabal compiles the C bridge alongside Haskell code
- **`-threaded -rtsopts`** -- links with the threaded RTS
