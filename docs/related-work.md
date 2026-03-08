# Related Work

Grasp occupies an unusual position: a dynamic Lisp living on a runtime designed for a statically-typed, lazy, compiled language. To understand what makes this novel, it helps to compare with related projects.

## Lisps on other runtimes

### Clojure (JVM)

Clojure is a Lisp dialect that runs on the Java Virtual Machine. It's the most successful example of a hosted Lisp, with a large ecosystem and production adoption.

**How it relates**: Like Grasp, Clojure chose to inhabit an existing runtime rather than build its own. Clojure values are JVM objects, and Clojure benefits from the JVM's GC, JIT compiler, and threading model.

**How it differs**: The JVM was **designed** to host multiple languages. It provides bytecode, classloaders, reflection, and invokedynamic. Clojure compiles to JVM bytecode and runs as JVM classes. The STG machine has none of this infrastructure — it was built for exactly one language. Grasp must use the RTS C API (designed for FFI, not language hosting) to interface with the runtime.

### Fennel (Lua VM)

Fennel is a Lisp that compiles to Lua source code. It produces Lua tables, functions, and coroutines.

**How it relates**: Fennel inhabits Lua's runtime, sharing its GC and data structures.

**How it differs**: Lua has a deliberately simple, clean C API that was designed for embedding and extension. Lua tables are a general-purpose data structure that any language can use. The STG machine's closure representation is specialized for lazy evaluation — pointer tagging, update frames, info tables.

### Hy (Python)

Hy compiles Lisp syntax to Python AST. It's essentially a different surface syntax for Python.

**How it relates**: Hy values are Python objects, traced by Python's GC.

**How it differs**: Hy works at the AST level — it produces the same code Python's compiler would. Grasp works at the closure level — it constructs STG closures directly, below the level of Haskell's compiler.

### Janet

Janet is a Lisp with its own bytecode VM, GC, and C API. It was designed to be embedded in C applications, similar to Lua.

**How it differs**: Janet builds everything from scratch. It doesn't share a runtime with any other language. This gives it full control but means it can't directly call into a host language's functions at the closure level.

## Dynamic languages on GHC

### GHCi

GHCi is GHC's interactive environment. It provides a REPL for Haskell, with the ability to evaluate expressions, load modules, and inspect types.

**How it relates**: GHCi runs on the same STG machine as compiled Haskell.

**How it differs critically**: GHCi is not a different language — it's a frontend for Haskell. Every expression goes through GHC's full compilation pipeline: parsing, renaming, typechecking, desugaring, simplification, code generation. The result is GHC bytecode (BCOs) that runs on a bytecode interpreter in the RTS. You cannot use GHCi without Haskell's type system, module system, and compilation infrastructure.

Grasp bypasses all of this. It has its own parser that produces S-expressions, its own evaluator, and constructs closures through the RTS C API. No Haskell source code is involved in evaluating a Grasp expression.

### `hint` (Haskell interpreter library)

`hint` is a library that embeds GHCi's API in Haskell applications. You can evaluate Haskell expressions at runtime from within a Haskell program.

**How it differs**: `hint` interprets Haskell, not a different language. It shells out to the GHC API, which means it carries the full weight of GHC's compiler infrastructure.

### GHC Plugins and Template Haskell

GHC plugins can transform Core (GHC's intermediate representation) at compile time. Template Haskell generates Haskell AST at compile time.

**How they differ**: Both operate during compilation, not at runtime. They extend GHC's compiler, not its runtime. Grasp operates at runtime, constructing closures on the live heap.

### Husk Scheme

Husk is a Scheme interpreter written in Haskell. It implements R5RS and parts of R7RS.

**How it relates**: Like Grasp, it's a Lisp implemented in Haskell.

**How it differs fundamentally**: Husk is a Lisp **written in** Haskell. Its values are Haskell ADTs (`LispVal` data type), its environments are Haskell maps, and its evaluator is a Haskell function. It uses Haskell as an implementation language the way one might use C or Java. It does not interact with the STG machine at the closure level.

Grasp values ARE native STG closures (`GraspVal = Any` from `GHC.Exts`). A Grasp integer IS a Haskell `I#`. Type discrimination reads info-table pointers via `unpackClosure#`. The relationship with the runtime is symbiotic, not incidental.

### Liskell

Liskell was a project that put Lisp syntax on Haskell. You wrote S-expressions that were translated to Haskell AST, then compiled through GHC's normal pipeline.

**How it differs**: Liskell was a syntax skin over Haskell, not a separate language. It still went through typechecking, desugaring, and optimization. Grasp is genuinely dynamic and untyped.

### Hackett

Hackett is an experimental language by Alexis King that combines Haskell's type system with Racket's macro system.

**How it differs**: Hackett runs on Racket's VM, not GHC's. It shares Racket's runtime, not GHC's STG machine.

## Graph reduction machines

The STG machine descends from a lineage of graph reduction machines. Understanding these shows where Grasp's runtime substrate comes from.

### The G-machine

The original G-machine (1984, Augustsson & Johnsson) compiled lazy functional programs to sequential code that reduced graphs. The STG machine is its spiritual descendant, with major improvements to closure representation, argument passing, and garbage collection.

### GRIP and ALICE

GRIP (Graph Reduction In Parallel) and ALICE were parallel graph reduction machines from the late 1980s. They explored hardware-level parallelism for functional languages.

**How they relate**: GHC's threaded RTS (with its parallel GC and green threads) is the software descendant of this line of research. When Grasp uses `rts_eval`, it's using a scheduler that embodies decades of parallel graph reduction research.

### OLisp

OLisp (1992) was a research project that implemented an object-oriented Lisp on a graph reduction machine. It's the closest historical precedent to Grasp: a Lisp that runs on graph reduction.

**How Grasp differs**: OLisp targeted a custom graph reduction machine. Grasp targets GHC's STG machine — a mature, production-grade runtime with a sophisticated GC, scheduler, and memory model.

## What makes Grasp novel

No existing project has attempted what Grasp is exploring:

1. **Not a syntax skin**: Unlike Liskell or similar projects, Grasp is a genuinely different language with its own evaluator. It doesn't go through Haskell's type system or compilation pipeline.

2. **Not just "written in Haskell"**: Unlike Husk Scheme, Grasp's values ARE native STG closures (`GraspVal = Any`). A Grasp integer is a real `I#` on the GHC heap. The relationship is symbiotic, not incidental.

3. **Not just FFI**: Grasp doesn't merely call Haskell functions across an FFI boundary. It constructs closures on the GHC heap, applies functions through the STG machine's own `rts_apply`, and evaluates through the STG scheduler's own `rts_eval`. The interop happens at the closure level, not the function-call level.

4. **Not a custom runtime**: Unlike Janet, CHICKEN, or other standalone Lisps, Grasp doesn't build its own GC, scheduler, or closure representation. It uses GHC's.

The result is a design point that hasn't been explored: a dynamic language that is a **native tenant** of a runtime designed for a static, compiled language, sharing its heap, GC, and evaluation machinery at the closure level.
