# C-Native Bootstrap Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a pure C library that creates GHC heap closures with runtime-created info tables, proving Grasp can define its own types without Haskell.

**Architecture:** Four C functions (`grasp_make_info`, `grasp_alloc`, `grasp_field`, `grasp_info`) backed by `mmap` for executable info table memory and the RTS `allocate()` for heap objects. A C test harness boots the RTS via `hs_init()`, creates cons/nil closures, and proves GC survival. Zero Haskell source files.

**Tech Stack:** C99, GHC 9.8.4 RTS headers (`Rts.h`), x86_64 Linux, `mmap` for executable memory

**RTS Reference:** All headers are at `$(ghc --print-libdir)/lib/x86_64-linux-ghc-9.8.4/rts-1.0.2/include/`

---

### Task 1: Verify RTS Layout Assumptions

Before writing any allocation code, we must confirm the exact byte layout of `StgInfoTable` and `StgClosure` under TABLES_NEXT_TO_CODE.

**Files:**
- Create: `cbits/grasp_layout_check.c`

**Step 1: Write the layout verification program**

```c
// cbits/grasp_layout_check.c
#include "Rts.h"
#include <stdio.h>
#include <stddef.h>

int main(int argc, char** argv) {
    hs_init(&argc, &argv);

    printf("=== GHC RTS Layout Check (GHC 9.8.4, x86_64) ===\n\n");

    // 1. Confirm TABLES_NEXT_TO_CODE
#if defined(TABLES_NEXT_TO_CODE)
    printf("TABLES_NEXT_TO_CODE: ENABLED\n");
#else
    printf("TABLES_NEXT_TO_CODE: DISABLED\n");
#endif

    // 2. StgInfoTable layout
    printf("\nsizeof(StgInfoTable)  = %zu\n", sizeof(StgInfoTable));
    printf("offsetof(layout)      = %zu\n", offsetof(StgInfoTable, layout));
    printf("offsetof(type)        = %zu\n", offsetof(StgInfoTable, type));
    printf("offsetof(srt)         = %zu\n", offsetof(StgInfoTable, srt));
#if defined(TABLES_NEXT_TO_CODE)
    printf("offsetof(code)        = %zu\n", offsetof(StgInfoTable, code));
#endif
    printf("sizeof(StgClosureInfo)= %zu\n", sizeof(StgClosureInfo));
    printf("sizeof(StgHalfWord)   = %zu\n", sizeof(StgHalfWord));
    printf("sizeof(StgSRTField)   = %zu\n", sizeof(StgSRTField));

    // 3. StgClosure layout
    printf("\nsizeof(StgClosure)    = %zu\n", sizeof(StgClosure));
    printf("sizeof(StgHeader)     = %zu\n", sizeof(StgHeader));
    printf("offsetof(header)      = %zu\n", offsetof(StgClosure, header));
    printf("offsetof(payload)     = %zu\n", offsetof(StgClosure, payload));

    // 4. Word size
    printf("\nsizeof(StgWord)       = %zu\n", sizeof(StgWord));
    printf("sizeof(StgPtr)        = %zu\n", sizeof(StgPtr));
    printf("sizeof(void*)         = %zu\n", sizeof(void*));

    // 5. Closure type constants
    printf("\nCONSTR     = %d\n", CONSTR);
    printf("CONSTR_1_0 = %d\n", CONSTR_1_0);
    printf("CONSTR_0_1 = %d\n", CONSTR_0_1);
    printf("CONSTR_2_0 = %d\n", CONSTR_2_0);
    printf("CONSTR_1_1 = %d\n", CONSTR_1_1);
    printf("CONSTR_0_2 = %d\n", CONSTR_0_2);

    // 6. Verify get_itbl round-trip with a known closure
    Capability* cap = rts_lock();
    HaskellObj fortytwo = rts_mkInt(cap, 42);
    const StgInfoTable* info = get_itbl((StgClosure*)fortytwo);
    printf("\nrts_mkInt(42) info table:\n");
    printf("  type = %d (expect CONSTR_0_1 = %d)\n", info->type, CONSTR_0_1);
    printf("  layout.payload.ptrs  = %d\n", info->layout.payload.ptrs);
    printf("  layout.payload.nptrs = %d\n", info->layout.payload.nptrs);
    printf("  closure info ptr     = %p\n", (void*)((StgClosure*)fortytwo)->header.info);
    printf("  get_itbl result      = %p\n", (void*)info);
    printf("  difference           = %zd bytes\n",
           (char*)((StgClosure*)fortytwo)->header.info - (char*)info);
    rts_unlock(cap);

    printf("\n=== Layout check complete ===\n");

    hs_exit();
    return 0;
}
```

**Step 2: Build and run**

```bash
nix develop -c ghc -no-hs-main -threaded -rtsopts \
    cbits/grasp_layout_check.c -o grasp_layout_check
./grasp_layout_check
```

Expected: prints all sizes and offsets. Key things to confirm:
- TABLES_NEXT_TO_CODE is ENABLED
- `sizeof(StgInfoTable)` — we need the exact size for mmap allocation
- The difference between `closure->header.info` and `get_itbl()` result — this is the negative offset (should equal `sizeof(StgInfoTable)` minus the code[] member)
- `rts_mkInt(42)` has type `CONSTR_0_1` with ptrs=0, nptrs=1

**Step 3: Record the values**

Write the output as a comment at the top of `grasp_rts.c` (created in Task 2). These are the constants we build on.

**Step 4: Commit**

```bash
git add cbits/grasp_layout_check.c
git commit -m "chore: add RTS layout verification program"
```

---

### Task 2: Implement `grasp_make_info`

Create info tables at runtime using `mmap` for executable memory. Each info table is a `StgInfoTable` followed by a short entry code stub, allocated together so TNTC layout is satisfied.

**Files:**
- Create: `cbits/grasp_rts.h`
- Create: `cbits/grasp_rts.c`

**Step 1: Write the header**

```c
// cbits/grasp_rts.h
#pragma once
#include "Rts.h"

// Opaque handle to a Grasp-created info table.
// With TNTC, this points to the code[] part (same as closure->header.info).
typedef const StgInfoTable* GraspInfo;

// Create a CONSTR info table with the given layout.
// ptrs:  number of pointer fields in payload
// nptrs: number of non-pointer fields in payload
// tag:   constructor tag (stored in srt field)
// Returns NULL on failure.
GraspInfo grasp_make_info(uint32_t ptrs, uint32_t nptrs, uint32_t tag);

// Allocate a closure on the GHC heap with the given info table.
// Payload words are copied from the fields array.
// n must equal ptrs + nptrs from the info table.
// Returns a pointer to the new closure (NOT pointer-tagged).
StgClosure* grasp_alloc(Capability* cap, GraspInfo info,
                        StgClosure** fields, uint32_t n);

// Read the i-th payload word from a closure.
StgClosure* grasp_field(StgClosure* closure, uint32_t i);

// Read the info pointer from a closure (type identity).
GraspInfo grasp_info(StgClosure* closure);

// Read ptrs/nptrs/tag from an info table.
uint32_t grasp_info_ptrs(GraspInfo info);
uint32_t grasp_info_nptrs(GraspInfo info);
uint32_t grasp_info_tag(GraspInfo info);
```

**Step 2: Write the implementation — `grasp_make_info`**

```c
// cbits/grasp_rts.c
#include "grasp_rts.h"
#include <sys/mman.h>
#include <string.h>
#include <stdio.h>

// Entry code stub: a single UD2 instruction (0F 0B).
// This crashes if a Grasp CONSTR is ever "entered" by the STG machine.
// For evaluated CONSTR closures this should never happen — the GC reads
// the info table metadata but never jumps to the entry code.
// Proper entry code (return to continuation) is a future task.
static const uint8_t ENTRY_STUB[] = { 0x0f, 0x0b };  // ud2
#define ENTRY_STUB_SIZE sizeof(ENTRY_STUB)

// Choose the appropriate CONSTR_x_y closure type constant.
static StgHalfWord constr_type(uint32_t ptrs, uint32_t nptrs) {
    // GHC uses specialized types for small arities
    if (ptrs == 0 && nptrs == 0) return CONSTR_NOCAF;
    if (ptrs == 1 && nptrs == 0) return CONSTR_1_0;
    if (ptrs == 0 && nptrs == 1) return CONSTR_0_1;
    if (ptrs == 2 && nptrs == 0) return CONSTR_2_0;
    if (ptrs == 1 && nptrs == 1) return CONSTR_1_1;
    if (ptrs == 0 && nptrs == 2) return CONSTR_0_2;
    return CONSTR;  // generic
}

GraspInfo grasp_make_info(uint32_t ptrs, uint32_t nptrs, uint32_t tag) {
    // We need to allocate: [StgInfoTable fields][entry code stub]
    // With TNTC, StgInfoTable ends with code[], so the struct size
    // already accounts for the layout. We allocate sizeof(StgInfoTable)
    // for the metadata, plus ENTRY_STUB_SIZE for the actual code bytes.
    //
    // Memory layout:
    //   [layout (8)][type (2)][srt (4)][entry code bytes...]
    //                                   ^--- "info pointer" points here
    //
    // The info pointer = address of entry code = base + sizeof(StgInfoTable)
    // (because sizeof includes the flexible array member at offset 0)
    //
    // Actually, sizeof(StgInfoTable) with TNTC gives us the size of the
    // struct WITHOUT the code[] contents (flexible array = 0 bytes).
    // So: total = sizeof(StgInfoTable) + ENTRY_STUB_SIZE

    size_t total = sizeof(StgInfoTable) + ENTRY_STUB_SIZE;

    // Allocate executable memory (one page minimum for mmap)
    // TODO: batch multiple info tables into one page for efficiency
    size_t page_size = 4096;
    void* mem = mmap(NULL, page_size,
                     PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) return NULL;

    // Fill in the info table fields
    StgInfoTable* info = (StgInfoTable*)mem;
    memset(info, 0, sizeof(StgInfoTable));

    info->layout.payload.ptrs  = (StgHalfWord)ptrs;
    info->layout.payload.nptrs = (StgHalfWord)nptrs;
    info->type = constr_type(ptrs, nptrs);
    info->srt  = (StgSRTField)tag;

    // Copy entry code stub right after the info table struct
    // With TNTC, the code[] member is at the end of the struct,
    // so we write into info->code
    memcpy(info->code, ENTRY_STUB, ENTRY_STUB_SIZE);

    // The "info pointer" for closures is the address of the code.
    // With TNTC, get_itbl() subtracts sizeof(StgInfoTable) to get back
    // to the metadata. We return the code address.
    return (GraspInfo)(&info->code[0]);

    // NOTE: this is WRONG. With TNTC, the closure's info pointer should
    // point to the code, and get_itbl goes BACKWARDS to find the metadata.
    // But StgInfoTable with TNTC is laid out as:
    //   [layout][type][srt][code[]]
    // And the info pointer points to code[]. get_itbl subtracts to reach
    // the start of the struct. So we return &info->code[0], which IS
    // ((char*)info + offsetof(StgInfoTable, code)).
    // Verify this in Task 1 output before proceeding!
}
```

**IMPORTANT**: The `return` value and TNTC pointer arithmetic must be verified against Task 1's output. The code above assumes `get_itbl(closure) == (StgInfoTable*)closure->header.info - 1` which is the standard TNTC convention, but the exact offset depends on `sizeof(StgInfoTable)`. The `&info->code[0]` approach should be correct because `info->code` IS at the right offset from the metadata fields.

**Step 3: Run the layout check from Task 1, adjust constants if needed**

**Step 4: Commit**

```bash
git add cbits/grasp_rts.h cbits/grasp_rts.c
git commit -m "feat: add grasp_make_info for runtime info table creation"
```

---

### Task 3: Implement `grasp_alloc`, `grasp_field`, `grasp_info`

**Files:**
- Modify: `cbits/grasp_rts.c` (add the three remaining functions)

**Step 1: Implement `grasp_alloc`**

```c
StgClosure* grasp_alloc(Capability* cap, GraspInfo info,
                        StgClosure** fields, uint32_t n) {
    // Total closure size: 1 word (info pointer) + n words (payload)
    uint32_t size_words = 1 + n;

    // Allocate on the GHC heap
    StgPtr mem = allocate(cap, size_words);

    // Set the info pointer (first word of closure)
    StgClosure* closure = (StgClosure*)mem;
    SET_HDR(closure, info, CCS_SYSTEM);
    // If SET_HDR doesn't work without profiling, do it manually:
    // closure->header.info = info;

    // Fill payload words
    for (uint32_t i = 0; i < n; i++) {
        closure->payload[i] = (StgClosure*)fields[i];
    }

    return closure;
}
```

**Note on `allocate`**: The function signature is `StgPtr allocate(Capability *cap, W_ n)` where `W_` is `StgWord` (unsigned 64-bit on x86_64). It's declared in `rts/storage/Storage.h` — verify this header is included transitively via `Rts.h`. If not, add `#include "rts/storage/Storage.h"`.

**Note on `SET_HDR`**: This macro sets the info pointer and profiling header. Without profiling it reduces to `closure->header.info = info`. If the macro isn't available, use the direct assignment.

**Step 2: Implement `grasp_field` and `grasp_info`**

```c
StgClosure* grasp_field(StgClosure* closure, uint32_t i) {
    return closure->payload[i];
}

GraspInfo grasp_info(StgClosure* closure) {
    return closure->header.info;
}

uint32_t grasp_info_ptrs(GraspInfo info) {
    const StgInfoTable* i = INFO_PTR_TO_STRUCT(info);
    return i->layout.payload.ptrs;
}

uint32_t grasp_info_nptrs(GraspInfo info) {
    const StgInfoTable* i = INFO_PTR_TO_STRUCT(info);
    return i->layout.payload.nptrs;
}

uint32_t grasp_info_tag(GraspInfo info) {
    const StgInfoTable* i = INFO_PTR_TO_STRUCT(info);
    return (uint32_t)i->srt;
}
```

**Note on `INFO_PTR_TO_STRUCT`**: With TNTC, this subtracts to go from the code pointer back to the struct base. It's the inverse of what `grasp_make_info` returns. Verify it's available as a macro in `InfoTables.h`. Alternative: use `get_itbl((StgClosure*)...)` which does the same thing.

**Step 3: Compile to check for errors**

```bash
nix develop -c ghc -c -no-hs-main -threaded cbits/grasp_rts.c -o /dev/null
```

If `allocate` is not found, check if it needs an explicit include or if it's only available internally. If so, we may need `rts_lock`/`rts_unlock` style wrappers or use `allocatePinned` from `RtsAPI.h` instead.

**Step 4: Commit**

```bash
git add cbits/grasp_rts.c
git commit -m "feat: add grasp_alloc, grasp_field, grasp_info"
```

---

### Task 4: Write the Bootstrap Test Harness

The proof: create closures in C, trigger GC, verify survival.

**Files:**
- Create: `cbits/grasp_boot.c`

**Step 1: Write the test program**

```c
// cbits/grasp_boot.c
#include "grasp_rts.h"
#include <stdio.h>
#include <assert.h>

// Helper: print test result
#define TEST(name, cond) do { \
    if (cond) { printf("  PASS: %s\n", name); } \
    else { printf("  FAIL: %s\n", name); failures++; } \
} while(0)

int main(int argc, char** argv) {
    int failures = 0;
    hs_init(&argc, &argv);
    Capability* cap = rts_lock();

    printf("=== Grasp C-Native Bootstrap ===\n\n");

    // --- Create the two fundamental info tables ---
    printf("Creating info tables...\n");
    GraspInfo nil_info  = grasp_make_info(0, 0, 0);
    GraspInfo cons_info = grasp_make_info(2, 0, 1);
    TEST("nil_info created",  nil_info != NULL);
    TEST("cons_info created", cons_info != NULL);

    // --- Verify info table metadata ---
    printf("\nInfo table metadata...\n");
    TEST("nil ptrs=0",   grasp_info_ptrs(nil_info) == 0);
    TEST("nil nptrs=0",  grasp_info_nptrs(nil_info) == 0);
    TEST("nil tag=0",    grasp_info_tag(nil_info) == 0);
    TEST("cons ptrs=2",  grasp_info_ptrs(cons_info) == 2);
    TEST("cons nptrs=0", grasp_info_nptrs(cons_info) == 0);
    TEST("cons tag=1",   grasp_info_tag(cons_info) == 1);

    // --- Allocate nil ---
    printf("\nAllocating nil...\n");
    StgClosure* nil = grasp_alloc(cap, nil_info, NULL, 0);
    TEST("nil allocated", nil != NULL);
    TEST("nil has nil_info", grasp_info(nil) == nil_info);

    // --- Allocate (cons 42 nil) ---
    printf("\nAllocating (cons 42 nil)...\n");
    StgClosure* val42 = rts_mkInt(cap, 42);
    StgClosure* cell1 = grasp_alloc(cap, cons_info,
                          (StgClosure*[]){val42, nil}, 2);
    TEST("cell1 allocated", cell1 != NULL);
    TEST("cell1 has cons_info", grasp_info(cell1) == cons_info);
    TEST("cell1 car = 42", rts_getInt(grasp_field(cell1, 0)) == 42);
    TEST("cell1 cdr = nil", grasp_info(grasp_field(cell1, 1)) == nil_info);

    // --- Allocate (cons 1 (cons 2 nil)) ---
    printf("\nAllocating nested list (1 2)...\n");
    StgClosure* v1 = rts_mkInt(cap, 1);
    StgClosure* v2 = rts_mkInt(cap, 2);
    StgClosure* inner = grasp_alloc(cap, cons_info,
                          (StgClosure*[]){v2, nil}, 2);
    StgClosure* outer = grasp_alloc(cap, cons_info,
                          (StgClosure*[]){v1, inner}, 2);
    TEST("nested car = 1", rts_getInt(grasp_field(outer, 0)) == 1);
    TEST("nested cadr = 2",
         rts_getInt(grasp_field(grasp_field(outer, 1), 0)) == 2);
    TEST("nested cddr = nil",
         grasp_info(grasp_field(grasp_field(outer, 1), 1)) == nil_info);

    // --- GC Survival Test ---
    printf("\nGC survival test...\n");
    // Pin the outer list so GC can trace it
    StgStablePtr sp = getStablePtr((StgPtr)outer);

    // Force a major GC — this moves/compacts the heap
    rts_unlock(cap);
    performMajorGC();
    cap = rts_lock();

    // Retrieve the (possibly moved) closure
    outer = (StgClosure*)deRefStablePtr(sp);
    TEST("outer survived GC", outer != NULL);
    TEST("outer still has cons_info", grasp_info(outer) == cons_info);
    TEST("outer car still 1", rts_getInt(grasp_field(outer, 0)) == 1);

    StgClosure* inner_after = grasp_field(outer, 1);
    TEST("inner survived GC", inner_after != NULL);
    TEST("inner car still 2", rts_getInt(grasp_field(inner_after, 0)) == 2);
    TEST("inner cdr still nil",
         grasp_info(grasp_field(inner_after, 1)) == nil_info);

    freeStablePtr(sp);

    // --- Type Discrimination ---
    printf("\nType discrimination...\n");
    TEST("nil != cons", grasp_info(nil) != grasp_info(cell1));
    TEST("cons == cons", grasp_info(cell1) == grasp_info(outer));

    // --- Summary ---
    printf("\n=== %s (%d failures) ===\n",
           failures == 0 ? "ALL PASSED" : "SOME FAILED", failures);

    rts_unlock(cap);
    hs_exit();
    return failures;
}
```

**Step 2: Build and run**

```bash
nix develop -c ghc -no-hs-main -threaded -rtsopts \
    cbits/grasp_rts.c cbits/grasp_boot.c \
    -o grasp_boot
./grasp_boot +RTS -N1
```

If `allocate` is not visible from user C code (it's an internal RTS function), we need an alternative. Options:
- Use `allocatePinned` (available via RtsAPI)
- Wrap `allocate` via Cmm (write a `.cmm` file that calls `allocate` and expose it as a C symbol)
- Link with `-optl-Wl,--whole-archive` to expose internal RTS symbols

Try linking first. If `allocate` is in the symbol table of `libHSrts.a`, it'll just work.

**Step 3: Debug any issues**

Common failure modes:
- **Segfault in GC**: info table layout is wrong (ptrs/nptrs don't match payload). Fix by checking Task 1 output.
- **`allocate` not found**: use alternative allocation path (see note above).
- **Info pointer mismatch after GC**: the GC moved the closure but our info table is in mmap'd memory (not moved). Info pointers should be stable — they point to info tables, not heap objects. This should work.
- **TNTC offset wrong**: `grasp_info_ptrs` etc. return garbage. Fix the pointer arithmetic in `grasp_make_info`.

**Step 4: Commit**

```bash
git add cbits/grasp_boot.c
git commit -m "feat: add C bootstrap test harness — GC survival proof"
```

---

### Task 5: Build System Integration

Make the bootstrap buildable from the project's nix environment with a simple command.

**Files:**
- Create: `Makefile` (or `boot.sh`)

**Step 1: Create a build script**

```makefile
# Makefile
GHC_FLAGS = -no-hs-main -threaded -rtsopts -Wall

# The C bootstrap — zero Haskell
grasp_boot: cbits/grasp_rts.c cbits/grasp_boot.c cbits/grasp_rts.h
	ghc $(GHC_FLAGS) cbits/grasp_rts.c cbits/grasp_boot.c -o $@

layout_check: cbits/grasp_layout_check.c
	ghc $(GHC_FLAGS) $< -o $@

# Run the bootstrap tests
.PHONY: boot
boot: grasp_boot
	./grasp_boot +RTS -N1

.PHONY: clean-boot
clean-boot:
	rm -f grasp_boot layout_check
	rm -f cbits/*.o cbits/*.hi
```

Usage:

```bash
nix develop -c make boot    # build and run the C bootstrap
nix develop -c make layout_check && ./layout_check   # verify layout
```

**Step 2: Verify it builds and runs**

```bash
nix develop -c make boot
```

Expected output: all tests PASS, especially the GC survival test.

**Step 3: Commit**

```bash
git add Makefile
git commit -m "chore: add Makefile for C-native bootstrap build"
```

---

### Task 6: Troubleshooting — `allocate` Visibility

This task exists as a contingency. If `allocate()` is not visible to user C code (it's an RTS-internal function), we need an alternative path.

**Option A: Check if it links**

```bash
nix develop -c ghc -no-hs-main -threaded cbits/grasp_rts.c cbits/grasp_boot.c -o grasp_boot 2>&1
```

If you get `undefined reference to 'allocate'`, proceed to Option B.

**Option B: Write a Cmm wrapper**

Create `cbits/grasp_alloc_cmm.cmm`:

```cmm
// cbits/grasp_alloc_cmm.cmm
// Expose the RTS allocate function to C code via a Cmm wrapper.

#include "Cmm.h"

grasp_allocate_wrapper(W_ n) {
    W_ p;
    ("ptr" p) = ccall allocate(MyCapability() "ptr", n);
    return (p);
}
```

Then in `grasp_rts.c`, instead of calling `allocate` directly:

```c
extern StgPtr grasp_allocate_wrapper(StgWord n);
```

Build with:

```bash
ghc -no-hs-main -threaded cbits/grasp_alloc_cmm.cmm cbits/grasp_rts.c cbits/grasp_boot.c -o grasp_boot
```

**Option C: Use `rts_mkConstr`-style approach**

If neither works, allocate a known Haskell CONSTR via the RTS API and overwrite its payload. This is hacky but would prove the concept. Only use as a last resort.

**Option D: Link against internal RTS symbols**

Pass `-optl -Wl,--whole-archive` or compile with `ghc -debug` which exposes more symbols.

**No commit for this task** — it modifies Task 3/4 code based on what works.

---

## Summary

| Task | What | Proves |
|------|------|--------|
| 1 | Layout verification | We know the exact byte layout |
| 2 | `grasp_make_info` | We can create info tables in C |
| 3 | `grasp_alloc/field/info` | We can create and read closures |
| 4 | Boot test harness | Closures survive GC — Level 2 achieved |
| 5 | Build integration | Reproducible build in nix |
| 6 | Troubleshoot `allocate` | Contingency if RTS internals aren't visible |

## Success Criteria

1. `grasp_boot` compiles with zero `.hs` files
2. `grasp_alloc` creates closures on the GHC heap
3. `performMajorGC()` does not crash — closures survive
4. Fields read back correctly after GC
5. `grasp_info` returns correct info pointers for type discrimination
6. The entire test prints `ALL PASSED`
