
// ════════════════════════════════════════════════════════════════════════
//   PER-LP REALIZED P&L (ETH side / Vogue) — reconstructed client-side.
//
//   The protocol emits no per-LP P&L event (this thread adds no Solidity), so
//   the connected wallet's ETH-LP position is rebuilt from the Vogue Deposit /
//   Withdraw logs (filtered by the `owner` indexed topic == the wallet):
//     • sharesHeld     = Σ deposit.shares − Σ withdraw.shares          (exact)
//     • ethInvestedNet = Σ deposit.assets − Σ withdraw.assets          (exact)
//     • currentValueEth= sharesHeld / lpShares() × vogueETH()  (on-chain, now)
//   The USD legs need a price PER deposit/withdraw block. The app's only price
//   source (market.ts → /api/market → CoinGecko) exposes the CURRENT price, not
//   a by-timestamp one, so the USD cost basis is APPROXIMATED at today's price
//   and flagged (costBasisApprox: true) — the UI must say so honestly. With an
//   archive RPC + historical feed this would become exact; the share/ETH math
//   above is already exact regardless.
//
//   Degrades gracefully (returns null / zeros, never throws), like flow.ts and
//   readOne do: no wallet, undeployed Vogue, or RPC log gaps → null / hasPosition
//   = false.
// ════════════════════════════════════════════════════════════════════════

import { ethers } from 'ethers'
import { CONTRACTS } from './chains.ts'
import { readOne, getLogs, blockNumber, padAddr, hasRpc, ZERO_ADDR } from './eth.ts'
import { fetchMarket } from './market.ts'

export interface LpPnl {
  hasPosition: boolean
  // ── exact, from events / on-chain ──
  sharesHeld: number          // Σ deposit.shares − Σ withdraw.shares
  ethInvestedNet: number      // Σ deposit.assets − Σ withdraw.assets (ETH)
  currentValueEth: number     // sharesHeld / lpShares × vogueETH (ETH, now)
  currentValueUsd: number     // currentValueEth × current ETH price
  feesEarnedEth: number       // position's share of pool fee growth (approx — see note)
  // ── USD legs (approx at current price unless an archive feed is wired) ──
  investedUsd: number         // Σ deposit.assets × price(t)
  withdrawnUsd: number        // Σ withdraw.assets × price(t)
  costBasisUsd: number        // investedUsd − withdrawnUsd (net dollars put in)
  netVsQdUsd: number          // currentValueUsd + withdrawnUsd − investedUsd  ← HEADLINE
  costBasisApprox: boolean    // true ⇒ USD legs priced at TODAY's price, not entry
}

// Vogue Deposit / Withdraw topic0 (signature hashes). Owner topic index differs:
//   Deposit(sender indexed, owner indexed, assets, shares)            → owner = topics[2]
//   Withdraw(sender indexed, receiver indexed, owner indexed, …)      → owner = topics[3]
const DEPOSIT_TOPIC  = ethers.id('Deposit(address,address,uint256,uint256)')
const WITHDRAW_TOPIC = ethers.id('Withdraw(address,address,address,uint256,uint256)')

// Each event's two non-indexed words are (assets, shares) — decode by POSITION
// (32-byte slots in `data`), name-robust like flow.ts does.
function decodeAssetsShares(dataHex: string): { assets: bigint; shares: bigint } {
  try {
    const d = dataHex.startsWith('0x') ? dataHex.slice(2) : dataHex
    if (d.length < 128) return { assets: 0n, shares: 0n }
    const assets = BigInt('0x' + d.slice(0, 64))
    const shares = BigInt('0x' + d.slice(64, 128))
    return { assets, shares }
  } catch { return { assets: 0n, shares: 0n } }
}

const toEth = (v: bigint) => Number(v) / 1e18

export async function fetchLpPnl(address: string | null): Promise<LpPnl | null> {
  if (!address || !hasRpc()) return null
  if (!CONTRACTS.vogue || CONTRACTS.vogue === ZERO_ADDR) return null

  const ownerTopic = padAddr(address)

  // Scan from genesis-ish (0) to latest. The wallet provider's eth_getLogs may
  // range-limit; getLogs returns [] on failure → we degrade to "no position"
  // rather than throw. Topic position differs per event (see above).
  const head = await blockNumber()
  if (head === 0) return null

  const [depLogs, wdLogs] = await Promise.all([
    getLogs({ address: CONTRACTS.vogue, fromBlock: 0, toBlock: head,
      topics: [DEPOSIT_TOPIC, null, ownerTopic] }),                 // owner = topics[2]
    getLogs({ address: CONTRACTS.vogue, fromBlock: 0, toBlock: head,
      topics: [WITHDRAW_TOPIC, null, null, ownerTopic] }),          // owner = topics[3]
  ])

  // ── EXACT share / ETH accounting from events ──
  let depShares = 0n, depAssets = 0n, wdShares = 0n, wdAssets = 0n
  for (const l of depLogs) { const { assets, shares } = decodeAssetsShares(l.data); depAssets += assets; depShares += shares }
  for (const l of wdLogs)  { const { assets, shares } = decodeAssetsShares(l.data); wdAssets += assets; wdShares += shares }

  const sharesHeldBig = depShares - wdShares
  const sharesHeld = Number(sharesHeldBig) / 1e18
  const ethInvestedNet = toEth(depAssets - wdAssets)

  const hasPosition = depLogs.length > 0 || wdLogs.length > 0

  if (!hasPosition) {
    return {
      hasPosition: false,
      sharesHeld: 0, ethInvestedNet: 0,
      currentValueEth: 0, currentValueUsd: 0, feesEarnedEth: 0,
      investedUsd: 0, withdrawnUsd: 0, costBasisUsd: 0, netVsQdUsd: 0,
      costBasisApprox: true,
    }
  }

  // ── Current value (on-chain, exact NOW): sharesHeld / lpShares × vogueETH ──
  let currentValueEth = 0
  const lpSharesRaw = await readOne(CONTRACTS.vogue, 'lpShares')
  const vogueEthRaw = await readOne(CONTRACTS.vogue, 'vogueETH')
  try {
    if (lpSharesRaw != null && vogueEthRaw != null) {
      const lpShares = BigInt(lpSharesRaw), vogueEth = BigInt(vogueEthRaw)
      if (lpShares > 0n && sharesHeldBig > 0n) {
        // value = sharesHeld/lpShares × vogueEth, computed in 1e18 fixed point.
        const valWei = (sharesHeldBig * vogueEth) / lpShares
        currentValueEth = toEth(valWei)
      }
    }
  } catch { /* leave 0 */ }

  // ── Fees earned (ETH): the position's share of pool fee growth. We have no
  //   per-LP ENTRY feesPerShare snapshot on-chain (no event carries it), so we
  //   surface the position's CURRENT pro-rata accrual = feesPerShare × shares,
  //   labelled as "fees earned (approx)". This is the same proxy InfoTab uses
  //   for the protocol total; it overstates if the LP entered after fees began
  //   accruing — kept honest via the UI label, not fabricated precision. ──
  let feesEarnedEth = 0
  const fpsRaw = await readOne(CONTRACTS.vogue, 'feesPerShare')
  try {
    if (fpsRaw != null && sharesHeldBig > 0n) {
      const fps = BigInt(fpsRaw)
      feesEarnedEth = Number((fps * sharesHeldBig) / (10n ** 18n)) / 1e18
    }
  } catch { /* leave 0 */ }

  // ── Price: current ETH price from the app's existing source (market.ts). No
  //   by-timestamp price is exposed, so USD cost basis is approximated at the
  //   CURRENT price and flagged. ──
  const market = await fetchMarket()
  const ethPrice = market && !market.degraded ? market.eth.price : 0
  const costBasisApprox = true   // always, until an archive/by-timestamp feed is wired

  const currentValueUsd = currentValueEth * ethPrice
  const investedUsd = toEth(depAssets) * ethPrice
  const withdrawnUsd = toEth(wdAssets) * ethPrice
  const costBasisUsd = investedUsd - withdrawnUsd
  // HEADLINE: lifetime result vs. having just held the dollars (the QD baseline).
  const netVsQdUsd = currentValueUsd + withdrawnUsd - investedUsd

  return {
    hasPosition: true,
    sharesHeld,
    ethInvestedNet,
    currentValueEth,
    currentValueUsd,
    feesEarnedEth,
    investedUsd,
    withdrawnUsd,
    costBasisUsd,
    netVsQdUsd,
    costBasisApprox,
  }
}
