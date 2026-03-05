module RtsBridgeSpec (spec) where

import Test.Hspec
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

  describe "rts_apply + rts_eval" $ do
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
