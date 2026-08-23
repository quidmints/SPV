# Audit — taproot channels + SGX + M11 at HEAD `bf62c578` (2026-08-22)

7-area parallel audit (Read/Grep only; bash `grep` is shimmed-broken here). Criticals re-verified by hand
against the code, not trusted from the sub-agent label. **Live status belongs in `QUEUE.md`** — this file
is the evidence record; fold the 🔴/🟠 rows into `QUEUE.md` (BUILD-QUEUE-AND-107.md is archive-only).

## Verdict by area
| area | verdict |
|---|---|
| Taproot channel signing | COMPLETE-WITH-RESIDUALS (all 6 goals met) |
| SGX enclave core + sealing + multi-TEE + EVM-key | COMPLETE-WITH-RESIDUALS |
| Rollback-freshness P0 + swap-in gate | COMPLETE-WITH-RESIDUALS (**P0 RESOLVED**) |
| Seed / provisioning / migration | COMPLETE-WITH-RESIDUALS |
| Completeness / masked-test sweep | COMPLETE (no masked tests) |
| Attestation / DCAP / RA-TLS | **GAPS-FOUND** |
| Taproot on-chain resolution | **GAPS-FOUND** |

## GENUINELY BETTER than prior work (verified)
- Coop-close nonce leak on restart-mid-close (was OPEN at sweep end, S10-19) is CLOSED: `closing_round`+`closing_partial_sent_at_round` persisted TLV 71/73, bumped on reload (`channel.rs:16456-16470`) — survives a crash, not just a reconnect.
- **P0 sealed-state rollback freshness RESOLVED**: on-chain-anchored per-channelId monotonic `BTCChannels.freshnessSeq`/`commitFreshness`, WIRED into `node::boot` monitor+manager load (`node.rs:862-877/920-953`), seq stamped inside sealed plaintext, fail-closed, e2e vs real anvil. Not the "InMemory+None-consumer" trap.
- EVM onlyHop/LP key born-in-enclave (`boot.rs:77-93`, `QUID_HOT_KEY` refused under SGX) — the old "foundational M11 gap" (operator-held plaintext) closed.
- Migration replay closed: 2-of-3 EIP-712, nonce consumed ON-CHAIN one-shot + agreement-reread; prod-guards wired at boot.
- EvmValidatingSigner is the sole prod signing chokepoint, allowlist DERIVED from `evm_codec` (no drift); MRENCLAVE-pins the EVM target.
- On-chain resolution witness CONSTRUCTION is fully P2TR (justice/HTLC/to_remote/anchor-CPFP), each with a passing sig-verifying test; CPFP + spendable weights are dynamic (M9e-4).

## 🔴 CONFIRMED (re-verified by hand)
1. **On-chain justice weight is a legacy P2WSH constant → `assert!` panic on breach.** `package.rs:120` `WEIGHT_REVOKED_OUTPUT=155` (P2WSH witness: 73-byte ECDSA sig + witnessScript), used unconditionally by `RevokedOutput::build` (`:170`, no `supports_simple_taproot()` branch). Real taproot script-path revoke witness ≈201 wu > 155. Feeds `onchaintx.rs:636 assert!(predicted_weight >= tx.weight())` (release `assert!`, not debug) on the malleable-package RBF path → panics instead of broadcasting the justice tx. Not caught by tests (`test_package_weight` covers only static-remote/anchors, never `simple_taproot`). FIX: taproot-aware weight in `RevokedOutput` (dynamic or a taproot constant) + a `simple_taproot` `test_package_weight` case.
2. **Attestation: TCB/CRL freshness unchecked + over-broad justifying comment.** `verifier.rs:440 revocation=None` (revoked PCK cert accepted); no cpusvn/TCB-level check (outdated-microcode platform accepted). Comment `:543-549` claims MRENCLAVE-pinning covers it — TRUE for ISVSVN/isvprodid (enclave-code, fold into MRENCLAVE), FALSE for CPUSVN (platform microcode) and PCK revocation. FIX: parse Intel TCB Info + CRL, gate cpusvn/tcbStatus; narrow the comment to ISVSVN only.
3. **`parkProvenSats` — supply side of the swap-in HTLC gate — has ZERO production callers.** Defined `BTCChannels.sol:1375`; referenced only in comments (`evm_codec.rs:118`, `swap.rs:31`); no `SIG_PARK`, no allowlist entry, no `evm_codec` calldata builder, no Rust caller (positive control: `settleSwapInProven` IS wired, `evm_codec.rs:110`). ⇒ `provenSatsAvailable[hop]=0` live ⇒ `settleSwapInBuffered` reverts `InsufficientProvenSats` on the first real LN swap-in; invoice path quotes without checking. LN buffered swap-in rail DEAD-ON-ARRIVAL (fail-safe, no fund leak). On-chain rail unaffected. Same family as the `create_sweep_tx`/vBTC-mint "on-chain built, Rust unwired" pattern.
4. **Split-brain after migration: old enclave's sealed seed is never deleted/tombstoned.** `ffs.delete` exists + used for monitor files, never for `SEALED_SEED_FILENAME` (`seed.rs`: read :97/187, write :179, no delete). Old box reboots → unseals same seed → two live signers → duplicate-commitment-broadcast risk. This is the gap `create_sweep_tx` (dead_code marker) tracks — KNOWN, still open. FIX: old enclave `ffs.delete(SEALED_SEED_FILENAME)` (or refuse-past tombstone) after confirmed transfer; + decommission runbook.

## 🟠
- Multi-TEE is PROVE-side only: `quid-cvm` generates SEV-SNP quotes (binds TLS-pk+EVM-addr, better than SGX's pk-only) but NO VCEK/ARK verifier exists and RA-TLS verifier is SGX-only → a SEV/TDX/Nitro node can attest but nothing can verify it over RA-TLS. (Sealing IS multi-TEE; RA-TLS trust is not.)
- On-chain HTLC package weights (`RevokedHTLCOutput`/`CounterpartyOffered`/`Received`/`HolderHTLC`) also P2WSH constants — safe OVER-estimate (fee waste), contradicts "no brittle taproot constants."
- No fallback punishment if a counterparty's revoked taproot 2nd-level HTLC tx confirms first (`channelmonitor.rs:5094-5126` detects+logs only, no justice package built) — self-documented; "covered because our commitment-level justice races for same UTXO" holds only if we win the race (offline/censored → no punishment).

## 🟡
- Secrets not zeroized on drop (`platform.rs:30-31` TODO; `derive_key_material` bare `[u8;16]`; `derive_eth_wallet_key` no Zeroizing) — defense-in-depth (EPC protects in-SGX).
- `pick_sealer` maps Tdx/Nitro→insecure mock; safety lives only in the `require_backend_for_role` call-site — refactor-fragile; make it structural.
- MigrationAuth/SweepAuth no expiry field; binds MRENCLAVE not instance (arguably intentional under SGX measurement-is-identity).
- report_data layout drift SGX[pk,0×32] vs SEV[pk,evm,0×12] — reconcile before a unified verifier.
- `quid-bridge/src/lib.rs:29-30` "Build status" UNDERclaims (drivers+rebalancer built).
- N-HTLC taproot on-chain-resolution tests are 1-per-test; anchor CPFP weight also a P2WSH over-estimate; deploy_env-mismatch reload test gap.

## Residuals from the known list — resolution at HEAD
#1 EVM-key-in-enclave RESOLVED · #2 rollback-freshness RESOLVED · #3 TCB/CRL STILL OPEN (🔴 above) · #4 migration replay RESOLVED (no-expiry 🟡) · #5 split-brain STILL OPEN (🔴 above) · #6 swap-in gate invariant RESOLVED but supply-side unwired (🔴 #3 above) · #7 seed rotation STILL OPEN/N-A (arch-hard).

---
# BTC "rest of surface" pass (2026-08-22) — NEW flaws only (SPRINT.md exclusion list applied)
5 auditors over BTCChannels / ChannelLib+BitcoinTx / SPV gateway / bridge+hop Rust / BTC-lev. Each held the
SPRINT.md §D2/§C2.3/§B exclusion list; criticals re-verified by hand. Result: **4 NEW findings** (3 confirmed by
my own read, 1 auditor-traced), none of which is an already-tracked TODO.

## 🔴 NEW-1 (highest severity, LIVE deploy path) — SPV checkpoint-epoch misalignment bricks the first retarget
`SPVGateway.__SPVGateway_init` accepts an arbitrary `blockHeight_` with **no `% 2016` alignment check**;
`_getEpochPassedTime` reads `getBlockHash(height−2016)`. For any non-aligned checkpoint H (the documented
860000-style recent anchor is non-aligned), the first boundary B after H needs `getBlockHash(B−2016)` with
`B−2016 < H` → unset → 0 → epochStart 0 → passedTime≈real-unix → clamp 4× → real header bits mismatch →
`_validateBlockRules` reverts → **gateway bricks at the first retarget (~832 blocks into the forward sync)**;
a cheap-PoW header matching the bogus eased target is a soundness break. Tests init at height 0 (aligned) →
uncaught. Distinct from the excluded E135 (burial depth / cumulativeWork). FIX: enforce `blockHeight_ % 2016 == 0`
at init, or seed the epoch-start block, or special-case the first post-checkpoint retarget. Hand-verified.

## 🔴 NEW-2 (confirmed, latent) — BTCChannels `poolSatsParker` cross-hop phantom
`parkProvenSats` accumulates `poolOwnedSats[cid]` but **overwrites** `poolSatsParker[cid] = msg.sender`
(`:1393-1394`); `_releasePoolSats` debits the full released amount from only the last parker
(`:1320-1330`). MAIN→FALLBACK failover both parking one channel ⇒ MAIN keeps a phantom `provenSatsAvailable`
→ credits sellers vs sats that left custody — the exact phantom the `_releasePoolSats` comment says it closed.
Latent (buffered rail unwired = excluded §LN-SWAPIN-REMAINDER; needs two-hop-same-channel + superseded hop
stays attested), but a landmine to fix BEFORE that rail goes live. FIX: per-(channelId,hop) parked ledger.
Hand-verified.

## 🔴/🟠 NEW-3 (confirmed, qualifies a "fork-proved" memory) — #54 delever withhold-vs-repay divergence
The called `swapOutDeleverAmt` resolves to the **inherited, unclamped** `LevBase.sol:217-224`; the
debt-clamped `BtcLevManager` override is a **dangling docstring with no body** (`:353-356`). `_sourceRepayFree`
withholds/sources `deLeverUsd6` (want-based) and **discards** `swapOutDelever`'s `(usedUsd,freedSats)`,
diverging from that function's own "withhold only usedUsd (debt)" contract (`:321-327`). At ~2× `want≈debt`
(≈neutral — why the fork test passed), but a pure-equity/off-target slice sources+withholds more than it
repays; excess stable sits at the venue, POOLED reconciled only async by keeper `syncLev`. Qualifies memory
`project-quid-54-delivery-side-delever` ("value-neutral, fork-proved" — proof covered only 2×). FIX: implement
the documented debt-clamp, or capture the returns and withhold `usedUsd` + mint the pure-equity remainder.
Hand-verified.

## 🔴 NEW-4 (auditor-traced; crux to confirm) — swap-out on-chain delivery double-pay
`deliver_swap_out`'s timeout calls `DeliveryCoordinator::cancel` (`vault.rs:371-374`) which only clears local
bookkeeping and **never aborts the LDK splice** already broadcast; the retry loop then pays the same
`sats`/`swapper_script` via another channel, or `reverse_swap_out_onchain` refunds USD — so a late-completing
splice yields BTC×2 or BTC+USD, plus a permanent per-channel reconciler desync (`ForeignSpliceOutput` revert
forever). The "retry is safe, each attempt is before its splice locks" comment conflates not-locked with
not-broadcast. Crux (cancel doesn't abort the LDK splice) is the auditor's end-to-end trace; confirm with the
vault-delivery owner. FIX: abort/RBF-cancel the splice on timeout before retry, or make retry/reversal
idempotent against a possibly-broadcast splice.

## CLEAN (modulo excluded)
- **ChannelLib + BitcoinTx** — FLAWLESS on a full line-by-line pass; only a low 🟡 *suspected* KeyAgg
  coefficient nit in the degenerate `lpPubkey==hopPubkey` case (fails-closed, bounded by the known E129).
- SPV PoW/nBits decode, retarget clamps, per-block cumulativeWork (single-global fix confirmed), reorg
  walk-back, merkle LE/BE + empty-proof reject — all sound.

## Everything else BTC-side that is open is already a SPRINT.md TODO (verified, not re-reported)
§LN-SWAPIN-REMAINDER/§NO-REJECT (incl. parkProvenSats unwired), §22 liveness gate, §LAZY-OPEN/B5, §E251/§C3/
§A.19b vBTC, §HANDOFF-SEED-THREAD (enclave-LP recovery / split-brain / monitor-dir backup), §LADDER-VALUE-IS-
CONDITIONAL, §V-R10 sUSDe, §V-R11 hedge, §E222/§E205 routing/tier, #59/#74 native acquirer, suite-state cluster,
§21 NotPubkeyHash fixture regression, and the SGX residuals (TCB/CRL, migration-expiry, secrets-zeroize, multi-TEE
RA-TLS verify). Plus this session's earlier 4 (justice-weight assert, TCB/CRL, parkProvenSats, split-brain).

---
# ASSUMPTION-DEPENDENCE CLASSIFICATION (2026-08-22, owner asked "consistent with the new architecture?")
Architecture per SPRINT.md: §M1#2 keystone — LP holds its OWN funding half, fleet runs vault-less (1a); LP-hosted
vault also supported (1b, quid-lp-daemon, LP seed, remote hop). SPV owns protocol; ibiza owns mobile producer +
social recovery + device lifecycle (§3b). ⚠️ Repo threat model is INTERNALLY CONTRADICTORY today (§C2.3②:
vault.rs:244 "fleet does NOT have the LP funding half" vs taproot_signer.rs:439 "fleet holds BOTH under Option B").

- ✅ TRUE REGARDLESS OF ANY ASSUMPTION (pure code/arithmetic): NEW-1 SPV retarget-brick; taproot #1 justice-weight
  assert-panic; NEW-3 #54 delever withhold-vs-repay. These stand unconditionally.
- ⚠️ ASSUMPTION-DEPENDENT: NEW-2 poolSatsParker — reachability needs (a) buffered rail wired [it isn't], (b) TWO
  attested hops parking the SAME channel, (c) superseded hop stays attested. Under single-fleet/vault-less this may
  be UNREACHABLE, not merely latent; it rides on the unresolved §C2.3② threat model. Re-classify: "fix ledger to
  per-(channel,hop) BEFORE wiring the buffered rail / adding a 2nd hop," not a confirmed live bug.
  NEW-4 swap-out double-pay — the LP-hosted-vault topology that makes it reachable IS supported (SPRINT 1b), so the
  assumption holds; but the crux (cancel() doesn't abort the LDK splice) is auditor-traced, not hand-verified — confirm with the vault-delivery owner.
- 🔵 CLIENT-OWED (ibiza, not SPV flaws): lost-phone/key/social recovery + device lifecycle (§3b) + NAT consent-push.
  Split-brain's REMEDY overlaps this; the SPV-side gap (fleet-enclave migration doesn't delete old seal) stays SPV (§D2#14/#15, create_sweep_tx).

---
# ADVERSARIAL-CLASS SWEEP (2026-08-22 @e21bad4a) — attack-class lens (reentrancy/MEV/griefing/oracle/SPV/sig-auth)
6 auditors by ATTACK CLASS (not area), everything already-found excluded. 3 confirmed 🔴 + 1 suspected 🔴 + 1 🟠 + 1 🟡.
- 🔴 §AUDIT-DELIVER-KEYS (auth, HAND-VERIFIED): `deliverSwapOutOnchain`/`_deliverSwapOut` (BTCChannels.sol:2258-2341) omits `_requireChannelKeys` that splice(:1126)/parkProvenSats(:1384)/emitDeadManExit(:1559)/recordClose-retire(:1814) all have. `_verifySplice`'s only key check is `isTwoOfTwoOutputKey` on the CALLER-SUPPLIED pair (:1694; comment :1676-1681 says so). ⇒ a malicious hop rotates the channel's funding output to Q'=KeyAgg(fakeLP,fakeHop) under cover of a delivery → custody migrates off the LP; close mints QUID vs stolen notional. Reachability rides on §C2.3² but it's a defense-in-depth consistency gap by the code's own standard. FIX: add `_requireChannelKeys(channelId,p)`.
- 🔴 §AUDIT-PUSHOBS (oracle, HAND-VERIFIED mechanism): `Core.pushObservation` (Core.sol:1374) is permissionless + instance-agnostic (no modifier, no observationSource guard, isWbtc DERIVED) → reactivates the BTC ring the "ring is simply not written" safety (Core.sol:1229) assumes dead. Biases ring ≤50bps/block; within the 500bps window `getTWAPforAsset(WBTC)` returns the manipulated ring → `RealRateBtcMorphoOracle.price()` (LevBase.sol:534) → mis-liquidation (rescue underwater / snipe healthy), gas-only, ~5%-bounded. FIX: gate `pushObservation` to `observationSource!=0` (keep the BTC ring dead) or to the ETH instance.
- 🔴 §AUDIT-OPENLPS-DOS (griefing, HAND-VERIFIED crux): `_openLps` (LevBase.sol:76, shared by both lev mgrs) unbounded + attacker-growable (MIN_OPEN_VBTC ~$30-50 × N EOAs, recoverable). `deleverEthOnDelivery` (SwapLib.sol:1830-1858) loops i<openLevCount() with no outer bound → OOG bricks the ETH swap-out liquidity-crunch fallback; same array's `catch{}→0` in `Core._levDebtUsd18`(:143)/`Quid._venueBalance`(:960-967) fail-OPEN → phantom yield credited to plain LPs. Generic "_openLps unbounded" ~ SCAN §1.B/L19680; hard-DoS + phantom-yield-flip are new. FIX: cap the book / bound+paginate / cache aggregates.
- 🔴(suspected) §AUDIT-SWAPOUT-CONCURRENT (MEV; COMPANION to the bridge double-pay): two authorized hop instances (MAIN+FALLBACK, normal HA — `_onlyHop` accepts either on ANY channel, no cross-process swapId lock in `swap_out_onchain.rs:180-314`) both deliver one swapId via DIFFERENT channels → swapper paid 2× on Bitcoin; only the first `deliverSwapOutOnchain` lands, the losing channel is left PERMANENTLY UNRETIRABLE (`_withdrawalPayout` ForeignSpliceOutput / `_requireNotSplice` SpliceIsNotAClose / `recordForceClosePermissionless` NotForceClose all reject the abandoned splice shape) holding phantom backing. Distinct root cause from the timeout/cancel double-pay (no timeout needed). FIX: serialize swap-out delivery per swapId across hops before the Bitcoin broadcast; make the losing channel reconcilable.
  ⇒ **RE-GRADED 🟠 2026-08-23 — SPRINT.md's row is the record; do not re-rate from this line alone.** Summary: the EVM half of the premise holds (`_onlyHop` accepts either address; the dedup is per-process), the Bitcoin half does not — rail B needs the fleet's own `VaultNode` to co-sign the splice, and vault seed and hop EVM identity both derive from `root_seed`, so two distinct hop addresses cannot share LP-side channel keys. Reachable only when `QUID_HOT_KEY` overrides the derivation off-SGX with one shared `root_seed`, which is two LDK nodes on one channel state — independently catastrophic. Root fix: bind the co-hosted vault to the DERIVED hop address. Full evidence with line numbers in `SPRINT.md`.
- 🟠 §AUDIT-REORG-DOS (SPV): `_updateMainchainHead` (SPVGateway.sol:314-350) fork-switch walk-back is O(depth) SLOAD+SSTORE in one atomic, permissionless, unchunked tx → a deep (>~1-3k block) divergence adopted first → tipping header always OOGs → gateway frozen forever on a stale chain. Distinct from the retarget bug + E135. FIX: max-reorg-depth cap or chunked/resumable switch.
- 🟡 §AUDIT-REENTRANCY-GAP (latent): `Vault.creditSwapIn/creditSwapOut`(:702/714)+addLiq/repack lack nonReentrant; `Core` has NO ReentrancyGuard; only BTCChannels' lock spans the nested creditSwapIn→Core.swap→AUX.take path. NOT live (all basket stables plain ERC20/4626, vBTC no hooks); Aux.sol:1118 comment is false. FIX: add nonReentrant before any hookable stable is added.
- RULED OUT (adversarial, verified sound): TWAP/skew single-block sandwich (onlyUs ring, oracle-anchored, ≤500bps Chainlink-clamped); CVE-2017-12842/2012-2459 merkle (defended/moot); low-diff header injection (target==blockTarget); most reentrancy (BTCChannels all-guarded, venues onlyManager+nonReentrant, Morpho flash correctly unguarded).
