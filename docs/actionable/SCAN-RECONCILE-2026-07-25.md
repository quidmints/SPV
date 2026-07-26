# Deep whole-turn scan reconciliation (2026-07-25) — session ad2385ae

> **✅ MIGRATED 2026-07-25 → `BUILD-QUEUE-AND-107.md` §V** (consolidated with the sibling 4fbacebd sweep): §2A net-new → §V.8, §2B stale-corrections → §V.9 (+ memories `m11-scope`/`multihop-swapin-sgx-residuals` corrected), the 12 overlaps collapsed in §V.7, §2C already-tracked NOT re-added, §0 overrules honored. This file is now the **ad2385ae audit trail only** — do NOT migrate it again; work the backlog from §V.

Method: 10 agents read every assistant turn (text + thinking) of the 78MB session prose (710k tok), each finding tagged with transcript line `L<n>`. Synthesis is **reverse-chronological**: a later turn/commit/user-overrule kills an earlier note. This file = STAGING. Nothing migrates to `BUILD-QUEUE-AND-107.md` until each survivor is grep-checked vs the canonical doc + `main` (drop already-tracked / already-done). `done-in-slice` + `superseded-by` items are dropped silently.

## 0. KILLED BY USER-OVERRULE — never resurface as TODO
- IL-elimination / YieldBasis / leverage-based IL levers; repack-hysteresis-as-free-win (L13448, L14220, L19339, old NOW-TODO#5)
- xStock / Kraken-pairs "generalize Vogue to N pairs" (L19339 "forget all this")
- CRE stable-depeg oracle — REMOVED entirely; setStableFeed/bindStableFeedFromRegistry gone (L7392, L7356)
- Force-close as recovery — DELETED; cooperative-only, LP waits if hop offline (L8212, L8284)
- Multisig/governance framing — "there is no governance, one-time msig"; single-EOA owner accepted (L15644, L16125, L19901)
- WBTC-backed vBTC framing — "register OUR OWN representation," no LBTC/cbBTC analog (L19468, L19585)
- Dashboard **subgraph** (L16205); family-plan **as a product tier** (L31462, keep code path only)
- SPV raw-PoW/nBits extra fixture tests (L6144 "nah"); BOLD depeg finding (L6220)
- EC-link in Solidity openChannel Finding C (L20783 → deferred to M11 SGX)
- settleSwapIn net-exposure cap (L20932 — breaks settle-then-claim)

## 1. SURVIVING OPEN CANDIDATES (verify vs doc+code before migrating)
Tag: [NEW?]=likely not in canonical · [TRK?]=may already be §A/§DR/§S/memory · [DONE?]=may be fixed on main · [VERIFY]=intent/status unclear

### A. SGX / M11 / attestation (newest slices 06/08/09 — freshest truth)
- from_identity: SGX reportData binds only cert_pk[0..32]; add evm_addr[32..52] like SEV (L31651) [NEW?]
- Attestation dispatch dead: attest_identity/sev_report/identity_report_data zero live callers; wire RA-TLS handshake (L30956,L31651) [NEW?]
- splice not `_requireAttested`-gated (recordClose participant-gated BY DESIGN; drawPooledUsdBtc Core.onlyUs) — confirm splice intent (L31651) [VERIFY]
- AttestedHopRegistry NOT deployed/wired in DeployL1_s; no real Automata verifier/Safe addr; `_parse` offsets unpinned (L31206, Solidity-agent-confirmed) [NEW?]
- SGX identity-quote → registerHop client flow (hardware-tail) (L31206) [NEW?]
- Reproducible build → deterministic MRENCLAVE (sgxs-hash recipe) (L31206) [NEW?]
- Client-side CVM attestation verification (virtee/sev verify feature) (L30956) [NEW?]
- TDX seal (tss-esapi vTPM) — infra-blocked; Nitro seal (KMS, cloud) — custody_ready=false (L30956) [TRK? status-report]
- **Seed cold-backup + hot-standby replication** — own-hardware-death strands funds; MANDATORY-before-custody, UNBUILT (L31675) [NEW? high]
- Contract-addr+chain-id: swap dev placeholders (0x…dEaD/chain1) → real pre-mainnet (L31637) [TRK? DR]
- ValidatingChannelSigner policy gating EVERY taproot op in-enclave (item 12, unchecked) (L31637) [VERIFY]
- Phase-5 ops (MANDATORY): external watchtower for offline nodes; Bitcoin anti-eclipse asmap.dat+addnode; LP always-on availability (L31637,L16832,L1417) [NEW?]
- SGX-target job in CI build matrix (fork drift can't silently rot) (L29665) [NEW?]
- Runtime-on-SGX audit: net path, every money-critical persist = sealed-storage not std::fs, process::id (L30707) [NEW?]
- detect_host CPUID/MSR cross-check (device-node-only today) (L30417) [NEW? minor]
- DCAP TCB freshness/revocation unchecked: verifier.rs:541-543 no cpusvn/isvsvn/isvprodid; TCB/CRL=None (L28076,L20620) [NEW?]
- Split-brain: same seed provisionable to two enclaves, no single-writer/shared-counter (L20620) [NEW? relates hot-standby]
- LP-daemon on-chain anti-rollback: InMemoryFreshnessAnchor + None nonce consumer; per-(cid,lpEth) counter + funded-send client UNBUILT (L28474,L23916,L23920) [NEW?]
- platform.rs seed/sealing key material not zeroized (ring limitation) (L20620,L15077) [NEW? minor]
- InMemorySigner raw-taproot has NO nonce-reuse guard (guard only in wrapper — defense-in-depth) (L22725) [NEW?]
- record_secret_release/release_commitment_secret no cross-check vs highest-signed-index after restart (L22744,L15466) [NEW? d-in-d]
- Entropy RDRAND-only; no RDSEED reseed / mixed pool (optional hardening; memory says entropy SAFE) (L27245) [NEW? minor]
- migration-auth nonce/epoch/expiry + bind successor INSTANCE not just measurement (L25470,L22131) [DONE? memory says anti-replay nonce built — verify]
- QUID_SEED env import auth gate (L25470) [DONE? guard_prod_trust_anchors — verify]
- Doc-stale: PRODUCTION-LAUNCH.md:103 marks rollback-freshness "optional" (it's built+wired); config.rs:240 "architectural residual" (guard now supplies binding) (L31646) [NEW? doc]

### B. Leverage (ETH) audit residuals (slice 06 — many done-in-slice; these left open)
- Root B: kill GOV venue-setter, immutable-pin adapters ("main unfinished by-construction item") (L20426) [VERIFY vs lev memories]
- openLev borrow loop dead/unreachable; drop loop + minWethOut param (L19669 H1) [DONE? acquirer superseded — verify]
- unbounded _openLps loop in vogueETH() → gas-griefing DoS; cap book / min-collateral (L19680) [NEW?]
- 255 sub-account exhaustion griefing on Euler venue (L19682) [NEW?]
- anti-MEV floor priced off internal band oracle, executed on real Uniswap (L19682) [NEW?]
- MED-6 keeper pins venue_liq_ltv_bps const; read liqThresholdBps() per-position (L19835) [NEW?]
- MED-9 Morpho pre-accrual understates debt; keeper-side accrue (L19835) [NEW?]
- live net-equity vs stale levPooled desync misprices honest LPs; permissionless syncLev at oracle-high pins inflated levPooled (L19859) [NEW?]
- deliverable_floor_ok hardcoded true in prod (documented bound non-functional) (L19669) [NEW?]
- entryPriceWad pinned at openLev not band-entry → directional-long basis (L19889) [NEW?]
- no on-chain invariant tying TARGET_LTV_CAP_BPS to venue liqThresholdBps (L19889) [NEW?]
- simplify: KeeperAction to_ltv/il_target dead; unused iface members (ISwapAux.swap/IEVC/accrueInterest/IERC20S); redundant SLOAD net-equity loop (L19669) [NEW? simplify]
- closeLev try/catch(syncLev) reintroduces stale-fee MED-4 on forced revert; emit event to auto-poke (L19881) [NEW?]

### C. Rust robustness (slices 04/07/08)
- no concurrency cap on reversal task fan-out (swap-out pays are capped ≤30, reversal isn't) (L15051) [NEW?]
- inflight_swapins fsync write-amplification of ever-growing Persisted blob per swap-in (L15051) [NEW?]
- on-chain watcher handled/paid dedup maps never pruned (L15051) [NEW?]
- adopt quid_tokio::LxTask supervision instead of raw tokio::spawn/JoinSet (reuse gap) (L22937) [NEW?]
- quid-hop dropped check_channel_configs → config bump won't propagate to open channels (L22937) [NEW?]
- funding_vout u16 / tip u32 silent narrowing; merkle_branch assert-on-esplora-data (fail-safe cleanups) (L15497) [NEW? minor]
- Event::DiscardFunding swallowed by other=> arm; add log (L28474) [NEW? minor]

### D. Bridge / swap-out finality (slices 01/03/07)
- **swap-OUT finality B-1**: single-endpoint, no burial re-check, asymmetric with swap-IN (other-thread Rust domain) (L7223,L13502,L15466) [VERIFY other-thread]
- EvmObligationReader (F3-LP) left first-healthy — scoped residual, LP's own RPC (L24430) [NEW? accepted?]
- lpFeePaid confirm-depth 6 < ETH finality → reorg+re-pay double-pay (documented LOW) (L25454,L26167) [NEW?]
- LP swap-out obligation read un-agreed + circular cross-check (M-1) (L25454) [NEW?]
- no cap on inbound channels from LP peer (resource exhaustion, MED-3) (L25470) [NEW?]
- SPV-1: lastEpochCumulativeWork single-global → fork-choice mis-accounting across epochs (MED) (L13501) [NEW?]
- confirmed-then-reorged permanently trusted (no isInMainchain re-check) — RISK-ACCEPTED SPV 6-conf; documented (L13502,L14126) [TRK? accepted]

### E. Gas dedup (slice 05 — deferred tail)
- redeem sweeps every 4626 twice (illiquidLoss + refreshAllHoldings); auxSwap 2× get_deposits; mint 2× get_metrics (needs return-plumb) (L8108,L19044) [NEW? low]
- spreadEquallyBody two-pass vaultHealth[].blocked SLOAD (optional low) (L19231) [NEW? low]
- SOR failed attempts pay full 4626 redeem + V4 swaps before revert (L17963) [NEW?]

### F. Dead-code prune (slice 02)
- 8 orphaned BitcoinTx script-builders + 6 commitment builders — force-close DELETED, so confirm truly dead vs used by #114 dead-man-exit, then prune (L8116,L8135) [VERIFY]
- targetToBits dead (inverse of live bitsToTarget); IERC3009 gasless USDC path dead (AA decided) (L8121) [NEW? verify]

### G. Config / PKI hardening (slices 00/07)
- lexe_ca.rs hard-references Lexe's CA constants — un-migrated trust root (misconfig Staging/Prod trusts Lexe infra) (L108,L22917) [NEW?]
- esplora url whitelist never enforced: url_is_whitelisted exists, never called (clamp applied, whitelist not) (L2377) [NEW?]

### H. Test / CI infra (recurring — many CI-gated)
- Slither into CI; Echidna coverage-guided fuzzing; forge invariant tests (D≥S+L, POOLED==realized, only-hop-settles, rounding-against-caller) (L30003) [NEW?]
- driver-e2e.sh into CI (real-LDK-vs-contract regressions) (L13318) [NEW?]
- cross-chain forge tests vm.skip()→GREEN in CI verifying nothing (real hazard) (L1760) [NEW?]
- month-12-warp maturity test (L8210,L16832) [NEW?]
- **External independent security audit** — single biggest gap, non-negotiable pre-mainnet (L16832,L17096) [TRK? likely noted]
- Formal verification of core invariants; MEV/game-theoretic swap-path modeling (L17096) [NEW?]
- LN e2e gaps: crash-recovery mid-swap, multi-channel/multi-LP P&L (>1 channel), liquidity-exhaustion + reorg sim, daemon::run full-boot, two-node open round-trip, production soak w/ fault injection (L207-221,L3407,L3556,L16994) [NEW? CI-gated]
- Lev: closeLev untested; fork tests never hit real venue-oracle liquidation/isolation (L19669) [NEW?]
- BtcLevKeeper anvil harness (markMigrationNonceUsed unexercised) (L27833) [NEW?]
- Rover coverage thin (1 test vs old 7) (L4657) [NEW?]
- H-1 payer-namespace feeId Solidity+e2e verification (was queued behind other thread) (L25873) [DONE? verify]

### I. Doc-stale / cleanup
- AUDIT-TODO.md stale + misleading (refresh/archive; user: "old folder" Link/L2Basket moot) (L30003) [NEW?]
- OFFCHAIN-STRATEGIES.md stale (taproot/M9 refresh) + move quid-ln/ → top-level docs/ (L17872,L19071) [NEW?]
- PRODUCTION-READINESS.md stale (predates bridge-daemon+splice) (L6423) [NEW?]
- BtcLevManager.sol:176 docstring "1e18" wrong (returns 8-dec sats); channel_driver.rs:255 "5 words"→6; ILevVenue vETH/dust doc-rot; lev M4 L=1/α stale narrative (L27833,L19669) [NEW? cosmetic]
- untouchables→tranche rename (~72 uses, behavior-preserving, no committed plan) (L19810) [NEW? verify done]

### J. Open design forks (need a decision — NOT killed)
- **LP-initiated splice / withdrawal production trigger** — initiate_splice test-only; Rail B env-gated not prod-enabled; "the one production splice gap" (L6703,L6810,L8306,L16832) [NEW? high]
- BTC IL-protect / internal vBTC 4626 surface: build vBTC ERC-20+4626 w/ manip-resistant convertToAssets; MorphoBtcVenue/EulerBtcVenue adapters + createMarket; LLTV-vs-channel-close-latency knob; register own BTC representation as collateral (L19398,L19474,L19584,L19592) [VERIFY vs BTC-lev memories — much may have landed]
- Basket auth renounced: atomic-launch vs surviving-registrar; btcShareBps medianiser global not per-Aux (L19246) [NEW? design-q]
- IL-recovery re-entry strat → OFFCHAIN-STRATEGIES.md opt-in probe (L17743) [NEW? low]
- migration two recovery modes: migration (seed intact) built; **rotation (seed exposed / key-compromise) ABSENT** (L20449,L20527) [NEW? — is this = seed-replication or distinct?]

### K. The "it's not launch phase only" note (user-flagged)
- Grep prose for exact "launch phase" context; user believes it's false (permanent product). RESOLVE. (L31816) [ACTION]

## 2. RECONCILED VERDICT (all 11 agents in; doc + 105 memory files + deploy docs cross-checked)

**Headline: almost nothing was lost.** The canonical doc (§A–§T, §S40) + the 105 memory files already
track the overwhelming majority of every candidate above. The whole-turn scan's real yield is (a) a
MODEST net-new residual, and (b) — more valuable — a few STALE tracked-items this thread SUPERSEDED
(the reverse-chron catch that prevents phantom rework). §K "launch phase only" = NON-ISSUE (misread of
me sequencing agents, "launch phase 2"; no product note exists).

### 2A. NET-NEW — surfaced here, NOT in doc/memory, not overruled, not done → migrate
- esplora `url_is_whitelisted` exists but is NEVER called (fee-rate clamp applied, whitelist not enforced) (L2377) [Rust sec]
- Reversal task fan-out has NO concurrency cap (swap-out pays capped ≤30; reversal unbounded) (L15051) [Rust robustness]
- `inflight_swapins` fsync write-amplification (fsync-per-swap-in of an ever-growing Persisted blob) (L15051) [Rust perf]
- On-chain watcher handled/paid dedup maps never pruned (unbounded growth if a sibling swap stays stuck) (L15051) [Rust leak]
- `funding_vout` u16 / `tip` u32 silent narrowing; merkle_branch assert-on-esplora-data (fail-safe hardening) (L15497) [Rust minor]
- `Event::DiscardFunding` swallowed by `other=>` arm — add a log for LP operability (L28474) [Rust obs]
- Gas dedup NOT in §O: redeem sweeps every 4626 2× (illiquidLoss+refreshAllHoldings); auxSwap 2× get_deposits; mint 2× get_metrics (return-plumb); spreadEquallyBody 2-pass vaultHealth SLOAD (L8108,L19044,L19231) [EVM gas, low]
- SOR failed attempts pay a full 4626 redeem + V4 swaps BEFORE reverting (wasted gas on a losing path) (L17963) [EVM]
- **cross-chain forge tests `vm.skip()` → GREEN in CI verifying nothing** (real false-confidence hazard) (L1760) [test]
- `splice` NOT `_requireAttested`-gated — 2 of 4 hop actions ungated (recordClose participant-gated by-design; confirm splice INTENT) (L31651) [attestation — VERIFY]
- `lexe_ca.rs` still hard-references Lexe's CA constants (un-migrated trust root; a Staging/Prod misconfig trusts Lexe infra) (L108,L22917) [config/PKI — borderline vs lexe-reuse-audit]

### 2B. STALE tracked-items this thread SUPERSEDED — CORRECT so they don't cause phantom rework
- memory `m11-enclave-build` + `multihop-swapin-sgx-residuals`: "EVM onlyHop key operator-held plaintext / move into enclave (highest-leverage M11)" → **DONE** born-in-enclave, sealed, env-refused-in-SGX (commit 7f1d840). Update both memories.
- memory `onchain-swapin-design`: "HIGH-1/#77 AttestedHopRegistry NEVER wired into BTCChannels — does ZERO work" → **STALE**: now WIRED + governance-armed (openChannel/settleSwapIn/emitDeadManExit via `_requireAttested`/`_authorizedHop`). Only DeployL1_s deploy-wiring + `_parse` offset-pinning + real Automata/Safe addrs remain. Fix the memory (already fixed in `onchain-hop-attestation` §RESIDUALS #1).
- memory `audit-pass`: "LINK onGovernanceReport arbitrary-call + vault-watcher" → **MOOT** (user L30005: old folder, no LINK/L2Basket in current tree).
- Multi-TEE landed since "SGX CORE": SEV-SNP custody, boot-policy fail-closed, EvmValidatingSigner, CVM attestation+measurement (commits 77fb9ed/b43beb6/0b5e31c/071cabb/ea360f9/583ae0f/755d19c). `m11-scope` "SGX CORE COMMITTED" understates it.

### 2C. Already tracked (confirmed — do NOT re-add). Representative homes:
- SGX/M11 residuals (rollback-freshness, migration-auth replay, TCB/CRL, seed rotation+split-brain, placeholders, identity-quote, reproducible build, TDX/Nitro, ValidatingChannelSigner): memories `m11-scope`/`m11-enclave-build`/`multihop-swapin-sgx-residuals`/`onchain-hop-attestation`/`taproot-nonce-reuse-critical` + `deploy/PRODUCTION-LAUNCH.md` Phase-0/5.
- Seed cold-backup + hot-standby replication: `PRODUCTION-LAUNCH.md:75-77,99,124` (MANDATORY) + memory `sgx-signer-scoping`.
- Watchtower / anti-eclipse asmap / LP always-on: `PRODUCTION-LAUNCH.md:73-80` + memory `ln-attack-surface`.
- Lev-audit cluster (_openLps DoS, 255-sub griefing, MED-6/9, closeLev untested, dead openLev loop, doc-rot, minOut=0 MEV): memories `il-elimination-yieldbasis`/`yb-leverage-resolved-design`/`btclev-keeper-audit-handoff`/`lev-audit-backlog`.
- Rust reuse gaps (LxTask, check_channel_configs, BridgeStore preimage, anti-rollback resolver): memory `lexe-reuse-audit`.
- LP-initiated splice/withdrawal trigger + Rail-B prod-enable: memories `swapout-lightning-gap`/`btc-lp-native-fees`/`ln-rebalancer-htlc-limit` + doc §N.
- swap-OUT finality B-1 / SPV fork-choice: memory `seam-bugs-crossside` + doc DR/§A.
- CI/Slither/Echidna/Puppeteer/month-12/external-audit/formal-verify/MEV: doc §C#20/#21, §H, L176-179.
- targetToBits/IERC3009/dead digests/settleSwapIn nonReentrant: doc §P.3c/§R/§O + memory `audit-pass`/`lp-delegation-B`.
- BTC vBTC-4626 / IL-protect / venue adapters: memories `vbtc-samebtc-leverage`/`yb-leverage-resolved-design`/`67-surplus-redemption-only` (much LANDED; heavy overrule history in §0).
- Force-close deleted → 8+6 BitcoinTx builders: KEEP (reused by #114 dead-man-exit, doc §N) — NOT dead.

### 2D. Migration plan (pending user OK — canonical doc untouched until then)
Append ONE new dated section to `BUILD-QUEUE-AND-107.md` (e.g. §S41): the 2A net-new list + the 2B stale-corrections. Do NOT duplicate 2C. Keep this staging file as the audit trail.
