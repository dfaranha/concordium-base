{-# LANGUAGE ForeignFunctionInterface , GeneralizedNewtypeDeriving, DerivingVia, OverloadedStrings #-}

module Concordium.Crypto.SHA256 where
import           Concordium.Crypto.ByteStringHelpers
import           Data.ByteString            (ByteString)
import           Data.ByteString.Short(ShortByteString)
import qualified Data.ByteString.Unsafe as B
import qualified Data.ByteString.Lazy       as L
import           Foreign.Ptr
import           Foreign.ForeignPtr
import           Data.Word
import           System.IO.Unsafe
import           Control.Monad
import           Data.Serialize
import           Data.Hashable               
import           Data.Bits
import qualified Data.FixedByteString       as FBS
import           Data.FixedByteString       (FixedByteString)
import           Text.Read
import           Data.Char

data SHA256Ctx

foreign import ccall unsafe "sha256_new"
   rs_sha256_init :: IO (Ptr SHA256Ctx)

foreign import ccall unsafe "&sha256_free"
   rs_sha256_free :: FunPtr (Ptr SHA256Ctx -> IO ())

foreign import ccall unsafe "sha256_input"
   rs_sha256_update :: Ptr SHA256Ctx -> Ptr Word8 -> Word32 -> IO ()

foreign import ccall unsafe "sha256_result"
   rs_sha256_final :: Ptr Word8 -> Ptr SHA256Ctx -> IO ()


createSha256Ctx :: IO (Maybe (ForeignPtr SHA256Ctx))
createSha256Ctx = do
  ptr <- rs_sha256_init
  if ptr /= nullPtr
    then do
      foreignPtr <- newForeignPtr_ ptr
      return $ Just foreignPtr
    else
      return Nothing

digestSize :: Int
digestSize = 32

data DigestSize

instance FBS.FixedLength DigestSize where
    fixedLength _ = digestSize

-- |A SHA256 hash.  32 bytes.
newtype Hash = Hash (FBS.FixedByteString DigestSize)
  deriving (Eq, Ord, Bits, Bounded, Enum)
  deriving Serialize via FBSHex DigestSize
  deriving Show via FBSHex DigestSize

instance Read Hash where
    readPrec = Hash . FBS.pack <$> mapM (const readHexByte) [1..digestSize]
        where
            readHexByte = do
                ms <- nibble =<< Text.Read.get
                ls <- nibble =<< Text.Read.get
                return (shiftL ms 4 .|. ls)
            nibble c
                | '0' <= c && c <= '9' = return (fromIntegral $ ord c - ord '0')
                | 'a' <= c && c <= 'f' = return (fromIntegral $ ord c - ord 'a' + 10)
                | 'A' <= c && c <= 'F' = return (fromIntegral $ ord c - ord 'A' + 10)
                | otherwise = mzero
    readListPrec = readListPrecDefault

instance Hashable Hash where
    hashWithSalt s (Hash b) = hashWithSalt s (FBS.toShortByteString b)
    hash (Hash b) = fromIntegral (FBS.unsafeReadWord64 b)

hash :: ByteString -> Hash
hash b = Hash $ unsafeDupablePerformIO $
                   do maybe_ctx <- createSha256Ctx
                      case maybe_ctx of
                        Nothing -> error "Failed to initialize hash"
                        Just ctx_ptr -> withForeignPtr ctx_ptr $ \ctx -> do
                          hash_update b ctx
                          hash_final ctx

hashShort :: ShortByteString -> Hash
hashShort b = Hash $ unsafeDupablePerformIO $
              do maybe_ctx <- createSha256Ctx
                 case maybe_ctx of
                   Nothing -> error "Failed to initialize hash"
                   Just ctx_ptr ->
                     withForeignPtr ctx_ptr $ \ctx -> do
                        hash_update_short b ctx 
                        hash_final ctx


hash_update :: ByteString -> Ptr SHA256Ctx ->  IO ()
hash_update b ptr = B.unsafeUseAsCStringLen b $
    \(message, mlen) -> rs_sha256_update ptr (castPtr message) (fromIntegral mlen)

hash_update_short :: ShortByteString -> Ptr SHA256Ctx ->  IO ()
hash_update_short b ctx = withByteStringPtrLen b $
    \message mlen -> rs_sha256_update ctx (castPtr message) (fromIntegral mlen)

-- |NB: hash_final deallocates the context pointed to by the first argument.
-- Hence it is impossible to use hash_final twice with the same context.
hash_final :: Ptr SHA256Ctx -> IO (FixedByteString DigestSize)
hash_final ptr = FBS.create $ \hsh -> rs_sha256_final hsh ptr

hashLazy :: L.ByteString -> Hash
hashLazy b = Hash $ unsafeDupablePerformIO $
                   do maybe_ctx <- createSha256Ctx
                      case maybe_ctx of
                        Nothing -> error "Failed to initialize hash"
                        Just ctx -> mapM_ (f ctx)  (L.toChunks b) >> 
                                    withForeignPtr ctx ( \ctx' -> hash_final ctx')
           where
             f ptr chunk = withForeignPtr ptr $ \ptr' -> hash_update chunk ptr'

    
hashTest ::FilePath ->  IO ()
hashTest path = do b <- L.readFile path
                   let (Hash b') = hashLazy b
                   putStrLn(byteStringToHex $ FBS.toByteString b')


-- |Convert a 'Hash' into a 'Double' value in the range [0,1].
-- This implementation takes the first 64-bit word (big-endian) and uses it
-- as the significand, with an exponent of -64.  Since the precision of a
-- 'Double' is only 53 bits, there is inevitably some loss.  This also means
-- that the outcome 1 is not possible.
hashToDouble :: Hash -> Double
hashToDouble (Hash h) =
    let w = FBS.unsafeReadWord64 h in
    encodeFloat (toInteger w) (-64)

-- |Convert a 'Hash' to an 'Int'.
hashToInt :: Hash -> Int
hashToInt (Hash h) = fromIntegral . FBS.unsafeReadWord64 $ h

-- |Convert a 'Hash' to a 'ByteString'.
-- Gives the same result a serializing, but more efficient.
hashToByteString :: Hash -> ByteString
hashToByteString (Hash h) = FBS.toByteString h

-- |Convert a 'Hash' to a 'ShortByteString'.
-- Gives the same result a serializing, but more efficient.
-- This is much more efficient than 'hashToByteString'. It involves no copying.
hashToShortByteString :: Hash -> ShortByteString
hashToShortByteString (Hash h) = FBS.toShortByteString h
