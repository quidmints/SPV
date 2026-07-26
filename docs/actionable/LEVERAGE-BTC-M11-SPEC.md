# BTC leverage — surviving open items (M11)

**Status:** NEARLY ALL BUILT. This file has been pruned to the genuine residual. The original 2026-07-11
spec (net-new `vBTC` token minted against SPV-proven custody, async `BtcLevVenue`, keeper-as-sole-liquidator,
LN↔EVM bridge) is **superseded** — see `LEVERAGE-COLLATERAL-ROUTE-SPEC.md` (WBTC/SOR spine + native-preferred
router) and memory [[project-quid-67-surplus-redemption-only]], [[project-quid-vbtc-samebtc-leverage]].

## What is already built (do NOT re-spec)
- **SGX core** — born-in-enclave seed, `EGETKEY` sealing, DCAP/RA-TLS, Safe-authed migration, taproot signing.
- **BTC auto-protect** (`protectFromQuid`, commit `c7d5727`) — asset-agnostic `LevMath.protectExec`; keeper
  counterpart `lev_keeper_btc.rs::protect_from_quid` live.
- **WBTC-mode leverage** (#90) — `BtcLevManager.rebalanceWbtc` atomic fold-up / flash-repay-first de-lever on
  a real Morpho {USDC,WBTC} market; keeper-driven via `PositionView.wbtc_mode`. Fork-proven
  `VBtcLevFeeLane.t.sol::testReal_WbtcLev_FoldUp_Then_FlashDelever`.
- **Native vBTC same-BTC overlay** — `vogueBTC` solvency term (WBTC-only), `syncLevBTC`, `levPooledBTC`,
  `Vault.vbtcExpose/vbtcUnexpose` (funded↔lev, single-count, no mint roundtrip). `netEquityBtc` paired into
  `POOLED_BTC`.
- **Venue pin-once** — `BtcLevManager`/`LevManager` allowlist is set-once-via-`init`-then-frozen
  (`venuesFrozen`), NOT a rotatable governance setter. (Closes the old §4.2 open decision.)
- **#67 deliverability** — CLOSED, no de-lever-into-pairing build (redemption-backing-only; the surplus addend
  was built-then-reverted). `deliverableDollars`/`totalDeliverableDollars` views kept as the sizing primitive.

## Genuinely OPEN (BTC-native-mode only)
1. **Native BTC sourcing / acquirer rail (#59 / #74).** WBTC mode is the workhorse; the native-mode acquire
   (source real BTC externally → dedicated enclave-custodied UTXO → expose) and native-mode de-lever legs are
   **stubbed** in the keeper (`lev_keeper_btc.rs::UnwiredNativeAcquirer`, both methods `bail!`; wired in
   `daemon.rs` as a fail-safe — WBTC positions never touch it, native positions fail SAFE). Real native
   acquirer = the well / native rail (see `BTC-MARKET-MAKING-SPEC.md` + `LEVERAGE-COLLATERAL-ROUTE-SPEC.md`).
2. **Native force-close LLTV buffer vs Bitcoin-confirmation latency (data gap).** For the native path a
   force-close cannot finalize until Bitcoin confirms (potentially hours), so the keeper-trigger LTV must sit
   far enough under the venue LLTV to cover close-confirmation latency. Sizing this needs a **measured
   channel-close-time distribution** — the one genuinely BTC-specific risk parameter still unmeasured. (Does
   NOT apply to WBTC mode, whose de-lever is atomic.)
3. **Freeze `levPooledBTC` fee accrual during a pending native force-close** (clean-up; the unwind-only
   property bounds it either way). Only relevant once native-mode force-close exists.
