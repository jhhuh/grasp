{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Grasp.Eval
  ( eval
  , defaultEnv
  , anyToExpr
  ) where

import Data.IORef
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import GHC.Exts (Any)
import System.IO.Unsafe (unsafeInterleaveIO)

import Grasp.Types
import Grasp.NativeTypes
import Grasp.HsRegistry (dispatchRegistered)
import Grasp.DynDispatch (dynDispatch, dynDispatchAnnotated)

defaultEnv :: IO Env
defaultEnv = do
  ghcRef <- newIORef Nothing
  newIORef $ EnvData
    { envBindings = Map.fromList
        [ ("+", mkPrim "+" (numBinOp (+)))
        , ("-", mkPrim "-" (numBinOp (-)))
        , ("*", mkPrim "*" (numBinOp (*)))
        , ("div", mkPrim "div" (numBinOp div))
        , ("=", mkPrim "=" eqOp)
        , ("<", mkPrim "<" (cmpOp (<)))
        , (">", mkPrim ">" (cmpOp (>)))
        , ("list", mkPrim "list" listOp)
        , ("cons", mkPrim "cons" consOp)
        , ("car", mkPrim "car" carOp)
        , ("cdr", mkPrim "cdr" cdrOp)
        , ("null?", mkPrim "null?" nullOp)
        ]
    , envHsRegistry = Map.empty
    , envGhcSession = ghcRef
    }

numBinOp :: (Int -> Int -> Int) -> [Any] -> IO Any
numBinOp op [a, b] = do
  a' <- forceIfLazy a
  b' <- forceIfLazy b
  pure $ mkInt (op (toInt a') (toInt b'))
numBinOp _ args = error $ "expected two integers, got: " <> show (length args) <> " args"

eqOp :: [Any] -> IO Any
eqOp [a, b] = mkBool <$> graspEq a b
eqOp _ = error "= expects two arguments"

cmpOp :: (Int -> Int -> Bool) -> [Any] -> IO Any
cmpOp op [a, b] = do
  a' <- forceIfLazy a
  b' <- forceIfLazy b
  pure $ mkBool (op (toInt a') (toInt b'))
cmpOp _ _ = error "comparison expects two integers"

listOp :: [Any] -> IO Any
listOp = pure . foldr mkCons mkNil

consOp :: [Any] -> IO Any
consOp [a, b] = pure $ mkCons a b
consOp _ = error "cons expects two arguments"

carOp :: [Any] -> IO Any
carOp [v] = do
  v' <- forceIfLazy v
  if isCons v' then pure $ toCar v'
  else error "car expects a cons cell"
carOp _ = error "car expects a cons cell"

cdrOp :: [Any] -> IO Any
cdrOp [v] = do
  v' <- forceIfLazy v
  if isCons v' then pure $ toCdr v'
  else error "cdr expects a cons cell"
cdrOp _ = error "cdr expects a cons cell"

nullOp :: [Any] -> IO Any
nullOp [v] = do
  v' <- forceIfLazy v
  pure $ mkBool (isNil v')
nullOp _ = error "null? expects one argument"

eval :: Env -> LispExpr -> IO GraspVal
eval _ (EInt n)    = pure $ mkInt (fromInteger n)
eval _ (EDouble d) = pure $ mkDouble d
eval _ (EStr s)    = pure $ mkStr s
eval _ (EBool b)   = pure $ mkBool b
eval env (ESym s)  = do
  ed <- readIORef env
  case Map.lookup s (envBindings ed) of
    Just v  -> pure v
    Nothing -> error $ "unbound symbol: " <> T.unpack s
eval _ (EList [ESym "quote", e]) = evalQuote e
eval env (EList [ESym "if", cond, then_, else_]) = do
  c <- eval env cond
  c' <- forceIfLazy c
  if graspTypeOf c' == GTBoolFalse
    then eval env else_
    else eval env then_
eval env (EList [ESym "define", ESym name, body]) = do
  val <- eval env body
  modifyIORef' env $ \ed -> ed { envBindings = Map.insert name val (envBindings ed) }
  pure val
eval env (EList (ESym "lambda" : EList params : body)) = do
  let paramNames = map (\case ESym s -> s; _ -> error "lambda params must be symbols") params
  case body of
    [expr] -> pure $ mkLambda paramNames expr env
    _      -> error "lambda body must be a single expression"
-- defmacro: define a macro
eval env (EList [ESym "defmacro", ESym name, EList params, body]) = do
  let paramNames = map (\case ESym s -> s; _ -> error "macro params must be symbols") params
  let macro = mkMacro paramNames body env
  modifyIORef' env $ \ed -> ed { envBindings = Map.insert name macro (envBindings ed) }
  pure macro
-- lazy: defer evaluation into a real GHC THUNK
eval env (EList [ESym "lazy", body]) = do
  thunk <- unsafeInterleaveIO (eval env body)
  pure (mkLazy thunk)
-- force: enter a lazy thunk, triggering GHC's update mechanism
eval env (EList [ESym "force", expr]) = do
  v <- eval env expr
  forceIfLazy v
-- hs@ annotated form: (hs@ "expr :: Type" args...)
eval env (EList (ESym "hs@" : exprArg : funcArgs)) = do
  exprVal <- eval env exprArg
  if graspTypeOf exprVal /= GTStr
    then error "hs@: first argument must be a string"
    else do
      ed <- readIORef env
      vals <- mapM (eval env) funcArgs
      dynDispatchAnnotated (envGhcSession ed) (toStr exprVal) vals
-- hs: prefix dispatches to registry, falls back to GHC API dynamic lookup
eval env (EList (ESym name : args))
  | Just hsName <- T.stripPrefix "hs:" name = do
      ed <- readIORef env
      vals <- mapM (eval env) args
      case Map.lookup hsName (envHsRegistry ed) of
        Just _  -> dispatchRegistered (envHsRegistry ed) hsName vals
        Nothing -> dynDispatch (envGhcSession ed) hsName vals
eval env (EList (fn : args)) = do
  f <- eval env fn
  f' <- forceIfLazy f
  case graspTypeOf f' of
    GTMacro -> do
      quotedArgs <- mapM evalQuote args
      let (params, body, closure) = toMacroParts f'
      let np = length params
          na = length quotedArgs
      if np /= na
        then error $ "macro expects " <> show np <> " args, got " <> show na
        else do
          let bindings = Map.fromList (zip params quotedArgs)
          parentEd <- readIORef closure
          childEnv <- newIORef $ parentEd { envBindings = Map.union bindings (envBindings parentEd) }
          expansion <- eval childEnv body
          eval env (anyToExpr expansion)
    _ -> do
      vals <- mapM (eval env) args
      apply f' vals
eval _ (EList []) = pure mkNil
eval _ e = error $ "cannot eval: " <> show e

apply :: Any -> [Any] -> IO Any
apply v args = do
  v' <- forceIfLazy v
  case graspTypeOf v' of
    GTPrim -> toPrimFn v' args
    GTLambda -> do
      let (params, body, closure) = toLambdaParts v'
      let np = length params
          na = length args
      if np /= na
        then error $ "lambda expects " <> show np <> " args, got " <> show na
        else do
          let bindings = Map.fromList (zip params args)
          parentEd <- readIORef closure
          childEnv <- newIORef $ parentEd { envBindings = Map.union bindings (envBindings parentEd) }
          eval childEnv body
    t -> error $ "not a function: " <> showGraspType t

evalQuote :: LispExpr -> IO GraspVal
evalQuote (EInt n)    = pure $ mkInt (fromInteger n)
evalQuote (EDouble d) = pure $ mkDouble d
evalQuote (ESym s)    = pure $ mkSym s
evalQuote (EStr s)    = pure $ mkStr s
evalQuote (EBool b)   = pure $ mkBool b
evalQuote (EList xs)  = do
  vals <- mapM evalQuote xs
  pure $ foldr mkCons mkNil vals

-- | Convert a runtime value back to a LispExpr for macro expansion.
anyToExpr :: Any -> LispExpr
anyToExpr v = case graspTypeOf v of
  GTInt       -> EInt (fromIntegral (toInt v))
  GTDouble    -> EDouble (toDouble v)
  GTBoolTrue  -> EBool True
  GTBoolFalse -> EBool False
  GTSym       -> ESym (toSym v)
  GTStr       -> EStr (toStr v)
  GTNil       -> EList []
  GTCons      -> EList (consToExprList v)
  t           -> error $ "cannot use " <> showGraspType t <> " as code in macro expansion"

-- | Walk a cons chain, converting each element to LispExpr.
consToExprList :: Any -> [LispExpr]
consToExprList v
  | isNil v   = []
  | isCons v  = anyToExpr (toCar v) : consToExprList (toCdr v)
  | otherwise = error "improper list in macro expansion"
