{- |A tool for generating update keys and authorizations for
    chain updates.  The generated authorizations can be used
    in genesis data, or used to update the authorizations on
    chain.
-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Monad
import qualified Data.Aeson.Encode.Pretty as AE
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Set as Set
import qualified Data.Vector as Vec
import Data.Word
import Options.Applicative
import System.Exit
import System.FilePath

import Concordium.Crypto.SignatureScheme
import Concordium.Types.Updates

data AuthDetails = AuthDetails {
    adThreshold :: Word16,
    adKeys :: [Word16]
} deriving (Show)

-- Reads "x:y,z,u" as AuthDetails x [y,z,u]
readAuthDetails :: ReadM AuthDetails
readAuthDetails = maybeReader $ \s -> case reads s of
    [(adThreshold, ':':r)] -> case reads ("[" ++ r ++ "]") of
        [(adKeys, "")] -> Just AuthDetails{..}
        _ -> Nothing
    _ -> Nothing

data HigherAuthDetails = HigherAuthDetails {
  hadThreshold :: Word16,
  hadNumKeys :: Word16
  } deriving (Show)

-- reads "x:y" as HigherLevelKeys x y
readHigherAuthDetails :: ReadM HigherAuthDetails
readHigherAuthDetails = maybeReader $ \s -> case reads s of
  [(hadThreshold, ':':r)] -> case reads r of
    [(hadNumKeys, "")] -> Just HigherAuthDetails{..}
    _ -> Nothing
  _ -> Nothing

data GenerateUpdateKeys
    = GenerateUpdateKeys {
        -- |Number of keys to generate
        gukKeyCount :: Word16,
        -- |Name of authorization file to generate
        gukAuthorizationFile :: FilePath,
        -- |Directory to generate key files
        gukKeyPath :: FilePath,
        -- |Threshold and number of root keys to generate
        gukRootKeys :: HigherAuthDetails,
        -- |Threshold and number of level 1 keys to generate
        gukLevel1Keys :: HigherAuthDetails,
        -- |Key indices (and thresholds) to use for each update type
        gukEmergency :: AuthDetails,
        gukProtocol :: AuthDetails,
        gukElectionDifficulty :: AuthDetails,
        gukEuroEnergy :: AuthDetails,
        gukGTUEuro :: AuthDetails,
        gukFoundationAccount :: AuthDetails,
        gukMintDistribution :: AuthDetails,
        gukTransactionFeeDistribution :: AuthDetails,
        gukGASRewards :: AuthDetails,
        gukBakerStakeThreshold :: AuthDetails,
        gukAddAnonymityRevoker :: AuthDetails,
        gukAddIdentityProvider :: AuthDetails
    } deriving (Show)

readKeyList :: ReadM [Word16]
readKeyList = maybeReader $ \s -> case reads ("[" ++ s ++ "]") of
    ((l, "") : _) -> Just l
    _ -> Nothing

parameters :: Parser GenerateUpdateKeys
parameters = GenerateUpdateKeys
    <$> argument auto (metavar "NUM" <> help "Number of level 2 keys to generate")
    <*> strOption (metavar "FILE" <> long "keys-outfile" <> help "File name for generated authorization" <> value "update-keys.json" <> showDefault)
    <*> strOption (metavar "PATH" <> long "keys-outdir" <> help "Path to output generated keys" <> value "." <> showDefault)
    <*> option readHigherAuthDetails (metavar "HACSTR" <> long "root-keys" <> help "Threshold and number of root keys to generate")
    <*> option readHigherAuthDetails (metavar "HACSTR" <> long "level1-keys" <> help "Threshold and number of level 1 keys to generate")
    <*> option readAuthDetails (metavar "ACSTR" <> long "emergency" <> help "Emergency update access structure")
    <*> option readAuthDetails (metavar "ACSTR" <> long "protocol" <> help "Protocol update access structure")
    <*> option readAuthDetails (metavar "ACSTR" <> long "election" <> help "Election difficulty update access structure")
    <*> option readAuthDetails (metavar "ACSTR" <> long "euro-energy" <> help "Euro:energy rate update access structure")
    <*> option readAuthDetails (metavar "ACSTR" <> long "gtu-euro" <> help "GTU:Euro rate update access structure")
    <*> option readAuthDetails (metavar "ACSTR" <> long "foundation-account" <> help "Foundation account update access structure")
    <*> option readAuthDetails (metavar "ACSTR" <> long "mint-distribution" <> help "Mint distribution update access structure")
    <*> option readAuthDetails (metavar "ACSTR" <> long "fee-distribution" <> help "Transaction fee distribution update access structure")
    <*> option readAuthDetails (metavar "ACSTR" <> long "gas-rewards" <> help "GAS rewards update access structure")
    <*> option readAuthDetails (metavar "ACSTR" <> long "baker-minimum-threshold" <> help "Baker minimum threshold access structure")
    <*> option readAuthDetails (metavar "ACSTR" <> long "add-anonymity-revoker" <> help "Add anonymity revoker access structure")
    <*> option readAuthDetails (metavar "ACSTR" <> long "add-identity-provider" <> help "Add identity provider access structure")

main :: IO ()
main = customExecParser p opts >>= generateKeys
    where
        opts = info (parameters <**> helper) $
            header "Generate keys for updates on the Concordium block chain."
            <> progDesc "Generate a set of keypairs and an authorization structure for chain updates. \
                        \An authorization structure determines which keys are required for performing \
                        \each kind of chain update. An authorization structure is required at genesis \
                        \and may subsequently be replaced in an authorization update."
            <> footer "HACSTR for root and level 1 keys should be entered in the form: THRESHOLD:NUMBER-OF-KEYS. ACSTR for level 2 keys should be \
                        \entered in the form: THRESHOLD:KEY1,KEY2,...,KEYn. THRESHOLD is \
                        \the minimum number of keys that are required to authorize the update (and must \
                        \be at most n). The level 2 keys are specified by 0-based index, and so must be less than \
                        \NUM (the total number of keys being generated). Root and level 1 keys will be generated separatedly from \
                        \ the level 2 keys, thus not being counted in the total number of generated keys."
        p = prefs showHelpOnEmpty

generateKeys :: GenerateUpdateKeys -> IO ()
generateKeys GenerateUpdateKeys{..} = do
        when (gukKeyCount == 0) $ die "At least one level 2 key is required."
        asEmergency <- makeAS gukEmergency "Emergency update access structure"
        asProtocol <- makeAS gukProtocol "Protocol update access structure"
        asParamElectionDifficulty <- makeAS gukElectionDifficulty "Election difficulty update access structure"
        asParamEuroPerEnergy <- makeAS gukEuroEnergy "Euro-energy rate update access structure"
        asParamMicroGTUPerEuro <- makeAS gukGTUEuro "GTU-Euro rate update access structure"
        asParamFoundationAccount <- makeAS gukFoundationAccount "Foundation account update access structure"
        asParamMintDistribution <- makeAS gukMintDistribution "Mint distribution update access structure"
        asParamTransactionFeeDistribution <- makeAS gukTransactionFeeDistribution "Transaction fee distribution update access structure"
        asParamGASRewards <- makeAS gukGASRewards "GAS rewards update access structure"
        asBakerStakeThreshold <- makeAS gukBakerStakeThreshold "Baker minimum threshold access structure"
        asAddAnonymityRevoker <- makeAS gukAddAnonymityRevoker "Add anonymity revoker access structure"
        asAddIdentityProvider <- makeAS gukAddIdentityProvider "Add identity provider access structure"
        putStrLn "Generating keys..."
        asKeys <- Vec.fromList <$> sequence [makeKey k "level2-key" | k <- [0..gukKeyCount-1]]
        rootKeys <- makeHAS gukRootKeys "root-key" "Root key structure"
        level1Keys <- makeHAS gukLevel1Keys "level1-key" "Level 1 key structure"
        let keyCollection = UpdateKeysCollection {level2Keys = Authorizations{..},..}
        LBS.writeFile gukAuthorizationFile (AE.encodePretty' AE.defConfig{AE.confCompare=keyComp} keyCollection)
    where
        keyComp = AE.keyOrder ["keys","emergency","protocol","electionDifficulty","euroPerEnergy","microGTUPerEuro","schemeId"]
                    <> compare
        makeAS AuthDetails{..} desc = do
            let accessPublicKeys = Set.fromList adKeys
                nKeys = Set.size accessPublicKeys
                -- maxKey should only be evaluated after determining accessPublicKeys to have at least one
                -- element
                maxKey = Set.findMax accessPublicKeys
            when (adThreshold < 1) $ die (desc ++ ": threshold must be at least 1")
            when (nKeys < 1) $ die (desc ++ ": number of keys provided must be at least 1")
            when (fromIntegral adThreshold > nKeys) $ die (desc ++ ": threshold (" ++ show adThreshold ++ ") cannot exceed number of keys (" ++ show nKeys ++ ")")
            when (maxKey >= gukKeyCount) $ die (desc ++ ": key index " ++ show maxKey ++ " is out of bounds. Maximal index is " ++ show (gukKeyCount - 1))
            return AccessStructure{accessThreshold= UpdateKeysThreshold adThreshold,..}
        makeHAS HigherAuthDetails{..} name desc = do
          when (hadThreshold > hadNumKeys) $ die (desc ++ ": threshold (" ++ show hadThreshold ++ ") cannot exceed number of keys (" ++ show hadNumKeys ++ ")")
          hlkKeys <- Vec.fromList <$> sequence [ makeKey k name | k <- [0..hadNumKeys-1] ]
          return HigherLevelKeys{hlkThreshold = UpdateKeysThreshold hadThreshold,..}
        makeKey k desc = do
            kp <- newKeyPair Ed25519
            LBS.writeFile (gukKeyPath </> (desc ++ "-" ++ show k ++ ".json")) (AE.encodePretty' AE.defConfig{AE.confCompare=keyComp} kp)
            return (correspondingVerifyKey kp)
