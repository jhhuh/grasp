{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
module Main where

import GHC.Exts (Any, unpackClosure#)
import GHC.Ptr (Ptr(Ptr))
import Foreign.Ptr (FunPtr)
import Unsafe.Coerce (unsafeCoerce)
import Grasp.RuntimeCheck (readRepTag, RepTag(..), getInfoPtr)
import Grasp.NativeTypes

foreign import ccall unsafe "grasp_debug_info_ptr"
  debugInfoPtr :: Ptr () -> IO ()

main :: IO ()
main = do
  let intVal = mkInt 42
  putStrLn "=== Int ==="
  let p = getInfoPtr intVal
  putStrLn $ "Haskell getInfoPtr: " ++ show p
  debugInfoPtr p
  putStrLn ""

  putStrLn "=== Nil ==="
  let pN = getInfoPtr mkNil
  putStrLn $ "Haskell getInfoPtr: " ++ show pN
  debugInfoPtr pN
