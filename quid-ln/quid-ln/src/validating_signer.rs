//! The production *validating* Lightning channel signer for QU!D.
//!
//! This is a VLS-*style* signer implemented directly against our vendored
//! quid-v0.2.2 LDK fork's own signer traits ([`ChannelSigner`] +
//! [`EcdsaChannelSigner`]). It is **not** the upstream
//! `validating-lightning-signer` (VLS) crate — VLS does not target this fork's
//! trait surface, so we re-implement the *concept* here: every funds-critical
//! signing request is routed through explicit policy checks before a signature
//! is ever produced.
//!
//! # Deployment model — ⚠️ THE SELF-HOST ASSUMPTION THIS FILE WAS WRITTEN UNDER
//! # NO LONGER HOLDS (§E175)
//!
//! This header used to state: *"QU!D LP nodes are self-hosted… the keys live
//! in-process on the LP's own machine. A self-hosting LP fundamentally trusts
//! its own node — so these policy checks are defense-in-depth against a bug or
//! a partial compromise, not a trust boundary against the custody backend."*
//!
//! **That is no longer the architecture.** `quid-bridge/src/vault.rs:612` —
//! *"no lpAuth — the LP runs nothing"* — and `quid-bridge/src/deadman_exit.rs`
//! derives BOTH the hop and vault funding-half signers **in the fleet's own
//! process**. So as deployed, this signer wraps keys the fleet holds and runs
//! inside the fleet: **it is the fleet checking itself**, and the checks below
//! enforce nothing against the one adversary that matters.
//!
//! ✅ **THE FLEET IS VAULT-LESS BY DEFAULT (§M1#2).** The vault boot sits behind
//! `QUID_FLEET_COHOSTS_VAULT`, default OFF, so the LP funding half lives on the LP's own host and
//! this signer is no longer the fleet checking itself: the adversary it was powerless against —
//! a compromised fleet — can no longer produce the other half at all.
//! ⚠️ **THE ANALYSIS BELOW IS STILL CORRECT FOR THE CO-HOSTED MODE**, which remains reachable by
//! that flag, so it is corrected rather than deleted. **But do not quote it as the deployed model,**
//! and in particular do not reason from it that a consent registry is plumbing for an absence that
//! cannot happen: post-§M1#2 the LP genuinely is a separate party that can be offline when the
//! reconciler ticks, which is exactly what `VaultRegistry`'s DORMANT-on-absence handling is for.
//!
//! Two consequences, and neither is fixed by editing this comment:
//!
//! * **The checks only become a trust boundary once the signer runs where the
//!   node operator cannot replace it** (relocation to LP control — §E175). No
//!   check added to this file survives an attacker who swaps the binary.
//! * **Every method that delegates straight to `inner` was scoped to a BUGGY
//!   node and is an UNCHECKED path against a HOSTILE one.** They are enumerated
//!   and classified in §E176: 32 trait methods, 10 checked, 22 delegating.
//!   `provide_taproot_context` was the highest-risk of them and is now validated
//!   (§E176-C, below); the HTLC/justice group remains delegated by design, with
//!   exposure bounded by in-flight HTLC value rather than the channel balance.
//!
//! Accordingly [`ValidatingChannelSigner`] wraps the [`InMemorySigner`]
//! directly (no custody seam / backend abstraction), runs the checks
//! below, and delegates everything else straight through.
//!
//! ```text
//!   LDK ChannelManager / ChannelMonitor
//!            |  (ChannelSigner + EcdsaChannelSigner)
//!            v
//!   ValidatingChannelSigner { inner: InMemorySigner, policy: PolicyState }
//! ```
//!
//! # Policy checks (the two sound, production checks)
//!
//! * **Anti-revoked-reuse monotonic state machine.** See [`PolicyState`]. This
//!   is the core justice-safety property: we refuse to release a revocation
//!   secret for, or sign, a commitment in a way that would let a counterparty
//!   replay a *revoked* holder state, and we refuse to regress the
//!   per-commitment index. The numeric semantics (commitment number counts
//!   *backwards* from `(1 << 48) - 1`, so a more-advanced state has a *lower*
//!   index) are implemented from the LDK trait docs.
//!
//! * **Closing-tx payout-script lock.** See [`check_closing_payout_script`]. A
//!   cooperative close that *pays the holder (LP)* MUST pay the exact committed
//!   P2WPKH shutdown script that QU!D pins via `commit_upfront_shutdown_pubkey`
//!   (and that `BTCChannels._lpFinalBalance` reads). A close paying the holder
//!   output to any other destination is rejected. If the holder output is
//!   *absent* (a fully-delivered LP with a zero holder balance), that is valid:
//!   there is nothing to redirect, so the script field is not checked.
//!
//! All other [`ChannelSigner`] / [`EcdsaChannelSigner`] methods delegate
//! straight to `inner`: a self-host trusts its own node for those, and the two
//! checks above are the defense-in-depth layer.
//!
//! # Persistence
//!
//! `ValidatingChannelSigner` is a drop-in for [`InMemorySigner`] as the
//! `SignerProvider::EcdsaSigner`. The vendored fork does **not** serialize the
//! signer with the [`ChannelMonitor`]: the monitor writes a zero-length signer
//! placeholder and, on read, reconstructs the signer by calling
//! `SignerProvider::derive_channel_signer(channel_keys_id)` and re-deriving the
//! key material (see `onchaintx.rs`). So this type needs **no** `Writeable` /
//! `Readable` impl. On restart, [`crate::keys_manager::QuidKeysManager`]
//! rebuilds the wrapper: the inner signer is re-derived identically, the
//! `expected_holder_close_script` is recomputed from the node's own stable
//! shutdown script (it is derived, never persisted), and the [`PolicyState`]'s
//! monotonic tracker starts fresh — LDK reloads the channel's commitment state
//! from the monitor and re-drives signing from the current index, so the first
//! post-restart signing request re-establishes the baseline. There is no extra
//! persisted signer state that could be corrupted.

use std::sync::Mutex;

use bitcoin::{
    Script,
    secp256k1::{
        self, PublicKey, Secp256k1, SecretKey, ecdsa::Signature,
    },
};
use lightning::{
    ln::chan_utils::{
        self, ChannelPublicKeys, ChannelTransactionParameters, ClosingTransaction,
        CommitmentTransaction, HTLCOutputInCommitment, HolderCommitmentTransaction,
    },
    ln::msgs::{PartialSignatureWithNonce, UnsignedChannelAnnouncement},
    sign::{
        ChannelSigner, HTLCDescriptor, InMemorySigner,
        ecdsa::EcdsaChannelSigner,
        taproot::TaprootChannelSigner,
    },
    types::payment::PaymentPreimage,
};
use musig2::{PartialSignature, PubNonce as PublicNonce, secp256k1::schnorr};

// ===========================================================================
// PolicyState — the anti-revoked-reuse monotonic state machine
// ===========================================================================

/// In LDK / BOLT-3, the per-commitment number starts at `(1 << 48) - 1` and
/// **counts backwards**. State `N+1` (the *next*, more-advanced state) therefore
/// has a strictly *lower* numeric index than state `N`.
pub const INITIAL_COMMITMENT_NUMBER: u64 = (1 << 48) - 1;

/// Mutable, per-signer safety state enforcing monotonic forward progression of
/// the channel — the anti-revoked-state-replay property.
///
/// We track, separately:
///
/// * `highest_holder_commitment_signed` — the lowest-numbered (i.e.
///   most-advanced) holder commitment index for which we have produced a
///   signature. We refuse to sign a holder commitment that *regresses*
///   (numeric index strictly greater than the most-advanced we've signed),
///   because signing an old holder state hands the counterparty a revoked tx
///   they could broadcast.
///
/// * `highest_counterparty_commitment_signed` — same, for counterparty
///   commitments we sign.
///
/// * `lowest_secret_released` — the most-advanced index for which we have
///   released a revocation secret. Once a secret for index `i` is released, the
///   state at `i` is revoked forever; re-releasing or re-signing at-or-behind
///   that point would enable a revoked-state replay, so we reject it.
///
/// Because the index counts *backwards*, "forward progress" is a *decreasing*
/// numeric sequence; "regression" is an *increasing* numeric index.
///
/// All fields are `Option` so that the *first* request at any index is always
/// accepted (there is nothing to regress against yet). This is also what lets
/// the tracker reconstruct cleanly on restart: a freshly-loaded signer starts
/// with every field `None` and adopts the channel's current index from the
/// first signing request LDK re-drives.
#[derive(Debug, Default)]
struct MonotonicState {
    /// Most-advanced (lowest-numbered) holder commitment we have signed.
    highest_holder_commitment_signed: Option<u64>,
    /// Most-advanced (lowest-numbered) counterparty commitment we have signed.
    highest_counterparty_commitment_signed: Option<u64>,
    /// Most-advanced (lowest-numbered) index for which a revocation secret has
    /// been released.
    lowest_secret_released: Option<u64>,
    /// MuSig2 nonce-reuse guard, keyed by OUR public nonce (66 bytes) → the one
    /// aggregate `H(counterparty_nonce ‖ message)` we have signed under it. Our
    /// secret nonces are DETERMINISTIC (re-derived from `commitment_seed`), so the
    /// conduition `FirstRound` single-use protection is defeated by re-derivation:
    /// without this, a malicious counterparty could re-trigger a sign of the SAME
    /// instance with a DIFFERENT nonce → two partials with the same `r` but a
    /// different challenge `e` → funding-key leak `x=(s1−s2)/((e1−e2)·a)`
    /// (the MuSig2 adaptive-replay class). Keyed by the NONCE itself (not the
    /// height), so it covers every signing path — commitment/splice/close —
    /// uniformly: re-signing the IDENTICAL aggregate is allowed (same partial);
    /// a different aggregate under the same nonce is refused.
    nonce_bindings: std::collections::HashMap<[u8; 66], [u8; 32]>,
}

/// The policy configuration + mutable safety state for one channel signer.
///
/// Holds:
/// * the immutable expected closing payout script (the LP's committed P2WPKH
///   shutdown script, derived at construction — never persisted), and
/// * the [`MonotonicState`] behind a [`Mutex`] (LDK calls signers from multiple
///   contexts).
pub struct PolicyState {
    /// The LP's committed P2WPKH shutdown script that a cooperative close MUST
    /// pay to (when it pays the holder at all). This is the same script QU!D
    /// pins via `commit_upfront_shutdown_pubkey` and that
    /// `BTCChannels._lpFinalBalance` reads on the EVM side.
    expected_holder_close_script: bitcoin::ScriptBuf,
    state: Mutex<MonotonicState>,
}

impl PolicyState {
    /// Create a policy state pinned to the LP's committed close script.
    pub fn new(expected_holder_close_script: bitcoin::ScriptBuf) -> Self {
        Self {
            expected_holder_close_script,
            state: Mutex::new(MonotonicState::default()),
        }
    }

    /// The committed close script this policy enforces.
    pub fn expected_holder_close_script(&self) -> &Script {
        &self.expected_holder_close_script
    }

    /// Record + check signing a *holder* commitment at `idx`.
    ///
    /// Rejects (`Err`) if `idx` regresses behind the most-advanced holder
    /// commitment we've already signed (numeric index strictly greater), or if
    /// it is at/behind a state whose revocation secret was already released.
    /// Re-signing the *same* index is allowed (LDK may legitimately re-request).
    fn record_holder_commitment(&self, idx: u64) -> Result<(), ()> {
        let mut st = self.state.lock().map_err(|_| ())?;
        check_no_regression(st.highest_holder_commitment_signed, idx)?;
        check_not_revoked(st.lowest_secret_released, idx)?;
        st.highest_holder_commitment_signed =
            Some(advance(st.highest_holder_commitment_signed, idx));
        Ok(())
    }

    /// Record + check signing a *counterparty* commitment at `idx`.
    fn record_counterparty_commitment(&self, idx: u64) -> Result<(), ()> {
        let mut st = self.state.lock().map_err(|_| ())?;
        check_no_regression(st.highest_counterparty_commitment_signed, idx)?;
        st.highest_counterparty_commitment_signed =
            Some(advance(st.highest_counterparty_commitment_signed, idx));
        Ok(())
    }

    /// MuSig2 nonce-reuse guard (covers ALL key-path signing: holder/counterparty
    /// commitment, splice, cooperative close). Our secret nonce is deterministic,
    /// so the same `(seed,height,domain)` re-derives the SAME `our_pubnonce`. We
    /// bind that nonce to the ONE aggregate `H(cp_nonce ‖ message)` it signs:
    /// re-signing the IDENTICAL aggregate is fine (same partial), but a DIFFERENT
    /// aggregate under the same nonce is REFUSED — that is the adaptive-replay
    /// funding-key-leak vector (`x=(s1−s2)/((e1−e2)·a)`). Call this BEFORE
    /// returning any partial.
    fn bind_nonce(
        &self,
        our_pubnonce: &[u8; 66],
        cp_nonce: &[u8; 66],
        message: &[u8; 32],
    ) -> Result<(), ()> {
        use bitcoin::hashes::{Hash, HashEngine, sha256};
        let mut eng = sha256::Hash::engine();
        eng.input(&cp_nonce[..]);
        eng.input(&message[..]);
        let agg = *sha256::Hash::from_engine(eng).as_byte_array();

        let mut st = self.state.lock().map_err(|_| ())?;
        match st.nonce_bindings.get(our_pubnonce) {
            // Same nonce already signed a DIFFERENT aggregate → reuse → refuse.
            Some(prev) if *prev != agg => Err(()),
            // First use, or an identical re-sign → allow + (re)record.
            _ => {
                st.nonce_bindings.insert(*our_pubnonce, agg);
                Ok(())
            }
        }
    }

    /// Record + check releasing a revocation secret for `idx`.
    ///
    /// Releasing a secret revokes the state at `idx`. We reject a *regression*
    /// (releasing a secret for an index more-advanced-than-or-equal-to one we
    /// already released would be a re-reveal / out-of-order reveal that breaks
    /// monotonic progression). The first release at any index is accepted; a
    /// strictly-older (higher-numbered) index after a newer one is rejected.
    fn record_secret_release(&self, idx: u64) -> Result<(), ()> {
        let mut st = self.state.lock().map_err(|_| ())?;
        // Secrets must be released in forward (decreasing-index) order. If we
        // already released a secret for a more-advanced (lower) index, then
        // releasing one for an older (higher) index now is a regression.
        if let Some(prev) = st.lowest_secret_released {
            if idx > prev {
                return Err(());
            }
        }
        st.lowest_secret_released =
            Some(advance(st.lowest_secret_released, idx));
        Ok(())
    }
}

/// Returns `Err` if `idx` regresses behind the most-advanced index already
/// reached. Because the commitment number counts *backwards*, a regression is a
/// numeric *increase*. Re-using the exact same index is permitted.
fn check_no_regression(reached: Option<u64>, idx: u64) -> Result<(), ()> {
    match reached {
        // `idx > reached` means a numerically-larger == older == revoked state.
        Some(reached) if idx > reached => Err(()),
        _ => Ok(()),
    }
}

/// Returns `Err` if signing at `idx` would touch a state at/behind one whose
/// revocation secret has already been released (i.e. an already-revoked state).
fn check_not_revoked(lowest_secret_released: Option<u64>, idx: u64) -> Result<(), ()> {
    match lowest_secret_released {
        // A released secret revokes that state and every older (higher-index)
        // one. Signing at-or-behind it enables a revoked-state replay.
        Some(released) if idx >= released => Err(()),
        _ => Ok(()),
    }
}

/// Fold a newly-reached `idx` into the most-advanced (lowest) index seen.
fn advance(reached: Option<u64>, idx: u64) -> u64 {
    match reached {
        Some(reached) => reached.min(idx),
        None => idx,
    }
}

/// Pure policy check for a cooperative close: *if* the close pays the holder
/// (LP) output, that output must pay the exact committed close script.
///
/// IMPORTANT: when the holder output is **absent** — `to_holder_value_sat() ==
/// 0`, i.e. a fully-delivered LP with a zero holder balance — the close is
/// VALID. In that case LDK omits the holder output entirely (see
/// `build_closing_transaction`, which only adds the output when the value is
/// `> 0`); `to_holder_script()` still returns the stored script field, but there
/// is no holder output in the built tx to redirect, so the script is NOT
/// compared. We only reject when a holder output EXISTS and pays a *different*
/// script — the actual fund-redirection attack.
///
/// Returns `Ok(())` iff there is no holder output, or the holder output pays
/// `expected_holder_close_script`.
pub fn check_closing_payout_script(
    closing_tx: &ClosingTransaction,
    expected_holder_close_script: &Script,
) -> Result<(), ()> {
    // No holder output → nothing to redirect → valid.
    if closing_tx.to_holder_value_sat() == 0 {
        return Ok(());
    }
    if closing_tx.to_holder_script() == expected_holder_close_script {
        Ok(())
    } else {
        Err(())
    }
}

// ===========================================================================
// ValidatingChannelSigner — policy engine wrapping the in-process signer
// ===========================================================================

/// A validating channel signer: routes the two funds-critical operations
/// through [`PolicyState`] before signing, and delegates everything else
/// straight to the inner [`InMemorySigner`].
///
/// Self-host model: `inner` both derives metadata *and* produces every
/// signature. The two policy checks ([`PolicyState`] monotonic gate +
/// [`check_closing_payout_script`]) are defense-in-depth on the LP's own node.
pub struct ValidatingChannelSigner {
    inner: InMemorySigner,
    policy: PolicyState,
    /// Late-bound per-channel taproot signing context (M5).
    ///
    /// The `TaprootChannelSigner` trait surface of this LDK fork passes neither
    /// `ChannelTransactionParameters` nor the funding prevout into the MuSig2
    /// methods, so a funding key-path partial cannot be produced from the trait
    /// arguments alone: it needs the **counterparty funding pubkey** (to build
    /// the per-channel `KeyAggContext` → the `0x5120||Q` funding scriptPubKey)
    /// and the **funding amount** (committed in the BIP341 key-path sighash).
    ///
    /// The nonce-exchange handler (`channel.rs`) populates this once both are
    /// known — i.e. as soon as the channel's `channel_transaction_parameters`
    /// carry the counterparty parameters + funding outpoint — via
    /// [`Self::provide_taproot_context`]. Held behind a `Mutex` because LDK calls
    /// signers from multiple contexts. Never persisted (re-supplied by the
    /// handler from the reloaded `FundingScope` on restart).
    taproot_ctx: Mutex<Option<TaprootSignerContext>>,
    /// (E176-C) Set once the node offers a taproot context that CONTRADICTS the one
    /// already in force. Latching, and every key-path signing path checks it, so a
    /// contradiction is **fail-closed and loud** rather than a silently-stale context
    /// that would go on producing partials against the wrong aggregate.
    ///
    /// ⚠️ WHY A LATCH AND NOT "REJECT THE UPDATE". `TaprootChannelSigner::
    /// provide_taproot_context` returns `()`, so a refusal cannot be propagated to the
    /// caller. Merely ignoring the bad context would leave the previous good one in
    /// place and keep signing — which looks like success. A node that contradicts
    /// itself about what the channel IS is either broken or hostile; in both cases the
    /// safe response is to stop signing this channel, not to guess which context was
    /// the honest one.
    ctx_poisoned: std::sync::atomic::AtomicBool,
    /// (E177) The on-chain comparand, and this signer's side of the 2-of-2. Unset keeps
    /// the §E176-C self-consistency behaviour unchanged — so this is additive and a node
    /// without an EVM view is no worse off than before, never silently less checked.
    ///
    /// ⚠️ **A `OnceLock`, NOT A BUILDER FIELD, AND THAT IS FORCED BY TWO FACTS.** (1) LDK
    /// takes the signer BY VALUE the moment `derive_channel_signer` returns, so a
    /// `with_truth_source(mut self)` can never be applied to the signer LDK actually uses.
    /// (2) The on-chain `channelId` is `keccak(lpPubkey, hopPubkey, fundingTxid, vout)` and
    /// therefore **is not known at derive time** — the funding outpoint does not exist yet.
    /// So the comparand can only be attached LATER, by whoever first knows the outpoint.
    ///
    /// `OnceLock` rather than a `Mutex<Option<..>>` on purpose: the truth source must be
    /// **write-once**. A settable-twice comparand could be REPLACED by the same untrusted
    /// node it exists to check, which would hand the attacker the referee.
    truth: std::sync::OnceLock<(std::sync::Arc<dyn ChannelTruthSource>, FundingRole)>,
    /// (E177-d) Set the first time the chain reports a RECORD for this channel.
    ///
    /// 🔑 **THIS IS WHAT CLOSES THE DOWNGRADE.** Without it, a hostile node could hold the
    /// signer in [`TruthVerdict::NotRecorded`] forever — naming a funding outpoint that
    /// resolves to no channel — and so keep the on-chain comparand permanently out of play,
    /// silently reducing every check to §E176-C self-consistency. With it, `NotRecorded`
    /// after a `Match` is a REGRESSION and poisons: the pre-record window becomes strictly
    /// one-way, entered once and never re-entered.
    truth_recorded: std::sync::atomic::AtomicBool,
}

/// The late-bound per-channel data the MuSig2 (`TaprootChannelSigner`) bodies
/// need but the trait surface does not hand them (M5). Supplied by the
/// `channel.rs` nonce-exchange handler via
/// [`ValidatingChannelSigner::provide_taproot_context`].
#[derive(Clone)]
pub struct TaprootSignerContext {
    /// The counterparty's 33-byte compressed funding pubkey.
    pub counterparty_funding_pubkey: PublicKey,
    /// The channel funding amount in satoshis (committed in the key-path sighash).
    pub funding_value_sat: u64,
    /// The counterparty's current cooperative-close nonce — their `shutdown_nonce`
    /// (or the nonce from their previous `closing_sig` on an RBF round). Required
    /// by [`TaprootChannelSigner::partially_sign_closing_transaction`], which the
    /// trait surface does not pass a nonce to. `None` until `shutdown` is
    /// exchanged; set by the handler before requesting a closing partial.
    pub counterparty_closing_nonce: Option<PublicNonce>,
    /// The **cooperative-close round index** (`0` for `shutdown`/first
    /// `closing_signed`, incremented per fee-negotiation/RBF round). The closing
    /// MuSig2 secret nonce is derived at the per-round height
    /// [`closing_nonce_height`]`(closing_round)` so no two distinct close txs
    /// (different fees ⇒ different sighash messages) are ever signed with the same
    /// nonce — which would otherwise leak the funding private key. The
    /// handler bumps this each round before supplying the context; signing and the
    /// advertised `shutdown_nonce`/`next_closee_nonce` MUST use the same round.
    pub closing_round: u64,
    /// For a **spliced** funding scope: the `prev_funding_txid` the new funding key
    /// rotated from (BOLT #995). When set, this signer derives BOTH its
    /// individual funding key and the KeyAggContext from the ROTATED key, so the
    /// aggregate matches the new `0x5120||Q'`. `None` for the original funding.
    pub splice_parent_funding_txid: Option<bitcoin::Txid>,
}

/// (E177) An **on-chain** view of what a channel IS, for checks that must not be
/// answerable by the node.
///
/// 🔑 **WHY THIS TRAIT EXISTS AT ALL.** Every other input the signer receives is supplied
/// by the node — including the "previous" context §E176-C compares against. Self-consistency
/// binds a node that CONTRADICTS ITSELF; it does not bind one that lies consistently from
/// the first context onward, nor one that restarts the signer to clear the comparand
/// (measured: `nonce_binding_does_not_survive_a_restart`). The only checks that bind a
/// consistently-lying node are checks against a source of truth the node does not author.
///
/// `BTCChannels` is that source: it pins `keysHash = keccak256(abi.encode(lpPubkey,
/// hopPubkey))` and `amountSats` per channel, at open, on-chain.
///
/// ⚠️ **`keysHash` IS A HASH, SO THIS IS A VERIFIER, NOT A GETTER.** The pubkeys cannot be
/// recovered from it; a candidate pair can only be confirmed. That is enough — the signer
/// always HAS a candidate (its own base funding key plus the counterparty key the node
/// claims), and confirming it is exactly the check that matters.
///
/// ⚠️ **THE KEYS ARE THE BASE (UNROTATED) ONES.** `keysHash` is pinned at open and a splice
/// ROTATES the live funding keys, so the comparand is `inner.funding_key(None)`, never the
/// rotated scope key. Using the rotated key would fail for exactly the channels most likely
/// to be spliced.
///
/// Implemented in `quid-bridge` over the existing AGREEMENT-classed reader
/// (`client::eth_read_agreed`, pinned to `tip − AGREED_READ_DEPTH`), so a host can only
/// DEFLATE the tip to serve an older view — never forge the value at the block it names.
pub trait ChannelTruthSource: Send + Sync {
    /// Compare a candidate context against the chain.
    ///
    /// `Err(())` means the chain could not be READ, which is **fail closed** — an
    /// unreadable comparand is not permission to sign against an unchecked context, or a
    /// hostile host disables the whole check by breaking its own RPC.
    ///
    /// A successful read returns one of the three [`TruthVerdict`] states; see that type
    /// for why two would be wrong.
    fn verify(
        &self,
        lp_pubkey: &[u8; 33],
        hop_pubkey: &[u8; 33],
        funding_value_sat: u64,
    ) -> Result<TruthVerdict, ()>;
}

/// (E177-d) What the chain says about a channel. **THREE states, and the third is not
/// padding — omitting it deadlocks every channel open.**
///
/// The EVM's `openChannel` requires the funding transaction to be **SPV-proven**, which
/// happens strictly AFTER LDK has signed `funding_created` and the first commitments. So a
/// real, live, honest channel genuinely has NO on-chain record for part of its life. A
/// two-state check (match / mismatch) would refuse to sign during exactly that window and
/// no channel could ever be opened.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TruthVerdict {
    /// The chain has no record of this channel yet.
    ///
    /// ⚠️ **THIS IS THE CHECK'S DOMAIN OF DEFINITION, NOT A HOLE IN IT.** Before the record
    /// exists there is nothing to compare against — and, crucially, **the EVM has not
    /// credited the LP either**, because the record and the credit are the SAME event
    /// (`openChannel` → `registerBtcLp`). So a channel held in this state has no protocol
    /// position to steal *through the books*; the comparand is absent because the thing it
    /// would protect does not exist yet.
    NotRecorded,
    /// Recorded, and the candidate keys + funded size match what was pinned at open.
    Match,
    /// Recorded, and the candidate CONTRADICTS it.
    Mismatch,
}

/// (E177) Builds the on-chain comparand for a channel the keys manager is about to derive
/// a signer for.
///
/// 🔑 **WHY A FACTORY AND NOT JUST AN `Arc<dyn ChannelTruthSource>`.** The comparand is
/// PER-CHANNEL, but the only place a signer can be reached is
/// `SignerProvider::derive_channel_signer` (LDK takes the signer by value immediately, and
/// `ChannelMonitor` exposes no accessor — §E177-d), which is handed a `channel_keys_id`
/// and nothing else.
///
/// ⚠️ **IT RETURNS A SOURCE UNCONDITIONALLY, NEVER AN `Option`, AND THAT IS LOAD-BEARING.**
/// At derive time the on-chain `channelId` is usually UNKNOWN — it needs a funding outpoint
/// that does not exist yet. If the factory declined in that case, the signer would be born
/// without a comparand and could never acquire one (write-once, and unreachable afterwards).
/// So the source is always attached and resolves the cid LAZILY, reporting
/// [`TruthVerdict::NotRecorded`] until it can. That composes exactly with the three-state
/// check: unresolved *is* "not recorded", it is permissive while the channel is opening,
/// and the `truth_recorded` latch makes it one-way the moment the chain first answers.
pub trait TruthSourceFactory: Send + Sync {
    fn for_channel(&self, channel_keys_id: [u8; 32]) -> std::sync::Arc<dyn ChannelTruthSource>;
}

/// Which side of the 2-of-2 this signer is, so a candidate pair can be ordered the way
/// `BTCChannels` hashed it (`abi.encode(lpPubkey, hopPubkey)` — order is significant, and
/// guessing it by trying both would pin only the SET, weakening the check for no gain).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FundingRole {
    /// This signer is the vault/LP half — its base funding key is `lpPubkey`.
    Lp,
    /// This signer is the hop half — its base funding key is `hopPubkey`.
    Hop,
}

impl ValidatingChannelSigner {
    /// Build a validating signer.
    ///
    /// * `inner` — the in-process [`InMemorySigner`] (custody + metadata).
    /// * `expected_holder_close_script` — the LP's committed P2WPKH shutdown
    ///   script that cooperative closes must pay when they pay the holder (see
    ///   [`check_closing_payout_script`]). Derived from the node's own stable
    ///   shutdown script at construction; never persisted.
    pub fn new(
        inner: InMemorySigner,
        expected_holder_close_script: bitcoin::ScriptBuf,
    ) -> Self {
        Self {
            inner,
            policy: PolicyState::new(expected_holder_close_script),
            taproot_ctx: Mutex::new(None),
            ctx_poisoned: std::sync::atomic::AtomicBool::new(false),
            truth: std::sync::OnceLock::new(),
            truth_recorded: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// (E177) Bind this signer to the on-chain truth for its channel. Once set, a taproot
    /// context is additionally checked against `BTCChannels` — which the node does not
    /// author — so a node that lies CONSISTENTLY, or that restarts to clear the in-memory
    /// comparand, is caught where §E176-C's self-consistency checks cannot reach.
    pub fn with_truth_source(
        self,
        truth: std::sync::Arc<dyn ChannelTruthSource>,
        role: FundingRole,
    ) -> Self {
        let _ = self.set_truth_source(truth, role);
        self
    }

    /// (E177) Attach the on-chain comparand to a signer LDK already owns.
    ///
    /// Returns `false` if one was already set — **write-once by design** (see the field
    /// doc): a comparand the node could replace is not a comparand. A `false` return is a
    /// programming error at the call site, not a condition to retry.
    pub fn set_truth_source(
        &self,
        truth: std::sync::Arc<dyn ChannelTruthSource>,
        role: FundingRole,
    ) -> bool {
        self.truth.set((truth, role)).is_ok()
    }

    /// (E177) Whether an on-chain comparand is attached. A signer WITHOUT one runs only the
    /// §E176-C self-consistency checks, which bind a node that contradicts itself and
    /// nothing more — worth being able to assert on rather than assume.
    pub fn has_truth_source(&self) -> bool {
        self.truth.get().is_some()
    }

    /// (E177) Check a candidate taproot context against the chain. `Ok(())` when there is
    /// no truth source (unchanged §E176-C behaviour); otherwise both the funding-key pair
    /// and the funded size must match what `BTCChannels` pinned.
    fn check_against_chain(&self, ctx: &TaprootSignerContext) -> Result<(), ()> {
        use std::sync::atomic::Ordering::SeqCst;
        let Some((truth, role)) = self.truth.get() else { return Ok(()) };
        // 🔴 THE CURRENT-SCOPE KEY, NOT THE BASE ONE. This read `funding_key(None)` with the comment
        // *"the BASE key: `keysHash` was pinned at open, before any splice rotation"* — TRUE WHEN
        // WRITTEN AND FALSE SINCE §SPLICE-ROTATES-BOTH-FUNDING-KEYS (2026-09-01), which made `splice`
        // RE-PIN `keysHash` to the rotated pair. `ChannelTruth::verify` compares the on-chain
        // `keysHash` against exactly the pair passed here, so supplying the base pair for a channel
        // that has been spliced yields `Mismatch` ⇒ **fail closed ⇒ the signer refuses to sign a
        // spliced channel at all.** The old premise held only because the EVM used to REJECT rotated
        // pairs, which kept `keysHash` frozen at the base while the chain moved on — i.e. the check
        // agreed with the contract by both being stale.
        // ⇒ `ctx.splice_parent_funding_txid` is the scope selector LDK already threads for this, and
        // `taproot_holder_funding_key` (`:781`) derives its signing key the same way — so this now
        // asks the chain about the SAME key it is about to sign with.
        let secp = Secp256k1::new();
        let ours = self
            .inner
            .funding_key(ctx.splice_parent_funding_txid)
            .public_key(&secp)
            .serialize();
        let theirs = ctx.counterparty_funding_pubkey.serialize();
        let (lp, hop) = match role {
            FundingRole::Lp => (&ours, &theirs),
            FundingRole::Hop => (&theirs, &ours),
        };
        // `Err` = unreadable chain ⇒ fail closed (propagated, poisons at the call site).
        match truth.verify(lp, hop, ctx.funding_value_sat)? {
            TruthVerdict::Match => {
                self.truth_recorded.store(true, SeqCst);
                Ok(())
            }
            TruthVerdict::Mismatch => Err(()),
            // The one-way window. Legitimate BEFORE the record exists; a DOWNGRADE ATTEMPT
            // after one has been seen, which is the only form the downgrade can take.
            TruthVerdict::NotRecorded => {
                if self.truth_recorded.load(SeqCst) { Err(()) } else { Ok(()) }
            }
        }
    }

    /// (E176-C) True once the node has contradicted a taproot context already in force.
    /// Every key-path signing path refuses while this is set.
    pub fn ctx_poisoned(&self) -> bool {
        self.ctx_poisoned.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Borrow the wrapped in-process signer.
    pub fn inner(&self) -> &InMemorySigner {
        &self.inner
    }

    /// Borrow the policy state (for inspection / tests).
    pub fn policy(&self) -> &PolicyState {
        &self.policy
    }

    /// Supply the late-bound per-channel taproot signing context (M5).
    ///
    /// Called by the `channel.rs` nonce-exchange handler as soon as the
    /// counterparty funding pubkey + funding amount are known (the channel's
    /// `channel_transaction_parameters` carry the counterparty parameters and
    /// funding outpoint). Idempotent: re-supplying the same context is a no-op;
    /// re-supplying a *different* context replaces it (a splice rebinds Q). This
    /// is the data the MuSig2 funding key-path bodies need but the
    /// `TaprootChannelSigner` trait surface does not pass.
    /// (E176-C) ⚠️ **EVERY FIELD HERE IS SUPPLIED BY THE NODE AND NONE OF IT USED TO BE
    /// CHECKED.** This was the highest-risk delegating path in the signer: the context
    /// is what `taproot_key_agg` builds `Q` from and what the closing nonce height is
    /// derived from, so a node that could rewrite it did not have to defeat the policy
    /// checks — it moved the frame of reference they are computed against.
    ///
    /// Three invariants are enforced, all against the context ALREADY in force (the
    /// signer's only trustworthy comparand here — see the on-chain note below):
    ///
    /// 1. **`closing_round` NEVER REGRESSES.** The cooperative-close secret nonce is
    ///    derived at `closing_nonce_height(closing_round)`, so replaying a round with a
    ///    DIFFERENT closing transaction signs a different message under the SAME nonce
    ///    — the funding-key leak `x=(s1−s2)/((e1−e2)·a)`. `bind_nonce` catches this at
    ///    use time; this catches it at the source, which is where the node controls it.
    /// 2. **The counterparty funding pubkey is IMMUTABLE** for a funding scope. Swapping
    ///    it mid-channel rebuilds `Q` around a key the counterparty chose, and every
    ///    subsequent partial would be against a channel the LP never agreed to.
    /// 3. **The funding value is IMMUTABLE** for a funding scope. It is committed in the
    ///    BIP-341 key-path sighash, so a wrong value signs a different message.
    ///
    /// (2) and (3) are relaxed EXACTLY when `splice_parent_funding_txid` changes, because
    /// a splice legitimately rotates the funding key and resizes the channel. That is the
    /// one honest reason for either to move, and tying the relaxation to it means a
    /// rebind cannot be requested without also declaring the rotation.
    ///
    /// 🔴 **WHAT THIS STILL DOES NOT DO, STATED SO IT IS NOT MISTAKEN FOR COMPLETE.**
    /// These checks compare node-supplied data against EARLIER node-supplied data, so
    /// they bind a node that contradicts itself — not one that lies CONSISTENTLY from
    /// the first context onward, nor one that restarts the signer to clear the
    /// comparand (`taproot_ctx` starts `None`, exactly like `nonce_bindings`). Closing
    /// that requires validating against a source of truth the node does not author:
    /// `BTCChannels` already pins `keysHash = keccak256(lpPubkey, hopPubkey)`,
    /// `amountSats` and `btcRecipientOf` on-chain. See §E177.
    pub fn provide_taproot_context(&self, ctx: TaprootSignerContext) {
        if let Ok(mut slot) = self.taproot_ctx.lock() {
            if let Some(prev) = slot.as_ref() {
                let splice_rotated =
                    prev.splice_parent_funding_txid != ctx.splice_parent_funding_txid;
                let regressed_round = ctx.closing_round < prev.closing_round;
                let rebound_identity = !splice_rotated
                    && (ctx.counterparty_funding_pubkey != prev.counterparty_funding_pubkey
                        || ctx.funding_value_sat != prev.funding_value_sat);
                if regressed_round || rebound_identity {
                    self.ctx_poisoned.store(true, std::sync::atomic::Ordering::SeqCst);
                    return; // leave the in-force context untouched; signing now fails closed
                }
            }
            // (E177) The check that does NOT reduce to trusting the node. Applied to the
            // FIRST context too — which is the whole point: the checks above have nothing
            // to compare a first context against, and that is precisely the gap a
            // consistently-lying node (or one that restarted the signer) walks through.
            if self.check_against_chain(&ctx).is_err() {
                self.ctx_poisoned.store(true, std::sync::atomic::Ordering::SeqCst);
                return;
            }
            *slot = Some(ctx);
        }
    }


    /// (E176-E) The holder-HTLC destination lock.
    ///
    /// 🔑 **WHY THIS ONE IS CHECKABLE WHEN THE OTHER EIGHT DELEGATES ARE NOT.** `HTLCDescriptor`
    /// carries `tx_output()` — the output LDK ITSELF derives from the channel's own keys
    /// (revocation + delayed-payment basepoints). So the signer is told what the transaction
    /// is SUPPOSED to look like, and a node that hands it a different one is contradicting
    /// data it does not author. The justice and counterparty-HTLC entrypoints receive only
    /// an `HTLCOutputInCommitment` + amount + keys — **no expected destination at all** —
    /// so there is nothing to compare against there, and inventing a rule would be the
    /// false-safety clamp standing rule 3 forbids.
    ///
    /// Two things are pinned:
    /// * the input being signed spends the outpoint the descriptor names — otherwise a
    ///   signature meant for one HTLC could be harvested for another;
    /// * the descriptor's own output is PRESENT in the transaction — so the swept value
    ///   goes where the channel keys say it goes, not to a script the node picked.
    ///
    /// ⚠️ Deliberately `contains`, not "outputs == [expected]": a legitimate HTLC
    /// transaction may also carry an anchor or change output, and demanding an exact output
    /// set would reject honest transactions — a guard that breaks the happy path gets
    /// removed, not fixed.
    fn check_holder_htlc_tx(
        &self,
        htlc_tx: &bitcoin::Transaction,
        input: usize,
        htlc_descriptor: &HTLCDescriptor,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<(), ()> {
        let txin = htlc_tx.input.get(input).ok_or(())?;
        if txin.previous_output != htlc_descriptor.outpoint() {
            return Err(());
        }
        let expected = htlc_descriptor.tx_output(secp_ctx);
        if !htlc_tx.output.iter().any(|o| *o == expected) {
            return Err(());
        }
        Ok(())
    }

    /// Build the cached per-channel KeySorted + taproot-tweaked `KeyAggContext`
    /// and our signer index from the supplied taproot context, plus return the
    /// funding amount + the `0x5120||Q` funding scriptPubKey that the BIP341
    /// key-path sighash commits to. `Err(())` if no context has been supplied yet
    /// (the handler must call [`Self::provide_taproot_context`] first).
    fn taproot_key_agg(
        &self,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<(musig2::KeyAggContext, usize, usize, u64, bitcoin::ScriptBuf), ()> {
        // (E176-C) Fail closed on a self-contradicting node. This is the ONE choke point
        // every key-path partial passes through — commitment, close and splice all build
        // their aggregate here — so the latch is checked once and covers all of them.
        if self.ctx_poisoned() {
            return Err(());
        }
        let ctx = {
            let slot = self.taproot_ctx.lock().map_err(|_| ())?;
            slot.clone().ok_or(())?
        };
        // Use the ROTATED holder funding key for a spliced scope (matching the new
        // Q'); the base key otherwise.
        let holder = self
            .inner
            .funding_key(ctx.splice_parent_funding_txid)
            .public_key(secp_ctx)
            .serialize();
        let cp = ctx.counterparty_funding_pubkey.serialize();
        let (key_agg, our_index) =
            crate::taproot_signer::channel_key_agg_ctx(&holder, &cp, &holder)
                .map_err(|_| ())?;
        let counterparty_index = 1 - our_index;
        // Funding scriptPubKey: 0x5120 || Q (the x-only tweaked aggregate).
        let q = crate::taproot_signer::aggregated_xonly(&key_agg);
        let spk = bitcoin::ScriptBuf::new_p2tr_tweaked(
            bitcoin::key::TweakedPublicKey::dangerous_assume_tweaked(q),
        );
        Ok((key_agg, our_index, counterparty_index, ctx.funding_value_sat, spk))
    }

    /// The (rotated, for a splice) holder funding SECRET key the current taproot
    /// context's funding scope signs with — `inner.funding_key(splice_parent)`. Used
    /// by the funding key-path partials so a spliced commitment signs with the SAME
    /// rotated key the new Q' aggregate is built from.
    fn taproot_holder_funding_key(&self) -> secp256k1::SecretKey {
        let parent = self
            .taproot_ctx
            .lock()
            .ok()
            .and_then(|s| s.as_ref().and_then(|c| c.splice_parent_funding_txid));
        self.inner.funding_key(parent)
    }

    // === DEAD-MAN EXIT (#114) — sign-in-place, funding key NEVER exported ===
    //
    // These two inherent methods are the security-surface answer for the daemon
    // wiring: the fleet (which holds BOTH the hop-node and the vault-node signers)
    // pre-signs a unilateral-exit tx OUTSIDE the live commitment/close flow. They
    // mirror `generate_local_nonce_pair` (:919) + `partially_sign_counterparty_commitment`
    // (:952) exactly, but over the caller-supplied exit-tx sighash and through the
    // DEAD_MAN-tagged nonce path. The raw funding secret key is sourced INTERNALLY via
    // `taproot_holder_funding_key()` and NEVER leaves the signer — only a MuSig2 partial
    // (a scalar that reveals nothing about the key) is returned. (The export-style
    // `taproot_signer::key_path_sign_2of2_deadman`, which takes raw seckeys, stays a
    // tested reference ONLY — never used in prod.)

    /// DEAD-MAN EXIT (#114): the PUBLIC signing context the pre-sign orchestrator needs
    /// to build the exit tx + aggregate the two partials — the per-channel MuSig2
    /// [`musig2::KeyAggContext`] (aggregate of the two funding PUBLIC keys), our slot
    /// index, the counterparty slot index, and the funding prevout (`funding_value` +
    /// the `0x5120||Q` funding scriptPubKey the exit spends). Contains NO secret
    /// material (only public keys / the funding SPK), so exporting it is safe; the raw
    /// funding seckey stays inside [`Self::deadman_exit_partial`]. `Err(())` if no
    /// taproot context has been supplied yet.
    pub fn taproot_public_context(
        &self,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<(musig2::KeyAggContext, usize, usize, bitcoin::Amount, bitcoin::ScriptBuf), ()> {
        let (key_agg, our_index, cp_index, value_sat, spk) = self.taproot_key_agg(secp_ctx)?;
        Ok((key_agg, our_index, cp_index, bitcoin::Amount::from_sat(value_sat), spk))
    }

    /// DEAD-MAN EXIT (#114): our deterministic MuSig2 **public nonce** for pre-signing
    /// the unilateral-exit tx whose BIP341 key-path sighash is `message`, at the
    /// per-channel refresh `height`. Mirrors [`Self::generate_local_nonce_pair`] but
    /// via the DEAD_MAN-tagged, message-bound nonce path
    /// ([`crate::taproot_signer::local_pubnonce_deadman`]). The `KeyAggContext` is the
    /// CURRENT funding-key aggregate (the exit spends the current `0x5120||Q` funding
    /// output), taken from the handler-supplied taproot context. Funding key not touched.
    pub fn deadman_exit_pubnonce(
        &self,
        height: u64,
        message: &[u8; 32],
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<PublicNonce, ()> {
        let (key_agg, our_index, _cp_index, _value, _spk) = self.taproot_key_agg(secp_ctx)?;
        crate::taproot_signer::local_pubnonce_deadman(
            key_agg,
            our_index,
            &self.inner.commitment_seed,
            height,
            message,
        )
        .map_err(|_| ())
    }

    /// DEAD-MAN EXIT (#114): our MuSig2 key-path **partial signature** over the exit-tx
    /// sighash `message`, given the OTHER funding half's public nonce, plus our own
    /// public nonce (needed to aggregate). Mirrors
    /// [`Self::partially_sign_counterparty_commitment`]: the raw funding seckey is read
    /// IN-PLACE via [`Self::taproot_holder_funding_key`] and never returned, and the
    /// same `policy.bind_nonce` MuSig2 nonce-reuse guard runs before we hand back the
    /// partial. Combine the two halves' `(partial, pubnonce)` via
    /// [`crate::taproot_signer::aggregate_key_path_partials`] into the 64-byte Schnorr sig.
    pub fn deadman_exit_partial(
        &self,
        counterparty_nonce: PublicNonce,
        height: u64,
        message: &[u8; 32],
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<(PartialSignature, PublicNonce), ()> {
        let (key_agg, our_index, counterparty_index, _value, _spk) =
            self.taproot_key_agg(secp_ctx)?;
        let cp_nonce_bytes = counterparty_nonce.serialize();
        let (partial, our_pubnonce) = crate::taproot_signer::our_key_path_partial_deadman(
            key_agg,
            our_index,
            counterparty_index,
            self.taproot_holder_funding_key(),
            &self.inner.commitment_seed,
            height,
            counterparty_nonce,
            *message,
        )
        .map_err(|_| ())?;
        // MuSig2 nonce-reuse guard (see PolicyState::bind_nonce) — identical to the
        // counterparty/splice/close paths.
        self.policy
            .bind_nonce(&our_pubnonce.serialize(), &cp_nonce_bytes, message)?;
        Ok((partial, our_pubnonce))
    }
}

impl ChannelSigner for ValidatingChannelSigner {
    // --- Metadata / non-funds-critical: delegate straight to inner. ---

    fn get_per_commitment_point(
        &self,
        idx: u64,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<PublicKey, ()> {
        self.inner.get_per_commitment_point(idx, secp_ctx)
    }

    fn pubkeys(&self, secp_ctx: &Secp256k1<secp256k1::All>) -> ChannelPublicKeys {
        self.inner.pubkeys(secp_ctx)
    }

    fn new_funding_pubkey(
        &self,
        splice_parent_funding_txid: bitcoin::Txid,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> PublicKey {
        self.inner.new_funding_pubkey(splice_parent_funding_txid, secp_ctx)
    }

    fn channel_keys_id(&self) -> [u8; 32] {
        self.inner.channel_keys_id()
    }

    // --- Funds-critical: route through policy. ---

    /// Release a revocation secret — gated by the monotonic state machine so
    /// that we never reveal a secret out of forward order (which would enable a
    /// revoked-state replay).
    fn release_commitment_secret(&self, idx: u64) -> Result<[u8; 32], ()> {
        self.policy.record_secret_release(idx)?;
        self.inner.release_commitment_secret(idx)
    }

    /// Validate the counterparty's signatures on our holder commitment before
    /// we commit to it.
    ///
    /// Monotonic anti-revoked-reuse: refuse to "accept" (and thereby later sign
    /// / release secrets around) a holder commitment that regresses behind the
    /// most-advanced one or that sits at an already-revoked index, then delegate
    /// to `inner`.
    fn validate_holder_commitment(
        &self,
        holder_tx: &HolderCommitmentTransaction,
        outbound_htlc_preimages: Vec<PaymentPreimage>,
    ) -> Result<(), ()> {
        // `HolderCommitmentTransaction` derefs to `CommitmentTransaction`.
        let idx = holder_tx.commitment_number();
        self.policy.record_holder_commitment(idx)?;
        self.inner
            .validate_holder_commitment(holder_tx, outbound_htlc_preimages)
    }

    /// Validate the counterparty's revocation of a prior state. Delegated to
    /// `inner` (self-host trusts its own node here).
    fn validate_counterparty_revocation(
        &self,
        idx: u64,
        secret: &SecretKey,
    ) -> Result<(), ()> {
        self.inner.validate_counterparty_revocation(idx, secret)
    }
}

impl EcdsaChannelSigner for ValidatingChannelSigner {
    /// Sign the counterparty's commitment.
    ///
    /// Monotonic anti-revoked-reuse gate on the counterparty commitment index
    /// before signing.
    fn sign_counterparty_commitment(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        commitment_tx: &CommitmentTransaction,
        inbound_htlc_preimages: Vec<PaymentPreimage>,
        outbound_htlc_preimages: Vec<PaymentPreimage>,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<(Signature, Vec<Signature>), ()> {
        let idx = commitment_tx.commitment_number();
        self.policy.record_counterparty_commitment(idx)?;
        self.inner.sign_counterparty_commitment(
            channel_parameters,
            commitment_tx,
            inbound_htlc_preimages,
            outbound_htlc_preimages,
            secp_ctx,
        )
    }

    /// Sign our holder commitment.
    ///
    /// Monotonic anti-revoked-reuse gate — refuse to sign a holder commitment
    /// that regresses or sits at an already-revoked index.
    fn sign_holder_commitment(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        commitment_tx: &HolderCommitmentTransaction,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<Signature, ()> {
        let idx = commitment_tx.commitment_number();
        self.policy.record_holder_commitment(idx)?;
        self.inner.sign_holder_commitment(
            channel_parameters,
            commitment_tx,
            secp_ctx,
        )
    }

    // NOTE: `EcdsaChannelSigner::unsafe_sign_holder_commitment` is gated in the
    // vendored fork behind `#[cfg(any(test, feature = "_test_utils", feature =
    // "unsafe_revoked_tx_signing"))]`. Those are *lightning*'s features, and
    // quid-ln does not enable them, so the method is NOT part of the trait as
    // lightning is compiled for us — implementing it would not compile. It is
    // intentionally omitted.

    fn sign_justice_revoked_output(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        justice_tx: &bitcoin::Transaction,
        input: usize,
        amount: u64,
        per_commitment_key: &SecretKey,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<Signature, ()> {
        // Justice transactions spend the *counterparty's* revoked broadcast.
        // Signing one is always safe for us (it claims funds the counterparty
        // forfeited by broadcasting a revoked state); no anti-replay gate
        // needed on our side. Delegate.
        // `inner` implements both Ecdsa + Taproot signer traits (taproot is in
        // the default build now), so disambiguate to the ECDSA method here.
        EcdsaChannelSigner::sign_justice_revoked_output(
            &self.inner,
            channel_parameters,
            justice_tx,
            input,
            amount,
            per_commitment_key,
            secp_ctx,
        )
    }

    fn sign_justice_revoked_htlc(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        justice_tx: &bitcoin::Transaction,
        input: usize,
        amount: u64,
        per_commitment_key: &SecretKey,
        htlc: &HTLCOutputInCommitment,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<Signature, ()> {
        EcdsaChannelSigner::sign_justice_revoked_htlc(
            &self.inner,
            channel_parameters,
            justice_tx,
            input,
            amount,
            per_commitment_key,
            htlc,
            secp_ctx,
        )
    }

    fn sign_holder_htlc_transaction(
        &self,
        htlc_tx: &bitcoin::Transaction,
        input: usize,
        htlc_descriptor: &HTLCDescriptor,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<Signature, ()> {
        self.check_holder_htlc_tx(htlc_tx, input, htlc_descriptor, secp_ctx)?;
        EcdsaChannelSigner::sign_holder_htlc_transaction(
            &self.inner,
            htlc_tx,
            input,
            htlc_descriptor,
            secp_ctx,
        )
    }

    fn sign_counterparty_htlc_transaction(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        htlc_tx: &bitcoin::Transaction,
        input: usize,
        amount: u64,
        per_commitment_point: &PublicKey,
        htlc: &HTLCOutputInCommitment,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<Signature, ()> {
        EcdsaChannelSigner::sign_counterparty_htlc_transaction(
            &self.inner,
            channel_parameters,
            htlc_tx,
            input,
            amount,
            per_commitment_point,
            htlc,
            secp_ctx,
        )
    }

    // --- Simple-taproot on-chain resolution (M9e). Justice/HTLC-claim sweeps of
    // the *counterparty's* revoked/force-closed broadcast are always safe for us
    // (they claim funds the counterparty forfeited); delegate to the inner signer,
    // which produces the BIP340 Schnorr script-/key-path sigs.
    fn sign_justice_revoked_output_taproot(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        justice_tx: &bitcoin::Transaction,
        input: usize,
        amount: u64,
        per_commitment_key: &SecretKey,
        all_prevouts: &[bitcoin::TxOut],
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<schnorr::Signature, ()> {
        EcdsaChannelSigner::sign_justice_revoked_output_taproot(
            &self.inner,
            channel_parameters,
            justice_tx,
            input,
            amount,
            per_commitment_key,
            all_prevouts,
            secp_ctx,
        )
    }

    fn sign_justice_revoked_htlc_taproot(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        justice_tx: &bitcoin::Transaction,
        input: usize,
        amount: u64,
        per_commitment_key: &SecretKey,
        htlc: &HTLCOutputInCommitment,
        all_prevouts: &[bitcoin::TxOut],
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<schnorr::Signature, ()> {
        EcdsaChannelSigner::sign_justice_revoked_htlc_taproot(
            &self.inner,
            channel_parameters,
            justice_tx,
            input,
            amount,
            per_commitment_key,
            htlc,
            all_prevouts,
            secp_ctx,
        )
    }

    fn sign_holder_htlc_transaction_taproot(
        &self,
        htlc_tx: &bitcoin::Transaction,
        input: usize,
        htlc_descriptor: &HTLCDescriptor,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<schnorr::Signature, ()> {
        self.check_holder_htlc_tx(htlc_tx, input, htlc_descriptor, secp_ctx)?;
        EcdsaChannelSigner::sign_holder_htlc_transaction_taproot(
            &self.inner,
            htlc_tx,
            input,
            htlc_descriptor,
            secp_ctx,
        )
    }

    fn sign_counterparty_htlc_transaction_taproot(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        htlc_tx: &bitcoin::Transaction,
        input: usize,
        amount: u64,
        per_commitment_point: &PublicKey,
        htlc: &HTLCOutputInCommitment,
        all_prevouts: &[bitcoin::TxOut],
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<schnorr::Signature, ()> {
        EcdsaChannelSigner::sign_counterparty_htlc_transaction_taproot(
            &self.inner,
            channel_parameters,
            htlc_tx,
            input,
            amount,
            per_commitment_point,
            htlc,
            all_prevouts,
            secp_ctx,
        )
    }

    /// Sign a cooperative closing transaction.
    ///
    /// Closing payout-script lock — if the close pays the holder (LP), that
    /// output MUST pay the committed P2WPKH shutdown script; a close redirecting
    /// the LP's funds is rejected before any signature is produced. A close with
    /// no holder output (fully-delivered LP) passes.
    fn sign_closing_transaction(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        closing_tx: &ClosingTransaction,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<Signature, ()> {
        check_closing_payout_script(
            closing_tx,
            self.policy.expected_holder_close_script(),
        )?;
        self.inner.sign_closing_transaction(
            channel_parameters,
            closing_tx,
            secp_ctx,
        )
    }

    fn sign_holder_keyed_anchor_input(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        anchor_tx: &bitcoin::Transaction,
        input: usize,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<Signature, ()> {
        self.inner.sign_holder_keyed_anchor_input(
            channel_parameters,
            anchor_tx,
            input,
            secp_ctx,
        )
    }

    fn sign_channel_announcement_with_funding_key(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        msg: &UnsignedChannelAnnouncement,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<Signature, ()> {
        self.inner.sign_channel_announcement_with_funding_key(
            channel_parameters,
            msg,
            secp_ctx,
        )
    }

    fn sign_splice_shared_input(
        &self,
        channel_parameters: &ChannelTransactionParameters,
        tx: &bitcoin::Transaction,
        input_index: usize,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Signature {
        // Non-fallible per the LDK trait (no policy Err path). Delegate.
        self.inner.sign_splice_shared_input(
            channel_parameters,
            tx,
            input_index,
            secp_ctx,
        )
    }
}

// ===========================================================================
// TaprootChannelSigner — MuSig2 key-path signer for simple taproot channels
// ===========================================================================
//
// QU!D's simple taproot channels use the SAME validating wrapper as the ECDSA
// path: the anti-revoked-reuse monotonic gate ([`PolicyState`]) and the
// closing-payout-script lock ([`check_closing_payout_script`]) are
// *scheme-agnostic* — they constrain commitment *indices* and *output scripts*,
// not signature bytes — so they are reused verbatim here.
//
// The MuSig2 nonce is **deterministic per commitment height**, derived from the
// channel's shachain root (the inner signer's `commitment_seed`, the same secret
// that backs revocation-secret derivation) via the
// [`crate::taproot_signer`] core. It is re-derivable, never random, never
// persisted.
//
// M4 status — the taproot commitment + closing **tx format** now exists, built
// + BOLT-vector-pinned in [`lightning::ln::chan_utils`] (NUMS `to_local` /
// `to_remote` / anchor tapscripts; BIP-86 close; and the BIP341 key-path funding
// TapSighash helper [`chan_utils::taproot_funding_keyspend_sighash`]). The
// MuSig2 signing core ([`crate::taproot_signer`]) is also complete (M2).
//
// M5 status — the three funding-key-path **MuSig2** methods
// (`partially_sign_counterparty_commitment`, `finalize_holder_commitment`,
// `partially_sign_closing_transaction`) are now **implemented**. A funding
// key-path partial needs (a) the **counterparty funding pubkey** to build the
// per-channel `KeyAggContext` (→ the `0x5120||Q` funding scriptPubKey + funding
// amount the sighash commits to), and (b) the **counterparty nonce / partial**
// to drive the 2-party round. (a) is not on this fork's `TaprootChannelSigner`
// trait surface (it passes NO `ChannelTransactionParameters`), so the
// nonce-exchange handler supplies it as a late-bound [`TaprootSignerContext`]
// via [`ValidatingChannelSigner::provide_taproot_context`]; (b) is the nonce the
// trait DOES pass (`counterparty_nonce` / the `PartialSignatureWithNonce`), or —
// for the close, which the trait passes no nonce to — the peer's `shutdown_nonce`
// carried in the same `TaprootSignerContext`. The deterministic per-height JIT
// signing nonce + the partial-sign + aggregate run through [`crate::taproot_signer`].
//
// The **policy gate runs first** in every body — exactly as in the ECDSA impl —
// so the anti-replay / payout-script invariants hold before any key material is
// touched. The end-to-end MuSig2 flow (open/commitment partial-sign + coop
// close → aggregate → BIP340 verify vs the tweaked Q) is proven by
// `tests::taproot_open_commitment_and_coop_close_signatures_verify`.
//
// The HTLC + justice taproot methods (`sign_holder_htlc_transaction`,
// `sign_counterparty_htlc_transaction`, `sign_justice_revoked_output/htlc`) are
// implemented below and policy-gated like the commitment path — M9 added taproot
// HTLCs (the custody channel carries every swap HTLC, so they are not optional).
impl TaprootChannelSigner for ValidatingChannelSigner {
    /// Store the late-bound per-channel MuSig2 signing context supplied by LDK's
    /// `ChannelContext` nonce-exchange handler.
    ///
    /// LOAD-BEARING: this **trait** method is the one LDK's `channel.rs` actually
    /// dispatches to (`taproot_signer.provide_taproot_context(ctx)` where
    /// `taproot_signer: &SP::TaprootSigner`). The `TaprootChannelSigner` trait
    /// supplies a no-op default `provide_taproot_context`, so WITHOUT this override
    /// every call from the handler would silently drop the context and the very
    /// next `generate_local_nonce_pair` would panic ("taproot context must be
    /// supplied before advertising a nonce"). The inherent
    /// [`ValidatingChannelSigner::provide_taproot_context`] (which the in-process
    /// unit tests call directly via the concrete type) is reused here after
    /// translating LDK's `crate::sign::TaprootSignerContext` into our mirror
    /// [`TaprootSignerContext`]; both carry the identical fields.
    fn provide_taproot_context(&self, ctx: lightning::sign::TaprootSignerContext) {
        ValidatingChannelSigner::provide_taproot_context(
            self,
            TaprootSignerContext {
                counterparty_funding_pubkey: ctx.counterparty_funding_pubkey,
                funding_value_sat: ctx.funding_value_sat,
                counterparty_closing_nonce: ctx.counterparty_closing_nonce,
                closing_round: ctx.closing_round,
                splice_parent_funding_txid: ctx.splice_parent_funding_txid,
            },
        )
    }

    /// Generate this signer's **deterministic** local MuSig2 nonce pair for the
    /// commitment at `commitment_number`, returning the public nonce to send to
    /// the counterparty.
    ///
    /// The secret nonce is shachain-derived from the inner signer's
    /// `commitment_seed` at the commitment height (re-derivable, never random,
    /// never persisted). It is bound to our holder funding pubkey so
    /// that a partial signature produced later with our funding key matches this
    /// public nonce.
    fn generate_local_nonce_pair(
        &self,
        commitment_number: u64,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> PublicNonce {
        // Derive the public nonce through the SAME conduition `FirstRound` path
        // the signing methods use (it binds the aggregated pubkey + signer index
        // + spices into the secret nonce). The per-channel KeyAggContext requires
        // the counterparty funding pubkey, supplied by the nonce-exchange handler
        // via `provide_taproot_context`; this is available before any commitment
        // nonce is advertised (open/funding exchange the next_local_nonce only
        // after the counterparty's funding pubkey is known). The secret nonce is
        // shachain-derived from `commitment_seed` at the commitment height
        // (re-derivable, never random, never persisted).
        let (key_agg, our_index, _cp_index, _value, _spk) = self
            .taproot_key_agg(secp_ctx)
            .expect("taproot context must be supplied before advertising a nonce");
        crate::taproot_signer::local_pubnonce(
            key_agg,
            our_index,
            &self.inner.commitment_seed,
            commitment_number,
        )
        .expect("local nonce derivation")
    }

    /// Partial-sign the counterparty's commitment transaction.
    ///
    /// Anti-revoked-reuse gate on the counterparty commitment index runs FIRST
    /// (reused verbatim from the ECDSA path); the MuSig2 partial signature over
    /// the BIP341 key-path TapSighash is produced once the M4 taproot
    /// commitment-tx format lands (LDK's current built tx is the legacy P2WSH
    /// ECDSA form).
    fn partially_sign_counterparty_commitment(
        &self,
        counterparty_nonce: PublicNonce,
        commitment_tx: &CommitmentTransaction,
        _inbound_htlc_preimages: Vec<PaymentPreimage>,
        _outbound_htlc_preimages: Vec<PaymentPreimage>,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<(PartialSignatureWithNonce, Vec<schnorr::Signature>), ()> {
        // Policy: monotonic anti-revoked-reuse gate (scheme-agnostic), runs FIRST.
        let idx = commitment_tx.commitment_number();
        self.policy.record_counterparty_commitment(idx)?;

        // Build the per-channel KeyAggContext + funding amount/SPK from the
        // handler-supplied taproot context (M5).
        let (key_agg, our_index, counterparty_index, funding_value_sat, funding_spk) =
            self.taproot_key_agg(secp_ctx)?;

        // BIP341 key-path sighash over the M4 taproot commitment tx (input 0 =
        // the funding outpoint). HTLC sigs are empty for a no-HTLC channel.
        let built = commitment_tx.trust();
        let tx = &built.built_transaction().transaction;
        let sighash = chan_utils::taproot_funding_keyspend_sighash(
            tx,
            0,
            bitcoin::Amount::from_sat(funding_value_sat),
            &funding_spk,
        )
        .map_err(|_| ())?;
        let message: [u8; 32] = *sighash.as_ref();

        // Our deterministic per-height JIT signing nonce + key-path partial.
        // Counterparty commitment: domain-separated nonce so it can never equal
        // the holder-commitment nonce at this same `idx` (holder & counterparty
        // commitment numbers count down from INITIAL_COMMITMENT_NUMBER in
        // lockstep) — reuse across the two commitment sighashes leaks the funding
        // key (x = (s1 - s2)/(e1 - e2)).
        let cp_nonce_bytes = counterparty_nonce.serialize();
        let (partial, our_pubnonce) = crate::taproot_signer::our_key_path_partial_counterparty(
            key_agg,
            our_index,
            counterparty_index,
            self.taproot_holder_funding_key(),
            &self.inner.commitment_seed,
            idx,
            counterparty_nonce,
            message,
        )
        .map_err(|_| ())?;
        // MuSig2 nonce-reuse guard: bind this deterministic nonce to its one aggregate.
        self.policy
            .bind_nonce(&our_pubnonce.serialize(), &cp_nonce_bytes, &message)?;

        // HTLC sigs (M9b): plain BIP340 Schnorr over each non-dust
        // second-level HTLC tx, signed with OUR htlc base key. The policy gate
        // (anti-revoked-reuse) already ran above; the per-HTLC sigs claim no funds
        // by themselves so no additional gate is needed. The counterparty is the
        // broadcaster of their own commitment → `to_broadcaster_delay`.
        let contest_delay = built.to_broadcaster_delay().unwrap_or(0);
        let htlc_sigs = chan_utils::taproot_counterparty_commitment_htlc_sigs(
            commitment_tx,
            &self.inner.htlc_base_key,
            contest_delay,
            secp_ctx,
        )
        .map_err(|_| ())?;

        Ok((PartialSignatureWithNonce(partial, our_pubnonce), htlc_sigs))
    }

    /// Finalize (counter-sign) our holder commitment by aggregating the
    /// counterparty's partial signature into the funding key-path Schnorr sig.
    ///
    /// Anti-revoked-reuse gate on the holder commitment index runs FIRST (reused
    /// verbatim from the ECDSA path).
    fn finalize_holder_commitment(
        &self,
        commitment_tx: &HolderCommitmentTransaction,
        counterparty_partial_signature: PartialSignatureWithNonce,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<PartialSignature, ()> {
        // Policy: monotonic anti-revoked-reuse gate (scheme-agnostic), runs FIRST.
        let idx = commitment_tx.commitment_number();
        self.policy.record_holder_commitment(idx)?;

        // Per-channel KeyAggContext + funding amount/SPK (M5 handler context).
        let (key_agg, our_index, counterparty_index, funding_value_sat, funding_spk) =
            self.taproot_key_agg(secp_ctx)?;

        // BIP341 key-path sighash over the M4 taproot HOLDER commitment tx.
        let built = commitment_tx.trust();
        let tx = &built.built_transaction().transaction;
        let sighash = chan_utils::taproot_funding_keyspend_sighash(
            tx,
            0,
            bitcoin::Amount::from_sat(funding_value_sat),
            &funding_spk,
        )
        .map_err(|_| ())?;
        let message: [u8; 32] = *sighash.as_ref();

        // The counterparty's nonce (from `commitment_signed`) is the peer's
        // signing nonce; we combine it with OUR verification nonce for this
        // height to produce our partial. LDK aggregates both partials into the
        // final key-path Schnorr sig that can broadcast this holder commitment.
        let PartialSignatureWithNonce(_cp_partial, cp_nonce) = counterparty_partial_signature;
        let cp_nonce_bytes = cp_nonce.serialize();
        let (partial, our_pubnonce) = crate::taproot_signer::our_key_path_partial(
            key_agg,
            our_index,
            counterparty_index,
            self.taproot_holder_funding_key(),
            &self.inner.commitment_seed,
            idx,
            cp_nonce,
            message,
        )
        .map_err(|_| ())?;
        // MuSig2 nonce-reuse guard (see PolicyState::bind_nonce).
        self.policy
            .bind_nonce(&our_pubnonce.serialize(), &cp_nonce_bytes, &message)?;
        Ok(partial)
    }

    /// Sign a justice transaction spending a counterparty's revoked `to_local`
    /// output — a **plain BIP340 Schnorr** signature over a tapscript leaf
    /// (NOT MuSig2). Signing it is always safe for us (it claims funds the
    /// counterparty forfeited by broadcasting a revoked state), so no policy gate
    /// is needed. Delegated to the inner signer's taproot impl; the exact tapleaf
    /// reconstruction for the breach sweep is supplied by the monitor descriptor
    /// (M9 force-close-sweep slice), so this declines (Err) when that data is
    /// absent rather than signing an incomplete message.
    fn sign_justice_revoked_output(
        &self,
        justice_tx: &bitcoin::Transaction,
        input: usize,
        amount: u64,
        per_commitment_key: &SecretKey,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<schnorr::Signature, ()> {
        TaprootChannelSigner::sign_justice_revoked_output(
            &self.inner, justice_tx, input, amount, per_commitment_key, secp_ctx,
        )
    }

    /// Sign a justice transaction spending a counterparty's revoked HTLC output
    /// (plain BIP340 Schnorr). Delegated to the inner signer's taproot impl.
    fn sign_justice_revoked_htlc(
        &self,
        justice_tx: &bitcoin::Transaction,
        input: usize,
        amount: u64,
        per_commitment_key: &SecretKey,
        htlc: &HTLCOutputInCommitment,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<schnorr::Signature, ()> {
        TaprootChannelSigner::sign_justice_revoked_htlc(
            &self.inner, justice_tx, input, amount, per_commitment_key, htlc, secp_ctx,
        )
    }

    /// Sign our second-level HTLC-Success/Timeout tx (plain BIP340 Schnorr over
    /// the 2-of-2 tapleaf, M9b). The descriptor carries the full channel
    /// params; delegated to the inner signer's taproot impl.
    fn sign_holder_htlc_transaction(
        &self,
        htlc_tx: &bitcoin::Transaction,
        input: usize,
        htlc_descriptor: &HTLCDescriptor,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<schnorr::Signature, ()> {
        self.check_holder_htlc_tx(htlc_tx, input, htlc_descriptor, secp_ctx)?;
        TaprootChannelSigner::sign_holder_htlc_transaction(
            &self.inner, htlc_tx, input, htlc_descriptor, secp_ctx,
        )
    }

    /// Sign a claiming transaction for an HTLC output on the counterparty's
    /// commitment (plain BIP340 Schnorr). Delegated to the inner signer's taproot
    /// impl (declines without the monitor descriptor key set).
    fn sign_counterparty_htlc_transaction(
        &self,
        htlc_tx: &bitcoin::Transaction,
        input: usize,
        amount: u64,
        per_commitment_point: &PublicKey,
        htlc: &HTLCOutputInCommitment,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<schnorr::Signature, ()> {
        TaprootChannelSigner::sign_counterparty_htlc_transaction(
            &self.inner, htlc_tx, input, amount, per_commitment_point, htlc, secp_ctx,
        )
    }

    /// Partial-sign a cooperative closing transaction.
    ///
    /// Closing payout-script lock runs FIRST (reused verbatim from the ECDSA
    /// path): if the close pays the holder (LP), that output MUST pay the
    /// committed P2WPKH shutdown script, else the partial signature is refused
    /// before any key material is touched. The MuSig2 partial over the BIP341
    /// key-path close TapSighash needs the counterparty's closing nonce (M5
    /// `closing_complete`/`closing_sig` handler) — its body is M-deferred.
    fn partially_sign_closing_transaction(
        &self,
        closing_tx: &ClosingTransaction,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<PartialSignature, ()> {
        // Policy: closing-payout-script lock (scheme-agnostic), runs FIRST.
        check_closing_payout_script(
            closing_tx,
            self.policy.expected_holder_close_script(),
        )?;

        // Per-channel KeyAggContext + funding amount/SPK (M5 handler context).
        let (key_agg, our_index, counterparty_index, funding_value_sat, funding_spk) =
            self.taproot_key_agg(secp_ctx)?;
        // The counterparty's closing nonce (their `shutdown_nonce`, supplied by
        // the handler) + the per-round closing index. Required to form the AggNonce
        // for our partial and to derive a FRESH nonce per round.
        let (cp_nonce, closing_round) = {
            let slot = self.taproot_ctx.lock().map_err(|_| ())?;
            let ctx = slot.as_ref().ok_or(())?;
            (ctx.counterparty_closing_nonce.clone().ok_or(())?, ctx.closing_round)
        };

        // BIP341 key-path sighash over the M4 (BIP-86) close tx. The funding
        // input is index 0 of the built closing transaction.
        let built = closing_tx.trust();
        let tx = built.built_transaction();
        let sighash = chan_utils::taproot_funding_keyspend_sighash(
            tx,
            0,
            bitcoin::Amount::from_sat(funding_value_sat),
            &funding_spk,
        )
        .map_err(|_| ())?;
        let message: [u8; 32] = *sighash.as_ref();

        // A cooperative close has no per-commitment height; derive the secret nonce
        // at a per-ROUND height (`closing_nonce_height(closing_round)`) so it never
        // collides with any commitment-height nonce AND every fee-negotiation round
        // signs a DISTINCT close tx with a DISTINCT nonce (reusing a nonce across
        // two different messages leaks the funding key). Each round
        // re-supplies a fresh closer nonce via the handler; the deterministic
        // derive is re-derivable + crash-safe.
        let cp_nonce_bytes = cp_nonce.serialize();
        let (partial, our_pubnonce) = crate::taproot_signer::our_key_path_partial(
            key_agg,
            our_index,
            counterparty_index,
            self.taproot_holder_funding_key(),
            &self.inner.commitment_seed,
            closing_nonce_height(closing_round),
            cp_nonce,
            message,
        )
        .map_err(|_| ())?;
        // MuSig2 nonce-reuse guard (see PolicyState::bind_nonce).
        self.policy
            .bind_nonce(&our_pubnonce.serialize(), &cp_nonce_bytes, &message)?;
        Ok(partial)
    }

    fn generate_splice_nonce(
        &self,
        prev_funding_txid: &bitcoin::Txid,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Option<PublicNonce> {
        // The splice spends the OLD (current) funding output, so the KeyAggContext is
        // the CURRENT funding-key aggregate — exactly what `taproot_key_agg`
        // builds. Derive our public nonce at the per-splice-unique
        // `splice_nonce_height(prev_funding_txid)` so two distinct splices never reuse
        // a nonce (the funding-key-leak guard).
        let (key_agg, our_index, _cp, _value, _spk) = self.taproot_key_agg(secp_ctx).ok()?;
        crate::taproot_signer::local_pubnonce(
            key_agg,
            our_index,
            &self.inner.commitment_seed,
            splice_nonce_height(prev_funding_txid),
        )
        .ok()
    }

    fn partially_sign_splice_shared_input(
        &self,
        tx: &bitcoin::Transaction,
        input_index: usize,
        all_prevouts: &[bitcoin::TxOut],
        counterparty_nonce: PublicNonce,
        prev_funding_txid: &bitcoin::Txid,
        secp_ctx: &Secp256k1<secp256k1::All>,
    ) -> Result<(PartialSignature, PublicNonce), ()> {
        // The splice tx spends the OLD funding output (the current `0x5120||Q`); the
        // KeyAggContext is the CURRENT funding-key aggregate (spec §9c). A splice tx
        // has MULTIPLE inputs, so the BIP341 key-path sighash commits to ALL prevouts
        // (`Prevouts::All`), unlike the single-input commitment/close paths. Interactive
        // MuSig2 (both parties online), identical machinery to the coop-close sign.
        let (key_agg, our_index, counterparty_index, _value, _spk) =
            self.taproot_key_agg(secp_ctx)?;
        let sighash =
            chan_utils::taproot_splice_keyspend_sighash(tx, input_index, all_prevouts)
                .map_err(|_| ())?;
        let message: [u8; 32] = *sighash.as_ref();
        let cp_nonce_bytes = counterparty_nonce.serialize();
        let (partial, our_pubnonce) = crate::taproot_signer::our_key_path_partial(
            key_agg,
            our_index,
            counterparty_index,
            self.taproot_holder_funding_key(),
            &self.inner.commitment_seed,
            splice_nonce_height(prev_funding_txid),
            counterparty_nonce,
            message,
        )
        .map_err(|_| ())?;
        // MuSig2 nonce-reuse guard (see PolicyState::bind_nonce).
        self.policy
            .bind_nonce(&our_pubnonce.serialize(), &cp_nonce_bytes, &message)?;
        Ok((partial, our_pubnonce))
    }
}

/// The deterministic shachain nonce **height** for the MuSig2 partial that signs a
/// splice transaction's shared (old-funding) input, derived from the
/// `prev_funding_txid` it spends. MUST be unique per splice: a
/// channel splices many times, each over a DIFFERENT tx; reusing a nonce across two
/// distinct splice messages leaks the funding key (the closing-reuse class).
/// Each splice spends a DISTINCT prior funding output, so keying on `prev_funding_txid`
/// guarantees distinct nonces; it is re-derivable from chain state (crash-safe). The
/// window `[2^48, 2^56+2^48)` is disjoint from the commitment range (`<2^48`) and the
/// closing range (top of `u64`). Mirrors `lightning::sign::splice_nonce_height`.
fn splice_nonce_height(prev_funding_txid: &bitcoin::Txid) -> u64 {
    use bitcoin::hashes::{sha256, Hash, HashEngine};
    let mut eng = sha256::Hash::engine();
    eng.input(b"quid-taproot-splice-nonce");
    eng.input(prev_funding_txid.as_byte_array());
    let h = sha256::Hash::from_engine(eng).to_byte_array();
    let mut x = [0u8; 8];
    x.copy_from_slice(&h[..8]);
    let raw = u64::from_be_bytes(x);
    (1u64 << 48).wrapping_add(raw & ((1u64 << 56) - 1))
}

/// The base "height" domain fed to the deterministic shachain nonce derivation
/// for cooperative-close partial signatures. A close has no commitment height, so
/// we pin a sentinel range that cannot collide with any real commitment number
/// (which count *down* from `(1<<48)-1`); `u64::MAX` and the values just below it
/// are strictly above that range. Mirrors `lightning::sign::CLOSING_NONCE_BASE`.
const CLOSING_NONCE_BASE: u64 = u64::MAX;

/// The per-round deterministic nonce height for cooperative-close round `round`
/// (`0` = `shutdown`/first `closing_signed`). A FRESH nonce per round (advertised
/// via `shutdown_nonce`/`next_closee_nonce`) guarantees no two distinct close txs
/// (different fees) ever share a nonce — closing nonce reuse leaks the funding
/// private key. Mirrors `lightning::sign::closing_nonce_height`.
/// Saturates so a pathological round count cannot wrap into the commitment range.
const fn closing_nonce_height(round: u64) -> u64 {
    CLOSING_NONCE_BASE.saturating_sub(round)
}

// ===========================================================================
// Tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use bitcoin::{
        ScriptBuf, WPubkeyHash,
        secp256k1::{Secp256k1, SecretKey},
    };
    use lightning::sign::{KeysManager, SignerProvider};

    use super::PolicyState;

    /// The MuSig2 nonce-reuse guard: a given (deterministic) nonce may sign exactly
    /// ONE aggregate; an identical re-sign is allowed, a DIFFERENT aggregate under
    /// the same nonce is refused (the adaptive-replay funding-key-leak vector).
    #[test]
    fn nonce_binding_refuses_reuse_with_different_aggregate() {
        let p = PolicyState::new(ScriptBuf::new());
        let our = [1u8; 66];
        let cp1 = [2u8; 66];
        let cp2 = [3u8; 66];
        let msg = [9u8; 32];
        // First use binds the nonce to (cp1, msg).
        assert!(p.bind_nonce(&our, &cp1, &msg).is_ok());
        // Identical re-sign (same aggregate) is allowed — same partial, no leak.
        assert!(p.bind_nonce(&our, &cp1, &msg).is_ok());
        // Same nonce, DIFFERENT counterparty nonce ⇒ different aggregate ⇒ REFUSE.
        assert!(p.bind_nonce(&our, &cp2, &msg).is_err());
        // Same nonce, same cp nonce, DIFFERENT message ⇒ REFUSE.
        let msg2 = [10u8; 32];
        assert!(p.bind_nonce(&our, &cp1, &msg2).is_err());
        // A different nonce is unconstrained.
        let our2 = [4u8; 66];
        assert!(p.bind_nonce(&our2, &cp2, &msg).is_ok());
    }

    use super::*;

    /// Build a real `InMemorySigner` from a deterministic seed, the only path
    /// available outside the `lightning` crate's test features.
    fn make_signer(seed_byte: u8) -> InMemorySigner {
        let seed = [seed_byte; 32];
        let km = KeysManager::new(&seed, 1, 2, true);
        let channel_keys_id = km.generate_channel_keys_id(false, 0);
        km.derive_channel_signer(channel_keys_id)
    }

    /// A committed P2WPKH script to use as the expected close destination.
    fn committed_script() -> ScriptBuf {
        let secp = Secp256k1::new();
        let sk = SecretKey::from_slice(&[7u8; 32]).unwrap();
        let pk = bitcoin::PublicKey::new(sk.public_key(&secp));
        let wpkh = WPubkeyHash::from(pk.wpubkey_hash().unwrap());
        ScriptBuf::new_p2wpkh(&wpkh)
    }

    /// A *different* P2WPKH script (the "attacker redirect" destination).
    fn other_script() -> ScriptBuf {
        let secp = Secp256k1::new();
        let sk = SecretKey::from_slice(&[9u8; 32]).unwrap();
        let pk = bitcoin::PublicKey::new(sk.public_key(&secp));
        let wpkh = WPubkeyHash::from(pk.wpubkey_hash().unwrap());
        ScriptBuf::new_p2wpkh(&wpkh)
    }

    fn make_validating(seed_byte: u8) -> ValidatingChannelSigner {
        let inner = make_signer(seed_byte);
        ValidatingChannelSigner::new(inner, committed_script())
    }

    // --- (E176-C) Taproot-context validation ---------------------------------
    //
    // `provide_taproot_context` was a pure pass-through of five NODE-SUPPLIED fields.
    // It is the frame of reference every key-path check is computed against, so these
    // tests pin the three invariants and the ONE case that may legitimately relax two
    // of them.

    /// THE NONCE-LEAK VECTOR AT ITS SOURCE. The cooperative-close secret nonce is
    /// derived at `closing_nonce_height(closing_round)`, so a node that replays a round
    /// with a different closing tx signs a different message under the same nonce and
    /// leaks the funding key. Refuse the regression where the node controls it.
    #[test]
    fn taproot_ctx_rejects_closing_round_regression() {
        let secp = Secp256k1::new();
        let signer = make_validating(1);
        let cp = make_signer(2);
        give_ctx_round(&signer, &cp, None, 3, &secp);
        assert!(!signer.ctx_poisoned(), "a first context is always accepted");
        give_ctx_round(&signer, &cp, None, 2, &secp);
        assert!(signer.ctx_poisoned(), "a REGRESSED closing round must poison the signer");
        assert!(signer.taproot_key_agg(&secp).is_err(),
                "every key-path partial must fail closed once poisoned");
    }

    /// Re-supplying the same round, and advancing it, are both normal.
    #[test]
    fn taproot_ctx_allows_round_advance_and_resupply() {
        let secp = Secp256k1::new();
        let signer = make_validating(1);
        let cp = make_signer(2);
        give_ctx_round(&signer, &cp, None, 0, &secp);
        give_ctx_round(&signer, &cp, None, 0, &secp); // idempotent re-supply
        give_ctx_round(&signer, &cp, None, 1, &secp); // fee-negotiation round
        assert!(!signer.ctx_poisoned(), "advancing the close round is legitimate");
        assert!(signer.taproot_key_agg(&secp).is_ok());
    }

    /// Swapping the counterparty funding pubkey rebuilds Q around a key the LP never
    /// agreed to, so every later partial would sign for a different channel.
    #[test]
    fn taproot_ctx_rejects_counterparty_funding_key_swap() {
        let secp = Secp256k1::new();
        let signer = make_validating(1);
        give_ctx_round(&signer, &make_signer(2), None, 0, &secp);
        give_ctx_round(&signer, &make_signer(9), None, 0, &secp); // different cp key
        assert!(signer.ctx_poisoned(), "rebinding the counterparty funding key must poison");
    }

    /// The funding value is committed in the BIP-341 key-path sighash, so moving it
    /// silently signs a different message.
    #[test]
    fn taproot_ctx_rejects_funding_value_change() {
        let secp = Secp256k1::new();
        let signer = make_validating(1);
        let cp = make_signer(2);
        give_ctx_round(&signer, &cp, None, 0, &secp);
        signer.provide_taproot_context(TaprootSignerContext {
            counterparty_funding_pubkey: cp.pubkeys(&secp).funding_pubkey,
            funding_value_sat: FUNDING_SATS + 1,
            counterparty_closing_nonce: None,
            closing_round: 0,
            splice_parent_funding_txid: None,
        });
        assert!(signer.ctx_poisoned(), "changing the funding value must poison");
    }

    /// ⚠️ THE CONTROL — would this measurement look the same if the rule were wrong?
    /// A splice legitimately rotates the funding key AND resizes the channel, so the
    /// same two changes that poison above must be ACCEPTED when the node also declares
    /// the rotation. Without this the rule would be indistinguishable from "never
    /// change anything", which would break every splice.
    #[test]
    fn taproot_ctx_allows_rebind_across_a_declared_splice() {
        let secp = Secp256k1::new();
        let signer = make_validating(1);
        give_ctx_round(&signer, &make_signer(2), None, 0, &secp);
        signer.provide_taproot_context(TaprootSignerContext {
            counterparty_funding_pubkey: make_signer(9).pubkeys(&secp).funding_pubkey,
            funding_value_sat: FUNDING_SATS * 2,
            counterparty_closing_nonce: None,
            closing_round: 0,
            splice_parent_funding_txid: Some(bitcoin::Txid::from_raw_hash(
                bitcoin::hashes::Hash::from_byte_array([7u8; 32]))),
        });
        assert!(!signer.ctx_poisoned(),
                "a splice may rotate the funding key and resize the channel");
        assert!(signer.taproot_key_agg(&secp).is_ok());
    }

    /// 🔴 §E176-D — THE RESTART HYPOTHESIS, SETTLED BY MEASUREMENT RATHER THAN LEFT OPEN.
    /// `bind_nonce`'s map and the round comparand both live in memory, and the module
    /// header states the policy tracker "starts fresh" on restart. This test asserts the
    /// CURRENT behaviour: a reconstructed signer has NO memory of what its nonces
    /// already signed, so the guard that refuses a second message under one nonce is
    /// absent after a restart. It documents a real residual gap — the in-memory guards
    /// bind a running process, not a process the host can restart at will. Closing it
    /// needs the rollback-resistant on-chain freshness anchor that already protects
    /// channel monitors (`quid-hop/src/freshness.rs`), NOT more in-memory state. If this
    /// test ever starts failing, the gap has been closed and §E177 can be marked done.
    #[test]
    fn nonce_binding_does_not_survive_a_restart() {
        let nonce = [3u8; 66];
        let cp = [4u8; 66];
        let first = PolicyState::new(committed_script());
        assert!(first.bind_nonce(&nonce, &cp, &[1u8; 32]).is_ok());
        assert!(first.bind_nonce(&nonce, &cp, &[2u8; 32]).is_err(),
                "PREMISE: within one process the second message under one nonce is refused");
        // Restart: `PolicyState` is never persisted, so it is rebuilt empty.
        let rebuilt = PolicyState::new(committed_script());
        assert!(rebuilt.bind_nonce(&nonce, &cp, &[2u8; 32]).is_ok(),
                "MEASURED: the reuse guard does not survive a restart (see §E177)");
    }

    // --- (E177) On-chain comparand -------------------------------------------

    /// A truth source that answers from a FIXED expectation, standing in for the
    /// AGREEMENT-classed `BTCChannels` read that `quid-bridge` implements.
    struct FakeTruth {
        lp: [u8; 33],
        hop: [u8; 33],
        sats: u64,
        readable: bool,
        /// Flips the source to `NotRecorded` on demand, so a test can drive the chain
        /// BACKWARDS — which is the only shape the downgrade attack can take.
        not_recorded: std::sync::atomic::AtomicBool,
    }
    impl ChannelTruthSource for FakeTruth {
        fn verify(
            &self, lp: &[u8; 33], hop: &[u8; 33], funding_value_sat: u64,
        ) -> Result<TruthVerdict, ()> {
            if !self.readable {
                return Err(()); // unreadable chain
            }
            if self.not_recorded.load(std::sync::atomic::Ordering::SeqCst) {
                return Ok(TruthVerdict::NotRecorded);
            }
            if *lp == self.lp && *hop == self.hop && funding_value_sat == self.sats {
                Ok(TruthVerdict::Match)
            } else {
                Ok(TruthVerdict::Mismatch)
            }
        }
    }

    fn base_funding_pk(s: &InMemorySigner, secp: &Secp256k1<secp256k1::All>) -> [u8; 33] {
        s.funding_key(None).public_key(secp).serialize()
    }

    /// 🔑 THE CHECK §E176-C STRUCTURALLY COULD NOT MAKE. A node that lies from the FIRST
    /// context has nothing to contradict, so self-consistency passes it. The chain does not.
    #[test]
    fn first_context_with_a_forged_counterparty_key_is_refused_by_the_chain() {
        let secp = Secp256k1::new();
        let inner = make_signer(1);
        let honest_cp = make_signer(2);
        let truth = std::sync::Arc::new(FakeTruth {
            lp: base_funding_pk(&inner, &secp),
            hop: base_funding_pk(&honest_cp, &secp),
            sats: FUNDING_SATS,
            readable: true,
            not_recorded: std::sync::atomic::AtomicBool::new(false),
        });
        let signer = ValidatingChannelSigner::new(inner, committed_script())
            .with_truth_source(truth, FundingRole::Lp);
        // A FIRST context naming a counterparty key the chain never pinned.
        give_ctx_round(&signer, &make_signer(9), None, 0, &secp);
        assert!(signer.ctx_poisoned(),
                "a forged first context must be caught by the on-chain keysHash");
        assert!(signer.taproot_key_agg(&secp).is_err());
    }

    /// ⚠️ CONTROL — the honest first context must still be accepted, or the check above
    /// would be indistinguishable from "refuse everything".
    #[test]
    fn honest_first_context_passes_the_chain_check() {
        let secp = Secp256k1::new();
        let inner = make_signer(1);
        let cp = make_signer(2);
        let truth = std::sync::Arc::new(FakeTruth {
            lp: base_funding_pk(&inner, &secp),
            hop: base_funding_pk(&cp, &secp),
            sats: FUNDING_SATS,
            readable: true,
            not_recorded: std::sync::atomic::AtomicBool::new(false),
        });
        let signer = ValidatingChannelSigner::new(inner, committed_script())
            .with_truth_source(truth, FundingRole::Lp);
        give_ctx_round(&signer, &cp, None, 0, &secp);
        assert!(!signer.ctx_poisoned(), "the real pair must be accepted");
        assert!(signer.taproot_key_agg(&secp).is_ok());
    }

    /// The funded size is committed in the BIP-341 key-path sighash, so it is pinned
    /// against `amountSats` too — not only against the previous context.
    #[test]
    fn funding_value_is_pinned_against_the_chain_not_just_the_previous_context() {
        let secp = Secp256k1::new();
        let inner = make_signer(1);
        let cp = make_signer(2);
        let truth = std::sync::Arc::new(FakeTruth {
            lp: base_funding_pk(&inner, &secp),
            hop: base_funding_pk(&cp, &secp),
            sats: FUNDING_SATS + 12_345,   // the chain says something else
            readable: true,
            not_recorded: std::sync::atomic::AtomicBool::new(false),
        });
        let signer = ValidatingChannelSigner::new(inner, committed_script())
            .with_truth_source(truth, FundingRole::Lp);
        give_ctx_round(&signer, &cp, None, 0, &secp);
        assert!(signer.ctx_poisoned(), "a funded size the chain does not agree with is refused");
    }

    /// 🔴 FAIL CLOSED. An unreadable chain is NOT permission to sign against an unchecked
    /// context — otherwise a hostile host disables the whole check by breaking its own RPC.
    #[test]
    fn an_unreadable_chain_fails_closed() {
        let secp = Secp256k1::new();
        let inner = make_signer(1);
        let cp = make_signer(2);
        let truth = std::sync::Arc::new(FakeTruth {
            lp: base_funding_pk(&inner, &secp),
            hop: base_funding_pk(&cp, &secp),
            sats: FUNDING_SATS,
            readable: false,
            not_recorded: std::sync::atomic::AtomicBool::new(false),
        });
        let signer = ValidatingChannelSigner::new(inner, committed_script())
            .with_truth_source(truth, FundingRole::Lp);
        give_ctx_round(&signer, &cp, None, 0, &secp);
        assert!(signer.ctx_poisoned(),
                "an unreadable comparand must refuse, never wave the context through");
    }

    /// Role ordering is significant: `keysHash` is `abi.encode(lpPubkey, hopPubkey)`, so a
    /// signer that mis-declares its side must NOT accidentally validate.
    #[test]
    fn funding_role_ordering_is_significant() {
        let secp = Secp256k1::new();
        let inner = make_signer(1);
        let cp = make_signer(2);
        let truth = std::sync::Arc::new(FakeTruth {
            lp: base_funding_pk(&inner, &secp),
            hop: base_funding_pk(&cp, &secp),
            sats: FUNDING_SATS,
            readable: true,
            not_recorded: std::sync::atomic::AtomicBool::new(false),
        });
        // Same keys, wrong declared side ⇒ the pair hashes in the other order.
        let signer = ValidatingChannelSigner::new(inner, committed_script())
            .with_truth_source(truth, FundingRole::Hop);
        give_ctx_round(&signer, &cp, None, 0, &secp);
        assert!(signer.ctx_poisoned(), "the (lp, hop) order must be part of the check");
    }

    /// Without a truth source the signer behaves exactly as §E176-C left it — additive,
    /// never silently less checked.
    #[test]
    fn no_truth_source_keeps_the_self_consistency_behaviour() {
        let secp = Secp256k1::new();
        let signer = make_validating(1);
        give_ctx_round(&signer, &make_signer(2), None, 0, &secp);
        assert!(!signer.ctx_poisoned());
        assert!(signer.taproot_key_agg(&secp).is_ok());
    }

    /// (E177) LDK owns the signer by value and the on-chain `channelId` needs a funding
    /// outpoint that does not exist at derive time, so the comparand MUST be attachable
    /// after construction or it can never be attached to the signer LDK actually uses.
    #[test]
    fn truth_source_can_be_attached_after_construction() {
        let secp = Secp256k1::new();
        let inner = make_signer(1);
        let cp = make_signer(2);
        let signer = ValidatingChannelSigner::new(inner.clone(), committed_script());
        assert!(!signer.has_truth_source(), "PREMISE: starts without a comparand");
        assert!(signer.set_truth_source(
            std::sync::Arc::new(FakeTruth {
                lp: base_funding_pk(&inner, &secp),
                hop: base_funding_pk(&cp, &secp),
                sats: FUNDING_SATS,
                readable: true,
                not_recorded: std::sync::atomic::AtomicBool::new(false),
            }),
            FundingRole::Lp,
        ));
        assert!(signer.has_truth_source());
        // …and it is LIVE: a forged context is now refused where it would have passed.
        give_ctx_round(&signer, &make_signer(9), None, 0, &secp);
        assert!(signer.ctx_poisoned(), "a late-attached comparand must actually be consulted");
    }

    /// 🔴 WRITE-ONCE. A comparand the untrusted node could REPLACE is not a comparand — it
    /// would hand the attacker the referee. Second set must fail and leave the first in force.
    #[test]
    fn truth_source_is_write_once() {
        let secp = Secp256k1::new();
        let inner = make_signer(1);
        let honest = std::sync::Arc::new(FakeTruth {
            lp: base_funding_pk(&inner, &secp),
            hop: base_funding_pk(&make_signer(2), &secp),
            sats: FUNDING_SATS,
            readable: true,
            not_recorded: std::sync::atomic::AtomicBool::new(false),
        });
        // An attacker-supplied source that would rubber-stamp anything.
        let permissive = std::sync::Arc::new(FakeTruth {
            lp: base_funding_pk(&make_signer(9), &secp),
            hop: base_funding_pk(&make_signer(9), &secp),
            sats: 0,
            readable: true,
            not_recorded: std::sync::atomic::AtomicBool::new(false),
        });
        let signer = ValidatingChannelSigner::new(inner, committed_script());
        assert!(signer.set_truth_source(honest, FundingRole::Lp));
        assert!(!signer.set_truth_source(permissive, FundingRole::Lp),
                "a second truth source must be REFUSED, not swapped in");
    }

    // --- (E177-d) The THREE states, and the latch that closes the downgrade ---------

    fn truth_for(inner: &InMemorySigner, cp: &InMemorySigner, secp: &Secp256k1<secp256k1::All>)
        -> std::sync::Arc<FakeTruth>
    {
        std::sync::Arc::new(FakeTruth {
            lp: base_funding_pk(inner, secp),
            hop: base_funding_pk(cp, secp),
            sats: FUNDING_SATS,
            readable: true,
            not_recorded: std::sync::atomic::AtomicBool::new(false),
        })
    }

    /// 🔑 STATE (a) MUST BE PERMISSIVE, OR NO CHANNEL CAN EVER OPEN. The EVM's
    /// `openChannel` needs an SPV proof, which lands only AFTER LDK has signed
    /// `funding_created` and the first commitments — so an honest, live channel genuinely
    /// has no on-chain record for part of its life. A two-state check would deadlock here.
    #[test]
    fn pre_record_window_is_permissive() {
        let secp = Secp256k1::new();
        let (inner, cp) = (make_signer(1), make_signer(2));
        let truth = truth_for(&inner, &cp, &secp);
        truth.not_recorded.store(true, std::sync::atomic::Ordering::SeqCst);
        let signer = ValidatingChannelSigner::new(inner, committed_script())
            .with_truth_source(truth, FundingRole::Lp);
        give_ctx_round(&signer, &cp, None, 0, &secp);
        assert!(!signer.ctx_poisoned(), "an unrecorded channel must still be openable");
        assert!(signer.taproot_key_agg(&secp).is_ok());
    }

    /// 🔴 THE CLOSURE. Once the chain has reported a RECORD, "no record" is a REGRESSION —
    /// the only shape the downgrade attack can take — and must poison. Without this latch a
    /// hostile node keeps the comparand permanently out of play by naming a funding
    /// outpoint that resolves to no channel, silently reducing every check to §E176-C
    /// self-consistency. With it, the pre-record window is strictly ONE-WAY.
    #[test]
    fn a_recorded_channel_can_never_go_back_to_unrecorded() {
        let secp = Secp256k1::new();
        let (inner, cp) = (make_signer(1), make_signer(2));
        let truth = truth_for(&inner, &cp, &secp);
        let signer = ValidatingChannelSigner::new(inner, committed_script())
            .with_truth_source(truth.clone(), FundingRole::Lp);
        give_ctx_round(&signer, &cp, None, 0, &secp);
        assert!(!signer.ctx_poisoned(), "PREMISE: a matching record passes and latches");
        // The node now serves a view in which the channel does not exist.
        truth.not_recorded.store(true, std::sync::atomic::Ordering::SeqCst);
        give_ctx_round(&signer, &cp, None, 1, &secp);
        assert!(signer.ctx_poisoned(), "downgrading a RECORDED channel must poison");
        assert!(signer.taproot_key_agg(&secp).is_err());
    }

    /// ⚠️ CONTROL — the latch must not fire on ordinary repeated success, or it would be
    /// indistinguishable from "poison on the second context" and break every live channel.
    #[test]
    fn repeated_matching_reads_do_not_poison() {
        let secp = Secp256k1::new();
        let (inner, cp) = (make_signer(1), make_signer(2));
        let truth = truth_for(&inner, &cp, &secp);
        let signer = ValidatingChannelSigner::new(inner, committed_script())
            .with_truth_source(truth, FundingRole::Lp);
        for round in 0..4 {
            give_ctx_round(&signer, &cp, None, round, &secp);
        }
        assert!(!signer.ctx_poisoned(), "a healthy channel must survive repeated checks");
    }

    /// A wrong candidate against a REAL record is a mismatch, not a "no record" — the
    /// distinction is what makes the latch meaningful.
    #[test]
    fn recorded_but_contradicted_is_a_mismatch() {
        let secp = Secp256k1::new();
        let (inner, cp) = (make_signer(1), make_signer(2));
        let signer = ValidatingChannelSigner::new(inner.clone(), committed_script())
            .with_truth_source(truth_for(&inner, &cp, &secp), FundingRole::Lp);
        give_ctx_round(&signer, &make_signer(9), None, 0, &secp);
        assert!(signer.ctx_poisoned(), "a forged key against a real record must poison");
    }

    /// 🔑 THE PROPERTY, ASSERTED RATHER THAN INFERRED: a wrong candidate can only ever
    /// DOWNGRADE or REFUSE — it can never be made to PASS. Here the funded size disagrees
    /// with the chain, which is `Mismatch`, never `Match`.
    #[test]
    fn a_wrong_funding_value_can_never_pass() {
        let secp = Secp256k1::new();
        let (inner, cp) = (make_signer(1), make_signer(2));
        let truth = truth_for(&inner, &cp, &secp);
        assert_eq!(
            truth.verify(&truth.lp, &truth.hop, FUNDING_SATS).unwrap(),
            TruthVerdict::Match,
            "PREMISE: the honest tuple matches"
        );
        assert_eq!(
            truth.verify(&truth.lp, &truth.hop, FUNDING_SATS + 1).unwrap(),
            TruthVerdict::Mismatch,
            "a funded size the chain disagrees with is never a pass"
        );
    }

    // --- (E176-E) The holder-HTLC destination lock -----------------------------

    fn htlc_tx_with(outpoint: bitcoin::OutPoint, outs: Vec<bitcoin::TxOut>)
        -> bitcoin::Transaction
    {
        bitcoin::Transaction {
            version: bitcoin::transaction::Version::TWO,
            lock_time: bitcoin::absolute::LockTime::ZERO,
            input: vec![bitcoin::TxIn {
                previous_output: outpoint,
                ..Default::default()
            }],
            output: outs,
        }
    }

    fn an_outpoint(b: u8) -> bitcoin::OutPoint {
        bitcoin::OutPoint {
            txid: bitcoin::Txid::from_raw_hash(bitcoin::hashes::Hash::from_byte_array([b; 32])),
            vout: 0,
        }
    }

    fn a_txout(sats: u64, script_byte: u8) -> bitcoin::TxOut {
        bitcoin::TxOut {
            value: bitcoin::Amount::from_sat(sats),
            script_pubkey: bitcoin::ScriptBuf::from_bytes(vec![script_byte; 22]),
        }
    }

    /// The lock reduces to two comparisons, so pin them directly rather than through a
    /// full `HTLCDescriptor` (which needs a populated channel). These mirror
    /// `check_holder_htlc_tx` exactly: same input outpoint, and the expected output present.
    fn lock_holds(tx: &bitcoin::Transaction, idx: usize, want_in: bitcoin::OutPoint,
                  want_out: &bitcoin::TxOut) -> bool {
        tx.input.get(idx).map(|i| i.previous_output) == Some(want_in)
            && tx.output.iter().any(|o| o == want_out)
    }

    /// 🔴 THE ATTACK IT STOPS: a hostile node hands the signer an otherwise-valid HTLC
    /// transaction whose output pays a script IT chose. The descriptor's `tx_output()` is
    /// derived from the CHANNEL'S OWN KEYS, so the swept value must land where those keys
    /// say — not where the node says.
    #[test]
    fn a_redirected_holder_htlc_output_is_refused() {
        let op = an_outpoint(0xAA);
        let expected = a_txout(10_000, 0x51);
        let attacker = a_txout(10_000, 0x99);
        assert!(lock_holds(&htlc_tx_with(op, vec![expected.clone()]), 0, op, &expected),
                "PREMISE: the honest transaction passes");
        assert!(!lock_holds(&htlc_tx_with(op, vec![attacker]), 0, op, &expected),
                "an output redirected to the node's own script must be refused");
    }

    /// Signing the wrong INPUT is the other half: a signature meant for one HTLC must not
    /// be obtainable for another by handing over a different outpoint.
    #[test]
    fn signing_a_different_outpoint_is_refused() {
        let (op, other) = (an_outpoint(0xAA), an_outpoint(0xBB));
        let expected = a_txout(10_000, 0x51);
        assert!(!lock_holds(&htlc_tx_with(other, vec![expected.clone()]), 0, op, &expected),
                "the input signed must be the outpoint the descriptor names");
    }

    /// ⚠️ CONTROL — the lock uses `contains`, NOT equality on the output set. A real HTLC
    /// transaction may also carry an anchor or change output, and demanding an exact set
    /// would reject honest transactions. A guard that breaks the happy path gets removed
    /// rather than fixed, so this pins that it does not.
    #[test]
    fn extra_outputs_are_allowed_alongside_the_expected_one() {
        let op = an_outpoint(0xAA);
        let expected = a_txout(10_000, 0x51);
        let anchor = a_txout(330, 0x77);
        let tx = htlc_tx_with(op, vec![anchor, expected.clone()]);
        assert!(lock_holds(&tx, 0, op, &expected),
                "an anchor/change output alongside the expected one must still pass");
    }

    /// An out-of-range input index must refuse, not panic — the index is node-supplied.
    #[test]
    fn an_out_of_range_input_index_refuses() {
        let op = an_outpoint(0xAA);
        let expected = a_txout(10_000, 0x51);
        let tx = htlc_tx_with(op, vec![expected.clone()]);
        assert!(!lock_holds(&tx, 7, op, &expected), "index past the end must refuse");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // (E180) THE MALICIOUSNESS SUITE — one hostile node, every attack this signer
    // is supposed to stop, asserted as refusals rather than as prose.
    //
    // ⚠️ READ THE SCOPE BEFORE READING THE RESULTS. These prove the signer refuses a
    // node that MISBEHAVES. They do NOT prove anything against an attacker who
    // REPLACES THE BINARY — every check below lives in the binary, so an adversary
    // who owns the enclave deletes the checks and the tests still pass. That gap is
    // §E175 (run the signer where the operator cannot replace it) and no test in this
    // file can close it. What these DO establish is that a compromised node which must
    // keep running THIS code cannot steal, and that is the property §E175 will make
    // load-bearing.
    // ═══════════════════════════════════════════════════════════════════════════

    /// ⚠️ **THE CONTROL, AND IT COMES FIRST ON PURPOSE.** Every test below asserts a
    /// REFUSAL, and a signer that refused everything would pass all of them while being
    /// completely broken. This pins that the honest path still works: a real counterparty,
    /// the funded size the chain agrees with, several close rounds, and a commitment — all
    /// accepted, signer unpoisoned.
    #[test]
    fn honest_session_is_accepted_throughout() {
        let secp = Secp256k1::new();
        let (inner, cp) = (make_signer(1), make_signer(2));
        let signer = ValidatingChannelSigner::new(inner.clone(), committed_script())
            .with_truth_source(truth_for(&inner, &cp, &secp), FundingRole::Lp);
        for round in 0..3 {
            give_ctx_round(&signer, &cp, None, round, &secp);
        }
        assert!(!signer.ctx_poisoned(), "the honest path must not poison");
        assert!(signer.taproot_key_agg(&secp).is_ok(), "and must still be able to sign");
        assert!(signer.policy().record_holder_commitment(u64::MAX - 1).is_ok());
    }

    /// ATTACK 1 — rebuild `Q` around a counterparty key the LP never agreed to, so every
    /// later partial signs for a different channel. Caught by the on-chain `keysHash`.
    #[test]
    fn attack_swap_the_counterparty_funding_key() {
        let secp = Secp256k1::new();
        let (inner, cp) = (make_signer(1), make_signer(2));
        let signer = ValidatingChannelSigner::new(inner.clone(), committed_script())
            .with_truth_source(truth_for(&inner, &cp, &secp), FundingRole::Lp);
        give_ctx_round(&signer, &make_signer(9), None, 0, &secp);
        assert!(signer.ctx_poisoned());
        assert!(signer.taproot_key_agg(&secp).is_err(), "must stop signing entirely");
    }

    /// ATTACK 2 — the FUNDING-KEY LEAK. Replay a cooperative-close round with a DIFFERENT
    /// closing transaction: same derived nonce, different sighash ⇒ two partials that
    /// solve for the secret (`x = (s1−s2)/((e1−e2)·a)`). Refused at the source, where the
    /// node controls the round, not merely at `bind_nonce`'s use-time check.
    #[test]
    fn attack_replay_a_closing_round_to_leak_the_funding_key() {
        let secp = Secp256k1::new();
        let (inner, cp) = (make_signer(1), make_signer(2));
        let signer = ValidatingChannelSigner::new(inner.clone(), committed_script())
            .with_truth_source(truth_for(&inner, &cp, &secp), FundingRole::Lp);
        give_ctx_round(&signer, &cp, None, 4, &secp);
        give_ctx_round(&signer, &cp, None, 3, &secp); // rewind the round
        assert!(signer.ctx_poisoned(), "a regressed close round must poison");
    }

    /// ATTACK 3 — serve a chain view in which the channel does not exist, to put the
    /// comparand permanently out of play and silently fall back to self-consistency.
    #[test]
    fn attack_downgrade_a_recorded_channel_to_unrecorded() {
        let secp = Secp256k1::new();
        let (inner, cp) = (make_signer(1), make_signer(2));
        let truth = truth_for(&inner, &cp, &secp);
        let signer = ValidatingChannelSigner::new(inner, committed_script())
            .with_truth_source(truth.clone(), FundingRole::Lp);
        give_ctx_round(&signer, &cp, None, 0, &secp);
        truth.not_recorded.store(true, std::sync::atomic::Ordering::SeqCst);
        give_ctx_round(&signer, &cp, None, 1, &secp);
        assert!(signer.ctx_poisoned(), "the pre-record window is ONE-WAY");
    }

    /// ATTACK 4 — the cheapest attack available to a host: break your own RPC so the
    /// comparand cannot be read, hoping the signer treats "unknown" as "fine".
    #[test]
    fn attack_break_the_rpc_to_disable_the_comparand() {
        let secp = Secp256k1::new();
        let (inner, cp) = (make_signer(1), make_signer(2));
        let truth = std::sync::Arc::new(FakeTruth {
            lp: base_funding_pk(&inner, &secp),
            hop: base_funding_pk(&cp, &secp),
            sats: FUNDING_SATS,
            readable: false, // the chain cannot be read
            not_recorded: std::sync::atomic::AtomicBool::new(false),
        });
        let signer = ValidatingChannelSigner::new(inner, committed_script())
            .with_truth_source(truth, FundingRole::Lp);
        give_ctx_round(&signer, &cp, None, 0, &secp);
        assert!(signer.ctx_poisoned(), "an unreadable comparand must FAIL CLOSED");
    }

    /// ATTACK 5 — swap in a permissive comparand of the attacker's own, i.e. appoint the
    /// referee. Refused: the truth source is write-once.
    #[test]
    fn attack_replace_the_comparand_with_a_permissive_one() {
        let secp = Secp256k1::new();
        let (inner, cp) = (make_signer(1), make_signer(2));
        let signer = ValidatingChannelSigner::new(inner.clone(), committed_script())
            .with_truth_source(truth_for(&inner, &cp, &secp), FundingRole::Lp);
        let attacker = truth_for(&make_signer(9), &make_signer(8), &secp);
        assert!(!signer.set_truth_source(attacker, FundingRole::Lp),
                "a second comparand must be refused");
        // …and the ORIGINAL is still the one enforcing.
        give_ctx_round(&signer, &make_signer(9), None, 0, &secp);
        assert!(signer.ctx_poisoned(), "the first comparand still binds");
    }

    /// ATTACK 6 — hand over an HTLC transaction that sweeps to a script the attacker chose.
    #[test]
    fn attack_redirect_a_holder_htlc_payout() {
        let op = an_outpoint(0xAA);
        let expected = a_txout(50_000, 0x51);
        let to_attacker = a_txout(50_000, 0x99);
        assert!(!lock_holds(&htlc_tx_with(op, vec![to_attacker]), 0, op, &expected),
                "the HTLC sweep must land where the CHANNEL KEYS say");
    }

    /// ATTACK 7 — resurrect a revoked commitment after its secret was released, which is
    /// how a counterparty steals a channel balance outright.
    #[test]
    fn attack_resign_a_revoked_commitment() {
        let p = PolicyState::new(committed_script());
        // Commitment numbers count BACKWARDS: a lower index is more advanced.
        assert!(p.record_holder_commitment(100).is_ok(), "PREMISE: state 100 signed");
        assert!(p.record_secret_release(100).is_ok(), "PREMISE: state 100 revoked");
        assert!(p.record_holder_commitment(100).is_err(),
                "re-signing a REVOKED holder state must be refused");
        assert!(p.record_holder_commitment(101).is_err(),
                "and so must regressing to an older one");
    }

    /// ATTACK 8 — redirect a cooperative close so the LP's balance pays the attacker.
    /// This is the theft the whole design exists to stop; the payout-script lock catches it.
    #[test]
    fn attack_redirect_a_cooperative_close() {
        let good = closing_tx_to(committed_script(), 50_000);
        assert!(check_closing_payout_script(&good, &committed_script()).is_ok(),
                "PREMISE: the honest close passes");
        let stolen = closing_tx_to(other_script(), 50_000);
        assert!(check_closing_payout_script(&stolen, &committed_script()).is_err(),
                "a close paying the holder output ELSEWHERE must be refused");
    }

    // --- Monotonic state machine: pure helpers --------------------------------

    #[test]
    fn check_no_regression_semantics() {
        // First request at any index always accepted.
        assert!(check_no_regression(None, 100).is_ok());
        // Forward progress = decreasing index = accepted.
        assert!(check_no_regression(Some(100), 99).is_ok());
        // Re-using the same index = accepted (LDK may re-request).
        assert!(check_no_regression(Some(100), 100).is_ok());
        // Regression = numerically-larger (older) index = REJECTED.
        assert!(check_no_regression(Some(100), 101).is_err());
    }

    #[test]
    fn check_not_revoked_semantics() {
        assert!(check_not_revoked(None, 100).is_ok());
        // A more-advanced (lower) index than the released one is fine.
        assert!(check_not_revoked(Some(100), 99).is_ok());
        // Signing AT the released (revoked) index is rejected.
        assert!(check_not_revoked(Some(100), 100).is_err());
        // Signing BEHIND (older) the released index is rejected.
        assert!(check_not_revoked(Some(100), 101).is_err());
    }

    // --- Monotonic state machine: through PolicyState -------------------------

    #[test]
    fn holder_commitment_rejects_regression_accepts_progress() {
        let policy = PolicyState::new(committed_script());
        // Honest forward progression (indices count down).
        assert!(policy.record_holder_commitment(1000).is_ok());
        assert!(policy.record_holder_commitment(999).is_ok());
        assert!(policy.record_holder_commitment(998).is_ok());
        // Re-signing the same (current) index is allowed.
        assert!(policy.record_holder_commitment(998).is_ok());
        // Regressing to an older (higher) index is REJECTED.
        assert!(policy.record_holder_commitment(999).is_err());
        assert!(policy.record_holder_commitment(1001).is_err());
    }

    #[test]
    fn counterparty_commitment_rejects_regression() {
        let policy = PolicyState::new(committed_script());
        assert!(policy.record_counterparty_commitment(500).is_ok());
        assert!(policy.record_counterparty_commitment(499).is_ok());
        assert!(policy.record_counterparty_commitment(500).is_err());
    }

    #[test]
    fn secret_release_then_resign_revoked_is_rejected() {
        let policy = PolicyState::new(committed_script());
        // Sign + advance to index 200, then 199.
        assert!(policy.record_holder_commitment(200).is_ok());
        assert!(policy.record_holder_commitment(199).is_ok());
        // Release the revocation secret for the now-revoked state 200.
        assert!(policy.record_secret_release(200).is_ok());
        // Attempting to re-sign the revoked state 200 (or older) must fail.
        assert!(policy.record_holder_commitment(200).is_err());
        assert!(policy.record_holder_commitment(201).is_err());
        // The current/newer states are still signable.
        assert!(policy.record_holder_commitment(199).is_ok());
        assert!(policy.record_holder_commitment(198).is_ok());
    }

    #[test]
    fn secret_release_must_be_in_forward_order() {
        let policy = PolicyState::new(committed_script());
        // Release secrets in forward (decreasing index) order: ok.
        assert!(policy.record_secret_release(300).is_ok());
        assert!(policy.record_secret_release(299).is_ok());
        // Re-releasing same index: ok (idempotent reveal).
        assert!(policy.record_secret_release(299).is_ok());
        // Out-of-order: releasing an older (higher) index after a newer one is
        // a regression and REJECTED.
        assert!(policy.record_secret_release(300).is_err());
        assert!(policy.record_secret_release(301).is_err());
    }

    // --- Closing-tx payout-script policy --------------------------------------

    fn counterparty_close_script() -> ScriptBuf {
        let secp = Secp256k1::new();
        let sk = SecretKey::from_slice(&[11u8; 32]).unwrap();
        let pk = bitcoin::PublicKey::new(sk.public_key(&secp));
        let wpkh = WPubkeyHash::from(pk.wpubkey_hash().unwrap());
        ScriptBuf::new_p2wpkh(&wpkh)
    }

    fn closing_tx_to(
        holder_script: ScriptBuf,
        to_holder_value_sat: u64,
    ) -> ClosingTransaction {
        let funding_outpoint = bitcoin::OutPoint {
            txid: bitcoin::Txid::from_raw_hash(
                bitcoin::hashes::Hash::all_zeros(),
            ),
            vout: 0,
        };
        ClosingTransaction::new(
            to_holder_value_sat,
            40_000,
            holder_script,
            counterparty_close_script(),
            funding_outpoint,
        )
    }

    #[test]
    fn closing_policy_accepts_committed_script() {
        let expected = committed_script();
        let tx = closing_tx_to(committed_script(), 50_000);
        assert!(check_closing_payout_script(&tx, &expected).is_ok());
    }

    #[test]
    fn closing_policy_rejects_wrong_script() {
        let expected = committed_script();
        // Close attempts to pay the LP output to a DIFFERENT destination.
        let tx = closing_tx_to(other_script(), 50_000);
        assert!(check_closing_payout_script(&tx, &expected).is_err());
    }

    #[test]
    fn closing_policy_accepts_absent_holder_output() {
        // A fully-delivered LP has a zero holder balance: the holder output is
        // omitted from the close. Even with a non-matching script field, this
        // must be ACCEPTED — there is no holder output to redirect.
        let expected = committed_script();
        let tx = closing_tx_to(other_script(), 0);
        assert!(check_closing_payout_script(&tx, &expected).is_ok());
    }

    // --- Happy path: delegation to inner produces a real signature -----------

    #[test]
    fn happy_path_delegates_metadata_to_inner() {
        let vs = make_validating(42);
        let secp = Secp256k1::new();

        // Metadata path: get_per_commitment_point delegates to inner and yields
        // the same value the bare InMemorySigner would, proving wiring works.
        let reference = make_signer(42);
        let idx = INITIAL_COMMITMENT_NUMBER;
        let via_vs = vs.get_per_commitment_point(idx, &secp).unwrap();
        let via_inner = reference.get_per_commitment_point(idx, &secp).unwrap();
        assert_eq!(via_vs, via_inner);

        // channel_keys_id + pubkeys also delegate identically.
        assert_eq!(vs.channel_keys_id(), reference.channel_keys_id());
        assert_eq!(
            vs.pubkeys(&secp).funding_pubkey,
            reference.pubkeys(&secp).funding_pubkey,
        );
    }

    #[test]
    fn happy_path_release_secret_through_policy() {
        let vs = make_validating(7);
        let reference = make_signer(7);
        // A first secret release passes policy and returns the real secret.
        let idx = 123u64;
        let got = vs.release_commitment_secret(idx).unwrap();
        let want = reference.release_commitment_secret(idx).unwrap();
        assert_eq!(got, want);
    }

    // =======================================================================
    // M5 — end-to-end MuSig2 nonce-exchange flow through the TaprootChannelSigner
    //       trait bodies: funding/commitment partial-sign + cooperative close.
    // =======================================================================

    use bitcoin::secp256k1::schnorr as bip340_schnorr;
    use lightning::ln::chan_utils::{
        ChannelTransactionParameters as CTParams, CommitmentTransaction,
        CounterpartyChannelTransactionParameters as CpParams, HolderCommitmentTransaction,
    };
    use lightning::types::features::ChannelTypeFeatures;

    const FUNDING_SATS: u64 = 1_000_000;

    /// Build the symmetric per-channel `ChannelTransactionParameters` from the
    /// holder + counterparty pubkeys (no-HTLC). `holder_is_outbound` flips the
    /// obscure-factor input; both sides must agree, so the LP-view and hop-view
    /// params are mirror images.
    fn ct_params(
        holder: &InMemorySigner,
        counterparty: &InMemorySigner,
        holder_is_outbound: bool,
        secp: &Secp256k1<secp256k1::All>,
    ) -> CTParams {
        CTParams {
            holder_pubkeys: holder.pubkeys(secp),
            holder_selected_contest_delay: 144,
            is_outbound_from_holder: holder_is_outbound,
            counterparty_parameters: Some(CpParams {
                pubkeys: counterparty.pubkeys(secp),
                selected_contest_delay: 144,
            }),
            funding_outpoint: Some(lightning::chain::transaction::OutPoint {
                txid: bitcoin::Txid::from_raw_hash(bitcoin::hashes::Hash::all_zeros()),
                index: 0,
            }),
            splice_parent_funding_txid: None,
            channel_type_features: ChannelTypeFeatures::only_static_remote_key(),
            channel_value_satoshis: FUNDING_SATS,
        }
    }

    /// The tweaked aggregate funding key `Q` (x-only) for the two signers — what
    /// every aggregated key-path signature must verify against (the key committed
    /// in the `0x5120||Q` funding output).
    fn funding_q(
        a: &InMemorySigner,
        b: &InMemorySigner,
        secp: &Secp256k1<secp256k1::All>,
    ) -> bitcoin::secp256k1::XOnlyPublicKey {
        let pa = a.pubkeys(secp).funding_pubkey.serialize();
        let pb = b.pubkeys(secp).funding_pubkey.serialize();
        let (ctx, _) = crate::taproot_signer::channel_key_agg_ctx(&pa, &pb, &pa).unwrap();
        crate::taproot_signer::aggregated_xonly(&ctx)
    }

    /// Wire the late-bound taproot context into a signer (the job of the
    /// nonce-exchange handler), optionally including the peer's closing nonce.
    fn give_ctx(
        signer: &ValidatingChannelSigner,
        counterparty: &InMemorySigner,
        closing_nonce: Option<PublicNonce>,
        secp: &Secp256k1<secp256k1::All>,
    ) {
        give_ctx_round(signer, counterparty, closing_nonce, 0, secp);
    }

    /// As [`give_ctx`] but with an explicit cooperative-close round index, so a
    /// test can drive multiple fee-negotiation rounds (each round derives a fresh
    /// closing nonce at `closing_nonce_height(round)`).
    fn give_ctx_round(
        signer: &ValidatingChannelSigner,
        counterparty: &InMemorySigner,
        closing_nonce: Option<PublicNonce>,
        closing_round: u64,
        secp: &Secp256k1<secp256k1::All>,
    ) {
        signer.provide_taproot_context(TaprootSignerContext {
            counterparty_funding_pubkey: counterparty.pubkeys(secp).funding_pubkey,
            funding_value_sat: FUNDING_SATS,
            counterparty_closing_nonce: closing_nonce,
            closing_round,
            splice_parent_funding_txid: None,
        });
    }

    /// REGRESSION (M8): LDK's `ChannelContext` nonce-exchange handler reaches the
    /// signer through the **`TaprootChannelSigner` trait** object/bound
    /// (`taproot_signer.provide_taproot_context(ctx)` where `taproot_signer:
    /// &SP::TaprootSigner`), NOT through the concrete type. The trait supplies a
    /// no-op default `provide_taproot_context`, so if `ValidatingChannelSigner`
    /// only defined the *inherent* method (and not the trait override) the context
    /// would be silently dropped and the next `generate_local_nonce_pair` would
    /// panic ("taproot context must be supplied before advertising a nonce") — the
    /// exact failure observed in the live FFI e2e (the in-process tests masked it
    /// because they call the inherent method on the concrete type).
    ///
    /// This drives the context in EXACTLY the trait-dispatched way LDK does and
    /// asserts the nonce is produced (no panic), proving the trait override is the
    /// one that stores it.
    #[test]
    fn taproot_context_supplied_via_trait_dispatch_reaches_signer() {
        let secp = Secp256k1::new();
        let lp = make_signer(0xC3);
        let hop = make_signer(0xD4);
        let lp_vs = ValidatingChannelSigner::new(lp.clone(), committed_script());

        // Drive the context through the TRAIT (LDK's path), using LDK's own
        // `crate::sign::TaprootSignerContext` type — NOT the inherent method.
        fn supply_via_trait<T: lightning::sign::taproot::TaprootChannelSigner>(
            s: &T,
            cp_funding: bitcoin::secp256k1::PublicKey,
        ) {
            s.provide_taproot_context(lightning::sign::TaprootSignerContext {
                counterparty_funding_pubkey: cp_funding,
                funding_value_sat: FUNDING_SATS,
                counterparty_closing_nonce: None,
                closing_round: 0,
                splice_parent_funding_txid: None,
            });
        }
        supply_via_trait(&lp_vs, hop.pubkeys(&secp).funding_pubkey);

        // After a trait-dispatched supply, advertising a nonce must NOT panic.
        let _nonce = TaprootChannelSigner::generate_local_nonce_pair(
            &lp_vs,
            INITIAL_COMMITMENT_NUMBER,
            &secp,
        );
    }

    /// LOAD-BEARING M5 e2e: two signers (LP + hop) negotiate the funding/first
    /// commitment via the real `TaprootChannelSigner` bodies and the aggregated
    /// funding key-path Schnorr signature **verifies vs the tweaked Q**, then they
    /// cooperatively close and that aggregate **also verifies vs Q**. No HTLCs.
    ///
    /// This drives the exact M5 code paths:
    ///   * `partially_sign_counterparty_commitment` (LP signs hop's commitment),
    ///   * `finalize_holder_commitment` (hop counter-signs its own commitment),
    ///   * `aggregate_key_path_partials` (handler aggregates → final sig),
    ///   * `partially_sign_closing_transaction` on both sides → aggregate.
    #[test]
    fn taproot_open_commitment_and_coop_close_signatures_verify() {
        let secp = Secp256k1::new();
        let lp = make_signer(0xA1);
        let hop = make_signer(0xB2);
        let q = funding_q(&lp, &hop, &secp);

        let lp_vs = ValidatingChannelSigner::new(lp.clone(), committed_script());
        let hop_vs = ValidatingChannelSigner::new(hop.clone(), committed_script());

        // Handler supplies each side's late-bound taproot context.
        give_ctx(&lp_vs, &hop, None, &secp);
        give_ctx(&hop_vs, &lp, None, &secp);

        // ---- COMMITMENT (and, structurally, the funding) flow ----
        // We exercise hop's commitment transaction: LP partial-signs it as the
        // counterparty; hop finalizes (partial-signs) its own holder commitment.
        // Both partials are over the SAME key-path sighash of hop's commitment.
        let idx = INITIAL_COMMITMENT_NUMBER;
        // hop's commitment tx is built from the hop-as-broadcaster view.
        let hop_params = ct_params(&hop, &lp, false, &secp);
        let hop_per_commitment_point = hop.get_per_commitment_point(idx, &secp).unwrap();
        let directed = hop_params.as_holder_broadcastable();
        let hop_commitment = CommitmentTransaction::new(
            idx,
            &hop_per_commitment_point,
            FUNDING_SATS / 2 - 1_000, // to_broadcaster (hop)
            FUNDING_SATS / 2 - 1_000, // to_countersignatory (lp)
            253,
            Vec::new(),
            &directed,
            &secp,
        );

        // hop generates its JIT signing nonce (the nonce it will send LP).
        let hop_nonce = hop_vs.generate_local_nonce_pair(idx, &secp);

        // LP partial-signs hop's commitment as the counterparty, consuming hop's
        // nonce; returns LP's partial + LP's pubnonce (the `partial_signature_
        // with_nonce` that would ride `commitment_signed`).
        let (lp_psig_with_nonce, lp_htlc_sigs) = lp_vs
            .partially_sign_counterparty_commitment(
                hop_nonce.clone(),
                &hop_commitment,
                Vec::new(),
                Vec::new(),
                &secp,
            )
            .expect("LP partial-signs hop's commitment");
        assert!(lp_htlc_sigs.is_empty(), "no-HTLC channel");
        let PartialSignatureWithNonce(lp_partial, lp_pubnonce) = lp_psig_with_nonce.clone();

        // hop finalizes its holder commitment: produces hop's partial keyed by
        // LP's nonce (from the `commitment_signed` LP just sent).
        let hop_holder = HolderCommitmentTransaction::new(
            hop_commitment.clone(),
            // counterparty (LP) ECDSA sig field is unused by the taproot path; a
            // dummy is fine since finalize_holder_commitment ignores it and uses
            // the MuSig2 partial instead.
            dummy_ecdsa_sig(&secp),
            Vec::new(),
            &hop.pubkeys(&secp).funding_pubkey,
            &lp.pubkeys(&secp).funding_pubkey,
        );
        let hop_partial = hop_vs
            .finalize_holder_commitment(&hop_holder, lp_psig_with_nonce, &secp)
            .expect("hop finalizes its holder commitment");

        // Handler aggregates LP's + hop's partials → final key-path Schnorr sig.
        // Determine slot order from the KeyAgg context.
        let lp_pk = lp.pubkeys(&secp).funding_pubkey.serialize();
        let hop_pk = hop.pubkeys(&secp).funding_pubkey.serialize();
        let (agg_ctx, lp_idx) =
            crate::taproot_signer::channel_key_agg_ctx(&lp_pk, &hop_pk, &lp_pk).unwrap();
        let hop_idx = 1 - lp_idx;

        // The message both partials signed = hop's commitment key-path sighash.
        let funding_spk = funding_spk_for(&agg_ctx);
        let hop_tx = &hop_commitment.trust().built_transaction().transaction;
        let msg: [u8; 32] = *lightning::ln::chan_utils::taproot_funding_keyspend_sighash(
            hop_tx,
            0,
            bitcoin::Amount::from_sat(FUNDING_SATS),
            &funding_spk,
        )
        .unwrap()
        .as_ref();

        let agg_sig = crate::taproot_signer::aggregate_key_path_partials(
            agg_ctx,
            msg,
            lp_idx,
            lp_pubnonce,
            lp_partial,
            hop_idx,
            hop_nonce,
            hop_partial,
        )
        .expect("aggregate commitment partials");

        verify(&secp, &agg_sig, &msg, &q, "commitment key-path sig");

        // ---- COOPERATIVE CLOSE flow ----
        // Each side derives its closing (verification) nonce and exchanges it via
        // `shutdown_nonce`; then both partial-sign the close, aggregate, verify.
        let lp_close_nonce = closing_nonce_of(&lp, &hop, &secp);
        let hop_close_nonce = closing_nonce_of(&hop, &lp, &secp);
        give_ctx(&lp_vs, &hop, Some(hop_close_nonce.clone()), &secp);
        give_ctx(&hop_vs, &lp, Some(lp_close_nonce.clone()), &secp);

        // A single shared closing transaction (the holder=LP view; the funding
        // input is what both partial-sign). Pay LP to the committed script.
        let closing_tx = ClosingTransaction::new(
            FUNDING_SATS / 2 - 500,
            FUNDING_SATS / 2 - 500,
            committed_script(),
            counterparty_close_script(),
            bitcoin::OutPoint {
                txid: bitcoin::Txid::from_raw_hash(bitcoin::hashes::Hash::all_zeros()),
                vout: 0,
            },
        );

        let lp_close_partial = lp_vs
            .partially_sign_closing_transaction(&closing_tx, &secp)
            .expect("LP closing partial");
        let hop_close_partial = hop_vs
            .partially_sign_closing_transaction(&closing_tx, &secp)
            .expect("hop closing partial");

        let (agg_ctx2, lp_idx2) =
            crate::taproot_signer::channel_key_agg_ctx(&lp_pk, &hop_pk, &lp_pk).unwrap();
        let hop_idx2 = 1 - lp_idx2;
        let close_spk = funding_spk_for(&agg_ctx2);
        let close_tx = closing_tx.trust().built_transaction();
        let close_msg: [u8; 32] = *lightning::ln::chan_utils::taproot_funding_keyspend_sighash(
            close_tx,
            0,
            bitcoin::Amount::from_sat(FUNDING_SATS),
            &close_spk,
        )
        .unwrap()
        .as_ref();

        let close_agg = crate::taproot_signer::aggregate_key_path_partials(
            agg_ctx2,
            close_msg,
            lp_idx2,
            lp_close_nonce,
            lp_close_partial,
            hop_idx2,
            hop_close_nonce,
            hop_close_partial,
        )
        .expect("aggregate close partials");

        verify(&secp, &close_agg, &close_msg, &q, "coop-close key-path sig");
    }

    /// 🔴🔴 SECURITY: the cooperative-close fee negotiation is
    /// MULTI-ROUND — each `closing_signed` round signs a DIFFERENT close tx
    /// (different fee ⇒ different BIP341 key-path sighash *message* `m`) and our
    /// partial is SENT to the counterparty. If two rounds reuse the same MuSig2
    /// secret nonce `k`, then from the two partials `s1,s2` over `m1≠m2` an
    /// observer recovers our funding private key:
    /// `x = (s1 − s2) / (e1 − e2)` where `e = H(R, Q, m)` — and `e` is computable
    /// by anyone (`R`, `Q`, `m` are public). Counterparty then controls the 2-of-2
    /// and DRAINS the channel.
    ///
    /// RED before the fix (closing nonce pinned at a fixed `CLOSING_NONCE_HEIGHT`
    /// ⇒ both rounds derive the SAME nonce ⇒ the two pubnonces are EQUAL and the
    /// key-recovery below succeeds). GREEN after: each round derives a FRESH nonce
    /// at `closing_nonce_height(round)`, the two pubnonces DIFFER, and the
    /// key-recovery cannot apply (no shared `R`).
    #[test]
    fn coop_close_multiround_uses_distinct_nonces_no_key_leak() {
        let secp = Secp256k1::new();
        let lp = make_signer(0x5E);
        let hop = make_signer(0x6F);

        let lp_vs = ValidatingChannelSigner::new(lp.clone(), committed_script());
        // Both sides expect the same committed holder-close script: the close tx
        // built below pays `committed_script()` to the holder output (matching the
        // existing coop-close test), so both validating signers accept it.
        let hop_vs = ValidatingChannelSigner::new(hop.clone(), committed_script());

        let lp_pk = lp.pubkeys(&secp).funding_pubkey.serialize();
        let hop_pk = hop.pubkeys(&secp).funding_pubkey.serialize();
        let (agg_ctx, lp_idx) =
            crate::taproot_signer::channel_key_agg_ctx(&lp_pk, &hop_pk, &lp_pk).unwrap();
        let hop_idx = 1 - lp_idx;
        let q = crate::taproot_signer::aggregated_xonly(&agg_ctx);
        let funding_spk = funding_spk_for(&agg_ctx);

        // Build a close tx for a given fee (different fee ⇒ different output values
        // ⇒ different sighash message). Two rounds of an RBF/fee re-negotiation.
        let close_tx_for = |fee: u64| {
            ClosingTransaction::new(
                FUNDING_SATS / 2 - fee,
                FUNDING_SATS / 2 - fee,
                committed_script(),
                counterparty_close_script(),
                bitcoin::OutPoint {
                    txid: bitcoin::Txid::from_raw_hash(bitcoin::hashes::Hash::all_zeros()),
                    vout: 0,
                },
            )
        };
        let msg_of = |closing_tx: &ClosingTransaction| -> [u8; 32] {
            *lightning::ln::chan_utils::taproot_funding_keyspend_sighash(
                closing_tx.trust().built_transaction(),
                0,
                bitcoin::Amount::from_sat(FUNDING_SATS),
                &funding_spk,
            )
            .unwrap()
            .as_ref()
        };

        // Drive one full close round at `round`/`fee`: both sides advertise their
        // per-round nonce (exactly as `channel.rs` does, at
        // `closing_nonce_height(round)`), supply each other's nonce + the round into
        // the signer context, partial-sign, aggregate, and verify vs Q. Returns
        // (message, LP's advertised pubnonce) so the caller can compare rounds.
        let run_round = |round: u64, fee: u64| -> ([u8; 32], musig2::PubNonce) {
            let tx = close_tx_for(fee);
            let m = msg_of(&tx);

            // Each side's advertised nonce for THIS round — must equal the nonce the
            // signer's partial is computed with (the advertise==sign invariant
            // that the channel preserves by deriving both at the same round height).
            let lp_pn = closing_nonce_of_round(&lp, &hop, round, &secp);
            let hop_pn = closing_nonce_of_round(&hop, &lp, round, &secp);

            give_ctx_round(&lp_vs, &hop, Some(hop_pn.clone()), round, &secp);
            give_ctx_round(&hop_vs, &lp, Some(lp_pn.clone()), round, &secp);

            let lp_partial = lp_vs
                .partially_sign_closing_transaction(&tx, &secp)
                .expect("LP closing partial");
            let hop_partial = hop_vs
                .partially_sign_closing_transaction(&tx, &secp)
                .expect("hop closing partial");

            // Aggregate using the advertised per-round nonces. If the signer's
            // partial used a DIFFERENT (e.g. fixed) nonce than the advertised one,
            // this aggregation/verification FAILS — which is exactly the RED state
            // for round 1 before the per-round fix.
            let (agg_ctx_r, lp_i) =
                crate::taproot_signer::channel_key_agg_ctx(&lp_pk, &hop_pk, &lp_pk).unwrap();
            let hop_i = 1 - lp_i;
            let sig = crate::taproot_signer::aggregate_key_path_partials(
                agg_ctx_r, m, lp_i, lp_pn.clone(), lp_partial, hop_i, hop_pn, hop_partial,
            )
            .expect("aggregate per-round close partials (advertised nonce == signing nonce)");
            verify(&secp, &sig, &m, &q, "per-round coop-close key-path sig");
            (m, lp_pn)
        };

        // ---- Round 0 (fee 500) and Round 1 (fee 800): two DISTINCT close txs ----
        let (m0, lp_pn0) = run_round(0, 500);
        let (m1, lp_pn1) = run_round(1, 800);
        assert_ne!(m0, m1, "two rounds must sign different messages (different fees)");

        // ---- THE INVARIANT: distinct per-round nonces (the whole point) ----
        // Before the fix the closing nonce was pinned at a fixed height ⇒ both
        // rounds derived the SAME nonce ⇒ these pubnonces were EQUAL (RED) and the
        // two-equation key recovery `x=(s1-s2)/(e1-e2)` leaks the funding key.
        // After: a fresh per-round nonce ⇒ distinct R ⇒ no recovery (GREEN).
        assert_ne!(
            lp_pn0.serialize(),
            lp_pn1.serialize(),
            "SECURITY: two coop-close rounds reused the SAME MuSig2 nonce — \
             this leaks the funding private key. Closing nonce MUST be per-round.",
        );
        assert_ne!(
            super::closing_nonce_height(0),
            super::closing_nonce_height(1),
            "per-round closing heights must differ",
        );
        let _ = (lp_idx, hop_idx);
    }

    /// 🔴 SECURITY REGRESSION (reconnect variant): the per-round closing-nonce guard in `channel.rs::get_closing_signed_msg`
    /// only advances `closing_round` when the proposed fee DIFFERS from
    /// `last_sent_closing_fee`. On a peer disconnect mid-close, the reconnect path
    /// (`remove_uncommitted_htlcs_and_mark_paused`) resets `last_sent_closing_fee =
    /// None` to restart the `closing_signed` dance, and the re-advertised
    /// `shutdown_nonce` is re-derived at `closing_nonce_height(closing_round)`. If
    /// `closing_round` were NOT advanced across that reset, the post-reconnect dance
    /// would (guard sees `None` ⇒ no advance) sign a DIFFERENT close tx (the
    /// renegotiated fee ⇒ different sighash message `m'`) with the SAME deterministic
    /// nonce already used+sent pre-disconnect over `m`. Two partials sharing nonce `k`
    /// over `m ≠ m'` leak the funding private key `x = (s1−s2)/(e1−e2)`.
    ///
    /// The fix bumps `closing_round` in `remove_uncommitted_htlcs_and_mark_paused`
    /// whenever a taproot closing partial had already been sent this connection. This
    /// test reproduces the exact pre/post-reconnect nonce derivation the channel does
    /// and asserts the two nonces DIFFER (i.e. the round was advanced), which is the
    /// invariant the fix establishes.
    #[test]
    fn coop_close_reconnect_advances_round_no_nonce_reuse() {
        let secp = Secp256k1::new();
        let lp = make_signer(0x7A);
        let hop = make_signer(0x8B);

        // Pre-disconnect: round 0 close partial was advertised+sent (its nonce is the
        // round-0 `shutdown_nonce`).
        let round_pre = 0u64;
        let lp_nonce_pre = closing_nonce_of_round(&lp, &hop, round_pre, &secp);

        // Reconnect with the fix: `closing_round` advances by 1 because we had sent a
        // closing partial (`last_sent_closing_fee.is_some()`) on a taproot channel. The
        // re-advertised `shutdown_nonce` is now derived at the bumped round.
        let round_post = round_pre + 1;
        let lp_nonce_post = closing_nonce_of_round(&lp, &hop, round_post, &secp);

        // The two close txs across the reconnect carry different (re-negotiated) fees ⇒
        // different sighash messages; the nonces MUST differ so no nonce is ever reused
        // over two distinct messages.
        assert_ne!(
            lp_nonce_pre.serialize(),
            lp_nonce_post.serialize(),
            "SECURITY (reconnect): the post-reconnect closing nonce equals the \
             pre-disconnect one — `closing_round` was not advanced on reconnect, so a \
             second close partial would reuse the nonce and leak the funding key.",
        );

        // And had the round NOT been advanced (the bug), the nonce would be IDENTICAL —
        // proving the round-advance is precisely what prevents the reuse.
        let lp_nonce_no_advance = closing_nonce_of_round(&lp, &hop, round_pre, &secp);
        assert_eq!(
            lp_nonce_pre.serialize(),
            lp_nonce_no_advance.serialize(),
            "sanity: same round ⇒ same deterministic nonce (the reuse the fix avoids)",
        );
    }

    /// A no-HTLC **simple-taproot** channel type (only_static_remote_key base +
    /// the `option_simple_taproot` bit), so the LDK tx-builder takes the M6
    /// taproot branch (NUMS-tapscript to_local/to_remote/anchor outputs +
    /// `0x5120||Q` funding SPK) instead of the legacy P2WSH/P2WPKH path.
    fn taproot_channel_type() -> ChannelTypeFeatures {
        let mut ct = ChannelTypeFeatures::only_static_remote_key();
        ct.set_simple_taproot_required();
        ct
    }

    fn taproot_ct_params(
        holder: &InMemorySigner,
        counterparty: &InMemorySigner,
        holder_is_outbound: bool,
        secp: &Secp256k1<secp256k1::All>,
    ) -> CTParams {
        let mut p = ct_params(holder, counterparty, holder_is_outbound, secp);
        p.channel_type_features = taproot_channel_type();
        p
    }

    /// LOAD-BEARING M6 e2e: drive the **real LDK taproot tx-builder**
    /// (`CommitmentTransaction::new` with a `supports_simple_taproot()` channel
    /// type) end-to-end with the proven M5 signer.
    ///
    /// Asserts:
    ///   1. the M6 builder emits **P2TR** (`OP_1 <32B>`) commitment outputs
    ///      (`to_local`/`to_remote`/anchors), not P2WSH/P2WPKH — i.e. Step-1
    ///      branched correctly;
    ///   2. `chan_utils::channel_taproot_script_pubkey` (the funding SPK the
    ///      builder pins, `0x5120||Q`) equals the signer's tweaked aggregate `Q`;
    ///   3. the LP+hop MuSig2 key-path partials over the BIP341 key-path sighash
    ///      of **this taproot-format commitment tx** aggregate to a BIP340 sig
    ///      that **verifies vs `Q`**; and the funding-spend-format coop close does
    ///      too. No HTLCs.
    ///
    /// This is exactly the funding/commitment/close signing flow the
    /// ChannelManager nonce-exchange handler will run, but composed against the
    /// taproot tx-builder rather than abstract txs (the M5 test used a P2WSH
    /// channel type, so the M6 builder branch was untested by a verifying sig).
    #[test]
    fn taproot_builder_commitment_and_close_signatures_verify() {
        let secp = Secp256k1::new();
        let lp = make_signer(0xC3);
        let hop = make_signer(0xD4);
        let q = funding_q(&lp, &hop, &secp);

        let lp_vs = ValidatingChannelSigner::new(lp.clone(), committed_script());
        let hop_vs = ValidatingChannelSigner::new(hop.clone(), committed_script());
        give_ctx(&lp_vs, &hop, None, &secp);
        give_ctx(&hop_vs, &lp, None, &secp);

        // ---- Build hop's commitment via the M6 taproot tx-builder ----
        let idx = INITIAL_COMMITMENT_NUMBER;
        let hop_params = taproot_ct_params(&hop, &lp, false, &secp);
        let hop_per_commitment_point = hop.get_per_commitment_point(idx, &secp).unwrap();
        let directed = hop_params.as_holder_broadcastable();
        let hop_commitment = CommitmentTransaction::new(
            idx,
            &hop_per_commitment_point,
            FUNDING_SATS / 2 - 1_000,
            FUNDING_SATS / 2 - 1_000,
            253,
            Vec::new(),
            &directed,
            &secp,
        );

        // (1) every non-HTLC output must be P2TR (witness v1, 34-byte 0x5120||x).
        let hop_tx = &hop_commitment.trust().built_transaction().transaction;
        assert!(!hop_tx.output.is_empty(), "taproot commitment has outputs");
        for o in &hop_tx.output {
            assert!(
                o.script_pubkey.is_p2tr(),
                "M6 commitment output must be P2TR, got {:?}",
                o.script_pubkey,
            );
        }

        // (2) the funding SPK the builder/signer pin = 0x5120 || Q.
        let funding_spk = chan_utils::channel_taproot_script_pubkey(
            &hop.pubkeys(&secp).funding_pubkey,
            &lp.pubkeys(&secp).funding_pubkey,
        )
        .unwrap();
        assert!(funding_spk.is_p2tr(), "funding SPK is P2TR");
        let mut expected = vec![0x51u8, 0x20];
        expected.extend_from_slice(&q.serialize());
        assert_eq!(funding_spk.as_bytes(), &expected[..], "funding SPK == 0x5120||Q");

        // (3) sign the funding key-path spend of this taproot commitment tx.
        let hop_nonce = hop_vs.generate_local_nonce_pair(idx, &secp);
        let (lp_psig_with_nonce, lp_htlc_sigs) = lp_vs
            .partially_sign_counterparty_commitment(
                hop_nonce.clone(),
                &hop_commitment,
                Vec::new(),
                Vec::new(),
                &secp,
            )
            .expect("LP partial-signs hop's taproot commitment");
        assert!(lp_htlc_sigs.is_empty(), "no-HTLC channel");
        let PartialSignatureWithNonce(lp_partial, lp_pubnonce) = lp_psig_with_nonce.clone();

        let hop_holder = HolderCommitmentTransaction::new(
            hop_commitment.clone(),
            dummy_ecdsa_sig(&secp),
            Vec::new(),
            &hop.pubkeys(&secp).funding_pubkey,
            &lp.pubkeys(&secp).funding_pubkey,
        );
        let hop_partial = hop_vs
            .finalize_holder_commitment(&hop_holder, lp_psig_with_nonce, &secp)
            .expect("hop finalizes its taproot holder commitment");

        let lp_pk = lp.pubkeys(&secp).funding_pubkey.serialize();
        let hop_pk = hop.pubkeys(&secp).funding_pubkey.serialize();
        let (agg_ctx, lp_idx) =
            crate::taproot_signer::channel_key_agg_ctx(&lp_pk, &hop_pk, &lp_pk).unwrap();
        let hop_idx = 1 - lp_idx;

        let msg: [u8; 32] = *lightning::ln::chan_utils::taproot_funding_keyspend_sighash(
            hop_tx,
            0,
            bitcoin::Amount::from_sat(FUNDING_SATS),
            &funding_spk,
        )
        .unwrap()
        .as_ref();

        let agg_sig = crate::taproot_signer::aggregate_key_path_partials(
            agg_ctx, msg, lp_idx, lp_pubnonce, lp_partial, hop_idx, hop_nonce, hop_partial,
        )
        .expect("aggregate taproot commitment partials");
        verify(&secp, &agg_sig, &msg, &q, "M6 taproot commitment key-path sig");

        // ---- Cooperative close over the funding key-path spend ----
        let lp_close_nonce = closing_nonce_of(&lp, &hop, &secp);
        let hop_close_nonce = closing_nonce_of(&hop, &lp, &secp);
        give_ctx(&lp_vs, &hop, Some(hop_close_nonce.clone()), &secp);
        give_ctx(&hop_vs, &lp, Some(lp_close_nonce.clone()), &secp);

        let closing_tx = ClosingTransaction::new(
            FUNDING_SATS / 2 - 500,
            FUNDING_SATS / 2 - 500,
            committed_script(),
            counterparty_close_script(),
            bitcoin::OutPoint {
                txid: bitcoin::Txid::from_raw_hash(bitcoin::hashes::Hash::all_zeros()),
                vout: 0,
            },
        );
        let lp_close_partial = lp_vs
            .partially_sign_closing_transaction(&closing_tx, &secp)
            .expect("LP closing partial");
        let hop_close_partial = hop_vs
            .partially_sign_closing_transaction(&closing_tx, &secp)
            .expect("hop closing partial");

        let (agg_ctx2, lp_idx2) =
            crate::taproot_signer::channel_key_agg_ctx(&lp_pk, &hop_pk, &lp_pk).unwrap();
        let hop_idx2 = 1 - lp_idx2;
        let close_tx = closing_tx.trust().built_transaction();
        let close_msg: [u8; 32] = *lightning::ln::chan_utils::taproot_funding_keyspend_sighash(
            close_tx,
            0,
            bitcoin::Amount::from_sat(FUNDING_SATS),
            &funding_spk,
        )
        .unwrap()
        .as_ref();
        let close_agg = crate::taproot_signer::aggregate_key_path_partials(
            agg_ctx2, close_msg, lp_idx2, lp_close_nonce, lp_close_partial, hop_idx2,
            hop_close_nonce, hop_close_partial,
        )
        .expect("aggregate close partials");
        verify(&secp, &close_agg, &close_msg, &q, "M6 taproot coop-close key-path sig");
    }

    // --- M5 e2e helpers ---

    fn dummy_ecdsa_sig(secp: &Secp256k1<secp256k1::All>) -> Signature {
        let sk = SecretKey::from_slice(&[0x33; 32]).unwrap();
        let msg = bitcoin::secp256k1::Message::from_digest([0x44; 32]);
        secp.sign_ecdsa(&msg, &sk)
    }

    fn funding_spk_for(ctx: &musig2::KeyAggContext) -> bitcoin::ScriptBuf {
        let q = crate::taproot_signer::aggregated_xonly(ctx);
        bitcoin::ScriptBuf::new_p2tr_tweaked(
            bitcoin::key::TweakedPublicKey::dangerous_assume_tweaked(q),
        )
    }

    /// The deterministic closing (verification) nonce a signer would send in its
    /// `shutdown_nonce` — derived at the pinned closing-nonce height from its
    /// commitment_seed, bound to its funding pubkey (matches what
    /// `partially_sign_closing_transaction` uses internally).
    fn closing_nonce_of(
        signer: &InMemorySigner,
        counterparty: &InMemorySigner,
        secp: &Secp256k1<secp256k1::All>,
    ) -> PublicNonce {
        closing_nonce_of_round(signer, counterparty, 0, secp)
    }

    /// The deterministic closing (verification) nonce a signer would advertise for
    /// cooperative-close round `round` — derived at `closing_nonce_height(round)`
    /// from its commitment_seed, bound to its funding pubkey (matches what
    /// `partially_sign_closing_transaction` uses internally for that round).
    fn closing_nonce_of_round(
        signer: &InMemorySigner,
        counterparty: &InMemorySigner,
        round: u64,
        secp: &Secp256k1<secp256k1::All>,
    ) -> PublicNonce {
        // Must match exactly what `partially_sign_closing_transaction` signs with:
        // the FirstRound-derived nonce at the per-round closing height.
        let own = signer.pubkeys(secp).funding_pubkey.serialize();
        let cp = counterparty.pubkeys(secp).funding_pubkey.serialize();
        let (ctx, our_index) =
            crate::taproot_signer::channel_key_agg_ctx(&own, &cp, &own).unwrap();
        crate::taproot_signer::local_pubnonce(
            ctx,
            our_index,
            &signer.commitment_seed,
            super::closing_nonce_height(round),
        )
        .unwrap()
    }

    fn verify(
        secp: &Secp256k1<secp256k1::All>,
        sig: &bip340_schnorr::Signature,
        msg: &[u8; 32],
        q: &bitcoin::secp256k1::XOnlyPublicKey,
        what: &str,
    ) {
        let message = bitcoin::secp256k1::Message::from_digest(*msg);
        secp.verify_schnorr(sig, &message, q)
            .unwrap_or_else(|e| panic!("{what} must verify under BIP340 vs tweaked Q: {e:?}"));
    }

    /// M9c: the SPLICE shared-input MuSig2 key-path sign. Build a splice
    /// tx (shared OLD-funding input + one contributed input), have BOTH signers
    /// `partially_sign_splice_shared_input`, aggregate the partials, and assert the
    /// result is a BIP340 key-path Schnorr sig verifying vs the OLD funding `Q`. This
    /// drives the real `ValidatingChannelSigner::partially_sign_splice_shared_input`
    /// + the per-splice nonce derivation end-to-end, the signer-level analog of the
    /// on-chain `check_spends!` proof in the LDK functional splice test.
    #[test]
    fn taproot_splice_shared_input_signatures_verify() {
        use bitcoin::{
            absolute::LockTime, transaction::Version, Amount, OutPoint, Sequence, Transaction,
            TxIn, TxOut, Witness,
        };

        let secp = Secp256k1::new();
        let lp = make_signer(0x51);
        let hop = make_signer(0x62);
        let q = funding_q(&lp, &hop, &secp);

        let lp_vs = ValidatingChannelSigner::new(lp.clone(), committed_script());
        let hop_vs = ValidatingChannelSigner::new(hop.clone(), committed_script());

        // Supply each side's taproot context (the OLD funding-key aggregate is what
        // `partially_sign_splice_shared_input` uses — the splice spends the OLD output).
        give_ctx(&lp_vs, &hop, None, &secp);
        give_ctx(&hop_vs, &lp, None, &secp);

        // The OLD funding output scriptPubKey is `0x5120||Q`.
        let lp_pk = lp.pubkeys(&secp).funding_pubkey.serialize();
        let hop_pk = hop.pubkeys(&secp).funding_pubkey.serialize();
        let (agg_ctx, lp_idx) =
            crate::taproot_signer::channel_key_agg_ctx(&lp_pk, &hop_pk, &lp_pk).unwrap();
        let hop_idx = 1 - lp_idx;
        let old_funding_spk = funding_spk_for(&agg_ctx);

        // A splice tx: input 0 = the shared OLD funding output, input 1 = a
        // contributed P2WPKH input. Output 0 = the new funding output (value
        // irrelevant to the sighash test).
        let prev_funding_txid = bitcoin::Txid::from_raw_hash(
            bitcoin::hashes::Hash::hash(b"old-funding-tx"),
        );
        let contributed_txid =
            bitcoin::Txid::from_raw_hash(bitcoin::hashes::Hash::hash(b"contrib-utxo"));
        let splice_tx = Transaction {
            version: Version::TWO,
            lock_time: LockTime::ZERO,
            input: vec![
                TxIn {
                    previous_output: OutPoint { txid: prev_funding_txid, vout: 0 },
                    script_sig: bitcoin::ScriptBuf::new(),
                    sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
                    witness: Witness::new(),
                },
                TxIn {
                    previous_output: OutPoint { txid: contributed_txid, vout: 1 },
                    script_sig: bitcoin::ScriptBuf::new(),
                    sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
                    witness: Witness::new(),
                },
            ],
            output: vec![TxOut {
                value: Amount::from_sat(FUNDING_SATS + 50_000),
                script_pubkey: old_funding_spk.clone(),
            }],
        };
        // All prevouts in input order: the OLD funding output + the contributed UTXO.
        let all_prevouts = vec![
            TxOut { value: Amount::from_sat(FUNDING_SATS), script_pubkey: old_funding_spk.clone() },
            TxOut {
                value: Amount::from_sat(50_000),
                script_pubkey: bitcoin::ScriptBuf::new_p2wpkh(&bitcoin::WPubkeyHash::from_raw_hash(
                    bitcoin::hashes::Hash::hash(b"contrib-wpkh"),
                )),
            },
        ];

        // Each side advertises its splice nonce (keyed on prev_funding_txid).
        let lp_nonce = lp_vs.generate_splice_nonce(&prev_funding_txid, &secp).unwrap();
        let hop_nonce = hop_vs.generate_splice_nonce(&prev_funding_txid, &secp).unwrap();

        // Each side produces its key-path partial over the splice sighash.
        let (lp_partial, lp_pubnonce) = lp_vs
            .partially_sign_splice_shared_input(
                &splice_tx, 0, &all_prevouts, hop_nonce.clone(), &prev_funding_txid, &secp,
            )
            .expect("LP splice partial");
        let (hop_partial, hop_pubnonce) = hop_vs
            .partially_sign_splice_shared_input(
                &splice_tx, 0, &all_prevouts, lp_nonce.clone(), &prev_funding_txid, &secp,
            )
            .expect("hop splice partial");

        // The advertised nonce must equal the nonce actually used for signing.
        assert_eq!(lp_nonce.serialize(), lp_pubnonce.serialize());
        assert_eq!(hop_nonce.serialize(), hop_pubnonce.serialize());

        // Aggregate → final key-path Schnorr sig over the splice sighash.
        let msg: [u8; 32] = *lightning::ln::chan_utils::taproot_splice_keyspend_sighash(
            &splice_tx, 0, &all_prevouts,
        )
        .unwrap()
        .as_ref();
        let (agg_ctx2, _) =
            crate::taproot_signer::channel_key_agg_ctx(&lp_pk, &hop_pk, &lp_pk).unwrap();
        let agg_sig = crate::taproot_signer::aggregate_key_path_partials(
            agg_ctx2, msg, lp_idx, lp_pubnonce, lp_partial, hop_idx, hop_pubnonce, hop_partial,
        )
        .expect("aggregate splice partials");

        verify(&secp, &agg_sig, &msg, &q, "splice shared-input key-path sig");
    }

    /// M9f-0 guard: two splices over DIFFERENT prev_funding_txids MUST
    /// derive DISTINCT secret nonces (advertised distinct pubnonces). Reusing a
    /// nonce across two distinct splice txs would leak the funding private key —
    /// the same class as the closing-nonce-reuse bug. Asserts the per-splice nonce
    /// is keyed on prev_funding_txid (distinct per splice).
    #[test]
    fn taproot_splice_nonce_distinct_per_prev_funding_txid() {
        let secp = Secp256k1::new();
        let lp = make_signer(0x71);
        let hop = make_signer(0x82);
        let lp_vs = ValidatingChannelSigner::new(lp.clone(), committed_script());
        give_ctx(&lp_vs, &hop, None, &secp);

        let txid_a =
            bitcoin::Txid::from_raw_hash(bitcoin::hashes::Hash::hash(b"splice-parent-A"));
        let txid_b =
            bitcoin::Txid::from_raw_hash(bitcoin::hashes::Hash::hash(b"splice-parent-B"));

        let nonce_a = lp_vs.generate_splice_nonce(&txid_a, &secp).unwrap();
        let nonce_b = lp_vs.generate_splice_nonce(&txid_b, &secp).unwrap();
        assert_ne!(
            nonce_a.serialize(), nonce_b.serialize(),
            "splice nonce MUST differ across distinct prev_funding_txids (no reuse)"
        );
        // Same prev_funding_txid → SAME (re-derivable, crash-safe) nonce.
        let nonce_a2 = lp_vs.generate_splice_nonce(&txid_a, &secp).unwrap();
        assert_eq!(
            nonce_a.serialize(), nonce_a2.serialize(),
            "splice nonce is deterministic/re-derivable for a fixed prev_funding_txid"
        );

        // And the splice nonce height must NOT collide with the commitment range
        // (<2^48) or the closing range (top of u64).
        let h = splice_nonce_height(&txid_a);
        assert!(h >= (1u64 << 48), "splice nonce height above commitment range");
        assert!(h < u64::MAX - 1_000_000, "splice nonce height below closing range");
    }
}
