// holder_root derivation - the identity commitment shared by circuit, contract and wallet.
//
// COPIED VERBATIM from rarime's noir_dl_lib/src/not_passports_zk_circuits.rs
// `extract_pk_identity_hash`. See jubjub.nr's header for why PP carries its own copy rather than
// depending on the whole passport library.
//
// MUST stay byte-identical to:
//   - HolderStateKeeper.sol's `holderRoot` / `identityKey` (Poseidon(pubkey(sk_identity)))
//   - the wallet's RarimeUtils.getProfileKey
// The published test vectors in identity_asp.nr / title_holder.nr are the enforcement.
use crate::jubjub::priv_to_pub;
use poseidon::poseidon::PoseidonHasher;
use std::hash::Hasher;

/// Poseidon(pubkey(sk_identity).x, pubkey(sk_identity).y).
pub fn extract_pk_identity_hash(sk_identity: Field) -> Field {
    let mut hasher = PoseidonHasher::default();
    let point = priv_to_pub(sk_identity);
    hasher.write(point.0);
    hasher.write(point.1);

    hasher.finish()
}
