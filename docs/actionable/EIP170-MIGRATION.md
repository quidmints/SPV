# EIP-170 DURABLE MIGRATION — "the last refactor" (2026-07-25)

**GOAL:** every DEPLOYED contract/library under 24576 B with enough headroom that ALL
remaining BUILD-QUEUE work fits without re-breaching. Not a byte-shave — a structural
change + a guardrail so the treadmill ends.

**METHOD constraint:** verify every step via artifact-size reads
(`jq -r .deployedBytecode.object out/<C>.sol/<C>.json | (len-2)/2`), NOT `forge --sizes`
(thrashes the 3.5 GB box). One big-box `forge test` at the very end — behavioral T1 + the
whole committed batch can only run once everything DEPLOYS.

## MEASURED START (fresh `forge build`, 2026-07-25)
OVER: **BtcLevManager 25043 (+467)** · **Core 24954 (+378)** · **LevMath 24776 (+200, lib)** · **SwapLib 24733 (+157, lib)**
NEAR (<2 KB): LevManager 23725 (851) · Vogue 23556 (1020) · Aux 22590 (1986) · BtcVaultLib 22579 (1997, lib)
(Test/script contracts show 400 KB+ — NOT deployed, irrelevant.)

## WHY SHAVING FAILS — the pending queue loads the already-full contracts
| Contract | Pending BUILD-QUEUE features that GROW it | ⇒ needs headroom |
|---|---|---|
| **Core** | #12 unify-POOLED, #100 pump/skew, #107 θ-metric, #108 deferred-deliver, #101 guard | ~2.5–4 KB |
| **SwapLib** | #100 premium, #101 guard, #110 partial-fill ladder, #85 short-collat | ~2 KB |
| **BtcLevManager** | #106 venue layer, #108 deferred-deliver, #85 de-stack | ~1.5–2 KB |
| **LevManager** | #106 venue layer, #109 cover-levers-inline, #85 | ~1.5 KB |
| **Vogue** | #107 θ, #109, #110 | ~1 KB |
The 5 hottest contracts each carry 3–5 pending features. **HEADROOM TARGET (derived): Core & SwapLib ≤ ~20,500; BtcLevManager/LevManager/Vogue ≤ ~22,000; everything else ≤ ~22,500.** That's the "fits all of BUILD QUEUE" budget.

## PHASE 0 — REMOVE (R-scan; free bytecode, zero risk) — verify + size-read
- R1 `FeeLib.calcFeeL1WithLookup` — already gone; drop the stale `SOR.sol:359` comment ref.
- R2 `FeeLib.MONTH` — already gone; confirm.
- R3 `VaultHealthCfg.aaveSpoke`/`.wethReserveId` dead fields — remove if present.
- Grep-sweep any other zero-consumer dead code (fns/vars/errors/events/consts).

## PHASE 1 — DEDUP (U-scan; each removes N-1 copies → relieves MULTIPLE contracts at once)
Only the ✅-clean ones (skip ⚠️ surface-first U6/U7/U9/U10 and 🛑 keep-divergent):
- **U0 `plainNet(pooled,lev)` ×8** (Vogue×4, VogueLib×2, Vault, BtcVaultLib) → one `LevMath.plainNet`. Relieves Vogue + Vault + BtcVaultLib + VogueLib. **HIGHEST** (safety + spread).
- **U3 skew-premium retain ×3** (SwapLib) → one `retainSkewPremium`. Relieves SwapLib (OVER).
- **U5 `resolveV4Price` ×5** (SwapLib) → one helper. Relieves SwapLib (OVER).
- **U1 QD-share-value** (redeem → `ShareMath.qdShareValue`), **U2 depeg-loss** (one `applyDepegHaircut`), **U4 depeg gross-up ×3** (FeeLib → `grossUpForDepeg`). Relieve SwapLib/BasketLib/FeeLib.
- **U8 `TARGET_LTV_CAP_BPS` literal** (LevManager+BtcLevManager) → `LevMath` const. Relieves both.

## PHASE 2 — EXTRACT (residuals with no dedup relief — measure, then move a cohesive body)
- **Core (+378, no dedup relief; needs ~3–4 KB for its 5 pending features):** new `CoreLib` (delegatecall) — extract cohesive bodies, measured biggest-first (candidates: TWAP/observation seeding, pending-swap-out accounting, outOfRange settlement math). Target Core ≤ ~20,500.
- **LevMath (+200, already a lib):** split BTC-specific math into `LevMathBtc` so ETH/BTC lev math each have their own budget.
- **BtcLevManager (+467 after U8; +1.5 KB pending):** extract close/delever bodies to `BtcVaultLib` (has room after U0) or a new `BtcLevLib`.
- **SwapLib (after U3/U5):** if still near, move a swap body into `BasketLib`/a `SwapLib2`.

## PHASE 3 — GUARDRAIL (the "never again")
- `evm/script/check-sizes.sh`: reads `out/*.json` `deployedBytecode`, FAILS if any DEPLOYED contract > TARGET (per-contract targets above). Wire into pre-commit / the build step.
- RULE: new logic goes into a library BY DEFAULT; the god-contracts are frozen at their post-migration size. Record the post-migration baseline table here.

## SEQUENCE & VERIFICATION
Phase 0 → size-read → Phase 1 (one U-item at a time, size-read after each) → Phase 2
(one extraction at a time, size-read) → all under target → Phase 3 guardrail → **big-box
`forge test`** (first time the committed batch + T1 can execute). Commit per phase.
