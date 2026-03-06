# GHC API Info Table Mismatch: Re-boxing Primitive Values

## Problem

When using the GHC API (`compileExpr` + bytecode interpreter) to evaluate Haskell
expressions at runtime, the returned values (Int, Bool, Double, etc.) have different
info table pointers than values constructed by the statically compiled binary.

This matters when your code uses `unpackClosure#` to inspect info table pointers for
type discrimination (as in Grasp's `graspTypeOf`). The bytecode interpreter's `I#` has
a different info table address than the native binary's `I#`, even though they represent
the same logical constructor.

## Symptoms

- `graspTypeOf` (or any info-pointer-based type check) fails with
  "unknown closure type at 0x..." on values returned from `dynCall`/`compileExpr`.
- Works fine for values created by the local binary's constructors.
- `DynLookupSpec` tests pass (they use `unsafeCoerce` to read the value), but
  integration tests through the evaluator fail (they call `graspTypeOf` on results).

## Root Cause

The GHC API loads library code (base, ghc-prim) into its own interpreter session.
Even though `GHC.Types.I#` is logically the same constructor everywhere, the bytecode
interpreter may have its own copy of the info table at a different address. The
statically compiled binary caches `getInfoPtr (0 :: Int)` at startup, which points
to the native binary's `I#` info table.

## Fix: Unbox and Re-box with NOINLINE

Force fresh allocation using the current binary's constructors by unboxing to
unboxed types and re-boxing:

```haskell
{-# LANGUAGE MagicHash #-}
import GHC.Int (Int(I#))
import GHC.Float (Double(D#))

{-# NOINLINE reboxInt #-}
reboxInt :: Int -> Any
reboxInt (I# n) = unsafeCoerce (I# n)

{-# NOINLINE reboxDouble #-}
reboxDouble :: Double -> Any
reboxDouble (D# d) = unsafeCoerce (D# d)

{-# NOINLINE reboxBool #-}
reboxBool :: Bool -> Any
reboxBool True  = unsafeCoerce True
reboxBool False = unsafeCoerce False
```

Key points:
- `NOINLINE` is essential to prevent GHC from seeing that the input and output are
  the same constructor and optimizing the re-boxing away.
- The pattern match `(I# n)` extracts the unboxed `Int#`. The `I# n` on the right
  creates a new boxed `Int` using the current compilation unit's `I#` info table.
- For `Bool`, explicit pattern matching on `True`/`False` forces the use of our
  binary's constructor info tables.
- `mkInt = unsafeCoerce` alone does NOT work because it just reinterprets the
  pointer without creating a new closure.

## When This Applies

Any time you:
1. Use `compileExpr` from the GHC API to evaluate expressions at runtime
2. Apply the resulting functions to arguments and get back values
3. Need to inspect those values using info-pointer-based type discrimination

This does NOT affect values that stay within the bytecode interpreter (e.g., passing
a GHC API result directly back into another GHC API call).
