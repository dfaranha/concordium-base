use curve_arithmetic::curve_arithmetic::*;
use dodis_yampolskiy_prf::secret as prf;
use elgamal::cipher::Cipher;
use pairing::Field;
use pedersen_scheme::commitment as pedersen;
use ps_sig::{public as pssig, signature::*};

use sigma_protocols::{com_enc_eq::ComEncEqProof, dlog::DlogProof};

pub trait Attribute<F: Field> {
    fn to_field_element(&self) -> F;
}

pub struct AttributeList<F: Field, AttributeType: Attribute<F>> {
    pub variant: u32,
    pub alist:   Vec<AttributeType>,
    _phantom:    std::marker::PhantomData<F>,
}

pub struct IdCredentials<C: Curve> {
    pub id_cred_sec: elgamal::SecretKey<C>,
    pub id_cred_pub: elgamal::PublicKey<C>,
}

pub struct CredentialHolderInfo<P: Pairing> {
    pub id_ah:   String,
    pub id_cred: IdCredentials<P::G_2>,
    // aux_data: &[u8]
}

pub struct AccCredentialInfo<P: Pairing, AttributeType: Attribute<P::ScalarField>> {
    pub acc_holder_info: CredentialHolderInfo<P>,
    pub prf_key:         prf::SecretKey<P::G_1>,
    pub attributes:      AttributeList<P::ScalarField, AttributeType>,
}

pub struct ArData<P: Pairing> {
    pub ar_name:  String,
    pub e_reg_id: Cipher<P::G_1>,
}

/// Information sent from the account holder to the identity provider.
pub struct PreIdentityObject<P: Pairing, AttributeType: Attribute<P::ScalarField>> {
    /// Name of the account holder.
    pub id_ah: String,
    /// Public credential of the account holder only.
    pub id_cred_pub: elgamal::PublicKey<P::G_1>,
    /// Information on the chosen anonymity revoker, and the encryption of the
    /// account holder's prf key with the anonymity revoker's encryption key.
    pub id_ar_data: ArData<P>,
    /// Chosen attribute list.
    pub alist: AttributeList<P::ScalarField, AttributeType>,
    /// Proof of knowledge of secret credentials corresponding to id_cred_pub
    pub pok_sc: DlogProof<P::G_1>,
    /// Commitment to the prf key.
    pub cmm_prf: pedersen::Commitment<P::G_1>,
    /// Proof that the encryption of the prf key in id_ar_data is the same as
    /// the key in cmm_prf (hidden behind the commitment).
    pub proof_com_eq: ComEncEqProof<P::G_1>,
}

/// Public information about an identity provider.
pub struct IpInfo<P: Pairing> {
    pub id_identity: String,
    pub id_verify_key: pssig::PublicKey<P>,
    /// The name and public key of the anonymity revoker chosen by this identity
    /// provider. In the future each identity provider will allow a set of
    /// anonymity revokers.
    pub ar_name: String,
    pub ar_public_key: elgamal::PublicKey<P::G_1>,
}

/// Information the account holder has after the interaction with the identity
/// provider. The account holder uses this information to generate credentials
/// to deploy on the chain.
pub struct IdentityObject<P: Pairing, AttributeType: Attribute<P::ScalarField>> {
    /// Identity provider who checked and signed the data in the
    /// PreIdentityObject.
    pub id_provider: IpInfo<P>,
    pub acc_credential_info: AccCredentialInfo<P, AttributeType>,
    /// Signature of the PreIdentityObject data.
    pub sig: Signature<P>,
    /// Information on the chosen anonymity revoker, and the encryption of the
    /// account holder's prf key with the anonymity revoker's encryption key.
    /// Should be the same as the data signed by the identity provider.
    pub ar_data: ArData<P>,
}

pub struct CredDeploymentInfo<P: Pairing, AttributeType: Attribute<P::ScalarField>> {
    pub reg_id:     P::G_1,
    pub attributes: AttributeList<P::ScalarField, AttributeType>,
}
