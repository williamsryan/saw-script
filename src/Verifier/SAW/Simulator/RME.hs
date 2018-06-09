{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE TypeFamilies #-}

{- |
Module      : Verifier.SAW.Simulator.RME
Copyright   : Galois, Inc. 2012-2015
License     : BSD3
Maintainer  : huffman@galois.com
Stability   : experimental
Portability : non-portable (language extensions)
-}

module Verifier.SAW.Simulator.RME
  ( evalSharedTerm
  , RValue, Value(..)
  , RExtra(..)
  , toBool
  , toWord
  , runIdentity
  , withBitBlastedPred
  ) where

import Control.Monad.Identity
import Control.Monad.State
import Data.Bits
import Data.IntTrie (IntTrie)
import qualified Data.IntTrie as IntTrie
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Vector (Vector)
import qualified Data.Vector as V

import Verifier.SAW.Simulator.RME.Base (RME)
import qualified Verifier.SAW.Simulator.RME.Base as RME
import qualified Verifier.SAW.Simulator.RME.Vector as RMEV

import qualified Verifier.SAW.Simulator as Sim
import Verifier.SAW.Simulator.Value
import qualified Verifier.SAW.Simulator.Prims as Prims
import Verifier.SAW.FiniteValue (FiniteType(..), asFiniteType)
import qualified Verifier.SAW.Recognizer as R
import Verifier.SAW.SharedTerm
import Verifier.SAW.TypedAST (ModuleMap, showTerm)

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
import Data.Traversable
#endif

------------------------------------------------------------

-- | Evaluator for shared terms.
evalSharedTerm :: ModuleMap -> Map Ident RValue -> Term -> RValue
evalSharedTerm m addlPrims t =
  runIdentity $ do
    cfg <- Sim.evalGlobal m (Map.union constMap addlPrims)
           Sim.noExtCns (const (const Nothing))
    Sim.evalSharedTerm cfg t

------------------------------------------------------------
-- Values

data ReedMuller

type instance EvalM ReedMuller = Identity
type instance VBool ReedMuller = RME
type instance VWord ReedMuller = Vector RME
type instance VInt  ReedMuller = Integer
type instance Extra ReedMuller = RExtra

type RValue = Value ReedMuller
type RThunk = Thunk ReedMuller

data RExtra = AStream (IntTrie RValue)

instance Show RExtra where
  show (AStream _) = "<stream>"

vBool :: RME -> RValue
vBool b = VBool b

toBool :: RValue -> RME
toBool (VBool b) = b
toBool x = error $ unwords ["Verifier.SAW.Simulator.RME.toBool", show x]

vWord :: Vector RME -> RValue
vWord x = VWord x

toWord :: RValue -> Vector RME
toWord (VWord x) = x
toWord (VVector vv) = fmap (toBool . runIdentity . force) vv
toWord x = error $ unwords ["Verifier.SAW.Simulator.RME.toWord", show x]

vStream :: IntTrie RValue -> RValue
vStream x = VExtra (AStream x)

toStream :: RValue -> IntTrie RValue
toStream (VExtra (AStream x)) = x
toStream x = error $ unwords ["Verifier.SAW.Simulator.RME.toStream", show x]

wordFun :: (Vector RME -> RValue) -> RValue
wordFun f = pureFun (\x -> f (toWord x))

genShift :: (a -> b -> b -> b) -> (b -> Integer -> b) -> b -> Vector a -> b
genShift cond f x0 v = go x0 (V.toList v)
  where
    go x [] = x
    go x (y : ys) = go (cond y (f x (2 ^ length ys)) x) ys

-- | op :: (w :: Nat) -> bitvector w -> Nat -> bitvector w;
bvShiftOp :: (Vector RME -> Integer -> Vector RME) -> RValue
bvShiftOp op =
  constFun $
  wordFun $ \x ->
  pureFun $ \y ->
    case y of
      VNat n   -> vWord (op x n)
      VToNat v -> vWord (genShift muxRMEV op x (toWord v))
      _        -> error $ unwords ["Verifier.SAW.Simulator.RME.shiftOp", show y]

------------------------------------------------------------

pure1 :: Applicative f => (a -> b) -> a -> f b
pure1 f x = pure (f x)

pure2 :: Applicative f => (a -> b -> c) -> a -> b -> f c
pure2 f x y = pure (f x y)

pure3 :: Applicative f => (a -> b -> c -> d) -> a -> b -> c -> f d
pure3 f x y z = pure (f x y z)

prims :: Prims.BasePrims ReedMuller
prims =
  Prims.BasePrims
  { Prims.bpAsBool  = RME.isBool
  , Prims.bpUnpack  = Identity
  , Prims.bpPack    = Identity
  , Prims.bpBvAt    = pure2 (V.!)
  , Prims.bpBvLit   = pure2 RMEV.integer
  , Prims.bpBvSize  = V.length
  , Prims.bpBvJoin  = pure2 (V.++)
  , Prims.bpBvSlice = pure3 V.slice
    -- Conditionals
  , Prims.bpMuxBool  = pure3 RME.mux
  , Prims.bpMuxWord  = pure3 muxRMEV
  , Prims.bpMuxInt   = pure3 muxInt
  , Prims.bpMuxExtra = pure3 muxExtra
    -- Booleans
  , Prims.bpTrue   = RME.true
  , Prims.bpFalse  = RME.false
  , Prims.bpNot    = pure1 RME.compl
  , Prims.bpAnd    = pure2 RME.conj
  , Prims.bpOr     = pure2 RME.disj
  , Prims.bpXor    = pure2 RME.xor
  , Prims.bpBoolEq = pure2 RME.iff
    -- Bitvector logical
  , Prims.bpBvNot  = pure1 undefined
  , Prims.bpBvAnd  = pure2 (V.zipWith RME.conj)
  , Prims.bpBvOr   = pure2 (V.zipWith RME.disj)
  , Prims.bpBvXor  = pure2 (V.zipWith RME.xor)
    -- Bitvector arithmetic
  , Prims.bpBvNeg  = pure1 RMEV.neg
  , Prims.bpBvAdd  = pure2 RMEV.add
  , Prims.bpBvSub  = pure2 RMEV.sub
  , Prims.bpBvMul  = pure2 RMEV.mul
  , Prims.bpBvUDiv = pure2 RMEV.udiv
  , Prims.bpBvURem = pure2 RMEV.urem
  , Prims.bpBvSDiv = pure2 RMEV.sdiv
  , Prims.bpBvSRem = pure2 RMEV.srem
  , Prims.bpBvLg2  = undefined--pure1 Prim.bvLg2
    -- Bitvector comparisons
  , Prims.bpBvEq   = pure2 RMEV.eq
  , Prims.bpBvsle  = pure2 RMEV.sle
  , Prims.bpBvslt  = pure2 RMEV.sle
  , Prims.bpBvule  = pure2 RMEV.ule
  , Prims.bpBvult  = pure2 RMEV.ult
  , Prims.bpBvsge  = pure2 (flip RMEV.sle)
  , Prims.bpBvsgt  = pure2 (flip RMEV.slt)
  , Prims.bpBvuge  = pure2 (flip RMEV.ule)
  , Prims.bpBvugt  = pure2 (flip RMEV.ult)
    -- Bitvector shift/rotate
  , Prims.bpBvRolInt = pure2 Prims.vRotateL
  , Prims.bpBvRorInt = pure2 Prims.vRotateR
  , Prims.bpBvShlInt = pure3 Prims.vShiftL
  , Prims.bpBvShrInt = pure3 Prims.vShiftR
  , Prims.bpBvRol    = pure2 (genShift muxRMEV Prims.vRotateL)
  , Prims.bpBvRor    = pure2 (genShift muxRMEV Prims.vRotateR)
  , Prims.bpBvShl    = pure3 (genShift muxRMEV . Prims.vShiftL)
  , Prims.bpBvShr    = pure3 (genShift muxRMEV . Prims.vShiftR)
    -- Integer operations
  , Prims.bpIntAdd = pure2 (+)
  , Prims.bpIntSub = pure2 (-)
  , Prims.bpIntMul = pure2 (*)
  , Prims.bpIntDiv = pure2 div
  , Prims.bpIntMod = pure2 mod
  , Prims.bpIntNeg = pure1 negate
  , Prims.bpIntEq  = pure2 (\x y -> RME.constant (x == y))
  , Prims.bpIntLe  = pure2 (\x y -> RME.constant (x <= y))
  , Prims.bpIntLt  = pure2 (\x y -> RME.constant (x < y))
  , Prims.bpIntMin = undefined--pure2 min
  , Prims.bpIntMax = undefined--pure2 max
  }

constMap :: Map Ident RValue
constMap =
  Map.union (Prims.constMap prims) $
  Map.fromList
  [ ("Prelude.bvShl" , bvShiftOp (Prims.vShiftL RME.false))
  , ("Prelude.bvShr" , bvShiftOp (Prims.vShiftR RME.false))
  , ("Prelude.bvSShr", bvShiftOp vSignedShiftR)
  -- Integers
  , ("Prelude.intToNat", Prims.intToNatOp)
  , ("Prelude.natToInt", Prims.natToIntOp)
  , ("Prelude.intToBv" , intToBvOp)
  , ("Prelude.bvToInt" , bvToIntOp)
  , ("Prelude.sbvToInt", sbvToIntOp)
  -- Streams
  , ("Prelude.MkStream", mkStreamOp)
  , ("Prelude.streamGet", streamGetOp)
  , ("Prelude.bvStreamGet", bvStreamGetOp)
  -- Miscellaneous
  , ("Prelude.bvToNat", Prims.bvToNatOp)
  ]

-- primitive bvToInt :: (n::Nat) -> bitvector n -> Integer;
bvToIntOp :: RValue
bvToIntOp = undefined -- constFun $ wordFun $ VInt . unsigned

-- primitive sbvToInt :: (n::Nat) -> bitvector n -> Integer;
sbvToIntOp :: RValue
sbvToIntOp = undefined -- constFun $ wordFun $ VInt . signed

-- primitive intToBv :: (n::Nat) -> Integer -> bitvector n;
intToBvOp :: RValue
intToBvOp =
  Prims.natFun' "intToBv n" $ \n -> return $
  Prims.intFun "intToBv x" $ \x -> return $
    VWord (V.reverse (V.generate (fromIntegral n) (RME.constant . testBit x)))

muxRMEV :: RME -> Vector RME -> Vector RME -> Vector RME
muxRMEV b = V.zipWith (RME.mux b)

muxInt :: RME -> Integer -> Integer -> Integer
muxInt b x y =
  case RME.isBool b of
    Just c -> if c then x else y
    Nothing -> if x == y then x else error $ "muxRValue: VInt " ++ show (x, y)

muxExtra :: RME -> RExtra -> RExtra -> RExtra
muxExtra b (AStream xs) (AStream ys) = AStream (muxRValue b <$> xs <*> ys)

muxRValue :: RME -> RValue -> RValue -> RValue
muxRValue b x y = runIdentity $ Prims.muxValue prims b x y

-- | Signed shift right simply copies the high order bit
--   into the shifted places.  We special case the zero
--   length vector to avoid a possible out-of-bounds error.
vSignedShiftR :: V.Vector a -> Integer -> V.Vector a
vSignedShiftR xs i
  | V.length xs > 0 = Prims.vShiftR x xs i
  | otherwise       = xs
 where x = xs V.! 0

----------------------------------------

-- MkStream :: (a :: sort 0) -> (Nat -> a) -> Stream a;
mkStreamOp :: RValue
mkStreamOp =
  constFun $
  pureFun $ \f ->
  vStream (fmap (\n -> runIdentity (apply f (ready (VNat n)))) IntTrie.identity)

-- streamGet :: (a :: sort 0) -> Stream a -> Nat -> a;
streamGetOp :: RValue
streamGetOp =
  constFun $
  pureFun $ \xs ->
  Prims.natFun'' "streamGetOp" $ \n -> return $
  IntTrie.apply (toStream xs) n

-- bvStreamGet :: (a :: sort 0) -> (w :: Nat) -> Stream a -> bitvector w -> a;
bvStreamGetOp :: RValue
bvStreamGetOp =
  constFun $
  constFun $
  pureFun $ \_xs ->
  wordFun $ \_i ->
  error "bvStreamGetOp"
  --IntTrie.apply (toStream xs) (Prim.unsigned i)

------------------------------------------------------------
-- Generating variables for arguments

newVars :: FiniteType -> State Int RValue
newVars FTBit = do
  i <- get
  put (i + 1)
  return (vBool (RME.lit i))
newVars (FTVec n t) = VVector <$> V.replicateM (fromIntegral n) (newVars' t)
newVars (FTTuple ts) = vTuple <$> traverse newVars' ts
newVars (FTRec tm) = vRecord <$> traverse newVars' tm

newVars' :: FiniteType -> State Int RThunk
newVars' shape = ready <$> newVars shape

------------------------------------------------------------
-- Bit-blasting primitives.

bitBlastBasic :: ModuleMap
              -> Map Ident RValue
              -> Term
              -> RValue
bitBlastBasic m addlPrims t = runIdentity $ do
  cfg <- Sim.evalGlobal m (Map.union constMap addlPrims)
         (\_varidx name _ty -> error ("RME: unsupported ExtCns: " ++ name))
         (const (const Nothing))
  Sim.evalSharedTerm cfg t

asPredType :: SharedContext -> Term -> IO [Term]
asPredType sc t = do
  t' <- scWhnf sc t
  case t' of
    (R.asPi -> Just (_, t1, t2)) -> (t1 :) <$> asPredType sc t2
    (R.asBoolType -> Just ())    -> return []
    _                            -> fail $ "Verifier.SAW.Simulator.BitBlast.asPredType: non-boolean result type: " ++ showTerm t'

withBitBlastedPred ::
  SharedContext ->
  Map Ident RValue ->
  Term ->
  (RME -> [FiniteType] -> IO a) -> IO a
withBitBlastedPred sc addlPrims t c = do
  ty <- scTypeOf sc t
  argTs <- asPredType sc ty
  shapes <- traverse (asFiniteType sc) argTs
  modmap <- scGetModuleMap sc
  let vars = evalState (traverse newVars' shapes) 0
  let bval = bitBlastBasic modmap addlPrims t
  let bval' = runIdentity $ applyAll bval vars
  case bval' of
    VBool anf -> c anf shapes
    _ -> fail "Verifier.SAW.Simulator.RME.bitBlast: non-boolean result type."
