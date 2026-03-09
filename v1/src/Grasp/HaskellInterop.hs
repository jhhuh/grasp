{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Grasp.HaskellInterop
  ( defaultEnvWithInterop
  , defaultRegistry
  ) where

import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Foreign.StablePtr
import GHC.Exts (Any)

import Grasp.Types
import Grasp.NativeTypes
import Grasp.Eval (defaultEnv)
import Grasp.RtsBridge (bridgeSafeApplyIntInt)
import Grasp.HsRegistry (dispatchRegistered)

-- | Default environment extended with haskell-call and hs: registry
defaultEnvWithInterop :: IO Env
defaultEnvWithInterop = do
  env <- defaultEnv
  reg <- defaultRegistry
  modifyIORef' env $ \ed -> ed
    { envBindings = Map.insert "haskell-call"
        (mkPrim "haskell-call" (haskellCall reg))
        (envBindings ed)
    , envHsRegistry = reg
    }
  pure env

haskellCall :: HsFuncRegistry -> [Any] -> IO Any
haskellCall reg (nameVal : args)
  | graspTypeOf nameVal == GTStr = dispatchRegistered reg (toStr nameVal) args
haskellCall _ _ = error "haskell-call expects (haskell-call \"name\" args...)"

-- | Build the default registry of Haskell functions
defaultRegistry :: IO HsFuncRegistry
defaultRegistry = do
  succEntry <- mkIntIntEntry "succ" (succ :: Int -> Int)
  negEntry  <- mkIntIntEntry "negate" (negate :: Int -> Int)
  pure $ Map.fromList
    [ ("succ",    succEntry)
    , ("negate",  negEntry)
    , ("reverse", HsFuncEntry [HsListInt] HsListInt hsReverse)
    , ("length",  HsFuncEntry [HsListInt] HsInt     hsLength)
    ]

-- | Create a registry entry for an (Int -> Int) function via the C bridge
mkIntIntEntry :: Text -> (Int -> Int) -> IO HsFuncEntry
mkIntIntEntry name f = do
  sp <- newStablePtr f
  pure $ HsFuncEntry [HsInt] HsInt $ \case
    [v] -> do
      result <- bridgeSafeApplyIntInt sp (toInt v)
      case result of
        Right r -> pure $ mkInt r
        Left err -> error $ T.unpack name <> ": " <> err
    _ -> error $ "internal: " <> T.unpack name <> " called with invalid args after validation"

hsReverse :: [Any] -> IO Any
hsReverse [listVal] = pure $ fromHaskellListInt (reverse (toHaskellListInt listVal))
hsReverse args = error $ "internal: reverse called with " <> show (length args) <> " args after validation"

hsLength :: [Any] -> IO Any
hsLength [listVal] = pure $ mkInt (length (toHaskellListInt listVal))
hsLength args = error $ "internal: length called with " <> show (length args) <> " args after validation"

-- | Marshal GraspVal cons list to Haskell [Int]
toHaskellListInt :: Any -> [Int]
toHaskellListInt v
  | isNil v   = []
  | isCons v  = toInt (toCar v) : toHaskellListInt (toCdr v)
  | otherwise = error "expected list of integers"

-- | Marshal Haskell [Int] to GraspVal cons list
fromHaskellListInt :: [Int] -> Any
fromHaskellListInt = foldr (\x acc -> mkCons (mkInt x) acc) mkNil
