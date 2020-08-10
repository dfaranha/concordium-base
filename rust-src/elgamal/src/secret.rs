// -*- mode: rust; -*-

//! Elgamal secret key types
use crate::{cipher::*, message::*};
use rand::*;

use crypto_common::*;
use curve_arithmetic::{Curve, Value};

use ff::Field;
use std::collections::HashMap;

/// Elgamal secret key packed together with a chosen generator.
#[derive(Debug, PartialEq, Eq, Clone, Serialize)]
pub struct SecretKey<C: Curve> {
    /// Generator of the group, not secret but convenient to have here.
    pub generator: C,
    /// Secret key.
    pub scalar: C::Scalar,
}

// THIS IS COMMENTED FOR NOW FOR COMPATIBILITY WITH BLS CURVE IMPLEMENTATION
// ONCE WE HAVE TAKEN OVER THE SOURCE OF THE CURVE THIS SHOULD BE IMPLEMENTED
// Overwrite secret key material with null bytes when it goes out of scope.
//
// impl Drop for SecretKey {
// fn drop(&mut self) {
// (self.0).into_repr().0.clear();
// }
// }

pub type BabyStepGiantStepTable = HashMap<Vec<u8>, u64>;

pub struct BabyStepGiantStep<C: Curve> {
    /// Precomputed table of powers.
    table: BabyStepGiantStepTable,
    /// Point base^{-m}
    inverse_point: C,
    /// Size of the table.
    m: u64,
}

impl<C: Curve> BabyStepGiantStep<C> {
    /// Generate a new instance, precomputing the table.
    pub fn new(base: &C, m: u64) -> Self {
        let mut table = HashMap::with_capacity(m as usize);
        let mut base_j = C::zero_point();
        for j in 0..m {
            table.insert(to_bytes(&base_j), j);
            base_j = base_j.plus_point(&base);
        }
        Self {
            table,
            m,
            inverse_point: base_j.inverse_point(),
        }
    }

    /// Compute the discrete log using the instance. This function's performance
    /// is linear in `l / m` where `l` is the value stored in the exponent of
    /// `v`, and `m` is the size of the table.
    ///
    /// The function will panic if `l` is not less than `u64::MAX`, although
    /// practically it will appear to loop well-before that value is reached.
    pub fn discrete_log(&self, v: &C) -> u64 {
        let mut y = *v;
        for i in 0..=u64::MAX {
            if let Some(j) = self.table.get(&to_bytes(&y)) {
                return i * self.m + j;
            }
            y = y.plus_point(&self.inverse_point);
        }
        unreachable!()
    }

    /// Composition of `new` nad `discrete_log` methods for convenience.
    ///
    /// Less efficient than reusing the table.
    pub fn discrete_log_full(base: &C, m: u64, v: &C) -> u64 {
        BabyStepGiantStep::new(base, m).discrete_log(v)
    }
}

impl<C: Curve> SecretKey<C> {
    pub fn decrypt(&self, c: &Cipher<C>) -> Message<C> {
        let x = c.0; // k * g
        let kag = x.mul_by_scalar(&self.scalar); // k * a * g
        let y = c.1; // m + k * a * g
        let value = y.minus_point(&kag); // m
        Message { value }
    }

    pub fn decrypt_exponent_slow(&self, c: &Cipher<C>) -> Value<C> {
        let m = self.decrypt(c).value;
        let mut a = <C::Scalar as Field>::zero();
        let mut i = C::zero_point();
        let field_one = <C::Scalar as Field>::one();
        while m != i {
            i = i.plus_point(&self.generator);
            a.add_assign(&field_one);
        }
        Value::new(a)
    }

    /// Decrypt the value in the exponent. It is assumed the encrypted value can
    /// be represented in 64 bits, and are small enough. Otherwise this function
    /// will appear to not terminate.
    ///
    /// This function takes an auxiliary instance of BabyStepGiantStep to speed
    /// up decryption.
    pub fn decrypt_exponent(
        &self,
        c: &Cipher<C>,
        bsgs: &BabyStepGiantStep<C>,
    ) -> u64 {
        let dec = self.decrypt(c).value;
        bsgs.discrete_log(&dec)
    }

    /// Generate a `SecretKey` from a `csprng`.
    pub fn generate<T: Rng>(generator: &C, csprng: &mut T) -> Self {
        SecretKey {
            generator: *generator,
            scalar:    C::generate_scalar(csprng),
        }
    }

    /// Generate a `SecretKey` as well as a generator.
    pub fn generate_all<T: Rng>(csprng: &mut T) -> Self {
        let x = C::generate_non_zero_scalar(csprng);
        SecretKey {
            generator: C::one_point().mul_by_scalar(&x),
            scalar:    C::generate_scalar(csprng),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pairing::bls12_381::{G1, G2};
    macro_rules! macro_test_secret_key_to_byte_conversion {
        ($function_name:ident, $curve_type:path) => {
            #[test]
            #[test]
            pub fn $function_name() {
                let mut csprng = thread_rng();
                for _i in 1..100 {
                    let sk: SecretKey<$curve_type> = SecretKey::generate_all(&mut csprng);
                    let res_sk2 = serialize_deserialize(&sk);
                    assert!(res_sk2.is_ok());
                    let sk2 = res_sk2.unwrap();
                    assert_eq!(sk2, sk);
                }
            }
        };
    }

    macro_test_secret_key_to_byte_conversion!(secret_key_to_byte_conversion_g1, G1);
    macro_test_secret_key_to_byte_conversion!(secret_key_to_byte_conversion_g2, G2);
}
