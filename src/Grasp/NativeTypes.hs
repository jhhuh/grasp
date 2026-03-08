{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE OverloadedStrings #-}
module Grasp.NativeTypes
  ( -- * Grasp-specific ADTs
    GraspSym(..)
  , GraspStr(..)
  , GraspCons(..)
  , GraspNil(..)
  , GraspLambda(..)
  , GraspPrim(..)
  , GraspLazy(..)
  , GraspMacro(..)
  , GraspChan(..)
  , GraspModule(..)
  -- * Type discrimination
  , GraspType(..)
  , graspTypeOf
  -- * Constructors
  , mkInt, mkDouble, mkBool
  , mkSym, mkStr
  , mkCons, mkNil
  , mkLambda, mkPrim
  , mkLazy
  , mkMacro
  , mkChan
  , mkModule
  -- * Extractors
  , toInt, toDouble, toBool
  , toSym, toStr
  , toCar, toCdr
  , toLambdaParts, toPrimFn, toPrimName
  , forceLazy, forceIfLazy
  , toMacroParts
  , toChan
  , toModuleName
  , toModuleExports
  -- * Predicates
  , isNil, isCons
  -- * Equality
  , graspEq
  -- * Display
  , showGraspType
  ) where

import GHC.Exts (Any, unpackClosure#)
import GHC.Ptr (Ptr(Ptr))
import Unsafe.Coerce (unsafeCoerce)
import Data.Text (Text)
import qualified Data.Text as T
import Control.Concurrent.Chan (Chan)
import qualified Data.Map.Strict as Map

-- GraspLambda needs LispExpr and Env from Grasp.Types.
-- This import direction avoids circular deps (Types doesn't import NativeTypes).
import Grasp.Types (LispExpr, Env)

-- ─── Grasp-specific ADTs ──────────────────────────────────
-- GHC generates info tables for these automatically.
-- Fields are lazy to allow dummy construction for info-pointer caching.

data GraspSym    = GraspSym Text
data GraspStr    = GraspStr Text
data GraspCons   = GraspCons Any Any
data GraspNil    = GraspNil
data GraspLambda = GraspLambda [Text] LispExpr Env
data GraspPrim   = GraspPrim Text ([Any] -> IO Any)
data GraspLazy   = GraspLazy Any  -- lazy field: holds a GHC THUNK
data GraspMacro  = GraspMacro [Text] LispExpr Env
data GraspChan   = GraspChan (Chan Any)
data GraspModule = GraspModule Text (Map.Map Text Any)

-- ─── Type tags ────────────────────────────────────────────

data GraspType
  = GTInt | GTDouble | GTBoolTrue | GTBoolFalse
  | GTSym | GTStr | GTCons | GTNil
  | GTLambda | GTPrim | GTLazy | GTMacro | GTChan | GTModule
  deriving (Eq, Show)

showGraspType :: GraspType -> String
showGraspType GTInt       = "Int"
showGraspType GTDouble    = "Double"
showGraspType GTBoolTrue  = "Bool"
showGraspType GTBoolFalse = "Bool"
showGraspType GTSym       = "Symbol"
showGraspType GTStr       = "String"
showGraspType GTCons      = "Cons"
showGraspType GTNil       = "Nil"
showGraspType GTLambda    = "Lambda"
showGraspType GTPrim      = "Primitive"
showGraspType GTLazy      = "Lazy"
showGraspType GTMacro     = "Macro"
showGraspType GTChan      = "Chan"
showGraspType GTModule    = "Module"

-- ─── Info pointer cache ───────────────────────────────────
-- Each closure type has a unique info-table address.
-- We cache them from reference closures and compare at runtime.
-- NB: Changing field strictness on any ADT above produces a different
-- info table, which would silently break graspTypeOf. If you add bangs,
-- update the corresponding *InfoPtr sentinel to match.

-- | Read the info-table pointer from a closure's header.
-- `seq` forces evaluation first so we read the constructor's info pointer,
-- not a thunk's or indirection's.
getInfoPtr :: a -> Ptr ()
getInfoPtr x = x `seq` case unpackClosure# x of (# info, _, _ #) -> Ptr info

{-# NOINLINE intInfoPtr #-}
intInfoPtr :: Ptr ()
intInfoPtr = getInfoPtr (0 :: Int)

{-# NOINLINE doubleInfoPtr #-}
doubleInfoPtr :: Ptr ()
doubleInfoPtr = getInfoPtr (0.0 :: Double)

{-# NOINLINE trueInfoPtr #-}
trueInfoPtr :: Ptr ()
trueInfoPtr = getInfoPtr True

{-# NOINLINE falseInfoPtr #-}
falseInfoPtr :: Ptr ()
falseInfoPtr = getInfoPtr False

{-# NOINLINE symInfoPtr #-}
symInfoPtr :: Ptr ()
symInfoPtr = getInfoPtr (GraspSym T.empty)

{-# NOINLINE strInfoPtr #-}
strInfoPtr :: Ptr ()
strInfoPtr = getInfoPtr (GraspStr T.empty)

{-# NOINLINE consInfoPtr #-}
consInfoPtr :: Ptr ()
consInfoPtr = getInfoPtr (GraspCons (unsafeCoerce ()) (unsafeCoerce ()))

{-# NOINLINE nilInfoPtr #-}
nilInfoPtr :: Ptr ()
nilInfoPtr = getInfoPtr GraspNil

{-# NOINLINE lambdaInfoPtr #-}
lambdaInfoPtr :: Ptr ()
lambdaInfoPtr = getInfoPtr (GraspLambda undefined undefined undefined)

{-# NOINLINE primInfoPtr #-}
primInfoPtr :: Ptr ()
primInfoPtr = getInfoPtr (GraspPrim undefined undefined)

{-# NOINLINE lazyInfoPtr #-}
lazyInfoPtr :: Ptr ()
lazyInfoPtr = getInfoPtr (GraspLazy (unsafeCoerce ()))

{-# NOINLINE macroInfoPtr #-}
macroInfoPtr :: Ptr ()
macroInfoPtr = getInfoPtr (GraspMacro undefined undefined undefined)

{-# NOINLINE chanInfoPtr #-}
chanInfoPtr :: Ptr ()
chanInfoPtr = getInfoPtr (GraspChan undefined)

{-# NOINLINE moduleInfoPtr #-}
moduleInfoPtr :: Ptr ()
moduleInfoPtr = getInfoPtr (GraspModule undefined undefined)

-- ─── Type discrimination ─────────────────────────────────

graspTypeOf :: Any -> GraspType
graspTypeOf v = let p = getInfoPtr v in
  if      p == intInfoPtr    then GTInt
  else if p == doubleInfoPtr then GTDouble
  else if p == trueInfoPtr   then GTBoolTrue
  else if p == falseInfoPtr  then GTBoolFalse
  else if p == symInfoPtr    then GTSym
  else if p == strInfoPtr    then GTStr
  else if p == consInfoPtr   then GTCons
  else if p == nilInfoPtr    then GTNil
  else if p == lambdaInfoPtr then GTLambda
  else if p == primInfoPtr   then GTPrim
  else if p == lazyInfoPtr   then GTLazy
  else if p == macroInfoPtr  then GTMacro
  else if p == chanInfoPtr   then GTChan
  else if p == moduleInfoPtr then GTModule
  else error $ "unknown closure type at " ++ show p

-- ─── Constructors ─────────────────────────────────────────

mkInt :: Int -> Any
mkInt = unsafeCoerce

mkDouble :: Double -> Any
mkDouble = unsafeCoerce

mkBool :: Bool -> Any
mkBool = unsafeCoerce

mkSym :: Text -> Any
mkSym s = unsafeCoerce (GraspSym s)

mkStr :: Text -> Any
mkStr s = unsafeCoerce (GraspStr s)

mkCons :: Any -> Any -> Any
mkCons car cdr = unsafeCoerce (GraspCons car cdr)

mkNil :: Any
mkNil = unsafeCoerce GraspNil

mkLambda :: [Text] -> LispExpr -> Env -> Any
mkLambda params body env = unsafeCoerce (GraspLambda params body env)

mkPrim :: Text -> ([Any] -> IO Any) -> Any
mkPrim name f = unsafeCoerce (GraspPrim name f)

mkLazy :: Any -> Any
mkLazy v = unsafeCoerce (GraspLazy v)

mkMacro :: [Text] -> LispExpr -> Env -> Any
mkMacro params body env = unsafeCoerce (GraspMacro params body env)

mkChan :: Chan Any -> Any
mkChan ch = unsafeCoerce (GraspChan ch)

mkModule :: Text -> Map.Map Text Any -> Any
mkModule name exports = unsafeCoerce (GraspModule name exports)

-- ─── Extractors ───────────────────────────────────────────

toInt :: Any -> Int
toInt = unsafeCoerce

toDouble :: Any -> Double
toDouble = unsafeCoerce

toBool :: Any -> Bool
toBool v = graspTypeOf v == GTBoolTrue

toSym :: Any -> Text
toSym v = let GraspSym s = unsafeCoerce v in s

toStr :: Any -> Text
toStr v = let GraspStr s = unsafeCoerce v in s

toCar :: Any -> Any
toCar v = let GraspCons car _ = unsafeCoerce v in car

toCdr :: Any -> Any
toCdr v = let GraspCons _ cdr = unsafeCoerce v in cdr

toLambdaParts :: Any -> ([Text], LispExpr, Env)
toLambdaParts v = let GraspLambda p b e = unsafeCoerce v in (p, b, e)

toPrimFn :: Any -> ([Any] -> IO Any)
toPrimFn v = let GraspPrim _ f = unsafeCoerce v in f

toPrimName :: Any -> Text
toPrimName v = let GraspPrim n _ = unsafeCoerce v in n

toMacroParts :: Any -> ([Text], LispExpr, Env)
toMacroParts v = let GraspMacro p b e = unsafeCoerce v in (p, b, e)

toChan :: Any -> Chan Any
toChan v = let GraspChan ch = unsafeCoerce v in ch

toModuleName :: Any -> Text
toModuleName v = let GraspModule n _ = unsafeCoerce v in n

toModuleExports :: Any -> Map.Map Text Any
toModuleExports v = let GraspModule _ e = unsafeCoerce v in e

forceLazy :: Any -> IO Any
forceLazy v = let GraspLazy inner = unsafeCoerce v in inner `seq` pure inner

forceIfLazy :: Any -> IO Any
forceIfLazy v = case graspTypeOf v of
  GTLazy -> forceLazy v
  _      -> pure v

-- ─── Predicates ───────────────────────────────────────────

isNil :: Any -> Bool
isNil v = graspTypeOf v == GTNil

isCons :: Any -> Bool
isCons v = graspTypeOf v == GTCons

-- ─── Equality ─────────────────────────────────────────────

graspEq :: Any -> Any -> IO Bool
graspEq a b = do
  a' <- forceIfLazy a
  b' <- forceIfLazy b
  case (graspTypeOf a', graspTypeOf b') of
    (GTInt, GTInt)           -> pure $ toInt a' == toInt b'
    (GTDouble, GTDouble)     -> pure $ toDouble a' == toDouble b'
    (GTSym, GTSym)           -> pure $ toSym a' == toSym b'
    (GTStr, GTStr)           -> pure $ toStr a' == toStr b'
    (GTBoolTrue, GTBoolTrue) -> pure True
    (GTBoolFalse, GTBoolFalse) -> pure True
    (GTNil, GTNil)           -> pure True
    (GTCons, GTCons)         -> (&&) <$> graspEq (toCar a') (toCar b')
                                     <*> graspEq (toCdr a') (toCdr b')
    _                        -> pure False
