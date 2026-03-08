# Grasp

**A Lisp that grasps the G-machine.**

Grasp is a dynamic, untyped Lisp that lives directly on GHC's runtime system — the Spineless Tagless G-machine (STG). Instead of building its own garbage collector, scheduler, or closure representation, Grasp inhabits GHC's: its values are native STG closures on GHC's heap, traced by GHC's generational GC, and evaluated by calling into the RTS.

This is not a Lisp *written in* Haskell. It is a Lisp that *lives on* the same runtime substrate as Haskell, sharing its heap, its GC, and its evaluation machinery.

## Why?

Most Lisps build everything from scratch: a custom GC, a custom VM, custom closures. This works, but it means you can't talk to the host runtime at the level of closures and heap objects — only through serialization boundaries (FFI, IPC, marshaling).

GHC's runtime is one of the most sophisticated language runtimes ever built: a parallel generational GC, lightweight green threads with M:N scheduling, software transactional memory (STM), and an efficient closure representation designed for higher-order functional programming. All of this machinery sits behind a C API (`rts_mkInt`, `rts_apply`, `rts_eval`) that was designed for FFI interop but has never been used to host an entire language.

Grasp asks: **what if a dynamic language simply moved in?**

## Status

**Phase 7 complete.** All values are native STG closures on GHC's heap. ~196 tests passing.

```
λ> (define square (lambda (x) (* x x)))
<lambda>
λ> (square 7)
49
λ> (hs:Data.List.sort (list 3 1 2))
(1 2 3)
λ> (defmacro when (cond body) (list 'if cond body '()))
<macro>
λ> (define ch (make-chan))
<chan>
λ> (spawn (lambda () (chan-put ch (square 6))))
()
λ> (chan-get ch)
36
λ> (loop ((i 0) (sum 0))
     (if (> i 10) sum (recur (+ i 1) (+ sum i))))
55
```

What works:
- **Native GHC closures** -- every Grasp value IS an STG closure (`GraspVal = Any`)
- **Type discrimination via `unpackClosure#`** -- zero FFI overhead
- **`hs:` / `hs@` syntax** -- call any Haskell function by name at runtime
- **Dynamic GHC API lookup** -- auto-infers types, caches compiled closures
- **`(lazy expr)` / `(force x)`** -- opt-in laziness via real GHC THUNKs
- **`defmacro`** -- hygienic macros with quote/unquote
- **`spawn` / channels** -- green threads via `forkIO`, blocking channels via `Chan`
- **`module` / `import`** -- file-based modules with qualified access (`math.square`), caching, circular dependency detection
- **`begin` / `let`** -- sequential evaluation, sequential bindings with implicit begin
- **`loop` / `recur`** -- Clojure-style explicit tail recursion
- **File execution** -- `cabal run grasp -- file.gsp` runs scripts
- **Standard library** -- `lib/prelude.gsp` with map, filter, fold, and more
- REPL with error recovery, 16 built-in primitives

## Quick Start

Requires [Nix](https://nixos.org/download.html) with flakes enabled.

```bash
git clone https://github.com/jhhuh/grasp.git
cd grasp
nix develop -c cabal run grasp           # interactive REPL
nix develop -c cabal run grasp -- file.gsp  # run a script
```

## Documentation

Full documentation is available at the [Grasp docs site](docs/):

- [Motivation & Vision](docs/motivation.md) — why this project exists
- [Language Reference](docs/language.md) — the Lisp dialect spec
- [Architecture](docs/architecture.md) — how Grasp works inside
- [The STG Machine](docs/stg-machine.md) — the runtime Grasp inhabits
- [Related Work](docs/related-work.md) — how Grasp compares to other projects
- [Roadmap](docs/roadmap.md) — what's next

## License

TBD
