# LP signing for the fleet — what it must cover, and why liveness gating settles it

**Owner, 2026-08-16: *"i am not tied to the current shape, finish what you need to make sure that
lp signing for the fleet is ready and allows all those operations to be finished (with its
intermittent liveness updates, otherwise to prevent themselves from being DoS'd other swappers
are not routed to this channel)."*** Companion to `HOP-TRUST-AUDIT.md`. **Fold both into
`QUEUE.md` when it is quiet** — they are here because that file has held another thread's
uncommitted edits all day (rule 14).

## 🔑 The proposal dissolves an open trade rather than adding to the pile

`§LADDER-REMOVAL` records a three-way choice nobody could win, because a splice rotates the
funding outpoint and BIP-341 `Prevouts::All` makes every pre-signed rung unbroadcastable at once:

* **(a) re-arm inside every splice** — the escape never lapses, but the phone signs PER SPLICE, so
  *"signs once, goes offline forever"* dies and **the phone's job grows**;
* **(b) never splice an armed channel** — keeps the phone's job one-time, pays in on-chain fees;
* **(c) clear `exitArmedAt` and accept a window** — cheapest, honest, but the LP is genuinely
  unprotected between splice and re-arm.

⚠️ (a) was rejected because it runs against the standing preference for shrinking the phone's job.
**Liveness-gated routing changes what (a) COSTS, and therefore which option is correct.**

⇒ **If an LP that has not posted recent liveness simply STOPS BEING ROUTED NEW SWAPPERS, then the
growth in the phone's job is OPT-IN rather than imposed.** Sign more, earn more; sign less, get
routed less, and *nothing breaks* — an idle channel is not spliced, because splices are driven by
routing volume (capacity keeping, fee flush, deliveries). **The LP that goes offline forever still
holds a valid ladder against an outpoint nobody is rotating.**

⇒ **THAT MAKES (a) VIABLE AND IT IS THE ONE TO BUILD.** It is also the only option that keeps an
escape live across routine operation, which is what §E156 was closed to guarantee.

## What the LP must now sign — and note the batch GREW this list

| operation | why the LP signs | when |
|---|---|---|
| `OpenAuth.lp_sig` | consent to the channel; the fleet relays and cannot manufacture it | once, at open |
| `exits` ladder rungs | pre-signed spends of the 2-of-2 — the offline LP's only escape | at open, **and per splice** under (a) |
| **freshness invalidation (§T3)** | making the freshness outpoint a 2-of-2 means the hop can no longer revoke every exit alone | whenever a fresher exit is agreed |
| **liveness heartbeat** | the routing gate below | intermittently |

⚠️ **§T3 IS WHY "SIGN ONCE" WAS ALREADY DEAD.** Even without the splice problem, making freshness
a 2-of-2 requires the LP's signature at invalidation time. The queue calls that *"free, because
invalidation only ever happens when a fresher exit is agreed and the LP is signing that anyway"* —
true, and it still means **the LP must be reachable then.** The batch in `HOP-TRUST-AUDIT.md`
therefore does not merely change signatures; **it converts the LP from a one-time signer into an
intermittently-live one**, and the liveness gate is what makes that safe rather than fragile.

## The liveness gate

**Shape:** the LP posts a signed, monotonically-numbered heartbeat over `(channelId, height, seq)`.
The hop refuses to route NEW swappers to a channel whose latest heartbeat is older than a threshold.

⚠️ **THE KEY SENTENCE HERE WAS STALE AND IS CORRECTED.** It read *"reuses the key `auth.lp_sig`
already uses"* — **§E183 deleted `OpenAuth.lp_sig`**, so that named something that no longer exists.
It re-derives to the same place rather than to a new key: Bitcoin and the EVM share secp256k1, so a
recoverable ECDSA signature by the LP's **channel key** recovers to `lpEthOf(lpPubkey)`, the very
address the contract derives. No new key material, no MuSig2, and `ethers` produces it today.
⇒ Built: `quid_hop::liveness` (`Heartbeat::digest`, domain-tagged `QUID-REALM::lp-liveness.v1`).

**What it protects, stated precisely:**
* **The swapper** — never routed into a channel whose LP cannot complete the co-signs the swap
  needs, so a swap does not stall halfway. This is the DoS the owner names.
* **The LP** — an outage costs FORGONE FEES, never funds. Existing positions, the armed ladder and
  the refund paths are untouched by going stale; only new routing stops.
* **NOT the LP against the hop.** ⚠️ A hop can decline to route for any reason and always could —
  the gate does not hand it a new power, it makes an EXISTING discretion legible. Say this plainly
  rather than claiming the gate is trust-free.

**Three things that decide the build, none of them yet answered:**
1. ✅ **ANSWERED — HOP-OBSERVED, AND THE TIP IS WHAT MAKES THAT HONEST.** Built hop-observed, no
   on-chain record. The worry with hop-observed was that the hop authors the number an LP is judged
   against; that is answered without gas by taking the tip from **`SPVGateway.getMainchainHeight()`**
   — the height the CONTRACT believes, advanced by SPV-proven headers anyone may submit. So a hop
   cannot manufacture staleness by claiming a tip the chain does not have. It can still simply
   decline to route, which this gate has never claimed to prevent. The on-chain dispute path stays
   unbuilt for the reason given: it is a fee question, not a safety one.
2. 🔴 **STILL OPEN, AND DELIBERATELY UNANSWERED IN CODE.** The threshold must be derived from the
   slowest co-sign the LP must complete, not picked. That measurement does not exist, so nothing
   invents one: `LivenessBook::is_routable` takes `max_age_blocks` as a REQUIRED argument, and the
   daemon reads `QUID_LP_HEARTBEAT_MAX_AGE_BLOCKS` with **no default** — unset means no gate at all.
   An operator must state the number, which keeps the assumption visible instead of buried in a
   constant. ▶️ Measure a full splice re-arm round trip to a real phone and derive it from that.
3. ✅ **ANSWERED — AUTOMATIC, AND PINNED BY A TEST.** Freshness is a pure function of the latest
   heartbeat against the tip, so the next heartbeat alone restores routing; there is no stale flag
   to clear and no operator action. `the_gate_offers_no_path_to_an_lp_that_cannot_cosign` asserts
   exactly that final step (*"re-entry must need nothing but a heartbeat"*).

## Order — this does NOT jump the phase queue

⛔ The heartbeat and the routing gate are worth building only once the LP actually holds its half
and must co-sign — i.e. **after** `§M1#2` (landed) and **with** the §T3 half of the batch, since
§T3 is what creates the recurring signature. Building the gate first protects against a DoS that
cannot happen yet, and would be a clamp on a state that is not reachable (rule 3).

▶️ **Order:** BIP-340 parity rule in the wallet → the batched `BTCChannels` change (§T2 deletion +
§T3 2-of-2 + §E166-2) → heartbeat + routing gate → re-arm-inside-splice (option **a**).

## Where each piece lives

* **SPV / Rust** — the heartbeat verifier and the routing gate (`quid-hop`, the routing decision);
  the freshness 2-of-2; the splice re-arm handshake.
* **SPV / Solidity** — the batch in `HOP-TRUST-AUDIT.md`; an on-chain liveness record only if (1)
  above chooses it.
* **ibiza / phone** — the signer itself: the ladder rungs, the freshness co-sign and the heartbeat.
  (`auth.lp_sig` stood here and is **deleted by §E183** — do not build it.) ⚠️ The `exits` ladder
  still needs an audited BIP-327 MuSig2 implementation; the heartbeat does NOT — it is a recoverable
  ECDSA signature by the channel key that `ethers` produces today, so **it can land first and
  independently.** ▶️ **POST IT TO `/lp/heartbeat`** (`{channel_id, height, seq, sig}`, bearer token,
  answers `{"recorded": bool}`) — the intake exists and is waiting for a poster.
  📌 On `@scure/btc-signer` for the ladder: its MuSig2 surface is confirmed against the real package
  and it does **not** give the nonce-reuse-is-a-type-error property the Rust crate does — use
  `deterministicSign`. See `ibiza/TODO.md §3b`.
