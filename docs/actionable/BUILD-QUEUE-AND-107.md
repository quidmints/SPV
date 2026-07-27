# Master agenda — audit findings + build queue + #107 derivations + locked decisions

> **📌 WORKING POLICY (user, 2026-07-24): THIS FILE IS THE WORK LOG.** Track EVERYTHING done here — every build, edit-set (files touched + one-line rationale, NOT the diffs), realization, decision, and open question — as it happens, so nothing is lost to compaction. Keep on-screen chat CONCISE: do not paste edits/diffs/code on screen; point to the file section instead. A realization not built the same turn MUST be written here immediately (see memory `feedback-record-realizations-before-compaction`). **Keep the SESSION STATUS block below CURRENT** — it is the live cross-thread dashboard.

## 🟢 SESSION STATUS — live dashboard (update every turn; 2026-07-24)
| Thread | State | Detail |
|---|---|---|
| **#113 ETH swap-out de-lever** | KEEP (user); core DONE, forge-UNVERIFIED | Decided KEEP (net-equity banded; de-lever unlocks Morpho collateral, keeper re-levers = wash+fees). DONE this turn: deleted `fundVenueForDelever` + `takeToSettle` called DIRECTLY (Vogue IS auth); **added `swapOutDeliverUnlevered` 0-debt branch** (the HODL slice — no repay/no backing hazard); docstrings fixed. **Remaining:** `DeleverEthBackingProbe` (fork-verify levered QD-burn path) + purge arbETH tombstones. §M.1. |
| **#114 BTC dead-man exit** | ✅ BUILT + security-reviewed (forge/BTC-broadcast unverified) | Full daemon done: sign-in-place (funding key NEVER exported — verified), 2-signer orchestrator, rust-bitcoin exit builder, `emitDeadManExit` encoder, heartbeat task (spawned), keyless `quid-recover-exit` broadcaster CLI + SPA link. 108+ tests green. **Residual (fail-safe): spliced channels unprotected** (splice-parent scope not wired → invalid-but-non-broadcastable sig). Big-box/testnet: on-chain BTC acceptance. §N. |
| **#115 simplification sweep** | TIER-1 EXECUTED (partial) | ✅ DONE: 3 dead internals + dead vBTC roundtrip (mintVBTC/burnVBTC + BtcVaultLib bodies) + unused bandEthOf/bandBtcOf iface decls + `debtUsd` dedup (routed to `LevMath._toUsd18`, DRY/bytecode-neutral). SKIPPED: `swapOutDeleverAmt` dedup (needs a new LevMath fn — can't verify vs the stack-too-deep WIP) + `_trackOpen`/set-primitives (invasive, follow-up). `vbtcTransfer`/`vbtcTransferFrom` + concrete `bandEthOf/Of` untouched. |
| **✅ WHOLE EVM SESSION SOLC-CLEAN (2026-07-24)** | targeted per-contract solc, all exit 0 | After the LevMath fix: `LevMath` + `LevManager` + `BtcLevManager` + `SwapLib` + `BtcVaultLib` + `Vogue` + `Vault` ALL compile clean (project optimizer/evm, solc 0.8.35). So the #113 ETH de-lever chain + #115 deletions + the IAux*→IAuxM refactor state are mutually solc-clean. STILL forge-UNVERIFIED (behavioral) — that needs the big box. NOTE: single-file solc needs the FULL v4 remapping set (`v4-core/`+`v4-periphery/`+`permit2/`) or Vogue/Vault throw phantom "IPoolManager→IPoolManager" dup-type errors. |
| **✅ COMPILE BLOCKER FIXED (2026-07-24)** | LevMath compiles clean | The `LevMath.sol` `extractToVaultBody`→`sellColl` **stack-too-deep is RESOLVED**: extracted the sell+return-flash+route-surplus tail into a new `_sellAndRoute` frame (drops `lp`/`venueAddr`/`extractUsd` from co-living with the sell). Verified via targeted solc compile (one library + imports, NOT full forge) → **exit 0, no stack-too-deep**, only benign natspec/shadow warnings. Caveat: ran on solc 0.8.35 (pinned is 0.8.30 — not local); fix is structural/version-independent, re-confirm on 0.8.30 at big-box. |
| **Short subsystem** | 🧭 OPEN (anchor) — removal MAYBE premature | Per memory `yb-shortleg-open-question`: committed `_growShort` BAND-SELLS (skew internal, NOT external-DEX leak) ⇒ Milionis IL≤LVR doesn't cleanly apply ⇒ net-vs-hold = unresolved SIM question. I flip-flopped 5×; anchor. Code removed this session; RESTORE = user's call. See §J.4. |
| **Comment purge** (user) | PARTIAL | Vault:369 docstring gone (fundVenueForDelever deleted); deleverEthOnDelivery docstring fixed. REMAINING: arbETH tombstones Vault:430 / SwapLib:125 + swapOutDelever/collToWethDeliver/_sendETH "NOT arbETH" clutter. §O.2. |
| **#12 drop-voting** | DONE (EVM + SPA) | EVM vote subsystem deleted (Basket −126 lines); SPA vote surface removed (abi.ts/page.tsx + hidden mint-gate), ComfortPanel cushion intact, tsc green. §O.3-B. |
| **BUILD QUEUE (user: build all, no Echidna, verify later)** | SEQUENCED (uncommitted ⇒ no worktrees ⇒ main-tree only ⇒ can't parallelize overlapping EVM) | 1) **§J.3 JIT flash-refill** (EVM callback @Vault:935 + Rust keeper). 2) **#59/#74 native BTC de/re-lever rail** (Rust lev_keeper_btc:196/212 — AFTER #114 daemon lands, shared daemon.rs). 3) **#12 unify-POOLED_USD** (Core.sol:91/93 mirror same dollars, count once in committedUsd18, drop sum-cap — no Echidna). 4) **#113 DeleverEthBackingProbe** + arbETH purge. 5) **#115 safe simplification wins** (§O.1). — **5b) 🔴 §J.8 weETH-on-Aave-v4 yield leg gated on Rover instant-convertibility** (user, 2026-07-26): venue 2 supplies **weETH** (the asset that hub actually lists — reserveId 2) sized to Rover's guaranteed instant weETH→WETH capacity; SPA surfaces the capacity + takes an explicit `withdraw`(wait-NFT, free) vs `exitInstant`(0.3%) opt-in when an exit would exceed it. Opt-in machinery + offramp rungs ALREADY exist (reuse, don't rebuild); "balanced" is client-side derivable from public Rover reads with NO new Solidity. Open user call: deposit-time cap vs withdraw-time check. — **6) ⚪ OPTIONAL / OPT-IN (NOT part of "build all"): EigenLayer AVS overlay (§W).** Split the two halves, they are not the same ask: **W.0** (hostable keyless watchtower — **NO EigenLayer at all**, cheap, the CLI broadcaster already exists) closes the §N watchtower flag + the `PRODUCTION-LAUNCH.md:79` box and is the real "runs without EL" liveness guarantee — take it whenever a slot is free. **W.1–W.4** (the ACTUAL AVS) build **ONLY if the decentralization endgame is explicitly bought** — it buys nothing W.0 doesn't, except removing the foundation as assumed watchtower operator and making liveness crypto-economically guaranteed. Never auto-promote it into items 1–5. |
| **EigenLayer AVS overlay** (user, 2026-07-25) | ⚪ OPTIONAL — queue item **6** (opt-in; §W) | HARD INVARIANT: all SPV-folder Rust runs WITHOUT EL (as today) **and** optionally WITH it as an AVS operator. Feature-gated `quid-avs`, **zero core dep** (`cargo test` EL-off must pull no EL crates). Anchor = the dead-man broadcaster (§N): secret-free + SPV-provable slashing ⇒ the one clean candidate. PROOF-based not BLS ⇒ Rust not eigensdk-go. QUI OUT of the bond (reflexive); exogenous ETH/weETH. **W.0** (hostable keyless reader, NO EL) closes the §N watchtower flag first; AVS = decentralization endgame, build only if explicitly bought. |

Plan of record (2026-07-21), reconstructed from the full pre-compaction transcript + a codebase existence
check. **The code (not this doc, not memory) is ground truth — verify each item at its mutation-sites before
acting.** Anchor every claim to HEAD; never to comments or recall (the θ-clamp exemplar fooled two agents by
comment). Status tags: 🔴 open · 🟡 partial/needs-verify · ✅ done · 🧊 deferred-by-design (reconcile before reversing).

**STANDING LAW (applies to every item below):** maximize elegance and REUSE (mirror/extend proven code — BDK/LDK/solmate/Avellaneda-Stoikov/existing libs — never hand-roll); on every touch, hunt dead code + constant/logic dedup opportunities and remove them; and harden security against every conceivable attack surface (donation/inflation, reentrancy, oracle-manipulation, MEV/ordering, griefing, authority mis-scoping). Never add a stub unless it's implemented all the way. Do NOT list dropped/done items — code-verify status before adding anything here.
- **CONSULT THE DISCUSSION FIRST.** Before implementing ANY item, read its entry in `DISCUSSION-DIGEST.md` (and grep the transcript) — honor the AGREED design, never re-derive from code and over-correct. Verify the INTENTION of existing code before changing it; only change what improves it beyond a shred of doubt; prefer a reorder/simplification/deletion over added code.
- **DOUBLE-INTERPRETATION RECONCILIATION.** When an empirical result conflicts with the recovered discussion/memory, or two readings of intent exist, SURFACE and reconcile it (fork-test it — empirics over docs — or ask), NEVER silently pick one. (Exemplar: #4 CAPO — fork proved Aave-V4 donation-immune, contradicting a recovered concession; resolved by testing + the user confirming the vector meant.)
- **ADJACENT-ADVERSARIAL-FLOW TESTING.** When testing/implementing one code path, ALSO exercise the flows it is adversarially/contextually related to (a swap path ↔ its redeem/mint/de-lever/refill neighbors that share pools, backing, or ordering) — the code comments hint at these couplings; follow them. Never test a function in isolation from the neighbors that can race, drain, or subsidize it.
- **RECORD DEFERRED NOTES IMMEDIATELY.** Any time you say/think "I'll surface X later / get to Y / follow up on Z," WRITE IT into the DEFERRED NOTES list below in the same turn — never leave a promise only in chat, where it evaporates (this is how the doc-generator + others got lost).
- **SURFACE-BEFORE-CUTTING for consequential changes.** Distinguish a clean/unambiguous change (implement it directly, then verify) from one with real consequences to WEIGH — opens an attack surface, ripples into another subsystem, reverses a prior decision, or changes economics. For the latter, bring the analysis + consequences to the user and get their call BEFORE implementing, not after. (E.g. baseRate removal = clean → done directly; concentration-fee removal = opens cherry-pick + ripples into SOR path-selection → surface first.)
- **CHECK OFF AS YOU GO.** The moment an item is committed or resolved, update its status tag in THIS doc in the SAME turn — ✅ DONE + commit hash (or ❎ invalid / ⚠️ needs-intent) — and rewrite the fix cell to what was actually done. Never let committed work keep showing 🔴 open (that lost #1/#7/#8 for a while). Periodically reconcile the doc's tags against `git log` so a fresh thread's "skip the green ones" is trustworthy.
- **APPLY EASY WINS ON SIGHT.** When you notice a clearly-better form — dedup/unify two divergent paths onto one principle, simplify, delete — that improves READABILITY, apply it in the same turn; don't defer it. And when you unify, DEFINE the concepts in the comment (what each quantity IS — e.g. "HEADROOM = backing − pooled", "θ = avgYield/(K·σ²), the risk budget") so the unified code teaches its own principle. (Exemplar: #8 closed by extracting `SwapLib.clampByBacking` used by the ETH band + BTC add + BTC reseat, not by asserting "the skip is sound".)
- **HUNT FOR SHARED-PRINCIPLE UNIFICATION (determinism).** Periodically scan for an economic quantity/rule computed in MORE THAN ONE place with divergent forms (backing, fee, skew/premium, headroom, de-lever sizing, gross-vs-net weight, LTV/target, pooled accounting…) and unify it onto ONE well-defined helper — a deterministic design must give the same quantity the same value everywhere, or the divergence itself becomes an exploit surface. Before unifying, confirm the divergence is NOT an intentional asymmetry (verify-intent rule — e.g. mint-par vs redeem-basket-share must STAY divergent). Then unify + define the concept in-comment. First-class recurring task (see "Unification scan" U-section).
- **🔴 STANDING RULE — FINISH THE IN-FLIGHT ITEM 100% BEFORE STARTING ANYTHING NEW (user, 2026-07-26).** Verbatim: *"if I INTERRUPT YOU WITH NEW CONTEXT … don't forget your last action item, and handle that item first before doing anything so it doesn't get forgotten (complete anything you are working on fully 100% before starting a new task)."* A mid-turn message adds to the queue, it does NOT replace what is in flight. Concretely: finish + verify the current change, THEN take the new item. When an interruption arrives, restate the in-flight item so it cannot be lost, and do not report a task done until its verification actually passed (a build that compiles is not a fix that works).
  **REAFFIRMED + REFINED (user, 2026-07-26, second statement):** *"never leave loose work like this … finish things completely before moving on to any next thing. permanent claude rule … unless some information is revealed that changes how that one thing you were working on at the moment should change."* — so there is exactly ONE exit from an in-flight item: new information showing the item ITSELF should change (adapt it; that is not abandonment). Nothing else releases you, including a new user request.
  ⚠️ **Corollary — suspect STALE BYTECODE before suspecting your own logic.** The `withdraw(type(uint).max)` cap looked broken through a long arc because gas was **identical (52444) before and after adding two cold SLOADs** — physically impossible if the new code ran. `forge` was serving cached artifacts; `forge build --force` alone made `testEthVenue_Euler_FullLifecycle` pass with the source unchanged. When a measurement is *impossible* rather than merely surprising, force a rebuild before theorising.
- **🔴 STANDING RULE — FIX WHAT YOU FIND, ON THE WAY (user, 2026-07-26).** Verbatim: *"when you detect any issues on the way similar to what you uncovered here, then immediately fix them on the way if there is no doubt about it (if there might be, challenge your assumption)."* So: a defect noticed in passing is FIXED in the same turn when it is unambiguous — do NOT merely log it and move on. When there IS doubt, the obligation is to CHALLENGE the assumption (measure it, look from another angle) rather than either guess or shelve it. The two failure modes this bans: (a) filing a real bug as a TODO because it wasn't the task, and (b) "fixing" something on an unverified hypothesis. Exemplars from the session that motivated it: the sentinel-zero bug (found while chasing an unrelated venue refactor — fixed on the spot, 38→8 failures), the `gauntlet == euler` aliasing (found while reading setUp — fixed), the five divergent `withdrawable` definitions (found while adding ONE deallocate call — unified), vs the counter-example of asserting the ~20% shortfall "was the AAVE fifth" three times without measuring.
- **🔴 STANDING RULE — NO CRYPTIC 2–3 LETTER NAMES (user, 2026-07-26).** Every variable, parameter and field earns a readable name: `venues` not `vs`, `adapter` not `ad`, `vault` not `v`. Applies to code you WRITE and to any line you TOUCH. (Rename-on-touch, not a big-bang sweep — the tree is full of them: `c`/`v`/`f`/`p`/`gv`/`mv`/`ev`/`bm`/`ec`/`ed`/`av`/`rf`/`mvB`/`evB`. A conventional single-char loop index `i` is the one accepted exception.)
- **🔴 STANDING RULE — ONE DECLARATION PER INTERFACE, IN A SHARED FILE (user, 2026-07-26).** Verbatim: *"what is with all these underscore V interfaces? we seem to be re-declaring interfaces across files. we can just define them in a file and import them in the files we need."* MEASURED: **26** suffix-variant declarations (`_V`/`_VG`/`_L`/`_VB`/`CL`) and **16 base names declared 2–4×** — `IAaveV4Spoke` ×5, `IWeETH`/`IRover`/`ILevEquity`/`IEthVenue`/`IDepositAdapter` ×3 each, plus ten ×2. Interfaces emit **ZERO deployed bytecode** (verified: `ILevDebtTotal`/`ILevGrossEth`/`IAaveV4Hub` artifacts are 0 bytes), so consolidating is a pure source win with NO EIP-170 cost — and the union of a duplicated interface costs nothing either. The suffixes exist only to dodge same-name collisions when two are imported into one file; one shared `src/imports/Interfaces.sol` with named imports removes the need entirely. **Existing plan: `docs/actionable/INTERFACE-DEDUP-AND-CONSOLIDATION.md`** (findings-only, anchored to `main@025bfe4` — re-verify at mutation sites; it also concludes the `IAuxTWAP_B`/`_BView` view/non-view "deliberate twins" are NOT forced and should collapse to one `view` interface).
  - ⚠️ **The 5 `IAaveV4Spoke` declarations have already DRIFTED into disjoint subsets of one ABI** — `Vault:44` {supply, withdraw, getReserveId}, `VaultLib:11` {supply, withdraw, **getUserSuppliedAssets**}, `Aux:30` {supply, withdraw, getReserveId}, `ChannelLib:41` {getReserveId, supply, withdraw}, `BasketLib:74` {supply, **getReserveSuppliedAssets**, **getReserveTotalDebt**}. Signatures AGREE where they overlap (so no live bug today), but five partial views of one contract is exactly how a future signature change lands in four files and misses the fifth. Consolidate to the UNION.
- **🔴 STANDING RULE — DO NOT JUMP TO CONCLUSIONS; CHALLENGE YOURSELF UNTIL THE SOLUTION IS ELEGANT (user, 2026-07-26; applies to EVERY task).** Verbatim: *"not jump to conclusions, [do] check yourself and try to challenge yourself when something isn't an obvious clear win, look at multiple approaches from all angles until you can find the most elegant solution (that will either reuse what we already have in the code or remove a big chunk of code for a solution that provides better guarantees or the same functionality with better efficiency)."*
  - **The bar for "done deciding":** the chosen approach either (a) REUSES an existing primitive/signal, or (b) DELETES a big chunk while giving better guarantees or equal function at better efficiency. If it does neither — if it merely ADDS — you have not finished looking.
  - **Enumerate ≥2 approaches explicitly** before writing code for anything non-obvious, and write down why the loser lost. A single plausible design is a sign of insufficient search, not of clarity.
  - **Why this rule exists (my own failures, 2026-07-26):** asserted the ~20% LP shortfall "was the AAVE fifth" three times on arithmetic coincidence before a trace refuted the mechanism; wrote "REUSE existing harness IS A DEAD END" into this doc after a filename grep, when `DeployLib` was exactly it; theorised `maxWithdraw == 0` was a per-owner artifact when measurement showed the comment was right. In every case the fix was to MEASURE or to look from another angle, not to reason further from the first hypothesis.
- **🔴 STANDING RULE — NO UNREACHABLE CODE, AND STRIP EVERY NON-SAFETY CLAMP (user, 2026-07-26; applies to EVERY task, not just removal sweeps).** Two directives, both now permanent:
  1. **"no code should be unreachable."** If a branch/guard/clamp provably cannot fire, DELETE it — "unreachable but intentional-defensive" is NO LONGER an accepted justification. This **REVERSES** the §R verdict that kept `FeeLib:194`'s `feeWad<WAD` guard, and any other row parked on defensive-but-dead grounds; re-audit those. An unreachable guard is worse than absent: it MASKS a violation of the invariant it claims to check (exemplar: the `QuidLens` `MAX_FEE` clamp hid any breach of `calcFeeL1`'s documented `[BASE, MAX_FEE]` range instead of surfacing it).
  2. **"if you can get rid of any clamps or caps along the way without reducing safety you should do so."** On EVERY touch, prove each clamp in scope either (a) can fire AND prevents real harm ⇒ keep, or (b) cannot fire / prevents nothing ⇒ delete with the proof in-comment. Removals landed under this rule: `QuidLens` `MAX_FEE` (unreachable — `scaledFeeL1 ≤ full ≤ MAX_FEE` on every path, `frac` already clamped at `FeeLib:146`); `VogueLib.derivedThetaWad`'s `theta > 1e18 ? 1e18` (every consumer already short-circuits at `>= 1e18` — `SwapLib.applyTheta:1299`, `VogueLib:470`, `BtcVaultLib:136` — and the real bound is physical HEADROOM in `clampByBacking`). KEPT under it: `FeeLib:146` `frac > WAD` (CAN fire — a withdrawal may exceed one stable's deposit).
- **🔴 STANDING RULE — DO NOT MOCK ANYTHING; USE THE REAL ADDRESSES (user, 2026-07-26).** No injected stand-in contracts, no fake vaults, no substitute tokens: wire the real mainnet addresses the deploy script uses. Where a real dependency cannot satisfy a test at the CURRENT fork block, the answer is to **move the fork block, not to mock** — the pin is the variable, the counterparty is not. (Live consequence: `Alles.t.sol`'s ETH venues. MEASURED 2026-07-26 — real Euler `0xD8b2…84C2` is fully withdrawable (gap 0), but Galaxy `0x1878…824F` and Gauntlet `0x43fC…92da` (same Morpho-V2 impl) report `maxWithdraw == 0` against a position we genuinely hold, so exits cannot source from them and 6+ tests fail. ⇒ **the correct fix is pinning a fork block where those two hold idle liquidity**; the stand-ins currently wired for them are a KNOWN VIOLATION of this rule and must be removed once the block is pinned. See §A.5/§A.7.)
- **HUNT FOR REMOVABLE CODE (less is more + EIP-170).** Periodically scan for code that can be DELETED without breaking anything: dead code (functions/vars/errors/events/constants/imports with ZERO consumers — verify with grep), USELESS caps/limits that aren't security boundaries (like `MAX_VAULTS`: an owner-only setter's self-limit, no loop used it → deleted the constant + struct field + 2 checks), assigned-once-used-once locals (inline them), redundant/unreachable guards, stale post-refactor leftovers. Prefer deletion over any addition; it also fights the 24576-byte contract limit (no via-IR — extract-to-library or delete). Be CONSERVATIVE: only remove verified-unused/provably-redundant; when unsure, flag. Recurring task (see "Removal scan").

**DEFERRED NOTES (open promises — clear each when done):**
- ⏳ **Cherry-pick vs concentration-fee removal:** removing the concentration fee (`scaledFeeL1`/`calcFeeL1`) opens cherry-picking during a depeg — a redeemer preferentially drains the *healthy* stable and concentrates the depeg loss on remaining holders. The concentration fee is exactly what makes cherry-pick not beat pro-rata (`EconAttackProbe.testDD` logs the advantage; `SOR:343` also selects paths by this fee). When implementing "no concentration fee / depeg-only", SURFACE this + decide handling (force pro-rata during depeg? basket-wide depeg haircut? does 6909/peg-defense cover it?). Also reconcile the SOR path-selection dependency.

## ★ HANDOFF — for a fresh thread (incl. Fable, not Opus) to pick up here
This doc + `DISCUSSION-DIGEST.md` are a self-contained handoff. **Skip every ✅/❎ item** (done+committed / invalid). Work the 🔴 items top-down; each has a fix + the agreed design in the digest. Green = skip, and knowing WHY it's green is in the row / commit message.

> ⚠️ **PORTABILITY — READ FIRST (you are likely on a DIFFERENT machine than the one that wrote this).** The agent-memory dir and the session JSONL transcripts are **NOT present here** — they lived only on the authoring box. So **every `memory `slug``, every `*.jsonl`, and every `/home/rico/.claude/…` or `/tmp/…scratchpad` path cited ANYWHERE in this doc is PROVENANCE ONLY — a dead-end path on this machine.** The actionable fact behind each such citation has been backfilled INLINE (see **§A.1** + the self-containment passes). **Do NOT chase those paths.** Your complete working context = **this repo**: this file + `docs/actionable/DISCUSSION-DIGEST.md` + the source tree. If a rationale genuinely cannot be reconstructed from the repo + digest, treat it as an OPEN question to re-derive and **say so** — never invent one.

**Context that IS here (in-repo, portable — this is all you need):**
- **Agenda + verdicts:** `docs/actionable/BUILD-QUEUE-AND-107.md` (this file). **Status-of-record = the SESSION STATUS block + §A + §S**; the older §C tag layer is an INDEX, not authoritative (see the §C banner).
- **Per-item AGREED design + user corrections:** `docs/actionable/DISCUSSION-DIGEST.md` — read the item's entry BEFORE implementing it.
- **Other in-repo specs:** `docs/actionable/*.md` (LST-PEG-MONITOR, IMPAIRMENT-DERISK-TRIGGER, JIT-DEPTH-GUARANTEE, …) + the `evm/` + `quid-ln/` source.

**Context that is NOT here (authoring-box only — do NOT rely on it):** the `memory/` distillations (~129 slugs, cited as `memory `slug``) and the conversation JSONL transcripts (`*.jsonl`, incl. the 279MB `1f505948` fork). Their content is ALREADY distilled into this doc + the digest; the citations remain purely so a future run *with* access could trace origin. Absence of these does not block any listed TODO.

**Keyword search recipe** (recover context on any item):
- `grep -a "<fnName>|#<issue>|<keyword>" <jsonl>` → note line numbers → read the surrounding window. User prose = `.message.role=="user"` conversational lines (not tool_result); assistant analysis = `.message.content[].text`.
- Prefer `DISCUSSION-DIGEST.md` (already distilled) over raw grep; fall back to grep for anything it doesn't cover.
- Status legend: ✅ done+committed (hash in row) · ❎ invalid/not-a-bug · 🔴 open · 🟡 partial/needs-verify · 🧊 deferred-by-design. **Commits this session:** `9633064` #102 uint[15] · `4273e4e` #4 donation classify · `c48ea01` #1/#7/#8 θ-base · `79c1973` #9 invalid/#10 revert · `58813c7` digest.

## U. UNIFICATION SCAN (2026-07-21) — shared-principle dedups found (exemplar: `clampByBacking` #8)
Ranked; ✅=clean dedup, ⚠️=safety/design decision (surface first), 🛑=intentional keep-divergent. All 3 agents in (fee/backing, swap/skew, leverage/band).
- ✅ **U0 `plainNet(pooled, lev)` = `pooled − levPooled` (zero-floored)** — HIGHEST/SAFETY. Open-coded **8×** (`Vogue:190/326/363/446`, `VogueLib:448/476`, `Vault:631`, `BtcVaultLib:588`) for 4 roles: hedge E0 base (`bandEthOf`/`bandBtcOf`), venue-yield weight, withdraw cap, transfer cap. A drifted copy (dropped floor / net levBuf not levPooled / `>=` vs `>`) → levered depth withdrawable, double-earned yield, or the `1/(1−t)` over-hedge the split exists to avoid. One pure `plainNet` helper (LevMath/SwapLib). Closest analogue to `clampByBacking`.
- ✅ **U8 `TARGET_LTV_CAP_BPS=7500` duplicated literal** (`LevManager:108`, `BtcLevManager:54`) → move to `LevMath` (like `PROTECT_MARGIN_BPS`) so ETH/BTC max-leverage can't be governed apart.
- ⚠️ **U9 ethThetaBacking parity** — ETH theta-backing inline (`VogueLib:357` `vogueETH+grossBuffer`) vs BTC's named `Core.btcThetaBacking()`. Only 1 ETH caller today; add `ethThetaBacking()` for parity/legibility (low payoff).
- ⚠️ **U10 post-clamp `targetUSD` rescale** — ETH recomputes `deltaTok·price/WAD` (`VogueLib:360`) vs BTC ratio-scale `targetUSD·capped/deltaTok` (`BtcVaultLib:119`); different rounding. Fold the sizeBySurplus→clamp→rescale tail into one helper (verify rounding intent).
- 🛑 lev KEEP-DIVERGENT (intentional, documented): shortfall backing ETH(net+gross-coll) vs BTC(POOLED+vogueBTC) — unifying re-doubles-counts BTC (`Core:564-586`) · BTC channel-add skips PHYSICAL-inventory clamp (self-custody sats; theta leg IS shared via clampByBacking) · live-theta fail-open try/catch vs bare check (stack/EIP-170 optimization).
- ✅ **U1 QD per-share value `min(par, solvent/mature)`** — SAFETY. `ShareMath.qdShareValue` (swap path `SwapLib:544`) vs HAND-ROLLED in redeem (`BasketLib:864`). ShareMath's own docstring says it must be THE ONE valuation (swap↔redeem no-arb). Route redeem through it. Sub-flag: docstring says supplyPreBurn=all-vintages but both callers pass mature-only — verify docstring stale, not callers.
- ✅ **U2 depeg loss on a balance** — SAFETY. `sev`-direct (`BasketLib:234`, NOT try/catched → a reverting feed reverts the whole basket) vs `riskFactor`-complement (`Aux:961`, try/catched → healthy). Same quantity, DIVERGENT failure semantics. One `applyDepegHaircut` fed by one severity accessor.
- ✅ **U3 skew-premium RETAIN arithmetic triplicated** — `premium=amount·skew; amount-=premium; recordSkewPremium` copy-pasted at `SwapLib:425/451/1000` (sell-in, USD-drain, BTC-vault-drain — same POOLED_BTC event). One `retainSkewPremium` helper (mirrors the single-impl draw side `payRefillBonus`).
- ✅ **U4 depeg gross-up `x·1e4/(1e4−sev)`** — byte-identical 3× in FeeLib (`:198/213/234`). One `grossUpForDepeg`.
- ✅ **U5 `resolveV4Price` idiom** — `v4p!=0 ? v4p : getTWAPforAsset(asset,1800)` copied 5× (`SwapLib:425/451/472/740/994`), the `1800` window literal repeated. One helper.
- ⚠️ **U6 "committed ≤ backing" gate uses THREE backing defs** — SURFACE FIRST. band-add depeg-ADJUSTED (`Core:984`) vs swap gate RAW par (`SwapLib:392`) vs terminal `checkBacking` RAW par (`BasketLib:930`). Under a depeg a drain passes checkBacking(par) while band-add fails(haircut) — "is the basket over-committed" has two answers. Decide: should checkBacking/swapToBody also subtract depegLoss? (`_maxBtcFromTvl` view raw vs gate haircut = same family.)
- ⚠️ **U7 sellSkew re-derives skewWad's target/inv** — latent coupling (`SwapLib:949` vs `:866`); factor `_invTarget` so the reflection provably inverts the kernel.
- 🛑 KEEP-DIVERGENT (intentional): fee-application trio (calcNeeded/applyFeeAndHaircut/allocate — pro-rata omits cherry-pick fee by design) · mint-par vs redeem-basket-share · swap-out drain-penalty vs swap-in refill-bonus (verified conserving-symmetric) · committedUsd18 summing ETH+BTC (consistency not double-count) · POOLED_USD /1e30 scale.

## R. REMOVAL SCAN (2026-07-21) — verified dead code / useless constants (exemplar: MAX_VAULTS deleted)
Grep-proven zero-consumers. ✅ DONE `MAX_VAULTS` (Aux+ChannelLib — pending commit). Fee/backing agent:
- ✅ **R1 `FeeLib.calcFeeL1WithLookup`** DEAD external fn (`FeeLib:138-147`; only a comment ref in `SOR:361`) — biggest single bytecode win.
- ✅ **R2 `FeeLib.MONTH`** DEAD constant (`FeeLib:36`; `BasketLib.MONTH` is the live one).
- ✅ **R3 `VaultHealthCfg.aaveSpoke` + `.wethReserveId`** DEAD struct fields (`BasketLib:1006-7`; zeroed by `Aux:463-4`, never read by pokeVaultHealth/evacuate) — Aux EIP-170 relief.
- ✅ **R4/R5 redundant `MAX_FEE` clamps** (`FeeLib:187` calcNeeded, `QuidLens:38`) — `scaledFeeL1 ≤ MAX_FEE` by construction, never fire.
- 🟢 **R6 (readability, 0 bytecode):** `IVogueLP` iface (`BasketLib:72`) · unused imports `WETH9`/`PoolKey` (`BasketLib:8/13`) · Aux dead error decls `BadAsset`/`NoBtcRecipient`/`BtcInflowsViaChannels` + dead dups of SOR/ChannelLib errors (`Aux:241-249,714-720`). ⚠️ KEEP `StableMissing` (test/ReentrancyProbe references the selector).
- 🛑 R (leave): `FeeLib:194` feeWad<WAD guard (unreachable but intentional-defensive). Ruled-OUT (all live): applyFeeAndHaircut, isManipulated, ticksToPrice, decPow, levClaimUsd6/realizedVarianceWad/wellSkew (RFQ seam), trancheTotal (test).

Swap/channel agent:
- ✅ **R7 SOR `matchMask` dead** (`SOR:343-368`; caller `:212` discards it) — remove `require(nPaths<=256,"too-many-paths")` (`:350`, string-bearing = biggest saving), `matchMask|=(1<<i)` (`:356`), the return param (`:344`). KEEP leastHopsIdx/leastHops (used `:378`).
- ✅ **R8 `SwapLib.waitNft` public→internal** (`:629`; only internal caller `:619`) — drops the external dispatcher.
- ✅ **R9 `ChannelLib.WAD` public→internal** (`:71`; all 3 uses internal) — drops the getter.
- 🟢 **R10 (source-only):** 5 never-reverted mirror errors `VaultLib:37-41` (Dust/NotOwner/BadPercent/NotAStable/ZeroTwap) · no-op `sqrtLower;` `Rover:622` · stale tombstone comments (`SwapLib:125-130`, `Rover:60/128/555/666-668`).
- ⚠️ VERIFY: `ChannelLib.locateChannelOutput` `:557` pubkey-length re-check on splice (likely redundant vs open-time validation).
- **CORRECTION:** swap-in refill bonus is LIVE (payRefillBonus/creditSwapInBody wired: `Vault:934`→SwapLib→`Core:208-244`), NOT orphaned. `drawSkewPremium` never existed (real symbol `drawPooledUsdBtc`). SPV getters + BTCChannels state vars all used (external ABI/tests) — not removable.

## DR. DEPLOY-READINESS AUDIT (2026-07-22) — correct-by-construction before mainnet

Session scope: prove the WHOLE environment deploys (no broadcast) purely via `evm/.env`; SGX forks by github URLs; deployment JSONs committed (not gitignored); SPA deno-deployed from the commit carrying them + site pins its JS to that commit.

- ✅ **SGX forks = quidmints github URLs, zero local copies** (audited every Cargo.toml + Cargo.lock + .cargo/config): all 13 git deps → `github.com/quidmints/{rust-sgx,axum-server,rust-esplora-client,hyper-util,mio,ring,tokio}` branch main, lockfile has ONLY quidmints `git+` sources; LDK fork is the one intentional in-tree vendor (`quid-ln/lib/rust-lightning`, QUID_PATCHES.md). Note: `[workspace.dependencies] sdk-uniffi = {path}` is dangling (dir absent, unconsumed) — removable.
- 🔥 **USDT0 REMOVED from DeployL1_s (was deploy-fatal).** Commit `aa86599` wired token `0x779Ded…3736` + "Gauntlet USDT0 vault" `0xb7Df8d…5c08` — BOTH have ZERO CODE on mainnet (anvil-fork verified block 25,584,841; control Gauntlet-USDC returns totalAssets fine). Morpho's registry has NO USDT0 vault on chain 1 at all (real Gauntlet-USDT0 vaults live on Unichain/HyperEVM/Arbitrum — where the USDT0 ERC20 exists; Ethereum L1 is by-design canonical-USDT + LayerZero lockbox). A codeless basket stable reverts every all-stables loop → DOA. Now 12 stables: AUSD[9], cUSD[10], BOLD[11] last.
- ✅ **Every OTHER hardcoded external address on-chain verified** (26 contracts: code + `asset()` role for every 4626/curator vault, Aave v3/v4, Liquity, SP, EVK, NFPM, poolManager) + **all 13 price feeds live + sane** (ETH $1941.72 / BTC $66,423 / stables ~$1; AUSD 18-dec as documented).
- ✅ **Lev overlay was NOT correct-by-construction — fixed.** `MORPHO_VBTC_ORACLE` can never pre-exist (prices vBTC through AUX, deployed in the SAME broadcast); no live inverse (short) market exists on chain 1 (Morpho API). Fix: promoted the fork-proven oracles from tests to `src/LevOracles.sol` (RealRateBtcMorphoOracle + InverseRateBtcMorphoOracle + InverseRateMorphoOracle; tests now import — dedup), deployed INLINE when env unset. Long legs JOIN the LIVE deep markets by default (weETH/USDC 86% oracle `0x5635a2…`, $1.76M; WETH/USDC 86% `0x0F948C…`, $3.7M; Morpho-API + on-chain verified): every `vm.envAddress` hard-require became `envOr` with a live default, so bare `DEPLOY_LEV=1` deploys the whole overlay.
- ✅ **Euler ETH venue pair chosen honoring INVARIANT #1:** eweETH-1 `0xD440bA…` (governor-RENOUNCED ⇒ immutably escrow, the ONLY escrow weETH vault any USDC vault accepts) + eUSDC-11 `0x417224…` (67% LTVBorrow, zero cash today ⇒ venue degrades safe until lenders arrive). Full 871-vault EVK factory enumeration: NO live escrow-weETH + liquid-USDC pair exists (liquid vaults only accept BORROWABLE weETH = the double-lend INVARIANT #1 forbids).
- ✅ **DEPLOY_SHORTS=1 decision** (user asked "deploy shorts?"): YES — the ETH short is same-broadcast-or-never (`LevManager` auto-detects `shortVenue` inside init's FROZEN array `LevManager:248`; no post-init pin), BTC's `pinShortVenue` is GOV-later but deploying now discharges the lever; fresh inverse markets have zero lenders so shorts are inert-but-wired (degrade-safe, no phantom backing `BtcLevManager:140-141`).
- ✅ **Deployment record committed:** DeployL1_s now writes `evm/deployments/l1.json` (`vm.writeJson`, addresses + chainId + deployer + checkpointHeight) on EVERY run incl. dry-runs; `.gitignore` now `evm/broadcast/**` + `!**/run-latest.json` (archives stay ignored). Dry-run addresses == later broadcast IFF deployer nonce unmoved (deployer `0x42cc02…74A4` owns ANGEL #16508 on mainnet — real-RPC dry-run passes the Basket ctor precondition; nonce 312 at audit time).
- ✅ **SPA pinning:** `chains.ts` base layer = imported `evm/deployments/l1.json` (env still overrides per-address for anvil e2e); `NEXT_PUBLIC_COMMIT` = `git rev-parse HEAD` inlined at build (`next.config.js`); `BuildStamp` (landing footer + `/app` corner, `data-commit`/`data-basket`) lets a visitor verify the running JS + addresses by commit; runbook `spa/DEPLOY.md`. Also fixed stale SPA list: added cUSD (18-dec verified), corrected the false "AUSD last" comment.
- ✅ **Rot removed:** `evm/scripts/DeployL1.s.sol` (self-declared deprecated, non-compiling) deleted; dead `HOP_BTC_PUBKEY` requirement dropped from `deploy-l1.sh` + example env (never read by the script).
- 🔴 **OPEN (test-coverage gap surfaced):** `Alles.t.sol:357` claims "mirrors DeployL1_s.sol ordering" but builds **11 stables** (no cUSD) vs the deploy's 12 — the deployed 12-stable topology is only exercised by the dedicated #102 fork test. Extend Alles' array (uint[15] already sized) or drop the "mirrors" claim.
- 🔴 **OPEN:** refresh `BTC_CHECKPOINT_*` in `evm/.env` to a RECENT block before the real broadcast (860000 anchor ⇒ ~45k-header forward walk for the hop).
- 🔴 **OPEN:** `evm/.env` carries the real deployer key on disk — fine for the operator box, but the final-launch runbook (`deploy/PRODUCTION-LAUNCH.md`) should say the broadcast machine is the only place it lives.

## A. AUDIT FINDINGS (dedup, severity-ranked; verify at mutation-sites)

| # | Label | File:line | Sev | Defect | Fix |
|---|-------|-----------|-----|--------|-----|
| 1 | θ-clamp mis-base (EXEMPLAR) | `BtcVaultLib:130-135`; `applyTheta SwapLib:1222`; `vogueBTC Aux:116/533/711`; `Core:575` | ✅ DONE `c48ea01` | `θ×vogueBTC`, but vogueBTC = disjoint WBTC-donation accumulator, not IL-bearing POOLED_BTC. θ<1 + thin donations → 0 in-range → throttles refill. | **DONE**: one `Core.btcThetaBacking()` (lpSharesBTC + totalBufferBTC) source for BOTH the LP-add clamp (+incoming `sats`) AND the reseat clamp (VogueLib), so a repack can't undo it; dropped dead `aux`/`vogueBTC`. Regression-free (6-red baseline). Closes #7,#8. |
| 2 | Leverage-cap denominator (D7) | `LevManager:108,122`/`BtcLevManager:54` `TARGET_LTV_CAP_BPS`; prose `LevManager:550-552`,`BtcLevManager:369-373` | ❎ INTENTIONAL (2026-07-22 examined) | E0-denominator IS the deliberate over-hedge fix: `debtDelta` sizes `debt=E0·t`; a collateral-LTV swap would reintroduce the over-hedge that `testProof_OnlyDynamicSizingCancelsIL`/`testProof_CorrectKeeperTargetLtv` guard against. | No code change. Only nit: the "≈4×" comments overstate the *conservative* real bound (~1.75× = 1+t); left as-is — E0/leverage semantics too subtle to re-word without risking a wrong number (#14 lesson). |
| 3 | uint[13] overflow / cUSD #102 | `DeployL1_s:198`; `BasketLib`; +9 files | ✅ HIGH | 13 stables vs uint[13] (BOLD[11]/TVL[12]); loop writes [1..12] → cUSD corrupts TVL, BOLD clobbers USDT0; silent backing corruption. | **DONE `9633064`**: uint[15], BOLD→[13], TVL→[14], 9 src + 8 test; backing 4/4 green. |
| 4 | sUSDe-class balanceOf-valuation tenor smoothing (was "4626 donation → CAPO, HIGH") | `BasketLib:330` convertToAssets | 🟡 LOW-MED (downgraded from HIGH — FORK-PROVEN 2026-07-21) | EMPIRICAL (`VaultDonationClassify`, `AaveV4DonationProbe`): Aave V4 spoke IMMUNE to BOTH donation (0 on 500 WETH) AND index/rate (exact 0 same-block under a util spike; +14bps/30d real yield only) — true remaining CAPO surface = the weETH LST price oracle (collateral pricing), not the aToken balance; Euler/sDAI/morphoUsds = IMMUNE; MetaMorpho galaxy/gauntlet/sky = 0–13 bps under a 100%-of-totalAssets donation; **only sUSDe inflates fully (100% donation → 100% cta, `totalAssets=balanceOf(USDe)`)**. NOT a profitable attack (donation = real permanent USDe backing, no transient). Residual: a sudden sUSDe cta jump feeds the forward-yield tenor (bufBps) → over-credits future yield now. | Growth-cap/EWMA-smooth ONLY the sUSDe-class balanceOf legs, applied to the TENOR calc (not raw backing, which is real). Aave/Euler/sDAI/MetaMorpho need nothing. |
| 5 | F2 committedUsd18 interest-loosening | `Core:100-122`; gate `Core:980` | ❎ REVERTED — intended behavior (2026-07-22) | Implemented `min(debt,recordedBuf)` then a named test refuted it: `BufferSwapDrain.t.sol::test_BufferConsumingSwap_CommittedTracksLiveDebt_NoDrain` asserts `committed==inRangeUSD−liveDebt` as "the fold's DEFINING identity, drift-free by construction". Interest shrinking committed is CORRECT (levered LP's real equity = collateral−debt genuinely shrinks; the lost value went to the venue, not the basket, so total claims stay ≤ backing). The "fix" reintroduced the stored counter the design deliberately avoids. | No change — reverted. Documented in Core.committedUsd18 NatSpec. |
| 6 | F3 levClaimUsd6 scarcity off debt | `Core:183-191` | ✅ DONE `3dcbf46` | Locked-volatile scarcity term fed `_levDebtUsd18` (short-stable ~1× leg), but locked volatile is gross collateral (~2×). Under-weighted + wrong leg. | **DONE**: added `Core.levGrossNative` (gross collateral, native units); `skewWad` split — `inv` subtracts GROSS (locked inventory), `target` keeps DEBT (draw/return demand). Fork-proved `testSkewBarrierRamp_ConvexCapAndMonotone`. |
| 7 | θ sibling VogueLib.addLiq | `VogueLib:348-352` | ✅ DONE `c48ea01` | Same `θ×backing` shape; masked on ETH (vogueETH≈POOLED_ETH), real only on BTC — the reseat path that would have re-collapsed the band. | **DONE**: VogueLib isBTC branch now reads `Core.btcThetaBacking()` (also fixed the entangled ETH-buffer-for-BTC-reseat bug). |
| 8 | F3-sibling BTC drops physical clamp | `BtcVaultLib:117,127-129` | ✅ DONE `c48ea01`+dedup | BTC LP-add skipped the ETH physical `backing−pooled` clamp → θ·backing was the sole bound → unbounded when θ fails open. | **DONE (unify, not "skip is sound")**: extracted `SwapLib.clampByBacking` (physical HEADROOM `backing−pooled` AND θ-budget `θ·backing−pooled`), now shared verbatim by the ETH band + BTC add + BTC reseat. Every path bounded at real backing even on fail-open. |
| 9 | ~~_finishMint omits illiquidLoss~~ INVALID — intentional asymmetry | `Basket:320-347` vs `:273-286` | ❎ NOT A BUG (2026-07-21) | Mint and redeem do NOT (and should not) value backing identically: mint over-mints forward yield at 1:1 (par); redeem values one basket share (min($1,solvent/mature)) which ABSORBS the over-mint. illiquid backing is TEMPORARY (thaws over the forward tenor of immature QUI), so the depositor path correctly excludes it; the protocol path subtracts it only because its QUI is redeemable-NOW. | No change — documented the asymmetry in-code so it isn't re-"fixed". |
| 10 | _touchBaseRate totalSupply vs matureSupply | `Aux:1071-1082`→`FeeLib.touchBaseRate` | ❎ MOOT (2026-07-22) | The whole baseRate register was REMOVED by `6b0d7ff` (no `touchBaseRate` definition remains — only "REMOVED" tombstones `Aux:1015,1055`, `FeeLib:186`); there is no basis choice left to make. NOTE: `DISCUSSION-DIGEST.md` "★ DECAY / baseRate" still describes the removed mechanism as keep-as-is — superseded. | — |
| 11 | Vote-median stale cache | `Basket` WEIGHTS_btc/SUM_btc/K_btc; `_median:202`; `_resyncVotes:504`←`_transferHelper:474` | ✅ DONE `3dcbf46` | Non-conserving subtraction (used live stake, not the prior contribution) let buckets accrue ghost weight; plus pure-maturation drift. | **DONE**: `votedWeight` snapshot makes every W[] update conserve exactly (also self-heals maturation drift on next interaction) — removed two computed locals from `_transferHelper`. Fork-proved `testGrief_ImmatureVote_NoDoubleCount`. Residual (never-touched voter's stale weight) is O(voters), bounded, soft-cap-only — documented in-code. |
| 12 | H1 #54 delivery-side de-lever | `SwapLib:1097-1144`; `BtcLevManager:567,574` | ✅ code-verified 2026-07-22 (no new commit — landed earlier) | RESOLVED at HEAD: `deleverOnDelivery`/`_sourceRepayFree` clamp `takeUsd18` to LIVE debt (`SwapLib:1124`) + held (`:1127`); `swapOutDelever` returns REALIZED `freedSats` (`BtcLevManager:574` `if (got != freedSats) freedSats = got`) + realized `usedUsd` (`:567`). Residual: stale-POOLED async reconcile via keeper `syncLevBTC`, documented `SwapLib:1133`. The branch-test half is still open → folded into #13's guard/test ask. | — |
| 13 | H2 #54 under-delivery | `SwapLib._sourceRepayFree:1116` | ✅ DONE `3dcbf46` (flash-fallback enhancement in progress) | takeUsd18==0 (basket lacks venue debt stable) → silently truncated to funded, leaving unbacked vBTC. | **DONE**: `takeUsd18==0` now reverts `DeleverStableUnavailable` (real debt) or frees the pure-equity slice (no debt). Fork-proved `testReal_DeliverSideDelever_SwapOutTapsLeveredSlice`. FOLLOW-ON (in progress): replace the revert with a free-Morpho-flash source (three-way ladder) so delivery never reverts on a sourceable stable. |
| 14 | F1 shortfall-arb comment drift | `Core:561-586` | ✅ DONE `3dcbf46` | The stale parenthetical claimed the ETH branch adds `totalGrossCollateralEth` to `vogueETH()`; verified `vogueETH` adds NET (`totalNetEquityEth`, VaultLib:121) and `totalGrossCollateralEth` was uncalled until #6 wired it into the skew. | **DONE**: rewrote the Core comment to NET-vs-NET (ETH) + why only BTC needs +totalBufferBTC; corrected the `LevManager.totalGrossCollateralEth` docstring to its real (skew) consumer. |
| 15 | F4 _btcCapClamp dual-base | `SwapLib.btcCapClamp` vs `Core` gate | ✅ DONE `3dcbf46` | Sizer measured the BTC-share cap off GROSS `POOLED_USD_BTC` while the Core gate uses NET `_bandEquityUsd18` → over-restricted legit BTC adds. | **DONE**: added `Core.btcBandEquityUsd18()`; `btcCapClamp` now measures NET, matching the gate. Inlined the clamp locals too. |
| 16 | F5 addLiq totalBuffer headroom | `VogueLib.addLiq` | ❎ INTENTIONAL (2026-07-22 examined) | `usdOut ≤ surplus = TVL − net-committed` ALWAYS (capped before the θ clamp); the buffer enters only the gross-θ DEPTH clamp (`clampByBacking`), never the TVL-surplus. Proven no F2-style loosening. | No change. |
| 17 | F6 pendingSwapOutUsd gross | `Core:140,491-493` | ❎ correct-by-construction (2026-07-22 examined) | The swap-in gate uses gross `POOLED_USD_BTC` because the delivery draw it guards (`drawPooledUsdBtc`) subtracts from that SAME gross slot — using net would be a mismatched over-tighten. | No change. |
| 18 | Basket.target ≡ seeded dup | `Basket:35,401-403,460,469`; `seedFee BasketLib:370-383` | ✅ DONE `3dcbf46` | `target` moved by the identical delta to `seeded` everywhere (the "×4yr/1.2" factor was never applied) = provable duplicate. | **DONE**: deleted the `target` storage var + its two writes; replaced with `function target() external view returns(uint){return seeded;}` — kills the redundant SSTOREs, `ChannelLib.seedFee` keeps working. |
| 19 | recordClose stale mint NatSpec | `BTCChannels:880-881` | ✅ DONE `3dcbf46` | NatSpec said "Vogue reconciles/mints" the coop-close proceeds, but the mint moved to the BtcVault (`unregisterBtcLp`, per the Basket auth regroup). | **DONE**: corrected the attribution to "the BtcVault (via unregisterBtcLp)". |
| 20 | deliverableDollars | `LevManager:368-387`; `BtcLevManager:256-275`; `LevMath.deliverableDollars` | ❎ correct-by-construction (2026-07-22 examined) | Margin-bounded `min(netEquityUsd, buffer)` — can't emit phantom USD (`D≥S+L` preserved); single-`px` aggregation is price-consistent. Guarded by `VBtcLevFeeLane.t.sol::test_LevDeliverabilityBTC_DeliverableDollarsView` (asserts real, ≤collateral, grows w/ net-equity, solvent). | No change — it's a live, tested #67 view, not dead. |
| 21 | Rover.take() tick-range half | `Rover:624-627` | ✅ DONE `3dcbf46` | amount1/WETH `L` sized over (sqrtCurrent,sqrtUpper); realizes over (sqrtLower,sqrtCurrent) → under-estimate short-delivery. | **DONE**: `getLiquidityForAmount1(sqrtLower, sqrtCurrent, need/2)`; removed the `; sqrtLower;` no-op. |
| 22 | settleSwapIn authority mis-based | `BTCChannels:1011-1063`, gate `:1020` | 🧊 LOW (SGX) | Hop draws GLOBAL POOLED_USD_BTC gated on owning ANY channel, not its own locked sats; dust-hop dilutes LPs. Deferred. | ⚠️ **DO NOT rebuild the on-chain per-hop cap** — it was BUILT + REVERTED. Swap-in is **settle-then-claim**: `lockedSatsOf` systematically LAGS the hop's real LN-received BTC (backing is off-chain in Lightning), so an on-chain `≤ f(own totalSatsLocked-share)` cap chicken-and-eggs legit swap-in throughput. **Correct fix = enclave G-2** (the SGX hop verifies attested sats ≤ committed inbound HTLC before the EVM draws) — this is an M11 residual, not an on-chain change. (memory `multihop-swapin-sgx-residuals`, `btc-swapin-atomicity-aave-cap`; the "cap breaks settle-then-claim" trace is in SCAN-RECONCILE §0 KILLED. Same note applies to INTERFACE-DEDUP §175, which proposes the same reverted cap.) |
| 23 | calcFeeL1 yield-axis | `FeeLib:120`; `SOR:343` | 🧊 LOW (spec) | Outflow fee prices yield-degradation (taxes high-yield drains) — arguably backwards vs collateral-quality. Intentional. | Reconsider risk axis; low urgency. |

**Secondary lev/BTC low-confidence (recorded so not lost):** `totalNetEquityEth` comment says "adds vogueETH" but it's SUBTRACTED; capacity term is gross grossCollateralEth → ETH(gross)/BTC(net) asymmetry (`LevManager:355-356`, MED-drift) · `shortTargetBps` clamps over-hold fraction at capBps (leverage cap reused as bound), load-bears only in `√(entry/now)−1` fallback (`LevMath:140-146`) · `swapOutDelever` frees freeSats decoupled from usedUsd — venue-health invariant enforced by caller not here (`BtcLevManager:557-580`) · `deleverRepayUsd` header says `Δ/(1−t)` but returns `curDebt−targetDebt` (`LevManager:795-798`, doc-drift) · `deliverSwapOutOnchain` never asserts shrinkSats≥so.sats → LP claims full proceeds for smaller reduction, hop-subsidized (`BTCChannels:1149-1200`) · `AttestedHopRegistry` verified-output offsets mock/unpinned, gate OFF (`:66-75,149-167`) · `FeeLib.calcFeeL1WithLookup` unknown-token→idx=0 prices slot-0 not no-op (`FeeLib:160-164`).

**Verified CLEAN (right-pattern templates — don't "fix"):** `bandEthOf/bandBtcOf=pooled−levPooled` · fee-weight split (trading GROSS, venue-yield PLAIN) · per-band equity floor `Core:104-109` · skewPremium conserving clamp `Core:212-247` · `capBufferUsd` capped at own debt · `surplus=liquidTotal−committedBoth` · soldFractionWad/boughtFractionWad live from geometry · all venue LTV-scale conversions · avgYield bond-bonus off reserve venue yield.

## A.1 REVERSE-AUDIT BACKFILL (2026-07-26) — per-task completing-context moved from memory into the doc

A memory→doc COMPLETENESS audit (does each open task have the context to be BUILT from the repo alone?) found these gaps. Migrated here so no open task needs private memory. (G1 is inline at §A#22.)

**G2 — §D "`outOfRangeBtc` vBTC mirror UNBUILT" (F-B): the missing why-deferred + live-loss.** Today `Core._settleTokSide` BURNS the boundary order's filled BTC leg (`pullBtc`) = an **ACCEPTED live owner-loss**, not merely a "documented gap." It **CANNOT be built pre-M11**: native delivery of the filled leg needs hop-attribution of the off-chain fill channel + new Vault→BTCChannels obligation wiring that REVERSES the current gate direction; interim option-1 (swap filled BTC → pay USD) was DECLINED. (memory `btc-proceeds-findings`, `m11-scope §C`.)

**G3 — 🔴 NEW TASK (was memory-only): BTC swap-out proceeds Phase-2 (M11).** The LN swap-out rail (`requestSwapOut` + bridge watcher/reporter + hop LN-pay) was **entirely REMOVED** (`34f6e30`), replaced by on-chain-exact `pendingSwapOutUsd`. M11 must **RE-IMPLEMENT from scratch** (NOT un-stub) with **exact hop-attribution** (per-channel delivery share + swap-in-reversal attribution). Also `btcFeesOwedSats` (native-BTC LP fee leg) is hop-WITHHOLDABLE → must move under SGX. (memory `btc-proceeds-findings`, `btc-lp-native-fees`, `m11-scope §C`.)

**G4 — M11/SGX residual actionable list (BUILD-QUEUE §V.9 only summarizes).** Completable list (memory + `deploy/PRODUCTION-LAUNCH.md`): G-2 swap-in HTLC gate (see §A#22); C-open key-control attest; DCAP TCB/revocation (`verifier.rs:440/543`); migration replay-nonce + Prod build-guard; seed key-rotation ("recovery #2"); split-brain; ReportData binds only `[0..32]` not the EVM addr `[32..52]`; contract-addr+chain-id→MRENCLAVE binding. **RECONCILE (memories disagree):** anti-rollback / sealed-freshness is **BUILT** (`570cbf8` + `1b76aaa` `commitFreshness`) — `taproot-nonce-reuse-critical` is authoritative; `multihop-swapin-sgx-residuals`'s "P0 UNBUILT" tag is STALE, do NOT re-scope it. (memories `m11-scope`, `m11-enclave-build`, `m11-foundation-audit`, `onchain-hop-attestation`.)

**Tier-2 (memory-only; verify with a grep, then fold into the relevant §):**
- `btc-lp-native-fees`: swap-IN net-RECEIVER reconcile (`Vogue:779` — a swap-in refilling a channel past funding leaves `finalBalance > funded`; LP keeps the extra natively) + partial/mid-channel LP settlement (full-close-only today).
- `yb-leverage-resolved-design`: `E0` **stale-on-band-resize** → keeper over-hedges (fix worth doing); #36 venue-gate = wire `vaultBlocked` into `netEquityEth`/`netEquityBtc` (distinct from S39 GAP-2).
- `multihop-trustless`: lev collateral **hardcoded weETH** (`LevManager.sol:67`) → a WETH-only LP can't lever; needs a WETH-collateral market / 2nd manager (verify vs LEVERAGE-COLLATERAL-ROUTE-SPEC).
- `leverage-liquity` (#19 directional Liquity long): the **earmark guard was REMOVED** — re-add on #19 ship, WITH a BOLD concentration cap + real depeg signal + pre-open D3 headroom gate + keeper D1/D2/D3. (§S5 records only the "BOLD trove rate HIGH" constraint.)
  - **📥 BACKFILL (define the shorthand so this is buildable from the repo alone):** **D1 = MCR-protect** — unwind when the trove's collateral-ratio falls below `MCR + buffer`. **D2 = repayment-BOLD liveness** — the LP's lever-up BOLD is deposited in the Liquity Stability Pool, but an SP liquidation burns BOLD pro-rata ⇒ the LP's share becomes seized ETH, NOT BOLD ⇒ at unwind they can't repay the trove to release their equity ETH; the **earmark guard** reserves BOLD (strict-BOLD draws capped at `SP_BOLD − earmarkedBOLD`) and the keeper converts seized ETH→BOLD BEFORE a liq burns it. **D3 = system-liquidity force-unwind** — levered opens convert pool ETH→earmarked-BOLD, carving regular LPs' free ETH; force-unwind the lowest-priority levered positions when `freeETH < pendingRegularWithdrawals`, so leverage may DEFER but never permanently TRAP a regular exit. (Why the concentration cap + real depeg signal are required: **BOLD is the only basket stable with NO Chainlink feed** — `getDepegSeverityBps ≡ 0` — so a BOLD depeg is invisible to the standard oracle path.)
- `il-bonds-truth`: repack **WIDTH hardcoded `200`** in `_updateTicks` → regime-adaptive width = new work (BAND_DELTA/reseat-at-edge ≠ width); the CRE depeg-risk aggregator is spec'd (`SPV/cre/main.go`), not implemented.
- `audit-pass`: **fee-split ratification** (100% to ETH+BTC LPs, 0 to stable stakers) is UNDECIDED + unrecorded; + MED internal-only BTC TWAP on `creditSwapIn` (no external anchor → drift/mis-mint on the BTC-swap-in mint axis; partly §P.3b).

**Status CORRECTIONS (verified — memory index over-states openness):** #51 redeemSplit DONE (`30a2d56`); `closeBtcLev:438` naked-swap wedge FIXED; taproot `to_self_delay` RESOLVED (symmetric 1008); `VBtcLevFeeLane.t.sol` EXISTS (il-elimination test gap closed). **DANGLING REF:** `LEVERAGE-ENGINE-SPEC.md` (cited by LEVERAGE-RISK-SURFACE.md + memory `il-elimination`) NO LONGER EXISTS in `docs/actionable/` — repoint those to LEVERAGE-DELIVERABILITY-SPEC / this doc.

## A.2 FORK-TEST FLAKE STATUS (2026-07-26) — what's fixed, what remains, what did NOT work

The mainnet-fork suite had two failure CLASSES (both pre-existing, both fail identically on committed HEAD — NOT regressions from the EIP-170 deploy work; verified by stash+rebuild of HEAD).

**✅ FIXED + committed (`7c04fe2`): stale TVL-index class.** `test_RunSim_A_SolvencyDepth_ProcyclicalCrash`, `_ConcentrationTilt`, `_ChopIsBenign`, `_TrendDownIL` read `get_deposits()` slot **[12]** for TVL, but the uint[13]→[15] migration (`9633064`) moved TVL to **[14]** (BOLD→[13]). Fixed `dep[12]/dep1[12]`→`[14]`. **Confirmed 23/23 suites green** (was 0/23). This was the DOMINANT class.

**🔴 REMAINING: lev px=0 (tick-underflow) class.** `testReal_Euler_OpenAndDelever` + `testReal_Morpho_OpenAndDelever` (div-by-zero), `testReal_Euler_RebalanceMany_BatchHoldsTarget` (`5168<=5168`, no lever-up), `testReal_Aave/Weth_OpenLeverClose` (`deliverable ETH … counts gross collateral: 5747 < 7508`). Root cause: `_crashBand` (LevYbReal:209) sells big ETH steps into the THIN mock band pool → the avg tick over the 1800 s window goes far negative → `BasketLib.ticksToPrice`→`getPrice` UNDERFLOWS to 0 → `getTWAPforAsset(WETH)` returns 0 (`twapResolve` line 188 short-circuits on `price==0`, never falling to Chainlink) → the de-lever divides by px=0 (panic) / sizes off 0 (no lever move).
  - **DID NOT WORK (do not repeat):** (1) `twapResolve` 0-internal→fresh-Chainlink hardening — insufficient because the TEST's mock ETH feed is ALSO stale after the 31-min warps (no fresh anchor to defer to); it IS a valid prod hardening but can't be demonstrated by this test. (2) `_crashBand` SPOT-guard (stop at −dropBps spot instead of the lagging TWAP) — insufficient because a SINGLE 30-ETH swap already overshoots the thin pool before the top-of-loop guard fires.
  - **NEXT (untried):** combine SPOT-guard + SMALLER `ethPerStep` (so no single swap overshoots), OR drive the crash via a controlled FRESH feed (set `_setEthFeed(start·(1−progressive))` each step, don't break on px==0) + the `twapResolve` hardening so getTWAPforAsset defers to the fresh feed. Also: `LevCascade.t.sol:120` has its OWN `_crashBand` copy (30% crash) needing the same fix; and `RebalanceMany`/`OpenLeverClose` may be partly separate (rally-side `_rallyBand` / a `deliverable-counts-gross` assertion) — triage each after the crash mechanic is fixed. Each iteration = a ~15-min fork build.

## A.3 VENUE REFACTOR — ⚠️ VERIFY ON A BUILD MACHINE (2026-07-26, commits `48abf53` + the follow-up fallback commit)

The ether.fi-via-Rover + no-always-live-sink + mappings-dedup refactor (user's `[ TODO ]` at `Vogue.sol:66-80`) is **committed but NOT compiled/tested in-thread** — this thread's machine has no working `forge` build (the `forge build` was interrupted; RAM-limited). **A fresh thread / the other machine MUST run the checklist below before treating this as done.** Everything here is reasoned from source, not verified by a run.

**What changed (files):**
- `evm/src/imports/VogueLib.sol` — removed the `VENUE_ETHERFI(=1)` dispatch tag; `depositETH` VENUE_ROVER branch + every SPLIT ether.fi leg go through `_supplyEtherFi`; explicit VENUE_GALAXY branch; SPLIT is equal 5-way and reverts `VenueUnavailable()` if any curated leg (Aave/Euler/Rover/Gauntlet) places short — NO Galaxy sink; `placed==0` ⇒ `revert VenueUnavailable()` (no silent fallback). **`_supplyEtherFi` fallback branch (the load-bearing bit):** Rover first; fall to direct weETH when Rover **reverts** (self-liquidated, drained v3 pool — `catch`) OR **returns 0** (Rover unset/inert — the `if (placed==0)` guard). Returns 0 only if BOTH place nothing.
- `evm/src/Vogue.sol` — dropped the `VENUE_ETHERFI` constant; fixed the stale "50/50 Galaxy+AAVE", "SPLIT sweep target", and `deposit(...,venue)` doc comments (lines ~82/93/1203) that MISLED a prior thread into thinking venue 0 was a 50/50; only `ethfiBacked` per-LP mapping kept (`aaveBacked` + `withdrawInstant` were already removed).
- `evm/test/Alles.t.sol` — the 4 old `venue=1` (ether.fi) deposits now use `venue=4`: 3 no-Rover tests (`testEthVenue_EtherFi_DepositAndOfframp`, `_WaitNFT`, `_InstantRedeem_Rung3`) hit the **return-0** fallback; `test_EmptiedWeethPool_OfframpResilient_RoverHandled` (funded Rover) mocks `rover.deposit` to revert around the deposit so it hits the **catch** fallback and keeps a direct-weETH slice. NEW explicit test `testEthVenue_Rover_SelfLiquidated_FallsBackToDirectWeETH` covers the catch branch head-on.

**CHECKLIST (run on the build machine):**
1. [x] **DONE 2026-07-26 (macOS x86_64, forge 1.5.1-stable, solc 0.8.30) — `forge build` EXIT 0, artifacts written.** Output was style lints ONLY (`mixed-case-variable`, `unwrapped-modifier-logic`) — zero errors/warnings. Verified the two specific claims: **no dangling `VENUE_ETHERFI` code refs** (the 4 remaining hits are COMMENTS documenting its deliberate absence — `Vogue:71`, `VogueLib:77/97/257`), and `VenueUnavailable` resolves (declared `VogueLib:89`, thrown `:287` curated-leg-short + `:291` placed==0). **EIP-170 gate PASSES: all 137 contracts under 24576.** ⚠️ **But the margins are RAZOR-THIN — treat as a hard constraint on every future edit: `LevManager` 24506 (**70 bytes** free), `LevMath` 24492 (**84**), `SwapLib` 24281 (**295**).** Next-largest are comfortable (`Aux` 1834, `BtcVaultLib` 2742, `BasketLib` 3441). Any addition to LevManager/LevMath/SwapLib must be offset by a deletion in the SAME contract — extract-to-library or delete (no via_ir).
2. [x] **RUN 2026-07-26 — 🔴 THE REFACTOR BREAKS THE DEFAULT VENUE ON MAINNET. `forge test --match-contract '^Alles$'` = 72 pass / 38 FAIL, and 36 of the 38 are `VenueUnavailable()`.** (Fork suite runs in ~30 s, not the ~15 min this doc predicts elsewhere; `foundry.toml`'s committed Ankr `eth_rpc_url` is live + archive-capable, so NO `.env` is needed for fork tests.)
   - **The 5 targeted venue tests are FINE** — `testEthVenue_EtherFi_{DepositAndOfframp,WaitNFT,InstantRedeem_Rung3}`, `_Euler_FullLifecycle`, `_Rover_{DepositFundsRoverAndExits,FairGateRefusesManipulatedPool,SelfLiquidated_FallsBackToDirectWeETH}` all PASS. The `_supplyEtherFi` return-0 AND catch fallbacks (checklist items 3+4) are therefore CONFIRMED working. The breakage is elsewhere.
   - **ROOT CAUSE (user, 2026-07-26: "its not a genuine bug, its a symptom of the removal") — CONFIRMED, and the test docstring already said so.** `Alles.t.sol:1301-1308`: *"On THIS fork the configured spoke (0x94e7…, GHO/USDG) doesn't list WETH, so `WETH_RESERVE_ID == 0` → venue 2 is inert and deposits **gracefully fall back to Galaxy**."* `supplyAaveEth` is not defective — AAVE-v4 has no WETH market at this fork block, and `WETH_RESERVE_ID` is fixed at CONSTRUCTION (`Vault.sol:277-279`). The old silent Galaxy sweep hid that; removing the sink made it fatal. Corollary worth stating plainly: **those AAVE tests were never testing AAVE** — they were testing Galaxy under an AAVE label.
   - **WHY IT SPREADS TO 36 TESTS:** almost nothing selects venue 2. They call the 2-arg `deposit` = **`VENUE_SPLIT`** (49 such call sites in `Alles.t.sol`), and SPLIT is all-or-nothing: `extSum += supplyAaveEth(fifth)` … `if (extSum < fifth*4) revert VenueUnavailable()` (`VogueLib:280-287`). With the AAVE leg structurally placing 0, `extSum` can NEVER reach `fifth*4` ⇒ **every default-venue ETH deposit reverts on mainnet.** Stale tests are a rounding error next to that.
   - 🟢 **REAL ROOT CAUSE FOUND — A SENTINEL-ZERO BUG, NOT A CONFIG FACT. FIXED 2026-07-26. (This SUPERSEDES the "SPLIT design decision" this row previously proposed — SPLIT's all-or-nothing rule is probably FINE; it was depending on a venue that was spuriously disabled.)** Prompted by the user asking "why would it not list weETH? how odd" — it *was* odd, because the premise was false.
     - **CHAIN-VERIFIED (live mainnet, not comments):** `hub.getAssetId(WETH)` returns **0**, and `spoke.getReserveId(hub,0)` returns **0** — but `getAssetId` **REVERTS** (`0xb77e1e0f`) for a genuinely unlisted asset (probed with SHIB + a dead address). So a 0 return means **"asset index 0"**, i.e. **WETH IS LISTED**, and reserve **0 is its real, valid reserve**. Independent proof: `AaveV4Venue` resolves `COLL_RESERVE` the same way (`:110`), gets 0, and `test/AaveV4Venue.t.sol` **PASSES 2/2** supplying real WETH + borrowing USDC against it. Asset map on this hub: WETH 0, weETH 2, USDT 4, USDC 5, GHO 6, USDG 8 (so weETH is listed too — this is the ether.fi/GHO-flavoured instance).
     - **THE BUG:** `Vault.sol` used `WETH_RESERVE_ID != 0` as the "venue 2 is wired" flag. Reserve 0 being legitimate makes that a **sentinel collision**: it read a perfectly wired venue as absent and **silently disabled ETH venue 2 — which therefore never ran on mainnet at all.** Corroborating evidence that was already in the repo: removal-scan **R3** had flagged `VaultHealthCfg.wethReserveId` as a DEAD field. The old fall-back-to-Galaxy sweep masked it; removing the sweep turned it fatal.
     - **BOTH the `Vault` comment ("0 if WETH isn't listed on this spoke") AND the `Alles.t.sol` docstring ("the configured spoke doesn't list WETH") asserted the false premise** — a textbook instance of the doc's own standing law ("anchor every claim to HEAD; never to comments — the θ-clamp exemplar fooled two agents by comment"). Both corrected in place.
     - **FIX (no new field, no new immutable, no meaningful bytecode):** `AAVE_SPOKE` becomes the single sentinel — an address cannot be validly zero. `Vault` now resolves inside `try IAaveV4Hub.getAssetId(WETH)` (a **revert** is the real listedness probe) and only then sets `AAVE_SPOKE` + grants the spoke its WETH approval; on revert venue 2 stays unwired with nothing propagated to the deploy. The **five** gates that tested the reserve id now test `aaveSpoke`: `VaultLib` `_aaveBal:83`, `:176`, `:217`, `:278`, `:316`. Stale comment at `BasketLib:1119` fixed too. **NOTE the 5th site (`:316`) was missed on the first pass and caught only by a follow-up grep — grep for `wethReserveId *[=!]= *0` after any change here.**
   - **RESULT AFTER THE SENTINEL FIX: 38 fail → 8 fail (72 pass → 101 pass, 2 skipped). All 36 `VenueUnavailable()` GONE.** SPLIT was never the problem, confirming the design change proposed above was unnecessary.
   - 🔴 **NEW, NEWLY-VISIBLE BUG — the AAVE-v4 leg cannot be WITHDRAWN (6 of the remaining 8).** Enabling venue 2 for the first time means SPLIT now really places a fifth into AAVE-v4 — and the exit path cannot get it back. The shortfall is arithmetically exact: `testDepositImmediateWithdraw` 19.80%, `testWithdrawWithAccruedFees` 19.51%, `test_BankRun_VaultLiquidity` 20.00%, `test_EthLp_RedeemConservationAndFairness` 19.39% (this one is the damning framing — *"equal LPs must get equal payout (no exit-order skim)"*), plus `testFuzz_VogueDepositWithdraw` ("Received too little") and `testAlternatingSwaps` (10.78%, diluted by churn). **≈1/5 everywhere = the AAVE fifth.** Supply works (`VaultLib:177/219/316`); the recovery leg is `VaultLib:278-290`, whose `try …withdraw(…) catch {}` SWALLOWS failure — so a broken pull degrades into a silent LP shortfall rather than a revert. **TRACE-NARROWED 2026-07-26 (`-vvvv` on `testDepositImmediateWithdraw`) — it is NOT the pull, and NOT the supply. Both work:**
     - `SpokeInstance::supply(0, 2e18, Vault)` SUCCEEDS, and `getUserSuppliedAssets(0, Vault)` returns **1999999999999999999** (via `HubInstance::previewRemoveByShares`). So the AAVE slice is really deposited and really readable. The earlier `setUsingAsCollateral` suspicion is WRONG — irrelevant for a pure supply/withdraw with no borrow.
     - There is **NO `SpokeInstance::withdraw` in the trace at all**, and correctly so: `Vault::withdrawSelf` is invoked for **4.009e18, NOT 5e18**, so `withdrawETH`'s ladder is satisfied by Galaxy alone (`MockGalaxyVault::withdraw` 2e18 + 0.901e18) and the `wethBal < amount` guard at `VaultLib:280` never opens the AAVE branch. The AAVE branch is behaving as designed.
     - **THE REAL DEFECT IS UPSTREAM: the exit only ever ASKS for 4/5.** The failing assertion is the POOLED_ETH one — the band is unwound for the FULL ~5e18 (`4999999999999999969`) while only `4009905199576741564` is delivered, so ~0.99 ETH of band depth is destroyed with nothing paid out for it. (`"withdraw returns most of the principal"` PASSES at 4.009 > 4.0 — the loose bound hides it.) So whatever computes the deliverable/available ETH is not counting the AAVE-supplied slice as sourceable, even though `aaveBal` can now see it. **NEXT: find the deliverable computation feeding `withdrawSelf`'s amount** (start at `Vogue._withdraw` → the deliverable/`vogueETH` path) and check where the AAVE slice drops out.
     - 🔴 **SEPARATE, ARGUABLY WORSE DEFECT — SILENT SHORTFALL BY DESIGN.** `VaultLib:286-288` and `:292-294` wrap the AAVE and Rover pulls in `try … catch {}` with EMPTY handlers, then `:297` does `sent = wethBal >= amount ? amount : wethBal` and returns the short amount as ordinary success. A venue fault therefore becomes QUIET LP VALUE LOSS instead of a revert — this is the mechanism that let a ~20% shortfall read as normal operation, and it is what made the sentinel bug invisible for so long. Worth fixing independently of the deliverable bug.
     - Note this whole path **had never executed on mainnet before today** — it was dead behind the sentinel bug, which is why it is unexercised.
   - **2 remaining failures are PRE-EXISTING (identical before and after the fix), NOT this class and NOT in §A.2's known list — triage separately:** `test_HoldingsCache_BoldExcludedSpFires` ("SP leg fired (BOLD valued via calcSPValue): 0 <= 0") and `test_Redeem_UnwindsBandToFreeCommittedDollars` ("redeemed more than free stables … 535136822828954480479889 <= 767808068162316845319488"). They got PAST the deposit, so they are independent of the venue work; unverified whether pre-existing (checking would need a revert of the refactor, which is upstream-committed, not a local change).
3. [ ] Confirm the **return-0 fallback assumption**: base `setUp()` deploys Rover OFF (`address(0)`), so `supplyEtherFiToRover` returns 0 and the 3 no-Rover tests fall to direct weETH. If some CI variant wires a Rover in setUp, those 3 would route THROUGH it instead — re-point them or add a `setRover(0)`.
4. [ ] The **catch fallback** (self-liquidated Rover) is exercised ONLY by the two mock-revert tests — there is no live drained-pool fork fixture. Good enough for unit coverage; flag if a real drained-pool integration test is wanted later.
5. [x] SPA checked in-thread — `spa/src/lib/chains.ts` `ETH_VENUES` already omits id=1 (ether.fi = id 4 "Rover", with a NOTE that direct weETH is the internal self-liquidated fallback); stale "exit from YOUR venue" comment corrected to ether.fi-slice-only. No hardcoded `venue=1` deposit in SPA source. (Rust ETH-venue deposit path not found — ETH LP deposits are SPA/on-chain, not daemon-driven; re-grep if that changes.)

## A.4 BUILD-MACHINE BRING-UP (2026-07-26, macOS x86_64) — toolchain fixed + regtest harness made portable

The "no working build machine" blocker behind §A.3 is a MACHINE problem, now resolved on the macOS box. Recorded so no one re-diagnoses it.

**Toolchain (no repo change, no sudo needed):**
- `forge`/`cast`/`anvil` were installed but DEAD on macOS — `dyld: Library not loaded: /usr/local/opt/libusb/lib/libusb-1.0.0.dylib`. Current foundry mac builds link libusb (hardware-wallet support) and Homebrew didn't have it. Fix = `brew install libusb`. `foundryup` alone does NOT fix it (the reinstalled binary links libusb too).
- Pinned to the **stable** channel (`foundryup -v stable` → 1.5.1-stable) to match CI's `foundry-toolchain@v1 version: stable`; a bare `foundryup` installs *nightly*, which CI does not use. `solc 0.8.30` (foundry.toml pin) auto-downloads via svm — no manual solc install.
- Rust: `quid-ln/rust-toolchain.toml` pins 1.90.0 and rustup auto-installs it on first `cargo` in that dir — nothing to pre-install.

**Regtest harness was LINUX-ONLY (real bug, fixed — `regtest/{env,setup,setup-ln}.sh`):** `setup.sh` mapped `x86_64`→`x86_64-**linux-gnu**` without ever consulting `uname -s`, and `env.sh`/`setup-ln.sh` hardcoded `lnd-**linux**-$ARCH`. On a macOS x86_64 host (`uname -m` == `x86_64`) both would silently download **Linux** binaries and produce a non-executable `bitcoind`/`lnd` — contradicting the README's "self-contained, no system install" claim. Fix DEDUPS rather than adds: the two separate `uname -m` case blocks (env.sh + setup.sh) collapse into **ONE platform table in `env.sh`** exporting `BTC_PLAT`/`LND_PLAT`, which both downloaders consume; `LND_ARCH` deleted. The table is spelled out per host on purpose — bitcoin-core names arm `aarch64` on linux but `arm64` on darwin, so string-munging `uname` would be wrong. Net: fewer lines, one detection site, 4 hosts supported.
- `sha256sum` DOES exist on current macOS (`/sbin/sha256sum`) — not a portability issue.
- Two MORE Linux-only breaks found by actually running the harness (reading it was not enough): **`start-ln.sh` used `setsid`** (util-linux; absent on macOS ⇒ LND never launched and the script aborted) → now `command -v setsid || command -v nohup`, so Linux keeps its exact prior behaviour and macOS gets equivalent detachment (stdin already `</dev/null`, SIGHUP-immune, disowned). And **`stop.sh` waited on RPC, not the process** — bitcoind closes RPC BEFORE releasing the datadir lock, so `stop.sh && start.sh` raced into "Cannot obtain a lock on directory … probably already running". Now polls `pgrep -f "bitcoind -datadir=$DATADIR"`. Both PRE-EXISTING (identical semantics at HEAD), neither caused by the platform table.

### A.4.1 VERSION BUMP → bitcoin-core 30.2 + LND v0.21.1-beta (user: "use the latest upstream")
Was 28.1 (shell) / `bitcoind_28_2` (Rust) / LND v0.20.1-beta. **Chosen: 30.2 EVERYWHERE, not the literal latest 31.1** — because `driver-e2e.sh:119` hands the shell harness's binary to the Rust harness via `BITCOIND_EXE`, and **`electrsd` caps at `bitcoind_30_2` even on its newest release (0.41)**. 31.1 on the shell side alone would run an untested bitcoind under electrsd in exactly that shared path. 30.2 is the newest version BOTH sides support ⇒ one version end-to-end. (Latest upstream is 31.1; there is no 32.)
- Files: `regtest/env.sh` (`BITCOIN_VERSION`, `LND_VERSION`), `quid-hop/Cargo.toml` (×2 `bitcoind_28_2`→`bitcoind_30_2`), `.github/workflows/e2e-harness.yml` (comment). **No electrsd version bump needed** (0.40 already offers `bitcoind_30_2`).
- **Prerequisite dedup:** `driver-e2e.sh` hardcoded `bitcoin-28.1` in a path literal and did NOT source `env.sh`, so bumping the pin would have silently desynced it (it would never find the dir, re-run `setup.sh` forever). It now sources `env.sh`. That surfaced a latent **`LN_DIR` name collision** — `driver-e2e.sh` used it for the *cargo workspace*, `env.sh` for the *LND data dir*; the driver's is renamed `RUST_WS`.
- **VERIFIED END-TO-END on macOS x86_64:** `setup.sh` → `bitcoin-30.2-x86_64-apple-darwin.tar.gz` SHA256 OK → `v30.2.0`; `setup-ln.sh` → `lnd-darwin-amd64-v0.21.1-beta`; `start.sh` → regtest up; `gen-fixture.sh` → fixture; `forge test --match-path test/btc/OpenChannelE2E.t.sol` → **PASS**; `start-ln.sh` → both LND nodes synced + **alice→bob channel active (500000 sat)**. So LND 0.21.1 ↔ bitcoind 30.2 is compatible on the paths we use.
- NOT affected: the `quid-hop` Rust e2e (`--features harness`) gets bitcoind/electrs from the `electrsd`/`bitcoind` CRATES, which resolve the host platform themselves.

### A.4.2 🔴→✅ FIXTURE GENERATOR WAS STILL P2WSH (user: "we don't use P2WSH, it's taproot everywhere")
`gen_open_channel_fixture.py` built a **P2WSH 2-of-2** funding output (`0x0020||sha256(redeem)`) while the contracts have moved to **SIMPLE-TAPROOT (BOLT #995) key-path P2TR** `0x5120||Q` (`BitcoinTx.buildTaprootScriptPubKey`, `ChannelLib.locateChannelOutput/_verifyAndLocate`). Consequences: the generator emitted **no `fundingTaproot`**, so running the README's own documented flow (`gen-fixture.sh` → `forge test`) FAILED with `vm.parseJsonBytes32: path ".fundingTaproot" must return exactly one JSON value`. The referenced `BitcoinTx.buildChannelRedeemScript` **no longer exists in Solidity** — the generator was its last consumer.
- **Why CI never caught it:** the Python is NOT in any automated path. Nothing invokes it but `regtest/gen-fixture.sh`; the `.t.sol` mentions it only in doc comments; no workflow runs it. It is a **manual fixture REgenerator**, and `forge test` reads the COMMITTED `open_channel_fixture.json` (which was already taproot). So the drift was invisible to CI and only bit a human following the README. **The automated e2e flow is bash + forge + cargo — no Python.**
- **Fix:** generator now takes a real `bech32m` address from bitcoind, asserts its scriptPubKey is `0x5120||Q` (34 bytes), and emits `fundingTaproot`. Faithful because `_verifyAndLocate` does **NO EC math** — "Q is lpAuth-committed and byte-matched, NOT reconstructed from the keys" — so Q need not be a real MuSig2 aggregate for the fixture, and this keeps the file's own "no custom Bitcoin crypto here" invariant. Also fixed the stale P2WSH prose in `regtest/gen-fixture.sh` + `regtest/README.md`, and dropped the `/tmp/bitcoin-28.1` literals from the .py (version now lives ONLY in `env.sh`).
- **VERIFIED:** regenerated fixture contains `5120||Q`, no `0020`, 32-byte Q → `OpenChannelE2E.t.sol` **PASSES**. Committed fixture then restored (generator proven by regeneration; keeping the diff minimal — a regen churns the whole header chain).

### A.4.3 REGTEST DEDUP (user: "absolutely dedup as you go along")
Three variants of the same `bitcoin-cli` invocation were open-coded across five scripts. `env.sh` already hosted the LN-side helpers (`ln_ports`, `lncli_node`), so the Bitcoin-side ones now live beside them — ONE definition site: `cli` (node), `wcli` (node+wallet), `mine`, `node_up`, `require_node`. Removed the duplicate `cli`/`wcli` defs from `start.sh`, the duplicate `wcli`/`mine` + copy-pasted "is it up?" guard from `start-ln.sh`, the same guard from `gen-fixture.sh`, and the inline invocations in `stop.sh` + `cli.sh`. Re-verified after the refactor: full stop→start→cli→gen-fixture→forge-test→start-ln cycle green.

## A.5 SPA↔CONTRACT DRIFT (2026-07-26) — 🔴 found by code-verification, NOT yet fixed (surface-before-cutting)

§A.3 item 5 checked `spa/src/lib/chains.ts` only. A wider sweep of the SPA's contract seam found **three real drifts in `spa/src/lib/abi.ts` + its two consumers** — all grep-verified against HEAD, none fixed yet (awaiting the user's call, and D1 overlaps the #12 POOLED_USD merge).

- 🔴 **D1 `get_deposits` ARITY IS STALE — `uint[13]` vs the contract's `uint[15]`.** `abi.ts:83` declares `(uint[13] amounts, uint[13] yieldW, uint avgYield, uint depegLoss)` and carries an emphatic *"DO NOT use uint[14]/3-tuple — the contract returns uint[13]"* comment. **That comment is wrong at HEAD:** audit #3 (`9633064`) widened it to `uint[15]`, and ALL 9 call sites agree (`Aux:945` decl, `Aux:545`, `QuidLens:8/29`, `SOR:51/350`, `Core:970`, `BtcVaultLib:45/110`). Static arrays encode INLINE, so the mis-declared arity desyncs everything after `amounts`: `dec[1]`(yieldW) is read 2 words early, and `dec[2]`/`dec[3]` (avgYield/depegLoss) decode garbage. Third inconsistent number: the call-site comments say `uint[14]` (`page.tsx:393`, `InfoTab.tsx:94`). **Fix = one edit to `abi.ts:83` + the two comments.**
  - **EMPIRICALLY CONFIRMED (ethers 6.17, matching the SPA's `^6.16.0` pin) — ethers does NOT throw on the 4 trailing words; it silently decodes 28 of 32.** So the `try`/`catch` around both call sites NEVER fires — there is no error anywhere, just a silently short read. **Blame split, keep it straight: D1 alone does NOT corrupt the rendered stables** (`dec[0]`'s first 13 words are genuinely `amounts[0..12]`); the wrong numbers on screen are **D2's** off-by-one. D1's damage is confined to `dec[1]`/`dec[2]`/`dec[3]` and is latent only while no consumer reads them. Measured on synthetic returndata (`amounts[i]=1000+i`, `yieldW[i]=2000+i`, avgYield=7777, depegLoss=8888): `dec[0]`=`1000..1012` (first 13 right), `dec[1]`=`1013,1014,2000..2010` (2 words early, exactly as the inline analysis predicts), `dec[2]`=`2011` (should be 7777), `dec[3]`=`2012` (should be 8888). Anyone who starts reading avgYield/depegLoss off this call gets plausible-looking garbage, not an error — which is why this is worth fixing BEFORE the #12 SPA work rather than with it.
- 🔴 **D2 OFF-BY-ONE in the stables-composition display (user-visible).** `amounts[0]` is NOT a stable — it is the **yield-weighted aggregate** (`BasketLib:191` "the basket baseline (amounts[0]/amounts[14])"); per-stable values are written at `amounts[i + 1]` (`BasketLib:245`), with BOLD's canonical slot at `amounts[13]` (`Aux:959`, it is SP-routed and filled in Aux, skipped by the BasketLib loop) and raw TVL at `amounts[14]` (`BasketLib:194`). But BOTH consumers map `STABLES[i] → amounts[i]`: `page.tsx:397` (`setPerStable(dec[0].map(...))`, rendered `:1069`) and `InfoTab.tsx:98`. So the breakdown renders the **aggregate labelled "USDC"**, shifts every stable down one, and **never shows BOLD**. `SPA STABLES` itself is CORRECT (12 entries, USDC…BOLD-last, matching `DeployL1_s:229-239` "AUSD at 9, cUSD at 10, BOLD LAST at 11"). **Fix = `amounts[i+1]`, with BOLD special-cased to `amounts[13]`.** Also stale: `page.tsx:1072` comment "Index 11..13 are aggregate slots".
- 🔴 **D3 venue enum stale in `abi.ts` (the §A.3 refactor's blind spot).** `abi.ts:119-121` still documents *"0=Split(Galaxy+AAVE,default) 1=ether.fi 2=AAVE-v4 3=Galaxy 4=ether.fi Rover 5=Euler"* + *"Hard-walled per-LP: your exit is served from YOUR venue only"*, and `:140-141` repeats the same enum for `outOfRange`. Post-§A.3 there is **no venue 1**, SPLIT is an equal **5-way** (not Galaxy+AAVE), **6=Gauntlet** is missing, and per-LP attribution is **ether.fi-slice-only**. Comment-only (no wrong selector), but it is exactly the stale-comment class that misled a prior thread into believing venue 0 was a 50/50 — fix it rather than let it re-mislead.
- 🟡 **D4 (informational, blocks nothing): `CORE_ABI` exposes `POOLED_USD_ETH`/`POOLED_USD_BTC` separately** (`abi.ts:27-28`; consumed at `InfoTab.tsx:88` for the inventory-skew gauge). The **#12 unify-POOLED_USD** build will change this surface — sequence the SPA edit WITH that build, not before it.

## A.5b 🔴🔴 PRODUCTION BUG — ETH exits CANNOT source from a zero-idle Morpho-V2 venue (MEASURED 2026-07-26)

**This is the root cause of the ~20% LP-exit shortfall class in §A.5, and it is a MAINNET bug, not a test artifact.** Found by challenging the assumption that the real curator vaults were simply "unusable" (user: *"maybe you aren't approving them correctly… i got the addresses from the morpho website and you can be assured money is there"* — correct on both counts).

**MEASURED on the fork, after a real 10 ETH SPLIT deposit (2 ETH per venue):**
| real vault | our shares worth | `maxWithdraw` | vault IDLE WETH | vault `totalAssets` |
|---|---|---|---|---|
| Galaxy `0x1878…824F` | 2.0 | **0** | **0.0** | 8973.86 (**+2.0** — our deposit DID land) |
| Euler `0xD8b2…84C2` | 2.0 | **2.0** ✓ | 474.9 (≈48%) | 979.18 |
| Gauntlet `0x43fC…92da` | 2.0 | **0** | ~0 (3.6e-12) | 4720 |

**Mechanism:** Galaxy/Gauntlet are **Morpho V2** vaults (`withdrawQueueLength()` REVERTS ⇒ not MetaMorpho v1.1) that hold liquidity in ADAPTERS and **auto-allocate on deposit** — our 2 WETH raised `totalAssets` but left `idle` at 0, so `maxWithdraw` is honestly 0. They run at ~zero idle as POLICY (0 of 8971; 3.6e-12 of 4720), so this is a steady state, NOT a fork-block artifact — **pinning a different block will NOT fix it.** Euler works only because it maintains a large idle buffer.
- ⚠️ Two of my earlier conclusions were WRONG and are retracted: (1) "real vaults structurally cannot deliver" — they can, via the hatch below; (2) `maxWithdraw == 0` is NOT the "owner holds nothing" artifact I hypothesised — we hold real shares (`convertToAssets == 2.0`) and the selector returns 0 cleanly without reverting.

**🔴 THE `forceDeallocate` FIX PRESCRIBED HERE WAS WRONG — DO NOT IMPLEMENT IT (disproven by direct probe, 2026-07-26; ✅ RESOLVED a different way in `f4a1c2a`).**

The original prescription was: *"`_pull4626` must, when `maxWithdraw < need` and the venue is Morpho-V2, `forceDeallocate(liquidityAdapter(), liquidityData(), need, address(this))` and then withdraw."* It was built, and then **PROBED against the real Galaxy vault: the call SUCCEEDS, returns `penaltyAssets: 0`, and leaves `maxWithdraw` at 0 — before and after, identical.** `liquidityData()` names exactly ONE market (loan=WETH, LLTV 0.945e18) and the vault's 8971 WETH is allocated across OTHERS, so that one hatch frees nothing. It cost ~113k gas per pull for zero effect. **Removed** (VaultLib 9,791 → 9,355 bytes).

**THE ACTUAL MECHANISM — the max-views are conservative, `withdraw()` self-deallocates:**
Probed on real Galaxy holding our 20 ETH: `maxWithdraw == 0` **AND `maxRedeem == 0`**, yet `withdraw(1 ether)` **SUCCEEDS** (burning 0.9939 shares) and `redeem` returns **1.875 ETH**. Morpho V2 pulls from its adapters *inside* `withdraw`. Both ERC-4626 max-views are idle-only. **Nothing was ever stuck — we simply never TRIED**, because every read clamped by `maxWithdraw`.
⇒ **Landed:** `VaultLib._withdrawableOf` is the ONE definition — reported position (`convertToAssets(balanceOf)`) for a Morpho-V2 impl detected via the `liquidityAdapter()` marker, honest `maxWithdraw` for everything else — shared by `_pull4626`, `_deliverableCap`, `evacuate` and `Vault.venuePosition`. `_pull4626` gained optimistic-then-fall-back (retry at the venue's conservative number on revert) since the reported amount is no longer a figure the venue promised.
⇒ **SECURITY, fixed in the same commit:** `Vault.venuePosition` feeds the **permissionless** `Aux.pokeVaultHealth`. Its comment already described the hazard — a healthy Morpho-V2 venue reads 0% liquid, so ANY caller could block-then-evacuate it — but the code below still did the raw `maxWithdraw` read, i.e. the documented fix had never been applied. Now wired, with `test_PokeVaultHealth_HealthyMorphoV2_NotBlocked` pinning it.
⇒ **Measured effect:** `deliverableETH` had been returning **0** against 16 solvent ETH in Galaxy; every ETH LP exit paid out NOTHING while the LP retained a full pooled balance. LevYbWeth 98 pass/22 fail (clean baseline) → **111 pass/11 fail**.
⇒ **Still open:** the silent-shortfall defect (§A.5) — a venue pull that fails must not degrade into quiet LP value loss (`sent = wethBal >= amount ? amount : wethBal`).

## A.5c 🔴 DESIGN — `deliverableETH` IS INCONSISTENT IN PRINCIPLE (user question, 2026-07-26: *"maybe deliverableETH is not correct in principle? it has to do with leverage and what else?"*)

**Verdict: yes — it haircuts THREE legs for liquidity and counts FOUR at full face value.** Today
`deliverableETH = vogueETH − Σ(4626 illiquid gaps) − levNetEquity`, but `_vogueETH` sums SEVEN kinds of backing:

| leg of `_vogueETH` | deliverability cap? | actually convertible NOW? |
|---|---|---|
| Galaxy / Euler / Gauntlet 4626 | ✅ `_deliverableCap` | (its definition was wrong for Morpho-V2 — see §A.5b) |
| lev net equity | ✅ subtracted | NO — unwind-only via `closeLev`, never the free ladder |
| **AAVE-v4 supplied WETH** (`_aaveBal`) | ❌ **NONE** | only up to Aave's own available liquidity (supplied − borrowed) |
| **weETH at Vault** (`getEETHByWeETH`) | ❌ **NONE** | needs the offramp ladder — rung 3 costs 0.3%, **rung 4 is a multi-DAY NFT** |
| **raw eETH** (Vault + Aux) | ❌ **NONE** | sits there mid wait-NFT withdrawal; not liquid by definition |
| **Rover** (`valueWeth`) | ❌ **NONE** | only its WETH side + idle is instantly convertible — **exactly §J.8's finding** |
| idle WETH (Vault + Aux) | n/a | yes |

**It therefore errs in BOTH directions at once, which is why the symptoms read as contradictory:**
- **OVER-counts** weETH / eETH / Rover's weETH side / the AAVE leg — none promptly convertible.
- **UNDER-counts** Morpho-V2 venues, because `withdrawable` meant "idle" (§A.5b, now unified behind `_withdrawableOf`).

**THE MISSING PRINCIPLE:** "deliverable" must mean *what the exit ladder can actually source right now* — and that ladder ALREADY EXISTS in `withdrawETH` (Aux idle → ether.fi weETH sale → the three 4626s → AAVE → Rover). `deliverableETH` is a SECOND, INDEPENDENT enumeration of the same sources with a different and incomplete cap set. That is precisely the *"same quantity computed in more than one place with divergent forms"* the STANDING LAW says to unify — and here the divergence is not cosmetic, it is the bug.
⇒ **Target: make `deliverableETH` the VIEW TWIN of the withdraw ladder** — same sources, same order, same caps — so it cannot promise what the withdraw cannot pull. That collapses the hand-rolled subtraction list AND makes §J.8's Rover instant-convertible capacity a SHARED input instead of a bolt-on, subsuming §A.5b + §J.8 rather than patching each.

**Why this is the likely root of the exit-order failures:** `test_EthLp_RedeemConservationAndFairness` asserts *"equal LPs must get equal payout (no exit-order skim)"* and fails at ~19.4%. Over-counted legs ARE the exit-order advantage: the first LP out is served from the genuinely liquid legs, later LPs hit the legs that were counted but cannot convert. Same for `test_BankRun_VaultLiquidity` ("User01 underpaid").

⚠️ **NOT YET IMPLEMENTED — deliberately.** This is a design change to a solvency-adjacent view (it feeds `Vogue._withdraw`'s `firstBurn` clamp), so per the standing rules it needs the multi-approach pass + measurement before code, not a same-turn edit. The two sub-questions to settle first: (1) does the view need to model the 0.3%-fee rung and the multi-day NFT rung as *discounted* rather than excluded? (2) should `levNetEquity` stay a subtraction or fall out naturally once the ladder is the definition?

## A.5d ⚠️ DOC-TRIAGE METHOD WARNING + what `IMPAIRMENT-DERISK-TRIGGER.md` ACTUALLY decides (2026-07-26)

**A "dead symbol" scan CANNOT judge whether a doc is stale, and I got this wrong twice in a row.**
Measuring how many backtick-quoted symbols in a doc are absent from source produces these false positives:
1. **Wrong tree** — v1 of the scan checked only `evm/src`, so Rust/SGX/SPA names read as dead: `TAPROOT-CHANNELS-BUILD-SPEC` scored **88%** (LDK types: `ChannelMonitor`, `AggNonce`) and `HOP-CUSTODY-SGX` **61%** (`EGETKEY`, `EREPORT`). Re-scanning across `quid-ln` + `spa/src` + `regtest` + `deploy` + `indexer` + `sims` dropped them to **26%** and **13%**. v1 would have condemned two valid specs.
2. **Aspirational names** — a MIGRATION plan naming files it intends to CREATE should score ~100% dead. `EIP170-MIGRATION.md` tops the corrected list at 54% purely because `BtcLevLib`/`CoreLib`/`LevMathBtc`/`SwapLib2` don't exist YET. High score ⇒ read it, never ⇒ delete it.
3. **Deliberate citation of REMOVED code** — the case below.

**`IMPAIRMENT-DERISK-TRIGGER.md` is NOT stale: it is a LIVE product/risk decision (user, 2026-07-26).** It scores 48% dead (`_growShort`, `_closeShort`, `_maybeShort`, `_shortTargetLive`, `pinShortVenue`) *because it argues AGAINST reviving them.* Do not delete it. What it decides:
- **The strategy as BUILT = "up-lever + hold-down":** above entry, lever to delta-1 (IL-free + fees); below entry, de-lever to 0 and HOLD, letting the LVR-free band heal the "impermanent" IL. A buy-the-dip-and-hold bet on recovery.
- **The one regime where that is WRONG (§4):** a sustained crash that does NOT recover — a structural re-rating. IL becomes PERMANENT, and it is doubly bad because the band doesn't merely hold the dip, it **OVER-holds** it: it keeps buying ETH all the way down, so you ride it down AND accumulate more. Framing: hold-down is **negative-skew / short-gamma** — "fine, fine, fine, ruinous" (the XIV profile); fine in the ~95% of regimes that mean-revert, ruinous in the ~5% that don't.
- **Why it is sharper for a STABLECOIN (§3.3):** that tail is NOT independent — it is correlated with the peg's worst moment. A systemic crash is exactly when redemptions spike, so hold-down leaves the pool on an over-concentrated depreciating bag *while* redemptions pull at it — a run dynamic stressing `D ≥ S + L`. **"Safe for the LP" and "safe for the backing" are different questions, and hold-down is arguably worse on the second.**
- **It does NOT ask for the short back.** It explicitly REJECTS both: `_growShort` (an always-on short bled the round-trip premium on every recovering dip) AND a triggered stop-loss (a dip is indistinguishable from a permanent re-rating ex-ante; ETH has no regime signal ⇒ whipsaws).
- **Its proposed answer is a DIFFERENT, UNBUILT product (§5): delta-1 MAINTAINED through the down-side** — stay levered below entry and rebalance to hold delta-1 (trim the over-hold as ETH falls, re-add on recovery), routed through our LVR-free band. Beats YieldBasis (same delta-1 protection + levered fees, but LVR stays IN-pool instead of leaking to arbers) and beats hold-down (linear tracking, no wrong-way gamma, bounded loss). Its cost is exactly what hold-down shed: funding cost + liquidation risk (carrying debt into a falling market) + the round-trip LVR premium on recovering dips.
- **The decision (§7), a product call not a code task:** hold-down (BUILT) = long-biased, cheap, negative-skew, fat-tailed · delta-1-maintained (NOT built) = neutral, priced, tail-free, the true YB competitor. For a stablecoin BACKING engine §3.3 pushes toward delta-1; for a long-biased book hold-down already ships.
- **This IS the queue's "Short subsystem 🧭 OPEN (anchor)"** — hence #85 and #97 are CONTINGENT on it: taking the §5 product re-opens the below-entry rebalance leg, but as a **levered capital-structure change, NOT the removed spot short.**

## A.5e 🟠 STALE-CACHE SOLVENCY FALSE-NEGATIVE — redeem values off `storedHoldings`, refreshes AFTER (2026-07-26)

**PIN RESOLVED — it is the HIGHER-severity branch.** The open question was whether `redeemAsBody` values off the CACHE (⇒ real over-draw) or off a live sum (⇒ only mint-valuation/band-sizing sees the stale window). Verified: **the cache.**
- `redeemAsBody` values via `IAux(this).get_deposits()` (`BasketLib:879`), and `Aux:946` passes **`storedHoldings`** in.
- Inside `get_deposits` the balance is read straight from storage — `Holding storage h = storedHoldings[stable]; balance = h.balance;` — and that same `balance` feeds BOTH the per-stable slot AND `amounts[14]`, the **TVL/backing sum**. No live `convertToAssets` on this path.
- `Aux` then calls `_refreshAllHoldings()` **AFTER** `redeemAsBody` returns (`:932`, "redeem does a FULL refresh"). So the order is **value → draw → refresh**.

⇒ **A redeemer inside the inter-op window values against stale-HIGH backing and can OVER-DRAW**, concentrating the loss on remaining holders — precisely the harm the live depeg haircut exists to prevent, but this vector slips past it because it never touches a depeg feed.

**Amplifiers (both verified):**
1. Health DETECTION is live (`convertToAssets`/`maxWithdraw` in `pokeVaultHealthBody:18-19`), so there is **no** false negative in detection — the false negative is in the BACKING SUM only.
2. `pokeVaultHealth` is **never scheduled** (§S39 GAP-1), so nothing marks a venue down proactively; the refresh depends entirely on organic ops.

**Scope/severity — LOW–MED, deliberately not overstated.** A **depeg** is caught LIVE (`getDepegSeverityBps` inside the haircut), so the exposed vector is narrow: a **no-depeg 4626 bad-debt drop** (venue loses value without any stable losing its peg) landing between mutations. Frequent ops bound the window.
**Fix directions (not yet chosen):** refresh the touched stables BEFORE valuing rather than after; or have the redeem path value off a live sum while keeping the cache for the hot read; or schedule `pokeVaultHealth` (closes GAP-1 too). Each is a different cost/benefit — needs the multi-approach pass before code.

## A.5f 🔴 TODO — NO ON-CHAIN PER-ACTION AUTHORISATION for the delegated strategy layer (user, 2026-07-26)

The strategy layer draws QUI for optimal entries and lever-LPs the proceeds under **delegated, revocable** permissions. The authorisation is split across two layers and **only the off-chain half exists**:
- **Off-chain (BUILT):** `quid-common/src/api/revocable_clients.rs` — `RevocableClients` keyed by **ed25519** pubkeys, each issued a `RevocableClientCert`, with `is_revoked`/`is_expired_at`, `MAX_LEN = 100`; plus `Scope` (`api/auth.rs:173`) and a `BearerAuthToken` (~15 min). This authenticates **who may talk to the node/gateway**. NOTE it is **NOT EIP-712** and **NOT fine-grained** — `Scope` has exactly two variants, `All` and `NodeConnect`.
- **On-chain (MISSING):** only COARSE gates — `onlyUs`, `vogueSyncHook`, `msg.sender == V4`. Those say *"this exact contract"*, never *"this delegate may do these actions, up to these limits, revocably."* There is no on-chain object expressing e.g. *"this keeper may draw ≤ X QUI for entries and lever-LP the proceeds."*
⇒ **Build target:** on-chain per-action delegation (EIP-712 typed permissions / ERC-7710-7715-style), scoped + capped + revocable, so the on-chain gate matches the off-chain revocability model.
⇒ **NOT needed for the BTC path:** `lpAuth` is `ecrecover` over `BTCChannels.openChannelDigest` (plain keccak digest with `hop` bound in to stop cross-submitter replay) — typed data would add nothing there.
⇒ The **optimal-entry ALPHA logic stays deliberately off-chain / LP-discretionary** — that is by design, not a gap.

## A.5g 🔴 NO PRODUCTION HOP RECONNECTOR — capability exists, only the TEST harness wires it (2026-07-26)

`quid-ln/OFFCHAIN-STRATEGIES.md:85-92` claims *"Persistent hop reconnector — LIVE, `quid-hop/src/reconnect.rs`"*. **That file does not exist**, and this is NOT merely a stale pointer — verified:
- The primitive IS built: `quid_ln::p2p::connect_peer_if_necessary` (+ `..._with_retries`, `p2p.rs:154/170`).
- Its ONLY caller anywhere in `quid-hop` is **`harness.rs:156` — the test harness** — and the sole `tokio::spawn` in `quid-hop` is likewise in `harness.rs`.
- `quid-hop/src/peer.rs` wraps LDK's `PeerManager`, but **LDK does NOT re-dial on its own**: `PeerManager` manages sockets it is handed; outbound reconnection is the integrator's job — which is precisely what `connect_peer_if_necessary` exists for.
⇒ **In production nothing re-dials a dropped LP peer.** A dropped connection stays dropped until some unrelated path happens to reconnect. This matters for the hop specifically because swap-in/swap-out settlement and channel ops all assume peer reachability.
⇒ **Fix is small and reuses what's there:** spawn a persistent reconnect task in the hop daemon's `JoinSet` calling `connect_peer_if_necessary_with_retries` on a cadence — no new mechanism, just wiring the built primitive outside the harness. Decide the cadence + backoff (user call).
⚠️ Same doc has two more stale file pointers, lower stakes: `:101 lp_fees.rs` and `:51 swap_out.rs` — that functionality moved to `store.rs` / `swap_out_onchain.rs`. Retarget rather than delete.

## A.6 STATUS RECONCILIATION (user audit, 2026-07-26) — every row CODE-VERIFIED at HEAD before re-tagging

The user supplied a built-vs-marked audit. I verified each claim against the source rather than accepting it (same rule that caught the sentinel bug: **the code is ground truth, and that applies to audit tables too**). All six confirmed.

**BUILT but under-credited — stop treating these as open work:**
| # | Item | Verified evidence at HEAD |
|---|---|---|
| **#101** | Loosen swap guard / oracle-via-TWAP | ✅ `SwapLib.twapResolve:186-204` **provably never reverts** — the Chainlink read is `try/catch {}` and EVERY path returns, including the `feed == address(0) \|\| price == 0` early return. Large swaps degrade to partial-fill instead of reverting. |
| **#81** | WBTC-base leverage collateral | ✅ `BtcLevManager:107` → `LevMath.vetVenue(v, WBTC, address(VBTC), WBTC)`; the in-code comment is explicit: *"c1=WBTC ⇒ WBTC venue allowed"*. Atomic path `:432-498`. |
| **#106** | BTC lev venue layer (vBTC↔WBTC / per-stable) | ✅ `BtcLevManager:87-99` — `allowedVenue` mapping + `venuesFrozen` + one-shot `init(hook, flash, venues)`, *"mirrors LevManager so a WBTC venue can sit beside the vBTC one"*. |
| **#89** | fold-vs-parallel dedup (Rust) | ✅ `lev_keeper_btc.rs:221` — *"#9/#89: out_of_band DEDUP'd → now imported from lev_keeper (the ONE shared predicate). Local copy removed."* Import at `:26`, used at `:120`. |
| **#103** | keeper gas constants vs measured | ✅ `lev_keeper.rs:266` `COMPOUND_GAS = 140_000` *"MIRRORS `Vogue.COMPOUND_GAS` … Keep in sync"*; the self-funding gate `compound_pays_for_itself` at `:272`. |

⚠️ **NUANCE on #81/#106 — do NOT read `EIP170-MIGRATION.md:22` as a built/unbuilt ledger.** That line is a table of *projected bytecode savings from planned migrations* (`| BtcLevManager | #106 venue layer, #108 …, #85 | ~1.5–2 KB |`). The FEATURES are built; what is outstanding there is EXTRACTING them for EIP-170 headroom — a different axis. Two separate states got conflated into "unbuilt".

**OVER-CLAIMED DONE — downgrade:**
| # | Item | Reality at HEAD |
|---|---|---|
| **#84** | "unify `lev_keeper` + `lev_keeper_btc` into ONE task" | 🔴 **NOT DONE.** `daemon.rs` still spawns TWO tasks: `:430` `set.spawn(run_lev_keeper(...))` and `:466` `set.spawn(run_btc_lev_keeper(...))`. Only `LevKeeperConfig` (both call `LevKeeperConfig::default()`) and the `out_of_band` predicate (#89) are shared. So the DEDUP landed; the UNIFICATION did not. The doc already flags 🔴 near `lev_keeper_btc.rs:221` — it is the task list that was wrong. |

**Lesson worth keeping:** the failure mode in both directions is a doc/tracker asserting a state the code contradicts — under-crediting (#101/#81/#106/#89/#103) wastes work re-deriving what exists, over-crediting (#84) silently drops it. Re-verify a status tag at its mutation site before trusting it, exactly as the STANDING LAW says.

## A.7 STATUS RECONCILIATION ROUND 2 (user audit, 2026-07-26) — the CORRECTED open-work list

Second audit pass. Again code-verified before re-tagging. **This section is the STATUS-OF-RECORD for the items below; where an older §C/§D row disagrees, this wins.**

**BUILT but mis-marked (stop re-deriving these):**
| # | Was | Reality at HEAD |
|---|---|---|
| **#102** | pending | ✅ **BUILT** — cUSD/stcUSD deploy-wired (`DeployL1_s:238,255,357`) + Redstone feed. **Only gap: no fork test.** |
| **#109** | in_progress | ✅ **BUILT** — inline `closeLevFor` is LIVE at `Vogue:502-505` (`levPooled>0 && amount>plainNet ⇒ closeLevFor(lp,0)` then `_reconcileLev`). It was mis-marked by a **stale docstring** at `Vogue:426` still saying "INLINE WIRING DEFERRED" + listing two blocking forks. **Comment corrected in place 2026-07-26** with how both forks actually resolved. |
| **#114** | in_progress | ✅ **BUILT** — full dead-man daemon: `deadman_exit.rs`, keyless `quid-recover-exit.rs`, `emitDeadManExit` encoder, on-chain sink `BTCChannels:868`. |
| **#97** | "no cleanup landed" | ✅ **EFFECTIVELY DONE** — the cleanup WAS removing stale short-management code post-#95, and it is gone everywhere (both keepers clean, EVM short-grow removed). **Absence of refs IS the cleanup** — reading it as not-done was the error. Contingent on the short staying removed. |
| **#85** | open | 🧊 **MOOT** — "post basket-stables as short collateral" presumes the short BORROWS. It does not (`_growShort` was self-funded). No borrow ⇒ nothing to collateralize or de-stack. Re-opens ONLY if a borrow-based short is ever restored (see the §J.4 "Short subsystem" anchor). |

**🔴 #107 / D3 — CONFIRMED OPEN, and doc:404 is WRONG. The θ FORMULA is settled/closed; the D3 NUMERATOR SWAP is not built.**
Verified at HEAD: `VogueLib:341` is literally `theta = mulDiv(IAux_VG(aux).avgYield(), 1e18, work)` — the numerator is **reserve** `avgYield()`. `grep -c skewPremium src/Aux.sol` = **0**. `Aux:969` folds `spYieldWeighted` (Liquity **Stability-Pool** yield) into `amounts[0]`, which is what makes the two look alike — but band **skewPremium** (the retained market-making fee) is NOT folded anywhere.
⇒ **doc line 404's "✅ DONE — folds skewPremium" describes code that is NOT at HEAD → treat as ❎.** The correct build is **θ-LOCAL** (doc:515): feed the band's realized FEE yield straight into `derivedThetaWad`. **Do NOT fold it into the shared `avgYield`** — that same accessor also feeds `seedFee` mint-valuation, so folding would move mint pricing as a side effect.

**🔴 #100 — the ACTIVE WBTC flash-serve. UNBUILT either way; only the TRIGGER is undecided.**
Two readings share the SAME core op and differ ONLY in trigger:
- **(A) PROACTIVE permissionless rebalance** — anyone calls a depletion-check entrypoint: flash WBTC → `creditSwapIn` → SOR a **PENDING** swap-out's USD → repay.
- **(B) REACTIVE JIT** — the flash fires inside/right after a swap-OUT when the vBTC reservoir is too thin: flash WBTC → deliver that swap-out → repay from **THAT** swapper's USD.
Both = "flash WBTC, serve the opposite BTC flow, repay, keep the skew premium for LPs". **STATUS: UNBUILT** — there is no `flashLoan` site for reservoir refill; every flash site in the tree is leverage de-lever.
**What IS built and must NOT be re-confused with it:** LP-entry pump (`registerBtcLp`), premium retention (`retainSkewPremium`→`skewPremium*`), geometric re-center (`Vogue.reseat`/`Rover.repackNFT`). See §J.3 for the full pin.

**Corrected 🟡 PARTIAL rows (impl vs test/loop split):**
- **#113** — 🟡 impl DONE (`LevManager:781-810`, mirrors BTC) / **ETH-side test MISSING** — only the BTC mirror is exercised. `DeleverEthBackingProbe` does not exist.
- **#84** — 🟡 PARTIAL — still two `set.spawn`s (`daemon.rs:430` + `:466`); only the CONFIG + `out_of_band` predicate are shared, **not the loop**. A true single supervised ETH+BTC keeper task remains to build.
- **#59** — 🟡 on-chain DONE / native rail deferred — expose/unexpose channel BTC as vBTC collateral + WBTC atomic on-chain lever/de-lever, no external acquirer. Solidity route built; the **native BTC↔stable de/re-lever is a loud no-op**, deferred with #74.
- **#74** — 🟡 — BTC borrow ROUTER preferring native (vBTC) with WBTC fallback: router selection + WBTC atomic path built; the **native execution arm is the deferred Rust rail**.
- **#72** — 🟡 rebalancer DONE / MM-RFQ DROPPED — we do NOT run an MM engine; what remains is a **READ-SEAM** (reservation offset / TWAP / fee) that an EXTERNAL Bebop-shaped MM/solver consumes.
- **#110** — 🟡 refund DONE (#105) / **LADDER OPEN** — the redeemNFT-shaped partial-fill ladder + SPA warning + optional bounty.

**✅ THE CORRECTED VERIFIED-OPEN BUILD LIST (everything else is built, moot, or 🧊 don't-build):**
**#18** puppeteer harness · **#100** flash-serve (trigger TBD) · **#107/D3** θ-local numerator · **#110** partial-fill ladder + bounty · **#113** ETH de-lever test · **#115** deeper 4626 refactor · **#84** true keeper unification · plus **#59/#74** native Rust rail (deferred-by-design).

## A.8 VERIFICATION PLAN (user, 2026-07-26) — Slither FIRST, then Echidna. Both are the LAST layer, after the TODOs.

**Order is load-bearing: Slither runs first** (static, cheap, no fork/RAM) **and its output feeds the Echidna target list** (§C#20). Do not start either until the open-work list above is closed — the user was explicit that this is the end-of-queue layer.

**Slither targets:**
- **Money-path reentrancy** — especially the HAND-ROLLED `nonReentrant`; consider just replacing it with solmate's `ReentrancyGuard`.
- **Access-control / arbitrary-call surfaces** — `onGovernanceReport` (arbitrary call), and the CONSISTENCY of the `onlyUs` / `onlyBTCChannels` gates.
- **Public-library `delegatecall`** — `LevMath` / `SwapLib` / `VaultLib` / `BtcVaultLib` unprotected-delegatecall detector.
- **This session's work specifically** — the venue refactor's no-fallback revert paths, plus #113/#114 which are forge-UNVERIFIED.

**Echidna money-path invariants (with the scaffolding to REUSE — per §C#20, reuse `DeployLib`, do not hand-roll a stack):**
| Invariant | Property to prove | Reuse |
|---|---|---|
| **Crash-drain solvency** (the headline "protected against drain?") | crash → mass redemption drains band → big skew premium → prove it NEVER prices out an urgent de-lever/redemption; backing ≥ supply + levered throughout | `DrainProbe.t.sol`, `BufferSwapDrain.t.sol` |
| **POOLED_USD count-once / no-double-spend** | after the #12 unify: `committedUsd18` counts the shared pool ONCE, sum-cap dropped, stale-pre-read racing swaps revert — prove no drain | new harness on `Core:91/93,106` |
| **Skew conserves premium** | `retainSkewPremium`→`recordSkewPremium` never creates/destroys value; the `mo`→manip-guard retune (#5) captures premium band-internal without harm | `LeverageCrossSubsidyProbe.t.sol` |
| **Base-LP no-free-lunch** | clean USD-space: swap output ≤ curve, `minOut` respected, no value extraction | doc §S rot-phase 18 |
| **Leverage reflexivity bounds** | backing-dilution / self-inflation bounded; no cross-subsidy of the levered leg by the plain leg (R1 zero-subsidy) | `LevCascade.t.sol`, `LeverageCrossSubsidyProbe` |
| **ETH de-lever backing (#113's missing test)** | `DeleverEthBackingProbe`: Σbacking invariant across a swap-out reaching levered depth (debt↓ + netEquity preserved) | mirror `LevYbWethProbe` |
| **vBTC totalSupply** (post-#115 mint/burn removal) | expose/unexpose single-count, no phantom supply | doc §O #1 |
| **Depeg cherry-pick** (the biggest test-rot) | `EconAttackProbe` has ~4/6 **log-only asserts that CANNOT FAIL** (#76) — convert them to real property checks; concentration-fee interaction is the standing DEFERRED NOTE | `EconAttackProbe` |

## B. DESIGN VERDICTS (load-bearing decisions)

- **θ Merton:** `θ=avgYield/(K·σ²)`, K=kLvrWad (band α, `VogueLib:263`), σ²=realizedVarianceWad; Merton-optimal risk-capital fraction into the IL bet. Fails OPEN (θ≥1e18 / cold ring → no-op). Higher α → higher K → lower θ → less levered depth (directionally right; magnitude = #107 D6).
- **surplus-vs-skew:** keep **surplus** as the sizing CAP (hard backing constraint D≥S+L); **skew** = PRICING signal (A-S reservation), already used so. Ideal LAYERED: `size=min(surplus_cap, θ·vol_cap, skew_desired_depth)` — skew pulls depth toward imbalance, never past safety ceilings. deltaTok is the right variable; the only defect is the `vogueAvail` argument (#1).
- **IL-neutral / 2×:** 2× (5000bps)=delta-1; hedge target=`1−√(entry/now)` (ilTargetBps) clamped at cap; boughtFractionWad=ground-truth over-hold (#94 band-bounds ~1% at ±2%). Up-side-only is the PROVEN baseline; down-side short is opt-in (wbtcShortOptIn).
- **R1 zero-subsidy (tested `LeverageCrossSubsidyProbe:42-44`):** every leverage leg executes EXTERNALLY, never the internal band. **LIVE REGRESSION:** `_growShort` ETH sells into the band (`LevMath:747 swapTo`) then SOR overflow (`:756`) — cross-subsidy violating the invariant (taker: passive LPs accumulate the falling asset; maker: jumps the passive queue). **Fix = external-route the ETH short sell (SOR only).** Fair price ≠ fair risk transfer.
- **De-lever-into-pairing:** #54 deleverOnDelivery (own proceeds repay debt → free collateral → deliver; value-neutral, single-pay) = necessary & non-toxic, BUILT. #67-rejected = force-unwind to manufacture NEW band backing = forbidden subordination. proceeds-repay OK; freed-USD-as-new-depth toxic.
- **Native-BTC map VERIFIED SOUND:** `funded=LP.pooled−levPooledBTC`=spliceable physical sats; levPooledBTC=synthetic unwind-only ("no channel BTC behind it", `Vault:179,819`); swap-out clamps shrinkSats to funded (`BtcVaultLib:239`); funded invariant across syncLevBTC; #54 is the ONLY synthetic→physical bridge. Rule: splice only funded; de-lever first to reach the levered slice.
- **Stale-cache-from-non-hooked-change class:** correct = live-on-read (matureSupply loop, touchBaseRate elapsed×decay); buggy = snapshot-at-hook + time-drift. Members: vote-median (#11), committedUsd18 interest (#5), storedHoldings/CAPO (#4), levPooledBTC. **Keep hunting this class.**
- **POOLED_USD shared-pool:** POOLED_USD_ETH/BTC mirror the SAME dollars; debiting both = consistency not double-spend; racing swaps → 2nd reverts on stale pre-read. Efficiency = drop sum-cap (each side sizes vs `TVL−own_committed`, debit both). **REQUIRED SAFETY:** committedUsd18 must count the shared pool ONCE, not ETH+BTC summed. Answer "protected against drain?" = the procyclical DoS residual → Echidna stress-block. **The median STAYS as the BTC risk-exposure cap (btcShareBps); the efficiency win (drop sum-cap) is orthogonal.** Optional NEW guarantee: per-side reserved liveness FLOOR (median-set) so correlated demand (both spike → shared pool starves one; BTC can't instant-retry like ETH) can't dark a market — an addition, not something lost by sharing. **Repurposing the median for a single-sided-LP volatile-fee→dollar-side split = DECIDED AGAINST (user, 2026-07-21: creates more problems than it solves) — do NOT build or re-propose.**
- **Refill-bonus / MEV:** don't win the race — ELIMINATE it. (1) atomicity: urgent exit/de-lever self-contained in its own tx, never refill-dependent. (2) JIT-internalize the imbalance into the draining tx (#100 volatile reservoir = home). (3) fair continuous A-S price, not a discrete jackpot. Fleet as normal refiller on self-funded gas (#87) → premium→LPs; payRefillBonus stays only as bounded fleet-down fallback. **atomic-flash-close is UNVERIFIED — prove owed settles on reserve/premium within one call vs needing a paired outflow BEFORE building.** (Existence check: keeper/RFQ refill was deliberately removed `Vault:722-730`; reintroducing = reversal, confirm.)
- **#95 sell-anchor:** zero-borrow (tower/debt-A/_closePass/SHORT_LLTV deleted); withdraw own base→sell→park stable (sv.debtOf==0). Symmetric ETH/WBTC; native vBTC no-SOR degrades safe (undo→up-side-only). Borrow-capable Morpho inverse-market unused by YB (park-only) — reserved for the directional short. De-rot: split park-only vault from inverse-market config, kill stale "implements inverse market today" comments.
- **Directional long (>2×):** cap itself IS the opt-in (`setTargetLtv>5000`), but keeper doesn't HONOR it (always drags to ilTargetLive). 2×-hardwire branch closes both: `cap==5000`→hardwired IL-neutral hedge; `cap!=5000`→directional (long via cap, short via wbtcShortOptIn), keeper=liquidation-guard only. Key off `targetLtvCapBps==5000` + honor cap-as-target when ≠2×; no new venues. (Existence: no boolean long-opt-in today; >2× implicit via LTV to ~4×.)
- **mature_quid_usd → maturity-or-FIXED-HAIRCUT:** NO secondary market to price unmatured QUID. Two honest options: wait to maturity (full value), or a **hardcoded conservative protocol haircut** for emergency liquidity — never a quote. protectFromQuid redeems mature at par; if it touches unmatured, a fixed fair haircut. (Existence: today unmatured is EXCLUDED entirely; BTC keeper hardcodes mature_quid_usd=0. BUILD the haircut path.)
- **Acquirer:** REMOVE `UnwiredNativeAcquirer` + `BtcLevAcquirer` trait/legs (`lev_keeper_btc:77,91`). It's a fail-SAFE stub (bails→de-lever re-supplies); WBTC-mode never invokes it. Kill the external-acquirer indirection; inline the fail-safe de-lever. Audit ALL live stubs: needed→fulfil fully, unneeded→delete.
- **#107 θ-μ (D3):** derivedThetaWad uses `IAux.avgYield()`=RESERVE yield (`VogueLib:298`); should be the band's realized FEE yield. NOT landed.

## C. OPEN AGENDA (build queue + asks; existence-annotated)

> ⚠️ **STATUS-SOURCE NOTE:** this §C list's 🔴/✅ tags are the OLDER layer and are NOT auto-keyed to §A's findings or the SESSION STATUS dashboard — some 🔴 here are since ✅ DONE (e.g. #1 θ-base `c48ea01`; #11 vote-median). Before working any §C item top-down, cross-check its live status against **SESSION STATUS** (top) + **§A** + **§S** (freshest), which are authoritative. Treat §C as the agenda's index, not its status of record.

1. 🔴 **θ-base fix** (#1/D4) — closes siblings #7,#8. HIGH.
2. 🔴 **CAPO** growth-cap wrapper (#4) + extend `EconAttackProbe:95` donation probe (stcUSD thin vs sUSDe deep) to assert the guard. Probe EXISTS — extend, don't rebuild.
3. 🔴 **F2/F3 Core gate fixes** (#5 min(debt,bufUsd); #6 gross-collateral scarcity term).
4. 🔴 **Vote-median lazy-resync** (#11) + keep hunting the stale-cache class.
5. ❎/🧊 **Short's ETH sell — doc framing was BACKWARDS (2026-07-22 verify-intent).** NOT an R1 leak: the band-internal sell routes `swapTo(forVolatile=false)` → `SwapLib.swapToBody` sell → `sellSkew` → `recordSkewPremium`, so the imbalancing short PAYS the skew premium and it's retained for OUR LPs (mock+onlyUs ⇒ no external LVR, we capture all price impact). The overflow-to-SOR at the `mo=fairPrice·(1−1% MAX_SLIPPAGE_BPS)` floor is the *actual* leak — it hands the 1%→band-capacity slice of premium to an external DEX. Real fix = LOOSEN `mo` toward the band's manip-guard capacity (~3%/30min) so we capture the premium band-internal, overflow to SOR only at true exhaustion. **ECHIDNA QUESTION (2026-07-22, user — keep Stoikov, don't simplify):** the `mo=fairPrice·(1−1% maxSlipBps)` floor prevents NO protocol harm — the slippage the short eats band-internal accrues to our other LPs (internal transfer), so the floor just leaks the 1%→3% premium slice to SOR. The ONLY bound that prevents real harm is the manip guard (±3%/30min = the DoS fence — KEEP). Target behavior: capture everything up to the manip-guard capacity, overflow to SOR only when a fill would trip the guard (rebalance slippage is real but internal-capture still beats a 100% SOR leak). Prove the safe `maxSlipBps`→manip-guard retune in the Echidna stress-block; do NOT retune now.
6. 🔴 **2×-hardwire keeper policy** (cap==5000→auto IL-hedge; else directional) + **honor directional LONG (>2×)** symmetric with the short (keeper honors cap-as-target). No boolean long-opt-in exists yet.
7. 🔴 **mature_quid_usd → fixed conservative haircut** (Rust + on-chain protect path); wire the BTC-keeper mature read (hardcoded 0 today).
8. 🔴 **Remove the acquirer** (trait+legs+stub); inline fail-safe de-lever; audit all live stubs.
9. 🔴 **#84 keeper union** — one supervised ETH+BTC loop (two separate set.spawns today, `daemon.rs:414/450`).
10. ✅ **cascadeDeleverMany for BTC** — DONE (uncommitted/unbuilt): `BtcLevManager.cascadeDeleverMany(lps, minOuts)` mirrors ETH `cascadeDelever` — batched atomic `rebalanceWbtc`, fault-tolerant (`DeleverFailed`; native-vBTC members skipped since they use async legs), NOT nonReentrant (each call self-locks). EIP-170: BtcLevManager is near the wall — validate at final build.
11. 🔴 **Refill-bonus→LPs via fleet free-Morpho-flash** — VERIFY atomic-close FIRST; reconcile with the deliberate no-keeper-refill design.
12. 🧊 **POOLED_USD shared-pool efficiency — SPEC CLARIFIED (2026-07-22), Echidna-gated.** Corrected understanding: today the two POOLED_USD are INDEPENDENT and `committedUsd18 = _bandEquityUsd18(ETH)+_bandEquityUsd18(BTC)` (SUMMED) ⇒ the shared TVL is effectively SPLIT between bands (the inefficiency). Target: the two mockUSDs MIRROR the same dollars (move in lockstep; debit both = consistency, not double-spend); `committedUsd18` counts the shared pool ONCE (required safety); DROP the sum-cap so each side sizes vs `TVL − own_committed` (reaches full shared TVL minus its own commitment); racing swaps → 2nd reverts on stale pre-read; `btcShareBps` median STAYS as the BTC risk cap (orthogonal); OPTIONAL per-side reserved liveness FLOOR (median-set) so correlated demand can't dark the market (BTC can't instant-retry like ETH). **"Protected against drain?" IS the Echidna stress-block question — this change is gated on that proving the drain-safety + that the efficiency is real/worth it.** (NOTE: there is NO `tryPair`; no gross sum-cap in executable code — only the stale `Core:48` comment describes the old cap.)

**SKEW/POOLED SUBSYSTEM DECISION (2026-07-22, user):** hold the whole skew question — rip-out of (a) procyclical drain-premium, (b) self-funding permissionless refill, (c) imbalancer LP revenue — for the Echidna block, and only pursue it IF the EIP-170/simplification efficiency it unlocks is real and worth it. Items #5 (skew retune) + #12 (POOLED mirror) fold into this one gated decision. **ALSO IN THE BUNDLE (2026-07-22): (i) refiller economics** — the bonus MUST stay PERMISSIONLESS (external capital); CORRECTION (2026-07-22): fleet-refill is NOT inherently procyclical — the risk is NET BTC EXPOSURE (accumulating crash-bought BTC), not funding. A zero-fee Morpho flash lets the fleet refill JIT-passthrough (flash BTC → serve a pending swap-out → repay from that swapper's USD), spending NO basket backing and accumulating NO directional position. Toxic ONLY if UNBOUNDED speculative accumulation. So: permissionless bonus (external capital) + a BOUNDED flash-funded fleet fallback are BOTH non-toxic; the bound (not the funding) is what prevents knife-catching. Echidna's "protected against drain?" must prove the reservoir refills without toxic backing-spend. **(ii) reseat-at-edge** — reseat the band when spot hits the band edge (vs fixed cadence) for capital efficiency (#71/#101 surgical reseat); BAND_DELTA=20 floor (single-tick degenerates the reseat re-add + realizes IL per reseat). Flash de-lever has NO implicit arb (value-neutral maintenance); without the refill bonus, reservoir refill becomes a subsidized keeper op. **DRAIN vs IMBALANCE (2026-07-22, user — CORRECTED): only SWAP-OUTS create an IMBALANCE (directional: BTC out / USD in) that triggers the skew + JIT refill. REDEEMS do NOT trigger JIT — a redeem is a BALANCED unband (proportional, both sides) even when it unwinds levers, so no imbalance, no refill, no skew premium. (Echidna crash-drain still models mass redemption for solvency, but redemption is not a JIT/skew trigger.) SwapLib/BtcLevManager/LevMath are at/over EIP-170 — the skew is the biggest reclaimable chunk, which is what makes the rip tempting.
13. 🔴 **Urgent-path atomicity trace** — confirm redemption / urgent-de-lever / close never block on a separate refill landing first.
14. 🔴 **Short-venue de-rot** (park-only split from Morpho inverse-market/oracle/LLTV; kill stale borrow comments).
15. 🔴 **#75** LevManager + BtcLevManager hand-rolled nonReentrant → solmate ReentrancyGuard.
16. 🟡 **Remove "YB" everywhere + "#107"-style tags from comments** — "#107" half DONE (0 hits in `evm/src`, verified 2026-07-22); "YB" half OPEN (28 hits across 14 src files).
17. 🔴 **Rename fleet/delegated-strat surface → Clutch.**
18. 🔴 **SPA** (off-chain): recognize ERC20 balances + on-chain positions; levered LP → whole-position value + auto-route deposit (top-up collateral→grow 2× base) / withdraw (auto-de-lever), no manual leverage-tab; short/long directional opt-in = fine-grained control; SOR right stable→WETH/WBTC via multicall (only if not enough unlevered vBTC to swap-in nor vBTC on Morpho/Euler to borrow against); markers: stable-selection (over-weighted, ≤-avg-yield, min hops), cheapest/deepest venue, USD→WBTC best-exec, Rover.
19. 🔴 **#107 derivations D1-D7** (numbers): D1 IL(α) concentrated vs `1−√` under-hedge; D2 α-aware hedge target shape; D3 θ numerator reserve→band-fee-yield; D4 θ-base (=#1); D5 IL-neutral exactly-2× or α-dependent; D6 less levered depth under higher α — right LVR budget or more elegant amortization; D7 leverage-cap denominator (=#2).
    - **📥 BACKFILL (D1/D2/D6 derivation setup — moved from agent-memory + source so these are buildable WITHOUT private context):**
      - **α = the band's concentration param = `kLvrWad`** in code (the LVR/concentration knob). The wide-pool relation `V_c ∝ √p` is the low-α limit; a MORE-concentrated band has a steeper `V_c(p)`.
      - **IL-vanishing anchor (verbatim from the `LevMath.ltvBps` docblock — verified in src):** a constant-leverage-`L` position has value `V* ∝ V_c^L`; a √p band has `V_c ∝ √p` ⇒ `V* ∝ p^(L/2)`; **`L=2` ⇒ `V* ∝ p` ⇒ IL cancels**, and `L = 2 = 2·α⁻¹` at the measured `α≈0.5`. That is the exact-2× (D5) result for the wide-pool α.
      - **D1 (IL(α) concentrated vs `1−√` under-hedge):** the shipped hedge target `1−√(entry/now)` = the band's SOLD FRACTION — an α-agnostic APPROXIMATION. A band MORE concentrated than the α≈0.5 baseline has STEEPER true IL than `1−√`, so the target UNDER-hedges. **To DO:** derive true IL as a function of α=`kLvrWad`, compare to `1−√`, size the gap. (No closed form written yet — the setup + the L=2 anchor above are the starting point; this is a derivation task, not a look-up.)
      - **D2 (α-aware hedge shape):** replace the static `1−√` with a target keyed to the LIVE α (`kLvrWad`) so the hedge matches D1's concentrated IL.
      - **D6 (depth-budget under higher α):** higher α ⇒ steeper IL ⇒ more hedge debt ⇒ less deliverable depth per unit equity. **🔴 OPEN VERDICT (genuinely undecided — exists nowhere, needs a call):** is "higher-α → less-levered-depth" the correct LVR budget, or should the extra IL be amortized differently (over time/fees) rather than cutting depth? A DECISION, not just a derivation.
      - θ (D3/D4) is the settled half: **θ = avgYield/(K·σ²)** — D4 θ-base = #1 (DONE `c48ea01`); D3 = swap the numerator from reserve avgYield to band realized-fee-yield (= task #107 proper).
20. 🔴 **Slither → Echidna** money-path invariants (backing≥supply, POOLED no-double-spend, skew conserves premium) — REUSE existing harness (check scaffolding first); manipulation floor = one uint min-half-life.
    - **✅ GATE RE-INSTATED + CAPABILITY CONFIRMED (user, 2026-07-26: "do not delay echidna verification, we have the capability to do this now").** This REVERSES the 2026-07-24 "no Echidna needed for now, verify later" lift recorded at §C#12/`:743`. Echidna verification now travels WITH the build-all work, not after it. Verified on the macOS build machine: **Echidna 2.3.2** (`/usr/local/bin/echidna`, brew), **slither 0.11.5**, **crytic-compile 0.4.1**, and **16 GB RAM** — which clears the 8–16 GB bar the note below sets, so the "too heavy" verdict is OBSOLETE HERE (it described a 3.5 GB box). Caveat: the standalone `solc` on PATH is 0.6.7 (nix); the project needs 0.8.30, so crytic MUST be driven through the foundry framework (`--compile-force-framework foundry`) to pick up forge's svm-managed 0.8.30 — do not let it fall back to the PATH solc.
    - **✅ "REUSE existing harness" IS CORRECT — reuse `DeployLib`, do NOT hand-roll a stack (2026-07-26; corrects an earlier wrong note in this doc that called it a dead end).** Searching for `*echidna*` filenames finds nothing and `evm/test/harness/` is unrelated (`LevKeeperTarget`/`FreshnessTarget` are anvil targets for the RUST keeper's RPC plumbing) — but that is the wrong thing to look for. **The reusable harness is the DEPLOYMENT scaffolding:**
      - **`DeployLib.deployQuidStack(StackConfig) → StackAddrs`** (`src/DeployLib.sol:106`) stands up the WHOLE stack (Vogue/Core/Aux/Basket/Vault + optional SPVGateway/BTCChannels/Rover) in ONE call. It is `internal` and explicitly "runs in the CALLER's context" (`:43`), so an Echidna harness CONSTRUCTOR calls it exactly as production (`DeployL1_s.sol:290`) and the mainnet-fork suite (`Alles.t.sol:423`) already do. Same entry point ⇒ the fuzzer exercises the REAL deployed topology, not a model.
      - **Echidna 2.x forks**: set `rpcUrl` + `rpcBlock` in `echidna.yaml` to get the mainnet state the stack needs (PoolManager, tokens, Morpho vaults, feeds) — the same reason `driver-e2e.sh` and `Alles.t.sol` fork.
      - **Copy these load-bearing details from `Alles.t.sol` setUp, they are NOT optional:** (a) the **ANGEL #16508 seed** — the deployer must hold it or Basket's ctor check fails (`:415-422`); (b) **nonce alignment** — Core's mock tokens derive their addresses FROM Core, and `_initPool` orients each synthetic pool by an address comparison (`token1isVol = volMock > usdMock`), so Core must land at the same deployer-nonce or the pools flip orientation (`:402-414`); (c) mock venue 4626s are created AFTER the shared deploy at PREDICTED addresses to preserve (b).
      - **⚠️ VERIFY BEFORE BUILDING:** `Alles.t.sol` setUp uses FOUNDRY cheatcodes (`vm.getNonce`, `vm.computeCreateAddress`, `vm.prank`). Echidna runs on **hevm**, which supports only a SUBSET — confirm each one, or reproduce (b) without cheatcodes (the nonce math is computable, and ANGEL can be sourced by fork-state manipulation). This is the one real porting risk; it is a porting cost, NOT a reason to hand-roll a second stack.
    - **RAM / MACHINE (2026-07-22, superseded above for this box):** Echidna is TOO HEAVY for the dev box (3.5 GB). It drives crytic-compile→solc, and solc on this protocol ALONE peaks ~1.7 GB / 900 s under memory pressure and OOM-kills when anything runs alongside; the fuzzer memory (per-worker EVM state, corpus, seq-len) stacks ON TOP. A meaningful whole-protocol campaign (Core+SwapLib+Basket+Aux+Vault+lev managers) realistically wants **8–16 GB**. **RUN ON A BIGGER MACHINE (user will).** Locally-runnable only if scoped hard: `--workers 1`, short `--seq-len`, and a MINIMAL harness contract that instantiates just the drain/POOLED invariants (not the whole system) → ~2–3 GB.
    - **PRIMARY DEFENSE IS BY-CONSTRUCTION, not the fuzzer:** manip guard (±3%/30min, #5), per-side liveness floor + count-once + stale-read-revert (#12). Echidna VALIDATES those on the big machine; it does NOT gate building them. The crash-drain stress-block ("protected against drain?") is the one that genuinely wants full RAM. The `mo`→manip-guard retune (#5) and POOLED-mirror drain-safety (#12) are its two headline questions.
21. 🔴 **Puppeteer e2e** (happy+unhappy, all integrated paths) — front-end fuzz before Slither/Echidna.
22. 🧊 taproot §10 audit; M11-on-hardware; AUDIT residuals (Link→multisig, onGovernanceReport arbitrary-call, settleSwapIn nonReentrant LOW).

**Execution order (top-down by leverage):** 1 θ-base → 2 CAPO+probe → 3 F2/F3 → 4 vote-median → 5 short external-route → then the rest of the build queue. Only ✅ so far: #102 uint[15] (`9633064`).

## D. RECOVERED USER ASKS (transcript sweep of every question + directive; NEW or refining)

Line refs are into the session JSONL. These were dropped from the agenda in compaction — pinned here.

**Unbuilt gaps (real missing pieces):**
- ❎ **#95 `recordSkewPremium` rail — ACTUALLY BUILT (doc claim was WRONG, code-verified 2026-07-21).** The levered LP's band-sold slice DOES pay the A-S skew premium → passive LPs: `LevMath._growShort:749` sells base into the band via `swapTo(...,forVolatile=false)` → `SwapLib.swapToBody` sell branch → `sellSkew` → `retainSkewPremium` → `Core.recordSkewPremium:219` (accrues skewPremiumETH/BTC, drawn by payRefillBonus). Do NOT re-implement. (The "called nowhere in LevMath" note read a stale state — it's called via swapTo→SwapLib, not directly.)
- 🔴 **`outOfRangeBtc` vBTC-funded mirror UNBUILT** — USD-funded only; an order filling into BTC has that leg burned in `Core._settleTokSide` (documented deferred gap). (L7093)
- 🟡 **C-priced sell-anchor hedge UNBUILT** — the short sizes off base-price + boughtFraction, not collateral-value C. DECIDE if wanted, then build. (L7093)
- 🟡 **`_withdraw` de-lever capacity** — caps at `pooled−levPooled` (`Vogue:446`), does NOT auto-delever. DECIDE on-chain auto-delever vs SPA-only. (L7093)
- 🔴 **surplus==0 / empty-band BTC swap-out hop** — served by real channel BTC + btcShortfall hop. Decide if worth building; document non-empty behavior. (L946)

**Deploy / ownership cluster (NO prior agenda coverage — high value):**
- 🔴 ANGEL seed-NFT burn: `ICollection(F8N).transferFrom(deployer, address(0), ANGEL)`; ownership renounced ONCE; **no `_transferOwnership`**; approve + deploy in one statement; deployer checked ONLY in DeployL1_s; **drop `lamboHeld` var**; minimalistic; pretend-execute on mainnet fork. L2 deferred. (L5714/6095)
- 🔴 Justify the ICollection interface's existence; **remove `onERC721Received`/`onERC20Received` from Aux**; CHECK DeployL1_s performs the approve. (L6073/6075)

**Refinements to existing items:**
- 🔴 **Acquirer removal nuance** — the acquirer served non-band LPs + explicit non-LP swap-in; CHECK that role is fully absorbed before deletion; "#67 may not forbid deliverDelever — just check." **Audit ALL live stubs, not just UnwiredNativeAcquirer:** delete unneeded, FULLY complete needed. (L280/287/6819)
- 🔴 **Fix stale "no-ops till acquirer" comment** on `setWbtcShortOptIn`; **remove GOV/hook gating from `closeLevFor`** — "there is no GOV." (L3659)
- 🔴 **Lever parity CHECK** — BTC/ETH YB lever in Solidity AND **Rust**; SPA exposes discrete 1× increments above 2× (3×/4×/5×) with keeper auto-adjust. (L3546)
- 🔴 **committedUsd18 fix must preserve the deliberate committed-identity 3+4 coupling** (do (a), don't break the coupling). (L694)
- 🔴 **Define `surplus` precisely** = excess over redeemable-today matureBalance + de-band clawback from BOTH POOLED_USDs; permitted uses = borrow-cost + QUI redemption ONLY, never withdrawable at will. (L838/852/4270)
- 🔴 **ETH-cap per-asset fix** `isBTC→skewWad→_maxWellSkew` (folds into #15 _btcCapClamp). (L5674)
- 🔴 **Venue-repay clamp-before-forward hardening** (folds into H1/H2). (L5674)
- 🔴 **#84 refine** — user explicitly wanted ONE unified loop; confirm no inefficiency. (L6787)
- 🔴 **Manipulation floor** = a minimum half-life (one uint) the adaptive decay can never go below. (L7035)
- 🔴 **Trace atomicity** — redemption + urgent-de-lever confirm none block on a separate refill/rebalance landing first; flag any that do. (L7035)
- 🔴 **Echidna stress-block** — crash → mass redemption drains band → big premium → refill race; prove it never prices out an urgent de-lever/redemption. (L7035)
- 🔴 **#97 rust cleanup** status reconcile (residual of #95/#71). (L4792)

**CHECKs / derivations (answer with code/numbers):**
- 🟡 **deltaTok sizing off skew vs surplus** — pros/cons; confirm θ-clamp isn't the wrong risk-bearer (= finding #1). (L6636/6658)
- 🟡 **2× fold math** — ETH needs multiple hops for full 2×; borrow premiums exceed that — where does the difference come from? who pays interest? Verify the deposit-borrow-swap fold loop is explicitly in code ("THERE IS NO BORROW ONCE"). (L3645/3751)
- 🟡 **Final borrowed leg venue** — can it deposit in a best-yield venue distinct from the borrow venue? (L3677)
- 🟡 **IL target** — cross-check against the YieldBasis **vyper reference** in the projects folder; assess consequences of dropping it. (L3775/4270)
- 🟡 **Router native+WBTC** — combine (band + SOR split) or stay either/or? (L3775)
- 🟡 **Keeper re-lever on rallies** to hold 2× (via intents/off-chain-strat) vs no-continuous-churn. (L3719)
- 🟡 **Over-weighted stable spend routes through the ETH path?** (L4560)
- 🟡 **Delta-1-below-entry "band-bounded residual" claim** — real or stale hallucination? (L6838)
- 🟡 **Design-superiority confirm** — no short-LLAMMA cost, no soft-liquidations vs YB. (L3677)
- 🟡 **Native force-close LLTV buffer** vs BTC-confirmation latency — needs a measured channel-close-time distribution; define the vBTC-market basket-seed. (L6787)
- 🟡 **Status checks** — JIT depth-guarantee §3 backing fork; **SOR significance-weighting**. (L6787)
- 🟡 **Waterfall/seniority** — confirm none in design; is sell-LP-equity inevitable when assets were borrowed? (L3474)

**Refactor / infra:**
- 🔴 **Codebase-doc generator** — forge doc only understands natspec; our comment blocks are richer. Build a small purpose-built generator that reads the comment blocks → headings + impl links. **Prototype on ONE contract for sign-off, then run across the tree.** (From the "document the entire codebase using the comments" directive.)
- 🔴 **Whole-Solidity gas/bytecode sweep** for further refactor wins (beyond LevMath). (L4408)
- ✅ **ERC-7201 / diamond-storage — DECIDED AGAINST (2026-07-21).** No ERC-7201 namespaced storage: no gas benefit (it's a bytecode play, not a gas win), so not worth it. Do NOT implement; drop from the queue. (supersedes the earlier "do the simpler one" ask)
- 🔴 **5 named test workstreams** (rot phase 17–21): hollow-test masses (~15, EconAttackProbe first); base-LP no-free-lunch invariant (clean USD-space); leverage reflexivity bounds (backing-dilution, self-inflation, large-move-guard); 5 swap-pricing pins; #50 band-gate-haircut pin. (L5674)

## E. COMPLETENESS-CRITIC OMISSIONS (adversarial doc-vs-transcript diff)

**⚠️ CORRECTIONS to earlier sections (were STALE — fix before acting):**
- **Pump #100 is NOT a keeper/RFQ refill.** Corrected design (user-confirmed 2026-07-17): #100 = the **symmetric second half of the on-chain skew** — reward the refill-DIRECTION swap-in with the skew bonus when scarce, a mirror of the swap-out drain penalty (`SwapLib.creditSwapInBody`, mirrors drain penalty `SwapLib:1062-1067`; the `payRefillBonus` rail already pays it). The Section B refill verdict's "keeper/JIT reservoir" framing is superseded — the mechanic is on-chain skew, already partly built. The OPEN question is fleet-*capture* of that bonus (my verification: needs a paired external volatile buy — arb, not self-closing).
- **BTC keeper IS already spawned** (`daemon.rs:451`, commit `60a0290`) — the old "keeper NOT spawned" HIGH is resolved. Section C #9's real gap is **loop UNIFICATION** (efficiency), not spawning.
- **Aave-v4 IS donation-immune** (critic was WRONG, verified 2026-07-21) — `aaveBalance` (`Aux:1249`) = `getUserSuppliedAssets` = Aave liquidity-INDEX balance (grows only from borrow interest, not a donated balance). CAPO (#4) scope = the **4626 `convertToAssets` legs ONLY**; the Aave legs need no wrapper. **CONTESTED (user, 2026-07-21):** user asserts aavev4 legs have the SAME donation problem. The index-read basis (`Aux:36-40`, share × liquidity-index) code-supports immunity — but RE-VERIFY against Aave *v4*'s actual accounting (any v4-specific rate/utilization manipulation vector, or whether the real target is an Aave-v4-*based 4626 wrapper*) before finalizing CAPO scope as 4626-only. Also: the 4626 set is WIDER than a handful — Wintermute/Sky/etc. curators, ~1+ per stable — CAPO must wrap EVERY 4626 leg, not an enumerated few.

**Numbers / constants (load-bearing, were absent):**
- 🟡 **Leverage-cap ramp table** (answers D5 concretely): sold-fraction leverage ramps WITH the rally — `2× (5000bps)` IL-neutral only after price **×4**; `3× (6667bps)` at **×9**; `4× (7500bps hard cap)` at **×16** (`LevManager:488`). D5 is no longer "open" — this is the answer.
- 🟡 `MAX_WELL_SKEW = 3e16` (3%) hard TWAP-anchor skew cap (`Vogue:766`).
- 🟡 `PROTECT_MARGIN_BPS = 1500` (15%) de-lever ceiling (`LevMath:206`); 4× cap sits ~11% under the 86% Morpho/Euler LLTV line.
- 🟡 Overlay committed-equity ratio **0.25–0.5× (minimal) up to 1× (default = full vBTC-base backstop)**, LP/keeper-settable.
- ✅ Keeper gas (#103) TUNED: Vogue.compound `COMPOUND_GAS=140_000` / `MAX_GASPRICE=200 gwei` (`Vogue:1242`); Rover `COMPOUND_GAS=600_000` = measured ~560k (RoverFork) + ~7% margin (`Rover:57`; stale "#103 finalizes" placeholder dropped). **Rust `lev_keeper.rs:266 COMPOUND_GAS=140_000` MIRRORS Vogue's on-chain constant** — the keeper's subsidy-free break-even gate `pending/2 ≥ gasprice·COMPOUND_GAS` (`lev_keeper.rs:273`) reads it, so the ONLY standing invariant is: any future change to a Solidity value MUST update the Rust mirror in lockstep. (session 0f5876e3 corrected the stale doc "Rover 250k UNVERIFIED".)

**Issue numbers the critic surfaced — VERIFIED DROPPED/DONE (2026-07-21), NOT open** (the critic pulled these from a task-tracker attachment mixing dropped/done items; always code-verify before listing):
- ~~#99 USYC RWA~~ DROPPED · ~~#72 MM RFQ~~ DROPPED · ~~#59 acquirer 3-layer spec~~ DROPPED (acquirer removal still needs the Section-D swap-in-role-absorbed check, but there's no #59 spec to honor) · ~~#101 swap price-move guard~~ DONE (`Core:718` extreme sqrtPriceLimit; isManipulated only for repack/reseat, not a swap revert) · ~~#66 B4~~ not a recognized open item, dropped.

**TODOs / checks (flash-crash residuals — important, were absent):**
- 🔴 **Black Thursday (a) oracle-lag:** the de-lever trigger must read a **fast/spot or the venue's own liquidation oracle, NOT a lagging TWAP** — never trip later than the venue liquidates.
- 🔴 **Black Thursday (b) inclusion:** multi-block congestion delays de-lever (mitigated not eliminated by priority gas); **requirement: `PROTECT_MARGIN` > price move across worst-case reaction+inclusion lag, sized for BTC vol.**
- 🟡 Confirm solvers can't use our venue for price-manipulative intents (2× fixed + mock onlyUs pool). (L6574)
- 🟡 weETH-with-Liquity-v2 question (answered via memory: weETH not a Liquity branch — record it). (L4270)
- 🟡 Swap-in reservation exclusivity — "no other swap can grab the reserved swap-in, is that what we want?" (L1205)

**Decisions / invariants (were absent):**
- 🔴 **INVARIANT #1: collateral must be unconditionally withdrawable** (#37) — WETH "park-borrowed-leg-for-rehyp-yield" mode DROPPED (rehyp risk); weETH primary; escrow-with-no-collateral-yield deliberate (`MorphoEscrowVenue:40`/`EulerEscrowVenue:43-46` verified escrow-only).
- 🔴 **Fold dual-mode = either/or router, NOT split** (settled) — native-vBTC-fold + WBTC-overlay-fold share ONE path, router picks. (Refines Section C item 9-adjacent / build #9.)

**Rust / SPA / other:**
- 🔴 **#89 concrete:** `out_of_band` predicate DUPLICATED across `lev_keeper.rs` + `lev_keeper_btc.rs` (dwell already shared; only the predicate copied) — dedup.
- 🔴 **#11 bridge decisions:** rebalancer acting-half policy (auto-splice-out = NONE per memory), on-chain-invoice (deletes registry), concrete `BtcHeaderSource`/`InvoiceReader` impls.
- 🔴 **SPA cushion framing (#25):** ComfortPanel = ONE "cushion" slider (minimal→max cushion, framed as CUSHION not leverage-×) + 3-number stress preview (+30%/−30%), IL-protect toggle folded in (not a separate card).
- 🟢 **SPA/e2e infra already built** (context for #21): self-hosted indexer (`SPV/indexer` TS+SQLite `/flow`), anvil-fork deploy+faucet harness, env-overridable addrs + EIP-1193 shim (#14/#16/#17). Puppeteer builds on this.
- 🟡 **SPA weETH-venue cost-opt (folds into C#18):** for a weETH-collateral lever, prefer a weETH-NATIVE Morpho/Euler/Aave venue over routing Rover→WETH→BOLD when the Rover NFT is already balanced (skips the V3 swap fee). On-chain `Rover.absorb` idle-bound already self-limits the conversion (won't disturb a balanced NFT), so this is a pure cost-opt, NOT a safety gate — the safety is handled. (session 0f5876e3; memory `weeth-rover-bold-path` L19/25)
- 🟡 **`amp.sol`** (old/) = reference for the AaveV3 hardcoded-index + deepest-venue depth check.
- 🟡 **deleverdeliver lib-fold** refactor question — could it fold into the others? (L2238)
- 🟢 A 100+ item persistent task-tracker exists (attachment L42, IDs 5–106); the doc mirrors most. NOTE: its "pending" statuses are unreliable (mix dropped/done) — the critic's #99/#101/#72/#59/#66 were all dropped/done on code-verify. Trust code + user, not the tracker.

## F. ASSISTANT-CREATED ISSUES (self-originated mid-thread, never tracked — all verified UNBUILT)

The axis that leaked the doc-generator: issue numbers the assistant opened while working and dropped. Each confirmed absent in `evm/src`.

- ❎ **#108 — BTC deferred-deliverability: DON'T BUILD (2026-07-22 verified).** The ETH sibling `deliverableDeferredETH` was REMOVED as dead in commit `3240705` ("unused speculative code" — a passthrough to a public aggregate, no keeper reads it). No Rust keeper reads any deferred-deliverable. BTC deliverability is already exposed via the live `BtcLevManager.totalDeliverableDollars` (#20-verified). A `deliverableDeferredBTC` passthrough would resurrect the exact dead-view its ETH twin was deleted for. Absent ≠ open.
- 🔴 **#109 — auto-delever in-band levers on band-exit: BUILD (2026-07-22, user-converged v3).** Superseded reasoning trail: (v1) "don't build, side-effect is harm" → (v2) "build for YB-2× only, leave directional untouched" → **(v3 FINAL = the UNIFIED model, §G below).** One-line: `levPooled>0` ⟺ in-band ⟺ auto-de-lever candidate for ANY trigger (redeem / swap-out / withdraw / keeper) — YB **and** directional alike, NO selection gate; the only YB-vs-directional branch is the *settlement math* on the touched LP's residual. **DEPRECATED v1 text (trail only):** Not "deferred" — WRONG. Force-closing an LP's separate lever as a side-effect of a band withdraw is a real financial HARM (not a semantics call): it crystallizes their opt-in DIRECTIONAL P&L at a time/price they didn't choose, strips control over a distinct overlay product, and can book a loss they'd have waited out. Current behavior is the CORRECT default: `_withdraw` caps at `pooled − levPooled` (free only), lever stays unwind-only via `closeLev` — respects band/lever separation. CORRECTION (user): crystallizing is only harmful for a DIRECTIONAL lever (opt-in >2× long / short) — a SEPARATE bet that must NEVER be auto-put-in-band or auto-closed. But the YB 2× (IL-neutral, delta-1) lever IS automatically IN the band, so auto-delevering it on withdraw and crystallizing at an unchosen price is FINE and MUST happen (they are a band participant). So the right #109 = auto-delever the YB-2×-in-band slice on withdraw (the LP gets whole-position value), gated to leave any directional overlay untouched. Directional side-effect = the harm; YB-2× side-effect = correct.
- 🔴 **#110 — swap-out opt-in ladder** + SPA partial-fill warning + bounty. Only generic SPA work (C#18) is captured; the ladder/partial-warning/bounty mechanics are not.
- ❎ **#104 — "internalize A" (de-lever-into-swap-out) double-pay path — RESOLVED (no build; already correct).** The "missing internalizeTap" was a false premise: the internalization IS the additive split in `Vault._resizeBtcLp` — `delevUsd = deleverOnDelivery(...)` (debt half, no QUI) + `resizeBtcLp(..., exactUsd - delevUsd)` (mint half). Single-pay is STRUCTURAL: `delevUsd + (exactUsd-delevUsd) ≡ exactUsd`, delevUsd∈[0,exactUsd], disjoint sat ranges, one-LP-per-slice, swapId consumed. Design decided (all sides): Option A (LTV-improving) > B (liquidation window) / C (under-serve); v4 (pool-routed, one conservation law) > v3 (bypass, leaves a residual); flash-fallback for the debt-stable-unsourceable edge REJECTED — delivery is inherently two-phase (splice pays swapper before EVM settles), so the `#13` DeleverStableUnavailable revert is a natural async re-try, not a gap, and flash would add callback surface + slippage to the hot path for a loss-free retryable case. Building `internalizeTap` would REINTRODUCE double-pay. Fork-proved by `testReal_DeliverSideDelever_SwapOutTapsLeveredSlice` (single-pay/obligation-cleared/replay-blocked). Closure documented at the split site in Vault.sol.
- 🟡 **flash-repay-first de-lever → relocate `BtcLevManager`→`LevMath`** (BtcLevManager ~1.2 KB headroom can't hold flash orchestration). Flash de-lever still in BtcLevManager today. (L4875)
- 🟢 **"merge/dual" owed reminder** (L334/L564) — a self-acknowledged un-discharged item the assistant never pinned down (distinct from the resolved USDT0-slot merge). Vague; surface if it clicks.
- ✅ **Parallel-thread contended-file reconciliation** — MOOT: user declared (this session) "all of it is now your thread's responsibility," so there is no separate thread to coordinate; I own every shared file.
- ✅ Verified FULFILLED (don't re-do): atomic-revert test `requireFull=true`⇒`SwapInPartialRejected` (`Alles.t.sol:2013-2027`); θ-formula self-check; #67-BTC revert check.

## G. DE-LEVER MODEL (CONVERGED 2026-07-22) — the unifying spec for #109 / #10 / #9 / redeem·swap-out·withdraw

Arrived at over ~6 user corrections this session. This section is AUTHORITATIVE; where earlier rows (#109 v1/v2, the "redeem excludes committed" plan, the "pool YB" idea) disagree, THIS wins.

### G.0 The invariant (user, verbatim intent)
> "you must never be in a position where whatever takes your asset out of the band or out of aux doesn't delever you."

Nothing removes a levered in-band / in-Aux asset without de-levering it. No unbacked extraction, ever.

### G.1 Auto-band rule (what lands in the band)
- **YB exactly-2× (delta-1, IL-neutral, NEVER short)** auto-bands **by contract** — it is a band participant the moment it opens.
- **ANY directional lever (>2×, long OR short)** does NOT auto-band. The lever loop produces an asset; the LP decides: (a) LP-deposit it → that **bands** it (and, being levered, the contract MUST track it for unwind); (b) hold / basket.mint a stable → sits in **Aux** (still must de-lever on any exit). A stable held at the end of the loop that is basket.mint'd must never leave without de-levering.

### G.2 The ONE discriminator
`levPooled[lp] > 0` ⟺ **in-band** ⟺ **auto-de-lever candidate for ANY trigger.** It is NOT a YB-vs-directional flag — a directional lever the LP chose to band ALSO has `levPooled>0` and IS touchable. "Anything in the band opts into auto-close, regardless of YB or directional" (user).
- **REGRESSION GUARD (I made this error 3×):** do NOT write "directional net-equity is the LP's own bet, so it stays untouched by redeem." FALSE. In the band = touchable by redeem/swap-out/withdraw/keeper. Period.

### G.3 The ONE mechanism (reactive/proactive dedup — user Q "why can't you unify")
Per-LP primitive: **`LevManager.deleverToVault(lp, extractUsd, sink, minOut)`** — value-neutral partial de-lever (flash-repay-FIRST → repay ΔD=X·debt/netEq → withdraw+sell paired collateral → surplus to `sink`), LTV PRESERVED, capped at #67 `deliverableDollars`, position stays OPEN. Body in `LevMath.extractToVaultBody` (delegatecall, EIP-170). Gated `vogueSyncHook || address(this)`.
- **REACTIVE = ONE shared entry `LevManager.deleverBook(usdWanted, sink, minOut)`** — walks the book (manager OWNS `_openLps`, so the walk lives THERE, not duplicated in the basket), fault-tolerant via the SAME `try this.deleverToVault(...)` self-call pattern as `cascadeDelever`. **BOTH redeem AND swap-out call this one function** — that's the dedup. BasketLib reaches it via `core→Vault.LEV_MANAGER()` (existing `IWiredCore`/`IWiredVault`, no new interfaces) and passes `sink = address(this)` (Aux).
- **PROACTIVE stays distinct — and CAN'T fully merge:** `cascadeDelever(lps, minOuts)` (`LevManager:720`) restores each position to TARGET (per-LP `deleverRepayUsd = Δ/(1−t)`, value STAYS in the position — a health rebalance, not an extraction). Different per-LP INTENT (restore-to-target vs extract-to-sink) ⇒ can't be the same call. What they SHARE (and now do share): the book, the flash primitives (`_deleverFlash`/the mode-callback), and the fault-tolerant self-call loop shape. BTC still lacks the proactive batch → **#10** builds `cascadeDeleverMany` there.
- "Know WHEN to delever" = only on the residual shortfall past FREE (funded) depth; "when NOT" = funded sufficed. Ranking: `deleverBook` walks book-order (each tap value-neutral + #67-capped, so order only picks WHICH lightly-levered LPs are tapped); strict LTV-descending is the proactive cascade's job (keeper supplies the ranked list).

### G.4 Settlement — the ONLY place YB vs directional branches (a per-position flag, applied to the touched LP's RESIDUAL claim; never a selection gate)
- **YB** → residual keeps the GUARANTEE (principal at full upside − IL + full 2× fees earned while levered); any **EXCESS** upside banked from the levered part is **socialized to all LPs** (stays in the band via feesPerShare / shared depth). `levPooled == netEquityEth` = the LP's claim via lpShares.
- **Directional** → residual keeps **their OWN** upside (their bet's P&L is theirs, not socialized).
- **RESOLVED (user 2026-07-22): DERIVE `isYB`** (leverage ≤2× & delta-1 ⇒ YB) — no stored bool; the settlement branch reads live position geometry.

### G.5 Ownership model — why the sweep is per-LP, and the pooling decision
Venue positions are **per-LP ISOLATED, not contract-owned-aggregate** (verified): Morpho `onBehalf=lp` + `isAuthorized(lp,adapter)` ("isolated by construction — one liquidation hits that LP's position", `MorphoEscrowVenue:35`); Euler per-LP **sub-accounts** `address(this)^subId` ("one LP's liquidation can never cascade into another's", `EulerEscrowVenue:39`). So proportional de-lever needs LTV-ranked *selection*.
- **DECISION: keep everything ISOLATED; do NOT pool YB.** Pooling YB into one manager-owned position first looked like a simplification (trivial shave, collapses #9/#10, drops per-LP venue perms). But: a **directional lever CAN be in-band** (G.1), it is isolated AND an auto-de-lever candidate, so the per-LP isolated LTV-ranked sweep is **unavoidable regardless**. Pooling YB on top would add a SECOND parallel de-lever path, not remove the machinery → redundant. One isolated mechanism, discriminated by trigger, is tighter. (User drove this: "if we keep directional isolated but the LP in-bands it as a candidate for auto-delevering, we still need all that machinery.")

### G.6 Redeem specifics (corrects the pre-compaction plan)
- **`_redeemQuote` does NOT change.** Fresh read: `perShare` is SOLVENT-based, so `wantUsd` ALREADY includes levered backing's value; the `committed` exclusion only governs what's paid from FREE stables first. Dropping it would just try to pay levered value from free stables (which don't exist for it). The stale "drop the committed exclusion" plan is WRONG.
- The fix is purely in **`_settleRedeem`'s shortfall path** (`BasketLib.sol:889`): after `unwindForRedeem(need)` (plain band) comes up short, the residual (`need − freed`) IS levered backing being unbanded → de-lever the residual from the book via the G.3 sweep (highest-LTV-first, value-neutral, LTV-improving), add freed to `delivered`. Invariant-safe: without this, dropping the funded-cap would let `unwindForRedeem`'s `_burnInRange` (capped at POOLED_ETH, which INCLUDES levPooled) burn levered depth WITHOUT de-levering — the exact violation.
- **Redeem is a BALANCED pro-rata unband ⇒ NO JIT / NO skew.** Only **swap-outs** (directional) create an imbalance → skew premium + fleet JIT refill. (User corrected an earlier "redeems trigger JIT" to this.)

### G.7 Withdraw specifics (#109-withdraw — HIGH CONFIDENCE, reuses `closeLevFor`)
`Vogue._withdraw` (`Vogue.sol:413`) caps at `plainNet(pooled, levPooled)` (FREE only); §4.2 cover-lever primitive `LevManager.closeLevFor(lp,minOut)` is BUILT but inline-wiring was DEFERRED on two forks (`Vogue.sol:394-405`). Both now RESOLVED:
- fork (b) "force-closing a SEPARATE lever as a side-effect is a semantics call" → RESOLVED by G.2: in-band (`levPooled>0`) = band participant, auto-close is correct not a side-effect; directional-out-of-band (`levPooled==0`) is structurally untouched.
- fork (a) "no minOut in `_withdraw` → sandwich" → RESOLVED: `closeLev` returns equity as **unsold collateral** (weETH/WETH direct to LP); only the debt-repay swap sells, self-floored to ≤`MAX_SLIPPAGE_BPS` by the flash-coverage requirement (op reverts past it). `minOut=0` ⇒ bounded ≤1% crystallization — exactly the in-band crystallization the user sanctioned.
- **Wiring:** when a withdraw reaches past FREE depth (`levPooled>0 && amount > plainNet`), call `closeLevFor(msg.sender, 0)` THEN `_reconcileLev(msg.sender)` inline — the callback's `syncLev` re-entrancy is nonReentrant-BLOCKED under the withdraw lock (try/caught → stale slice), so the manual reconcile clears the now-0 slice so the cap re-reads to full pooled. LP gets lever value as collateral (already delivered by closeLevFor) + free band depth.

### G.8 vBTC/WBTC on withdrawal (user check)
WBTC-mode LP withdrawal MUST **sell WBTC → dollars** (else "you get exactly the vBTC you put in"). vBTC (native channel claim) is NOT sellable → the down-side/close path uses external WBTC and `Aux.sorSelfFundedReverse` (WBTC→stable). ETH side: `closeLev` returns weETH/WETH collateral (LP wanted ETH exposure — correct). BTC side needs the WBTC→stable sale on the withdrawal/close leg — verify wired in the BTC sweep (#10) not returning raw WBTC.

### G.9 Directional keeper auto-unwind (user check — CONFIRMED already correct)
Keeper auto-unwinds OUT-OF-band directional LPs via `closeLev` → `transfer(lp, back)` (`LevManager:780`): freed collateral incl. full directional P&L → **the LP** (keeps their upside). That's the opposite of in-band YB (guarantee + socialize excess) and is WHY out-of-band directional stays isolated. Existing behavior, no change.

### G.10 Build order (batch — ONE forge build at the very end, per user "in a hurry, don't build after every change")
1. #109-withdraw wiring (G.7) — reuse `closeLevFor`+`_reconcileLev`. **✅ DONE (Vogue.sol, uncommitted/unbuilt).**
2. Redeem shortfall sweep (G.6) — **✅ DONE (uncommitted/unbuilt):** `LevMath.extractToVaultBody` (extraction body), `LevManager.deleverToVault` (per-LP) + `deleverBook` (shared reactive walk) + mode-2 flash callback + `_extractCfg`/`_lastFreed`, `BasketLib._settleRedeem` shortfall→`_deleverBookForRedeem`→`deleverBook`. **EIP-170 WATCH:** LevManager +~600B (was 851B headroom), LevMath +~400B — VALIDATE at final build; if over, extract per the no-viaIR rule.
   - **CORRECTION (2026-07-22, code-verified): the "swap-out also calls deleverBook" line in §G.3 was an OVER-generalization.** `deleverBook` is STABLE-denominated (sells collateral→stable→sink) ⇒ it fits the stable-out REDEEM. The swap-outs deliver VOLATILE, and are ALREADY invariant-safe by different means: (a) **ETH swap-out** (QD→ETH) delivers capped at `deliverableETH` which EXCLUDES levered net-equity, and #105 partial-fills + refunds the unreachable remainder — it NEVER removes levered depth (invariant holds with NO de-lever; reaching levered ETH would need a WETH-delivery variant = capital-efficiency choice, NOT a safety gap, DEFERRED); (b) **BTC swap-out** already de-levers per-LP via `deleverOnDelivery` (#54, `SwapLib:1102`). So the ONLY reactive `deleverBook` consumer is redeem. No swap-out wiring needed. §G.3 reactive-triggers list amended: redeem→`deleverBook`; ETH swap-out→#105 partial-fill; BTC swap-out→#54; withdraw→`closeLevFor`.
3. **#10** — `cascadeDeleverMany` for BTC — **✅ DONE (uncommitted/unbuilt).** `BtcLevManager.cascadeDeleverMany` mirrors ETH, fault-tolerant, keeper LTV-ranked list. (WBTC→stable sale already lives in `rebalanceWbtc`'s `_flashDeleverWbtc`/`sorSelfFundedReverse`, per G.8.)
4. **#9 / #89** — **✅ DONE (uncommitted/unbuilt):** `out_of_band` deduped to ONE `pub(crate)` predicate in `lev_keeper.rs`, imported by `lev_keeper_btc.rs` (local copy deleted). The decision brain (`decide`/`DwellTracker`) was ALREADY shared; the classify/actuate loops correctly stay separate (BTC's `timeout` + `wbtc_mode` branch + distinct actuators — merging would conflate WBTC-atomic vs native-async routing). The either/or fold router (§E #246) is a separate refinement, not this dedup.
5. **#19 / D3** — θ-numerator — **✅ DONE (uncommitted/unbuilt):** `Aux.get_deposits` now folds the retained band market-making yield into the weighted-avg NUMERATOR (`amounts[0] += (Core.skewPremiumETH + skewPremiumBTC)·1e12`, 6→18 dec), principal (`amounts[14]`) untouched to avoid double-counting POOLED_USD. Flows to θ via `get_metrics`→`computeMetrics`→`avgYield()`→`derivedThetaWad`. So θ's numerator is now reserve-yield + band-market-making-return, not reserve-only. `derivedThetaWad` itself unchanged (fix is at the `avgYield` SOURCE, per user). Trading-fee rewards excluded (LP-owed, not basket-retained). Scale verified: skewPremium* are 6-dec USD (`SwapLib:27`).
6. **#110** — swap-out opt-in ladder + SPA partial-fill warning + bounty (the ladder/partial-warning/bounty mechanics; generic SPA work C#18 already captured). SEPARATE from the sweep but in this batch.
7. END: `#nnn`-tag removal from comments (#16 tail), ONE build+targeted tests, commit by path to main (trailers: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` + `Claude-Session: …`).

**Already-staged uncommitted batch (this session, pre-de-lever):** payRefillBonus removal (Core/SwapLib — premium stays in basket as LP backing via `recordSkewPremium`, no bonus paid to the self-funding fleet refiller); acquirer removal (#8, `lev_keeper_btc.rs`+`daemon.rs`); "YB"-tag removal (14 evm/src files). NOT yet built.

### G.11 Status of the items the user named
- **#108** — ❎ DON'T BUILD (dead-view resurrection; ETH twin deleted `3240705`). Decided.
- **#109** — 🔴 BUILD = this section (v3 unified). In progress.
- **#110** — 🔴 open, SEPARATE (swap-out opt-in ladder + SPA partial-fill warning + bounty). Not part of the de-lever primitive.
- **#9 / #10 / #19** — folded into G.10 (steps 3/4/5).

## H. DROP BTC-SHARE MEDIAN VOTE + THE btcShareBps CAP (2026-07-22, user-decided, stress-tested)

**Decision: remove the median BTC-share vote AND the `btcShareBps` allocation cap entirely — EVM + SPA.** Stress-tested against code; the cap is NOT a solvency or backing guard, so its removal is safe.

### H.1 Why it's safe (the load-bearing facts, code-verified)
- `btcShareBps` is **"a soft policy signal, not solvency"** (`Basket:143`). It is an ALLOCATION-policy knob, nothing more.
- **Solvency is SEPARATE and stays intact:** `POOLED_USD_ETH + POOLED_USD_BTC ≤ TVL` (`Core:48-52`, enforced inline in `_handleDelta` on every USD add) PLUS the `committed ≤ backing` gate + repack heal (`backingCoreBody`). None of these is the cap; removing the cap touches none of them.
- **The refiller handles inventory imbalance** (transient, fleet-coupled — see §G-JIT notes). Imbalance ≠ allocation; the cap governs allocation, which is now demand-driven within the `≤TVL` invariant.
- **The vote is misaligned by construction:** QUID holders are STABLECOIN holders — they want peg safety, not to express a BTC-risk-appetite. The median over apathetic voters is NOISE, not signal. (Deeper than "it doesn't allocate.")
- **IL is NOT part of this argument** (deliberately). Whether the BTC band bears IL and who eats it (`Core:357` calls locked sats "IL-bearing backing") is governed by the BTC LP share/close accounting, ENTIRELY orthogonal to the `btcShareBps` cap. Do not reintroduce IL as a justification here.

### H.2 The one honest caveat (liquidity-quality, NOT solvency)
The cap implicitly BALANCED ETH-vs-BTC depth (stopped a BTC surge pulling most of TVL into the BTC band, thinning ETH swap depth). Dropping it makes depth demand-driven. Acceptable. IF ETH depth ever needs a guarantee, add a small ETH-side FLOOR — never resurrect a BTC cap.

### H.3 Code to remove — EXHAUSTIVE, line-verified (2026-07-22)
**`Basket.sol`** (the whole vote subsystem):
- State: `K_btc` (`:134`), `SUM_btc` (`:135`), `WEIGHTS_btc[90]` (`:136`), `btcShareVotes` mapping (`:137`), `votedWeight` mapping (`:144`).
- Functions: the **vote entry** (`castBtcShareVote`/similar, `:~198-210` — sets `btcShareVotes`/`votedWeight`, calls `_median`), `_median` (`:216`, the 90-slot weighted-median core), `btcShareBps()` (`:238`).
- Transfer path: the 2 vote SLOADs (`fromVote`/`toVote`, `:461-462`) + the `_resyncVotes(...)` call (`:489`) in `_transferHelper`, and `_resyncVotes` itself (`:519-534`).
- Comments referencing the vote: `:126-127`, `:143`, `:459`.
- **KEEP** `immatureSupply()` / `immatureBalanceOf()` — used by redeem/mature accounting, NOT vote-specific. Do NOT delete.

**`Core.sol`**: `maxPooledUsdBtc()` (`:494-501`) + its doc (`:50`). POOLED_USD_BTC then bounded ONLY by the `≤TVL` invariant (`_handleDelta`) — which STAYS.

**`Vogue.sol`**: the `maxPooledUsdBtc × 1e12` pool ceiling (`capScaled`, docstring `:738` + the consuming logic near it — grep `maxPooledUsdBtc` in Vogue).

**`SwapLib.sol`**: in `sizeBySurplus` (`:1214`), remove the cap term `uint allowed = IV4(v4).maxPooledUsdBtc()*1e12` (`:1198`) and the clamp that uses it — BTC sizes by solvency-surplus only. Remove the `maxPooledUsdBtc()` interface decl (`:1585`). **Verify the sizer degrades cleanly to surplus-only** (its own build, since this is the money-path bit).

**Empty-vote default:** `btcShareBps() = 10_000 − K_btc·9000/89`; `K_btc` inits to 44 → ~55% default today. After removal there is NO btcShareBps — every reader above is deleted, so no dangling default needed.

### H.3b Build-order note
§H spans the sizer (`SwapLib.sizeBySurplus`) → do it as its OWN batch with its OWN build, separate from the de-lever batch.

### H.4 Code to remove (SPA) — source files identified
- `spa/src/components/app/AllocationSlider.tsx` — the BTC-share vote slider (the removal target). **CARE:** confirm this is the *BTC-share allocation vote*, NOT the ComfortPanel "cushion" slider (which is leverage-cushion, a DIFFERENT control that STAYS).
- `spa/src/components/app/ComfortPanel.tsx` — remove only its BTC-share reference if any; keep the cushion knob.
- `spa/src/lib/abi.ts` — delete the `btcShareBps()` / vote-cast ABI entries.
- `spa/src/app/(app)/app/page.tsx` — remove the AllocationSlider wiring/usage.
(Build artifacts under `spa/.next` regenerate; ignore.)

### H.5 Status
🔴 QUEUED — clean deletion, SEPARATE from the de-lever work. Touches Basket/Core/Vogue/VogueLib + SPA. Do as its own batch (its own build) since it spans the sizer. Fold the #5/#12 skew-simplification consideration alongside if de-gating from Echidna (see §F #12 / the JIT-drain notes).

## I. OPEN-CHANNEL UX CONSOLIDATION + SPA CLEANUPS (2026-07-22, user)

### I.1 Open-channel = a keeper endpoint (reduce moving parts, trust STRONGER)
The pasted open-channel flow (build BIP-380 descriptor → fund P2WSH → wait confs → build SPV proof → sign lpAuth) is far too much for an LP. **Fold it into the keeper we ALREADY run** — no new watcher service.
- **Why safe / not a new attack surface:** `openChannel` verifies the SPV proof AND `lpAuth` (ecrecover) ON-CHAIN. The completer (keeper) is untrusted-for-safety by construction — a bad proof reverts, and the channel owner is the `lpAuth` signer NOT the submitter, so it can't forge or steal. Only surface is liveness/DoS, neutralized because the open is PERMISSIONLESS (same `lpAuth` submittable by the LP or any relayer) → keeper is the DEFAULT convenience path, never a dependency.
- **Trust stronger by reuse:** the fleet is already SGX-attested + in `AttestedHopRegistry` (DCAP) → the default completer is a known attested entity, not an anonymous relayer — a bonus, not a required assumption.
- **LP's job shrinks to 2 actions:** fund the derived address (NON-custodial — keeper never holds their sats) + hand over `lpAuth` (in the request). Keeper derives descriptor, waits confs, builds proof, submits.
- **Guardrails:** NEVER custodial (automate only AFTER funding); stateless/idempotent handler (public inputs only, safe to re-run).
- **Pieces ALL EXIST (verified 2026-07-22) — wiring only:** SPV proof + `openChannel` + `lpAuth` in `channel_driver.rs`; Bitcoin funding-watcher in `daemon.rs`/`header_source.rs`/`swap_in_onchain.rs`; endpoint pattern to mirror in `swap_in_api.rs`; permissionless submit in `relayer.rs`. Build = expose `channel_driver`'s open flow as a `swap_in_api`-style endpoint fed by the daemon watcher.
- 🔴 QUEUED (bridge/keeper task; SGX-fleet endpoint).

### I.2 SPA: unify the two swap tabs
USD→BTC and BTC→USD are TWO tabs today. Merge into ONE swap component with a direction toggle (USD ⇄ BTC flip), like a normal DEX swap. `src/app/(app)/app/page.tsx`. 🔴 QUEUED.

### I.3 SPA: vBTC-is-an-ERC20 explainer fix (USER is doing this)
`src/app/(app)/app/page.tsx:~1842-1851` — the "BTC is wrapless — one internal token" `<p>` explains only BitGo WBTC and never mentions **vBTC** (`VBTC`, the native channel-BTC collateral ERC-20, distinct from WBTC). User rewriting it themselves.

## J. ARCHITECTURE REVIEW BACKLOG (user, 2026-07-24) — dedup / refactor / verify

### J.1 Dedup patterns (bytecode + clarity; repeat across contracts)
- 🔴 **External-wrapper-over-internal collapse:** e.g. `_reserveIdOf` internal + an external view getter that just returns it. Make the internal `public` (or keep one). SWEEP every contract for `external fn { return _internalFn(); }` shims and collapse.
- 🔴 **Multiple interfaces for ONE external contract** (user: "why does Vogue need ILevHost + ILevClose + ILevEquityV?"). Merge per-target-contract interface fragments into ONE interface each. Repeats in EVERY contract — systematic sweep.
- 🔴 **Merge `refreshHoldingsSelf(stable)` + `refreshAllHoldingsSelf()`** into one (address(0)=all, or a flag).
- 🔴 **`BtcVaultLib.outOfRangeBTC` vs one generic `outOfRange`** — dedup to a single range predicate that handles ETH+BTC (like the #9 `out_of_band` dedup we just did in Rust).

### J.2 Refactors (structural)
**STATUS 2026-07-24: NOT STARTED (user asked "did you finish the 4626 refactors?" — no).** Code confirms: `Vault.sol` is STILL the merged EthVenue+BtcVault carrying live vBTC ERC20 (`vbtcTransfer`/`vbtcTransferFrom`); the #115 batch only deletes the DEAD `mintVBTC`/`burnVBTC` roundtrip, not the segregation. **PREREQ (user, cleaning-mode): FIRST complete + VERIFY the round-trip proof** ("vogue-not-4626 doesn't mean the ETH-in-band isn't a 4626" — prove the collapse/merge is behavior-neutral on a deposit→band→withdraw round-trip) BEFORE refactoring the vault-share model. 🔴 QUEUED, structural, needs the proof gate first.
- 🔴 **Vogue should NOT be a 4626** if vBTC is its own segregated 4626 and Vogue manages BOTH vETH and vBTC. Refactor the vault-share model.
- 🔴 **Vault.sol should NOT contain vBTC ERC20 functions** — segregate them out (into the vBTC 4626).
- 🔴 **Full-2× buffer-as-band-depth UNIFICATION (user believes big dedup):** "the band sells the buffer" == "unwind the borrow for a swap" == the tap mechanism — ALL one operation. If the buffer sits in the band as depth (borrowed), a buy-ETH swap sells it → the levered slice de-levers → debt repaid, with no separate tap/buffer mechanism. Same-block refill re-aligns POOLED_USD of both pools + undoes the LTV delta by shifting where Aux holds stables (cover the collateral delta vs deposit-to-earn). VALIDATE this reduces moving parts and dedup accordingly.

### J.3 Permissionless JIT refill (SIMPLIFICATION — user)

**🟡 SCOPE SETTLED (user, 2026-07-26) — "partially done": the ECONOMICS are live, the FLASH REBALANCE is the genuine remaining work. Read this before anything below.** The mechanism is ONE thing — fix an imbalance in our OWN band, LPs keep the fee — and it decomposes into three parts, two built:
1. ✅ **BUILT + LIVE — premium→LPs (the fee).** A swap that drains the scarce side pays an Avellaneda–Stoikov scarcity premium (`wellSkew`, `SwapLib:937`); `retainSkewPremium` (`SwapLib:1330`) withholds it from the swapper's output and `Core.recordSkewPremium` (`Core:253`) accrues it to `skewPremiumBTC`/`skewPremiumETH` (`Core:246-247`, emits `SkewPremiumRetained`). On the hot path: called from `swapToBody` (`SwapLib:457/479`) and the RFQ/route path (`:1035`). The **refilling (imbalance-REDUCING) direction is exempt** → yields 0 (`SwapLib:452,962`). The swapper-facing `payRefillBonus` was **deliberately REMOVED** (`Core:261`) so the premium stays with LPs — so do NOT re-introduce a bonus to a flasher/refiller.
2. ✅ **BUILT + PERMISSIONLESS — geometric re-center (reseat).** `Vogue.reseat()` (`:1029`) and `Rover.repackNFT()` (`:296`) are `public nonReentrant`; anyone pokes them. (#96.)
3. 🔴 **NOT BUILT — the flash-funded ACTIVE rebalance.** Flash the scarce asset → route it through our own imbalanced band to correct inventory → repay → premium stays with LPs. **Every `flashLoan` call site in the tree is leverage de-lever, never the reservoir** (`LevManager:752/839`, `BtcLevManager._flashDeleverWbtc`). The building blocks ALL exist — Morpho zero-fee flash provider, `sorSelfFunded` router, RFQ-drawable premium (`SwapLib:1035`) — they were simply never assembled into ONE permissionless entrypoint. **This is the real remaining work.**

**Corrections to earlier readings of this section (do not repeat them):** (a) it is NOT "superseded" by the LP-entry pump — the pump comment at `Vault:719-727` ("NO bespoke pump/keeper/RFQ") describes the PRIMARY organic refill and does not cover the active flash top-up; (b) `Core:242`'s description of a "self-funding fleet op (JIT Morpho-flash BTC → creditSwapIn → repay)" is NOT stale-and-wrong — it names exactly this unbuilt part, so leave it; (c) the split of "pump" vs "refiller" into two mechanisms was wrong — it is one mechanism.

**What blocks a build TODAY (both are user decisions, not derivable from the code):** the **depletion threshold** ("what counts as depleted" — the trigger predicate) and the **bound** on a single top-up (the §S "toxic ONLY if UNBOUNDED" constraint). Also note `creditSwapIn` is `onlyBTCChannels` (`Vault:937`), gated to the hop settling a REAL swap-in — so a permissionless entrypoint cannot simply call it; that auth seam has to be designed, not bypassed.
- 🔴 The atomic flash-refill (flash WBTC → creditSwapIn → SOR the swap-out's USD → repay) only ever rebalances OUR OWN reservoir (value-neutral, sole internal beneficiary, nothing extractable) ⇒ make it **fully PERMISSIONLESS** — anyone pays gas to trigger it. NO keeper-gate, NO dedicated gas-comp (keepers already covered by other gas-comp layers). Model on permissionless-open-via-ecrecover. On-chain flash callback lives near `creditSwapIn` (Vault.sol:935); trigger is a depletion check anyone can call.
- 🔴🔴 **LOAD-BEARING CONSTRAINT (user, do NOT violate):** the JIT refill is a **keeper op — ASYNC, next-block.** ⇒ you **CANNOT retire a SYNCHRONOUS safety guard on the strength of an asynchronous fix.** The **swap-out→refill window** (the gap between a swap depleting the reservoir and the next-block keeper refill) is **exactly where an adversary would act.** So any sync guard (e.g. the swap price-move / depletion guard — ties to #101 "loosen the swap guard") must STAY as the in-tx protection; the JIT refill is a *convergence/top-up* mechanism, NOT a substitute for the synchronous guard. When touching #101 or the well/reservoir, keep the synchronous in-swap protection intact and treat JIT as additive only.
- 🧭 **RECONCILED with §P.1 (NOT a contradiction — read both together):** §P.1 says a swap-in refill "CANNOT be JIT-internalized into the drain" and "the reservoir is the answer." That is CONSISTENT with this section: the drain tx cannot refill ITSELF (opposite direction, needs a counterparty), so §J.3's flash-refill does NOT run inside the draining swap — it is a SEPARATE, per-need top-up that **flashes to serve a PENDING opposite-direction flow** (flash WBTC → serve a pending swap-out → repay from that swapper's USD; §169) and **folds into the #100 reservoir** as its fast fill path. Trigger cadence = **piggyback the existing `reseat`/`repack` hook** (per §Q4 — no standalone keeper, no gas-comp), NOT a caller inside the drain. Net: reservoir/LP-staking = PRIMARY (async) refill; §J.3 flash-JIT = bounded fast top-up folded into it; the sync in-swap guard (above) stays regardless. So §J.3 + §P.1 + §Q4 + #100 describe ONE mechanism, not competing ones.

### J.8 🔴 weETH-on-Aave-v4 yield leg, gated on Rover instant-convertibility (user, 2026-07-26)

**The ask (user, verbatim intent):** if the Rover NFT — which *guarantees* liquidity can't be pulled from the weETH/WETH v3 pool — is both **balanced** and **large enough** to support instant conversion of some weETH amount back to WETH, then that weETH amount (mintable from the WETH any LP brings to the Vogue band, levered or not) **can be lent on Aave-v4 for extra yield**. Otherwise — when we CANNOT guarantee the instant withdraw and the LP would eat the ~0.3% ether.fi instant-redeem fee — the **frontend must surface a hint** and take an **explicit opt-in at withdrawal time**: either the slow `waitNFT` flow (free) or accept the 0.3%. **User constraint: reuse existing views, do NOT write new code for the hint.**

**Why this is the natural shape of ETH venue 2 (ties to §A.3/§A.5):** on the wired Aave-v4 hub **weETH IS listed (assetId 2 → reserveId 2)**; plain WETH is assetId 0 → reserveId 0. Lending the *weETH* leg is what that hub is actually set up for, and weETH is what the ether.fi/Rover path already produces.

**REUSE INVENTORY — the opt-in already exists, don't rebuild it:**
- `Vogue.exitInstant(assets, receiver)` (`:1273`) = the **per-tx** opt-in to the ~0.3% instant redeem ("for THIS tx only"); plain `withdraw`/`redeem` already default to **WAIT** with no forced haircut (`:1257/:1265`). So both branches the user describes ARE the current contract surface.
- `SwapLib.offrampBody` (`:595`) is the 4-rung ladder and already encodes the preference order: **rung 2 = Rover unwind** (`:618`, needs no Aux weETH), **rung 3 = 0.3% instant** (`:637`, gated on the `instant` flag), **rung 4 = free wait-NFT** (`:642`). `waitNft` is also standalone (`:652`).
- `Rover.take(amount)` is the actual capacity consumer (`:595`).

**✅ THE OPEN QUESTION IS RESOLVED — "balanced" IS derivable with ZERO new Solidity.** The worry was that `Rover.valueWeth()` (`:641`) returns only total NAV, whereas instant convertibility depends on the **WETH side of the v3 position at the current tick**. It turns out `valueWeth` ALREADY computes exactly that split — `getAmountsForLiquidity(sqrtCurrent, sqrtLower, sqrtUpper, liquidityUnderManagement)` → `(posWeth, posWeeth)` via `token1isWETH` — and then **sums them into one scalar, discarding the split**. But every INPUT is public, so the SPA can recompute `posWeth` client-side with the standard Uniswap-v3 amounts math:
`Rover.LOWER_TICK`/`UPPER_TICK` (`:48-49`) · `liquidityUnderManagement` (`:67`) · `token1isWETH` (`:44`) · `POOL_FEE` (`:64`) · `ID` (`:37`), plus `sqrtPriceX96` straight off the v3 pool's `slot0`, plus `WETH.balanceOf(rover)` for the idle leg.
⇒ **instant-convertible capacity ≈ idle WETH at Rover + `posWeth`**, and "balanced" = `posWeth` is a meaningful fraction rather than the position having drifted entirely to the weETH side. No new view function required. (A tiny `roverWethSide()` view would be *nicer* than duplicating the math off-chain — but it is NOT required, and the user asked for no new code.)

**GENUINELY NEW WORK (the 🔴):**
1. Route ETH venue 2 to supply **weETH** (reserve 2) rather than WETH, sized to the Rover-guaranteed instant-convertible capacity above — never more, or an exit is forced into the 0.3% rung or the slow NFT.
2. SPA: derive the capacity, and when a withdrawal would exceed it, require an explicit choice between `withdraw` (wait-NFT, free) and `exitInstant` (0.3%). Surface WHICH rung will serve, not just a warning.
3. ✅ **DECIDED (user, 2026-07-26): WITHDRAW-TIME check.** The bound is evaluated at exit, not as a deposit-time cap — so the yield leg is never throttled by a capacity forecast. Consequence to build accordingly: an exiting LP CAN find their ask exceeds the instant-convertible capacity, which is exactly why item 2's explicit opt-in (wait-NFT free vs `exitInstant` 0.3%) is REQUIRED rather than nice-to-have — it is the thing that makes a withdraw-time bound honest instead of a surprise.

### J.4 Design questions to answer/verify (banked; some answered inline in chat)

**🧭 ANCHOR (2026-07-24, per memory `project-quid-yb-shortleg-open-question` — the meta-position is OPEN; STOP re-deriving, I flip-flopped 5×):** the down-side short-leg is an **OPEN, UNRESOLVED question — NOT a settled leak, NOT settled-keep.** The single load-bearing fact: **the committed `_growShort` BAND-SELLS** — its rebalance routes THROUGH our own band, so the skew is **captured INTERNALLY by the LP, NOT leaked to an external DEX arber.** Consequence: the Milionis "IL ≤ LVR" argument does NOT cleanly apply — LVR is the value bled to EXTERNAL arbers; an internal band-capture may bleed nothing, so "holding dominates on return" is UNPROVEN here. **net-vs-hold = an unresolved SIM question** (turns on: does the reseated band even accrue a down-side over-hold? and is captured-skew ≥ the recovery-option the hold retains?). ⇒ the parallel-thread CODE removal of `runShort`/`_growShort`/short venue **MAY BE PREMATURE.** Do NOT re-argue the economics either way; anchor here. **Code state:** `runShort`/`_growShort` stay REMOVED. **"RESTORE" does NOT mean restoring `runShort` — it means building the DIRECTIONAL LEVERING flow in §K.2** (SOR/QUID→collat → borrow volatile → weETH-via-Rover leverage loop → outOfRange band leg, over the generic legs). A short is just "borrow the volatile you're short, dollar-collateralized" in that flow. The band-routed-internal-skew net-vs-hold question = a fees/skew-vs-LVR SIM (not a fresh derivation), does NOT block shipping current design. ⇒ ship short-removed; directional levering §K.2 = 🔴 QUEUED build.

- 🟡 ~~**Short / inverse-venue — SETTLED 2026-07-24: NO code change; opt-in, default hold.**~~ **[Historical reasoning journey below — SUPERSEDED by the ANCHOR above (OPEN, band-sells-internal, removal maybe premature). Do not treat as settled.]** Three layers, kept separate:
  1. **Mechanics:** the short trims the below-entry OVER-hold (net-equity delta drifts >1) back to **delta-1 — a clean 1:1 LONG, in-band, SELF-FUNDED** (`_growShort`: withdraw own base → SOR → own segregated stable, NO borrow). It is NOT delta-0/market-neutral, NOT external. (My "not an LP / market-neutral" was wrong — conflated delta-1 with delta-0.)
  2. **Coexistence = OPT-IN:** short venue UNSET (env-gated, `DeployL1_s:513`) ⇒ `_maybeShort` no-ops ⇒ **up-side-only-hold is the DEFAULT**; venue PINNED ⇒ delta-1-both-ways. Keeper handles both (short skipped when unset). The user's preferred behavior is already the default — no code change to get it.
  3. **Economics:** achieving delta-1 down-side SELLS the over-hold into the fall ⇒ realizes LVR; down-side IL is IMPERMANENT (heals on recovery). So **hold dominates FOR A LONG-BIASED LP** (don't pay to lock in a loss that would heal) — which is why hold IS the default. But NOT strictly-dominant for an LP buying the **YieldBasis product** (synthetic IL-free 1× linear exposure + fees, net-positive **iff fees > LVR**) — that LP rationally opts in. So the short is a legitimate niche opt-in, not a leak to delete.
  - **KEEP both modes** (default=hold, opt-in=delta-1-both-ways). Directional LONG = the >2× opt-in (exists). Directional SHORT only coheres as an LP via **delta-neutral fee-farming** (target net-delta-0, NOT band-delta-1) — a SEPARATE fresh product reusing the `_growShort` primitive, NOT the current `runShort` leg. Pure directional short = not a band/LP position.
  - **ACTIONABLE (the only one): `LevYbPnl.t.sol` proves the delta-1 property but NEVER measures fees vs the LVR realized** — so the opt-in's net-positivity (fees > LVR) is UNPROVEN, only the delta math is. Promoting the opt-in needs a **fees-vs-LVR sim/backtest**, NOT code. 🔴 QUEUED (sim, not a build).
  - Retracted: BOTH "delete the subsystem" AND "market-neutral." This entry is the settled verdict — do not re-derive.
- 🟢 **Soft-liquidation engine still unnecessary** (up-side-only design: below entry dynamic-α target=0 → keeper de-levers to zero debt, nothing to liquidate; above entry collateral appreciated → healthy LTV; counter-cyclical to liq risk; residual gap-crash backstopped by venue isolated hard-liq R1). CONFIRM still true.
- 🟡 **Buffer: dynamically borrowed per-swap, or sits in the band borrowed-at-max always?** Resolve (ties to J.2 unification).
- 🟢 **Excess attribution (YB socialized vs directional kept-by-LP): ANSWERED 2026-07-24 → §K.1.** It is SETTLEMENT ACCOUNTING on the residual, NEVER a sweep gate: YB residual = principal@full-upside − IL + full 2× fees, EXCESS socialized; directional residual = own upside, NOT socialized. Sweeps reach all levered LPs uniformly.
- 🟡 **immatureBalanceOf correctness** — user suspects wrong; check vs old `matureBatches` (mature = batch ≤ currentMonth; immature = >). Current sums balanceOf[who][cm+1..cm+13]. VERIFY the window/off-by-one.
- 🟡 **Why is SOR not connected to routeSwap?** Investigate + wire if it should be.
- 🟡 **Stable→stable fee for "strict" since the Liquity base-rate was removed** — how handled now? SOR should have a DUAL mapping keyed by asset-bought AND asset-sold (most efficient), deployment-SAFE to ADD new poolIds (never remove old).
- 🟢 **LVR / re-seat-to-Chainlink / "less arb ⇒ less flow ⇒ less fees?"** — ANSWERED (chat): LVR arb is TOXIC (adverse-selection; LPs lose more than its fees). Removing it removes a LOSS, not revenue. Uninformed fee flow stays. Net-positive. (memory: orderflow-tam-truth.)

### J.5 Feature #107 original variable (user Q)
- Before D3, θ's numerator was **`avgYield()`** (`Aux:971` = `metrics.yield` = the RESERVE/basket-stablecoin yield). Replaced because θ SIZES band-liquidity deployment (`applyTheta`/`clampByBacking`) — the "yield" must be the band's OWN market-making return (fees), not the unrelated reserve yield. Correct D3 = θ-LOCAL (feed band fee-yield into `derivedThetaWad` directly; do NOT fold into the shared `avgYield`, which also feeds `seedFee` mint-valuation — that conflation was the tangent).

### J.6 Open-channel automation (RE-EMPHASIZED by user) → see §I.1
- All the off-chain LP steps the SPA lists (descriptor build, P2WSH fund, confirmations, SPV proof, lpAuth) are being AUTOMATED via the permissionless keeper endpoint. §I.1 is the task; the SPA copy must change from "LP does X,Y,Z" to "fund + sign, we do the rest."

### J.7 User's manual [TODO] markers — COMPLETE catalog (verified 2026-07-24, address in the refactor)
Full grep of `evm/src` — these are the USER's hand-typed annotations; do NOT lose, address each:
1. `Basket.sol:44` — `onlyUs() // TODO make sure the Vogue [...]`
2. `Basket.sol:76` — `// TODO` (bare — check what it flags)
3. `Vogue.sol:65` — `[ TODO there are a couple problems with only letting the LP withdraw [...]` (ties to the levered-slice withdraw / §G)
4. `Vogue.sol:91` — `[ TODO we are missing VENUE_GAUNTLET ??? do not assume Galaxy to be the default ]` (also `DeployLib.sol:131` below)
5. `Vogue.sol:98` — `[ TODO why do we have separate mappings for each venue, it should just [...]` (per-venue-mapping dedup)
6. `Vogue.sol:111` — `[ TODO we dont need a mapping for this user setting because it only becomes [...]` (drop a per-user mapping)
7. `Vogue.sol:137` — `[ TODO i dont need one liner functions like this, merge it into the other deployment ops` (fn-merge dedup, §J.1)
8. `Vogue.sol:332` — `[ TODO this implementation changed considerably from what was in Vogue.sol of [...]` — **the outOfRange TODO**: sits at the close of `_outOfRange` (301-328). Pairs with the outOfRange dedup below.
9. `Vogue.sol:434` — `[ TODO why isnt this actively closed? can we get rid of code by being more proactive [...]` (relates to §4.2 closeLevFor / #109)
10. `DeployLib.sol:131` — `[ TODO whhy is this missing the Gauntlet vault ??? ]` (same as #4 — VENUE_GAUNTLET missing)

### J.8 outOfRange dedup (user TODO + "directional bands via outOfRange")
- `Core.outOfRange(bool isBTC, …)` (`Core.sol:524`) is ALREADY fused (Action enum ETH vs BTC). The DUPLICATION is one level up: `Vogue._outOfRange` (`Vogue.sol:301`, ETH) + `BtcVaultLib.outOfRangeBtc` (`BtcVaultLib.sol:307`, BTC) both compute ticks + call the SAME fused Core.outOfRange. 🔴 DEDUP: collapse the two wrappers into ONE `isBTC`-parameterized tick-compute+band function (mirror Core). Note: the directional short/long products BAND via `outOfRange` (own dollars→SOR→collateral→borrow-volatile→`outOfRange`), so a single clean wrapper is the reuse surface for §K. Addresses TODO #8.

## K. DIRECTIONAL PRODUCTS + YB/DIRECTIONAL KEEPER SEPARATION (settled 2026-07-24)

**Requirement (user):** the YB keeper regime and the directional product must be cleanly separated (no interference), reusing existing functions, adding nothing superfluous.

**The interference (diagnosed in code):** keeper `decide` (lev_keeper.rs) runs TWO tracks on every position in `_openLps`: (1) safety (urgent de-lever near liquidation) — universal; (2) IL-target track (lazy DeLever/ReLever to `target_ltv_bps` = `ilTargetLive`) — YB-specific. There is NO regime flag on `Pos` (only `targetLtvCapBps`, a cap), so a directional >2× LP gets dragged to the IL target by track (2) = the YB keeper unwinds their bet.

**Settled design — OFF-CHAIN regime, reuse-maximal, ZERO new on-chain surface:**
- The generic venue legs (`leverBorrow`/`leverSupply`/`deleverWithdraw`/`repay`) operate on `pos[lp].venue` and `openLev` takes the venue as a param ⇒ **already venue-agnostic**. Every product rides them.
- **Directional SHORT** = a normal `openLev` on an INVERSE venue ({stable collateral, volatile loan}) added to the existing `allowedVenue` allowlist → generic legs → STATIC target. Does NOT use `runShort`/`_growShort` (those were the SELF-FUNDED YB down-side hedge, correctly deleted). A borrow-volatile short just borrows via the generic legs.
- **Directional LONG** = `openLev` on the long venue at cap >2× → generic legs → STATIC target.
- **YB** = `openLev` at exactly 2× → generic legs → IL target (keeper track 2).
- **Regime boundary = OFF-CHAIN, self-describing via (venue collateral type, cap):** `2× on long venue`=YB (full IL-track); `>2× on long venue`=directional long (safety-only + static); `ANY position on inverse/stable-collateral venue`=directional short (safety-only + static). A short is a DIFFERENT VENUE ⇒ never misclassified as YB. "2× directional long" is not a distinct product (2× delta-1 long IS IL-neutral = YB). So "cap as intent" fragility is resolved — the venue type does the heavy lifting.
- **Keeper change (the ONLY work):** `decide` early-returns after the safety block (track 1) for directional positions (venue-type/cap filter); never runs track (2) IL-management on them. A separate directional keeper policy (or the same task, branched) drives directional positions to their STATIC target via the same legs. No on-chain flag, no second manager, no restored short functions.
- **CONSEQUENCE: the short-subsystem deletion STANDS.** `runShort`/`_growShort`/`_closeShort`/`shortVenue`/`_maybeShort`/`_shortTargetLive`/`bidirTargetBps`/`runShortBtc` stay removed. The user's "reusable primitive to keep" resolved to the GENERIC LEGS + inverse-venue allowlist entry (both already exist) + the off-chain keeper filter — NOT the self-funded `runShort`.
- 🔴 QUEUED (Rust keeper: the directional regime filter + static-target policy; + allow an inverse venue in DeployL1_s allowlist when a directional-short product is actually shipped). "maybe most of it off-chain" (user) = YES, this is off-chain keeper policy + one allowlist entry.

**K.1 YB-vs-directional = SETTLEMENT ACCOUNTING ONLY, never a sweep GATE (user, 2026-07-24 — resolves §J.4:441 "excess attribution HOW"):** the regime distinction is applied ONLY to the touched LP's **residual claim** AFTER a sweep/de-lever reaches it — it is NEVER a gate on WHETHER the sweep (the §M.1 ETH swap-out de-lever, the redeem `deleverBook`, the keeper cascade) can reach that LP. Any levered LP — YB or directional — is swept identically to free/deliver the ETH; the two differ only in how the LP's leftover claim settles:
  - **YB** → the residual keeps the GUARANTEE: **principal at full-upside − IL + full 2× fees**; any EXCESS beyond that is **SOCIALIZED to all LPs.**
  - **Directional** → the residual keeps **their OWN upside**: their bet's P&L is **theirs, NOT socialized.**
  ⇒ IMPLICATION for §M.1: `deleverEthOnDelivery`/`swapOutDelever`/`swapOutDeliverUnlevered` do NOT branch on regime to decide reachability — they sweep uniformly; the YB-vs-directional split lives ONLY in the residual settlement (the excess-socialization vs kept-P&L split). ✅ answers §J.4:441.

**K.2 DIRECTIONAL LEVERING MECHANISM (user, 2026-07-24 — the FULL flow; this is the "transform the deleted short code into directional levering" that settles §J.4 restore-vs-keep) — 🔴 QUEUED, NOT built, spec here in full:**
The directional product does NOT restore `runShort`/`_growShort`. It builds the directional position (long OR short) by a levering LOOP over the GENERIC legs, sourcing collateral and depositing the borrowed volatile into the band. Exact flow:
1. **Source the DOLLAR collateral — two paths:** (a) **SOR** to acquire dollars (stable), OR (b) take the LP's EXISTING **QUID (matured OR unmatured)** and **SOR it INTO collateral instead of REDEEMING it** — i.e., convert QUID→collateral through SOR, NOT through the redeem rail (avoids the redeem-capacity/band-unwind path; the QUID becomes directional collateral directly).
2. **Borrow the VOLATILE** against that dollar collateral — the target asset: **vBTC / WETH / WBTC** (this borrowed volatile IS the directional exposure).
3. **WETH sub-path = the leverage LOOP:** if the volatile is WETH → **first convert WETH→weETH through Rover** (IF Rover can absorb it — Rover-optional, fair-rate) → **pledge the weETH** as additional collateral → **borrow MORE dollars** against it → **borrow MORE volatile** → iterate. (weETH's staking yield + Rover-fee make the loop's collateral productive.)
4. **FINAL leg — the borrow lands IN THE BAND at `outOfRange`:** the borrowed volatile is deployed as a **concentrated out-of-range band position** (`outOfRange`/`outOfRangeBtc`) = the directional bet's band leg (earns fees + IS the directional exposure; a directional band via the outOfRange primitive, ties to §J.8).
**Reuses (nothing new hand-rolled):** the generic `leverBorrow`/`leverSupply`/`deleverWithdraw`/`repay` legs (venue-agnostic), **SOR** (dollar sourcing + the QUID→collat conversion), **Rover** (WETH→weETH absorb), the **`outOfRange` band primitive**. Does NOT touch the deleted `runShort`/`_growShort`/short-venue.
**§J.4 SETTLEMENT (via this):** the short stays REMOVED; "restore" is NOT restoring `runShort` — it is building THIS directional levering flow (fresh code over generic legs), of which a short is just "borrow the volatile you're short, dollar-collateralized." The band-routed-internal-skew net-vs-hold question (memory `yb-shortleg-open-question`) is answered downstream by the SIM; it does NOT block shipping the current (short-removed) design. ⇒ code state = short REMOVED; directional levering (this K.2 flow) = 🔴 QUEUED build.

## L. VENUE YIELD + VYPER SIM-PARITY (user, 2026-07-24)

### L.1 Levered-ETH earns in TWO places (verified — "hold" ≠ idle)
- **Band-side (ALWAYS):** the levered slice is mock-token band depth (`levBuf`/`levPooled`→V4) earning TRADING FEES regardless of collateral.
- **Collateral-side (VENUE-DEPENDENT):** weETH on Morpho/Euler escrow = ether.fi STAKING yield intrinsically (escrow never re-lends — rehyp INVARIANT #1 — but weETH appreciates); WETH on AaveV4Venue = Aave SUPPLY yield (Hub/Spoke); **WETH on Morpho/Euler escrow = NOTHING** (escrow custody + plain WETH has no intrinsic yield). User is right: plain WETH collateral only earns on Aave; weETH earns everywhere; band always earns fees. Dual-yield (staking+fees) = weETH.
- 🔴 QUEUED: verify EACH venue's collateral-leg yield behavior is wired correctly + prefer a yield-bearing route (weETH, or WETH→Aave) over idle-WETH-on-escrow. Relates to #37 (park-idle-borrowed-leg yield mode).

### L.2 Vyper sim-parity (do our sims match YieldBasis/crvUSD?)
- 🔴 QUEUED: compare our simulations/economics to the reference vyper — CONFIRMED present at `/home/rico/projects/ybamm/` and `/home/rico/projects/yb-core/` (real `.vy`: AMM.vy, HybridVault.vy, LT.vy, VirtualPool.vy, CryptopoolLPOracle.vy, Factory.vy, …). Cross-check: our up-side-only overlay + de-lever-to-1× vs their LT/AMM (LLAMMA) mechanics; confirm our LVR/IL claims (§J.4) hold against their actual code, not our summary of it. This is the empirical proof behind "are we better than YB" — do it against the running vyper, not docs (per feedback-thread-empirics-over-docs).

## M. ETH SWAP-OUT PHANTOM-DEPTH GAP (user-found, VERIFIED 2026-07-24) — REAL, needs building

**Finding (definitive, traced end-to-end):** an ETH swap-out does NOT de-lever the levered slice; the levered net-equity+buffer sit in `POOLED_ETH` as real tradeable V4 liquidity (`levAddNet`/`levAddGross`→`modLP(false,…)`), so a swap PRICES against them (tighter slippage than deliverable) but DELIVERY (`takeETH`/`_sendETH`, funded WETH venue only) can't reach them and never de-levers. Grep of the whole ETH swap path = ZERO de-lever calls; the only `deleverOnDelivery` is BTC-only (`SwapLib:1103`). ⇒ a swap into levered depth quotes tight (PRICING DISTORTION), delivers funded-only, partial-fills the rest (#105). The levered ETH is PHANTOM to a swap-out.

**Asymmetry:** BTC swap-out = `deleverOnDelivery` (#54, BUILT) → sells levered BTC + repays debt on delivery = real/self-liquidating. ETH swap-out = nothing = phantom.

**This IS the §J.2 "buffer-sale == de-lever == tap" unification — designed, NOT built for ETH.** User's "structurally undeliverable distorts pricing" + "why band it if protected — unfair fees" critiques were CORRECT.

**FIX (🔴 QUEUED, real build):** mirror BTC `deleverOnDelivery` on the ETH swap-out — when a swap consumes into levered band depth, de-lever the slice (sell buffer collateral → repay debt → deliver the freed ETH) so the depth is REAL and self-liquidating. Reuses `LevManager._deleverFlash`/`deleverToVault` (the redeem-sweep extraction) + the #54 pattern. Then the levered depth stops being phantom: it either delivers-by-de-levering or isn't priced in. Removes the distortion AND makes the fees fair (depth backs real swaps). Ties to §J.2 (buffer unification) + §G (redeem already de-levers; swap-out must too).

### M.1 CORRECTED MECHANISM (2026-07-24, this session — the build spec; #113)

**Two paths, do NOT conflate them (this was the mistake I made and corrected):**
| Path | Function | Sells LP equity? | Verdict |
|---|---|---|---|
| **REDEEM** (mode 2) | `extractToVaultBody` → stable-to-sink | YES, correctly | KEEP untouched — net-equity IS redemption backing (#67); a redeemer is entitled to the basket share. |
| **SWAP-OUT** (mode 3) | must be **equity-preserving** | NO | A swap-out is a TRADE, must be value-neutral for the LP ("same in principal as not swapping" — user). |

**The correct swap-out mechanism = EQUITY-PRESERVING, mirrors BTC `deleverOnDelivery`/`_sourceRepayFree` (SwapLib:1103/1131), NOT a flash-and-sell.**
- Flash-and-sell (my first draft, DELETED this session) forces delivery out of the LP's equity → realizes the LP's IL → the exact LVR leak we killed the short for. WRONG.
- Correct: **source the swap's OWN proceeds from the basket (`takeToSettle`) → repay `min(want, debt)` → free the paired collateral → deliver it.** Math proof it's value-neutral: LP had (C coll, D debt, E=C·p−D). Sell X ETH from coll, repay Y=X·p debt ⇒ (C−X, D−X·p) ⇒ net-equity = (C−X)·p−(D−X·p) = C·p−D = **E unchanged.** The swap's USD repaid the LP's debt (LP benefit), LP de-levered, principal VALUE identical. Only the IL-protection LEVEL (gross buffer) drops; keeper re-levers next tick.
- **Bounded by DEBT (buffer capacity = up to repaying all debt), NOT by "buffer capacity" as extra depth.** Beyond the de-leverable buffer → #105 partial-fill. The V4 curve ALREADY priced against full `POOLED_ETH` at REQUEST (SwapLib:1098) — this is a DELIVERY-time reconciliation of already-sold depth, not a depth-extension trigger.

**LIQUIDATION SAFETY (user asked twice — VERIFIED):** delivering-out-of-equity is NEVER needed to avert liquidation. Liquidation is averted by REPAYING DEBT; value-neutral de-lever gives new LTV = (D−ΔD)/(V−ΔD) < D/V ⟺ V>D ⇒ **strictly improves LTV.** Capped at `deliverableDollars` (≤ liq threshold #67). The flash paths that DO avert liquidation — `deleverOne`/`cascadeDelever` (mode 0, LevManager:629/651/746) + `protectFromQuid` (:413) — are UNTOUCHED. Removing the mode-3 draft removed ZERO liquidation protection.

**Two ETH-specific deltas from BTC:** (1) ETH delivery is POOLED (not per-channel) ⇒ **aggregate book-walk** over the lev book, not BTC's single delivering-LP; (2) ETH must **deliver weETH→WETH on-chain** (BTC just un-encumbers because the sats already spliced out).

**BUILD (reuse pins, verified this session):**
1. `LevManager.swapOutDeleverAmt(lp, maxUsd18) → (venue, stable, amtNative)` — IDENTICAL to `BtcLevManager` (view, clamp to debt).
2. `LevManager.swapOutDelever(lp, stableUsd, recipient, minWethOut) → (usedUsd, wethDelivered)` — gate `vogueSyncHook`; `venue.repay` (stable pre-funded by the Vault via `takeToSettle`); withdraw paired collateral (`_collToEth`/`_collToken`/`_isWethVenue` on LevManager); weETH→WETH via LevMath (`_weethToWeth` is `internal` at LevMath:368 — needs a public wrapper OR do the convert inside a LevMath body); deliver WETH to recipient; `syncLev(lp)`.
3. SwapLib ETH aggregate orchestration mirroring `deleverOnDelivery`/`_sourceRepayFree`: walk lev book, per-LP `swapOutDeleverAmt` → `takeToSettle`(swap USD → venue) → `swapOutDelever` → accumulate WETH until shrink covered.
4. Hook into the ETH swap-out delivery. Physical ETH delivery = `VOGUE.takeETH(tokAmount, who)` at **Core.sol:1000**; deliverable cap = `VaultLib.deliverableETH` (excludes `totalNetEquityEth`, VaultLib:145-157). Hook where delivery would exceed base-deliverable.

**ORCHESTRATION + HOOK (the remaining cross-contract wiring — design locked this session):**
- Delivery-shortfall point = **`Vogue._sendETH`** (Vogue.sol:~895→`_sendETH`): it draws WETH via `EV.vogueOp(false, needed,1,…)`; when deliverableETH is exhausted `got < needed` ⇒ `sent < howMuch` (under-delivery). `howMuch` is EXACT here (curve already ran in `Core.swap`) — so this is the BTC-style "reconcile at delivery" site, NOT a pre-swap quote.
- Wire: `_sendETH`, when `sent < howMuch`, calls a NEW `Aux` onlyUs orchestrator `deleverEthForDelivery(shortfallEth, toWhom) → deliveredExtra` and adds it to `sent`. Aux has the plumbing Vogue lacks (`takeToSettle` + the LevManager handle + the lev book).
- `Aux.deleverEthForDelivery` (mirror of BTC `SwapLib.deleverOnDelivery`, aggregate): walk the lev book (`LevManager._openLps`), per-LP: `swapOutDeleverAmt(lp, remUsd)` → `takeToSettle(venue, amtUsd, stable)` (route the swap's OWN proceeds from the basket to the venue) → `LevManager.swapOutDelever(lp, amtUsd, toWhom, minWethOut)` (repay + free + deliver WETH; unwrap to ETH for `toWhom` OR deliver WETH and let `_sendETH` unwrap) → accumulate until `shortfallEth` covered. Fault-tolerant try/catch per-LP (stuck LP → #105 partial-fill).
- Gating chain (verified): `swapOutDelever` gates `msg.sender==vogueSyncHook`; vogueSyncHook==Vogue(band); so the call must originate from Vogue's context (or Aux acting for the band). Confirm the `takeToSettle`/`drawPooledUsdEth` mirror of BTC's POOLED_USD_BTC draw (SwapLib:1151) exists for ETH (`drawPooledUsdEth`? — CHECK) so committed/liquid move together and the de-levered share isn't double-counted as backing.
- Bound: de-lever only the shortfall (`howMuch − sent`), which ≤ the levered portion the curve already priced. Beyond de-leverable buffer ⇒ existing #105 partial-fill/refund.

**🔴 CRITICAL ACCOUNTING FINDING (2026-07-24 — the orchestration is NOT a BTC copy):** `drawPooledUsdBtc`/`subPendingSwapOut`/`settleDelivered` are **BTC-ONLY** (Core:484/502). The BTC swap-out is **ASYNC** (request → later channel-splice delivery → `settleDelivered` mints QUI for the proceeds; the de-lever draws the retired-debt share out of `POOLED_USD_BTC` so it isn't minted). The **ETH swap-out is SYNCHRONOUS** (one tx, `swapToBody`): it BURNS QD (QD-in) or takes stable-in as backing, delivers ETH atomically — **no pending-swap-out, no delivery-mint, no `drawPooledUsdEth`.** So the ETH de-lever's backing reconciliation must be re-derived, NOT mirrored:
- Position-level value-neutrality is PROVEN (§M.1 above). The open question is SYSTEM-level: for a **QD-in** ETH swap-out, the swapper adds NO fresh stable, yet the de-lever needs stable to repay the LP's debt ⇒ `takeToSettle` draws EXISTING basket stable. Value-check: burn ΔS QD + draw ΔS stable to repay + LP net-equity unchanged ⇒ backing ratio preserved (S−ΔS QD ← D−ΔS + E). Looks balanced BUT unverified.
- Real risk sits in the `POOLED_ETH` / `POOLED_USD_ETH` / net-equity band-slice reconciliation: the V4 swap already decremented `POOLED_ETH` by the delivered X at execution; the de-lever then repays debt + physically frees X ETH; `syncLev(lp)` must reconcile the LP's band slice so the freed X isn't double-counted (once as consumed curve depth, once as vanished net-equity). This is EXACTLY where a silent over/under-backing bug lives, and it CANNOT be verified without forge (OOM locally).

**DECISION (do NOT blind-build the accounting):** primitives are safe (value-neutral, proven). The `Aux.deleverEthForDelivery` orchestrator + `Vogue._sendETH` hook + the QD-burn/`syncLev`/`POOLED_ETH` reconciliation must be built AND fork-verified together on the big box (a `DeleverEthBackingProbe` asserting Σbacking invariant across a swap-out that reaches levered depth), not merged blind. Surface as a money-path fork.

**🔴 arbETH-ADJACENCY (2026-07-24 — do NOT reintroduce the toxic mechanism):** `arbETH`/`arbBody` (ETH-pool shortfall BUY from basket free surplus) was DELIBERATELY REMOVED as TOXIC (Vault.sol:430-431, SwapLib:125-128 — "spent the shared safety margin to patch a usually-impermanent shortfall"; = the R1 / toxic-sweep verdict, memory `il-leverage-amortization-verdict`). The §M de-lever hooks at the SAME `Vogue._sendETH` shortfall point arbETH used, so the build MUST make explicit that it is the NON-TOXIC kind: per-LP, funded by the swap's OWN proceeds repaying THAT LP's OWN debt (value-neutral, LTV-improving), NEVER a socialized basket-surplus buy. `swapOutDelever` is exactly this — but comment it loudly at the hook so the arbETH removal isn't seen as undone (verify-intent / no silent over-correction).

**🔴 GATING PREMISE WAS WRONG (corrected 2026-07-24, caught by the #115 scan + verified):** I claimed a "gating split" forcing `Vault.fundVenueForDelever`. FALSE. In **Aux**, `V4 == Vogue` (Aux.sol:89 `Vogue internal immutable V4`; :320 `V4 = Vogue(...)`), and `_requireUs` authorizes `msg.sender==V4` ⇒ **Vogue IS `takeToSettle`-authorized.** (I misread the `V4` in the `_requireUs` list as the Core pool.) ⇒ **`Vault.fundVenueForDelever` is UNNECESSARY** — `SwapLib.deleverEthOnDelivery` (delegatecall'd by Vogue, address(this)==Vogue) can call `Aux.takeToSettle` DIRECTLY. The "fold is lateral" conclusion was ALSO downstream of this misread. Simplify: DELETE `Vault.fundVenueForDelever`; orchestrator sources stable itself. (Also: `swapOutDelever`'s gate is `vogueSyncHook==Vogue`, consistent — Vogue is the single authorized context for BOTH calls. No split at all.)

**🔴🔴 DEEPER NECESSITY QUESTION (user, 2026-07-24 — "WHY DO WE EVEN NEED THIS CODE"): #113 may be over-built.** The QD-in ETH swap-out has NO fresh stable to fund the de-lever (QD is burned) ⇒ the de-lever would draw EXISTING basket stable to repay the LP's debt ⇒ the backing reconciliation I flagged is a REAL hazard, and possibly a sign the swap-out de-lever ENGINE is the wrong solution. Memory `project-quid-67-surplus-redemption-only` says #67 CLOSED with "**NO opt-in/mint/new-engine**; de-lever capacity = USD surplus; redemption-de-lever = forbidden subordination." So a NEW inline swap-out de-lever engine for ETH may CONTRADICT the #67 decision. Alternatives that need NO engine + have NO backing hazard: (B) exclude levered net-equity from POOLED_ETH so the curve matches deliverableETH (no phantom to begin with); or (C) accept the #105 partial-fill (levered depth simply isn't inline-swap-deliverable; de-lever capacity serves redemption/keeper, per #67). **DECISION OWED (user's call): keep #113 (mirror BTC #54, do the backing work) vs remove it for B/C.** The dedup pass IS an audit — this necessity question is that audit working. Do NOT finish wiring #113 until decided.

**✅ DECIDED (user, 2026-07-24): KEEP #113 — net-equity stays in the band.**

**PRECISE MECHANISM (corrected — my "reverses IL" phrasing was sloppy):** net-equity's ETH is physically LOCKED as Morpho collateral (backs the leverage debt) — THAT is why the old workaround left it priced-in-curve but undeliverable (the distortion). The de-lever UNLOCKS it: repay debt w/ the swap's USD → withdraw freed collateral → deliver. Value-neutral (debt↓, collateral↓ equally, net-equity value unchanged); keeper RE-LEVERS next tick (re-buys ETH). ⇒ the round-trip = sell-on-swap + re-buy-on-relever = **a WASH + the swap fee** ⇒ no LVR/IL locked in (UNLIKE the naked short which sold + never re-bought). Result: banded (fee-earning) + deliverable (distortion gone) + no forced realized loss. NOT magic IL-reversal — "deliver-via-de-lever + keeper re-establishes exposure."

**🔴 GAP the user caught (2026-07-24): the FULLY-UNLEVERED (0-debt) net-equity is STILL phantom in my build.** Below entry, target debt → 0, so the position can be unlevered. `swapOutDelever` clamps `amt = min(usd, debt) = 0` ⇒ delivers NOTHING ⇒ the unlevered net-equity (the "HODL part that re-levers later") is left exactly as distorted as before. Its collateral sits in Morpho with no debt to repay, so it needs a **plain withdraw-and-deliver path** (no de-lever; keeper re-levers as usual). WITHOUT this, #113 only fixes the levered slice — defeating the point (the unlevered slice is the main HODL part). **FINISH #113 must add the 0-debt withdraw-and-deliver branch to `swapOutDelever`/the walk.**

**FINISH #113 checklist:** (1) DELETE unnecessary `Vault.fundVenueForDelever`; `SwapLib.deleverEthOnDelivery` calls `Aux.takeToSettle` directly (Vogue IS authorized). (2) ADD the 0-debt (unlevered net-equity) withdraw-and-deliver branch. (3) QD-burn backing reconciliation + `DeleverEthBackingProbe` (fork-verify — the LP IL is handled, but system backing when QD-in draws basket stable still needs proving).

**⚠️ STALE-SECTION NOTE:** the old "SIMPLIFICATION EVALUATED (fold rejected as lateral)" reasoning was built on the WRONG gating premise (Vogue-not-`takeToSettle`-authorized). That premise was a MISREAD (Vogue==V4 IS in `Aux._requireUs`) → `fundVenueForDelever` is UNNECESSARY and has been DELETED, and `deleverEthOnDelivery` calls `Aux.takeToSettle` directly. The fold question is moot. Superseded by the CURRENT STATE below.

**✅ CURRENT STATE (2026-07-24, post-KEEP + gating-fix + 0-debt build):** #113 core BUILT + solc-clean-intent (forge-UNVERIFIED):
- `LevMath.collToWethDeliver` + `LevManager.swapOutDeleverAmt` + `LevManager.swapOutDelever` (levered, equity-preserving) + **`LevManager.swapOutDeliverUnlevered` (NEW — the 0-debt HODL branch)** + `SwapLib.deleverEthOnDelivery` (aggregate walk, calls `Aux.takeToSettle` DIRECTLY — Vogue is authorized) + `Vogue._sendETH` hook. `Vault.fundVenueForDelever` DELETED.
- **Resolves the user's confusion (mid#50, re-asked 2026-07-24) — the full chain:** net-equity STAYS banded (fee-earning) AND becomes DELIVERABLE (old distortion gone). A swap-out delivers VALUE-NEUTRALLY — levered slice = repay-debt-with-the-swap's-USD → free collateral; unlevered (0-debt HODL) slice = withdraw net-equity collateral, and the V4 curve already rebalanced the LP's band slice ETH→USD (so the LP is paid). Keeper RE-LEVERS next tick (re-buys ETH = "adds collateral back to the loan", = the user's mid#37 instinct, realized async). ⇒ round-trip = sell-on-swap + re-buy-on-relever = **WASH + swap fee ⇒ NO realized IL on the HODL part**, and we NEVER de-band it (it keeps earning fees). "Still banded but delevered" = the correct TRANSIENT: leverage momentarily shrinks, net-equity value + band-membership persist, keeper restores the hedge.
- REMAINING: `DeleverEthBackingProbe` (fork-verify the LEVERED QD-burn backing — mirror `LevYbWethProbe`: open lev WETH LP, big `_rallyBand` into lev depth, assert debt↓ + netEquity preserved + committed≤backing + open) + finish arbETH comment purge. Forge OOMs locally ⇒ solc-clean only; unverified axes = gating chain, QD-burn backing invariant, non-toxicity.

## N. BTC CUSTODY — DEAD-MAN EXIT (2026-07-24, user-decided; #114 — REPLACES "export monitor blob")

**Problem (investigation-verified):** the LIVE Option-B daemon is fleet-enclave-custody, NOT self-custody. Fleet holds BOTH MuSig2 key halves + the ChannelMonitor + commitment/revocation (`vault.rs:1-10` "LP runs NOTHING"; `persister.rs:111-177`; both halves HKDF off one fleet seed `vault.rs:46-48`; `drive_open` retired `lpAuth`, `channel_driver.rs:696-706`). SPA still advertises the legacy self-host/lpAuth path (`hop.ts:55-66`, `page.tsx:1721-1733`) — a stale contradiction. `drive_open` retiring lpAuth is itself SAFE: lpAuth authorized the OPEN, now subsumed by on-chain `delegatedAuthority[lpEth]` (one-time `registerDelegation`); it was NEVER the fund-recovery backstop (that's `btcRecipientOf` + commitment). Blast radius bounded (fleet opens only from the LP's own deposit; payout pinned to `btcRecipientOf`).

**User decision: HYBRID — keep Option-B UX (LP runs nothing), add a backstop; and the backstop must need NOTHING from the LP: no downloaded keyfile, no sidecar recovery tool.**

**DESIGN — the dead-man's exit (no LP key, no LP tool):** the LP's MetaMask key can't produce a taproot Schnorr/MuSig2 sig through MetaMask anyway, so "LP signs at recovery" is a dead end. Instead let the fleet pre-sign while alive and let BITCOIN enforce release:
- Fleet (holds both key halves) pre-signs a FULLY-signed unilateral-exit tx: pays the LP's **checkpoint balance → `btcRecipientOf`**, with an **absolute CLTV timelock** to a near-future dead-man deadline.
- **Emitted on-chain** as a `BTCChannels` EVENT (cheap, public, retrievable forever; not stored).
- **Refreshed on a heartbeat**: alive fleet re-emits with CLTV pushed forward ⇒ CLTV always future ⇒ NOT broadcastable ⇒ no griefing/premature close.
- Fleet vanishes ⇒ heartbeat stops ⇒ last exit's CLTV MATURES ⇒ the pre-signed bytes are already public ⇒ **anyone** (keeper / watchtower / LP via a stateless page hitting a public mempool API) broadcasts RAW BYTES — no key, no signing.
- **Reuses Solidity:** `BTCChannels` already has `btcRecipientOf` + registry + splice flow; add exit-emission + heartbeat/deadline field. EVM = trustless bulletin board; **Bitcoin CLTV = enforcement.** Each splice recreates Q ⇒ invalidates the prior exit (only ONE live exit per current Q).

**Tradeoffs (honest, = standard watchtower/dead-man pattern, NOT hand-rolled crypto):** recovers the LAST CHECKPOINT balance (splice granularity, not last off-chain HTLC); dead-man delay Δ before broadcastable. In exchange the LP does LITERALLY NOTHING.

**STATUS (2026-07-24):** SUBSTRATE BUILT + verified where verifiable (reviewed — safety-critical pieces sound):
- `BTCChannels.sol`: `deadManDeadline` mapping + `DeadManExitEmitted` event + `emitDeadManExit` (gated `_requireAttested`+`_authorizedHop` like openChannel, emit-only/no-reentrancy). **solc-clean confirmed**; EIP-170 fine (18379 B, ~6197 margin).
- `taproot_signer.rs`: `new_deadman` nonce (domain tag `quid/musig2/dead-man-exit` via the proven `derive_secnonce_seed_domain` + `with_message(sighash)` — DISJOINT from both commitment domains ⇒ no funding-key leak) + `key_path_sign_2of2_deadman`. **cargo test 12/12 green** (4 new disjointness tests), no OOM.
- SPA `hop.ts`/`page.tsx`: stale self-host/lpAuth copy replaced with honest enclave-custody + `btcRecipientOf` pin + dead-man backstop; manual open reframed as legacy/operator path.
- CLTV = tx `nLockTime` (correct for key-path 2-of-2, no script opcode).

**✅ DAEMON BUILT + SECURITY-REVIEWED (2026-07-24 agent + my review). All 7 §N steps done; 108 quid-ln tests + 17 evm_codec + 3 recovery_broadcast green; `cargo build -p quid-bridge` clean (no OOM).** Files: `taproot_signer.rs` (one-sided deadman helpers), `validating_signer.rs` (in-place `deadman_exit_pubnonce`/`deadman_exit_partial` + `taproot_public_context`), NEW `quid-ln/src/deadman_exit.rs` (rust-bitcoin exit builder + `presign_deadman_exit` 2-signer orchestrator), vendored LDK `channel_keys_id()` accessor, `evm_codec.rs` (`encode_emit_dead_man_exit`), NEW `quid-bridge/src/deadman_exit.rs` (heartbeat task, spawned in daemon `JoinSet`), NEW `recovery_broadcast.rs` + `bin/quid-recover-exit.rs` (keyless broadcaster + CLI), SPA points to the recovery client.
- **MY REVIEW — security-sound (verified in-code):** (1) funding seckey NEVER exported — `deadman_exit_partial` reads `taproot_holder_funding_key()` in-place, returns only (partial, pubnonce); orchestrator passes only pubnonces/partials. (2) LDK `channel_keys_id()` = non-secret KDF index only. (3) nonce = `new_deadman` DEAD_MAN domain tag + message-bind → disjoint from both commitment domains, no key leak. (4) BIP340 sig verifies vs the tweaked `Q` (tested).
- **🔴 RESIDUAL (fail-safe, needs wiring): SPLICED channels get NO live backstop** — heartbeat arms `splice_parent_funding_txid=None` (base scope); a spliced channel's `Q'` ≠ derived `Q` ⇒ exit sig INVALID ⇒ non-broadcastable (no leak/mispayment, fails safe) but unprotected until the monitor's splice scope is threaded into `presign_deadman_exit`. FIX before spliced channels rely on it.
- **Flags:** open/splice coverage is POLL-based (next heartbeat tick, tick-guaranteed) not event-immediate; policy consts `DEAD_MAN_DELTA_BLOCKS=144`(~1d) + `DEAD_MAN_FEE_SATS=2000` tunable; end-to-end on-chain BTC acceptance NOT locally verifiable (no regtest broadcast) — big-box/testnet verify.

~~**NOT built (flagged money-path fork):** the Rust daemon heartbeat task + splice hook that actually PRE-SIGNS + emits.~~ [SUPERSEDED — BUILT above.] Blockers verified by the agent: (1) needs raw funding secret keys + both `commitment_seed`s per channel — private inside the two LDK signers (hop + vault nodes), NO existing accessor (exposing raw funding-key material = a sensitive security-surface change); (2) `initiate_splice_out_to` is interactive + broadcasts immediately — can't produce a held-back future-timelocked pre-signed tx, so a bespoke rust-bitcoin exit builder (unsigned tx → BIP341 key-path sighash → witness) + an `emitDeadManExit` calldata encoder are still needed; (3) not locally fork-verifiable (no regtest BTC broadcast; a nonce mistake leaks the key). The highest-risk slice (the signing primitive) IS built + tested.

**DAEMON WIRING DESIGN (2026-07-24 — security-correct, DESIGNED not built):**
- **Key access = SIGN-IN-PLACE, funding key NEVER exported** (the security-surface answer). The signer already exposes the material internally: `ValidatingChannelSigner::taproot_holder_funding_key()` (validating_signer.rs:464) + `self.inner.commitment_seed` (== the shachain root) + `taproot_key_agg()` (counterparty pubkey from the `TaprootSignerContext`). Add two METHODS mirroring `generate_local_nonce_pair` (:919) + `partially_sign_counterparty_commitment` (:952): `deadman_exit_pubnonce(height,msg)` + `deadman_exit_partial(cp_nonce,height,msg)` — both call the internal key accessor; the raw seckey NEVER leaves the signer. Do NOT use the export-style `key_path_sign_2of2_deadman` (takes raw seckeys) in prod — it stays as the tested reference only.
- **One-sided deadman helpers to add** to taproot_signer.rs (mirror `local_pubnonce` :340 + `our_key_path_partial_counterparty` :390, but new_deadman + DEAD_MAN tag): `local_pubnonce_deadman(...)` + `our_key_path_partial_deadman(...) -> (partial, our_pubnonce)`. Combine via the EXISTING `aggregate_key_path_partials` (:425). Keep the `policy.bind_nonce` guard.
- **2-signer orchestrator** (fleet holds BOTH hop + vault signers, same process): hop.pubnonce + vault.pubnonce → hop.partial(vault_nonce) + vault.partial(hop_nonce) → `aggregate_key_path_partials` → 64-byte Schnorr sig. Indices from `channel_key_agg_ctx` keysort.
- **Exit-tx builder (rust-bitcoin, NOT hand-rolled):** unsigned tx spending the funding outpoint → LP `btcRecipientOf` P2TR, `nLockTime`=CLTV dead-man deadline, non-final input `nSequence` (CLTV = nLockTime, no opcode — key-path spend); BIP341 key-path sighash (`SighashCache::taproot_key_spend_signature_hash`) = the `message`; witness = [64-byte sig]. Reuse the `checkpointSats` − fee for the output value.
- **`emitDeadManExit` calldata encoder** (evm_codec) + EVM submit (reuse `estimate_gas_and_send`).
- **Heartbeat task + splice hook:** a periodic daemon task that re-signs with a pushed-forward CLTV + submits `emitDeadManExit`; and a hook at splice (each new Q) to emit the fresh exit. Reuse the existing daemon task/loop structure.

**WHERE THE BROADCASTER GETS THE BYTES (user Q, 2026-07-24):** the fully-signed exit tx bytes are carried in the on-chain **`DeadManExitEmitted(channelId, lpEth, cltvDeadline, checkpointSats, signedExitTx)` event** (BTCChannels — BUILT). Any broadcaster (a watchtower, a keeper, or a stateless one-page web app) reads the LATEST event for the channel via `eth_getLogs`/an indexer, extracts `signedExitTx`, and POSTs the raw bytes to a public Bitcoin mempool/Esplora broadcast endpoint. **No key, no signing — just publishing already-public bytes** once the CLTV has matured. **NOT BUILT:** the broadcaster/recovery reader itself (the SPA copy was updated to describe it, but the one-page-web / watchtower reader that does `getLogs → POST rawtx` is not written). Flag.

## O. SIMPLIFICATION SWEEP RESULTS (#115 scan, 2026-07-24) + TODAY'S OPEN-ITEM CAPTURE
**GATE MAP (verified):** `Aux._requireUs` = {V4(**=Vogue**), CORE, QUID, ethVenue(**=Vault**), this}. `Core.onlyUs` = {AUX, VOGUE, BTCVAULT(=Vault)} — **BTCChannels NOT a member**. `Vault.onlyUs`={V4,AUX,this}; `NotVogueCore`={V4}. Vault/BtcVault/ethVenue = ONE merged contract. LevManager(ETH)/BtcLevManager(BTC) = parallel siblings sharing LevMath.

### O.1 Ranked findings (READ-ONLY; re-verify caller-set before acting; 🔴=money-path fork-verify)
**TIER 1 — behavior-preserving wins:**
1. 🔴 **DEAD vBTC roundtrip** — `Vault.mintVBTC`(:583)+`burnVBTC`(:590) + `BtcVaultLib.vbtcMintBody`(:561)+`vbtcBurnBody`(:568): `onlyBtcChannels` but BTCChannels NEVER calls them; live path = `expose/unexposeBtcToLev`. DELETE all 4. Fork-verify vBTC totalSupply invariant. KEEP `vbtcTransfer/vbtcTransferFrom` (venues use them). EIP-170 win (Vault+lib).
2. **DEAD internals** (0 tree refs): `Rover._adjustToNearestIncrement`(:433), `TargetsHelper.countEpochCumulativeWork`(:114, sibling `countCumulativeWork` is used), `BitcoinTx.hash160`(:291). DELETE.
3. 🔴 **ETH/BTC byte-identical dedup**: `debtUsd`(LevManager:390 vs BtcLevManager:153), `swapOutDeleverAmt`(LevManager:798 vs BtcLevManager:550), open-LP set primitives `_trackOpen/_untrackOpen/openLevCount/openLpAt`(LevManager:122-136 vs BtcLevManager:71-83). → shared LevMath helpers + a shared abstract base. Helps EIP-170 on BOTH near-limit managers. Fork-verify swap-out delever. (`swapOutDelever` itself NOT mergeable — ETH sig+pooled-walk ≠ BTC single-LP.)
4. **Unused iface methods**: `ILevSyncHook.bandEthOf`(LevManager:45), `ILevSyncHookB.bandBtcOf`(BtcLevManager:10) — declared, never called (managers size off `pos[lp].e0Eth`). Remove decls (compile-time safe). Defs `Vogue.bandEthOf:214`/`Vault.bandBtcOf:636` removable only if no off-chain lens reads (Tier-3).
**TIER 2 — lateral (the template pattern; user's call):** `Vault.addPendingSwapOut/subPendingSwapOut`(:964-965) = 1-line forwarders bridging BTCChannels→Core (BTCChannels not in Core.onlyUs). Collapse = new Core `btcChannels`-gated entry. LATERAL (relocates trust boundary; can't widen Core.onlyUs = would expose modLP/swap = security). Don't action w/o a bytecode/security driver.
**TIER 3 — LOW confidence dead (confirm NO off-chain/keeper/SPA reader first):** `LevManager.weethValueUsd`(:292, dup of LevMath:453), `Vault.aaveEthBalance`(:416, vestige per Aux:827), `Core.btcBandEquityUsd18`(:120), `BTCChannels.openChannelDigest/spliceDigest/swapOutDeliverDigest`(:563/586/606, likely off-chain signer conveniences).
**KEEP (investigated, NOT dead):** delegatecall-to-lib thin forwarders (EIP-170 relief = load-bearing); `Vogue.takeETH`(:895, gate boundary); ~15 `IAux*` interface fragments (interfaces=0 bytecode; consolidation=cosmetic + regression risk); `ILevManagerDeliver` vs `ILevEthDeliver` (only `swapOutDeleverAmt` overlaps; delever sigs differ); arbETH/arbBTC/ratchet/baseRate/deferToWaitNft/acquirer = already fully deleted (only comment tombstones remain); vendored unused iface members (3rd-party, leave). Events/errors/modifiers swept clean (1 emit/revert each).
**FACTUAL FIX:** `Vault.sol:369` docstring "Vogue is NOT takeToSettle-authorized" is STALE/WRONG (V4=Vogue IS in `Aux._requireUs`) — fix comment (ties to §M.1 gating correction; = why `fundVenueForDelever` is unnecessary).
**ACTION ORDER:** #1+#2 first (biggest Vault/manager bytecode relief) → #3 → #4 → Tier-3 after confirming readers → skip #5.

### O.2 TODAY'S OPEN-ITEM SWEEP (re-read all responses; nothing lost)
- **Comment purge (user 2026-07-24):** stale arbETH-removal tombstones `Vault:430-433` + `SwapLib:125-128`; my arbETH-distraction comments in the #113 ETH de-lever (`Vault.fundVenueForDelever`, `SwapLib.deleverEthOnDelivery`, `Vogue._sendETH` hook — the "NOT arbETH" clutter); `Vault:369` stale docstring. `_sendETH` is a GENERIC send utility — no arbETH relevance. PURGE all. 🔴 QUEUED.
- **D3 θ fee-yield (§J.5):** the CORRECT source (`feesPerShare`/`USD_FEES`, θ-LOCAL) was NEVER built — only the wrong `skewPremium` version (reverted). Still QUEUED (user asked; I held back). 🔴.
- **JIT flash-refill (§J.3):** still NOT built (design only).
- **#113 fundVenueForDelever:** now KNOWN unnecessary (gating misread, §M.1) — DELETE when #113 necessity is decided.
- **#113 DeleverEthBackingProbe:** not built (§M.1).
- **Short-leg (§J.4 anchor):** OPEN; code removed this session but removal MAYBE premature — user's call whether to restore.
- **task #12** (vote enforcement) = already `completed` (user asked "did you build #12?"). If "#12" meant something else, clarify.

### O.3 DISCOVERY RESULTS (2026-07-24 agent) — refill/JIT Rust + the REAL #12
**A) "Unfinished refill/JIT Rust" — the Rust is actually DONE + green (`cargo check -p quid-bridge` = Finished).** The uncommitted Rust (daemon.rs, lev_keeper.rs, lev_keeper_btc.rs, taproot_signer.rs, stamped Jul 22) is COMPLETE: #8 acquirer removal (lev_keeper_btc), #9/#89 `out_of_band` dedup, #114 dead-man nonce substrate, daemon spawn-arg drop. `quid-hop/{rebalancer,swap,event_handler}.rs` = NO diff. ⇒ the "unfinished refill/JIT" is NOT dangling Rust; it's one of:
  - **§J.3 JIT flash-refill = genuinely NOT built** (EVM callback near `Vault.sol:935` flash-WBTC→creditSwapIn→SOR→repay, permissionless + a Rust keeper trigger). `JIT-DEPTH-GUARANTEE.md` = "No code yet." No `flashRefill`/`reservoirDeplet` symbol in evm/src. **← most likely what the user means.**
  - **#59/#74 native BTC↔stable rail = deferred**: `lev_keeper_btc.rs:196/212 do_delever/do_relever` are DELIBERATE loud no-ops for NATIVE (channel-vBTC) positions (fall to venue isolated liq); `usd_to_vbtc_sats:77` is `#[allow(dead_code)] // reserved for #59/#74`. WBTC-mode (shipping) never reaches them.
  - Pump #100: `payRefillBonus` already REMOVED (Core.sol:261, self-funding); `creditSwapInBody` built. No refiller/reservoir keeper defined-but-unspawned.
**B) The REAL #12 = "drop voting + unify POOLED_USD" (§H / BUILD-QUEUE:162,164) — PARTIAL:**
  - **Half 1 DROP VOTING = DONE in EVM (uncommitted):** `Basket.sol` −126 lines (K_btc/SUM_btc/WEIGHTS_btc[90]/btcShareVotes/_median/btcShareBps/_resyncVotes all gone); `Core.maxPooledUsdBtc`+median readers gone; `SwapLib:1241` cap removed. **REMAINING = SPA cleanup:** `abi.ts:55-60` (vote-cast ABI + btcShareBps view), `page.tsx:849` (btcShareBps compute), `AllocationSlider.tsx` usage — ⚠️ AllocationSlider is SHARED with ComfortPanel (leverage-cushion slider STAYS); remove only the BTC-share usage, not the component.
  - **Half 2 UNIFY POOLED_USD = NOT STARTED:** `Core.sol:91/93` still separate `POOLED_USD_ETH`/`POOLED_USD_BTC`; `committedUsd18() :106-107` still SUMS both bands; invariant `:48-52` unchanged. Target: two mockUSDs MIRROR the same dollars, count ONCE in committedUsd18, drop the sum-cap (each side sizes vs `TVL−own_committed`), stale-pre-read racing swaps revert. **⚠️ SUPERSEDED — ECHIDNA GATE RE-INSTATED (user, 2026-07-26: "do not delay echidna verification, we have the capability to do this now").** The 2026-07-24 lift ("no echidna needed for now, just build it then we will verify later") NO LONGER APPLIES: the box now has Echidna 2.3.2 + 16 GB, so verification travels WITH this build instead of trailing it. Still BUILD NOW — the defense is by-construction (§C#20) and Echidna VALIDATES rather than gates — but land the crash-drain + POOLED-no-double-spend invariants alongside, not "later". See §C#20 for the confirmed toolchain + the no-existing-scaffolding finding. NOTE: this SUPERSEDES the "Echidna-gated"/🧊 language in §H.5 and §C#12/#20 — those are stale; the unify is GO.

## P. PRESERVATION PASS (2026-07-24) — recovered from transcripts (today + 07-22) + reconciled gaps
Two sweep agents (today's 3 transcripts incl. the 280MB pre-compaction one; the 07-22 session) + a targeted refill-thread extraction. The 5 user-named "maybe-dropped" topics (SPA-openChannel, Rust, directional long/short, [TODO]s, refill/JIT) are ALL already covered (§I.1/§J.6/§N, §O.3-A/§K, §K/§J.4, §J.7 [10 markers, grep-verified complete], §J.3). Below = the genuine residue.

### P.1 REFILL/RESERVOIR — full reasoning recovered (compaction kept only fragments; from 1f505948 L22655/L39720/L74823)
- **Two-layer refill (do not conflate):** (1) the RESERVOIR (#100) is the **IN-TX ATOMIC self-refill** — the drain refills itself, same tx, from the protocol's OWN reserve ⇒ no external counterparty in the critical path, no bonus, no searcher race, no on-chain imbalance ever persists. (2) the reservoir **REPLENISHES ASYNCHRONOUSLY** (fleet, at fair value, under NO time pressure ⇒ no gas-war). Chicago-Deep-Tunnel analogy: decouple the surge from the processing rate — the plant only handles the average, the reservoir buffers the peak.
- **Why a swap-in refill CANNOT be JIT-internalized into the drain:** they're OPPOSITE directions (drain = swap-OUT, pool ends USD-heavy; refill = swap-IN, brings volatile back). The draining tx can't refill itself from thin air — a real refill needs a counterparty who brings volatile. Only two counterparties: an EXTERNAL refiller (→ bonus → race) OR the protocol's OWN reservoir (→ no bonus, no race). ⇒ the reservoir is the answer; §J.3 "flash-refill" folds into #100.
- **Liquidity-mismatch is STRUCTURAL (the async keeper unwind can't be designed away):** leverage makes claims LIQUID (LPs withdraw anytime) but part of the backing is LOCKED behind a debt-repay-then-unwind on Euler/Morpho. When an unlevered withdrawal exceeds the FREE (unencumbered) ETH and hits the locked piece, the band physically cannot hand that ETH over IN the withdrawal tx — the keeper's unwind is ALWAYS a separate (async) tx ⇒ the `_withdraw` deferral residual (recoverable `LP.pooled`) is structural, not paranoia; a live keeper just makes it a rare backstop. (The elegant `emit AccordionNeeded`→keeper is design-only, NOT built.)
- **⇒ reinforces §J.3's load-bearing constraint:** the async layer (replenishment / keeper unwind / §J.3 flash-refill) can NEVER retire a synchronous in-swap guard — the swap-out→refill window is the adversary's window. Sync guard STAYS (#101); async refill is additive convergence only.

### P.2 TODAY's gaps (from the today-sweep)
- **P.2a IL-MATH — SETTLED 2026-07-24 (user's premise CONFIRMED by code):** "the levered slice is band DEPTH so it eats its own IL — don't we need >2×? did you check the math with the levered part in the band?" **CODE FACT (VogueLib:150/160/162/167/180): the GROSS is in the band** — `levAddGross` runs BOTH `levAddNet` (net→`modLP` into V4, as equity/pooled) AND `levAddBuf` (buffer→`levBuf` fee-weight **AND the V4 position**). So the whole gross `C` experiences the √p band-selling. The `LevYbPnl` test modeled only NET-in-band ⇒ its model is incomplete (its *conclusion* — dynamic-sizing cancels IL, static-2× doesn't — still holds).
  - **Correct math (gross-in-band):** net ETH = `C/√r − D/r` (band sells the gross `C/√r`; the offset is the FIXED-USD debt `D` SHRINKING in ETH-terms `D/r` as price rises — NOT a held-delta-1 buffer). At entry r=1 with C=2E0,D=E0: net=E0, and dδ/dr=0 ⇒ **static 2× is delta-1 ONLY at entry.** For large up-moves it UNDER-hedges (r=4 ⇒ 0.75·E0). ⇒ **you DO need leverage to rise above 2× as price rises** — the user is right.
  - **HOW it's handled (already designed): the DYNAMIC keeper target `ilTargetLive = 1−√(entry/now)`** re-levers ABOVE 2× as price rises to hold IL-neutrality — a static 2× would not. So no static change; the keeper's dynamic re-lever IS the >2× the user intuited.
  - **RESIDUAL (verify, not a blocker):** re-derive that `ilTargetLive` EXACTLY cancels the gross-in-band IL for all r (the test's net-in-band proof doesn't cover it) + fix `LevYbPnl` to model gross-in-band. 🔴 QUEUED (math-verify + test-fix). Paired Q "escrow weETH on AaveV4?" = ANSWERED no (Aave=rehyp; escrow only Morpho/Euler).
- **P.2b Swap-out "add-collateral-instead" (user mid#37) — CORRECTED (my earlier "rejected" was WRONG):** user asked "ARE WE ALLOWED to let this swap out, won't it cause IL for the LP who levered to prevent IL — should it just ADD EXTRA COLLATERAL to the loan?" The add-collateral instinct is **CORRECT and is REALIZED, not rejected**: after the §M.1 de-lever delivers the ETH value-neutrally, the keeper **RE-LEVERS — which IS "adding the collateral/exposure back to the loan."** So the round-trip = deliver (sell) + re-lever (re-buy) = **a WASH + the swap fee ⇒ NO IL locked in** (the exact protection the LP levered for). The only nuance: it's not done INLINE (add-collateral-instead-of-delivering) because the swapper genuinely wants ETH OUT and inline-add wouldn't relieve the phantom depth; it's done as deliver-THEN-re-lever (async keeper). Net effect = identical to the user's intent. Pin in §M.1.
- **P.2c Short-removal DEAD-CODE residuals (from the removal agent's own flags) — pending §J.4 restore decision:** (a) `DeployL1_s._ethShortVenue` + `InverseRateMorphoOracle` import left INERT; (b) `SwapLib.boughtFractionWad` now DEAD (Vogue/Vault impls removed); (c) KEPT short-concept tests `testProof_ShortLeg_BoundedByConcentratedBand` + 4× `testProof2_*` + `testProof_NestedShort_Solvent_BandUntouched` validate the deleted design. If §J.4 stays removed → delete these; if RESTORED → they come back. Hold with the §J.4 anchor.
- **P.2d SPA pre-commit storage (user mid#49) — pin the resolved Q→A:** "keeping the pre-commitment? how does the LP store it? not cookies? reuse Solidity?" ANSWER (already in §N substance): dead-man exit = fleet-signed, EMITTED on-chain (`DeadManExitEmitted`), broadcast keyless by anyone; the LP stores NOTHING (no cookies, no keyfile) — the EVM event is the durable store, `registerDelegation`/`btcRecipientOf` is the Solidity reuse. Pin to §I/§J.6 openChannel-SPA task.

### P.3 07-22 gaps (from the previous-session sweep — NEVER migrated into the doc)
- **P.3a 🔴 BIGGEST: cross-contract byte-identical INTERFACE CONSOLIDATION is HALF-DONE + untracked.** The 07-22 dedup map found ~5 byte-identical interface clusters duplicated across files; only the LEV subset was applied (commits 5e5b636/6d44ee6). Still duplicated VERBATIM, and **no `imports/Interfaces.sol` exists**: `IAaveV4Hub`×4 (Aux:43, Vault:53, ChannelLib:49, AaveV4Venue:10); `IWeETH`×6 (Vault:64, LevManager:23, LevMath:20, SwapLib:23, VaultLib:18, Rover:22); `IDepositAdapter`×4 (Vault:60, Rover:21, VaultLib:21, LevMath:24); `IMorphoFlash`×2 (LevManager:65, BtcLevManager:16); `IAggregatorV3`×2 (FeeLib:20, SwapLib:30) + the two `IEthVenue` subset merges. ⇒ create `imports/Interfaces.sol`, point all at it. (§J.1 captured a DIFFERENT framing; §O.1 wrongly deemed the IAux* family "cosmetic skip" — this concrete byte-identical cross-contract dedup is real + EIP-170-relevant.) 🔴 QUEUED. NOTE the view/non-view de-uglification (IAuxTWAP_B vs _BView, non-view boughtFractionWad) WAS done (5e5b636).
- **P.3b THREE 07-22 security findings NEVER folded into §A — migrate:**
  - 🟠 **MED — oracle anchor is OPT-IN:** `getTWAPforAsset` short-circuits to the RAW internal V4 TWAP when `assetPriceFeed[asset]==0` (`SwapLib.twapResolve`); ALL lev valuation + BTC swap-in pricing read it; `setAssetFeed` is PIN-ONCE ⇒ a renounce/finalize BEFORE WETH/WBTC feeds are pinned leaves collateral/debt grind-able over a multi-block TWAP. FIX: make the Chainlink anchor MANDATORY for WETH/WBTC (revert if unset, or block finalize/renounce until both pinned). → §A/§DR.
  - 🟡 **LOW — `Vogue._venueBalance` upward bias (LIVE, Vogue:765-769):** on a `catch` of `totalNetEquityEth()` it leaves `total` at full `vogueETH` (incl levered net-equity) ⇒ over-counts plain-venue backing (UNSAFE direction) → over-delivers ETH to an exiting plain LP / books a lev open-close as fake venue yield. FIX: catch → exclude, or fail-closed. → §A.
  - 🟡 **Minor — stale `BtcInflowCap` comments** (BTCChannels:256, AttestedHopRegistry:30-38) assert a per-call bound `SwapLib:701-702` REMOVED; underlying HIGH (settleSwapIn can drain POOLED_USD_BTC) is §A#22 but rated 🧊-LOW/SGX-deferred vs the agent's HIGH — reconcile the rating + purge the stale comments. → §A#22.
- **P.3c dead-code residuals (07-22, low-confidence):** `Vogue.VENUE_GALAXY:92` (declared-only, 1 ref — maybe intentional const), `spv/libs/TargetsHelper.targetToBits:159` (no callers; inverse `bitsToTarget` used). Confirm then remove. → §O.1/§R.

## Q. USER NOTES + DESIGN QUESTIONS (2026-07-24 batch — verify/record/decide; do NOT lose)
- **Q1 #109-withdraw (closeLevFor + _reconcileLev) — ✅ VERIFIED DONE (~3 days ago work landed):** `Vogue.sol:487` `closeLevFor(msg.sender,0)` → `:488 _reconcileLev` (clears the nonReentrant-blocked slice); `:457` reconcile on levPooled>0. The redeem/swap-out shortfall sweep (§G) + #10/#9 also landed (§O.3-A). Nothing outstanding from that 3-day-old list EXCEPT the Q7 ranking gap below.
- **Q7 shared shortfall-de-lever primitive — 🟡 MOSTLY, ONE GAP:** shortfall-triggered + shared per-LP machinery EXIST (redeem→`deleverBook` LevManager:883; ETH swap-out→`deleverEthOnDelivery` SwapLib:1198; BTC→`deleverOnDelivery` #54; withdraw→`closeLevFor`). Invariant "any removal of levered in-band value de-levers proportionally, on shortfall past funded, never blindly/per-LP" = HELD. **🔴 GAP: the REACTIVE walk (`deleverBook`/`deleverEthOnDelivery`) iterates `_openLps` in STORAGE order, NOT highest-LTV-first.** Only the keeper's `cascadeDelever` takes an LTV-ranked list. FIX: sort the reactive walk highest-LTV-first (de-lever riskiest slices first) so "same ranking, two triggers" actually holds. 🔴 QUEUED.
- **Q2 Morpho account ownership + authorization (user):** the MANAGER is the Morpho/Euler account owner (NO per-LP `isAuthorized`/sub-accounts). ⇒ the manager can de-lever/unwind ANY LP on behalf of all (needed for the shortfall sweep + keeper) WITHOUT per-LP permission prompts. RESOLUTION: the LP's permission IS granted by opting in via `openLev` (the control flow that hands collateral to the manager's account) — enforced ON-CHAIN in that tx regardless of whether they used our SPA. So: no per-function off-chain authority scheme needed, and no need to forbid programmatic (non-SPA) banding — an LP CANNOT be simultaneously in-band AND borrowed without going through our control flow (openLev), and that opt-in is the enforced permission. Commingled single-account, per-LP accounting in `pos[lp]`. ✅ no change needed; document the trust model.
- **Q3 SAFE/deployer ownership — CORRECTION (user) + ⚠️ TENSION with current adminless design (must resolve before building):** user says: the DEPLOYER (`.env` key) owns ANGEL (NOT "the Safe"), and IN THE DEPLOY SCRIPT: (1) CREATE the SAFE, (2) ADD ITSELF as a SAFE member, (3) at `finalize()` TRANSFER ownership → the SAFE. **BUT the CURRENT `DeployL1_s` is deliberately ADMINLESS** (line 391 "NO governance handoff, adminless — every admin key RENOUNCED, no multisig handoff"; `AUX.finalize()`:404 burns ANGEL + RENOUNCES Aux; :405 Safe renounces Basket; :150 comment "the Safe (deployer) MUST own ANGEL"). So Q3's "TRANSFER to SAFE at finalize" ≠ the current "RENOUNCE at finalize" — it flips adminless → **Safe-governed**. TWO parts: (a) the ANGEL-ownership CLARITY fix (deployer≠Safe; fix the :150/:394 comments) is safe. (b) the transfer-to-Safe-instead-of-renounce is a **GOVERNANCE-MODEL DECISION** that reverses the deliberate adminless design — 🔴 NEEDS USER CONFIRM: does QU!D become Safe-governed (deployer-created Safe = owner post-finalize), abandoning adminless? Do NOT rewrite finalize until confirmed. (verify-intent: the adminless renounce was intentional.)
- **Q4 JIT/refill TRIGGER (user):** trigger it PER-NEED, NO caller/keeper gas-comp — i.e. **as a STEP folded into `reseat`/`repack`** (which already run per swap / LP-in / LP-out), same cadence as reseat/repack. "Was that the original plan?" — YES, adopt it: the JIT/reservoir refill piggybacks the existing reseat/repack hook (no standalone keeper, no gas-comp). 🔴 QUEUED — wire the JIT/reservoir top-up into the reseat/repack path (ties §J.3 + #100 + P.1).
- **Q5 directional levPooled / manual-band recognition (user, "increase elegance"):** directional levers never auto-band ⇒ `levPooled==0` ⇒ naturally untouched by the band sweep. RISK: if a directional-levered LP MANUALLY bands, the band doesn't see the lever (levPooled=0) so it won't know to unwind on shortfall. **Direction (elegance):** the shortfall-de-lever reaches LPs via the LevManager's `_openLps` book (ALL levered LPs), NOT via the band's `levPooled` — so reachability does NOT need `levPooled` at all. `levPooled` is only a FEE-WEIGHT/accounting var. CONSIDER: drop `levPooled` as a Solidity state var and let the keeper/JIT own the lever↔band association (the de-lever already walks `_openLps`; the manual-band case is covered because the LevManager book still lists the LP). 🔴 QUEUED — evaluate removing `levPooled` (keeper/JIT-owned) vs keeping it; ensure manual-band of a directional-levered LP is still swept (via `_openLps`, not levPooled).
- **Q6 REDEEM auto-de-lever PRIORITY (user directive):** a redeem that must carve back from the band **MUST auto-de-lever and release the HODL (net-equity)** — REDEMPTION IS THE PRIORITY, above the LP's lever. Even if the de-lever doesn't cover the LP's IL, the LP NEVER loses PRINCIPAL or the FEES earned to that point; they only lose the lever. **🔴 GAP:** current `deleverBook`→`deleverToVault` caps at `deliverableDollars` (the #67 value-neutral, LTV-safe bound). For the edge case where a redeem needs MORE than that bound, it does NOT escalate to releasing the full HODL. FIX: redeem shortfall must be able to ESCALATE past the value-neutral cap → close the lever / release the full net-equity (LP keeps principal+fees, loses lever, may eat residual IL). Edge case (redeems will rarely unband) but must be protected. 🔴 QUEUED. NOTE this is REDEEM-ONLY escalation — swap-out stays value-neutral-bounded (#105 partial-fill beyond).

## R. 🛡️ FLEET-DOWN USER PROTECTION — HARD INVARIANT (user, 2026-07-24: "protect the user in ALL possible ways if the keeper/fleet is NOT available")
**INVARIANT: every BTC-side user action must have a NON-CUSTODIAL, FLEET-INDEPENDENT fallback. The keeper/fleet is a convenience/default path, NEVER a safety dependency.** The trust anchor is always ON-CHAIN, so the completer (keeper or not) cannot cheat.

**R.1 openChannel = a KEEPER ENDPOINT, permissionless (user re-affirmed the design):**
- `openChannel` verifies the SPV proof + `lpAuth` (ecrecover) ON-CHAIN ⇒ whoever submits literally cannot cheat: bad proof reverts; channel owner = the `lpAuth` SIGNER, not the submitter ⇒ can't steal/misassign. Exposing it as a keeper endpoint adds ZERO fund-theft surface.
- Folds into the existing BTC keeper loop (fleet already watches BTC, builds SPV proofs for splice/close, submits rebalanceWbtc/cascadeDeleverMany/close). Completing an open = same class of op (detect funding at derived addr → build proof → submit). Not a new service.
- LP's job shrinks to: fund the address (ONE non-custodial BTC send — keeper NEVER touches the sats) + hand over `lpAuth` (bundled). 
- **PERMISSIONLESS FALLBACK (the fleet-down protection):** the SAME `lpAuth` can be submitted by the LP OR any relayer. Keeper down/spammed → LP self-submits or uses another relayer → same signature, same result. **No liveness lock-in.** Only real surface = liveness/DoS, neutralized by permissionlessness.
- **Trust STRONGER by reuse:** the default completer is a DCAP-attested fleet (AttestedHopRegistry) — a known attested entity, not an anonymous relayer — while the permissionless fallback makes attestation a BONUS, not a required assumption. Same attestation that secures splice + close.
- **GUARDRAILS (keep it clean):** (1) NEVER CUSTODIAL — the keeper automates everything AFTER funding; the moment it holds the LP's sats "to fund on their behalf" = a real trust surface, DON'T. (2) STATELESS/IDEMPOTENT handler — public inputs only (pubkey/amount/proof), no secret state, safe to re-run.

**R.2 FLEET-DOWN FALLBACK per flow (the audit — every row MUST have a non-custodial fleet-independent path):**
| Flow | Fleet-down fallback | Status |
|---|---|---|
| **Open channel** | permissionless self-submit (LP/any relayer, same `lpAuth`+SPV proof) | ✅ design (R.1); verify the keeper endpoint + permissionless submit exist in code |
| **Swap-in** (BTC→USD) | user CLTV refund if the hop never settles (on-chain, `requireFull` refund) | ✅ #105/#70 built — verify |
| **Swap-out** (USD→BTC) | user CLTV refund / on-chain splice-out; #105 partial-fill refund | ✅ built — verify the refund can't be fleet-blocked |
| **Splice / cooperative close** | LP's own committed shutdown → recordClose pays `btcRecipientOf`; force-close via commitment | verify LP can force w/o fleet |
| **FLEET VANISHES ENTIRELY** | **the DEAD-MAN EXIT (#114)** — fleet-pre-signed, on-chain-emitted, keyless permissionless broadcast after CLTV | ✅ built; **splice-scope GAP FIXED 2026-07-24** (added `ChannelMonitor::splice_parent_funding_txid()` [same scope as `get_funding_txo`] → `arm_signer` threads it → both signers derive the ROTATED key/`Q'`; module-doc FLAG→WIRED). Spliced channels now get the backstop. ✅ `cargo check -p quid-bridge` CLEAN (1m21s, no OOM). Only big-box fork-verify remains (no regtest BTC broadcast locally). |
| **Recovery of the exit bytes** | on-chain `DeadManExitEmitted` event → anyone broadcasts (keyless); `quid-recover-exit` CLI | ✅ built |

**R.3 🔴 ACTION:** (a) **wire the splice-scope into the dead-man exit** (in progress — else spliced channels lose the fleet-down backstop); (b) AUDIT each R.2 row in code to confirm the fallback is real + cannot be fleet-blocked (esp. that CLTV refunds + permissionless-open submit don't secretly depend on a fleet-only path). This invariant GATES the openChannel-keeper build (R.1) — permissionless fallback is MANDATORY, not optional.

## S. SCAN-RECOVERED OBSERVATIONS (2026-07-24) — assistant-flagged items not previously in doc/memory
Full-thread scan of my own responses (this session + the 280MB pre-compaction session), diffed vs the whole doc + memory, EXCLUDING the short/YB thread (anchored §J.4/§K). The doc was already near-complete; these 8 are the genuine residue:
- **S1 🟡 STALE CAP DRIFT (comment/log only):** `openLev` docstring + the Rust keeper's logging still say "L ∈ [1,2]" / clamp `5000`, but the ENFORCED ceiling is `7500` (4×). Reconcile so comments/logs don't mislead. (Distinct from §A#2's deliberate "≈4×" prose — this is an unambiguous stale OLD cap.) → §A drift / §C#16 / §J.7.
- **S2 🔴 #111 GAS-PASS concrete wins** (doc §D only has the generic sweep; "#111" appears nowhere): `_deployed`→`immutable`; the `get_deposits` **2–3× call dedup (the real gas win)**; struct-packing `SelfManaged`/`BTCChannel`. NOTE dropping `currentMonth()`/`totalSupply()` caching = MARGINAL (don't bother). → §D.
- **S3 🔴 vogueBTC solvency/θ sum uses the HEAVY per-LP debt read:** `vogueBTC` sums per-LP `debtOf` on-chain via `getUserReservesData` (~30+ Aave reserve structs PER CALL) — gas-heavy exactly where summed on-chain. FIX: light per-asset `IAaveProtocolDataProvider.getUserReserveData(STABLE, escrow).currentVariableDebt`. (Applied to the new `AaveV3Venue` already; the on-chain SOLVENCY-SUM path itself is uncaptured.) → §D / §L.1.
- **S4 🟡 `FORFEIT_BPS` magnitude = open money-knob (immature-redeem haircut):** seed mints project ~100% APR, so ONE conservative constant covering seed (~50%+) over-penalizes regular early-exiters. Choice: (A) one conservative `FORFEIT_BPS` (~25%) vs (B) haircut the FORWARD-YIELD component specifically. Real money knob — decide. (memory `FORFEIT` is unrelated = channel-retire.) → §C#7 / §B `mature_quid_usd`.
- **S5 🔴 BOLD rate for the ETH IL-leg must be set HIGH (out of Liquity-V2 redemption range):** Liquity V2 redeems the LOWEST-rate troves first, taking their ETH at FACE — worst case for a levered-LONG. ⇒ can't set the trove rate to the floor for cheap carry; set it high enough to stay out of the redemption band. (memory `leverage-liquity` has the generic concentration risk but NOT this rate-setting constraint; §K.2/§L directional-lever spec uses BOLD WITHOUT it.) → §K.2 / §L.
- **S6 🔴 ETH 2× lever CARRY = OPEN, PERMANENT question (user corrected my bad recording 2026-07-24):** I originally folded a hand-wave ("negative carry is launch-phase only, at volume fees cover it"). **That's FALSE — QU!D is a PERMANENT product, not a launch-phase.** The real question is STRUCTURAL and permanent: does the 2× ETH lever's yield (fees on 2× gross band depth + weETH staking yield on the buffer) COVER the stable-borrow APR on the debt? If NEGATIVE, someone bears it PERMANENTLY — per IL-truth (memory `il-bonds-truth`), the ETH LP. "At volume fees cover it" is not an answer (volume scales both sides). 🔴 UNRESOLVED — needs the real carry math (fees(2×)+staking vs borrow APR) + WHO bears a permanent shortfall, NOT a transient framing. Answers §D "2× fold math / who pays interest?" ONLY once actually derived. → §D / §B.
  - **📥 BACKFILL (the exact terms to plug — so the carry is computable without private context):** **YIELD** = (a) band swap-fee yield on the **2× gross** depth (≈ `2 × fee_rate × band_volume / equity`) + (b) **weETH staking yield (~3–4% APR)** on the buffer half. **COST** = the **stable-borrow APR** on the debt (Aave/Morpho/Euler USDC market rate). **Net carry per unit debt = (a)+(b) − borrowAPR**, and it is PERMANENT. If negative, the **ETH LP** bears it (memory `il-bonds-truth`: bond=dollar leg has no IL; IL/carry falls on ETH LPs). The live numbers are NOT in-repo — plug current rates to resolve. Do NOT accept "at volume fees cover it": volume scales BOTH (a) and the borrow base, not the spread between them.
- **S7 🟡 SPA: pin the Rover "best execution (recommended)" marker** at the venue picker in `LeverageActionPanel.tsx` (+ the swap-route display). (§C#18 has a generic "Rover" marker; this pins file+copy.) → §C#18 / §I.2.
- **S8 🔴 SWAP-PRICING guards #2/#3 are CHAINLINK-FEED-DEPENDENT ⇒ FEEDLESS stables (cUSD, BOLD) get NO cross-check** — they lean on the depeg-severity / CRE path instead. (Distinct from §P.3b's WETH/WBTC pin-once oracle = collateral/debt TWAP; this is swap-pricing guard COVERAGE for stables.) → §A / §P.3b.

**Marginal (recorded for completeness):**
- **S-m1** `vogueOp` fold is lateral, revisit at fork-verify (already ≈ §O.1 KEEP thin-forwarders + §M.1).
- **S-m2 (USE in #12 unify build):** `SwapLib:763` is an OBLIGATION/solvency check (`POOLED_USD_BTC ≥ pendingSwapOutUsd`), NOT an imbalance floor — it MUST be KEPT when dropping the sum-cap. "Not all POOLED guards are imbalance floors." → fold into the #12 unify-POOLED_USD build (§O.3-B).

**DEEP RE-SCAN (2026-07-24, whole-turn read, broader net — S6 was a bad recording, so this pass reads for substance not phrases). Slice-4 (this session) additions:**
- **S9 🔴 #111 gas — add `require`→custom-error bytecode sweep** to the S2 wins list (S2 enumerated `_deployed`→immutable + `get_deposits` dedup + struct-pack but OMITTED this). → §S2/§D.
- **S10 🟢 FLAT-MULTIPLE product = DECIDED AGAINST (answers the OPEN §D:219 check "hold 2× vs no-continuous-churn"):** do NOT offer a maintained flat 2×/3×/4×/5×. Holding a constant multiple through every wiggle re-levers on every up-tick → LLAMMA-style churn. The keeper deliberately tracks the cap-bounded IL target `1−√(entry/now)` **with a dead-band** = correct AND low-churn. ⇒ resolve §D:219 as ANSWERED. → §D:219 / §K / §B.
- **S-m3 (marginal, load-bearing link):** do NOT conflate the `btcShareBps` median-VOTE drop (§H) with the `getTWAPforAsset` Chainlink price-ANCHOR — the JIT/reservoir refill balances inventory TO the anchor's honest target price, so the ANCHOR is load-bearing for JIT and MUST stay; only "median-as-allocator" is droppable. → note in §H / §J.3.
- **S-m4 (marginal, muddled):** #12 per-side liveness floor is DROPPABLE under atomic swap-out+refill lockstep (swap reverts if it can't refill ⇒ imbalance never persists ⇒ floor never binds); count-once + stale-read-revert STAY. NOTE user later reframed #12 as "just the vote/§H removal" + called the floor language a mislabel ⇒ one-line reconciliation only, not a build note. → §C#12/§H.5.

**Scan confirmed FULLY captured (not re-listed):** short/YB (excluded), WBTC venue-depth (Aave-v3 deepest, resolved in-session), `.env`/`deploy.env` (all ignored, correct — resolved in-session), #113/#114/#115, POOLED-unify, θ-μ D3, audit #1–#23, ERC-7201 cold/hot-loop gas (memory `lev-fold-gas-findings`), Black-Thursday oracle-lag, reseat-at-edge/BAND_DELTA, buffer-unification §J.2. The 280MB pre-compaction session is substantially captured by §P.1/§P.3. [Slices 1–3 (280MB) still scanning — more may append.]

## T. ETH-CRASH DOWN-SIDE TAIL — hold-down vs delta-1-maintained (full note: `IMPAIRMENT-DERISK-TRIGGER.md`, user 2026-07-24)
**Subject: ETH (base) PRICE crash that doesn't recover — NOT LST/wrapper credit impairment (that's an orthogonal weETH-peg risk, separate footnote).** Refines §J.4/§K: the real YB competitor is NEITHER `_growShort` (deleted, stays deleted) NOR the §K.2 directional product — it's a **capital-structure choice on the LEVERED position below entry.**

**T.1 What's BUILT = "up-lever + hold-down":** up-side levered/IL-free/fees; below entry de-lever to 0 (`ilTargetBps→0` at/below entry, `LevMath:108`) and HOLD the √p over-hold, letting the LVR-free band heal the impermanent IL. Long-biased "buy-the-dip-and-hold" (bets on recovery). Keeps the mandatory solvency de-lever-to-entry.

**T.2 🔴 THE COUNTER-CASE (why "hold-down = safe/clean" is FALSE framing — the load-bearing risk argument):**
1. Hold-down is **short-vol / negative-skew wearing a conservative costume** — "harvest vol (buy dips/sell rips/bank fees)" = SHORT GAMMA; smooth returns until one gap erases years (XIV profile). WORSE than textbook: below entry the band OVER-holds (keeps buying the faller) ⇒ **long the dip with amplifying size into a crash** = negative skew AND wrong-way gamma.
2. "Do nothing" = a **large hidden directional bet** (implicit "I bet this recovers", over-hold doubles down) mislabeled neutral. Delta-1 is the genuinely neutral/hedgeable one; hold-down is convex-wrong-way + path-dependent (HARDER to model, opposite of "clean").
3. 🔴 **The tail is CORRELATED with the peg's worst moment (the stablecoin-specific killer):** systemic crash = everything down + redemptions spike + confidence thin. Hold-down then sits on an over-concentrated depreciating bag AS redemptions pull ⇒ run dynamic → forced sales at worst prices, stresses `D≥S+L` + the peg WHEN MOST FRAGILE. "Safe for the LP" ≠ "safe for the stablecoin"; hold-down is arguably WORSE on the second. For a peg issuer the tail cost isn't dollar-EV, it's **reputational ruin (near-infinite)**.
4. "Cleaner" is cosmetic — you STILL run the solvency de-lever + keeper + venues + reseat; you only dropped the below-entry leg ⇒ ~full complexity, bought a fat tail.
- **Honest landing:** this does NOT resurrect always-on `_growShort` (it bled round-trip premium on every recovering dip — real cost, round-trip theorem holds on the modal path). It establishes narrowly: **"hold-down = safest" is false**; it's negative-skew — fine in the ~95% mean-reverting regimes, ruinous in the ~5% that don't, and the 5% correlates with what a stablecoin can't survive twice.

**T.3 The ONE failure regime (§4):** a SUSTAINED one-directional ETH re-rating with NO recovery — "impermanent" IL becomes PERMANENT + AMPLIFIED (over-hold accumulated more on the way down). **NOT fixable by a stop-loss:** ETH has NO structural regime signal (only price) ⇒ a price-trigger whipsaws (cuts at a flash-crash bottom that recovers = worse than holding) + is late on real ones. So the choice is structural (T.4).

**T.4 ★ THE PRODUCT (§5) — DELTA-1 MAINTAINED THROUGH THE DOWN-SIDE (the real "better than YB", NOT built):** stay delta-1 BOTH ways incl. below entry, rebalance INSIDE our own LVR-free band. Above entry = identical to today. Below entry = instead of de-lever-to-0+hold, **keep the position LEVERED and rebalance to stay delta-1** (trim over-hold as ETH falls, re-add on recovery) — doubled liquidity stays deployed → keeps earning fees like YB.
- **Beats YB:** YB's rebalance is public `exchange` ⇒ arbers extract the LVR (leaks to MEV). Our band is LVR-free (mock/onlyUs, Chainlink-reseated, skew owned) ⇒ same delta-1 rebalance keeps the LVR IN-POOL for our LPs. Same protection + fees, minus YB's structural leak.
- **Beats hold-down:** delta-1 tracks ETH LINEARLY (no over-hold ⇒ no wrong-way gamma, no negative-skew tail); in the crash regime it already trimmed exposure ⇒ BOUNDED loss, not amplified. The explicit-neutral option.
- **COSTS (the insurance side hold-down SELLS):** (1) round-trip LVR premium on every recovering dip (internal/in-pool but the LP still pays it); (2) funding cost (carry debt through a falling market); (3) liquidation risk (keeper must de-lever fast enough vs LTV; a gap can liquidate). Hold-down eliminated all three by de-levering to 0.
- **NOT `_growShort` revived (§6):** growShort de-levered to 0 THEN spot-shorted the unlevered equity into the SHARED band (killed fee income, cross-subsidy breaks R1, directional bet). Delta-1-maintained KEEPS leverage ON + rebalances the LEVERED position through the band — a **capital-structure difference**, not the removed mechanism. The short apparatus stays DELETED.

**T.5 ENGINEERING DELTA (if delta-1 is chosen — the build spec):**
- **Target:** below entry, `ilTargetBps` returns 0 (`LevMath:108`); the product returns a NONZERO delta-1-maintaining target = the `√(entry/now)−1` offset applied to the LEVERED position (not a spot short).
- **Rebalance routing:** the levered de-lever currently uses external SOR (`deleverRepay`→`sorSelfFunded`); for the LVR to stay IN-POOL it must route THROUGH the band (`swapTo`) first, SOR only on overflow (mirrors how `_growShort` band-sold). [ties §K.2 band-routing + §J.4.]
- **Keeper:** manage leverage safely through a crash — de-lever cadence to stay ahead of LTV, liquidation buffer, reuse JIT-lock/dwell damping.
- **Risk knobs:** max-leverage-below-entry cap + a hard de-risk floor bound the liquidation tail.
- **Fork-prove:** delta-1 held both ways, LVR captured in-pool (not leaked), bounded loss on a sustained crash, no liquidation under a bounded gap.

**T.6 🔴 DECISION OWED (product/risk call — which LP, NOT a code task):** **hold-down** (negative-skew, cheap, fat-tailed, long-biased — BUILT) vs **delta-1-maintained** (neutral, priced, tail-free, YB-competitor — NOT built). For a STABLECOIN BACKING ENGINE, T.2.3 (ruinous-correlated-tail) pushes toward delta-1; for a long-biased book, hold-down already ships. Pick which LP you serve. → until decided, hold-down stands (built); delta-1-maintained = 🔴 QUEUED conditional build (T.5). NOTE the footnote credit-hedge (weETH-peg-break → `_weethToWeth` offramp on getRate-drop) is a SEPARATE orthogonal note, not this decision.

### S (cont.) — DEEP RE-SCAN slices 1+3 (2026-07-24) — the keyword-pass MISSED these (whole-turn read)
**🔴 AMM/band composition-audit (adversarial "compose entrypoints in one block" — OPEN, absent from §A):**
- **S11 🟠 `Vogue._withdraw` interactions-before-effects (CEI):** sends native ETH (`_sendETH` .call{value}, ~:473) + delivers (`_burnInRange(...recipient)`) BEFORE `LP.pooled/lpShares -= amount` (~:485). nonReentrant but Aux's lock is SEPARATE → recipient gets control, can call Aux. Bounded (Aux doesn't read the lagging per-LP state) but a real ordering defect (Vogue:393 TODO path). → §A.
- **S12 🟠 withdraw burns at SPOT, deposit is oracle-priced** (`Vogue:449`) — asymmetry leaks ≤50 bps IL pool-wide. Fix: oracle-price the withdraw burn. → §A.
- **S13 🟠 normal repack recenters on SPOT not oracle** (`:1325`, realizes IL at spot `Core:672`) — front-runnable ±50 bps within the 300-bps gate. Fix: oracle-center it (unify w/ reseat's Chainlink move). → §A.
- **S14 ✅ JIT fee-snipe on the 4626 LP path FIXED (`a25d0e4`):** auto-managed 4626 `_withdraw` had NO same-block lock (unlike `pull`'s created+47) → deposit→Aux.swap→withdraw atomic. Fixed via `lastDepositBlock` gate. Record so not re-derived. → §A.
- **S15 🟡 true atomic reach ~100 bps not 50** — strict `>` in `isManipulated` lets the boundary swap through ⇒ two swaps walk ~2× the per-swap cap in one block (the real LVR window). → §A secondary.
- **S16 🟠 `minOut=0` SILENT-LOSS (the "most important finding", un-built):** SPA defaults `minOut`/`minSats`=0 on every swap/redeem (`page.tsx:687`); anvil e2e proved a swap consumed 1000 USDC + delivered 0 (status 1, NO revert because minOut=0). Fix: SPA must not default 0 (warn) AND/OR **the contract should REVERT on 0-delivery** (distinct hardening). → §A + §I.

**🔴 POOLED_USD (user focus) — uncaptured concepts:**
- **S17 ✅ Aux-vs-POOLED mis-attribution FIXED (`bacfb6a`):** skew-premium payout drew from `POOLED` (mock-USD) when the premium lives in **Aux holdings**. Concept: `POOLED_USD` = a REPRESENTATION of a chunk of Aux holdings ⇒ paying the premium = an `AUX.take` ONLY, no mock burn, no POOLED touch. Read-only sweep confirmed it was the SOLE instance of the class. **Directly load-bearing for #12 unify.** → §A + §C#12.
- **S18 concept: POOLED_USD is band SWAP-LIQUIDITY, NOT mint backing.** A seed mint never pairs into a band ⇒ `POOLED_USD` stays 0; seed X lands fully in `deposits[12]`; `D≥S+L` relaxed ONLY in the seed/calibration window (`calibrating` skip), re-enforced by the 1:1 cap once avgYield reveals. Sharpens #12 + `backing-invariant`. → §C#12.

**🔴 WELL/SKEW (committed but uncaptured vs the queue):**
- **S19 #101 REMOVE grinding (REVERSES §J.3/§C#5 "guard load-bearing"):** delete the two 50-bps per-swap truncations; band stays thin, large swaps walk the real curve + partial-fill at true exhaustion. Safety now = 30-min internal TWAP + **5% Chainlink anchor** (`TWAP_MAX_DEVIATION_BPS`, Aux:645) as a cross-check/switch (NOT a hard clamp) + reseat auto-heal. ⚠️ TENSION with §J.3 P.1's "sync guard STAYS" — reconcile: the anchor is the retained sync guard; the 50-bps grinding truncations are what's removed. → §101/§J.3.
- **S20 surgical reseat split:** don't re-band the whole position on imbalance — keep a BALANCED two-sided band at the oracle (serve swaps fair) + place ONLY the excess USD Δ as a concentrated bid just below oracle (exact amount to restore target inventory, at the discount that pays a refiller; fills on the smallest move). → §71/reseat.
- **S21 vBTC-borrow as FIRST-LINE refill (unifies 3 consumers):** reservoir defense order = free `POOLED_BTC` → **borrow vBTC against basket stables** (Morpho 1-market-per-stable / Euler multi-collat; skew premium funds carry; caveat = short-vBTC) → skew/organic refill (unwinds borrow) → WBTC fallback. ONE `getUserSuppliedAssets` read serves 3 consumers: skew-absorption signal + borrow source + #74 base-selection. → §71/#74.
- **S22 dynamic swap fee = σ²×one-sidedness, netted vs skew** (the missing adverse-selection axis; skew prices INVENTORY, this prices FLOW): `fee_σ² = max(0, k·σ² − skewApplied)`, charged ONCE via `max(skew,fee)` never sum; keyed on flow one-sidedness not raw σ² (don't deter volume). → §71/#1.
- **S23 reservation-recenter (#3) DECIDED-AGAINST:** recentering the reseat on the reservation price chases the drain + amplifies the move, conflicts with anchor-recentered reseat. Dropped. → decided-against note.
- **S24 ✅ EIP-170 slimming DONE (#78/#93 UNBLOCKED):** all 5 over-limit contracts under 24576 (Vogue 27266→23645, Vault 25605→22032, SwapLib 25346→20338, LevManager 24927→23422, Aux 24707→24134); main deployable. §DR/#78 list it as open — RESOLVE. (13 money-path bodies relocated; box OOMs full run.)
- **S25 detail: 48h flow-EWMA + σ-derived skew cap** — `FLOW_DECAY` un-tied from `BR_DECAY`, set `0.5^(1/2880)` (48h). `MAX_WELL_SKEW` DERIVED from σ: `√(σ²·T_confs/yr)·2 + 0.2%` clamped 3% (~1% @40% vol → 3% @~150%); per-asset conf window (ETH 1-block, BTC ~1hr). → §71.

**🔴 KEEPER / self-funding (user focus) — extensions:**
- **S26 self-funding across ALL machinery (mandatory, ZERO operator subsidy) — extends #87:** two sources by op type — (A) BENEFICIARY-SKIM (compound skims LP harvest; de-lever/protect skims freed collateral; settleSwapIn/delivery skims the swap fee) + (B) a GAS RESERVE funded by a sliver of every swap fee for infra ops (SPV relay, freshness commits, reconciler) + bootstrap float. Each skim grief-capped. User escalated "safety ops operator-funded" → **all ops self-fund**. → §87/memory.
- **S27 harvest-before-mutate INVARIANT (anti-rot #76):** MasterChef fee correctness hinges on every `LP.pooled`/`lpShares`-touching path harvesting FIRST (verified swap/deposit/withdraw/unwindForRedeem). Add a targeted #76 sweep: "does any share-mutating path skip `_rebalance`/`_settlePending`?" → §76.
- **S28 DwellTracker restart footnote (low pri):** a crash-loop can indefinitely defer LAZY IL rebalances (fee-optimality drift, NOT safety — urgent de-lever fires regardless). → untracked/low.

**🔴 DEPLOY / TRUST — uncaptured:**
- **S29 🔴 HIGH TRUST GAP: `AttestedHopRegistry` is ORPHANED** — never wired into `BTCChannels`; EVERY hop money-path (`settleSwapIn`/`recordClose`/`splice`/`drawPooledUsdBtc`) gated ONLY by "owns ≥1 open channel", NOT attestation ⇒ the DCAP/MRENCLAVE machinery does ZERO on-chain work. Wiring blocked (only attest path = `registerHop(rawQuote)`→real DCAP, no gov bypass, needs SGX HW → would brick all hops/tests). Decision: doc-correct now, gate-wire at the very END (#77). `onchain-hop-attestation` memory describes the registry but NOT the orphaned/unenforced finding. → §DR + fix memory. (NB: task #77 marked "completed" — VERIFY, this says orphaned.)
- **S30 seam bugs (extend `seam-bugs-crossside`):** `registerDelegation` reverted — Rust encoder said `uint256 version` vs contract's `uint64` → wrong selector → fallback (caught only by cross-side regtest). Separately: validating-signer allowlist had **3 stale B selectors** (openChannel/splice/deliver) the regtest DIDN'T catch (plain sender, not the SGX-signing wrapper). → memory.
- **S31 pre-existing RED: `rev_client_ser_basic`** red on main (stale pubkey after an M11 secp256k1/key-deriv change) — NOT in the 3-red list in `reference-spv-preexisting-red-tests`. → add.

**🔴 CROSS-CHAIN TEST GAP:**
- **S32 forge-FFI LN↔EVM e2e harness EXISTS but UN-RUN:** `quid-hop/src/harness.rs` + `bin/e2e_ffi.rs` + `Alles.t.sol::testCrossChain_FullE2E` — `vm.ffi`s a Rust bin driving REAL bitcoind/LDK (fund→open 2-of-2→swap-in→coop-close→SPV proofs, byte-exact) then Solidity drives REAL `SPVGateway→openChannel→registerBtcLp→settleSwapIn→recordClose`. The ONLY test covering the LN↔EVM round-trip. "Cannot run here (no bitcoind); needs a CI runner w/ bitcoind+electrs." → §C#21/§DR.

**🔴 BACKING NUANCE:**
- **S33 crater-tail IMPAIRS the bond/senior claim (nuance to `il-bonds-truth`):** LPs eat loss up to their equity thickness; a crash deep enough to EXHAUST LP equity spills onto the bond ladder (the bond funded the dollar leg the pool SPENT buying the falling asset). True for normal P&L, NOT the crater tail — the senior/bond claim IS exposed once LP first-loss equity is gone. "Verify the exact Core/Vault backing accounting before trusting any number." Ties §T. → §B + reconcile `il-bonds-truth`.

**🟡 STRATEGIC / PROCESS / RECONCILE:**
- **S34 idea: make ETH an inventory VENUE (compete with Uniswap):** today ETH holds NO inventory (sourced on-demand via SOR/Uniswap). Because QU!D oracle-anchors, its ETH LPs bear LESS LVR than Uniswap LPs ⇒ can quote TIGHTER + still profit → attract benign flow. "Prototype the spread math before committing." Strategic expansion, unrecorded. → new backlog.
- **S35 🔴 PROCESS LESSON (bears on RIGHT NOW):** a "comment-only" mass-sweep agent SILENTLY DELETED load-bearing code (`Basket.matureSupply()` — used by `SwapLib:670` swap-out share value + `BasketLib:844` redeem → would runtime-REVERT, masked because called through an interface) + Rover struct fields. **LESSON: run mass-edit/agent sweeps ONLY against a COMMITTED tree** (trivially revertible). ⇒ argues for committing the checkpoint before more agent edits (the current tree is uncommitted).
- **S36 #99 USYC/Teller RWA (shelved, lowest pri) — details:** Teller alongside AUSD, decoupled from Aave auto-alt; Safe-pledge tranche ($1.2M, 3-of-6), untouchable-cut→USDC+USYC-premium, KYC-via-Safe; `stcUSD`/`cUSD`=sUSDe pattern. Not in queue/memory. → §D/backlog.
- **S37 reconcile #104 double-interpretation:** §F marks #104 "RESOLVED (no build, already correct)" but the pre-compaction session actively DESIGNS + begins building Option A (de-lever-into-swap-out, LTV-improving). Surface + reconcile which is current. → §F.
- **S38 `a25d0e4` (the well) committed COMPILE-UNCONFIRMED + not fork-proven:** premium-tracking build orphaned by session restarts; the `--mt` skew proof (deterministic-impact + backing-neutral + forbidden-sandwich) is a #76 follow-up. Residual risk. → §76.
- **Lower-conf/moot:** M11 `btcFeesOwedSats` hop-withholding (likely moot via #69 fee-into-close); YB-lev keeper impl-security (`rebalance(victim,0)` sandwich → oracle-derived `minOut` floor; LevManager LTV off band-TWAP vs venue liquidation-oracle mismatch) — sits inside the excluded YB thread's IMPLEMENTATION-security residue, flag in case the exclusion wasn't meant to cover it. → lev-audit.

### S29 — CORRECTION (2026-07-24, verified against code): NOT orphaned. BAD RECORDING.
The scan's "AttestedHopRegistry is orphaned / isAttested never called" claim is **FALSE** — a doc-staleness artifact, not a code fact. Verified: attestation IS wired.
- `BTCChannels._requireAttested` (:531, calls `isAttested` when `hopRegistry!=0`) + `_authorizedHop` (:672, returns `isAttested(hop)`) gate the hop money-paths: **openChannel** (:690/:691), **settleSwapIn** — the real POOLED_USD_BTC drain path (:1091), **emitDeadManExit** (:871/:872). recordClose is participant-gated + retire-only (no fresh mint) by design; drawPooledUsdBtc lives in Core.onlyUs (not a hop entrypoint — S29 mis-categorized it).
- Task **#77 is legitimately COMPLETE**, not a mis-mark.
- The ONE real residual: enforcement is **governance-armed** — `_requireAttested` is a no-op while `hopRegistry==0`; a deployment that never calls `setHopRegistry` falls back to the `openChannelsOf` (owns-a-channel) gate. Intentional bootstrap (regtest has no real DCAP quote), NOT an orphan. Hard-requiring it = drop the `if(reg!=0)` guard, which bricks every test lacking an attested hop → keep armed-fallback, pin in prod.
- ROOT CAUSE of the bad recording: stale header comments (BTCChannels:62-66, AttestedHopRegistry:29-38) said wiring was "pending/NOT YET LIVE" while the code had moved ahead. **FIXED** both comments 2026-07-24 to read "wired + governance-armed." Lesson reinforced (like S6): a scan reading comments-as-truth mis-reports; verify against call-sites.

### S39 — Morpho curated-vault HEALTH (responsiveness + evacuate-to-Aave): PARTIAL, 2 real gaps (verified 2026-07-24)
Morpho plays TWO roles; health handling differs sharply:
**Role 1 — basket-stable ERC4626 (Gauntlet-curated USDC/USDT, held by Aux; DeployL1_s:373-374) + WETH venues (Galaxy/Euler):**
- (a) RESPONSIVENESS = BUILT-BUT-UNCALLED. `Aux.pokeVaultHealth` (Aux:447 → BasketLib.pokeVaultHealthBody:1064) is permissionless + on-chain, reads ERC4626 ground truth (`convertToAssets(balanceOf)` vs `maxWithdraw`), blocks+evac when liq<50% (LIQ_TOL_BPS=5000). DETECTS illiquidity (utilization spike) + realized bad debt (convertToAssets auto-drops). Does NOT detect curator pause / oracle failure / UNREALIZED bad debt (undetectable from on-chain scalars — VAULT-WATCHER.md:52-63, by design).
  🟠 **GAP-1: nothing CALLS it.** No Rust keeper loop invokes pokeVaultHealth (quid-bridge has only settle/relay/swap-out pollers); the Go cron was RETIRED ([[project-quid-cre-flow-sensor]]) in favor of "permissionless on-chain" — but then NO scheduled caller remains. Detection exists, responsiveness doesn't. Then 30-min EVAC_DWELL (BasketLib:1023) before evac fires. FIX: wire pokeVaultHealth into the fleet keeper (cheap read, permissionless) OR a CRE cron; the user's "responsiveness" concern lands HERE.
- (b) EVACUATE-TO-AAVE = BUILT (WETH) / PARTIAL (stables). WETH venues → `evacuateVenue` pulls maxWithdraw WETH to the **AAVE haven** (BasketLib:1119). Stable Morpho vaults → redeem + `spreadEquallyBody` across other unblocked vaults of the SAME stable (Aave among siblings, not specifically targeted; BasketLib:1128). Frozen redeem → try/catch, stays blocked, loss socialized.
**Role 2 — leverage collateral market (MorphoEscrowVenue, weETH collateral / stable debt, per-LP isolated):**
- (a) RESPONSIVENESS = OPEN-GATE ONLY. `LevMath.requireOpenable` (:275) blocks NEW opens on a de-allowlisted / `setVaultHealth`-flagged venue; close/rebalance stay open. No live venue-impairment monitor beyond the keeper's LTV-based liquidation-avoidance de-lever (lev_keeper.rs, tracks LTV not venue health).
- (b) EVACUATE-TO-AAVE = 🟠 **GAP-2: NOT BUILT.** No path migrates an OPEN levered weETH-on-Morpho position to Aave on impairment; isolation is by-construction, remediation is only de-lever/repay. If Gauntlet/Morpho weETH market impairs, a levered LP can't be moved out — only unwound.
**VERDICT for the user's Q:** basket/WETH side has BOTH responsiveness + evac (to Aave for WETH), but (GAP-1) the poke is never scheduled, and (GAP-2) the levered weETH-on-Morpho venue has neither live health-monitoring nor evacuation. Both are real, both actionable; neither was previously tracked. → new queue items.

### S40 — DEEP RE-SCAN of 3rd titled sibling (0f5876e3, 2026-07-25): latent bugs in COMMITTED #54 code (HIGHEST) + un-tracked tails
The exhaustive whole-turn scan of the un-scanned titled sibling. Most items were already tracked (agents flagged those); these are the genuinely-untracked ones. **The #54/#104 delever-on-delivery AUDIT findings are latent in LIVE committed code — highest priority:**
- **🔴 H1 — `freedSats < want` shortfall drift** (EVM/POOLED): `delevUsd` is computed from intended `want` BEFORE the actual freed sats; venue cap/withdraw-slip (BtcLevManager:571,574) can shrink `freedSats` below `want` → delivery burns fewer sats while `settleDelivered` still mints `exactUsd − delevUsd` → POOLED_BTC vs QUI drift until async `syncLevBTC` reconciles. UNTESTED branch. Fix: derive delevUsd from ACTUAL freedSats, or clamp/reconcile at delivery.
- **🔴 H2 — `takeUsd18==0` silent under-delivery** (EVM/POOLED): if the basket lacks the venue's debt stable (e.g. BOLD), `deleverOnDelivery` short-circuits (SwapLib:1129-1130) → `delevUsd=0` → delivery truncates to `funded`, silently under-delivering an obligation already recorded at request. Fail-soft but latent.
- **🟠 C1 — cross-tx splice double-pay: no on-chain guard** (EVM/POOLED/security): LP internalize-de-levered in tx A (debt→0), then its channel spliced/credited in tx B runs full `exactUsd` mint with `delevUsd=0` → paid twice. Only per-`swapId` anti-replay exists (BTCChannels:1168), no per-LP-value flag. Assistant later argued #54 closes the SAME-TX case by construction — but the CROSS-TX guard genuinely does not exist. Ties #104 §F double-pay open question. STATUS: unresolved.
- **🟠 M1 — multi-LP fairness ("most-over-collat-first") unimplemented** (EVM): only single-channel delever + a pure-view sum (BtcLevManager.totalDeliverableDollars:270-274); no sort/selection to tap multiple levered LPs fairly.
- **🟡 M3 — asymmetric underflow policy** (POOLED): `subPendingSwapOut` floors silently at 0 (Core:492) while `drawPooledUsdBtc` reverts (Core:481) → a real accounting-mismatch hole the moment a v3/bypass-pool path splits the two draws.
- **🟡 M4** — `deLeverUsd6` ceil over-draws POOLED_USD_BTC by ≤1e-6 (SwapLib:1135); conservative, note-only.
- **🔴 T1 — #54 test coverage is ONE happy path** (test): untested = multi-LP delever, cross-tx double-pay (C1), freedSats<want (H1), takeUsd18==0 (H2), fairness ordering (M1), #105 partial-fill × de-lever interaction, and a second delivery before async reconcile. → add these as regression tests.
- **🟡 C2 — EIP-170 Core headroom** (gas): a snapshot measured Core=24425 (only 151 B free); any NEW Core entrypoint won't fit — a hard constraint biasing v3-vs-v4 design. (Pre-dates the §S24 slimming; RE-MEASURE against current before trusting.)

**Un-tracked non-#54 items:**
- **✅ legacy_sweep orphaned — RESOLVED (deleted, commit `4f3c952`):** `wallet/legacy_sweep.rs` (the orphaned lexe-legacy sweep, never spawned) was DELETED — it no longer exists at HEAD. Nothing to wire. (Distinct from run_btc_lev_keeper, which is spawned.)
- **🔴 TWO security-fix ORPHAN commits — need HARD confirm they're LIVE in main (not a memory claim):** `7cb99dc` (H-1 cross-hop fee griefing) and `b0b20b3` (MED-3/LOW-4 cap inbound LP channels). If they're dangling/superseded but their fix didn't actually land, that's a live vuln. → git-verify the fix code is present in HEAD.
- **🟡 COMPOUND_GAS sync invariant** (Rust/gas, #103-adjacent): Rust `lev_keeper.rs:266 COMPOUND_GAS=140k` MUST stay in sync with `Vogue.sol:1242`'s 140k (keeper break-even gate `pending/2 ≥ gasprice·COMPOUND_GAS`; mis-set → keeper runs at a loss → stops → liveness risk). NOT the Rover 600k (that's a different constant). Add a comment cross-link on both sides.
- Already-in-doc (agents cross-checked): payRefillBonus cost+gas-cap (B/C#11/E#140), #101 guard (§S19/§C), #102 cUSD follow-ups, #107 θ (do-not-record per user), JIT §2, #75 hand-rolled nonReentrant (C#15), #89 out_of_band dup (E#166), #95 recordSkewPremium (D#91), outOfRangeBtc vBTC mirror (D#92), #104 internalize-A (F#181). Task-status #100-112 tracked by number.
- **Memory FIX:** `project-quid-btclev-keeper-audit-handoff` "keeper NOT spawned" is STALE — resolved by 60a0290 (run_btc_lev_keeper spawned daemon.rs:451). [updating]

### S40 — RECONCILED against HEAD 45531fa (2026-07-25): most "latent #54 bugs" were ALREADY FIXED. Scan was NOT reverse-chron.
⚠️ **META-CAVEAT:** S40 (and S11–S39) were folded from HISTORICAL transcripts, NOT scanned newest→oldest — so findings that NEWER code/discoveries already rendered irrelevant were recorded as if live. Every S-item must be RE-VERIFIED against HEAD before action. Confirmed-stale so far: S40 H2/M4/M3 (below), S29 (attestation IS wired), S6 (bad recording). **A full reverse-chron reconciliation of §S is owed.**
Re-verified S40 #54 items against current code:
- **H2 — RESOLVED.** `SwapLib._sourceRepayFree:1147-1157` (tagged `#13/H2`): `amtNative>0 & no venue stable held` → `revert DeleverStableUnavailable` (fail-safe, hop/keeper retries after top-up); `amtNative==0` → zero-repay free, deLeverUsd6=0, full mint (correct). NOT silent under-delivery. DROP as a hazard.
- **M4 — handled.** `SwapLib:1159` rounds UP + `:1160` clamps to exactUsd6 (never over-mint). Note-only, not a live over-draw. DROP.
- **M3 — not a hole.** `Core.drawPooledUsdBtc:484-490` is FAIL-LOUD BY DESIGN (documented; `exactUsd ≤ pendingSwapOut ≤ POOLED` ⇒ draw & mint agree by construction). `subPendingSwapOut` floor-at-0 only diverges IF a future v3/bypass path splits the two draws → LATENT, not live. DROP from "live hazard"; keep as a v3-precondition note.
- **C1 — = tracked #104 (F#181), not new.** `deleverOnDelivery:1122-1123` guards `lev==0 → return 0`; a re-run on an already-de-levered LP no-ops. The cross-tx splice double-pay is the known #104 design fork (bypass-pool v3 vs top-up v4), owned by the user. NOT a blind-fixable bug.
- **H1 — folds into #105 partial-fill, likely safe.** `swapOutDelever:531-536` reconciles `freedSats` to the venue's ACTUAL `got`; if the venue withdraws less, fewer sats un-encumber → delivery is PARTIAL (#105 handles the refund). `deLeverUsd6` derives from actual debt repaid (`takeUsd18`, clamped to held + live-debt), drawn + withheld consistently; async `syncLevBTC` reconciles the debt-buffer; mismatch errs toward over-repay (LTV improves). Not a live drift. → worth a T1 regression test, NOT a code change.
- **T1 — still valid** (thin coverage: multi-LP, freedSats<want, second-delivery-before-reconcile). **M1 — feature gap** (multi-LP fairness unbuilt), not a bug. Both real, neither a "fix the committed code" item.
**NET: the #54 delever code is substantially hardened vs the old-thread scan — NO live latent bug to fix. Genuine open work = T1 tests + M1 fairness + the #104 double-pay design fork (user's call).**

### S41 — TAIL-SCAN of 1f505948 (280M sibling, lines 60000-75866, newest-first) — 2026-07-25
This thread ORIGINATED LST-PEG-MONITOR.md. Reverse-chron: mid-thread bug-flags were fixed LATER in the same thread → HEAD-verified stale (validates the reverse-chron method):
- ✅ **btcVault deploy bug** (DeployLib passed Vogue not Vault as BTCChannels.btcVault → all BTC swap-out reverted, registerBtcLp no-op) — FIXED + regression-guarded at HEAD (DeployLib:160 passes `eth`, :184 `require(btcVault==eth)`). The old "fork flake" memory attribution was WRONG (real deploy bug). [memory to correct if any]
- ✅ **#105 ×3 beyond-minOut partial-fill leak** (swapToBody/creditSwapOut/creditSwapIn) — FIXED at HEAD (SwapLib `consumed`:484 + `_refundExcess`:497-508 + `inToken`:380). Matches task #105 complete.
- ✅ **#95 sell-anchor** committed (b204da0/787b59a); ✅ **#93** Vogue/Vault were never over-limit at HEAD (stale blocker) — the real risk was LevManager margin-2, fixed by moving shortTargetBps to a LevMath delegatecall helper.

**GENUINELY-LIVE (at HEAD) from this thread:**
- 🔴 **LST-PEG-MONITOR.md FINAL VERDICT (supersedes S39 GAP-2):** do NOT build a reactive weETH-evac engine — it's over-engineering. QU!D values weETH at INTRINSIC (`getEETHByWeETH×ETH/USD`, LevManager:290-291), so a Mode-1 MARKET discount (the common, self-healing kind — stETH-June-2022) is INVISIBLE to the backing books; only a Mode-2 INTRINSIC loss (slash/exploit → getRate drops) matters, and that's ALREADY auto-reflected in D≥S+L. A reactive getRate trigger is also weak (discrete slash = loss already taken; fast exploit outruns the rate fn). Design = rely on existing per-LP isolation + venue liquidation, add TRANSPARENCY (extend dashboard stress-test #25), at most gate NEW deposits into a freshly-impaired wrapper. → S39's "levered weETH has no evacuation (GAP-2)" is REFRAMED: evacuation isn't the design; isolation is.
- 🔴 **THE DECIDING OPEN QUESTION (unresolved, high-value):** is the PLAIN (unlevered) ether.fi/weETH venue truly per-LP ISOLATED, or does an intrinsic loss there SOCIALIZE across all ETH LPs via the shared vogueETH share price (Core:597)? The LEVERAGE side is definitively per-LP isolated (LevManager:68-77,201 "never socialized"); the plain side was only INFERRED. This single fact decides whether LST-PEG-MONITOR.md becomes "do essentially nothing on-chain + dashboard signal" or keeps a real ex-ante control. NB: our new venue work attributes the ether.fi slice per-LP via `ethfiBacked` (hard-wall "exit from YOUR venue only"), BUT vogueETH is a POOLED sum (VaultLib _venue4626Value) → share price is shared → a value loss MAY socialize despite the attribution. NEEDS a trace of vogueETH share-pricing vs ethfiBacked. → verify before finalizing the LST doc.
- 🟠 **ETH-cap over-priced** (`_maxWellSkew` applies the BTC ~1hr confirmation window to ETH; needs per-asset conf-fraction, thread isBTC through skewWad). HEAD-status UNVERIFIED (may be fixed later like the others — check).
- 🟠 **Adaptive flow-decay gap:** `FLOW_DECAY` (Core:156, 48h) is ONE constant for BOTH ETH & BTC despite very different refill latencies (ETH mins on-chain; BTC slow cross-chain). Staged fix: per-side decay first (2 constants), then optionally adaptive to `realizedVarianceWad` (TWAP-based, manip-safe) with a min-half-life floor; NEVER adaptive to instantaneous flow. ETH-side should track Rover's refill cadence (Rover has no inventory-cost reaction today).
- 🟠 **#102 cUSD deposit-gate-on-feed RULE (established):** a market-floating stable is deposit-eligible IFF `stableFeed[token] != address(0)` (or structural-floor allowlist = BOLD) — else `getDepegSeverityBps` returns 0 → valued at par → over-mint/dilution exploit. Correction: RLUSD/USDG/AUSD DO have real Chainlink feeds ("proxy" = ENS resolution); only BOLD is truly feed-less (safe via Liquity redemption floor). cUSD/stcUSD maps 1:1 onto sUSDe/USDE (setVault + setStableFeed 0x8fFf…). Unverified forks: cUSD permissionless-vs-KYC; does 0x8fFf… return cUSD/USD (not the stcUSD share-rate)?
- 🟡 **ROT PHASE (deliberately last):** ~15 hollow-test masks; WORST = **EconAttackProbe 4/6 tests log-only → cannot fail** (#76). Plus base-LP no-free-lunch invariant, leverage reflexivity bounds, 5 swap-pricing pins, #50 band-gate-haircut pin.
- **Consistent (no conflict):** #69 fully closed (retired lp_fees.rs — confirms the 7cb99dc orphan verdict); run_btc_lev_keeper WBTC-mode spawned (#90) but NATIVE btc_tick still blocked on BtcLevAcquirer (#59/#74) → BTC-lev-native stays prod-disabled; single-sided-LP "generosity vote" design (reuse Basket._median, weight by LP share NOT immature-QUI to avoid self-deal); re-merge/offset-tick NOT built + recommend-drop (rebalances in-place at oracle).
- 🛠 **Infra lesson:** a ZOMBIE `solc`/`forge` from a killed build silently eats ~2.6GB → OOMs the 3.5GB box. Rule: pgrep/kill zombie solc/forge before every build; one build at a time; `--skip '*.t.sol'` for deploys.

## V. REVERSE-CHRON TRANSCRIPT SWEEP (2026-07-25) — thread 4fbacebd (ether.fi lineage, 94MB/35k lines)
Deep whole-turn re-read of THIS thread's entire transcript: 18 slices × semantic extraction = **906 raw notices** → 292 still-open (the rest resolved/overruled in-thread) → reconciled NEWEST-first against this doc + current `main` HEAD → **49 survivors / 243 dropped** (BUILT/TRACKED/RESOLVED-LATER/CROSS-THREAD/M11-by-design/NON-ACTIONABLE). Raw per-slice findings + survivor evidence in scratchpad (ephemeral) — re-derive from JSONL if needed. `[conf]` = confirmed-open vs unverified(needs a look). `⇄`=cross-thread (route to the lev/Rust thread), `👤`=user action.

### V.1 Security / money-path
- 🔴 ⇄ **SOR SELF_FUNDED source leg uses raw `transfer`/`transferFrom`** (`SOR.sol:126`, `Aux.sorSelfFunded`) not SafeERC20 → USDT/USDT0-sourced self-funded swap reverts (liveness DoS, no fund loss). [confirmed] S17-38/S17-24. (USDT0-feed-alias half is MOOT — USDT0 removed from DeployL1_s.)
- 🔴 **Bootstrap-year (`currentMonth()<12`) non-seed mints skip the 1:1 headroom claw-back** and project full 12-mo forward yield → a sustained avgYield-inflation (donation/share-price) attack on a thin basket in that window is unmitigated. §S18 documents the mechanism as by-design but NOT this attack surface. [unverified] S17-22.
- 🔴 **No deploy-time bound/scale checks on Morpho market wiring** — `MorphoEscrowVenue.sol:59-66` takes ORACLE/IRM/LLTV raw from ctor, no oracle-scale assertion, no LLTV bound to preserve the ~60-min async-BTC-unwind buffer. [confirmed] S17-16/17.
- 🟠 **Hop esplora reads are single-source-trusted** (`header_source.rs` → one `esplora.client()`) while EVM RPC has a full `QuorumJsonRpc` majority transport — add multi-esplora quorum (Blockstream/mempool/self-electrs). [confirmed] S05-44.
- 🟠 ⇄ **`assertFullyWired` never checks `LEV_MANAGER`/`LEV_MANAGER_BTC`**; `Vault.setLevManager*` stay `onlyOwner` post-finalize (no renounce, no rationale, unlike the explicit BTCChannels-kept-owned comment) on a `DEPLOY_LEV=0` deploy. [confirmed] S17-14.
- 🟠 **Document explicitly that the BTC/ETH lev keeper signs with the LP's OWN key** — on-chain LTV clamps bound leverage but NOT theft via borrow/withdraw to a keeper-controlled addr (distinct from the SGX scoped-session-key model; memory notes "BTC needs self-host/watchtower"). [unverified] S17-6.
- 🟡 **Sanctions-list ERC20 transfer hook** (if ever added to Basket) = hard external-oracle dep on the hot transfer path; needs a pause/bypass before building. [unverified] S13-40.
- 🟡 ⇄ **Decrypted seed JSON request-body buffer not zeroized** after use (enclave provisioning). [unverified] S13-23.
- 🟡 👤 **Confirm the two GitHub PATs pasted in earlier sessions were revoked** (recurring reminder, never confirmed; only you can check GitHub). S15-2/S14-7.
- 🟡 ⇄ **Bridge relayer has only one hot key** — no 2nd funded relayer / tiered-fee-ceiling defer for hot-key blast-radius (memory `Bridge DoS/queues` flags this as the residual). [confirmed] S06-18/S03-4.
- 🟡 **LN reputation/endorsement absent in forked LDK** — no app-level jamming mitigation beyond the 483-HTLC-cap note. [unverified] S02-24.

### V.2 Risk-reduction / correctness
- 🔴 **Urgent-BTC-delever basis mismatch** — `lev_keeper.rs:161-175` `decide()` triggers on venue-safety LTV but sizes the target to the IL-basis `target_ltv_bps`; a crash can size the safety leg wrong exactly when it must fire. [confirmed] S17-7.
- 🟠 **Wire `MorphoEscrowVenue.accrueAndDebtOf` into backing/keeper reads** — accessor exists (`:98`) with ZERO call sites; reads use pre-accrual `debtOf`, biasing net-equity/backing UP between pokes. [confirmed] S17-12/S17-3/S15-28.
- 🟠 **Exclude Rover's protocol-owned weETH/WETH v3 MtM (`valueWeth()`) from the `venueFeesPerShareInc` bookmark** — `VaultLib._vogueETH` folds it into one total; `rebalanceBody` distributes the delta over plainDepth, crediting Rover P&L as "yield" to ALL plain ETH LPs incl. non-opted. [confirmed] S00-13.
- 🟡 **AAVE-v4 `supply()` calls are bare** (a revert bricks deposit/rebalance) while the parallel AAVE `withdraw` is try/catch-wrapped — asymmetry worth re-review now Euler/Gauntlet add surface; "intentional" verdict never recorded. [unverified] S07-5.
- 🟡 **Re-verify `POOLED_USD_*_LEV ≤ Σdebt` re-established on external liquidation on BOTH sides** (ETH lazy-synced `Vogue.sol:649`; BTC plain-withdraw + Core-cap NOT confirmed) + `_reconcileLev` no-op-skip gas/grief gap. [unverified] S17-26/27/28.
- 🟡 **MED-4**: freeze `levPooledBTC` accrual during pending BTC channel-close vs accept bounded keeper-sync window; confirm async BTC close can re-sync the levered band slice (unlike ETH same-tx closeLev+syncLev). [unverified] S15-32/31.
- 🟡 **Capacity-poisoning defense part (c)**: penalize/retire chronically-offline channels — only liveness-filter (a)/(b) exist in `swap_out_onchain.rs`. [confirmed] S13-28.
- 🟡 **Gas-griefing of the hop hot wallet via a flood of min-size swaps** — never investigated. [unverified] S06-12.
- 🟡 **Settler/delivery auto-acquire BTC against owed proceeds on total delivery failure** instead of just reversing (old settler retired). [unverified] S07-18.
- 🟡 **Top-N pro-rata cap on redeem vault traversal** if the basket grows beyond ~15 stables (`BasketLib` loops the full set, gas/DoS). [unverified] S07-13.
- 🟡 ⇄ **Fresh BTC channels have zero hop outbound liquidity** → swap-outs fail until a swap-in seeds; splice can't fix this cold-start. [unverified] S05-42.
- 🟢 **Tier/raise `MIN_CONFIRMATIONS` for large channels** (flat 6-conf regardless of size; the documentation half is DONE). [unverified] S06-7.
- 🟢 **Nested-loop test fn with many locals at stack-too-deep risk** (compiles today; distinct from the fixed LevMath src issue). [unverified] S04-12.

### V.3 Design decisions to make
- **Seed 600k CAP: one-time lifetime budget (as shipped) vs revolving/outstanding cap** that reopens as tranches mature/drain — the exact open Q in memory `levbasket-security-audit`. S17-32.
- ~~**ETH LP share is NOT vintage-exact** (mints 1:1 nominal, redeems pro-rata NAV → cross-vintage subsidy); fix = NAV minting.~~ **⚠️ RE-SCOPED (code-verified 2026-07-25). The SUBSIDY fear is a NON-ISSUE: deposit AND withdraw are BOTH nominal (`pooled±=deltaETH`/`lpShares±=amount`, `Vogue:733/547`; `_deposit4626` returns pooled-delta not convertToShares, `:1214`) and yield is VINTAGE-EXACT via the fee/venue ACCUMULATORS (`_settlePending` runs first on withdraw `:474`; a fresh LP's feesPerShare/venueFeesPerShare bookmarks are set current at deposit → owed 0 of prior yield). No cross-vintage value leak; a NAV-minting "fix" would DOUBLE-COUNT vs the accumulator. NOT §A#9 (that's the QU!D token). **REAL residual (narrower):** the ERC-4626 VIEWS `convertToShares/Assets`→`previewDeposit`/`maxWithdraw`/`previewRedeem`/`totalAssets` (`:1153-1189`) are NAV-based (`vogueETH/lpShares`) and MISREPORT vs the nominal+accumulator execution when yield is unsettled (NAV>1): maxWithdraw over-states, previewDeposit under-states. Fix = make the 4626 views nominal-consistent OR document them approximate. Compliance/integrator bug, NOT a value bug. S17-31.
- **Live venue-APY feed to drive venue rotation** (today it's a manual per-LP hard-wall pick; §L only verifies yield-wiring correctness). S07-30.
- ~~**Claim-without-close fee harvest** for both ETH and BTC LPs (no such entrypoint exists).~~ **✅ STALE/DONE (verified 2026-07-25): both entrypoints EXIST — `Vogue.collectFees()` (`:1284`, ETH) + `Vault.collectBtcLpFees` (`:863`, "Harvest … WITHOUT closing the channel"). Drop.** S02-26.

### V.4 Dedup / simplification / dead-code / perf
- **tranche[] seed marker desyncs from actual seed-vintage QUI on transfer** (marker follows whatever batch is sent) — tighten now the CAP clamp shipped. S17-23.
- ~~**Merge `Vogue._settlePending` + `Vault._settleBtcLp`** into one isBTC-branched helper.~~ **⚠️ SUPERSEDED (verified 2026-07-25): sibling-session extreme-care verdict (ad2385ae L9732) = DO NOT FOLD — different TOK-leg + caller-vs-internal bookmark-refresh semantics; `_settleBtcLp` was DELIBERATELY regrouped into BtcVault (`Vogue:399`), not a stalled merge. Keep separate. (Memory `btc-multichannel-bug` corrected.)** S03-8/S02-57.
- **`BTCHopRequest` event (`Aux.sol:869/876`) has zero consumers** — wire a consumer or drop. (netDeliveredBtc-trigger half is stale — mechanism GONE.) S07-20.
- ⇄ **Relocate `DeployL1_s.sol` from `evm/src/` → `scripts/`** (deprecated `DeployL1.s.sol` already removed; live one never moved). S14-6/S13-37.
- **Fold `BitcoinTx.sol`/`OracleLib.sol` into `ChannelLib`** (file-count/deploy-count win only, optional). S14-1.
- **`BasketLib.spreadEquallyBody` two-pass** (count then distribute) over the vault array on deposit-spread; low-value. S07-9.
- ⇄ **Marketing-clone SPA FAQ "Read article" links are dead/stub** (no detail route); the family-plan FAQ copied the broken pattern. S14-25.
- **Exit-liquidity guardrail** to cap the dashboard/regime-brain "move to QD" suggestion — never built. S07-32.

### V.5 Test-coverage gaps
- **WETH-collateral liquidation-isolation capstone test** (only weETH/Aave v3/v4 have one; `LevYbWeth.t.sol` = open/close only). S17-30.
- **`lev_keeper_btc.rs` native fail-safe path tests** — urgent no-op branch (`:190-206`), `LEG_TIMEOUT` 45s, multi-LP partial-failure (only 4 tests today). S17-10.
- **Taproot reconnect-retransmit nonce-replay reachability test** (fix applied `channel.rs:16456`, no test drives the actual replay path). S13-36.
- **Taproot on-chain-resolution test with N (not 1) HTLCs incl. a dust HTLC** (M9e-3 only single-HTLC-tested). S10-14.
- **Taproot channel shutdown with a swap HTLC still pending** — interaction untested. S10-15.
- **Reload-during-interactive-splice test** (crash mid interactive-tx, Q' not locked) for clean-abort/durability. S10-16.
- **Reconciler-recovery e2e** (crash/restart mid-reconcile). S06-29.
- **Balance-instrumented LN test** proving the commitment-balance sign the rebalancer depends on. S05-43.
- ⇄ **`cargo-fuzz` quid-hop `lp_auth` target is a detached scaffold** — never run, not in CI (nightly unavailable). S05-31.
- **Systematic sweep-and-confirm of panicking `unwrap()`** in the Rust money path (only ad-hoc fixes so far). S05-37.
- **Direct stable-deposit balance-delta check** vs a future USDT fee-switch flip (trusts nominal amount). S06-58.
- **Dev-tooling blind spots**: headStart stubber skips ctor/fallback/modifiers/auto-getters; regex fn-finder misses ctor/dispatcher stack-too-deep; unused-param script misses pass-through dead params. S04-1/S03-28/S03-19.
- **Em-dash-in-string Solidity compile error** recurs — no lint/pre-commit prevention. S03-30.

### V.6 SPOT-VERIFICATION of the 🔴 confirmed-open items (2026-07-25, code-read at HEAD)
- ✅ **CONFIRMED — SOR raw transfer** (S17-38/S17-24): `SOR.sol:126` `IERC20(u.sourceAsset).transfer(...)` in the SELF_FUNDED branch, and `Aux.sol:779/796` `sorSelfFunded`/`Reverse` use raw `transferFrom` — while the SAME file's OUTPUT legs use `safeTransfer` (`SOR.sol:156/160`). Real asymmetry; USDT/USDT0 (non-standard bool) reverts. Fix = SafeERC20/forceApprove on the source leg. ⇄ other thread's files.
- ✅ **CONFIRMED — Morpho market wiring unbounded** (S17-16/17): `MorphoEscrowVenue.sol:59-64` ctor assigns `ORACLE=m.oracle; IRM=m.irm; LLTV=m.lltv` straight from the struct — zero `require`/bound/oracle-scale assertion. Real, but it's a **deploy-config correctness guard (MED)**, not a runtime exploit (deployer-set). Worth a deploy-time oracle-scale + LLTV-bound assert.
- ⚠️ **DOWNGRADED — bootstrap-year "skips the 1:1 clawback"** (S17-22): misframed. `Basket.sol:331-342` shows there is **NO mint-side 1:1 cap at all** post-month-12 either — it was deliberately removed ("that IS the bond"); the safety is entirely REDEEM-side (immature vintages term-locked; mature redeem = `min($1, solvent/matureSupply)` solvency haircut absorbs the over-mint). The ONLY bootstrap-specific behavior is `maxFwd=12` (full-year projection with no buffer data, `:281-282`). The residual worth keeping = "can a thin-4626 avgYield spike inflate the forward projection in the <12mo window?" — which **substantially overlaps the already-tracked §A#4 sUSDe balanceOf-tenor-smoothing** item. Not a standalone 🔴; fold into §A#4's scope.
- ⚠️ **DOWNGRADED — urgent-delever basis mismatch** (S17-7): the keeper's `decide()` (`lev_keeper.rs:161-193`) is **documented intentional** — it TRIGGERS urgent on venue-safety proximity (`current_ltv ≥ venue_liq − safety_margin`) but de-levers TO the healthy IL-target `target_ltv_bps`, which is below venue-liq by construction (comments `:99/:103/:335`). In the urgent case `current > target` ⇒ `debtDeltaToTarget` repay is positive — **no silent no-op**. Genuine residual is narrower: (a) the ON-CHAIN LevMath urgent sizing basis wasn't traced here, and (b) an edge where a miscalibrated `target_ltv ≥ urgent_threshold` would under-clear (loop, not no-op) — worth a one-line clamp/assert, not a HIGH. Reframe accordingly.

### V.7 RECONCILIATION vs SCAN-RECONCILE-2026-07-25.md (sibling sweep, session ad2385ae)
That file is the reverse-chron sweep of the OTHER same-day session (ad2385ae, "Audit Rust code", 78MB) and is
STILL STAGING — its §2D migration ("append as §S41") was never executed, so its §2A net-new + §2B
stale-corrections are NOT yet in this canonical doc. The two sweeps cover DIFFERENT sessions (4fbacebd vs
ad2385ae, sibling forks sharing tree+memory), so §V is mostly additive — but ~12 items OVERLAP and must be
single-tracked, not double-worked:

**OVERLAPS (my §V item ↔ SCAN-RECONCILE ref — treat as ONE):**
- V.2 accrueAndDebtOf-wired-to-nothing  ↔  SCAN §B MED-9 (L19835) + §2C (memory `btclev-keeper-audit`). SAME.
- V.2 POOLED_USD_*_LEV≤Σdebt re-verify  ↔  SCAN §B "live net-equity vs stale levPooled desync" (L19859).
- V.2 MED-4 freeze levPooledBTC  ↔  SCAN §B "closeLev try/catch(syncLev) stale-fee MED-4" (L19881).
- V.2 urgent-delever basis (already DOWNGRADED §V.6)  ↔  SCAN §B MED-6 venue_liq_ltv pin (L19835) + entryPriceWad (L19889).
- V.4 spreadEquallyBody two-pass  ↔  SCAN §E / §2A (L19231). EXACT DUP.
- V.5 WETH liq-isolation test  ↔  SCAN §H "fork tests never hit venue-oracle liquidation/isolation" (L19669).
- V.5 lev_keeper_btc fail-safe tests  ↔  SCAN §H BtcLevKeeper anvil harness (L27833).
- V.5 reconciler-recovery e2e + reload-mid-splice  ↔  SCAN §H LN e2e crash-recovery cluster (L207-221).
- V.1 hop esplora quorum  ↔  SCAN §G/§2A esplora `url_is_whitelisted` never called (L2377) — related (distinct but same file/area).
- V.1 decrypted-seed-buffer zeroize  ↔  SCAN §A platform.rs seed/sealing not zeroized (L20620/L15077).
- V.1 assertFullyWired misses lev managers  ↔  SCAN §B "kill GOV venue-setter / immutable-pin adapters, Root B" (L20426).
- V.1 bridge single relayer hot-key  ↔  SCAN §2C (already tracked, memory `Bridge DoS/queues`).

**GENUINELY UNIQUE to the 4fbacebd sweep (not in SCAN-RECONCILE):** SOR safeTransfer (§V.6-confirmed),
Rover-MtM-in-yield-bookmark, AAVE-v4 bare-supply asymmetry, bootstrap-year/§A#4 avgYield-source (§V.6),
seed-CAP one-time-vs-revolving, ETH-LP-share-not-vintage-exact, venue-APY rotation feed, claim-without-close,
tranche-marker-desync, merge _settlePending/_settleBtcLp, dead BTCHopRequest event, DeployL1_s relocate,
SPA FAQ dead links, exit-liquidity guardrail, capacity-poisoning(c) retire-offline-channels, hop min-swap
gas-grief, settler auto-acquire-on-fail, top-N redeem-traversal cap, fresh-channel cold-start, tiered
MIN_CONFIRMATIONS, nested-loop test stack risk, GitHub-PAT revoke, LN reputation/endorsement, sanctions-hook,
USDT fee-switch balance-delta, dev-tooling blind spots, em-dash lint, Rust unwrap() sweep, balance-instrumented
rebalancer LN test, + the finer taproot tests (reconnect-nonce-replay, N/dust-HTLC, shutdown-with-pending-HTLC).

**ACTION PENDING USER:** SCAN-RECONCILE's own §2A/§2B never migrated (its §2D). Recommend ONE consolidation
pass folding both sweeps' net-new into a single canonical section and collapsing the 12 overlaps above — so
BUILD-QUEUE has one deduped backlog, not §V + a pending §S41.

### V.8 CONSOLIDATION — SCAN-RECONCILE §2A net-new folded in (session ad2385ae; verified)
These are SCAN-RECONCILE's verified-net-new items that are NOT already in §V.1–V.6 (the 12 overlaps are single-tracked above, not repeated). §V is now the single canonical home for BOTH same-day sweeps.
- 🟠 **esplora `url_is_whitelisted` exists but is NEVER called** — fee-rate clamp is applied, the endpoint whitelist is not enforced (L2377). [Rust sec] (companion to §V.1 hop-esplora-quorum: whitelist-then-quorum together).
- 🟠 **Reversal task fan-out has NO concurrency cap** — swap-out pays are capped ≤30, reversal retries are unbounded (L15051). [Rust]
- 🟡 **`inflight_swapins` fsync write-amplification** — fsync-per-swap-in of an ever-growing Persisted blob (L15051). [Rust perf]
- 🟡 **On-chain watcher `handled`/`paid` dedup maps never pruned** — unbounded growth if a sibling swap stays stuck (L15051). [Rust leak]
- 🟢 **`funding_vout` u16 / `tip` u32 silent narrowing** + merkle_branch assert-on-esplora-data (fail-safe hardening) (L15497). [Rust minor]
- 🟢 **`Event::DiscardFunding` swallowed by the `other=>` arm** — add a log for LP operability (L28474). [Rust obs]
- 🟢 **Gas dedup**: redeem sweeps every 4626 twice (illiquidLoss + refreshAllHoldings); auxSwap 2× get_deposits; mint 2× get_metrics (needs return-plumb) (L8108,L19044). [EVM gas, low] (spreadEquallyBody 2-pass already = §V.4 / S07-9.)
- 🟡 **SOR failed attempts pay a full 4626 redeem + V4 swaps BEFORE reverting** — wasted gas on a losing path (L17963). [EVM]
- 🔴 **cross-chain forge tests `vm.skip()` → GREEN in CI verifying nothing** — false-confidence hazard (L1760). [test] (same class as §V.5 vm.skip concerns.)
- 🟡 **`splice` is NOT `_requireAttested`-gated** — 2 of 4 hop actions ungated (recordClose participant-gated by-design; drawPooledUsdBtc Core.onlyUs) — confirm splice INTENT (L31651). [attestation — VERIFY]
- 🟡 **`lexe_ca.rs` still hard-references Lexe's CA constants** — un-migrated trust root; a Staging/Prod misconfig would trust Lexe infra (L108,L22917). [config/PKI] (borderline vs memory `lexe-reuse-audit`.)
- 🟠 **CI GAP — no secure-enclave build pipeline** (verified 2026-07-25: `.github/workflows/{ci.yml,e2e-harness.yml}` = plain `cargo build/test --workspace` + forge; ZERO `sgx|enclave|dcap|sgxs|mrenclave|fortanix` in any workflow). All SGX content elsewhere (G4 M11 residuals, S29 AttestedHopRegistry, DCAP TCB) is FEATURE work — this is the missing BUILD-HYGIENE CI that gates it. Split by what's CI-able: **(a) reproducible SGX build → MRENCLAVE pin is HARDWARE-FREE, CI-able NOW** — `cargo +nightly --target x86_64-fortanix-unknown-sgx -p quid-bridge` → `ftxsgx-elf2sgxs` → `sgxs-hash` (a pure hash of the .sgxs); this is what makes the AttestedHopRegistry whitelist auditable (does the pinned measurement == a build of the published commit?) and catches SGX-fork drift silently rotting (memory `m11-enclave-build`); **(b) `quid-sgxs-sign` signing smoke** (host-only, CI-able); **(c) DCAP/attestation smoke = needs a real SGX runner** (the infra-gated tail, like G4's hardware residuals — not closeable in hosted CI). Complements W.1 (EL-off zero-dep CI invariant) + S32 (FFI e2e CI). [CI/build-hygiene] — (a)+(b) actionable now; (c) SGX-runner-gated.

### V.9 STALE-TRACKED CORRECTIONS (SCAN-RECONCILE §2B — commit-verified 2026-07-25, memories updated)
These mark things a later thread already BUILT, so no one re-does them (the reverse-chron payoff). All commits confirmed present at HEAD.
- **onlyHop/LP signing key "operator-held plaintext → move into enclave" = DONE** — born-in-enclave, derived from the sealed seed (commit `7f1d840`), env-refused under SGX. Corrected memories `m11-enclave-build`, `multihop-swapin-sgx-residuals`.
- **AttestedHopRegistry "NEVER wired into BTCChannels" = STALE** — now wired + governance-armed via `_requireAttested`/`_authorizedHop` (`BTCChannels.sol:533/671/694`, openChannel/settleSwapIn/emitDeadManExit). Residual = only DeployL1_s deploy-wiring + `_parse` offset-pinning + real Automata/Safe addrs (that residual is §V.8 splice-gate-adjacent + already in memory `onchain-hop-attestation §RESIDUALS`).
- **LINK `onGovernanceReport` arbitrary-call = MOOT** — the CRE onReport/LINK path was removed; not in the current tree (memory `audit-pass` already records the #2043-2050 removal).
- **"SGX CORE COMMITTED" understates reality** — multi-TEE landed since: SEV-SNP custody + boot-policy fail-closed + `EvmValidatingSigner` + CVM attestation/measurement (commits `77fb9ed`/`b43beb6`/`0b5e31c`/`583ae0f`/`755d19c`). Corrected memory `m11-scope`.

**SCAN-RECONCILE-2026-07-25.md is now MIGRATED into §V (V.7 map + V.8 net-new + V.9 corrections). It remains as the ad2385ae audit trail; do not migrate it again.**

## W. OPTIONAL EIGENLAYER AVS OVERLAY (2026-07-25, user) — EigenLayer is OPT-IN; the fleet MUST run without it

**HARD INVARIANT (user):** every Rust component in the SPV folder MUST run **standalone without EigenLayer** (exactly as today — SGX-attested, foundation/self/LP-hosted, permissionless keepers) **AND** optionally as an **EigenLayer AVS operator with it**. EigenLayer is an **additive opt-in overlay with ZERO dependency in the core**: `cargo build` / `cargo test` of the core workspace with the EL feature OFF must stay green and pull **no** EL/AVS crates. This is a build-gated invariant, not a promise.

**Architecture (feature-gate, not a rewrite):**
- Core crates (`quid-ln`, `quid-bridge`, `quid-hop`, `quid-common`, SPV) — UNCHANGED, no EL dep.
- NEW optional workspace member `quid-avs` (or an `eigenlayer` feature), compiled only when wanted. It WRAPS the existing hot path; it is NEVER a dependency of the core.
- The existing keyless broadcaster (`recovery_broadcast.rs` / `quid-recover-exit`) is the standalone (no-EL) path and STAYS the default.

**Anchor = the dead-man broadcaster AVS (§N / #114) — the one clean candidate.** It is the rare fleet component that is (a) **SECRET-FREE** (reads a public `DeadManExitEmitted` event, POSTs already-signed public bytes) → open operator set, **no SGX-vs-decentralization conflict**; and (b) **PROVABLY SLASHABLE via the project's OWN SPV**: the operator must submit a **BTC inclusion SPV proof** of the broadcast within a grace window after the CLTV deadline; no proof → slash. Proving a POSITIVE (inclusion) is exactly what the SPV does natively. The other fleet parts (key-custody hop/signer; a watchtower for *revoked-state* justice) are NOT clean AVS candidates — they need SGX confidentiality and/or have hard-to-attribute faults. Do NOT force them in.

**Rust, not Go/eigensdk-go:** EL's interface is Solidity contracts + Eth RPC (language-agnostic); `eigensdk-go` / the "Incredible Squaring" example is a convenience whose main reason-to-exist is the BN254 **BLS aggregator**. Make this AVS **PROOF-BASED (on-chain SPV-verified), not BLS-aggregation-based** ⇒ skip BN254 entirely. Rust operator = the existing broadcaster + `alloy` (RPC / contract bindings / ECDSA) + the existing SPV verifier. At most a thin **one-time registration** script is non-Rust.

**Security = EXOGENOUS. QUI stays OUT of the slashing bond.** Secure it with restaked ETH / ether.fi **weETH** (alignment — QU!D already holds weETH as collateral). Securing QU!D infra with QU!D's own QUI is **reflexive/procyclical** (crisis → QUI craters → security craters *simultaneously*; Terra/FTX-class death-spiral) — forbidden by the same instinct as memory `procyclical-intermediary-caution` + R1. QUI's MAX role = a **reward recipient**, never the slashed collateral.

**PLAN (phased; W.0 needs NO EigenLayer and closes the §N flag):**
- **W.0 — standalone watchtower (no EL, DO FIRST).** Finish the flagged-unbuilt hostable keyless reader (`getLogs → POST rawtx`, §N line 615) as a one-page web app + a daemon task; run ≥3 redundant instances (foundation + LPs). Closes the `PRODUCTION-LAUNCH.md:79` watchtower box. This IS the "runs without EigenLayer" liveness guarantee. Cheap — the CLI broadcaster is already built.
- **W.1 — feature-gate scaffolding.** Carve any EL-touching code into `quid-avs` (optional member / `eigenlayer` feature). CI proof: core workspace builds + tests EL-OFF with zero EL deps (the hard invariant).
- **W.2 — AVS contract (Solidity).** `ServiceManager`: `submitInclusionProof` (verify via the existing SPV verifier → mark duty done + pay reward) and the `{deadline+grace elapsed} ∧ {no proof} → slash` predicate + operator-set registration. **VERIFY the current EL API FIRST** — operator sets / `AllocationManager` replaced `AVSDirectory` in the 2025 slashing release; do NOT bind against recalled API.
- **W.3 — Rust operator overlay (`quid-avs`).** Wrap `recovery_broadcast` + alloy register/allocate-stake + submit-proof.
- **W.4 — testnet + economics.** Exogenous ETH/weETH security live; reward routing (QUI reward-only). Confirm nonprofit fit for AVS rewards (QuidMint Foundation, ASC 958) BEFORE any emissions.

**Value it buys (honest):** W.0 already gives redundant liveness. The AVS (W.1–4) buys ONLY **removing the foundation as the assumed watchtower operator** + turning liveness from *expected* → *crypto-economically guaranteed*. Build the AVS ONLY if that decentralization endgame is explicitly bought — NOT merely to close the §N flag (W.0 does that). Refs: memories `reference-weeth-valued-at-intrinsic`, `procyclical-intermediary-caution`, `ln-attack-surface`; §N; `IMPAIRMENT-DERISK-TRIGGER.md`.

### §S — AUTHORITATIVE RECONCILIATION vs HEAD d91107f (2026-07-25). Reverse-chron, verified.
**✅ STRUCK — mis-recorded as live, RESOLVED at HEAD (do not re-raise):** S3 (light getUserReserveData AaveV3Venue:148), S10 (flat-multiple decided-against), S11 (_withdraw CEI Vogue:547), S14 (JIT snipe lastDepositBlock a25d0e4), S16 (revert on 0-delivery SwapLib:496), S17 (Aux-vs-POOLED bacfb6a), S29 (attestation wired), S30 (registerDelegation selectors uint64), S35 (matureSupply present Basket:156), S40 H1/H2/M3/M4 (delever hardened), S40 security-orphans (H-1 surface removed + MED-3 cap live), S40 COMPOUND_GAS (140k in sync).
**🔴 GENUINELY LIVE backlog at HEAD:**
- S39 GAP-1 — `Aux.pokeVaultHealth` (Aux:448) has NO scheduled caller. Wire into fleet keeper / CRE cron.
- S39 GAP-2 — no evacuate-to-Aave for OPEN levered weETH-on-Morpho. ⚠️ REFRAMED by S41 LST verdict: reactive evac = over-engineering; the real item is the plain-venue-socialization question (S41).
- S40 M1 — multi-LP "most-over-collat-first" delever fairness unbuilt (feature).
- S40 T1 — #54 delever regression tests owed (needs forge).
- ~~S40 legacy_sweep — orphaned; wire or delete.~~ ✅ RESOLVED: `wallet/legacy_sweep.rs` DELETED (`4f3c952`); no longer exists at HEAD.
- S1 — FIXED 2026-07-25 (LevManager:496 "(L∈[1,2])" → "up to ~4× / 75% LTV").
- S12/S13 — LOW ≤50bps IL-leak refinements (oracle-price withdraw burn Vogue:551; oracle-center normal-repack).
- S40 C1/S37 — #104 cross-tx double-pay design fork — USER-OWNED.
**❓ NEEDS FRESH BUILD/RUN:** S24 & S40-C2 (EIP-170 sizes — `out/` STALE Jul-22; run `forge build --sizes`), S31 (rev_client_ser_basic), S32 (LN↔EVM FFI e2e — bitcoind CI).

## A.8 UNRECORDED-WORK SWEEP (2026-07-26, end of session) — items that existed only in-thread

Written after the user asked *"all the remaining todos are now in the build queue?"* and the honest
answer was NO. The queue was **three commits stale** (last touched at `86f31f5`, missing everything
from `f4a1c2a`/`4d11f6f`/`9efcf04`), and the items below existed only in conversation. Recording them
is the point: anything not in this file does not survive the thread.

### A.8a ✅ LANDED this session (do NOT redo)
- **`_withdrawableOf`** — one Morpho-V2-aware withdrawable definition (`f4a1c2a`). See the corrected §A.5b.
- **`forceDeallocate` REMOVED** — probed ineffective. §A.5b now says DO NOT IMPLEMENT; it previously
  prescribed exactly that. VaultLib 9,791 → 9,355 bytes.
- **`venuePosition` security fix** — permissionless-poke false-signal, was documented-but-unapplied.
- **Interface consolidation STARTED** (`9efcf04`) — `src/imports/Interfaces.sol` created; 20 decls → 6
  (`IAaveV4Spoke` 5→1, `IWeETH`/`IRover`/`IDepositAdapter`/`IAaveV4Hub`/`IMorphoFlash` 3→1). 144 → 130.
- **`withdraw(type(uint).max)` cap** (`86f31f5`) — cap at the FULL position, NOT the free slice, or
  #109's auto-de-lever becomes unsatisfiable by construction.
- **#113 ETH de-lever test** — had NEVER been executed; the failure was a unit error in the TEST
  (`debtOf` returns native stable decimals, not USD 1e18). Now passes.
- **Test retargeting** (`4d11f6f`) — Strand-2 and the poke test moved Galaxy → Euler.

### A.8b 🔴 OPEN — discovered this session, NOT yet actioned
1. **`BasketLib` stable-side has the SAME Morpho-V2 bug, and it is NOT fixed.** `_withdrawableOf` was
   applied to the ETH path only (that is what was measured). `BasketLib:824` and `:1082` still read a
   raw `maxWithdraw` for the STABLE 4626 vaults. If any stable vault is a Morpho-V2 impl, its
   deliverability is being understated exactly as the ETH side was — and `:824` feeds the redemption
   haircut. ⇒ **Measure which stable vaults are V2 before changing anything** (do not assume).
2. **Gauntlet venue is UNVERIFIED.** Every probe this session left it at 0 shares — a deposit with
   venue selector 6 never landed. Unknown whether that is a supply cap, a routing bug, or the selector.
   It is 1 of our 3 ETH venues and has never been exercised end-to-end.
3. **Remaining interface consolidation.** `ILevEquity` (no single superset variant: union 5, largest 4)
   plus `IAux`/`ICore`/`IEthVenue`/`IAuxSwap` (16–27 members). `IAux.take` is a GENUINE 4-arg vs 5-arg
   overload, not naming variance — needs judgement, not the script. Method that worked: normalise
   `uint`→`uint256`, strip param names, compare selectors, take the superset variant's body verbatim.
4. **`PREMIUM_ANNUALIZE = 127` is unvalidated.** The θ-local numerator (#107/D3) swapped `avgYield` for
   a band-fee EWMA and DELETED the `theta > 1e18` ceiling, so θ is now unbounded above. No test
   exercises either change. θ gates in-range band depth ⇒ this is not cosmetic.
5. **Two LiquidityRace thaw tests were passing VACUOUSLY** until `4d11f6f` — their LP-side
   "Galaxy 30%-liquid" premise had gone inert. Fixed by neutralising the V2 marker in the mock, but the
   general lesson is unaudited: **other tests may pass for reasons unrelated to their premise.** No
   sweep has been done for this class.

### A.8c 🟠 OPEN — carried from earlier, absent from this file until now
- **MISS 1** — JIT-DEPTH §4/§5-step-2 built but still marked TODO.
- **MISS 4** — INTERFACE-DEDUP §0; partially resolved by `9efcf04`, see A.8b#3 for the remainder.
- **MISS 6** — dangling spec refs, incl. `LevManager.sol:78`.
- **`__pycache__` is not gitignored anywhere.**
- **Doc verdicts still owed:** `HOP-CUSTODY-SGX.md`, `BTC-MARKET-MAKING-SPEC.md`, `AUDIT-TODO.md`;
  `LEVERAGE-RISK-SURFACE.md` recommended for deletion (0 open markers) and awaiting the user's word.

### A.8d ⚠️ The 11 remaining suite failures — triage, so nobody re-derives it
- **4 pre-existing** (`testReal_*` lever cases) — fail IDENTICALLY on the clean `364b3ff` baseline.
  Includes two `panic: division or modulo by zero (0x12)`. Not caused by this session's work.
- **The fairness / bank-run / churn cluster** — `test_EthLp_RedeemConservationAndFairness` improved from
  a **210% skew to 19.4%** (both LPs now paid alike, but ~19% short). §A.5c already names the cause and
  the target: make `deliverableETH` the VIEW TWIN of the withdraw ladder. **That is the next work item.**

### A.8e 🟠 θ FAIL-OPEN — fix landed, but NOT PINNED BY A TEST (be honest about this)

`derivedThetaWad`'s docstring promised *"FAILS OPEN on an unmeasured register (`premium == 0` ⇒
return 1e18)"*, but the code did `mulDiv(_bandFeeYieldWad(...), 1e18, work)`, and
`_bandFeeYieldWad` returns 0 for BOTH `premium == 0` and `pooled == 0` — so θ failed **CLOSED**.
That is the deadlock the docstring itself warns about: θ=0 ⇒ `applyTheta` clamps in-range depth to
zero ⇒ no fees ⇒ no premium ⇒ no depth, permanently. A cold band could never bootstrap. **Fixed**
(2-line guard, matches the sibling `sigmaSq == 0` / `kWad == 0` / `work == 0` early-returns).

⚠️ **TWO attempts to test it BOTH passed with the fix REVERTED** — i.e. both were vacuous. On this
fixture `derivedThetaWad` returns 1e18 from an EARLIER short-circuit (`sigmaSq == 0`, or `kWad == 0`
once flow exists), so the premium branch is never reached and the mutation is invisible. The tests
were deleted rather than kept: a test that passes against the mutation is worse than no test,
because it advertises coverage that does not exist (same class as the LiquidityRace thaw tests).
⇒ **To pin it, a future attempt must first establish `sigmaSq > 0 AND kWad > 0` and verify BOTH are
non-zero before asserting** — do not assume flow produces them. Then zero only `premiumEwmaUsd`.
⇒ **`PREMIUM_ANNUALIZE = 127` remains unvalidated**, and the `theta > 1e18` ceiling is still deleted
(argued safe: every consumer short-circuits at >=1e18 and `clampByBacking` is the real bound).

**METHOD NOTE — mutation-test your tests.** Every "verified" claim this session that later collapsed
came from asserting without mutating: #113 (written, never run), `forceDeallocate` ("works" — frees
nothing), θ (shipped untested, had this bug), and both θ tests. Revert the fix; if the test still
passes, it pins nothing. Use `--match-contract <OneProbe> --match-test <name>` (~30s), NOT a full
suite run (~150s x N) — the cheap check is what makes this habit affordable.

## A.9 🔴 THE "~20% LP-EXIT SHORTFALL" DOES NOT EXIST — it is a TEST MEASUREMENT ARTIFACT (MEASURED 2026-07-26)

**Retracts the framing of §A.5b/§A.5c.** Six failing tests all reported the LP receiving ~80% of
expected — 80.0 / 80.2 / 80.3 / 80.5 / 80.6 / 80.8%. That uniformity was read as one systemic
value loss ("the ~20% exit shortfall class") and §A.5c built a design theory on it: that
`deliverableETH` over-counts legs the ladder cannot convert. **The premise was never measured
at the primitive.** Measured now, replicating `testDepositImmediateWithdraw` exactly:

```
POOLED_ETH drop  : 4.999999999999999976
native ETH recvd : 4.009905234387772624   <- the ONLY thing the assertion counts
WETH       recvd : 0.988208510413466412   <- ignored by the assertion
                   ─────────────────────
             total 4.998113744801239036   = 99.96% of 5.0
```

**No value is lost.** The withdraw ladder legitimately pays part of an exit as WETH (idle WETH at
the Vault is handed over directly) and part unwrapped to native ETH. The recurring "~80%" is simply
the ETH/WETH SPLIT RATIO. The assertions read `User01.balance` only.

⇒ **Group A — measurement artifact, NOT protocol bugs.** `testDepositImmediateWithdraw`,
`testWithdrawWithAccruedFees`, `testAlternatingSwaps`, `test_BankRun_VaultLiquidity`,
`testFuzz_VogueDepositWithdraw`. Fix the ASSERTIONS to count ETH+WETH (the tree already has the
right helper — `_lpReceived` sums eth + weth + QUID-as-ETH). Do NOT "fix" the contracts for these.
⇒ **Group B — GENUINELY REAL, and now the only open exit defect.**
`test_EthLp_RedeemConservationAndFairness` uses `_lpReceived`, i.e. it ALREADY counts WETH and QUID,
and still reports LP1 80.58 vs LP2 100.00 — a 19.4% EXIT-ORDER asymmetry between two equal LPs, with
the FIRST-out receiving LESS. That is a distinct defect and must not be lumped with Group A.
⇒ **§A.5c's redesign is NOT justified by this evidence.** It may still be worth doing on its own
merits (the view/ladder divergence is real as a code-duplication argument), but the empirical
motivation it cited is withdrawn. Re-derive before building.

**METHOD — the blindspot this exposes.** The ~20% framing was inherited from an earlier doc and
carried forward for a whole session without anyone measuring the primitive quantity. A uniform
ratio across independent tests should have prompted "what is 80% OF?" immediately — a shared
denominator usually means a shared MEASUREMENT, not a shared bug. Measure the primitive before
theorising about the system.

## A.10 EXIT-ORDER FAIRNESS — the 19.4% was the §A.9 artifact; a REAL ~2% first-mover edge sits under it

`test_EthLp_RedeemConservationAndFairness` was the last suspected exit defect. It does NOT use
`_lpReceived` (an earlier claim that it did was wrong) — it measured `User01.balance` only, so it
was Group A after all. Counting ETH+WETH makes the fairness assertion PASS: **the 19.4% exit-order
skim does not exist.** Two real effects were hiding beneath it, both measured:

**1. A genuine ~2.15% FIRST-MOVER ADVANTAGE.** Re-run with the flow ROUND-TRIPPED (alternate
buy/sell instead of the test's monotonic 6× ETH→USDC), LP1 = 99.962 and LP2 = 97.856 — first out
gets MORE. The test's own one-directional flow masks this, because under monotonic flow the payout
composition difference dominates. This is the real fairness question and it is UNRESOLVED.
⇒ Likely mechanism: the first exit is served from the most liquid legs (idle WETH, honest-view
venues) and the second bears the residual. That is the §A.5c view/ladder question in its ONLY
empirically-supported form — note it is ~2%, NOT the ~20% §A.5c was built to explain.

**2. PRINCIPAL IS NOT PRESERVED under real flow.** With the test's own one-directional flow, total
out is 199.963 vs 200.000 in (−1.86 bps): IL slightly EXCEEDS fees. The test asserts an "IL-free
normal regime", but a monotonic 6 ETH walk of the price is not IL-free — the premise contradicts
the scenario. Under round-tripped flow the total is 197.8, i.e. worse, so this is not a one-off.

⚠️ **The scenario change was REVERTED and is NOT in the tree.** Reshaping a test's flow until it
passes is tuning, not fixing; the alternating run above was a diagnostic only. Only the ETH+WETH
MEASUREMENT correction was kept. The test still fails, now on `total out >= total in` — an honest
economic result rather than a phantom.
⇒ **Decision needed (user):** is a small net-IL outcome under one-directional flow ACCEPTABLE (then
the assertion's "IL-free" premise should be restated to bound IL rather than forbid it), or is
fee capture expected to cover it (then the fee/band math is the defect)? Do not silently relax the
bound — that is the assertion that would have caught real value leakage.

## A.11 ✅ RESOLVED — the "IL / principal loss" was a DEFERRED position the assertion ignored

Closes §A.10's open question. The user pushed back on "IL slightly exceeds fees" — correctly, because
that was INFERRED, never measured. Measured, accounting for every asset in the exact scenario:

| | native ETH | WETH | QUID | **still pooled** | total |
|---|---|---|---|---|---|
| LP1 | 80.583 | 19.380 | 0 | **3.0013** | 102.96 |
| LP2 | 100.000 | 0 | 0 | **3.0013** | 103.00 |

- **NOT a levered route** — `levPooled == 0` for both LPs. (The user asked; it had been assumed.)
- **NO IL and NO leakage.** 199.963 delivered **+ 6.003 still pooled** = ~205.97 against 200.000 in.
  The LPs GAINED ~5.97 in fees. Nothing is unaccounted.
- **Fairness is fine** — 99.963 vs 100.000, equal to 0.04%. Combined with §A.10, BOTH the 19.4% skim
  and the "principal loss" were artifacts of what the assertions counted.
- **The 2.15% "first-mover advantage" in §A.10 is therefore also suspect** — it was measured with the
  same delivered-only accounting and did NOT include the retained position. Do not treat it as a
  confirmed defect; re-measure with delivered+retained before acting. §A.10 amended accordingly.

**Root cause: the test asserted on DELIVERED value while neither LP fully exits.**
`withdraw(type(uint).max)` delivers what the ETH ladder can source and DEFERS the remainder as a
live, recoverable `pooled` claim — here each LP's share of the 6 ETH User03 swapped in, part of which
is a USD-denominated claim the ETH ladder correctly refuses to pay out as ETH. Reading that deferral
as a loss is what produced the phantom IL.

**Fixed** by asserting over `delivered + retained`. Kept rather than deleted, after checking overlap:
`test_RunSim_AllExit_Normal` covers principal-back BETTER (uses `_lpReceived`, i.e. ETH+WETH+QUID, and
asserts the stronger no-stuck-bag property `rem < 1e9`), but this test uniquely covers **exit-order
fairness** and the **conservation UPPER bound**. Those two are its reason to exist.

⚠️ **Residual worth knowing:** LPs do NOT fully exit in this scenario (3.0013 each deferred), whereas
`test_RunSim_AllExit_Normal` asserts they DO (`rem < 1e9`) and passes. The difference is that runsim
has redeemers burning QU!D first, which frees stables. Whether a deferral with no redeemer present is
acceptable-by-design or a liquidity gap is NOT settled here — but it is a deferral, not a loss.

## A.12 THE 3 REMAINING FAILURES — diagnosed to root cause (2026-07-26); 2 are ONE bug, not "pre-existing noise"

They were being written off as "pre-existing testReal_* lever cases". Traced properly:

### `testReal_Morpho_OpenAndDelever` + `testReal_Euler_OpenAndDelever` — ONE bug: zero TWAP inside the flash-loan callback
Both died on `panic: division or modulo by zero (0x12)`. Cause: `LevMath.deleverSettleBody` is called
with **`pxWeth == 0`**, and divided by it unguarded at `LevMath:549` and `:793`.
`Aux.getTWAPforAsset` deliberately NEVER reverts (that is what makes #101's degrade-to-partial-fill
work), so a zero price is a VALUE it can return, and two divisors trusted it blindly.

**FIXED (defensively):** both divisions now `revert NoPrice()`. A panic burns all gas and is
undiagnosable; a named revert is the correct failure for an op that cannot be sized without a price.
⚠️ It had to be a CUSTOM ERROR, not `require(..., "lev:noPrice")` — the string form measured 38 bytes
PAST EIP-170 for `LevMath`. With the custom error it sits at 24,556 with **20 bytes free**. Anything
added to `LevMath` from here must check `forge build --sizes` first.

**FIXED (fixture):** `_setupMorpho`/`_setupEuler` now pin the ETH/USD anchor exactly as the real deploy
does (`DeployL1_s:326`) — they never did, so `rpx` was silently 0. An `assertGt(rpx, 0)` now guards it.

🔴 **STILL OPEN — the real defect, now precisely located.** The anchor resolves NON-ZERO at setup (the
new assert passes), yet the TWAP returns 0 *later*, inside `onMorphoFlashLoan`. From the trace,
`BasketLib.ticksToPrice(1161326410, 2758414210, 1800, true)`: the average tick is
`(2758414210-1161326410)/1800 = 887271`, i.e. **essentially MAX_TICK (887272)**. The pool is pinned at
its boundary, the price is not representable, and `ticksToPrice` yields 0.
⇒ Two candidate readings, NOT yet distinguished: (a) the fixture's V4 pool is initialised/pushed to an
extreme so this is a TEST-POOL artifact; or (b) the levered open genuinely walks this thin pool to the
tick boundary, in which case reading the TWAP mid-flash-loan is unsound in production too.
⇒ **Do not "fix" this by widening a tolerance.** Distinguish (a) from (b) first — log the pool tick
immediately before the flash loan.

### `testReal_Euler_RebalanceMany_BatchHoldsTarget` — a strict-inequality assert on an unchanged value
`5314620473 <= 5314620473`: the batch rebalance moved the target by EXACTLY ZERO. Distinct from the
two above (no panic, no price involvement). Either `rebalanceMany` is a no-op in this fixture, or the
position already sat at target so there was nothing to do. Unresolved; needs its own look.

## A.13 🔴🔴 REAL PROTOCOL DEFECT — the band's restoration is DISABLED BY THE CONDITION IT EXISTS TO FIX

Answers "why is this failure happening" for §A.12's two `testReal_*` deaths. It is **NOT a fixture
artifact** — I first proposed a test-side "depth guard" and the user rejected it as masking the
question. Correctly: the guard would have hidden a genuine self-reinforcing failure loop.

**The mechanism, measured end-to-end:**
1. One-directional selling into the band drains its USD side (`POOLED_USD_ETH` 27,290 → 0;
   `committedUsd18` → 0). The band correctly absorbs ETH (`POOLED_ETH` 2.13 → 8.25).
2. As it drains, the pool spot walks toward the tick boundary — measured `sqrtPriceX96` =
   1461446703485210103287273052203988822378723970341, i.e. **`MAX_SQRT_RATIO − 1`**.
3. At the boundary the price is unrepresentable, so `BasketLib.ticksToPrice` yields **0** and
   `getTWAPforAsset` returns 0 (it deliberately never reverts — #101 degrade-to-partial-fill).
4. **`SwapLib.sol:1531` — `if (twap == 0) return r; // didRepack stays false → keep current range`.**
5. `didRepack == false` ⇒ `Core._handleRepack`/`_repackAdd` never run ⇒ **`Vogue.addLiq` is never
   called**, so the band is never re-paired with Aux dollars. Measured: 8 `Vogue::repack` calls during
   the crash but only 3 `addLiq`, all of them during setup/open — **zero during the crash**.
6. The drain therefore cannot stop, the pool pins, and every price consumer downstream reads 0 —
   including `LevMath`'s divisors, which panicked before §A.12's `NoPrice()` guard.

**The dollars and the headroom were BOTH available the whole time** — which is what makes this a
defect rather than a limit: basket surplus **$176,779**, and `clampByBacking` headroom
`backing 16.13 − pooled 8.25 = 7.88 ETH`. Neither `sizeBySurplus` nor `clampByBacking` nor θ
(measured 1e18 fail-open at every stage) was the throttle. Restoration was simply never reached.

⇒ **Fix direction (needs a decision, do NOT guess):** step 4 is the load-bearing line. `twap == 0`
currently means "don't touch the range", but at the boundary that is exactly backwards — a pinned pool
is precisely when a reseat onto the Chainlink anchor is needed. `Vogue.reseat()` already exists for
this ("PERMISSIONLESS deadlock-recovery poke… moves the spot onto the oracle so swaps resume") and the
anchor IS pinned and healthy (`assetPriceFeed(WETH)` = Chainlink, resolving 1927–1942 throughout).
So the material question: should `twap == 0` route to the RESEAT path (heal onto Chainlink) instead of
returning early? That inverts a guard on the swap hot path, so it needs its own review — but the
current behaviour is a deadlock the recovery mechanism cannot reach.

### A.13b `RebalIn` cannot be shrunk safely (asked 2026-07-26)
All 11 fields are READ by `rebalanceBody` (measured: core 1, aux 2, ev 1, weth 1, token1isETH 1,
lpShares 3, totalLevPooled 1, totalBuffer 2, lowerTick 2, upperTick 2, bookmark 3) — no dead fields.
The struct is the DELEGATECALL-BOUNDARY TAX, not bloat: VogueLib can read neither Vogue's immutables
(baked into Vogue's bytecode) nor Vogue's storage (libraries cannot declare state), so every value
must cross explicitly. Rejected alternatives: library self-calls (`IVogue(address(this)).AUX()`) move
bytecode INTO Vogue, the EIP-170-critical contract — spending headroom where it is scarcest to save it
where it is not; and collapsing `lpShares`+`totalLevPooled` into `plainDepth` fails because `lpShares`
is read 3× independently. The struct also exists to avoid stack-too-deep on the legacy pipeline, so
flattening it to positional args breaks the build.


## A.14 ✅ SUITE GREEN — 123 passed / 0 failed / 2 skipped (2026-07-26)

From the clean `364b3ff` baseline of 98 passed / 22 failed. The last two failures were fixed at their
root, and one earlier masking change was REMOVED.

**`testReal_Weth_OpenLeverClose`** asserted `vogueETH >= GROSS collateral` (5.920 vs 7.506) — one term
covering two. `vogueETH` counts a levered position at NET equity BY DESIGN; the debt-funded remainder
lives in `totalBuffer`, deliberately excluded from equity so it cannot be withdrawn as if it were the
LP's. The protocol's own ETH-backing composition is `vogueETH + grossBuffer` (`VogueLib.addLiq`), and
the assertion now uses exactly that. It failed by precisely the debt.

**`testReal_Euler_RebalanceMany_BatchHoldsTarget`** — debt moved by EXACTLY zero, and `debtDelta` was
RIGHT to do nothing. MEASURED: after `_openEulerLp` the band's sold fraction is already 0.821e18, so
the test's own `_rallyBand(.., 0.4e18, ..)` broke on iteration 0 (`0.821 >= 0.4`); and the position was
already AT its IL target because `_openEulerLp` ends with `rebalance(LP, 0)` and the target is capped
at the LP's chosen 5000 bps. `debtDeltaToTarget` returned `(false, 0)` = in band. The test could never
pass. Fixed via the real product path: `setTargetLtv(7500)` raises the LP's own cap, lifting the IL
target `min(soldFraction, cap)` above current LTV so the batch has genuine work. (LP-permissioned cap,
permissionless rebalance toward it — which is what the test exercises.)

**🔴 A REJECTED CHANGE HAD LANDED AND IS NOW REMOVED.** The `_crashBand` "depth guard" of §A.12 was
rejected by the user as masking the question, but it reached the tree and was swept into commit
`324d2f9` by a `git add -A`. It has been reverted. Both `testReal_*_OpenAndDelever` tests PASS WITHOUT
it, which proves §A.13's one-line anchor fix (`twapResolve` no longer skipping Chainlink when the
internal TWAP is 0) was the real fix and the guard was pure masking. Lesson: after a rejected edit,
verify the file — do not assume rejection reverted it.

## A.15 🟠 A DEPOSIT INFLATES THE VERY BUFFER THAT GATES ITS OWN FORWARD TENOR (found 2026-07-26)

`Basket._finishMint` bounds how far forward a cohort may lock by the live over-collateralization
buffer: `bufBps >= 500 -> 12 months, >= 300 -> 6, >= 150 -> 3, else 1`. The stated intent is that
"longer locks ONLY when the buffer supports it… so a thin buffer can't be stretched into long-dated
cohorts."

**But the buffer is measured INSIDE the mint, with the incoming deposit already counted in `total`
while the new QUI has NOT yet been added to `totalSupply()`.** So the depositor's own money counts
toward the collateralization that authorises their own tenor.

MEASURED via `test_forwardHorizon_thinBuffer_clampsToFloor`: the basket's natural buffer was **0 bps**,
yet a 100k USDC mint into a ~157k-supply basket made the mint read **3887 bps** — vaulting it past the
500-bps tier and granting the full 12-month lock that the thin buffer was supposed to forbid. The test
had been computing the buffer BEFORE the deposit, which is why it asserted `maxFwd == 1` and failed.

⇒ **Not fixed in contract — recorded for a decision.** The gate is doing something, but not what its
comment claims: it bounds tenor by post-deposit collateralization, so a large enough deposit always
self-authorises the maximum. Whether that is acceptable (the 1:1 cap still binds the *amount*, and
`redeem` values one basket share at `min($1, solvent/mature)`) or should measure the buffer EX the
incoming deposit is a design call. Sizing matters: the effect scales with deposit/basket, so it is
largest exactly when the basket is small.
⇒ Test now sizes its deposit to 1% of supply so the thin-buffer path is genuinely exercised, and
`_mintFarDated` takes the mint size as a parameter with the interaction documented.

## A.16 🔴 REAL FINDING — a levered LP's lifecycle EXPENSES the passive LP by ~7.5% (2026-07-26)

The last failing test in the tree, and it is **NOT a test bug**. `test_PassiveLp_NotExpensedByLeveredLpLifecycle`
is a treatment-vs-control probe and it is detecting exactly what it was built to detect.

- **TREATMENT:** band rally → levered LP opens/rebalances → REAL Morpho liquidation (`_seizeReal`) → realign.
- **CONTROL:** `vm.revertToState` back, then the SAME rally price path with NO levered LP at all.
- **RESULT:** passive LP value 10,619 (treatment) vs 11,482 (control) — the passive LP ends **~7.5%
  worse off** purely because a levered LP existed and was liquidated. The assertion allows 0.1%.

**Verified NOT an oracle/fixture artifact.** This fixture also never registered its pool-tracking
`ETH_FEED` with Aux (`assetPriceFeed(WETH) == address(0)`), which is the §A.13 confound that broke
three other tests — a treatment/control comparison is especially vulnerable to it, since the arms
could diverge on oracle availability rather than on the levered LP. The anchor is now pinned here too,
and the result is **unchanged to 4 significant figures** (10,619,232 → 10,619,445). So the cross-subsidy
is real, not a measurement divergence.

⇒ **DELIBERATELY NOT "FIXED".** Relaxing this bound would delete the only automated detector of
leverage cross-subsidy in the tree — the exact "mask the question" failure mode the user named. The
assertion stays red until the mechanism is understood.
⇒ **Where to look:** the liquidation is the prime suspect — a Morpho seizure takes collateral at a
discount, and if any part of that loss lands on shared band/backing rather than solely on the levered
LP's own net equity, passive LPs absorb it. Related: §A.11 established that `vogueETH` counts levered
positions at NET while the debt-funded gross sits in `totalBuffer`; a seizure changes gross and net by
DIFFERENT amounts, so the split is where a leak would hide. `_seizeReal` + `syncLev`'s reconciliation
after an external seizure (`_reconcileLev`, "self-heal a levered position seized by an EXTERNAL venue
liquidation") is the code path to audit.


## A.17 ✅ SWEEP — "a guard that short-circuits past its own recovery path" (2026-07-26)

Run because THREE instances turned up in one session (§A.13 `twapResolve`, `Vault.venuePosition`'s
documented-but-unapplied fix, `_pull4626`'s swallowed zero fallback). Two detectors, both over `src/`:

**Detector 1 — an early `return`/`break` on a zero/sentinel that PRECEDES a recovery mechanism in the
same function.** 13 candidates. It re-found all four defects already fixed this session (which is the
validation), and **every remaining one is sound**:
- `SwapLib.sourceWethBody` — returning 0 means "this rung sourced nothing"; `withdrawETH`'s ladder
  moves to the next rung. The empty catch falls through to the second fee tier BY DESIGN.
- `LevManager.deleverOne` — its `require(debt < debtBefore)` deliberately SURFACES "sourced nothing"
  so `cascadeDelever` catches and skips that LP. That is the fault-tolerance, not a swallow.
- `LevMath._roverAbsorb` — returns 0 so the caller falls to `_weethToWethDex`.
- `VaultLib._supply4626` — try 4626 → else AAVE → else HOLD IDLE, and idle WETH is counted by
  `_vogueETH`, so all three outcomes are accounted.
- `Core._levDebtUsd18` / `levGrossNative`, `Vault.totalNetEquityBtc` — view fail-safes whose direction
  is documented and conservative ("subtract 0 debt … only RAISES committed ⇒ STRICTER gate").

**Detector 2 — a DOCSTRING promising a fallback the body may not implement** (the shape that caught
`venuePosition`). 22 candidates; the θ family and the `falls back` promises audited. All implement what
they promise: `BtcVaultLib._thetaClampBtc` has `if (thetaEff == 0) thetaEff = 1e18`, `v3SwapTiered`
explicitly assigns the fallback to the CALLER, `_aaveYieldWeighted` has `shares > 0 ? … : assets`.

### 🔴 SELF-CORRECTION — §A.8e OVERSTATED the θ fail-closed bug
The sweep's real find is that **my own claim was wrong**. §A.8e and commit `54d9077` said `derivedThetaWad`
failing closed would cause "θ=0 ⇒ applyTheta clamps depth to zero ⇒ no fees ⇒ no premium ⇒ no depth,
permanently. A cold band could never bootstrap." **That deadlock was NOT reachable.** Both consumers
already normalise 0 → 1e18 BEFORE `applyTheta` sees it:
- `VogueLib._liveTheta:467` — `try … returns (uint t) { return t == 0 ? 1e18 : t; }` (this is what
  `addLiq` calls, i.e. the ETH band-sizing path)
- `BtcVaultLib._thetaClampBtc:125` — `if (thetaEff == 0) thetaEff = 1e18;`

The fix is still correct and stays — the function must match its own docstring, and the EXTERNAL views
(`Vogue.derivedThetaWad`, `Vault.derivedThetaWadBtc`) were reporting a bare 0 that reads as "throttle to
zero" to any off-chain consumer. But it is **belt-and-braces, not a deadlock preventer**, and it was
never load-bearing. Recorded so nobody cites §A.8e as evidence of a bug that could fire.

**Conclusion:** the codebase's fallback discipline is sound. The three instances that motivated this
sweep were genuine outliers, not the tip of a pattern — and the sweep was still worth running, because
it is what caught the overstatement above.

## A.16b 🔴🔴 MECHANISM FOUND — the SHARE FORMULA socialises a levered LP's liquidation (2026-07-26)

Answers §A.16. **MEASURED end-to-end**, and the user's framing is the correct one: *"the share formula
is broken — a levered LP's shares should not affect what the other LPs get out with respect to their
own positions."*

### How it happens (measured, not theorised)
`_seizeReal(LEVR)` = a REAL Morpho liquidation of the levered LP. Across that single call:

| | before seizure | after seizure | after `syncLev(LEVR)` |
|---|---|---|---|
| `vogueETH` (backing, shared numerator) | 16.443 | **11.217** (−5.226) | 11.217 |
| `lpShares` (shared denominator) | 20.503 | **20.503 — UNCHANGED** | **15.277** (−5.226) |
| `levPooled[LEVR]` | 5.503 | **5.503 — UNCHANGED** | 0.277 |
| `autoManaged[PASSIVE].pooled` | 10.000 | 10.000 | **10.000 — untouched** |
| implied share price | 0.802 | **0.547 (−32%)** | 0.734 |

**The seizure destroys 5.226 ETH of backing and burns NOBODY's shares.** Share price is
`vogueETH / lpShares` — ONE shared numerator over ONE shared denominator — so the entire 32% drop lands
on every holder. The passive LP holds 10.0 of 20.503 shares and therefore eats ~half of a liquidation
they had no part in. That is the ~7.5% of §A.16.

`_reconcileLev` exists for exactly this ("self-heal a levered position seized by an EXTERNAL venue
liquidation"), and it works: forcing `syncLev(LEVR)` burns **exactly 5.226** of the LEVERED LP's shares,
leaves PASSIVE's 10.000 intact, and **the test PASSES**. But it is LAZY — reached only from
`Vogue._withdraw` (`if (levPooled[msg.sender] > 0) _reconcileLev(msg.sender)`) and `syncLev`, i.e. on the
LEVERED LP's OWN next action. Until then the loss sits socialised.
⇒ **So it is a RACE**: whoever exits before the levered LP is reconciled absorbs a share of someone
else's liquidation. Nothing prevents a passive LP from being that party — and a liquidation is exactly
when everyone tries to exit.

### Q1 (user): can unlevered LPs be prevented from taking the loss? — YES, proven
`syncLev` already charges the loss to precisely the right party. The gap is only that nothing GUARANTEES
it runs before value is extracted. Options, cheapest first:
1. **Reconcile-before-extract (targeted).** In `Vogue._withdraw`/`redeem`, before pricing shares, force
   reconciliation of any STALE levered slice. Cheap staleness probe already exists: compare the live
   `ILevEquity.totalGrossCollateralEth()` against the recorded gross — `_reconcileLev`'s own docstring
   says it "reconciles the (possibly stale) levered slice to the live gross". Invariant to enforce:
   **nobody extracts at a share price computed from stale levered collateral.**
2. **Permissionless `syncLev(lp)` + keeper.** Already permissionless-shaped; make the liquidation path
   or a keeper call it. Weakness: still depends on someone calling it, so the race narrows but survives.
3. **STRUCTURAL (the user's point, strongest).** Stop pricing a levered LP's claim out of the shared
   `vogueETH/lpShares` pool at all. Their gross collateral already lives in an ISOLATED per-LP
   `MorphoEscrowVenue`, and the debt-funded part is already tracked apart in `totalBuffer` — so the
   isolation exists everywhere EXCEPT the share formula. Making the levered slice price off its own
   position removes the race by construction rather than by timing.

### Q2 (user): is forcing everyone to be a levered LP a solution? — NO, and it is not needed
It would make things worse: it does not remove the shared denominator, it just enrols everyone in
each other's liquidation risk. The isolation architecture ALREADY exists (per-LP escrow venues,
net-equity accounting in `vogueETH`, gross segregated in `totalBuffer`). **The only leak is that the
share formula prices a levered claim against shared backing.** This is a bookkeeping-scope bug, not a
missing-architecture problem — no product change is required to fix it.

### Status / scope warning
🔴 **NOT FIXED — expected to be a long task, banked deliberately.** Option 3 touches share pricing, the
most safety-critical formula in the system (it gates redemption value and the backing invariant), so it
needs its own design pass, not a same-turn edit. Option 1 is the smaller, shippable mitigation and can
land first without foreclosing option 3.
⚠️ **`test_PassiveLp_NotExpensedByLeveredLpLifecycle` stays RED on purpose.** It is the only automated
detector of this in the tree. A `syncLev` call was ADDED to the test during diagnosis and REMOVED again
before commit — with it in place the test passes, which would have masked the defect exactly as §A.13's
depth guard nearly did.

## A.18 🔴🔴 THE FORK IS NOT PINNED — the whole fork suite is NON-REPRODUCIBLE (found 2026-07-27)

`vm.createSelectFork(vm.rpcUrl("mainnet"))` — **no block number**. Every run forks at the current
mainnet HEAD, so results depend on live external state at the moment of the run.

**Caught red-handed:** `test_forwardHorizon_*` passed at `fe1246c`, then failed hours later with
`AbsoluteCapExceeded()` from a Morpho-V2 stable vault — with `git diff fe1246c HEAD -- evm/src/` EMPTY
and the test file byte-identical. Nothing in the repo changed; the vault's cap utilisation moved on
real mainnet. Also explains the debt drift observed all session across identical runs:
5278077636 → 5288115014 → 5298701298 → 5314620473 → 5384222951.

**Consequences, all of which bit today:**
- Green today ≠ green tomorrow. A CI pass proves nothing about a later run.
- `git bisect` and before/after comparisons are unsound. My "upstream fails identically, to the wei"
  checks (§A.12, §A.16) only held because the two runs were minutes apart — that was luck, not method.
- A test can fail for reasons with no cause in the diff, which is exactly the trap that burns hours.

⇒ **FIX: pin the block** (`vm.createSelectFork(vm.rpcUrl("mainnet"), BLOCK)`). Note the standing rule
already assumes a pinned block exists ("when a real dependency can't satisfy a test at the current fork
block, MOVE THE FORK BLOCK, don't mock") — the rule is right, the wiring never implemented it.
⇒ Pin ONE constant in the shared fixture; per-file `createSelectFork` calls should read it. Expect some
tests to need the block moved rather than mocked, per the standing rule.

## A.16d ⛔ REVERTED — the structural share-price fix was WRONG (2026-07-27)

`477dfae` (§A.16c) is **reverted in `2e5a0fa`**. The user challenged it — *"why does share price isolate
the levered book if levered assets are in the band?"* — and was right.

MEASURED in a HEALTHY, perfectly in-sync state (`levPooled == netEquity`, gap exactly 0):

| formula | plain share price |
|---|---|
| shared `vogueETH / lpShares` (original) | 0.614 |
| plain `(vogueETH − netEq) / (lpShares − levPooled)` (my change) | **0.1886 — 69% LOWER** |

`vogueETH` 6.453 minus `totalNetEquityEth` 5.510 leaves **0.943 of backing against 5.000 plain shares**.
The two terms DO NOT cancel: `totalNetEquityEth` is not a separable additive component matching
`totalLevPooled` on the same basis, because the levered capital is COMMINGLED in the band (its buffer is
real V4 depth). Netting it out therefore strips backing that genuinely supports plain claims and would
have cut plain-LP redemption value by ~69% in normal operation.

🔴 **The full suite passed (123/0) with this change in.** That is the lesson: the cross-subsidy test went
green because the price became INSENSITIVE to the levered book — correct in relative terms, catastrophic
in absolute terms — and round-trip tests apply the same wrong price on both sides, so they cancel. Green
tests are not a proof of a pricing formula. Any future attempt MUST assert an ABSOLUTE price against a
hand-computed expected value, not just relative invariants.

⇒ **Back to option 1 (reconcile-before-extract) as the live candidate**, and the user's reasoning is why:
the assets ARE shared, so they cannot be separated by construction — the accounting must instead be kept
SYNCHRONISED. Enforce "nobody extracts at a share price computed from stale levered collateral" by
forcing `_reconcileLev` on any stale slice before pricing in `_withdraw`/`redeem`.

## A.19 BTC swap-out: how a swapper with NO channel receives real BTC (answers user, 2026-07-27)

`BTCChannels.requestSwapOutOnchain` takes a raw **scriptPubKey** (validated as 22/25/34 bytes =
P2WPKH/P2PKH/P2WSH/P2TR), and `deliverSwapOutOnchain` is gated to `msg.sender == channels[channelId].hop`.
So: **the HOP sends real on-chain BTC to the swapper's plain Bitcoin address, and the swapper never
touches Lightning at all.** They need no channel, no LN node — only an address. The protocol settles the
hop afterwards; `swapOutOwedUsd` tracks the undelivered obligation.

**Why this matters for the vBTC-market question (§A.19b below):** redemption today is bound to a SPECIFIC
`channelId` and its hop. That is the per-LP binding. A liquidator who seizes vBTC has no channel and
therefore no redemption route — which is precisely why an OPEN Morpho/Euler market for vBTC cannot
attract liquidators or, consequently, lenders. The user's framing is exact: we enable BTC redemption
**de facto** (any address can be paid) but **not de jure** (no channel-independent claim exists).
⇒ The pooled-backing BTC token dissolves the binding by construction — redeemable against AGGREGATE
channel capacity rather than the originating LP — but it needs its own accounting to prevent the
double-claim that `exposeBtcToLev`'s "the LP never receives loose vBTC" invariant currently guards.


## A.19b 🔴 CORRECTION + TODO — vBTC redemption is MECHANICALLY the same as swap-out (user, 2026-07-27)

**§A.19 was too pessimistic and is corrected here.** I said a vBTC holder "has no redemption route".
The user's challenge — *"isn't a swap out the same as bearer redemption mechanically? why would it work
any differently for any vBTC holder to redeem to any address?"* — is correct.

**Swap-out is ALREADY bearer-shaped:** `requestSwapOutOnchain` takes USD + a raw P2TR scriptPubKey and
the hop delivers real on-chain BTC to it. The recipient needs no channel, no LN node, no prior
relationship. So the protocol demonstrably CAN pay an arbitrary bearer at an arbitrary address. The
recipient side is a solved problem, not a blocker.

**What is actually missing is therefore only TWO things, not a redemption capability:**
1. **An entrypoint.** `exposeBtcToLev`/`unexposeBtcFromLev` are gated to `LEV_MANAGER_BTC`, so no third
   party can burn vBTC at all. A `redeemVBtc(sats, p2trScript, channelId)` that burns the caller's vBTC
   and enqueues the SAME `pendingOnchainSwapOut` delivery would reuse the existing rail wholesale.
2. **Source-of-funds binding — the REAL open question.** Swap-out names a `channelId` and is delivered
   by THAT channel's hop. A liquidator holding vBTC minted against LP-A's channel is bound to LP-A: if
   that channel is drained or its hop is unresponsive, the claim is stuck even though aggregate channel
   capacity exists elsewhere. **The binding is about WHICH channel pays, NOT about whether a bearer can
   be paid.** That is the precise thing a pooled-backing model dissolves.

⇒ **This also softens the "no open Morpho/Euler market" conclusion**: a liquidator CAN be paid, so the
market is not structurally impossible — it is impossible only while redemption is pinned to the
originating channel, because a liquidator cannot underwrite that counterparty risk.

### TODO — what a POOLED-backing vBTC would entail (context banked, user will return to this)
- **Redeem against AGGREGATE capacity**: pick any channel/hop with free capacity rather than the
  originator. Needs a capacity index + selection (cheapest/most-liquid hop) and a fallback when the
  chosen hop fails mid-delivery (the existing `settleSwapIn` reversal is the model).
- **The double-claim invariant is the hard part.** Today's guard is structural and blunt: "the LP never
  receives loose vBTC (that would double-claim the same channel BTC)" (`exposeBtcToLev`). Pooling
  DELIBERATELY breaks the 1:1 token↔channel binding, so that guard must be replaced by an aggregate
  one: Σ outstanding vBTC ≤ Σ free channel capacity, enforced on mint AND on every channel
  close/splice/drain that reduces capacity.
- **Per-LP fairness**: if any LP's channel can service any redemption, an LP whose channel is chosen
  bears the outflow while the fee/risk accrued to another. Needs either pro-rata assignment or
  compensation — the SAME class of problem as §A.16's cross-subsidy, and worth solving together.
- **Liquidation interaction**: with pooled redemption, a seized vBTC position is exitable, which is what
  makes an external lending market viable — the payoff that justifies the work.

## A.20 SWEEP — vacuous tests ("passes for a reason unrelated to its premise"), 2026-07-27

Run because §A.8b#5 promised it and never delivered — the user caught the omission. Three instances had
already been hit by hand this session (the two LiquidityRace thaw tests; BOTH of my θ tests), so the
class is real.

**Two distinct shapes, and only one is cheaply automatable:**

**(1) INERT MOCK — the test mocks something the code under test no longer reads.** Automatable:
extract every `vm.mockCall` selector in `test/`, check it is still CALLED in `src/`. Result: 16 distinct
mocked functions, **no genuine inert mocks**. The 4 flagged were false positives — `selector`/`sevSel`
are local variables, and `ethAmountLockedFor*` mock ETHER.FI'S OWN contracts (LiquidityPool
`0x308861A4…`, RedemptionManager `0x35e7D6fe…`), which our `src` legitimately never calls because
ether.fi's code reads them. ⇒ **Detector refinement for next time: only flag a mock whose TARGET
ADDRESS is one of our own contracts.** A mock on a third party proves nothing either way.

**(2) UNREACHABLE ASSERTION — the assertion is satisfied by an EARLIER short-circuit, so the branch
under test never runs.** This is the one that bit twice (θ), and it is NOT statically detectable —
the only sound check is MUTATION: revert the fix and confirm the test flips to red. Cheaply, that is
`--match-contract <OneProbe> --match-test <name>` (~30s), not a full-suite run.

**Mutation status of the tests this session touched** (honest audit):
- ✅ #113 units, Strand-2 retarget, `_mockVenueIlliquid` thaw fix, the 5 ETH+WETH assertion fixes,
  `_crashBand`/anchor fixes — all were RED before and GREEN after, i.e. mutation-verified by construction.
- ✅ `test_PokeVaultHealth_HealthyMorphoV2_NotBlocked` (new) — without `_withdrawableOf` the venue IS
  blocked, so it binds.
- ✅ `testGauntletVenue_DepositAndFullExit` (new) — asserts `maxWithdraw == 0` AND `deliverable == 20`,
  which only both hold with the fix.
- ✅ The share-price fix (§A.16, second attempt) — verified by an ABSOLUTE byte-identity assertion,
  the precise check the reverted first attempt would have failed.
- ⛔ Both θ tests — did NOT bind, and were DELETED rather than kept (§A.8e).

⇒ **Standing rule earned from this: a test written to pin a fix is not done until it has been shown to
FAIL without that fix.** Cheap enough (~30s) that there is no excuse to skip it.

## A.21 ✅ SPA ABI DRIFT FIXED + a checker built to stop it recurring (2026-07-27)

**D1 (real bug, shipped):** `spa/src/lib/abi.ts` declared
`get_deposits() returns (uint[13], uint[13], uint, uint)` while the contract returns `uint[15]`. With
STATIC arrays that shifts the head, so `avgYield` and `depegLoss` decoded from INSIDE the arrays —
wrong numbers rendered with no error anywhere. Fixed to `uint[15]`.
**D2 (comments only):** the indexing was already correct (`STABLES.map((s,i) => amounts[i])`, 12 stables
at 0..11); three comments claimed `uint[14]` and "index 11..13 are aggregate slots" — the aggregates are
12..14. Comments corrected; no rendering change.
**D3 (already clean):** the SPA venue enum matches the contract exactly (0 Split / 2 AAVE / 3 Galaxy /
4 Rover / 5 Euler / 6 Gauntlet). No drift.

**`tools/check-client-abis.py` NOW EXISTS.** The standing rule said to run it; it was never in the repo,
which is why D1 shipped. It parses the SPA's hand-written signatures, matches them against every
compiled ABI under `evm/out`, and diffs the return tuples. It immediately found a SECOND drift nobody
had noticed: `exitInstant(uint256,address)` declared NO return while the contract returns `uint256`.
Both fixed; **76 signatures checked, 0 drifted.** Run it after any contract signature change.

## A.22 SWEEP — hardcoded expectations vs live fork state (user directive: derive, do NOT pin)

The user rejected pinning the fork ("real values being tested… our contracts should work with real
fluctuating values") and asked for expectations derived from live state instead. Correct: the fork drift
is a FEATURE; the bug is tests carrying constants that silently assume external state.

Swept every assertion for absolute literals: **29 sites across 9 files**. Most are LEGITIMATE and were
left alone — a test that deposits 10,000e6 and asserts on 10,000e6 derives from its own action, and
`LiquityVenue`'s `1900e18`/`1000e18` are Liquity's 2000-BOLD minimum-debt floor and the test's own
borrow, not market prices. **Do not "fix" those** — a constant is only fragile when it encodes EXTERNAL
state.

Genuinely fragile ones fixed:
- `ForwardMintHeadroom`: `assertGt(minted, 105_000e18)` silently encoded the 100k default mint size —
  now derived from the principal actually deposited. `assertGt(minted, 99_900e18)` likewise scaled.
- `test_forwardHorizon_thinBuffer_clampsToFloor` **now asserts the PROPERTY, not a predicted tier.** The
  test cannot reproduce the contract's internal depeg-adjusted `total` (computed INSIDE the mint, after
  the deposit lands — §A.15), so pinning `nextMonth + 1` was really asserting that our estimate of a
  live moving quantity matched to the bps. It didn't (estimate <150, mint saw the 150-300 tier). It now
  asserts what the test exists to prove: the far request was CLAMPED, and a thin buffer yields a SHORT
  lock (the 1mo/3mo tiers, never 6/12) — true across the whole thin band and independent of the estimate.

⇒ **The pattern to reuse:** when a value depends on live external state, assert the INVARIANT that holds
across its plausible range, not a point value. That is what makes an unpinned fork an asset instead of
a flake source.

## A.23 📁 ACTIONABLE-FOLDER TRIAGE (2026-07-27) — verified against CODE, not against doc text

User: *"do not trust the docs… check the logic of the items and the code"* — after I deleted
`LST-PEG-MONITOR` on the strength of its own "don't build it" status line, which the user had ALREADY
told me to keep. That first pass was wrong in method: it scored docs by their self-description and by
citation count. **Citation count is not a keep signal and a doc's own status line is not evidence.**
Redone by testing each claim against the code.

### PROVEN STALE BY CODE → deleted
- `AUDIT-TODO` — its residuals are mostly DEAD, verified:
  · "Link ownership → multisig before mainnet" and "`Link.onGovernanceReport` arbitrary-call" both
    reference a contract **THAT NO LONGER EXISTS** — no `Link.sol`, and zero hits for
    `onGovernanceReport`/`setForwarder` anywhere in `evm/src`.
  · "`settleSwapIn` not `nonReentrant`" — **FALSE**: `BTCChannels.sol:1086` already declares
    `external nonReentrant`.
  Only two items survived and are migrated to §A.24.
- `INTERFACE-DEDUP-AND-CONSOLIDATION` — landed this session (144 → 116 declarations); remainder in §A.17.
- `LEVERAGE-COLLATERAL-ROUTE-SPEC` — the route is shipped (`LevManager.openLev` + generic venue legs).
- `LEVERAGE-RISK-SURFACE` — 0 open markers; superseded by the live leverage code and §A.16/§A.16b.
- `BTC-MARKET-MAKING-SPEC` — its ONLY code citation was a historical aside in `Core.sol:158`; not
  load-bearing. Comment reworded to stand on its own.
- `DISCUSSION-DIGEST` — a conversation log, superseded by this queue.

### VERIFIED LIVE → KEPT (my first pass had these wrong)
- `LST-PEG-MONITOR` — **KEEP.** Its one surviving lever, the ex-ante weETH venue-share cap, is
  **NOT in the code** (grep: no cap in `VogueLib`/`Vogue`). The doc's "don't build the monitor"
  conclusion is not the same as "nothing here is open". The user had already said keep; I ignored that.
- `HOP-CUSTODY-SGX` — **KEEP, but on WEAKER grounds than first stated.** 116 Rust files reference
  SGX/enclave, so the subject is alive. ⚠️ **RETRACTED:** I also cited "`lexe_ca.rs` still hard-references
  Lexe's CA constants" as a live bug in this doc's domain. **That is FALSE — verified 2026-07-27:**
  `lexe_ca.rs` does not exist, and the only three "lexe" hits are two vendored-upstream LDK comments and
  one prose comment. The migration was completed. The claim came from a STALE MEMORY of mine, which is
  now corrected — the same "trust the record over the code" error the user has caught repeatedly.
- `EIP170-MIGRATION` — **KEEP.** Headroom is critical RIGHT NOW: `LevManager` 70 bytes free, `LevMath`
  20 bytes free. Guidance for the tightest constraint in the tree is not stale.
- `PUPPETEER-E2E-MATRIX` — **TRIM, don't delete.** Voting IS gone from the code (0 hits for
  `castVote`/`function vote`), so those sections are stale, but the rest is E2E coverage mapping.
- `TAPROOT`, `JIT-DEPTH`, `LEVERAGE-BTC-M11`, `IMPAIRMENT-DERISK`, `SOR-SIGNIFICANCE` — all cited for
  LIVE semantics or open decisions, and their subjects verified present in code.
- `FAMILY-PLAN`, `KHALANI-SOLVER-INTEGRATION` — UNBUILT FORWARD DESIGNS. Deleting these destroys design
  work rather than removing rot; needs the user's explicit call, not a sweep.

⚠️ **`JIT-DEPTH-GUARANTEE` status is stale even though the doc is load-bearing** — its §4 list marks
work as TODO that is already built (§4.1 COMPOUND-not-transfer is present in `Vogue.sol`). Fix the
status; do not delete.

## A.24 THE TWO SURVIVING AUDIT-TODO RESIDUALS (the rest were dead — see §A.23)
- 🟡 **`repack` `myLiquidity` trusted-arg.** VERIFIED still open: `Core.repack` takes `myLiquidity` from
  the caller with no `poolStats`-vs-arg assertion. POOLED desync is structurally safe (mutated only from
  realized V4 `BalanceDelta`) and it is inside the Vogue keeper trust boundary, but add the assertion +
  a POOLED-equals-realized invariant test to close it.
- ⚠️ **RISK-2 bootstrap-year forward-yield over-mint (by-design, watch).** The 1:1 cap is skipped for
  `currentMonth() < 12` and `avgYield` is grindable via a 4626 share-price held past the averaging
  horizon. Accepted cold-start tradeoff; maturity-lock contains redeemability. **Directly related to
  §A.15** (a deposit inflating the buffer that gates its own tenor) — solve them together.
- **Accepted/won't-fix, carried forward:** §9a `recordClose` co-signed STALE close (`finalBalance` is
  hop-trusted); RISK-3 cross-LP close fairness (inherent to the pooled model); BTC-share median
  staleness (sizing cap only, self-correcting on churn).

## A.25 🔴 PRICING-INTEGRITY CLASS CLOSED AT THE MORPHO ORACLES (2026-07-27)

§A.13 fixed the ROOT (a zero internal TWAP now falls through to the Chainlink anchor). This closes the
same failure class at the most dangerous CONSUMERS: the three Morpho `IOracle` implementations in
`LevOracles.sol`, which EXTERNAL PROTOCOL CODE calls. Found by sweeping all 55 `getTWAPforAsset`
consumers for unguarded zero handling.

| oracle | old behaviour on a zero price | consequence |
|---|---|---|
| `RealRateBtcMorphoOracle` | returns **0** | Morpho values ALL vBTC collateral at zero ⇒ **every position instantly liquidatable** |
| `InverseRateBtcMorphoOracle` | `1e66 / 0` ⇒ **panic** | Morpho's calls revert with an opaque `Panic(0x12)`, after burning all forwarded gas |
| `InverseRateMorphoOracle` | `1e56 / uint256(p)` with **`p <= 0`** | Chainlink returns `int256`; a NEGATIVE answer casts to ~2^256 ⇒ price ~0 ⇒ the mass-liquidation case. `p == 0` panics. |

All three now `revert NoPrice()`. **The choice is a security decision, not style:** returning 0 causes
irreversible mass liquidation; reverting halts new borrows AND liquidations and everything RESUMES when
the feed recovers. A frozen market is recoverable; a mass liquidation at a false zero is not.

Note the third oracle's bug was NOT a zero-TWAP issue at all — it is a raw `int256`→`uint256` cast on a
Chainlink answer, and `p <= 0` (not `p == 0`) is the correct guard. It would have survived a
zero-TWAP-only sweep.

Verified: LevYbWeth 123/0/2, VBtcLevFeeLane 125/0/2.

## A.26 CORRECTIONS to the DualPoolStableHook comparison (user, 2026-07-27)

Two claims of mine were wrong and are retracted:
1. **"We can't serve external order flow" — FALSE.** `Aux.swap` is `public payable` with NO caller gate
   and sends output to `msg.sender`. Any router, aggregator or searcher can call it today. What we lack
   is DISCOVERABILITY by V4-native routing — our pool's currencies are mock tokens nobody else holds, so
   Uniswap's own router cannot path through us. That is an INTEGRATION gap (an adapter/aggregator
   listing would close it), not a capability gap.
2. **The IL comparison was apples-to-oranges.** `DualPoolStableHook` is STABLE-to-STABLE, so IL is
   near-zero by construction — it is not that JIT eliminated IL. Our band is ETH/USD, where IL is real
   and unavoidable, so the IL-protect leverage stack is a REQUIREMENT of the pair, not overhead versus
   their design.

Standing where the comparison is still favourable: the same capital earns venue yield AND provides band
depth simultaneously (they must shuttle real assets vault↔pool every swap); and the V4 pool is not a
value-bearing attack surface (mock tokens are worthless outside the system), which is why we need none
of their `emergencyRevokeVault`/vault-vetting/native-ETH-rejection machinery. Gas remains UNMEASURED
against their implementation — do not claim it.

## A.27 ✅ THE `_effectiveAssets` QUESTION, ANSWERED — we DO over-quote, but we MATERIALISE rather than cap

Prompted by DualPoolStableHook capping quotes at `_effectiveAssets` to prevent over-claiming against
reserves. **Yes, our band can quote depth it cannot immediately deliver** — and the code already knew,
at `Vogue.sol:954`: the swap prices against `POOLED_ETH`, which INCLUDES the levered slice, while
`deliverableETH` EXCLUDES lev net-equity. That gap is the "§M phantom depth".

**We take the opposite approach to Uniswap's, deliberately:**
- **They CAP** the quote at effective reserves — the taker simply gets less.
- **We OVERDRAW then MATERIALISE**: when the venue base is exhausted mid-delivery,
  `SwapLib.deleverEthOnDelivery` de-levers the levered book **with the swap's own proceeds**, converting
  phantom depth into real deliverable ETH. Value-neutral per LP (−collateral −debt of equal oracle
  value), and explicitly NOT the removed toxic `arbETH` (which spent shared basket surplus) — it repays
  each LP's OWN debt.
⇒ Ours quotes MORE usable depth for the same reserves; theirs is simpler and cannot short-deliver.
The tradeoff is real work on the delivery path, so it must actually work — which is why the marker
below mattered.

**Stale marker cleared.** That paragraph was tagged `🔴 UNVERIFIED — fork-test w/ DeleverEthBackingProbe`.
The test it asks for is `testReal_DeleverEthBacking_SwapOutTapsLeveredSlice` — written earlier in THIS
session, found never to have been executed, fixed (its `debtOf` units were native-decimals, not USD
1e18), and now passing on a real Morpho/Euler fork with value-neutrality, LTV improvement and
no-phantom-depth all asserted. Marker updated to ✅ VERIFIED.

⚠️ **Residual worth noting:** materialising depends on the levered book HAVING room to de-lever. With no
levered positions open, the phantom depth is simply absent (POOLED_ETH == deliverable, no gap), so this
is self-consistent — but a fully de-levered book plus exhausted venue base is the case where a taker
CAN still be short-delivered (`sent = wethBal >= amount ? amount : wethBal`). That silent-short path is
§A.5's open item and is NOT closed by this.

## A.28 RUST FORKS vs LOCAL CRATES — no duplication to remove; the real finding is UNPINNED deps

User asked whether the local Rust duplicates the `quidmints` forks and could be replaced by dynamic
git imports. **Measured — the premise does not hold, and the safety question inverts.**

**There are TWO categories and they are already correct:**
- **Third-party forks are ALREADY git deps, not vendored.** `rust-sgx`, `axum-server`,
  `rust-esplora-client`, `hyper-util`, `tokio`, `mio`, `ring` — all `git = "https://github.com/quidmints/…"`
  in `quid-ln/Cargo.toml`. There is no local copy of any of them to delete.
- **The 25 local `quid-*` folders are OUR OWN crates**, workspace members via `path =`, **710 files
  tracked inside the SPV repo**. `quid-ln` has no `.git` of its own. They are first-party SOURCE, not
  duplicates of anything.

**Replacing our own crates with git deps would be actively harmful, not a cleanup:**
- No local edits without `[patch]` overrides — every change becomes push-then-pull.
- Chicken-and-egg: a change must be PUBLISHED before it can be tested.
- Loses workspace-shared incremental builds; adds a network fetch to every clean build.
- The source has to live somewhere regardless — this moves code between repos, it does not remove it.

🔴 **THE REAL SAFETY ISSUE, and it is the opposite of the question: our git deps are NOT PINNED.**
**16** fork dependencies, **13 declared `branch = "main"`, ZERO with `rev =`.** `Cargo.lock` currently
pins exact commits (e.g. `ring#12d3b388`, `rust-sgx#08048855`), so builds are reproducible TODAY — but
`branch` without `rev` means any `cargo update` silently re-resolves to whatever that branch points at,
and a rewritten/compromised fork branch changes what we build.
⇒ **This matters most for exactly the wrong crates: `ring` (crypto) and `rust-sgx`/`dcap-ql`/`sgxs`
(SGX ATTESTATION).** A silent move there is a supply-chain compromise of the enclave trust root.
⇒ **Fix: add `rev = "<sha>"` alongside each `branch`, taking the sha already in `Cargo.lock`.** One line
per dep, no behaviour change, makes the pin explicit and immune to `cargo update`. Pairs with the
recorded `lexe_ca.rs` un-migrated CA-constants issue — same trust-root class.

## A.29 THE OVER-QUOTE, FROM ALL SIDES — and why §A.5's "silent short" must NOT be "fixed" with a revert

User: *"look at this from all sides, don't break our existing code."* Traced the whole ETH delivery
chain (`Vogue.sol:949-971`):
```
inWETH = balance
if (needed > inWETH)  → pull from venues (vogueOp)
if (inWETH < needed)  → deleverEthOnDelivery   ← materialise the phantom depth (§A.27)
sent = inWETH + alreadyInETH                    ← CAN be < needed
```
So `sent` can be short. The question is whether that is ever SILENT, and **on both consumer paths it is
already guarded:**
1. **SWAPPERS — protected by `minOut`.** `SwapLib:262` `if (amountOut < minOut) revert SlippageExceeded()`
   and `:493` `if (max == 0 || max < r.minOut) revert SlippageMaxS()`. A short fill below the caller's
   own bound reverts the entire swap. Not silent, and the swapper sets the tolerance.
2. **LP WITHDRAWALS — the shortfall is DEFERRED, not lost.** MEASURED in §A.11: 423.14 delivered +
   76.86 retained as live `pooled` = exactly the 500.00 principal. The LP keeps a recoverable claim.
3. **Before either fires**, `deleverEthOnDelivery` converts levered phantom depth into real ETH (§A.27).

⇒ **DO NOT add a revert-on-short to `withdrawETH`.** It would convert a partial fill + deferral into a
hard failure, and the scenario where it fires is a BANK RUN — exactly when reverting everyone is worse
than paying each LP what is available and deferring the rest. The existing `_withdraw` comment already
argues this ("gridlock during a stress event is worse than first-out unfairness"). The design is right.

⇒ **§A.5's "silent short" framing is mostly wrong for the SAME reason §A.9's "~20% shortfall" was:** the
value is not lost, it is deferred, or the caller is protected by their own bound. The genuine residual
is narrow and should be stated precisely rather than as a general hazard: **is there any caller of
`withdrawETH` that neither sets a `minOut` nor defers the remainder?** That is the only question worth
auditing here, and it is a bounded audit rather than an open-ended risk.

## A.30 CLEANUP + a memory correction the user caught (2026-07-27)

**Deleted (dead code, verified):**
- `IlliquidGalaxy` and `MockGalaxyVault` test helpers — **0 real uses**. `IlliquidGalaxy` was made dead
  THIS session when `vm.etch` was replaced by `vm.mockCall` (§A.20's inert-mock class); only stale
  doc-comments referenced them, and those are removed too.
  ⚠️ **Method note:** my first detector counted `new X(` only and flagged `RevertingV3Router` as dead —
  it is NOT: it is used via `vm.etch(..., type(RevertingV3Router).runtimeCode)` at `Alles.t.sol:1387`.
  Counting constructor calls is the wrong test for a Solidity helper; check `type(X).runtimeCode` too.
- `evm/broadcast/DeployL1_s.sol/1/run-latest.json` — a regenerable deploy artifact that was tracked;
  now gitignored.

**🔴 MEMORY CORRECTION — the Lexe trust root is GONE, and I claimed otherwise.** I told the user
`lexe_ca.rs` "still hard-references Lexe's CA constants (a live bug)". The user challenged it
(*"i thought we deleted everything lexe related"*) and was right. VERIFIED: `lexe_ca.rs` does not exist;
only three files mention "lexe" at all, two are VENDORED UPSTREAM LDK (`lib/rust-lightning/`, 441
tracked files, not a submodule) where the hits are test-fixture attributions in comments, and one was a
prose comment in `quid-hop/tests/swap_in_onchain_e2e.rs` — **now removed, so our own source has ZERO
lexe mentions.** The vendored LDK comments are deliberately left alone: editing upstream would conflict
on every LDK update.
⇒ This came from a STALE MEMORY of mine, now corrected. Same failure mode as trusting doc status lines
(§A.23) — **the record is not evidence; the code is.** It also weakens §A.23's stated grounds for
keeping `HOP-CUSTODY-SGX` (the "live bug in its domain" justification is void); it is kept only because
116 Rust files still reference SGX/enclave.

## A.31 §J.2 IS THE VOGUE/VAULT CLEANUP TODO — still NOT STARTED, and gated
User asked where the Vogue/Vault cleanup lives. It is **§J.2 Refactors (structural)**: Vogue should not
be a 4626 if vBTC is its own segregated 4626; `Vault.sol` should not carry vBTC ERC-20 functions; plus
the full-2× buffer-as-band-depth unification.
**PREREQ (user, unchanged): complete + VERIFY the deposit→band→withdraw round-trip behaviour-neutrality
proof BEFORE refactoring the vault-share model.**
⇒ **Note for whoever picks it up:** the share-price formula CHANGED this session (`_pricingBacking`,
§A.16). The round-trip proof must therefore be written against the FIXED model, not the pre-fix one —
which is the correct order, but means any earlier round-trip reasoning is stale.

## A.32 UNUSED-CODE SWEEP + Rust dep pinning (2026-07-27)

**Why `--force` is needed (the user asked):** a CACHED `forge build` emits no warnings at all, so warning
analysis requires `forge build --force` once. Not a habit to repeat — but it is the only way to see them.

**`src` unused declarations: 7 found, 7 fixed → 0 remain.** The notable one was MY OWN dead code:
`VogueLib.derivedThetaWad(core, aux, …)` — the `aux` parameter went dead when #107/D3 moved the θ
numerator off `avgYield` (the only reader of `aux`). Parameter dropped and both callers updated;
**Vogue 24,092 → 24,061 bytes (515 free).** The rest (`Aux:736`, `VogueLib:176`, `Rover:391/553/665`)
were silenced by dropping the identifier, preserving every signature and the ABI.
⚠️ **Two near-misses worth recording, both caught only by re-checking:**
- At `Rover:553` I first dropped `price` — but the compiler's column 10 pointed at `liq`; `price` is
  used at `:559`. **Read the warning COLUMN, not the eye's guess at which name looks unused.**
- `RevertingV3Router` was flagged dead by a `new X(`-counting detector but is used via
  `vm.etch(type(X).runtimeCode)`. **Constructor counts are the wrong deadness test in Solidity tests.**

**Test-side:** removed `MockGalaxyVault` + `IlliquidGalaxy` (0 real uses), the orphaned `pe0` in
`LevCascade` (dead since I replaced that test's assertion earlier today), and unused `yield1`/`yield2`
destructurings. A handful of cosmetic unused-local warnings remain in test files whose line numbers
shifted during this session's deletions; they are noise, not defects, and are NOT worth further
archaeology.

**🔐 Rust git deps PINNED (§A.28's finding, now fixed).** All 13 `quidmints` fork dependencies moved from
`branch = "main"` (re-resolvable by any `cargo update`) to an explicit `rev = "<40-char sha>"` taken from
the shas already resolved in `Cargo.lock`. Highest-value for `ring` (crypto) and
`rust-sgx`/`dcap-ql`/`sgxs` (SGX attestation), where a silent branch move is a trust-root compromise.
⚠️ **Used `rev` ALONE, not `branch` + `rev`:** Cargo REJECTS an ambiguous spec — *"Only one of `branch`,
`tag` or `rev` is allowed"* — so the first pass would have broken the Rust build outright.
⚠️ **NOT verified by a build: `cargo` is not installed on this machine.** The shas are cross-checked
against `Cargo.lock` (e.g. `rust-sgx` → `08048855…`) and the syntax is correct, but a `cargo check` on a
machine with the toolchain is still required before trusting it.

EVM verified: builds clean, LevYbWeth 123 passed / 0 failed / 2 skipped.

## A.33 📁 SECOND PURGE — verified against code (2026-07-27). 12 docs → 7.

Per user: drop `FAMILY-PLAN` + `KHALANI`, and re-verify "stale" claims IN THE CODE before deleting.

### Deleted, each with the code check that proved it
- `FAMILY-PLAN`, `KHALANI-SOLVER-INTEGRATION` — dropped on the user's explicit call (unbuilt forward
  designs; recoverable from git if either is revived).
- `HOP-CUSTODY-SGX` — **every claim verified stale.** It self-declares "PARTIALLY SUPERSEDED", is the
  OLDEST doc (2026-06-05) and says it "predates the taproot build; key mechanics changed". Verified:
  the superseding `deploy/PRODUCTION-LAUNCH.md` EXISTS; the "still-unbuilt service glue" IS built
  (`evm_final` 3 files, `decode_swap_out_requested` 2 files, plus `quid-bridge-daemon.rs` and
  `quid-watchtower.rs`); and it cited `AUDIT-TODO.md`, already deleted, so that reference dangled.
- `EIP170-MIGRATION` — its stated GOAL ("enough headroom that ALL remaining BUILD-QUEUE work fits
  without re-breaching") is **measurably NOT met**: LevMath 20 B free, LevManager 70 B, SwapLib 306 B,
  Vogue 515 B, Core 663 B. So it is not a completed record, and the live constraint is already tracked
  (§A.12) and measurable in seconds via `forge inspect <C> deployedBytecode`. Its one durable method
  note is preserved below.
- `LEVERAGE-BTC-M11-SPEC` — its "genuinely open" item #1 describes a stub that **no longer exists**:
  `lev_keeper_btc.rs:71` records that the `BtcLevAcquirer` trait + `UnwiredNativeAcquirer` stub "was
  REMOVED (2026-07-22, #8)… the acquirer indirection was dead", with native positions now failing SAFE
  INLINE. The SUBSTANCE survives and is migrated below; the doc's specifics were stale, and it also
  cited two already-deleted docs.

### Migrated residuals (do not lose)
- 🔴 **Native BTC rail (#59/#74) is UNWIRED.** WBTC mode is the workhorse and rebalances fully on-chain
  (`rebalance_wbtc`, atomic). A native position fails SAFE inline in `do_delever`/`do_relever` — a loud
  no-op that falls through to the venue's ISOLATED liquidation. A `usd_to_vbtc_sats` helper is kept
  `#[allow(dead_code)] // reserved for the #59/#74 native rail`.
- 🔴 **Native force-close LLTV buffer vs Bitcoin-confirmation latency (DATA GAP).** A native force-close
  cannot finalize until Bitcoin confirms (potentially hours), so the keeper-trigger LTV must sit far
  enough under the venue LLTV to cover that latency. Sizing it needs a **measured channel-close-time
  distribution** — the one genuinely BTC-specific risk parameter still unmeasured. Does NOT apply to
  WBTC mode (atomic de-lever).
- 🟡 **Freeze `levPooledBTC` fee accrual during a pending native force-close** — clean-up, and only
  relevant once native-mode force-close exists.
- 📏 **EIP-170 method note (worth keeping):** read sizes from the artifact
  (`forge inspect <C> deployedBytecode`), NOT `forge build --sizes`, which rebuilds everything and
  thrashes a small box. Current tightest: **LevMath 20 B, LevManager 70 B** — check before adding
  anything to either.

### Kept (7, incl. the queue) — each verified live
`BUILD-QUEUE` · `TAPROOT-CHANNELS-BUILD-SPEC` (Rust-cited, shipped model) · `JIT-DEPTH-GUARANTEE`
(Vogue:419 cites §4.1 for live semantics; ⚠️ its §4 STATUS is stale — marks built work as TODO) ·
`IMPAIRMENT-DERISK-TRIGGER` (DeployL1_s:553 cites it as an OPEN product decision) ·
`SOR-SIGNIFICANCE-DESIGN` (SOR.sol:362 cites it as "⚠️ PARTIAL") · `LST-PEG-MONITOR` (its ex-ante weETH
venue-share cap is NOT in the code) · `PUPPETEER-E2E-MATRIX` (live E2E runbook — TRIMMED below).

### PUPPETEER trimmed, and one real error fixed
Verified its API references against code: `requestSwapOutOnchain` ✓, `Vogue.deposit(assets, receiver,
venue)` ✓ — but **`requestOnchainSwapIn` has ZERO hits in `evm/src`.** Corrected: swap-IN is
hop-initiated and settles through `BTCChannels.settleSwapIn` → `Vault.creditSwapIn`. Also collapsed the
two long strikethrough corrections (vote gate, USDT0) into one compact "settled, do not re-raise" note,
both re-verified against code. 109 → 102 lines.

## A.34 WHY `quid-tls` & friends live locally while forks live on GitHub (user, 2026-07-27)

User: *"i dont understand why we need quid-tls code and so many deps directly in our quid-ln folder if
they exist as separate repos (forks) on our github account"*. **Measured — they are NOT the same things,
and the naming is what makes it look like duplication.**

**The GitHub forks** (`quidmints/tokio`, `mio`, `ring`, `rust-sgx`, `hyper-util`, `axum-server`,
`rust-esplora-client`) are UPSTREAM crates patched to build for the SGX target. `quid-ln/.cargo/config.toml`
declares `[target.x86_64-fortanix-unknown-sgx]` with a custom `run-sgx-cargo` runner and compile-time
crypto intrinsics (`+adx,+aes,+pclmulqdq,+sha,+vaes` — enclaves cannot do runtime cpuid feature
detection). Upstream tokio/mio/ring do not support that target, which is the entire reason the forks
exist. They are consumed as git deps and there is **no local copy of any of them.**

**The local `quid-*` crates are OUR OWN code that USES those deps** — small, and clearly so once
measured:

| crate | lines | what it actually is |
|---|---|---|
| `quid-tls` | 3,318 | our TLS/attestation config, certs and utilities (`rcgen`, `x509_parser`, `quid_crypto`) |
| `quid-tokio` | 855 | *"utilities and extensions built ON TOP OF Tokio"* — `pub use tokio;` + `events_bus`/`notify`/`task` |
| `quid-std` | 823 | our std-shim for the enclave target |
| `quid-serde` | 706 | our serde helpers |
| `quid-hex`/`quid-sha256`/`quid-byte-array` | 322/100/222 | tiny leaf utilities |

For scale: a real vendored `tokio` fork is ~100k lines. `quid-tokio` is 855. **These are wrappers, not
copies.** Deleting them would delete first-party code, not remove duplication.

⇒ **The confusion is naming, and it is worth fixing separately if it keeps costing time:** `quid-tokio`
reads like "our fork of tokio" when it is "our helpers built on tokio". A rename (e.g. `quid-async-util`)
would remove the ambiguity — cosmetic, non-urgent, and NOT done here.
⇒ The genuine hygiene issue in this area was the UNPINNED forks, now fixed in §A.32 (all 13 moved to
explicit `rev =`).

## A.35 🔴 TODO — audit the Rust workspace for dead crates/code, then E2E the BTC core (user, 2026-07-27)

**User's ask, verbatim intent:** *"im not sure we need quid-api, there might be a lot [of] dead code in
the rust folder — eventually we should check all those with e2e tests for all our solidity core work
with BTC after we do these [other in-flight] items."*

- 🔴 **`quid-api` may be unnecessary.** Suspected dead. Do NOT delete on suspicion — this session
  produced two hard lessons about exactly that: `RevertingV3Router` looked dead to a `new X(` counter
  but is used via `vm.etch(type(X).runtimeCode)`, and `LST-PEG-MONITOR` was deleted on its own status
  line and had to be restored. **Test: is the crate in any binary's dependency graph?**
  `cargo tree -i -p quid-api` answers it directly (cargo IS available — verified 2026-07-27).
- 🔴 **Broader Rust dead-code sweep.** 25 workspace crates. Use the compiler, not greps: `cargo check`
  emits `dead_code` warnings, and `#[allow(dead_code)]` markers already flag deliberate reservations
  (e.g. `usd_to_vbtc_sats` is reserved for the #59/#74 native rail — NOT dead-by-accident). Anything
  reachable only from `#[cfg(test)]` is also a candidate.
- 🔴 **THEN E2E the BTC core against Solidity.** Sequence matters: prune first so the E2E covers what
  actually ships. The rails already exist — `quid-hop`'s `evm_final` finality gate,
  `decode_swap_out_requested`, `quid-bridge-daemon.rs`, `quid-watchtower.rs`, and the fork tests in
  `VBtcLevFeeLane.t.sol` — so this is wiring an end-to-end path over built pieces, not new machinery.
- **ORDERING (user):** do this AFTER the in-flight items below. It is a cleanup+coverage pass, not a
  blocker for them.

### Status correction — several items previously listed as open are now DONE
Recorded so this list is not re-litigated from a stale quote:
- ✅ **SPA drift D1/D2/D3** — FIXED (§A.21). D1 was the real bug (`uint[13]` vs the contract's
  `uint[15]`, silently misdecoding `avgYield`/`depegLoss`); D2 was comments-only (indexing was already
  correct); D3 was already clean. Plus `tools/check-client-abis.py` now EXISTS and found a second drift
  (`exitInstant`) — 76 signatures, 0 drifted.
- ✅ **§A.16 leverage cross-subsidy** — FIXED (§A.16b/c/d then the same-clock fix): the share price now
  reads the levered book on the SAME CLOCK as the denominator. Steady state is byte-identical to the
  old formula; the passive-LP test passes.
- ✅ **The "guard that short-circuits past its own recovery path" sweep** — DONE (§A.17). Two detectors,
  13 + 22 candidates; only the four already-fixed were real, and it caught my own θ overstatement.
- ✅ **Doc verdicts + deletions** — DONE (§A.23 + §A.33): 18 docs → 7, each deletion verified in code.
- ✅ **Interface consolidation, `__pycache__`, Gauntlet coverage, #113** — all done earlier this session.

### Genuinely still open (the accurate list)
§A.5e redeem stale-cache (needs a user decision) · §A.5f on-chain per-action delegation · §A.5g hop
reconnector · §J.8 weETH-on-Aave venue leg · `VogueLib.depositETH` venue-share cap (LST-PEG-MONITOR's
one surviving lever) · #12 POOLED_USD · MISS 1/4/6 · §J.2 Vogue/Vault refactor (gated on the round-trip
proof) · §A.5c deliverableETH view-twin · §A.15 self-authorising forward tenor · §A.24 repack
`myLiquidity` assertion · the native BTC rail #59/#74 + its force-close LLTV data gap · JIT-DEPTH §4
status.

### The vBTC synthesis worth keeping (user)
**The liquidator blocker and the anonymity blocker are ONE problem.** Both reduce to vBTC having no
bearer redemption, and both are held in place by the same explicit invariant — *"The LP never receives
loose vBTC (that would double-claim the same channel BTC)."* Swap-out already proves the protocol can
pay an arbitrary bearer at an arbitrary P2TR address with no channel (§A.19b), so what is missing is an
entrypoint plus a source-of-funds rule — not a capability. Solve the invariant (aggregate
Σ vBTC ≤ Σ free channel capacity) and BOTH blockers fall together.
