{-# LANGUAGE OverloadedStrings #-}
module Grasp.DynLookup
  ( GraspArgType(..)
  , GraspFuncInfo(..)
  , GhcState
  , initGhcState
  , lookupFunc
  , dynCall
  , dynCallInferred
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import GHC.Exts (Any)
import Unsafe.Coerce (unsafeCoerce)
import Control.Monad.IO.Class (liftIO)

-- GHC API
import GHC
  ( runGhc, getSessionDynFlags, setSessionDynFlags, setContext
  , getContext, compileExpr, exprType
  )
import GHC.Driver.Monad (Session(..), Ghc, reflectGhc, reifyGhc)
import GHC.Driver.Backend (interpreterBackend)
import GHC.Driver.DynFlags (DynFlags(..), GhcLink(..), GhcMode(..))
import GHC.Hs.ImpExp (simpleImportDecl)
import GHC.Unit.Module (mkModuleName)
import GHC.Runtime.Context (InteractiveImport(..))
import GHC.Tc.Module (TcRnExprMode(..))
import GHC.Tc.Utils.TcType (tcSplitFunTys)
import GHC.Core.TyCo.Rep (scaledThing)
import GHC.Core.Type (expandTypeSynonyms, tcSplitTyConApp_maybe)
import GHC.Builtin.Types (intTyCon, doubleTyCon, boolTyCon, listTyCon, charTyCon)
import GHC.Core.TyCon (tyConName)
import GHC.Types.Name (getOccString)
import GHC.Paths (libdir)
import qualified GHC.Core.TyCo.Rep as Rep

-- ─── Types ──────────────────────────────────────────────

data GraspArgType
  = NativeInt
  | NativeDouble
  | NativeBool
  | ListOf GraspArgType
  | HaskellString
  | HaskellText
  deriving (Eq, Show)

data GraspFuncInfo = GraspFuncInfo
  { funcArity  :: Int
  , funcArgs   :: [GraspArgType]
  , funcReturn :: GraspArgType
  } deriving (Eq, Show)

-- | Opaque handle to a running GHC API session.
newtype GhcState = GhcState Session

-- ─── Session management ────────────────────────────────

-- | Start a GHC API session with interpreter backend, importing Prelude + Data.List.
initGhcState :: IO GhcState
initGhcState = runGhc (Just libdir) $ do
  dflags <- getSessionDynFlags
  setSessionDynFlags dflags
    { backend = interpreterBackend
    , ghcLink = LinkInMemory
    , ghcMode = CompManager
    }
  setContext
    [ IIDecl (simpleImportDecl (mkModuleName "Prelude"))
    , IIDecl (simpleImportDecl (mkModuleName "Data.List"))
    ]
  -- Capture the live Session (IORef HscEnv) for later use
  reifyGhc $ \session -> pure (GhcState session)

-- | Run a Ghc action in an existing session, preserving state across calls.
runInGhc :: GhcState -> Ghc a -> IO a
runInGhc (GhcState session) action = reflectGhc action session

-- ─── Type classification ────────────────────────────────

-- | Classify a GHC Type into our GraspArgType system.
classifyType :: Rep.Type -> Either String GraspArgType
classifyType ty =
  let ty' = expandTypeSynonyms ty
  in case tcSplitTyConApp_maybe ty' of
    Just (tc, args)
      | tc == intTyCon    -> Right NativeInt
      | tc == doubleTyCon -> Right NativeDouble
      | tc == boolTyCon   -> Right NativeBool
      | tc == listTyCon, [elemTy] <- args ->
          case tcSplitTyConApp_maybe elemTy of
            Just (etc, _)
              | etc == charTyCon -> Right HaskellString
            _ -> ListOf <$> classifyType elemTy
      | otherwise -> Left $ "unsupported type: " <> getOccString (tyConName tc)
    Nothing -> Left "cannot classify non-TyCon type"

-- | Decompose a function type into argument types + return type.
decomposeFuncType :: Rep.Type -> Either String GraspFuncInfo
decomposeFuncType ty =
  let (scaledArgs, retTy) = tcSplitFunTys (expandTypeSynonyms ty)
      argTys = map scaledThing scaledArgs
  in case argTys of
    [] -> Left "not a function type"
    _  -> do
      args <- mapM classifyType argTys
      ret  <- classifyType retTy
      Right GraspFuncInfo
        { funcArity  = length args
        , funcArgs   = args
        , funcReturn = ret
        }

-- ─── Lookup and call ────────────────────────────────────

-- | Lookup a function by name and get its type info.
lookupFunc :: GhcState -> Text -> IO (Either String GraspFuncInfo)
lookupFunc gs name = runInGhc gs $ do
  ty <- exprType TM_Inst (T.unpack name)
  pure (decomposeFuncType ty)

-- | Compile a typed expression and apply it to arguments.
dynCall :: GhcState -> Text -> [Any] -> IO Any
dynCall gs expr args = runInGhc gs $ do
  hv <- compileExpr (T.unpack expr)
  liftIO $ applyN (unsafeCoerce hv) args

-- | Infer type from name, compile, and apply.
dynCallInferred :: GhcState -> Text -> [Any] -> IO Any
dynCallInferred gs name args = do
  ensureModuleImported gs name
  runInGhc gs $ do
    hv <- compileExpr (T.unpack name)
    liftIO $ applyN (unsafeCoerce hv) args

-- | Apply a curried function to a list of arguments one at a time.
applyN :: Any -> [Any] -> IO Any
applyN f []     = pure f
applyN f (x:xs) = do
  let f' = (unsafeCoerce f :: Any -> Any) x
  applyN f' xs

-- ─── Module importing ───────────────────────────────────

-- | If the name is qualified (e.g. "Data.List.sort"), import the module.
ensureModuleImported :: GhcState -> Text -> IO ()
ensureModuleImported gs name = case extractModule name of
  Nothing -> pure ()
  Just modName -> runInGhc gs $ do
    ctx <- getContext
    let newImport = IIDecl (simpleImportDecl (mkModuleName (T.unpack modName)))
    setContext (newImport : ctx)
  where
    -- Extract module name from possibly annotated expressions like
    -- "(Data.List.sort :: [Int] -> [Int])" or "Data.List.sort"
    extractModule :: Text -> Maybe Text
    extractModule n =
      let -- Strip leading parens and whitespace, take identifier before ::
          stripped = T.strip $ T.dropWhile (\c -> c == '(') n
          ident = T.strip $ fst $ T.breakOn "::" stripped
          parts = T.splitOn "." ident
      in if length parts >= 2
         then Just (T.intercalate "." (init parts))
         else Nothing
