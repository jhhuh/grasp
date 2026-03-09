# Roadmap

## v1 History (archived)

v1 explored whether a dynamic Lisp could inhabit the STG machine as a native tenant. It proved the concept across 8 phases:

1. **Native STG closures** -- `GraspVal = Any`, info-pointer type discrimination
2. **Dynamic function lookup** -- GHC API, `hs:` prefix, `hs@` annotated form
3. **Opt-in laziness** -- real GHC THUNKs via `unsafeInterleaveIO`
4. **Concurrency** -- `forkIO` green threads, `Chan` channels
5. **Macro system** -- `defmacro` with quoted arguments
6. **Module system** -- `module`/`import` with qualified access
7. **Control flow & standard library** -- `begin`, `let`, `loop`/`recur`, `lib/prelude.gsp`
8. **Conditions, pattern matching, REPL, debugging** -- delimited continuations, `match`, isocline REPL, `type-of`/`inspect`/`gc-stats`

v1 reached 223 tests and proved the fundamental thesis. It used a C bridge (`rts_apply`/`rts_mkInt`/`rts_eval`) for Haskell function calls and had modules like `DynLookup`, `DynDispatch`, `HsRegistry`, `HaskellInterop`, and `Continuations`. v1 source is preserved in `v1/`.

## v2 Current Status

v2 is a clean reboot. The vision shifted from "a Lisp on GHC" to "a programmable interface to the GHC RTS" grounded in formal theory (CBPV, gradual typing, Henglein coercions).

What changed from v1:
- **No C bridge for function calls.** v1 routed Haskell function calls through C FFI (`rts_apply`, `rts_eval`). v2 calls Haskell directly -- the evaluator is Haskell, no round-trip needed. The only remaining C code reads `StgInfoTable.type` for closure inspection.
- **CBPV-aware evaluator.** Two modes: `ModeComputation` (full IO) and `ModeTransaction` (STM only, entered via `atomically`). IO-only primitives are rejected in transaction mode.
- **STM as first-class.** `make-tvar`, `read-tvar`, `write-tvar`, `atomically` -- transactions compose, IO cannot enter.
- **Simplified module set.** 8 source modules (Types, NativeTypes, RuntimeCheck, RtsBridge, Parser, Eval, Printer, Main) vs v1's 12+.
- **QuasiQuoter scaffolding.** `EQuoter`/`EAntiquote` AST nodes in the parser types for future QQ support.

What works now:
- S-expression parser (integers, doubles, strings, booleans, symbols, lists, quoting)
- CBPV-aware tree-walking evaluator
- 22 built-in primitives (arithmetic, comparison, list ops, STM, concurrency, IO)
- Special forms: `quote`, `if`, `define`, `lambda`, `begin`, `let`, `loop`/`recur`, `lazy`/`force`, `atomically`, `defmacro`
- 18 native types with info-pointer discrimination
- isocline REPL with history
- File execution (`cabal run grasp -- file.gsp`)
- ~130 tests passing

## v2 Next Steps

### Feature parity sprint

Restore v1 features on the v2 architecture:

- **Prelude** -- `lib/prelude.gsp` with map, filter, fold, etc. (v1 had this)
- **GHC API integration** -- Dynamic Haskell function lookup. v2 does this in pure Haskell (no C bridge), but the GHC API session and dispatch logic need to be rebuilt.
- **Pattern matching** -- `(match expr (pattern body) ...)` with literal, cons, nil, wildcard, and variable patterns
- **Condition system** -- `with-handler`/`signal` via delimited continuations (`prompt#`/`control0#`)
- **Module system** -- `module`/`import` with qualified access and caching

### RTS deepening

Move up the RTS citizenship levels:

- **Level 1 -- Raw closure allocation**: Allocate heap objects with controlled payload layouts. Know which fields are pointers vs non-pointers. Use existing Haskell info tables.
- **Level 2 -- Custom info tables**: Create info tables at runtime with custom GC layout bitmaps and entry code pointers. GHC's GC traces them natively. This is the target for v2.

### Gradual typing

Introduce optional type annotations:

- **Flow typing**: After `(int? x)` succeeds in a branch, the compiler knows `x : Int` and can compile that branch to primops.
- **Contracts**: Types as predicates -- runtime-checked, erased when provable. `(-> positive? int?)` wraps a function with entry/exit checks.
- **Henglein coercion reduction**: Eliminate redundant `tag`/`check` pairs at boundaries.

## Future Vision

### QuasiQuoter

`[grasp| ... |]` in Haskell source. Types inferred from the surrounding Haskell context. Grasp code compiled to native closures at Haskell compile time. The QQ is a compiler from Grasp to STG.

### JIT Compilation

Level 3 RTS citizenship: emit machine code for closure entry. A compiled Grasp lambda is a closure whose entry code runs generated native instructions calling primops directly. No interpreter dispatch.

### RTS Extension

Level 4 (far horizon): custom GC behavior per closure type. Custom scavenging, evacuation, promotion policies. Grasp as a programmable GC policy language.
