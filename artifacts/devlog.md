# Grasp Dev Journal

## 2026-03-06: NativeTypes module (Task 1)

**Goal**: Create `Grasp.NativeTypes` module -- the foundation for replacing `LispVal` with native GHC heap closures.

**What was done**:
- Created `src/Grasp/NativeTypes.hs` with ADTs, type discrimination via `unpackClosure#`, constructors, extractors, predicates, equality, and display.
- Created `test/NativeTypesSpec.hs` with 27 tests covering type discrimination (8), round-trip constructors/extractors (11), and equality (8).
- Updated `grasp.cabal`: added `Grasp.NativeTypes` to both `other-modules` lists, `NativeTypesSpec` to test modules, `ghc-prim` to both `build-depends`.

**Bug found and fixed**:
- `Foreign.Ptr (Ptr(Ptr))` does not export the `Ptr` constructor in GHC 9.8.4. Fixed by importing from `GHC.Ptr (Ptr(Ptr))` instead.
- `graspEq` on cons cells crashed with "unknown closure type". Root cause: `unpackClosure#` on a thunk returns the thunk's info pointer, not the underlying value's. When `toCar`/`toCdr` extract lazy fields from `GraspCons`, the optimizer may leave the result as a thunk. Fix: added `seq` to `getInfoPtr` to force values to WHNF before inspecting their info-table pointer. This protects all callers, not just `graspEq`.

**Cleanup during self-review**:
- Removed unused `Data.IORef (IORef)` import from NativeTypes.hs.
- Removed unused `GHC.Exts (Any)` and `Unsafe.Coerce` imports from test file.

**Result**: 77 tests pass (50 existing + 27 new). Commit: `08907e3`.
