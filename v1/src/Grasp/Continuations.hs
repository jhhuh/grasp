{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE LambdaCase #-}
module Grasp.Continuations
  ( newPromptTag
  , prompt
  , control0
  , pushHandler
  , popHandler
  , peekHandler
  ) where

import GHC.Exts (Any, PromptTag#, newPromptTag#, prompt#, control0#)
import GHC.IO (IO(IO))
import Unsafe.Coerce (unsafeCoerce)
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)

-- unsafeCoerce can't bridge lifted<->unlifted types.
-- We use unsafeCoerce# (re-exported from GHC.Exts) for that.
-- But unsafeCoerce# is levity-polymorphic and tricky to import directly.
-- Instead we use a helper via Any and unboxed coercion through inline wrappers.

-- | Box a PromptTag# as a lifted Any value
boxTag :: PromptTag# Any -> Any
boxTag t = case unsafeCoerce (BoxTag t) of (a :: Any) -> a

-- | Unbox an Any back to PromptTag#
unboxTag :: Any -> PromptTag# Any
unboxTag a = case unsafeCoerce a of BoxTag t -> t

-- Helper newtype to bridge the levity gap
data BoxTag = BoxTag (PromptTag# Any)

-- | Create a new prompt tag, returned as boxed Any
newPromptTag :: IO Any
newPromptTag = IO $ \s ->
  case newPromptTag# s of
    (# s', tag #) -> (# s', boxTag tag #)

-- | Delimit a computation with a prompt tag.
-- tag is a boxed PromptTag# (as Any). body is the IO computation to run.
prompt :: Any -> IO Any -> IO Any
prompt tagBox body = IO $ \s ->
  prompt# (unboxTag tagBox)
    (\s' -> case body of IO f -> f s') s

-- | Capture the continuation up to the nearest prompt with the given tag.
-- The callback receives a function (Any -> IO Any) that resumes the continuation.
control0 :: Any -> ((Any -> IO Any) -> IO Any) -> IO Any
control0 tagBox callback = IO $ \s ->
  control0# (unboxTag tagBox)
    (\k s' -> case callback (\v -> IO (\s'' -> k (\s3 -> (# s3, v #)) s'')) of IO f -> f s')
    s

-- Global handler stack: list of (promptTag, handlerFn) pairs as Any
{-# NOINLINE handlerStack #-}
handlerStack :: IORef [(Any, Any)]
handlerStack = unsafePerformIO (newIORef [])

pushHandler :: Any -> Any -> IO ()
pushHandler tag handler = modifyIORef' handlerStack ((tag, handler) :)

popHandler :: IO ()
popHandler = modifyIORef' handlerStack $ \case
  [] -> []
  (_:rest) -> rest

peekHandler :: IO (Maybe (Any, Any))
peekHandler = do
  stack <- readIORef handlerStack
  pure $ case stack of
    []    -> Nothing
    (h:_) -> Just h
