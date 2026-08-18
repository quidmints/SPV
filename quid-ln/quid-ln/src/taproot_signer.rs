//! MuSig2 (BIP327) key-path signing core for QU!D **simple taproot channels**.
//!
//! This module is the signing-core for milestone **M2** of the taproot-channel
//! build (`docs/TAPROOT-CHANNELS-BUILD-SPEC.md`). It provides:
//!
//! * [`derive_secnonce_seed`] — the **deterministic per-commitment** MuSig2 nonce
//!   seed, per the BOLT simple-taproot-channels scheme. The secret nonce is
//!   derived from the channel's shachain root and the commitment **height** via
//!   an HMAC; it is therefore **re-derivable** (crash-safe), **never random**, and
//!   **never persisted**. A fixed `(root, height)` always yields the identical
//!   seed, and two distinct heights yield distinct seeds — so a `SecNonce` is
//!   never reused with a different message across a restart (the reuse hazard that
//!   randomization or a persisted-nonce DB would reintroduce).
//!
//! * [`key_path_sign_2of2`] — a 2-party MuSig2 key-path sign helper driving the
//!   conduition [`FirstRound`]/[`SecondRound`] flow end-to-end (KeySort → KeyAgg →
//!   `with_unspendable_taproot_tweak` → exchange `PubNonce` → partial-sign →
//!   partial-verify-on-receive → aggregate → BIP340 [`schnorr::Signature`]).
//!
//! ## Nonce scheme (BIP327 §nonce-gen + BOLT)
//!
//! ```text
//!   musig2_shachain_root = sha256(shachain_root)            // domain-separate the root
//!   nonce_seed(height)   = HMAC-SHA256(key = musig2_shachain_root,
//!                                      msg = height.to_be_bytes())
//! ```
//!
//! The 32-byte seed feeds conduition's `SecNonce` derivation
//! (`SecNonce::build_with_pubkey(seed, ..)`), which additionally binds the
//! aggregated pubkey, the signer's own pubkey, and (via the round) the message —
//! so even an accidental seed collision would not by itself produce a reused
//! `(nonce, message)` pair. We nonetheless guarantee seed uniqueness per height.
//!
//! ## Why this, not random nonces
//!
//! BIP327 permits a deterministic nonce derived from secret key material + a
//! unique per-session input; the BOLT pins that unique input to the commitment
//! height. This is the interop-correct scheme AND removes any nonce state to
//! persist. Re-deriving for a fixed `(root, height)` is safe because the message
//! signed at a given height is itself fixed; signing two *different* messages at
//! the same height is a protocol violation handled at a higher layer (the height
//! advances per state).

use bitcoin::hashes::{sha256, Hash, Hmac, HmacEngine, HashEngine};

use musig2::secp256k1::{PublicKey, SecretKey, XOnlyPublicKey};
use musig2::{FirstRound, KeyAggContext, PartialSignature, PubNonce, SecNonceSpices};

/// Domain-separation prefix folded into the HMAC key alongside the shachain root.
///
/// Hashing the raw root first (`sha256(shachain_root)`) matches the spec formula
/// (`musig2_shachain_root = …`) and ensures the HMAC key is not the raw root.
fn musig2_shachain_root(shachain_root: &[u8; 32]) -> sha256::Hash {
    sha256::Hash::hash(shachain_root)
}

/// Derive the **deterministic** 32-byte MuSig2 secret-nonce *seed* for a given
/// commitment `height` from the channel's `shachain_root`.
///
/// `nonce_seed = HMAC-SHA256(key = sha256(shachain_root), msg = height_be)`.
///
/// Properties (asserted in tests):
/// * deterministic — same `(root, height)` ⇒ same seed (crash-safe re-derive);
/// * height-unique — different `height` ⇒ different seed (no cross-height reuse);
/// * never random, never persisted.
pub fn derive_secnonce_seed(shachain_root: &[u8; 32], height: u64) -> [u8; 32] {
    let key = musig2_shachain_root(shachain_root);
    let mut engine = HmacEngine::<sha256::Hash>::new(&key[..]);
    engine.input(&height.to_be_bytes());
    let mac: Hmac<sha256::Hash> = Hmac::from_engine(engine);
    *mac.as_byte_array()
}

/// Domain separator mixed into the secret-nonce seed for the **counterparty's**
/// commitment. The holder and counterparty commitment transactions are signed at
/// the SAME commitment height (both count down from `INITIAL_COMMITMENT_NUMBER`
/// in lockstep), so an untagged `(root, height)` seed yields the SAME nonce for
/// both — and signing the two different commitment sighashes under one nonce
/// leaks the funding key (`x = (s1 - s2)/(e1 - e2)`). The holder path keeps the
/// untagged seed; only the counterparty path is tagged, so the two nonces are
/// unconditionally distinct at every height.
pub const COUNTERPARTY_COMMITMENT_NONCE_TAG: &[u8] = b"quid/musig2/counterparty-commitment";

/// Domain-separated [`derive_secnonce_seed`]: HMACs `domain || height` so a
/// tagged derivation can never collide with the untagged holder-commitment seed
/// at the same height. Distinct `domain` ⇒ distinct seed; height-uniqueness holds
/// within a domain.
pub fn derive_secnonce_seed_domain(
    shachain_root: &[u8; 32],
    height: u64,
    domain: &[u8],
) -> [u8; 32] {
    let key = musig2_shachain_root(shachain_root);
    let mut engine = HmacEngine::<sha256::Hash>::new(&key[..]);
    engine.input(domain);
    engine.input(&height.to_be_bytes());
    let mac: Hmac<sha256::Hash> = Hmac::from_engine(engine);
    *mac.as_byte_array()
}

/// Domain separator for the DEAD-MAN EXIT (#114) pre-signing. The fleet (which
/// holds BOTH key halves under Option B) pre-signs a unilateral-exit tx OUTSIDE the
/// live commitment/close flow, so its secret nonce MUST be unable to collide with a
/// holder (untagged) or counterparty (`COUNTERPARTY_COMMITMENT_NONCE_TAG`) commitment
/// nonce at ANY height — else two partials over different sighashes could share a
/// secret nonce and leak the funding key (`x = (s1-s2)/(e1-e2)`). This tag guarantees
/// the dead-man derivation is disjoint from both commitment domains.
pub const DEAD_MAN_EXIT_NONCE_TAG: &[u8] = b"quid/musig2/dead-man-exit";

/// KeySort the two 33-byte compressed funding keys lexicographically (smaller
/// serialized key first), then build the cached [`KeyAggContext`] with the
/// BIP341 §158 key-path-only (empty merkle root) taproot tweak applied.
///
/// This is the exact `KeyAgg(KeySort(..)).with_unspendable_taproot_tweak()`
/// pattern from [`crate::`]`..funding::channel_taproot_script_pubkey` (M1); the
/// signer, the counterparty and the EVM contract MUST all use this identical sort
/// or `Q` mismatches → unspendable funding.
///
/// Returns `(ctx, signer_index)` where `signer_index` is the position of
/// `my_funding_pubkey` in the sorted key list (the index conduition's round API
/// requires). Errors only on a degenerate aggregate/tweak (unreachable for two
/// distinct valid pubkeys).
pub fn channel_key_agg_ctx(
    lp: &[u8; 33],
    hop: &[u8; 33],
    my_funding_pubkey: &[u8; 33],
) -> Result<(KeyAggContext, usize), KeyAggError> {
    let (lo, hi) = if lp[..] < hop[..] { (lp, hop) } else { (hop, lp) };
    let lo_pk = PublicKey::from_slice(lo).map_err(|_| KeyAggError::BadPubkey)?;
    let hi_pk = PublicKey::from_slice(hi).map_err(|_| KeyAggError::BadPubkey)?;

    let ctx = KeyAggContext::new([lo_pk, hi_pk])
        .map_err(|_| KeyAggError::Aggregate)?
        .with_unspendable_taproot_tweak()
        .map_err(|_| KeyAggError::Tweak)?;

    // Which slot are we? Compare the sorted ordering against our own key.
    let signer_index = if my_funding_pubkey[..] == lo[..] {
        0
    } else if my_funding_pubkey[..] == hi[..] {
        1
    } else {
        return Err(KeyAggError::NotAParticipant);
    };
    Ok((ctx, signer_index))
}

/// The x-only tweaked aggregate output key `Q` (32 bytes) for a built context —
/// the key a BIP340 verifier checks the aggregated key-path signature against,
/// and the key committed in the P2TR funding `scriptPubKey` (`0x5120 || Q`).
pub fn aggregated_xonly(ctx: &KeyAggContext) -> XOnlyPublicKey {
    let q: PublicKey = ctx.aggregated_pubkey();
    q.x_only_public_key().0
}

/// Errors building the per-channel [`KeyAggContext`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAggError {
    /// A funding key was not a valid 33-byte compressed secp256k1 point.
    BadPubkey,
    /// The two keys aggregated to the point at infinity (degenerate input).
    Aggregate,
    /// The taproot tweak produced the point at infinity (degenerate input).
    Tweak,
    /// `my_funding_pubkey` is neither of the two channel participants.
    NotAParticipant,
}

/// A single signer's first-round state: holds the (single-use) `SecNonce` inside
/// the conduition [`FirstRound`] and exposes our [`PubNonce`] to send to the peer.
///
/// The `SecNonce` is derived from the deterministic shachain seed for the
/// commitment height; it is dropped when the round is finalized (consumed) and is
/// never persisted — on restart it is re-derived for the same height.
pub struct KeyPathFirstRound {
    inner: FirstRound,
}

impl KeyPathFirstRound {
    /// Begin a key-path signing round for `height`, deriving the secret nonce
    /// deterministically from `shachain_root`.
    ///
    /// `ctx` is the cached per-channel [`KeyAggContext`] (already KeySorted +
    /// taproot-tweaked); `signer_index` is our slot in the sorted key list (see
    /// [`channel_key_agg_ctx`]).
    pub fn new(
        ctx: KeyAggContext,
        signer_index: usize,
        shachain_root: &[u8; 32],
        height: u64,
    ) -> Result<Self, SignError> {
        let seed = derive_secnonce_seed(shachain_root, height);
        let inner = FirstRound::new(ctx, seed, signer_index, SecNonceSpices::new())
            .map_err(|_| SignError::RoundSetup)?;
        Ok(Self { inner })
    }

    /// Begin the COUNTERPARTY-commitment signing round. Two guards, both by construction:
    ///
    /// 1. DOMAIN SEPARATION — the secret nonce is derived from a domain-separated seed
    ///    ([`derive_secnonce_seed_domain`] + [`COUNTERPARTY_COMMITMENT_NONCE_TAG`]) so it
    ///    can never equal the holder-commitment nonce at the SAME height.
    /// 2. NONCE-REUSE / FUNDING-KEY-LEAK GUARD — the secret nonce is ALSO bound to the
    ///    counterparty's public nonce AND the message via BIP327 [`SecNonceSpices`]. A
    ///    malicious peer can rotate its nonce on `channel_reestablish` and induce us to
    ///    re-sign the SAME (root, height) counterparty commitment (we retransmit
    ///    `commitment_signed`). A secret nonce fixed ONLY by (root, height) would be reused
    ///    across two DIFFERENT challenges, leaking the funding key via
    ///    `x = (s1 - s2)/(e1 - e2)`. Binding re-randomises the secret nonce for any rotated
    ///    nonce/message, so no two distinct signing sessions ever share one.
    ///
    /// This is closed BY CONSTRUCTION and RESTART-SAFE (deterministic in its inputs), so it
    /// does not rely on any in-memory guard that an enclave restart would clear. Interop is
    /// preserved: our pubnonce is sent WITH the partial (`partial_signature_with_nonce`),
    /// never pre-advertised, so re-deriving it here changes nothing the peer relies on.
    /// (The holder path — `Self::new` / `finalize_holder_commitment` — is pre-advertised via
    /// `next_local_nonce` and its partial is never sent to the peer, so it stays UNspiced.)
    pub fn new_counterparty(
        ctx: KeyAggContext,
        signer_index: usize,
        shachain_root: &[u8; 32],
        height: u64,
        counterparty_nonce: &PubNonce,
        message: &[u8; 32],
    ) -> Result<Self, SignError> {
        let seed = derive_secnonce_seed_domain(shachain_root, height, COUNTERPARTY_COMMITMENT_NONCE_TAG);
        let cp_nonce_bytes = counterparty_nonce.serialize();
        let spices = SecNonceSpices::new().with_message(message).with_extra_input(&cp_nonce_bytes);
        let inner = FirstRound::new(ctx, seed, signer_index, spices)
            .map_err(|_| SignError::RoundSetup)?;
        Ok(Self { inner })
    }

    /// Begin a DEAD-MAN EXIT (#114) key-path signing round. The secret nonce is
    /// derived from a domain-separated seed ([`derive_secnonce_seed_domain`] +
    /// [`DEAD_MAN_EXIT_NONCE_TAG`]) AND bound to `message` via BIP327
    /// [`SecNonceSpices`]. Two guarantees, both by construction:
    ///
    /// 1. DOMAIN SEPARATION — the dead-man nonce can never equal a holder (untagged)
    ///    or counterparty (`COUNTERPARTY_COMMITMENT_NONCE_TAG`) commitment nonce at the
    ///    same `height`, so pre-signing an exit can never collide with live commitment
    ///    signing (which would share a secret nonce over two different sighashes → leak
    ///    the funding key).
    /// 2. MESSAGE BINDING — the secret nonce is spiced with the exit sighash, so a
    ///    REFRESHED exit (heartbeat pushes the CLTV forward ⇒ a NEW nLockTime ⇒ a NEW
    ///    sighash) re-randomises the nonce even if the caller reuses `height`; two
    ///    distinct exit messages therefore NEVER share a nonce. Re-signing the SAME
    ///    message (a crash re-emit at the same deadline) reproduces the SAME nonce and
    ///    hence the SAME signature — deterministic + crash-safe, never a leak.
    ///
    /// Unlike [`Self::new_counterparty`] there is NO wire peer here (the fleet drives
    /// both halves locally), so no counterparty-nonce spice is needed: message binding
    /// alone closes the reuse-across-distinct-messages hazard.
    pub fn new_deadman(
        ctx: KeyAggContext,
        signer_index: usize,
        shachain_root: &[u8; 32],
        height: u64,
        message: &[u8; 32],
    ) -> Result<Self, SignError> {
        let seed = derive_secnonce_seed_domain(shachain_root, height, DEAD_MAN_EXIT_NONCE_TAG);
        let spices = SecNonceSpices::new().with_message(message);
        let inner = FirstRound::new(ctx, seed, signer_index, spices)
            .map_err(|_| SignError::RoundSetup)?;
        Ok(Self { inner })
    }

    /// Our public nonce to send to the counterparty (66 bytes serialized).
    pub fn our_public_nonce(&self) -> PubNonce {
        self.inner.our_public_nonce()
    }

    /// Receive the counterparty's public nonce, then finalize the first round by
    /// partial-signing `message` with our `seckey`, yielding a
    /// [`KeyPathSecondRound`]. Consumes `self` (the `SecNonce` is single-use).
    pub fn receive_nonce_and_sign(
        mut self,
        counterparty_index: usize,
        counterparty_nonce: PubNonce,
        seckey: SecretKey,
        message: [u8; 32],
    ) -> Result<KeyPathSecondRound, SignError> {
        self.inner
            .receive_nonce(counterparty_index, counterparty_nonce)
            .map_err(|_| SignError::Nonce)?;
        let second = self
            .inner
            .finalize(seckey, message)
            .map_err(|_| SignError::Finalize)?;
        Ok(KeyPathSecondRound { inner: second })
    }
}

/// A single signer's second-round state: holds our [`PartialSignature`] and
/// verifies + aggregates the counterparty's partial into the final BIP340 sig.
pub struct KeyPathSecondRound {
    inner: musig2::SecondRound<[u8; 32]>,
}

impl KeyPathSecondRound {
    /// Our partial signature to send to the counterparty (32 bytes serialized).
    pub fn our_partial_signature(&self) -> PartialSignature {
        self.inner.our_signature()
    }

    /// Receive the counterparty's partial signature. conduition **verifies the
    /// partial against the aggregate nonce + the counterparty's pubkey here and
    /// errors on a bad one** (partial-verify-before-agg).
    pub fn receive_partial(
        &mut self,
        counterparty_index: usize,
        counterparty_partial: PartialSignature,
    ) -> Result<(), SignError> {
        self.inner
            .receive_signature(counterparty_index, counterparty_partial)
            .map_err(|_| SignError::PartialVerify)
    }

    /// Aggregate into the final BIP340 key-path [`schnorr::Signature`].
    ///
    /// [`schnorr::Signature`]: musig2::secp256k1::schnorr::Signature
    pub fn finalize(self) -> Result<musig2::secp256k1::schnorr::Signature, SignError> {
        self.inner.finalize().map_err(|_| SignError::Aggregate)
    }
}

/// Derive **our** deterministic public nonce for `height` exactly as the signing
/// path ([`our_key_path_partial`]) will — i.e. through the same conduition
/// `FirstRound` derivation (which binds the aggregated pubkey + signer index +
/// spices into the secret nonce). This MUST be used to advertise the nonce we
/// will later sign with (`next_local_nonce` / `shutdown_nonce`); deriving it via
/// any other path (e.g. a bare `SecNonceBuilder`) yields a DIFFERENT nonce than
/// the one the round actually uses, so aggregation would fail.
///
/// `ctx` is the cached per-channel KeySorted+taproot-tweaked [`KeyAggContext`];
/// `our_index` is our slot from [`channel_key_agg_ctx`].
pub fn local_pubnonce(
    ctx: KeyAggContext,
    our_index: usize,
    shachain_root: &[u8; 32],
    height: u64,
) -> Result<PubNonce, SignError> {
    Ok(KeyPathFirstRound::new(ctx, our_index, shachain_root, height)?.our_public_nonce())
}

/// Produce **our** MuSig2 key-path partial signature over `message`, given the
/// counterparty's public nonce — the single-party half of the 2-party round used
/// by the [`crate::validating_signer::ValidatingChannelSigner`]
/// `TaprootChannelSigner` bodies (M5 handler state machine).
///
/// Unlike [`key_path_sign_2of2`] (which drives *both* sides for the load-bearing
/// roundtrip test), this is what a live signer runs: we hold only our own
/// `seckey` + shachain root and have just received the peer's `PubNonce` over the
/// wire (in `funding_created`/`funding_signed`/`commitment_signed`/closing). We
/// build our deterministic per-height secret nonce, place the counterparty's
/// nonce, partial-sign `message`, and return:
///
/// * `our_partial` — our [`PartialSignature`] (the 32-byte `s`), and
/// * `our_pubnonce` — our [`PubNonce`] (66 bytes) that the peer needs to verify
///   + aggregate this partial (sent alongside it in `partial_signature_with_nonce`).
///
/// `ctx` is the cached per-channel KeySorted+taproot-tweaked [`KeyAggContext`];
/// `our_index`/`counterparty_index` are the slots from [`channel_key_agg_ctx`].
#[allow(clippy::too_many_arguments)]
pub fn our_key_path_partial(
    ctx: KeyAggContext,
    our_index: usize,
    counterparty_index: usize,
    seckey: SecretKey,
    shachain_root: &[u8; 32],
    height: u64,
    counterparty_nonce: PubNonce,
    message: [u8; 32],
) -> Result<(PartialSignature, PubNonce), SignError> {
    let r1 = KeyPathFirstRound::new(ctx, our_index, shachain_root, height)?;
    let our_pubnonce = r1.our_public_nonce();
    let r2 = r1.receive_nonce_and_sign(counterparty_index, counterparty_nonce, seckey, message)?;
    Ok((r2.our_partial_signature(), our_pubnonce))
}

/// Counterparty-commitment variant of [`our_key_path_partial`]: derives the secret nonce
/// via [`KeyPathFirstRound::new_counterparty`], which is domain-separated from the holder
/// nonce AND bound to `(counterparty_nonce, message)` — so a peer that rotates its nonce on
/// reconnect and induces a re-sign of the same (root, height) commitment CANNOT extract the
/// funding key from two partials (each uses a different secret nonce). The returned pubnonce
/// is advertised alongside the partial in `partial_signature_with_nonce`; the peer
/// verifies/aggregates against THAT nonce, so the holder advertisement (`next_local_nonce`)
/// and `finalize_holder_commitment` (both untagged/unspiced) stay matched and unchanged.
#[allow(clippy::too_many_arguments)]
pub fn our_key_path_partial_counterparty(
    ctx: KeyAggContext,
    our_index: usize,
    counterparty_index: usize,
    seckey: SecretKey,
    shachain_root: &[u8; 32],
    height: u64,
    counterparty_nonce: PubNonce,
    message: [u8; 32],
) -> Result<(PartialSignature, PubNonce), SignError> {
    let r1 = KeyPathFirstRound::new_counterparty(
        ctx,
        our_index,
        shachain_root,
        height,
        &counterparty_nonce,
        &message,
    )?;
    let our_pubnonce = r1.our_public_nonce();
    let r2 = r1.receive_nonce_and_sign(counterparty_index, counterparty_nonce, seckey, message)?;
    Ok((r2.our_partial_signature(), our_pubnonce))
}

/// DEAD-MAN EXIT (#114) variant of [`local_pubnonce`]: derive **our** deterministic
/// public nonce for the pre-signed exit at `(height, message)` through the same
/// conduition `FirstRound` derivation the dead-man signing path
/// ([`our_key_path_partial_deadman`]) uses — i.e. via [`KeyPathFirstRound::new_deadman`]
/// (domain-separated by [`DEAD_MAN_EXIT_NONCE_TAG`] + spiced with the exit sighash).
///
/// The nonce MUST be derived through this exact path: deriving it any other way
/// (bare `SecNonceBuilder`, or the untagged/holder path) yields a DIFFERENT nonce
/// than the one the round actually signs with, so aggregation would fail. `message`
/// is the BIP341 key-path sighash of the exit tx; a refreshed exit (new nLockTime ⇒
/// new sighash) re-randomises this nonce even at the same `height`.
pub fn local_pubnonce_deadman(
    ctx: KeyAggContext,
    our_index: usize,
    shachain_root: &[u8; 32],
    height: u64,
    message: &[u8; 32],
) -> Result<PubNonce, SignError> {
    Ok(KeyPathFirstRound::new_deadman(ctx, our_index, shachain_root, height, message)?
        .our_public_nonce())
}

/// DEAD-MAN EXIT (#114) variant of [`our_key_path_partial_counterparty`]: produce
/// **our** MuSig2 key-path partial over the exit-tx sighash `message`, given the
/// other half's public nonce, deriving our secret nonce via
/// [`KeyPathFirstRound::new_deadman`] (domain-separated + message-bound). Returns
/// `(our_partial, our_pubnonce)`. ⛔ **THIS SAID "the fleet holds BOTH funding halves, so it calls
/// this once per half" UNTIL 2026-08-18, AND `99fda5e9` (§M1#2) MADE THAT FALSE.** The fleet is
/// vault-less by DEFAULT now, so it holds ONE half and calls this once, with the LP's pubnonce
/// arriving from the LP's own host; the both-halves form survives only under
/// `QUID_FLEET_COHOSTS_VAULT=true`, the single-custodian deployment that logs a warning saying its
/// multisig is nominal. Partials still combine via [`aggregate_key_path_partials`] either way —
/// only WHO produces the second one moved. Because the nonce is disjoint from both
/// commitment domains AND bound to the exit sighash, this partial can never share a
/// secret nonce with live commitment/close signing nor with a refreshed exit over a
/// different sighash (the funding-key-leak guard, `x = (s1-s2)/(e1-e2)`).
#[allow(clippy::too_many_arguments)]
pub fn our_key_path_partial_deadman(
    ctx: KeyAggContext,
    our_index: usize,
    counterparty_index: usize,
    seckey: SecretKey,
    shachain_root: &[u8; 32],
    height: u64,
    counterparty_nonce: PubNonce,
    message: [u8; 32],
) -> Result<(PartialSignature, PubNonce), SignError> {
    let r1 = KeyPathFirstRound::new_deadman(ctx, our_index, shachain_root, height, &message)?;
    let our_pubnonce = r1.our_public_nonce();
    let r2 = r1.receive_nonce_and_sign(counterparty_index, counterparty_nonce, seckey, message)?;
    Ok((r2.our_partial_signature(), our_pubnonce))
}

/// Aggregate **our** + the **counterparty's** key-path partial signatures (each
/// produced with their respective public nonce) into the final BIP340 key-path
/// [`schnorr::Signature`] that spends the `0x5120||Q` funding output.
///
/// This is the closing/holder-commitment finalization step (M5): the handler has
/// both partials + both public nonces and produces the single 64-byte aggregate
/// Schnorr signature. Both nonces are needed to reconstruct the same `AggNonce`
/// the partials were computed against; conduition verifies each partial on
/// receive and errors on a bad one.
///
/// [`schnorr::Signature`]: musig2::secp256k1::schnorr::Signature
#[allow(clippy::too_many_arguments)]
pub fn aggregate_key_path_partials(
    ctx: KeyAggContext,
    message: [u8; 32],
    our_index: usize,
    our_pubnonce: PubNonce,
    our_partial: PartialSignature,
    counterparty_index: usize,
    counterparty_pubnonce: PubNonce,
    counterparty_partial: PartialSignature,
) -> Result<musig2::secp256k1::schnorr::Signature, SignError> {
    use musig2::{aggregate_partial_signatures, AggNonce};
    // The two nonces are summed into the AggNonce (commutative). The partials,
    // however, MUST be passed in signer-index order (the order of the keys in the
    // KeyAggContext), so place each by its slot.
    let agg_nonce = AggNonce::sum([&our_pubnonce, &counterparty_pubnonce]);
    let mut partials: [PartialSignature; 2] = [musig2::secp::MaybeScalar::Zero; 2];
    partials[our_index] = our_partial;
    partials[counterparty_index] = counterparty_partial;
    aggregate_partial_signatures(&ctx, &agg_nonce, partials, message)
        .map_err(|_| SignError::Aggregate)
}

/// Errors in the 2-party key-path signing flow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignError {
    /// Failed to set up the first round (bad signer index / key mismatch).
    RoundSetup,
    /// Failed to place the counterparty's public nonce.
    Nonce,
    /// Failed to finalize the first round (partial sign).
    Finalize,
    /// The counterparty's partial signature failed verification.
    PartialVerify,
    /// Final aggregation failed.
    Aggregate,
}

/// Convenience: drive a **complete** 2-party MuSig2 key-path sign over `message`
/// from both parties' secret keys, returning the aggregated BIP340 signature.
///
/// Used by the load-bearing roundtrip test; also a reference for the live two-node
/// flow (where each side only holds its own `seckey` + receives the peer's
/// pubnonce/partial over the wire). Both parties derive their nonces from their
/// own shachain root at `height`.
#[allow(clippy::too_many_arguments)]
pub fn key_path_sign_2of2(
    lp_pub: &[u8; 33],
    hop_pub: &[u8; 33],
    lp_sec: SecretKey,
    hop_sec: SecretKey,
    lp_shachain_root: &[u8; 32],
    hop_shachain_root: &[u8; 32],
    height: u64,
    message: [u8; 32],
) -> Result<(musig2::secp256k1::schnorr::Signature, XOnlyPublicKey), SignError> {
    // Each party independently builds the (identical) KeySort+KeyAgg+tweak ctx.
    let (lp_ctx, lp_idx) =
        channel_key_agg_ctx(lp_pub, hop_pub, lp_pub).map_err(|_| SignError::RoundSetup)?;
    let (hop_ctx, hop_idx) =
        channel_key_agg_ctx(lp_pub, hop_pub, hop_pub).map_err(|_| SignError::RoundSetup)?;
    let agg_xonly = aggregated_xonly(&lp_ctx);

    // R1: build first rounds + exchange public nonces.
    let lp_r1 = KeyPathFirstRound::new(lp_ctx, lp_idx, lp_shachain_root, height)?;
    let hop_r1 = KeyPathFirstRound::new(hop_ctx, hop_idx, hop_shachain_root, height)?;
    let lp_pubnonce = lp_r1.our_public_nonce();
    let hop_pubnonce = hop_r1.our_public_nonce();

    // R2: each receives the other's nonce + partial-signs the message.
    let mut lp_r2 =
        lp_r1.receive_nonce_and_sign(hop_idx, hop_pubnonce, lp_sec, message)?;
    let mut hop_r2 =
        hop_r1.receive_nonce_and_sign(lp_idx, lp_pubnonce, hop_sec, message)?;

    // Exchange + verify partials (receive_* verifies each partial), aggregate.
    let lp_partial = lp_r2.our_partial_signature();
    let hop_partial = hop_r2.our_partial_signature();
    lp_r2.receive_partial(hop_idx, hop_partial)?;
    hop_r2.receive_partial(lp_idx, lp_partial)?;

    let sig_lp = lp_r2.finalize()?;
    let sig_hop = hop_r2.finalize()?;
    // Both parties must aggregate to the identical signature.
    debug_assert_eq!(sig_lp.serialize(), sig_hop.serialize());

    Ok((sig_lp, agg_xonly))
}

/// DEAD-MAN EXIT (#114): drive a **complete** 2-party MuSig2 key-path sign over the
/// exit-tx `message` (its BIP341 key-path sighash) from BOTH funding secret keys —
/// which the FLEET holds under Option B (the hop-node key + the vault-node key both
/// descend from the one enclave seed). Returns the aggregated BIP340 signature that
/// spends the `0x5120||Q` funding output, plus the x-only `Q`.
///
/// This mirrors [`key_path_sign_2of2`] but derives each party's secret nonce via
/// [`KeyPathFirstRound::new_deadman`] (domain-separated + message-bound), so the
/// pre-signed exit can NEVER share a secret nonce with live commitment/close signing
/// (domain separation) NOR across two refreshed exits with different sighashes
/// (message binding). Re-signing the identical exit reproduces the identical
/// signature (crash-safe). See [`new_deadman`](KeyPathFirstRound::new_deadman) for
/// the funding-key-leak argument.
///
/// `height` is a per-channel monotonic refresh counter; it need not be unique across
/// distinct messages (message binding covers that) but SHOULD advance per refresh so
/// nonces are legibly distinct. The exit is a KEY-PATH spend (no script), so the
/// "CLTV" is enforced purely by the tx's `nLockTime` (a future value) + a non-final
/// input `nSequence` — the standard pre-signed-timelocked-tx pattern; there is no
/// `OP_CHECKLOCKTIMEVERIFY` opcode to embed.
#[allow(clippy::too_many_arguments)]
pub fn key_path_sign_2of2_deadman(
    lp_pub: &[u8; 33],
    hop_pub: &[u8; 33],
    lp_sec: SecretKey,
    hop_sec: SecretKey,
    lp_shachain_root: &[u8; 32],
    hop_shachain_root: &[u8; 32],
    height: u64,
    message: [u8; 32],
) -> Result<(musig2::secp256k1::schnorr::Signature, XOnlyPublicKey), SignError> {
    let (lp_ctx, lp_idx) =
        channel_key_agg_ctx(lp_pub, hop_pub, lp_pub).map_err(|_| SignError::RoundSetup)?;
    let (hop_ctx, hop_idx) =
        channel_key_agg_ctx(lp_pub, hop_pub, hop_pub).map_err(|_| SignError::RoundSetup)?;
    let agg_xonly = aggregated_xonly(&lp_ctx);

    let lp_r1 = KeyPathFirstRound::new_deadman(lp_ctx, lp_idx, lp_shachain_root, height, &message)?;
    let hop_r1 =
        KeyPathFirstRound::new_deadman(hop_ctx, hop_idx, hop_shachain_root, height, &message)?;
    let lp_pubnonce = lp_r1.our_public_nonce();
    let hop_pubnonce = hop_r1.our_public_nonce();

    let mut lp_r2 = lp_r1.receive_nonce_and_sign(hop_idx, hop_pubnonce, lp_sec, message)?;
    let mut hop_r2 = hop_r1.receive_nonce_and_sign(lp_idx, lp_pubnonce, hop_sec, message)?;

    let lp_partial = lp_r2.our_partial_signature();
    let hop_partial = hop_r2.our_partial_signature();
    lp_r2.receive_partial(hop_idx, hop_partial)?;
    hop_r2.receive_partial(lp_idx, lp_partial)?;

    let sig_lp = lp_r2.finalize()?;
    let sig_hop = hop_r2.finalize()?;
    debug_assert_eq!(sig_lp.serialize(), sig_hop.serialize());
    Ok((sig_lp, agg_xonly))
}

#[cfg(test)]
mod tests {
    use super::*;
    use musig2::secp256k1::{Message, Secp256k1, SecretKey};

    /// Derive a 33-byte compressed pubkey from a fixed secret-key byte.
    fn keypair(seed: u8) -> (SecretKey, [u8; 33]) {
        let secp = Secp256k1::new();
        let sk = SecretKey::from_slice(&[seed; 32]).unwrap();
        let pk = sk.public_key(&secp);
        (sk, pk.serialize())
    }

    // === LOAD-BEARING correctness proof: 2-party MuSig2 key-path roundtrip ===

    /// Both parties KeySort+KeyAgg+`with_unspendable_taproot_tweak`, derive
    /// deterministic shachain nonces at a height, exchange pubnonces,
    /// partial-sign, aggregate, and the result **verifies under BIP340 Schnorr
    /// against the x-only tweaked aggregate `Q`** (`KeyAggContext.aggregated_pubkey()`).
    #[test]
    fn musig2_key_path_roundtrip_verifies() {
        let secp = Secp256k1::new();
        let (lp_sec, lp_pub) = keypair(0x11);
        let (hop_sec, hop_pub) = keypair(0x22);
        let lp_root = [0xAB; 32];
        let hop_root = [0xCD; 32];
        let height = 281_474_976_710_654; // (1<<48)-2, a realistic commitment idx
        let msg = [0x42u8; 32]; // a 32-byte "sighash"

        let (sig, agg_xonly) = key_path_sign_2of2(
            &lp_pub, &hop_pub, lp_sec, hop_sec, &lp_root, &hop_root, height, msg,
        )
        .expect("2-party key-path sign succeeds");

        // BIP340 verify against the tweaked aggregate Q.
        let message = Message::from_digest(msg);
        secp.verify_schnorr(&sig, &message, &agg_xonly)
            .expect("aggregated key-path signature verifies under BIP340 vs tweaked Q");

        // Sanity: a wrong message does NOT verify under the same key.
        let bad = Message::from_digest([0x43u8; 32]);
        assert!(
            secp.verify_schnorr(&sig, &bad, &agg_xonly).is_err(),
            "signature must not verify for a different message"
        );
    }

    /// The aggregate Q is symmetric under swapping the two funding keys (the
    /// KeySort makes the context order-independent) — the same property the M1
    /// funding scriptPubKey relies on, so the signer's Q matches the funding Q.
    #[test]
    fn aggregate_is_keysort_symmetric() {
        let (_lp_sec, lp_pub) = keypair(0x11);
        let (_hop_sec, hop_pub) = keypair(0x22);
        let (ctx_a, _ia) = channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap();
        let (ctx_b, _ib) = channel_key_agg_ctx(&hop_pub, &lp_pub, &lp_pub).unwrap();
        assert_eq!(
            aggregated_xonly(&ctx_a).serialize(),
            aggregated_xonly(&ctx_b).serialize(),
            "KeySort makes Q independent of the argument order",
        );
    }

    /// LOAD-BEARING (M5): the live per-signer flow used by the
    /// `TaprootChannelSigner` bodies — each side independently runs
    /// [`our_key_path_partial`] (deriving its own deterministic nonce, receiving
    /// the peer's pubnonce, partial-signing), then one side
    /// [`aggregate_key_path_partials`] both partials + both pubnonces into the
    /// final BIP340 key-path Schnorr sig that **verifies against the tweaked Q**.
    /// This is the exact code path of open/commitment/close partial signing.
    #[test]
    fn our_key_path_partial_then_aggregate_verifies() {
        let secp = Secp256k1::new();
        let (lp_sec, lp_pub) = keypair(0x11);
        let (hop_sec, hop_pub) = keypair(0x22);
        let lp_root = [0xAB; 32];
        let hop_root = [0xCD; 32];
        let height = 281_474_976_710_652u64;
        let msg = [0x77u8; 32];

        // Each side builds its own ctx + index.
        let (lp_ctx, lp_idx) = channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap();
        let (hop_ctx, hop_idx) = channel_key_agg_ctx(&lp_pub, &hop_pub, &hop_pub).unwrap();
        let agg_xonly = aggregated_xonly(&lp_ctx);

        // R1: each side derives its pubnonce (we need them to cross before R2;
        // re-derive deterministically — that is the crash-safe property).
        let lp_pn = KeyPathFirstRound::new(lp_ctx, lp_idx, &lp_root, height)
            .unwrap()
            .our_public_nonce();
        let hop_pn = KeyPathFirstRound::new(hop_ctx, hop_idx, &hop_root, height)
            .unwrap()
            .our_public_nonce();

        // Each side produces its partial via the live single-party helper.
        let (lp_ctx2, _) = channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap();
        let (hop_ctx2, _) = channel_key_agg_ctx(&lp_pub, &hop_pub, &hop_pub).unwrap();
        let (lp_partial, lp_pn2) = our_key_path_partial(
            lp_ctx2, lp_idx, hop_idx, lp_sec, &lp_root, height, hop_pn.clone(), msg,
        )
        .unwrap();
        let (hop_partial, hop_pn2) = our_key_path_partial(
            hop_ctx2, hop_idx, lp_idx, hop_sec, &hop_root, height, lp_pn.clone(), msg,
        )
        .unwrap();
        // The pubnonce the helper returns must match the one re-derived in R1.
        assert_eq!(lp_pn.serialize(), lp_pn2.serialize());
        assert_eq!(hop_pn.serialize(), hop_pn2.serialize());

        // Aggregate (as the holder/closing-finalize handler does).
        let (agg_ctx, _) = channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap();
        let sig = aggregate_key_path_partials(
            agg_ctx, msg, lp_idx, lp_pn, lp_partial, hop_idx, hop_pn, hop_partial,
        )
        .unwrap();

        let message = Message::from_digest(msg);
        secp.verify_schnorr(&sig, &message, &agg_xonly)
            .expect("aggregated key-path sig from the live per-signer flow verifies vs Q");
    }

    // === Nonce determinism + no-reuse-across-heights ===

    #[test]
    fn nonce_seed_is_deterministic_per_height() {
        let root = [0x07; 32];
        // Same (root, height) ⇒ identical seed (crash-safe re-derive).
        assert_eq!(
            derive_secnonce_seed(&root, 100),
            derive_secnonce_seed(&root, 100),
        );
        // Different height ⇒ different seed (no cross-height reuse).
        assert_ne!(
            derive_secnonce_seed(&root, 100),
            derive_secnonce_seed(&root, 101),
        );
        // Different root ⇒ different seed.
        let other_root = [0x08; 32];
        assert_ne!(
            derive_secnonce_seed(&root, 100),
            derive_secnonce_seed(&other_root, 100),
        );
    }

    /// A `SecNonce` (and thus its public nonce) is never reused across two
    /// different heights: distinct seeds ⇒ distinct public nonces.
    #[test]
    fn secnonce_never_reused_across_heights() {
        let (_sk, pubk) = keypair(0x11);
        let (_sk2, pubk2) = keypair(0x22);
        let root = [0x07; 32];
        let (ctx_a, idx) = channel_key_agg_ctx(&pubk, &pubk2, &pubk).unwrap();
        let (ctx_b, _idx) = channel_key_agg_ctx(&pubk, &pubk2, &pubk).unwrap();

        let r_h1 = KeyPathFirstRound::new(ctx_a, idx, &root, 1).unwrap();
        let r_h2 = KeyPathFirstRound::new(ctx_b, idx, &root, 2).unwrap();
        assert_ne!(
            r_h1.our_public_nonce().serialize(),
            r_h2.our_public_nonce().serialize(),
            "the public (hence secret) nonce must differ between two commitment heights",
        );

        // And re-deriving the SAME height reproduces the SAME public nonce
        // (crash-safe), proving determinism end-to-end through the SecNonce.
        let (ctx_c, _idx) = channel_key_agg_ctx(&pubk, &pubk2, &pubk).unwrap();
        let r_h1_again = KeyPathFirstRound::new(ctx_c, idx, &root, 1).unwrap();
        assert_eq!(
            r_h1.our_public_nonce().serialize(),
            r_h1_again.our_public_nonce().serialize(),
            "same (root, height) must reproduce the same nonce on restart",
        );
    }

    /// FUNDING-KEY-LEAK GUARD: the holder and counterparty commitment
    /// transactions are signed at the SAME commitment height (both numbers count
    /// down from `INITIAL_COMMITMENT_NUMBER` in lockstep). Without domain
    /// separation, `our_key_path_partial` (holder finalize) and
    /// `our_key_path_partial_counterparty` would derive the SAME secret nonce at
    /// that height, and signing the two different commitment sighashes under one
    /// nonce leaks the funding key (`x = (s1 - s2)/(e1 - e2)`). Assert the two
    /// nonces are distinct at the worst case (the initial commitment number).
    #[test]
    fn counterparty_nonce_domain_separated_from_holder_at_same_height() {
        let (_sk, pubk) = keypair(0x11);
        let (_sk2, pubk2) = keypair(0x22);
        let root = [0x5A; 32];
        // INITIAL_COMMITMENT_NUMBER: holder# == counterparty# == (1<<48)-1.
        let height = (1u64 << 48) - 1;

        // The tagged counterparty seed must differ from the untagged holder seed.
        assert_ne!(
            derive_secnonce_seed(&root, height),
            derive_secnonce_seed_domain(&root, height, COUNTERPARTY_COMMITMENT_NONCE_TAG),
            "counterparty-tagged seed must differ from the untagged holder seed at the same height",
        );

        // ...and so must the public (hence secret) nonces actually used to sign.
        let (ctx_h, idx) = channel_key_agg_ctx(&pubk, &pubk2, &pubk).unwrap();
        let (ctx_c, _idx) = channel_key_agg_ctx(&pubk, &pubk2, &pubk).unwrap();
        let holder_pn = KeyPathFirstRound::new(ctx_h, idx, &root, height)
            .unwrap()
            .our_public_nonce();
        let msg = [0x42u8; 32];
        let cp_pn = KeyPathFirstRound::new_counterparty(ctx_c, idx, &root, height, &holder_pn, &msg)
            .unwrap()
            .our_public_nonce();
        assert_ne!(
            holder_pn.serialize(),
            cp_pn.serialize(),
            "holder and counterparty commitment nonces MUST differ at the same height (funding-key-leak guard)",
        );
    }

    /// NONCE-REUSE / FUNDING-KEY-LEAK GUARD (the restart-safe, by-construction half):
    /// re-signing the SAME counterparty commitment (same root, height, message) against a
    /// peer that ROTATED its nonce MUST derive a DIFFERENT secret nonce — else the two
    /// partials share a secret nonce and the peer recovers the funding key. We can't read
    /// the secret nonce, but a different secret nonce ⇒ a different PUBLIC nonce, so assert
    /// that. This is exactly the `channel_reestablish`-rotate-then-retransmit attack, and it
    /// must hold even across an enclave restart (the derivation is deterministic + stateless,
    /// so it does — no in-memory guard involved).
    #[test]
    fn counterparty_nonce_rerandomised_when_peer_rotates_nonce_same_height() {
        let (_a, pubk) = keypair(0x11);
        let (_b, pubk2) = keypair(0x22);
        let root = [0x5A; 32];
        let height = (1u64 << 48) - 1;
        let msg = [0x42u8; 32];
        // Two DIFFERENT counterparty nonces the peer might present across a reconnect.
        let peer_nonce_a = KeyPathFirstRound::new(
            channel_key_agg_ctx(&pubk, &pubk2, &pubk2).unwrap().0, 1, &[0x01; 32], height)
            .unwrap().our_public_nonce();
        let peer_nonce_b = KeyPathFirstRound::new(
            channel_key_agg_ctx(&pubk, &pubk2, &pubk2).unwrap().0, 1, &[0x02; 32], height)
            .unwrap().our_public_nonce();
        assert_ne!(peer_nonce_a.serialize(), peer_nonce_b.serialize(), "test setup: nonces differ");

        let (ctx_a, idx) = channel_key_agg_ctx(&pubk, &pubk2, &pubk).unwrap();
        let (ctx_b, _) = channel_key_agg_ctx(&pubk, &pubk2, &pubk).unwrap();
        let our_pn_a = KeyPathFirstRound::new_counterparty(ctx_a, idx, &root, height, &peer_nonce_a, &msg)
            .unwrap().our_public_nonce();
        let our_pn_b = KeyPathFirstRound::new_counterparty(ctx_b, idx, &root, height, &peer_nonce_b, &msg)
            .unwrap().our_public_nonce();
        assert_ne!(
            our_pn_a.serialize(), our_pn_b.serialize(),
            "a rotated peer nonce at the same (root,height,message) MUST re-randomise our secret nonce \
             (else two partials share it → funding-key leak)",
        );
    }

    // === DEAD-MAN EXIT (#114) pre-signing: correctness + no-nonce-reuse ===

    /// LOAD-BEARING: the fleet-held 2-of-2 dead-man sign produces a BIP340 signature
    /// that verifies against the tweaked aggregate `Q` — i.e. the pre-signed exit is a
    /// valid key-path spend of the `0x5120||Q` funding output.
    #[test]
    fn deadman_sign_verifies_vs_q() {
        let secp = Secp256k1::new();
        let (lp_sec, lp_pub) = keypair(0x11);
        let (hop_sec, hop_pub) = keypair(0x22);
        let lp_root = [0xAB; 32];
        let hop_root = [0xCD; 32];
        let msg = [0x42u8; 32]; // the exit-tx key-path sighash
        let (sig, q) = key_path_sign_2of2_deadman(
            &lp_pub, &hop_pub, lp_sec, hop_sec, &lp_root, &hop_root, 0, msg,
        )
        .expect("dead-man 2-of-2 sign succeeds");
        secp.verify_schnorr(&sig, &Message::from_digest(msg), &q)
            .expect("dead-man exit signature verifies under BIP340 vs tweaked Q");
    }

    /// CRASH-SAFE: re-signing the IDENTICAL exit (same message + height) reproduces the
    /// IDENTICAL signature — a heartbeat re-emit at the same deadline never re-signs a
    /// fresh (leaky) nonce.
    #[test]
    fn deadman_same_message_is_deterministic() {
        let (lp_sec, lp_pub) = keypair(0x11);
        let (hop_sec, hop_pub) = keypair(0x22);
        let lp_root = [0xAB; 32];
        let hop_root = [0xCD; 32];
        let msg = [0x42u8; 32];
        let (s1, _) = key_path_sign_2of2_deadman(
            &lp_pub, &hop_pub, lp_sec, hop_sec, &lp_root, &hop_root, 7, msg,
        )
        .unwrap();
        let (s2, _) = key_path_sign_2of2_deadman(
            &lp_pub, &hop_pub, lp_sec, hop_sec, &lp_root, &hop_root, 7, msg,
        )
        .unwrap();
        assert_eq!(s1.serialize(), s2.serialize(), "same exit ⇒ same signature (crash-safe)");
    }

    /// FUNDING-KEY-LEAK GUARD (the whole point of message binding): a REFRESHED exit —
    /// heartbeat pushes the CLTV forward ⇒ new nLockTime ⇒ a DIFFERENT sighash — MUST
    /// derive a DIFFERENT secret nonce, EVEN IF the caller reuses the same `height`.
    /// We can't read the secret nonce, but a different secret nonce ⇒ a different PUBLIC
    /// nonce, so assert that (via `new_deadman` directly for both messages at one height).
    #[test]
    fn deadman_distinct_message_rerandomises_nonce_same_height() {
        let (_lp, lp_pub) = keypair(0x11);
        let (_hop, hop_pub) = keypair(0x22);
        let root = [0x5A; 32];
        let (ctx_a, idx) = channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap();
        let (ctx_b, _) = channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap();
        let m1 = [0x01u8; 32];
        let m2 = [0x02u8; 32];
        let pn1 = KeyPathFirstRound::new_deadman(ctx_a, idx, &root, 3, &m1)
            .unwrap()
            .our_public_nonce();
        let pn2 = KeyPathFirstRound::new_deadman(ctx_b, idx, &root, 3, &m2)
            .unwrap()
            .our_public_nonce();
        assert_ne!(
            pn1.serialize(),
            pn2.serialize(),
            "a refreshed exit (new sighash) at the same height MUST re-randomise the nonce \
             (else two partials share it → funding-key leak)",
        );
    }

    /// LOAD-BEARING (step 1 of the daemon wiring): the ONE-SIDED per-signer dead-man
    /// flow the fleet actually runs — each half independently derives its pubnonce via
    /// [`local_pubnonce_deadman`], then produces its partial via
    /// [`our_key_path_partial_deadman`] (given the OTHER half's pubnonce), and one side
    /// [`aggregate_key_path_partials`] both partials + both pubnonces into the final
    /// BIP340 key-path Schnorr sig that **verifies against the tweaked Q**. This mirrors
    /// `our_key_path_partial_then_aggregate_verifies` but through the DEAD_MAN-tagged
    /// nonce path (what `deadman_exit_pubnonce`/`deadman_exit_partial` call in-place).
    #[test]
    fn deadman_one_sided_partial_then_aggregate_verifies() {
        let secp = Secp256k1::new();
        let (lp_sec, lp_pub) = keypair(0x11);
        let (hop_sec, hop_pub) = keypair(0x22);
        let lp_root = [0xAB; 32];
        let hop_root = [0xCD; 32];
        let height = 5u64;
        let msg = [0x99u8; 32]; // the exit-tx BIP341 key-path sighash

        let (lp_idx, hop_idx) = {
            let (_c, i) = channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap();
            let (_c2, j) = channel_key_agg_ctx(&lp_pub, &hop_pub, &hop_pub).unwrap();
            (i, j)
        };
        let agg_xonly = {
            let (c, _) = channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap();
            aggregated_xonly(&c)
        };

        // R1: each half derives its dead-man pubnonce (deterministic, re-derivable).
        let lp_pn = local_pubnonce_deadman(
            channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap().0,
            lp_idx, &lp_root, height, &msg,
        )
        .unwrap();
        let hop_pn = local_pubnonce_deadman(
            channel_key_agg_ctx(&lp_pub, &hop_pub, &hop_pub).unwrap().0,
            hop_idx, &hop_root, height, &msg,
        )
        .unwrap();

        // R2: each half signs its partial given the OTHER half's pubnonce.
        let (lp_partial, lp_pn2) = our_key_path_partial_deadman(
            channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap().0,
            lp_idx, hop_idx, lp_sec, &lp_root, height, hop_pn.clone(), msg,
        )
        .unwrap();
        let (hop_partial, hop_pn2) = our_key_path_partial_deadman(
            channel_key_agg_ctx(&lp_pub, &hop_pub, &hop_pub).unwrap().0,
            hop_idx, lp_idx, hop_sec, &hop_root, height, lp_pn.clone(), msg,
        )
        .unwrap();
        // The pubnonce the signing helper returns must match the advertised one.
        assert_eq!(lp_pn.serialize(), lp_pn2.serialize());
        assert_eq!(hop_pn.serialize(), hop_pn2.serialize());

        // Aggregate both partials into the final 64-byte Schnorr sig.
        let (agg_ctx, _) = channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap();
        let sig = aggregate_key_path_partials(
            agg_ctx, msg, lp_idx, lp_pn, lp_partial, hop_idx, hop_pn, hop_partial,
        )
        .unwrap();

        secp.verify_schnorr(&sig, &Message::from_digest(msg), &agg_xonly)
            .expect("one-sided dead-man partials aggregate to a BIP340 sig that verifies vs Q");
    }

    /// DOMAIN SEPARATION: the dead-man nonce can never equal a holder (untagged) or
    /// counterparty commitment nonce at the same height — pre-signing an exit can't
    /// collide with live commitment signing.
    #[test]
    fn deadman_nonce_disjoint_from_commitment_domains() {
        let root = [0x5A; 32];
        let height = (1u64 << 48) - 1; // INITIAL_COMMITMENT_NUMBER
        let holder = derive_secnonce_seed(&root, height);
        let counterparty = derive_secnonce_seed_domain(&root, height, COUNTERPARTY_COMMITMENT_NONCE_TAG);
        let deadman = derive_secnonce_seed_domain(&root, height, DEAD_MAN_EXIT_NONCE_TAG);
        assert_ne!(deadman, holder, "dead-man seed must differ from the holder-commitment seed");
        assert_ne!(deadman, counterparty, "dead-man seed must differ from the counterparty-commitment seed");
    }

    /// A tampered counterparty partial signature is rejected at receive time
    /// (partial-verify-before-aggregate).
    #[test]
    fn bad_partial_is_rejected() {
        let (lp_sec, lp_pub) = keypair(0x11);
        let (hop_sec, hop_pub) = keypair(0x22);
        let root_lp = [0xAB; 32];
        let root_hop = [0xCD; 32];
        let msg = [0x42u8; 32];

        let (lp_ctx, lp_idx) = channel_key_agg_ctx(&lp_pub, &hop_pub, &lp_pub).unwrap();
        let (hop_ctx, hop_idx) = channel_key_agg_ctx(&lp_pub, &hop_pub, &hop_pub).unwrap();
        let lp_r1 = KeyPathFirstRound::new(lp_ctx, lp_idx, &root_lp, 5).unwrap();
        let hop_r1 = KeyPathFirstRound::new(hop_ctx, hop_idx, &root_hop, 5).unwrap();
        let lp_pn = lp_r1.our_public_nonce();
        let hop_pn = hop_r1.our_public_nonce();

        let mut lp_r2 = lp_r1
            .receive_nonce_and_sign(hop_idx, hop_pn, lp_sec, msg)
            .unwrap();
        let hop_r2 = hop_r1
            .receive_nonce_and_sign(lp_idx, lp_pn, hop_sec, msg)
            .unwrap();

        // Tamper: feed our OWN partial in the counterparty slot → must fail verify.
        let our_partial = lp_r2.our_partial_signature();
        let _ = hop_r2; // keep alive
        assert_eq!(
            lp_r2.receive_partial(hop_idx, our_partial),
            Err(SignError::PartialVerify),
            "a partial that does not verify for the claimed signer is rejected",
        );
    }
}
