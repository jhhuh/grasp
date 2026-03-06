{-# LANGUAGE OverloadedStrings #-}
module NativeTypesSpec (spec) where

import Test.Hspec
import Grasp.NativeTypes

spec :: Spec
spec = describe "NativeTypes" $ do
  describe "type discrimination" $ do
    it "identifies Int" $
      graspTypeOf (mkInt 42) `shouldBe` GTInt

    it "identifies Double" $
      graspTypeOf (mkDouble 3.14) `shouldBe` GTDouble

    it "identifies True" $
      graspTypeOf (mkBool True) `shouldBe` GTBoolTrue

    it "identifies False" $
      graspTypeOf (mkBool False) `shouldBe` GTBoolFalse

    it "identifies Sym" $
      graspTypeOf (mkSym "foo") `shouldBe` GTSym

    it "identifies Str" $
      graspTypeOf (mkStr "hello") `shouldBe` GTStr

    it "identifies Cons" $
      graspTypeOf (mkCons (mkInt 1) mkNil) `shouldBe` GTCons

    it "identifies Nil" $
      graspTypeOf mkNil `shouldBe` GTNil

    it "discriminates GraspLazy" $ do
      let inner = mkInt 42
      let lazy = mkLazy inner
      graspTypeOf lazy `shouldBe` GTLazy

    it "forceLazy returns inner value" $ do
      let inner = mkInt 42
      let lazy = mkLazy inner
      result <- forceLazy lazy
      graspTypeOf result `shouldBe` GTInt
      toInt result `shouldBe` 42

    it "forceIfLazy passes non-lazy through" $ do
      let v = mkInt 99
      result <- forceIfLazy v
      toInt result `shouldBe` 99

    it "forceIfLazy forces lazy values" $ do
      let lazy = mkLazy (mkInt 77)
      result <- forceIfLazy lazy
      toInt result `shouldBe` 77

  describe "constructors and extractors" $ do
    it "round-trips Int" $
      toInt (mkInt 42) `shouldBe` 42

    it "round-trips negative Int" $
      toInt (mkInt (-7)) `shouldBe` (-7)

    it "round-trips Double" $
      toDouble (mkDouble 3.14) `shouldBe` 3.14

    it "round-trips Bool True" $
      toBool (mkBool True) `shouldBe` True

    it "round-trips Bool False" $
      toBool (mkBool False) `shouldBe` False

    it "round-trips Sym" $
      toSym (mkSym "foo") `shouldBe` "foo"

    it "round-trips Str" $
      toStr (mkStr "hello") `shouldBe` "hello"

    it "round-trips Cons car" $
      toInt (toCar (mkCons (mkInt 1) (mkInt 2))) `shouldBe` 1

    it "round-trips Cons cdr" $
      toInt (toCdr (mkCons (mkInt 1) (mkInt 2))) `shouldBe` 2

    it "identifies nil" $
      isNil mkNil `shouldBe` True

    it "identifies non-nil" $
      isNil (mkInt 42) `shouldBe` False

  describe "graspEq" $ do
    it "equal ints" $
      graspEq (mkInt 42) (mkInt 42) `shouldReturn` True

    it "unequal ints" $
      graspEq (mkInt 1) (mkInt 2) `shouldReturn` False

    it "equal bools" $
      graspEq (mkBool True) (mkBool True) `shouldReturn` True

    it "equal nil" $
      graspEq mkNil mkNil `shouldReturn` True

    it "equal cons" $
      graspEq (mkCons (mkInt 1) mkNil) (mkCons (mkInt 1) mkNil) `shouldReturn` True

    it "different types" $
      graspEq (mkInt 1) (mkBool True) `shouldReturn` False

    it "equal strings" $
      graspEq (mkStr "a") (mkStr "a") `shouldReturn` True

    it "equal symbols" $
      graspEq (mkSym "x") (mkSym "x") `shouldReturn` True
