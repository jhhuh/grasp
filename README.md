# Grasp

**A Lisp that grasps the G-machine.**

Grasp is a dynamic, untyped Lisp that lives directly on GHC's runtime system — the Spineless Tagless G-machine (STG). Instead of building its own garbage collector, scheduler, or closure representation, Grasp inhabits GHC's: its values are native STG closures on GHC's heap, traced by GHC's generational GC, and evaluated by calling into the RTS.

This is not a Lisp *written in* Haskell. It is a Lisp that *lives on* the same runtime substrate as Haskell, sharing its heap, its GC, and its evaluation machinery.

## Why?

Most Lisps build everything from scratch: a custom GC, a custom VM, custom closures. This works, but it means you can't talk to the host runtime at the level of closures and heap objects — only through serialization boundaries (FFI, IPC, marshaling).

GHC's runtime is one of the most sophisticated language runtimes ever built: a parallel generational GC, lightweight green threads with M:N scheduling, software transactional memory (STM), and an efficient closure representation designed for higher-order functional programming. All of this machinery sits behind a C API (`rts_mkInt`, `rts_apply`, `rts_eval`) that was designed for FFI interop but has never been used to host an entire language.

Grasp asks: **what if a dynamic language simply moved in?**

## Status

**MVP complete.** The REPL works with arithmetic, lambdas, list operations, and can call compiled Haskell functions through the RTS C API.

```
$ grasp
grasp v0.1 — a Lisp on GHC's runtime
Type (quit) to exit.
λ> (+ 1 2)
3
λ> (define square (lambda (x) (* x x)))
<lambda>
λ> (square 7)
49
λ> (haskell-call "reverse" (list 1 2 3))
(3 2 1)
λ> (haskell-call "succ" 41)
42
```

The `succ` and `negate` calls go through the C bridge — `rts_apply` builds a thunk, `rts_eval` forces it through GHC's scheduler, `rts_getInt` extracts the result. This is real RTS integration, not simulation.

## Quick Start

Requires [Nix](https://nixos.org/download.html) with flakes enabled.

```bash
git clone https://github.com/jhhuh/grasp.git
cd grasp
nix develop -c cabal run grasp
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
