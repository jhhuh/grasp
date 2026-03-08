# Grasp

**A Lisp that grasps the G-machine.**

Grasp is a dynamic, untyped Lisp that lives directly on GHC's runtime system — the Spineless Tagless G-machine (STG). Its values are native STG closures on GHC's heap, traced by GHC's generational GC, and evaluated through the RTS C API.

## What is this?

Grasp explores a question that hasn't been seriously attempted before: **can a dynamic language inhabit the STG machine as a native tenant, not a foreign guest?**

Most hosted languages (Clojure on JVM, Fennel on Lua) target runtimes that were *designed* to host other languages. The JVM has bytecode, classloaders, and reflection. Lua has a simple stack-based VM with a clean C API. GHC's STG machine was designed for exactly one language: Haskell. It has no official "guest language" story.

And yet, the STG machine is extraordinarily capable. It provides:

- **A generational, parallel garbage collector** that can handle millions of short-lived allocations
- **Lightweight green threads** with M:N scheduling (thousands of threads on a few OS threads)
- **Software transactional memory** (STM) for lock-free concurrent data structures
- **An efficient closure representation** with info tables, pointer tagging, and thunk update
- **A stable C API** (`rts_mkInt`, `rts_apply`, `rts_eval`) for constructing and evaluating closures

Grasp reaches into this machinery and builds a Lisp on top of it.

## How to read these docs

| Document | What it covers |
|----------|---------------|
| [Motivation](motivation.md) | Why this project exists, what it's trying to prove |
| [Language Reference](language.md) | The Lisp dialect: syntax, special forms, primitives |
| [Architecture](architecture.md) | How Grasp works: parser, evaluator, C bridge, RTS integration |
| [The STG Machine](stg-machine.md) | The runtime substrate: closures, info tables, evaluation, GC |
| [Delimited Continuations](delimited-continuations.md) | Theory, GHC RTS implementation, and Grasp's condition system |
| [Related Work](related-work.md) | How Grasp compares to Clojure, GHCi, Husk Scheme, etc. |
| [Roadmap](roadmap.md) | Project history and future directions |
