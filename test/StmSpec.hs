{-# LANGUAGE OverloadedStrings #-}
module StmSpec (spec) where

import Test.Hspec
import Grasp.Types
import Grasp.NativeTypes
import Grasp.Eval (eval, defaultEnv, EvalMode(..))
import Grasp.Printer

spec :: Spec
spec = describe "STM" $ do
  describe "TVar basics" $ do
    it "creates and reads a TVar" $ do
      env <- defaultEnv
      val <- eval ModeComputation env
        (EList [ESym "atomically",
          EList [ESym "let",
            EList [ESym "tv", EList [ESym "make-tvar", EInt 42]],
            EList [ESym "read-tvar", ESym "tv"]]])
      printVal val `shouldBe` "42"

    it "writes and reads back" $ do
      env <- defaultEnv
      val <- eval ModeComputation env
        (EList [ESym "let",
          EList [ESym "tv",
            EList [ESym "atomically", EList [ESym "make-tvar", EInt 0]]],
          EList [ESym "begin",
            EList [ESym "write-tvar", ESym "tv", EInt 99],
            EList [ESym "read-tvar", ESym "tv"]]])
      printVal val `shouldBe` "99"

  describe "TVar type" $ do
    it "type-discriminates as tvar" $ do
      env <- defaultEnv
      val <- eval ModeComputation env (EList [ESym "make-tvar", EInt 0])
      showGraspType (graspTypeOf val) `shouldBe` "tvar"

    it "prints as <tvar>" $ do
      env <- defaultEnv
      val <- eval ModeComputation env (EList [ESym "make-tvar", EInt 0])
      printVal val `shouldBe` "<tvar>"
