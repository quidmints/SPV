use std::field;
use std::hash::Hasher;
use poseidon::poseidon::PoseidonHasher;
use super::{sigver, sigver::curve_224::ecdsa_ver, sigver::ecdsa::verify_secp521r1_ecdsa, sigver::ecdsa::verify_brainpoolp512r1_ecdsa, sigver::ecdsa::verify_brainpoolp384r1_ecdsa, sigver::ecdsa::verify_secp256r1_ecdsa, big_curve::curves::secp256r1::Secp256r1Fr, sigver::ecdsa::verify_brainpoolp256r1_ecdsa, big_curve::curves::secp256r1::Secp256r1Fq};
use crate::bignum::BigNum;
use crate::sigver::brainpoolP256r1::params::{BrainpoolP256r1Fq, BrainpoolP256r1Fr};
use crate::sigver::brainpoolP384r1::params::{BrainpoolP384r1Fq, BrainpoolP384r1Fr};
use crate::sigver::brainpoolP512r1::params::{BrainpoolP512r1Fq, BrainpoolP512r1Fr};
use crate::sigver::secp521r1::params::{Secp521r1Fq, Secp521r1Fr};
// secp384r1 (NIST P-384) for SIG_TYPE 28. Unlike the brainpool curves this one lives under
// `big_curve::curves`, not `sigver::*::params`. `verify_secp384r1_ecdsa` ALREADY EXISTED in
// sigver/ecdsa.nr - it was simply never dispatched, which is why SIG_TYPE 28 verified nothing.
use crate::big_curve::curves::secp384r1::{Secp384r1Fq, Secp384r1Fr};
use crate::sigver::ecdsa::verify_secp384r1_ecdsa;

pub fn register_identity<
    let DG1_LEN: u32,
    let DG15_LEN: u32,
    let EC_LEN: u32,
    let SA_LEN: u32,
    let N: u32,
    let EC_FIELD_SIZE: u32,
    let DG_HASH_ALGO: u32,
    let HASH_ALGO: u32,
    let SIG_TYPE: u32,
    let DG1_SHIFT: u32,
    let DG15_SHIFT: u32,
    let EC_SHIFT: u32,
    let AA_SIG_TYPE: u32,
    let AA_SHIFT: u32>(
    dg1: [u8; DG1_LEN],
    dg15: [u8; DG15_LEN],
    ec: [u8; EC_LEN],
    sa: [u8; SA_LEN],
    pk: [Field; N], 
    reduction_pk: [Field; N],
    sig: [Field; N],
    sk_identity: Field,
    icao_root: Field,
    inclusion_brances: [Field; 80]
    ) -> (Field, Field, Field, Field){
    
    // 1. Verify flow

    let _ = passport_verification_flow::<
        DG1_LEN, 
        DG15_LEN, 
        EC_LEN, 
        SA_LEN, 
        DG_HASH_ALGO,
        HASH_ALGO,
        DG1_SHIFT,
        DG15_SHIFT,
        EC_SHIFT,
        >(dg1, dg15, ec, sa);

    // 2. Verify signature

    let mut sa_hash: [u8; HASH_ALGO] = passport_hash::<HASH_ALGO, SA_LEN>(sa);
    if (SIG_TYPE == 24){
        let tmp_hash: [u8; 28] = passport_hash::<28, SA_LEN>(sa);
        for i in 0..28{
            sa_hash[i] = tmp_hash[i];
        }
    }

    let _ = verify_signature::<
            N, SIG_TYPE, HASH_ALGO
        >(
            pk, reduction_pk, sig, 
            sa_hash
        );

    // 3. Verfiy merkle tree inclusion proof
    let leaf = extract_pk_hash::<N, EC_FIELD_SIZE, SIG_TYPE>(pk);
    let key  = leaf;
    let is_verfied = super::smt::smt_verifier::<80>(icao_root, leaf, key, inclusion_brances);
    assert(is_verfied == 1, "Merkle tree verification failure");

    // 4. Get dg15 pubkey hash
    let dg15_pk_hash = extract_dg15_pk_hash::<DG15_LEN, AA_SHIFT, AA_SIG_TYPE>(dg15);
    // let dg15_pk_hash = 0;

    // 5. Get dg1Commitment
    let dg1_commitment = extract_dg1_commitment::<DG1_LEN>(dg1, sk_identity);

    // 6. sk_iden_hash
    let sk_hash = extract_pk_identity_hash(sk_identity);

    // 7. Get passport hash
    let passport_hash = extract_passport_hash::<HASH_ALGO>(sa_hash);

    (dg15_pk_hash, passport_hash, dg1_commitment, sk_hash)
        
}

fn passport_verification_flow<
    let DG1_LEN: u32,
    let DG15_LEN: u32,
    let EC_LEN: u32,
    let SA_LEN: u32,
    let DG_HASH_ALGO: u32,
    let HASH_ALGO: u32,
    let DG1_SHIFT: u32,
    let DG15_SHIFT: u32,
    let EC_SHIFT: u32>(
        dg1: [u8; DG1_LEN],
        dg15: [u8; DG15_LEN],
        ec: [u8; EC_LEN],
        sa: [u8; SA_LEN],
    ){
    
    let dg1_hash: [u8; DG_HASH_ALGO] = passport_hash::<DG_HASH_ALGO, DG1_LEN>(dg1);

    
    let mut dg15_hash: [u8; DG_HASH_ALGO] = [0; DG_HASH_ALGO];
    if (DG15_LEN != 0){
        dg15_hash = passport_hash::<DG_HASH_ALGO, DG15_LEN>(dg15);
    }
    let ec_hash: [u8; HASH_ALGO] = passport_hash::<HASH_ALGO, EC_LEN>(ec);
    
    for i in 0..DG_HASH_ALGO{
        assert(dg1_hash[i] == ec[i + DG1_SHIFT], "dg1 mismatch");
        if (DG15_LEN != 0){
            assert(dg15_hash[i] == ec[i + DG15_SHIFT], "dg15 mismatch");
        }
    }
    for i in 0..HASH_ALGO{
        assert(ec_hash[i] == sa[i + EC_SHIFT], "ec mismatch");
    }
}

fn verify_signature<
    let N: u32,
    let SIG_TYPE: u32,
    let HASH_ALGO: u32>(
    pk: [Field; N],
    reduction_pk: [Field; N],
    sig: [Field; N],
    hashed: [u8; HASH_ALGO]
    ){
    
    if (SIG_TYPE == 1){

        let mut pk_fixed: [Field; 18] = [0; 18];
        let mut red_fixed: [Field; 18] = [0; 18];
        let mut sig_fixed: [Field; 18] = [0; 18];

        for i in 0..18{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }

        let _ = super::rsa::verify_rsa::<2048, 18, HASH_ALGO, 65537>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 2){
        let mut pk_fixed: [Field; 35] = [0; 35];
        let mut red_fixed: [Field; 35] = [0; 35];
        let mut sig_fixed: [Field; 35] = [0; 35];

        for i in 0..35{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }

        let _ = super::rsa::verify_rsa::<4096, 35, HASH_ALGO, 65537>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );

    }
    if (SIG_TYPE == 3){

        let mut pk_fixed: [Field; 18] = [0; 18];
        let mut red_fixed: [Field; 18] = [0; 18];
        let mut sig_fixed: [Field; 18] = [0; 18];

        for i in 0..18{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }


        let _ = super::rsa::verify_rsa::<2048, 18, HASH_ALGO, 65537>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 4){

        let mut pk_fixed: [Field; 18] = [0; 18];
        let mut red_fixed: [Field; 18] = [0; 18];
        let mut sig_fixed: [Field; 18] = [0; 18];

        for i in 0..18{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }


        let _ = super::rsa::verify_rsa::<2048, 18, HASH_ALGO, 37187>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 5){

        let mut pk_fixed: [Field; 18] = [0; 18];
        let mut red_fixed: [Field; 18] = [0; 18];
        let mut sig_fixed: [Field; 18] = [0; 18];

        for i in 0..18{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }


        let _ = super::rsa::verify_rsa::<2048, 18, HASH_ALGO, 65537>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 6){

        let mut pk_fixed: [Field; 26] = [0; 26];
        let mut red_fixed: [Field; 26] = [0; 26];
        let mut sig_fixed: [Field; 26] = [0; 26];

        for i in 0..26{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }


        let _ = super::rsa::verify_rsa::<3072, 26, HASH_ALGO, 58333>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 7){

        let mut pk_fixed: [Field; 26] = [0; 26];
        let mut red_fixed: [Field; 26] = [0; 26];
        let mut sig_fixed: [Field; 26] = [0; 26];

        for i in 0..26{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }


        let _ = super::rsa::verify_rsa::<3072, 26, HASH_ALGO, 45347>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 8){

        let mut pk_fixed: [Field; 26] = [0; 26];
        let mut red_fixed: [Field; 26] = [0; 26];
        let mut sig_fixed: [Field; 26] = [0; 26];

        for i in 0..26{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }


        let _ = super::rsa::verify_rsa::<3072, 26, HASH_ALGO, 46271>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }

    if (SIG_TYPE == 10){
        let mut pk_fixed: [Field; 18] = [0; 18];
        let mut red_fixed: [Field; 18] = [0; 18];
        let mut sig_fixed: [Field; 18] = [0; 18];

        for i in 0..18{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }

        let _ = super::rsa_pss::verify_rsa_pss::<2048, 18, HASH_ALGO, 32, 3>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 11){

        let mut pk_fixed: [Field; 18] = [0; 18];
        let mut red_fixed: [Field; 18] = [0; 18];
        let mut sig_fixed: [Field; 18] = [0; 18];

        for i in 0..18{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }
        
        let _ = super::rsa_pss::verify_rsa_pss::<2048, 18, HASH_ALGO, 32, 65537>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 12){

        let mut pk_fixed: [Field; 18] = [0; 18];
        let mut red_fixed: [Field; 18] = [0; 18];
        let mut sig_fixed: [Field; 18] = [0; 18];

        for i in 0..18{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }

        let _ = super::rsa_pss::verify_rsa_pss::<2048, 18, HASH_ALGO, 64, 65537>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 13){
           
        let mut pk_fixed: [Field; 18] = [0; 18];
        let mut red_fixed: [Field; 18] = [0; 18];
        let mut sig_fixed: [Field; 18] = [0; 18];

        for i in 0..18{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }

        let _ = super::rsa_pss::verify_rsa_pss::<2048, 18, HASH_ALGO, 48, 65537>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 14){
        let mut pk_fixed: [Field; 26] = [0; 26];
        let mut red_fixed: [Field; 26] = [0; 26];
        let mut sig_fixed: [Field; 26] = [0; 26];

        for i in 0..26{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }
        
        let _ = super::rsa_pss::verify_rsa_pss::<3072, 26, HASH_ALGO, 32, 65537>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 15){

        let mut pk_fixed: [Field; 18] = [0; 18];
        let mut red_fixed: [Field; 18] = [0; 18];
        let mut sig_fixed: [Field; 18] = [0; 18];

        for i in 0..18{
            pk_fixed[i] = pk[i];
            red_fixed[i] = reduction_pk[i];
            sig_fixed[i] = sig[i];
        }


        let _ = super::rsa_pss::verify_rsa_pss::<2048, 18, HASH_ALGO, 64, 65537>(
            pk_fixed, 
            red_fixed, 
            sig_fixed, 
            hashed
        );
    }
    if (SIG_TYPE == 21){
        let mut limbs_x: [Field; 3] = [0; 3];
        let mut limbs_y: [Field; 3] = [0; 3];
        let mut limbs_r: [Field; 3] = [0; 3];
        let mut limbs_s: [Field; 3] = [0; 3];

        for i in 0..3{
            limbs_x[i] = pk[i];
            limbs_y[i] = pk[i + 3];
            limbs_r[i] = sig[i];
            limbs_s[i] = sig[i + 3];   
        }

        let r: BrainpoolP256r1Fr = BigNum {
            limbs: limbs_r,
        };

        let s: BrainpoolP256r1Fr = BigNum {
            limbs: limbs_s
        };

        let public_key_x: BrainpoolP256r1Fq = BigNum {
            limbs: limbs_x
        };

        let public_key_y: BrainpoolP256r1Fq = BigNum {
            limbs: limbs_y
        };

        assert(verify_brainpoolp256r1_ecdsa(public_key_x, public_key_y, hashed, (r, s)));
    }
    if (SIG_TYPE == 20){
        let mut limbs_x: [Field; 3] = [0; 3];
        let mut limbs_y: [Field; 3] = [0; 3];
        let mut limbs_r: [Field; 3] = [0; 3];
        let mut limbs_s: [Field; 3] = [0; 3];

        for i in 0..3{
            limbs_x[i] = pk[i];
            limbs_y[i] = pk[i + 3];
            limbs_r[i] = sig[i];
            limbs_s[i] = sig[i + 3];   
        }

        let r: Secp256r1Fr = BigNum {
            limbs: limbs_r,
        };

        let s: Secp256r1Fr = BigNum {
            limbs: limbs_s
        };

        let public_key_x: Secp256r1Fq = BigNum {
            limbs: limbs_x
        };

        let public_key_y: Secp256r1Fq = BigNum {
            limbs: limbs_y
        };

        assert(verify_secp256r1_ecdsa(public_key_x, public_key_y, hashed, (r, s)));
    }

    if (SIG_TYPE == 23){
        let mut limbs_x: [Field; 2] = [0; 2];
        let mut limbs_y: [Field; 2] = [0; 2];
        let mut limbs_r: [Field; 2] = [0; 2];
        let mut limbs_s: [Field; 2] = [0; 2];

        for i in 0..2{
            limbs_x[i] = pk[i];
            limbs_y[i] = pk[i + 2];
            limbs_r[i] = sig[i];
            limbs_s[i] = sig[i + 2];   
        }

        let mut ext_hashed: [u8; 20] = [0;20];

        for i in 0..20{
            ext_hashed[i] = hashed[i];
        }

        sigver::curve_192::ecdsa_ver([limbs_r, limbs_s], [limbs_x, limbs_y], ext_hashed);
    }

    if (SIG_TYPE == 24){
        let mut limbs_x: [Field; 2] = [0; 2];
        let mut limbs_y: [Field; 2] = [0; 2];
        let mut limbs_r: [Field; 2] = [0; 2];
        let mut limbs_s: [Field; 2] = [0; 2];

        for i in 0..2{
            limbs_x[i] = pk[i];
            limbs_y[i] = pk[i + 2];
            limbs_r[i] = sig[i];
            limbs_s[i] = sig[i + 2];   
        }

        let mut ext_hashed: [u8; 28] = [0;28];

        for i in 0..28{
            ext_hashed[i] = hashed[i];
        }
        println([limbs_r, limbs_s]);
        println([limbs_x, limbs_y]);
        println(hashed);

        ecdsa_ver([limbs_r, limbs_s], [limbs_x, limbs_y], ext_hashed);
    }

    if (SIG_TYPE == 25){
        let mut limbs_x: [Field; 4] = [0; 4];
        let mut limbs_y: [Field; 4] = [0; 4];
        let mut limbs_r: [Field; 4] = [0; 4];
        let mut limbs_s: [Field; 4] = [0; 4];

        for i in 0..4{
            limbs_x[i] = pk[i];
            limbs_y[i] = pk[i + 4];
            limbs_r[i] = sig[i];
            limbs_s[i] = sig[i + 4];   
        }

        let r: BrainpoolP384r1Fr = BigNum {
            limbs: limbs_r,
        };

        let s: BrainpoolP384r1Fr = BigNum {
            limbs: limbs_s
        };

        let public_key_x: BrainpoolP384r1Fq = BigNum {
            limbs: limbs_x
        };

        let public_key_y: BrainpoolP384r1Fq = BigNum {
            limbs: limbs_y
        };
        
        assert(verify_brainpoolp384r1_ecdsa(public_key_x, public_key_y, hashed, (r, s)));
    }

    // SIG_TYPE 28 - secp384r1 (NIST P-384), SHA-384.
    //
    // ⚠️ THIS BRANCH'S ABSENCE WAS A SOUNDNESS HOLE, NOT A MISSING FEATURE. `verify_signature`
    // returns nothing and every branch asserts internally, so a SIG_TYPE with no branch does not
    // fail - the body simply does nothing and registration proceeds WITH THE DOCUMENT SIGNATURE
    // UNVERIFIED. The Merkle step still proves the DSC key is in the ICAO tree, but DSC public keys
    // are published in the ICAO master list, so that alone would let a prover assert an arbitrary
    // MRZ. `28_384_3_3_576_264_24_2024_4_2792` shipped in exactly that state, here and upstream.
    //
    // Identifying the curve: SIG_TYPE 28 carries N=8, EC_FIELD_SIZE=384 and SHA-384 - the same shape
    // as SIG_TYPE 25 (brainpoolP384r1). Of the two 384-bit curves in ICAO use, brainpool is already
    // 25, and secp384r1 is the only curve absent from an otherwise complete set (20 secp256r1,
    // 21 brainpoolP256r1, 23 secp192r1, 24 secp224r1, 25 brainpoolP384r1, 26 brainpoolP512r1,
    // 27 secp521r1). `verify_secp384r1_ecdsa` was already vendored and merely unreferenced.
    //
    // Structurally this is SIG_TYPE 25's branch with the curve types swapped: both are 4-limb
    // 384-bit fields and both verifiers instantiate `verify_ecdsa` with the identical <97, 48>
    // parameters, so the limb plumbing is unchanged.
    if (SIG_TYPE == 28){
        let mut limbs_x: [Field; 4] = [0; 4];
        let mut limbs_y: [Field; 4] = [0; 4];
        let mut limbs_r: [Field; 4] = [0; 4];
        let mut limbs_s: [Field; 4] = [0; 4];

        for i in 0..4{
            limbs_x[i] = pk[i];
            limbs_y[i] = pk[i + 4];
            limbs_r[i] = sig[i];
            limbs_s[i] = sig[i + 4];
        }

        let r: Secp384r1Fr = BigNum {
            limbs: limbs_r,
        };

        let s: Secp384r1Fr = BigNum {
            limbs: limbs_s
        };

        let public_key_x: Secp384r1Fq = BigNum {
            limbs: limbs_x
        };

        let public_key_y: Secp384r1Fq = BigNum {
            limbs: limbs_y
        };

        assert(verify_secp384r1_ecdsa(public_key_x, public_key_y, hashed, (r, s)));
    }

    if (SIG_TYPE == 26){
        let mut limbs_x: [Field; 5] = [0; 5];
        let mut limbs_y: [Field; 5] = [0; 5];
        let mut limbs_r: [Field; 5] = [0; 5];
        let mut limbs_s: [Field; 5] = [0; 5];

        for i in 0..5{
            limbs_x[i] = pk[i];
            limbs_y[i] = pk[i + 5];
            limbs_r[i] = sig[i];
            limbs_s[i] = sig[i + 5];   
        }

        let r: BrainpoolP512r1Fr = BigNum {
            limbs: limbs_r,
        };

        let s: BrainpoolP512r1Fr = BigNum {
            limbs: limbs_s
        };

        let public_key_x: BrainpoolP512r1Fq = BigNum {
            limbs: limbs_x
        };

        let public_key_y: BrainpoolP512r1Fq = BigNum {
            limbs: limbs_y
        };
        
        assert(verify_brainpoolp512r1_ecdsa(public_key_x, public_key_y, hashed, (r, s)));
    }

    if (SIG_TYPE == 27){
        let mut limbs_x: [Field; 5] = [0; 5];
        let mut limbs_y: [Field; 5] = [0; 5];
        let mut limbs_r: [Field; 5] = [0; 5];
        let mut limbs_s: [Field; 5] = [0; 5];

        for i in 0..5{
            limbs_x[i] = pk[i];
            limbs_y[i] = pk[i + 5];
            limbs_r[i] = sig[i];
            limbs_s[i] = sig[i + 5];   
        }

        let r: Secp521r1Fr = BigNum {
            limbs: limbs_r,
        };

        let s: Secp521r1Fr = BigNum {
            limbs: limbs_s
        };

        let public_key_x: Secp521r1Fq = BigNum {
            limbs: limbs_x
        };

        let public_key_y: Secp521r1Fq = BigNum {
            limbs: limbs_y
        };
        
        assert(verify_secp521r1_ecdsa(public_key_x, public_key_y, hashed, (r, s)));
    }
}

fn extract_dg15_pk_hash<
    let DG15_LEN: u32,
    let AA_SHIFT: u32,
    let AA_SIG_TYPE: u32>(
    dg15: [u8; DG15_LEN]
    ) -> Field{
    let mut dg15_pk_hash: Field = 0;

    if (AA_SIG_TYPE != 0){
        // RSA AA keys that are NOT 1024-bit.
        //
        // The block below hardcodes a 128-byte read (4 chunks of 25 plus one of 28), i.e. it assumes
        // every RSA Active Authentication key is 1024-bit. `14_256_1_4_1752_576_1_1496_3_512` has a
        // 768-bit one: AA_SHIFT(64) + modulus(96) + exponent(5) = 165 = DG15_LEN exactly, so the
        // 128-byte read runs 27 bytes past the end of dg15 and the profile could not be built at all.
        //
        // The selector is the EXACT structural question - does a 1024-bit key physically fit - not a
        // tuned threshold: if AA_SHIFT + 128 exceeds DG15_LEN then a 1024-bit key cannot be what is
        // stored there. No new generic is needed, and every existing profile keeps its previous
        // chunking and therefore its previous hash (all 40 have AA_SHIFT=32 with DG15_LEN >= 163, so
        // 32 + 128 = 160 fits and they take the 1024-bit path unchanged).
        //
        // ⚠️ Relies on Noir folding these comptime branches, which is not an assumption: the
        // SIG_TYPE 2 branch in verify_signature indexes pk[34], and SIG_TYPE 1 profiles with N=18
        // compile anyway - impossible unless the dead branch is eliminated before bounds checking.
        if ((AA_SIG_TYPE < 20) & (AA_SHIFT + 128 > DG15_LEN)) {
            // 768-bit: 3 chunks of 25 bytes plus one of 21 = 96.
            let mut dg15_chunks: [Field; 4] = [0; 4];
            let mut poseidon_hasher: PoseidonHasher = PoseidonHasher::default();

            for i in 0..4{
                if (i != 3){
                    let mut current = 1;
                    for j in 0..25{
                        dg15_chunks[i] += (dg15[AA_SHIFT + (24 - j) + i * 25]) as Field * current;
                        current *= 256;
                    }
                    poseidon_hasher.write(dg15_chunks[i]);
                } else {
                    let mut current = 1;
                    for j in 0..21{
                        dg15_chunks[i] += (dg15[AA_SHIFT + (20 - j) + i * 25]) as Field * current;
                        current *= 256;
                    }
                    poseidon_hasher.write(dg15_chunks[i]);
                }

                dg15_pk_hash = poseidon_hasher.finish();
            }
        }

        if ((AA_SIG_TYPE < 20) & (AA_SHIFT + 128 <= DG15_LEN)) { // rsa keys stored, 1024-bit
            let mut dg15_chunks: [Field; 5] = [0; 5];
            let mut poseidon_hasher: PoseidonHasher = PoseidonHasher::default();

            for i in 0..5{
                if (i !=4){
                    let mut current = 1;
                    for j in 0..25{ // 200 bit
                        dg15_chunks[i] += (dg15[AA_SHIFT + (24 - j) + i * 25]) as Field * current;
                        current *= 256;
                    }
                    poseidon_hasher.write(dg15_chunks[i]);

                } else {
                    let mut current = 1;
                    for j in 0..28{ // 224 bit
                        dg15_chunks[i] += (dg15[AA_SHIFT + (27 - j) + i * 25]) as Field * current;
                        current *= 256;
                    }
                    poseidon_hasher.write(dg15_chunks[i]);

                }

                dg15_pk_hash = poseidon_hasher.finish();
                
            }

        }

        // ⚠️ MUST be an explicit test, not the `else` of the RSA branch. The RSA case is now split in
        // two (1024-bit and 768-bit), so an `else` would send every non-1024-bit RSA key into the
        // ECDSA reader instead of its own branch.
        if (AA_SIG_TYPE >= 20) { // ecdsa key stored
            let mut HASH_SIZE = 31;
            let mut EC_FIELD_SIZE = 32;
            if (AA_SIG_TYPE == 22){
                EC_FIELD_SIZE = 40;
            }
            // AA_SIG_TYPE 24 is secp224r1: coordinates are 28 bytes, not the 32 this fell through to.
            // Without this the extractor reads x starting 4 bytes off and y at 32 bytes after x
            // instead of 28, so BOTH coordinates come from the wrong bytes and dg15_pk_hash does not
            // commit to the actual AA key. HASH_SIZE must drop to 28 as well - it is capped by the
            // coordinate width (28 < 31), exactly as type 23 caps it at 24, and leaving it at 31
            // would make X_Y_SHIFT (EC_FIELD_SIZE - HASH_SIZE) underflow.
            //
            // ⚠️ AA_SIG_TYPE 25 (brainpoolP384r1, 48-byte coordinates) IS ALSO WRONG HERE and is
            // deliberately NOT fixed: its only profile, 20_256_3_5_336_248_25_2120_5_1816, is
            // UNSATISFIABLE with the correct width. The read spans AA_SHIFT - 1 + 2*EC_FIELD_SIZE
            // regardless of HASH_SIZE, so 227 - 1 + 96 = 322 needs DG15_LEN >= 323 while
            // DG15_BLOCK_NUMBER=5 caps it at 5*64 - 9 = 311. It is satisfiable ONLY under the wrong
            // 32-byte width, which would ship a verifier committing to garbage. A branch for it
            // would be unreachable code; the consistency checker rejects the profile by table instead.
            if (AA_SIG_TYPE == 24){
                EC_FIELD_SIZE = 28;
                HASH_SIZE = 28;
            }
            // AA_SIG_TYPE 25 is brainpoolP384r1: 48-byte coordinates, not the 32 default. HASH_SIZE
            // stays 31 because it is a cap (31 < 48), so X_Y_SHIFT becomes 17 and the low 31 bytes of
            // each coordinate are folded in, exactly as for the other wide curves.
            if (AA_SIG_TYPE == 25){
                EC_FIELD_SIZE = 48;
            }
            if (AA_SIG_TYPE == 23){
                EC_FIELD_SIZE = 24;
                HASH_SIZE = 24;
            }

            let X_Y_SHIFT = EC_FIELD_SIZE - HASH_SIZE;
            let mut x = 0;
            let mut y = 0;


            let mut current = 1;
            for j in 0..HASH_SIZE{ 
                x += (dg15[AA_SHIFT + (HASH_SIZE - 1 - j) + X_Y_SHIFT]) as Field * current;
                y += (dg15[AA_SHIFT + (HASH_SIZE - 1 - j) + X_Y_SHIFT + EC_FIELD_SIZE]) as Field * current;
                current *= 256;
            }

            let mut poseidon_hasher: PoseidonHasher = PoseidonHasher::default();
            poseidon_hasher.write(x);
            poseidon_hasher.write(y);
            dg15_pk_hash = poseidon_hasher.finish();
        }
    }

    dg15_pk_hash
}

pub fn extract_dg1_commitment<
    let DG1_LEN: u32>(
    dg1: [u8; DG1_LEN], 
    sk_identity: Field) -> Field{
    let mut poseidon_hasher = PoseidonHasher::default();

    let mut dg1_bits: [Field; DG1_LEN * 8] = [0; DG1_LEN * 8];

    for i in 0..DG1_LEN{
        let tmp_bits = u8_to_8_u1(dg1[i]);
        for j in 0..8{
            dg1_bits[i * 8 + j] = tmp_bits[j];
        }
    }

    for i in 0..4{
        let mut chunk = 0;
        let mut current = 1;
        for j in 0..(DG1_LEN * 2){
            chunk += (dg1_bits[i * 2 * DG1_LEN + j ] as Field) * current;
            current = current * 2;
        }
        poseidon_hasher.write(chunk);
    }

    let mut poseidon_hasher_2 = PoseidonHasher::default();
    poseidon_hasher_2.write(sk_identity);
    poseidon_hasher.write(poseidon_hasher_2.finish());

    poseidon_hasher.finish()
}

pub fn extract_pk_identity_hash<>(
    sk_identity: Field
    ) -> Field{
    let mut hasher = PoseidonHasher::default();
    let point = super::jubjub::priv_to_pub(sk_identity);
    hasher.write(point.0);
    hasher.write(point.1);
    
    hasher.finish()

}

fn extract_passport_hash<
    let HASH_TYPE:u32>(
    sa_hash: [u8; HASH_TYPE]
    )->Field{

    let mut poseidon_hasher = PoseidonHasher::default();
    let mut sa_hash_bits: [Field; 252] = [0; 252];

    if (HASH_TYPE >= 32){
        for i in 0..32{
            let tmp_bits = u8_to_8_u1(sa_hash[i]);
            if (i != 31){
                for j in 0..8{
                    sa_hash_bits[i * 8 + j] = tmp_bits[j];
                }
            } else {
                for j in 0..4{ // 248 - 251 bits
                    sa_hash_bits[i * 8 + j] = tmp_bits[j];
                }
            }
        } 
    } else {
        for i in 0..HASH_TYPE{
            let tmp_bits = u8_to_8_u1(sa_hash[i]);
            
            for j in 0..8{
                sa_hash_bits[i * 8 + j] = tmp_bits[j];
            }
        } 
    }
    let mut current = 1;
    let mut preimage = 0;
    for i in 0..252{
        preimage += (sa_hash_bits[i] as Field) * current;
        current *= 2;
    }

    poseidon_hasher.write(preimage);
    poseidon_hasher.finish()
}

fn extract_pk_hash<
    let N: u32,
    let EC_FIELD_SIZE: u32,
    let SIG_TYPE: u32>(
        pubkey: [Field; N] 
    ) -> Field{
    let mut out = 0;

    if (SIG_TYPE < 20){
        let mut pk_bits: [Field; 960] = [0; 960];
        for i in 0..8{
            let bits: [Field; 120] = crate::utils::bits_to_field(pubkey[i].to_le_bits());
            for j in 0..120{
                pk_bits[i * 120 + j] = bits[j];
            }
        }

        let mut chunks: [Field; 15] = [0; 15];
        for i in 0..15{
            let mut current = 1;
            for j in 0..64{
                chunks[i] += (pk_bits[i * 64 + j] as Field) * current;
                current *= 2;
            }
        }
        let mut hasher = PoseidonHasher::default();
        for i in 0..5{
            hasher.write(chunks[i * 3] * 340282366920938463463374607431768211456 + chunks[i * 3 + 1] * 18446744073709551616 + chunks[i * 3 + 2]);
        }

        out = hasher.finish();

    } else {

        let mut DIFF = 0;
        if (EC_FIELD_SIZE > 248){
            DIFF = EC_FIELD_SIZE - 248;
        }
        let mut x_bits: [Field; EC_FIELD_SIZE] = [0; EC_FIELD_SIZE]; 
        let mut y_bits: [Field; EC_FIELD_SIZE] = [0; EC_FIELD_SIZE]; 

        for i in 0..((N / 2)){
            if i != ((N/2) - 1){
                let bits_x = pubkey[i].to_le_bits::<120>();
                let bits_y = pubkey[i + (N / 2)].to_le_bits::<120>();
                for j in 0..120{
                    x_bits[i * 120 + j] = bits_x[j] as Field;
                    y_bits[i * 120 + j] = bits_y[j] as Field;
                }
            } else {
                let bits_x = pubkey[i].to_le_bits::<EC_FIELD_SIZE % 120>();
                let bits_y = pubkey[i + (N / 2)].to_le_bits::<EC_FIELD_SIZE % 120>();
                for j in 0..(EC_FIELD_SIZE % 120){
                    x_bits[i * 120 + j] = bits_x[j] as Field;
                    y_bits[i * 120 + j] = bits_y[j] as Field;
                }
            }
        }

        let mut current = 1;
        let mut res_x = 0;
        let mut res_y = 0;
        for i in 0..EC_FIELD_SIZE - DIFF{
            res_x += (x_bits[i] as Field) * current;
            res_y += (y_bits[i] as Field) * current;
            current *= 2;
        }   

        let mut hasher = PoseidonHasher::default();
        
        hasher.write(res_x);
        hasher.write(res_y);
        
        out = hasher.finish();

    }
    out
}

fn u8_to_8_u1(x:u8) -> [Field; 8]{
    let out = unsafe { __u8_to_8_u1(x) };
    assert((out[0] as u8) * 128 +
            (out[1] as u8) * 64 + 
            (out[2] as u8) * 32 + 
            (out[3] as u8) * 16 + 
            (out[4] as u8) * 8 +
            (out[5] as u8) * 4 + 
            (out[6] as u8) * 2 +
            (out[7] as u8) == x, "byte to bits conversion");
    out
}

unconstrained fn __u8_to_8_u1(x:u8) -> [Field; 8]{
    let mut x_clone = x;
    let mut out: [Field; 8] = [0; 8];
    for i in 0..8{
        out[7 - i] = (x_clone % 2) as Field;
        x_clone = x_clone / 2;
    }
    out
}

pub fn passport_hash<let HASH_SIZE: u32, let N: u32>(preimage: [u8; N]) -> [u8; HASH_SIZE]{
    let mut out: [u8; HASH_SIZE] = [0; HASH_SIZE];
    if (HASH_SIZE == 20){
        let hash_result = super::sha1::digest(preimage);
        for i in 0..20{
            out[i] = hash_result[i];
        }
    }
    if (HASH_SIZE == 28){
        let hash_result = super::sha224::digest(preimage);
        for i in 0..28{
            out[i] = hash_result[i];
        }
    }
    if (HASH_SIZE == 32){
        let hash_result = sha256::digest(preimage);
        for i in 0..32{
            out[i] = hash_result[i];
        }
    }
    if (HASH_SIZE == 48){
        let hash_result = super::sha384::digest(preimage);
        for i in 0..48{
            out[i] = hash_result[i];
        }
    }
    if (HASH_SIZE == 64){
        let hash_result = crate::sha512::digest(preimage);
        for i in 0..64{
            out[i] = hash_result[i];
        }
    }

    out
}
