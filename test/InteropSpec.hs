module InteropSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Control.Exception (evaluate, try, SomeException)
import Data.List (isInfixOf)
import Grasp.Types
import Grasp.Eval
import Grasp.Parser
import Grasp.Printer
import Grasp.HaskellInterop

-- Helper: parse + eval with interop, return printed result
run :: String -> IO String
run input = do
  env <- defaultEnvWithInterop
  case parseLisp (T.pack input) of
    Left err -> error (show err)
    Right expr -> do
      val <- eval env expr
      pure (printVal val)

-- Helper: parse + eval, expect error
runError :: String -> IO (Either SomeException String)
runError input = try (run input >>= evaluate)

isLeftContaining :: String -> Either SomeException a -> Bool
isLeftContaining needle (Left e) = needle `isInfixOf` show e
isLeftContaining _ (Right _) = False

spec :: Spec
spec = describe "Haskell Interop" $ do
  describe "haskell-call (backward compat)" $ do
    it "calls succ on an Int" $
      run "(haskell-call \"succ\" 41)" `shouldReturn` "42"

    it "calls negate on an Int" $
      run "(haskell-call \"negate\" 10)" `shouldReturn` "-10"

    it "calls reverse on a list of Ints" $
      run "(haskell-call \"reverse\" (list 1 2 3))" `shouldReturn` "(3 2 1)"

    it "calls length on a list" $
      run "(haskell-call \"length\" (list 10 20 30))" `shouldReturn` "3"

  describe "hs: syntax" $ do
    it "calls hs:succ" $
      run "(hs:succ 41)" `shouldReturn` "42"

    it "calls hs:negate" $
      run "(hs:negate 5)" `shouldReturn` "-5"

    it "calls hs:reverse on a list" $
      run "(hs:reverse (list 1 2 3))" `shouldReturn` "(3 2 1)"

    it "calls hs:length on a list" $
      run "(hs:length (list 10 20 30))" `shouldReturn` "3"

  describe "type validation" $ do
    it "rejects type mismatch (string to Int function)" $ do
      result <- runError "(haskell-call \"succ\" \"hello\")"
      result `shouldSatisfy` isLeftContaining "expected Int"

    it "rejects unknown function" $ do
      result <- runError "(haskell-call \"nonexistent\" 42)"
      result `shouldSatisfy` isLeftContaining "unknown Haskell function"

    it "rejects hs: type mismatch" $ do
      result <- runError "(hs:succ \"hello\")"
      result `shouldSatisfy` isLeftContaining "expected Int"

    it "rejects hs: unknown function" $ do
      result <- runError "(hs:nonexistent_xyz 42)"
      result `shouldSatisfy` isLeftContaining "nonexistent_xyz"

  describe "hs: dynamic lookup fallback" $ do
    it "calls abs (Prelude, not in registry)" $
      run "(hs:abs -5)" `shouldReturn` "5"

    it "calls not (Bool -> Bool)" $
      run "(hs:not #f)" `shouldReturn` "#t"

    it "calls Data.List.sort with list marshaling" $
      run "(hs:Data.List.sort (list 3 1 2))" `shouldReturn` "(1 2 3)"

    it "calls Data.List.nub with list marshaling" $
      run "(hs:Data.List.nub (list 1 2 1 3 2))" `shouldReturn` "(1 2 3)"

  describe "hs@ annotated form" $ do
    it "calls sort with explicit type" $
      run "(hs@ \"Data.List.sort :: [Int] -> [Int]\" (list 3 1 2))" `shouldReturn` "(1 2 3)"

    it "calls reverse with explicit type" $
      run "(hs@ \"reverse :: [Int] -> [Int]\" (list 1 2 3))" `shouldReturn` "(3 2 1)"

    it "calls (+) with explicit type and two args" $
      run "(hs@ \"(+) :: Int -> Int -> Int\" 10 32)" `shouldReturn` "42"
