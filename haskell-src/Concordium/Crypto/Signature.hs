{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving, ForeignFunctionInterface , TypeFamilies  #-}
-- |This module provides a prototype implementation of 
-- EDDSA scheme of Curve Ed25519 
--  IRTF RFC 8032
module Concordium.Crypto.Signature(
    SignKey,
    VerifyKey,
    KeyPair(..),
    Signature,
    test,
    randomKeyPair,
    newKeyPair,
    sign,
    verify,
    Ed25519
   --emptySignature
) where

import           Concordium.Crypto.ByteStringHelpers
import           Text.Printf
import           Data.IORef
import           Data.ByteString.Internal   (create, toForeignPtr)
import           Data.Word
import           System.IO.Unsafe
import           Foreign.Ptr
import           Foreign.ForeignPtr
import qualified Concordium.Crypto.SHA256 as Hash
import qualified Data.ByteString.Lazy as L
import           Data.Serialize
import qualified Data.ByteString  as B
import           Data.ByteString (ByteString) 
import           Data.ByteString.Builder
import qualified Data.FixedByteString as FBS
import           Data.Word
import           System.Random
import           Foreign.Marshal.Array
import           Foreign.Marshal.Alloc
import           Foreign.C.Types
import           Concordium.Crypto.SignatureScheme (SignatureScheme, SignatureScheme_, SchemeId)
import qualified Concordium.Crypto.SignatureScheme as S 


foreign import ccall "eddsa_priv_key" c_priv_key :: Ptr Word8 -> IO CInt
foreign import ccall "eddsa_pub_key" c_public_key :: Ptr Word8 -> Ptr Word8 -> IO ()
foreign import ccall "eddsa_sign" c_sign :: Ptr Word8 -> Word32 -> Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> IO ()
foreign import ccall "eddsa_verify" c_verify :: Ptr Word8 -> Word32 -> Ptr Word8 -> Ptr Word8 -> IO CInt


signKeySize :: Int
signKeySize = 32
verifyKeySize :: Int
verifyKeySize = 32
signatureSize :: Int
signatureSize = 64

data SignKeySize
instance FBS.FixedLength SignKeySize where
    fixedLength _ = signKeySize

data VerifyKeySize
instance FBS.FixedLength VerifyKeySize where
    fixedLength _ = verifyKeySize

data SignatureSize
instance FBS.FixedLength SignatureSize where
    fixedLength _ = signatureSize


-- |Signature private key.  32 bytes
data SignKey = SignKey (FBS.FixedByteString SignKeySize)
    deriving (Eq)
instance Serialize SignKey where
    put (SignKey key) = putByteString $ FBS.toByteString key
    get = SignKey . FBS.fromByteString <$> getByteString signKeySize
instance Show SignKey where
    show (SignKey sk) = byteStringToHex $ FBS.toByteString sk


-- |Signature public (verification) key. 32 bytes
data VerifyKey = VerifyKey (FBS.FixedByteString VerifyKeySize)
    deriving (Eq, Ord)
instance Serialize VerifyKey where
    put (VerifyKey key) = putByteString $ FBS.toByteString key
    get = VerifyKey . FBS.fromByteString <$> getByteString verifyKeySize
instance Show VerifyKey where
    show (VerifyKey vk) = byteStringToHex $ FBS.toByteString vk

-- |Signature. 64 bytes
newtype Signature = Signature (FBS.FixedByteString SignatureSize)
    deriving (Eq)

instance Serialize Signature where
    put (Signature sig) = putByteString $ FBS.toByteString sig
    get = Signature . FBS.fromByteString <$> getByteString signatureSize
instance Show Signature where
    show (Signature sig) = byteStringToHex $ FBS.toByteString sig

data KeyPair = KeyPair {
    signKey :: SignKey,
    verifyKey :: VerifyKey
} deriving (Eq, Show)
instance Serialize KeyPair where
    put (KeyPair sk vk) = put sk >> put vk
    get = do
        sk <- get
        vk <- get
        return $ KeyPair sk vk

newPrivKey :: IO SignKey
newPrivKey =
     do suc <- newIORef (0::Int)
        sk <- FBS.create $ \priv ->
            do rc <-  c_priv_key priv
               case rc of
                    1 ->  do writeIORef suc 1
                    _ ->  do writeIORef suc 0
        suc' <- readIORef suc
        case suc' of
            1 -> return (SignKey sk)
            _ -> error "Private key generation failed"

pubKey :: SignKey -> IO VerifyKey
pubKey (SignKey sk) = do pk <- FBS.create $ \pub -> 
                                 FBS.withPtr sk $ \y -> c_public_key y pub
                         return (VerifyKey pk)

randomKeyPair :: RandomGen g => g -> (KeyPair, g)
randomKeyPair gen = (key, gen')
        where
            (gen0, gen') = split gen
            privKey = SignKey $ FBS.pack $ randoms gen0
            key = KeyPair privKey (unsafePerformIO $ pubKey privKey)


newKeyPair :: IO KeyPair
newKeyPair = do sk <- newPrivKey
                pk <- pubKey sk
                return (KeyPair sk pk)

sign :: KeyPair -> ByteString -> Signature
sign (KeyPair (SignKey sk) (VerifyKey pk)) m = Signature $ FBS.unsafeCreate $ \sig ->
       withByteStringPtr m $ \m' -> 
          FBS.withPtr pk $ \pk' ->
             FBS.withPtr sk $ \sk' ->
                c_sign m' mlen sk' pk' sig 
   where
       mlen = fromIntegral $ B.length m


verify :: VerifyKey -> ByteString -> Signature -> Bool
verify (VerifyKey pk) m (Signature sig) =  suc > -1
   where
       mlen = fromIntegral $ B.length m
       suc  = unsafeDupablePerformIO $ 
           withByteStringPtr m $ \m'->
                 FBS.withPtr pk $ \pk'->
                    FBS.withPtr sig $ \sig' ->
                       c_verify m' mlen pk' sig'



test :: IO ()
test = do kp@(KeyPair sk pk) <- newKeyPair
          putStrLn ("SK: " ++ show sk)
          putStrLn ("PK: " ++ show pk)
          putStrLn("MESSAGE:")
          alpha <- B.getLine
          let sig = sign kp alpha
              suc = verify pk alpha sig
           in
              putStrLn ("signature: " ++ show sig) >>
              putStrLn ("Good?: " ++ if suc then "YES" else "NO")



data Ed25519
instance SignatureScheme_ Ed25519 where
    data VerifyKey Ed25519    = Ed25519_PK (FBS.FixedByteString VerifyKeySize)
    data SignKey Ed25519      = Ed25519_SK (FBS.FixedByteString SignKeySize)
    data Signature Ed25519    = Ed25519_Sig (FBS.FixedByteString SignatureSize)
    generatePrivateKey        = unsafePerformIO $ do (SignKey x) <- newPrivKey
                                                     return (Ed25519_SK x)
    publicKey (Ed25519_SK x) = unsafePerformIO $ do (VerifyKey y) <- pubKey (SignKey x)
                                                    return (Ed25519_PK y)
    sign (Ed25519_SK x) (Ed25519_PK y) b = let (Signature s ) = sign KeyPair{signKey=(SignKey x), verifyKey=(VerifyKey y)} b
                                           in (Ed25519_Sig s)
    verify (Ed25519_PK x) b (Ed25519_Sig s) = verify (VerifyKey x) b (Signature s)
    schemeId _ = S.SchemeId (fromIntegral 2)
    putVerifyKey (Ed25519_PK s) = putByteString $ FBS.toByteString s
    getVerifyKey  = Ed25519_PK . FBS.fromByteString <$> getByteString verifyKeySize
    putSignKey (Ed25519_SK s) = putByteString $ FBS.toByteString s
    getSignKey  = Ed25519_SK . FBS.fromByteString <$> getByteString signKeySize
    signKeyEq (Ed25519_SK sk0) (Ed25519_SK sk1) = sk0==sk1   
    verifyKeyEq (Ed25519_PK pk0) (Ed25519_PK pk1) = pk0==pk1   


