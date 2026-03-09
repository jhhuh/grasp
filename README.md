# Grasp

**A programmable interface to the GHC runtime system.**

Grasp is a dynamic language whose values, closures, and thunks are native GHC RTS objects -- indistinguishable from those produced by compiled Haskell. It enters the GHC pipeline at the STG level, where types have been erased but runtime representations remain. Haskell and Grasp share the same heap, the same GC, the same primops.

From Haskell's perspective, Grasp is the part of the RTS you can script.
From Grasp's perspective, it is a Lisp with the full power of the GHC runtime beneath it.

## Design

Grasp v2 is grounded in **Call-by-Push-Value** (Levy 2001), extended to three modes:

- **Value** -- data that already exists (evaluated, inspectable)
- **Transaction** -- composable STM work, rollbackable, no IO
- **Computation** -- unrestricted IO, not rollbackable

The mode system is enforced at runtime: STM blocks reject IO operations. The long-term vision is **gradual typing** -- `?` (dynamic/Any) narrows to concrete Haskell types, bridging the gap from interpreted scripts to compiled embeddings.

### RTS Citizenship Levels

| Level | Capability | Status |
|-------|-----------|--------|
| L0 | Read info pointers, discriminate types | v2 interpreter |
| L1 | Raw closure allocation | **grasp0** |
| L2 | Custom info tables at runtime | **grasp0** |
| L3 | JIT compilation | Future |
| L4 | GC extension points | Future |

## grasp0: C-Native Foundation

Pure C, zero Haskell. Grasp creates its own closures directly on the GHC heap.

```bash
$ nix develop -c make boot     # build and run C bootstrap tests
=== Grasp C-Native Bootstrap Tests ===
[Info Tables]    8/8 PASS
[Allocation]    10/10 PASS
[GC Survival]    8/8 PASS     # closures survive performMajorGC()
[Type Discrimination] 2/2 PASS
```

Four functions, two info tables:
- `grasp_make_info(ptrs, nptrs, tag)` -- runtime info table creation via mmap
- `grasp_alloc(cap, info, fields, n)` -- heap allocation via RTS `allocate()`
- `grasp_field(closure, i)` / `grasp_info(closure)` -- field access, type identity

Everything is cons and nil. The rest is structure.

## v2 Interpreter

**130 tests passing.** Built on Haskell ADTs (will migrate to grasp0).

```
$ nix develop -c cabal run grasp
grasp> (define square (lambda (x) (* x x)))
<lambda>
grasp> (square 7)
49
grasp> (define tv (make-tvar 0))
<tvar>
grasp> (atomically (write-tvar tv 42))
()
grasp> (atomically (read-tvar tv))
42
grasp> (define ch (make-chan))
<chan>
grasp> (spawn (lambda () (chan-put ch (square 6))))
()
grasp> (chan-get ch)
36
grasp> (loop ((i 0) (sum 0))
         (if (> i 10) sum (recur (+ i 1) (+ sum i))))
55
```

What works:
- **Native GHC closures** -- every value IS an STG closure (`GraspVal = Any`)
- **Type discrimination via `unpackClosure#`** -- zero FFI overhead
- **CBPV mode enforcement** -- `atomically` blocks reject IO operations
- **STM** -- `make-tvar`, `read-tvar`, `write-tvar`, composable transactions
- **Concurrency** -- `spawn` / `make-chan` / `chan-put` / `chan-get`
- **`lazy` / `force`** -- opt-in laziness via real GHC thunks
- **`defmacro`** -- macros with quote/unquote
- **`loop` / `recur`** -- explicit tail recursion
- **19 primitives**, REPL with isocline, file loading

## Quick Start

Requires [Nix](https://nixos.org/download.html) with flakes enabled.

```bash
git clone https://github.com/jhhuh/grasp.git
cd grasp
nix develop -c cabal run grasp              # interactive REPL
nix develop -c cabal run grasp -- file.gsp  # run a script
nix develop -c cabal test                   # run tests
```

## Documentation

- [grasp0 Design](docs/plans/2026-03-09-c-native-bootstrap-design.md) -- C-native foundation, 4 functions, 2 info tables
- [v2 Foundations Design](docs/plans/2026-03-09-grasp-v2-foundations-design.md) -- vision, CBPV semantics, RTS citizenship
- [v2 Core Interpreter Plan](docs/plans/2026-03-09-grasp-v2-core-interpreter.md) -- implementation details

v1 sources are archived in `v1/`.

## License

TBD
