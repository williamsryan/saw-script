{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Verifier.SAW.Translation.Coq
Copyright   : Galois, Inc. 2018
License     : BSD3
Maintainer  : atomb@galois.com
Stability   : experimental
Portability : portable
-}

module Verifier.SAW.Translation.Coq.Term where

import           Control.Lens                                  (makeLenses, over, set, to, view)
import qualified Control.Monad.Except                          as Except
import qualified Control.Monad.Fail                            as Fail
import           Control.Monad.Reader                          hiding (fail, fix)
import           Control.Monad.State                           hiding (fail, fix, state)
import           Data.Char                                     (isDigit)
import qualified Data.IntMap                                   as IntMap
import           Data.List                                     (intersperse, sortOn)
import           Data.Maybe                                    (fromMaybe)
import qualified Data.Map                                      as Map
import qualified Data.Set                                      as Set
import qualified Data.Text                                     as Text
import           Prelude                                       hiding (fail)
import           Prettyprinter

import           Data.Parameterized.Pair
import           Data.Parameterized.NatRepr
import qualified Data.BitVector.Sized                          as BV
import qualified Data.Vector                                   as Vector (toList)
import qualified Language.Coq.AST                              as Coq
import qualified Language.Coq.Pretty                           as Coq
import           Verifier.SAW.Recognizer
import           Verifier.SAW.SharedTerm
import           Verifier.SAW.Term.Pretty
import           Verifier.SAW.Term.Functor
import           Verifier.SAW.Translation.Coq.Monad
import           Verifier.SAW.Translation.Coq.SpecialTreatment

{-
import Debug.Trace
traceTerm :: String -> Term -> a -> a
traceTerm ctx t a = trace (ctx ++ ": " ++ showTerm t) a
-}

newtype TranslationReader = TranslationReader
  { _currentModule  :: Maybe ModuleName
  }
  deriving (Show)

makeLenses ''TranslationReader

data TranslationState = TranslationState

  { _globalDeclarations :: [String]
  -- ^ Some Cryptol terms seem to capture the name and body of some functions
  -- they use (whether from the Cryptol prelude, or previously defined in the
  -- same file).  We want to translate those exactly once, so we need to keep
  -- track of which ones have already been translated.

  , _topLevelDeclarations :: [Coq.Decl]
  -- ^ Because some terms capture their dependencies, translating one term may
  -- result in multiple declarations: one for the term itself, but also zero or
  -- many for its dependencies.  We store all of those in this, so that a caller
  -- of the translation may retrieve all the declarations needed to translate
  -- the term.  The translation function itself will return only the declaration
  -- for the term being translated.

  , _localEnvironment  :: [Coq.Ident]
  -- ^ The list of Coq identifiers for de Bruijn-indexed local
  -- variables, innermost (index 0) first.

  , _unavailableIdents :: Set.Set Coq.Ident
  -- ^ The set of Coq identifiers that are either reserved or already
  -- in use. To avoid shadowing, fresh identifiers should be chosen to
  -- be disjoint from this set.

  , _sharedNames :: IntMap.IntMap Coq.Ident
  -- ^ Index of identifiers for repeated subterms that have been
  -- lifted out into a let expression.

  , _nextSharedName :: Coq.Ident
  -- ^ The next available name to be used for a let-bound shared
  -- sub-expression.

  }
  deriving (Show)

makeLenses ''TranslationState

type TermTranslationMonad m =
  TranslationMonad TranslationReader TranslationState m

-- | The set of reserved identifiers in Coq, obtained from section
-- "Gallina Specification Language" of the Coq reference manual.
-- <https://coq.inria.fr/refman/language/gallina-specification-language.html>
reservedIdents :: Set.Set Coq.Ident
reservedIdents =
  Set.fromList $
  concatMap words $
  [ "_ Axiom CoFixpoint Definition Fixpoint Hypothesis IF Parameter Prop"
  , "SProp Set Theorem Type Variable as at by cofix discriminated else"
  , "end exists exists2 fix for forall fun if in lazymatch let match"
  , "multimatch return then using where with"
  ]

-- | Extract the list of names from a list of Coq declarations.  Not all
-- declarations have names, e.g. comments and code snippets come without names.
namedDecls :: [Coq.Decl] -> [String]
namedDecls = concatMap filterNamed
  where
    filterNamed :: Coq.Decl -> [String]
    filterNamed (Coq.Axiom n _)                               = [n]
    filterNamed (Coq.Parameter n _)                           = [n]
    filterNamed (Coq.Variable n _)                            = [n]
    filterNamed (Coq.Comment _)                               = []
    filterNamed (Coq.Definition n _ _ _)                      = [n]
    filterNamed (Coq.InductiveDecl (Coq.Inductive n _ _ _ _)) = [n]
    filterNamed (Coq.Snippet _)                               = []
    filterNamed (Coq.Section _ ds)                            = namedDecls ds

-- | Retrieve the names of all local and global declarations from the
-- translation state.
getNamesOfAllDeclarations ::
  TermTranslationMonad m =>
  m [String]
getNamesOfAllDeclarations = view allDeclarations <$> get
  where
    allDeclarations =
      to (\ (TranslationState {..}) -> namedDecls _topLevelDeclarations ++ _globalDeclarations)

runTermTranslationMonad ::
  TranslationConfiguration ->
  TranslationReader ->
  [String] ->
  [Coq.Ident] ->
  (forall m. TermTranslationMonad m => m a) ->
  Either (TranslationError Term) (a, TranslationState)
runTermTranslationMonad configuration r globalDecls localEnv =
  runTranslationMonad configuration r
  (TranslationState { _globalDeclarations = globalDecls
                    , _topLevelDeclarations  = []
                    , _localEnvironment   = localEnv
                    , _unavailableIdents  = Set.union reservedIdents (Set.fromList localEnv)
                    , _sharedNames        = IntMap.empty
                    , _nextSharedName     = "var__0"
                    })

errorTermM :: TermTranslationMonad m => String -> m Coq.Term
errorTermM str = return $ Coq.App (Coq.Var "error") [Coq.StringLit str]

-- | Translate an 'Ident' with a given list of arguments to a Coq term, using
-- any special treatment for that identifier and qualifying it if necessary
translateIdentWithArgs :: TermTranslationMonad m => Ident -> [Term] -> m Coq.Term
translateIdentWithArgs i args = do
  currentModuleName <- asks (view currentModule . otherConfiguration)
  let identToCoq ident =
        if Just (identModule ident) == currentModuleName
          then escapeIdent (identName ident)
          else
            show (translateModuleName (identModule ident))
            ++ "." ++ escapeIdent (identName ident)
  specialTreatment <- findSpecialTreatment i
  applySpecialTreatment identToCoq (atUseSite specialTreatment)

  where

    applySpecialTreatment identToCoq UsePreserve =
      Coq.App (Coq.Var $ identToCoq i) <$> mapM translateTerm args
    applySpecialTreatment identToCoq (UseRename targetModule targetName expl) =
      Coq.App
        ((if expl then Coq.ExplVar else Coq.Var) $ identToCoq $
          mkIdent (fromMaybe (translateModuleName $ identModule i) targetModule)
          (Text.pack targetName))
          <$> mapM translateTerm args
    applySpecialTreatment _identToCoq (UseMacro n macroFun)
      | length args >= n
      , (m_args, args') <- splitAt n args =
        do f <- macroFun <$> mapM translateTerm m_args
           Coq.App f <$> mapM translateTerm args'
    applySpecialTreatment _identToCoq (UseMacro n _) =
      errorTermM (unwords
        [ "Identifier"
        , show i
        , "not applied to required number of args, which is"
        , show n
        ]
      )

-- | Helper for 'translateIdentWithArgs' with no arguments
translateIdent :: TermTranslationMonad m => Ident -> m Coq.Term
translateIdent i = translateIdentWithArgs i []

-- | Translate a constant with optional body to a Coq term. If the constant is
-- named with an 'Ident', then it already has a top-level translation from
-- translating the SAW core module containing that 'Ident'. If the constant is
-- an 'ImportedName', however, then it might not have a Coq definition already,
-- so add a definition of it to the top-level translation state.
translateConstant :: TermTranslationMonad m => ExtCns Term -> Maybe Term ->
                     m Coq.Term
translateConstant ec _
  | ModuleIdentifier ident <- ecName ec = translateIdent ident
translateConstant ec maybe_body =
  do -- First, apply the constant renaming to get the name for this constant
     configuration <- asks translationConfiguration
     -- TODO short name seems wrong
     let nm_str = Text.unpack $ toShortName $ ecName ec
     let renamed =
           escapeIdent $ fromMaybe nm_str $
           lookup nm_str $ constantRenaming configuration

     -- Next, test if we should add a definition of this constant
     alreadyTranslatedDecls <- getNamesOfAllDeclarations
     let skip_def =
           elem renamed alreadyTranslatedDecls ||
           elem renamed (constantSkips configuration)

     -- Add the definition if we aren't skipping it
     case maybe_body of
       _ | skip_def -> return ()
       Just body ->
         -- If the definition has a body, add it as a definition
         do b <- withTopTranslationState $ translateTermLet body
            tp <- withTopTranslationState $ translateTermLet (ecType ec)
            modify $ over topLevelDeclarations $ (mkDefinition renamed b tp :)
       Nothing ->
         -- If not, add it as a Coq Variable declaration
         do tp <- withTopTranslationState $ translateTermLet (ecType ec)
            modify (over topLevelDeclarations (Coq.Variable renamed tp :))

     -- Finally, return the constant as a Coq variable
     pure (Coq.Var renamed)


-- | Translate an 'Ident' and see if the result maps to a SAW core 'Ident',
-- returning the latter 'Ident' if so
translateIdentToIdent :: TermTranslationMonad m => Ident -> m (Maybe Ident)
translateIdentToIdent i =
  (atUseSite <$> findSpecialTreatment i) >>= \case
    UsePreserve -> return $ Just (mkIdent translatedModuleName (identBaseName i))
    UseRename   targetModule targetName _ ->
      return $ Just $ mkIdent (fromMaybe translatedModuleName targetModule) (Text.pack targetName)
    UseMacro _ _ -> return Nothing
  where
    translatedModuleName = translateModuleName (identModule i)

translateSort :: Sort -> Coq.Sort
translateSort s = if s == propSort then Coq.Prop else Coq.Type

flatTermFToExpr ::
  TermTranslationMonad m =>
  FlatTermF Term ->
  m Coq.Term
flatTermFToExpr tf = -- traceFTermF "flatTermFToExpr" tf $
  case tf of
    Primitive pn  -> translateIdent (primName pn)
    UnitValue     -> pure (Coq.Var "tt")
    UnitType      ->
      -- We need to explicitly tell Coq that we want unit to be a Type, since
      -- all SAW core sorts are translated to Types
      pure (Coq.Ascription (Coq.Var "unit") (Coq.Sort Coq.Type))
    PairValue x y -> Coq.App (Coq.Var "pair") <$> traverse translateTerm [x, y]
    PairType x y  -> Coq.App (Coq.Var "prod") <$> traverse translateTerm [x, y]
    PairLeft t    ->
      Coq.App <$> pure (Coq.Var "fst") <*> traverse translateTerm [t]
    PairRight t   ->
      Coq.App <$> pure (Coq.Var "snd") <*> traverse translateTerm [t]
    -- TODO: maybe have more customizable translation of data types
    DataTypeApp n is as -> translateIdentWithArgs (primName n) (is ++ as)
    CtorApp n is as -> translateIdentWithArgs (primName n) (is ++ as)

    RecursorType _d _params motive motiveTy ->
      -- type of the motive looks like
      --      (ix1 : _) -> ... -> (ixn : _) -> d ps ixs -> sort
      -- to get the type of the recursor, we compute
      --      (ix1 : _) -> ... -> (ixn : _) -> (x:d ps ixs) -> motive ixs x
      do let (bs, _srt) = asPiList motiveTy
         (varsT,bindersT) <- unzip <$>
           (forM bs $ \ (b, bType) -> do
             bTypeT <- translateTerm bType
             b' <- freshenAndBindName b
             return (Coq.Var b', Coq.PiBinder (Just b') bTypeT))

         motiveT <- translateTerm motive
         let bodyT = Coq.App motiveT varsT
         return $ Coq.Pi bindersT bodyT

    -- TODO: support this next!
    Recursor (CompiledRecursor d parameters motive _motiveTy eliminators elimOrder) ->
      do maybe_d_trans <- translateIdentToIdent (primName d)
         rect_var <- case maybe_d_trans of
           Just i -> return $ Coq.ExplVar (show i ++ "_rect")
           Nothing ->
             errorTermM ("Recursor for " ++ show d ++
                         " cannot be translated because the datatype " ++
                         "is mapped to an arbitrary Coq term")

         let fnd c = case Map.lookup (primVarIndex c) eliminators of
                       Just (e,_ety) -> translateTerm e
                       Nothing -> errorTermM
                          ("Recursor eliminator missing eliminator for constructor " ++ show c)

         ps <- mapM translateTerm parameters
         m  <- translateTerm motive
         elimlist <- mapM fnd elimOrder

         pure (Coq.App rect_var (ps ++ [m] ++ elimlist))

    RecursorApp r indices termEliminated ->
      do r' <- translateTerm r
         let args = indices ++ [termEliminated]
         Coq.App r' <$> mapM translateTerm args

    Sort s _h -> pure (Coq.Sort (translateSort s))
    NatLit i -> pure (Coq.NatLit (toInteger i))
    ArrayValue (asBoolType -> Just ()) (traverse asBool -> Just bits)
      | Pair w bv <- BV.bitsBE (Vector.toList bits)
      , Left LeqProof <- decideLeq (knownNat @1) w -> do
          return (Coq.App (Coq.Var "intToBv")
                  [Coq.NatLit (intValue w), Coq.ZLit (BV.asSigned w bv)])
    ArrayValue _ vec -> do
      elems <- Vector.toList <$> mapM translateTerm vec
      -- NOTE: with VectorNotations, this is actually a Coq vector literal
      return $ Coq.List elems
    StringLit s -> pure (Coq.Scope (Coq.StringLit (Text.unpack s)) "string")

    ExtCns ec -> translateConstant ec Nothing

    -- The translation of a record type {fld1:tp1, ..., fldn:tpn} is
    -- RecordTypeCons fld1 tp1 (... (RecordTypeCons fldn tpn RecordTypeNil)...).
    -- Note that SAW core equates record types up to reordering, so we sort our
    -- record types by field name to canonicalize them.
    RecordType fs ->
      foldr (\(name, tp) rest_m ->
              do rest <- rest_m
                 tp_trans <- translateTerm tp
                 return (Coq.App (Coq.Var "RecordTypeCons")
                         [Coq.StringLit (Text.unpack name), tp_trans, rest]))
      (return (Coq.Var "RecordTypeNil"))
      (sortOn fst fs)

    -- The translation of a record value {fld1 = x1, ..., fldn = xn} is
    -- RecordCons fld1 x1 (... (RecordCons fldn xn RecordNil) ...). Note that
    -- SAW core equates record values up to reordering, so we sort our record
    -- values by field name to canonicalize them.
    RecordValue fs ->
      foldr (\(name, trm) rest_m ->
              do rest <- rest_m
                 trm_trans <- translateTerm trm
                 return (Coq.App (Coq.Var "RecordCons")
                         [Coq.StringLit (Text.unpack name), trm_trans, rest]))
      (return (Coq.Var "RecordNil"))
      (sortOn fst fs)

    RecordProj r f -> do
      r_trans <- translateTerm r
      return (Coq.App (Coq.Var "RecordProj") [r_trans, Coq.StringLit (Text.unpack f)])

-- | Recognizes an $App (App "Cryptol.seq" n) x$ and returns ($n$, $x$).
asSeq :: Recognizer Term (Term, Term)
asSeq t = do (f, args) <- asApplyAllRecognizer t
             fid <- asGlobalDef f
             case (fid, args) of
               ("Cryptol.seq", [n, x]) -> return (n,x)
               _ -> Fail.fail "not a seq"

asApplyAllRecognizer :: Recognizer Term (Term, [Term])
asApplyAllRecognizer t = do _ <- asApp t
                            return $ asApplyAll t

-- | Run a translation, but keep some changes to the translation state local to
-- that computation, restoring parts of the original translation state before
-- returning.
withLocalTranslationState :: TermTranslationMonad m => m a -> m a
withLocalTranslationState action = do
  before <- get
  result <- action
  after <- get
  put (TranslationState
    -- globalDeclarations is **not** restored, because we want to translate each
    -- global declaration exactly once!
    { _globalDeclarations = view globalDeclarations after
    -- topLevelDeclarations is **not** restored, because it accumulates the
    -- declarations witnessed in a given module so that we can extract it.
    , _topLevelDeclarations = view topLevelDeclarations after
    -- localEnvironment **is** restored, because the identifiers added to it
    -- during translation are local to the term that was being translated.
    , _localEnvironment = view localEnvironment before
    -- unavailableIdents **is** restored, because the extra identifiers
    -- unavailable in the term that was translated are local to it.
    , _unavailableIdents = view unavailableIdents before
    -- sharedNames **is** restored, because we are leaving the scope of the
    -- locally shared names.
    , _sharedNames = view sharedNames before
    -- nextSharedName **is** restored, because we are leaving the scope of the
    -- last names used.
    , _nextSharedName = view nextSharedName before
    })
  return result

-- | Run a translation in the top-level translation state
withTopTranslationState :: TermTranslationMonad m => m a -> m a
withTopTranslationState m =
  withLocalTranslationState $
  do modify $ set localEnvironment []
     modify $ set unavailableIdents reservedIdents
     modify $ set sharedNames IntMap.empty
     modify $ set nextSharedName "var__0"
     m

-- | Generate a Coq @Definition@ with a given name, body, and type, using the
-- lambda-bound variable names for the variables if they are available
mkDefinition :: Coq.Ident -> Coq.Term -> Coq.Term -> Coq.Decl
mkDefinition name (Coq.Lambda bs t) (Coq.Pi bs' tp)
  | length bs' == length bs =
    -- NOTE: there are a number of cases where length bs /= length bs', such as
    -- where the type of a definition is computed from some input (so might not
    -- have any explicit pi-abstractions), or where the body of a definition is
    -- a partially applied function (so might not have any lambdas). We could in
    -- theory try to handle these more complex cases by assigning names to some
    -- of the arguments, but it's not really necessary for the translation to be
    -- correct, so we just do the simple thing here.
    Coq.Definition name bs (Just tp) t
mkDefinition name t tp = Coq.Definition name [] (Just tp) t

-- | Make sure a name is not used in the current environment, adding
-- or incrementing a numeric suffix until we find an unused name. When
-- we get one, add it to the current environment and return it.
freshenAndBindName :: TermTranslationMonad m => LocalName -> m Coq.Ident
freshenAndBindName n =
  do n' <- translateLocalIdent n
     modify $ over localEnvironment (n' :)
     pure n'

mkLet :: (Coq.Ident, Coq.Term) -> Coq.Term -> Coq.Term
mkLet (name, rhs) body = Coq.Let name [] Nothing rhs body

-- | Given a list of 'LocalName's and their corresponding types (as 'Term's),
-- return a list of explicit 'Binder's, for use representing the bound
-- variables in 'Lambda's, 'Let's, etc.
translateParams ::
  TermTranslationMonad m =>
  [(LocalName, Term)] -> m [Coq.Binder]
translateParams bs = concat <$> mapM translateParam bs

-- | Given a 'LocalName' and its type (as a 'Term'), return an explicit
-- 'Binder', for use representing a bound variable in a 'Lambda',
-- 'Let', etc.
translateParam ::
  TermTranslationMonad m =>
  (LocalName, Term) -> m [Coq.Binder]
translateParam (n, ty) =
  translateBinder n ty >>= \(n',ty',nhs) ->
    return $ Coq.Binder n' (Just ty') :
             map (\(nh,nhty) -> Coq.ImplicitBinder nh (Just nhty)) nhs

-- | Given a list of 'LocalName's and their corresponding types (as 'Term's)
-- representing argument types and a 'Term' representing the return type,
-- return the resulting 'Pi', with additional implicit arguments added after
-- each instance of @isort@, @qsort@, etc.
translatePi :: TermTranslationMonad m => [(LocalName, Term)] -> Term -> m Coq.Term
translatePi binders body = withLocalTranslationState $ do
  bindersT <- concat <$> mapM translatePiBinder binders
  bodyT <- translateTermLet body
  return $ Coq.Pi bindersT bodyT

-- | Given a 'LocalName' and its type (as a 'Term'), return an explicit
-- 'PiBinder' followed by zero or more implicit 'PiBinder's representing
-- additonal implicit typeclass arguments, added if the given type is @isort@,
-- @qsort@, etc.
translatePiBinder ::
  TermTranslationMonad m => (LocalName, Term) -> m [Coq.PiBinder]
translatePiBinder (n, ty) =
  translateBinder n ty >>= \case
    (n',ty',[])
      | n == "_"  -> return [Coq.PiBinder Nothing ty']
      | otherwise -> return [Coq.PiBinder (Just n') ty']
    (n',ty',nhs) ->
      return $ Coq.PiBinder (Just n') ty' :
               map (\(nh,nhty) -> Coq.PiImplicitBinder (Just nh) nhty) nhs

-- | Given a 'LocalName' and its type (as a 'Term'), return the translation of
-- the 'LocalName' as an 'Ident', the translation of the type as a 'Type',
-- and zero or more additional 'Ident's and 'Type's representing additonal
-- implicit typeclass arguments, added if the given type is @isort@, etc.
translateBinder ::
  TermTranslationMonad m =>
  LocalName ->
  Term ->
  m (Coq.Ident,Coq.Type,[(Coq.Ident,Coq.Type)])
translateBinder n ty@(asPiList -> (args, asSortWithFlags -> mb_sort)) =
  do ty' <- translateTerm ty
     n' <- freshenAndBindName n
     let flagValues = sortFlagsToList $ maybe noFlags snd mb_sort
         flagLocalNames = [("Inh", "SAWCoreScaffolding.Inhabited"),
                           ("QT", "QuantType")]
     nhs <- forM (zip flagValues flagLocalNames) $ \(fi,(prefix,tc)) ->
       if not fi then return []
       else do nhty <- translateImplicitHyp (Coq.Var tc) args (Coq.Var n')
               nh <- translateLocalIdent (prefix <> "_" <> n)
               return [(nh,nhty)]
     return (n',ty',concat nhs)

-- | Given a typeclass (as a 'Term'), a list of 'LocalName's and their
-- corresponding types (as 'Term's), and a type-level function with argument
-- types given by the prior list, return a 'Pi' of the given arguments, inside
-- of which is an 'App' of the typeclass to the fully-applied type-level
-- function
translateImplicitHyp ::
  TermTranslationMonad m =>
  Coq.Term -> [(LocalName, Term)] -> Coq.Term -> m Coq.Term
translateImplicitHyp tc [] tm = return (Coq.App tc [tm])
translateImplicitHyp tc args tm = withLocalTranslationState $
  do args' <- mapM (uncurry translateBinder) args
     return $ Coq.Pi (concatMap mkPi args')
                (Coq.App tc [Coq.App tm (map mkArg args')])
 where
  mkPi (nm,ty,nhs) =
    Coq.PiBinder (Just nm) ty :
    map (\(nh,nhty) -> Coq.PiImplicitBinder (Just nh) nhty) nhs
  mkArg (nm,_,_) = Coq.Var nm

-- | Translate a local name from a saw-core binder into a fresh Coq identifier.
translateLocalIdent :: TermTranslationMonad m => LocalName -> m Coq.Ident
translateLocalIdent x = freshVariant (escapeIdent (Text.unpack x))

-- | Find an fresh, as-yet-unused variant of the given Coq identifier.
freshVariant :: TermTranslationMonad m => Coq.Ident -> m Coq.Ident
freshVariant x =
  do used <- view unavailableIdents <$> get
     let ident0 = x
     let findVariant i = if Set.member i used then findVariant (nextVariant i) else i
     let ident = findVariant ident0
     modify $ over unavailableIdents (Set.insert ident)
     return ident

nextVariant :: Coq.Ident -> Coq.Ident
nextVariant = reverse . go . reverse
  where
    go :: String -> String
    go (c : cs)
      | c == '9'  = '0' : go cs
      | isDigit c = succ c : cs
    go cs = '1' : cs

translateTermLet :: TermTranslationMonad m => Term -> m Coq.Term
translateTermLet t =
  withLocalTranslationState $
  do let counts = scTermCount False t
     let locals = fmap fst $ IntMap.filter keep counts
     names <- traverse (const nextName) locals
     modify $ set sharedNames names
     defs <- traverse translateTermUnshared locals
     body <- translateTerm t
     -- NOTE: Larger terms always have later IDs than their subterms,
     -- so ordering by VarIndex is a valid dependency order.
     let binds = IntMap.elems (IntMap.intersectionWith (,) names defs)
     pure (foldr mkLet body binds)
  where
    keep (t', n) = n > 1 && shouldMemoizeTerm t'
    nextName =
      do x <- view nextSharedName <$> get
         x' <- freshVariant x
         modify $ set nextSharedName (nextVariant x')
         pure x'

translateTerm :: TermTranslationMonad m => Term -> m Coq.Term
translateTerm t =
  case t of
    Unshared {} -> translateTermUnshared t
    STApp { stAppIndex = i } ->
      do shared <- view sharedNames <$> get
         case IntMap.lookup i shared of
           Nothing -> translateTermUnshared t
           Just x -> pure (Coq.Var x)

translateTermUnshared :: TermTranslationMonad m => Term -> m Coq.Term
translateTermUnshared t = withLocalTranslationState $ do
  -- traceTerm "translateTerm" t $
  -- NOTE: env is in innermost-first order
  env <- view localEnvironment <$> get
  -- let t' = trace ("translateTerm: " ++ "env = " ++ show env ++ ", t =" ++ showTerm t) t
  -- case t' of
  case unwrapTermF t of

    FTermF ftf -> flatTermFToExpr ftf

    Pi {} -> translatePi params e
      where
        (params, e) = asPiList t

    Lambda {} -> do
      paramTerms <- translateParams params
      e' <- translateTermLet e
      pure (Coq.Lambda paramTerms e')
        where
          -- params are in normal, outermost first, order
          (params, e) = asLambdaList t

    App {} ->
      -- asApplyAll: innermost argument first
      let (f, args) = asApplyAll t
      in
      case f of
      (asGlobalDef -> Just i) ->
        case i of
        "Prelude.natToInt" ->
          case args of
          [n] -> translateTerm n >>= \case
            Coq.NatLit n' -> pure $ Coq.ZLit n'
            _ -> translateIdentWithArgs "Prelude.natToInt" [n]
          _ -> badTerm
        "Prelude.intNeg" ->
          case args of
          [z] -> translateTerm z >>= \case
            Coq.ZLit z' -> pure $ Coq.ZLit (-z')
            _ -> translateIdentWithArgs "Prelude.intNeg" [z]
          _ -> badTerm
        "Prelude.ite" ->
          case args of
          -- `rest` can be non-empty in examples like:
          -- (if b then f else g) arg1 arg2
          _ty : c : tt : ft : rest -> do
            ite <- Coq.If <$> translateTerm c <*> translateTerm tt <*> translateTerm ft
            case rest of
              [] -> return ite
              _  -> Coq.App ite <$> mapM translateTerm rest
          _ -> badTerm

        -- Refuse to translate any recursive value defined using Prelude.fix
        "Prelude.fix" -> badTerm

        _ -> translateIdentWithArgs i args
      _ -> Coq.App <$> translateTerm f <*> traverse translateTerm args

    LocalVar n
      | n < length env -> Coq.Var <$> pure (env !! n)
      | otherwise -> Except.throwError $ LocalVarOutOfBounds t

    -- Constants
    Constant n maybe_body -> translateConstant n maybe_body

  where
    badTerm          = Except.throwError $ BadTerm t

-- | In order to turn fixpoint computations into iterative computations, we need
-- to be able to create "dummy" values at the type of the computation.
defaultTermForType ::
  TermTranslationMonad m =>
  Term -> m Coq.Term
defaultTermForType typ = do
  case typ of
    (asBoolType -> Just ()) -> translateIdent (mkIdent preludeName "False")

    (isGlobalDef "Prelude.Nat" -> Just ()) -> return $ Coq.NatLit 0

    (asIntegerType -> Just ()) -> return $ Coq.ZLit 0

    (asSeq -> Just (n, typ')) -> do
      seqConst <- translateIdent (mkIdent (mkModuleName ["Cryptol"]) "seqConst")
      nT       <- translateTerm n
      typ'T    <- translateTerm typ'
      defaultT <- defaultTermForType typ'
      return $ Coq.App seqConst [ nT, typ'T, defaultT ]

    (asPairType -> Just (x,y)) -> do
      x' <- defaultTermForType x
      y' <- defaultTermForType y
      return $ Coq.App (Coq.Var "pair") [x',y']

    (asPiList -> (bs,body))
      | not (null bs)
      , looseVars body == emptyBitSet ->
      do bs'   <- forM bs $ \ (_nm, ty) -> Coq.Binder "_" . Just <$> translateTerm ty
         body' <- defaultTermForType body
         return $ Coq.Lambda bs' body'

    _ -> Except.throwError $ CannotCreateDefaultValue typ

-- | Translate a SAW core term along with its type to a Coq term and its Coq
-- type, and pass the results to the supplied function
translateTermToDocWith ::
  TranslationConfiguration ->
  TranslationReader ->
  [String] -> -- ^ globals that have already been translated
  [String] -> -- ^ string names of local variables in scope
  (Coq.Term -> Coq.Term -> Doc ann) ->
  Term -> Term ->
  Either (TranslationError Term) (Doc ann)
translateTermToDocWith configuration r globalDecls localEnv f t tp_trm = do
  ((term, tp), state) <-
    runTermTranslationMonad configuration r globalDecls localEnv
    ((,) <$> translateTermLet t <*> translateTermLet tp_trm)
  let decls = view topLevelDeclarations state
  return $
    vcat $
    [ (vcat . intersperse hardline . map Coq.ppDecl . reverse) decls
    , if null decls then mempty else hardline
    , f term tp
    ]

-- | Translate a SAW core 'Term' and its type (given as a 'Term') to a Coq
-- definition with the supplied name
translateDefDoc ::
  TranslationConfiguration ->
  TranslationReader ->
  [String] ->
  Coq.Ident -> Term -> Term ->
  Either (TranslationError Term) (Doc ann)
translateDefDoc configuration r globalDecls name =
  translateTermToDocWith configuration r globalDecls [name]
  (\ t tp -> Coq.ppDecl $ mkDefinition name t tp)
