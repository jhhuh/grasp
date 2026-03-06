{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Grasp.Eval
  ( eval
  , defaultEnv
  ) where

import Data.IORef
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import GHC.Exts (Any)

import Grasp.Types
import Grasp.NativeTypes
import Grasp.HsRegistry (dispatchRegistered)

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
numBinOp op [a, b] = pure $ mkInt (op (toInt a) (toInt b))
numBinOp _ args = error $ "expected two integers, got: " <> show (length args) <> " args"

eqOp :: [Any] -> IO Any
eqOp [a, b] = pure $ mkBool (graspEq a b)
eqOp _ = error "= expects two arguments"

cmpOp :: (Int -> Int -> Bool) -> [Any] -> IO Any
cmpOp op [a, b] = pure $ mkBool (op (toInt a) (toInt b))
cmpOp _ _ = error "comparison expects two integers"

listOp :: [Any] -> IO Any
listOp = pure . foldr mkCons mkNil

consOp :: [Any] -> IO Any
consOp [a, b] = pure $ mkCons a b
consOp _ = error "cons expects two arguments"

carOp :: [Any] -> IO Any
carOp [v] | isCons v = pure $ toCar v
carOp _ = error "car expects a cons cell"

cdrOp :: [Any] -> IO Any
cdrOp [v] | isCons v = pure $ toCdr v
cdrOp _ = error "cdr expects a cons cell"

nullOp :: [Any] -> IO Any
nullOp [v] = pure $ mkBool (isNil v)
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
  if graspTypeOf c == GTBoolFalse
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
-- hs: prefix dispatches to the Haskell function registry
eval env (EList (ESym name : args))
  | Just hsName <- T.stripPrefix "hs:" name = do
      ed <- readIORef env
      vals <- mapM (eval env) args
      dispatchRegistered (envHsRegistry ed) hsName vals
eval env (EList (fn : args)) = do
  f <- eval env fn
  vals <- mapM (eval env) args
  apply f vals
eval _ e = error $ "cannot eval: " <> show e

apply :: Any -> [Any] -> IO Any
apply v args = case graspTypeOf v of
  GTPrim -> toPrimFn v args
  GTLambda -> do
    let (params, body, closure) = toLambdaParts v
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
