{-# LANGUAGE OverloadedStrings #-}
module Grasp.HaskellInterop
  ( defaultEnvWithInterop
  , defaultRegistry
  ) where

import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Foreign.StablePtr

import Grasp.Types
import Grasp.Eval (defaultEnv)
import Grasp.RtsBridge (bridgeSafeApplyIntInt)
import Grasp.HsRegistry (dispatchRegistered)

-- | Default environment extended with haskell-call
defaultEnvWithInterop :: IO Env
defaultEnvWithInterop = do
  env <- defaultEnv
  reg <- defaultRegistry
  modifyIORef' env $ Map.insert "haskell-call" $
    LPrimitive "haskell-call" (haskellCall reg)
  pure env

haskellCall :: HsFuncRegistry -> [LispVal] -> IO LispVal
haskellCall reg [LStr name, arg] = dispatchRegistered reg name [arg]
haskellCall _ _ = error "haskell-call expects (haskell-call \"name\" arg)"

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
  pure $ HsFuncEntry [HsInt] HsInt $ \[LInt n] -> do
    result <- bridgeSafeApplyIntInt sp (fromIntegral n)
    case result of
      Right v -> pure $ LInt (fromIntegral v)
      Left err -> error $ show name <> ": " <> err

hsReverse :: [LispVal] -> IO LispVal
hsReverse [listVal] = pure $ fromHaskellListInt (reverse (toHaskellListInt listVal))
hsReverse _ = error "reverse: expected 1 argument"

hsLength :: [LispVal] -> IO LispVal
hsLength [listVal] = pure $ LInt (fromIntegral (length (toHaskellListInt listVal)))
hsLength _ = error "length: expected 1 argument"

-- | Marshal LispVal cons list to Haskell [Int]
toHaskellListInt :: LispVal -> [Int]
toHaskellListInt LNil = []
toHaskellListInt (LCons (LInt n) rest) = fromIntegral n : toHaskellListInt rest
toHaskellListInt _ = error "expected list of integers"

-- | Marshal Haskell [Int] to LispVal cons list
fromHaskellListInt :: [Int] -> LispVal
fromHaskellListInt = foldr (\x acc -> LCons (LInt (fromIntegral x)) acc) LNil
