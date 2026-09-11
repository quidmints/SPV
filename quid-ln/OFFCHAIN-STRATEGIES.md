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
- ⛔ **THE LP DAEMON IS DELETED (§NO-SELF-PROVISIONED-LPS, owner 2026-09-11) — "there are no self
  provisioned lps".** `quid-bridge/src/bin/quid-lp-daemon.rs` and `deploy/run-lp.sh` are gone
  (`8faddbb1`), and with them `quid-bridge/src/lp_seed.rs`, whose whole premise was phase 1b making
  the LP the sole holder of its seed. **There is no self-host path. Do not restore one from this
  file's history.**
  🔴 **WHAT FOLLOWS, AND IT IS THE THING TO KNOW BEFORE READING ANY "the LP self-exits" CLAIM
  ANYWHERE:** the fleet holds **BOTH halves** of every channel's 2-of-2, and its vault seed is
  `derive_vault_seed(&root_seed)` — an HKDF **sibling** of the hop seed. That is not two keys on one
  box; it is **one key wearing two hats**, so no key-separation control reaches it. ⇒ **the multisig
  is nominal by design and the enclave is the whole of the protection.** Every exit, ladder and
  splice policy is a guarantee by a party that can already spend the funding output outright.
  ⚠️ **The `QUID_FLEET_COHOSTS_VAULT` knob is gone too** — with no LP daemon it had one reachable
  value, which is a lie about the deployment and a variable rule 23 forbids. The vault boots
  unconditionally.

  > ⛔ **THE ⚠️ "CORRECTED 2026-08-01" BLOCK THAT USED TO SIT HERE IS DELETED: IT CITED THREE SYMBOLS
  > THAT DO NOT EXIST IN THE TREE.** `grep evm/src` returns **zero** for `registerDelegation`,
  > `hopRegistry` and `delegatedAuthority`. It described an LP signing "ONE cold EIP-712 delegation,
  > relayed gaslessly, and then running NOTHING", with `delegatedAuthority` resolving to "a concrete
  > hop (family/self-host) or the Safe-governed `hopRegistry`". **None of that is buildable now:**
  > there is no delegation registry, and hops are two IMMUTABLE addresses (`MAIN_HOP`/`FALLBACK_HOP`,
  > `BTCChannels.sol` §E164) precisely so no registry can grant itself channels. The Safe is gone as
  > well (owner: *"we are not using a Safe anymore, just a simple msig"*).
  > ✅ What survives is `lpAuth` (7 references in `BTCChannels.sol`) and `btcRecipientOf` being
  > **pinned and LOCKED** at open, so a fully compromised hop can still only pay the LP — that
  > property is real and is enforced on-chain, unlike the delegation machinery around it.

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

Two rails, both starting from `requestSwapOut*` on the EVM, which records the obligation
PER-OBLIGATION in `Core.pendingSwapOutUsd` (the swapper's actual USD is pinned at request and paid to
the delivering LP at `deliverSwapOutOnchain`).

> ⚠️ **CORRECTED 2026-08-01:** this used to say the obligation lands in `netDeliveredBtc`/`swapUsdBtc`,
> "a shared cross-channel proceeds pool". That machinery and its clamp are GONE (`Core.sol:765-770`,
> `BTCChannels.sol:466-470`), so there is no shared pool to race over. Note `BTCChannels.sol:966-978`
> still describes the old pool in a comment and contradicts `:467` in the same file.

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

## Persistent hop reconnector — LIVE (§A.5g)

`quid-bridge/src/daemon.rs` (task in the daemon `JoinSet`) + `VaultNode::ensure_hop_connected`
(`quid-bridge/src/vault.rs`): LDK's `PeerManager` owns sockets but never re-dials, and the
vault's startup dial is one-shot — so a dropped vault↔hop link stayed dropped and every
channel op failed until a restart. The task re-checks every 30s; `ensure_hop_connected` is a
no-op while connected (a peer-table lookup), so there is no dial-storm, and
`MissedTickBehavior::Delay` prevents a backlog of dials after a stall. Warns only on a FAILED
re-dial. Outbound leaf, no NAT traversal.

> **CORRECTED 2026-08-01.** This section previously claimed `quid-hop/src/reconnect.rs`
> **which never existed** — the only caller of `connect_peer_if_necessary` was the TEST
> harness, so in production nothing re-dialled. The doc asserted a component that was not
> wired, which is exactly why §A.5g went unnoticed. Two code comments made the same claim
> (`vault.rs` *"the reconnect path will retry"*, `p2p.rs` *"a race between the reconnector
> and open_channel"*); both are now TRUE.

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
