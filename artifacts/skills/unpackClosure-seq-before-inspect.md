# unpackClosure# requires seq to avoid thunk info pointers

## Problem

`GHC.Exts.unpackClosure#` inspects the raw closure on the heap. If the value is
an unevaluated thunk, `unpackClosure#` returns the thunk's info-table pointer,
not the underlying value's. This breaks info-pointer-based type discrimination.

## When it happens

Lazy fields in ADTs that store `Any` values. When you extract a field and pass
it to `unpackClosure#` without forcing it, the optimizer may leave it as a thunk
(especially across module boundaries with `-O1`).

Example:
```haskell
data GraspCons = GraspCons Any Any

toCar :: Any -> Any
toCar v = let GraspCons car _ = unsafeCoerce v in car
-- car may be a thunk here!

graspTypeOf :: Any -> GraspType
graspTypeOf v = let p = getInfoPtr v in ...
-- if v is a thunk, getInfoPtr sees the thunk's info pointer
```

## Fix

Force with `seq` before `unpackClosure#`:

```haskell
getInfoPtr :: a -> Ptr ()
getInfoPtr x = x `seq` case unpackClosure# x of (# info, _, _ #) -> Ptr info
```

This evaluates to WHNF first, so `unpackClosure#` always sees the value's
constructor info pointer.

## Notes

- Single-module tests may pass because GHC can optimize away the thunk in that
  context. Cross-module (cabal test suite) is where it fails.
- Bang patterns on the ADT fields (`!Any`) don't help -- they change the
  constructor's own info pointer since strict and lazy constructors have
  different STG representations.
