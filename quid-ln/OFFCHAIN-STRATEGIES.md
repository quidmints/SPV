# QU!D off-chain strategies & architecture

The off-chain half of QU!D is the **LN↔EVM bridge**: the Lightning nodes + daemons that
move real BTC over Lightning/on-chain and mirror every move onto the EVM contracts, which
hold the actual accounting authority. This doc captures the off-chain *strategies* (the
how + the why) discussed and built. The EVM contracts are the source of truth; nothing
here can mint QUI or move LP funds without the on-chain checks passing.

> Status legend: **LIVE** (built + tested), **ENV-GATED** (built, off by default), **TRUST**
> (relies on the trusted hop), **RESIDUAL** (known follow-up).

## Roles & trust model

- **Hop** (`quid-hop` + `quid-bridge` daemon): protocol-operated bridge infrastructure.
  Single configured node; `OpenChannelRequest` force-closes every other peer. It is
  **TRUSTED infrastructure** (it co-signs channel ops and submits EVM mirrors) but it
  **cannot steal**: every value path also requires the LP's `lpAuth` signature + the
  Bitcoin 2-of-2 spend. Worst case for a compromised/lost hop key is **halt-not-theft**
  (no new channels/swaps), and LPs always self-exit (see below). `hopNode` is a single
  EOA (no multisig) — accepted, since it's halt-not-theft.
- **LP daemon** (`quid-bridge/src/bin/quid-lp-daemon.rs`): the liquidity provider's
  **self-hosted, non-custodial** node. The LP holds one Bitcoin key + one EVM key; it
  signs `lpAuth` over channel ops from its OWN chain view and never blind-signs. The SGX/
  managed-host/remote-signer designs were dropped — an LP runs a node anyway, so self-host
  *is* non-custodial. LPs come and go freely (free entry); the protocol is hardened so a
  malicious LP can't over-mint or steal another LP's proceeds.

## Swap-in (BTC → USD) — LIVE

Seller sends BTC over Lightning (protocol is the LN *receiver*; it generates the preimage);
the EVM credits USD.

- **Settle-then-claim**: USD is delivered on-chain *before* the BTC HTLC is claimed, with a
  **CLTV-headroom gate** at emit AND a live-tip re-check at settle (`event_handler` +
  `swap_in.rs`). Both fail **safe** — a tip-read error DEFERS, never settles blind; if
  headroom eroded, the HTLC is failed back (no USD out). So the protocol never delivers USD
  for BTC it can no longer claim in time.
- **Restart durability / dedup**: the in-flight swap-in is persisted *before* settle
  (`store.add_inflight_swapin`, fsync); a boot re-drive finishes a crashed swap-in (this
  LDK doesn't re-emit `PaymentClaimable`); re-settle is idempotent via on-chain
  `swapInUsed` → `AlreadySettled` → claim.
- **On-chain swap-IN rail**: was scaffolded (`settleSwapInOnchain`) with **no driver** —
  **PRUNED** (commit in `70e03e1`). Not a shipping rail.

## Swap-out (USD → BTC) — rail A LIVE, rail B ENV-GATED

Two rails, both starting from `requestSwapOut*` on the EVM (records the obligation in
`netDeliveredBtc`/`swapUsdBtc`, a shared cross-channel proceeds pool):

- **Rail A — Lightning** (`swap_out.rs`): the swapper is the LN receiver; the hop pays a
  BOLT11 from pooled liquidity. **LIVE.**
- **Rail B — on-chain** (`swap_out_onchain.rs`): the hop drives a splice-out from an LP's
  channel paying the swapper's Bitcoin address; settled via `deliverSwapOutOnchain`.
  **ENV-GATED** (`QUID_SWAPOUT_ONCHAIN`, off by default).
- **Dispatched-marker dedup**: the durable `store.dispatched_swap_outs` marker is set
  atomically with `add_inflight` *before* the irreversible pay, kept past the inflight
  drop, cleared only on failed-dispatch — the restart double-pay guard (LDK's
  `PaymentId==hash` is the last-resort backstop). Replaced the historical `swapOutUsed`-
  misread bug.
- **Reversal** (`store.run_reversal_retry` + dead-letter API): an undeliverable swap-out
  returns the swapper's USD via `settleSwapIn(paymentHash=swapId)`; deliver and reverse are
  mutually exclusive on-chain (`swapInUsed[swapId]`), capped retries → dead-letter.
- **F-1 (LP defense vs a misbehaving hop)** — LIVE (commit `13c104d`): before the LP
  splices its OWN channel BTC out for a rail-B delivery, it reads
  `pendingOnchainSwapOut(swapId)` from the EVM and **refuses unless** the swapper-script
  hash + sats match the on-chain obligation (`lp_auth_responder::verify_swap_out_obligation`
  over an injected `SwapOutObligationReader`; EVM-read impl in
  `swap_out_onchain::EvmObligationReader`, wired behind `QUID_L1_RPC_URL`). **No reader
  configured ⇒ the delivery path is REFUSED (fail-safe).** Must be wired before enabling
  rail B.

## Liquidity rebalancer (LP-side) — LIVE

`quid-hop/src/rebalancer.rs`: when a channel's swap-in forwarding capacity falls below the
per-swap ceiling, the LP **splices IN** from its own wallet to restore capacity (set-and-
forget UX). Strategy:
- **One splice per channel outstanding** — a shared in-flight set, claim-before-fire,
  released on lock or on error; the poll interval is the natural rate-limit (no cooldown
  timer, no retry storm). Does **not** overfire.
- **No auto-splice-OUT**: capital is never "idle" (it's a concentrated AMM position);
  shrinking is an LP IL/withdrawal decision, LP-initiated only.
- Few/large HTLCs + splice, not micro-payment loops (the 483 in-flight-HTLC/side cap +
  jamming risk make payment-loop rebalancing a non-starter).

## Persistent hop reconnector (LP-side) — LIVE

`quid-hop/src/reconnect.rs`: a home-hosted LP (sleep/wake, NAT idle, ISP reconnect, IP
change) would silently go offline — nothing else re-dials. The reconnector owns a single
outbound connection task and re-dials the instant it ends. No dial-storm: already-connected
→ sleep+recheck (no dial); dial-failure → exponential backoff (1s‒30s). Outbound leaf, no
NAT traversal.

## SPV relayer — LIVE

`quid-bridge/src/relayer.rs` + `header_source.rs`: feeds Bitcoin block headers (Esplora
source) into the EVM `SPVGateway` so the contracts can SPV-verify funding/close/splice txs.
The gateway validates PoW/target/median-time and clamps the difficulty retarget to
Bitcoin's ±4× consensus rule; fork-choice is per-block cumulative work. Reorg search is
clamped to `min(gateway_height, source_tip)`; gas-fit prevents OOG.

## LP fee settler — LIVE

`quid-bridge/src/lp_fees.rs`: the USD-leg of BTC-LP trading fees mints as QUI to the LP; the
BTC-leg accrues in `btcFeesOwedSats` and is **paid natively by the hop at close**. Durable
`settled_lp_fees` marker prevents double-pay across restart.

## Validating signer — LIVE (defense-in-depth on the node's OWN funds)

`quid-ln/src/validating_signer.rs`:
- **Monotonic revocation gate**: never releases a revocation secret out of forward order
  (anti revoked-state replay).
- **Closing payout-script lock** (`check_closing_payout_script`): a cooperative close that
  pays the holder must pay the committed P2WPKH shutdown script.
- These are defense-in-depth on the node's own holder output. The *protocol* defense against
  a malicious LP redirecting its CLOSE payout is LDK's `commit_upfront_shutdown_pubkey` +
  BOLT2 (the hop's LDK rejects a non-committed shutdown script); the withdrawal-splice and
  swap-out paths are pinned on-chain (see the EVM side).
- **RESIDUAL** (low, defense-in-depth): `sign_splice_shared_input` is non-fallible (no
  policy Err path); `release_commitment_secret` isn't cross-checked against the
  most-advanced holder commitment after a restart. Both are own-LDK trust, not a malicious-
  LP boundary.

## Restart durability & idempotency — the cross-cutting strategy

The chain is the state. No off-chain action that moves money relies on a local journal as
the *authority*:
- Swap-in/out re-drives read on-chain `swapInUsed` / `pendingOnchainSwapOut` as the truth;
  durable markers (`dispatched_swap_outs`, inflight, `settled_lp_fees`) are *dedup hints*,
  fsync'd before the irreversible action and pruned below a monotonic cursor.
- The channel reconciler recomputes each channel's on-chain `channelId` from the STABLE
  original funding outpoint (survives splices), reads `channels(channelId)`, and skips if
  never-opened / already-closed / `amount_sats >= new_total` (splice already applied) — so a
  re-scan or restart can't re-fire an op that already landed. An RAII in-flight slot
  (shared by the event path + reconciler) prevents concurrent double-drive.

## Known residuals / follow-ups (off-chain)

- **F-2** (LOW): the hop doesn't pre-assert the splice pays `swapper_script` before
  submitting `deliverSwapOutOnchain` — the on-chain check catches it (just burns a doomed
  tx). Fail-fast pre-check would be nicer.
- **F-3** (LOW): post-restart revocation-secret cross-check (above).
- **Separate relayer key** (RESIDUAL): the SPV relayer shares the operator key; a tiered-
  ceiling + relayer-defer mitigates without a second key.
- **External watchtower** (RESIDUAL): channel breach protection currently relies on the
  node being online; an external watchtower is the production hardening.
- **Rail B (on-chain swap-out)**: needs the LP daemon's `QUID_L1_RPC_URL` wired (F-1) AND a
  real bitcoind/esplora e2e before `QUID_SWAPOUT_ONCHAIN` is enabled.
