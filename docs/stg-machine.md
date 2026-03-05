# The STG Machine

This document explains the runtime substrate that Grasp inhabits: GHC's Spineless Tagless G-machine. Understanding the STG machine is essential for understanding what Grasp does and where it's headed.

## What is the STG machine?

The STG machine is GHC's abstract machine for executing lazy functional programs. It was introduced by Simon Peyton Jones in 1992 and has been refined continuously since. The name stands for:

- **Spineless** — no central evaluation stack ("spine") for application nodes
- **Tagless** — (historically) closures don't carry a tag indicating their evaluation state; instead, the code pointer in the info table handles this. Modern GHC actually uses pointer tagging for performance, but the name persists.
- **G-machine** — a **Graph reduction** machine. Programs are represented as graphs of closures (nodes), and evaluation proceeds by reducing (rewriting) these graphs.

## Closures

Everything on the GHC heap is a **closure** — a contiguous block of memory with a fixed layout:

```
┌──────────────┬──────────────┬──────────────┐
│  Info Pointer │  Payload[0]  │  Payload[1]  │  ...
└──────┬───────┴──────────────┴──────────────┘
       │
       ▼
┌──────────────────────────────────────────────┐
│              Info Table                       │
│  ┌──────────┬──────────┬──────────┬────────┐ │
│  │ closure  │ GC info  │ layout   │ entry  │ │
│  │  type    │ (ptrs,   │          │ code   │ │
│  │          │ non-ptrs)│          │        │ │
│  └──────────┴──────────┴──────────┴────────┘ │
└──────────────────────────────────────────────┘
```

The **info pointer** is the first word of every closure. It points to a statically-allocated **info table** that describes the closure's type, layout, and behavior. With `TABLES_NEXT_TO_CODE` (the default on most platforms), the info table sits immediately before the entry code in memory, so the info pointer also serves as the code pointer.

The **payload** contains the closure's data: pointers to other closures and raw unboxed values. The info table tells the GC which payload words are pointers (and therefore need to be traced) versus non-pointers.

## Closure Types

GHC classifies closures by their **closure type**, stored in the info table. The main types relevant to Grasp:

### `CONSTR` — Data constructors

Fully evaluated data. A `CONSTR` closure is in weak head normal form (WHNF). Entering a `CONSTR` just returns it. Examples: the `Just` in `Just 42`, the `:` in `1 : []`.

```
CONSTR (tag=0, ptrs=2, nptrs=0)
  payload: [ptr_to_head, ptr_to_tail]
```

The **constructor tag** distinguishes alternatives in a data type (e.g., `Nothing` = 0, `Just` = 1).

### `FUN` — Function closures

A function that hasn't been fully applied. Its info table contains the **arity** (number of arguments needed). If you apply a `FUN` to fewer arguments than its arity, you get a `PAP`.

### `THUNK` — Unevaluated expressions

A suspended computation. When entered (forced), the thunk executes its code, overwrites itself with the result (an **update**), and returns the result. This is how laziness works: a thunk is created cheaply, and only computed when needed.

The overwrite mechanism uses a `BLACKHOLE` — when a thunk begins evaluation, it's immediately overwritten with a `BLACKHOLE`. This serves two purposes:
1. Detects infinite loops (re-entering a `BLACKHOLE` is an error)
2. Allows the GC to collect values referenced only by the thunk's now-executing code

### `PAP` — Partial application

A function applied to some but not all of its arguments. For example, if `f` has arity 3 and you apply it to 2 arguments, the result is a `PAP` containing `f` plus the 2 arguments. Applying the `PAP` to one more argument completes the application.

### `AP` — Generic application

An unevaluated function application. Similar to a `THUNK` but created by the runtime rather than the compiler. `rts_apply` creates `AP` closures.

### `IND` — Indirection

A pointer that says "the real value is over there." Created when a thunk is updated: the thunk becomes an indirection pointing to its result. The GC eventually "shorts out" indirections.

### `BLACKHOLE`

A thunk currently being evaluated. If another thread tries to enter a `BLACKHOLE`, it blocks until the evaluating thread finishes — this is how GHC's runtime implements synchronization for shared thunks.

## Evaluation

Evaluation in the STG machine means **entering a closure**. What happens depends on the closure type:

| Closure type | On entry |
|-------------|----------|
| `CONSTR` | Return immediately (already in WHNF) |
| `FUN` | Return immediately (functions are values) |
| `THUNK` | Execute code, update with result, return result |
| `PAP` | Return immediately (partial apps are values) |
| `AP` | Push continuation, enter the function |
| `IND` | Follow pointer, enter the target |
| `BLACKHOLE` | Block (wait for evaluating thread) |

Evaluation to **WHNF** (weak head normal form) means reducing until the top-level closure is a `CONSTR`, `FUN`, or `PAP`. The "weak head" part means we don't evaluate inside data constructors — `Just (1+2)` is in WHNF even though its argument is a thunk.

## The RTS C API

GHC exposes a C API for constructing and evaluating closures from outside the Haskell world. This API was designed for `foreign export` interop, but Grasp uses it as a language substrate.

### Key functions

```c
// Capability management
Capability* rts_lock(void);        // Acquire a capability
void        rts_unlock(Capability* cap);  // Release a capability

// Constructing closures
HaskellObj rts_mkInt   (Capability* cap, HsInt val);
HaskellObj rts_mkWord  (Capability* cap, HsWord val);
HaskellObj rts_mkDouble(Capability* cap, HsDouble val);
HaskellObj rts_mkChar  (Capability* cap, HsChar val);
HaskellObj rts_mkBool  (Capability* cap, HsBool val);

// Application
HaskellObj rts_apply(Capability* cap, HaskellObj fn, HaskellObj arg);

// Evaluation
void rts_eval  (Capability** cap, HaskellObj p, HaskellObj* ret);
void rts_evalIO(Capability** cap, HaskellObj p, HaskellObj* ret);

// Extracting values
HsInt    rts_getInt   (HaskellObj obj);
HsWord   rts_getWord  (HaskellObj obj);
HsDouble rts_getDouble(HaskellObj obj);
HsChar   rts_getChar  (HaskellObj obj);
HsBool   rts_getBool  (HaskellObj obj);
```

### Capabilities

A **Capability** is a GHC concept representing the right to execute Haskell code. The threaded RTS has one capability per `-N` thread. `rts_lock()` acquires one (blocking if all are busy), and `rts_unlock()` releases it.

You must hold a capability to:
- Allocate on the GHC heap (`rts_mkInt`, etc.)
- Apply functions (`rts_apply`)
- Evaluate closures (`rts_eval`)

The capability also serves as GC synchronization — the GC can only run when it has stopped all capabilities.

### `rts_apply` in detail

`rts_apply(cap, f, arg)` creates an `AP` closure on the heap:

```
AP closure:
  info_ptr → stg_AP_info
  payload:  [fn, arg]
```

This doesn't evaluate anything. It just builds a graph node representing "apply f to arg." The evaluation happens when `rts_eval` forces the `AP`.

For multi-argument functions, you chain `rts_apply` calls:

```c
// Haskell: f x y
HaskellObj app1 = rts_apply(cap, f, x);   // f x   (an AP)
HaskellObj app2 = rts_apply(cap, app1, y); // f x y (an AP of an AP)
rts_eval(&cap, app2, &result);            // evaluate
```

### `rts_eval` in detail

`rts_eval(&cap, p, &ret)` enters the closure `p` and evaluates it to WHNF. This invokes the full STG machine:

1. Enter the closure (follow the info pointer to the entry code)
2. If it's a thunk, execute the thunk's code
3. Handle partial applications, stack frames, GC if needed
4. Return when the result is in WHNF
5. Store the result in `*ret`

The `cap` pointer may change during evaluation (e.g., if a GC relocates the capability), which is why it's passed by pointer.

## Garbage Collection

GHC's garbage collector is a **generational, copying, parallel** collector:

- **Generational**: New allocations go into generation 0 (the "nursery"). Surviving objects are promoted to older generations. Young-generation collections are fast because most objects die young.
- **Copying**: Live objects are copied to a new space, leaving behind only garbage. No fragmentation.
- **Parallel**: Multiple GC threads can work on the same collection.

For Grasp, the key property is that **any `HaskellObj` returned by `rts_mk*` or `rts_apply` is a real heap object traced by the GC**. Grasp doesn't need its own garbage collector — GHC's GC handles everything.

The one caveat is `StablePtr`: a `StablePtr` is a GC root that pins an object. Grasp must `freeStablePtr` when done, or the pointed-to closure (and everything it references) will never be collected.

## Pointer Tagging

Modern GHC uses **pointer tagging** as a performance optimization. The low bits of a pointer (which are always zero due to alignment) encode information about the pointed-to closure:

- Tag 0: unknown or unevaluated
- Tag 1-6: evaluated constructor, tag indicates which alternative
- Tag 7: (on 64-bit) too many alternatives to encode, or other

This means you can often avoid entering a closure just by checking the pointer tag. If the tag says "evaluated constructor #2," you know it's in WHNF without following the pointer.

Pointer tagging is transparent to the RTS C API — `rts_eval` handles it automatically.

## Why this matters for Grasp

Currently, Grasp uses the RTS C API to construct and evaluate closures. Grasp's own values (`LispVal`) are Haskell ADTs — they live on the GHC heap as `CONSTR` closures, but they're "just" Haskell data.

The long-term vision is for Grasp to construct **its own closures** with custom info tables — closures that the STG machine evaluates directly, without going through a Haskell evaluator. This would make Grasp values truly native:

- A Grasp integer would be an `Int#` in an `StgClosure`, indistinguishable from a Haskell `Int`
- A Grasp function would be a `FUN` closure with a code pointer that jumps into Grasp evaluation
- A Grasp lazy expression would be a `THUNK` that the STG machine forces using its normal mechanism
- GHC's GC would trace Grasp closures exactly as it traces Haskell closures

This is what "native tenant of the STG machine" means: Grasp wouldn't call into the STG machine — it would be part of it.
