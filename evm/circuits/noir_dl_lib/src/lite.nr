use crate::not_passports_zk_circuits::{extract_dg1_commitment, extract_pk_identity_hash, passport_hash};

/// Reduce a DG1 digest to a field element.
///
/// SKIPS digest[0] AND READS THE REMAINING 31 BYTES BIG-ENDIAN. That convention is not arbitrary
/// and not obvious: 32 bytes do not fit a BN254 field, so one byte has to go, and this drops the
/// FIRST rather than truncating the last. Any other packing - including the obvious
/// `digest[0..31]` - yields a DIFFERENT field element.
///
/// EXTRACTED SO THERE IS EXACTLY ONE COPY (sec. 2.18i). `dg1Hash` is the anti-replay key
/// that makes a physical document bindable to exactly one holder, so two registration paths that
/// pack it differently would let the SAME passport bind TWICE under two holder roots - destroying
/// the document scarcity the whole identity blacklist rests on. Every path that emits a `dg1Hash`
/// MUST call this function rather than reimplement it.
pub fn dg1_hash_field<let DG_HASH_ALGO: u32>(digest: [u8; DG_HASH_ALGO]) -> Field {
    let mut hash_diff = 0;
    if (DG_HASH_ALGO < 31) {
        hash_diff = 31 - DG_HASH_ALGO;
    }

    let mut acc: Field = 0;
    let mut place: Field = 1;
    for i in 0..(31 - hash_diff) {
        acc += place * digest[DG_HASH_ALGO - 1 - i] as Field;
        place *= 256;
    }
    acc
}

pub fn register_identity_light<
    let DG1_LEN: u32,
    let DG_HASH_ALGO: u32,
>(
    dg1: [u8; DG1_LEN],
    sk_identity: Field,

) -> (Field, Field, Field){

    
    let sk_hash = extract_pk_identity_hash(sk_identity);
    let dg1_commitment = extract_dg1_commitment::<DG1_LEN>(dg1, sk_identity);
    let dg1_hash_bytes: [u8; DG_HASH_ALGO] = passport_hash::<DG_HASH_ALGO, DG1_LEN>(dg1);
    let dg1_hash: Field = dg1_hash_field::<DG_HASH_ALGO>(dg1_hash_bytes);

    (dg1_commitment, dg1_hash, sk_hash)
}

/// KNOWN-ANSWER TEST for the digest packing - the ONE assertion here that is not self-referential.
///
/// WHY IT IS NEEDED, and what the sibling test in `register_identity` does NOT do. That test
/// compares this function's output against `register_identity_light`'s, and both call THIS
/// function - so breaking the packing here changes both sides equally and the comparison still
/// passes. I verified that by breaking it, and it did. It catches a future path that INLINES its
/// own copy; it cannot catch a change to the shared definition.
///
/// This one can, because the expected value comes from OUTSIDE Noir: it is the `dg1Hash` that
/// `tools/build-escrow-fixtures.js` computes with node's sha256 and its own explicit packing loop,
/// and that the committed escrow fixture and `HolderStateKeeper` have both agreed with since. Any
/// change to the packing breaks this, which is the point.
#[test]
fn test_dg1_hash_field_matches_the_published_vector() {
    // escrow0's DG1 - identity_asp.nr's published identity, 95-byte TD1 buffer.
    let dg1: [u8; 95] = [
        0, 0, 0, 0, 0, 80, 60, 71, 66, 82, 83, 77, 73, 84, 72, 60,
        60, 74, 79, 72, 78, 60, 65, 76, 69, 88, 65, 78, 68, 69, 82, 60,
        60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60,
        60, 60, 49, 50, 51, 52, 53, 54, 55, 56, 57, 55, 71, 66, 82, 56,
        48, 48, 49, 48, 49, 57, 77, 51, 48, 48, 49, 48, 49, 55, 60, 60,
        60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 48, 0, 0,
    ];

    let digest: [u8; 32] = passport_hash::<32, 95>(dg1);
    let packed = dg1_hash_field::<32>(digest);

    assert(
        packed
            == 25221877208166930351050665436133530901095817342996592571437213589958279235,
        "dg1_hash_field no longer matches the published fixture vector - every committed escrow proof and every bound document key just changed",
    );
}
