{-# LANGUAGE OverloadedStrings #-}
module Grasp.Types where

import Data.IORef
import Data.Text (Text)
import qualified Data.Map.Strict as Map
import GHC.Exts (Any)

-- | Source-level expression (what the parser produces)
data LispExpr
  = EInt Integer
  | EDouble Double
  | ESym Text
  | EStr Text
  | EList [LispExpr]
  | EBool Bool
  | EQuoter Text [(Text, LispExpr)] [LispExpr]   -- (name| (binds) body |)
  | EAntiquote Text LispExpr                      -- ,name(expr) or bare ,expr
  deriving (Show, Eq)

-- | Runtime value — an untyped pointer to a GHC heap closure.
type GraspVal = Any

-- | Environment: bindings + Haskell function registry
data EnvData = EnvData
  { envBindings   :: Map.Map Text GraspVal
  , envHsRegistry :: HsFuncRegistry
  , envGhcSession :: IORef (Maybe Any)  -- GhcState, cast via unsafeCoerce
  , envModules    :: Map.Map Text GraspVal
  , envLoading    :: [Text]
  }

type Env = IORef EnvData

-- | Haskell type tags for the interop boundary
data HsType = HsInt | HsListInt | HsBool | HsString
  deriving (Show, Eq)

-- | A registered Haskell function with type metadata
data HsFuncEntry = HsFuncEntry
  { hfArgTypes :: [HsType]
  , hfRetType  :: HsType
  , hfInvoke   :: [GraspVal] -> IO GraspVal
  }

-- | Registry of available Haskell functions
type HsFuncRegistry = Map.Map Text HsFuncEntry
