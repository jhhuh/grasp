#include "rts_bridge.h"

/* Read StgInfoTable.type from an info table pointer.
   unpackClosure# already applies INFO_PTR_TO_STRUCT (%GET_STD_INFO),
   so the pointer we receive points directly at the StgInfoTable. */
HsWord grasp_closure_type(void *info_ptr) {
    const StgInfoTable *info = (const StgInfoTable *)info_ptr;
    return (HsWord)info->type;
}
