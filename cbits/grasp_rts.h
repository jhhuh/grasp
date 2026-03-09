#pragma once
#include "Rts.h"

/* Opaque handle to a Grasp-created info table.
   With TNTC, this points to the code[] part (same convention as
   closure->header.info). */
typedef const StgInfoTable* GraspInfo;

/* Create a CONSTR info table at runtime.
   ptrs:  number of pointer fields in payload
   nptrs: number of non-pointer fields in payload
   tag:   constructor tag (0-based)
   Returns the info pointer (code[] address), or NULL on failure. */
GraspInfo grasp_make_info(uint32_t ptrs, uint32_t nptrs, uint32_t tag);

/* Allocate a closure on the GHC heap with the given info table.
   fields: array of payload words (pointers or raw StgWords cast to StgClosure*)
   n: number of payload words (must equal ptrs + nptrs) */
StgClosure* grasp_alloc(Capability* cap, GraspInfo info,
                        StgClosure** fields, uint32_t n);

/* Read the i-th payload word from a closure (untags automatically). */
StgClosure* grasp_field(StgClosure* closure, uint32_t i);

/* Read the info pointer from a closure (untags automatically). */
GraspInfo grasp_info(StgClosure* closure);

/* Read metadata from an info table. */
uint32_t grasp_info_ptrs(GraspInfo info);
uint32_t grasp_info_nptrs(GraspInfo info);
uint32_t grasp_info_tag(GraspInfo info);
