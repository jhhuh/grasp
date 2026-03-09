#ifndef GRASP_RTS_BRIDGE_H
#define GRASP_RTS_BRIDGE_H

#include "HsFFI.h"

/* Round-trip: create an Int on the GHC heap via rts_mkInt, read it back via rts_getInt */
HsInt grasp_roundtrip_int(HsInt val);

/* UNSAFE: Apply (Int -> Int) via rts_eval — aborts on exceptions. */
HsInt grasp_apply_int_int(HsStablePtr fn_sp, HsInt arg);

/* Build thunk (fn arg) without evaluating. Returns StablePtr to unevaluated app. */
HsStablePtr grasp_build_int_app(HsStablePtr fn_sp, HsInt arg);

#endif
