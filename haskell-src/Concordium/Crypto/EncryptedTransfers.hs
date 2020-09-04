{-| This module provides the necessary primitives for encrypted amount transfers. -}
{-# LANGUAGE DerivingStrategies, DerivingVia, StandaloneDeriving #-}
module Concordium.Crypto.EncryptedTransfers (
  -- * Encrypted amount
  EncryptedAmount(..),
  aggregateAmounts,

  -- * Encrypted indices
  EncryptedAmountAggIndex(..),
  EncryptedAmountIndex(..),
  addToAggIndex,

  -- * Aggregated decrypted amount
  AggregatedDecryptedAmount,
  makeAggregatedDecryptedAmount,
  withAggregatedDecryptedAmount,

  -- * Public to secret transfer
  encryptAmountZeroRandomness,

  -- * Encrypted transfer
  EncryptedAmountTransferData(..),
  EncryptedAmountTransferProof,
  getEncryptedAmountTransferProof,
  putEncryptedAmountTransferProof,
  makeEncryptedAmountTransferData,
  verifyEncryptedTransferProof,

  -- * Secret to public transfer
  SecToPubAmountTransferData(..),
  SecToPubAmountTransferProof,
  getSecToPubAmountTransferProof,
  putSecToPubAmountTransferProof,
  makeSecToPubAmountTransferData,
  verifySecretToPublicTransferProof,

  -- * Decryption of encrypted amounts.
  computeTable,
  decryptAmount,
  encryptAmount
  ) where

import Data.Serialize
import Data.Word
import Data.Aeson
import Foreign.Ptr
import Data.ByteString.Short
import Foreign.Marshal (alloca)
import Foreign.Storable (peek)
import System.IO.Unsafe (unsafeDupablePerformIO)
import Data.Foldable(foldl')

import Foreign (newForeignPtr, withForeignPtr, ForeignPtr)
import Foreign (Storable)
import Foreign.C.Types (CChar)
import Foreign.C (CStringLen)

import Concordium.Crypto.FFIDataTypes
import Concordium.Crypto.FFIHelpers
import Concordium.Crypto.ByteStringHelpers
import Concordium.ID.Parameters
import Concordium.ID.Types
import Concordium.Common.Amount

-- Note: The FFI functions imported in this file are defined in encrypted_transfers/src/ffi.rs

--------------------------------------------------------------------------------
------------------------------- EncryptedAmount --------------------------------
--------------------------------------------------------------------------------

-- | See `EncryptedAmounts` in encrypted_transfers/src/types.rs
data EncryptedAmount = EncryptedAmount{
  -- | Encryption of the high-chunk (highest 32 bits).
  encryptionHigh :: ElgamalCipher,
  -- | Encryption of the low-chunk (lowest 32 bits).
  encryptionLow :: ElgamalCipher
  }
  deriving (Show, FromJSON, ToJSON) via Base16JSONSerialize EncryptedAmount
  deriving(Eq)

instance Serialize EncryptedAmount where
  put EncryptedAmount{..} = put encryptionLow <> put encryptionHigh
  get = do
    encryptionLow <- get
    encryptionHigh <- get
    return EncryptedAmount{..}

instance Semigroup EncryptedAmount where
  (<>) = aggregateAmounts

instance Monoid EncryptedAmount where
  mempty = EncryptedAmount zeroElgamalCipher zeroElgamalCipher
  -- mconcat is redefined for efficiency reasons. The default implemenation uses
  -- foldr, which is bad in this case since `aggregateAmounts` is strict in the
  -- second argument.
  mconcat [] = mempty
  mconcat (x:xs) = foldl' aggregateAmounts x xs

-- | Aggregate two encrypted amounts together.
foreign import ccall unsafe "aggregate_encrypted_amounts"
  aggregate_encrypted_amounts ::
     Ptr ElgamalCipher -- ^ High chunk of the first amount.
     -> Ptr ElgamalCipher -- ^ Low chunk of the first amount.
     -> Ptr ElgamalCipher -- ^ High chunk of the second amount.
     -> Ptr ElgamalCipher -- ^ Low chunk of the second amount.
     -> Ptr (Ptr ElgamalCipher) -- ^ Place to write the pointer to the high chunk of the result.
     -> Ptr (Ptr ElgamalCipher) -- ^ Place to write the pointer to the low chunk of the result.
     -> IO ()

-- |Aggregate two encrypted amounts together. This operation is strict and
-- associative.
aggregateAmounts :: EncryptedAmount -> EncryptedAmount -> EncryptedAmount
aggregateAmounts left right = unsafeDupablePerformIO $ do
  withElgamalCipher (encryptionHigh left) $ \leftHighPtr ->
    withElgamalCipher (encryptionLow left) $ \leftLowPtr ->
      withElgamalCipher (encryptionHigh right) $ \rightHighPtr ->
        withElgamalCipher (encryptionLow right) $ \rightLowPtr ->
          alloca $ \outHighPtr ->
            alloca $ \outLowPtr -> do
              aggregate_encrypted_amounts leftHighPtr leftLowPtr rightHighPtr rightLowPtr outHighPtr outLowPtr
              outHigh <- unsafeMakeCipher =<< peek outHighPtr
              outLow <- unsafeMakeCipher =<< peek outLowPtr
              return EncryptedAmount{encryptionHigh = outHigh, encryptionLow = outLow}

--------------------------------------------------------------------------------
-------------------------- Encrypted aggregated index --------------------------
--------------------------------------------------------------------------------

-- |An indexed used to determine which encryped amounts were used in a transaction.
newtype EncryptedAmountAggIndex = EncryptedAmountAggIndex {theAggIndex :: Word64}
    deriving newtype (Eq, Show, Ord, FromJSON, ToJSON, Num, Integral, Real, Enum, Storable, Serialize)

--------------------------------------------------------------------------------
---------------------------- Encrypted amount index ----------------------------
--------------------------------------------------------------------------------

-- |An individual index of an encrypted amount. This is used when assigning
-- indices for encrypted amounts added to an account.
newtype EncryptedAmountIndex = EncryptedAmountIndex {theIndex :: Word64}
    deriving newtype (Eq, Show, Ord, FromJSON, ToJSON, Num, Integral, Real, Enum, Serialize)

-- |Add an offset to an encrypted amount aggregation index to obtain a new encrypted amount index.
-- It is assume that this will not overflow. The function is still safe in case of overflow,
-- but it will wrap around.
addToAggIndex :: EncryptedAmountAggIndex -> Word -> EncryptedAmountIndex
addToAggIndex (EncryptedAmountAggIndex aggIdx) len = EncryptedAmountIndex (aggIdx + fromIntegral len)

--------------------------------------------------------------------------------
------------------------- Aggregated Encrypted Amount --------------------------
--------------------------------------------------------------------------------

foreign import ccall unsafe "make_aggregated_decrypted_amount" make_aggregated_decrypted_amount ::
  Ptr ElgamalCipher -- ^ High chunk of the encrypted amount
  -> Ptr ElgamalCipher -- ^ Low chunk of the encrypted amount
  -> Word64 -- ^ Amount in plaintext
  -> EncryptedAmountAggIndex -- ^ Index up to which amounts have been aggregated
  -> IO (Ptr AggregatedDecryptedAmount)

foreign import ccall unsafe "&free_aggregated_decrypted_amount" free_aggregated_decrypted_amount ::
  FunPtr (Ptr AggregatedDecryptedAmount -> IO ())

newtype AggregatedDecryptedAmount = AggregatedDecryptedAmount (ForeignPtr AggregatedDecryptedAmount)
withAggregatedDecryptedAmount :: AggregatedDecryptedAmount -> (Ptr AggregatedDecryptedAmount -> IO b) -> IO b
withAggregatedDecryptedAmount (AggregatedDecryptedAmount ptr) = withForeignPtr ptr

makeAggregatedDecryptedAmount :: EncryptedAmount -> Amount -> EncryptedAmountAggIndex -> AggregatedDecryptedAmount
makeAggregatedDecryptedAmount encAmount (Amount amount) idx = unsafeDupablePerformIO $
  withElgamalCipher (encryptionHigh encAmount) $ \enc_hi ->
    withElgamalCipher (encryptionLow encAmount) $ \enc_lo ->
    AggregatedDecryptedAmount <$> (newForeignPtr free_aggregated_decrypted_amount =<< make_aggregated_decrypted_amount enc_hi enc_lo amount idx)

--------------------------------------------------------------------------------
-------------------------- Public to secret transfer ---------------------------
--------------------------------------------------------------------------------

foreign import ccall unsafe "encrypt_amount_with_zero_randomness"
  encrypt_amount_with_zero_randomness ::
    Ptr GlobalContext -- ^ Global context
    -> Word64 -- ^ Amount to be encrypted
    -> Ptr (Ptr ElgamalCipher) -- ^ Place to write the pointer to the high chunk of the result.
    -> Ptr (Ptr ElgamalCipher) -- ^ Place to write the pointer to the low chunk of the result.
    -> IO ()

-- | Encrypt the given amount with zero randomness. To be used in transfer to secret
encryptAmountZeroRandomness :: GlobalContext -> Amount -> EncryptedAmount
encryptAmountZeroRandomness gc (Amount amount) = unsafeDupablePerformIO $
  withGlobalContext gc $ \gcPtr ->
  alloca $ \outHighPtr ->
  alloca $ \outLowPtr -> do
      encrypt_amount_with_zero_randomness gcPtr amount outHighPtr outLowPtr
      outHigh <- unsafeMakeCipher =<< peek outHighPtr
      outLow <- unsafeMakeCipher =<< peek outLowPtr
      return EncryptedAmount{encryptionHigh = outHigh, encryptionLow = outLow}

--------------------------------------------------------------------------------
--------------------------- Encrypted transfer data ----------------------------
--------------------------------------------------------------------------------

foreign import ccall unsafe "make_encrypted_transfer_data" make_encrypted_transfer_data ::
  Ptr GlobalContext -- ^ Pointer to the global context
  -> Ptr ElgamalPublicKey  -- ^ Public key of the receiver
  -> Ptr ElgamalSecretKey -- ^ Secret key of the sender
  -> Ptr AggregatedDecryptedAmount -- ^ Encrypted amount placed for the transfer
  -> Word64 -- ^ Amount that want to be transferred
  -> Ptr (Ptr ElgamalCipher) -- ^ Place to write the high chunk of the remaining amount
  -> Ptr (Ptr ElgamalCipher) -- ^ Place to write the low chunk of the remaining amount
  -> Ptr (Ptr ElgamalCipher) -- ^ Place to write the high chunk of the transfer amount
  -> Ptr (Ptr ElgamalCipher) -- ^ Place to write the low chunk of the transfer amount
  -> Ptr EncryptedAmountAggIndex -- ^ Place to write the index
  -> Ptr Word64 -- ^ Place to write the length of the proof
  -> IO (Ptr CChar) -- ^ Pointer to the proof

-- | Serialized version of `EncryptedAmountTransferProof` in encrypted_transfers/src/types.rs
newtype EncryptedAmountTransferProof = EncryptedAmountTransferProof { theEncryptedAmountTransferProof :: ShortByteString }
  deriving (Eq, Show, FromJSON, ToJSON) via ByteStringHex
  deriving Serialize via Short65K

withEncryptedAmountTransferProof :: EncryptedAmountTransferProof -> (CStringLen -> IO a) -> IO a
withEncryptedAmountTransferProof (EncryptedAmountTransferProof s) = useAsCStringLen s

makeEncryptedAmountTransferProof :: CStringLen -> IO EncryptedAmountTransferProof
makeEncryptedAmountTransferProof c = do
  res <- EncryptedAmountTransferProof <$> packCStringLen c
  rs_free_array_len (castPtr (fst c)) (fromIntegral (snd c))
  return res

-- | Custom serialization functions for proofs which allow us to have the same
-- serialization as in rust, provided enough context, i.e., length.
getEncryptedAmountTransferProof :: Word32 -> Get EncryptedAmountTransferProof
getEncryptedAmountTransferProof len = EncryptedAmountTransferProof <$> getShortByteString (fromIntegral len)

-- |Put the proof directly without the length.
-- The proof can be deserialized in the right contexts using 'getEncryptedAmountTransferProof'
putEncryptedAmountTransferProof :: EncryptedAmountTransferProof -> Put
putEncryptedAmountTransferProof = putShortByteString . theEncryptedAmountTransferProof

-- | Haskell counterpart of `EncryptedAmountTransferData` in encrypted_transfers/src/types.rs
data EncryptedAmountTransferData = EncryptedAmountTransferData {
  eatdRemainingAmount :: !EncryptedAmount,
  eatdTransferAmount :: !EncryptedAmount,
  eatdIndex :: !EncryptedAmountAggIndex,
  eatdProof :: !EncryptedAmountTransferProof
  } deriving (Eq, Show)

withEncryptedAmountTransferData :: EncryptedAmountTransferData
                                -> (Ptr ElgamalCipher -> Ptr ElgamalCipher -> Ptr ElgamalCipher -> Ptr ElgamalCipher -> EncryptedAmountAggIndex -> Word64 -> Ptr CChar -> IO a)
                                -> IO a
withEncryptedAmountTransferData EncryptedAmountTransferData{..} f =
  withElgamalCipher (encryptionHigh eatdRemainingAmount) $ \remaining_high ->
  withElgamalCipher (encryptionLow eatdRemainingAmount) $ \remaining_low ->
  withElgamalCipher (encryptionHigh eatdTransferAmount) $ \transfer_high ->
  withElgamalCipher (encryptionLow eatdTransferAmount) $ \transfer_low ->
  withEncryptedAmountTransferProof eatdProof $ \(bytesPtr, len) -> do
    f remaining_high remaining_low transfer_high transfer_low eatdIndex (fromIntegral len) bytesPtr

makeEncryptedAmountTransferData :: GlobalContext
                                    -> ElgamalPublicKey
                                    -> ElgamalSecretKey
                                    -> AggregatedDecryptedAmount
                                    -> Amount
                                    -> IO (Maybe EncryptedAmountTransferData)
makeEncryptedAmountTransferData gc receiverPk senderSk aggAmount (Amount desiredAmount) =
  withGlobalContext gc $ \gcPtr ->
  withElgamalPublicKey receiverPk $ \receiverPkPtr ->
  withElgamalSecretKey senderSk $ \senderSkPtr ->
  withAggregatedDecryptedAmount aggAmount $ \aggAmountPtr ->
    alloca $ \rem_hi_ptr ->
    alloca $ \rem_lo_ptr ->
    alloca $ \trans_hi_ptr ->
    alloca $ \trans_lo_ptr ->
    alloca $ \idx_ptr ->
    alloca $ \len_ptr -> do
      proof_ptr <- make_encrypted_transfer_data gcPtr receiverPkPtr senderSkPtr aggAmountPtr desiredAmount rem_hi_ptr rem_lo_ptr trans_hi_ptr trans_lo_ptr idx_ptr len_ptr
      if proof_ptr /= nullPtr then do
        rem_hi <- unsafeMakeCipher =<< peek rem_hi_ptr
        rem_lo <- unsafeMakeCipher =<< peek rem_lo_ptr
        trans_hi <- unsafeMakeCipher =<< peek trans_hi_ptr
        trans_lo <- unsafeMakeCipher =<< peek trans_lo_ptr
        idx <- peek idx_ptr
        len <- peek len_ptr
        proof <- makeEncryptedAmountTransferProof (proof_ptr, fromIntegral len)
        return $ Just (EncryptedAmountTransferData {
          eatdRemainingAmount = EncryptedAmount rem_hi rem_lo,
          eatdTransferAmount = EncryptedAmount trans_hi trans_lo,
          eatdIndex = idx,
          eatdProof = proof
          })
      else return Nothing

-- | Verify an encrypted transfer proof.
foreign import ccall unsafe "verify_encrypted_transfer"
  verify_encrypted_transfer ::
       Ptr GlobalContext -- ^ Pointer to the global context needed to validate the proof.
     -> Ptr ElgamalPublicKey -- ^ Public key of the receiver.
     -> Ptr ElgamalPublicKey -- ^ Public key of the sender.
     -> Ptr ElgamalCipher -- ^ High chunk of the current balance.
     -> Ptr ElgamalCipher -- ^ Low chunk of the current balance.
     -> Ptr ElgamalCipher -- ^ High chunk of the remaining amount.
     -> Ptr ElgamalCipher -- ^ Low chunk of the remaining amount.
     -> Ptr ElgamalCipher -- ^ High chunk of the transfer amount.
     -> Ptr ElgamalCipher -- ^ Low chunk of the transfer amount.
     -> EncryptedAmountAggIndex -- ^ Index up to which amounts have been aggregated
     -> Ptr CChar -- ^ Pointer to the proof
     -> Word64 -- ^ Length of the proof
     -> IO Word8 -- ^ Return either 0 if proof checking failed, or non-zero in case of success.

verifyEncryptedTransferProof ::
  -- |Global context with parameters
  GlobalContext ->
  -- |Public key of the receiver.
  AccountEncryptionKey ->
  -- |Public key of the sender.
  AccountEncryptionKey ->
  -- |Aggregated encrypted amount on the sender's account that was used.
  EncryptedAmount ->
  -- |Proof of validity of the transfer.
  EncryptedAmountTransferData ->
  Bool
verifyEncryptedTransferProof gc receiverPK senderPK initialAmount transferData = unsafeDupablePerformIO $ do
  withGlobalContext gc $ \gcPtr ->
    withElgamalPublicKey receiverPK' $ \receiverPKPtr ->
      withElgamalPublicKey senderPK' $ \senderPKPtr ->
        withElgamalCipher (encryptionHigh initialAmount) $ \initialHighPtr ->
          withElgamalCipher (encryptionLow initialAmount) $ \initialLowPtr ->
            -- this is safe since the called function handles the 0 length case correctly.
            withEncryptedAmountTransferData transferData $ \rem_hi rem_lo trans_hi trans_lo idx proof_len proof_ptr -> do
               res <- verify_encrypted_transfer
                       gcPtr
                       receiverPKPtr
                       senderPKPtr
                       initialHighPtr
                       initialLowPtr
                       rem_hi
                       rem_lo
                       trans_hi
                       trans_lo
                       idx
                       proof_ptr
                       proof_len
               return (res /= 0)
  where AccountEncryptionKey receiverPK' = receiverPK
        AccountEncryptionKey senderPK' = senderPK

--------------------------------------------------------------------------------
--------------------------- Sec to pub transfer data ---------------------------
--------------------------------------------------------------------------------

foreign import ccall unsafe "make_sec_to_pub_data"
  make_sec_to_pub_transfer_data ::
       Ptr GlobalContext -- ^ Pointer to the global context
     -> Ptr ElgamalSecretKey -- ^ Secret key of the sender
     -> Ptr AggregatedDecryptedAmount -- ^ Input encrypted amount for the transaction
     -> Word64 -- ^ Amount to transfer.
     -> Ptr (Ptr ElgamalCipher) -- ^ High chunk of the remaining amount
     -> Ptr (Ptr ElgamalCipher) -- ^ Low chunk of the remaining amount
     -> Ptr EncryptedAmountAggIndex -- ^ Place to write the index
     -> Ptr Word64 -- ^ Place to write the length of the proof
     -> IO (Ptr CChar) -- ^ The proof

-- | Serialized version of `SecToPubAmountTransferProof` in encrypted_transfers/src/types.rs
newtype SecToPubAmountTransferProof = SecToPubAmountTransferProof { theSecToPubAmountTransferProof :: ShortByteString }
  deriving (Eq, Show, FromJSON, ToJSON) via ByteStringHex
  deriving Serialize via Short65K

withSecToPubAmountTransferProof :: SecToPubAmountTransferProof -> (CStringLen -> IO a) -> IO a
withSecToPubAmountTransferProof (SecToPubAmountTransferProof s) = useAsCStringLen s

makeSecToPubAmountTransferProof :: CStringLen -> IO SecToPubAmountTransferProof
makeSecToPubAmountTransferProof c = SecToPubAmountTransferProof <$> packCStringLen c

-- | Custom serialization functions for proofs which allow us to have the same
-- serialization as in rust, provided enough context, i.e., length.
getSecToPubAmountTransferProof :: Word32 -> Get SecToPubAmountTransferProof
getSecToPubAmountTransferProof len = SecToPubAmountTransferProof <$> getShortByteString (fromIntegral len)

-- |Put the proof directly without the length.
-- The proof can be deserialized in the right contexts using 'getSecToPubAmountTransferProof'
putSecToPubAmountTransferProof :: SecToPubAmountTransferProof -> Put
putSecToPubAmountTransferProof = putShortByteString . theSecToPubAmountTransferProof

-- | Haskell counterpart of `SecToPubAmountTransferData` in encrypted_transfers/src/types.rs
data SecToPubAmountTransferData = SecToPubAmountTransferData {
  stpatdRemainingAmount :: !EncryptedAmount,
  stpatdTransferAmount :: !Amount,
  stpatdIndex :: !EncryptedAmountAggIndex,
  stpatdProof :: !SecToPubAmountTransferProof
  } deriving (Eq, Show)

withSecToPubAmountTransferData :: SecToPubAmountTransferData
                               -> (Ptr ElgamalCipher -> Ptr ElgamalCipher -> Word64 -> EncryptedAmountAggIndex -> Word64 -> Ptr CChar -> IO a)
                               -> IO a
withSecToPubAmountTransferData SecToPubAmountTransferData{..} f = do
  withElgamalCipher (encryptionHigh stpatdRemainingAmount) $ \remaining_high ->
    withElgamalCipher (encryptionLow stpatdRemainingAmount) $ \remaining_low ->
    withSecToPubAmountTransferProof stpatdProof $ \(proof, proof_len) ->
    f remaining_high remaining_low (_amount stpatdTransferAmount) stpatdIndex (fromIntegral proof_len) proof

makeSecToPubAmountTransferData :: GlobalContext
                               -> ElgamalSecretKey
                               -> AggregatedDecryptedAmount
                               -> Amount
                               -> IO (Maybe SecToPubAmountTransferData)
makeSecToPubAmountTransferData gc sk aggAmount (Amount amount) =
  withGlobalContext gc $ \gcPtr ->
  withElgamalSecretKey sk $ \skPtr ->
  withAggregatedDecryptedAmount aggAmount $ \aggAmountPtr ->
    alloca $ \rem_hi_ptr ->
    alloca $ \rem_lo_ptr ->
    alloca $ \idx_ptr ->
    alloca $ \len_ptr -> do
      proof_ptr <- make_sec_to_pub_transfer_data gcPtr skPtr aggAmountPtr amount rem_hi_ptr rem_lo_ptr idx_ptr len_ptr
      if proof_ptr == nullPtr
      then return Nothing
      else do
        rem_hi <- unsafeMakeCipher =<< peek rem_hi_ptr
        rem_lo <- unsafeMakeCipher =<< peek rem_lo_ptr
        idx <- peek idx_ptr
        len <- peek len_ptr
        proof <- makeSecToPubAmountTransferProof (proof_ptr, fromIntegral len)
        return $ Just SecToPubAmountTransferData {
          stpatdRemainingAmount = EncryptedAmount rem_hi rem_lo,
          stpatdTransferAmount = Amount amount,
          stpatdIndex = idx,
          stpatdProof = proof
          }

foreign import ccall unsafe "verify_sec_to_pub_transfer"
  verify_sec_to_pub_transfer ::
       Ptr GlobalContext -- ^ Pointer to the global context needed to validate the proof.
     -> Ptr ElgamalPublicKey -- ^ Public key of the sender.
     -> Ptr ElgamalCipher -- ^ High chunk of the current balance.
     -> Ptr ElgamalCipher -- ^ Low chunk of the current balance.
     -> Ptr ElgamalCipher -- ^ High chunk of the remaining amount.
     -> Ptr ElgamalCipher -- ^ Low chunk of the remaining amount.
     -> Word64 -- ^ Plaintext amount that is to be transferred
     -> EncryptedAmountAggIndex -- ^ Index up to which amounts have been aggregated
     -> Ptr CChar -- ^ Pointer to the proof
     -> Word64
     -> IO Word8 -- ^ Return either 0 if proof checking failed, or non-zero in case of success.

verifySecretToPublicTransferProof ::
  -- |Global context with parameters
  GlobalContext ->
  -- |Public key of the sender.
  AccountEncryptionKey ->
  -- |Aggregated encrypted amount on the sender's account that was used.
  EncryptedAmount ->
  -- |Proof of validity of the transfer.
  SecToPubAmountTransferData ->
  Bool
verifySecretToPublicTransferProof gc senderPK initialAmount transferData = unsafeDupablePerformIO $ do
  withGlobalContext gc $ \gcPtr ->
    withElgamalPublicKey senderPK' $ \senderPKPtr ->
      withElgamalCipher (encryptionHigh initialAmount) $ \initialHighPtr ->
        withElgamalCipher (encryptionLow initialAmount) $ \initialLowPtr ->
          -- this is safe since the called function handles the 0 length case correctly.
          withSecToPubAmountTransferData transferData $ \rem_hi rem_lo amount idx proof_len proof_ptr -> do
             res <- verify_sec_to_pub_transfer
                     gcPtr
                     senderPKPtr
                     initialHighPtr
                     initialLowPtr
                     rem_hi
                     rem_lo
                     amount
                     idx
                     proof_ptr
                     proof_len
             return (res /= 0)
  where AccountEncryptionKey senderPK' = senderPK

-- |Decrypt an encrypted amount.

newtype Table = Table (ForeignPtr Table)

withTable :: Table -> (Ptr Table -> IO b) -> IO b
withTable (Table fp) = withForeignPtr fp

-- Precompute the baby step giant step table
foreign import ccall unsafe "compute_table"
  computeTablePtr :: Ptr GlobalContext -> Word64 -> IO (Ptr Table)

foreign import ccall unsafe "&free_table"
  freeTable :: FunPtr (Ptr Table -> IO ())

foreign import ccall unsafe "decrypt_amount"
  decryptAmountPtr ::
   Ptr Table
   -> Ptr ElgamalSecretKey
   -> Ptr ElgamalCipher -- ^Pointer to high bits of the amount
   -> Ptr ElgamalCipher -- ^Pointer to low bits of the amount
   -> IO Word64

computeTable :: GlobalContext -> Word64 -> Table
computeTable gc m = Table . unsafeDupablePerformIO $ do
    r <- withGlobalContext gc (flip computeTablePtr m)
    newForeignPtr freeTable r

-- |Decrypt an encrypted amount that is assumed to have been encrypted with the
-- public key corresponding to the given secret key, as well as parameters in
-- global context and table. If this is not the case this function is almost
-- certainly going to appear to loop.
decryptAmount :: Table -> ElgamalSecretKey -> EncryptedAmount -> Amount
decryptAmount table sec EncryptedAmount{..} = Amount . unsafeDupablePerformIO $
    withTable table $ \tablePtr ->
      withElgamalSecretKey sec $ \secPtr ->
        withElgamalCipher encryptionHigh $ \highPtr ->
          withElgamalCipher encryptionLow $ decryptAmountPtr tablePtr secPtr highPtr

--------------------------------------------------------------------------------
-------------------------- Helper mostly for testing ---------------------------
--------------------------------------------------------------------------------

foreign import ccall unsafe "encrypt_amount"
  encrypt_amount ::
    Ptr GlobalContext -- ^ Global context
    -> Ptr ElgamalPublicKey -- ^ Public key with which to encrypt.
    -> Word64 -- ^ Amount to be encrypted
    -> Ptr (Ptr ElgamalCipher) -- ^ Place to write the pointer to the high chunk of the result.
    -> Ptr (Ptr ElgamalCipher) -- ^ Place to write the pointer to the low chunk of the result.
    -> IO ()

-- | Encrypt the given amount. This is non-deterministic since it samples
-- randomness to encrypt with.
encryptAmount :: GlobalContext -> ElgamalPublicKey -> Amount -> IO EncryptedAmount
encryptAmount gc pub (Amount amount) =
  withGlobalContext gc $ \gcPtr ->
  withElgamalPublicKey pub $ \pubPtr ->
    alloca $ \outHighPtr ->
    alloca $ \outLowPtr -> do
        encrypt_amount gcPtr pubPtr amount outHighPtr outLowPtr
        outHigh <- unsafeMakeCipher =<< peek outHighPtr
        outLow <- unsafeMakeCipher =<< peek outLowPtr
        return EncryptedAmount{encryptionHigh = outHigh, encryptionLow = outLow}
