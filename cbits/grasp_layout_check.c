// cbits/grasp_layout_check.c
// Verifies GHC RTS struct layout assumptions for Grasp's C-native bootstrap.
#include "Rts.h"
#include <stdio.h>
#include <stddef.h>

int main(int argc, char** argv) {
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
#else
    printf("offsetof(entry)       = %zu\n", offsetof(StgInfoTable, entry));
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
    printf("CONSTR_NOCAF = %d\n", CONSTR_NOCAF);

    // 6. Verify get_itbl round-trip with a known closure (needs RTS)
    printf("\n--- Runtime verification ---\n");
    fflush(stdout);
    hs_init(&argc, &argv);

    Capability* cap = rts_lock();
    HaskellObj fortytwo = rts_mkInt(cap, 42);

    // IMPORTANT: rts_mkInt returns a tagged pointer — must untag before access
    StgClosure* cl = UNTAG_CLOSURE((StgClosure*)fortytwo);
    printf("raw HaskellObj        = %p\n", (void*)fortytwo);
    printf("untagged ptr          = %p\n", (void*)cl);
    printf("tag bits              = %lu\n", (unsigned long)((StgWord)fortytwo & 7));

    const StgInfoTable* info = get_itbl(cl);
    printf("\nrts_mkInt(42) info table:\n");
    printf("  type = %d (expect CONSTR_0_1 = %d)\n", info->type, CONSTR_0_1);
    printf("  layout.payload.ptrs  = %d\n", info->layout.payload.ptrs);
    printf("  layout.payload.nptrs = %d\n", info->layout.payload.nptrs);
    printf("  closure info ptr     = %p\n", (void*)cl->header.info);
    printf("  get_itbl result      = %p\n", (void*)info);
    printf("  difference           = %zd bytes\n",
           (char*)cl->header.info - (char*)info);
    printf("  payload[0] (raw)     = %p (expect 0x2a = 42)\n",
           (void*)cl->payload[0]);

    rts_unlock(cap);
    hs_exit();

    printf("\n=== Layout check complete ===\n");
    return 0;
}
