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

**Shape:** the LP posts a signed, monotonically-numbered heartbeat (an EVM signature over
`(channelId, height, nonce)` costs nothing and reuses the key `auth.lp_sig` already uses). The hop
refuses to route NEW swappers to a channel whose latest heartbeat is older than a threshold.

**What it protects, stated precisely:**
* **The swapper** — never routed into a channel whose LP cannot complete the co-signs the swap
  needs, so a swap does not stall halfway. This is the DoS the owner names.
* **The LP** — an outage costs FORGONE FEES, never funds. Existing positions, the armed ladder and
  the refund paths are untouched by going stale; only new routing stops.
* **NOT the LP against the hop.** ⚠️ A hop can decline to route for any reason and always could —
  the gate does not hand it a new power, it makes an EXISTING discretion legible. Say this plainly
  rather than claiming the gate is trust-free.

**Three things that decide the build, none of them yet answered:**
1. **On-chain or hop-observed?** Hop-observed is free and instant; on-chain costs gas but lets an
   LP PROVE liveness when a hop claims otherwise. ⇒ Suggest hop-observed for routing, with an
   on-chain path reserved for dispute — but note the on-chain one only matters if being unrouted
   is ever worth disputing, which is a fee question, not a safety one.
2. **The threshold is a liveness/latency trade and must not be a magic number.** It should be
   derived from the slowest co-sign the LP must complete, not picked. Measure that first.
3. **Re-entry after staleness must be cheap and automatic**, or the gate becomes a trap: an LP
   that missed a heartbeat by a minute should be routable again on its next one, with no operator
   action.

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
* **ibiza / phone** — the signer itself: `auth.lp_sig`, the ladder rungs, the freshness co-sign and
  the heartbeat. ⚠️ Its `exits` ladder still needs an audited BIP-327 MuSig2 implementation
  (`@scure/btc-signer`, per `ibiza/TODO.md`); the heartbeat and `lp_sig` do NOT — they are EVM
  signatures `ethers` already produces, so **they can land first and independently.**
