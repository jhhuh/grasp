{-# LANGUAGE OverloadedStrings #-}
module Grasp.Types where

import Data.IORef
import Data.Text (Text)
import qualified Data.Map.Strict as Map

-- | Source-level expression (what the parser produces)
data LispExpr
  = EInt Integer
  | EDouble Double
  | ESym Text
  | EStr Text
  | EList [LispExpr]
  | EBool Bool
  deriving (Show, Eq)

-- | Runtime values
data LispVal
  = LInt Integer
  | LDouble Double
  | LSym Text
  | LStr Text
  | LBool Bool
  | LCons LispVal LispVal
  | LNil
  | LFun [Text] LispExpr Env   -- params, body, captured env
  | LPrimitive Text ([LispVal] -> IO LispVal)

instance Show LispVal where
  show (LInt n) = show n
  show (LDouble d) = show d
  show (LSym s) = show s
  show (LStr s) = show s
  show (LBool b) = if b then "#t" else "#f"
  show LNil = "()"
  show (LCons _ _) = "(...)"
  show (LFun{}) = "<lambda>"
  show (LPrimitive name _) = "<primitive:" <> show name <> ">"

instance Eq LispVal where
  LInt a == LInt b = a == b
  LDouble a == LDouble b = a == b
  LSym a == LSym b = a == b
  LStr a == LStr b = a == b
  LBool a == LBool b = a == b
  LNil == LNil = True
  LCons a b == LCons c d = a == c && b == d
  _ == _ = False

-- | Environment: mutable bindings
type Env = IORef (Map.Map Text LispVal)

-- | Haskell type tags for the interop boundary
data HsType = HsInt | HsListInt | HsBool | HsString
  deriving (Show, Eq)

-- | A registered Haskell function with type metadata
data HsFuncEntry = HsFuncEntry
  { hfArgTypes :: [HsType]
  , hfRetType  :: HsType
  , hfInvoke   :: [LispVal] -> IO LispVal
  }

-- | Registry of available Haskell functions
type HsFuncRegistry = Map.Map Text HsFuncEntry
