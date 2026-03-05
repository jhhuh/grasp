#ifndef GRASP_RTS_BRIDGE_H
#define GRASP_RTS_BRIDGE_H

#include "HsFFI.h"

/* Round-trip: create an Int on the GHC heap via rts_mkInt, read it back via rts_getInt */
HsInt grasp_roundtrip_int(HsInt val);

/* Apply a Haskell (Int -> Int) function (given as StablePtr) to an Int arg,
   evaluate via rts_eval, and return the Int result. */
HsInt grasp_apply_int_int(HsStablePtr fn_sp, HsInt arg);

#endif
