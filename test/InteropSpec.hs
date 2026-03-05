module InteropSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
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

spec :: Spec
spec = describe "Haskell Interop" $ do
  it "calls succ on an Int" $
    run "(haskell-call \"succ\" 41)" `shouldReturn` "42"

  it "calls negate on an Int" $
    run "(haskell-call \"negate\" 10)" `shouldReturn` "-10"

  it "calls reverse on a list of Ints" $
    run "(haskell-call \"reverse\" (list 1 2 3))" `shouldReturn` "(3 2 1)"

  it "calls length on a list" $
    run "(haskell-call \"length\" (list 10 20 30))" `shouldReturn` "3"
