//registerIdentity_3_160_3_3_336_200_NA_td1
//
// THE TD1 (ID-CARD) FULL REGISTRATION CIRCUIT - the permissionless enrolment path at the length the
// rest of the live system actually uses (sec. 2.18j / 2.18z).
//
// WHY THIS EXISTS. `register_identity` is TD3: a passport booklet, `DG1_LEN = 93`. Everything else
// on the live path is TD1 at 95 - `register_identity_light_td1`, `escrow_envelope`, and the wallet,
// whose vendored rarime circuit registry points exclusively at `.../id_cards/`. The two could not
// interoperate: a document registered through the 93-byte circuit produces a `registrationSmt` leaf
// that `escrow_envelope` can never reproduce, because `dgCommit` is computed over a different
// number of bytes. **So the permissionless path registered documents that could not reach the
// pool.** This closes that.
//
// IDENTICAL TO `register_identity` IN EVERY OTHER PARAMETER. Only `DG1_LEN` changes. The SOD layout
// generics - `EC_LEN`, `SA_LEN`, `DG1_SHIFT`, `EC_SHIFT` - describe where hashes sit INSIDE the
// signed attributes and encapsulated content, which is a property of the SOD encoding rather than
// of the MRZ's length, so they carry over unchanged.
//
// WHAT IS VERIFIED HERE AND WHAT IS NOT, stated rather than implied:
//   - VERIFIED: `dg1_hash` agrees with `register_identity_light` AT 95 BYTES, which is the property
//     the whole anti-replay argument rests on (sec. 2.18i). That test runs today.
//   - NOT VERIFIED: the SOD layout constants against a REAL TD1 document. No such document exists
//     here, and we do not fabricate an ICAO chain to pretend otherwise (sec. 2.18k). The shifts are
//     inherited from the profile this circuit is named for; a real card may need a different
//     variant, which is a parameter change and not a redesign.
//
// The header comment is the circuit's own name, per rarime's convention - `autogen.sh` reads it.
use noir_dl::lite::dg1_hash_field;
use noir_dl::not_passports_zk_circuits::{passport_hash, register_identity};

/// sha256 - must match the DG_HASH_ALGO the light path uses, or the two `dg1Hash`es differ.
global DG_HASH_ALGO: u32 = 32;
/// TD1: 3 MRZ lines x 30 chars, plus a 5-byte tag/length header.
global DG1_LEN: u32 = 95;

fn main(
	dg1: [u8; DG1_LEN],
	ec: [u8; 126],
	sa: [u8; 62],
	pk: [Field; 18],
	reduction_pk: [Field; 18],
	sig: [Field; 18],
	sk_identity: Field,
	icao_root: Field,
	inclusion_branches: [Field; 80]) -> pub (Field, Field, Field, Field, Field, Field, Field){
	// beta.13 rejects `[u8; 0]` as an entry-point type, and this profile carries no DG15 (the
	// generic below is 0), so the parameter is constructed locally instead. Constraints and public
	// inputs are unchanged; only the witness map loses an empty entry.
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

	// The anti-replay key. See register_identity/src/main.nr for why this output exists at all:
	// without it the two registration paths would key on different values and one document could
	// bind twice under two holder roots.
	let dg1_hash = dg1_hash_field::<DG_HASH_ALGO>(passport_hash::<DG_HASH_ALGO, DG1_LEN>(dg1));

	// THE EXPIRY, so `notAfter` stops being a lie (sec. 2.18gz-nocontroller).
	//
	// `HolderRegistration` hardcodes `notAfter = 0` because "nothing in the proof attests an
	// expiry", and that was true of THIS circuit while being false of the codebase: `query.nr`
	// has read the field for TD1 all along. A document's expiry is stated by the issuing state and
	// signed into the SOD, so it needs no authority to attest it - which is why emitting it here
	// removes a whole class of controller-driven revocation rather than merely adding a field.
	//
	// Offsets are the ones `td1_dg1_data_extractor` uses (EXPIRATION_DATE_SHIFT = 43, size 6), read
	// big-endian into a Field. They are INLINED rather than imported: that extractor is private and
	// lives in `query.nr`, which the 88 profile circuits also link, and this session measured that
	// touching shared library code perturbs unrelated verification keys.
	//
	// ⚠️ This is the raw YYMMDD digits as bytes, NOT a timestamp. The consumer converts; the circuit
	// must not, because a century window is policy and would be baked into a verifier if decided here.
	let mut expiry_date: Field = 0;
	let mut place: Field = 1;
	for i in 0..6 {
		expiry_date += place * dg1[43 + 6 - 1 - i] as Field;
		place *= 256;
	}

	(tmp.0, tmp.1, tmp.2, tmp.3, icao_root, dg1_hash, expiry_date)
}

/// The TD1 permissionless path must agree with the TD1 LIGHT path on `dg1Hash`.
///
/// This is the whole reason the length mattered. `escrow_envelope` reproduces a document's leaf by
/// recomputing `dgCommit` over 95 bytes; `HolderRegistration._replayKey` keys anti-replay on
/// `dg1Hash`. If this circuit and `register_identity_light` disagreed at the same length, a document
/// enrolled permissionlessly could never be escrowed - which is precisely the defect this variant
/// exists to fix, and it would be silent.
#[test]
fn test_dg1_hash_agrees_with_the_light_path_at_td1_length() {
	let mut dg1: [u8; DG1_LEN] = [0; DG1_LEN];
	// Arbitrary but non-trivial - an all-zero DG1 could agree by accident.
	for i in 0..DG1_LEN {
		dg1[i] = ((i * 11 + 7) % 251) as u8;
	}

	let light = noir_dl::lite::register_identity_light::<DG1_LEN, DG_HASH_ALGO>(dg1, 909090);
	let full = dg1_hash_field::<DG_HASH_ALGO>(passport_hash::<DG_HASH_ALGO, DG1_LEN>(dg1));

	assert(
		full == light.1,
		"TD1 full and light registration disagree on dg1Hash - a document enrolled through one could never be escrowed",
	);
}

/// And the dgCommit the leaf carries must match too, since that is what escrow reproduces.
#[test]
fn test_dg_commit_agrees_with_the_light_path_at_td1_length() {
	let mut dg1: [u8; DG1_LEN] = [0; DG1_LEN];
	for i in 0..DG1_LEN {
		dg1[i] = ((i * 11 + 7) % 251) as u8;
	}
	let sk: Field = 909090;

	let light = noir_dl::lite::register_identity_light::<DG1_LEN, DG_HASH_ALGO>(dg1, sk);
	let direct = noir_dl::not_passports_zk_circuits::extract_dg1_commitment::<DG1_LEN>(dg1, sk);

	assert(
		direct == light.0,
		"dgCommit disagrees at TD1 length - escrow could not reproduce the registration leaf",
	);
}
