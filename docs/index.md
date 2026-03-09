# Grasp

**A programmable interface to the GHC RTS.**

Grasp is a dynamic language whose values, closures, and thunks are native GHC RTS objects. It is not "a Lisp implemented in Haskell" — it is a scriptable layer inside the GHC runtime system. From Haskell's perspective, Grasp is the part of the RTS you can script. From Grasp's perspective, it is a dynamic language with the full power of the GHC runtime beneath it.

Formal foundations: Call-by-Push-Value (CBPV), gradual typing (Siek & Taha), Henglein coercions. Compilation has a precise meaning: resolving `?` to concrete types, eliminating interpreter dispatch.

## Documentation

| Document | What it covers |
|----------|---------------|
| [Motivation](motivation.md) | Why Grasp exists and the v2 vision |
| [Language Reference](language.md) | Syntax, special forms, primitives, evaluation model |
| [Architecture](architecture.md) | Parser, evaluator, RTS bridge, module layout |
| [The STG Machine](stg-machine.md) | The runtime substrate: closures, info tables, evaluation, GC |
| [Delimited Continuations](delimited-continuations.md) | Theory and GHC RTS implementation |
| [Related Work](related-work.md) | Comparison with Clojure, GHCi, Husk Scheme, etc. |
| [Roadmap](roadmap.md) | v1 history, v2 status, future directions |

## Design Documents

| Document | What it covers |
|----------|---------------|
| [v2 Foundations](plans/2026-03-09-grasp-v2-foundations-design.md) | CBPV, gradual typing, RTS citizenship levels, dual interface |
