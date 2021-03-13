#[macro_use]
extern crate failure;
#[macro_use]
extern crate serde_json;
use crypto_common::{
    types::{Amount, KeyIndex, Signature, TransactionSignature},
    *,
};
use dodis_yampolskiy_prf::secret as prf;
use ed25519_dalek as ed25519;
use ed25519_dalek::Signer;
use either::Either::{Left, Right};
use encrypted_transfers::encrypt_amount_with_fixed_randomness;
use failure::Fallible;
use id::{account_holder, ffi::AttributeKind, secret_sharing::Threshold, types::*};
use pairing::bls12_381::{Bls12, G1};
use rand::thread_rng;
use serde_json::{from_str, from_value, to_string, Value};
use sha2::{Digest, Sha256};
use std::{
    cmp::max,
    collections::BTreeMap,
    convert::TryInto,
    ffi::{CStr, CString},
    io::Cursor,
};

use crypto_common::serde_impls::KeyPairDef;
type ExampleCurve = G1;

/// Context for a transaction to send.
#[derive(SerdeDeserialize)]
#[serde(rename_all = "camelCase")]
struct TransferContext {
    pub from:   AccountAddress,
    pub to:     Option<AccountAddress>,
    pub expiry: u64,
    pub nonce:  u64,
    pub keys:   AccountKeys,
    pub energy: u64,
}

/// Sign the given hash.
fn make_signatures<H: AsRef<[u8]>>(keys: AccountKeys, hash: &H) -> Fallible<TransactionSignature> {
    // we'll just sign with all the keys we are given, disregarding the threshold.
    // It is not our job here to decide and in any case the wallet is meant to
    // support only single key accounts.
    let mut out = BTreeMap::new();
    for (cred_index, map) in keys.keys.into_iter() {
        let mut cred_sigs = BTreeMap::new();
        for (key_index, kp) in map.keys.into_iter() {
            let public = kp.public;
            let secret = kp.secret;
            let signature = ed25519_dalek::Keypair { public, secret }.sign(hash.as_ref());
            cred_sigs.insert(key_index, Signature {
                sig: signature.to_bytes().to_vec(),
            });
        }
        out.insert(cred_index, cred_sigs);
    }
    Ok(TransactionSignature { signatures: out })
}

/// Create a JSON encoding of an encrypted transfer transaction.
fn create_encrypted_transfer_aux(input: &str) -> Fallible<String> {
    let v: Value = from_str(input)?;
    let ctx: TransferContext = from_value(v.clone())?;
    let ctx_to = match ctx.to {
        Some(to) => to,
        None => bail!("to account should be present"),
    };

    // context with parameters
    let global_context: GlobalContext<ExampleCurve> = try_get(&v, "global")?;

    // plaintext amount to transfer
    let amount: Amount = try_get(&v, "amount")?;

    let sender_sk: elgamal::SecretKey<ExampleCurve> = try_get(&v, "senderSecretKey")?;

    let receiver_pk = try_get(&v, "receiverPublicKey")?;

    let input_amount = try_get(&v, "inputEncryptedAmount")?;

    // Should be safe on iOS and Android, by calling SecRandomCopyBytes/getrandom,
    // respectively.
    let mut csprng = thread_rng();

    let payload = encrypted_transfers::make_transfer_data(
        &global_context,
        &receiver_pk,
        &sender_sk,
        &input_amount,
        amount,
        &mut csprng,
    );
    let payload = match payload {
        Some(payload) => payload,
        None => bail!("Could not produce payload."),
    };

    let (hash, body) = {
        let mut payload_bytes = Vec::new();
        payload_bytes.put(&16u8); // transaction type is encrypted transfer
        payload_bytes.put(&ctx_to);
        payload_bytes.extend_from_slice(&to_bytes(&payload));

        make_transaction_bytes(&ctx, &payload_bytes)
    };

    let signatures = make_signatures(ctx.keys, &hash)?;

    let response = json!({
        "signatures": signatures,
        "transaction": hex::encode(&body),
        "remaining": payload.remaining_amount,
    });

    Ok(to_string(&response)?)
}

/// Given payload bytes, make a full transaction body (that is, transaction
/// minus the signature) together with its hash.
fn make_transaction_bytes(
    ctx: &TransferContext,
    payload_bytes: &[u8],
) -> (impl AsRef<[u8]>, Vec<u8>) {
    let payload_size: u32 = payload_bytes.len() as u32;
    let mut body = Vec::new();
    // this needs to match with what is in Transactions.hs
    body.put(&ctx.from);
    body.put(&ctx.nonce);
    body.put(&ctx.energy);
    body.put(&payload_size);
    body.put(&ctx.expiry);
    body.extend_from_slice(payload_bytes);

    let hasher = Sha256::new().chain(&body);
    (hasher.finalize(), body)
}

fn create_transfer_aux(input: &str) -> Fallible<String> {
    let v: Value = from_str(input)?;

    let ctx: TransferContext = from_value(v.clone())?;
    let ctx_to = match ctx.to {
        Some(to) => to,
        None => bail!("to account should be present"),
    };

    let amount: Amount = try_get(&v, "amount")?;

    let (hash, body) = {
        let mut payload = Vec::new();
        payload.put(&3u8); // transaction type is transfer
        payload.put(&ctx_to);
        payload.put(&amount);

        let payload_size: u32 = payload.len() as u32;
        assert_eq!(payload_size, 41);

        make_transaction_bytes(&ctx, &payload)
    };

    let signatures = make_signatures(ctx.keys, &hash)?;

    let response = json!({
        "signatures": signatures,
        "transaction": hex::encode(&body),
    });

    Ok(to_string(&response)?)
}

fn create_pub_to_sec_transfer_aux(input: &str) -> Fallible<String> {
    let v: Value = from_str(input)?;

    let ctx: TransferContext = from_value(v.clone())?;

    let amount: Amount = try_get(&v, "amount")?;

    // context with parameters
    let global_context: GlobalContext<ExampleCurve> = try_get(&v, "global")?;

    let (hash, body) = {
        let mut payload = Vec::new();
        payload.put(&17u8); // transaction type is public to secret transfer
        payload.put(&amount);

        // let payload_size: u32 = payload.len() as u32;
        // assert_eq!(payload_size, 41);

        make_transaction_bytes(&ctx, &payload)
    };

    let signatures = make_signatures(ctx.keys, &hash)?;
    let encryption = encrypt_amount_with_fixed_randomness(&global_context, amount);
    let response = json!({
        "signatures": signatures,
        "transaction": hex::encode(&body),
        "addedSelfEncryptedAmount": encryption
    });

    Ok(to_string(&response)?)
}

/// Create a JSON encoding of a secret to public amount transaction.
fn create_sec_to_pub_transfer_aux(input: &str) -> Fallible<String> {
    let v: Value = from_str(input)?;
    let ctx: TransferContext = from_value(v.clone())?;

    // context with parameters
    let global_context: GlobalContext<ExampleCurve> = try_get(&v, "global")?;

    // plaintext amount to transfer
    let amount: Amount = try_get(&v, "amount")?;

    let sender_sk: elgamal::SecretKey<ExampleCurve> = try_get(&v, "senderSecretKey")?;

    let input_amount = try_get(&v, "inputEncryptedAmount")?;

    // Should be safe on iOS and Android, by calling SecRandomCopyBytes/getrandom,
    // respectively.
    let mut csprng = thread_rng();

    let payload = encrypted_transfers::make_sec_to_pub_transfer_data(
        &global_context,
        &sender_sk,
        &input_amount,
        amount,
        &mut csprng,
    );
    let payload = match payload {
        Some(payload) => payload,
        None => bail!("Could not produce payload."),
    };

    let (hash, body) = {
        let mut payload_bytes = Vec::new();
        payload_bytes.put(&18u8); // transaction type is secret to public transfer
        payload_bytes.extend_from_slice(&to_bytes(&payload));

        make_transaction_bytes(&ctx, &payload_bytes)
    };

    let signatures = make_signatures(ctx.keys, &hash)?;

    let response = json!({
        "signatures": signatures,
        "transaction": hex::encode(&body),
        "remaining": payload.remaining_amount,
    });

    Ok(to_string(&response)?)
}

fn check_account_address_aux(input: &str) -> bool { input.parse::<AccountAddress>().is_ok() }

/// Aggregate two encrypted amounts together into one.
fn combine_encrypted_amounts_aux(left: &str, right: &str) -> Fallible<String> {
    let left = from_str(left)?;
    let right = from_str(right)?;
    Ok(to_string(&encrypted_transfers::aggregate::<ExampleCurve>(
        &left, &right,
    ))?)
}

/// Try to extract a field with a given name from the JSON value.
fn try_get<A: serde::de::DeserializeOwned>(v: &Value, fname: &str) -> Fallible<A> {
    match v.get(fname) {
        Some(v) => Ok(from_value(v.clone())?),
        None => bail!(format!("Field {} not present, but should be.", fname)),
    }
}

/// This function creates the identity object request
fn create_id_request_and_private_data_aux(input: &str) -> Fallible<String> {
    let v: Value = from_str(input)?;

    let ip_info: IpInfo<Bls12> = try_get(&v, "ipInfo")?;
    let global_context: GlobalContext<ExampleCurve> = try_get(&v, "global")?;

    let ars_infos: BTreeMap<ArIdentity, ArInfo<ExampleCurve>> = try_get(&v, "arsInfos")?;

    // FIXME: IP defined threshold
    let threshold = {
        let l = ars_infos.len();
        ensure!(l > 0, "ArInfos should have at least 1 anonymity revoker.");
        Threshold(max((l - 1).try_into().unwrap_or(255), 1))
    };

    // Should be safe on iOS and Android, by calling SecRandomCopyBytes/getrandom,
    // respectively.
    let mut csprng = thread_rng();

    let prf_key = prf::SecretKey::generate(&mut csprng);

    let chi = CredentialHolderInfo::<ExampleCurve> {
        id_cred: IdCredentials::generate(&mut csprng),
    };

    let aci = AccCredentialInfo {
        cred_holder_info: chi,
        prf_key,
    };

    // Choice of anonymity revokers, all of them in this implementation.
    let context = IPContext::new(&ip_info, &ars_infos, &global_context);

    // Generating account data for the initial account
    let mut keys = std::collections::BTreeMap::new();
    let mut csprng = thread_rng();
    keys.insert(
        KeyIndex(0),
        crypto_common::serde_impls::KeyPairDef::from(ed25519::Keypair::generate(&mut csprng)),
    );

    let initial_acc_data = InitialAccountData {
        keys,
        threshold: SignatureThreshold(1),
    };
    let (pio, randomness) = {
        match account_holder::generate_pio(&context, threshold, &aci, &initial_acc_data) {
            Some(x) => x,
            None => bail!("Generating the pre-identity object failed."),
        }
    };

    let acc_keys = AccountKeys::from(initial_acc_data);

    let id_use_data = IdObjectUseData { aci, randomness };

    let reg_id = &pio.pub_info_for_ip.reg_id;
    let address = AccountAddress::new(reg_id);
    let secret_key = elgamal::SecretKey {
        generator: *global_context.elgamal_generator(),
        // the unwrap is safe since we've generated the RegID successfully above.
        scalar:    id_use_data.aci.prf_key.prf_exponent(0).unwrap(),
    };

    let response = json!({
        "idObjectRequest": Versioned::new(VERSION_0, pio),
        "privateIdObjectData": Versioned::new(VERSION_0, id_use_data),
        "initialAccountData": json!({
            "accountKeys": acc_keys,
            "encryptionSecretKey": secret_key,
            "encryptionPublicKey": elgamal::PublicKey::from(&secret_key),
            "accountAddress": address,
        })
    });

    Ok(to_string(&response)?)
}

fn create_credential_aux(input: &str) -> Fallible<String> {
    let v: Value = from_str(input)?;
    let expiry = try_get(&v, "expiry")?;
    let ip_info: IpInfo<Bls12> = try_get(&v, "ipInfo")?;

    let ars_infos: BTreeMap<ArIdentity, ArInfo<ExampleCurve>> = try_get(&v, "arsInfos")?;

    let global_context: GlobalContext<ExampleCurve> = try_get(&v, "global")?;

    let id_object: IdentityObject<Bls12, ExampleCurve, AttributeKind> =
        try_get(&v, "identityObject")?;

    let id_use_data: IdObjectUseData<Bls12, ExampleCurve> = try_get(&v, "privateIdObjectData")?;

    let tags: Vec<AttributeTag> = try_get(&v, "revealedAttributes")?;

    let acc_num: u8 = try_get(&v, "accountNumber")?;

    // The mobile wallet for now only creates new accounts and does not support
    // adding credentials onto existing ones. Once that is supported the address
    // should be coming from the input data.
    let new_or_existing = Left(expiry);

    // The mobile wallet can only create new accounts, which means new credential
    // data will be generated.
    let cred_data = {
        let mut keys = std::collections::BTreeMap::new();
        let mut csprng = thread_rng();
        keys.insert(KeyIndex(0), KeyPairDef::generate(&mut csprng));

        CredentialData {
            keys,
            threshold: SignatureThreshold(1),
        }
    };

    let mut policy_vec = std::collections::BTreeMap::new();
    for tag in tags {
        if let Some(att) = id_object.alist.alist.get(&tag) {
            if policy_vec.insert(tag, att.clone()).is_some() {
                bail!("Cannot reveal an attribute more than once.")
            }
        } else {
            bail!("Cannot reveal an attribute which is not part of the attribute list.")
        }
    }

    let policy = Policy {
        valid_to: id_object.alist.valid_to,
        created_at: id_object.alist.created_at,
        policy_vec,
        _phantom: Default::default(),
    };

    let context = IPContext::new(&ip_info, &ars_infos, &global_context);

    let cdi = account_holder::create_credential(
        context,
        &id_object,
        &id_use_data,
        acc_num,
        policy,
        &cred_data,
        &new_or_existing,
    )?;

    let address = match new_or_existing {
        Left(_) => AccountAddress::new(&cdi.values.cred_id),
        Right(address) => address,
    };

    // unwrap is safe here since we've generated the credential already, and that
    // does the same computation.
    let enc_key = id_use_data.aci.prf_key.prf_exponent(acc_num).unwrap();
    let secret_key = elgamal::SecretKey {
        generator: *global_context.elgamal_generator(),
        scalar:    enc_key,
    };

    let credential_message = AccountCredentialMessage {
        message_expiry: expiry,
        credential:     AccountCredential::Normal { cdi },
    };

    let response = json!({
        "credential": Versioned::new(VERSION_0, credential_message),
        "accountKeys": AccountKeys::from(cred_data),
        "encryptionSecretKey": secret_key,
        "encryptionPublicKey": elgamal::PublicKey::from(&secret_key),
        "accountAddress": address,
    });
    Ok(to_string(&response)?)
}

fn generate_accounts_aux(input: &str) -> Fallible<String> {
    let v: Value = from_str(input)?;

    let global_context: GlobalContext<ExampleCurve> = try_get(&v, "global")?;

    let id_object: IdentityObject<Bls12, ExampleCurve, AttributeKind> =
        try_get(&v, "identityObject")?;

    let id_use_data: IdObjectUseData<Bls12, ExampleCurve> = try_get(&v, "privateIdObjectData")?;

    let start: u8 = try_get(&v, "start").unwrap_or(0);

    let mut response = Vec::with_capacity(256);

    for acc_num in start..id_object.alist.max_accounts {
        if let Ok(reg_id) = id_use_data
            .aci
            .prf_key
            .prf(global_context.elgamal_generator(), acc_num)
        {
            let enc_key = id_use_data.aci.prf_key.prf_exponent(acc_num).unwrap();
            let secret_key = elgamal::SecretKey {
                generator: *global_context.elgamal_generator(),
                scalar:    enc_key,
            };
            let address = AccountAddress::new(&reg_id);
            response.push(json!({
                "encryptionSecretKey": secret_key,
                "encryptionPublicKey": elgamal::PublicKey::from(&secret_key),
                "accountAddress": address,
            }));
        }
    }
    Ok(to_string(&response)?)
}

/// Embed the precomputed table for decryption.
/// It is unfortunate that this is pure bytes, but not enough of data is marked
/// as const, and in any case a HashMap relies on an allocator, so will never be
/// const.
static TABLE_BYTES: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/table_bytes.bin"));

fn decrypt_encrypted_amount_aux(input: &str) -> Fallible<Amount> {
    let v: Value = from_str(input)?;
    let encrypted_amount = try_get(&v, "encryptedAmount")?;
    let secret = try_get(&v, "encryptionSecretKey")?;

    let table = (&mut Cursor::new(TABLE_BYTES)).get()?;
    Ok(
        encrypted_transfers::decrypt_amount::<id::constants::ArCurve>(
            &table,
            &secret,
            &encrypted_amount,
        ),
    )
}

/// Set the flag to 0, and return a newly allocated string containing
/// the error message. The returned string is NUL terminated.
///
/// # Safety
/// This function does not check that the flag pointer is not null.
unsafe fn signal_error(flag: *mut u8, err_msg: String) -> *mut c_char {
    *flag = 0;
    CString::new(err_msg)
        .expect("Error message string should be non-zero and utf8.")
        .into_raw()
}

unsafe fn encode_response(response: Fallible<String>, success: *mut u8) -> *mut c_char {
    match response {
        Ok(s) => {
            let cstr: CString = {
                match CString::new(s) {
                    Ok(s) => s,
                    Err(e) => {
                        return signal_error(success, format!("Could not encode response: {}", e))
                    }
                }
            };
            *success = 1;
            cstr.into_raw()
        }
        Err(e) => signal_error(success, format!("Could not produce response: {}", e)),
    }
}

/// Try to get a normal string from a `*const c_char`.
///
/// This needs to be a macro due to early return.
macro_rules! get_string {
    ($input_ptr:expr, $success:expr) => {{
        if $input_ptr.is_null() {
            return signal_error($success, "Null pointer input.".to_owned());
        }
        match CStr::from_ptr($input_ptr).to_str() {
            Ok(s) => s,
            Err(e) => {
                return signal_error($success, format!("Could not decode input string: {}", e))
            }
        }
    }};
}

/// Make a wrapper for functions of the form
///
/// ```
///    f(input_ptr: *const c_char, success: *mut u8) -> *mut c_char
/// ```
/// or
/// ```
///    f(input_ptr_1: *const c_char, input_ptr_2: *const c_char, success: *mut u8) -> *mut c_char
/// ```
macro_rules! make_wrapper {
    ($(#[$attr:meta])* => $f:ident -> $call:expr) => {
        $(#[$attr])*
        #[no_mangle]
        pub unsafe fn $f(input_ptr: *const c_char, success: *mut u8) -> *mut c_char {
            let input_str = get_string!(input_ptr, success);
            let response = $call(input_str);
            encode_response(response, success)
        }
    };
    ($(#[$attr:meta])* => $f:ident --> $call:expr) => {
        $(#[$attr])*
        #[no_mangle]
        pub unsafe fn $f(input_ptr_1: *const c_char, input_ptr_2: *const c_char, success: *mut u8) -> *mut c_char {
            let input_str_1 = get_string!(input_ptr_1, success);
            let input_str_2 = get_string!(input_ptr_2, success);
            let response = $call(input_str_1, input_str_2);
            encode_response(response, success)
        }
    };
}

// Make external wrappers that can be used in android and iOS libraries.
make_wrapper!(
    /// Take a pointer to a NUL-terminated UTF8-string and return a NUL-terminated
    /// UTF8-encoded string. The returned string must be freed by the caller by
    /// calling the function 'free_response_string'. In case of failure the function
    /// returns an error message as the response, and sets the 'success' flag to 0.
    ///
    /// See rust-bins/wallet-notes/README.md for the description of input and output
    /// formats.
    ///
    /// # Safety
    /// The input pointer must point to a null-terminated buffer, otherwise this
    /// function will fail in unspecified ways.
    => create_transfer -> create_transfer_aux);
make_wrapper!(
    /// Take a pointer to a NUL-terminated UTF8-string and return a NUL-terminated
    /// UTF8-encoded string. The input string should contain the JSON payload of an
    /// attribute list, name of id object, and the identity provider public
    /// information.
    ///
    /// The return value contains a JSON object with two values, one is
    /// the request for the identity object that is public, and the other is the
    /// private keys and other secret values that must be kept by the user.
    /// These secret values will be needed later to use the identity object.
    ///
    /// The returned string must be freed by the caller by calling the function
    /// 'free_response_string'. In case of failure the function returns an error
    /// message as the response, and sets the 'success' flag to 0.
    ///
    /// # Safety
    /// The input pointer must point to a null-terminated buffer, otherwise this
    /// function will fail in unspecified ways.
    => create_id_request_and_private_data -> create_id_request_and_private_data_aux);

make_wrapper!(
    /// Take a pointer to a NUL-terminated UTF8-string and return a NUL-terminated
    /// UTF8-encoded string. The returned string must be freed by the caller by
    /// calling the function 'free_response_string'. In case of failure the function
    /// returns an error message as the response, and sets the 'success' flag to 0.
    ///
    /// See rust-bins/wallet-notes/README.md for the description of input and output
    /// formats.
    ///
    /// # Safety
    /// The input pointer must point to a null-terminated buffer, otherwise this
    /// function will fail in unspecified ways.
    => create_credential -> create_credential_aux);

make_wrapper!(
    /// Take a pointer to a NUL-terminated UTF8-string and return a NUL-terminated
    /// UTF8-encoded string. The returned string must be freed by the caller by
    /// calling the function 'free_response_string'. In case of failure the function
    /// returns an error message as the response, and sets the 'success' flag to 0.
    ///
    /// See rust-bins/wallet-notes/README.md for the description of input and output
    /// formats for encrypted transfers.
    ///
    /// # Safety
    /// The input pointer must point to a null-terminated buffer, otherwise this
    /// function will fail in unspecified ways.
    => create_encrypted_transfer -> create_encrypted_transfer_aux);

make_wrapper!(
    /// Take a pointer to a NUL-terminated UTF8-string and return a NUL-terminated
    /// UTF8-encoded string. The returned string must be freed by the caller by
    /// calling the function 'free_response_string'. In case of failure the function
    /// returns an error message as the response, and sets the 'success' flag to 0.
    ///
    /// See rust-bins/wallet-notes/README.md for the description of input and output
    /// formats for encrypted transfers.
    ///
    /// # Safety
    /// The input pointer must point to a null-terminated buffer, otherwise this
    /// function will fail in unspecified ways.
    => create_pub_to_sec_transfer -> create_pub_to_sec_transfer_aux);

make_wrapper!(
    /// Take a pointer to a NUL-terminated UTF8-string and return a NUL-terminated
    /// UTF8-encoded string. The returned string must be freed by the caller by
    /// calling the function 'free_response_string'. In case of failure the function
    /// returns an error message as the response, and sets the 'success' flag to 0.
    ///
    /// See rust-bins/wallet-notes/README.md for the description of input and output
    /// formats for encrypted transfers.
    ///
    /// # Safety
    /// The input pointer must point to a null-terminated buffer, otherwise this
    /// function will fail in unspecified ways.
    => create_sec_to_pub_transfer -> create_sec_to_pub_transfer_aux);

make_wrapper!(
    /// Take pointers to NUL-terminated UTF8-strings and return a NUL-terminated
    /// UTF8-encoded string. The returned string must be freed by the caller by
    /// calling the function 'free_response_string'. In case of failure the function
    /// returns an error message as the response, and sets the 'success' flag to 0.
    ///
    /// The input strings must contain base16 encoded encrypted amounts. If they can be
    /// decoded then the result is also a string of the same form, and the success flag is 1.
    /// If there is failure decoding input arguments the return value is a string
    /// describing the error.
    ///
    /// # Safety
    /// The input pointers must point to a null-terminated buffer, otherwise this
    /// function will fail in unspecified ways.
    => combine_encrypted_amounts --> combine_encrypted_amounts_aux);

make_wrapper!(
    /// Take pointers to NUL-terminated UTF8-strings and return a NUL-terminated
    /// UTF8-encoded string. The returned string must be freed by the caller by
    /// calling the function 'free_response_string'. In case of failure the function
    /// returns an error message as the response, and sets the 'success' flag to 0.
    ///
    /// The input strings must contain a valid JSON object with fields `identityObject`, `privateIdObjectData`, and `global`.
    /// If there is failure decoding input arguments the return value is a string
    /// describing the error.
    ///
    /// # Safety
    /// The input pointer must point to a null-terminated buffer, otherwise this
    /// function will fail in unspecified ways.
    => generate_accounts -> generate_accounts_aux);

/// Take pointers to a NUL-terminated UTF8-string and return a u64.
///
/// In case of failure to decode the input the function will
/// set the `success` flag to `0`, and the return value should not be used.
/// If `success` is set to `1` the return value is the decryption of the input
/// amount.
///
/// The input string should encode a JSON object with two fields "global" and
/// "encryptedAmount".
///
/// # Safety
/// The input pointer must point to a null-terminated buffer, otherwise this
/// function will fail in unspecified ways.
#[no_mangle]
pub unsafe fn decrypt_encrypted_amount(input_ptr: *const c_char, success: *mut u8) -> u64 {
    let input_str = if input_ptr.is_null() {
        *success = 0;
        return 0;
    } else {
        match CStr::from_ptr(input_ptr).to_str() {
            Ok(s) => s,
            Err(_) => {
                *success = 0;
                return 0;
            }
        }
    };
    if let Ok(v) = decrypt_encrypted_amount_aux(input_str) {
        *success = 1;
        u64::from(v)
    } else {
        *success = 0;
        0
    }
}

#[no_mangle]
/// # Safety
/// The input must be NUL-terminated.
pub unsafe fn check_account_address(input_ptr: *const c_char) -> u8 {
    let input_str = {
        match CStr::from_ptr(input_ptr).to_str() {
            Ok(s) => s,
            Err(_) => return 0,
        }
    };
    if check_account_address_aux(input_str) {
        1
    } else {
        0
    }
}

#[no_mangle]
/// # Safety
/// This function is unsafe in the sense that if the argument pointer was not
/// Constructed via CString::into_raw its behaviour is undefined.
pub unsafe fn free_response_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        let _ = CString::from_raw(ptr);
    }
}

#[cfg(target_os = "android")]
mod android;
