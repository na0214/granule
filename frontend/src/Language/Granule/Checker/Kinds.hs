-- Mainly provides a kind checker on types
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE ViewPatterns #-}

module Language.Granule.Checker.Kinds (
                      inferKindOfType
                    , inferKindOfType'
                    , joinCoeffectTypes
                    , hasLub
                    , joinKind
                    , inferCoeffectType
                    , inferCoeffectTypeAssumption
                    , mguCoeffectTypes
                    , promoteTypeToKind
                    , demoteKindToType
                    , getKindRequired
                      -- ** 'Safe' inference
                    , inferKindOfTypeSafe
                    , inferKindOfTypeSafe'
                    , mguCoeffectTypesSafe
                    ) where

import Control.Monad.State.Strict
import Control.Monad.Trans.Maybe

import Language.Granule.Checker.Errors
import Language.Granule.Checker.Interface (interfaceExists, getInterfaceKind)
import Language.Granule.Checker.Monad
import Language.Granule.Checker.Predicates

import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Type
import Language.Granule.Context
import Language.Granule.Utils


promoteTypeToKind :: Type -> Kind
promoteTypeToKind (TyVar v) = KVar v
promoteTypeToKind t = KPromote t

demoteKindToType :: Kind -> Maybe Type
demoteKindToType (KPromote t) = Just t
demoteKindToType (KVar v)     = Just (TyVar v)
demoteKindToType _            = Nothing


inferKindOfType :: (?globals :: Globals) => Span -> Type -> MaybeT Checker Kind
inferKindOfType s t = do
    checkerState <- get
    inferKindOfType' s (stripQuantifiers $ tyVarContext checkerState) t


inferKindOfType' :: (?globals :: Globals) => Span -> Ctxt Kind -> Type -> MaybeT Checker Kind
inferKindOfType' s quantifiedVariables t = do
  res <- inferKindOfTypeSafe' s quantifiedVariables t
  case res of
    Left err -> halt err
    Right res -> pure res


type IllKindedReason = CheckerError


inferKindOfTypeSafe :: (?globals :: Globals) => Span -> Type -> MaybeT Checker (Either IllKindedReason Kind)
inferKindOfTypeSafe s t = do
    checkerState <- get
    inferKindOfTypeSafe' s (stripQuantifiers $ tyVarContext checkerState) t


inferKindOfTypeSafe' :: (?globals :: Globals) => Span -> Ctxt Kind -> Type -> MaybeT Checker (Either IllKindedReason Kind)
inferKindOfTypeSafe' s quantifiedVariables t =
    typeFoldM (TypeFold (weither2 kFun)
                        kCon
                        (weither1 . kBox)
                        (weither1 . kDiamond)
                        kVar
                        (weither2 kApp)
                        kInt
                        (weither2 . kInfix)
                        kCoeffect) t
  where
    weither2 c t t2 = do
      let r = ((,) <$> t <*> t2)
      case r of
        Left err -> pure (Left err)
        Right (k1, k2) -> c k1 k2
    weither1 c t = either (pure . Left) c t
    illKindedNEq sp k1 k2 = pure . Left $
      KindError (Just sp) $ concat ["Expected kind ", prettyQuoted k1, " but got ", prettyQuoted k2]
    wellKinded = pure . pure
    kFun (KPromote (TyCon c)) (KPromote (TyCon c'))
     | internalName c == internalName c' = pure $ pure $ kConstr c

    kFun KType KType = wellKinded KType
    kFun KType (KPromote (TyCon (internalName -> "Protocol"))) = wellKinded $ KPromote (TyCon (mkId "Protocol"))
    kFun KType y = illKindedNEq s KType y
    kFun x _     = illKindedNEq s KType x
    kCon conId = fmap Right $ getKindRequired s conId

    kBox c KType = do
       -- Infer the coeffect (fails if that is ill typed)
       _ <- inferCoeffectType s c
       wellKinded KType
    kBox _ x = illKindedNEq s KType x

    kDiamond _ KType = wellKinded KType
    kDiamond _ x     = illKindedNEq s KType x

    kVar tyVar =
      case lookup tyVar quantifiedVariables of
        Just kind -> wellKinded kind
        Nothing   -> do
          st <- get
          case lookup tyVar (tyVarContext st) of
            Just (kind, _) -> wellKinded kind
            Nothing ->
              halt $ UnboundVariableError (Just s) $
                       "Type variable `" <> show tyVar
                    <> "` is unbound (not quantified)."
                    <?> show quantifiedVariables

    kApp (KFun k1 k2) kArg | k1 `hasLub` kArg = wellKinded k2
    kApp k kArg = illKindedNEq s (KFun kArg (KVar $ mkId "....")) k

    kInt _ = wellKinded $ kConstr $ mkId "Nat"

    kInfix op k1 k2 = do
      st <- get
      (ka, kb) <- requireInScope (typeConstructors, "Operator") s (mkId op)
      case (ka, kb) of
       (KFun k1' (KFun k2' kr), _) ->
         if k1 `hasLub` k1'
          then if k2 `hasLub` k2'
               then wellKinded kr
               else illKindedNEq s k2' k2
          else illKindedNEq s k1' k1
       (k, _) -> illKindedNEq s (KFun k1 (KFun k2 (KVar $ mkId "?"))) k
    kCoeffect c = inferCoeffectType s c >>= wellKinded . KPromote


-- | Compute the join of two kinds, if it exists
joinKind :: Kind -> Kind -> Maybe Kind
joinKind k1 k2 | k1 == k2 = Just k1
joinKind (KPromote t1) (KPromote t2) =
   fmap KPromote (joinCoeffectTypes t1 t2)
joinKind _ _ = Nothing

-- | Some coeffect types can be joined (have a least-upper bound). This
-- | function computes the join if it exists.
joinCoeffectTypes :: Type -> Type -> Maybe Type
joinCoeffectTypes t1 t2 = case (t1, t2) of
  -- Equal things unify to the same thing
  (t, t') | t == t' -> Just t

  -- `Nat` can unify with `Q` to `Q`
  (TyCon (internalName -> "Q"), TyCon (internalName -> "Nat")) ->
        Just $ TyCon $ mkId "Q"

  (TyCon (internalName -> "Nat"), TyCon (internalName -> "Q")) ->
        Just $ TyCon $ mkId "Q"

  -- `Nat` can unify with `Ext Nat` to `Ext Nat`
  (t, TyCon (internalName -> "Nat")) | t == extendedNat ->
        Just extendedNat
  (TyCon (internalName -> "Nat"), t) | t == extendedNat ->
        Just extendedNat

  (TyApp t1 t2, TyApp t1' t2') ->
    TyApp <$> joinCoeffectTypes t1 t1' <*> joinCoeffectTypes t2 t2'

  _ -> Nothing

-- | Predicate on whether two kinds have a leasy upper bound
hasLub :: Kind -> Kind -> Bool
hasLub k1 k2 =
  case joinKind k1 k2 of
    Nothing -> False
    Just _  -> True


-- | Infer the type of ta coeffect term (giving its span as well)
inferCoeffectType :: (?globals :: Globals) => Span -> Coeffect -> MaybeT Checker Type

-- Coeffect constants have an obvious kind
inferCoeffectType _ (Level _)         = return $ TyCon $ mkId "Level"
inferCoeffectType _ (CNat _)          = return $ TyCon $ mkId "Nat"
inferCoeffectType _ (CFloat _)        = return $ TyCon $ mkId "Q"
inferCoeffectType _ (CSet _)          = return $ TyCon $ mkId "Set"
inferCoeffectType s (CProduct c1 c2)    = do
  k1 <- inferCoeffectType s c1
  k2 <- inferCoeffectType s c2
  return $ TyApp (TyApp (TyCon $ mkId "×") k1) k2

inferCoeffectType s (CInterval c1 c2)    = do
  k1 <- inferCoeffectType s c1
  k2 <- inferCoeffectType s c2

  case joinCoeffectTypes k1 k2 of
    Just k -> return $ TyApp (TyCon $ mkId "Interval") k

    Nothing ->
      halt $ KindError (Just s) $ "Interval grades do not match: `" <> pretty k1
          <> "` does not match with `" <> pretty k2 <> "`"

-- Take the join for compound coeffect epxressions
inferCoeffectType s (CPlus c c')  = mguCoeffectTypes s c c'
inferCoeffectType s (CMinus c c') = mguCoeffectTypes s c c'
inferCoeffectType s (CTimes c c') = mguCoeffectTypes s c c'
inferCoeffectType s (CMeet c c')  = mguCoeffectTypes s c c'
inferCoeffectType s (CJoin c c')  = mguCoeffectTypes s c c'
inferCoeffectType s (CExpon c c') = mguCoeffectTypes s c c'

-- Coeffect variables should have a type in the cvar->kind context
inferCoeffectType s (CVar cvar) = do
  st <- get
  case lookup cvar (tyVarContext st) of
     Nothing -> do
       halt $ UnboundVariableError (Just s) $ "Tried to look up kind of `" <> pretty cvar <> "`"
                                              <?> show (cvar,(tyVarContext st))
--       state <- get
--       let newType = TyVar $ "ck" <> show (uniqueVarId state)
       -- We don't know what it is yet though, so don't update the coeffect kind ctxt
--       put (state { uniqueVarId = uniqueVarId state + 1 })
--       return newType


     Just (KVar   name, _) -> return $ TyVar name
     Just (KPromote t, _)  -> checkKindIsCoeffect s t
     Just (k, _)           -> illKindedNEq s KCoeffect k

inferCoeffectType s (CZero t) = checkKindIsCoeffect s t
inferCoeffectType s (COne t)  = checkKindIsCoeffect s t
inferCoeffectType s (CInfinity (Just t)) = checkKindIsCoeffect s t
-- Unknown infinity defaults to the interval of extended nats version
inferCoeffectType s (CInfinity Nothing) = return (TyApp (TyCon $ mkId "Interval") extendedNat)
inferCoeffectType s (CSig _ t) = checkKindIsCoeffect s t

inferCoeffectTypeAssumption :: (?globals :: Globals)
                            => Span -> Assumption -> MaybeT Checker (Maybe Type)
inferCoeffectTypeAssumption _ (Linear _) = return Nothing
inferCoeffectTypeAssumption s (Discharged _ c) = do
    t <- inferCoeffectType s c
    return $ Just t

checkKindIsCoeffect :: (?globals :: Globals) => Span -> Type -> MaybeT Checker Type
checkKindIsCoeffect span ty = do
  kind <- inferKindOfType span ty
  case kind of
    KCoeffect -> return ty
    -- Came out as a promoted type, check that this is a coeffect
    KPromote k -> do
      kind' <- inferKindOfType span k
      case kind' of
        KCoeffect -> return ty
        _         -> illKindedNEq span KCoeffect kind
    KVar v -> do
      st <- get
      case lookup v (tyVarContext st) of
        Just (KCoeffect, _) -> return ty
        _                   -> illKindedNEq span KCoeffect kind

    _         -> illKindedNEq span KCoeffect kind


mguCoeffectTypes :: (?globals :: Globals) => Span -> Coeffect -> Coeffect -> MaybeT Checker Type
mguCoeffectTypes s c1 c2 = mguCoeffectTypesSafe s c1 c2 >>= either halt pure


-- Find the most general unifier of two coeffects
-- This is an effectful operation which can update the coeffect-kind
-- contexts if a unification resolves a variable
mguCoeffectTypesSafe :: (?globals :: Globals) => Span -> Coeffect -> Coeffect -> MaybeT Checker (Either IllKindedReason Type)
mguCoeffectTypesSafe s c1 c2 = do
  ck1 <- inferCoeffectType s c1
  ck2 <- inferCoeffectType s c2
  case (ck1, ck2) of
    -- Both are variables
    (TyVar kv1, TyVar kv2) | kv1 /= kv2 -> do
      updateCoeffectType kv1 (KVar kv2)
      okay (TyVar kv2)

    (t, t') | t == t' -> okay t

   -- Linear-hand side is a poly variable, but right is concrete
    (TyVar kv1, ck2') -> do
      updateCoeffectType kv1 (promoteTypeToKind ck2')
      okay ck2'

    -- Right-hand side is a poly variable, but Linear is concrete
    (ck1', TyVar kv2) -> do
      updateCoeffectType kv2 (promoteTypeToKind ck1')
      okay ck1'

    (TyCon k1, TyCon k2) | k1 == k2 -> okay $ TyCon k1

    -- Try to unify coeffect types
    (t, t') | Just tj <- joinCoeffectTypes t t' -> okay tj

    -- Unifying a product of (t, t') with t yields (t, t') [and the symmetric version]
    (isProduct -> Just (t1, t2), t) | t1 == t -> okay ck1
    (isProduct -> Just (t1, t2), t) | t2 == t -> okay ck1
    (t, isProduct -> Just (t1, t2)) | t1 == t -> okay ck2
    (t, isProduct -> Just (t1, t2)) | t2 == t -> okay ck2

    (k1, k2) -> nope $ KindError (Just s) $ "Cannot unify coeffect types '"
                 <> pretty k1 <> "' and '" <> pretty k2
                 <> "' for coeffects `" <> pretty c1 <> "` and `" <> pretty c2 <> "`"
    where okay = pure . pure
          nope = pure . Left


-- Given a coeffect type variable and a coeffect kind,
-- replace any occurence of that variable in a context
updateCoeffectType :: (?globals :: Globals) => Id -> Kind -> MaybeT Checker ()
updateCoeffectType tyVar k = do
   modify (\checkerState ->
    checkerState
     { tyVarContext = rewriteCtxt (tyVarContext checkerState) })
 where
   rewriteCtxt :: Ctxt (Kind, Quantifier) -> Ctxt (Kind, Quantifier)
   rewriteCtxt [] = []
   rewriteCtxt ((name, (KPromote (TyVar kindVar), q)) : ctxt)
    | tyVar == kindVar = (name, (k, q)) : rewriteCtxt ctxt
   rewriteCtxt ((name, (KVar kindVar, q)) : ctxt)
    | tyVar == kindVar = (name, (k, q)) : rewriteCtxt ctxt
   rewriteCtxt (x : ctxt) = x : rewriteCtxt ctxt


-- | Retrieve a kind from the type constructor scope
getKindRequired :: (?globals :: Globals) => Span -> Id -> MaybeT Checker Kind
getKindRequired sp name = do
  ifaceExists <- interfaceExists name
  if ifaceExists
  then getInterfaceKind sp name
  else do
    tyCon <- lookupContext typeConstructors name
    case tyCon of
      Just (kind, _) -> pure kind
      Nothing -> do
        dConTys <- requireInScope (dataConstructors, "Interface or constructor") sp name
        case dConTys of
          (Forall _ [] [] t, []) -> pure $ KPromote t
          _ -> halt $ GenericError (Just sp)
               ("I'm afraid I can't yet promote the polymorphic data constructor:"  <> pretty name)
