{-# LANGUAGE OverloadedStrings #-}
module Grasp.HsRegistry
  ( dispatchRegistered
  ) where

import Data.Text (Text)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T

import Grasp.Types

-- | Look up a Haskell function, validate arg types, invoke.
dispatchRegistered :: HsFuncRegistry -> Text -> [LispVal] -> IO LispVal
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

checkType :: Text -> HsType -> LispVal -> IO ()
checkType name expected val
  | matchesType expected val = pure ()
  | otherwise = error $ T.unpack name <> ": expected "
              <> showHsType expected <> ", got " <> valTypeName val

matchesType :: HsType -> LispVal -> Bool
matchesType HsInt     (LInt _)    = True
matchesType HsBool    (LBool _)   = True
matchesType HsString  (LStr _)    = True
matchesType HsListInt LNil        = True
matchesType HsListInt (LCons (LInt _) rest) = matchesType HsListInt rest
matchesType _ _ = False

showHsType :: HsType -> String
showHsType HsInt     = "Int"
showHsType HsListInt = "List[Int]"
showHsType HsBool    = "Bool"
showHsType HsString  = "String"

valTypeName :: LispVal -> String
valTypeName (LInt _)       = "Int"
valTypeName (LDouble _)    = "Double"
valTypeName (LStr _)       = "String"
valTypeName (LBool _)      = "Bool"
valTypeName (LSym _)       = "Symbol"
valTypeName LNil           = "Nil"
valTypeName (LCons _ _)    = "List"
valTypeName (LFun{})       = "Lambda"
valTypeName (LPrimitive{}) = "Primitive"
