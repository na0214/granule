{-# LANGUAGE FlexibleInstances #-}

module Expr where

import Data.List
import Control.Monad.State.Strict

type Id = String
data Op = Add | Sub | Mul deriving (Eq, Show)

data Expr = Abs Id Expr
          | App Expr Expr
          | Var Id
          | Num Int
          | Binop Op Expr Expr
          | Promote Expr
          | LetBox Id Type Expr Expr
          deriving (Eq, Show)

fvs :: Expr -> [Id]
fvs (Abs x e) = (fvs e) \\ [x]
fvs (App e1 e2) = fvs e1 ++ fvs e2
fvs (Var x)   = [x]
fvs (Binop _ e1 e2) = fvs e1 ++ fvs e2
fvs (Promote e) = fvs e
fvs (LetBox x _ e1 e2) = fvs e1 ++ ((fvs e2) \\ [x])
fvs _ = []

-- Syntactic substitution (assuming variables are all unique)
subst :: Expr -> Id -> Expr -> Expr
subst es v (Abs w e)          = Abs w (subst es v e)
subst es v (App e1 e2)        = App (subst es v e1) (subst es v e2)
subst es v (Binop op e1 e2)   = Binop op (subst es v e1) (subst es v e2)
subst es v (Promote e)        = Promote (subst es v e)
subst es v (LetBox w t e1 e2) = LetBox w t (subst es v e1) (subst es v e2)
subst es v (Var w) | v == w = es
subst es v e = e

data Def = Def Id Expr Type
          deriving (Eq, Show)

-- Types

data TyCon = TyInt | TyBool | TyVar String -- TyVar not used yet
    deriving (Eq, Show)

data Type = FunTy Type Type | ConT TyCon | Box Coeffect Type
    deriving (Eq, Show)

data Coeffect = Nat Int
              | CVar String
              | CPlus Coeffect Coeffect
              | CTimes Coeffect Coeffect
    deriving (Eq, Show)

{- Pretty printers -}

class Pretty t where
    pretty :: t -> String

instance Pretty Coeffect where
    pretty (Nat n) = show n
    pretty (CVar c) = c
    pretty (CPlus c d) = pretty c ++ " + " ++ pretty d
    pretty (CTimes c d) = pretty c ++ " * " ++ pretty d

instance Pretty Type where
    pretty (ConT TyInt)  = "Int"
    pretty (ConT TyBool) = "Bool"
    pretty (FunTy t1 t2) = "(" ++ pretty t1 ++ ") -> " ++ pretty t2
    pretty (Box c t) = "[" ++ pretty t ++ "] " ++ pretty c

instance Pretty [Def] where
    pretty = intercalate "\n"
     . map (\(Def v e t) -> v ++ " : " ++ pretty t ++ "\n" ++ v ++ " = " ++ pretty e)

instance Pretty t => Pretty (Maybe t) where
    pretty Nothing = "unknown"
    pretty (Just x) = pretty x

{-
instance Pretty t => Pretty [t] where
    pretty ts = "[" ++ (intercalate "," $ map pretty ts) ++ "]"
-}

instance Pretty Expr where
    pretty expr =
      case expr of
        (Abs x e) -> parens $ "\\" ++ x ++ " -> " ++ pretty e
        (App e1 e2) -> parens $ pretty e1 ++ " " ++ pretty e2
        (Binop op e1 e2) -> parens $ pretty e1 ++ prettyOp op ++ pretty e2
        (LetBox v t e1 e2) -> parens $ "let [" ++ v ++ ":" ++ pretty t ++ "] = "
                                     ++ pretty e1 ++ " in " ++ pretty e2
        (Promote e)      -> "[ " ++ pretty e ++ " ]"
        (Var x) -> x
        (Num n) -> show n
     where prettyOp Add = " + "
           prettyOp Sub = " - "
           prettyOp Mul = " * "
           parens s = "(" ++ s ++ ")"

{- Smart constructors -}

addExpr :: Expr -> Expr -> Expr
addExpr = Binop Add

subExpr :: Expr -> Expr -> Expr
subExpr = Binop Sub

mulExpr :: Expr -> Expr -> Expr
mulExpr = Binop Mul

uniqueNames :: [Def] -> [Def]
uniqueNames = flip evalState (0 :: Int) . mapM uniqueNameDef
  where
    uniqueNameDef (Def id e t) = do
      e' <- uniqueNameExpr e
      return $ (Def id e' t)

    uniqueNameExpr (Abs id e) = do
      v <- get
      let id' = id ++ show v
      put (v+1)
      e' <- uniqueNameExpr (subst (Var id') id e)
      return $ Abs id' e'

    uniqueNameExpr (LetBox id t e1 e2) = do
      v <- get
      let id' = id ++ show v
      put (v+1)
      e1' <- uniqueNameExpr e1
      e2' <- uniqueNameExpr (subst (Var id') id e2)
      return $ LetBox id' t e1' e2'

    uniqueNameExpr (App e1 e2) = do
      e1' <- uniqueNameExpr e1
      e2' <- uniqueNameExpr e2
      return $ App e1' e2'

    uniqueNameExpr (Binop op e1 e2) = do
      e1' <- uniqueNameExpr e1
      e2' <- uniqueNameExpr e2
      return $ Binop op e1' e2'

    uniqueNameExpr (Promote e) = do
      e' <- uniqueNameExpr e
      return $ Promote e'

    uniqueNameExpr c = return c