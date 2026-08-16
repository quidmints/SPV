# BTC CUSTODY — WHAT IS STILL OPEN, AND WHY

Companion to `QUEUE.md`, not a replacement. `QUEUE.md` holds the row-level evidence; **this file
holds the state of the BTC custody work as one picture**, including items that never got a queue
row. Written 2026-08-16 at the end of a long BTC thread, because several open items are *design
forks owned by the repo owner* rather than tasks, and a fork recorded only as a row reads like
something someone forgot to do.

⚠️ **Statuses here are as-of writing and go stale.** Every claim below names the file and symbol
it rests on so it can be re-checked rather than believed — see `[[your-own-ledger-goes-stale]]`.

---

## 0. THE ONE-LINE STATE — AS CODE, NOT AS A LABEL

⚠️ **This file used to be titled §M1 and that labelling was probably mine and probably wrong**
(owner, 2026-08-16: *"M1 was finished a long time ago"*). `QUEUE.md` contains **no definition of
§M1 at all** — every `M1#1` mention in it is about the phantom-entrypoint work. So the state below
is stated as **facts about the code**, which are checkable and do not depend on whose milestone
numbering is right.

**1. The phantom credit entrypoint is gone, on both sides.** `settleSwapIn` is absent from
`evm/src` and from all six Rust client sites that outlived it.

**2. In the CO-HOSTED fleet deployment, one custodian holds both halves of every 2-of-2.**
`bin/quid-bridge-daemon.rs:339` still calls `derive_vault_seed(&root_seed)`, and `vault.rs` states
the consequence itself: *"one custodian, one secret"* (`:59`) and **"SO THE 2-of-2 IS NOMINAL IN
THIS DEPLOYMENT, AND NOTHING SHOULD CLAIM OTHERWISE"** (`:65`).

**3. The split is now POSSIBLE but is a deployment choice, not a code gap.** `quid-lp-daemon`
(landed 2026-08-16) boots the same vault with a seed the fleet cannot derive, against a remote
hop. Whether it is *used* is a topology decision — see §2.1.

---

## 1. LANDED THIS THREAD (do not redo — each has a queue row with evidence)

| area | what landed |
|---|---|
| the phantom entrypoint | `settleSwapIn` gone from contracts **and** from all six Rust client sites |
| vault-less fleet (phase 1a) | `daemon::run` takes `Option<VaultNode>`; fleet can run vault-less |
| LP-hosted vault (phase 1b) | `bin/quid-lp-daemon.rs` — LP-hosted vault against a remote hop |
| defect | `boot_vault` accepted `hop_addr` then dialled hardcoded `LOCALHOST` — the actual 1b blocker |
| §W1 | sweep authorization folded into `quid-migrate-auth` + the authorized trigger (`QUID_SWEEP_AUTH`) |
| §E172 follow-up | orderly quiesce (`await_quiescent`) so an LP departs with nothing in flight |
| client gate | `check-client-abis.py` rebuilt (ghost artifacts, Rust ORPHAN, events, noise) — 12 findings → 0 |
| delegation | `registerDelegation`/`delegation_digest` encoders deleted; `delegationVersion` was a LIVE `BAD_GATEWAY` |
| accounting | `Core.subPendingSwapOut`'s `Math.min` deleted (measured unreachable); 3 ledger pairs audited |
| resource | deposit-watch window — an unfunded onboard no longer polls esplora forever |

---

## 2. OPEN — OWNER DECISIONS (these are FORKS, not tasks; nobody should "just do" them)

### 2.1 🔴 §E172 — does the vault↔hop channel keep FORWARDING?
**Everything on the exit/ladder seam is downstream of this.** §E172 measured
(`quid-hop/src/rebalancer.rs:32-35`) that the channel is a live routing channel, so **every
swap-in is a commitment update needing the LP-side funding signature** — not merely every splice.
Two duties with different latencies:

* **per-HTLC commitment updates** — continuous; a payer does not wait for a check-in window;
* **consent + exit arming** — occasional, latency-tolerant, phone-shaped.

**A phone can do the second and cannot do the first.** Owner chose **option (c)**: the LP is
online sometimes, swap-ins route only then, and the channel quiesces before departure — the
quiesce is built. **What is still undecided is whether the channel should forward at all**, which
determines whether the ladder is the escape or a vestige.

⚠️ The offline failure mode is **degraded service, not loss** — an HTLC simply cannot be added.
The one exception is in-flight HTLCs at departure, which is exactly what the quiesce handles.

### 2.2 🔴 Routing-fee ATTRIBUTION (pool-wide vs per-channel)
Mechanics are settled and need no new rail: **fees are not paid out at all** — they compound into
the position (`BtcVaultLib.feeCompounded` → `Vault.sol:543` `lpSharesBTC += feeCompounded`) and
settle at resize/close. The **credit calculation** is
`weight = LP.pooled + levBufBTC[lp]`, `owed = weight × accumulator / WAD`, `reward = owed − bookmark`,
denominator `lpSharesBTC + totalBufferBTC`.

**The fork:** V4 swap fees are pool-wide pro-rata; routing fees are earned by ONE channel's
liquidity. Socialising them makes the LP whose channel routed everything subsidise those whose
channels routed nothing. Precedent exists for either shape — the levered buffer "earns V4 fees but
is UNWIND-ONLY", so this codebase already separates *what earns* from *what can leave*.

⚠️ **Nothing accrues yet:** routing fees are absent **by design** — `announce_for_forwarding`
defaults `false` and is never overridden, so the node is unannounced and unroutable. This decides
a revenue stream that does not exist, rather than one going unaccounted.

### 2.3 🔴 LP seed ENTROPY shape
Production is **already not deterministic** (`seed.rs:390` `SysRng` = `ring::SystemRandom`).
Owner asked for device randomness mixed with chain-native randomness. **Chain randomness is
PUBLIC and therefore cannot add secrecy** — if the device RNG is predictable, `H(device ‖ chain)`
is too. What it genuinely buys is **freshness/anti-collision**: identical images, thin first-boot
entropy, and VM snapshots are real LP-box failure modes and a beacon fixes them. If the threat is
a weak device RNG, the answer is an independent **private** source (user entropy, or generating
from a user-supplied mnemonic). Recommended: `HKDF(os ‖ user ‖ beacon)` with each term's job
documented, and the mnemonic kept as the system of record.

---

## 3. OPEN — REAL WORK, BLOCKED ONLY BY §2.1

* **`exitArmedAt` reports `true` for rungs that cannot confirm.** A splice rotates the funding
  outpoint (documented at `BTCChannels.sol:301-302`), pre-signed rungs then spend a spent output,
  and the map is never cleared. **Not exploitable** — `recordDeadManExit` needs a *confirmed* tx —
  but it is a security-relevant flag that is silently false. Fixing it is correct under every
  branch of §2.1.
* **per-channel freshness per-channel freshness (phase 3)** — not started. It changes *what an exit commits to*
  (`Prevouts::All` binds the freshness UTXO), so it must not be designed against a rung model that
  §2.1 may invalidate.
* **Phase 4 lazy `openChannel`** — not started; reuses §T1-f's custody/claim seam.

---

## 4. OPEN — NOT TRACKED ANYWHERE ELSE (the reason this file exists)

1. **The regime brain has two classifiers and the shared one is unused.**
   `spa/src/lib/regime.ts` documents itself as source-agnostic and says the LP-facing regime "must
   COMBINE" internal-pool and external-market sources because pool state alone is circular.
   `lib/market.ts` grew its own `marketRegime` and does not import it. `fetchRegime` /
   `classifyRegime` / `decodeTwapTicks` have **no caller**. ⇒ Wire it into the combination, or
   delete it and drop the framing. Leaving it reads as a live half of a combination that does not
   exist. **Do NOT wire it into the keeper** — the keeper's dwell gates on the position's own LTV,
   which is the right basis for an action whose cost is that position's gas.
2. **`quid-bridge-daemon` / bin-target `E0463` is a FLAKE.** Two sightings, both self-clearing on
   an immediate re-run with no code change. **Re-run before diagnosing**; do not attribute it to
   the last edit.
3. **The secp256k1 lever is a HYPOTHESIS, not a result.** Bitcoin and the EVM share the curve and
   this repo already pays for on-chain EC (`MuSig2Agg`, the `KeyAgg` gate, ~631k gas), so an LP
   could prove control of its channel half **by signature, verified on-chain, with no third
   party**. ⚠️ Unverified: nobody has checked *which entrypoints actually run that gate* or whether
   any establishes **control** rather than key **equality**. §E165's ladder proves control; the
   plain path does not. Settle that before building recovery on it.
4. **ERC-7947-style recovery is ruled out for `lpEth`, and the reason generalises.**
   `_lpPayoutScript` derives the BTC payout script FROM `lpEth`, so a rotatable `lpEth` lets
   whoever compromises a recovery provider redirect payouts — the cross-LP theft ibiza rejected,
   arriving via the EVM side. **The durable test for any custody/recovery proposal: does it let
   anything other than the LP's own secp256k1 key move where value lands?**
5. **LOSS and UPGRADE are different failures.** `migration.rs`'s k-of-n cannot serve recovery
   because it is the OLD ENCLAVE that exports — no old enclave, no migration. Any recovery
   proposal must say which of the two it addresses before it is worth evaluating.
6. **The v4 purge branch is NOT merged.** `SPV-v4cut` is a worktree of this repo on a divergent
   branch, **31 commits ahead of `main`, with `main` 73 ahead of it**. `main` still has ~111 code
   references to `TickMath`/`LiquidityAmounts`/`sqrtPriceX96`. A read-only `git merge-tree`
   preview shows the merge is **essentially clean (1 conflict marker)** across 12 overlapping
   files. ⚠️ **It was mid-purge with six uncommitted files at the time of writing — merge only
   when that tree is clean, and by whoever owns it.**
   ⇒ **Consequence for the SPA regime fix:** it converts price-cumulatives into TICK units using
   `LN_1_0001`, calibrated against `CHOP_TICKS = 200`. Correct against today's `main`; **re-check
   at merge**, because the purge removes the tick vocabulary it is expressed in.
7. **`LeveragePnLProbe::testLeverage_LvrControlVsTreatment` is a TEST defect, not a leak** (skew
   thread's measurement, twice-corrected): the control arm redeems fully and the treatment arm
   partially, and only what *leaves* the redeem is valued. Fix the comparison — value the retained
   shares or force both arms to redeem fully. Left red deliberately.

---

## 5. THE PATTERN THIS THREAD KEPT HITTING (worth more than any single item)

Five corrections landed, **four of them mine**, and all the same shape: **a conclusion built on
one line read in isolation, when the surrounding lines or a prior row already said otherwise.**

* the ladder "splice invalidates it" finding — documented three lines above the block quoted;
* the freshness-anchor "blocker" — refuted by `freshness.rs`'s own header;
* "the regime brain has zero consumers" — the *type* was imported under another name;
* "BTC fees are WBTC held by the pool" — `Vault.sol:109` names a **unit**, not a location;
* citing a keysend as the delivery rail — three comments describe it, **no implementation exists**.

⇒ **Read the neighbours before concluding, and grep `QUEUE.md` for prior coverage before writing
anything up.** Both cost seconds. Everything caught this thread was caught by running or reading
something; everything wrong was reasoned to.
