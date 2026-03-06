{-# LANGUAGE OverloadedStrings #-}
module DynLookupSpec (spec) where

import Test.Hspec
import Data.IORef
import Unsafe.Coerce (unsafeCoerce)
import Data.List (isInfixOf)

import Grasp.DynLookup

spec :: Spec
spec = describe "DynLookup" $ do
  -- Share a single GHC session across all tests for speed.
  -- `before` would re-init per test; `beforeAll` runs once.
  gsRef <- runIO $ initGhcState >>= newIORef

  describe "initGhcState" $ do
    it "creates a GHC session" $ do
      gs <- readIORef gsRef
      -- Verify we can look up a Prelude function (with type annotation to avoid ambiguity)
      result <- lookupFunc gs "(succ :: Int -> Int)"
      result `shouldSatisfy` isRight'

  describe "lookupFunc / type classification" $ do
    it "classifies Int -> Int" $ do
      gs <- readIORef gsRef
      result <- lookupFunc gs "(succ :: Int -> Int)"
      result `shouldBe` Right (GraspFuncInfo 1 [NativeInt] NativeInt)

    it "classifies [Int] -> [Int]" $ do
      gs <- readIORef gsRef
      result <- lookupFunc gs "(reverse :: [Int] -> [Int])"
      result `shouldBe` Right (GraspFuncInfo 1 [ListOf NativeInt] (ListOf NativeInt))

    it "classifies [Int] -> Int" $ do
      gs <- readIORef gsRef
      result <- lookupFunc gs "(sum :: [Int] -> Int)"
      result `shouldBe` Right (GraspFuncInfo 1 [ListOf NativeInt] NativeInt)

    it "classifies Int -> Int -> Int" $ do
      gs <- readIORef gsRef
      result <- lookupFunc gs "((+) :: Int -> Int -> Int)"
      result `shouldBe` Right (GraspFuncInfo 2 [NativeInt, NativeInt] NativeInt)

    it "classifies Bool -> Bool" $ do
      gs <- readIORef gsRef
      result <- lookupFunc gs "not"
      result `shouldBe` Right (GraspFuncInfo 1 [NativeBool] NativeBool)

    it "returns error for unsupported types (Char)" $ do
      gs <- readIORef gsRef
      result <- lookupFunc gs "(id :: Char -> Char)"
      result `shouldSatisfy` isLeftContaining "unsupported type"

  describe "dynCall" $ do
    it "applies succ" $ do
      gs <- readIORef gsRef
      result <- dynCall gs "succ :: Int -> Int" [unsafeCoerce (41 :: Int)]
      (unsafeCoerce result :: Int) `shouldBe` 42

    it "applies negate" $ do
      gs <- readIORef gsRef
      result <- dynCall gs "negate :: Int -> Int" [unsafeCoerce (10 :: Int)]
      (unsafeCoerce result :: Int) `shouldBe` (-10)

    it "applies not" $ do
      gs <- readIORef gsRef
      result <- dynCall gs "not" [unsafeCoerce True]
      (unsafeCoerce result :: Bool) `shouldBe` False

    it "applies (+)" $ do
      gs <- readIORef gsRef
      result <- dynCall gs "(+) :: Int -> Int -> Int"
        [unsafeCoerce (3 :: Int), unsafeCoerce (4 :: Int)]
      (unsafeCoerce result :: Int) `shouldBe` 7

    it "applies reverse on [Int]" $ do
      gs <- readIORef gsRef
      result <- dynCall gs "reverse :: [Int] -> [Int]"
        [unsafeCoerce [1 :: Int, 2, 3]]
      (unsafeCoerce result :: [Int]) `shouldBe` [3, 2, 1]

    it "applies sort on [Int]" $ do
      gs <- readIORef gsRef
      result <- dynCall gs "Data.List.sort :: [Int] -> [Int]"
        [unsafeCoerce [3 :: Int, 1, 2]]
      (unsafeCoerce result :: [Int]) `shouldBe` [1, 2, 3]

  describe "dynCallInferred" $ do
    it "applies not (monomorphic, no annotation needed)" $ do
      gs <- readIORef gsRef
      result <- dynCallInferred gs "not" [unsafeCoerce True]
      (unsafeCoerce result :: Bool) `shouldBe` False

    it "applies a qualified function (Data.List.nub) with annotation" $ do
      gs <- readIORef gsRef
      result <- dynCallInferred gs "(Data.List.nub :: [Int] -> [Int])"
        [unsafeCoerce [1 :: Int, 2, 1, 3, 2]]
      (unsafeCoerce result :: [Int]) `shouldBe` [1, 2, 3]

-- ─── Helpers ────────────────────────────────────────────

isRight' :: Either a b -> Bool
isRight' (Right _) = True
isRight' _         = False

isLeftContaining :: String -> Either String a -> Bool
isLeftContaining needle (Left e) = needle `isInfixOf` e
isLeftContaining _ _             = False
