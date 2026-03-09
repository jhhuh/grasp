#include "Rts.h"
#include "rts_bridge.h"

HsInt grasp_roundtrip_int(HsInt val)
{
    Capability *cap = rts_lock();
    HaskellObj obj = rts_mkInt(cap, val);
    HsInt result = rts_getInt(obj);
    rts_unlock(cap);
    return result;
}

/* UNSAFE: rts_eval aborts the process on Haskell exceptions.
   Kept for backward-compatible roundtrip tests. */
HsInt grasp_apply_int_int(HsStablePtr fn_sp, HsInt arg)
{
    Capability *cap = rts_lock();
    HaskellObj fn = (HaskellObj)deRefStablePtr(fn_sp);
    HaskellObj harg = rts_mkInt(cap, arg);
    HaskellObj app = rts_apply(cap, fn, harg);
    HaskellObj result;
    rts_eval(&cap, app, &result);
    HsInt ret = rts_getInt(result);
    rts_unlock(cap);
    return ret;
}

/* Build a thunk (fn arg) without evaluating it.
   Returns a StablePtr to the unevaluated application.
   Safe: only allocates, never forces. */
HsStablePtr grasp_build_int_app(HsStablePtr fn_sp, HsInt arg)
{
    Capability *cap = rts_lock();
    HaskellObj fn = (HaskellObj)deRefStablePtr(fn_sp);
    HaskellObj harg = rts_mkInt(cap, arg);
    HaskellObj app = rts_apply(cap, fn, harg);
    HsStablePtr result_sp = getStablePtr((StgPtr)app);
    rts_unlock(cap);
    return result_sp;
}
