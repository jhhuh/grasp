# Native STG Closures — Design

## Goal

Replace the `LispVal` Haskell ADT with native GHC heap closures. Every Grasp
runtime value becomes an `StgClosure` on the GHC heap — integers ARE `I#`
closures, booleans ARE `True`/`False` closures, and Grasp-specific types
(symbols, lambdas, cons cells) use Haskell ADTs whose info tables GHC
generates automatically.

## Architecture

`GraspVal = Any` from `GHC.Exts`. All Grasp values are untyped pointers to
GHC heap closures with zero wrapper overhead. Type discrimination uses
`unpackClosure#` to read the info-table address and compare against cached
known addresses. Construction and extraction use `unsafeCoerce`.

## Key Decisions

1. **Reuse GHC's info tables** for Int, Double, Bool — zero-cost interop
   with Haskell functions (no marshaling).

2. **Haskell ADTs for Grasp-specific types** — GHC generates the info tables,
   entry code, and GC layout. No hand-written C info tables.

3. **`unpackClosure#` for type discrimination** — read info pointer directly
   from Haskell, compare with `Ptr ()` equality. No FFI round-trip in the
   eval hot path.

4. **`Int` replaces `Integer`** — 64-bit fixed-width. Matches GHC's `I#`
   layout. Arbitrary precision deferred.

## Value Representation

### GHC-equivalent types (reuse existing closures)

| Grasp value | Haskell type | GHC closure | Layout |
|-------------|-------------|-------------|--------|
| Integer | `Int` | `I# n` | CONSTR_0_1: info + 1 non-ptr word |
| Float | `Double` | `D# d` | CONSTR_0_1: info + 1 non-ptr word |
| True | `Bool` | `True` | static CONSTR_0_0 |
| False | `Bool` | `False` | static CONSTR_0_0 |

### Grasp-specific types (Haskell ADTs, GHC generates info tables)

```haskell
data GraspSym    = GraspSym !Text                        -- CONSTR_1_0
data GraspStr    = GraspStr !Text                        -- CONSTR_1_0
data GraspCons   = GraspCons !Any !Any                   -- CONSTR_2_0
data GraspNil    = GraspNil                              -- CONSTR_0_0
data GraspLambda = GraspLambda ![Text] !LispExpr !Env    -- CONSTR_3_0
data GraspPrim   = GraspPrim !Text !([Any] -> IO Any)    -- CONSTR_2_0
```

Note: `GraspCons`/`GraspNil` are used instead of GHC's `(:)`/`[]` because
Grasp supports improper lists: `(cons 1 2)` where cdr is not a list.

## Type Discrimination

```haskell
import GHC.Exts (Any, unpackClosure#)
import Foreign.Ptr (Ptr(Ptr))

getInfoPtr :: a -> Ptr ()
getInfoPtr x = case unpackClosure# x of (# info, _, _ #) -> Ptr info

-- Cached at module init (NOINLINE for stability)
{-# NOINLINE intInfoPtr #-}
intInfoPtr :: Ptr ()
intInfoPtr = getInfoPtr (0 :: Int)

-- ... similarly for all types

data GraspType
  = GTInt | GTDouble | GTBoolTrue | GTBoolFalse
  | GTSym | GTStr | GTCons | GTNil
  | GTLambda | GTPrim
  deriving (Eq, Show)

graspTypeOf :: Any -> GraspType
graspTypeOf v = let p = getInfoPtr v in
  if      p == intInfoPtr       then GTInt
  else if p == doubleInfoPtr    then GTDouble
  else if p == trueInfoPtr      then GTBoolTrue
  else if p == falseInfoPtr     then GTBoolFalse
  else if p == symInfoPtr       then GTSym
  else if p == strInfoPtr       then GTStr
  else if p == consInfoPtr      then GTCons
  else if p == nilInfoPtr       then GTNil
  else if p == lambdaInfoPtr    then GTLambda
  else if p == primInfoPtr      then GTPrim
  else error "unknown closure type"
```

## Constructors and Extractors

```haskell
-- Construction: wrap Haskell value as Any
mkInt :: Int -> Any
mkInt = unsafeCoerce

mkBool :: Bool -> Any
mkBool = unsafeCoerce

mkCons :: Any -> Any -> Any
mkCons car cdr = unsafeCoerce (GraspCons car cdr)

mkNil :: Any
mkNil = unsafeCoerce GraspNil

mkSym :: Text -> Any
mkSym s = unsafeCoerce (GraspSym s)

mkLambda :: [Text] -> LispExpr -> Env -> Any
mkLambda params body env = unsafeCoerce (GraspLambda params body env)

mkPrim :: Text -> ([Any] -> IO Any) -> Any
mkPrim name f = unsafeCoerce (GraspPrim name f)

-- Extraction: unwrap Any to concrete type (caller ensures correct type)
toInt :: Any -> Int
toInt = unsafeCoerce

toBool :: Any -> Bool
toBool v = graspTypeOf v == GTBoolTrue

toCar :: Any -> Any
toCar v = let GraspCons car _ = unsafeCoerce v in car

toCdr :: Any -> Any
toCdr v = let GraspCons _ cdr = unsafeCoerce v in cdr

toSym :: Any -> Text
toSym v = let GraspSym s = unsafeCoerce v in s

toStr :: Any -> Text
toStr v = let GraspStr s = unsafeCoerce v in s

toLambdaParts :: Any -> ([Text], LispExpr, Env)
toLambdaParts v = let GraspLambda p b e = unsafeCoerce v in (p, b, e)

toPrimFn :: Any -> ([Any] -> IO Any)
toPrimFn v = let GraspPrim _ f = unsafeCoerce v in f

toPrimName :: Any -> Text
toPrimName v = let GraspPrim n _ = unsafeCoerce v in n
```

## Evaluator Changes

Pattern matching on `LispVal` constructors becomes type inspection:

```haskell
-- Atoms
eval _ (EInt n)  = pure $ mkInt (fromInteger n)
eval _ (EStr s)  = pure $ mkStr s
eval _ (EBool b) = pure $ mkBool b

-- Symbol lookup
eval env (ESym s) = do
  ed <- readIORef env
  case Map.lookup s (envBindings ed) of
    Just v  -> pure v
    Nothing -> error $ "unbound symbol: " <> T.unpack s

-- Application
apply :: Any -> [Any] -> IO Any
apply v args = case graspTypeOf v of
  GTLambda -> do
    let (params, body, closure) = toLambdaParts v
    let bindings = Map.fromList (zip params args)
    parentEd <- readIORef closure
    childEnv <- newIORef $ parentEd
      { envBindings = Map.union bindings (envBindings parentEd) }
    eval childEnv body
  GTPrim -> toPrimFn v $ args
  _ -> error $ "not a function: " ++ show (graspTypeOf v)

-- Primitives
numBinOp :: (Int -> Int -> Int) -> [Any] -> IO Any
numBinOp op [a, b] = pure $ mkInt (op (toInt a) (toInt b))
```

## Environment

```haskell
data EnvData = EnvData
  { envBindings   :: Map.Map Text Any     -- was: Map Text LispVal
  , envHsRegistry :: HsFuncRegistry
  }
```

## Printer

```haskell
printVal :: Any -> String
printVal v = case graspTypeOf v of
  GTInt       -> show (toInt v)
  GTDouble    -> show (unsafeCoerce v :: Double)
  GTBoolTrue  -> "#t"
  GTBoolFalse -> "#f"
  GTSym       -> T.unpack (toSym v)
  GTStr       -> show (T.unpack (toStr v))
  GTCons      -> "(" ++ printCons v ++ ")"
  GTNil       -> "()"
  GTLambda    -> "<lambda>"
  GTPrim      -> "<primitive:" ++ T.unpack (toPrimName v) ++ ">"
```

## Haskell Interop

The `hs:` interop simplifies because Grasp integers ARE `I#` closures.
For `succ`/`negate`, the thunk `rts_apply(cap, succ, grasp_int)` receives
a genuine boxed Int — no marshaling needed.

The `HsFuncRegistry` type validation changes:
- `HsInt` check: `graspTypeOf v == GTInt`
- `HsListInt` check: walk cons chain checking each element is GTInt
- `HsBool` check: `graspTypeOf v == GTBoolTrue || GTBoolFalse`

## GC Safety

All values are proper GHC heap closures. `Any` is a lifted, GC-traced type.
No StablePtrs needed for value storage. GC traces everything normally because:

- GHC-equivalent types ARE standard GHC closures
- Grasp-specific types ARE Haskell ADTs that GHC allocated and knows how to trace
- `Any` in `Map Text Any` is stored as a boxed pointer — GC sees it

## Risk: unsafeCoerce Correctness

Type errors become segfaults. Mitigation:
- Every extractor checks `graspTypeOf` in debug builds
- The type discrimination function is heavily tested
- The number of `unsafeCoerce` call sites is bounded and auditable

## Files Changed

| Module | Status | Changes |
|--------|--------|---------|
| `Grasp.NativeTypes` | NEW | ADTs, constructors, extractors, `graspTypeOf` |
| `Grasp.Types` | MODIFY | Remove `LispVal`, `type GraspVal = Any`, update `EnvData` |
| `Grasp.Eval` | REWRITE | Use mkX/toX, type-based dispatch |
| `Grasp.Printer` | REWRITE | Use `graspTypeOf` + extractors |
| `Grasp.HaskellInterop` | MODIFY | Update for `Any`, simplify Int interop |
| `Grasp.HsRegistry` | MODIFY | Update type validation |
| `Main.hs` | MINOR | Update imports |
| All test files | MODIFY | Same behavior, updated internal types |
| `grasp.cabal` | MODIFY | Add `Grasp.NativeTypes`, add `ghc-prim` dependency |
