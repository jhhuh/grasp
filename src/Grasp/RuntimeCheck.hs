{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
module Grasp.RuntimeCheck
  ( RepTag(..)
  , readRepTag
  , getInfoPtr
  ) where

import GHC.Exts (Any, unpackClosure#)
import GHC.Ptr (Ptr(Ptr))
import Data.Word (Word)
import System.IO.Unsafe (unsafePerformIO)

import Grasp.RtsBridge (graspClosureType)

-- | Runtime representation tag: info pointer + closure type.
-- Info pointer = unique constructor identity.
-- Closure type = category (CONSTR, FUN, THUNK, etc.).
data RepTag = RepTag
  { rtInfoPtr     :: !(Ptr ())  -- info table address = type identity
  , rtClosureType :: !Word      -- from StgInfoTable.type
  } deriving (Eq, Show)

-- | Read the info-table pointer from a closure's header.
-- `seq` forces to WHNF first so we read the constructor's info pointer,
-- not a thunk's or indirection's.
getInfoPtr :: a -> Ptr ()
getInfoPtr x = x `seq` case unpackClosure# x of (# info, _, _ #) -> Ptr info

-- | Read a complete RepTag from a value.
readRepTag :: Any -> RepTag
readRepTag v = let p = getInfoPtr v in
  RepTag p (unsafePerformIO (graspClosureType p))
