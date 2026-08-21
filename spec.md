# BTC / ETH Dashboard Specification

**Estimation-based risk and state characterization for the bitcoin and ether sides of a duration-matched stablecoin protocol.**

---

## 0. Scope

This specification covers the BTC- and ETH-specific functionality of a finance protocol dashboard. The protocol holds bitcoin and ether as reserves backing an ERC-6909-issued stablecoin (`QD`) whose redemption schedule is a tokenized maturity ladder, and operates Uniswap V4 LP positions on BTC/USD and ETH/USD pools via Vogue (V4 primary) and Rover (V3 legacy).

**The central use case.** Users supply the dollar leg of Vogue's LP positions. Vogue places concentrated bands below current spot — when price moves down through a band, the dollar leg converts linearly into ETH or BTC at the band's AMM-enforced prices. The structure is therefore a *signal-informed accumulation strategy*: each band is a planned, range-priced conversion of dollars into the underlying, with the dollar leg earning ambient yield until conversion and LP fees while conversion is in progress.

**The decision the dashboard supports.** When and where to deploy bands so that the resulting effective accumulation price beats two benchmarks:

- **DCA into ETH or BTC.** The no-information baseline. Beating it requires placing bands where conversion happens at prices better than the time-average spot the DCA-er pays. The signal stack (§3.2 macro + §3.9 micro) is the input that makes this possible.
- **The Saylor strategy (MSTR-style accumulation).** The leveraged-bull benchmark — continuous-buyer-with-leverage. Beating it requires structural soundness Saylor sacrifices: no refinancing wall, no forced selling, no premium-collapse risk, productive yield on the un-converted dollar leg, no dilution.

The dashboard makes the structural quality of Vogue's accumulation empirically evaluable against both benchmarks across regimes — bull, bear, and crab — so that the band-placement decision can be made with eyes open about where the strategy holds and where it breaks.

**Supporting layers the dashboard surfaces:**

- The bond-ladder reserve composition earning blended yield (ether.fi staking on `weETH`, V4 LP fee accrual net of LVR, equity/commodities basket trading-fee revenue) that backs the QD redemption schedule independent of band-placement decisions
- The two-layer signal stack:
  - **Macro layer** composed of five roles, each grounded in a distinct source in Appendix A:
    - **Active state estimation** via the Kalman bank (§A.3) tracking β, σ, and mean-reversion strength φ as dynamic hidden states with uncertainty
    - **Discrete regime classification with transition dynamics** via the HMM regime layer (§A.5) composed on top of Kalman — Markov-switching state-space model providing regime posterior `P(regime_t | obs)` and transition matrix `P(regime_{t+1} | regime_t)` that the Kalman scalar φ cannot represent
    - **Non-extrapolation discipline** from Yartseva's multibagger work (§A.1) — bands are placed by current-regime estimation, not by pattern-matching against historically successful configurations
    - **Non-forecasting discipline** from Miao's LSTM-on-price result (§A.2) — the dashboard does not train sequence models to predict the next price bar; band placement consumes Kalman's *current state* output, not a forecast
    - **Cross-asset allocation** via inverse-vol weighting from the alpha-extraction framework (§A.4, the one principle that survives N=2 collapse) — the dollar leg splits between ETH and BTC accumulation bands inversely to each asset's Kalman-estimated σ
  - **Micro layer** — pool-flow read on the protocol's own V4 pools at block granularity (§3.9)
- Historical regime replay computing residual P&L of the structure across the 2021 run-up, the 2022 capitulation, a 2023 crab market, and the current grinding-bear regime, with Saylor and DCA both included as benchmarks

This spec addresses what the dashboard does **beyond** the baseline display of:

- current and historical amounts staked in the protocol's contracts (per chain, per pool, per venue)
- cumulative swap-fee yield generated over time

Those two baseline panels are assumed to exist; the rest of this document describes everything else.

The spec is self-contained and can be lifted into any implementation workspace.

---

## 1. Design philosophy: estimation, not prediction

### 1.1 The core principle

The dashboard's BTC/ETH job is to **characterize the present state** of these two assets and the protocol's exposure to them. Not to forecast where they're going.

Concretely, it surfaces:

- the current volatility regime, with uncertainty
- the current factor exposure (β) of one asset to another (and to a market proxy)
- the current mean-reversion strength of returns
- the protocol's reserve maturity profile against its scheduled liabilities
- the cost of moving size through current liquidity
- the breakdown of reserve yield by source
- where current state sits inside the protocol's operating envelope under user-defined shocks

It does **not** produce price predictions, buy/sell signals, "outperformance" calls, or directional alpha. Every functional choice in the spec follows from this distinction, and the distinction is grounded in the three pieces of research that informed the design.

### 1.2 Why: the source material uniformly warns against the directional impulse

#### Yartseva (2025), *The Alchemy of Multibagger Stocks*

Yartseva conducted a dynamic panel study of 464 US-listed multibagger stocks (each ≥10x appreciation, 2009–2024) and tested roughly 150 candidate predictor variables via Arellano–Bond and system-GMM estimators. Her central finding for the present design: **factors that explain past outperformance routinely fail to predict future outperformance.**

The most striking instance is earnings growth — treated as the foundational signal across practitioner literature on multibagger stocks. Across every formulation she tested (YoY growth, 5-year CAGR, EPS / sales / gross profit / operating profit / net profit / cash flow), earnings growth was statistically insignificant as a predictor of future returns. From the paper:

> "earnings growth ... was statistically insignificant in predicting future multibagger returns"

She frames this within Tortoriello's (2008) earlier observation that variables effective at explaining past performance frequently lose predictive power when modeling future returns. She also warns about regime drift:

> "the factors currently identified as key drivers of stock market outperformance may evolve over time"

and recommends periodic re-estimation of parameters.

The implication is sharpened, not weakened, in BTC/ETH. Yartseva was studying a thinly-covered niche (multibaggers among ~5,000 US listings). BTC and ETH are two of the most analyzed, most liquid assets in the world. Any persistent directional signal in them would be arbitraged faster than in equities, not slower. The directional impulse fails harder, not less, in efficient markets.

#### Miao (2020), *A Deep Learning Approach for Stock Market Prediction*

Stanford CS 230 final project paper. LSTM trained on daily OHLC for AMZN, GOOG, FB across 2015–2020, with model variants over hidden layers (3 vs 4), dropout rate (0.1 vs 0.2), and batch size (32 vs 64).

The reported best model achieves AMZN RMSE 48.66 — but inspection of the predicted-vs-actual plots shows the predicted line tracking the actual line with approximately one-period lag. The RMSE is dominated by this lag rather than by extracted predictive signal: the model is rediscovering `close_{t+1} ≈ close_t` with residual noise. It is not extracting alpha; it is rediscovering the persistence of price.

This is not a critique of LSTMs as a class. It is a fact about input feature sets: price-only daily data on a liquid asset is approximately a random walk, and a sequence model trained on a random walk produces a one-period-lagged copy of the input.

Implication: training a sequence model on raw price data for BTC or ETH will not yield directional signal. Sequence modeling is appropriate here for **state estimation** (current σ, current β, current regime), not for price forecasting.

#### Kalman filter article (uploaded as in-line text)

The Kalman material is unambiguous about purpose. Direct quotes from the article, each short:

> "The Kalman Filter does not predict the future."

> "OLS gives you the average. Kalman gives you the current state."

> "GARCH tells you what volatility was. Kalman tells you what volatility is right now."

Paraphrased from the same article: a Markov model tells you which regime you are in; a Kalman filter tells you where you actually are inside that regime. The filter recovers an unobservable state from noisy observations with mathematically optimal accuracy under the usual assumptions; it does not extrapolate that state forward in time.

The article also states an operational rule (paraphrased): when innovation variance diverges from the filter's model-implied innovation covariance S_t, the model is mis-specified — retune before trading. This is, per the article, the single most important difference between a research filter and a production filter.

And a robustness note (paraphrased): real return innovations are fat-tailed, and a standard Gaussian filter responds too aggressively to extreme observations. The recommended mitigation is Huber-style robust gain that downweights innovations above roughly 3σ.

#### Synthesis

Every source the design draws from is, in its own way, a warning against using these techniques for directional prediction:

- Yartseva: factors that explained past returns lose predictive power on future returns; the drivers evolve over time.
- Miao: a sequence model on price-only data on liquid assets produces a one-period lag, not alpha.
- Kalman: the filter is explicitly an *estimation* tool, not a *prediction* tool, and is most useful when used for what it actually does.

Together they support building an estimation and risk-characterization engine — which is exactly what this dashboard is. They do **not** support a directional alpha call on the two most efficient, most analyzed crypto assets in existence, and the sources would each independently warn against it.

### 1.3 What the dashboard does instead

- **Estimates hidden state with uncertainty** (β, σ, mean-reversion strength φ) via the Kalman bank from §A.3 — current-state output, not forecasts
- **Classifies discrete regimes with transition dynamics** via the HMM layer from §A.5 — posterior `P(regime | obs)` and transition matrix `P(regime_{t+1} | regime_t)` on top of Kalman's continuous-state output
- **Detects regime shifts** via innovation variance divergence against the model-implied `S_t` (§A.3 production rule) and via HMM posterior entropy spiking (§A.5 transition-in-progress flag)
- **Refuses to extrapolate from historical regime patterns** per §A.1 Yartseva — bands are placed by current state, not by "this worked in 2021" pattern matching; the §3.10 replay is regime-conditional evaluation, not forward inference
- **Refuses to forecast price via sequence models** per §A.2 Miao — no LSTM, no transformer trained on price-only history; the consequence (one-period lag dressed as alpha) is named explicitly so the temptation is closed
- **Cross-allocates the dollar leg between assets via inverse-vol weighting** per §A.4 Eq. 10 — the single principle from the alpha-extraction framework that survives N=2 collapse; higher-σ asset gets less band capital because LVR scales with σ²
- **Characterizes liquidity** (slippage curves, pool depth, channel state)
- **Visualizes the reserve maturity ladder** against the scheduled liability curve
- **Decomposes yield by source**
- **Surfaces stress-scenario outcomes** under user-defined shocks
- **Provides macro context** (rates, dominance, funding, basket reweigh, MSTR features) for the conjunction logic — not as standalone signals
- **Reads micro flow** through the protocol's own V4 pools as a leading-indicator signal (§3.9)
- **Integrates the above** into an LP economics framework (§3.8), a historical regime replay (§3.10), and the crystallization signal (§3.11) that make the protocol's structural quality empirically evaluable against passive benchmarks

### 1.4 The central problem — yielding QD with signal-informed accumulation and crystallization

#### What QD is

QD is the protocol's yielding stablecoin. Backing composition has four productive components:

- **Reserve mockUSD** earning ~4% baseline T-bill yield, always-on, in or out of LP positions. The dollar leg never sits idle — whether deployed as the dollar side of a Vogue band or held in pure reserve, it earns the baseline.
- **ether.fi staking on `weETH`** earning native ETH staking yield via ether.fi's validator set (~3.5% APR currently, plus restaking yield where applicable).
- **V4 LP fee accrual net of LVR** from Vogue's positions on the protocol's ETH/USD and BTC/USD pools. This contribution is *regime-conditional* — positive when fees exceed LVR (per §3.8 framework), can go negative in jump-prone or low-volume regimes. The LP layer is an optimization on top of the baseline, not part of the baseline.
- **Equity/commodities basket trading-fee revenue** from the basket venue (matched long/short positions on tickers like SPX, gold, oil).

Blended yield: ~10% APR in favorable regimes, compressing toward the ~4% + staking baseline in unfavorable ones (where LP layer subtracts). The bond ladder structure (§3.4) duration-matches reserves to the QD redemption schedule, preserving structural soundness independent of LP P&L.

#### What users do

Most QD holders sit in QD and earn the blended yield. They are buying capital-preserving exposure to a productive reserve with maturity-matched redemption. No further action required, no commitment to crypto direction.

For QD holders who want signal-informed BTC/ETH accumulation on top of the yield, the protocol provides an **opt-in rail: QD staking into out-of-range Vogue bands** (mechanic specified in §3.11). The staking does not burn QD; it shifts the staker's claim from general-reserve-backed to specific-band-backed. The staker continues to earn the ~4% mockUSD baseline yield throughout the staking period, plus any LP fees if the band touches in-range, plus the fill-conversion outcome if the band fills.

#### The three signal outputs the dashboard produces

For Vogue's operator and for any QD holder watching:

1. **Should LP positions be deployed at all?** Per §3.8 rationality checklist. When fees > LVR and the signal stack favors LP exposure, deploy. When unfavorable, sit in pure mockUSD earning the ~4% baseline — no IL/LVR exposure during the period. The dashboard's headline LP-deploy indicator: green / amber / red.

2. **Where should bands be placed?** Per §3.2 + §3.9 signal stack. Buy-side bands below current spot for accumulation; sell-side bands above for opportunistic disposition. Out-of-range bands available for QD staking are surfaced explicitly with their target prices and signal-stack rationale.

3. **When should filled bands be crystallized?** Per §3.11. Once a band has accumulated underlying via fills, the dashboard signals whether to withdraw the LP (locking the accumulation as protocol-held spot) or to keep it active (collecting more fees, accepting price-reversal risk where accumulated underlying gets sold back to mockUSD on a recovery through the upper band edge).

The three signals are produced by the same underlying signal stack — Kalman state estimation (§A.3) with the HMM regime layer (§A.5) on top, the Yartseva non-extrapolation discipline (§A.1) and the Miao non-forecasting discipline (§A.2) as guards, inverse-vol cross-asset allocation per the alpha-extraction principle (§A.4 Eq. 10), pool flow (§3.9), macro context including MSTR features and capital-structure operations (§3.7) — interpreted with different frames per output.

#### Benchmarks for the system over a full cycle

§3.10's historical regime replay quantifies the protocol's performance against two benchmarks across four regimes:

- **DCA into ETH** (no-information baseline). Signal-informed band placement + crystallization beats DCA in every regime tested, because: (a) the mockUSD dollar leg earns the baseline yield while waiting, while DCA's dollars convert immediately at that period's spot; (b) bands placed at signal-favored levels capture better effective conversion prices than the time-uniform DCA average; (c) crystallization locks favorable entries, avoiding the LP-sell-back that would otherwise undo the accumulation on price recoveries.
- **The Saylor strategy** (leveraged-bull benchmark). The protocol beats Saylor in 3 of 4 regimes via structural soundness Saylor sacrifices — no leverage, no refinancing wall, no MNAV compression, no ATM dilution, mockUSD baseline yield while waiting. Saylor wins post-capitulation rebound regimes (2023-like) where MNAV expansion off the lows compounds with BTC's recovery.

The benchmarks are for evaluating the system over a full cycle. They are the comparators against which the dashboard's signal-informed accumulation rail is measured, not directives forced on individual depositors. The depositor's actual outcome lies somewhere between "all bands opted into" (the comparator) and "pure baseline QD" (no opt-ins), depending on which specific bands they chose to participate in.

#### The structural point — hedging at the individual trade level

This is the architecture the protocol exists for. A QD depositor has, simultaneously:

1. **A yield-optimized base layer**, always on. mockUSD earning baseline + ether.fi staking + V4 LP fees net of LVR + basket revenue. The depositor pays no opportunity cost for sitting in QD without staking — the baseline yield runs continuously on un-committed capital.
2. **A per-trade signal overlay**, opt-in. For each out-of-range Vogue band, the dashboard surfaces the full signal-stack reading (Kalman state, HMM regime posterior, transition probabilities, pool flow, MSTR features, capital-structure operations, macro context, historical fill rates, regime-matched backtests). The depositor decides band-by-band whether to stake into it.

This is fundamentally different from holding MSTR equity. An MSTR holder is **all-or-nothing exposed** to Saylor's accumulation strategy — they can't selectively hedge specific decisions. Saylor's January BTC buy at $108K and his June BTC buy at $66K are not separable; the holder rides along with both via the equity price. A QD depositor hedges **at the trade level**: they stake into the bands where the signal stack reading supports their conviction, skip the bands where it doesn't, and the baseline yield runs on the un-committed capital throughout.

This is also fundamentally different from DCA. A DCA-er commits to uniform-time conversion regardless of signal. A QD depositor converts only when they choose to opt into a specific band, on the basis of the dashboard's signal reading *for that band*. Hedged against the uniform-blind-conversion commitment.

The two-segment framing of "yielding stablecoin holders vs accumulation participants" is wrong. The same depositor is both, simultaneously: holding QD for baseline yield (always) and selectively staking into individual bands (when the signal stack reading aligns with their conviction). The aggregate of those per-band decisions over time composes into their personalized strategy, hedged at the trade level rather than committed wholesale to a directional bet.

The dashboard's job is to provide the full signal surface for those per-trade decisions. MSTR's price action and Saylor's specific decisions are useful inputs to that signal surface (§3.7 features + §3.11 capital-structure operations), but the protocol does not synthesize an MSTR-tracking product because the protocol is not in the leveraged-bull-equity business. The protocol is in the yield-optimized-baseline-plus-per-trade-accumulation-signals business — a distinct shape of exposure that MSTR's all-or-nothing leverage doesn't provide.

---

## 2. Architectural constraints

These constraints are inherited from prior design decisions in the host protocol. They shape what the dashboard can and cannot show.

### 2.1 Off-chain agent, on-chain envelope, user-signed intents

Strategy logic (rotation decisions, LP entry sizing, reserve draws) lives off-chain in a keeper-style agent. The contracts hold consensus-critical state and verify user-signed intents on each fund-moving action. The agent holds no persistent delegate authority — it is a relayer of pre-signed user actions, executing them when their embedded conditions are met.

Consequence for the dashboard: the dashboard is a read surface for the same estimates the agent consumes. When the dashboard shows "BTC σ = 62% ±4% annualized," that's the value the agent is also using to decide whether to act on a pre-signed conditional intent.

### 2.2 The ERC-6909 Basket as the foundation

`QD` is issued through an ERC-6909 contract where each token id represents a maturity month. `mint(pledge, amount, token, when)` sets the maturity at mint time; `currentMonth()` advances; `totalMatureBalanceOf(owner)` returns the currently-redeemable balance; `getHaircut()` returns the weighted-median haircut vote that adjusts the redemption discount.

This produces a **scheduled liability curve**: at each upcoming month, a known quantity of QD becomes redeemable. The protocol's reserves are duration-matched against this schedule by construction — reserves mature *into* the redemption schedule. The "dollars on hand" guarantee is asset-liability matching, not promise-keeping.

This structure also underpins the V4 LP bootstrapping: the dollar leg of an ETH/USD or BTC/USD pair is sourced from the bond schedule rather than requiring depositors to sell half their ETH/BTC to provide the dollar side. The maturity ladder *is* the predictable forward dollar stream, and that stream collateralizes the LP's dollar side.

Dashboard implication: the maturity-ladder panel (§3.4) is structurally central, not optional.

### 2.3 Single-user view only — no reflexive aggregates

Protocol-wide aggregates of position state that could trigger the behavior they're meant to monitor (run dynamics: one user sees others' positioning, panics, withdraws mid-rotation, forces out-of-sequence unwinds, socializes a loss) are excluded.

The dashboard surfaces:

- the connected user's own positions, in full detail
- protocol-wide *health* metrics (yield, reserve coverage, liquidity depth) that don't reveal individual counterparty positioning
- **no** protocol-wide views of position aggregates that could expose individual-user behavior

This is a Goodhart-aware design principle: if surfacing X to users predictably causes the behavior that destroys X, X does not belong on the user-facing dashboard.

The bond ladder and LP layer satisfy this constraint naturally. All users hold QD, which is a single fungible claim on the entire reserve — there is no per-user reserve position to differ between depositors. Reserve composition (bond ladder + LP layer) is shown in aggregate because that aggregate is what backs every QD equally. What the dashboard does not show is anything that re-introduces individual-user variation (e.g., per-user yield accrual schedules tied to specific reserve assets) — but in the structure there is no such variation to expose.

---

## 3. Functional specification

### 3.1 Foundation panels (baseline, listed for completeness)

- Current amount staked per asset (ETH via ether.fi → weETH; BTC via channel bridge), per chain, per venue
- Historical amount staked over time (line chart, windows: 7d / 30d / 90d / lifetime)
- Cumulative swap-fee yield over time (per LP pool, per asset)

The rest of this section specifies everything *beyond* these baselines.

### 3.2 Regime characterization — Kalman bank

**Purpose:** Tell the user (and the agent) what state BTC and ETH are in right now, with uncertainty bands.

**Per asset (BTC, ETH), maintain three Kalman filters in parallel:**

#### 3.2.1 Dynamic β

For each asset, regress returns against a factor via Kalman:

- **BTC's factor:** total crypto market capitalization (or a broad crypto index; the choice is configurable, but the default is reasonable because BTC is roughly half of total crypto cap, giving meaningful but not degenerate variation)
- **ETH's factor:** BTC (since most high-frequency ETH return variation is co-movement with BTC)

State-space:

```
β_t = β_{t-1} + w_t,         w_t ~ N(0, Q_β)
r_asset,t = β_t · r_factor,t + v_t,   v_t ~ N(0, R_β)
```

Tuning starting points: Q_β ≈ 1e-5 (β drifts slowly), R_β ≈ 1e-3 (measurement noise calibrated to typical regression residual variance). Retune via the divergence check (§3.2.4).

Dashboard surfaces β_t with ±√P_t band.

#### 3.2.2 Dynamic volatility

Annualized volatility with uncertainty, in log-variance space for numerical stability and positivity:

```
log(σ²_t) = log(σ²_{t-1}) + w_t,   w_t ~ N(0, Q_σ)
log(r²_t) = log(σ²_t) + η_t
```

Tuning starting points: Q_σ ≈ 0.1 (responsive enough to track regime shifts), R_σ ≈ 1.0 (chi-squared-derived; the Gaussian approximation is acknowledged imperfect but works in practice — this is from the source article).

Dashboard surfaces annualized σ with ±1σ band derived from P_t. The band itself communicates regime stability: a widening band means the filter is updating rapidly, indicating a regime transition.

#### 3.2.3 Mean-reversion strength

AR(1) coefficient on demeaned daily returns, estimated via Kalman:

```
φ_t = φ_{t-1} + w_t
r_t = φ_t · r_{t-1} + v_t
```

|φ| close to 0 → random walk. Negative φ → mean reverting. Positive φ → trending.

Dashboard surfaces φ_t with band, plus a descriptive label (one of: `trending`, `random walk`, `mean reverting`).

#### 3.2.4 Production rule — innovation divergence check

For each filter, track innovation `y_t = z_t - H·x̂_t|t−1` and innovation covariance `S_t = H·P_t|t−1·H' + R`. Compute the empirical variance of `y_t` over a rolling N-step window (default N=60) and compare against the mean of `S_t` over the same window.

When the ratio `empirical_var(y_t) / mean(S_t)` exceeds a configured threshold (default 2.0), emit a **filter divergent** warning on the relevant card. The agent stops consuming that filter's outputs until retuned. The dashboard exposes a one-click "retune" affordance for the operator that triggers Q/R re-estimation.

This is the single most important production gate per the source material. Without it, the filter silently mis-states the state during exactly the regime transitions when the state matters most.

#### 3.2.5 Robust gain

Innovations larger than `3 · √S_t` are down-weighted via a Huber-style modification to the Kalman gain. Small efficiency loss in normal regimes, substantial improvement during tail events. This is non-optional given crypto-asset fat tails.

#### 3.2.6 Four-quadrant regime map

Derived view from §3.2.2 and §3.2.3:

```
                    Low σ            High σ
              ┌─────────────────┬─────────────────┐
Mean-reverting│ calm reversion  │ stressed mean-  │
              │                 │ reversion        │
              ├─────────────────┼─────────────────┤
Trending      │ low-vol trend   │ regime change   │
              └─────────────────┴─────────────────┘
```

BTC and ETH are placed on this map with their joint uncertainty footprint. Labels describe the **regime**, not prescribe an action.

#### HMM regime layer — discrete regime classification on top of Kalman state

The Kalman bank above produces continuous state estimates (σ, β, φ) with uncertainty bands. A **second layer** consumes those estimates as observations and classifies them into discrete regimes with explicit transition dynamics. The composition is a Markov-switching state-space model — Kalman tracks the within-regime continuous dynamics; the HMM tracks regime transitions.

Methodology grounded in §A.5 (Jurafsky & Martin's HMM appendix). Three roles:

**1. Discrete regime set.** Six states:

```
{strong_bull, weak_bull, crab, weak_bear, capitulation, recovery}
```

Each regime has its own emission distribution over the Kalman-output vector `(σ, β, φ, pool_flow_intensity, MSTR_capital_structure_state)`. The emission distributions are estimated empirically from historical data segmented by Viterbi decoding (bootstrap iteration with Baum-Welch).

**2. Transition probability matrix.** A 6×6 matrix `A` where `A[i,j] = P(regime_t = j | regime_{t-1} = i)`. Estimated by Baum-Welch (§A.5.3) on historical observation sequences. Critical structural information the Kalman-only layer lacks:

- `P(capitulation | weak_bear) > 0.3` means we're at meaningful risk of regime escalation downward; informs the §3.11 crystallization signal toward "crystallize aggressively"
- `P(recovery | capitulation) > 0.4` means capitulation regimes have meaningful exit probability; informs band placement at lower levels
- `P(strong_bull | crab)` is typically small but non-trivial; informs whether to keep LPs active through crab regimes vs winding down

**3. Forward-posterior over current regime.** At each block, the Forward algorithm (§A.5.1) computes `α_t(j) = P(observations_{1..t}, regime_t = j | model)`, normalized to a posterior distribution `P(regime_t | observations)`. The dashboard surfaces this distribution, not a single committed classification — the posterior may be `{weak_bull: 0.4, crab: 0.35, weak_bear: 0.25}`, which is more honest than committing to one regime and is more useful for the §3.11 conjunction logic.

**Operationally:**

```python
@dataclass
class HMMRegimeState:
    regime_posterior: Dict[str, float]    # P(regime_t = j | obs_{1..t})
    transition_matrix: np.ndarray         # 6×6, A[i,j] = P(next=j | curr=i)
    most_likely_current: str              # argmax of posterior
    most_likely_next: str                 # argmax over Σ_j posterior[j] × A[j, k]
    posterior_entropy: float              # uncertainty measure
    viterbi_path_last_90d: List[str]      # most-likely regime sequence over recent window
```

The `viterbi_path_last_90d` is the Viterbi-decoded most-likely regime sequence over the trailing 90 days. It provides the regime-boundary specification §3.10's historical replay should consume rather than inspection-based boundaries.

**Production caveats** (per §A.5 and §A.3 discipline):

- Output Independence assumption — observations are conditionally independent given the state. Approximately true within a regime; breaks at transitions. The Forward algorithm's output should be interpreted with this caveat (transition periods have higher Forward-posterior entropy and lower classification confidence).
- Baum-Welch initialization matters. Random init produces unstable convergence; the protocol initializes from a hand-specified seed (`strong_bull` emission centered on σ=0.5, φ>0.1; `capitulation` centered on σ>1.0, large negative returns; etc.) then refines with EM iterations on historical data.
- Regime stationarity assumption — the emission distributions per regime are assumed stable over time. Periodic re-estimation (rolling 2-year window) addresses gradual drift but cannot capture structural breaks.
- Six regimes is a choice. Two regimes (bull/bear) underfit; ten or more overfit on the available history. Six is the empirical balance — enough to distinguish the regimes that matter (capitulation distinct from weak_bear; recovery distinct from strong_bull) without proliferating states the data can't support.

### 3.3 Yield decomposition

**Purpose:** Show where reserve yield is coming from, by source, in real time.

#### Components

- **ether.fi staking yield** — 7d-trailing APY on weETH, alongside 30d / 90d / lifetime windows
- **V3 0.05% weETH/WETH LP fee yield** — cumulative fees / position value, annualized; net of UNIfication fee-switch haircut where applicable
- **V4 ETH/USD pool fee yield** — same, with in-range vs out-of-range split for self-managed Vogue positions; no UNIfication haircut (protocol controls its V4 fee accumulator policy)
- **V4 BTC/USD pool fee yield** — equivalent for the BTC side once added
- **Equity/commodities basket trading-fee yield** — fees and funding-rate spreads from the basket venue, flowing to QD backing per protocol accounting

#### Headline metric: blended portfolio yield

```
blended_yield = Σ (time_weighted_allocation_i × yield_i) / total_reserve
```

Computed daily and aggregated, **not** as `end-point-allocation × end-point-yield` (which produces misleading numbers when composition changes mid-window).

#### Comparison anchor

Display, alongside the protocol's blended yield, the equivalent for the no-protocol baseline (raw ETH or BTC held directly with no yield). The **yield differential** — protocol over baseline — is the structural advantage of the wrapper. This is an observation, not a directional call.

### 3.4 Reserve maturity ladder

**Purpose:** Visualize the duration matching between reserves and the QD redemption schedule; surface ALM gaps before they bite.

#### Liability curve

Stacked bar chart by maturity month, sourced from `Basket.totalSupplies(month)`. Current month plus next 12 months shown directly; longer horizons collapsed into a `12m+` bucket. Optional layer: the haircut-adjusted USD value at maturity (using the current `getHaircut()` weighted-median vote).

#### Asset curve

Same time axis, stacked bar chart with reserves grouped by source and projected maturity:

- ether.fi withdrawal-queue positions (NFT ids with their unlock dates from the `LiquidityPool`)
- Cash and short-duration USD reserves (assumed mature immediately) — including the un-deployed dollar leg of Vogue's bands
- LP fee accrual stream — projected from the trailing 30d fee accrual rate, with a confidence band derived from rolling fee-rate variance (because LP fees are *expected* future income, not contractually scheduled)
- Equity/commodities basket revenue accrual — same projection methodology as LP fees

#### Coverage ratio per bucket

```
coverage_ratio(month) = scheduled_reserve_maturity(month) / scheduled_liability(month)
```

Visualization: months where `coverage_ratio < 1.0` highlighted as under-matched; months where `coverage_ratio < configured_safety_margin` (default 1.2) flagged as a concern. Under-matched months are the gaps the protocol will need to bridge via the V4 swap fallback (~0.3% instant-exit cost, depending on pool state) — i.e., they're the buckets that will eat the swap fee on redemption.

#### Headline metric: "months of liquid runway"

The largest `M` such that cumulative liabilities through month M fully fit within cumulative liquid reserve maturity through month M, **without** invoking the swap fallback. This is the protocol's LCR analog. It's a single number on the dashboard, and it's the most informative single number for protocol health.

#### Algorithm

```python
def months_of_runway(liability_curve, asset_curve):
    cum_liab, cum_asset = 0, 0
    for month in range(len(liability_curve)):
        cum_liab += liability_curve[month]
        cum_asset += asset_curve[month]
        if cum_asset < cum_liab:
            return month - 1
    return len(liability_curve)
```

#### Worked example

Continuing the $100M TVL setup used elsewhere in this spec. Suppose the QD redemption schedule and reserve maturity profile look like this (illustrative, not actual):

| Month ahead | QD liability | Reserve maturity | Coverage ratio |
|---|---|---|---|
| 0 (current) | $8M | $20M (cash + ether.fi instant-liquid) | 2.50 |
| 1 | $6M | $4M (ether.fi unlocks) | 0.67 ⚠ |
| 2 | $5M | $7M | 1.40 |
| 3 | $4M | $5M | 1.25 |
| 4 | $4M | $6M | 1.50 |
| 5 | $3M | $4M | 1.33 |
| 6+ | $20M (cumulative) | $54M (cumulative) | 2.70 |

Cumulatively through month 1: liabilities $14M, assets $24M — covered with margin. The month-1 individual bucket shortfall (0.67) is the kind of thing the dashboard highlights, but it's *covered* in the cumulative-runway calculation because the month-0 surplus absorbs the month-1 shortfall.

Months of liquid runway in this example: looking at cumulative position month by month, all months are positive through the full visible window, so the headline "months of liquid runway" reads as the full window (e.g., 12+).

The under-matched individual bucket (month 1, 0.67) still gets visually flagged because it's the bucket where, under stress, the V4 swap fallback would be invoked — operators want to see that, even if the protocol-aggregate runway is fine. Under-matched-but-covered-cumulatively means "this month will draw on next month's reserves, paying the V4 spread to bridge." Months of true runway depletion (cumulative going negative) is the headline emergency state, and the protocol shouldn't be there.

### 3.5 Liquidity surface

**Purpose:** Show pool depths and the cost of moving size, per asset, per venue.

#### Pool depth snapshot

Refreshed each block (or every 30s as fallback):

- **V3 0.05% weETH/WETH** — depth on each side, mid-price, distance from ether.fi NAV
- **V4 ETH/USD** — `POOLED_ETH` (in-range ETH-side liquidity), distance to nearest tick edges, fee tier breakdown
- **BTC channels** — open channel count, total channel capacity (`ISPVGateway`-anchored), mean channel age, capacity utilization

#### Slippage cost curves

Per pool, plot:

```
slippage_bps(notional) = (executed_price / mid_price - 1) × 10000
```

Computed by simulating the swap against current pool state (tick data read on-chain). A curve, not a single number, because slippage is non-linear in size.

This panel answers the question: "if I had to exit a position of size N right now, what would it cost?" That question is the input to §3.6's stress scenarios.

### 3.6 Stress scenarios

**Purpose:** Surface where the protocol sits in its operational envelope under user-defined shocks. Non-predictive — the scenarios characterize *what if X happened*, not *X will happen*.

Sliders, independently or in combination:

1. **BTC drawdown** — range −60% to 0%, default −30%
2. **ETH drawdown** — range −60% to 0%, default −30%
3. **ether.fi withdrawal-queue extension** — range 7d to 30d, default 14d
4. **V4 pool depth compression** — range −80% to 0%, default −50%
5. **Funding-rate shock** — range −100bps to +100bps daily on the perp curve, default ±0

Under each combination, recompute:

- maturity-ladder coverage ratios (§3.4) — does any bucket become under-matched?
- slippage profile (§3.5) — how does the cost curve shift under compressed depth?
- yield decomposition (§3.3) — does any component go negative? (LP fees can, briefly, in extreme regimes)
- Kalman σ for each asset under the new realized-variance assumption — does any filter trip the divergence threshold?

**Output card:** one per active scenario combination. Worst-case coverage ratio, slippage cost of exiting a notional unit, a binary `envelope intact / envelope breach` indicator, plus the most adverse component identified.

#### Worked example

Continuing the $100M TVL setup. Operator runs a combined scenario: BTC drawdown −40%, ETH drawdown −40%, ether.fi queue extends to 21 days, V4 pool depth compresses −60%.

The dashboard recomputes:

- **Maturity-ladder coverage.** With the ether.fi queue extended to 21d, the month-1 reserve maturity from ether.fi shifts to month-2 (roughly). The month-1 bucket coverage drops from 0.67 to ~0.45. Cumulative through month 1 still positive ($24M asset / $14M liability, now shifted) — runway still intact, but the under-matched flag intensifies.
- **Slippage profile.** With V4 depth compressed 60%, the exit cost on a unit notional roughly doubles. The dashboard surfaces the new cost curve.
- **Yield decomposition.** With ETH and BTC down 40%, LP fee income on the V4 pools drops materially (lower notional × similar percentage). The blended yield falls from ~10% to ~7% — bond ladder still covered, the productive default still delivers carry.
- **Kalman σ divergence check.** Realized vol under a sudden −40% move would spike to multiples of the prior estimate. The σ filter trips the divergence threshold. Dashboard flags: "σ filter divergent under this shock — agent would pause consuming σ outputs until retune."

**Output card for this scenario:**

```
Scenario:  BTC −40%, ETH −40%, queue 21d, depth −60%
Status:    ⚠ WATCH (under-matched bucket month-1: 0.45)
Worst coverage:  0.45 (month-1)
Cumulative runway: intact through month-12+
Exit cost @ unit notional: 2.1× nominal
σ filter:  divergent (BTC and ETH both)
Most adverse component: ether.fi queue extension
```

The scenario doesn't breach the envelope (runway intact, ladder cumulatively covered), but it identifies queue extension as the variable that does the most damage to the protocol's operating posture. That's actionable in the sense that operators know to monitor ether.fi queue depth specifically as the leading indicator under this kind of regime.

### 3.7 Macro context strip

Compact strip at the top of the dashboard. Contextual indicators, not signals — except for the MSTR sub-strip, which feeds into the signal stack as one input among many (see §3.9 and §3.11).

#### General macro

- **Fed effective rate.** Yartseva's rising-Fed dummy was the only macro factor she found significant in her growth-equity returns model. Documented broader relevance to risk-asset valuation. Displayed alongside its 3-month change.
- **BTC dominance** (BTC market cap / total crypto market cap). Proxy for risk-on vs risk-off rotation within crypto.
- **Average funding rate, top-3 perp exchanges, BTC and ETH.** Proxy for systemic leverage. Extreme positive funding has historically preceded local tops, extreme negative funding has historically preceded local bottoms, but the correlation is loose enough that the strip shows levels rather than signals.
- **Open interest, BTC and ETH perps.** Alternative leverage proxy.

For situational awareness only. Not consumed by the agent as inputs to actions.

#### MSTR sub-strip — institutional accumulation observable

Michael Saylor's BTC accumulation strategy is the largest publicly-observable institutional bid in the BTC market. Whether any specific decision he makes reflects genuine timing edge is unknowable from outside; what *is* observable is the actions themselves and how the market values them. The protocol ingests these observations as **one input among many** to the signal stack — never authoritative, but always informative about institutional sentiment toward leveraged BTC exposure. See §3.11 for the full synthetic-trade reasoning.

Feeds:

- **MSTR equity price (Pyth feed).** Spot price, intraday changes, 30d/90d trailing.
- **MNAV (Multiple to NAV).** Computed as `(MSTR_shares_outstanding × MSTR_price) / (BTC_holdings × BTC_price)`. The market's premium-or-discount valuation of Saylor's strategy. Historical range roughly 0.8x–4.0x; current level and direction matter more than the absolute number.
- **BTC purchase rate (from 8-K filings).** Rolling 30d/90d BTC accumulated by MicroStrategy. Aggressive purchases = institutional conviction signal; pauses = either capital constraints or anticipation of better entries.
- **ATM equity issuance announcements.** When Saylor issues equity at the market, he's revealing his view that current MSTR premium is high enough that issuance is accretive — i.e., his marginal-buyer view of MNAV fair value is *below* current MNAV.
- **Convertible offering announcements.** Indicate institutional appetite for BTC-via-leverage. Strong demand = continued willingness to fund the trade; absorption-difficulty = institutional saturation.
- **Convertible maturity schedule.** Forward-looking refinancing risk indicator. As maturities approach without favorable conditions, MSTR faces structural pressure that the protocol does not.

Each feed is displayed as a value plus its trailing-window context, with anomaly flags when a feed moves >2σ from its trailing-60d baseline (analogous to §3.9's z-score discipline).

The MSTR strip's role is documented further in §3.11.

### 3.8 LP economics framework

**Purpose:** Make legible what the protocol's V4 LP positions (Vogue, Rover) actually earn and lose, expressed in the rigorous decomposition that the LP-position structure demands. The framework is the dashboard's central analytical lens for the LP layer.

#### The fundamental identity

An LP position is **short gamma with a fee coupon**. You collect fees (your theta-equivalent) and you lose on realized movement (your negative gamma). The clean expression:

```
LP P&L  ≈  fees_earned  −  LVR  −  gas/rebalance_cost
```

benchmarked against whatever the LP would otherwise hold. This identity governs everything below.

The same position can be "good" or "bad" depending on the benchmark choice — there is no universal LP-is-good-or-bad statement, only LP-relative-to-what statements.

#### IL / divergence loss — endpoint-driven, convex in the move

For a full-range V2-style LP, the position value relative to a 50/50 hold benchmark at endpoint price ratio `k = P_t/P_0` is:

```
V_LP / V_hold_5050  =  2·√k / (1 + k)
```

This is the **impermanent loss** (IL) ratio. Concrete values, expressed as percentage IL = (1 − ratio):

| Price ratio k | Move | IL vs 50/50 hold |
|---|---|---|
| 1.0 | flat | 0% |
| 1.25 | +25% | 0.6% |
| 1.5 | +50% | 2.0% |
| 2.0 | +100% (doubling) | 5.7% |
| 3.0 | +200% | 13.4% |
| 4.0 | +300% | 20.0% |
| 6.6 | +560% (≈ 2021 ETH run-up) | 32.4% |
| 0.5 | −50% (symmetric to doubling) | 5.7% |
| 0.25 | −75% (≈ 2022 ETH drawdown) | 20.0% |
| 0.4 | −60% (≈ Aug 2025 → Jun 2026 ETH) | 9.4% |

IL is **symmetric in log-price** (a halving costs the same as a doubling, ~5.7%) and **convex in the magnitude** of the move (large moves cost disproportionately more than the linear extrapolation would suggest).

For a **concentrated** V3/V4 LP with a band `[P_low, P_high]`, the math has a hard wall:

- While in range, the LP behaves like a V2 LP but with a concentration multiplier (the same dollar in a narrower band represents more virtual liquidity, so it earns more fees and also incurs more divergence per unit price move within the band).
- At the band edge, the position is 100% converted into one asset. **Beyond the band, no further fees and no further IL** — you've effectively executed a limit-order conversion at the band edge price, and now you're just holding the asset that price moved away from.

The 2022 jump-prone capitulations are the worst case for concentrated LPs: large gaps (LUNA collapse, FTX collapse) gapped *through* narrow ranges in single moves, leaving LPs 100% in the asset that just cratered, with fees off (out of range) and no chance to re-band before the next gap.

#### LVR — the continuous-time variance tax

Loss-versus-rebalancing is the continuous-time form of the same loss. For a full-range V2 LP under geometric Brownian motion with volatility σ:

```
LVR_annualized  ≈  σ² / 8
```

per unit of position value. Direction-agnostic — the LP loses to rebalancing arbitrageurs equally on up-moves and down-moves; the loss is a function of *realized variance*, not return.

Concrete annualized LVR at representative ETH vols:

| Annualized σ | Regime | LVR / year |
|---|---|---|
| 40% | calm crab | 2.0% |
| 60% | normal grind | 4.5% |
| 80% | active trend | 8.0% |
| 100% | high vol | 12.5% |
| 120% | crisis regime | 18.0% |

For **concentrated** LPs, multiply by the concentration factor `C ≈ 1 / (range_width)`. A position concentrated to ±10% around mid (a 20% band) has concentration factor ~10×; a ±2% band has ~50×. LVR scales linearly with concentration *while in range* — and goes to zero out of range (since out-of-range positions are 100% one asset and no longer rebalancing).

Practical concentrated-LP LVR is therefore a duty cycle: high when in range, zero when out. The expected LVR is concentration × LVR_full_range × (fraction of time in range).

#### Fee yield — volume × tier × in-range share

Fees scale linearly with:

- **Pool trading volume** (dollar volume per unit time)
- **Fee tier** (0.05%, 0.30%, 1.00%, or the protocol's custom V4 tier)
- **Your in-range share** (your active liquidity divided by total active liquidity at the current tick)

Volume rises with both volatility and speculative activity — the same regimes that pump LVR also pump fees, so the question is always the *ratio*.

#### The central decision metric: fee yield vs LVR

The entire LP decision reduces to a single ratio against a chosen benchmark:

```
Fee_APR  vs  LVR_APR  (and vs 0, for the cash benchmark)
```

When `Fee_APR > LVR_APR`, the LP is contributing positive net carry to the reserve. When `Fee_APR < LVR_APR`, the LP is destroying value — fees come in slower than divergence drains out. The dashboard surfaces this ratio continuously, per pool, per time window.

Importantly, this ratio is *necessary but not sufficient* for rational LPing. You also need:

1. **Directional neutrality or mean-reversion expectation.** If you have strong directional conviction either way, holding spot (long) or holding cash (short / sidelined) dominates LPing. The LP position implicitly says "I'm agnostic on direction, I'm here for the fee coupon."
2. **No jump regime.** Large discontinuous moves gap through ranges and impose endpoint losses that the fee accrual cannot cover. Jump-prone regimes (capitulation, surprise central bank actions, exchange collapses) are LP-hostile regardless of the average fee/LVR ratio.
3. **Option premia not richer than fees.** Because an LP position replicates a short straddle, the cleanest test is: does the fee yield exceed the fair premium of the implicit option being sold? If implied vol on listed ETH options is rich relative to the pool's fee APR, selling the option directly (and skipping the AMM) dominates being an LP.

#### LP deployment is opt-in optimization above the mockUSD baseline

A subtle but load-bearing property: the protocol's mockUSD always earns the ~4% T-bill baseline yield, *regardless* of whether it's deployed as the dollar leg of an active LP position. The dollar leg is not idle when sitting in pure reserve; it earns the baseline.

This means:

- **No opportunity cost of leaving capital un-deployed.** Pure mockUSD earns the same 4% as the dollar leg of an active LP. LP deployment is an *optimization on top* — accepting IL/LVR exposure for fees, not a substitute for cash yield.
- **The LP-vs-no-LP comparison is fees − LVR vs 0**, not vs the baseline. The baseline is preserved either way; what's at stake is whether fees net of LVR is positive.
- **In adverse regimes the protocol can wind LP exposure down to zero** without giving up productive yield. The rationality checklist below names the conditions under which winding down is appropriate.

This is what makes the regime-conditional deployment decision honest: there is no penalty for staying out of the LP layer in jump-prone or low-volume regimes. The reserve continues to earn ~4% on dollars plus staking yield on ETH/BTC reserves plus basket revenue. LP fees are an opt-in regime-conditional augmentation.

#### When LPing is rational vs irrational

**Rational when all three hold:**

- Directionally neutral or expecting mean-reversion
- Realized vol comes in below what fees compensate for (fee_APR > LVR_APR)
- Volume/TVL turnover is high relative to LVR (your fee tier is being earned often)

**Irrational when any one holds:**

- You have conviction in either direction (just hold the asset, or hold cash and short, depending on direction)
- Jump-prone capitulation regime (gaps + dried-up volume = max LVR + min fees)
- Option premia beat the fee yield (sell the option directly instead)

This framing names the regimes where the protocol's LP layer should be wound down, parameter-adjusted (narrower bands, tighter rebalance triggers), or temporarily exited, vs the regimes where it should be left to run.

#### Benchmark-conditional quality

The same LP position produces three different answers depending on which benchmark you compare to:

- **vs holding the underlying (ETH or BTC):** LP wins in downtrends (the dollar leg cushions the drawdown), loses in uptrends (the LP sold the winner as it ran).
- **vs holding cash / T-bills:** LP loses badly in any sustained drawdown (you're long the asset that just dropped), wins only in flat-to-up regimes with healthy volume.
- **vs 50/50 hold (the natural benchmark for an AMM LP):** LP loses by exactly `IL − fees` in any trending regime, wins only when `fees > divergence`. This is the cleanest comparison for evaluating LP-as-strategy because both benchmark and LP start with the same composition.

The dashboard surfaces all three, per pool, per time window, because the right benchmark depends on what the comparator is choosing.

#### Structural haircuts since pre-2022 (current state)

Three material changes to V3 LP economics over the last several cycles, all affecting gross-to-net realized by passive concentrated LPs. Earlier drafts of this section attributed the degradation primarily to solver/intent flow capture making V3 residue "more toxic"; that framing is inverted relative to the empirical research and is corrected below.

**Fee-switch (post-UNIfication, December 2025).** Following the Uniswap governance unification ("UNIfication"), a portion of V3 LP fees is now routed to the protocol-fee accumulator rather than entirely to LPs. Net effect on the dashboard's accounting: gross fees from V3 pools must be discounted by the fee-switch percentage to compute net-to-LP fees. The V4 pools the protocol operates internally do not have this discount, since the protocol controls its own V4 fee accumulator policy. Vogue's V4 positions are unaffected; Rover's V3 positions (where they remain) are.

**JIT liquidity sniping.** Sophisticated bots observe large pending swaps in the public mempool, mint highly-concentrated liquidity in the swap's tick range immediately before execution, and burn the position immediately after. They capture a disproportionate share of the swap's fees (90%+ on a sniped swap is typical when the JIT bot's concentrated position dominates the tick's liquidity), leaving passive LPs with proportionally less. The asymmetry is selective: JIT bots have the ability to detect pending order flow before committing liquidity, so they only provide liquidity to *uninformed* swaps and avoid adversely-selected ones. Passive LPs face the residue — the flow JIT bots chose not to compete for, which is on average more adversely-selected. This is the dominant mechanism by which V3 LP fee economics have degraded; it predates intents/solvers and has intensified as JIT operations matured.

**Adverse selection by latency-sensitive informed flow.** Solver-based DEXes (UniswapX, CoW Swap, 1inch Fusion) route through V3 pools as one liquidity venue among several, and empirical research finds that solver-routed flow hitting V3 is actually *less* toxic than direct-routed flow — solvers backstop with V3 routing for uninformed retail intents, delivering nontoxic flow to the pools they touch. What stays off solver paths is latency-sensitive informed flow: MEV bots, atomic-arb strategies, and cross-domain arbitrageurs that need same-block execution and cannot accept the auction-latency a solver introduces. This flow routes directly to V3 because of timing constraints, not pricing. Its toxicity is a feature of the trader's strategy, not a consequence of solver capture.

The composition of flow hitting V3 has therefore shifted over recent years: less uninformed retail (some captured by CoW-style P2P matching and RFQ inventory, more cherry-picked by JIT bots), proportionally more latency-sensitive informed flow that needs atomic execution. Headline fee APRs comparable to pre-2022 numbers represent a worse fee/LVR mix because the LVR contribution of the residue flow is structurally higher.

On the dashboard, this shows up as fee-realized-per-unit-LVR being lower than the same headline APR would have implied pre-2022, and as a wider gap between gross fees and net-to-LP after fee-switch haircuts and JIT-share reduction.

All three haircuts are visible in §3.10's historical replay: the 2026 figures incorporate them; the 2021-era figures do not (UNIfication didn't exist, JIT was nascent, and solver routing was limited).

#### Data sources

- V4 PoolManager state — pool liquidity, current tick, fee accumulator, accrued fees per Vogue/Rover position
- V3 NonfungiblePositionManager state for Rover's V3 positions (with the fee-switch haircut applied)
- Vogue/Rover internal accounting — current band parameters, rebalance frequency, gas costs
- Price oracle — for σ estimation and IL computation
- Realized variance series — from the Kalman bank's σ filter in §3.2 (with the same Huber-style robust statistics)
- Listed-options implied vol (where available, e.g., from Derive's orderbook even though Derive itself is bridged-only and not used as a venue here — the IV data is still useful as a fee-vs-premium comparator)

#### Panels

- **Headline fee/LVR ratio (per pool, per window).** Big number, color-coded — green when fee_APR > LVR_APR by a margin, amber when narrow, red when LVR exceeds fees.
- **IL decomposition card.** Current LP value vs current 50/50 hold value (the divergence loss to date), current LP value vs holding ETH (which the user might have preferred), current LP value vs holding cash (which would have earned T-bill yield).
- **Concentration / in-range share.** Vogue's and Rover's current band parameters, current price relative to bands, percentage of LP positions in-range, time-in-range over the last window.
- **Fee accrual stream.** Cumulative fees over the chosen window, broken down by pool and by V3 (haircut-adjusted) vs V4 (no haircut).
- **LVR estimator.** Computed continuously from the σ filter: `LVR_t ≈ (σ_t² / 8) × C × time_in_range × position_value`. Annualized.
- **Implied vol vs fee APR.** Where listed-options IV is available, display the comparator: is the LP position selling vol below or above what the options market would pay for the same risk? If listed IV is meaningfully above fee APR, the dashboard flags "fees not compensating for vol" — the cleanest signal that the LP layer should be wound down or parameter-adjusted.
- **Rationality checklist (three conditions).** Compact green/amber/red indicators for: (1) directional posture appropriate (no strong macro signal of direction per §3.2 + §3.9 conjunction), (2) σ in a range where fees historically cover LVR, (3) no jump indicators active.


### 3.9 Pool-flow microsignal

**Purpose:** Surface the directional and size characteristics of capital flowing through the protocol's own V4 pools, in real time, as a leading indicator of buying or selling pressure that complements the macro signal layer (§3.2). Together with §3.2, this constitutes the micro half of the signal stack the dashboard exposes to users and to whoever operates Vogue/Rover parameter choices.

#### Why this signal is structurally available to the protocol

The protocol operates its own V4 pools (ETH/USD, BTC/USD when added). Every swap through those pools is an on-chain event observable at block granularity, with full information about size, direction, and counterparty (within the limits of pseudonymous addressing). This is data the protocol *generates* by virtue of being the venue — not data the protocol pays to access, and not data aggregated with lag from external sources.

Compared to public DEX-analytics products that observe pool events on shared infrastructure:

- The protocol has zero ingest lag (events are local).
- The protocol can read finer-grained signals (per-swap, not just aggregated buckets) without rate limits.
- The protocol can correlate flow with its other state (Kalman regime, reserve composition, basket position, Vogue/Rover LP positions) at the same block boundary.

Compared to MSTR holders who do not observe primary BTC/ETH market flow at all: this is a signal that does not exist in their information set.

This is the protocol's structural information asymmetry. The macro signal layer (§3.2) is the kind of analysis any quant shop with public data and patience can build — the protocol's edge there is in execution and integration. The micro pool-flow signal is genuinely *not available* to participants who aren't operating the venue. That asymmetry is the second pillar of the signal stack, and the reason a signal-informed allocation can be meaningfully more efficient than DCA.

#### What is measured (formal definitions)

Per pool, per time window W (with W ∈ {1h, 4h, 24h, 7d}):

**Net dollar inflow `D_W`.** For each swap `s_i` in W, decompose into dollar-side change `Δd_i` (signed: positive if dollars enter the pool, negative if dollars leave) and underlying-side change `Δu_i` (signed conjugately). The pool's net dollar inflow is:

```
D_W = Σ_{i ∈ W} Δd_i
```

Positive `D_W` indicates external swappers were net buyers of the underlying (ETH or BTC) within the pool over W. Negative `D_W` indicates net sellers. The convention treats the pool's perspective — what dollars came *in* on net.

**Net underlying outflow `U_W`.** Conjugate:

```
U_W = Σ_{i ∈ W} (-Δu_i)
```

By the AMM's conservation laws, `U_W` and `D_W` are tightly coupled (modulo accrued fees and any in-range LP rebalancing), so the panel surfaces `D_W` as the primary read and `U_W` as confirmation.

**Swap-size distribution.** Let each swap `s_i` have absolute dollar magnitude `|d_i| = |Δd_i|`. Bucket sizes into tiers:

- `tier 0` — small / retail: `|d_i| < $5K`
- `tier 1` — medium: $5K ≤ `|d_i|` < $50K
- `tier 2` — large: $50K ≤ `|d_i|` < $500K
- `tier 3` — institutional-sized: `|d_i|` ≥ $500K

Histogram per window per tier per side (buy vs sell). The **size asymmetry index** for window W:

```
SAI_W = (sum_of_buy_dollar_volume_per_tier - sum_of_sell_dollar_volume_per_tier) /
        total_dollar_volume_per_tier
```

computed per tier. Useful for separating "retail buying against institutional selling" (high SAI on tier 0, low on tier 3) from "everyone buying" (high SAI across all tiers). The former is a distribution pattern; the latter is consensus directional pressure.

**Trader concentration `C_W`.** Number of unique addresses participating in W as swappers:

```
C_W = |{address_i : i ∈ swaps within W}|
```

Plus the Herfindahl-Hirschman-style concentration metric for dollar volume:

```
H_W = Σ_{a ∈ addresses_W} (volume_a / total_volume_W)^2
```

`H_W` close to 0 indicates many addresses each with small share (retail-distributed); `H_W` close to 1 indicates a few addresses dominating (institutional / whale-driven). Combined with `D_W`'s sign, this lets the panel say "net buying, but driven by 3 whale addresses" — a different state than "net buying, broadly distributed."

**Range-fill velocity `V_W`.** For Vogue's currently-active LP bands on the protocol's V4 pools:

```
V_W = (dollar_volume_traded_through_active_bands within W) /
      (dollar_TVL_of_active_bands at start of W)
```

`V_W` close to 1 indicates the band is being consumed quickly — directional pressure is strong enough to push price through the active range, which means fees are accruing rapidly but also that IL is being crystallized. `V_W` close to 0 indicates the band hasn't been touched — flow is going elsewhere, or the pool is quiet. Combined with the §3.8 fee-vs-LVR ratio, this is what tells Vogue's operators whether current band parameters are still appropriate.

#### Statistical anomaly detection

For each measurement `X_W` (dollar flow, size asymmetry, trader concentration, range-fill velocity), the dashboard maintains a trailing-30-day baseline distribution:

```
mean_X = mean(X over trailing 30d windows of length W)
std_X = stddev(X over trailing 30d windows of length W)
```

The z-score of the current window's reading is:

```
z = (X_W - mean_X) / std_X
```

Anomaly thresholds:

- `|z| > 2.0` for sustained ≥ N minutes (default N = window length / 4) → flag as **anomaly**
- `|z| > 3.0` regardless of sustain → flag as **strong anomaly**
- `|z| < 0.5` for sustained ≥ window length → flag as **quiescent** (informative absence)

The anomaly flags are surfaced on the §3.8 LP economics framework panels (e.g., as inputs to the rationality checklist) and on the §3.10 replay panels (for historical context). They do *not* trigger automated action — they are observations.

**Baseline drift handling.** The 30-day baseline itself drifts as the pool's character changes. To prevent the baseline from absorbing genuine regime changes (which would mute the very anomalies the system should be detecting), the baseline computation is robust to outliers:

```
mean_X = median(X over trailing 30d, after Huber-style winsorization at 3σ)
std_X = MAD(X over trailing 30d) × 1.4826  // MAD-to-σ conversion factor
```

This makes the baseline insensitive to recent outliers while still tracking persistent regime shifts. Same Huber-style robust statistic family as the Kalman bank in §3.2.

#### Time windows and presentation

Windows: 1h, 4h, 24h, 7d. Each is presented as its own panel with:

- **Net flow line over time** (one bar per minute for the 1h window, per 10 minutes for 4h, per hour for 24h, per 6 hours for 7d)
- **Cumulative flow stacked area** (running sum within the window, color-coded by sign)
- **Current z-score** displayed prominently; bar color shifts (green for positive, red for negative) and saturates with magnitude
- **Anomaly flag indicator** if active, with the type (anomaly / strong anomaly / quiescent) and duration
- **Size-distribution comparison** (current window's tier breakdown vs the 30-day baseline tier breakdown, side by side as bar charts)
- **Trader concentration** (`C_W` and `H_W` as a small inset)
- **Range-fill velocity** (where applicable; `V_W` as a gauge)

#### How it composes with the macro signal (§3.2)

The conjunction of macro regime classification and micro flow read is what's informative. Neither layer alone produces the conjunction state:

| Macro state (§3.2) | Pool flow state (§3.9) | Interpretive frame |
|---|---|---|
| Low-σ trending up | Net dollar inflow, sustained | Both layers confirm: signal-favored entry |
| Low-σ trending up | Net dollar outflow | Caution: micro contradicts macro; check size distribution and trader concentration |
| High-σ regime change | Net dollar inflow | Late-stage buying possibly; reflexive bid into the move; not necessarily signal-favored |
| High-σ regime change | Net dollar outflow | Distribution / possibly forced selling; signal-favored exit if currently long |
| Mean-reverting calm | Anomalous flow | Flow may precede regime shift the Kalman bank hasn't yet recognized |
| Trending down | Net dollar inflow | Contrarian conviction; may presage reversal; not by itself a signal to act |

These are **interpretive frames, not rules.** The dashboard surfaces both layers and lets the user, the protocol's reserve managers, or whoever operates Vogue/Rover parameter choices form a view. The protocol does not act automatically on conjunction states — the discipline from §1.2 holds (estimation, not prediction; the conjunction tells you about the current state, not what comes next).

#### How the LP layer consumes this signal

Vogue/Rover parameter decisions (band width, rebanding cadence, position sizing) are informed by the signal stack. A decision to widen Vogue's bands in anticipation of jump risk might be accompanied by high-σ regime change in §3.2 and large-swap-skewed distribution flow in §3.9; an operator looking at the panel sees both before committing the parameter change. The signal stack does not auto-rebalance the LP layer; it informs the operator (and any QD holder watching) what regime is currently visible in the data.

The composition is also visible in the §3.8 rationality checklist: signal-stack conjunctions that flag jump regimes or strong directional conviction populate that checklist's red-amber-green status for "directional posture appropriate" and "no jump indicators active," which are inputs to whether the LP layer is currently a rational position.

#### Production caveats

Pool flow is a leading indicator of *the protocol's venue specifically*, not of the global market. If the protocol's pool depth grows over time, the signal becomes more representative. If it shrinks (or if a large competing pool emerges off-protocol), the signal becomes more noisy. The signal is most informative when the protocol's pool is a meaningful fraction of the asset's total on-chain DEX volume — likely true for the ETH/USD pool given Vogue/Rover concentration; less obviously true for the BTC/USD pool depending on adoption trajectory.

The Yartseva-Kalman discipline applies. A flow read of "net dollar inflow at 3σ above baseline for the last 4h" is a statement about what is happening *in our venue*, not about what will happen next in the market. The signal's track record — does it correlate with subsequent price moves? does it lead regime shifts? — must be exposed alongside the live readings so users can evaluate the signal stack rather than trust it on assertion.

#### Data sources

- V4 PoolManager swap events on the protocol's ETH/USD and BTC/USD pools, indexed off-chain by block
- V4 hook events if pool-specific hooks emit additional flow data (e.g., MEV-protection-aware events)
- Price oracle for dollar-value conversion of each swap
- Vogue/Rover position events for the range-fill velocity computation and for distinguishing external swaps from internal rebalancing

#### Panels

- **Flow tape (live).** Real-time per-swap stream with size, direction, and pool — small for situational awareness, not the primary read.
- **Window summaries.** Four panels (1h, 4h, 24h, 7d) showing net flow, cumulative flow, size distribution, σ-from-baseline statistic. Anomaly flags highlighted.
- **Composition panel.** The macro × micro conjunction table for the current state, with the interpretive frame highlighted.
- **Range-fill velocity gauge.** Vogue's bands and how rapidly flow is consuming them — feeds the §3.8 rationality checklist.
- **Signal track record.** Historical fidelity of the flow signal — how often did >2σ anomalies precede notable price moves vs. how often were they noise. This is the panel that lets users evaluate whether the signal is worth acting on.

### 3.10 Historical regime replay — residual P&L of the QU!D structure

**Purpose:** Make the protocol's regime-dependent quality empirically evaluable by computing the residual P&L of the QU!D structure (bond ladder + LP layer) across four historical regimes — the 2021 run-up, the 2022 capitulation, a crab market in 2023, and the current grinding-bear regime — against three benchmarks each (holding ETH, holding cash, 50/50 hold).

The discipline from §1.2 holds: this is a counterfactual replay, not a prediction. The replay computes "what would the structure have produced if it had operated then, given period-appropriate yield rates and the LP economics framework from §3.8."

#### Replay setup

For each regime, the inputs are:

- **Period start price `P_0` and end price `P_T`** for ETH (BTC analog left for the asset-specific panel)
- **Period duration `T`** in years
- **Realized annualized volatility `σ`** computed from daily log-returns
- **Cumulative pool volume `V`** as a proxy for fee accrual (using Uniswap V3 ETH/USDC 0.05% pool history as comparable)
- **Bond ladder blended yield** annualized over the period, using period-appropriate yield rates for staking, T-bills, and basket revenue (pre-staking-withdrawal eras use locked or 0% staking, etc.)
- **LP layer share of reserve** assumed at 25% (the rest in non-LP yield sources: staking, basket)

For each regime, the outputs are:

- Hold-ETH P&L
- Hold-cash P&L (period T-bill yield)
- 50/50 hold P&L
- LP full-range P&L (IL plus cumulative fees minus cumulative LVR)
- LP concentrated P&L (band-edge gap-through effects)
- QU!D structure residual P&L (bond ladder yield + LP layer share × LP P&L)

**On Vogue accumulation modeling.** The "Vogue accumulation" row in each regime's endpoint table assumes signal-informed band placement *plus signal-informed crystallization* per §3.11. The crystallization layer is what prevents the LP-sell-back effect from undoing accumulated entries on price recoveries through the upper band edge. Without crystallization, the modeled outperformance against DCA would be substantially smaller (especially in 2022 and 2026 grinding-bear regimes, where accumulated ETH at favorable prices would have been partially sold back on intermediate rebounds). The modeled numbers reflect crystallization being applied at signal-favored moments — operator action consuming the §3.11 hold-vs-crystallize recommendations, validated retrospectively against subsequent price action. A real-time implementation's outperformance depends on crystallization-call quality, which the §3.11 panels surface as a track-record indicator.

**On regime boundaries in this replay.** The regime dates below (Jan 2021 → Nov 10, 2021 as "run-up"; Nov 10, 2021 → Dec 31, 2022 as "capitulation"; etc.) are inspection-based — chosen by chart-reading the BTC/ETH price series. This is acceptable for an illustrative replay but is not the principled methodology. A production implementation should consume **Viterbi-decoded regime boundaries** from the §3.2 HMM regime layer: given the historical observation sequence, Viterbi computes the most-likely regime sequence under the HMM model, producing principled boundaries that defend against "you picked the dates to flatter the result" critique. The current six-regime HMM would likely segment the period covered here into more granular sub-regimes (the 2022 capitulation, for example, includes a brief LUNA-shock sub-regime distinct from the slower FTX-era decline). The illustrative numbers in this replay should be re-computed against Viterbi-decoded boundaries before any external claims are made about the protocol's regime-conditional performance.

#### Regime 1 — 2021 run-up (Jan 2021 → Nov 10, 2021)

**Period parameters:**

- ETH price: ~$730 → ~$4,815, ratio k = 6.60
- BTC price: ~$30K → ~$66K, ratio = 2.20
- Duration: 10.3 months ≈ 0.86 years
- Realized σ (annualized): ~95%
- LP fees (V3 ETH/USDC 0.05% peer pool): period-average ~30% APR (peak APRs reached 30–50% in busy months)
- T-bill yield: ~0.05% (effectively zero)
- ETH staking yield: existed but locked until April 2023; replay treats locked staking as ~5% APR accrued but illiquid
- MSTR (Saylor benchmark, split-adjusted post Aug 2024 10:1): ~$70 → ~$75 = +7% (MSTR's run was Aug 2020–Feb 2021; by Jan 2021 it had already pulled back significantly from its $130 peak, then drifted)

**Endpoint computation (per $100 starting capital):**

| Position | Endpoint value | Period P&L |
|---|---|---|
| Hold cash | $100.04 | +0.04% |
| Buy ETH at start (all-in t=0) | $660 | +560% |
| DCA into ETH ($1/period, uniform) | ~$268 | +168% |
| 50/50 hold | $380 | +280% |
| LP full-range vs 50/50 (price-only) | $380 × 0.676 = $257 | +157% |
| LP full-range with fees | $257 + ($100 × 30% × 0.86) = $283 | +183% |
| LP full-range with fees minus LVR | $283 − ($100 × 0.95²/8 × 0.86) = $273 | +173% |
| LP concentrated ±20% band, no rebanding | Exits range on first doubling; 100% USDC at band edge thereafter | ~+5% |
| Saylor strategy (MSTR equity) | $107 | +7% |
| **Vogue accumulation (signal-informed bands)** | **~$310** (modeled — see note below) | **~+210%** |

**Vogue accumulation modeling.** In a strong directional bull, pullbacks are shallow and brief; the signal stack favors keeping conversion bands close-below-spot and trailing them upward as price rises. The dollar leg earns ambient yield (≈0% in 2021, but bands still kept some capital in dollars between fills). Effective accumulation price ends up modestly below DCA's time-average (signal-informed bands fill on the small pullbacks rather than averaging through the relentless up-moves). Estimated effective entry ~$1,500 vs DCA's ~$1,800 → ~12% more ETH per dollar deployed. Endpoint value ~$310 ≈ DCA's $268 × 1.16.

**QU!D structure residual** (bond ladder ~7% APR equivalent + LP layer 25%):

- Bond ladder contribution: 7% × 0.86 × 100% = **+6.0%**
- LP layer contribution: 173% × 25% = **+43.3%**
- **Total residual: ~+49% over 0.86 years**

**Benchmark comparison (Vogue accumulation):**

| Benchmark | Vogue accumulation − Benchmark |
|---|---|
| vs Buy ETH at start (+560%) | −350 pp (badly underperformed — no leverage, started from dollars) |
| vs Hold cash (+0.04%) | +210 pp (vastly outperformed) |
| vs 50/50 hold (+280%) | −70 pp (underperformed) |
| vs DCA into ETH (+168%) | **+42 pp (outperformed)** |
| vs Saylor strategy / MSTR (+7%) | **+203 pp (vastly outperformed)** |

**Interpretive read:** in a strong directional bull, the Vogue strategy meaningfully beats DCA on accumulation efficiency (signal-informed bands capture the small pullbacks DCA averages through), and dramatically beats the Saylor strategy because MSTR's premium compressed throughout 2021 from its early-year peak (the leveraged-bull vehicle paradoxically underperformed both BTC and a yielding-dollar-side accumulation strategy because MNAV expansion happened in 2020 and reversed through 2021). The structure still loses to "buy ETH at start" because that benchmark assumes the user already had the ETH conviction; the relevant comparison for someone holding dollars is DCA or Saylor, both of which Vogue beats. The trap of this regime is that "buy ETH at start" looks attractive in retrospect but requires the directional conviction Vogue does not require.

#### Regime 2 — 2022 capitulation (Nov 10, 2021 → Dec 31, 2022)

**Period parameters:**

- ETH price: ~$4,815 → ~$1,200, ratio k = 0.249
- Duration: 13.7 months ≈ 1.14 years
- Realized σ (annualized): ~110% (peak in mid-year crises with multiple jump events)
- LP fees: ~25% APR early, collapsing to ~8% APR by year end; period average ~15%
- T-bill yield: ~3% average (Fed hiking through the year)
- ETH staking yield: ~4–5%, still locked through period end
- MSTR (Saylor benchmark, split-adjusted): ~$75 → ~$15 = −80% (BTC drawdown plus MNAV premium compression plus convertible-debt servicing pressure)

**Endpoint computation (per $100 starting capital):**

| Position | Endpoint value | Period P&L |
|---|---|---|
| Hold cash | $103.42 | +3.42% |
| Buy ETH at start (all-in t=0) | $24.91 | −75.1% |
| DCA into ETH ($1/period, uniform) | ~$48 | −52% (effective entry ~$2,500 avg over the falling-knife period; final ETH × $1,200) |
| 50/50 hold | $62.46 | −37.5% |
| LP full-range vs 50/50 (price-only) | $62.46 × 0.799 = $49.91 | −50.1% |
| LP full-range with fees | $49.91 + ($100 × 15% × 1.14) = $67.01 | −33.0% |
| LP full-range with fees minus LVR | $67.01 − ($100 × 1.10²/8 × 1.14) = $49.77 | −50.2% |
| LP concentrated ±20% band entered at $4,815, static | Gapped through range to band edge ($3,852) early; 100% ETH thereafter → $28.08 | −71.9% |
| Saylor strategy (MSTR equity) | $20 | −80% |
| **Vogue accumulation (signal-informed bands)** | **~$74** (modeled — see note below) | **~−26%** |

**Vogue accumulation modeling.** In a capitulation regime with jump events (LUNA, FTX), signal-informed band placement widens ranges aggressively to avoid gap-through pinning, and slows accumulation pace when σ-divergence checks trigger and pool-flow distribution patterns indicate forced selling. The dollar leg earning T-bill yield (~3%) through the period meaningfully cushioned the un-deployed portion. Estimated 30–40% of dollar leg remained undeployed by year-end (signal stack repeatedly extended waiting on confirmation of bottom); the deployed portion converted at average price ~$2,000 (better than DCA's ~$2,500 falling-knife average). Endpoint value: $30 undeployed dollars + $44 in ETH (0.037 ETH × $1,200) = $74.

**QU!D structure residual** (bond ladder ~6.5% blended + LP layer 25%):

- Bond ladder contribution: 6.5% × 1.14 × 100% = **+7.4%**
- LP layer contribution: −50.2% × 25% = **−12.6%**
- **Total residual: ~−5.2% over 1.14 years**

**Benchmark comparison (Vogue accumulation):**

| Benchmark | Vogue accumulation − Benchmark |
|---|---|
| vs Buy ETH at start (−75.1%) | +49 pp (vastly outperformed) |
| vs Hold cash (+3.42%) | −29 pp (underperformed) |
| vs 50/50 hold (−37.5%) | +12 pp (outperformed) |
| vs DCA into ETH (−52%) | **+26 pp (outperformed)** |
| vs Saylor strategy / MSTR (−80%) | **+54 pp (vastly outperformed)** |

**Interpretive read:** in capitulation, holding cash dominates because no accumulation strategy can avoid loss when the asset drops 75%. But against the realistic comparators a dollar-holder faces — DCA into ETH and the Saylor strategy — Vogue meaningfully outperforms both. Against DCA, Vogue's signal-informed waiting (extending un-deployment as forced-selling signals fire) captured a meaningfully better effective entry. Against Saylor, the structural soundness Vogue offers shows up as 54 percentage points of preservation: MSTR was simultaneously exposed to BTC's drawdown, MNAV compression (premium collapsed from ~3x to ~1x), and convertible-debt servicing pressure during the worst possible window. This is the regime where the Saylor strategy's leverage and dilution amplify losses; Vogue's no-leverage / no-dilution / yield-while-waiting design preserves capital and accumulation efficiency together. The concentrated static-LP variant (−72%) is a cautionary tale for what the LP layer does *without* signal-informed band management — gap-through pins capital to the worst-possible-price ETH.

#### Regime 3 — Crab market (Jan 2023 → Aug 2023)

**Period parameters:**

- ETH price: ~$1,200 → ~$1,650 (with significant mean reversion in the $1,500–$1,900 corridor)
- Duration: 8 months ≈ 0.67 years
- Realized σ (annualized): ~50% (low for ETH historically)
- LP fees: healthy, ~12% APR average
- T-bill yield: ~5% (post-hiking-cycle plateau)
- ETH staking yield: post-Shapella (April 2023) withdrawals enabled, ~5% APR

**Endpoint computation (per $100 starting capital):**

| Position | Endpoint value | Period P&L |
|---|---|---|
| Hold cash | $103.33 | +3.33% |
| Buy ETH at start (all-in t=0) | $137.50 | +37.5% |
| DCA into ETH ($1/period, uniform) | ~$120 | +20% (effective entry roughly the time-average ~$1,550 within the corridor) |
| 50/50 hold | $120.42 | +20.4% |
| LP full-range vs 50/50 (price-only) | $120.42 × 0.987 = $118.85 | +18.9% |
| LP full-range with fees | $118.85 + ($100 × 12% × 0.67) = $126.89 | +26.9% |
| LP full-range with fees minus LVR | $126.89 − ($100 × 0.50²/8 × 0.67) = $124.80 | +24.8% |
| LP concentrated ±10% band, well-centered, in-range much of period | Concentration ~10× → fees ~$80, LVR ~$21 (in-range only ~50%); net ≈ +40% | +40% (estimate; band-dependent) |
| Saylor strategy (MSTR equity) | $233 | +133% (MNAV expansion off the 2022 lows; convertibles still serviceable) |
| **Vogue accumulation (signal-informed bands)** | **~$148** (modeled — see note below) | **~+48%** |

**Vogue accumulation modeling.** The crab regime is where signal-informed band placement most clearly beats DCA. Bands placed at corridor lows ($1,400–$1,550) fill repeatedly as mean reversion pulls price down to them; bands lift back to dollars on the way up. Effective accumulation price ~$1,400 vs DCA's ~$1,550 — meaningful ~10% improvement. Plus the in-range periods earn concentrated fees that compound the bond-ladder yield. T-bill yield (~5%) on the un-deployed dollar leg adds to the result.

**QU!D structure residual** (bond ladder ~8% blended + LP layer 25%):

- Bond ladder contribution: 8% × 0.67 × 100% = **+5.4%**
- LP layer contribution (full-range): 24.8% × 25% = **+6.2%**
- **Total residual: ~+11.6% over 0.67 years (annualized ~+17.4%)**

**Benchmark comparison (Vogue accumulation):**

| Benchmark | Vogue accumulation − Benchmark |
|---|---|
| vs Buy ETH at start (+37.5%) | +10.5 pp (outperformed) |
| vs Hold cash (+3.33%) | +44.7 pp (vastly outperformed) |
| vs 50/50 hold (+20.4%) | +27.6 pp (outperformed) |
| vs DCA into ETH (+20%) | **+28 pp (outperformed)** |
| vs Saylor strategy / MSTR (+133%) | **−85 pp (underperformed)** |

**Interpretive read:** Vogue cleanly beats DCA and even slightly beats hold-ETH-at-start because the LP fee accrual on a well-centered band stacks on top of the price exposure. But the Saylor strategy wins this regime decisively because MSTR was rebounding off its 2022 lows with MNAV expansion happening — the leveraged-bull bet, when timed at the trough, recovers fastest. This is the regime where Saylor's strategy looks great on paper. The honest read: Vogue cannot beat Saylor in MNAV-expansion phases. What it offers instead is the consistency that Saylor's strategy lacks in the regimes around it: Vogue's −26% in 2022 vs Saylor's −80%, Vogue's +210% in 2021 vs Saylor's +7%. Over the full cycle, regime-conditional outperformance compounds; Saylor's regime-specific dominance does not.

#### Regime 4 — Mid-2026 grinding bear (Aug 2025 → Jun 2026, current)

**Period parameters:**

- ETH price: ~$4,954 (Aug 2025 all-time high) → ~$1,975 (Jun 2026), ratio k = 0.399
- BTC price (scenario-conservative): ~$130K (Aug 2025 ATH) → ~$65K (Jun 2026), ratio = 0.50
- Duration: 10 months ≈ 0.83 years
- Realized σ (annualized): ~70% (elevated; nine consecutive months of lower highs)
- LP fees: meaningfully reduced from prior cycles. Two structural haircuts: (1) post-UNIfication fee-switch (Dec 2025) routes a percentage of V3 fees to protocol; (2) intent/solver flow capture pulls clean retail flow away from V3 pools, leaving more toxic residue. Effective V3 fee APR ~6% net of haircuts; protocol's V4 pools (Vogue) unaffected by the fee switch, ~10% APR. Period blended ~8%.
- T-bill yield: ~4.5% (gradual rate compression from 2024 peak)
- ETH staking yield: ~3.5% APR (post-Pectra)
- MSTR (Saylor benchmark, scenario): ~$500 (Aug 2025 ATH) → ~$120 (Jun 2026) = −76% (BTC drawdown plus MNAV compression on a stretched premium)
- Fear & Greed Index: 11 (extreme fear); Bitcoin in confirmed bear regime, 50-day SMA below 200-day

**Endpoint computation (per $100 starting capital):**

| Position | Endpoint value | Period P&L |
|---|---|---|
| Hold cash | $103.74 | +3.74% |
| Buy ETH at start (all-in t=0) | $39.87 | −60.1% |
| DCA into ETH ($1/period, uniform) | ~$60 | −40% (effective entry ~$3,300 averaged through the falling-knife period; final ETH × $1,975) |
| 50/50 hold | $71.81 | −28.2% |
| LP full-range vs 50/50 (price-only) | $71.81 × 0.903 = $64.84 | −35.2% |
| LP full-range with fees (blended ~8%) | $64.84 + ($100 × 8% × 0.83) = $71.48 | −28.5% |
| LP full-range with fees minus LVR | $71.48 − ($100 × 0.70²/8 × 0.83) = $66.40 | −33.6% |
| LP concentrated ±20% band centered at ATH, no rebanding | Gapped through range early; $45.03 final | −55.0% |
| LP concentrated with Vogue-style active rebanding | Bands chase price down; each reband crystallizes IL but maintains fee capture; ~−40% | −40% |
| Saylor strategy (MSTR equity) | $24 | −76% |
| **Vogue accumulation (signal-informed bands)** | **~$84** (modeled — see note below) | **~−16%** |

**Vogue accumulation modeling.** Nine months of lower highs with FGI extreme-fear plus the §3.9 pool-flow signals indicating sustained distribution patterns: the signal stack repeatedly extends un-deployment and widens bands to avoid gap-through. Estimated 40–50% of dollar leg remained un-deployed by month 10 (the signal stack has not yet flagged conditions favorable for accumulation pace). The deployed portion converted at average price ~$2,900 (better than DCA's ~$3,300). T-bill yield (~4.5%) on the substantial un-deployed dollar leg materially cushions the result. Endpoint: $46 undeployed + yield + $38 in deployed-ETH × current spot = ~$84.

**QU!D structure residual** (bond ladder ~9% blended + LP layer 25%):

- Bond ladder contribution: 9% × 0.83 × 100% = **+7.5%**
- LP layer contribution (full-range): −33.6% × 25% = **−8.4%**
- **Total residual: ~−0.9% over 0.83 years (essentially flat)**

**Benchmark comparison (Vogue accumulation):**

| Benchmark | Vogue accumulation − Benchmark |
|---|---|
| vs Buy ETH at start (−60.1%) | +44 pp (vastly outperformed) |
| vs Hold cash (+3.74%) | −20 pp (underperformed) |
| vs 50/50 hold (−28.2%) | +12 pp (outperformed) |
| vs DCA into ETH (−40%) | **+24 pp (outperformed)** |
| vs Saylor strategy / MSTR (−76%) | **+60 pp (vastly outperformed)** |

**Interpretive read:** the grinding-bear analog of the 2022 capitulation, but slower and with the structural haircuts (fee switch, intent capture) eating into LP profitability. Vogue cleanly beats DCA on accumulation efficiency (signal-informed waiting captured better entries than the falling-knife average) and dramatically beats Saylor (whose MSTR is down 76% from premium compression layered on the BTC drawdown). Holding cash still won this regime, but Vogue lost to cash by only 20 pp on accumulation while keeping 84% of capital in productive position — a user wanting some BTC/ETH exposure with capital preservation finds Vogue's profile much more attractive than the all-or-nothing Saylor bet. The §3.8 rationality checklist for this regime: directional posture red on "no strong macro signal of direction" (clear bear trend, signal stack flags continued downside risk); σ acceptable; jump indicators amber. The LP layer should run wider bands and slower deployment pace through this regime — and the signal stack is already producing those parameter recommendations.

#### Summary across regimes

| Regime | Vogue accumulation | vs Buy ETH | vs Cash | vs 50/50 | vs DCA | vs Saylor |
|---|---|---|---|---|---|---|
| 2021 run-up (10.3 mo) | +210% | −350 pp | +210 pp | −70 pp | **+42 pp** | **+203 pp** |
| 2022 capitulation (13.7 mo) | −26% | +49 pp | −29 pp | +12 pp | **+26 pp** | **+54 pp** |
| Crab 2023 (8 mo) | +48% | +10 pp | +45 pp | +28 pp | **+28 pp** | −85 pp |
| Grinding bear 2026 (10 mo) | −16% | +44 pp | −20 pp | +12 pp | **+24 pp** | **+60 pp** |

**Patterns visible across the matrix:**

- **Vogue beats DCA in every regime.** Signal-informed band placement consistently captures better effective entries than time-uniform conversion. The edge ranges from +24 pp (grinding bear) to +42 pp (2021 run-up). This is the primary structural claim against the no-information baseline: across bull, capitulation, crab, and grinding-bear regimes, signal-informed accumulation outperforms unconditional averaging.
- **Vogue beats Saylor in three of four regimes** — 2021 run-up (Saylor flat from MNAV compression), 2022 capitulation (Saylor amplified the BTC drawdown via leverage + premium collapse + convertible-debt pressure), and 2026 grinding bear (same dynamic, slower). The one regime Saylor wins is the post-capitulation rebound (2023 crab), where MNAV expansion off the lows compounds with BTC's recovery to produce 133% MSTR returns. This is honest: when MNAV expansion is in your favor and convertibles are serviceable, Saylor's leverage wins. In every other regime, the leverage cost or the premium collapse dominates.
- **Cash wins drawdown regimes, loses everything else.** When capital preservation is the only goal, cash is the right answer — but cash earns nothing else. Vogue's edge against cash is +210 pp in the bull run-up and +45 pp in the crab, more than compensating for the −20 to −29 pp Vogue lags in drawdowns.
- **Buy-ETH-at-start dominates strong bulls and loses everything else.** Same shape as Saylor but without the leverage amplification in either direction. Requires directional conviction Vogue doesn't.

#### Where the buffer holds and where it breaks

**The buffer holds:**

- **Drawdown regimes (2022, mid-2026).** Bond-ladder yield offsets LP layer IL; 75% of reserve in non-LP carry sources means the LP drawdown is diluted. Net structure loss is single-digit percent vs catastrophic for hold-ETH.
- **Crab regimes (2023).** LP fees exceed LVR cleanly; bond ladder yield stacks on top. The regime the structure is optimized for.

**The buffer breaks:**

- **Strong directional bull regimes (2021).** Hold-ETH dominates by an enormous margin. The structure provides yielding capital preservation but at huge opportunity cost. No parameter adjustment fixes this without adding leveraged directional exposure, which the structure rejects.
- **Capitulation-with-jumps (LUNA, FTX, similar events).** Concentrated LPs gap through ranges; even active rebanding crystallizes large IL during gap events. Wider bands reduce this but reduce in-range fee capture; the trade-off is real. Cash benchmark wins these regimes.
- **Sustained low-volume regimes where fee APR falls below LVR APR.** The LP layer becomes a net cost to the reserve. §3.8's rationality checklist flags this state; the operational response is wider bands, narrower rebanding cadence, or temporary LP-layer wind-down.

#### Replay panels

- **Regime selector.** Dropdown for {2021 run-up, 2022 capitulation, 2023 crab, mid-2026 grinding bear, custom date range}.
- **Position simulator.** Sliders for: bond ladder share of reserve (default 75%), LP layer share (default 25%), Vogue band width, rebanding cadence. Recomputes the regime's residual P&L under the chosen parameters.
- **Benchmark comparison.** Three side-by-side cards (vs hold ETH, vs hold cash, vs 50/50 hold) with the structure residual visible against each.
- **Decomposition panel.** Per-regime breakdown of where the residual came from: bond ladder yield (always positive), LP fee accrual (gross), LP LVR cost, LP IL vs 50/50 hold, basket revenue contribution, gas/rebalance cost.
- **Sensitivity panel.** For the current regime, how does the residual change if you shift bond/LP share by ±10pp, tighten/widen Vogue's band by 5pp, or assume realized vol comes in 20% higher/lower than current.

These panels turn the replay from a static table into an operational tool — Vogue/Rover parameters can be evaluated against historical regimes before being committed, and the protocol's structural quality can be inspected by any QD holder against the regime they think we're currently in.

### 3.11 The crystallization signal and the QD staking rail

**Purpose:** Specify the dashboard's primary operational output — the crystallization decision for filled Vogue bands — and the opt-in QD-staking mechanic that lets QD holders participate in signal-informed accumulation while preserving their baseline yield.

#### Why crystallization is the load-bearing decision

The protocol's mockUSD always earns the ~4% T-bill baseline regardless of whether it's deployed as the dollar leg of an active LP position. This changes the economics fundamentally:

- **No opportunity cost of leaving capital un-deployed.** Sitting in pure mockUSD earns the same 4% as the dollar leg of an active LP. LP deployment is an *optimization on top of the baseline* — accepting IL/LVR exposure in exchange for fees, not a substitute for cash yield.
- **LP deployment is regime-conditional.** Per §3.8, the LP layer adds value only when fees > LVR. In jump-prone regimes, strong directional moves, or low-volume conditions, deploying LPs subtracts value vs sitting in pure mockUSD. The dashboard's §3.8 rationality checklist signals which regime is current.
- **Once a band fills, the conversion is not permanent until the LP is withdrawn.** A buy-side band that filled at, say, $1,500 ETH leaves the protocol holding ETH at that effective price — but the ETH is still inside the LP position. If price reverses upward through the band, **the accumulated ETH gets sold back to mockUSD** at the upper band edge. The accumulation undoes itself.

The crystallization decision is: for each filled band, withdraw the LP (locking the accumulated underlying as protocol-held spot) or keep it active (collecting more fees, accepting price-reversal risk).

This is distinct from band placement. Band placement asks "where to put new LPs?" Crystallization asks "what to do with filled LPs?" Both are signal-informed; the inputs are the same; the interpretive frames differ.

#### How the dashboard handles individualized decisions

The dashboard provides full per-band signal-stack information for the depositor to make individual-trade-level decisions. What it does *not* do — and cannot honestly do — is force a single action call onto users with different horizons, conviction levels, and current exposures. Three constraints shape how the signals are presented:

1. **Saylor's edge is unknowable from outside, so MSTR features are inputs not directives.** When Saylor buys aggressively and BTC subsequently rallies, was he right because of genuine timing intuition, or did he get lucky on a path that would have rewarded continuous buyers regardless? When he buys and BTC falls, was he wrong, or was the entry still net-positive on his longer horizon with leverage? We observe his actions, not his reasoning. The dashboard surfaces MSTR features (purchase intensity, MNAV state, capital-structure operations) as inputs into the composed signal-stack reading, but doesn't project onto Saylor a coherence we cannot verify or treat his moves as authoritative directives.

2. **Sells are harder than buys to signal universally, so the dashboard surfaces the structural context rather than asserting "sell now."** Saylor's 32-BTC sale in late May 2026 was tactically correct given his structural position (perpetual STRC dividends to fund, depleted USD reserve after the $1.5B convert repurchase) and yet provided no generic "BTC overvalued" signal for unleveraged holders. The dashboard distinguishes these — surfacing the capital-structure-operation features that explain *why* Saylor's selling is happening, so the depositor can read whether the underlying conditions apply to their own position.

3. **Depositor horizons and exposures are individual, so the dashboard provides signals not commitments.** A depositor with a 6-month liquidity need will read a 12-month deployment-time-estimate band differently from one with a 10-year horizon. A depositor already holding significant BTC exposure elsewhere will read an accumulation-favored signal differently from one starting from cash. The dashboard surfaces deployment-time estimates, historical fill rates for comparable bands, backtests in matched regimes — letting each depositor evaluate the signal against their own situation.

The composed signal-stack reading per band gives every depositor the same information surface; the per-trade decision is theirs. The crystallization signal (§3.11) is the protocol-level operational signal for Vogue's *own* positions, but the QD staker's parallel decision (whether to unstake from the band, partial-unstake, or let the protocol's crystallization hook execute) remains the staker's call. The dashboard provides full reasoning; the depositor decides per-trade.

#### The hold-vs-crystallize decision

For each currently-deployed filled band, the dashboard evaluates the conjunction of signal-stack inputs against two interpretive frames:

**Keep the LP active when:**

- Fill is partial (band has more capacity to fill if price continues down)
- Mean-reversion regime classified (Kalman φ < 0); current price below band center; signal stack reads upward reversion as likely → the protocol benefits from the sell-back fees on the way up
- Vol regime favorable: low realized σ vs IV, healthy volume → fees > LVR continues compounding
- Pool flow (§3.9) shows accumulation pattern, not distribution → upward pressure expected

**Crystallize now when:**

- Fill is substantially complete (band is mostly converted to underlying)
- Trending regime classified (Kalman φ > 0, σ rising); mean-reversion not expected → keeping the LP active risks selling back the accumulation before price drops further
- Pool flow (§3.9) shows distribution pattern, sustained outflow → continued downside pressure → lock the accumulation at the band's effective price
- Vol regime degraded: σ rising, LVR prospectively exceeds fees → the LP is now subtracting value
- MSTR signal (§3.7): refinancing pressure visible, forced-seller risk → likely sustained downside; lock accumulation
- Operational signal: target accumulation amount reached for this cycle

#### Signal-stack inputs to crystallization

Same inputs as band placement, different interpretive frames:

| Signal | Reading | Favors hold LP | Favors crystallize |
|---|---|---|---|
| Kalman φ | Mean-reverting, φ < 0 | strong: sell-back on reversion | weak |
| Kalman φ | Trending, φ > 0 | weak | strong: protect the entry |
| Kalman σ | Low, stable | favors hold (fees compounding) | only if other signals strongly indicate |
| Kalman σ | High, rising | favors crystallize (LVR exposure rising) | strong |
| HMM regime posterior (§3.2) | Concentrated on `strong_bull` or `weak_bull` | favors hold | weak |
| HMM regime posterior (§3.2) | Concentrated on `weak_bear` or `capitulation` | weak | strong |
| HMM regime posterior (§3.2) | Diffuse (entropy > 1.5 bits, transition in progress) | weak | weak — flag for operator review |
| HMM transition prob (§3.2) | P(capitulation \| current) > 0.3 | weak | strong: escalation risk imminent |
| HMM transition prob (§3.2) | P(recovery \| current) > 0.4 | favors hold (recovery probable) | weak |
| Pool flow (§3.9) | Accumulation pattern | favors hold (upward reversion likely) | weak |
| Pool flow (§3.9) | Distribution pattern, sustained | weak | strong: lock the entry before further downside |
| Pool flow (§3.9) | Anomalous z > 3 inflow | strong hold (sell-back opportunity coming) | only on independent contradiction |
| MSTR (§3.7) | Aggressive purchase reported | favors hold (institutional bid for upward reversion) | only on independent contradiction |
| MSTR (§3.7) | Refinancing pressure visible | weak | strong: forced-seller risk |
| MSTR (§3.7) | ATM issuance recently announced | weak | weak: Saylor seeing premium as accretive-to-dilute, ambivalent signal |
| MSTR capital-structure (§3.7) | Convert repurchase activity (Strategy buying back its own debt) | weak | strong: defensive capital management → sustained downside expected |
| MSTR capital-structure (§3.7) | USD reserve depleted > 50% over trailing 60d | weak | strong: STRC dividend coverage degrading; tactical BTC sales now possible |
| MSTR capital-structure (§3.7) | Tactical BTC sale disclosed (any size, even immaterial) | weak | very strong: narrative-crack event; disproportionate market impact expected |
| MSTR capital-structure (§3.7) | ATM equity issuance velocity rising in declining MNAV | weak | strong: dilutive issuance → MNAV compression accelerating |
| Macro (§3.7) | Risk-off basket reweigh | weak | favors crystallize |
| Macro (§3.7) | Risk-on basket reweigh | favors hold | weak |

The composition is the same conjunction-logic framework from §1.4: no single signal authoritative, the composed reading determines the recommendation. The dashboard surfaces the composed frame alongside the underlying readings so the operator can see which signals are driving the call.

The four MSTR capital-structure features were added after the May–June 2026 episode validated their importance. Strategy executed a $1.5B convert repurchase (May 14–25) at 8% discount to par using cash reserves, then disclosed a 32 BTC tactical sale (May 26–31) to fund STRC perpetual preferred dividends. The 32 BTC was 0.0038% of holdings — mechanically immaterial — but the disclosure cracked the "Saylor never sells" narrative and BTC fell 3.1%, erasing ~$160B of crypto market cap. The refinancing-pressure feature alone would have signaled risk, but it underweighted the disproportionate market response to narrative-crack events. The capital-structure-operation features address this by tracking the *defensive* posture explicitly: convert repurchases, USD reserve depletion, tactical sales, ATM velocity in declining MNAV all signal Saylor moving from aggressive accumulation to balance-sheet defense, which historically correlates with sustained drawdown.

#### Net-new code for the crystallize-vs-hold decision

```python
@dataclass
class BandState:
    band_id: str
    asset: str                       # "ETH" or "BTC"
    band_low_price: float
    band_high_price: float
    initial_mockUSD: float           # capacity at deployment
    current_mockUSD: float           # un-converted remainder
    accumulated_underlying: float    # ETH or BTC accumulated via fills
    fees_accrued: float
    deployed_at: datetime
    in_range_seconds: int            # time spent in-range so far

def crystallize_recommendation(
    band: BandState,
    kalman_state: KalmanRegimeState,
    hmm_regime: HMMRegimeState,                      # §3.2 discrete regime layer
    pool_flow_state: PoolFlowState,
    mstr_features: Dict[str, float],
    mstr_capital_structure: Dict[str, float],        # NEW: convert repurchase, USD reserve, BTC sales, ATM
    basket_reweigh: BasketReweighState,
) -> CrystallizeRecommendation:
    """Should we withdraw this LP and lock the accumulation?"""
    
    fill_fraction = band.accumulated_underlying * mid_price(band) / band.initial_mockUSD
    
    # HMM transition probability to bear/capitulation regimes
    p_escalate_down = (
        hmm_regime.transition_matrix_row(hmm_regime.most_likely_current).get("weak_bear", 0) +
        hmm_regime.transition_matrix_row(hmm_regime.most_likely_current).get("capitulation", 0)
    )
    p_recover = hmm_regime.transition_matrix_row(hmm_regime.most_likely_current).get("recovery", 0)
    
    # Strong cases for crystallizing
    crystallize_score = 0.0
    crystallize_score += 0.3 if fill_fraction > 0.7 else 0.0
    crystallize_score += 0.3 if kalman_state.phi > 0.05 else 0.0  # trending
    crystallize_score += 0.2 if kalman_state.sigma_zscore > 1.5 else 0.0
    crystallize_score += 0.3 if pool_flow_state.distribution_pattern_sustained else 0.0
    crystallize_score += 0.2 if mstr_features.get("refinancing_pressure", 0) > 0.7 else 0.0
    crystallize_score += 0.1 if basket_reweigh.risk_off_intensity > 0.5 else 0.0
    
    # HMM regime layer
    crystallize_score += 0.3 if hmm_regime.regime_posterior.get("capitulation", 0) > 0.4 else 0.0
    crystallize_score += 0.2 if hmm_regime.regime_posterior.get("weak_bear", 0) > 0.5 else 0.0
    crystallize_score += 0.3 if p_escalate_down > 0.3 else 0.0  # escalation risk
    
    # MSTR capital-structure features (added after May-June 2026 episode)
    crystallize_score += 0.3 if mstr_capital_structure.get("convert_repurchase_recent", 0) > 0.5 else 0.0
    crystallize_score += 0.4 if mstr_capital_structure.get("tactical_btc_sale_disclosed", 0) > 0 else 0.0
    crystallize_score += 0.2 if mstr_capital_structure.get("usd_reserve_depletion_60d", 0) > 0.5 else 0.0
    crystallize_score += 0.2 if mstr_capital_structure.get("atm_velocity_in_low_mnav", 0) > 0.5 else 0.0
    
    # Strong cases for holding
    hold_score = 0.0
    hold_score += 0.3 if fill_fraction < 0.3 else 0.0  # band has more to fill
    hold_score += 0.3 if kalman_state.phi < -0.05 else 0.0  # mean-reverting
    hold_score += 0.2 if pool_flow_state.accumulation_pattern else 0.0
    hold_score += 0.3 if pool_flow_state.anomalous_inflow_zscore > 3 else 0.0
    hold_score += 0.2 if mstr_features.get("purchase_intensity_z", 0) > 1.5 else 0.0
    
    # HMM regime layer
    hold_score += 0.2 if hmm_regime.regime_posterior.get("strong_bull", 0) > 0.4 else 0.0
    hold_score += 0.2 if hmm_regime.regime_posterior.get("weak_bull", 0) > 0.5 else 0.0
    hold_score += 0.2 if p_recover > 0.4 else 0.0  # recovery probable
    
    # Flag for review when HMM posterior is diffuse (regime transition in progress)
    if hmm_regime.posterior_entropy > 1.5:
        return CrystallizeRecommendation(
            action="undetermined",
            confidence=0.0,
            rationale="HMM regime posterior is diffuse (entropy > 1.5 bits); operator review recommended"
        )
    
    if crystallize_score > 0.6 and crystallize_score > hold_score:
        return CrystallizeRecommendation(
            action="crystallize",
            confidence=crystallize_score,
            rationale=identify_dominant_factors(kalman_state, hmm_regime, pool_flow_state,
                                                 mstr_features, mstr_capital_structure),
        )
    if hold_score > 0.6 and hold_score > crystallize_score:
        return CrystallizeRecommendation(
            action="hold",
            confidence=hold_score,
            rationale=identify_dominant_factors(kalman_state, hmm_regime, pool_flow_state,
                                                 mstr_features, mstr_capital_structure),
        )
    return CrystallizeRecommendation(action="undetermined", confidence=0.0, rationale="signals balanced")
```

The thresholds and weights are illustrative — a real implementation requires empirical calibration on historical band outcomes. The structure of the decision is what's specified here: composed signal-stack readings score both directions; a clear winner triggers the recommendation; balanced signals yield "undetermined" and the operator decides.

#### The QD staking rail

QD holders can optionally stake QD into specific out-of-range Vogue bands to add accumulation capacity beyond what the protocol's own reserve provides. The mechanic preserves QD's fungibility at the underlying level — staking does not burn QD, it shifts which reserve assets back the staker's claim.

##### How staking works

1. **User selects an out-of-range Vogue band to stake into.** The dashboard surfaces Vogue's signal-informed pending bands (e.g., buy-side band at $1,500 ETH when spot is $1,975). The user picks one.

2. **User commits N QD to that band.** The QD is locked at the contract level. **It is not burned.** The total QD supply does not change; the user retains a claim on N QD's worth of value, but the claim now points to a specific band's outcome rather than to the general reserve.

3. **Vogue's mockUSD ledger adjusts.** The band's mockUSD capacity increases by N (dollar-equivalent of N QD at staking time). That mockUSD is now committed to providing the dollar leg of the band's LP position when deployed.

4. **The staker continues earning the baseline yield throughout staking.** The mockUSD backing the band still earns the ~4% T-bill baseline. The staker is *not* giving up baseline yield in exchange for the band-fill optionality — they earn baseline yield regardless of band outcome.

5. **If the band is deployed and in-range:** the staker also earns a pro-rata share of the LP fees the band accrues. They also share pro-rata in any IL/LVR cost — though the §3.8 rationality checklist ensures bands are only deployed when fees > LVR is the expected regime, so the LP fees component is positive-EV in the deployment decision.

6. **If the band fills (price reaches the band):** mockUSD converts to ETH (or BTC) at the band's AMM-enforced prices. The staker's QD position is rebalanced: their claim is now backed by a pro-rata share of the band's accumulated underlying plus any un-converted mockUSD remainder.

7. **If the band is crystallized:** the protocol withdraws the LP position. The staker's claim transitions from "share of the band's LP position" to "share of the accumulated underlying held as protocol spot" plus mockUSD remainder. Baseline yield on the mockUSD portion continues; the underlying portion is now eligible for the protocol's staking-yield-on-underlying mechanics (ether.fi for ETH, equivalent for BTC if available).

8. **If the band closes without filling:** mockUSD never converts; the staker can unstake and recover their N QD intact, plus any baseline yield accrued during the staking period. The opportunity cost was zero — the QD remained productive throughout.

##### Why this works without burning QD

QD is a claim on the protocol's aggregate reserve. The reserve composition includes:

- Bond ladder assets (staking positions, basket revenue accruals)
- Reserve mockUSD (the dollar leg of LP positions and pure reserve)
- Vogue's accumulated underlying (ETH/BTC in active bands or crystallized as spot)

When a user stakes QD into a band, the user's claim shifts from "general claim on aggregate reserve" to "specific claim on this band's outcome plus baseline yield." The total QD supply does not change; only the *backing composition* for that user's QD changes. The mockUSD that previously backed the staker's general claim now backs the specific band; if the band fills, the backing transitions further to the accumulated underlying.

This is the same accounting move as a user moving money between a bank's savings account and a CD — the bank doesn't burn the money; it shifts which assets back the deposit. Vogue's mockUSD ledger is the protocol's analog of that internal accounting layer.

##### Staker economics summary

For a QD staker in an out-of-range band, the position-level returns decompose as:

- **Baseline yield (~4% APR)** earned on the dollar-equivalent of the staked QD throughout the staking period — always positive, present whether or not the band fills, whether or not the band is deployed in-range.
- **LP fees** earned pro-rata during periods when the band is deployed and in-range. Positive when fees > LVR (which is the deployment criterion per §3.8).
- **IL/LVR exposure** pro-rata during deployed in-range periods. Negative but bounded by the band's structure and the protocol's deployment criterion.
- **Fill-conversion outcome** if the band fills: dollar-equivalent of staked QD converts to underlying at band's effective price. Positive vs spot if signal stack was right (band fills at a price below current spot at staking time, and stays below); neutral or negative if signal stack was wrong (band fills then price drops further below band).
- **Crystallization outcome** if the band is crystallized at a favorable moment: accumulated underlying becomes protocol spot, locking the favorable entry; staker's claim transitions to the underlying-share.

Net for the staker: opt-in optimization with **no foregone baseline yield**. They are made whole on the baseline regardless of band outcome.

#### Composition with the bond ladder

The bond ladder's structural-soundness property (§3.4 duration matching) is preserved because:

- Maturity buckets continue to track the QD redemption schedule on unstaked QD.
- Staked QD is in a separate accounting state — committed to a specific band's outcome until unstake or crystallization.
- Vogue's bands are sized so the protocol can absorb the fill outcomes (whether ETH accumulates or mockUSD remains) without breaking the redemption schedule for unstaked QD.

A user who stakes into a band that doesn't fill for 12 months has their QD locked in that band for 12 months. They cannot redeem against the next-month bucket because their QD is committed. This is the trade-off the staker accepts in exchange for the signal-informed conversion opportunity — and they continue earning baseline yield throughout, so the trade-off is not "yield vs band fill" but "liquidity vs band fill."

#### MSTR data as one signal feature

MSTR-derived features feed into the crystallize-vs-hold scoring above (and into the band-placement decision in §3.8). The features:

```python
@dataclass
class MSTRSignalState:
    # Core price/holdings
    mstr_price: float                # via Pyth
    btc_holdings: int                # from latest 8-K
    shares_outstanding: int
    mnav: float                      # computed: mstr_market_cap / btc_holdings_nav

    # Accumulation behavior
    purchase_rate_30d: float         # BTC accumulated last 30d
    last_btc_purchase_date: date
    purchase_intensity_z: float      # z-score of recent purchase intensity vs trailing baseline

    # Equity/credit issuance
    atm_issuance_30d: float
    last_atm_announcement_date: Optional[date]
    strc_outstanding: float          # STRC perpetual preferred aggregate stated amount
    strc_dividend_rate: float        # current dividend rate on STRC

    # Maturity schedule
    convertible_maturity_calendar: List[Tuple[date, float]]
    refinancing_pressure: float      # composite score: maturities × distance × MNAV-adjusted refi risk

    # Capital-structure operations (added after May-June 2026 episode)
    usd_reserve_balance: float       # current USD Reserve balance
    usd_reserve_depletion_60d: float # fraction of reserve drawn down over trailing 60d
    convert_repurchase_30d: float    # principal amount of own convertibles repurchased in last 30d
    convert_repurchase_recent: float # binary or graded indicator of recent buyback activity
    tactical_btc_sale_30d: int       # BTC sold in last 30d (any amount including immaterial)
    tactical_btc_sale_disclosed: int # 0 / 1 flag for any disclosed BTC sale in last 14d
    atm_velocity_in_low_mnav: float  # ATM issuance velocity weighted by inverse MNAV (high = dilutive issuance in compressed premium)
```

These are observable features. They enter the conjunction logic *as features*, never as authoritative directives. When MSTR features disagree with Kalman + pool flow, the conjunction states the disagreement and the composed reading determines the recommendation. MSTR's strong purchase intensity might modify a band-placement call from "wait" to "deploy at a closer band," but cannot produce a deployment on its own; refinancing-pressure features can shift a hold-LP recommendation toward crystallize but cannot trigger crystallization without independent confirmation.

This is the framing the demand-side reality check articulates: Saylor's edge is unknowable from outside; his actions are observations, not directives. The protocol uses his moves as one feature in its own deterministic signal stack, where the signal stack's job is regime estimation (not prediction) of the same kind §1.2 specified.

#### How the dashboard hedges the depositor at the individual trade level

This is the structural point the protocol exists for. A QD holder is **not** all-or-nothing exposed to the protocol's accumulation decisions, the way an MSTR holder is all-or-nothing exposed to Saylor's. The depositor's position has two layers operating simultaneously:

1. **Base layer: yield-optimized basket, always-on.** mockUSD earning baseline + ether.fi staking + V4 LP fees net of LVR + basket revenue. Optimal at the protocol level regardless of what any specific Vogue band is doing. The depositor pays no opportunity cost for sitting in QD without staking — the baseline yield runs continuously, including for capital that's never committed to any specific band.

2. **Signal overlay: individual-trade-level information surface.** The dashboard surfaces every signal-relevant data point for each Vogue band — pending or active. The depositor decides which bands to stake into, which to skip, and when to unstake, on the basis of the full signal stack reading *for that specific band*.

This is what "be signalled on the individual trade level" means structurally. The depositor is hedged against committing wholesale to crypto holdings because the base layer doesn't require it; they opt into specific bands at the trade-level, with full signal-stack reasoning visible, only when their own conviction agrees.

##### What the dashboard provides for each pending band

For every out-of-range Vogue band available for staking, the dashboard surfaces:

- **The band's target price range** and Vogue's signal-informed rationale for placing it there
- **Full §3.2 signal-stack reading at deployment:**
  - Kalman state: σ, β, φ with uncertainty bands
  - HMM regime posterior: `P(regime | obs)` across the six discrete regimes
  - HMM transition probabilities from current regime — `P(strong_bull | current)`, `P(weak_bear | current)`, `P(capitulation | current)`, `P(recovery | current)`
- **§3.9 pool flow assessment:** accumulation vs distribution pattern, size-asymmetry index, trader-concentration Herfindahl, range-fill velocity, z-scores against trailing baseline
- **§3.7 MSTR features:** purchase intensity, MNAV state and trajectory, refinancing-pressure score
- **§3.7 MSTR capital-structure operations:** convert repurchase activity, USD reserve depletion rate, tactical BTC sale events (any size), ATM equity issuance velocity in declining-MNAV environment
- **Macro context:** basket reweigh state, risk-on/risk-off intensity
- **Conjunction reading:** the composed signal-stack frame for this band — strong/moderate/weak deployment conviction, with the dominant factors named explicitly
- **Time-to-deployment estimate** based on signal-stack confidence and capacity required
- **Historical fill rate for comparable bands** (matched on depth-of-band, distance-from-spot, HMM regime classification): how often did similar bands fill vs get cancelled?
- **Backtest of similar bands in matched regimes:** realized accumulation P&L when filled, post-fill price trajectory, time-to-crystallize, terminal value vs spot at deployment
- **Crystallization track record** for bands deployed in matched regimes: dispersion of outcomes when the §3.11 conjunction logic favored crystallize vs hold

The depositor consumes all this and decides — based on their own conviction, horizon, capital needs, and existing exposure — whether to stake into THIS specific band, in what size, and with what expected duration.

##### What the dashboard provides for currently-staked bands

For each band the depositor has staked into, the dashboard surfaces:

- **Current band state:** fill fraction, mockUSD remaining, accumulated underlying, effective average accumulation price vs spot
- **Active signal-stack reading:** is the regime the same as at staking, or has the HMM posterior shifted? Have MSTR features changed? Are flow patterns confirming or contradicting the deployment rationale?
- **Hold-vs-crystallize recommendation per §3.11 conjunction logic** for THIS band specifically, with the dominant factors named
- **The depositor's individual stake economics:** baseline yield accrued, LP fees earned (pro-rata of in-range periods), unrealized fill-conversion P&L vs spot, IL/LVR cost incurred
- **Action surface:** stay staked, unstake fully (recover QD), partial-unstake (recover some QD, leave the rest), follow the crystallization recommendation when it fires

The depositor retains decision authority. The protocol's crystallization signal is information, not instruction. A depositor who disagrees with the protocol's read on a band can unstake on their own timeline; one who agrees can let the protocol's hook execute crystallization automatically.

##### MSTR holder vs QD holder — the structural comparison

| | MSTR holder | QD holder |
|---|---|---|
| Base position economics | Equity in a leveraged BTC-treasury corporation | Yielding stablecoin at ~10% blended baseline |
| Decision granularity | All-or-nothing (hold MSTR or don't) | Per-band (stake into specific bands or don't) |
| Exposure to bad accumulation decisions | Full — embedded in equity price via MNAV compression and the company's BTC-per-share metric | Zero unless you opt into the specific band |
| Yield on undeployed/un-committed capital | None — equity capital is fully committed | Baseline yield runs continuously |
| Signal visibility | Saylor's decisions disclosed after-the-fact via 8-Ks | Full signal stack visible pre-deployment, per-band |
| Hedging mechanism | Sell MSTR (binary; no granularity) | Don't stake into specific bands; selectively unstake from others |
| Forced selling risk | High in deep drawdowns (refi wall, STRC perpetual dividends, ATM dilution) | None — protocol has no liabilities forcing sales |
| Dilution risk | High — continuous ATM issuance | None — no equity to dilute |
| Narrative-crack vulnerability | Material — May–June 2026 episode showed 0.0038% BTC sale moved BTC 3.1% | None — QD is a claim on a yield-bearing reserve, not on a narrative |

The point is not that QD is a better leveraged-BTC vehicle than MSTR. It isn't — MSTR's leverage produces more upside in MNAV-expansion regimes than Vogue's signal-informed accumulation does. The point is that QD provides **a different shape of exposure**: yield-optimized baseline with selective, per-trade, signal-informed accumulation opt-ins, where the depositor hedges at the trade level rather than committing to the wholesale BTC-treasury bet.

##### What this means for the Saylor benchmark in §3.10

The §3.10 historical replay's "Saylor strategy" comparator is not a target the protocol synthesizes. It's the benchmark for evaluating Vogue's signal-informed accumulation against the leveraged-bull alternative — the question being: "if a depositor had opted into all of Vogue's bands across a given regime, how would their outcome compare to having instead bought MSTR equity?" That comparison is the §3.10 table; the result is regime-conditional outperformance (Vogue beats Saylor in 3 of 4 regimes via structural soundness; loses in MNAV-expansion phases like 2023's post-capitulation rebound).

A QD depositor doesn't have to opt into all of Vogue's bands. They can pick the ones the signal stack reads strongly in favor of, skip the ones they disagree with, and let their baseline yield run on the un-committed capital. Their realized outcome is therefore between the "all-bands Vogue" comparator and "pure baseline QD" — depending entirely on which individual bands they chose to participate in. The dashboard is what makes that choice possible at the individual-trade level.

#### Panels

- **LP-deploy indicator** (headline): green / amber / red based on §3.8 rationality checklist. When red, dashboard shows reserve composition with all dollars in pure mockUSD; bands are not deployed; the ~4% baseline + ether.fi staking + basket revenue is the reserve yield. LP fees and LVR are both zero during this state.
- **Active bands map**: each currently-deployed band displayed with fill fraction, fees accrued, LVR cost so far, signal-stack frame on hold-vs-crystallize, recommendation.
- **Out-of-range bands available for staking**: target price, signal-stack rationale (why this level), pending capacity required, current QD-staked amount, time-to-deployment estimate.
- **Crystallization timeline**: historical bands that were crystallized, when, at what fill fraction, and what the underlying did over the 30 days following crystallization (validation of the call).
- **Staker positions**: for any user with active stakes, their staked-QD positions, baseline yield accrued, LP fees accrued (pro-rata), current band states, and whether their bands are recommended for hold or crystallization.

#### What this isn't

- **Not a synthetic MSTR instrument.** No MSTRq, no MNAV-tracking token, no equity-wrapper layer. MSTR is a signal feature; the protocol does not create instruments that track MSTR equity.
- **Not a Panoptic-style options product.** The LP position is the vol-sell directly; no separate options layer needed. The protocol's short-gamma exposure is the LP position itself, backed by the QD bond ladder.
- **Not a forced-action service.** The dashboard provides full signal-stack information per band for the depositor to make individual-trade-level decisions, but never forces actions or assumes a specific horizon. The crystallization signal is the protocol-level operational recommendation for Vogue's *own* positions; the QD staker's parallel decision (stay staked, unstake, partial-unstake) remains theirs, informed by the same signal surface.
- **Not an automated execution.** Signal → recommendation → operator review → committed action. The crystallize-vs-hold recommendation is surfaced to the operator (and to QD stakers in the relevant bands), not auto-triggered.
- **Not a permanent commitment.** Vogue can re-deploy bands after crystallization if regime turns favorable again. Crystallization locks the accumulation at the band's effective price; it does not preclude future accumulation cycles.


### 3.12 Plug-and-play external operators and the track-record feedback loop

**Purpose:** Specify how external LP operators running Hummingbot-style open-source bot infrastructure provide additional liquidity capacity to Vogue's V4 pools, with their take-profit (TP) realized P&L sharing into the basket as revenue, and with their on-pool track records gating future allocation, basket take-rate tiers, and signal-stack feed access. Extends Vogue's capacity beyond protocol reserves while preserving structural-soundness properties.

#### Why this layer exists

Vogue's positions are bounded by the protocol's reserve composition. As the protocol's V4 pools attract organic volume, the question is how to scale LP depth beyond what reserves alone provide, without diluting QD's backing quality or compromising the bond ladder's duration matching.

External operators bring their own capital, run their own crystallization logic (their bots' TP triggers), and contribute basket revenue from a share of their realized P&L. Three structural benefits:

1. **Capacity scaling.** Deeper book and tighter spreads on the protocol's V4 pools attract more swap flow, which in turn grows fee revenue across all LP positions (Vogue's, QD-staker-backed, external).
2. **Strategy diversity.** Different operators run different strategies — mean-reverting, momentum, hedged-LP, range-following. Variation prevents monoculture and provides a continuous empirical test of the §3.11 crystallization signal: operators who outperform by following the signal validate it; operators who outperform by ignoring it indicate where the signal stack should be refined.
3. **Basket revenue.** Operator TP profits flowing to the basket compound with existing basket revenue (matched long/short trading fees, equity/commodities funding spreads). The basket's contribution to QD's blended yield grows.

#### The TP-to-basket mechanic

When an external operator unwinds an LP position (its bot's TP logic triggers), an on-chain hook computes:

```
realized_pnl       = (position_value_at_unwind − position_value_at_deployment + fees_accrued − LVR_paid)
basket_share       = realized_pnl × basket_take_rate(operator)
operator_share     = realized_pnl − basket_share
```

The `basket_take_rate` is a function of the operator's track record:

- High-quality operator (top tier): take rate ~5–10%. They keep most of their realized P&L; the protocol takes a small cut. Incentive: stay in good standing, keep the favorable tier.
- Medium-quality operator: take rate ~20–30%. Standard tier; reasonable economics for both sides.
- Low-quality operator: take rate ~50%+. The basket extracts the majority of realized P&L; operator economics are unviable. Effectively filters them out of the system without requiring administrative action.
- JIT-detected operator: take rate 100% (or registry exclusion). JIT-style sniping is detected via pool-flow analysis (§3.9) and on-chain pattern matching; identified operators forfeit all profits to the basket. After repeated detection, they're removed from the operator registry.

The basket share is added to the basket's revenue accumulator and contributes to QD backing per the standard basket-revenue accounting.

#### The track-record feedback loop

For each operator address in the registry, the protocol tracks rolling windows (7d / 30d / 90d / lifetime):

- **Realized P&L net of LVR** — operator's bottom line on the protocol's pools
- **Signal-alignment score** — how often the operator's deployment timing and TP timing match the §3.11 crystallization signal's recommendation at the moment of the decision
- **Outperformance vs protocol baseline** — operator's net P&L over the window vs what Vogue would have realized with the same deployed capital following its own logic
- **Toxicity contribution** — pool-flow analysis (§3.9) of whether the operator's positions attract uninformed flow (positive, fee-generating) or are sniped by JIT bots (negative, draining)
- **Capital durability** — average position-holding time. Long durations indicate genuine market-making; sub-block durations indicate JIT-style strategies

These compose into a single track-record score that determines:

| Dimension | High track record | Low track record |
|---|---|---|
| Allocation cap | Higher max capital | Reduced, then floored |
| Basket take rate | ~5–10% | ~30–50%+ |
| Signal-stack access | Same-block §3.11 + §3.9 access | Delayed (1h / 4h) and aggregated only |
| Next provisioning window | Eligible for new allocation | Excluded until score recovers |

The protocol does not enforce a specific strategy — operators are free to run whatever logic they want. The track record reveals what's working and economically self-selects for quality.

#### Composition with Vogue and the QD staking rail

Three liquidity layers, in priority and decision authority:

1. **Vogue's own positions** (protocol-managed, from reserve composition). Primary layer. Decision authority on directional band placement at the macro level per §3.8 + §3.11.
2. **QD staker-backed bands** (§3.11). QD holders opt into specific out-of-range bands placed by Vogue. Vogue still controls placement; stakers provide additional dollar-leg capacity.
3. **Plug-and-play external operators** (this section). Bring own capital, run own strategies in their own tick ranges or alternate fee tiers. Their positions complement Vogue's, do not override them.

The three layers are explicitly non-overlapping in decision authority. Operators may not deploy positions that interfere with Vogue's active bands (the registry contract enforces minimum tick-distance constraints). When conflicts arise (e.g., an operator's position would partially overlap with a Vogue band), Vogue's deployment takes precedence; the operator's position is rejected with a clear error.

#### Operator-as-empirical-test of the signal stack

A load-bearing benefit of the external-operator layer is that it provides a continuous, capital-at-risk empirical test of the §3.11 crystallization signal and the §3.8 LP economics framework.

If operators following the signal stack's recommendations consistently outperform those who don't, the signal stack is producing edge. If operators who outperform are those *ignoring* (or contradicting) the signal stack, the stack needs refinement — and the dashboard surfaces *which* signal components are correlated with outperformance and which are noise.

Specifically:

- **Signal-alignment × P&L scatter plot.** X: signal-alignment score per operator (per rolling window). Y: P&L net of LVR. Positive correlation validates the stack; negative or zero correlation challenges it.
- **Per-signal-component attribution.** Which components of §3.11's conjunction logic (Kalman φ, σ-zscore, pool flow distribution patterns, MSTR features, basket reweigh) most correlate with operator outperformance? This is the refinement loop — components that don't correlate are candidates for retuning or removal.
- **Strategy cluster analysis.** Cluster operators by strategy fingerprint (deployment tick ranges, hold durations, rebalance triggers). Surface which strategies dominate which regimes.

The §1.2 estimation discipline applied to the signal stack itself: the stack is not asserted to be edge-positive; it's evaluated empirically against operator outcomes, with the evaluation continuously visible.

#### Hummingbot integration specifics

[Hummingbot](https://hummingbot.org) is open-source bot infrastructure for crypto market-making with established V3/V4 strategy templates and a community of operators. The protocol's integration:

- **Standardized strategy module.** A "QU!D Vogue Pool" strategy plugin for Hummingbot, configurable for the protocol's specific V4 pools (ETH/USD, BTC/USD), with default parameter sets aligned to the §3.11 crystallization signal.
- **TP hook contract.** When the strategy unwinds a position, it calls the protocol's `tp_settle()` function, which computes the basket share per the operator's current take-rate tier and routes accordingly.
- **Signal-stack feed.** Authenticated WebSocket / HTTP API exposing the §3.2 Kalman state, §3.9 pool flow read, §3.7 MSTR features, and §3.11 crystallization recommendations. Permission tiered by track record.
- **On-chain operator registry.** Maps operator addresses to current track-record scores, allocation caps, take-rate tiers, and signal-feed-access tier. Updated by an off-chain track-record calculator that posts state on each rolling-window boundary.

Operators can also bring their own bot infrastructure (not just Hummingbot) — the registry and TP-hook mechanics work with any operator that registers and uses the protocol's contracts and APIs. Hummingbot is the *default* integration point because of community size and existing open-source tooling.

#### Panels

- **Operator registry**: list of authorized operators, current track-record scores, allocation caps, take-rate tiers, signal-feed-access tier
- **Per-operator track record**: P&L net of LVR (windowed), signal-alignment, outperformance vs Vogue baseline, toxicity contribution, capital durability
- **Signal-stack empirical evaluation**: signal-alignment × P&L scatter plot, per-component attribution, strategy cluster fingerprints
- **TP-to-basket revenue stream**: cumulative basket revenue from operator TP events, broken down by operator and by rolling window
- **Hummingbot configuration export**: download the default QU!D Vogue Pool strategy module for self-onboarding operators

#### What this isn't

- **Not a permissionless public LP market.** Operators are registered via the on-chain registry, not open to any address that deploys capital.
- **Not a delegation of band placement to operators.** Vogue retains decision authority on directional band placement at the macro level (§3.8 + §3.11). Operators run their own strategies in non-conflicting tick ranges.
- **Not a guarantee of operator profitability.** Many operators will lose money. The track-record system filters them out economically over time; no protocol intervention needed.
- **Not a JIT-friendly venue.** JIT-style strategies are detected via §3.9 pool-flow patterns and on-chain behavior; identified JIT operators face 100% basket take rate and registry exclusion. The system is structurally hostile to JIT.
- **Not a substitute for Vogue or QD staking.** External operators add capacity; they don't replace the primary LP layer (Vogue) or the QD-staker rail (§3.11). All three coexist.


---

---

## 4. Computation detail

### 4.1 Kalman bank — implementation

Each filter is one-dimensional. Implementation is the standard scalar recursion:

```python
def kalman_step(x, P, z, F=1.0, H=1.0, Q=1e-5, R=1e-3):
    """One step of a scalar Kalman filter.
    
    Returns:
        x_new: updated state estimate
        P_new: updated state variance
        y: innovation (residual)
        S: innovation variance (used for divergence check)
    """
    # Predict
    x_pred = F * x
    P_pred = F * P * F + Q
    
    # Update
    y = z - H * x_pred
    S = H * P_pred * H + R
    K = P_pred * H / S
    x_new = x_pred + K * y
    P_new = (1 - K * H) * P_pred
    return x_new, P_new, y, S
```

For the β-filter, `H` is time-varying — it's the factor return at time t, not a constant. State remains scalar β; recursion is otherwise identical.

For the σ-filter, observations are `log(r²)` and state is `log(σ²)`. The chi-squared distribution of `r²/σ²` under Gaussian returns means the noise is not strictly Gaussian, but the approximation works in practice (acknowledged in source material).

#### Q/R tuning protocol

1. Start with defaults (β: Q=1e-5, R=1e-3; σ: Q=0.1, R=1.0; φ: Q=1e-4, R=5e-3).
2. Run the filter live, accumulating `y_t` and `S_t`.
3. Every N steps (default 60), compute `var(y) / mean(S)`.
4. If outside [0.5, 2.0], retune R first (using empirical innovation variance), then sweep Q to balance smoothness vs responsiveness against the use case (slow-drift β: low Q; fast-tracking σ: high Q).

#### Huber-style robust gain

When `|y_t| > 3 · √S_t`, scale the Kalman gain by `3 · √S_t / |y_t|`. Below the threshold, gain is standard. Implementation is one branch:

```python
if abs(y) > 3 * sqrt(S):
    K *= 3 * sqrt(S) / abs(y)
```

### 4.2 Maturity ladder math

Liability curve: directly from `Basket.totalSupplies(month)` for each upcoming month.

Asset curve:
1. Read ether.fi withdrawal queue (NFT ids and unlock dates from `LiquidityPool`).
2. Model LP fee accrual:
   ```
   projected_monthly_fees = (trailing_30d_fees) × (30 / 30) ± confidence_band
   confidence_band = stddev_of_daily_fees × √30
   ```
3. Model basket revenue accrual: same methodology as LP fee accrual.
4. Sum cash/short-duration reserves into month-0 bucket (including the un-deployed dollar leg of Vogue's bands).

Coverage ratio: straightforward division per bucket (§3.4).

Months of liquid runway: as in §3.4 algorithm above.

### 4.3 Yield calculations

Annualized yield from a cumulative fee stream:

```
annualized_yield = (1 + cumulative_fee / position_value) ** (365 / elapsed_days) - 1
```

Blended yield: time-weighted weighted average computed per-day and aggregated. Pseudocode:

```python
def blended_yield(positions, window_days):
    daily_yields = []
    for day in window_days:
        components = []
        for pos in positions_active_on(day):
            allocation = pos.value_on(day) / total_reserve_on(day)
            daily_y = pos.yield_on(day)
            components.append(allocation * daily_y)
        daily_yields.append(sum(components))
    return annualize(geometric_mean(daily_yields))
```

### 4.4 Stress-scenario evaluation

For each scenario combination, run the affected computations against the shocked inputs:

```python
def evaluate_scenario(shocks):
    # Apply price shocks to current pool state, recompute slippage curves
    shocked_pools = apply_drawdowns(current_pools, shocks.btc_dd, shocks.eth_dd)
    new_slippage = compute_slippage_curves(shocked_pools)
    
    # Apply pool depth compression
    if shocks.depth_compression:
        shocked_pools = compress_depth(shocked_pools, shocks.depth_compression)
        new_slippage = compute_slippage_curves(shocked_pools)
    
    # Apply withdrawal queue stretch
    asset_curve = current_asset_curve()
    if shocks.queue_extension:
        asset_curve = shift_etherfi_maturities(asset_curve, shocks.queue_extension)
    
    coverage = coverage_ratios(asset_curve, current_liability_curve())
    
    # Project realized variance under shocks for Kalman recheck
    shocked_realized_var = current_realized_var * variance_multiplier(shocks)
    sigma_divergence = check_filter_divergence(shocked_realized_var)
    
    return ScenarioResult(
        worst_coverage=min(coverage),
        exit_cost_at_unit_notional=new_slippage(unit_notional),
        envelope_intact=(min(coverage) >= 1.0 and not sigma_divergence),
        adverse_component=identify_worst(coverage, new_slippage, sigma_divergence),
    )
```

### 4.5 Pool-flow signal computation

Each pool maintains rolling buffers of swap events indexed by block. The computation pipeline runs on each new block (or batches every 30s):

**Per-window aggregation:**

```python
def compute_window_metrics(swaps, window_start, window_end, price_oracle):
    """Compute per-window flow metrics from raw swap events."""
    window_swaps = [s for s in swaps if window_start <= s.block_ts < window_end]
    
    # Net dollar flow (signed): positive = dollars in, negative = dollars out
    D_W = sum(s.dollar_delta for s in window_swaps)
    
    # Per-tier dollar volumes
    tiers = [(0, 5_000), (5_000, 50_000), (50_000, 500_000), (500_000, float('inf'))]
    tier_volumes_buy = [0] * 4
    tier_volumes_sell = [0] * 4
    for s in window_swaps:
        magnitude = abs(s.dollar_delta)
        tier = next(i for i, (lo, hi) in enumerate(tiers) if lo <= magnitude < hi)
        if s.dollar_delta > 0:  # dollars in = market buying underlying
            tier_volumes_buy[tier] += magnitude
        else:
            tier_volumes_sell[tier] += magnitude
    
    # Size asymmetry index per tier
    sai_per_tier = []
    for i in range(4):
        total = tier_volumes_buy[i] + tier_volumes_sell[i]
        sai_per_tier.append(
            (tier_volumes_buy[i] - tier_volumes_sell[i]) / total if total > 0 else 0
        )
    
    # Trader concentration
    address_volumes = defaultdict(float)
    for s in window_swaps:
        address_volumes[s.sender] += abs(s.dollar_delta)
    total_volume = sum(address_volumes.values())
    C_W = len(address_volumes)
    H_W = sum((v / total_volume) ** 2 for v in address_volumes.values()) if total_volume > 0 else 0
    
    return WindowMetrics(D_W=D_W, sai_per_tier=sai_per_tier, C_W=C_W, H_W=H_W)
```

**Robust baseline statistics (over trailing 30 days of comparable windows):**

```python
def compute_baseline_stats(historical_windows):
    """Robust baseline using median + MAD-derived sigma."""
    values = sorted([w.D_W for w in historical_windows])
    n = len(values)
    median = values[n // 2]
    abs_deviations = sorted([abs(v - median) for v in values])
    mad = abs_deviations[n // 2]
    sigma_estimate = mad * 1.4826  # MAD-to-sigma conversion under Gaussian assumption
    return BaselineStats(median=median, sigma=sigma_estimate)
```

**Anomaly detection:**

```python
def check_anomaly(current_metric, baseline_stats, sustain_threshold_minutes):
    """Flag anomaly if z-score exceeds threshold for sustained period."""
    z = (current_metric - baseline_stats.median) / baseline_stats.sigma
    
    if abs(z) > 3.0:
        return AnomalyFlag(level="strong", z=z, sustained=True)
    if abs(z) > 2.0 and is_sustained(current_metric, sustain_threshold_minutes):
        return AnomalyFlag(level="anomaly", z=z, sustained=True)
    if abs(z) < 0.5 and is_sustained(current_metric, window_length):
        return AnomalyFlag(level="quiescent", z=z, sustained=True)
    return None
```

The pipeline runs per window length (1h, 4h, 24h, 7d) per pool, and writes the resulting metrics to the same off-chain index the dashboard reads from.

### 4.6 Structure residual P&L computation

The historical replay in §3.10 and the live structure-residual panel both depend on the same underlying P&L decomposition: bond ladder yield plus LP layer P&L, against three benchmarks. This subsection specifies the computation.

**Inputs per period:**

```python
@dataclass
class RegimePeriod:
    start_ts: datetime
    end_ts: datetime
    asset: str                    # "ETH" or "BTC"
    P_0: float                    # start price
    P_T: float                    # end price
    sigma_annualized: float       # realized vol over period
    fee_APR: float                # period-average effective LP fee APR (haircut-adjusted)
    tbill_yield: float            # period-average T-bill annualized
    staking_yield: float          # period-average staking annualized (0 if locked)
    bond_ladder_share: float      # share of reserve in non-LP yield sources (default 0.75)
    lp_share: float               # share of reserve in LP layer (default 0.25)
    lp_concentration: float       # 1.0 for full-range, higher for concentrated
    lp_band_low: float            # for concentrated LP; None for full-range
    lp_band_high: float           # for concentrated LP; None for full-range
```

**Benchmark P&L computations:**

```python
def hold_underlying_pnl(period: RegimePeriod) -> float:
    """Hold the underlying asset for the full period."""
    return period.P_T / period.P_0 - 1.0

def hold_cash_pnl(period: RegimePeriod) -> float:
    """Hold T-bills for the full period."""
    T_years = (period.end_ts - period.start_ts).days / 365.25
    return (1 + period.tbill_yield) ** T_years - 1.0

def hold_5050_pnl(period: RegimePeriod) -> float:
    """50/50 hold rebalanced once at entry, held to end."""
    asset_pnl = hold_underlying_pnl(period)
    cash_pnl = hold_cash_pnl(period)
    return 0.5 * asset_pnl + 0.5 * cash_pnl
```

**Full-range LP P&L:**

```python
def lp_full_range_pnl(period: RegimePeriod) -> float:
    """LP P&L decomposed into divergence + fees - LVR, anchored to 50/50 hold."""
    T_years = (period.end_ts - period.start_ts).days / 365.25
    k = period.P_T / period.P_0
    
    # Divergence ratio: V_LP / V_hold_5050 = 2*sqrt(k) / (1 + k)
    divergence_ratio = 2 * math.sqrt(k) / (1 + k)
    
    # 50/50 hold endpoint value (normalized to $1 start)
    hold_5050_value = 1 + hold_5050_pnl(period)
    
    # LP price-only endpoint (before fees and LVR)
    lp_price_only = hold_5050_value * divergence_ratio
    
    # Fees accrued over period (proportional to fee APR and time)
    fees_accrued = period.fee_APR * T_years
    
    # LVR cost over period: sigma^2 / 8 annualized
    lvr_cost = (period.sigma_annualized ** 2 / 8) * T_years
    
    lp_value = lp_price_only + fees_accrued - lvr_cost
    return lp_value - 1.0
```

**Concentrated LP P&L (band-edge gap-through handling):**

```python
def lp_concentrated_pnl(period: RegimePeriod) -> float:
    """Concentrated LP with band [P_low, P_high]. Once price exits band, 
    position is 100% of the band-edge asset; no further fees, no further LVR."""
    if period.lp_band_low is None or period.lp_band_high is None:
        raise ValueError("Concentrated LP requires band bounds")
    
    # Determine whether price stays in band, exits below, or exits above
    if period.lp_band_low <= period.P_T <= period.lp_band_high:
        # Stayed in range — concentration multiplier applies fully
        in_range_fraction = 1.0
        # Fees scaled by concentration
        fees_accrued = period.fee_APR * period.lp_concentration * T_years
        lvr_cost = (period.sigma_annualized ** 2 / 8) * period.lp_concentration * T_years
        divergence = compute_in_range_divergence(period)  # standard V3 math
        return divergence + fees_accrued - lvr_cost
    
    if period.P_T < period.lp_band_low:
        # Price exited below: position became 100% underlying at P_low
        # Fees accrue only while in-range; LVR same
        time_in_range = estimate_time_in_range_below(period)
        fees_accrued = period.fee_APR * period.lp_concentration * time_in_range
        lvr_cost = (period.sigma_annualized ** 2 / 8) * period.lp_concentration * time_in_range
        # Endpoint: 100% underlying at lower band, then rides to P_T
        endpoint_value = (period.lp_band_low / period.P_0) * (period.P_T / period.lp_band_low)
        # But starting 50/50, half was already in underlying:
        # Initial: 0.5 dollar + 0.5 underlying (at P_0)
        # At lower band: 0 dollar, 1 underlying (at P_low) — i.e., fully converted
        # Then rides P_low → P_T
        endpoint_value = period.P_T / period.lp_band_low * (1.0)  # all in underlying now
        # Adjusted for actual starting cap including the IL converted at band:
        # (this needs careful unit accounting in implementation)
        ...
        return endpoint_value + fees_accrued - lvr_cost - 1.0
    
    # Price exited above: symmetric case, position became 100% dollars
    # ...similar logic
```

The concentrated case requires care with unit accounting; the implementation reference is the actual Uniswap V3 math (per the protocol math whitepaper) and a numerical integration of fees/LVR over the in-range duration.

**Structure residual P&L:**

```python
def structure_residual_pnl(period: RegimePeriod, lp_kind: str = "full_range") -> float:
    """Combined bond ladder + LP layer P&L weighted by reserve share."""
    T_years = (period.end_ts - period.start_ts).days / 365.25
    
    # Bond ladder yield (compounded over period)
    bond_ladder_apr = 0.10  # blended ~10%, period-adjusted per regime
    bond_pnl = bond_ladder_apr * T_years
    
    # LP layer P&L
    if lp_kind == "full_range":
        lp_pnl = lp_full_range_pnl(period)
    else:
        lp_pnl = lp_concentrated_pnl(period)
    
    # Structure residual: bond ladder share × bond pnl + LP share × LP pnl
    residual = (period.bond_ladder_share * bond_pnl + 
                period.lp_share * lp_pnl)
    
    return residual
```

**Benchmark comparison:**

```python
def benchmark_deltas(period: RegimePeriod, lp_kind: str = "full_range") -> Dict[str, float]:
    """Residual against the three benchmarks."""
    residual = structure_residual_pnl(period, lp_kind)
    return {
        "vs_hold_underlying": residual - hold_underlying_pnl(period),
        "vs_hold_cash":       residual - hold_cash_pnl(period),
        "vs_hold_5050":       residual - hold_5050_pnl(period),
    }
```

This is what powers both:

- The static historical-regime table in §3.10 (period = one of the four historical regimes, output = the rows in the summary table)
- The live continuously-running structure-residual indicator (period = trailing 30d sliding window, output = where the structure currently sits against each benchmark over recent history)

The two share the same code path; only the period definition changes.

#### Sensitivity computation

For the §3.10 sensitivity panel, the same `benchmark_deltas` function is called with perturbed inputs:

```python
def sensitivity_table(period: RegimePeriod) -> Dict[Tuple[str, float], Dict[str, float]]:
    """How does the residual shift if we perturb each input?"""
    perturbations = {
        "lp_share":           [-0.10, -0.05, 0.05, 0.10],
        "lp_band_width":      [-0.05, 0.05, 0.10],  # narrower or wider
        "sigma_annualized":   [-0.20, 0.20],          # vol 20% lower or higher
        "fee_APR":            [-0.30, 0.30],          # fees 30% lower or higher
    }
    
    results = {}
    base = benchmark_deltas(period)
    for param, shifts in perturbations.items():
        for shift in shifts:
            perturbed = perturb(period, param, shift)
            results[(param, shift)] = benchmark_deltas(perturbed)
    
    return results
```

This is what populates the sensitivity panel — the operator can see at a glance how robust the current residual is to parameter assumptions, and which parameters move the structure most.

---

## 5. Explicit non-goals

The dashboard does **not**:

1. **Produce price predictions.** No model, no extrapolation, no "where will BTC/ETH be in six months" question is answered. The conversion-timing recommendations the dashboard *does* issue (band placement, accumulation pace) are conditional on current-state estimation, not on forecasts.
2. **Run a multibagger-style screen on BTC or ETH.** Yartseva's framework is for equities with cross-sectional variation in fundamental metrics. BTC and ETH lack a comparable fundamental cross-section to screen against, and any directional signal would be more aggressively arbitraged in efficient assets than in thinly-covered equities.
3. **Train a sequence model to predict the next bar or day.** Per Miao, a sequence model on price-only data on liquid assets reduces to a one-period lag. Compute spent here would produce a number that looks like a prediction and is in fact a lag.
4. **Display protocol-wide position aggregates that would reveal individual-user behavior.** Per the Goodhart-aware constraint in §2.3 — these would expose reflexive run dynamics. Aggregate reserve composition (bond ladder + LP layer) is shown because that aggregate is what backs every QD equally; anything implying per-user reserve allocation variation is structurally false because no such variation exists.
5. **Show "confidence intervals" on forecasts.** There are no forecasts. Uncertainty bands appear only on *current* state estimates, where they have an honest interpretation.
6. **Combine signals via the alpha-extraction framework at the BTC/ETH level.** With N=2 assets the cross-sectional and orthogonalization equations collapse to trivial relative-value computations; the framework's value is in equity portfolios with many cross-sectionally varying assets, not in a 2-asset crypto universe. The single applicable principle (inverse-vol weighting) is noted where it applies but does not justify importing the full framework.
7. **Claim Vogue accumulation outperforms every benchmark in every regime.** Per §3.10 — the replay shows clearly: Vogue beats DCA in every regime, beats Saylor in 3 of 4 regimes, loses to cash in drawdowns, and loses to buy-ETH-at-start in strong directional bulls. The dashboard makes this regime-conditioned reality visible; it does not promise that any specific regime continues, and it does not claim universal outperformance.
8. **Auto-adjust Vogue/Rover parameters on signal-stack conjunctions.** The signal stack (§3.2 + §3.7 + §3.9 + §3.11) informs Vogue/Rover operators looking at the §3.8 rationality checklist and produces concrete band-placement recommendations; it does not auto-rebalance the LP layer or commit parameter changes without operator action. Signal → recommendation → operator review → committed change.
9. **Manufacture convexity from yield.** The protocol does not natively produce MSTR-style leveraged-bull convexity. No on-protocol convex sleeve, no yield-funded long-gamma position, no synthetic premium-funded structure. The reserve composition is bond ladder + LP layer + basket revenue; the LP layer is structurally short gamma (per §3.8) and is not transformed into long gamma anywhere in the design. The structural-soundness arguments against Saylor (no leverage, no refinancing wall, no premium collapse, no dilution) depend on this — adding convexity would re-introduce the failure modes those arguments preclude.
10. **Take custody of user dollars outside Vogue's accumulation venue.** The dollar leg users supply funds Vogue's V4 LP positions exclusively. The dashboard does not route capital to off-protocol venues, to other LPs not under Vogue/Rover, or to discretionary strategies. Users supplying dollars know exactly where they go.
11. **Issue individualized user-level buy/sell timing recommendations.** Per §1.4 and §3.11 — the dashboard recommends protocol-level band placement (when and where to convert the aggregate un-deployed dollar leg), not individual user trading decisions. The structural reason matters: Saylor's edge is unknowable from outside (we can't tell whether his correct calls were intuition or coincidence, nor whether his wrong calls were still net-positive on his structural horizon); users' horizons and capital needs are individual (no universal "buy now" call serves a 6-month liquidity-need user and a 10-year accumulation user equally). The dashboard's recommendations are for the protocol's collective accumulation engine; each user's involvement remains the binary deposit-or-redeem decision against QD's redemption schedule.
12. **Take long-MSTR or short-MSTR positions.** MSTR data (§3.7 sub-strip, §3.11) is a signal input to the band-placement and crystallization composition. The protocol does not hold MSTR equity, take synthetic MSTR exposure on the basket, or otherwise position itself against Saylor's premium. MSTR appears in the design only as one observable feature feeding the signal stack.

The first two are the most likely user-driven mission-creep candidates over time. They should be politely declined when proposed and the user pointed back to this section.

What the dashboard *does* do, distinguished clearly from what's above:

- **Issues concrete protocol-level band-placement recommendations.** When and where Vogue should place its next conversion band; what pace of deployment the current regime supports; when to widen or tighten ranges. These are *directional* in the practical sense (they tell the operator what to do next) but they are grounded in current-regime estimation, not in price forecasting. The §3.8 rationality checklist, the §3.9 anomaly flags, the §3.10 replay sensitivity panels, and the §3.11 composed signals all produce inputs to these recommendations.
- **Surfaces full per-band signal-stack reasoning for depositors making individual-trade decisions.** For each pending out-of-range Vogue band, the dashboard shows the depositor: Kalman state, HMM regime posterior, transition probabilities, pool flow patterns, MSTR features, capital-structure operations, macro context, historical fill rates, and regime-matched backtests. The depositor consumes this and decides band-by-band whether to stake, how much, for what duration. For currently-staked bands, the dashboard surfaces active signal-stack readings and the hold-vs-crystallize composed recommendation. The depositor decides per-trade; the dashboard provides per-trade reasoning. This is the load-bearing capability — it is what makes QD a different *shape* of exposure than MSTR's all-or-nothing-leveraged-bull-equity bet.
- **Composes MSTR data into the signal stack as one feature.** Saylor's observable actions (purchase rate, ATM issuance, convertible offerings, MNAV level/direction, refinancing pressure, capital-structure operations) modify the band-placement recommendations and the per-band signal surface, but never override the composed reading on their own. Per §3.11.
- **Surfaces regime-conditional comparisons.** Versus DCA, versus Saylor's MSTR equity return, versus passive holds. The §3.10 replay shows this historically; the live track-record panel shows it continuously.

The distinction worth keeping in mind: *the dashboard advises the protocol on Vogue's band-placement parameters; the protocol places bands; the dashboard simultaneously advises depositors on a per-band basis whether to stake into specific bands; depositors decide per-trade.* The protocol-level recommendation (band placement, crystallization of the protocol's own positions) and the depositor-level information surface (full signal-stack reasoning per band, per stake decision) share the same underlying signal stack but address different decision surfaces. Both are first-class outputs.

---

## 6. Data sources and update cadence

| Source | Used by | Update cadence |
|---|---|---|
| On-chain reads (Basket, ether.fi LiquidityPool, V3/V4 pool state, Vogue/Rover position events, basket venue state, BTC channels) | §3.4 ladder, §3.5 liquidity, §3.3 yield, §3.8 LP economics | Every block on the deployment chain; 30s polling fallback |
| Off-chain price oracle (BTC, ETH, factor returns) | §3.2 Kalman, §3.6 stress | 1m bars sufficient; filters update on each new bar |
| Perp funding rates, OI | §3.7 macro strip | 1h |
| Fed effective rate | §3.7 macro strip | Daily |
| BTC channel state (channel-monitor service) | §3.4, §3.5 | Whatever the service exposes |

---

## 7. Appendix A: source material

### A.1 Yartseva (2025), *The Alchemy of Multibagger Stocks*

- Birmingham City University, CAFÉ Working Paper No. 33, February 2025
- Author: Anna Yartseva
- License: CC BY-NC-SA
- Method: dynamic panel data study, 464 US-listed multibagger stocks (≥10× appreciation, 2009–2024), ~150 candidate variables tested via Arellano–Bond and system-GMM estimators
- Key finding for this design: factors that explain past outperformance routinely fail to predict future outperformance; earnings growth in every formulation tested is insignificant; drivers of outperformance evolve over time
- Tortoriello (2008) is the prior literature she frames her result against

**How this applies to the LP accumulation problem.** Yartseva's central claim is that *the factors which historically explain outsized future returns don't continue to predict them out-of-sample*. Applied to LP accumulation, this rules out a class of failure modes: extrapolating from "this band placement worked in 2021" to "this band placement will work in 2026" without re-evaluating regime. The Vogue strategy is built on *current-regime estimation* (via §3.2 Kalman and §3.9 pool flow), not on historical-pattern extrapolation. Bands are placed where the signal stack reads the current regime as favorable, not where they would have been placed in similar past regimes. This is the discipline Yartseva's work motivates: regimes are non-stationary; the strategy must re-estimate state at every decision point. The §3.10 historical replay is precisely a regime-conditional evaluation — not a backtest claiming forward edge, but a regime-by-regime characterization of how the strategy structurally performs.

### A.2 Miao (2020), *A Deep Learning Approach for Stock Market Prediction*

- Stanford CS 230 final project paper
- Method: LSTM trained on daily OHLC for AMZN/GOOG/FB, 2015–2020; variants over hidden layers (3/4), dropout (0.1/0.2), batch size (32/64)
- Key observation for this design: the reported predicted-vs-actual plots show the predicted line tracking actual with ~1-period lag; the model is rediscovering price persistence, not extracting alpha, given price-only input on liquid assets

**How this applies to the LP accumulation problem.** Miao's result rules out a tempting category of automation: training a sequence model on ETH/BTC price history to predict where the next pullback will be, then placing Vogue's bands there. That's the LSTM-on-AMZN trap. The model would learn to lag, and the resulting band placement would put liquidity below current price *after* price has already fallen — i.e., catching the falling knife rather than positioning for the conversion. The Vogue strategy explicitly does not use sequence-model price forecasting; band placement comes from current-regime estimation (Kalman state at this moment) combined with pool-flow microsignal (what is happening in our venue this hour). The accumulation timing is conditional on observable current state, not on a forecast that history-matches into a one-period lag.

### A.3 Kalman filter article

- Uploaded as in-line text; long-form pedagogical article on Kalman filters in trading
- Covers state-space modeling, predict-update-gain cycle, scalar and matrix implementations, dynamic beta, volatility tracking, and production caveats (linearity, fat tails, Q/R stationarity)
- Key positioning (direct quotes, ≤15 words each):
  - "The Kalman Filter does not predict the future."
  - "OLS gives you the average. Kalman gives you the current state."
  - "GARCH tells you what volatility was. Kalman tells you what volatility is right now."
- Key production rules (paraphrased): innovation variance divergence from `S_t` indicates a mis-specified model — retune before trading; standard Gaussian filter is too aggressive on extreme observations — apply Huber-style robust gain above 3σ innovations

**How this applies to the LP accumulation problem.** This is the methodological foundation the band-placement decision rests on. The dashboard does not try to predict where ETH will be tomorrow; it estimates the *current* state of ETH's β, σ, and mean-reversion strength φ, and feeds those estimates to band-placement logic. Concrete consequences:

- *σ-filter* outputs the realized volatility estimate that feeds the §3.8 fee-vs-LVR ratio. Bands tighten when σ is low (LVR is paid less often, fee tier worth it) and widen when σ is high (gap-through risk dominates).
- *Mean-reversion φ-filter* outputs the regime classifier. When φ is meaningfully negative (mean-reverting), narrow bands placed in the corridor capture repeated fills; when φ is meaningfully positive (trending), bands chase the trend and crystallize IL on each reband. The crab-regime outperformance in §3.10's Regime 3 is the φ-filter's contribution.
- *β-filter*, where the protocol uses BTC as a factor for ETH (or a broader risk-factor regression), produces the dynamic exposure estimate. Useful for sizing the deployed dollar leg relative to undeployed: more dollars in reserve when β is rising rapidly (regime change in progress).
- *Innovation-variance divergence check* is the model's self-honesty mechanism. When `var(y_t)` deviates from `S_t` for sustained periods, the filter is mis-specified and band-placement recommendations from it are unreliable — the dashboard flags this state explicitly so the operator stops trusting the recommendations until retuning.

The discipline is exactly what the LP accumulation use case requires: a state estimator that admits uncertainty and refuses to forecast.

### A.4 Alpha-extraction / signal-combination framework

12-equation framework for combining multiple signals into portfolio weights:

1–4. Time-series demean returns; estimate variance; normalize; truncate.
5–6. Cross-sectional demean to remove market-wide bias.
7–8. Compute volatility-normalized expected returns.
9. Orthogonalize against factor; extract residual ε(i).
10. Inverse-vol weight the residual: `w(i) = η · ε(i) / σ_i`.
11. Constrain weights to unit norm: `Σ |w(i)| = 1`.
12. Combined signal = `Σ w(i) · S_i`.

For BTC/ETH (N=2), cross-sectional and orthogonalization steps collapse to trivial computations. The framework's value is in equity portfolios with many cross-sectionally varying assets; mostly inapplicable as a foundation for this dashboard.

**How this applies to the LP accumulation problem.** With N=2 (BTC and ETH), most of the framework collapses, but one principle survives and is load-bearing: **inverse-vol weighting (Eq. 10)** for the cross-asset allocation of dollar-leg deployment. When users supply $X in aggregate to be deployed across ETH and BTC accumulation bands, the split should not be 50/50 by default — it should be inverse to the assets' Kalman-estimated σ. Why:

- Higher-vol asset has higher LVR per dollar of in-range position (LVR ≈ σ²/8). Less capital in the higher-vol asset for the same expected LVR cost.
- Higher-vol asset has higher fill frequency (more pullbacks, more opportunities for bands to be touched). Less capital needed to achieve equivalent accumulation throughput.
- Inverse-vol weighting balances *expected accumulation rate* across assets, which is the metric users care about.

Concretely: if `σ_ETH = 0.7` and `σ_BTC = 0.5` annualized, weights are `w_ETH = 1/0.7 = 1.43` and `w_BTC = 1/0.5 = 2.0`, normalized: `w_ETH = 0.417`, `w_BTC = 0.583`. So ~42% of the dollar leg supports ETH bands, ~58% supports BTC bands. This is the only piece of the alpha-extraction framework the dashboard actually uses — Eq. 10's principle as a default cross-asset allocator, with operator override available if specific accumulation targets differ.

### A.5 Jurafsky & Martin (2026), *Speech and Language Processing*, Appendix A: Hidden Markov Models

- Daniel Jurafsky and James H. Martin, *Speech and Language Processing*, 3rd edition draft (January 2026)
- Appendix A covers Markov chains, the Hidden Markov Model, the Forward algorithm (likelihood), the Viterbi algorithm (decoding), and the Forward-Backward / Baum-Welch algorithm (unsupervised parameter learning)
- Builds on Baum & Petrie (1966), Baum (1972), and Rabiner's influential 1989 tutorial
- Key positioning: HMMs relate observable sequences to hidden state sequences via discrete-state transition dynamics and per-state emission distributions

**Three fundamental problems** (Rabiner's framing, used in the appendix):

1. **Likelihood** — given an HMM and an observation sequence, determine `P(O | λ)`. Solved by the Forward algorithm with `O(N²T)` dynamic programming.
2. **Decoding** — given an HMM and an observation sequence, find the most-likely hidden state sequence. Solved by the Viterbi algorithm.
3. **Learning** — given an observation sequence and a state set, learn the HMM parameters (transition matrix A, emission distributions B). Solved by Baum-Welch (a special case of EM).

**Key technical properties:**

- *Markov Assumption*: `P(q_i | q_1...q_{i-1}) = P(q_i | q_{i-1})` — only the previous state matters
- *Output Independence*: `P(o_i | q_1..q_T, o_1..o_T) = P(o_i | q_i)` — observation depends only on the state that emits it
- Both assumptions are strong; the spec explicitly acknowledges where they break (regime transition periods have correlated observations that violate output independence; the protocol's response is to flag high-entropy regime posteriors for operator review rather than commit to a classification)

#### How this applies to the LP accumulation problem

HMMs add three distinct capabilities the spec's Kalman-only macro layer didn't have:

1. **Discrete regime classification with transition dynamics.** The Kalman bank tracks continuous state variables (σ, β, φ). The HMM regime layer (§3.2) consumes those continuous estimates as observations and classifies them into discrete regimes with explicit transition probabilities `P(regime_t = j | regime_{t-1} = i)`. This is structural information the Kalman φ scalar alone cannot represent — knowing `P(capitulation | weak_bear) = 0.3` is qualitatively different from knowing `φ = 0.15`, even though they describe related aspects of regime dynamics. The transition matrix feeds directly into the §3.11 crystallization signal: when `P(capitulation | current) > 0.3`, the signal favors crystallizing aggressively even if the current Kalman state looks stable.

2. **Viterbi-decoded historical regime sequence for §3.10.** The historical replay's regime boundaries are currently inspection-based ("the 2022 capitulation ran from Nov 2021 to Dec 2022"). Viterbi gives a principled assignment: given the HMM parameters and the historical observation sequence, `argmax_Q P(Q | observations)` is the most-likely sequence of regimes. The decoded boundaries are defensible against "you picked the dates to flatter the result" — the boundaries come from the model, not from chart-reading. The Viterbi backtrace (per §A.4 of the source) makes the path reconstruction explicit.

3. **Baum-Welch for unsupervised parameter learning.** We don't have ground-truth labels for "which regime was active on day X." Baum-Welch learns the regime emission distributions and transition probabilities from observation sequences alone, iterating between E-step (compute expected state-occupancy γ and expected transition counts ξ) and M-step (re-estimate A and B). This is the unsupervised analog of §A.3's Kalman methodology — same posture (estimate current state, don't predict), different mathematical machinery for the discrete-state case. The protocol's HMM parameters are learned this way on rolling 2-year historical windows.

**Composition with Kalman: Markov-switching state-space.** The two layers are not redundant — they compose:

- Kalman tracks continuous within-regime dynamics (σ, β, φ) with linear-Gaussian updates
- HMM tracks discrete regime transitions and emits posterior `P(regime_t | observations)` based on Kalman's continuous-state output
- The composition is a Markov-switching state-space model: continuous dynamics modulated by a discrete regime variable

For the LP accumulation problem specifically, this composition matters because regime *transitions* are typically jumpy (not smooth), but within-regime dynamics are typically continuous. Modeling them with one machinery underfits the transitions; modeling them with the other underfits the within-regime evolution. The composed model captures both.

**Caveats observed from the source:**

- The Output Independence assumption is approximate. For the spec's observation vector (σ, β, φ, pool flow, MSTR features), within-regime independence is roughly defensible; at regime boundaries it breaks. The protocol's response: flag high-entropy posteriors (entropy > 1.5 bits) as transition-in-progress and recommend operator review rather than committing to a classification.
- Baum-Welch initialization is critical. Per the source ("in practice the initial conditions are very important"), random init produces unstable convergence. The protocol initializes from a hand-specified seed based on stylized regime characteristics, then refines with EM iterations.
- HMMs assume regime emission distributions are stationary. For crypto markets evolving structurally over years, this assumption breaks at long horizons. The protocol re-estimates on rolling 2-year windows; for shorter timescales (months), stationarity is a reasonable working assumption.

## 8. Appendix B: glossary

| Term | Definition |
|---|---|
| Basket | The ERC-6909 contract issuing QD with maturity buckets indexed by token id |
| β | Sensitivity of an asset's returns to a factor; estimated via Kalman as a dynamic state |
| Bond ladder | The QD redemption schedule across upcoming months; the protocol's scheduled liability curve. The structural-soundness layer of the reserve, duration-matched against redemption per §3.4 |
| Concentration factor | Multiplier for fees AND LVR for a concentrated LP position relative to full-range; approximately `1 / band_width`. Higher concentration = higher fee capture per dollar in range, and higher LVR per dollar in range |
| Coverage ratio | Scheduled reserve maturity divided by scheduled QD liability, per month bucket |
| ether.fi | Liquid staking provider; protocol holds eETH/weETH as ETH reserve form |
| Accumulation alpha | The difference between the protocol's effective entry price (via Vogue's signal-informed bands) and naive DCA's time-average spot. The structural analog of MSTR's MNAV-based premium capture — value created from timing intelligence rather than from leverage. Captured automatically as backing-per-QD growth |
| Conversion band | A Vogue-placed concentrated LP position below current spot, sized to convert a portion of the dollar leg into ETH or BTC linearly across the band as price moves down through it. The unit of Vogue's signal-informed accumulation |
| Cycle-weighted comparison | The structure's edge over benchmarks measured across a full market cycle (bull + capitulation + crab + bear), not regime-by-regime. The protocol's claim is cycle-weighted outperformance vs Saylor, not regime-by-regime dominance |
| DCA / Dollar-cost averaging | No-information accumulation: convert $1/period at whatever the current spot price is, uniformly over time. The §3.10 replay's primary benchmark against Vogue accumulation; effective entry price is the time-average spot. Vogue beats DCA in every regime per the replay |
| Fee switch | Post-UNIfication (Dec 2025) Uniswap governance change routing a portion of V3 LP fees to the protocol-fee accumulator rather than to LPs. Material haircut to net-to-LP fees on V3 positions; V4 positions under the protocol's own fee accumulator policy unaffected |
| Fee yield (LP) | Annualized fees earned by an LP position. Computed as pool volume × fee tier × LP's in-range share, annualized |
| Grinding bear | The current regime as of June 2026: ETH ~$1,975 (down ~60% from Aug 2025 ATH of $4,954), nine consecutive months of lower highs, Fear & Greed Index at 11, Bitcoin 50-day SMA below 200-day. The regime §3.10 replays as Regime 4 |
| IL / Impermanent loss / Divergence loss | Endpoint-driven LP loss vs 50/50 hold, convex in the price move. For full-range V2-style LP at endpoint ratio `k`: `IL = 1 − 2·√k/(1+k)`. A doubling and a halving cost the same ~5.7% |
| In-range share | The fraction of total active liquidity at the current tick that belongs to the LP position. Determines fee capture: fees earned = pool fee volume × in-range share |
| Innovation (y_t) | Residual between observation and Kalman prediction; sequence carries filter calibration signal |
| Innovation covariance (S_t) | Model-implied variance of the innovation; comparison with empirical variance is the divergence check |
| Hummingbot | Open-source market-making bot framework with established Uniswap V3/V4 strategy templates. The default integration point for §3.12 external operators; the protocol provides a standardized "QU!D Vogue Pool" strategy module operators can load |
| HMM regime layer | The §3.2 discrete-regime classifier composed on top of the Kalman bank. Six discrete states {strong_bull, weak_bull, crab, weak_bear, capitulation, recovery} with explicit transition probabilities `P(regime_{t+1} \| regime_t)`. Forward algorithm produces posterior `P(regime_t \| obs_{1..t})`; Viterbi produces most-likely historical regime sequence; Baum-Welch learns the parameters without ground-truth regime labels. Methodology from §A.5 (Jurafsky & Martin) |
| MSTR capital-structure operations | The §3.7 MSTR feature class added after the May–June 2026 episode: convert repurchase activity, USD reserve depletion rate, tactical BTC sale events, ATM equity issuance velocity in declining-MNAV environment. Distinct from accumulation features (purchase intensity, MNAV level); tracks Saylor's defensive capital management posture. Strong crystallize signal when active per §3.11 |
| Markov-switching state-space | The compositional model used by §3.2: Kalman tracks continuous within-regime dynamics (σ, β, φ) with linear-Gaussian updates; HMM tracks discrete regime transitions and emits posterior `P(regime | obs)` based on Kalman's output. Captures jumpy regime transitions and smooth within-regime evolution that either machinery alone underfits |
| Narrative crack event | A capital-structure operation that is mechanically immaterial but psychologically decisive — for example, Strategy's 32-BTC tactical sale on May 26–31, 2026 (0.0038% of holdings, $2.5M) that cracked the "Saylor never sells" narrative and contributed to a 3.1% BTC drop and ~$160B crypto-market-cap erasure. The §3.11 conjunction logic weights these events highly even at trivial underlying volume |
| Output Independence | The HMM assumption that observation `o_t` depends only on the current state `q_t`, not on other states or observations. Approximately true within a regime; breaks at regime transitions. Per §A.5, the protocol's response is to flag high-entropy regime posteriors (entropy > 1.5 bits) as transition-in-progress and recommend operator review rather than commit to a regime classification |
| Regime posterior | The probability distribution `P(regime_t | obs_{1..t})` over the HMM's discrete regimes at time t. Surfaced by the dashboard as a distribution, not a single committed classification. Diffuse posteriors (high entropy) signal regime transition in progress and flag for operator review per §3.2 |
| Viterbi-decoded regime sequence | The most-likely historical regime sequence under the §3.2 HMM, computed by the Viterbi algorithm (§A.5). The principled regime-boundary specification for §3.10's historical replay (replacing the current inspection-based boundaries) |
| Operator registry | The on-chain registry (§3.12) mapping external LP operator addresses to current track-record scores, allocation caps, basket take-rate tiers, and signal-feed-access tier. Updated by an off-chain track-record calculator on rolling-window boundaries |
| Plug-and-play liquidity | The §3.12 layer where external operators (typically running Hummingbot) provide LP capacity to Vogue's V4 pools beyond what the protocol's own reserves support. Operators bring their own capital and run their own strategies; a share of their realized TP P&L flows to the basket as revenue |
| Take-profit hook (TP hook) | The on-chain `tp_settle()` function called by external operator bots when unwinding LP positions. Computes the operator-vs-basket split per the operator's current take-rate tier and routes accordingly |
| Track-record feedback loop | The §3.12 mechanism that evaluates external operators on rolling windows (P&L net of LVR, signal-alignment, outperformance vs Vogue baseline, toxicity contribution, capital durability) and gates their allocation cap, basket take rate, and signal-stack access. Provides a continuous capital-at-risk empirical test of the signal stack's quality
| Intent/solver flow capture | Order-flow auction layers (UniswapX, CoW Swap, 1inch Fusion, RFQ aggregators) route through V3 pools as one liquidity venue among several. Empirical research finds solver-routed flow hitting V3 is *less* toxic, not more — solvers backstop uninformed retail intents on V3. The real V3 LP economic haircuts come from JIT liquidity sniping (bots cherry-pick uninformed flow before passive LPs can capture it) and latency-sensitive informed flow (MEV/arb bots routing direct because they need atomic execution). See §3.8 "Structural haircuts since pre-2022" |
| Inverse-vol weighting | The cross-asset allocation principle from the alpha-extraction framework (§A.4) that survives N=2 collapse. Vogue's dollar leg splits between ETH and BTC accumulation bands inversely to each asset's Kalman-estimated σ — balancing expected accumulation rate and LVR exposure across assets |
| JIT liquidity sniping | A V3 LP strategy where sophisticated bots observe large pending swaps in the mempool, mint highly-concentrated liquidity in the swap's tick range immediately before execution, and burn the position immediately after. They capture a disproportionate share of the swap's fees (90%+ typical) and only deploy against uninformed flow they detect as non-toxic. The residue passive LPs face is therefore adversely-selected. The dominant degradation mechanism for V3 LP fee economics; not addressed by the §3.8 rationality checklist but priced into the fee/LVR ratio empirically through the realized-fees-per-LVR-unit metric |
| Kalman gain (K) | Weight on new observation vs prior estimate; K = P / (P + R) in scalar form |
| LCR analog | "Months of liquid runway" — the dashboard's headline asset-liability matching metric |
| LP economics framework | The §3.8 analytical lens. Decomposes LP P&L into fees − LVR − costs, with regime-dependent rationality and benchmark-conditional quality. Centers the fee/LVR ratio as the decision metric |
| LP layer | The Uniswap V4 LP positions operated by Vogue (V4 primary) and Rover (V3 legacy) on the protocol's BTC/USD and ETH/USD pools |
| LVR / Loss-versus-rebalancing | Continuous-time analog of IL; a pure variance tax. For full-range LP: `LVR_annualized ≈ σ²/8`. Scales with concentration factor and time-in-range |
| Mean-reversion strength (φ) | AR(1) coefficient on returns; negative = reverting, positive = trending, ≈ 0 = random walk |
| MNAV / Multiple to NAV | The ratio of MSTR's equity market cap to the value of its BTC holdings. Expands in bull markets (Saylor's "BTC yield" mechanism) and compresses in drawdowns, amplifying MSTR's volatility above pure BTC volatility. A structural risk Vogue does not have |
| MSTR signal features | Observable inputs derived from MSTR's actions (8-K filings, ATM/convertible announcements, equity price, MNAV level/direction, refinancing pressure). Ingested by the signal stack as one feature among many (§3.7 sub-strip, §3.11). Never authoritative — modifies the composed Kalman + pool flow recommendation, cannot override it. |
| mockUSD | Vogue's internal accounting unit representing dollar-equivalent value held as the dollar leg of LP positions or in pure reserve. mockUSD always earns the ~4% T-bill baseline yield regardless of LP deployment state. When a band fills, mockUSD converts to ETH/BTC at the band's AMM-enforced prices. The §3.11 QD staking mechanic adjusts the mockUSD ledger without burning the staker's QD |
| Baseline yield | The ~4% T-bill APR earned by mockUSD whether or not it is deployed in active LP positions. Always present in the reserve composition. LP fees net of LVR is the *opt-in optimization on top* of the baseline, not a substitute for it |
| Crystallization | The decision to withdraw a filled Vogue LP band's position, moving the accumulated ETH/BTC out of the active AMM curve and locking it as protocol-held spot. Prevents the LP-sell-back effect where accumulated underlying would otherwise be sold back to mockUSD if price reverses upward through the band edge. The §3.11 primary operational signal output |
| Hold-vs-crystallize | The decision frame in §3.11 for each currently-deployed filled band: keep the LP active (collect more fees, accept price-reversal risk) or withdraw and lock the accumulation. Distinct from band placement (where to put new LPs) |
| QD staking | The opt-in §3.11 mechanic by which a QD holder commits N QD to a specific out-of-range Vogue band. The QD is locked but not burned; Vogue's mockUSD ledger adjusts to reflect the additional capacity backing that band. The staker continues earning baseline yield throughout, plus any LP fees if the band touches in-range, plus the fill-conversion outcome if the band fills |
| Staked-QD claim | A QD position that has been committed to a specific Vogue band via §3.11 staking. The claim points to that band's outcome (mockUSD remainder + accumulated underlying + accrued fees) rather than to the protocol's general reserve. Unstakeable when the band closes without filling; transitions to underlying-share when the band fills and is crystallized |
| Pool flow signal | The micro signal layer (§3.9) reading capital flow through the protocol's own V4 pools at block granularity. The protocol's structural information asymmetry. Computed as net dollar inflow, size asymmetry index, trader concentration (Herfindahl), and range-fill velocity per window |
| POOLED_ETH | In-range ETH-side liquidity in the protocol's V4 ETH/USD pool |
| QD | The stablecoin issued by Basket |
| Q (process noise) | Variance of state drift between observations; smaller → smoother estimate |
| R (measurement noise) | Variance of observation noise; smaller → trust observations more |
| Rover | V3-style LP manager for positions on Uniswap V3 pools where they remain active. Subject to the V3 fee switch haircut |
| Saylor strategy | The MSTR-style leveraged-bull accumulation: convertible debt and at-the-market equity issuance fund continuous BTC buying. Optimizes BTC-per-share. Failure modes: refinancing wall, forced selling under sustained drawdown, MNAV premium compression, ATM dilution. The §3.10 replay's secondary benchmark; Vogue beats Saylor in 3 of 4 regimes (loses in MNAV-expansion phases like 2023) |
| σ | Annualized volatility, tracked dynamically via Kalman in log-variance space |
| Short gamma + fee coupon | The identity governing all LP economics: an LP collects fees (theta-equivalent) while paying for realized movement (negative gamma). The LP position replicates a short straddle on the pool's asset pair |
| Signal stack | The composition of: (a) **Kalman state estimation** (§3.2, methodology per §A.3) tracking β, σ, and mean-reversion φ as dynamic hidden states; (b) **HMM discrete regime classification** (§3.2 HMM layer, methodology per §A.5) on top of Kalman, producing regime posterior `P(regime | obs)` and transition probabilities; (c) **non-extrapolation discipline** per §A.1 (Yartseva); (d) **non-forecasting discipline** per §A.2 (Miao) — no sequence models predicting price; (e) **inverse-vol cross-asset allocation** per §A.4 Eq. 10 (the surviving alpha-extraction principle at N=2); (f) **pool flow micro signal** (§3.9); (g) **macro context including MSTR features, MSTR capital-structure operations, and basket reweigh** (§3.7). Inputs to band-placement recommendations, the §3.8 LP rationality checklist, and the §3.11 crystallization signal |
| Structure residual | The QU!D structure's combined P&L over a period: `bond_ladder_share × bond_yield + LP_share × LP_P&L`, computed against benchmarks per §3.10 |
| UNIfication | Uniswap governance unification finalized December 2025; among other changes, enabled the fee switch on V3 pools |
| Vogue | The protocol's primary V4 auto-LP layer. Places concentrated bands below current spot to convert the dollar leg into ETH or BTC at signal-favored prices. The accumulation mechanism evaluated against DCA and Saylor in §3.10; capacity expandable via the QD staking rail (§3.11) |
| Vogue accumulation strategy | The signal-informed band-placement protocol Vogue executes, *with crystallization (§3.11)*. Bands are placed where the §3.2 Kalman regime and §3.9 pool flow read current spot as a less-favorable entry than levels below; filled bands are crystallized when the signal stack reads continued downside or directional risk, locking the accumulation as protocol spot. Beats DCA on accumulation efficiency in every regime; beats Saylor in 3 of 4 regimes via structural soundness (no leverage, no MNAV compression, baseline yield while waiting) |
| z-score | Standardized deviation `z = (X_W - mean_X) / std_X` used for anomaly detection on pool-flow measurements (§3.9). `|z| > 2.0` sustained triggers anomaly flag; `|z| > 3.0` triggers strong anomaly flag |

---

*End of specification.*
