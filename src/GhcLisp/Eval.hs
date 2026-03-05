{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module GhcLisp.Eval
  ( eval
  , defaultEnv
  ) where

import Data.IORef
import qualified Data.Text as T
import qualified Data.Map.Strict as Map

import GhcLisp.Types

defaultEnv :: IO Env
defaultEnv = newIORef $ Map.fromList
  [ ("+", LPrimitive "+" (numBinOp (+)))
  , ("-", LPrimitive "-" (numBinOp (-)))
  , ("*", LPrimitive "*" (numBinOp (*)))
  , ("div", LPrimitive "div" (numBinOp div))
  , ("=", LPrimitive "=" eqOp)
  , ("<", LPrimitive "<" (cmpOp (<)))
  , (">", LPrimitive ">" (cmpOp (>)))
  , ("list", LPrimitive "list" listOp)
  , ("cons", LPrimitive "cons" consOp)
  , ("car", LPrimitive "car" carOp)
  , ("cdr", LPrimitive "cdr" cdrOp)
  , ("null?", LPrimitive "null?" nullOp)
  ]

numBinOp :: (Integer -> Integer -> Integer) -> [LispVal] -> IO LispVal
numBinOp op [LInt a, LInt b] = pure $ LInt (op a b)
numBinOp _ args = error $ "expected two integers, got: " <> show (length args) <> " args"

eqOp :: [LispVal] -> IO LispVal
eqOp [a, b] = pure $ LBool (a == b)
eqOp _ = error "= expects two arguments"

cmpOp :: (Integer -> Integer -> Bool) -> [LispVal] -> IO LispVal
cmpOp op [LInt a, LInt b] = pure $ LBool (op a b)
cmpOp _ _ = error "comparison expects two integers"

listOp :: [LispVal] -> IO LispVal
listOp = pure . foldr LCons LNil

consOp :: [LispVal] -> IO LispVal
consOp [a, b] = pure $ LCons a b
consOp _ = error "cons expects two arguments"

carOp :: [LispVal] -> IO LispVal
carOp [LCons a _] = pure a
carOp _ = error "car expects a cons cell"

cdrOp :: [LispVal] -> IO LispVal
cdrOp [LCons _ d] = pure d
cdrOp _ = error "cdr expects a cons cell"

nullOp :: [LispVal] -> IO LispVal
nullOp [LNil] = pure $ LBool True
nullOp [_]    = pure $ LBool False
nullOp _      = error "null? expects one argument"

eval :: Env -> LispExpr -> IO LispVal
eval _ (EInt n)    = pure $ LInt n
eval _ (EDouble d) = pure $ LDouble d
eval _ (EStr s)    = pure $ LStr s
eval _ (EBool b)   = pure $ LBool b
eval env (ESym s)  = do
  bindings <- readIORef env
  case Map.lookup s bindings of
    Just v  -> pure v
    Nothing -> error $ "unbound symbol: " <> T.unpack s
eval env (EList [ESym "quote", e]) = evalQuote e
eval env (EList [ESym "if", cond, then_, else_]) = do
  c <- eval env cond
  case c of
    LBool False -> eval env else_
    _           -> eval env then_
eval env (EList [ESym "define", ESym name, body]) = do
  val <- eval env body
  modifyIORef' env (Map.insert name val)
  pure val
eval env (EList (ESym "lambda" : EList params : body)) = do
  let paramNames = map (\case ESym s -> s; _ -> error "lambda params must be symbols") params
  case body of
    [expr] -> pure $ LFun paramNames expr env
    _      -> error "lambda body must be a single expression"
eval env (EList (fn : args)) = do
  f <- eval env fn
  vals <- mapM (eval env) args
  apply f vals
eval _ e = error $ "cannot eval: " <> show e

apply :: LispVal -> [LispVal] -> IO LispVal
apply (LPrimitive _ f) args = f args
apply (LFun params body closure) args = do
  let bindings = Map.fromList (zip params args)
  parentBindings <- readIORef closure
  childEnv <- newIORef (Map.union bindings parentBindings)
  eval childEnv body
apply v _ = error $ "not a function: " <> show v

evalQuote :: LispExpr -> IO LispVal
evalQuote (EInt n)    = pure $ LInt n
evalQuote (EDouble d) = pure $ LDouble d
evalQuote (ESym s)    = pure $ LSym s
evalQuote (EStr s)    = pure $ LStr s
evalQuote (EBool b)   = pure $ LBool b
evalQuote (EList xs)  = foldr LCons LNil <$> mapM evalQuote xs
