{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Grasp.Eval
  ( eval
  , apply
  , defaultEnv
  ) where

import Data.IORef
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import GHC.Exts (Any)

import Grasp.Types
import Grasp.NativeTypes

defaultEnv :: IO Env
defaultEnv = do
  ghcRef <- newIORef Nothing
  newIORef $ EnvData
    { envBindings = Map.fromList
        [ ("+",     mkPrim "+"     (numBinOp (+)))
        , ("-",     mkPrim "-"     (numBinOp (-)))
        , ("*",     mkPrim "*"     (numBinOp (*)))
        , ("div",   mkPrim "div"   (numBinOp div))
        , ("=",     mkPrim "="     eqOp)
        , ("<",     mkPrim "<"     (cmpOp (<)))
        , (">",     mkPrim ">"     (cmpOp (>)))
        , ("list",  mkPrim "list"  listOp)
        , ("cons",  mkPrim "cons"  consOp)
        , ("car",   mkPrim "car"   carOp)
        , ("cdr",   mkPrim "cdr"   cdrOp)
        , ("null?", mkPrim "null?" nullOp)
        ]
    , envHsRegistry = Map.empty
    , envGhcSession = ghcRef
    , envModules    = Map.empty
    , envLoading    = []
    }

-- ─── Primitive implementations ──────────────────────────────

numBinOp :: (Int -> Int -> Int) -> [Any] -> IO Any
numBinOp op [a, b] = do
  a' <- forceIfLazy a
  b' <- forceIfLazy b
  pure $ mkInt (op (toInt a') (toInt b'))
numBinOp _ args = error $ "expected two integers, got " <> show (length args) <> " args"

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
carOp _ = error "car expects one argument"

cdrOp :: [Any] -> IO Any
cdrOp [v] = do
  v' <- forceIfLazy v
  if isCons v' then pure $ toCdr v'
  else error "cdr expects a cons cell"
cdrOp _ = error "cdr expects one argument"

nullOp :: [Any] -> IO Any
nullOp [v] = do
  v' <- forceIfLazy v
  pure $ mkBool (isNil v')
nullOp _ = error "null? expects one argument"

-- ─── Evaluator ──────────────────────────────────────────────

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
  pure mkNil
eval env (EList (ESym "lambda" : EList params : body)) = do
  let paramNames = map (\case ESym s -> s; _ -> error "lambda params must be symbols") params
  case body of
    []     -> error "lambda must have at least one body expression"
    [expr] -> pure $ mkLambda paramNames expr env
    _      -> pure $ mkLambda paramNames (EList (ESym "begin" : body)) env
eval env (EList (ESym "begin" : exprs)) = case exprs of
  [] -> pure mkNil
  _  -> last <$> mapM (eval env) exprs
eval env (EList (fn : args)) = do
  f <- eval env fn
  f' <- forceIfLazy f
  vals <- mapM (eval env) args
  apply f' vals
eval _ (EList []) = pure mkNil
-- Catch-all for EQuoter/EAntiquote — not supported yet
eval _ e = error $ "eval: unsupported expression: " <> show e

-- ─── Apply ──────────────────────────────────────────────────

apply :: Any -> [Any] -> IO Any
apply v args = do
  v' <- forceIfLazy v
  case graspTypeOf v' of
    GTPrim -> toPrimFn v' args
    GTLambda -> do
      let (params, body, closure) = toLambdaParts v'
          np = length params
          na = length args
      if np /= na
        then error $ "lambda expects " <> show np <> " args, got " <> show na
        else do
          let bindings = Map.fromList (zip params args)
          parentEd <- readIORef closure
          childEnv <- newIORef $ parentEd { envBindings = Map.union bindings (envBindings parentEd) }
          eval childEnv body
    t -> error $ "not a function: " <> showGraspType t

-- ─── Quote helper ───────────────────────────────────────────

evalQuote :: LispExpr -> IO GraspVal
evalQuote (EInt n)    = pure $ mkInt (fromInteger n)
evalQuote (EDouble d) = pure $ mkDouble d
evalQuote (ESym s)    = pure $ mkSym s
evalQuote (EStr s)    = pure $ mkStr s
evalQuote (EBool b)   = pure $ mkBool b
evalQuote (EList xs)  = do
  vals <- mapM evalQuote xs
  pure $ foldr mkCons mkNil vals
evalQuote e = error $ "evalQuote: unsupported expression: " <> show e
