module Syntax.ExprSpec where

import Test.Hspec hiding (Spec)
import qualified Test.Hspec as Test

import Syntax.Expr

spec :: Test.Spec
spec = do
  describe "Expression helpers" $
    it "free variable test" $
      fvs (Abs "x" (Abs "y" (Var "z"))) `shouldBe` ["z"]