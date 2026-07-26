// ════════════════════════════════════════════════════════════════════════
//   KALMAN BANK — dynamic state estimation (§3.2 of the dashboard spec).
//   "OLS gives you the average. Kalman gives you the current state."
//
//   Pure functions, no I/O. A scalar Kalman filter over a random-walk state
//   x_t = x_{t-1} + w (Q), with a (possibly time-varying) linear observation
//   z_t = H_t·x_t + v (R). Used three ways:
//     • σ — dynamic volatility in log-variance space (positivity + stability)
//     • β — dynamic factor exposure (ETH vs BTC)
//     • φ — AR(1) mean-reversion coefficient (trending / RW / mean-reverting)
//
//   Production rules from the spec, both implemented:
//     • innovation-divergence check: var(y)/mean(S) > THRESH → filter divergent
//     • Huber robust gain: down-weight innovations beyond 3·√S (fat tails)
// ════════════════════════════════════════════════════════════════════════

const DIVERGENCE_THRESHOLD = 2.0   // §3.2.4
const HUBER_K = 3.0                // §3.2.5 — clamp innovations beyond 3·√S

export interface KalmanResult {
  state: number       // filtered x_T (final)
  band: number        // ±√P_T uncertainty
  divergent: boolean  // innovation variance diverged from model S → retune
  divergenceRatio: number
}

// Run a scalar Kalman filter. `obs` = [{z, H}] in time order. Q/R/x0/P0 tune it.
function scalarKalman(obs: { z: number; H: number }[], Q: number, R: number, x0: number, P0: number): KalmanResult {
  let x = x0, P = P0
  const innovations: number[] = []
  const sList: number[] = []
  for (const { z, H } of obs) {
    // predict
    P = P + Q
    // innovation
    const y = z - H * x
    const S = H * P * H + R
    sList.push(S)
    innovations.push(y)
    // Huber robust gain: clamp the effective innovation beyond 3·√S
    const root = Math.sqrt(Math.max(S, 1e-12))
    const yEff = Math.abs(y) > HUBER_K * root ? Math.sign(y) * HUBER_K * root : y
    const K = (P * H) / S
    x = x + K * yEff
    P = (1 - K * H) * P
    if (!isFinite(x) || !isFinite(P)) { x = x0; P = P0 }   // guard
  }
  // divergence: empirical innovation variance vs model-implied mean(S)
  const n = innovations.length
  const meanY = innovations.reduce((a, b) => a + b, 0) / Math.max(n, 1)
  const varY = innovations.reduce((a, v) => a + (v - meanY) ** 2, 0) / Math.max(n - 1, 1)
  const meanS = sList.reduce((a, b) => a + b, 0) / Math.max(sList.length, 1)
  const ratio = meanS > 0 ? varY / meanS : 0
  return { state: x, band: Math.sqrt(Math.max(P, 0)), divergent: ratio > DIVERGENCE_THRESHOLD, divergenceRatio: ratio }
}

// ── Historical perspective: where does TODAY's volatility sit vs the whole
//    series? Rolling `window`-day annualized realized vol across the full
//    history, then the % of those days that were MORE volatile than the latest
//    reading (high → today is calm by historical standards). 90 days tells you
//    nothing about whether "normal" is normal; a decade does. ──
export function volPercentile(returns: number[], window = 30, periodsPerYear = 365): { current: number; calmerThanPct: number } {
  if (returns.length < window + 5) return { current: 0, calmerThanPct: 0 }
  const ann = Math.sqrt(periodsPerYear)
  const series: number[] = []
  for (let i = window; i <= returns.length; i++) {
    const w = returns.slice(i - window, i)
    const m = w.reduce((a, b) => a + b, 0) / window
    const v = w.reduce((a, r) => a + (r - m) ** 2, 0) / (window - 1)
    series.push(Math.sqrt(v) * ann)
  }
  const current = series[series.length - 1]
  const higher = series.filter(s => s > current).length
  return { current, calmerThanPct: (higher / series.length) * 100 }
}

// log-returns from a price series.
export function logReturns(prices: number[]): number[] {
  const r: number[] = []
  for (let i = 1; i < prices.length; i++) {
    if (prices[i] > 0 && prices[i - 1] > 0) r.push(Math.log(prices[i] / prices[i - 1]))
  }
  return r
}

// ── σ: dynamic volatility (§3.2.2), log-variance space. Returns annualized σ. ──
//    state = log(σ²_per-step); z = log(r²). periodsPerYear annualizes.
export interface VolResult { sigmaAnnual: number; band: number; divergent: boolean }
export function estimateVol(returns: number[], periodsPerYear: number): VolResult {
  if (returns.length < 5) return { sigmaAnnual: 0, band: 0, divergent: false }
  const obs = returns.map(r => ({ z: Math.log(Math.max(r * r, 1e-12)), H: 1 }))
  // R ≈ 1.0 (chi-square-derived per spec; Gaussian approx), Q_σ ≈ 0.1
  const seed = Math.log(Math.max(returns.reduce((a, r) => a + r * r, 0) / returns.length, 1e-12))
  const k = scalarKalman(obs, 0.1, 1.0, seed, 1.0)
  const sigmaStep = Math.exp(0.5 * k.state)            // √(σ²_per-step)
  const ann = Math.sqrt(periodsPerYear)
  // band: propagate ±√P through 0.5·exp(0.5·state) (delta method), annualized
  const dSigma = 0.5 * sigmaStep
  return { sigmaAnnual: sigmaStep * ann, band: dSigma * k.band * ann, divergent: k.divergent }
}

// ── β: dynamic factor exposure (§3.2.1). z = r_asset, H = r_factor. ──
export interface BetaResult { beta: number; band: number; divergent: boolean }
export function estimateBeta(assetReturns: number[], factorReturns: number[]): BetaResult {
  const n = Math.min(assetReturns.length, factorReturns.length)
  if (n < 5) return { beta: 1, band: 0, divergent: false }
  const obs = Array.from({ length: n }, (_, i) => ({ z: assetReturns[i], H: factorReturns[i] }))
  const k = scalarKalman(obs, 1e-5, 1e-3, 1, 1)        // Q_β≈1e-5, R_β≈1e-3
  return { beta: k.state, band: k.band, divergent: k.divergent }
}

// ── φ: AR(1) mean-reversion (§3.2.3). z = r_t, H = r_{t-1}. ──
export type ReversionLabel = 'trending' | 'random walk' | 'mean reverting'
export interface PhiResult { phi: number; band: number; label: ReversionLabel; divergent: boolean }
export function estimateMeanReversion(returns: number[]): PhiResult {
  if (returns.length < 6) return { phi: 0, band: 0, label: 'random walk', divergent: false }
  const obs: { z: number; H: number }[] = []
  for (let i = 1; i < returns.length; i++) obs.push({ z: returns[i], H: returns[i - 1] })
  const k = scalarKalman(obs, 1e-5, 1e-3, 0, 1)
  const phi = k.state
  const label: ReversionLabel = phi > 0.1 ? 'trending' : phi < -0.1 ? 'mean reverting' : 'random walk'
  return { phi, band: k.band, label, divergent: k.divergent }
}
