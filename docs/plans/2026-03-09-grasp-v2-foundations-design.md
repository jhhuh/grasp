# Grasp v2: A Programmable Interface to the GHC RTS

**Date**: 2026-03-09
**Status**: Design

## Vision

Grasp is a programmable, scriptable layer inside the GHC runtime system.
It is not "a Lisp implemented in Haskell" — it is a dynamic language whose
values, closures, and thunks are native GHC RTS objects, indistinguishable
from those produced by compiled Haskell.

From Haskell's perspective, Grasp is the part of the RTS you can script.
From Grasp's perspective, it is a dynamic language with the full power of
the GHC runtime beneath it.

## Core Thesis

The GHC compilation pipeline erases types:

    Haskell source → Core (System FC) → STG → Cmm → machine code
                         full types      types erased, RuntimeRep survives

Grasp enters at the STG level — the point where types have been erased but
runtime representations remain. Haskell and Grasp share:

- **Primops**: The same primitive operations (`+#`, `newMutVar#`, `catch#`, etc.)
- **RuntimeRep**: The same representation kinds (`IntRep`, `DoubleRep`, `BoxedRep Lifted`, etc.)
- **The heap**: GHC's generational GC manages both Haskell and Grasp objects
- **The mutator**: Closure allocation, thunk entry, update-in-place, blackholing

Nothing more. Grasp does not inherit Haskell's type classes, GADTs,
higher-rank polymorphism, or type families. Those are Haskell's discipline,
built above the same foundation. Grasp builds its own.

## Formal Foundations

### CBPV as the Semantic Spine

Levy's Call-by-Push-Value (CBPV, 2001) distinguishes:

- **Value types** `A` — data that already exists (evaluated, inspectable)
- **Computation types** `B̲` — suspended work that produces values

With explicit shifts:

- `thunk B̲` — suspend a computation into a value
- `force A` — resume a suspended computation

GHC's mutator already implements CBPV operationally:

| CBPV          | GHC mutator                              | Grasp            |
|---------------|------------------------------------------|------------------|
| Value `A`     | `CONSTR` closure — evaluated, GC-traced  | Known type → compile |
| Computation `B̲` | `THUNK` closure — unevaluated, update frame | Unknown type → interpret |
| `thunk`       | Allocate THUNK in nursery                | `(lazy expr)`    |
| `force`       | Enter closure — eval/apply, blackhole, update | `(force x)` / auto |

**Evaluation strategy couples with the type system.** Strict evaluation
(call-by-value) means arguments are values at call boundaries — their types
are observable, their info pointers are readable, compilation is possible.
Lazy evaluation defers this knowledge. Grasp defaults to strict, with
opt-in laziness via real GHC thunks. This maximizes the compilable surface.

### The STG Observable Fragment

The common ground between Haskell and Grasp — what's observable at runtime:

| Layer                  | Observable at STG? | Usable by Grasp? |
|------------------------|-------------------|-----------------|
| RuntimeRep             | Yes — calling convention | Yes |
| Concrete monomorphic types | Yes — info pointer | Yes |
| Data constructors      | Yes — info pointer | Yes |
| Function arity         | Yes — closure info | Yes |
| Parametric polymorphism | No — erased | No (monomorphize) |
| Type classes           | No — dictionary erased | No |
| GADTs                  | No — refinement erased | No |
| Higher-rank/type families | No — erased | No |

The usable fragment is: **monomorphic types + function types + algebraic
data types with known constructors**. Approximately: simply-typed lambda
calculus with ADTs. This is Grasp's foundation.

### Gradual Typing: From Dynamic to Compiled

Grasp's type discipline is a gradual type system (Siek & Taha, 2006)
built over the STG observable fragment:

- `?` — the dynamic type. All values are `Any` (`BoxedRep Lifted`).
  Operations go through interpreter dispatch + info-pointer checks.
- Concrete Haskell types — `Int`, `Double`, `Bool`, `[a]`, `a -> b`.
  Operations compile to primops. No dispatch.

The gradient:

    Fully dynamic (REPL)          Fully typed (QQ / compiled)
         ?  ←———————————————→  Haskell type
       Any                     Int#, Double#, concrete closures
    tree-walk                  primops, native entry code

Boundary crossings use Henglein-style coercions (Henglein, 1994):

- `tag_T : T → Any` — box a concrete value into the dynamic world
- `check_T : Any → T` — runtime check (read info pointer) + unbox

Coercion reduction eliminates redundant tag/check pairs — the formal
basis for optimizing boundary overhead.

### Grasp's Own Discipline

Above the common ground, Grasp builds type-system features suited to
a dynamic language:

- **Flow typing** (occurrence typing): After `(int? x)` succeeds in a
  branch, the compiler knows `x : Int` and can compile that branch to
  primops. This formalizes what dynamic code already does.

- **Contracts**: Types as predicates — runtime-checked, erased when
  provable. `(-> positive? int?)` wraps a function with entry/exit checks.
  When the compiler proves a contract holds, it removes the check.
  That removal IS compilation.

- **Structural typing**: Values typed by shape, not name. Interop with
  Haskell's nominal types happens at the boundary via coercions.

These are not final — they are directions to explore. The formal spine
(CBPV + gradual typing + coercions) supports all of them.

## Architecture

### Layered Design

```
┌──────────────────────────────────────────────┐
│  Grasp's discipline                          │
│  (CBPV types, gradual typing, contracts,     │
│   flow typing, compilation decisions)        │
├──────────────────────────────────────────────┤
│  STG observable fragment                     │
│  (RuntimeRep, info pointers, constructor     │
│   tags, function arity)                      │
├──────────────────────────────────────────────┤
│  GHC mutator = CBPV machine                 │
│  (CONSTR/THUNK/FUN allocation, eval/apply,   │
│   update-in-place, blackholing, GC)          │
├──────────────────────────────────────────────┤
│  Primops                                     │
│  (+#, *#, newMutVar#, catch#, prompt#, ...)  │
└──────────────────────────────────────────────┘
```

### RTS Citizenship Levels

Grasp's relationship with the RTS deepens over time:

**Level 0 — Read-only tenant (v1)**:
Read info pointers via `unpackClosure#`. Store values via `unsafeCoerce`
to `Any`. Force thunks via `seq`. Guest using Haskell ADTs as closures.

**Level 1 — Raw closure allocation**:
Allocate heap objects with specific payload layouts. Control which fields
are pointers vs non-pointers. Still use existing Haskell info tables.

**Level 2 — Custom info tables (target for v2)**:
Create info tables at runtime: closure type, GC layout bitmap, entry code
pointer. Allocate closures pointing to Grasp-defined info tables. GHC's GC
traces them natively — they are indistinguishable from Haskell closures.

**Level 3 — Custom entry code (future: JIT)**:
Emit machine code for closure entry. A compiled Grasp lambda is a closure
whose entry code runs generated native instructions calling primops
directly. No interpreter dispatch.

**Level 4 — RTS extension (far horizon)**:
Custom GC behavior per closure type. Custom scavenging, evacuation,
promotion. Grasp as a programmable GC policy language.

### Dual Interface

**REPL (dynamic scripting)**:
All values start as `?` (Any). Interpreter dispatch via info-pointer
checks. Interactive exploration of the RTS. Gradual annotation enables
partial compilation of hot paths.

**Haskell QuasiQuoter (compiled embedding)**:
`[grasp| ... |]` in Haskell source. Types inferred from Haskell context
(the surrounding type signature). Grasp code compiled to native closures
at Haskell compile time. The QQ is a compiler from Grasp to STG.

Both interfaces target the same RTS objects. A closure created in the REPL
and a closure created via QQ are the same kind of heap object.

## Formal References

The design draws on these foundational works:

1. **CBPV**: Levy, "Call-by-Push-Value" (2001) — the semantic spine,
   value/computation distinction
2. **Gradual Typing**: Siek & Taha, "Gradual Typing for Functional
   Languages" (2006) — the `?` type, consistency, cast insertion
3. **Coercion Calculus**: Henglein, "Dynamic Typing: Syntax and Proof
   Theory" (1994) — tag/check cost model, coercion reduction
4. **RuntimeRep**: Eisenberg & Peyton Jones, "Levity Polymorphism" (2017)
   — kinds as calling conventions, representation types
5. **STG**: Peyton Jones, "Implementing Lazy Functional Languages on Stock
   Hardware" (1992) — the operational foundation
6. **Data Layout**: DeYoung & Pfenning, "Data Layout from a Type-Theoretic
   Perspective" (2022) — type-theoretic control of memory layout,
   the `↓A` shift for controlling indirection
7. **Typed Closure Conversion**: Minamide, Morrisett & Harper (1996) —
   typing closures with existentials
8. **Typed Assembly Language**: Morrisett et al. (1999) — type-preserving
   compilation methodology

## Safety Model

Grasp is direct but not unsafe. "Direct" means operating on RTS objects
without abstraction barriers. "Safe" means the type discipline guarantees
operations are valid.

The safety guarantee is always present — it moves between compile-time
and runtime depending on available type information:

- **Fully typed** (QQ, annotated code): Safety checked at compile time.
  Checks erased. Runs at compiled Haskell speed. Like Haskell itself.
- **Partially typed** (gradual): Safety checked at compile time where
  types are known, at runtime (info-pointer checks, coercions) where
  types are `?`. Like Typed Racket.
- **Fully dynamic** (REPL, unannotated): Safety checked entirely at
  runtime via info-pointer discrimination. Like v1. Slower but always safe.

The type system does not restrict what you can express — it restricts
what can go wrong. An untyped Grasp program is safe (runtime checks
catch misuse). A typed Grasp program is safe AND fast (checks erased).
This is the ATS/Rust principle: direct control with guaranteed safety.

## What This Design Does NOT Cover

- Concrete syntax for type annotations
- Implementation plan for each RTS citizenship level
- Parser/evaluator architecture (to be designed separately)
- Specific primop surface exposed to Grasp
- Module system design
- Macro system interaction with types
- Error reporting and blame tracking for contract violations

These are subsequent design documents, each building on this foundation.

## Success Criteria

The foundation is solid if:

1. Every Grasp value is a valid GHC heap object (GC-safe, inspectable)
2. The type system has a formal semantics grounded in CBPV + gradual typing
3. "Compilation" has a precise meaning: resolving `?` to concrete types,
   eliminating interpreter dispatch, emitting direct primop calls
4. Haskell and Grasp interoperate without marshaling (same heap, same closures)
5. The architecture permits deepening RTS integration without redesign
