module Grasp.RtsBridge
  ( bridgeRoundtripInt
  , bridgeApplyIntInt
  ) where

import Foreign.StablePtr (StablePtr)

foreign import ccall safe "grasp_roundtrip_int"
  c_roundtrip_int :: Int -> IO Int

foreign import ccall safe "grasp_apply_int_int"
  c_apply_int_int :: StablePtr (Int -> Int) -> Int -> IO Int

bridgeRoundtripInt :: Int -> IO Int
bridgeRoundtripInt = c_roundtrip_int

bridgeApplyIntInt :: StablePtr (Int -> Int) -> Int -> IO Int
bridgeApplyIntInt = c_apply_int_int
