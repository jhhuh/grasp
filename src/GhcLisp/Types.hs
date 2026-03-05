module GhcLisp.Types where

import Data.Text (Text)

-- | Source-level expression (what the parser produces)
data LispExpr
  = EInt Integer
  | EDouble Double
  | ESym Text
  | EStr Text
  | EList [LispExpr]
  | EBool Bool
  deriving (Show, Eq)
