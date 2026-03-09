{-# LANGUAGE OverloadedStrings #-}
module PrinterSpec (spec) where

import Test.Hspec
import Grasp.NativeTypes
import Grasp.Printer

spec :: Spec
spec = describe "Printer" $ do
  it "prints integers" $
    printVal (mkInt 42) `shouldBe` "42"

  it "prints negative integers" $
    printVal (mkInt (-7)) `shouldBe` "-7"

  it "prints doubles" $
    printVal (mkDouble 3.14) `shouldBe` "3.14"

  it "prints true" $
    printVal (mkBool True) `shouldBe` "#t"

  it "prints false" $
    printVal (mkBool False) `shouldBe` "#f"

  it "prints symbols" $
    printVal (mkSym "foo") `shouldBe` "foo"

  it "prints strings" $
    printVal (mkStr "hello") `shouldBe` "\"hello\""

  it "prints nil" $
    printVal mkNil `shouldBe` "()"

  it "prints proper list" $
    printVal (mkCons (mkInt 1) (mkCons (mkInt 2) (mkCons (mkInt 3) mkNil)))
      `shouldBe` "(1 2 3)"

  it "prints dotted pair" $
    printVal (mkCons (mkInt 1) (mkInt 2)) `shouldBe` "(1 . 2)"

  it "prints nested list" $
    printVal (mkCons (mkCons (mkInt 1) (mkCons (mkInt 2) mkNil)) (mkCons (mkInt 3) mkNil))
      `shouldBe` "((1 2) 3)"

  it "prints primitives" $
    printVal (mkPrim "+" (\_ -> pure mkNil)) `shouldBe` "<primitive:+>"

  it "prints modules" $
    printVal (mkModule "math" mempty) `shouldBe` "<module:math>"
