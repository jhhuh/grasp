# Related Work

Grasp occupies an unusual position: a dynamic language living on a runtime designed for a statically-typed, lazy, compiled language. To understand what makes this novel, it helps to compare with related projects.

## v1 to v2: what changed

v1 demonstrated that a dynamic Lisp could inhabit the STG machine as a native tenant. It proved the core thesis (shared heap, shared GC, closure-level interop) but treated Grasp primarily as "a Lisp on GHC."

v2 reframes Grasp as "a programmable interface to the GHC RTS" and adds formal foundations: CBPV as the semantic spine (with STM transactions as a first-class mode), gradual typing for the dynamic-to-compiled gradient, and Henglein coercions as the formal cost model for boundary crossings. This theoretical grounding distinguishes v2 from ad-hoc hosted language implementations -- compilation has a precise, formal meaning (resolving `?` to concrete types, eliminating dispatch).

## Lisps on other runtimes

### Clojure (JVM)

Clojure is a Lisp on the JVM. Like Grasp, it inhabits an existing runtime. Clojure values are JVM objects; it benefits from JVM's GC, JIT, and threading.

**Key difference**: The JVM was designed to host multiple languages (bytecode, classloaders, reflection, invokedynamic). The STG machine was built for exactly one language. Grasp must work at the closure level, below any official guest-language API.

### Fennel (Lua VM)

Fennel compiles Lisp to Lua source. Lua has a deliberately simple C API designed for embedding and extension.

**Key difference**: Lua's data structures (tables) are general-purpose. STG closures are specialized for lazy evaluation -- pointer tagging, update frames, info tables. Grasp must understand and work with this specialization.

### Hy (Python)

Hy compiles Lisp syntax to Python AST. It works at the AST level, producing the same code Python's compiler would.

**Key difference**: Grasp works at the closure level, below the compiler. It constructs STG closures directly.

### Janet

Janet is a Lisp with its own bytecode VM, GC, and C API, designed for embedding.

**Key difference**: Janet builds everything from scratch. Grasp reuses GHC's GC, scheduler, and closure representation. The tradeoff: less control, but access to a production-grade runtime.

## Dynamic languages on GHC

### GHCi

GHCi is GHC's interactive REPL. It runs on the same STG machine.

**Key difference**: GHCi is not a different language. Every expression goes through GHC's full pipeline (parser, renamer, typechecker, desugarer, simplifier, code generator). The result is bytecode (BCOs) run by the RTS interpreter. Grasp bypasses all of this -- it has its own parser, its own evaluator, and constructs closures without involving Haskell's compilation infrastructure.

### `hint` (Haskell interpreter library)

`hint` embeds the GHC API for evaluating Haskell expressions at runtime.

**Key difference**: `hint` interprets Haskell, carrying the full weight of GHC's compiler. Grasp interprets its own language with a lightweight tree-walking evaluator.

### GHC Plugins and Template Haskell

Both operate at compile time -- they extend GHC's compiler, not its runtime. Grasp operates at runtime, constructing closures on the live heap.

### Husk Scheme

Husk is a Scheme interpreter written in Haskell. It implements R5RS and parts of R7RS.

**Key difference**: Husk is a Lisp **written in** Haskell. Its values are Haskell ADTs (`LispVal`), its environments are Haskell maps, and the relationship with the runtime is incidental. Grasp values ARE native STG closures (`GraspVal = Any`). A Grasp integer is a real `I#` on the GHC heap. Type discrimination reads info-table pointers via `unpackClosure#`. The relationship is symbiotic.

### Liskell

Liskell put Lisp syntax on Haskell -- S-expressions translated to Haskell AST, then compiled through GHC's normal pipeline.

**Key difference**: Liskell was a syntax skin over Haskell. Grasp is genuinely dynamic and untyped (at the REPL level), with a path toward gradual typing.

### Hackett

Hackett combines Haskell's type system with Racket's macro system. It runs on Racket's VM, not GHC's.

## Graph reduction machines

### The G-machine

The original G-machine (1984, Augustsson & Johnsson) compiled lazy programs to sequential graph reduction code. The STG machine is its spiritual descendant.

### GRIP and ALICE

Parallel graph reduction machines from the late 1980s. GHC's threaded RTS (parallel GC, green threads) is the software descendant of this research.

### OLisp

OLisp (1992) implemented an object-oriented Lisp on a graph reduction machine -- the closest historical precedent to Grasp.

**Key difference**: OLisp targeted a custom graph reduction machine. Grasp targets GHC's STG machine, a mature production runtime.

## What makes Grasp novel

1. **Not a syntax skin**: Grasp is a different language with its own evaluator, not a frontend for Haskell's compiler.

2. **Not just "written in Haskell"**: Grasp values ARE native STG closures (`GraspVal = Any`). The relationship with the runtime is symbiotic, not incidental.

3. **Not just FFI**: Grasp constructs closures on the GHC heap, shares GC and scheduler, and discriminates types by reading info-table pointers. Interop happens at the closure level.

4. **Not a custom runtime**: Grasp reuses GHC's GC, scheduler, and closure representation rather than building its own.

5. **Formally grounded**: Unlike most hosted language implementations, Grasp v2 has a formal semantic spine (CBPV), a formal type discipline (gradual typing), and a formal cost model for boundary crossings (Henglein coercions). "Compilation" is not an optimization -- it is a precisely defined operation: resolving `?` to concrete types, eliminating interpreter dispatch.

The result is a design point that hasn't been explored: a formally-grounded dynamic language that is a native tenant of a runtime designed for a static, compiled language, with a precise theory for the gradient between interpretation and compilation.
