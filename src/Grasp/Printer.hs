module Grasp.Printer (printVal) where

import qualified Data.Text as T
import GHC.Exts (Any)
import Grasp.NativeTypes

printVal :: Any -> String
printVal v = case graspTypeOf v of
  GTInt       -> show (toInt v)
  GTDouble    -> show (toDouble v)
  GTBoolTrue  -> "#t"
  GTBoolFalse -> "#f"
  GTSym       -> T.unpack (toSym v)
  GTStr       -> "\"" <> T.unpack (toStr v) <> "\""
  GTNil       -> "()"
  GTLambda    -> "<lambda>"
  GTPrim      -> "<primitive:" <> T.unpack (toPrimName v) <> ">"
  GTLazy      -> "<lazy>"
  GTMacro     -> "<macro>"
  GTChan      -> "<chan>"
  GTModule    -> "<module:" <> T.unpack (toModuleName v) <> ">"
  GTCons      -> "(" <> printCons (toCar v) (toCdr v) <> ")"

printCons :: Any -> Any -> String
printCons x d
  | isNil d   = printVal x
  | isCons d  = printVal x <> " " <> printCons (toCar d) (toCdr d)
  | otherwise = printVal x <> " . " <> printVal d
