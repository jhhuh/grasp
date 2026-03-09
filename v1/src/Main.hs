{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Control.Exception (catch, SomeException, displayException)
import Data.IORef (readIORef)
import qualified Data.Map.Strict as Map

import qualified System.Console.Isocline as IC

import Grasp.Types (Env, EnvData(..))
import Grasp.Parser
import Grasp.Eval
import Grasp.Printer
import Grasp.HaskellInterop (defaultEnvWithInterop)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> do
      putStrLn "grasp v0.1 — a Lisp on GHC's runtime"
      putStrLn "Type (quit) to exit."
      IC.setHistory ".grasp_history" 200
      env <- defaultEnvWithInterop
      repl env
    [file] -> runFile file
    _ -> do
      putStrLn "Usage: grasp [file.gsp]"
      exitFailure

runFile :: FilePath -> IO ()
runFile file = do
  content <- TIO.readFile file
  case parseFile content of
    Left err -> do
      putStrLn $ "parse error: " <> show err
      exitFailure
    Right exprs -> do
      env <- defaultEnvWithInterop
      results <- mapM (\expr ->
        (Right <$> eval env expr)
          `catch` \(e :: SomeException) -> do
            putStrLn $ "error: " <> displayException e
            pure (Left ())) exprs
      case [v | Right v <- results] of
        [] -> pure ()
        vs -> putStrLn (printVal (last vs))

repl :: Env -> IO ()
repl env = do
  minput <- IC.readlineExMaybe "λ> " (Just (completer env)) Nothing
  case minput of
    Nothing -> putStrLn "\nBye."  -- Ctrl-D / EOF
    Just input
      | T.strip (T.pack input) == "(quit)" -> putStrLn "Bye."
      | null input -> repl env
      | otherwise -> do
          case parseLisp (T.pack input) of
            Left err -> putStrLn $ "parse error: " <> show err
            Right expr -> do
              result <- (Right <$> eval env expr)
                `catch` \(e :: SomeException) -> pure (Left (displayException e))
              case result of
                Right val -> putStrLn (printVal val)
                Left err  -> putStrLn $ "error: " <> err
          repl env

-- | Tab completion: complete env binding names
completer :: Env -> IC.CompletionEnv -> String -> IO ()
completer env cenv input = do
  ed <- readIORef env
  let names = map T.unpack $ Map.keys (envBindings ed)
  IC.completeWord cenv input Nothing (\prefix -> IC.completionsFor prefix names)
