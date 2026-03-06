{-# LANGUAGE OverloadedStrings #-}
module Grasp.HsRegistry
  ( dispatchRegistered
  ) where

import Data.Text (Text)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import GHC.Exts (Any)

import Grasp.Types
import Grasp.NativeTypes

dispatchRegistered :: HsFuncRegistry -> Text -> [GraspVal] -> IO GraspVal
dispatchRegistered reg name args =
  case Map.lookup name reg of
    Nothing -> error $ "unknown Haskell function: " <> T.unpack name
    Just entry -> do
      let expected = hfArgTypes entry
      if length args /= length expected
        then error $ T.unpack name <> ": expected "
                   <> show (length expected) <> " argument(s), got "
                   <> show (length args)
        else do
          mapM_ (uncurry (checkType name)) (zip expected args)
          hfInvoke entry args

matchesType :: HsType -> Any -> Bool
matchesType HsInt     v = graspTypeOf v == GTInt
matchesType HsBool    v = graspTypeOf v == GTBoolTrue || graspTypeOf v == GTBoolFalse
matchesType HsString  v = graspTypeOf v == GTStr
matchesType HsListInt v
  | isNil v   = True
  | isCons v  = graspTypeOf (toCar v) == GTInt && matchesType HsListInt (toCdr v)
  | otherwise = False

checkType :: Text -> HsType -> Any -> IO ()
checkType name expected val
  | matchesType expected val = pure ()
  | otherwise = error $ T.unpack name <> ": expected "
                      <> showHsType expected <> ", got "
                      <> valTypeName val

showHsType :: HsType -> String
showHsType HsInt     = "Int"
showHsType HsListInt = "List[Int]"
showHsType HsBool    = "Bool"
showHsType HsString  = "String"

valTypeName :: Any -> String
valTypeName = showGraspType . graspTypeOf
