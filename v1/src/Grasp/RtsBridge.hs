{-# LANGUAGE ScopedTypeVariables #-}
module Grasp.RtsBridge
  ( bridgeRoundtripInt
  , bridgeApplyIntInt
  , bridgeSafeApplyIntInt
  ) where

import Control.Exception (SomeException, displayException, evaluate, try)
import Foreign.StablePtr (StablePtr, deRefStablePtr, freeStablePtr)

foreign import ccall safe "grasp_roundtrip_int"
  c_roundtrip_int :: Int -> IO Int

foreign import ccall safe "grasp_apply_int_int"
  c_apply_int_int :: StablePtr (Int -> Int) -> Int -> IO Int

foreign import ccall safe "grasp_build_int_app"
  c_build_int_app :: StablePtr (Int -> Int) -> Int -> IO (StablePtr Int)

bridgeRoundtripInt :: Int -> IO Int
bridgeRoundtripInt = c_roundtrip_int

-- | UNSAFE: aborts process on Haskell exceptions. Kept for tests.
bridgeApplyIntInt :: StablePtr (Int -> Int) -> Int -> IO Int
bridgeApplyIntInt = c_apply_int_int

-- | Safe: builds thunk in C, forces in Haskell with exception catching.
bridgeSafeApplyIntInt :: StablePtr (Int -> Int) -> Int -> IO (Either String Int)
bridgeSafeApplyIntInt fnSp arg = do
  thunkSp <- c_build_int_app fnSp arg
  thunk <- deRefStablePtr thunkSp
  result <- try (evaluate thunk)
  freeStablePtr thunkSp
  case result of
    Left (e :: SomeException) -> pure (Left (displayException e))
    Right v -> pure (Right v)
