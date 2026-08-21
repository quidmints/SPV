> ⚠️ STATUS (2026-08-01, re-verified against the contracts): PARTIALLY-STALE. The empirical findings here (no external LVR, IL is impermanent and realized at withdrawal, K measurements, conservation) remain valid on their own terms. The design conclusions tied to arbETH/R2 ("protocol self-provides liquidity from backing and eats IL") are OVERRULED: arbETH/refillETH are REMOVED and the IL-protect is opt-in per-LP collateral leverage on external Euler/Morpho/Aave/Liquity, **UP-SIDE ONLY**. The previous banner's "bidirectional (long above + short below entry)" was itself stale; the short leg was removed 2026-07-24 (`LevManager.sol:580-584`). §5's "leverage stays a separate DIRECTIONAL opt-in" is right; §3's "the protocol must self-provide liquidity from backing and eat the IL" is not. All θ/K figures assume a ±2% band; the deployed band is **±0.2%** (`SwapLib.BAND_DELTA = 20`). `docs/actionable/LEVERAGE-ENGINE-SPEC.md` does not exist. See memory `spv-informational-docs-diverge-from-code`.

# IL findings (this thread, 2026-06) — corrections + additions to IL-CERTIFICATION.md

IL-CERTIFICATION.md is treated as CLAIMS to test, not authority. Verified empirically this thread:

## 1. QU!D's pool has NO external arbitrage (internal-TWAP, mock-token, onlyUs swaps)
Swaps execute at `getTWAPforAsset` (internal TWAP cross-checked vs Chainlink), reused as the v4 price;
the pool trades Core-only mock tokens, swap is `onlyUs`. So the LP is NOT exposed to public
concentrated-LP arbitrage LVR. The IL is the **composition divergence** the pool realizes as it tracks
the external price (via reseat), plus a <=50bps execution lag — NOT the public-LP LVR.

## 2. IL is IMPERMANENT — our repack does NOT realize it (over-realization RETRACTED)
The repack/reseat is MOCK-only ("real assets in the basket/venue are untouched"): it re-ranges the VIRTUAL
POOLED_ETH/POOLED_USD accounting and realizes NOTHING. The earlier sims/over_realize.js charged each virtual
repack as a real-AMM trade — that was the bug; the over-realization finding is **RETRACTED**. QU!D's IL accrues
only via real user swaps (TWAP-priced, <=5% lag), is impermanent (recovers on reversal), and is realized only at
WITHDRAWAL — borne FAIRLY via the share price (`convertToAssets` = pro-rata of `vogueETH`), never over-realized on
noise. Magnitude (sims/strategy_compare.js, DERIVED theta): ~flat in most regimes; a violent bull is only ~-2%
(theta = yield/(K*sigma^2) collapses the in-range slice exactly when vol spikes); worst bad-exit ~-4%. The "-15%
bull hole" in an earlier sim was a theta=0.5 BUG. The one real exposure is the LOW-VOL GRIND (sims/find_makewhole_window.js):
low sigma keeps theta HIGH, so a smooth rally sells the slice off cheap -> ~10% upper-bound gap, still mostly
impermanent. LP relief = honest "don't exit mid-grind" disclosure (lpHealth grind flag), NOT realizing it from
anyone's pocket. NOT a fixed theta dial (removed) and NOT leverage on our books.

## 3. The LP turnover BREAK-EVEN (sims/lp_breakeven.js)
LP net/yr = yield*(1-theta) + fee*turnover*theta - K*sigma^2*theta. In-range LPing beats hold+yield IFF
`fee*turnover > K*sigma^2 + yield`. At 30bps/60%-vol that needs >102x annual turnover; below ~150x the
rational LP sets theta=0 (holds + yields, provides NO liquidity). => a viable in-range LP exists ONLY in a
high-turnover venue. In the low-turnover regime the protocol must self-provide liquidity from backing and
eat the IL (= what arbETH/R2 is FOR) — sustainable only within yield-coverage (yield >= IL), else musical chairs.

## 4. K measured on real 5m data (sims/measure_K.js)
COVID window: guard-OFF K=2.74 (doc 2.24), guard-ON K=1.84 (doc 0.71 — our guard model damps less than the
doc's; needs a fuller guard model + more windows, not the COVID tail alone). Direction robust: concentrated
+/-2% IL is large in high vol.

## 5. Conservation: IL cannot be eliminated, only reduced/offset/relocated
YieldBasis (constant-leverage) and EulerSwap (JIT-borrow) both RELOCATE IL to borrow CARRY; both justified
ONLY when (leveraged) fees > carry, i.e. HIGH-turnover pools. Neither applies to QU!D's low-turnover internal
pool. Leverage stays a separate DIRECTIONAL opt-in, not an IL fix. Theta-budget reduces (not eliminates) IL by
exposing less; the bigger free win is NOT realizing IL on noise (#2).

## 6. arbETH/arbBTC verdict — REMOVED (toxic), superseded by R1
Superseded. arbETH/arbBTC/refillETH were a surplus-funded make-whole, and surplus = `TVL − committed` = the
SHARED safety margin ("what we owe back"), NOT a payout reserve. Spending it to make ONE exiting LP whole
compensates the flow at every other claimholder's expense — the toxic "first-out at others' expense" pattern the
redemption path already avoids (pro-rata depeg haircut, no first-out-at-par). REMOVED this thread:
`Quid._withdraw` arbETH step; `Core.refillETH` + `ETHRefillRequest` (permissionless + griefable: a 1% magnitude
gate, no persistence, so anyone could force the speculative buy); `Aux.btcShortfall` WBTC-from-surplus fallback
(KEPT the hop — real-BTC delivery on L1, consumes no basket stables); and the now-orphaned `arbETH`/`arbBody`
machinery (Vault/Aux/SwapLib).
Net design = **R1**: the LP bears its own (small, mostly-impermanent) IL via the share price
(`convertToAssets` = pro-rata of `vogueETH`); a venue-illiquidity residual defers as `LP.pooled` (re-withdrawn on
thaw). No make-whole, and no leverage on the protocol's books — a leveraged unwind routes into the pool, and a 2x
LP liquidates in 5-19% of historical ETH windows (sims/leveraged_lp.js). Leverage, if an LP wants it, lives on
their OWN external book. See memory `project-quid-il-leverage-amortization-verdict`.
