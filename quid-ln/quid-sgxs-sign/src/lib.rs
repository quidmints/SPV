//! `quid-sgxs-sign` is a small utility crate used for:
//!
//! 1. signing SGX enclave binaries (`*.sgxs` files)
//! 2. generating and manipulating the non-standard RSA keys used for (1.)
//!
//! We sign `*.sgxs` binaries with a QU!D key pair so clients can verify their
//! enclaves were created by QU!D.
//!
//! ### Why this crate exists
//!
//! The `fortanix/rust-sgx` SGX sdk provides similar utilities, but adds a
//! dependency on `openssl`, which significantly complicates our build. This
//! crate instead uses the rust-only `RustCrypto/rsa` crate.
//!
//! ### Why we can't use `ring` v0.16.20
//!
//! Ideally we would only use a single crypto backend (oneof `ring`, `openssl`,
//! or `RustCrypto` crates) and we already use `ring` (almost) everywhere else.
//!
//! Sadly, the .sgxs signing process is non-standard, as 3072 RSA+SHA256 is
//! uncommon and the [`Sigstruct`] requires computing some intermediate `q1`,
//! `q2` values.
//!
//! As a misuse-resistant crypto library, `ring` neither supports
//! 3072-RSA+SHA256 nor exposes enough low-level primitives to derive `q1` and
//! `q2`.
//!
//! ### Generating a signing key (the reproducible process)
//!
//! ```bash
//! cargo run -p quid-sgxs-sign --bin gen-signer -- <out.der>
//! ```
//!
//! This samples a fresh 3072-bit RSA (exp=3) key, writes the PKCS#8 DER to
//! `<out.der>`, and prints its MRSIGNER (signer measurement). The dev key lives
//! at `quid-sgxs-sign/data/dev-sgxs-signer.der` (committed — it only signs
//! `--debug` enclaves). The production key must be generated offline / in an
//! HSM-backed environment, kept OUT of the repo, and its MRSIGNER pasted into
//! [`quid_enclave::enclave::Measurement::PROD_SIGNER`].

use std::fmt;

use anyhow::{ensure, format_err};
use quid_byte_array::ByteArray;
use quid_crypto::rng::{Crng, SysRng};
use quid_enclave::enclave;
use quid_hex::hex;
use quid_sha256::sha256;
use rsa::{
    pkcs1v15::Pkcs1v15Sign,
    pkcs8::{DecodePrivateKey, EncodePrivateKey, EncodePublicKey},
    traits::{PublicKeyParts, SignatureScheme},
};
use sgxs::{
    crypto::{SgxHashOps, SgxRsaOps},
    sigstruct::Sigstruct,
};

/// A 3072-bit RSA keypair, configured exclusively for signing SGX enclave
/// [`Sigstruct`]s.
///
/// This implementation lets us avoid any `openssl` dependency in our codebase.
#[cfg_attr(test, derive(PartialEq))]
pub struct KeyPair {
    inner: rsa::RsaPrivateKey,
}

/// [`KeyPair::sign_sgxs`] but generic over the `rust-sgx` traits, so we can use
/// the same impl when checking for openssl parity in tests below.
fn sign_sgxs_generic<K: SgxRsaOps, H: SgxHashOps>(
    key: &K,
    measurement: enclave::Measurement,
    is_debug_enclave: bool,
    date_ymd: Option<(u16, u8, u8)>,
) -> anyhow::Result<sgxs::sigstruct::Sigstruct> {
    let attributes = if !is_debug_enclave {
        enclave::attributes::QUID_FLAGS_PROD
    } else {
        enclave::attributes::QUID_FLAGS_DEBUG
    };
    let measurement = sgxs::sigstruct::EnclaveHash::new(measurement.to_array());
    let mut signer = sgxs::sigstruct::Signer::new(measurement);
    signer.attributes_flags(attributes, enclave::attributes::QUID_MASK.bits());
    signer.attributes_xfrm(enclave::xfrm::QUID_FLAGS, enclave::xfrm::QUID_MASK);
    signer.miscselect(
        enclave::miscselect::QUID_FLAGS,
        enclave::miscselect::QUID_MASK.bits(),
    );
    signer.isvprodid(0);
    signer.isvsvn(0);
    if let Some((year, month, day)) = date_ymd {
        signer.date(year, month, day);
    }

    let sigstruct = signer
        .sign::<K, H>(key)
        .map_err(|err| format_err!("{err}"))?;
    Ok(sigstruct)
}

impl KeyPair {
    const NUM_BITS: usize = 3072;

    pub fn dev_signer() -> Self {
        Self::deserialize_pkcs8_der(include_bytes!(
            "../data/dev-sgxs-signer.der"
        ))
        .expect("Failed to deserialize dev sgxs signer")
    }

    pub fn from_rng(rng: &mut impl Crng) -> Self {
        // SGX assumes exp=3
        let exp = rsa::BigUint::from(3_u8);
        let inner = rsa::RsaPrivateKey::new_with_exp(rng, Self::NUM_BITS, &exp)
            .expect("Failed to generate SGX RSA 3072 keypair");
        Self { inner }
    }

    fn try_from_inner(inner: rsa::RsaPrivateKey) -> anyhow::Result<Self> {
        ensure!(inner.n().bits() == Self::NUM_BITS, "not a 3072 bit RSA key");
        ensure!(
            inner.e() == &rsa::BigUint::from(3_u8),
            "RSA key must have exp=3"
        );
        Ok(Self { inner })
    }

    pub fn deserialize_pkcs8_der(bytes: &[u8]) -> anyhow::Result<Self> {
        rsa::RsaPrivateKey::from_pkcs8_der(bytes)
            .map_err(|err| format_err!("Failed to deserialize PKCS#8 DER-encoded SGX RSA 3072 keypair: {err:?}"))
            .and_then(Self::try_from_inner)
    }

    #[allow(dead_code)]
    #[cfg(test)]
    fn deserialize_pkcs1_der_legacy(bytes: &[u8]) -> anyhow::Result<Self> {
        use rsa::pkcs1::DecodeRsaPrivateKey;
        rsa::RsaPrivateKey::from_pkcs1_der(bytes)
            .map_err(|err| format_err!("Failed to deserialize legacy PKCS#1 DER-encoded SGX RSA 3072 keypair: {err:?}"))
            .and_then(Self::try_from_inner)
    }

    pub fn serialize_pkcs8_der(&self) -> Vec<u8> {
        self.inner
            .to_pkcs8_der()
            .expect("Failed to PKCS#8 DER-serialize RSA keypair")
            .as_bytes()
            .to_vec()
    }

    pub fn serialize_pubkey_pkcs8_der(&self) -> Vec<u8> {
        let pubkey: &rsa::RsaPublicKey = self.inner.as_ref();
        pubkey
            .to_public_key_der()
            .expect("Failed to PKCS#8 DER-serialize RSA pubkey")
            .into_vec()
    }

    /// Return the signer measurement (also known as the MRSIGNER).
    ///
    /// The signer measurement is the SHA-256 hash of the pubkey modulus in
    /// little endian byte order.
    ///
    /// See: <https://github.com/intel/linux-sgx/blob/sgx_2.23/sdk/sign_tool/SignTool/manage_metadata.cpp#L1807>
    pub fn signer_measurement(&self) -> enclave::Measurement {
        let modulus = self.n();
        let mut modulus_buf = [0u8; 384];
        modulus_buf[..modulus.len()].copy_from_slice(&modulus);

        let measurement = sha256::digest(&modulus_buf);
        enclave::Measurement::new(measurement.to_array())
    }

    fn padding_scheme() -> Pkcs1v15Sign {
        // Should match:
        // dbg!(Pkcs1v15Sign::new::<rsa::sha2::Sha256>())
        let mut p = Pkcs1v15Sign::new_unprefixed();
        p.hash_len = Some(32);
        p.prefix =
            hex::decode_const::<19>(b"3031300d060960864801650304020105000420")
                .as_slice()
                .into();
        p
    }

    fn sign_raw_with_q1_q2(
        &self,
        rng: &mut impl Crng,
        message_hash: &[u8],
    ) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        let padding = Self::padding_scheme();
        let mut signature = self
            .inner
            .sign_with_rng(rng, padding, message_hash)
            .unwrap();

        // SGX expects the signature to be in little-endian.
        signature.reverse();

        let (q1, q2) = calculate_rsa_q1_q2(self.inner.n(), &signature);
        (signature, q1, q2)
    }

    /// Sign the given [`enclave::Measurement`] (SHA256 hash of the `*.sgxs`
    /// enclave binary) with a 3072-bit RSA private key and the standard QU!D
    /// enclave attributes.
    pub fn sign_sgxs(
        &self,
        measurement: enclave::Measurement,
        is_debug_enclave: bool,
        date_ymd: Option<(u16, u8, u8)>,
    ) -> anyhow::Result<Sigstruct> {
        sign_sgxs_generic::<_, SgxHasher>(
            self,
            measurement,
            is_debug_enclave,
            date_ymd,
        )
    }

    fn verify_raw(
        &self,
        signature: &[u8],
        message_hash: &[u8],
    ) -> Result<(), StringError> {
        // We need to convert back to big endian before verifying.
        let mut signature = signature.to_vec();
        signature.reverse();

        let padding = Self::padding_scheme();
        padding
            .verify(self.inner.as_ref(), message_hash, &signature)
            .map_err(|err| StringError(format!("{err:?}").into()))
    }

    #[cfg(test)]
    fn verify_sigstruct_signature(
        &self,
        sigstruct: &Sigstruct,
    ) -> Result<(), StringError> {
        // SHA256 hash of signed parts of the `Sigstruct`.
        #[allow(clippy::tuple_array_conversions)]
        let tbs_sigstruct_hash = {
            let (tbs1, tbs2) = sigstruct.signature_data();
            sha256::digest_many(&[tbs1, tbs2]).to_array()
        };

        self.verify_raw(&sigstruct.signature, tbs_sigstruct_hash.as_slice())
    }
}

impl fmt::Debug for KeyPair {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("quid_sgxs_sign::KeyPair(..)")
    }
}

impl SgxRsaOps for KeyPair {
    // Can't figure out the type tetris required to get `anyhow::Error` or
    // `Box<dyn Error>` here, so shove this thing in instead.
    type Error = StringError;

    fn len(&self) -> usize {
        Self::NUM_BITS
    }

    fn sign_sha256_pkcs1v1_5_with_q1_q2<H: AsRef<[u8]>>(
        &self,
        hash: H,
    ) -> Result<(Vec<u8>, Vec<u8>, Vec<u8>), Self::Error> {
        let mut rng = SysRng::new();
        Ok(self.sign_raw_with_q1_q2(&mut rng, hash.as_ref()))
    }

    fn verify_sha256_pkcs1v1_5<S: AsRef<[u8]>, H: AsRef<[u8]>>(
        &self,
        sig: S,
        hash: H,
    ) -> Result<(), Self::Error> {
        self.verify_raw(sig.as_ref(), hash.as_ref())
    }

    fn e(&self) -> Vec<u8> {
        self.inner.e().to_bytes_le()
    }

    fn n(&self) -> Vec<u8> {
        self.inner.n().to_bytes_le()
    }
}

/// Compute the `q1` and `q2` values from the RSA pubkey modulus, `n`, and the
/// signature, `sig_slice`. These values then go into their corresponding
/// [`Sigstruct`] fields.
///
/// Not sure why SGX requires computing these values, but it does. : )
///
/// See: [`linux-sgx/sign_tool::calc_RSAq1q2`](https://github.com/intel/linux-sgx/blob/sgx_2.23/sdk/sign_tool/SignTool/sign_tool.cpp#L349)
/// See: [`rust-sgx/sgxs::calculate_q1_q2`](https://github.com/fortanix/rust-sgx/blob/e2f677b28e2a934bc3b3d20cc201962f0bf556b3/intel-sgx/sgxs/src/crypto/mod.rs#L85)
fn calculate_rsa_q1_q2(
    n: &rsa::BigUint,
    sig_slice: &[u8],
) -> (Vec<u8>, Vec<u8>) {
    let s = rsa::BigUint::from_bytes_le(sig_slice);
    let s_2 = &s * &s;
    let q1 = &s_2 / n;

    let s_3 = &s_2 * &s;
    let tmp1 = &q1 * &s;
    let tmp2 = &tmp1 * n;
    let tmp3 = &s_3 - &tmp2;
    let q2 = &tmp3 / n;

    (q1.to_bytes_le(), q2.to_bytes_le())
}

struct SgxHasher(sha256::Context);

impl SgxHashOps for SgxHasher {
    fn new() -> Self {
        Self(sha256::Context::new())
    }

    fn update(&mut self, data: &[u8]) {
        self.0.update(data)
    }

    fn finish(self) -> [u8; 32] {
        self.0.finish().to_array()
    }
}

pub struct StringError(Box<str>);

impl std::error::Error for StringError {
    fn description(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for StringError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
impl fmt::Debug for StringError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_vectors() {
        let key_hex = "308206fd020100300d06092a864886f70d0101010500048206e7308206e30201000282018100bb1dbbb6a5f8747d8088ac4a78f19b9706a681d2171827e60dfc8bd1ad9d6082fbffd831b865a80e1dcf4a82aefa850a1c7942abe9933ab8ee05e54ec4b197255e3736caaab876d13d2f90588e3fd5649ae40ba03c106446ba25a3ff08284d8546cb088f55e3f8460e1bb5be648b9891e217d028a9f1c228c87dff9cb91e235b5b51727adcf5afd1b6c5ea441273305ac1c5dfb3856c93d1635de2a2248000811e07bbe1688335e75b625f08af8f6fde07a939bd84479e878b6f27aee0552ff7b26d2cdb0b117ef81a16a800395ed35aec6323a2aaa07478ec35c1b87fbec29e242b8e31c83fefdd24774f7f3a47eb2e5f42c3082101fbd8b4429b7cd6311ca16a2bb87b0bfb0f0e907ebfdc8c5905440eee5a9374ceac72da353cacc49a1f300d286493714a81905a954049bd76539293007b4c646e661cdec9a87ecb2173d2001be206de4ec73ef3b768bf27c14bab0a5efd43b2a0cdba9fbfbb6aba3a7e4d5abd6ff722b9a55fc095c78e4f72e4068d859c061ea23d6d4d72a9ec339f082d020103028201807cbe7d246ea5a2fe55b072dc50a11264af19abe164bac544095307e11e68eb01fd553acbd043c55ebe8a31ac74a7035c12fb81c7f10cd1d09eae98df2dcbba18e97a24871c7af9e0d3750ae5b42a8e4311ed5d157d6042d9d16e6d54b01ade58d9dcb05f8e97fad95ebd23d44307bb0bec0fe01b1bf6817085a95513261417923ce0f6fc934e753679d946d80c4ccae72bd93fcd039db7e0ece941c16daaab00beafd29645acce9a3cec3f5b1fb4f53eafc6267e582fbf05079f6fc9eae3754ea7ccde6a14f7989093bb63a17f814b676e119fc2c7bda0b16dfe5edff9f4190e1907c01ccb6294d2f34f8632dbe34bfb8ed0bbaa74c8516c8adcd149cd83bb66e47bb980e3515f96cb9df82eabab33eb0fde53890d37859994773b92d8a74e003984b9a314ebaca3b642993efcc45c74e2ee9bb9a4482ec8110aaac9840cae6faf9ed91e900e73753cf0842fb73d5e9c72e3146667331311d4f3332e64aef8f34580d24aef913b218aa83f723f2ef8dc63d68c779db63f412bcff727584ce46b0281c100ea2440334730101ca601de458e4f39aa8689aff3f71c02b7bed551850adcc1052abf49775e7e2bcac2ccbace8bd5a7d156d177b70016b5831e333042f6144946a76b6417d47d3c60157e58c3987e3cba1f685e7fd6421ff50af930757488e8ee8b403c0e1f9b6f3dbdac2590f54017c7f808df34352cbc93b677aed0823c3cf012036d1d9df6ab2b1339ed6f1608da4c5664047e57e6168ae14db49d08d1e563a491ade270f81b7f396ab366b98ae5e03869e5dd54c1fa984b0a97a21f22a8690281c100cc959f08a46e0a02967bb4486bcda89540bf040a87e800b70862e1e37df3dc03d3e0a48f38ade4d5f4b34b64649d5163b23831d171becc32c5c4314b2bd73a406c06be21e283c34c499372d2f259faa957b87ec60ab94417708932db0b1641412ba11210b24d8f5d0b8534da4d0fb11b4691b281b8d5635d0ec1f98002d2313a66aa2f3b68426ee40514b5087edc637407a65a2bbfee1a94ff053a081a62237ccdea86a44a67b12e372eb4fc372188dbbf59e3755d4ee3f340b01f8f100909250281c1009c182accda200abdc4013ed9098a2671af06754d4f6801cfd48e3658b1e880ae1c7f864f94541d31d73327345d391a8b8f364fcf556479021422202ca40d862f1a47980fe2fe28400e543b2d1054287c14f03effe42c154e0750caf8f85b45f45cd57d5ebfbcf4d3d3c8190b4e2aba855005ea22ce1dd30d244fc9e056d2d34ab6acf36913f9c7720cd148f4b95b3c32e442ada98feeb9b1eb8923135b3698ed18611e96f5fabcff7b9c7799d10743ead046993e388151badcb1ba6c14c1c59b0281c1008863bf5b18495c01b9a7cd859d33c5b8d5d4ad5c5a9aab24b041ebecfea292ad37eb185f7b1e988ea3223242edbe364276d021364bd48821d92d76321d3a26d59d59d41697028232dbb7a1e1f6e6a71b8fd0548407262d64f5b0cc9207642b80c7c0b6b5cc33b4e8b258cde6de0a76122f0bcc567b38ece8b481510001e17626ef1c1f7cf02c49ed58b878b05492ecf8051991727ff411b8aa037c0566ec17a88947046d86efcb7424c9cdfd7a165b3d2a3becf8e8df42a22b20150a0ab0b0c30281c100aa0b889e2a80546dd516bb1b72357dea14436c1807884255008b0aa78bef925c2d6574412abf7d1ac2b0d9a9c31e1ed37bdf53502ab5cd194317bbddcc39c8ddef964189a62190e716ff3a22f2d468ea0717e9356ee49c19a0f72d5996f4f46161d93149620cbed7ac5a3c109fb258f6e25c57130e9342fdb8e2b1fd2e081203907c8fa0de3d9e551b56e08784fe10b14a59c4cbecd3805d9d7f5b6fb928d400a617b3afe8f5d5550a6d0f75207a510a06d18e2ed2a9a86b3445c77e9281cf8b";
        let key_bytes = hex::decode(key_hex).unwrap();
        let key = KeyPair::deserialize_pkcs8_der(&key_bytes).unwrap();

        let measurement = enclave::Measurement::new([0x69; 32]);
        let is_debug_enclave = false;
        let date_ymd = Some((2024, 3, 4));
        let sigstruct = key
            .sign_sgxs(measurement, is_debug_enclave, date_ymd)
            .unwrap();
        key.verify_sigstruct_signature(&sigstruct).unwrap();

        let sigstruct_bytes = sigstruct.as_ref();

        let ref_sigstruct_hex = "06000000e10000000000010000000000000000000403242001010000600000006000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002d089f33eca9724d6d3da21e069c858d06e4724f8ec795c05fa5b922f76fbd5a4d7e3aba6abbbf9fbacda0b243fd5e0aab4bc127bf68b7f33ec74ede06e21b00d27321cb7ea8c9de1c666e644c7b0093925376bd4940955a90814a719364280d301f9ac4ac3c35da72acce74935aee0e4405598cdcbf7e900e0ffb0b7bb82b6aa11c31d67c9b42b4d8fb012108c3425f2eeb473a7f4f7724ddef3fc8318e2b249ec2be7fb8c135ec7874a0aaa22363ec5ad35e3900a8161af87e110bdb2c6db2f72f55e0ae276f8b879e4784bd39a907de6f8faf085f625be7358368e1bb071e81008024a2e25d63d1936c85b3dfc5c15a30731244eac5b6d1aff5dc7a72515b5b231eb99cff7dc828c2f1a928d017e291988b64beb51b0e46f8e3558f08cb46854d2808ffa325ba4664103ca00be49a64d53f8e58902f3dd176b8aaca36375e2597b1c44ee505eeb83a93e9ab42791c0a85faae824acf1d0ea865b831d8fffb82609dadd18bfc0de6271817d281a606979bf1784aac88807d74f8a5b6bb1dbb030000002a57921ebfe86dfb005792a08f115840bbec6810b683600241045e35758eb16d12d946892484b7bd692afd0e467f83a67c7d52337f4b255c93a55e12eedc4b9ef7f93a8eaca46f1d43fa4c78ec487d1d16474116ebeb6b9ad23e7fce48d543c8139cb298377856029ec2c673e268c8c08b59d98183b21b9c94a76fa660a37efecf08eb3022ebf8fd2ec4c958d1fb54f3a8d7a10f6510afa2970a1778ad1ed7956c5c647ad0fa767ea5329dc2ba4c84cdd7fcd765956508e18665c3d3f717aa9493658fed2baf7adc8a61b13afa7ef66a718036c90faad0d2bde8a5062f9719b6d9feaec53f4b02863a49f67bc8e0cbcb308811f0f00da8d259ac4e310d791981cb85c0c5facfa0ea5782e779b2803b828e060182e5a23204fddc23d76ae0494fa56ef2904b389cdbbb99f355c244b3da659bad69623404d629ae578339b29aa7d68de7bc3db8dea9da003d4c2f8688e32983157dfcccf585d1273c2d07b36458dac37c49e41923e3e6b4ecacf320475047506629241192c81a28c9d627715ab5000000000000000000000000000000000000000000000000000000000400000000000000e7000000000000000700000000000000e7000000000000006969696969696969696969696969696969696969696969696969696969696969000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000046125946aa89abe0abb2f78b550966be9a8571dd2a26d79a5f468439b61c1ab2ec0e44d330ee6b901eeb8132626c8b82c9d8b200e08c7387154cbaad44f3c8a41ee33505bf075cd099399ce54eff11ceb4be8fed95bedfc7636013eea95289f496b782fa433421eb6a80d8fed3b79f22113cd0b86404b4cbcc788895690a91d99eb9d5d1b90b5404323787e395b537ea9d3800983545ec7769d12df73f81e6055bafccd6769d4502be2dde9eec6d53169e5ad0071285fb9a27acad5715d689eee1ed5d24fd55f1af63133a5e78a279ede4fc95ea0f86f405f316ceadf2221aa6d4bcdfcd60b2a06878262fee018f57035b86f21cf25ba5e1097563e4d563b56d94ce6b34660708d9149236c81f7cf620d7fe57cbd92c0b1bfd31889e5defe0bd34593fa600d9f58201a05beaca9719401834b7edb9dedcd14ae9836f93dfde367b514f3b4d8336ea5a6357e5c4af78f98dd62353a93c2ea8a95864b7ff6d5a60beae2397f7528b0126494ccd130a9458d491ab29c6d3db840ea40965396c4af6eda29562ed0ae669dbdbd147474bd75b5ac3564e661717523f9c98d8223fcddf79bb4b020ef9bb46826adc02108365a6ce14cbb465f96e5e1742586b912bc4c5c3fc145bed64925c22d0c278b4ec0f59f49955757d1d4d268d0079275ed730299baa75ff3cbb1d379d6168133eb4167c0c3bae9dd029c0415a4c8294a6eff148cfaaf20762682a204dd8250dc69c45f087ba9f8f0ae90c1a599320499b5f15e878122b48a109a8c765177ff06044883fca2b270deace515dad23bf08657cda4259098e98c4db3933a89a37541c04c9d4aa73c132ef76db5d02a2ede1008b9ccb1aae8211640bf6d106dc0305e829c2bb92642e968c0c26c44b9c52f2a224aa12dd82b1b5ddfa7557b047dc9244b010b0234bee6530b9c82b469ed3e9326a9df89a0d4b5fa83f87373f392b5210b42431ab5b33d9862862bd1a744484f764bb73ad51c0244a8f36d493462e47145b30f0963be189f57cce4a17d95eb4d6790071d1e9dd97fa5224e510be7429be9828dd4462450c50740afb67d86e81b4e6e4f";
        let ref_sigstruct_bytes = hex::decode(ref_sigstruct_hex).unwrap();

        assert_eq!(sigstruct_bytes, &ref_sigstruct_bytes);
    }

    #[test]
    fn test_dev_signer_measurement() {
        let key = KeyPair::dev_signer();
        assert_eq!(key.signer_measurement(), enclave::Measurement::DEV_SIGNER);
    }

    #[test]
    fn test_ser_de() {
        // Sampling RSA keys takes a long time... (several seconds)
        let key = KeyPair::dev_signer();
        let key_bytes_pkcs8 = key.serialize_pkcs8_der();

        let key_pkcs8 =
            KeyPair::deserialize_pkcs8_der(&key_bytes_pkcs8).unwrap();

        assert_eq!(key, key_pkcs8);
    }
}
