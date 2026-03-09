{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
module RuntimeCheckSpec (spec) where

import Test.Hspec
import Data.Word (Word)
import GHC.Exts (Any)
import Unsafe.Coerce (unsafeCoerce)
import Grasp.RuntimeCheck (RepTag(..), readRepTag)
import Grasp.NativeTypes

-- Closure type constants from RTS (ClosureTypes.h)
pattern CONSTR :: Word
pattern CONSTR = 1

pattern CONSTR_0_1 :: Word
pattern CONSTR_0_1 = 7

pattern CONSTR_NOCAF :: Word
pattern CONSTR_NOCAF = 8

-- Constructor closure types are 1..8 in GHC's RTS
isConstrType :: Word -> Bool
isConstrType ct = ct >= 1 && ct <= 8

spec :: Spec
spec = describe "RuntimeCheck" $ do
  describe "readRepTag" $ do
    it "Int has CONSTR closure type" $ do
      let rt = readRepTag (mkInt 42)
      isConstrType (rtClosureType rt) `shouldBe` True

    it "Double has CONSTR closure type" $ do
      let rt = readRepTag (mkDouble 3.14)
      isConstrType (rtClosureType rt) `shouldBe` True

    it "Bool True has CONSTR closure type" $ do
      let rt = readRepTag (mkBool True)
      isConstrType (rtClosureType rt) `shouldBe` True

    it "Nil has CONSTR closure type" $ do
      let rt = readRepTag mkNil
      isConstrType (rtClosureType rt) `shouldBe` True

    it "Sym has CONSTR closure type" $ do
      let rt = readRepTag (mkSym "x")
      isConstrType (rtClosureType rt) `shouldBe` True

    it "different types have different info pointers" $ do
      let intTag = readRepTag (mkInt 1)
          dblTag = readRepTag (mkDouble 1.0)
          symTag = readRepTag (mkSym "a")
          nilTag = readRepTag mkNil
      rtInfoPtr intTag `shouldNotBe` rtInfoPtr dblTag
      rtInfoPtr intTag `shouldNotBe` rtInfoPtr symTag
      rtInfoPtr intTag `shouldNotBe` rtInfoPtr nilTag
      rtInfoPtr dblTag `shouldNotBe` rtInfoPtr symTag

    it "same type has same info pointer" $ do
      let rt1 = readRepTag (mkInt 42)
          rt2 = readRepTag (mkInt 99)
      rtInfoPtr rt1 `shouldBe` rtInfoPtr rt2

    it "all 17 types produce valid RepTags" $ do
      let vals :: [(String, Any)]
          vals =
            [ ("Int",       mkInt 0)
            , ("Double",    mkDouble 0)
            , ("True",      mkBool True)
            , ("False",     mkBool False)
            , ("Sym",       mkSym "x")
            , ("Str",       mkStr "s")
            , ("Cons",      mkCons (mkInt 1) mkNil)
            , ("Nil",       mkNil)
            , ("Lambda",    mkLambda undefined undefined undefined)
            , ("Prim",      mkPrim "p" undefined)
            , ("Lazy",      mkLazy (unsafeCoerce ()))
            , ("Macro",     mkMacro undefined undefined undefined)
            , ("Chan",      mkChan undefined)
            , ("Module",    mkModule "m" undefined)
            , ("Recur",     mkRecur [])
            , ("PromptTag", mkPromptTag (unsafeCoerce ()))
            , ("TVar",      mkTVar undefined)
            ]
      mapM_ (\(name, v) -> do
        let rt = readRepTag v
        -- Should not crash and should have CONSTR closure type
        isConstrType (rtClosureType rt) `shouldBe` True
        ) vals
