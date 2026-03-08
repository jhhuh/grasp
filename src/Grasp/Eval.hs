{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Grasp.Eval
  ( eval
  , defaultEnv
  , anyToExpr
  , apply
  ) where

import Data.IORef
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import GHC.Exts (Any)
import System.IO.Unsafe (unsafeInterleaveIO)
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (newChan, writeChan, readChan)
import Control.Exception (SomeException, catch, displayException)
import Control.Monad (void)

import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist)

import Grasp.Types
import Grasp.NativeTypes
import Grasp.HsRegistry (dispatchRegistered)
import Grasp.DynDispatch (dynDispatch, dynDispatchAnnotated)
import Grasp.Parser (parseFile)
import Grasp.Continuations (newPromptTag, prompt, control0, pushHandler, popHandler, peekHandler)

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
        , ("spawn", mkPrim "spawn" spawnOp)
        , ("make-chan", mkPrim "make-chan" makeChanOp)
        , ("chan-put", mkPrim "chan-put" chanPutOp)
        , ("chan-get", mkPrim "chan-get" chanGetOp)
        , ("apply", mkPrim "apply" applyOp)
        ]
    , envHsRegistry = Map.empty
    , envGhcSession = ghcRef
    , envModules = Map.empty
    , envLoading = []
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

spawnOp :: [Any] -> IO Any
spawnOp [f] = do
  _ <- forkIO $ void (apply f []) `catch` \(_ :: SomeException) -> pure ()
  pure mkNil
spawnOp _ = error "spawn expects one argument (a zero-arg function)"

makeChanOp :: [Any] -> IO Any
makeChanOp [] = mkChan <$> newChan
makeChanOp _ = error "make-chan expects no arguments"

chanPutOp :: [Any] -> IO Any
chanPutOp [ch, val] = do
  ch' <- forceIfLazy ch
  writeChan (toChan ch') val
  pure mkNil
chanPutOp _ = error "chan-put expects two arguments (channel, value)"

chanGetOp :: [Any] -> IO Any
chanGetOp [ch] = do
  ch' <- forceIfLazy ch
  readChan (toChan ch')
chanGetOp _ = error "chan-get expects one argument (channel)"

graspListToList :: Any -> IO [Any]
graspListToList v = do
  v' <- forceIfLazy v
  if isNil v' then pure []
  else if isCons v' then do
    rest <- graspListToList (toCdr v')
    pure (toCar v' : rest)
  else error "apply: second argument must be a list"

applyOp :: [Any] -> IO Any
applyOp [f, argList] = do
  args <- graspListToList argList
  apply f args
applyOp _ = error "apply expects two arguments (function, arg-list)"

-- | Try to match a runtime value against a pattern expression.
-- Returns Just bindings on match, Nothing on no match.
matchPattern :: Any -> LispExpr -> IO (Maybe (Map.Map T.Text Any))
matchPattern _val (ESym "_") = pure (Just Map.empty)  -- wildcard
matchPattern val (ESym name) = pure (Just (Map.singleton name val))  -- variable bind
matchPattern val (EInt n) = do
  v <- forceIfLazy val
  if graspTypeOf v == GTInt && toInt v == fromInteger n
    then pure (Just Map.empty)
    else pure Nothing
matchPattern val (EStr s) = do
  v <- forceIfLazy val
  if graspTypeOf v == GTStr && toStr v == s
    then pure (Just Map.empty)
    else pure Nothing
matchPattern val (EBool b) = do
  v <- forceIfLazy val
  let expected = if b then GTBoolTrue else GTBoolFalse
  if graspTypeOf v == expected
    then pure (Just Map.empty)
    else pure Nothing
matchPattern val (EList []) = do  -- nil pattern
  v <- forceIfLazy val
  if isNil v then pure (Just Map.empty) else pure Nothing
matchPattern val (EList [ESym "cons", hPat, tPat]) = do  -- cons destructuring
  v <- forceIfLazy val
  if isCons v then do
    mh <- matchPattern (toCar v) hPat
    case mh of
      Nothing -> pure Nothing
      Just hBinds -> do
        mt <- matchPattern (toCdr v) tPat
        case mt of
          Nothing -> pure Nothing
          Just tBinds -> pure (Just (Map.union hBinds tBinds))
  else pure Nothing
matchPattern _ _ = pure Nothing

eval :: Env -> LispExpr -> IO GraspVal
eval _ (EInt n)    = pure $ mkInt (fromInteger n)
eval _ (EDouble d) = pure $ mkDouble d
eval _ (EStr s)    = pure $ mkStr s
eval _ (EBool b)   = pure $ mkBool b
eval env (ESym s)  = do
  ed <- readIORef env
  case Map.lookup s (envBindings ed) of
    Just v  -> pure v
    Nothing
      | Just (prefix, suffix) <- splitQualified s -> do
          case Map.lookup prefix (envModules ed) of
            Just modVal -> do
              let exports = toModuleExports modVal
              case Map.lookup suffix exports of
                Just v  -> pure v
                Nothing -> error $ "unbound symbol: " <> T.unpack s
            Nothing -> error $ "unbound symbol: " <> T.unpack s
      | otherwise -> error $ "unbound symbol: " <> T.unpack s
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
    []     -> error "lambda must have at least one body expression"
    [expr] -> pure $ mkLambda paramNames expr env
    _      -> pure $ mkLambda paramNames (EList (ESym "begin" : body)) env
-- defmacro: define a macro
eval env (EList [ESym "defmacro", ESym name, EList params, body]) = do
  let paramNames = map (\case ESym s -> s; _ -> error "macro params must be symbols") params
  let macro = mkMacro paramNames body env
  modifyIORef' env $ \ed -> ed { envBindings = Map.insert name macro (envBindings ed) }
  pure macro
-- module: define a module with exports
eval env (EList (ESym "module" : ESym name : EList (ESym "export" : exports) : body)) = do
  let exportNames = map (\case ESym s -> s; _ -> error "export list must contain symbols") exports
  -- Create child env inheriting parent's bindings (primitives, etc.)
  parentEd <- readIORef env
  childEnv <- newIORef parentEd
  -- Evaluate body forms sequentially in child env
  mapM_ (eval childEnv) body
  -- Collect exports (validate all exports exist eagerly)
  childEd <- readIORef childEnv
  exportPairs <- mapM (\s -> case Map.lookup s (envBindings childEd) of
        Just val -> pure (s, val)
        Nothing  -> error $ "module " <> T.unpack name
                         <> ": exported symbol '" <> T.unpack s
                         <> "' is not defined"
    ) exportNames
  let exportMap = Map.fromList exportPairs
  let modVal = mkModule name exportMap
  -- Store module in parent's envModules
  modifyIORef' env $ \ed -> ed { envModules = Map.insert name modVal (envModules ed) }
  pure modVal
-- import: load a module from file
eval env (EList [ESym "import", moduleRef]) = do
  -- Resolve file path
  (filePath, _expectedName) <- case moduleRef of
    EStr path -> pure (T.unpack path, Nothing :: Maybe T.Text)
    ESym name -> pure (T.unpack name <> ".gsp", Just name)
    _ -> error "import expects a symbol or string"
  -- Check file exists
  exists <- doesFileExist filePath
  if not exists
    then error $ "import: file not found: " <> filePath
    else do
      -- Read and parse file
      content <- TIO.readFile filePath
      case parseFile content of
        Left err -> error $ "import: parse error in " <> filePath <> ": " <> show err
        Right exprs -> do
          case exprs of
            [] -> error $ "import: no module definition in " <> filePath
            (modExpr:rest) -> do
              -- Extract module name from the module form
              let modName = case modExpr of
                    EList (ESym "module" : ESym n : _) -> n
                    _ -> error $ "import: no module definition in " <> filePath
              -- Check for circular dependency
              ed <- readIORef env
              if modName `elem` envLoading ed
                then error $ "import: circular dependency: "
                          <> T.unpack (T.intercalate " -> " (envLoading ed <> [modName]))
                else do
                  -- Check cache
                  case Map.lookup modName (envModules ed) of
                    Just cached -> do
                      bindModuleExports env modName cached
                      pure cached
                    Nothing -> do
                      -- Push loading stack
                      modifyIORef' env $ \ed' -> ed' { envLoading = envLoading ed' <> [modName] }
                      -- Create child env inheriting primitives
                      parentEd <- readIORef env
                      childEnv <- newIORef parentEd
                      -- Eval all expressions (module + any top-level forms)
                      results <- mapM (eval childEnv) (modExpr : rest)
                      -- Find the module result
                      let modVal = case filter (\v -> graspTypeOf v == GTModule) results of
                            (m:_) -> m
                            []    -> error $ "import: no module definition in " <> filePath
                      -- Pop loading stack and cache
                      modifyIORef' env $ \ed' -> ed'
                        { envLoading = filter (/= modName) (envLoading ed')
                        , envModules = Map.insert modName modVal (envModules ed')
                        }
                      -- Bind exports
                      bindModuleExports env modName modVal
                      pure modVal
-- lazy: defer evaluation into a real GHC THUNK
eval env (EList [ESym "lazy", body]) = do
  thunk <- unsafeInterleaveIO (eval env body)
  pure (mkLazy thunk)
-- force: enter a lazy thunk, triggering GHC's update mechanism
eval env (EList [ESym "force", expr]) = do
  v <- eval env expr
  forceIfLazy v
-- begin: evaluate forms sequentially, return last
eval env (EList (ESym "begin" : exprs)) = case exprs of
  [] -> pure mkNil
  _  -> last <$> mapM (eval env) exprs
-- let: sequential bindings with body
eval env (EList (ESym "let" : EList bindings : body)) = do
  parentEd <- readIORef env
  childEnv <- newIORef parentEd
  mapM_ (\case
    EList [ESym name, valExpr] -> do
      val <- eval childEnv valExpr
      modifyIORef' childEnv $ \ed -> ed { envBindings = Map.insert name val (envBindings ed) }
    _ -> error "let binding must be (name value)") bindings
  case body of
    [] -> pure mkNil
    _  -> last <$> mapM (eval childEnv) body
-- recur: return sentinel value for loop restart
eval env (EList (ESym "recur" : args)) = do
  vals <- mapM (eval env) args
  pure $ mkRecur vals
-- loop: iterative construct with recur
eval env (EList (ESym "loop" : EList bindings : body)) = do
  parentEd <- readIORef env
  childEnv <- newIORef parentEd
  varNames <- mapM (\case
    EList [ESym name, initExpr] -> do
      val <- eval childEnv initExpr
      modifyIORef' childEnv $ \ed -> ed { envBindings = Map.insert name val (envBindings ed) }
      pure name
    _ -> error "loop binding must be (name init)") bindings
  let go = do
        result <- case body of
          [] -> pure mkNil
          _  -> last <$> mapM (eval childEnv) body
        if graspTypeOf result == GTRecur
          then do
            let newVals = toRecurArgs result
            if length newVals /= length varNames
              then error $ "recur: expected " <> show (length varNames) <> " args, got " <> show (length newVals)
              else do
                mapM_ (\(name, val) -> modifyIORef' childEnv $ \ed ->
                  ed { envBindings = Map.insert name val (envBindings ed) }) (zip varNames newVals)
                go
          else pure result
  go
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
-- with-handler: establish a condition handler with delimited continuation
eval env (EList [ESym "with-handler", handlerExpr, body]) = do
  handler <- eval env handlerExpr
  tag <- newPromptTag
  pushHandler tag handler
  result <- (do
    r <- prompt tag (eval env body)
    popHandler
    pure r)
    `catch` \(e :: SomeException) -> do
      popHandler
      let errStr = mkStr (T.pack (displayException e))
      let noRestart = mkPrim "<no-restart>" (\_ -> error "cannot restart from a Haskell exception")
      apply handler [errStr, noRestart]
  pure result
-- signal: raise a condition to the nearest handler
eval env (EList [ESym "signal", valExpr]) = do
  val <- eval env valExpr
  mh <- peekHandler
  case mh of
    Nothing -> error "signal: no handler installed"
    Just (tag, handler) -> do
      control0 tag $ \k -> do
        popHandler
        let restart = mkPrim "<restart>" (\case
              [v] -> do
                pushHandler tag handler
                r <- k v
                popHandler
                pure r
              _ -> error "restart expects one argument")
        apply handler [val, restart]
-- match: structural pattern matching
eval env (EList (ESym "match" : scrutinee : clauses)) = do
  val <- eval env scrutinee
  let tryMatch [] = error "match: no matching clause"
      tryMatch (EList [pat, body] : rest) = do
        result <- matchPattern val pat
        case result of
          Nothing -> tryMatch rest
          Just bindings -> do
            parentEd <- readIORef env
            childEnv <- newIORef $ parentEd { envBindings = Map.union bindings (envBindings parentEd) }
            eval childEnv body
      tryMatch _ = error "match: each clause must be (pattern body)"
  tryMatch clauses
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

-- | Bind a module's exports into the environment (qualified + unqualified).
bindModuleExports :: Env -> T.Text -> Any -> IO ()
bindModuleExports env modName modVal = do
  let exports = toModuleExports modVal
      qualifiedBindings = Map.mapKeys (\k -> modName <> "." <> k) exports
  modifyIORef' env $ \ed -> ed
    { envBindings = Map.union qualifiedBindings (Map.union exports (envBindings ed)) }

-- | Split a qualified symbol on the first dot: "foo.bar" -> Just ("foo", "bar")
splitQualified :: T.Text -> Maybe (T.Text, T.Text)
splitQualified s = case T.break (== '.') s of
  (prefix, rest)
    | T.null rest -> Nothing           -- no dot
    | T.null prefix -> Nothing         -- starts with dot
    | otherwise -> Just (prefix, T.tail rest)  -- drop the dot

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
