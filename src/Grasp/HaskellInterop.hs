{-# LANGUAGE OverloadedStrings #-}
module Grasp.HaskellInterop
  ( defaultEnvWithInterop
  ) where

import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Foreign.StablePtr

import Grasp.Types
import Grasp.Eval (defaultEnv)
import Grasp.RtsBridge (bridgeSafeApplyIntInt)

-- | Default environment extended with haskell-call
defaultEnvWithInterop :: IO Env
defaultEnvWithInterop = do
  env <- defaultEnv
  modifyIORef' env $ Map.insert "haskell-call" $
    LPrimitive "haskell-call" haskellCall
  pure env

haskellCall :: [LispVal] -> IO LispVal
haskellCall [LStr name, arg] = dispatchHaskellCall name arg
haskellCall _ = error "haskell-call expects (haskell-call \"name\" arg)"

dispatchHaskellCall :: Text -> LispVal -> IO LispVal
-- Int -> Int functions: route through C bridge (rts_apply/rts_eval)
dispatchHaskellCall "succ" (LInt n) = do
  sp <- newStablePtr (succ :: Int -> Int)
  result <- bridgeSafeApplyIntInt sp (fromIntegral n)
  freeStablePtr sp
  case result of
    Right v -> pure $ LInt (fromIntegral v)
    Left err -> error $ "haskell-call succ: " <> err

dispatchHaskellCall "negate" (LInt n) = do
  sp <- newStablePtr (negate :: Int -> Int)
  result <- bridgeSafeApplyIntInt sp (fromIntegral n)
  freeStablePtr sp
  case result of
    Right v -> pure $ LInt (fromIntegral v)
    Left err -> error $ "haskell-call negate: " <> err

-- List functions: Haskell-side marshaling
dispatchHaskellCall "reverse" listVal = do
  let hs = toHaskellListInt listVal
  pure $ fromHaskellListInt (reverse hs)

dispatchHaskellCall "length" listVal = do
  let hs = toHaskellListInt listVal
  pure $ LInt (fromIntegral (length hs))

dispatchHaskellCall name _ = error $ "unknown Haskell function: " <> T.unpack name

-- | Marshal LispVal cons list to Haskell [Int]
toHaskellListInt :: LispVal -> [Int]
toHaskellListInt LNil = []
toHaskellListInt (LCons (LInt n) rest) = fromIntegral n : toHaskellListInt rest
toHaskellListInt _ = error "expected list of integers"

-- | Marshal Haskell [Int] to LispVal cons list
fromHaskellListInt :: [Int] -> LispVal
fromHaskellListInt = foldr (\x acc -> LCons (LInt (fromIntegral x)) acc) LNil
