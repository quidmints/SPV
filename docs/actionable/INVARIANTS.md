# INVARIANTS — the Echidna target list

Requested 2026-08-12: *"list all the invariants for echidna … so we can reduce the quantity
of tests by instead making them verify more conditions."*

**The point is leverage.** A unit test asserts one transition from one state. An invariant
asserts a property over *every* state the fuzzer can reach. The repo's own history says a
green suite is what an unreached state produces — §E-defects-live-at-boundaries found three
defects in one function that passed every gate, and a single corner sweep would have caught
all three. **Each invariant below should retire several example-based tests.**

⚠️ **AN INVARIANT MUST BE MEASURED INDEPENDENTLY OF THE CODE IT CHECKS.** Three guards once
missed a zero-delivery bug because each read a number produced by the failing code; only an
independently measured balance delta caught it. Prefer token `balanceOf` / supply reads over
protocol accumulators.

⚠️ **AND ECHIDNA NEEDS A STATIONARY BASELINE.** Fuzzing against a moving baseline cannot
distinguish a real break from drift, so any invariant below that references a *rate* must be
stated against a snapshot taken in the same call.

Status legend: **[A]** asserted somewhere today · **[U]** unasserted anywhere.

---

## 1. Supply ↔ backing conservation

- **[U] `Σ_lp levPooled[lp]` READ ON THE BTC RANGE `== VBtc.totalSupply()`** at all times.
  One line; drift is a double-spend of the levered slice. (Queue §A10 — *"UNASSERTED
  ANYWHERE"*.) **Highest value on this list.** ⚠️ **This read `levPooledBTC` until 2026-08-23, and
  that name has ZERO references in `evm/src` — it was RENAMED, not removed.** The suffix went when
  the ranges became two INSTANCES of one implementation, so `levPooled` on the BTC instance IS what
  `levPooledBTC` named: same slot, same meaning, different address (`DeployLib.sol` constructs
  `new Core(cfg.weth,…)` and `new Core(cfg.wbtc,…)`). **Whoever writes this invariant must bind the
  BTC instance explicitly — reading the ETH instance's `levPooled` against `VBtc.totalSupply()` would
  compare two different ranges and is the successor to exactly the bug this line guards.**
  (`VBtc.totalSupply` re-verified live at `VBtc.sol:75`, moved at `:148`/`:155`.)
- **[U] `Σ registered BTC positions == Σ confirmed funding UTXO value`** — the account-vs-UTXO
  pair §E179 exists to audit. Any divergence is phantom backing.
- **[U] QU!D supply never exceeds solvent basket value + immature projections.** Mint sites
  are enumerable; a fuzzer that mints/redeems/swaps should never break it.

## 2. Channel lifecycle

- **[U] A channel is OPEN ⇒ its funding outpoint is unspent** (or a retire path has run).
  This is §E107's property generalised: the fix added `recordDeadManExit`, and the invariant
  is what stops the *next* unretirable-close class rather than that one instance.
- **[A] One open channel per `lpEth`** — `hasOpenBtcChannel`. Already guarded; assert it
  survives arbitrary open/splice/close interleavings.
- **[U] `checkpointOf[cid]` ≤ what the armed exit actually pays** — §E165-b enforces this at
  arming; as an invariant it also covers splices that move the balance afterwards.
- **[U] A funding outpoint backs at most one channel, ever** — `_useOutpoint`. State it over
  reorg/replay sequences, not just one call.

## 3. Payout destination

- **[A] Every BTC-paying path pays `btcRecipientOf`** — close, splice-out, dead-man exit.
  Now also swap-out (§E184). **As an invariant this retires several per-path tests.**
- **[U] `btcRecipientOf` is never zero for an address with a live obligation.**

## 4. Swap-in / swap-out

- **[U] Credited sats ≤ sats provably paid to the derived deposit address.** ~~⚠️ Only holds on
  the proven path — **T1 says the unproven `settleSwapIn` still exists**, so this invariant
  is *how you would detect* that trapdoor being used.~~ ✅ The on-chain deposit rail now settles
  through `settleSwapInProven` (§T1-c), so it holds there; the LN rail is the remaining hole.
  🔴 **RE-RUN 2026-08-23 @`7e32eb48`: THE UNPROVEN `settleSwapIn` NO LONGER EXISTS.** `BTCChannels.sol`
  declares exactly two: `settleSwapInBuffered` (`:1417`) and `settleSwapInProven` (`:2059`); `:2138`
  records the removal — *"REPLACED, not merely removed: `parkProvenSats` + `settleSwapInBuffered`"*.
  **So the trapdoor this invariant was to detect is closed by construction, and the invariant's JOB
  changes rather than disappearing.** ⚠️ **The LN hole is still open and is now a DIFFERENT shape:**
  `settleSwapInBuffered`'s supply side is `parkProvenSats` (`:1375`), which has **zero production
  callers** — no `SIG_PARK`, no `evm_codec` calldata builder, only two Rust comments
  (`quid-hop/src/evm_codec.rs:118`, `swap.rs:31`), against the positive control that
  `settleSwapInProven` IS wired (`evm_codec.rs:110`, `client.rs:667`). So the buffered rail reverts
  `InsufficientProvenSats` on the first real LN swap-in. ⇒ **Fail-safe, not a leak — the invariant
  cannot be violated on a rail that cannot execute, and it becomes live the moment `parkProvenSats`
  is wired.** State it now; it is the acceptance test for that wiring.
- **[U] `Σ swap-in credits issued ≤ Σ SPV-proven sats spliced into custody`, per hop.** 🎯 This
  is the whole of §T1-e-r stated as one property, and it is the reason that design needs no
  bond: if it holds at every moment, **no credit was ever issued against sats that were not
  already in custody** — which is exactly what the unproven entrypoint cannot promise. Note it
  is deliberately a RUNNING-TOTAL inequality rather than a per-swap match: sats are fungible, so
  the invariant is about the balance, not about which coins settled which swap.
- **[A] Deposit dedup is on the outpoint, not a hop-chosen hash** (`swapInUsed[txid]`).
- **[U] `swapOutUsed` and `swapInUsed` never both hold for one id** — the strand that would
  make a swap both undeliverable and unreversible.

## 5. Signer policy (Rust-side; property tests, not Echidna)

Listed for completeness because they are the same *kind* of claim:
- monotonic commitment index; never re-sign a revoked state
- one nonce signs exactly one message (§E176-D: **the in-memory guard does not survive a
  restart** — the invariant must be stated across restarts, which is why it needs the
  on-chain freshness anchor)
- `NotRecorded → Match` is one-way (§E177-e)

## 6. Decimal bases — the repo's most common bug class

- **[U] No value crosses 6/8/18 without an explicit conversion.** CLAUDE.md records a
  positional divisor (`i < 4 || i == 11 ? 1e12 : 1`) that shipped and broke when a 6-dec
  stable joined at a later slot. A fuzzer that varies the stable set catches that class.

---

## Wiring notes

- Echidna needs a **deterministic** deployment; the fork-dependent venues will have to be
  stubbed or the run pinned to a block. ⚠️ `FOUNDRY_RPC_ENDPOINTS_MAINNET` is silently
  ignored here — use `ETH_RPC_URL`, and a pinned block **requires** the archive endpoint.
- Start with §1 and §2. They are the ones where a violation is **silent** — the failure
  announces itself nowhere, which is exactly the discriminator for a check earning its place.
