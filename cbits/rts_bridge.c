#include "Rts.h"
#include "rts_bridge.h"

HsInt ghclisp_roundtrip_int(HsInt val)
{
    Capability *cap = rts_lock();
    HaskellObj obj = rts_mkInt(cap, val);
    HsInt result = rts_getInt(obj);
    rts_unlock(cap);
    return result;
}

HsInt ghclisp_apply_int_int(HsStablePtr fn_sp, HsInt arg)
{
    Capability *cap = rts_lock();

    /* Dereference the StablePtr to get the function closure */
    HaskellObj fn = (HaskellObj)deRefStablePtr(fn_sp);

    /* Create the argument */
    HaskellObj harg = rts_mkInt(cap, arg);

    /* Apply function to argument (creates a thunk) */
    HaskellObj app = rts_apply(cap, fn, harg);

    /* Evaluate the application to WHNF */
    HaskellObj result;
    rts_eval(&cap, app, &result);

    /* Extract the Int result */
    HsInt ret = rts_getInt(result);

    rts_unlock(cap);
    return ret;
}
