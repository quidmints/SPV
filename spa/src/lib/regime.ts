// The market regime, as a type. Consumed by market.ts, quant.ts and the market API route.
//
// §TWAP-DELETED (2026-09-11) — THE RUNTIME HALF OF THIS FILE IS GONE, AND ITS SUBJECT WENT WITH IT.
// `fetchRegime` classified the regime from `Core.observe(uint32[])` — the observation ring — which
// was deleted along with the rest of the TWAP machinery. The ring was a time-average OF the
// Chainlink feed, validated AGAINST the same feed, so it bought no manipulation resistance and
// added a MEASURED median 4,209 ppm of staleness against a 420 ppm charge.
//
// `fetchRegime`, `classifyRegime`, `realizedVol` and `decodeTwapLogPrices` all went with it. They
// had ZERO callers in `spa/src` at the time of deletion — measured, not assumed — so nothing in the
// app regressed. `RegimeRead`, `regimeLabel` and `regimePosture` were also uncalled and went too.
//
// ⛔ DO NOT RESTORE A POOL-RING REGIME READ. There is no pool ring. If a regime signal is wanted
// again it must come from a source the protocol does not itself produce, or it is the same circular
// measurement in a new costume.
export type Regime = 'chop' | 'oscillation' | 'trend'
