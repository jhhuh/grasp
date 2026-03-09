#include "grasp_rts.h"
#include <stdio.h>

#define TEST(name, cond) do { \
    if (cond) { printf("  PASS: %s\n", name); } \
    else { printf("  FAIL: %s\n", name); failures++; } \
} while(0)

int main(int argc, char** argv) {
    int failures = 0;

    printf("=== Grasp C-Native Bootstrap Tests ===\n\n");

    hs_init(&argc, &argv);
    Capability* cap = rts_lock();

    /* --- Task 2: Info table creation --- */
    printf("[Info Tables]\n");

    GraspInfo nil_info  = grasp_make_info(0, 0, 0);
    GraspInfo cons_info = grasp_make_info(2, 0, 1);

    TEST("nil_info != NULL",  nil_info != NULL);
    TEST("cons_info != NULL", cons_info != NULL);
    TEST("nil_info ptrs=0",   grasp_info_ptrs(nil_info) == 0);
    TEST("nil_info nptrs=0",  grasp_info_nptrs(nil_info) == 0);
    TEST("nil_info tag=0",    grasp_info_tag(nil_info) == 0);
    TEST("cons_info ptrs=2",  grasp_info_ptrs(cons_info) == 2);
    TEST("cons_info nptrs=0", grasp_info_nptrs(cons_info) == 0);
    TEST("cons_info tag=1",   grasp_info_tag(cons_info) == 1);

    /* --- Task 3: Closure allocation --- */
    printf("\n[Allocation]\n");

    /* nil = Nil (no fields) */
    StgClosure* nil = grasp_alloc(cap, nil_info, NULL, 0);
    TEST("nil allocated", nil != NULL);
    TEST("nil info matches", grasp_info(nil) == nil_info);

    /* Use rts_mkInt to create boxed integers for payload */
    HaskellObj val42 = rts_mkInt(cap, 42);
    HaskellObj val1  = rts_mkInt(cap, 1);
    HaskellObj val2  = rts_mkInt(cap, 2);

    /* cons42 = Cons 42 nil */
    StgClosure* cons42_fields[] = { (StgClosure*)val42, nil };
    StgClosure* cons42 = grasp_alloc(cap, cons_info, cons42_fields, 2);
    TEST("cons42 allocated", cons42 != NULL);
    TEST("cons42 info matches", grasp_info(cons42) == cons_info);

    /* Read fields back */
    StgClosure* head42 = grasp_field(cons42, 0);
    StgClosure* tail42 = grasp_field(cons42, 1);
    TEST("cons42 head is val42", head42 == (StgClosure*)val42);
    TEST("cons42 tail is nil",   tail42 == nil);

    /* inner = Cons 2 nil */
    StgClosure* inner_fields[] = { (StgClosure*)val2, nil };
    StgClosure* inner = grasp_alloc(cap, cons_info, inner_fields, 2);

    /* outer = Cons 1 inner */
    StgClosure* outer_fields[] = { (StgClosure*)val1, inner };
    StgClosure* outer = grasp_alloc(cap, cons_info, outer_fields, 2);

    TEST("outer head is val1", grasp_field(outer, 0) == (StgClosure*)val1);
    TEST("outer tail is inner", grasp_field(outer, 1) == inner);
    TEST("inner head is val2", grasp_field(inner, 0) == (StgClosure*)val2);
    TEST("inner tail is nil",  grasp_field(inner, 1) == nil);

    /* --- Task 4: GC survival --- */
    printf("\n[GC Survival]\n");

    /* Pin outer via StablePtr before GC */
    StgStablePtr sp_outer = getStablePtr((StgPtr)outer);
    StgStablePtr sp_nil   = getStablePtr((StgPtr)nil);
    StgStablePtr sp_cons42 = getStablePtr((StgPtr)cons42);

    rts_unlock(cap);
    performMajorGC();
    cap = rts_lock();

    /* Recover pointers */
    outer  = (StgClosure*)deRefStablePtr(sp_outer);
    nil    = (StgClosure*)deRefStablePtr(sp_nil);
    cons42 = (StgClosure*)deRefStablePtr(sp_cons42);

    TEST("outer survives GC", outer != NULL);
    TEST("outer info after GC", grasp_info(outer) == cons_info);
    TEST("nil survives GC", nil != NULL);
    TEST("nil info after GC", grasp_info(nil) == nil_info);
    TEST("cons42 survives GC", cons42 != NULL);
    TEST("cons42 info after GC", grasp_info(cons42) == cons_info);

    /* Check nested structure survived */
    StgClosure* outer_head = grasp_field(outer, 0);
    StgClosure* outer_tail = grasp_field(outer, 1);
    TEST("outer head after GC is int",
         grasp_info(outer_head) == grasp_info((StgClosure*)rts_mkInt(cap, 0)));
    TEST("outer tail after GC has cons_info",
         grasp_info(outer_tail) == cons_info);

    hs_free_stable_ptr(sp_outer);
    hs_free_stable_ptr(sp_nil);
    hs_free_stable_ptr(sp_cons42);

    /* --- Type discrimination --- */
    printf("\n[Type Discrimination]\n");

    TEST("nil vs cons: different info",  grasp_info(nil) != grasp_info(cons42));
    TEST("cons42 vs outer: same info",   grasp_info(cons42) == grasp_info(outer));

    rts_unlock(cap);
    hs_exit();

    printf("\n=== Results: %d failure(s) ===\n", failures);
    return failures ? 1 : 0;
}
