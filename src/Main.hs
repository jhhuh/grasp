{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.Text as T
import System.Console.Isocline
import Control.Exception (SomeException, catch)

import Grasp.Parser (parseLisp)
import Grasp.Eval (eval, defaultEnv, EvalMode(..))
import Grasp.Printer (printVal)
import Grasp.Types (Env)

main :: IO ()
main = do
  setHistory "grasp_history" 200
  env <- defaultEnv
  putStrLn "grasp v2"
  repl env

repl :: Env -> IO ()
repl env = do
  mline <- readlineExMaybe "grasp> " Nothing Nothing
  case mline of
    Nothing -> putStrLn "bye."
    Just line
      | all (== ' ') line || null line -> repl env
      | otherwise -> do
          case parseLisp (T.pack line) of
            Left err -> putStrLn $ "parse error: " <> show err
            Right expr -> (do
              result <- eval ModeComputation env expr
              putStrLn (printVal result))
              `catch` \(e :: SomeException) ->
                putStrLn $ "error: " <> show e
          repl env
