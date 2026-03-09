#include "rts_bridge.h"

/* Read StgInfoTable.type from an info pointer.
   In TNTC (tables-next-to-code), the info table sits at a negative offset
   from the info pointer (which points to the entry code).
   INFO_PTR_TO_STRUCT expects const StgInfoTable* (the entry code address). */
HsWord grasp_closure_type(void *info_ptr) {
    const StgInfoTable *info = INFO_PTR_TO_STRUCT((const StgInfoTable *)info_ptr);
    return (HsWord)info->type;
}
