{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import System.IO (hFlush, stdout, hSetBuffering, stdin, BufferMode(..))
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Control.Exception (catch, SomeException, displayException)

import GhcLisp.Types
import GhcLisp.Parser
import GhcLisp.Eval
import GhcLisp.Printer
import GhcLisp.HaskellInterop (defaultEnvWithInterop)

main :: IO ()
main = do
  hSetBuffering stdin LineBuffering
  putStrLn "ghc-lisp v0.1 — a Lisp on GHC's runtime"
  putStrLn "Type (quit) to exit."
  env <- defaultEnvWithInterop
  repl env

repl :: Env -> IO ()
repl env = do
  putStr "λ> "
  hFlush stdout
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
