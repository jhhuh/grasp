module Grasp.RtsBridge
  ( graspClosureType
  ) where

import Data.Word (Word)
import Foreign.Ptr (Ptr)

foreign import ccall unsafe "grasp_closure_type"
  graspClosureType :: Ptr () -> IO Word
