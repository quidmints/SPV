// Identity-based ASP membership - the rescoped P2 upgrade (see PP-NOIR-FUSION.md P2 and the
// 2026-07-24 directive: "build the identity-based upgrade now using ERC identity standard").
//
// UPSTREAM (0xbow) PROBLEM: ASP membership is keyed by `label`, a value pinned per DEPOSIT
// (commitment.nr). Association-set clearance is therefore a property of one deposit event, not of
// the depositor - an already-cleared identity gets no benefit for any OTHER deposit, and
// clearance can't be reused as a standalone fact ("this identity passed screening") outside the
// specific note it was proven for.
//
// THIS GADGET proves ASP membership of an IDENTITY instead. The leaf is
// `holder_root = Poseidon2(pubkey(sk_identity).x, pubkey(sk_identity).y)` - the SAME durable
// commitment rarime's own HolderStateKeeper anchors as `holderRoot`
// (backend/contracts/contracts/holder/HolderStateKeeper.sol: "holder root (durable) = identityKey
// = Poseidon(pubkey(sk_identity))") and every document leaf is bound under
// (`Poseidon2(documentKey, holderRoot)`), and that the wallet computes as `profileKey`
// (frontend/identity-wallet/src/sdk/RarimeUtils.ts getProfileKey). We reuse
// `noir_dl::not_passports_zk_circuits::extract_pk_identity_hash` - the EXACT function rarime's own
// register_identity circuit uses for this value (not_passports_zk_circuits.nr, called with
// `sk_identity` there too) - rather than reimplement the EC scalar-mult + hash, so there is ONE
// definition of "this identity's commitment" shared by the holder tree, this ASP tree, and the
// wallet, not three that could drift.
//
// `sk_identity` is a PRIVATE witness, never a public signal - the proof shows "the prover knows an
// sk_identity whose holder_root is included in the tree at `asp_root`" without revealing WHICH
// member it is. Anonymity set = every ASP-cleared identity, matching upstream's per-label
// anonymity set (also never exposes `label` publicly - see PrivacyPool.sol's WithdrawProof
// pubSignals, which likewise omits it), just re-keyed from "cleared deposit" to "cleared
// identity".
//
// REUSABLE CLEARANCE (the actual point): because the leaf is the identity and not a deposit
// label, ANY of that identity's PP notes can be withdrawn once the identity is cleared - clearance
// is a durable per-identity fact, not a single-use deposit attribute. This is the mechanism behind
// "an already-ASP-cleared identity's clearance becomes reusable, provable evidence" for
// peer-vouching (e.g. a NotarialTitle attestation) discussed alongside this upgrade - out of scope
// for this gadget itself, which only proves membership.
use crate::holder_root::extract_pk_identity_hash;
use crate::lean_imt::lean_imt_inclusion;

pub struct IdentityAspMembership {
    // Returned, not asserted-equal-to-anything by this function - the caller decides whether to
    // expose it as a public signal. For withdrawal it should stay private (mirrors upstream: PP's
    // WithdrawProof never exposes `label` either), so ASP membership doesn't deanonymize identity
    // by revealing which member of the set is withdrawing.
    pub holder_root: Field,
}

/// Proves `sk_identity` derives `holder_root`, and that `holder_root` is included in the ASP
/// LeanIMT rooted at `asp_root`. `asp_root` is expected to be the Entrypoint's currently-active,
/// evidence-registry-anchored root (Entrypoint.updateRoot / latestActiveRoot) - this gadget only
/// checks tree inclusion; root freshness/activation-delay is enforced on-chain, unchanged from the
/// existing label-based scheme (Entrypoint doesn't care what a leaf represents).
pub fn identity_asp_membership<let MAX_DEPTH: u32>(
    sk_identity: Field,
    asp_root: Field,
    leaf_index: Field,
    siblings: [Field; MAX_DEPTH],
    actual_depth: u32,
) -> IdentityAspMembership {
    let holder_root = extract_pk_identity_hash(sk_identity);
    let computed_root = lean_imt_inclusion(holder_root, leaf_index, siblings, actual_depth);
    assert(computed_root == asp_root);

    IdentityAspMembership { holder_root }
}

// Cross-checked EMPIRICALLY (2026-07-24, not "by construction") against the wallet's real
// derivation path, using @iden3/js-crypto's babyJub + Poseidon (already established this session
// as byte-identical to noir-lang/poseidon's bn254::hash_N / poseidon-solidity - see commitment.nr
// and notes.ts's cross-check log) - the SAME primitives RarimeUtils.getProfileKey uses:
//   pubPoint = babyJub.mulPointEScalar(babyJub.Base8, 1234n)
//   holder_root = Poseidon.hash(pubPoint)              == 11639338456537070031828088151704016282968167813614481831572112488559037365741
//   asp_root    = Poseidon.hash([holder_root, 99999n]) == 6236689451309527230350628968094528759868141833300921467691845026671532338086
// (depth-1 tree: leaf_index 0 => holder_root is the LEFT child, 99999 the RIGHT sibling, matching
// lean_imt.nr's bit-0-is-left convention.) This checks extract_pk_identity_hash's OUTPUT value
// against a real, independent implementation; it does not itself run nargo (restricted this
// session - run `nargo test` to execute this assertion once approved).
#[test]
fn test_matches_wallet_profile_key_derivation() {
    let sk_identity: Field = 1234;
    let expected_holder_root: Field =
        11639338456537070031828088151704016282968167813614481831572112488559037365741;
    let expected_asp_root: Field =
        6236689451309527230350628968094528759868141833300921467691845026671532338086;

    let result = identity_asp_membership(sk_identity, expected_asp_root, 0, [99999], 1);
    assert(result.holder_root == expected_holder_root);
}
