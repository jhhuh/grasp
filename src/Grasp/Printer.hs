module Grasp.Printer (printVal) where

import qualified Data.Text as T
import Grasp.Types

printVal :: LispVal -> String
printVal (LInt n)    = show n
printVal (LDouble d) = show d
printVal (LSym s)    = T.unpack s
printVal (LStr s)    = "\"" <> T.unpack s <> "\""
printVal (LBool b)   = if b then "#t" else "#f"
printVal LNil        = "()"
printVal (LFun{})    = "<lambda>"
printVal (LPrimitive name _) = "<primitive:" <> T.unpack name <> ">"
printVal (LCons a d) = "(" <> printCons a d <> ")"
  where
    printCons x LNil        = printVal x
    printCons x (LCons y z) = printVal x <> " " <> printCons y z
    printCons x y           = printVal x <> " . " <> printVal y
