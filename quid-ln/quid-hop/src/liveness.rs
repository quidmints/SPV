//! (§LP-LIVENESS) The routing gate that makes "the LP is a phone" safe.
//!
//! **WHY THIS EXISTS, AND WHY IT IS NOT OPTIONAL.** `LP-SIGNING-READINESS.md` sets out the
//! splice/`Prevouts::All` problem and rejects option **(a)** — re-arm inside every splice — because
//! *"the phone signs PER SPLICE, so 'signs once, goes offline forever' dies and the phone's job
//! grows"*. (a) becomes correct ONLY with this gate: an LP that has not posted a recent heartbeat
//! stops being routed NEW swappers, so *"the growth in the phone's job is OPT-IN rather than
//! imposed"* and *"the LP that goes offline forever still holds a valid ladder against an outpoint
//! nobody is rotating."*
//!
//! ⛔ **§E233-ladder LANDED (a) FIRST, OUT OF THE DOCUMENTED ORDER** (which is: heartbeat + routing
//! gate → *then* re-arm-inside-splice). Until this gate is wired into the routing decision, a
//! splice on an offline LP's channel simply reverts, and deliveries, fee flushes and capacity
//! keeping all block on a phone being reachable.
//!
//! **WHAT IT PROTECTS, STATED EXACTLY** (the doc is careful here and so is this):
//! * **The swapper** — never routed into a channel whose LP cannot complete the co-signs the swap
//!   needs, so a swap does not stall half-done. That is the DoS this exists for.
//! * **The LP** — an outage costs FORGONE FEES, never funds. Existing positions, the armed ladder
//!   and the refund paths are untouched by going stale; only NEW routing stops.
//! * ⚠️ **NOT the LP against the hop.** A hop may decline to route for any reason and always could.
//!   This does not hand it a new power; it makes an existing discretion legible. Do not describe
//!   the gate as trust-free.
//!
//! 🔑 **THE KEY IS THE CHANNEL KEY — there is no separate heartbeat key, and no new trust.** §E183
//! deleted `OpenAuth.lp_sig`, so the doc's suggestion that the heartbeat *"reuses the key
//! `auth.lp_sig` already uses"* names something that no longer exists. It re-derives to the same
//! place: Bitcoin and the EVM share secp256k1, so an ECDSA signature by the LP's channel key
//! recovers to `lpEthOf(lpPubkey)` — the very address the contract derives. The phone already holds
//! that key, and this is an EVM-shaped signature `ethers` produces today, so it needs **no**
//! BIP-327 MuSig2 and can ship before the ladder work does.

use alloy_primitives::{keccak256, Address, B256};
use secp256k1::ecdsa::{RecoverableSignature, RecoveryId};
use secp256k1::{Message, Secp256k1};
use std::collections::HashMap;
use std::sync::RwLock;

/// Domain tag. A heartbeat must never be reinterpretable as any other message this key signs.
const HEARTBEAT_TAG: &[u8] = b"QUID-REALM::lp-liveness.v1";

/// One heartbeat: *this channel, at this height, with this sequence number*.
///
/// `seq` is what makes replay useless — a captured heartbeat cannot be re-posted to fake liveness
/// later, because the book only accepts a STRICTLY greater one. `height` is what makes staleness
/// measurable without trusting the poster's clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Heartbeat {
    pub channel_id: B256,
    pub height: u32,
    pub seq: u64,
}

impl Heartbeat {
    /// The digest the LP signs. Domain-tagged and length-fixed: every field is written at a
    /// constant width, so no two distinct heartbeats can produce the same preimage.
    pub fn digest(&self) -> B256 {
        let mut buf = Vec::with_capacity(HEARTBEAT_TAG.len() + 32 + 4 + 8);
        buf.extend_from_slice(HEARTBEAT_TAG);
        buf.extend_from_slice(self.channel_id.as_slice());
        buf.extend_from_slice(&self.height.to_be_bytes());
        buf.extend_from_slice(&self.seq.to_be_bytes());
        keccak256(buf)
    }
}

/// Recover the signer of a heartbeat, or `None` if the signature is malformed.
///
/// ⚠️ Returns the RECOVERED address rather than a bool against an expected one, deliberately: the
/// caller must compare it to the channel's own `lpEth`, and a function that took the expected value
/// would let a caller pass whatever it just recovered and "verify" successfully.
pub fn recover_heartbeat(hb: &Heartbeat, sig65: &[u8]) -> Option<Address> {
    if sig65.len() != 65 {
        return None;
    }
    let rec = RecoveryId::from_i32(match sig65[64] {
        v @ 0..=1 => v as i32,
        v @ 27..=28 => (v - 27) as i32,
        _ => return None,
    })
    .ok()?;
    let sig = RecoverableSignature::from_compact(&sig65[..64], rec).ok()?;
    let msg = Message::from_digest(hb.digest().0);
    let pk = Secp256k1::verification_only().recover_ecdsa(&msg, &sig).ok()?;
    let uncompressed = pk.serialize_uncompressed(); // 0x04 || X || Y
    Some(Address::from_slice(&keccak256(&uncompressed[1..])[12..]))
}

/// The hop's view of who is live. Hop-observed, per the doc's own recommendation: free and instant,
/// with an on-chain record reserved for dispute — and that only matters if being unrouted is ever
/// worth disputing, which is a fee question rather than a safety one.
#[derive(Default)]
pub struct LivenessBook {
    latest: HashMap<B256, Heartbeat>,
}

impl LivenessBook {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a heartbeat if it verifies against `lp_eth` and strictly advances `seq`.
    ///
    /// Returns `false` for a bad signature, a wrong signer, or a replayed/stale sequence — all
    /// three are the same answer to the caller (*this did not update liveness*) and none is an
    /// error worth propagating: a hop receives these from the network and must not be DoS-able by
    /// malformed ones.
    pub fn record(&mut self, hb: Heartbeat, sig65: &[u8], lp_eth: Address) -> bool {
        if recover_heartbeat(&hb, sig65) != Some(lp_eth) {
            return false;
        }
        match self.latest.get(&hb.channel_id) {
            Some(prev) if hb.seq <= prev.seq => false,
            _ => {
                self.latest.insert(hb.channel_id, hb);
                true
            }
        }
    }

    pub fn latest(&self, channel_id: &B256) -> Option<Heartbeat> {
        self.latest.get(channel_id).copied()
    }

    /// Is this channel routable for a NEW swapper?
    ///
    /// ⚠️ **`max_age_blocks` IS A REQUIRED ARGUMENT AND HAS NO DEFAULT, DELIBERATELY.** The doc is
    /// explicit that the threshold *"is a liveness/latency trade and must not be a magic number —
    /// it should be DERIVED from the slowest co-sign the LP must complete, not picked. Measure that
    /// first."* That measurement does not exist yet, so this refuses to invent one: a caller must
    /// state the number it is using, which keeps the assumption visible instead of buried here.
    ///
    /// 🔑 **Unknown ⇒ NOT routable.** A channel that has never posted is treated as stale, so the
    /// gate fails CLOSED for the swapper. The cost of a false "stale" is forgone fees; the cost of
    /// a false "live" is a swap that stalls half-done.
    pub fn is_routable(&self, channel_id: &B256, tip: u32, max_age_blocks: u32) -> bool {
        match self.latest.get(channel_id) {
            // A heartbeat from the future is not evidence of liveness; treat it as no evidence.
            Some(hb) if hb.height > tip => false,
            Some(hb) => tip - hb.height <= max_age_blocks,
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use secp256k1::{Secp256k1, SecretKey};

    fn signer(byte: u8) -> (SecretKey, Address) {
        let sk = SecretKey::from_slice(&[byte; 32]).expect("valid key");
        let pk = sk.public_key(&Secp256k1::new());
        let un = pk.serialize_uncompressed();
        (sk, Address::from_slice(&keccak256(&un[1..])[12..]))
    }

    fn sign(sk: &SecretKey, hb: &Heartbeat) -> Vec<u8> {
        let sig = Secp256k1::new()
            .sign_ecdsa_recoverable(&Message::from_digest(hb.digest().0), sk);
        let (rec, compact) = sig.serialize_compact();
        let mut out = compact.to_vec();
        out.push(rec.to_i32() as u8);
        out
    }

    fn hb(seq: u64, height: u32) -> Heartbeat {
        Heartbeat { channel_id: B256::repeat_byte(0xAB), height, seq }
    }

    #[test]
    fn a_heartbeat_recovers_to_the_lps_own_address() {
        let (sk, lp) = signer(0x11);
        let h = hb(1, 100);
        assert_eq!(recover_heartbeat(&h, &sign(&sk, &h)), Some(lp));
    }

    /// ⚠️ THE POINT OF THE DOMAIN TAG AND THE FIXED WIDTHS. A signature is only evidence of
    /// liveness for the channel, height and sequence it names; if any field could be changed
    /// without invalidating it, a captured heartbeat would prove liveness for a different channel.
    #[test]
    fn every_field_is_committed() {
        let (sk, lp) = signer(0x22);
        let h = hb(7, 500);
        let sig = sign(&sk, &h);
        for other in [
            Heartbeat { channel_id: B256::repeat_byte(0xCD), ..h },
            Heartbeat { height: 501, ..h },
            Heartbeat { seq: 8, ..h },
        ] {
            assert_ne!(recover_heartbeat(&other, &sig), Some(lp), "field not committed");
        }
    }

    #[test]
    fn another_key_is_not_the_lp() {
        let (sk, _) = signer(0x33);
        let (_, other_lp) = signer(0x44);
        let mut book = LivenessBook::new();
        let h = hb(1, 10);
        assert!(!book.record(h, &sign(&sk, &h), other_lp), "wrong signer accepted");
        assert!(book.latest(&h.channel_id).is_none());
    }

    /// A captured heartbeat must not fake liveness later — the sequence must strictly advance.
    #[test]
    fn a_replayed_heartbeat_does_not_refresh_liveness() {
        let (sk, lp) = signer(0x55);
        let mut book = LivenessBook::new();
        let first = hb(5, 100);
        assert!(book.record(first, &sign(&sk, &first), lp));
        assert!(!book.record(first, &sign(&sk, &first), lp), "replay accepted");
        let older = hb(4, 400);
        assert!(!book.record(older, &sign(&sk, &older), lp), "regressed seq accepted");
        assert_eq!(book.latest(&first.channel_id).unwrap().height, 100, "state moved on a replay");
    }

    /// 🔑 THE GATE FAILS CLOSED. Never-posted and long-stale are both unroutable; the cost of a
    /// false "stale" is forgone fees, the cost of a false "live" is a swap stalling half-done.
    #[test]
    fn unknown_and_stale_are_both_unroutable() {
        let (sk, lp) = signer(0x66);
        let mut book = LivenessBook::new();
        let id = B256::repeat_byte(0xAB);
        assert!(!book.is_routable(&id, 1_000, 144), "a channel with no heartbeat routed");
        let h = hb(1, 800);
        assert!(book.record(h, &sign(&sk, &h), lp));
        assert!(book.is_routable(&id, 900, 144), "100 blocks old must be routable at 144");
        assert!(!book.is_routable(&id, 1_000, 144), "200 blocks old must not be routable at 144");
        // Re-entry is automatic: the next heartbeat restores routing with no operator action.
        let fresh = hb(2, 1_000);
        assert!(book.record(fresh, &sign(&sk, &fresh), lp));
        assert!(book.is_routable(&id, 1_000, 144), "re-entry after staleness must be automatic");
    }

    /// A heartbeat dated after the tip is not evidence of liveness — it is a clock the hop cannot
    /// check, so it is treated as no evidence rather than as maximally fresh.
    #[test]
    fn a_future_dated_heartbeat_is_not_evidence() {
        let (sk, lp) = signer(0x77);
        let mut book = LivenessBook::new();
        let h = hb(1, 5_000);
        assert!(book.record(h, &sign(&sk, &h), lp));
        assert!(!book.is_routable(&h.channel_id, 1_000, 144), "future-dated heartbeat routed");
    }

    /// 🔑 THE ROUTING DECISION ITSELF. A channel is routable only when it is BOUND to an on-chain
    /// id and its LP has posted recently — unmapped, unheard-from and stale all read the same to a
    /// payer: no path is offered, so no swap starts down a channel whose LP cannot co-sign.
    #[test]
    fn the_gate_offers_no_path_to_an_lp_that_cannot_cosign() {
        let (sk, lp) = signer(0x88);
        let gate = RoutingGate::new(144);
        let ldk = [0x01u8; 32];
        let cid = B256::repeat_byte(0xAB);
        gate.set_tip(1_000);

        assert!(!gate.is_routable_ldk(&ldk), "an UNBOUND channel must not be routed");
        gate.bind(ldk, cid, lp);
        assert!(!gate.is_routable_ldk(&ldk), "bound but never heard from must not be routed");

        let fresh = hb(1, 990);
        assert!(gate.record(ldk, fresh, &sign(&sk, &fresh)));
        assert!(gate.is_routable_ldk(&ldk), "a live LP must be routable");

        // Time passes with no heartbeat: routing stops on its own, no operator action.
        gate.set_tip(1_200);
        assert!(!gate.is_routable_ldk(&ldk), "stale LP still routed");

        // ⚠️ One channel's heartbeat must never refresh another's.
        let other = Heartbeat { channel_id: B256::repeat_byte(0xCD), height: 1_200, seq: 2 };
        assert!(!gate.record(ldk, other, &sign(&sk, &other)), "wrong channelId accepted");
        assert!(!gate.is_routable_ldk(&ldk), "liveness refreshed by another channel's heartbeat");

        // The LP comes back: routing resumes on the next heartbeat alone.
        let back = hb(2, 1_200);
        assert!(gate.record(ldk, back, &sign(&sk, &back)));
        assert!(gate.is_routable_ldk(&ldk), "re-entry must need nothing but a heartbeat");
    }

    #[test]
    fn a_malformed_signature_is_refused_not_panicking() {
        let h = hb(1, 10);
        for bad in [vec![], vec![0u8; 64], vec![0u8; 65], vec![9u8; 66]] {
            assert_eq!(recover_heartbeat(&h, &bad), None);
        }
    }
}

/// (§LP-LIVENESS) The gate as the ROUTING PATH sees it: "may a new swapper be sent down this LDK
/// channel?"
///
/// 🔑 **IT RESOLVES LDK's CHANNEL ID TO OURS, because they are not the same thing.** LDK identifies
/// a channel by its own id; the contract identifies it by `channelId`, derived from the ORIGINAL
/// funding outpoint and the sorted 2-of-2 pubkeys (`onchain_cid_from_monitor`). The heartbeat
/// signs OUR id — the one the contract and the phone agree on — so the routing filter has to cross
/// that boundary, and the map is maintained by whoever already walks the monitors.
///
/// ⚠️ **AN UNMAPPED CHANNEL IS NOT ROUTABLE**, for the same reason an unheard-from one is not: the
/// gate cannot show the LP is live, and the cheap error is forgone fees.
pub struct RoutingGate {
    inner: RwLock<GateState>,
    /// See [`LivenessBook::is_routable`] — required, never defaulted, because the threshold must be
    /// derived from the slowest co-sign rather than picked.
    max_age_blocks: u32,
}

#[derive(Default)]
struct GateState {
    book: LivenessBook,
    tip: u32,
    /// LDK channel id → (our on-chain `channelId`, the LP that must sign for it).
    known: HashMap<[u8; 32], (B256, Address)>,
}

impl RoutingGate {
    pub fn new(max_age_blocks: u32) -> Self {
        Self { inner: RwLock::new(GateState::default()), max_age_blocks }
    }

    /// Bind an LDK channel to its on-chain id and LP. Idempotent; call it whenever the monitor set
    /// is walked.
    pub fn bind(&self, ldk_id: [u8; 32], channel_id: B256, lp_eth: Address) {
        if let Ok(mut g) = self.inner.write() {
            g.known.insert(ldk_id, (channel_id, lp_eth));
        }
    }

    pub fn set_tip(&self, height: u32) {
        if let Ok(mut g) = self.inner.write() {
            g.tip = height;
        }
    }

    /// Record a heartbeat the LP posted. Returns false on a bad signature, the wrong signer, a
    /// replay, or an unbound channel — all "this did not update liveness".
    pub fn record(&self, ldk_id: [u8; 32], hb: Heartbeat, sig65: &[u8]) -> bool {
        let Ok(mut g) = self.inner.write() else { return false };
        let Some(&(cid, lp)) = g.known.get(&ldk_id) else { return false };
        // The heartbeat must name the channel it is posted for; otherwise one channel's heartbeat
        // would refresh another's liveness.
        if hb.channel_id != cid {
            return false;
        }
        g.book.record(hb, sig65, lp)
    }

    /// THE ROUTING DECISION. `false` ⇒ this channel is left out of the route hints, so a payer is
    /// never given a path to it and no NEW swap starts down a channel whose LP cannot co-sign.
    pub fn is_routable_ldk(&self, ldk_id: &[u8; 32]) -> bool {
        let Ok(g) = self.inner.read() else { return false };
        match g.known.get(ldk_id) {
            Some(&(cid, _)) => g.book.is_routable(&cid, g.tip, self.max_age_blocks),
            None => false,
        }
    }
}
