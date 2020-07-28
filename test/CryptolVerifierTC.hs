{-# LANGUAGE ImplicitParams #-}

module Main where

import qualified Data.ByteString as BS
import qualified Data.Map as Map

import qualified Cryptol.ModuleSystem.Name as N
import qualified Cryptol.Utils.Ident as N

import qualified Verifier.SAW.Cryptol as C
import           Verifier.SAW.SharedTerm
import qualified Verifier.SAW.SCTypeCheck as TC
import qualified Verifier.SAW.Cryptol.Prelude as C
import qualified Verifier.SAW.CryptolEnv as CEnv

main :: IO ()
main =
  do sc <- mkSharedContext
     C.scLoadPreludeModule sc
     C.scLoadCryptolModule sc
     putStrLn "Loaded Cryptol.sawcore!"
     let ?fileReader = BS.readFile
     cenv <- CEnv.initCryptolEnv sc
     putStrLn "Translated Cryptol.cry!"
     mapM_ (checkTranslation sc) $ Map.assocs (CEnv.eTermEnv cenv)
     putStrLn "Checked all terms!"

checkTranslation :: SharedContext -> (N.Name, Term) -> IO ()
checkTranslation sc (name, term) =
  do result <- TC.scTypeCheck sc Nothing term
     case result of
       Right _ -> pure ()
       Left err ->
         do putStrLn $ "Type error when checking " ++ show (N.unpackIdent (N.nameIdent name))
            putStrLn $ unlines $ TC.prettyTCError err
            fail "internal type error"
