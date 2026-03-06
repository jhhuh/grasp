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

## 2026-03-06: Tasks 4-6 — Dynamic dispatch wiring (Phase 2)

**Goal**: Wire GHC API dynamic lookup into the evaluator so `hs:` falls back to GHC API on registry miss, add `hs@` annotated form, and extract `getOrInitGhc` helper.

**What was done**:
- Created `src/Grasp/DynDispatch.hs` — new module containing:
  - `getOrInitGhc` — shared helper to lazily init GHC session from env ref
  - `marshalGraspToHaskell` / `marshalHaskellToGrasp` — bidirectional marshaling between Grasp cons chains and Haskell lists, plus type-aware passthrough for native types
  - `dynDispatch` — full dynamic dispatch for `hs:` prefix (lookup, marshal, call, marshal back)
  - `dynDispatchAnnotated` — same for `hs@` with explicit type annotations
  - Type inference from Grasp values for polymorphic function fallback
- Updated `Eval.hs`: `hs@` handler before `hs:`, `hs:` handler checks registry first then falls back to `dynDispatch`
- Updated `InteropSpec.hs`: 7 new tests for dynamic lookup and hs@ form
- Updated `grasp.cabal`: added `Grasp.DynDispatch` module

**Two bugs discovered and fixed**:

1. **GHC API info table mismatch**: Values returned by GHC API bytecode interpreter (e.g. `Int`, `Bool`, `Double`) have different info table pointers than values constructed by the statically compiled binary. `graspTypeOf` compares info pointers and fails with "unknown closure type". Fix: `marshalHaskellToGrasp` re-boxes primitive values by unboxing to unboxed types (`I#`, `D#`) and re-boxing, forcing fresh allocation with the current binary's constructors. `NOINLINE` prevents GHC from optimizing away the re-allocation. See skill file `ghc-api-info-table-mismatch-rebox.md`.

2. **Polymorphic function lookup failure**: `lookupFunc` uses `exprType TM_Inst` which can't monomorphize constrained types like `abs :: Num a => a -> a`. The constraint arrow isn't decomposed by `tcSplitFunTys`, so it reports "not a function type". Fix: when bare name lookup fails, infer types from the actual Grasp arguments, construct a type annotation string (e.g. `(abs :: Int -> Int)`), and retry with `dynCall` using the annotated expression. Return type is guessed from the first arg type, with special-case overrides for known functions (`length`, `even`, etc.).

**Result**: 99 tests pass (all existing + 7 new). No regressions.
