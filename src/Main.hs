{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import System.IO (hFlush, stdout, hSetBuffering, stdin, BufferMode(..), isEOF)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Control.Exception (catch, SomeException, displayException)

import Grasp.Types (Env)
import Grasp.Parser
import Grasp.Eval
import Grasp.Printer
import Grasp.HaskellInterop (defaultEnvWithInterop)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> do
      hSetBuffering stdin LineBuffering
      putStrLn "grasp v0.1 — a Lisp on GHC's runtime"
      putStrLn "Type (quit) to exit."
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
  putStr "λ> "
  hFlush stdout
  eof <- isEOF
  if eof
    then putStrLn "\nBye."
    else do
      line <- TIO.getLine
      if T.strip line == "(quit)"
        then putStrLn "Bye."
        else do
          case parseLisp line of
            Left err -> putStrLn $ "parse error: " <> show err
            Right expr -> do
              result <- (Right <$> eval env expr)
                `catch` \(e :: SomeException) -> pure (Left (displayException e))
              case result of
                Right val -> putStrLn (printVal val)
                Left err  -> putStrLn $ "error: " <> err
          repl env
