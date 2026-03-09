# grasp0: C-Native Foundation Design

**Date**: 2026-03-09
**Status**: Implemented

## Vision

Grasp's value representation is built entirely in C, directly on the GHC
RTS. No Haskell ADTs. No `unsafeCoerce`. The foundation is four C functions
and two info tables.

The GHC RTS is pure C/Cmm/asm. Grasp's foundation should be the same.
Haskell code comes later — for the evaluator, interop, QuasiQuoter — but
the realm Grasp lives in is C, speaking the RTS's own language.

## Minimal Core

### Four functions

```c
GraspInfo*   grasp_make_info(uint32_t ptrs, uint32_t nptrs, uint32_t tag);
StgClosure*  grasp_alloc(Capability* cap, GraspInfo* info, StgClosure** fields, uint32_t n);
StgClosure*  grasp_field(StgClosure* c, uint32_t i);
GraspInfo*   grasp_info(StgClosure* c);
```

- **`grasp_make_info`** — Create a `StgInfoTable` at runtime for a CONSTR
  closure with `ptrs` pointer fields, `nptrs` non-pointer fields, and a
  constructor `tag`. Returns an info pointer. The info table lives in
  executable memory (required by TABLES_NEXT_TO_CODE) and persists for the
  lifetime of the process.

- **`grasp_alloc`** — Allocate a closure on the GHC heap via `allocate()`,
  set its info pointer, fill payload words from the `fields` array. Returns
  a pointer-tagged `StgClosure*`. This is a first-class GHC heap object —
  the GC traces it, moves it, promotes it.

- **`grasp_field`** — Read the i-th payload word from a closure. No type
  checking — the caller must know the layout (from the info table).

- **`grasp_info`** — Read the info pointer from a closure's header. This
  is type identity: two closures have the same type iff they have the same
  info pointer.

### Two info tables, everything is lists

```
nil_info  = grasp_make_info(0, 0, 0)   // no fields, tag 0
cons_info = grasp_make_info(2, 0, 1)   // two pointer fields (car, cdr), tag 1
```

From cons and nil, everything is structure:

```
integer    → (cons 'int 42)           // tag + unboxed value
symbol     → (cons 'sym <ptr>)        // tag + pointer to name
string     → (cons 'str <ptr>)        // tag + pointer to chars
lambda     → (cons 'fn (cons params (cons body env)))
env        → list of (cons name value) pairs
```

This is Lisp: the only data structure is the pair. "Types" are
conventions — a symbol is a cons whose car is the symbol tag. The
evaluator enforces these conventions, not the representation layer.

Later, when performance matters, we can promote hot types to their own
info tables (a dedicated `int_info` with 0 pointer fields and 1
non-pointer field, avoiding the cons overhead). But the bootstrap needs
only two.

## RTS Surface

The C library stands on five RTS functions:

| Function | Purpose |
|----------|---------|
| `hs_init(argc, argv)` | Boot the RTS |
| `rts_lock()` | Acquire a Capability (permission to allocate) |
| `rts_unlock(cap)` | Release the Capability |
| `allocate(cap, n)` | Allocate n words on the GHC heap |
| `performMajorGC()` | Trigger garbage collection (for testing) |

Plus `mmap` (or platform equivalent) for allocating executable memory for
info tables.

No other RTS internals are needed. This is the entire foundation.

## TABLES_NEXT_TO_CODE

GHC's default mode places the info table at a negative offset from the
entry code in memory:

```
memory: [...info table fields...][entry code bytes...]
                                  ^── info pointer points here
```

For CONSTR closures, the entry code is trivial — it returns to the
continuation on the stack. On x86_64:

```asm
jmp *(%rbp)     // jump to return address (2 bytes)
```

To create an info table at runtime:

1. `mmap` a page with `PROT_READ | PROT_WRITE | PROT_EXEC`
2. Write `StgInfoTable` fields at the start
3. Write the entry code stub immediately after
4. The "info pointer" is the address of the entry code (right after the
   info table struct)

All CONSTR closures of the same arity can share one entry code stub.
The constructor tag is stored in the info table's `srt` field (GHC's
convention for CONSTR), so `grasp_make_info(2, 0, 0)` and
`grasp_make_info(2, 0, 1)` can share entry code but have different tags.

### Entry code detail

GHC's CONSTR entry code on x86_64 does:

1. Tag the pointer: set low bits of the closure pointer to the constructor
   tag (for pointer tagging optimization)
2. Return to the stack continuation

For the bootstrap, a minimal stub that just returns without tagging is
sufficient. Pointer tagging is an optimization we can add later.

## Closure Layout

A Grasp closure on the GHC heap:

```
┌─────────────────┬────────────┬────────────┬─────┐
│  info pointer   │ payload[0] │ payload[1] │ ... │
│  (1 word)       │ (1 word)   │ (1 word)   │     │
└─────────────────┴────────────┴────────────┴─────┘
```

- **info pointer** — points to our C-created info table. Tells the GC
  how many pointer fields to trace.
- **payload** — pointer fields first, then non-pointer fields. The GC
  scans `ptrs` words as pointers and ignores `nptrs` words.

For the two-info-table bootstrap:

```
nil:   [nil_info]                        (1 word total)
cons:  [cons_info][car][cdr]             (3 words total)
```

## GC Safety

The GC must correctly trace Grasp closures. This works because:

1. Our info tables have correct `layout.payload.ptrs` and
   `layout.payload.nptrs` counts
2. `allocate()` returns nursery memory that the GC knows about
3. The closure type field is set to `CONSTR` (or appropriate variant:
   `CONSTR_1_0`, `CONSTR_2_0`, etc.)
4. Pointer fields come first in the payload (GHC's convention)

**The proof**: allocate a closure, trigger `performMajorGC()`, read the
fields back. If the values survive, the GC traced correctly. If not, it
crashes.

**GC roots**: closures referenced only from the C stack are not GC roots.
They can be collected. For the test harness, we either:
- Use `StablePtr` to pin closures during the test
- Keep closures reachable from a GC-traced root (e.g., store them in
  another heap closure)
- Run the test without yielding (no GC between alloc and read)

For the bootstrap test, `StablePtr` is the simplest approach.

## Files

```
cbits/grasp_rts.h       — public API (the four functions)
cbits/grasp_rts.c       — implementation (info tables, allocation)
cbits/grasp_boot.c      — C main(), boots RTS, exercises the library
```

### Build

```bash
ghc -no-hs-main -threaded \
    cbits/grasp_rts.c cbits/grasp_boot.c \
    -o grasp_boot
```

`-no-hs-main` tells GHC there's no Haskell — we provide our own C
`main()`. GHC is used purely as a C compiler/linker that knows where
`Rts.h` and `libHSrts` live.

### Test program

```c
int main(int argc, char** argv) {
    hs_init(&argc, &argv);
    Capability* cap = rts_lock();

    // Create the two fundamental types
    GraspInfo* nil_info  = grasp_make_info(0, 0, 0);
    GraspInfo* cons_info = grasp_make_info(2, 0, 1);

    // Build: (cons 42 nil)
    StgClosure* val = rts_mkInt(cap, 42);
    StgClosure* nil = grasp_alloc(cap, nil_info, NULL, 0);
    StgClosure* cell = grasp_alloc(cap, cons_info,
                         (StgClosure*[]){val, nil}, 2);

    // Read back
    assert(rts_getInt(grasp_field(cell, 0)) == 42);
    assert(grasp_info(grasp_field(cell, 1)) == nil_info);

    // GC survival test
    // (pin cell as StablePtr so GC doesn't collect it)
    StablePtr sp = getStablePtr(cell);
    performMajorGC();
    cell = deRefStablePtr(sp);
    assert(rts_getInt(grasp_field(cell, 0)) == 42);
    printf("GC survival: PASS\n");

    // Type discrimination
    assert(grasp_info(cell) == cons_info);
    assert(grasp_info(nil) == nil_info);
    printf("Type discrimination: PASS\n");

    // Nested structure: (cons 1 (cons 2 nil))
    StgClosure* v1 = rts_mkInt(cap, 1);
    StgClosure* v2 = rts_mkInt(cap, 2);
    StgClosure* inner = grasp_alloc(cap, cons_info,
                          (StgClosure*[]){v2, nil}, 2);
    StgClosure* outer = grasp_alloc(cap, cons_info,
                          (StgClosure*[]){v1, inner}, 2);
    assert(rts_getInt(grasp_field(outer, 0)) == 1);
    assert(rts_getInt(grasp_field(grasp_field(outer, 1), 0)) == 2);
    printf("Nested cons: PASS\n");

    freeStablePtr(sp);
    rts_unlock(cap);
    hs_exit();
    return 0;
}
```

## Success Criteria

1. `grasp_boot` compiles with zero Haskell source files
2. Closures allocated by `grasp_alloc` survive `performMajorGC()`
3. `grasp_field` reads back correct values after GC
4. `grasp_info` returns the correct info pointer for type discrimination
5. Nested cons structures (lists) work correctly
6. The entire test runs without segfault or GC panic

## What This Design Does NOT Cover

- The evaluator (that's Haskell or Grasp code, built later on this foundation)
- Unboxed fields (Int#, Double#) — all fields are pointers for now
- FUN/THUNK closures — only CONSTR for now
- Pointer tagging optimization — deferred
- Thread safety beyond single-capability use
- The transition from current Haskell ADTs to C-native closures

## Relationship to Current Code

The existing Haskell evaluator (`src/Grasp/Eval.hs`) and its ADT-based
value representation (`src/Grasp/NativeTypes.hs`) continue to work
unchanged. The C bootstrap is a parallel foundation. Once proven, the
Haskell layer can be rewritten to use C-allocated closures instead of
ADTs — but that's a separate design decision.

The C foundation is Grasp's realm. Haskell visits.
