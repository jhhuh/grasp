# Motivation & Vision

## Two perspectives

**From Haskell's perspective**, Grasp is the part of the RTS you can script. GHC's runtime -- the STG machine -- is one of the most sophisticated pieces of runtime engineering ever built: parallel generational GC, green threads, STM, an efficient closure representation, and a calling convention optimized for higher-order functional programming. But it serves exactly one language. Grasp opens it up.

**From Grasp's perspective**, it is a dynamic language with the full power of the GHC runtime beneath it. Not a Lisp "implemented in Haskell" (like Husk Scheme), not a syntax skin over Haskell (like Liskell), and not a Haskell REPL with extra steps (like GHCi). Grasp values ARE GHC heap objects. Its closures are indistinguishable from those produced by compiled Haskell.

## The shared foundation

The GHC compilation pipeline erases types:

```
Haskell source → Core (System FC) → STG → Cmm → machine code
                     full types      types erased, RuntimeRep survives
```

Grasp enters at the STG level -- the point where types have been erased but runtime representations remain. Haskell and Grasp share:

- **Primops**: The same primitive operations (`+#`, `newMutVar#`, `catch#`, etc.)
- **RuntimeRep**: The same representation kinds (`IntRep`, `DoubleRep`, `BoxedRep Lifted`)
- **The heap**: GHC's generational GC manages both Haskell and Grasp objects
- **The mutator**: Closure allocation, thunk entry, update-in-place, blackholing

Nothing more. Grasp does not inherit Haskell's type classes, GADTs, higher-rank polymorphism, or type families. Those are Haskell's discipline, built above the same foundation. Grasp builds its own.

## Formal foundations

v2 is grounded in established theory:

- **Call-by-Push-Value** (Levy, 2001): The semantic spine. Distinguishes values (data that exists) from computations (work to be done), extended to three modes with STM transactions as a first-class intermediate layer.

- **Gradual typing** (Siek & Taha, 2006): The type discipline. All REPL values start as `?` (dynamic, `Any`). Concrete types can be introduced incrementally. The gradient runs from fully dynamic (tree-walking, info-pointer dispatch) to fully typed (primops, no dispatch).

- **Henglein coercions** (Henglein, 1994): The cost model. Boundary crossings between dynamic and typed code use `tag_T : T -> Any` (box) and `check_T : Any -> T` (unbox). Coercion reduction eliminates redundant pairs.

**Compilation has a precise meaning**: resolving `?` to concrete types, eliminating interpreter dispatch, emitting direct primop calls. This is not an optimization -- it is the formal definition of what it means to compile Grasp code.

## Use cases

### Live-coding and interactive development

Redefine functions in a running system. Inspect state. Build programs incrementally at a REPL. Like Common Lisp's SLIME or Erlang's shell, but on GHC's runtime -- with its GC, threads, and STM available.

### Scripting Haskell libraries

GHC's ecosystem has thousands of libraries. Today, using them requires writing Haskell and compiling it. Grasp enables calling into these libraries dynamically, from a REPL, without a compilation step.

### Runtime research

GHC's STG machine is well-documented in papers but opaque in practice. Grasp provides a hands-on way to explore it: construct closures, trigger evaluation, observe GC behavior, experiment with thunks and update frames.

### Embeddable extension language

Haskell applications could embed Grasp as a scripting layer -- like how C applications embed Lua. The embedding is natural because Grasp lives on the same runtime. The future QuasiQuoter interface (`[grasp| ... |]`) makes this a compile-time embedding with zero runtime overhead for typed code.

## The thesis

A dynamic language can be a **native tenant** of the STG machine, not a foreign guest:

- Grasp values ARE STG closures (not wrappers around them)
- GHC's GC traces Grasp values (no separate GC)
- GHC's scheduler runs Grasp computations (no separate scheduler)
- Grasp closures can be passed to Haskell functions and vice versa (no marshaling)

If this works fully, it establishes a new design point: **symbiotic runtimes**, where multiple languages share a single runtime substrate at the closure level. The formal foundations (CBPV + gradual typing + coercions) provide the theory to reason about this sharing precisely.
