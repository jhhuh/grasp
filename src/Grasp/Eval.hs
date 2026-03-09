{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Grasp.Eval
  ( eval
  , apply
  , defaultEnv
  , EvalMode(..)
  ) where

import Data.IORef
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import GHC.Exts (Any)
import Control.Monad (when)

import System.IO.Unsafe (unsafeInterleaveIO)
import Control.Concurrent.STM (newTVarIO, readTVarIO, writeTVar, atomically)

import Grasp.Types
import Grasp.NativeTypes

-- ─── CBPV Eval Modes ──────────────────────────────────────

data EvalMode = ModeComputation | ModeTransaction
  deriving (Eq, Show)

ioOnlyPrims :: Set.Set T.Text
ioOnlyPrims = Set.fromList ["spawn", "make-chan", "chan-put", "chan-get"]

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
        , ("make-tvar",  mkPrim "make-tvar"  makeTVarOp)
        , ("read-tvar",  mkPrim "read-tvar"  readTVarOp)
        , ("write-tvar", mkPrim "write-tvar" writeTVarOp)
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

makeTVarOp :: [Any] -> IO Any
makeTVarOp [v] = mkTVar <$> newTVarIO v
makeTVarOp _ = error "make-tvar expects one argument"

readTVarOp :: [Any] -> IO Any
readTVarOp [v] = readTVarIO (toTVar v)
readTVarOp _ = error "read-tvar expects one argument"

writeTVarOp :: [Any] -> IO Any
writeTVarOp [tv, val] = do
  atomically $ writeTVar (toTVar tv) val
  pure mkNil
writeTVarOp _ = error "write-tvar expects two arguments"

-- ─── Evaluator ──────────────────────────────────────────────

eval :: EvalMode -> Env -> LispExpr -> IO GraspVal
eval _ _ (EInt n)    = pure $ mkInt (fromInteger n)
eval _ _ (EDouble d) = pure $ mkDouble d
eval _ _ (EStr s)    = pure $ mkStr s
eval _ _ (EBool b)   = pure $ mkBool b
eval mode env (ESym s)  = do
  ed <- readIORef env
  case Map.lookup s (envBindings ed) of
    Just v  -> pure v
    Nothing -> error $ "unbound symbol: " <> T.unpack s
eval _ _ (EList [ESym "quote", e]) = evalQuote e
eval mode env (EList [ESym "if", cond, then_, else_]) = do
  c <- eval mode env cond
  c' <- forceIfLazy c
  if graspTypeOf c' == GTBoolFalse
    then eval mode env else_
    else eval mode env then_
eval mode env (EList [ESym "define", ESym name, body]) = do
  val <- eval mode env body
  modifyIORef' env $ \ed -> ed { envBindings = Map.insert name val (envBindings ed) }
  pure mkNil
eval mode env (EList (ESym "lambda" : EList params : body)) = do
  let paramNames = map (\case ESym s -> s; _ -> error "lambda params must be symbols") params
  case body of
    []     -> error "lambda must have at least one body expression"
    [expr] -> pure $ mkLambda paramNames expr env
    _      -> pure $ mkLambda paramNames (EList (ESym "begin" : body)) env
eval mode env (EList (ESym "begin" : exprs)) = case exprs of
  [] -> pure mkNil
  _  -> last <$> mapM (eval mode env) exprs
eval mode env (EList (ESym "let" : EList bindings : body)) = do
  childEnv <- readIORef env >>= newIORef
  let go [] = pure ()
      go (ESym name : expr : rest) = do
        val <- eval mode childEnv expr
        modifyIORef' childEnv $ \ed ->
          ed { envBindings = Map.insert name val (envBindings ed) }
        go rest
      go _ = error "let: odd number of binding forms"
  go bindings
  let bodyExpr = case body of [e] -> e; es -> EList (ESym "begin" : es)
  eval mode childEnv bodyExpr
eval mode env (EList (ESym "loop" : EList bindings : body)) = do
  childEnv <- readIORef env >>= newIORef
  let pairs = goPairs bindings
      names = map fst pairs
      goPairs [] = []
      goPairs (ESym n : e : rest) = (n, e) : goPairs rest
      goPairs _ = error "loop: odd number of binding forms"
  mapM_ (\(name, expr) -> do
    val <- eval mode childEnv expr
    modifyIORef' childEnv $ \ed ->
      ed { envBindings = Map.insert name val (envBindings ed) }
    ) pairs
  let bodyExpr = case body of [e] -> e; es -> EList (ESym "begin" : es)
      go = do
        result <- eval mode childEnv bodyExpr
        if graspTypeOf result == GTRecur
          then do
            let newVals = toRecurArgs result
            modifyIORef' childEnv $ \ed ->
              ed { envBindings = foldr (uncurry Map.insert) (envBindings ed)
                                       (zip names newVals) }
            go
          else pure result
  go
eval mode env (EList (ESym "recur" : args)) = do
  vals <- mapM (eval mode env) args
  pure $ mkRecur vals
eval mode env (EList [ESym "lazy", body]) = do
  thunk <- unsafeInterleaveIO (eval mode env body)
  pure $ mkLazy thunk
eval mode env (EList [ESym "force", expr]) = do
  val <- eval mode env expr
  forceIfLazy val
eval _ env (EList [ESym "atomically", body]) = do
  eval ModeTransaction env body
eval mode env (EList (fn : args)) = do
  f <- eval mode env fn
  f' <- forceIfLazy f
  vals <- mapM (eval mode env) args
  apply mode f' vals
eval _ _ (EList []) = pure mkNil
-- Catch-all for EQuoter/EAntiquote — not supported yet
eval _ _ e = error $ "eval: unsupported expression: " <> show e

-- ─── Apply ──────────────────────────────────────────────────

apply :: EvalMode -> Any -> [Any] -> IO Any
apply mode v args = do
  v' <- forceIfLazy v
  case graspTypeOf v' of
    GTPrim -> do
      let name = toPrimName v'
      when (name `Set.member` ioOnlyPrims && mode == ModeTransaction) $
        error $ T.unpack name <> ": not allowed inside atomically (transaction mode)"
      toPrimFn v' args
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
          eval mode childEnv body
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
