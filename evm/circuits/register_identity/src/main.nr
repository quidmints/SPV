//registerIdentity_3_160_3_3_336_200_NA
//
// THE FULL REGISTRATION CIRCUIT - the permissionless enrolment path (sec. 2.18g/2.18h).
//
// Unlike `register_identity_light`, this verifies the ENTIRE ICAO chain in-circuit:
//   1. DG1 hashes into EC, EC hashes into the signed attributes (the SOD chain)
//   2. the DSC's signature over those attributes
//   3. the DSC public key's inclusion in the ICAO master tree at `icao_root`
// NO backend signature, NO certificate dispatcher: that is the whole point - enrolment through this
// path cannot be refused to one person, because nothing about it is per-person.
//
// ============================================================================================
// READ THIS BEFORE WRITING THE CONSUMING CONTRACT (sec. 2.18k).
//
// STEP 3 IS VACUOUS UNLESS THE CONTRACT PINS `icao_root`. The tree is proven against whatever root
// the PROVER supplies, and rarime's own witness generator supplies a fake one:
//
//     const branches = new Array(80).fill(0);
//     const root = poseidon([pk_hash, pk_hash, 1n]);   // a ONE-LEAF tree, holding this very key
//
// With all-zero siblings the SMT verifier reduces to exactly that hash and accepts by construction.
// So anyone can generate their own CSCA/DSC, sign a fabricated SOD over a fabricated MRZ, set
// `icao_root` to the hash of their own key, and produce a COMPLETELY VALID proof of this circuit.
//
// `icao_root` is returned as a public output for exactly one reason: so the contract can check it.
// **That check is the entire security of this path.** Without it the circuit proves only that the
// prover can sign their own documents.
//
// AND THE PARAMETER IS MISNAMED, WHICH IS ITS OWN TRAP. Despite the name, the correct check is NOT
// against `StateKeeper.icaoMasterTreeMerkleRoot()`. The tree this circuit walks holds DSC keys -
// `leaf = extract_pk_hash(pk)` where `pk` is the key that signed the SOD - and `StateKeeper` keeps
// exactly that tree as `certificatesSmt`, whose leaves are added key-equals-value
// (`certificatesSmt.add(certificateKey_, certificateKey_)`), matching this circuit's `key = leaf`.
// So the check is:
//
//     PoseidonSMT(stateKeeper.certificatesSmt()).isRootValid(icao_root)
//
// `icaoMasterTreeMerkleRoot` is a DIFFERENT structure entirely - a keccak256 Merkle tree of CSCA
// public keys, consumed only by `Registration2.registerCertificate` when admitting a DSC. Comparing
// this circuit's root against it would reject every genuine proof while looking principled.
//
// AND THE TEST FOR IT CANNOT BE THE HAPPY PATH. Any fixture must use the fake single-leaf root - we
// hold no real DSC private key - so a suite that configures the state keeper with the fixture's own
// root passes whether or not the check exists. The test that carries the property is the NEGATIVE
// one: a proof bearing a DIFFERENT `icao_root` must be REJECTED.
// ============================================================================================
//
// `dg1_hash` IS RETURNED, AND THAT IS A DELIBERATE ADDITION (sec. 2.18i).
//
// It closes a trap that would otherwise be invisible until it had already cost someone their
// scarcity guarantee. `HolderRegistration._replayKey` keys anti-replay on `dg1Hash` - the value
// that makes one physical document bindable to exactly ONE holder root. This circuit originally
// returned `passport_hash` (over the SOD's signed attributes) and NOT `dg1_hash`. Had the
// permissionless path keyed on `passportHash` while the signer path kept `dg1Hash`, the SAME
// PASSPORT could have been bound TWICE under two different holder roots - one through each door -
// and the identity blacklist rests entirely on that not being possible. It is exactly the defect
// sec. 2.13n's `_replayKey` fix closed, reappearing through a second entrance.
//
// Computed with `noir_dl::lite::dg1_hash_field`, the SAME function `register_identity_light` uses,
// so the two paths cannot drift: there is one definition of the packing, not two.
use noir_dl::lite::dg1_hash_field;
use noir_dl::not_passports_zk_circuits::{passport_hash, register_identity};

/// sha256 - must match the DG_HASH_ALGO the light path uses, or the two dg1Hashes differ.
global DG_HASH_ALGO: u32 = 32;
/// TD3: 2 MRZ lines x 44 chars, plus a 5-byte tag/length header.
global DG1_LEN: u32 = 93;

fn main(
	dg1: [u8; DG1_LEN],
	ec: [u8; 126],
	sa: [u8; 62],
	pk: [Field; 18],
	reduction_pk: [Field; 18],
	sig: [Field; 18],
	sk_identity: Field,
	icao_root: Field,
	inclusion_branches: [Field; 80]) -> pub (Field, Field, Field, Field, Field, Field){
	// beta.13 rejects `[u8; 0]` as an entry-point type. This variant has no DG15 (note the DG15
	// length generic below is 0), so the parameter carried no data - it is constructed locally
	// instead. Constraints and public inputs are unchanged; only the witness map loses an empty
	// entry.
	let dg15: [u8; 0] = [];
	let tmp = register_identity::<
		DG1_LEN,
		0,
		126,
		62,
		18,
		0,
		20,
		20,
		3,
		25,
		0,
		42,
		0,
		0>(
	dg1, dg15, ec, sa, pk, reduction_pk, sig, sk_identity, icao_root, inclusion_branches);

	// The anti-replay key. See the header: this is what stops one passport binding to two holders.
	let dg1_hash = dg1_hash_field::<DG_HASH_ALGO>(passport_hash::<DG_HASH_ALGO, DG1_LEN>(dg1));

	(tmp.0, tmp.1, tmp.2, tmp.3, icao_root, dg1_hash)
}

/// The two registration paths MUST agree on `dg1Hash` for the same document.
///
/// WHAT THIS CATCHES, PRECISELY - and it is narrower than it first looks. Both sides call
/// `lite::dg1_hash_field`, so changing THAT function moves both together and this still passes. I
/// checked by breaking the packing, and it did pass. What this catches is a future edit where one
/// path stops calling the shared function and inlines its own copy - which is the realistic
/// regression, since inlining is what someone reaching for "just compute the hash here" would do.
///
/// THE NON-VACUOUS GUARD IS ELSEWHERE: `lite::test_dg1_hash_field_matches_the_published_vector`
/// pins the packing against a value computed OUTSIDE Noir, by the fixture generator's own sha256.
/// That one does fail when the packing changes. Both are needed; neither substitutes for the other.
///
/// The stake either way: if the paths disagree, the same passport binds twice - once through the
/// signer path, once through the permissionless one - and the document scarcity the entire identity
/// blacklist depends on silently stops holding.
#[test]
fn test_dg1_hash_agrees_with_the_light_registration_path() {
	let mut dg1: [u8; DG1_LEN] = [0; DG1_LEN];
	// Arbitrary but non-trivial - an all-zero DG1 could agree by accident.
	for i in 0..DG1_LEN {
		dg1[i] = ((i * 7 + 13) % 251) as u8;
	}

	let light = noir_dl::lite::register_identity_light::<DG1_LEN, DG_HASH_ALGO>(dg1, 4242);
	let light_dg1_hash = light.1;

	let full_dg1_hash = dg1_hash_field::<DG_HASH_ALGO>(passport_hash::<DG_HASH_ALGO, DG1_LEN>(dg1));

	assert(
		full_dg1_hash == light_dg1_hash,
		"the two registration paths disagree on dg1Hash - one passport could bind to two holders",
	);
}
