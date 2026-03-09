#include "grasp_rts.h"
#include <sys/mman.h>
#include <string.h>
#include <unistd.h>

/* GHC RTS internal — allocate words on the nursery. */
extern StgPtr allocate(Capability *cap, W_ n);

/* Pick the specific CONSTR_x_y type for the given pointer/non-pointer counts. */
static StgHalfWord constr_type(uint32_t ptrs, uint32_t nptrs) {
    if (ptrs == 0 && nptrs == 0) return CONSTR_NOCAF;
    if (ptrs == 1 && nptrs == 0) return CONSTR_1_0;
    if (ptrs == 0 && nptrs == 1) return CONSTR_0_1;
    if (ptrs == 2 && nptrs == 0) return CONSTR_2_0;
    if (ptrs == 1 && nptrs == 1) return CONSTR_1_1;
    if (ptrs == 0 && nptrs == 2) return CONSTR_0_2;
    return CONSTR;
}

GraspInfo grasp_make_info(uint32_t ptrs, uint32_t nptrs, uint32_t tag) {
    long page_size = sysconf(_SC_PAGESIZE);
    void* mem = mmap(NULL, page_size,
                     PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) return NULL;

    StgInfoTable* tbl = (StgInfoTable*)mem;
    memset(tbl, 0, sizeof(StgInfoTable));

    tbl->layout.payload.ptrs  = ptrs;
    tbl->layout.payload.nptrs = nptrs;
    tbl->type = constr_type(ptrs, nptrs);
    tbl->srt  = tag;  /* constructor tag lives in srt field */

    /* With TNTC, code[] is at offset sizeof(StgInfoTable) = 16.
       Write ud2 (0x0f 0x0b) as a crash stub — entry code should never run
       for CONSTR closures. */
    uint8_t* code = (uint8_t*)mem + sizeof(StgInfoTable);
    code[0] = 0x0f;
    code[1] = 0x0b;

    /* Return the code[] address — this is what closures store as info ptr. */
    return (GraspInfo)code;
}

StgClosure* grasp_alloc(Capability* cap, GraspInfo info,
                        StgClosure** fields, uint32_t n) {
    StgClosure* cl = (StgClosure*)allocate(cap, 1 + n);
    cl->header.info = info;
    for (uint32_t i = 0; i < n; i++) {
        cl->payload[i] = (StgClosurePtr)fields[i];
    }
    return cl;
}

StgClosure* grasp_field(StgClosure* closure, uint32_t i) {
    StgClosure* c = UNTAG_CLOSURE(closure);
    return (StgClosure*)c->payload[i];
}

GraspInfo grasp_info(StgClosure* closure) {
    StgClosure* c = UNTAG_CLOSURE(closure);
    return c->header.info;
}

uint32_t grasp_info_ptrs(GraspInfo info) {
    /* info points to code[] (TNTC). Subtract sizeof(StgInfoTable) to reach
       the struct base. */
    const StgInfoTable* tbl =
        (const StgInfoTable*)((uint8_t*)info - sizeof(StgInfoTable));
    return tbl->layout.payload.ptrs;
}

uint32_t grasp_info_nptrs(GraspInfo info) {
    const StgInfoTable* tbl =
        (const StgInfoTable*)((uint8_t*)info - sizeof(StgInfoTable));
    return tbl->layout.payload.nptrs;
}

uint32_t grasp_info_tag(GraspInfo info) {
    const StgInfoTable* tbl =
        (const StgInfoTable*)((uint8_t*)info - sizeof(StgInfoTable));
    return tbl->srt;
}
