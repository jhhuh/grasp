module RtsBridgeSpec (spec) where

import Test.Hspec
import Data.Either (isLeft)
import Foreign.StablePtr
import Grasp.RtsBridge

spec :: Spec
spec = describe "RtsBridge" $ do
  describe "rts_mkInt roundtrip" $ do
    it "creates a Haskell Int on the heap and reads it back" $ do
      val <- bridgeRoundtripInt 42
      val `shouldBe` 42

    it "handles negative ints" $ do
      val <- bridgeRoundtripInt (-7)
      val `shouldBe` (-7)

  describe "rts_apply + rts_eval (unsafe)" $ do
    it "applies a Haskell function via the RTS" $ do
      sp <- newStablePtr (succ :: Int -> Int)
      result <- bridgeApplyIntInt sp 41
      freeStablePtr sp
      result `shouldBe` 42

    it "applies negate via the RTS" $ do
      sp <- newStablePtr (negate :: Int -> Int)
      result <- bridgeApplyIntInt sp 10
      freeStablePtr sp
      result `shouldBe` (-10)

  describe "safe apply (bridgeSafeApplyIntInt)" $ do
    it "applies succ safely" $ do
      sp <- newStablePtr (succ :: Int -> Int)
      result <- bridgeSafeApplyIntInt sp 41
      freeStablePtr sp
      result `shouldBe` Right 42

    it "applies negate safely" $ do
      sp <- newStablePtr (negate :: Int -> Int)
      result <- bridgeSafeApplyIntInt sp 10
      freeStablePtr sp
      result `shouldBe` Right (-10)

    it "returns Left on exception (does not abort)" $ do
      sp <- newStablePtr ((\_ -> error "boom") :: Int -> Int)
      result <- bridgeSafeApplyIntInt sp 0
      freeStablePtr sp
      result `shouldSatisfy` isLeft
