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

import Grasp.Types
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
        (LPrimitive "haskell-call" (haskellCall reg))
        (envBindings ed)
    , envHsRegistry = reg
    }
  pure env

haskellCall :: HsFuncRegistry -> [LispVal] -> IO LispVal
haskellCall reg (LStr name : args) = dispatchRegistered reg name args
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
    [LInt n] -> do
      result <- bridgeSafeApplyIntInt sp (fromIntegral n)
      case result of
        Right v -> pure $ LInt (fromIntegral v)
        Left err -> error $ T.unpack name <> ": " <> err
    _ -> error $ "internal: " <> T.unpack name <> " called with invalid args after validation"

hsReverse :: [LispVal] -> IO LispVal
hsReverse [listVal] = pure $ fromHaskellListInt (reverse (toHaskellListInt listVal))
hsReverse args = error $ "internal: reverse called with " <> show (length args) <> " args after validation"

hsLength :: [LispVal] -> IO LispVal
hsLength [listVal] = pure $ LInt (fromIntegral (length (toHaskellListInt listVal)))
hsLength args = error $ "internal: length called with " <> show (length args) <> " args after validation"

-- | Marshal LispVal cons list to Haskell [Int]
toHaskellListInt :: LispVal -> [Int]
toHaskellListInt LNil = []
toHaskellListInt (LCons (LInt n) rest) = fromIntegral n : toHaskellListInt rest
toHaskellListInt _ = error "expected list of integers"

-- | Marshal Haskell [Int] to LispVal cons list
fromHaskellListInt :: [Int] -> LispVal
fromHaskellListInt = foldr (\x acc -> LCons (LInt (fromIntegral x)) acc) LNil
