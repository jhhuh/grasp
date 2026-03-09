{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MagicHash #-}
module Grasp.DynDispatch
  ( getOrInitGhc
  , dynDispatch
  , dynDispatchAnnotated
  , marshalGraspToHaskell
  , marshalHaskellToGrasp
  ) where

import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Control.Monad (when, zipWithM)
import GHC.Exts (Any)
import GHC.Int (Int(I#))
import GHC.Float (Double(D#))
import Unsafe.Coerce (unsafeCoerce)

import Grasp.NativeTypes
import Grasp.DynLookup (GhcState, GraspArgType(..), GraspFuncInfo(..), initGhcState, lookupFunc, dynCall, dynCallInferred)

-- ─── GHC session management ──────────────────────────────

-- | Get or lazily initialize the GHC API session from the env ref.
getOrInitGhc :: IORef (Maybe Any) -> IO GhcState
getOrInitGhc gsRef = do
  mgs <- readIORef gsRef
  case mgs of
    Just gs -> pure (unsafeCoerce gs :: GhcState)
    Nothing -> do
      gs <- initGhcState
      writeIORef gsRef (Just (unsafeCoerce gs :: Any))
      pure gs

-- ─── Grasp ↔ Haskell marshaling ──────────────────────────

-- | Marshal a Grasp value to what Haskell expects, based on type info.
marshalGraspToHaskell :: GraspArgType -> Any -> IO Any
marshalGraspToHaskell NativeInt    v = pure v
marshalGraspToHaskell NativeDouble v = pure v
marshalGraspToHaskell NativeBool   v = pure v
marshalGraspToHaskell HaskellText  v = pure v
marshalGraspToHaskell HaskellString v = pure $ unsafeCoerce (T.unpack (toStr v))
marshalGraspToHaskell (ListOf elemType) v = unsafeCoerce <$> toHaskellList elemType v

-- | Convert a Grasp cons chain to a Haskell list.
toHaskellList :: GraspArgType -> Any -> IO [Any]
toHaskellList _ v | isNil v = pure []
toHaskellList elemType v | isCons v = do
  hd <- marshalGraspToHaskell elemType (toCar v)
  tl <- toHaskellList elemType (toCdr v)
  pure (hd : tl)
toHaskellList _ _ = error "expected a list"

-- | Marshal a Haskell return value back to Grasp representation.
-- Re-boxes primitive values by unboxing and re-boxing, forcing fresh allocation
-- with our binary's info tables. GHC API bytecode interpreter may use different
-- info tables for standard constructors like I#, D#, True, False.
marshalHaskellToGrasp :: GraspArgType -> Any -> IO Any
marshalHaskellToGrasp NativeInt    v = pure $! reboxInt (unsafeCoerce v)
marshalHaskellToGrasp NativeDouble v = pure $! reboxDouble (unsafeCoerce v)
marshalHaskellToGrasp NativeBool   v = pure $! reboxBool (unsafeCoerce v)
marshalHaskellToGrasp HaskellText  v = pure v
marshalHaskellToGrasp HaskellString v = pure $ mkStr (T.pack (unsafeCoerce v))
marshalHaskellToGrasp (ListOf elemType) v = do
  let hsList = unsafeCoerce v :: [Any]
  elems <- mapM (marshalHaskellToGrasp elemType) hsList
  pure $ foldr mkCons mkNil elems

-- | Unbox and re-box an Int to get our binary's I# info table.
{-# NOINLINE reboxInt #-}
reboxInt :: Int -> Any
reboxInt (I# n) = unsafeCoerce (I# n)

-- | Unbox and re-box a Double to get our binary's D# info table.
{-# NOINLINE reboxDouble #-}
reboxDouble :: Double -> Any
reboxDouble (D# d) = unsafeCoerce (D# d)

-- | Re-box a Bool to get our binary's True/False info tables.
{-# NOINLINE reboxBool #-}
reboxBool :: Bool -> Any
reboxBool True  = unsafeCoerce True
reboxBool False = unsafeCoerce False

-- ─── Type inference from Grasp values ──────────────────

-- | Infer a GraspArgType from a Grasp runtime value.
inferArgType :: Any -> GraspArgType
inferArgType v = case graspTypeOf v of
  GTInt       -> NativeInt
  GTDouble    -> NativeDouble
  GTBoolTrue  -> NativeBool
  GTBoolFalse -> NativeBool
  GTNil       -> ListOf NativeInt   -- empty list defaults to [Int]
  GTCons      -> ListOf (inferElemType v)
  GTStr       -> HaskellString
  _           -> NativeInt  -- fallback

-- | Infer the element type of a cons chain.
inferElemType :: Any -> GraspArgType
inferElemType v
  | isNil v   = NativeInt  -- default for empty
  | isCons v  = inferArgType (toCar v)
  | otherwise = NativeInt

-- | Render a GraspArgType as a Haskell type string.
argTypeToHaskell :: GraspArgType -> Text
argTypeToHaskell NativeInt      = "Int"
argTypeToHaskell NativeDouble   = "Double"
argTypeToHaskell NativeBool     = "Bool"
argTypeToHaskell HaskellString  = "String"
argTypeToHaskell HaskellText    = "Data.Text.Text"
argTypeToHaskell (ListOf inner) = "[" <> argTypeToHaskell inner <> "]"

-- | Guess the return type from a function name and its argument types.
-- For most cases, assume the return type matches the first arg.
-- Special cases: functions known to return different types.
guessReturnType :: Text -> [GraspArgType] -> GraspArgType
guessReturnType name argTypes
  -- Functions known to return Int from a list
  | baseName `elem` ["length", "sum", "product", "maximum", "minimum"]
  , [ListOf _] <- argTypes
  = NativeInt
  -- Functions known to return Bool
  | baseName `elem` ["null", "elem", "even", "odd", "and", "or"]
  = NativeBool
  | otherwise
  = case argTypes of
      (t:_) -> t          -- same as first arg
      []    -> NativeInt  -- shouldn't happen
  where
    -- Strip module qualifier: "Data.List.sort" -> "sort"
    baseName = snd (T.breakOnEnd "." name)

-- | Build a type-annotated expression from a name and inferred arg types.
-- e.g. "abs" [NativeInt] -> "(abs :: Int -> Int)"
buildAnnotatedExpr :: Text -> [GraspArgType] -> Text
buildAnnotatedExpr name argTypes =
  let retType = guessReturnType name argTypes
      allTypes = map argTypeToHaskell argTypes <> [argTypeToHaskell retType]
      sig = T.intercalate " -> " allTypes
  in "(" <> name <> " :: " <> sig <> ")"

-- ─── Dynamic dispatch ────────────────────────────────────

-- | Full dynamic dispatch: look up function, marshal, call, marshal back.
-- Tries bare name lookup first; if that fails (e.g. polymorphic function),
-- infers a type annotation from the actual args and retries with dynCall.
dynDispatch :: IORef (Maybe Any) -> Text -> [Any] -> IO Any
dynDispatch gsRef name args = do
  state <- getOrInitGhc gsRef
  args' <- mapM forceIfLazy args
  typeResult <- lookupFunc state name
  case typeResult of
    Right info -> do
      when (length args' /= funcArity info) $
        error $ T.unpack name <> ": expected " <> show (funcArity info)
              <> " argument(s), got " <> show (length args')
      marshaledArgs <- zipWithM marshalGraspToHaskell (funcArgs info) args'
      result <- dynCallInferred state name marshaledArgs
      marshalHaskellToGrasp (funcReturn info) result
    Left _ -> do
      -- Polymorphic function — infer types from actual arguments
      let inferredArgs = map inferArgType args'
          annotated = buildAnnotatedExpr name inferredArgs
      typeResult2 <- lookupFunc state annotated
      case typeResult2 of
        Left err2 -> error $ T.unpack name <> ": " <> err2
        Right info -> do
          when (length args' /= funcArity info) $
            error $ T.unpack name <> ": expected " <> show (funcArity info)
                  <> " argument(s), got " <> show (length args')
          marshaledArgs <- zipWithM marshalGraspToHaskell (funcArgs info) args'
          result <- dynCall state annotated marshaledArgs
          marshalHaskellToGrasp (funcReturn info) result

-- | Dynamic dispatch with explicit type annotation (for hs@ form).
dynDispatchAnnotated :: IORef (Maybe Any) -> Text -> [Any] -> IO Any
dynDispatchAnnotated gsRef expr args = do
  state <- getOrInitGhc gsRef
  args' <- mapM forceIfLazy args
  typeResult <- lookupFunc state expr
  case typeResult of
    Left err -> error $ "hs@: " <> err
    Right info -> do
      when (length args' /= funcArity info) $
        error $ "hs@: expected " <> show (funcArity info)
              <> " argument(s), got " <> show (length args')
      marshaledArgs <- zipWithM marshalGraspToHaskell (funcArgs info) args'
      result <- dynCall state expr marshaledArgs
      marshalHaskellToGrasp (funcReturn info) result
