{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
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

{- |
Module      : Verifier.SAW.Translation.Coq
Copyright   : Galois, Inc. 2018
License     : BSD3
Maintainer  : atomb@galois.com
Stability   : experimental
Portability : portable
-}

module Verifier.SAW.Translation.Coq.SpecialTreatment where

import           Control.Lens                       (_1, _2, over)
import           Control.Monad.Reader               (asks)
import           Data.Char                          (isAlphaNum)
import qualified Data.Map                           as Map
import           Data.String.Interpolate            (i)
import qualified Data.Text                          as Text
import           Prelude                            hiding (fail)
import           Text.Encoding.Z                    (zEncodeString)

import qualified Language.Coq.AST                   as Coq
import           Verifier.SAW.SharedTerm
import           Verifier.SAW.Translation.Coq.Monad
import           Verifier.SAW.Term.Functor

data SpecialTreatment = SpecialTreatment
  { moduleRenaming        :: Map.Map ModuleName String
  , identSpecialTreatment :: Map.Map ModuleName (Map.Map String IdentSpecialTreatment)
  }

-- | How to handle SAWCore identifiers at their definition sites.
data DefSiteTreatment
  = -- | Translate the identifier unchanged, and directly translate the assocated
    --   SAWCore declaration.
    DefPreserve
  | -- | Translate the identifier into the given Coq identifer,
    --   and otherwise directly translate the associated SAWCore declaration.
    DefRename String
  | -- | Replace the declaration of the identifier with the given text.
    DefReplace  String
    -- | Skip the declartion of the identifier altogether.
  | DefSkip

-- | How to translate SAWCore identifiers at their use sites.
data UseSiteTreatment
  = -- | Translate the identifier unchanged
    UsePreserve
    -- | Rename the given identifier into the given (optionally qualified)
    --   Coq identifier.  The boolean value, if true, indicates that the
    --   identifier should be an "explicit" identifier with a leading \"\@\"
    --   symbol, which indicates to Coq that all implicit arguments should be
    --   treated as explicit.
  | UseRename   (Maybe ModuleName) String Bool
    -- | Apply a macro function to the translations of the first @n@ SAWCore
    -- arguments of this identifier
  | UseMacro Int ([Coq.Term] -> Coq.Term)

data IdentSpecialTreatment = IdentSpecialTreatment
  { atDefSite :: DefSiteTreatment
  , atUseSite :: UseSiteTreatment
  }

moduleRenamingMap :: Map.Map ModuleName ModuleName
moduleRenamingMap = Map.fromList $
  over _1 (mkModuleName . (: [])) <$>
  over _2 (mkModuleName . (: [])) <$>
  [ ("Cryptol", "CryptolPrimitivesForSAWCore")
  , ("Prelude", "SAWCorePrelude")
  ]

translateModuleName :: ModuleName -> ModuleName
translateModuleName mn =
  Map.findWithDefault mn mn moduleRenamingMap

findSpecialTreatment ::
  TranslationConfigurationMonad r m =>
  Ident -> m IdentSpecialTreatment
findSpecialTreatment ident = do
  configuration <- asks translationConfiguration
  let moduleMap =
        Map.findWithDefault Map.empty (identModule ident) (specialTreatmentMap configuration)
  let defaultTreatment =
        IdentSpecialTreatment
        { atDefSite = DefPreserve
        , atUseSite = UsePreserve
        }
  pure $ Map.findWithDefault defaultTreatment (identName ident) moduleMap

-- | Use `mapsTo` for identifiers whose definition has a matching definition
-- already on the Coq side.  As such, their definition can be skipped, and use
-- sites can be replaced by the appropriate call.
mapsTo :: ModuleName -> String -> IdentSpecialTreatment
mapsTo targetModule targetName = IdentSpecialTreatment
  { atDefSite = DefSkip
  , atUseSite = UseRename (Just targetModule) targetName False
  }

-- | Like 'mapsTo' but use an explicit variable reference so
-- that all implicit arguments must be provided.
mapsToExpl :: ModuleName -> String -> IdentSpecialTreatment
mapsToExpl targetModule targetName = IdentSpecialTreatment
  { atDefSite = DefSkip
  , atUseSite = UseRename (Just targetModule) targetName True
  }

-- | Like 'mapsToExpl' but add an @n@th argument that is inferred by Coq
mapsToExplInferArg :: String -> Int -> IdentSpecialTreatment
mapsToExplInferArg targetName argNum = IdentSpecialTreatment
  { atDefSite = DefSkip
  , atUseSite = UseMacro argNum (\args ->
                                  Coq.App (Coq.ExplVar targetName)
                                  (args ++ [Coq.Var "_"]))
  }

-- | Use `realize` for axioms that can be realized, or for primitives that must
-- be realized. While some primitives can be written directly in a standalone
-- Coq module, some primitives depend on code from the extracted module, and are
-- depended upon by following code in the same module. Such primitives can
-- therefore *neither* be defined a priori, *nor* a posteriori, and must be
-- realized where they were originally declared.
realize :: String -> IdentSpecialTreatment
realize code = IdentSpecialTreatment
  { atDefSite = DefReplace code
  , atUseSite = UsePreserve
  }

-- | Use `rename` for identifiers whose definition can be translated, but has to
-- be renamed. This is useful for certain definitions whose name on the
-- SAWCore/Cryptol side clashes with names on the Coq side. For instance, `at`
-- is a reserved Coq keyword, but is used as a function name in SAWCore Prelude.
-- Also useful for translation notations, until they are better supported.
rename :: String -> IdentSpecialTreatment
rename ident = IdentSpecialTreatment
  { atDefSite = DefRename ident
  , atUseSite = UseRename Nothing ident False
  }

-- | Replace any occurrences of identifier applied to @n@ arguments with the
-- supplied Coq term
replaceDropArgs :: Int -> Coq.Term -> IdentSpecialTreatment
replaceDropArgs n term = IdentSpecialTreatment
  { atDefSite = DefSkip
  , atUseSite = UseMacro n (const term)
  }

-- | A version of 'replaceDropArgs' that drops no arguments; i.e., just replaces
-- an identifier with the supplied Coq term
replace :: Coq.Term -> IdentSpecialTreatment
replace = replaceDropArgs 0


-- | Use `skip` for identifiers that are already defined in the appropriate
-- module on the Coq side.
skip :: IdentSpecialTreatment
skip = IdentSpecialTreatment
  { atDefSite = DefSkip
  , atUseSite = UsePreserve
  }

-- | The Coq built-in @Datatypes@ module
datatypesModule :: ModuleName
datatypesModule =
  -- NOTE: SAW core convention is most specific module name component first, so
  -- this is really Coq.Init.Datatypes
  mkModuleName ["Datatypes", "Init", "Coq"]

-- | The Coq built-in @Logic@ module
logicModule :: ModuleName
logicModule =
  -- NOTE: SAW core convention is most specific module name component first, so
  -- this is really Coq.Init.Logic
  mkModuleName ["Logic", "Init", "Coq"]

-- | The Coq built-in @String@ module.
stringModule :: ModuleName
stringModule =
  -- NOTE: SAW core convention is most specific module name component first, so
  -- this is really Coq.Strings.String
  mkModuleName ["String", "Strings", "Coq"]

-- | The @SAWCoreScaffolding@ module
sawDefinitionsModule :: ModuleName
sawDefinitionsModule = mkModuleName ["SAWCoreScaffolding"]

-- | The @CompM@ module
compMModule :: ModuleName
compMModule = mkModuleName ["CompM"]

specMModule :: ModuleName
specMModule = mkModuleName ["SpecM"]

sawVectorDefinitionsModule :: TranslationConfiguration -> ModuleName
sawVectorDefinitionsModule (TranslationConfiguration {..}) =
  mkModuleName [Text.pack vectorModule]

cryptolPrimitivesModule :: ModuleName
cryptolPrimitivesModule = mkModuleName ["CryptolPrimitivesForSAWCore"]

preludeExtraModule :: ModuleName
preludeExtraModule = mkModuleName ["SAWCorePreludeExtra"]

cryptolPreludeSpecialTreatmentMap :: Map.Map String IdentSpecialTreatment
cryptolPreludeSpecialTreatmentMap = Map.fromList $ []

  ++
  [ ("Num_rec",               mapsTo cryptolPrimitivesModule "Num_rect") -- automatically defined
  , ("unsafeAssert_same_Num", skip) -- unsafe and unused
  ]

specialTreatmentMap :: TranslationConfiguration -> Map.Map ModuleName (Map.Map String IdentSpecialTreatment)
specialTreatmentMap configuration = Map.fromList $
  over _1 (mkModuleName . (: [])) <$>
  [ ("Cryptol", cryptolPreludeSpecialTreatmentMap)
  , ("Prelude", sawCorePreludeSpecialTreatmentMap configuration)
  ]

-- NOTE: while I initially did the mapping from SAW core names to the
-- corresponding Coq construct here, it makes the job of translating SAW core
-- axioms into Coq theorems much more annoying, because one needs to manually
-- rename every constant mentioned in the statement to its Coq counterpart.
-- Instead, I am now trying to keep the names the same as much as possible
-- during this translation (it is sometimes impossible, for instance, `at` is a
-- reserved keyword in Coq), so that primitives' and axioms' types can be
-- copy-pasted as is on the Coq side.
sawCorePreludeSpecialTreatmentMap :: TranslationConfiguration -> Map.Map String IdentSpecialTreatment
sawCorePreludeSpecialTreatmentMap configuration =
  let vectorsModule = sawVectorDefinitionsModule configuration in
  Map.fromList $

  -- sawLet
  [ ("sawLet", mapsTo sawDefinitionsModule "sawLet_def") ]

  -- Unsafe SAW features
  ++
  [ ("error",             mapsTo sawDefinitionsModule "error")
  , ("fix",               skip)
  , ("fix_unfold",        skip)
  , ("unsafeAssert",      replaceDropArgs 3 $ Coq.Ltac "solveUnsafeAssert")
  , ("unsafeAssertBVULt", replaceDropArgs 3 $ Coq.Ltac "solveUnsafeAssertBVULt")
  , ("unsafeAssertBVULe", replaceDropArgs 3 $ Coq.Ltac "solveUnsafeAssertBVULe")
  , ("unsafeCoerce",      skip)
  , ("unsafeCoerce_same", skip)
  ]

  -- coercions
  ++
  [ ("coerce",      mapsTo sawDefinitionsModule "coerce")
  , ("coerce__def", mapsTo sawDefinitionsModule "coerce")
  , ("coerce__eq",  replace (Coq.Var "eq_refl"))
  , ("uip",         replace (Coq.Var "UIP"))
  ]

  -- Unit
  ++
  [ ("Unit",          mapsTo sawDefinitionsModule "Unit")
  , ("UnitType",      mapsTo sawDefinitionsModule "UnitType")
  , ("UnitType__rec", mapsTo sawDefinitionsModule "UnitType__rec")
  ]

  -- Records
  ++
  [ ("EmptyType",       skip)
  , ("EmptyType__rec",  skip)
  , ("RecordType",      skip)
  , ("RecordType__rec", skip)
  ]

  -- Decidable equality, does not make sense in Coq unless turned into a type
  -- class
  -- Apparently, this is not used much for Cryptol, so we can skip it.
  ++
  [ ("eq",            skip) -- MapsTo $ mkCoqIdent sawDefinitionsModule "eq")
  , ("eq_bitvector",  skip)
  , ("eq_Bool",       skip) -- MapsTo $ mkCoqIdent "CryptolToCoq.SAW" "eq_Bool")
  , ("eq_Nat",        skip)
  , ("eq_refl",       skip) -- MapsTo $ mkCoqIdent "CryptolToCoq.SAW" "eq_refl")
  , ("eq_VecBool",    skip)
  , ("eq_VecVec",     skip)
  , ("ite_eq_cong_1", skip)
  , ("ite_eq_cong_2", skip)
  ]

  -- Boolean
  ++
  [ ("Bool",          mapsTo datatypesModule "bool")
  , ("True",          mapsTo datatypesModule "true")
  , ("False",         mapsTo datatypesModule "false")
  , ("and",           mapsTo datatypesModule "andb")
  , ("and__eq",       mapsTo sawDefinitionsModule "and__eq")
  , ("or",            mapsTo datatypesModule "orb")
  , ("or__eq",        mapsTo sawDefinitionsModule "or__eq")
  , ("xor",           mapsTo datatypesModule "xorb")
  , ("xor__eq",       mapsTo sawDefinitionsModule "xor__eq")
  , ("not",           mapsTo datatypesModule "negb")
  , ("not__eq",       mapsTo sawDefinitionsModule "not__eq")
  , ("boolEq",        mapsTo sawDefinitionsModule "boolEq")
  , ("boolEq__eq",    mapsTo sawDefinitionsModule "boolEq__eq")
  , ("ite",           mapsTo sawDefinitionsModule "ite")
  , ("iteDep",        mapsTo sawDefinitionsModule "iteDep")
  , ("iteDep_True",   mapsTo sawDefinitionsModule "iteDep_True")
  , ("iteDep_False",  mapsTo sawDefinitionsModule "iteDep_False")
  , ("ite_bit",       skip) -- FIXME: change this
  , ("ite_eq_iteDep", mapsTo sawDefinitionsModule "ite_eq_iteDep")
  ]

  -- Pairs
  ++
  [ ("PairType",  mapsTo sawDefinitionsModule "PairType")
  , ("PairValue", mapsTo sawDefinitionsModule "PairValue")
  , ("Pair__rec", mapsTo sawDefinitionsModule "Pair__rec")
  , ("fst",       replaceDropArgs 2 $ Coq.Var "fst")
  , ("snd",       replaceDropArgs 2 $ Coq.Var "snd")
  ]

  -- Equality
  ++
  [ ("Eq",      mapsToExpl logicModule "eq")
  , ("Eq__rec", mapsTo sawDefinitionsModule "Eq__rec")
  , ("Refl",    mapsToExpl logicModule "eq_refl")
  ]

  -- Nat le/lt
  ++
  [ ("IsLeNat"     , mapsTo sawDefinitionsModule "IsLeNat")
  , ("IsLeNat__rec", mapsTo sawDefinitionsModule "IsLeNat__rec")
  , ("IsLeNat_base", mapsTo sawDefinitionsModule "IsLeNat_base")
  , ("IsLeNat_succ", mapsTo sawDefinitionsModule "IsLeNat_succ")
  , ("IsLtNat"     , mapsTo sawDefinitionsModule "IsLtNat")
  ]

  -- Strings
  ++
  [ ("String", mapsTo stringModule "string")
  , ("equalString", mapsTo sawDefinitionsModule "equalString")
  , ("appendString", mapsTo sawDefinitionsModule "appendString")
  ]

  -- Utility functions
  ++
  [ ("id", mapsTo datatypesModule "id")
  ]

  -- Natural numbers
  ++
  [ ("divModNat", mapsTo sawDefinitionsModule "divModNat")
  , ("Nat",       mapsTo datatypesModule "nat")
  , ("widthNat",  mapsTo sawDefinitionsModule "widthNat")
  , ("Zero",      mapsTo sawDefinitionsModule "Zero")
  , ("Succ",      mapsTo sawDefinitionsModule "Succ")
  ]

  -- Vectors
  ++
  [ ("EmptyVec",      mapsTo vectorsModule "EmptyVec")
  , ("at",            rename "sawAt") -- `at` is a reserved keyword in Coq
  , ("at_gen_BVVec",  mapsTo preludeExtraModule "at_gen_BVVec")
  , ("atWithDefault", mapsTo vectorsModule "atWithDefault")
  , ("atWithProof",   mapsTo vectorsModule "atWithProof")
  , ("at_single",     skip) -- is boring, could be proved on the Coq side
  , ("bvAdd",         mapsTo vectorsModule "bvAdd")
  , ("bvLg2",         mapsTo vectorsModule "bvLg2")
  , ("bvMul",         mapsTo vectorsModule "bvMul")
  , ("bvNat",         mapsTo vectorsModule "bvNat")
  , ("bvNeg",         mapsTo vectorsModule "bvNeg")
  , ("bvSDiv",        mapsTo vectorsModule "bvSDiv")
  , ("bvSRem",        mapsTo vectorsModule "bvSRem")
  , ("bvSShr",        mapsTo vectorsModule "bvSShr")
  , ("bvSub",         mapsTo vectorsModule "bvSub")
  , ("bvToNat",       mapsTo vectorsModule "bvToNat")
  , ("bvUDiv",        mapsTo vectorsModule "bvUDiv")
  , ("bvURem",        mapsTo vectorsModule "bvURem")
  , ("bvsge",         mapsTo vectorsModule "bvsge")
  , ("bvsgt",         mapsTo vectorsModule "bvsgt")
  , ("bvsle",         mapsTo vectorsModule "bvsle")
  , ("bvslt",         mapsTo vectorsModule "bvslt")
  , ("bvult",         mapsTo vectorsModule "bvult")
  , ("bvule",         mapsTo vectorsModule "bvule")
  , ("coerceVec",     mapsTo vectorsModule "coerceVec")
  , ("eq_Vec",        skip)
  , ("foldr",         mapsTo vectorsModule "foldr")
  , ("foldr_nil",     mapsTo vectorsModule "foldr_nil")
  , ("foldr_cons",    mapsTo vectorsModule "foldr_cons")
  , ("foldl",         mapsTo vectorsModule "foldl")
  , ("foldl_nil",     mapsTo vectorsModule "foldl_nil")
  , ("foldl_cons",    mapsTo vectorsModule "foldl_cons")
  , ("gen_at_BVVec",  mapsTo preludeExtraModule "gen_at_BVVec")
  , ("genWithProof",  mapsTo vectorsModule "genWithProof")
  , ("scanl",         mapsTo vectorsModule "scanl")
  , ("gen",           mapsTo vectorsModule "gen")
  , ("rotateL",       mapsTo vectorsModule "rotateL")
  , ("rotateR",       mapsTo vectorsModule "rotateR")
  , ("shiftL",        mapsTo vectorsModule "shiftL")
  , ("shiftR",        mapsTo vectorsModule "shiftR")
  , ("take0",         skip)
  -- zip must be realized in-place because it both depends on definitions and is
  -- used by other definitions in the same file, so it can neither be pre- nor
  -- post-defined.
  , ("zip",           realize zipSnippet)
  -- cannot map directly to Vector.t because arguments are in a different order
  , ("Vec",           mapsTo vectorsModule "Vec")
  , ("head",          mapsTo vectorsModule "head")
  , ("tail",          mapsTo vectorsModule "tail")
  , ("head_gen",      mapsTo vectorsModule "head_gen")
  , ("tail_gen",      mapsTo vectorsModule "tail_gen")
  ]

  -- Streams
  ++
  [ ("streamScanl",   mapsTo preludeExtraModule "streamScanl")
  ]

  -- Integers
  ++
  [ ("Integer",  mapsTo sawDefinitionsModule "Integer")
  , ("intAdd",   mapsTo sawDefinitionsModule "intAdd")
  , ("intSub",   mapsTo sawDefinitionsModule "intSub")
  , ("intMul",   mapsTo sawDefinitionsModule "intMul")
  , ("intDiv",   mapsTo sawDefinitionsModule "intDiv")
  , ("intMod",   mapsTo sawDefinitionsModule "intMod")
  , ("intMin",   mapsTo sawDefinitionsModule "intMin")
  , ("intMax",   mapsTo sawDefinitionsModule "intMax")
  , ("intNeg",   mapsTo sawDefinitionsModule "intNeg")
  , ("intAbs",   mapsTo sawDefinitionsModule "intAbs")
  , ("intEq",    mapsTo sawDefinitionsModule "intEq")
  , ("intLe",    mapsTo sawDefinitionsModule "intLe")
  , ("intLt",    mapsTo sawDefinitionsModule "intLt")
  , ("intToNat", mapsTo sawDefinitionsModule "intToNat")
  , ("natToInt", mapsTo sawDefinitionsModule "natToInt")
  , ("intToBv",  mapsTo vectorsModule "intToBv")
  , ("bvToInt",  mapsTo vectorsModule "bvToInt")
  , ("sbvToInt", mapsTo vectorsModule "sbvToInt")
  ]

  -- Modular integers
  ++
  [ ("IntMod",     mapsTo sawDefinitionsModule "IntMod")
  , ("toIntMod",   mapsTo sawDefinitionsModule "toIntMod")
  , ("fromIntMod", mapsTo sawDefinitionsModule "fromIntMod")
  , ("intModEq",   mapsTo sawDefinitionsModule "intModEq")
  , ("intModAdd",  mapsTo sawDefinitionsModule "intModAdd")
  , ("intModSub",  mapsTo sawDefinitionsModule "intModSub")
  , ("intModMul",  mapsTo sawDefinitionsModule "intModMul")
  , ("intModNeg",  mapsTo sawDefinitionsModule "intModNeg")
  ]

  -- Axioms currently skipped
  ++
  [ ("drop0",                skip)
  , ("bvugt",                skip)
  , ("bvuge",                skip)
  , ("bvPopcount",           skip)
  , ("bvCountLeadingZeros",  skip)
  , ("bvCountTrailingZeros", skip)
  , ("bvForall",             skip)
  , ("bvAddZeroL",           skip)
  , ("bvAddZeroR",           skip)
  , ("bvShl",                mapsTo vectorsModule "bvShl")
  , ("bvShr",                mapsTo vectorsModule "bvShr")
  , ("bvShiftL_bvShl",       skip)
  , ("bvShiftR_bvShr",       skip)
  , ("bvEq_refl",            skip)
  , ("equalNat_bv",          skip)
  , ("Float",                skip)
  , ("mkFloat",              skip)
  , ("Double",               skip)
  , ("mkDouble",             skip)
  , ("bveq_sameL",           skip)
  , ("bveq_sameR",           skip)
  , ("bveq_same2",           skip)
  , ("ite_split_cong",       skip)
  , ("ite_join_cong",        skip)
  , ("map_map",              skip)
  , ("test_fun0",            skip)
  , ("test_fun1",            skip)
  , ("test_fun2",            skip)
  , ("test_fun3",            skip)
  , ("test_fun4",            skip)
  , ("test_fun5",            skip)
  , ("test_fun6",            skip)
  ]

  -- The computation monad
  ++
  [ ("CompM",                replace (Coq.Var "CompM"))
  , ("returnM",              replace (Coq.App (Coq.ExplVar "returnM")
                                       [Coq.Var "CompM", Coq.Var "_"]))
  , ("bindM",                replace (Coq.App (Coq.ExplVar "bindM")
                                       [Coq.Var "CompM", Coq.Var "_"]))
  , ("errorM",               replace (Coq.App (Coq.ExplVar "errorM")
                                       [Coq.Var "CompM", Coq.Var "_"]))
  , ("catchM",               skip)
  , ("existsM",              mapsToExpl compMModule "existsM")
  , ("forallM",              mapsToExpl compMModule "forallM")
  , ("orM",                  mapsToExpl compMModule "orM")
  , ("assertingM",           mapsToExpl compMModule "assertingM")
  , ("assumingM",            mapsToExpl compMModule "assumingM")
  , ("asserting",            skip)
  , ("assuming",             skip)
  , ("fixM",                 replace (Coq.App (Coq.ExplVar "fixM")
                                       [Coq.Var "CompM", Coq.Var "_"]))
  , ("LetRecType",           mapsTo specMModule "LetRecType")
  , ("LRT_Ret",              mapsTo specMModule "LRT_Ret")
  , ("LRT_Fun",              mapsTo specMModule "LRT_Fun")
  , ("lrtToType",            mapsTo compMModule "lrtToType")
  , ("LetRecTypes",          mapsTo compMModule "LetRecTypes")
  , ("LRT_Cons",             mapsTo compMModule "LRT_Cons")
  , ("LRT_Nil",              mapsTo compMModule "LRT_Nil")
  , ("lrtPi",                mapsTo compMModule "lrtPi")
  , ("lrtTupleType",         mapsTo compMModule "lrtTupleType")
  , ("multiFixM",            mapsToExpl compMModule "multiFixM")
  , ("letRecM",              mapsToExpl compMModule "letRecM")
  ]

  -- The specification monad
  ++
  [ ("EvType",               mapsTo specMModule "EvType")
  , ("Build_EvType",         mapsTo specMModule "Build_EvType")
  , ("evTypeType",           mapsTo specMModule "evTypeType")
  , ("evRetType",            mapsTo specMModule "evRetType")
  , ("SpecM",                mapsToExpl specMModule "SpecM")
  , ("retS",                 mapsToExpl specMModule "RetS")
  , ("bindS",                mapsToExpl specMModule "BindS")
  , ("errorS",               mapsToExpl specMModule "ErrorS")
  , ("liftStackS",           mapsToExpl specMModule "liftStackS")
  , ("existsS",              mapsToExplInferArg "SpecM.ExistsS" 3)
  , ("forallS",              mapsToExplInferArg "SpecM.ForallS" 3)
  , ("FunStack",             mapsTo specMModule "FunStack")
  , ("LRTInput",             mapsToExpl specMModule "LRTInput")
  , ("LRTOutput",            mapsToExpl specMModule "LRTOutput")
  , ("lrt1Pi",               mapsToExpl specMModule "lrtPi")
  , ("lrtLambda",            mapsToExpl specMModule "lrtLambda")
  , ("nthLRT",               mapsToExpl specMModule "nthLRT")
  , ("FrameCall",            mapsToExpl specMModule "FrameCall")
  , ("FrameCallOfArgs",      mapsToExpl specMModule "FrameCallOfArgs")
  , ("mkFrameCall",          mapsToExpl specMModule "mkFrameCall")
  , ("FrameCallRet",         mapsToExpl specMModule "FrameCallRet")
  , ("LRTType",              mapsToExpl specMModule "LRTType")
  , ("FrameTuple",           mapsToExpl specMModule "FrameTuple")
  , ("callS",                mapsToExpl specMModule "CallS")
  , ("multiFixS",            mapsToExpl specMModule "MultiFixS")
  , ("FunStackE_type",       mapsToExpl specMModule "FunStackE")
  , ("FunStackE_enc",        replace (Coq.Lambda [Coq.Binder "E" (Just (Coq.Var "SpecM.EvType"))]
                                       (Coq.App (Coq.ExplVar "SpecM.FunStackE_encodes")
                                         [Coq.App (Coq.Var "SpecM.evTypeType") [Coq.Var "E"],
                                          Coq.App (Coq.Var "SpecM.evRetType") [Coq.Var "E"]])))
  , ("SpecPreRel",           mapsToExpl specMModule "SpecPreRel")
  , ("SpecPostRel",          mapsToExpl specMModule "SpecPostRel")
  , ("eqPreRel",             mapsToExpl specMModule "eqPreRel")
  , ("eqPostRel",            mapsToExpl specMModule "eqPostRel")
  , ("refinesS",             mapsToExpl specMModule "spec_refines")
  , ("refinesS_eq",          mapsToExpl specMModule "spec_refines_eq")
  ]

  -- Dependent pairs
  ++
  [ ("Sigma", replace (Coq.ExplVar "sigT"))
  , ("exists", replace (Coq.ExplVar "existT"))
  , ("Sigma__rec", replace (Coq.ExplVar "sigT_rect"))
  , ("Sigma_proj1", replace (Coq.ExplVar "projT1"))
  , ("Sigma_proj2", replace (Coq.ExplVar "projT2"))
  ]

  -- Lists
  ++
  [ ("List", mapsToExpl datatypesModule "list")
  , ("Nil", mapsToExpl datatypesModule "nil")
  , ("Cons", mapsToExpl datatypesModule "cons")
  , ("List__rec", mapsToExpl datatypesModule "list_rect")
  ]

  -- Lists at sort 1
  ++
  [ ("List1", mapsToExpl datatypesModule "list")
  , ("Nil1", mapsToExpl datatypesModule "nil")
  , ("Cons1", mapsToExpl datatypesModule "cons")
  ]

  -- Lists at sort 2
  ++
  [ ("List2", mapsToExpl datatypesModule "list")
  , ("Nil2", mapsToExpl datatypesModule "nil")
  , ("Cons2", mapsToExpl datatypesModule "cons")
  , ("List2__rec", mapsToExpl datatypesModule "list_rect")
  ]

escapeIdent :: String -> String
escapeIdent str
  | all okChar str = str
  | otherwise      = "Op_" ++ zEncodeString str
 where
   okChar x = isAlphaNum x || x `elem` ("_'" :: String)

zipSnippet :: String
zipSnippet = [i|
Fixpoint zip (a b : sort 0) (m n : nat) (xs : Vec m a) (ys : Vec n b)
  : Vec (minNat m n) (a * b) :=
  match
    xs in Vector.t _ m'
    return Vector.t _ (minNat m' n)
  with
  | Vector.nil => Vector.nil _
  | Vector.cons x pm xs =>
    match
      ys in Vector.t _ n'
      return Vector.t _ (minNat (S pm) n')
    with
    | Vector.nil => Vector.nil _
    | Vector.cons y pm' ys => Vector.cons _ (x, y) _ (zip _ _ _ _ xs ys)
    end
  end
.
|]
