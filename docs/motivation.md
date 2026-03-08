# Motivation & Vision

## The gap

There are two traditions in language runtime design that rarely meet:

**Dynamic languages** (Lisp, Scheme, Python, Lua) prioritize interactive development. You sit at a REPL, redefine functions in a running system, inspect and modify state, and explore ideas incrementally. The runtime is a living environment you inhabit.

**GHC's runtime** (the STG machine) is one of the most sophisticated pieces of runtime engineering ever built. It provides a parallel generational GC, green threads, STM, an efficient closure representation, and a calling convention optimized for higher-order functional programming. But it serves exactly one language: Haskell. And Haskell's development model is static — you write code, compile it, run it. GHCi provides some interactivity, but it still goes through Haskell's full compilation pipeline (parser, renamer, typechecker, desugarer, simplifier).

Grasp asks: **what if you could have a dynamic language that simply lives on GHC's runtime, without going through Haskell's compilation pipeline?**

## What this means concretely

When you type `(+ 1 2)` at the Grasp REPL:

1. The parser produces an S-expression AST
2. The evaluator constructs native STG closures on GHC's heap (`GraspVal = Any`)
3. The result is printed

When you type `(hs:succ 41)`:

1. The evaluator looks up `succ` in the registry (or the GHC API for dynamic lookup)
2. The C bridge calls `rts_mkInt` to box the argument on GHC's heap
3. `rts_apply` creates an application thunk: `succ 41`
4. The thunk is forced safely in Haskell via `try`/`evaluate`
5. The Lisp REPL prints `42`

These are the same code paths that GHC uses for its own `foreign export` mechanism. The difference is that Grasp uses them to implement a *language*, not just a function call.

## Use cases

### Live-coding and interactive development

Redefine functions in a running system. Inspect state. Build programs incrementally at a REPL. Like Common Lisp's SLIME or Erlang's shell, but on GHC's runtime — with its GC, threads, and STM available.

### Scripting Haskell libraries

GHC's ecosystem has thousands of high-quality libraries (parsers, data structures, network protocols, cryptography). Today, using them requires writing Haskell and compiling it. Grasp would let you call into these libraries dynamically, from a REPL, without a compilation step.

### Runtime research

GHC's STG machine is well-documented in academic papers but opaque in practice. Grasp provides a hands-on way to explore it: construct closures, trigger evaluation, observe GC behavior, experiment with thunks and update frames. It's an interactive laboratory for the STG machine.

### Embeddable extension language

Haskell applications could embed Grasp as a scripting layer — like how C applications embed Lua or Guile. Users write Grasp scripts that call into the host application's Haskell functions. The embedding is natural because Grasp lives on the same runtime.

## The thesis

Grasp is exploring a hypothesis: **a dynamic language can be a native tenant of the STG machine, not a foreign guest.**

"Native tenant" means:
- Grasp values ARE STG closures (not wrappers around them)
- GHC's GC traces Grasp values (no separate GC)
- GHC's scheduler runs Grasp computations (no separate scheduler)
- Grasp closures can be passed to Haskell functions and vice versa (no marshaling at the boundary)

If this works, it opens a new design point in language implementation: **symbiotic runtimes**, where multiple languages share a single runtime substrate at the closure level.
