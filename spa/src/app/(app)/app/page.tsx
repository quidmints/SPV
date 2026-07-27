'use client'

import { useState, useEffect, useCallback, useMemo } from 'react'
import { ethers } from 'ethers'
import {
  CHAIN_ID, CHAIN_HEX, CHAIN_NAME, EXPLORER,
  CONTRACTS, STABLES, WBTC_DECIMALS, isUsdtLike, ETH_VENUES, type StableToken, type LevVenue,
} from '@/lib/chains'
import { ERC20_ABI, BASKET_ABI, AUX_ABI, VOGUE_ABI, BTCCHANNELS_ABI, LEV_MANAGER_ABI } from '@/lib/abi'
import { addressToScriptPubKey, randomSwapId } from '@/lib/btcaddress'
import { requestOnchainSwapIn, pollSwapIn, hopApiConfigured, submitOpenChannel, pollOpenChannel,
  type OnchainSwapInQuote, type SwapInStatus, type OpenChannelResult } from '@/lib/hop'
import { readLevPosition, type LevPosition } from '@/lib/leverage'
import InfoTab from '@/components/app/InfoTab'
import ComfortPanel from '@/components/app/ComfortPanel'
import LeverageCard from '@/components/app/LeverageCard'
import LeverageActionPanel from '@/components/app/LeverageActionPanel'
import PnLPanel from '@/components/app/PnLPanel'
import { sendTx, enableProtection, PROTECT } from '@/lib/protect'

declare global { interface Window { ethereum?: any } }

// ═════════════════════════════════════════════════════════════════════
//   FORMATTING HELPERS
// ═════════════════════════════════════════════════════════════════════
const fmt = (n: number, d = 4) =>
  !isFinite(n) || n === 0 ? '0'
  : Math.abs(n) < 0.0001 ? '<0.0001'
  : n.toLocaleString('en-US', { maximumFractionDigits: d })

const fmtUSD = (n: number, d = 2) => `$${fmt(n, d)}`
const short = (a: string) => a ? `${a.slice(0, 6)}…${a.slice(-4)}` : ''
const MAX_UINT256 = (1n << 256n) - 1n
const ZERO_ADDR = '0x0000000000000000000000000000000000000000'

// ═════════════════════════════════════════════════════════════════════
//   ABI ENCODING — one ethers.Interface for all read/write encodes
// ═════════════════════════════════════════════════════════════════════
const iface = new ethers.Interface([
  ...ERC20_ABI, ...BASKET_ABI, ...AUX_ABI, ...VOGUE_ABI, ...BTCCHANNELS_ABI, ...LEV_MANAGER_ABI,
])

const enc = {
  // ERC20
  balanceOf:  (a: string) => iface.encodeFunctionData('balanceOf(address)', [a]),
  allowance:  (o: string, s: string) => iface.encodeFunctionData('allowance', [o, s]),
  approve:    (s: string, n: bigint) => iface.encodeFunctionData('approve', [s, n]),
  // Basket
  // NOTE: full signatures REQUIRED — the merged iface has overloads of mint/swap/
  // redeem/auxSwap (Basket + Vogue + Aux), so the bare name is ambiguous in ethers v6.
  mint:       (p: string, amt: bigint, t: string, when: number) =>
                iface.encodeFunctionData('mint(address,uint256,address,uint256)', [p, amt, t, when]),
  currentMonth: () => iface.encodeFunctionData('currentMonth', []),
  immatureBal: (u: string) => iface.encodeFunctionData('immatureBalanceOf', [u]),
  totalSupply: () => iface.encodeFunctionData('totalSupply', []),
  // Aux
  swap:        (token: string, asset: string, forVolatile: boolean, amt: bigint, minOut: bigint) =>
                iface.encodeFunctionData('swap(address,address,bool,uint256,uint256)', [token, asset, forVolatile, amt, minOut]),
  redeem:      (n: bigint) => iface.encodeFunctionData('redeem(uint256)', [n]),
  auxSwap:     (tIn: string, tOut: string, amt: bigint, recip: string, minOut: bigint) =>
                iface.encodeFunctionData('auxSwap(address,address,uint256,address,uint256)', [tIn, tOut, amt, recip, minOut]),
  exitInstant: (a: bigint, r: string) => iface.encodeFunctionData('exitInstant', [a, r]),
  redeemable:  () => iface.encodeFunctionData('redeemableAmount', []),
  twapAsset:   (asset: string, p: number) => iface.encodeFunctionData('getTWAPforAsset', [asset, p]),
  metrics:     (force: boolean) => iface.encodeFunctionData('get_metrics', [force]),
  deposits:    () => iface.encodeFunctionData('get_deposits', []),
  avgYield:    () => iface.encodeFunctionData('avgYield', []),
  // Vogue (ETH side ERC4626-shaped)
  vogueDepositV: (a: bigint, r: string, v: number) => iface.encodeFunctionData('deposit(uint256,address,uint8)', [a, r, v]),
  vogueWithdraw: (a: bigint, r: string, o: string) =>
                iface.encodeFunctionData('withdraw(uint256,address,address)', [a, r, o]),
  autoManaged:    (u: string) => iface.encodeFunctionData('autoManaged', [u]),
  autoManagedBTC: (u: string) => iface.encodeFunctionData('autoManagedBTC', [u]),
  vogueTotalShares: () => iface.encodeFunctionData('totalShares', []),
  vogueLpShares:    () => iface.encodeFunctionData('lpShares', []),
  // Self-managed
  outOfRange: (amt: bigint, token: string, distance: number, range: number, venue: number) =>
                iface.encodeFunctionData('outOfRange', [amt, token, distance, range, venue]),
  pull:       (id: bigint, percent: number, token: string) =>
                iface.encodeFunctionData('pull', [id, percent, token]),
  positions:  (u: string, i: number) => iface.encodeFunctionData('positions', [u, i]),
  selfManaged: (id: bigint) => iface.encodeFunctionData('selfManaged', [id]),
  // BTCChannels
  channels:    (id: string) => iface.encodeFunctionData('channels', [id]),
  requestSwapOutOnchain: (token: string, usd: bigint, minSats: bigint, swapId: string, script: string) =>
                iface.encodeFunctionData('requestSwapOutOnchain', [token, usd, minSats, swapId, script]),
  recordClose: (id: string, rawTx: string, blk: string, proof: string[], txIndex: number) =>
                iface.encodeFunctionData('recordClose', [id, rawTx, blk, proof, txIndex]),
  openChannelDigest: (p: unknown, rawTx: string, hop: string) =>
                iface.encodeFunctionData('openChannelDigest', [p, rawTx, hop]),
  openChannel: (p: unknown, rawTx: string, proof: string[], lpAuth: string, payoutHash: string) =>
                iface.encodeFunctionData('openChannel', [p, rawTx, proof, lpAuth, payoutHash]),
  // LevManager (YB leverage overlay, #65). Full sigs (merged iface has overloads).
  // openLev passes an EMPTY minWethOut[] — the open borrows nothing (opens at zero
  // leverage); the keeper levers up afterward, so there's no swap to floor here.
  openLev:      (targetLtvBps: number, venue: string, coll: bigint, minWethOut: bigint[]) =>
                iface.encodeFunctionData('openLev(uint64,address,uint256,uint256[])', [targetLtvBps, venue, coll, minWethOut]),
  setTargetLtv: (capBps: number) => iface.encodeFunctionData('setTargetLtv(uint64)', [capBps]),
  closeLev:     (minOut: bigint) => iface.encodeFunctionData('closeLev(uint256)', [minOut]),
  levCap:       () => iface.encodeFunctionData('TARGET_LTV_CAP_BPS', []),
}

// ═════════════════════════════════════════════════════════════════════
//   eth_call helper + USDT-safe approval + tx waiter
// ═════════════════════════════════════════════════════════════════════
async function ethCall(to: string, data: string): Promise<string> {
  return window.ethereum.request({
    method: 'eth_call',
    params: [{ to, data }, 'latest'],
  })
}

async function waitTx(hash: string, timeoutSec = 90): Promise<void> {
  for (let i = 0; i < timeoutSec; i++) {
    await new Promise(r => setTimeout(r, 1000))
    const r = await window.ethereum.request({
      method: 'eth_getTransactionReceipt', params: [hash],
    })
    if (r?.status === '0x1') return
    if (r?.status === '0x0') throw new Error(`tx ${hash} reverted`)
  }
  throw new Error(`tx ${hash} timed out`)
}

async function ensureAllowance(
  token: string, spender: string, amount: bigint, owner: string,
  setStatus?: (s: string) => void,
): Promise<void> {
  const cur = BigInt(await ethCall(token, enc.allowance(owner, spender)))
  if (cur >= amount) return
  if (isUsdtLike(token) && cur > 0n) {
    setStatus?.('USDT: resetting allowance to 0…')
    const reset = await sendTx({ from: owner, to: token, data: enc.approve(spender, 0n) })
    await waitTx(reset)
  }
  setStatus?.('Approving token…')
  const tx = await sendTx({ from: owner, to: token, data: enc.approve(spender, MAX_UINT256) })
  await waitTx(tx)
}

// msg.value + WETH max-pull (mirror Aux._depositETH on the wallet side).
function splitEthForDeposit(totalWei: bigint, rawEthWei: bigint, wethWei: bigint):
  { msgValue: bigint; wethAmount: bigint } {
  if (totalWei <= rawEthWei) return { msgValue: totalWei, wethAmount: 0n }
  if (totalWei <= rawEthWei + wethWei) return { msgValue: rawEthWei, wethAmount: totalWei - rawEthWei }
  throw new Error('Insufficient ETH + WETH balance')
}

// ═════════════════════════════════════════════════════════════════════
//   APP
// ═════════════════════════════════════════════════════════════════════
type Tab = 'info' | 'mint' | 'deposit' | 'withdraw' | 'swap' | 'redeem' | 'channel'

export default function QuidApp() {
  const [tab, setTab] = useState<Tab>('mint')
  // Deep-link from the landing's "Explore X" cards: /app?tab=channel selects a tab.
  useEffect(() => {
    const q = new URLSearchParams(window.location.search).get('tab')
    if (q && ['info', 'mint', 'deposit', 'withdraw', 'swap', 'redeem', 'channel'].includes(q)) setTab(q as Tab)
  }, [])

  // ── Wallet ──────────────────────────────────────────────────────────
  const [connected, setConnected] = useState(false)
  const [protect, setProtect] = useState(false)   // frontrunning protection (private relay) active
  const [address, setAddress] = useState('')
  const [chainOk, setChainOk] = useState(false)

  // ── Balances ────────────────────────────────────────────────────────
  // Note: no on-chain BTC balance stat — there is no user-facing BTC token.
  // The user's BTC stake is QUID (minted at channel open); BTC-leg fees accrue
  // as native sats (Vogue.btcFeesOwedSats). WBTC is an Aux-internal pricing/SOR
  // leg only. Native BTC is delivered by the hop on swap-out — never wrapped.
  const [ethBal, setEthBal] = useState('0')
  const [wethBal, setWethBal] = useState('0')
  const [qdBal, setQdBal] = useState('0')
  const [matureQd, setMatureQd] = useState('0')
  const [stableBals, setStableBals] = useState<Record<string, string>>({})
  const [stableAllowances, setStableAllowances] = useState<Record<string, string>>({})

  // ── Protocol state ──────────────────────────────────────────────────
  const [ethTwap, setEthTwap] = useState(0)
  const [btcTwap, setBtcTwap] = useState(0)  // WBTC TWAP (= BTC/USD via the V4 BTC pool)
  const [currentMonth, setCurrentMonth] = useState(0)
  const [redeemable, setRedeemable] = useState('0')
  const [qdTotalSupply, setQdTotalSupply] = useState('0')
  const [basketTotal, setBasketTotal] = useState(0)
  const [basketYield, setBasketYield] = useState(0)
  const [avgYield, setAvgYield] = useState(0)
  const [perStable, setPerStable] = useState<number[]>([])
  const [vogueShares, setVogueShares] = useState(0)
  const [autoMan, setAutoMan] = useState<{ pooled: number; feesEth: number; feesUsd: number; usdOwed: number } | null>(null)
  const [showBreakdown, setShowBreakdown] = useState(false)

  // ── Leverage overlay (YB IL-protect, #65) ──────────────────────────
  const [levPos, setLevPos] = useState<LevPosition | null>(null)
  const [levCap, setLevCap] = useState(7500)  // on-chain TARGET_LTV_CAP_BPS

  // ── Tx UI ───────────────────────────────────────────────────────────
  const [busy, setBusy] = useState(false)
  const [txMutex, setTxMutex] = useState(false)
  const [status, setStatus] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [lastTx, setLastTx] = useState<string | null>(null)

  // ── Per-tab state ───────────────────────────────────────────────────
  const [mintToken, setMintToken] = useState<StableToken | null>(null)
  const [mintAmount, setMintAmount] = useState('')
  const [maturityMonths, setMaturityMonths] = useState(12)

  const [depositSubTab, setDepositSubTab] = useState<'auto' | 'self'>('auto')
  const [depositVenue, setDepositVenue] = useState(0) // ETH_VENUES id; 0 = Split (default)
  const [withdrawSubTab, setWithdrawSubTab] = useState<'auto' | 'self' | 'btc'>('auto')
  // BTC LP withdrawal (channel close) — lives in the withdraw screen alongside ETH.
  const [myChannels, setMyChannels] = useState<{ id: string; sats: bigint; status: number }[]>([])
  const [btcLp, setBtcLp] = useState<{ pooledSats: number; feesSats: number; usdOwed: number; feesUsd: number } | null>(null)
  const [closeId, setCloseId] = useState('')
  const [closeRawTx, setCloseRawTx] = useState('')
  const [closeBlockHash, setCloseBlockHash] = useState('')
  const [closeProof, setCloseProof] = useState('')      // JSON array of bytes32
  const [closeTxIndex, setCloseTxIndex] = useState('')
  const [depositAmount, setDepositAmount] = useState('')
  const [withdrawAmount, setWithdrawAmount] = useState('')
  // Per-tx ether.fi exit preference (replaces the former stored withdrawInstant flag): when
  // true, THIS withdrawal calls Vogue.exitInstant (opts into the ~0.3% instant redeem).
  const [instantExit, setInstantExit] = useState(false)

  // Self-managed (Vogue.outOfRange / pull) state
  const [oorAmount, setOorAmount] = useState('')
  const [oorSide, setOorSide] = useState<'eth' | 'usd'>('eth')
  const [oorStable, setOorStable] = useState<StableToken | null>(null)
  const [oorDistance, setOorDistance] = useState(5)   // UI %; sent as ticks = % × 100
  const [oorRange, setOorRange] = useState(2)         // UI %; ticks = % × 100, snap to 50
  const [smPositions, setSmPositions] = useState<
    { id: bigint; created: bigint; lower: number; upper: number; liq: bigint }[]
  >([])
  const [pullPercents, setPullPercents] = useState<Record<string, number>>({})
  const [pullTokens,   setPullTokens]   = useState<Record<string, string>>({})

  // BTC direction is "USD → BTC" externally — internally it's USD → WBTC on
  // the V4 BTC pool (pricing leg only); the hop daemon broadcasts native BTC
  // to the user's btcRecipientOf address.
  const [swapDirection, setSwapDirection] = useState<'usdToEth' | 'ethToUsd' | 'usdToBtc' | 'btcToUsd' | 'usdToUsd'>('usdToEth')
  // BTC→USD swap-in (on-chain, invoice-free): request a deposit address, send BTC, poll.
  const [swapInQuote, setSwapInQuote] = useState<OnchainSwapInQuote | null>(null)
  const [swapInStatus, setSwapInStatus] = useState<SwapInStatus | null>(null)
  const [swapInBusy, setSwapInBusy] = useState(false)
  const [swapAmount, setSwapAmount] = useState('')
  const [swapToken, setSwapToken] = useState<StableToken | null>(null)
  const [swapMinOut, setSwapMinOut] = useState('0')
  const [swapBtcAddr, setSwapBtcAddr] = useState('')   // user's Bitcoin address for USD→BTC (rail B)
  const [swapTokenOut, setSwapTokenOut] = useState<StableToken | null>(null) // output stable for stable↔stable
  const [btcRecipientHash, setBtcRecipientHash] = useState('')
  // openChannel EVM-half: artifacts produced by the LP's node / funding tooling.
  const [ocParams, setOcParams] = useState('')    // OpenParams JSON
  const [ocRawTx, setOcRawTx] = useState('')       // rawFundingTx hex
  const [ocProof, setOcProof] = useState('')       // fundingMerkleProof JSON array
  const [ocLpAuth, setOcLpAuth] = useState('')     // lpAuth signature hex
  const [ocLpBtcPayout, setOcLpBtcPayout] = useState('') // lpBtcPayoutHash (P2WPKH, node-supplied)
  const [ocDigest, setOcDigest] = useState('')     // computed openChannelDigest
  const [ocRecovered, setOcRecovered] = useState('') // address recovered from lpAuth
  const [ocRelay, setOcRelay] = useState<OpenChannelResult | null>(null) // hop relay progress
  const [redeemAmount, setRedeemAmount] = useState('')

  // ── Waiver modal ────────────────────────────────────────────────────
  const [showWaiver, setShowWaiver] = useState(false)
  const [showAbout, setShowAbout] = useState(false)
  const [waiverChecked, setWaiverChecked] = useState(false)
  const [waiverAccepted, setWaiverAccepted] = useState(false)
  useEffect(() => {
    try { setWaiverAccepted(localStorage.getItem('quid-waiver-v1') === '1') } catch {}
  }, [])

  // ═══════════════════════════════════════════════════════════════════
  //   WALLET
  // ═══════════════════════════════════════════════════════════════════
  const switchChain = useCallback(async () => {
    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: CHAIN_HEX }],
      })
      setChainOk(true)
    } catch (e: any) {
      setError(`Switch to ${CHAIN_NAME} (chainId ${CHAIN_ID}) in your wallet.`)
    }
  }, [])

  const connect = useCallback(async () => {
    if (!window.ethereum) { setError('Install MetaMask or another EVM wallet.'); return }
    setError(null); setBusy(true)
    try {
      const [a] = await window.ethereum.request({ method: 'eth_requestAccounts' })
      setAddress(a); setConnected(true)
      const hex = await window.ethereum.request({ method: 'eth_chainId' })
      if (parseInt(hex, 16) !== CHAIN_ID) await switchChain()
      else setChainOk(true)
      // Offer frontrunning protection: route the write-path through a private
      // relay (Flashbots Protect / MEV Blocker). Best-effort — user may decline.
      setProtect(await enableProtection())
    } catch (e: any) { setError(e.message || 'connect failed') }
    finally { setBusy(false) }
  }, [switchChain])

  useEffect(() => {
    if (!window.ethereum) return
    const onAccount = (acc: string[]) => {
      if (acc[0]) { setAddress(acc[0]); setConnected(true) }
      else {
        setAddress(''); setConnected(false)
        setStableBals({}); setStableAllowances({})
        setQdBal('0'); setMatureQd('0')
      }
    }
    const onChain = (hex: string) => setChainOk(parseInt(hex, 16) === CHAIN_ID)
    window.ethereum.on('accountsChanged', onAccount)
    window.ethereum.on('chainChanged', onChain)
    return () => {
      window.ethereum.removeListener?.('accountsChanged', onAccount)
      window.ethereum.removeListener?.('chainChanged', onChain)
    }
  }, [])

  // ═══════════════════════════════════════════════════════════════════
  //   READS
  // ═══════════════════════════════════════════════════════════════════
  const fetchBalances = useCallback(async () => {
    if (!connected || !chainOk) return

    // Native ETH
    try {
      const e = await window.ethereum.request({ method: 'eth_getBalance', params: [address, 'latest'] })
      setEthBal((Number(BigInt(e)) / 1e18).toFixed(6))
    } catch {}

    // WETH (combined with native ETH for LP deposit)
    try {
      const w = await ethCall(CONTRACTS.weth, enc.balanceOf(address))
      setWethBal((Number(BigInt(w)) / 1e18).toFixed(6))
    } catch {}

    // QUI / mature QUI / month / total supply
    if (CONTRACTS.basket !== ZERO_ADDR) {
      try {
        const bal = BigInt(await ethCall(CONTRACTS.basket, enc.balanceOf(address)))
        setQdBal(bal.toString())
        // mature = total − immature (Basket exposes no totalMatureBalanceOf getter)
        try {
          const imm = BigInt(await ethCall(CONTRACTS.basket, enc.immatureBal(address)))
          setMatureQd((bal > imm ? bal - imm : 0n).toString())
        } catch {}
      } catch {}
      let cm = currentMonth
      try { cm = Number(BigInt(await ethCall(CONTRACTS.basket, enc.currentMonth()))); setCurrentMonth(cm) } catch {}
      try { setQdTotalSupply(BigInt(await ethCall(CONTRACTS.basket, enc.totalSupply())).toString()) } catch {}
    }

    // Stable balances + allowances to Aux
    const bals: Record<string, string> = {}
    const allows: Record<string, string> = {}
    for (const s of STABLES) {
      try {
        bals[s.address] = BigInt(await ethCall(s.address, enc.balanceOf(address))).toString()
      } catch { bals[s.address] = '0' }
      if (CONTRACTS.aux !== ZERO_ADDR) {
        try {
          allows[s.address] = BigInt(await ethCall(s.address, enc.allowance(address, CONTRACTS.aux))).toString()
        } catch { allows[s.address] = '0' }
      }
    }
    setStableBals(bals); setStableAllowances(allows)
  }, [connected, chainOk, address])

  const fetchMetrics = useCallback(async () => {
    if (!chainOk || CONTRACTS.aux === ZERO_ADDR) return
    // ETH TWAP — getTWAPforAsset(WETH, …); there is no ETH-only getTWAP on Aux.
    try { setEthTwap(Number(BigInt(await ethCall(CONTRACTS.aux, enc.twapAsset(CONTRACTS.weth, 1800)))) / 1e18) } catch {}
    // WBTC TWAP (BTC/USD on the V4 BTC pool, via Aux.getTWAPforAsset)
    try { setBtcTwap(Number(BigInt(await ethCall(CONTRACTS.aux, enc.twapAsset(CONTRACTS.wbtc, 1800)))) / 1e18) } catch {}
    // get_metrics (not view — state-mutating in some paths; eth_call still works)
    try {
      const m = await ethCall(CONTRACTS.aux, enc.metrics(false))
      const dec = iface.decodeFunctionResult('get_metrics', m)
      setBasketTotal(Number(BigInt(dec[0])) / 1e18)
      setBasketYield(Number(BigInt(dec[1])) / 1e18)
    } catch {}
    // average yield
    try {
      const y = await ethCall(CONTRACTS.aux, enc.avgYield())
      setAvgYield(Number(BigInt(y)) / 1e16)  // WAD bps → %
    } catch {}
    // redeemableAmount
    try { setRedeemable(BigInt(await ethCall(CONTRACTS.aux, enc.redeemable())).toString()) } catch {}
    // per-stable deposits: get_deposits returns uint[15] — 12 stables at 0..11, aggregates at 12..14
    try {
      const d = await ethCall(CONTRACTS.aux, enc.deposits())
      const dec = iface.decodeFunctionResult('get_deposits', d)
      setPerStable((dec[0] as bigint[]).map(v => Number(v) / 1e18))
    } catch {}
  }, [chainOk])

  const fetchVogue = useCallback(async () => {
    if (!chainOk || CONTRACTS.vogue === ZERO_ADDR) return
    try {
      const ts = await ethCall(CONTRACTS.vogue, enc.vogueTotalShares())
      setVogueShares(Number(BigInt(ts)) / 1e18)
    } catch {}
    if (!address) return
    try {
      const a = await ethCall(CONTRACTS.vogue, enc.autoManaged(address))
      const dec = iface.decodeFunctionResult('autoManaged', a)
      // Types.Deposit order: (pooled, usd_owed, fees_tok, fees_usd).
      setAutoMan({
        pooled:  Number(BigInt(dec[0])) / 1e18,  // pooled
        usdOwed: Number(BigInt(dec[1])) / 1e18,  // usd_owed
        feesEth: Number(BigInt(dec[2])) / 1e18,  // fees_tok (ETH-side fee leg)
        feesUsd: Number(BigInt(dec[3])) / 1e18,  // fees_usd
      })
    } catch {}
  }, [chainOk, address])

  // Leverage overlay: the LP's live position + the on-chain hard LTV cap.
  const fetchLevPos = useCallback(async () => {
    if (!connected || !chainOk || CONTRACTS.levManager === ZERO_ADDR || !address) { setLevPos(null); return }
    try { setLevPos(await readLevPosition(address)) } catch { setLevPos(null) }
    try {
      const c = Number(BigInt(await ethCall(CONTRACTS.levManager, enc.levCap())))
      if (c > 0) setLevCap(c)
    } catch {}
  }, [connected, chainOk, address])

  // Walk positions[user] until id == 0 (capped to 50 for safety).
  // Skip zero-liq entries (already pulled to 0%).
  const fetchSmPositions = useCallback(async () => {
    if (!connected || !chainOk || CONTRACTS.vogue === ZERO_ADDR) return
    const out: typeof smPositions = []
    for (let i = 0; i < 50; i++) {
      try {
        const idR = await ethCall(CONTRACTS.vogue, enc.positions(address, i))
        const id = BigInt(idR)
        if (id === 0n) break
        const smR = await ethCall(CONTRACTS.vogue, enc.selfManaged(id))
        const dec = iface.decodeFunctionResult('selfManaged', smR)
        const liq = BigInt(dec[4] as bigint)
        if (liq > 0n) {
          out.push({
            id,
            created: BigInt(dec[0] as bigint),
            lower:   Number(dec[2]),
            upper:   Number(dec[3]),
            liq,
          })
        }
      } catch { break }  // array out-of-bounds = end of list
    }
    setSmPositions(out)
  }, [connected, chainOk, address])

  useEffect(() => { void fetchBalances() }, [fetchBalances])
  useEffect(() => { void fetchMetrics() }, [fetchMetrics])
  useEffect(() => { void fetchVogue() }, [fetchVogue])
  useEffect(() => { void fetchSmPositions() }, [fetchSmPositions])
  useEffect(() => { void fetchLevPos() }, [fetchLevPos])

  // Auto-pick first stable with balance for mint
  useEffect(() => {
    if (mintToken) return
    const first = STABLES.find(s => BigInt(stableBals[s.address] || '0') > 0n)
    if (first) setMintToken(first)
  }, [stableBals, mintToken])

  // Auto-pick first stable with balance for swap (USD-side)
  useEffect(() => {
    if (swapToken) return
    const first = STABLES.find(s => BigInt(stableBals[s.address] || '0') > 0n) || STABLES[0]
    setSwapToken(first)
  }, [stableBals, swapToken])

  // Combined ETH + WETH
  const combinedEth = useMemo(
    () => (parseFloat(ethBal) || 0) + (parseFloat(wethBal) || 0),
    [ethBal, wethBal],
  )

  // ═══════════════════════════════════════════════════════════════════
  //   MINT (stable → QUI via Basket.mint after Aux approval)
  // ═══════════════════════════════════════════════════════════════════
  const doMint = useCallback(async () => {
    if (!mintToken || !mintAmount || !connected || txMutex) return
    if (!waiverAccepted) { setShowWaiver(true); return }
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      const amt = ethers.parseUnits(mintAmount, mintToken.decimals)
      await ensureAllowance(mintToken.address, CONTRACTS.aux, amt, address, setStatus)
      setStatus('Minting QUI…')
      const when = currentMonth + 1 + maturityMonths
      const tx = await sendTx({
          from: address, to: CONTRACTS.basket,
          data: enc.mint(address, amt, mintToken.address, when),
        })
      setLastTx(tx); setStatus('Submitted, waiting…')
      await waitTx(tx); setStatus('Minted.')
      setMintAmount(''); void fetchBalances(); void fetchMetrics()
    } catch (e: any) { setError(e.message || 'mint failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [mintToken, mintAmount, connected, txMutex, waiverAccepted, currentMonth, maturityMonths, address, fetchBalances, fetchMetrics])

  // ═══════════════════════════════════════════════════════════════════
  //   ETH LP DEPOSIT (Vogue.deposit + msg.value/WETH split)
  // ═══════════════════════════════════════════════════════════════════
  const doDeposit = useCallback(async () => {
    if (!depositAmount || !connected || txMutex) return
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      const total = ethers.parseEther(depositAmount)
      const rawEth = ethers.parseEther(ethBal || '0')
      const wethW  = ethers.parseEther(wethBal || '0')
      const { msgValue, wethAmount } = splitEthForDeposit(total, rawEth, wethW)

      if (wethAmount > 0n) {
        await ensureAllowance(CONTRACTS.weth, CONTRACTS.vogue, wethAmount, address, setStatus)
      }
      setStatus('Depositing to V4 LP…')
      const tx = await sendTx({
          from: address, to: CONTRACTS.vogue,
          data: enc.vogueDepositV(wethAmount, address, depositVenue),
          ...(msgValue > 0n ? { value: '0x' + msgValue.toString(16) } : {}),
        })
      setLastTx(tx); setStatus('Submitted, waiting…')
      await waitTx(tx); setStatus('Deposited.')
      setDepositAmount(''); void fetchBalances(); void fetchVogue()
    } catch (e: any) { setError(e.message || 'deposit failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [depositAmount, depositVenue, connected, txMutex, ethBal, wethBal, address, fetchBalances, fetchVogue])

  // ═══════════════════════════════════════════════════════════════════
  //   ETH LP WITHDRAW (Vogue.withdraw)
  // ═══════════════════════════════════════════════════════════════════
  const doWithdraw = useCallback(async () => {
    if (!withdrawAmount || !connected || txMutex) return
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      const assets = ethers.parseEther(withdrawAmount)
      setStatus('Withdrawing from V4 LP…')
      const tx = await sendTx({
          from: address, to: CONTRACTS.vogue,
          data: instantExit ? enc.exitInstant(assets, address)
                            : enc.vogueWithdraw(assets, address, address),
        })
      setLastTx(tx); setStatus('Submitted, waiting…')
      await waitTx(tx); setStatus('Withdrawn.')
      setWithdrawAmount(''); void fetchBalances(); void fetchVogue()
    } catch (e: any) { setError(e.message || 'withdraw failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [withdrawAmount, instantExit, connected, txMutex, address, fetchBalances, fetchVogue])

  // ═══════════════════════════════════════════════════════════════════
  //   LEVERAGE OVERLAY (YB IL-protect, #65) — open / adjust / close.
  //   open: approve the venue's collateral (weETH or WETH) to LevManager, then
  //   openLev(targetLtvBps, venue, coll, []) — opens at zero leverage; the keeper
  //   levers up to the cap as the band sells. adjust: setTargetLtv(capBps). close:
  //   closeLev(0) fully unwinds (short leg first, then long) back to the LP.
  // ═══════════════════════════════════════════════════════════════════
  const doOpenLev = useCallback(async (targetLtvBps: number, venue: LevVenue, amount: bigint) => {
    if (!connected || txMutex || amount <= 0n) return
    const collToken = venue.collateral === 'weETH' ? CONTRACTS.weeth : CONTRACTS.weth
    if (collToken === ZERO_ADDR) { setError(`${venue.collateral} address is not configured`); return }
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      await ensureAllowance(collToken, CONTRACTS.levManager, amount, address, setStatus)
      setStatus('Opening leverage position…')
      const tx = await sendTx({
          from: address, to: CONTRACTS.levManager,
          data: enc.openLev(targetLtvBps, venue.address, amount, []),
        })
      setLastTx(tx); setStatus('Submitted, waiting…')
      await waitTx(tx); setStatus('Leverage position opened — the keeper levers up from here.')
      void fetchLevPos(); void fetchBalances()
    } catch (e: any) { setError(e.message || 'open leverage failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [connected, txMutex, address, fetchLevPos, fetchBalances])

  const doAdjustLev = useCallback(async (capBps: number) => {
    if (!connected || txMutex) return
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      setStatus('Adjusting leverage level…')
      const tx = await sendTx({ from: address, to: CONTRACTS.levManager, data: enc.setTargetLtv(capBps) })
      setLastTx(tx); await waitTx(tx); setStatus('Leverage level updated.')
      void fetchLevPos()
    } catch (e: any) { setError(e.message || 'adjust leverage failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [connected, txMutex, address, fetchLevPos])

  const doCloseLev = useCallback(async () => {
    if (!connected || txMutex) return
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      setStatus('Closing leverage position…')
      const tx = await sendTx({ from: address, to: CONTRACTS.levManager, data: enc.closeLev(0n) })
      setLastTx(tx); await waitTx(tx); setStatus('Leverage position closed — equity returned to you.')
      void fetchLevPos(); void fetchBalances()
    } catch (e: any) { setError(e.message || 'close leverage failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [connected, txMutex, address, fetchLevPos, fetchBalances])

  // ── BTC LP withdrawal = channel close. List the user's channels from
  //    ChannelOpened(lpEth=user) logs, then read channels() for live status. ──
  const fetchMyChannels = useCallback(async () => {
    if (!connected || !address || CONTRACTS.btcChannels === ZERO_ADDR) { setMyChannels([]); return }
    try {
      // ChannelOpened gained a 3rd indexed arg (address hop) → new topic0 signature.
      // lpEth is still topics[2] (indexed position unchanged), so the [topic, null,
      // padded] filter-by-owner still works.
      const topic = ethers.id('ChannelOpened(bytes32,address,address,uint256,bytes,bytes,bytes32,uint32,bytes32,uint64)')
      const padded = '0x' + address.toLowerCase().replace(/^0x/, '').padStart(64, '0')
      const logs: any[] = await window.ethereum.request({ method: 'eth_getLogs', params: [{
        address: CONTRACTS.btcChannels, fromBlock: '0x0', toBlock: 'latest', topics: [topic, null, padded],
      }] }) || []
      const ids = Array.from(new Set(logs.map(l => l.topics[1])))
      const rows: typeof myChannels = []
      for (const id of ids) {
        // CURRENT struct order: [0]amountSats [1]fundingTxId [2]lpEth [3]fundingVout
        // [4]status [5]hop — selfRefundTime removed (standard-LDK cut).
        const dec = iface.decodeFunctionResult('channels', await ethCall(CONTRACTS.btcChannels, enc.channels(id)))
        const status = Number(dec[4])
        if (status === 0) continue // 0 = none/closed; skip
        rows.push({ id, sats: BigInt(dec[0]), status })
      }
      setMyChannels(rows)
      // BTC-LP fees/position: autoManagedBTC(user) = (pooled sats, usd_owed, fees_tok=sats, fees_usd).
      // BTC-leg fees accrue as native sats, settled by the hop at channel close.
      try {
        const am = iface.decodeFunctionResult('autoManagedBTC', await ethCall(CONTRACTS.vogue, enc.autoManagedBTC(address)))
        setBtcLp({
          pooledSats: Number(BigInt(am[0])) / 1e8,
          usdOwed:    Number(BigInt(am[1])) / 1e18,
          feesSats:   Number(BigInt(am[2])) / 1e8,
          feesUsd:    Number(BigInt(am[3])) / 1e18,
        })
      } catch { setBtcLp(null) }
    } catch { setMyChannels([]); setBtcLp(null) }
  }, [connected, address])

  useEffect(() => { if (tab === 'withdraw' && withdrawSubTab === 'btc') void fetchMyChannels() },
    [tab, withdrawSubTab, fetchMyChannels])

  const doCloseChannel = useCallback(async () => {
    if (!closeId || !closeRawTx || !connected || txMutex) return
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      const proof: string[] = closeProof.trim() ? JSON.parse(closeProof.trim()) : []
      const txIndex = Number(closeTxIndex || '0')
      setStatus('Recording close…')
      // One entrypoint now: recordClose branches on the tx locktime (cooperative
      // vs unilateral refund) internally. forceCloseByLP was removed.
      const data = enc.recordClose(closeId, closeRawTx.trim(), closeBlockHash.trim(), proof, txIndex)
      const tx = await sendTx({ from: address, to: CONTRACTS.btcChannels, data })
      setLastTx(tx); setStatus('Submitted, waiting…')
      await waitTx(tx); setStatus('Channel closed. BTC settles on-chain to your address.')
      setCloseRawTx(''); setCloseBlockHash(''); setCloseProof(''); setCloseTxIndex('')
      void fetchMyChannels()
    } catch (e: any) { setError(e.message || 'close failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [closeId, closeRawTx, closeBlockHash, closeProof, closeTxIndex, connected, txMutex, address, fetchMyChannels])

  // ═══════════════════════════════════════════════════════════════════
  //   SELF-MANAGED LP — Vogue.outOfRange / pull
  //   Contract validates: range ∈ [100,1000] step 50; distance ∈ [-5000,5000]
  //   step 100, non-zero. UI multiplies % by 100 to get ticks (so range%50 == 0
  //   requires UI step 0.5%; distance multiplies cleanly for any UI int %).
  //   Contract auto-flips distance sign based on pool token ordering, so UI
  //   distance is unambiguous: + = above current price, − = below.
  // ═══════════════════════════════════════════════════════════════════
  const doOpenOutOfRange = useCallback(async () => {
    if (!oorAmount || !connected || txMutex) return
    if (oorSide === 'usd' && !oorStable) { setError('Pick a stable'); return }
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      const distanceTicks = Math.round(oorDistance * 100)
      const rangeTicks    = Math.round(oorRange * 100 / 50) * 50  // snap to 50
      let msgValue = 0n
      let amount:  bigint
      let tokenAddr: string

      if (oorSide === 'eth') {
        tokenAddr = ZERO_ADDR
        const total = ethers.parseEther(oorAmount)
        const rawEth = ethers.parseEther(ethBal || '0')
        const wethW  = ethers.parseEther(wethBal || '0')
        const split = splitEthForDeposit(total, rawEth, wethW)
        msgValue = split.msgValue
        amount   = split.wethAmount
        if (amount > 0n) {
          await ensureAllowance(CONTRACTS.weth, CONTRACTS.vogue, amount, address, setStatus)
        }
      } else {
        tokenAddr = oorStable!.address
        amount    = ethers.parseUnits(oorAmount, oorStable!.decimals)
        // USD-side: Aux.deposit is the entry that pulls the stable.
        await ensureAllowance(oorStable!.address, CONTRACTS.aux, amount, address, setStatus)
      }

      setStatus('Opening self-managed position…')
      const tx = await sendTx({
          from: address, to: CONTRACTS.vogue,
          data: enc.outOfRange(amount, tokenAddr, distanceTicks, rangeTicks, depositVenue),
          ...(msgValue > 0n ? { value: '0x' + msgValue.toString(16) } : {}),
        })
      setLastTx(tx); await waitTx(tx); setStatus('Position opened.')
      setOorAmount(''); void fetchBalances(); void fetchSmPositions(); void fetchVogue()
    } catch (e: any) { setError(e.message || 'open failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [oorAmount, oorSide, oorStable, oorDistance, oorRange, depositVenue, connected, txMutex, ethBal, wethBal, address, fetchBalances, fetchVogue, fetchSmPositions])

  const doPullPosition = useCallback(async (id: bigint) => {
    if (!connected || txMutex) return
    const idStr = String(id)
    const percent = pullPercents[idStr] ?? 100
    const tokenAddr = pullTokens[idStr] ?? ZERO_ADDR
    if (percent < 1 || percent > 100) { setError('Pull % must be 1..100'); return }
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      setStatus(`Pulling ${percent}% of #${idStr}…`)
      const tx = await sendTx({
          from: address, to: CONTRACTS.vogue,
          data: enc.pull(id, percent, tokenAddr),
        })
      setLastTx(tx); await waitTx(tx); setStatus('Pulled.')
      void fetchBalances(); void fetchSmPositions(); void fetchVogue()
    } catch (e: any) {
      // The 47-block timelock comes back as a revert "too soon" — surface plainly.
      const msg = e.message?.includes('too soon')
        ? 'Position is too fresh — 47-block timelock (≈9.4 min after open) still active.'
        : (e.message || 'pull failed')
      setError(msg)
    }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [connected, txMutex, pullPercents, pullTokens, address, fetchBalances, fetchSmPositions, fetchVogue])

  // ═══════════════════════════════════════════════════════════════════
  //   SWAP — Aux.swap(token, asset, forVolatile, amount, minOut)
  //   USD→ETH:  token=stable, asset=WETH,  forVolatile=true,  approve stable to Aux
  //                                                          minOut in 18-dec WETH units
  //   ETH→USD:  token=stable, asset=WETH,  forVolatile=false, msg.value + WETH max-pull
  //                                                          minOut in stable's native decimals
  //   USD→BTC:  token=stable, asset=WBTC,  forVolatile=true,  approve stable to Aux,
  //                                                          minOut in 8-dec WBTC units,
  //                                                          requires btcRecipientOf(user) != 0
  //                                                          (hop broadcasts native BTC to recipient)
  //   (BTC→USD blocked on-chain by BtcInflowsViaChannels — BTC inflows
  //    only happen via channel state changes.)
  // ═══════════════════════════════════════════════════════════════════
  const doSwap = useCallback(async () => {
    if (!swapAmount || !connected || txMutex) return
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      // minOut is in the OUTPUT token's native decimals — parse accordingly.
      const outDecimals =
        swapDirection === 'usdToEth' ? 18 :              // WETH out
        swapDirection === 'usdToBtc' ? WBTC_DECIMALS :   // WBTC pricing leg (8)
        (swapToken?.decimals ?? 18)                       // stable out
      const minOut = ethers.parseUnits(swapMinOut || '0', swapDirection === 'usdToUsd' ? (swapTokenOut?.decimals ?? 18) : outDecimals)

      if (swapDirection === 'usdToUsd') {       // stable → stable (Aux.auxSwap)
        if (!swapToken || !swapTokenOut) throw new Error('Pick both stables')
        if (swapToken.address === swapTokenOut.address) throw new Error('Pick two different stables')
        const amt = ethers.parseUnits(swapAmount, swapToken.decimals)
        await ensureAllowance(swapToken.address, CONTRACTS.aux, amt, address, setStatus)
        setStatus(`${swapToken.symbol} → ${swapTokenOut.symbol}…`)
        const tx = await sendTx({ from: address, to: CONTRACTS.aux,
            data: enc.auxSwap(swapToken.address, swapTokenOut.address, amt, address, minOut) })
        setLastTx(tx); await waitTx(tx); setStatus('Swapped.')

      } else if (swapDirection === 'usdToEth') {
        if (!swapToken) throw new Error('Pick a stable')
        const amt = ethers.parseUnits(swapAmount, swapToken.decimals)
        await ensureAllowance(swapToken.address, CONTRACTS.aux, amt, address, setStatus)
        setStatus('USD → ETH…')
        const tx = await sendTx({
            from: address, to: CONTRACTS.aux,
            data: enc.swap(swapToken.address, CONTRACTS.weth, true, amt, minOut),
          })
        setLastTx(tx); await waitTx(tx); setStatus('Swapped.')

      } else if (swapDirection === 'ethToUsd') {
        if (!swapToken) throw new Error('Pick a stable for the output')
        const total = ethers.parseEther(swapAmount)
        const rawEth = ethers.parseEther(ethBal || '0')
        const wethW  = ethers.parseEther(wethBal || '0')
        const { msgValue, wethAmount } = splitEthForDeposit(total, rawEth, wethW)
        if (wethAmount > 0n) {
          await ensureAllowance(CONTRACTS.weth, CONTRACTS.aux, wethAmount, address, setStatus)
        }
        setStatus('ETH → USD…')
        const tx = await sendTx({
            from: address, to: CONTRACTS.aux,
            data: enc.swap(swapToken.address, CONTRACTS.weth, false, wethAmount, minOut),
            ...(msgValue > 0n ? { value: '0x' + msgValue.toString(16) } : {}),
          })
        setLastTx(tx); await waitTx(tx); setStatus('Swapped.')

      } else { // usdToBtc — on-chain swap-out (rail B): deliver native BTC to the user's address
        if (!swapToken) throw new Error('Pick a stable')
        const script = addressToScriptPubKey(swapBtcAddr)
        if (!script) throw new Error('Enter a valid Bitcoin address')
        const usdAmount = ethers.parseUnits(swapAmount, swapToken.decimals)
        const swapId = randomSwapId()
        // The swapper approves Aux for the USD pull (same as any swap); minOut here
        // is parsed at 8 dec = the minSats floor.
        await ensureAllowance(swapToken.address, CONTRACTS.aux, usdAmount, address, setStatus)
        setStatus('USD → BTC (on-chain delivery to your address)…')
        const tx = await sendTx({
            from: address, to: CONTRACTS.btcChannels,
            data: enc.requestSwapOutOnchain(swapToken.address, usdAmount, minOut, swapId, script),
          })
        setLastTx(tx); await waitTx(tx)
        setStatus('Swap-out recorded — the hop delivers BTC on-chain to your address (≈1 block).')
      }

      setSwapAmount(''); void fetchBalances(); void fetchMetrics()
    } catch (e: any) { setError(e.message || 'swap failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [swapAmount, swapDirection, swapToken, swapTokenOut, swapMinOut, swapBtcAddr, connected, txMutex, address, ethBal, wethBal, fetchBalances, fetchMetrics])

  // ether.fi exit preference is now PER-TX (see the `instantExit` state) — no stored-setting
  // tx; the checkbox just flips `instantExit`, which doWithdraw reads to pick exitInstant.

  // ── BTC→USD swap-IN (on-chain, invoice-free): ask the hop for a deposit address +
  //    exact amount; the user sends BTC from any wallet; the hop SPV-settles it. ──
  const doRequestSwapIn = useCallback(async () => {
    if (!connected || !swapToken || !swapAmount) return
    setSwapInBusy(true); setError(null); setSwapInQuote(null); setSwapInStatus(null)
    try {
      const sats = Math.floor(parseFloat(swapAmount) * 1e8)   // user enters BTC
      if (!isFinite(sats) || sats <= 0) throw new Error('Enter a BTC amount')
      const q = await requestOnchainSwapIn(address, swapToken.address, sats)
      if (!q) throw new Error(hopApiConfigured() ? 'Hop could not quote (amount too small?)' : 'Swap-in is coming online — the hop endpoint isn’t configured yet.')
      setSwapInQuote(q); setSwapInStatus('awaiting_deposit')
    } catch (e: any) { setError(e.message || 'swap-in request failed') }
    finally { setSwapInBusy(false) }
  }, [connected, swapToken, swapAmount, address])

  // Poll the hop for the swap-in's progress until settled/expired.
  useEffect(() => {
    if (!swapInQuote || swapInStatus === 'settled' || swapInStatus === 'expired' || swapInStatus === 'failed') return
    const id = setInterval(async () => {
      const st = await pollSwapIn(swapInQuote.swapId)
      if (st) setSwapInStatus(st)
      if (st === 'settled') { void fetchBalances(); void fetchMetrics() }
    }, 15000)
    return () => clearInterval(id)
  }, [swapInQuote, swapInStatus, fetchBalances, fetchMetrics])

  // ═══════════════════════════════════════════════════════════════════
  //   REDEEM (Aux.redeem)
  // ═══════════════════════════════════════════════════════════════════
  const doRedeem = useCallback(async () => {
    if (!redeemAmount || !connected || txMutex) return
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      const amt = ethers.parseUnits(redeemAmount, 18)
      setStatus('Redeeming…')
      const tx = await sendTx({ from: address, to: CONTRACTS.aux, data: enc.redeem(amt) })
      setLastTx(tx); await waitTx(tx); setStatus('Redeemed.')
      setRedeemAmount(''); void fetchBalances(); void fetchMetrics()
    } catch (e: any) { setError(e.message || 'redeem failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [redeemAmount, connected, txMutex, address, fetchBalances, fetchMetrics])

  // ═══════════════════════════════════════════════════════════════════
  //   SET BTC RECIPIENT (manual entry; channel-open also sets this automatically)
  // ═══════════════════════════════════════════════════════════════════
  const doSetBtcRecipient = useCallback(async () => {
    if (!btcRecipientHash || !connected || txMutex) return
    if (!/^0x[0-9a-fA-F]{40,64}$/.test(btcRecipientHash)) {
      setError('Recipient must be a hex hash (RIPEMD160 of SHA256(pubkey), 20-byte or padded to 32).')
      return
    }
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null)
    try {
      // Pad to bytes32 if 20-byte hex provided
      let h = btcRecipientHash.toLowerCase()
      if (h.length === 42) h = '0x' + h.slice(2).padStart(64, '0')
      setStatus('Setting BTC recipient…')
      const tx = await sendTx({
          from: address, to: CONTRACTS.btcChannels,
          data: iface.encodeFunctionData('setBtcRecipient', [h]),
        })
      setLastTx(tx); await waitTx(tx); setStatus('Set.')
      setBtcRecipientHash('')
    } catch (e: any) { setError(e.message || 'set recipient failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 6000) }
  }, [btcRecipientHash, connected, txMutex, address])

  // ─── openChannel (EVM half) ──────────────────────────────────────
  // The Bitcoin half (BIP-380 funding tx + SPV proof + lpAuth signature) is
  // produced off-chain by the LP's node/wallet tooling and pasted in here.
  // lpAuth is the LP node's signature over the RAW openChannelDigest (no
  // EIP-191 prefix) — the contract recovers the channel owner from it, so any
  // relayer (incl. this wallet) can submit. No QU!D is minted on open.
  const buildOpenParams = useCallback(() => {
    const o = JSON.parse(ocParams)
    // CURRENT OpenParams (taproot channels folded into the default build): 7 fields.
    // hopPubkey is the hop's per-channel LDK funding pubkey (node-supplied at open);
    // fundingTaproot is the 32-byte x-only MuSig2 key-path aggregate Q. Both come from
    // the LP node's funding tooling. `o.hop` (the hop EVM submitter address) is bound
    // into the digest, NOT into this struct — the node supplies it alongside the params.
    return {
      fundingBlockHash:   o.fundingBlockHash,
      fundingBlockHeight: o.fundingBlockHeight,
      fundingTxIndex:     o.fundingTxIndex,
      lpPubkey:           o.lpPubkey,
      hopPubkey:          o.hopPubkey,
      amountSats:         o.amountSats,
      fundingTaproot:     o.fundingTaproot ?? ethers.ZeroHash,
    }
  }, [ocParams])

  const computeChannelDigest = useCallback(async (): Promise<{ digest: string; lp: string }> => {
    const p = buildOpenParams()
    // openChannelDigest now binds the hop (EVM submitter) address the LP signed against
    // — the node supplies it in the pasted params as `o.hop`. Without the matching hop
    // the recovered owner won't equal the intended lpEth (that's the anti-replay point).
    const hop = (JSON.parse(ocParams).hop as string) ?? ethers.ZeroAddress
    const res = await ethCall(CONTRACTS.btcChannels, enc.openChannelDigest(p, ocRawTx.trim(), hop))
    const [digest] = iface.decodeFunctionResult('openChannelDigest', res)
    const lp = ethers.recoverAddress(digest, ocLpAuth.trim())
    return { digest, lp }
  }, [buildOpenParams, ocParams, ocRawTx, ocLpAuth])

  const doVerifyChannel = useCallback(async () => {
    setError(null)
    try {
      const { digest, lp } = await computeChannelDigest()
      setOcDigest(digest); setOcRecovered(lp)
      setStatus(`lpAuth → channel owner ${lp}`); setTimeout(() => setStatus(null), 8000)
    } catch (e: any) { setError(e.message || 'verify failed') }
  }, [computeChannelDigest])

  // openChannel is HOP-ONLY submit on-chain (§9b): a user wallet can't land it.
  // So the SPA hands the artifacts to the hop, which relays the tx. We still
  // verify locally first (eth_call) that lpAuth recovers to a real owner — the
  // recovered address (NOT the submitter) becomes the channel owner, so the
  // relayer's identity is irrelevant and no funds route through it.
  const doOpenChannel = useCallback(async () => {
    if (!ocParams || !ocRawTx || !ocLpAuth || !connected || txMutex) return
    setTxMutex(true); setBusy(true); setError(null); setLastTx(null); setOcRelay(null)
    try {
      const p = buildOpenParams()
      const proof: string[] = ocProof.trim() ? JSON.parse(ocProof) : []
      const { digest, lp } = await computeChannelDigest()
      if (lp === ethers.ZeroAddress) throw new Error('lpAuth recovers to zero address')
      setOcDigest(digest); setOcRecovered(lp)
      if (!hopApiConfigured()) throw new Error('LP onboarding is coming online — the hop endpoint isn’t configured yet.')
      setStatus(`Handing channel-open to the hop — owner ${lp}…`)
      const res = await submitOpenChannel({
        params: p, rawTx: ocRawTx.trim(), proof,
        lpAuth: ocLpAuth.trim(), lpBtcPayout: ocLpBtcPayout.trim() || ethers.ZeroHash,
      })
      if (!res) throw new Error('Hop unreachable — try again shortly.')
      setOcRelay(res)
      if (res.status === 'rejected') throw new Error(`Hop rejected the open${res.reason ? `: ${res.reason}` : ''}`)
      if (res.txHash) setLastTx(res.txHash)
      // Poll the hop until the channel confirms on-chain (or it reports failure).
      const channelId = res.channelId
      if (channelId) {
        for (let i = 0; i < 60 && (ocRelay?.status !== 'opened'); i++) {
          const pr = await pollOpenChannel(channelId)
          if (pr) { setOcRelay(pr); if (pr.txHash) setLastTx(pr.txHash) }
          if (pr?.status === 'opened') { setStatus('Channel opened.'); break }
          if (pr?.status === 'rejected') throw new Error(`Open failed${pr.reason ? `: ${pr.reason}` : ''}`)
          await new Promise(r => setTimeout(r, 4000))
        }
      } else {
        setStatus('Channel-open submitted to the hop.')
      }
    } catch (e: any) { setError(e.message || 'openChannel failed') }
    finally { setBusy(false); setTxMutex(false); setTimeout(() => setStatus(null), 8000) }
  }, [ocParams, ocRawTx, ocProof, ocLpAuth, ocLpBtcPayout, connected, txMutex, buildOpenParams, computeChannelDigest, ocRelay?.status])

  // ═══════════════════════════════════════════════════════════════════
  //   RENDER
  // ═══════════════════════════════════════════════════════════════════
  const numQd = Number(BigInt(qdBal)) / 1e18
  const numMatureQd = Number(BigInt(matureQd)) / 1e18
  const numRedeemable = Number(BigInt(redeemable)) / 1e18

  return (
    <main className="min-h-screen p-4 sm:p-6 max-w-4xl mx-auto">
      {/* Header */}
      <header className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-3">
          <h1 className="text-2xl font-bold tracking-tight">QU!D</h1>
          <button onClick={() => setShowAbout(true)} className="text-xs px-2 py-1 rounded bg-white/5 hover:bg-white/10">
            About
          </button>
        </div>
        <div className="text-sm">
          {connected ? (
            <span className="flex items-center gap-2">
              <span className="font-mono">{short(address)}</span>
              {chainOk
                ? <span className="px-2 py-1 rounded bg-emerald-900/40 border border-emerald-700/50 text-xs">{CHAIN_NAME}</span>
                : <button onClick={switchChain} className="px-2 py-1 rounded bg-red-900/40 border border-red-700/50 text-xs">
                    Switch to {CHAIN_NAME}
                  </button>}
              {protect
                ? <span title={`Transactions are sent privately via ${PROTECT.name} — they skip the public mempool, so they can't be frontrun or sandwiched.`}
                    className="px-2 py-1 rounded bg-emerald-900/40 border border-emerald-700/50 text-xs">🛡 Protected</span>
                : <button onClick={async () => setProtect(await enableProtection(true))}
                    title="Route transactions through a private relay to prevent frontrunning."
                    className="px-2 py-1 rounded bg-amber-900/30 border border-amber-700/40 text-xs hover:bg-amber-900/50">Enable protection</button>}
            </span>
          ) : (
            <button onClick={connect} disabled={busy}
              className="px-4 py-2 rounded-lg bg-gradient-to-r from-cyan-600 to-blue-600 hover:opacity-90 disabled:opacity-40">
              {busy ? '…' : 'Connect wallet'}
            </button>
          )}
        </div>
      </header>

      {/* Toasts */}
      {error && (
        <div className="mb-4 p-3 rounded-lg bg-red-900/40 border border-red-700 text-sm flex justify-between">
          <span>{error}</span>
          <button onClick={() => setError(null)} className="opacity-70 hover:opacity-100">✕</button>
        </div>
      )}
      {status && (
        <div className="mb-4 p-3 rounded-lg bg-blue-900/40 border border-blue-700 text-sm">
          {status} {lastTx && <a className="underline ml-1" href={`${EXPLORER}/tx/${lastTx}`} target="_blank">view ↗</a>}
        </div>
      )}

      {/* Wallet snapshot. Note: no BTC stat — user's BTC stake lives in QUID
          (minted at channel open), not as an on-chain ERC20. */}
      <div className="grid grid-cols-2 sm:grid-cols-5 gap-2 mb-4 text-sm">
        <Stat label="ETH"    value={fmt(parseFloat(ethBal))} />
        <Stat label="WETH"   value={fmt(parseFloat(wethBal))} />
        <Stat label="QUI"     value={fmt(numQd)} />
        <Stat label="Mature" value={fmt(numMatureQd)} />
        <Stat label="Month"  value={String(currentMonth)} />
      </div>

      {/* Protocol metrics */}
      <div className="mb-6 p-4 rounded-xl bg-black/20 border border-white/5">
        <div className="flex items-center justify-between mb-3">
          <h2 className="text-sm font-semibold opacity-80">Protocol</h2>
          <button onClick={() => setShowBreakdown(!showBreakdown)} className="text-xs opacity-60 hover:opacity-100">
            {showBreakdown ? '− hide breakdown' : '+ stable breakdown'}
          </button>
        </div>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 text-sm">
          <Stat label="Basket TVL" value={fmtUSD(basketTotal, 0)} />
          <Stat label="Yield earned" value={fmtUSD(basketYield, 0)} />
          <Stat label="Avg yield" value={`${fmt(avgYield, 2)}%`} />
          <Stat label="QUI supply" value={fmt(Number(BigInt(qdTotalSupply)) / 1e18, 0)} />
          <Stat label="ETH TWAP" value={fmtUSD(ethTwap, 2)} />
          <Stat label="BTC TWAP" value={fmtUSD(btcTwap, 0)} />
          <Stat label="Vogue shares" value={fmt(vogueShares, 0)} />
          <Stat label="Your LP" value={autoMan ? `${fmt(autoMan.pooled, 3)} ETH` : '—'} />
        </div>
        {showBreakdown && perStable.length > 0 && (
          <div className="mt-3 grid grid-cols-3 sm:grid-cols-6 gap-1 text-xs">
            {STABLES.map((s, i) => (
              <div key={s.address} className="p-2 rounded bg-white/5">
                <div className="opacity-60">{s.symbol}</div>
                <div className="font-mono">{fmt(perStable[i] || 0, 0)}</div>
              </div>
            ))}
            {/* 12 stables occupy 0..11; indices 12..14 are get_deposits' aggregate slots */}
          </div>
        )}
      </div>

      {/* Tabs */}
      <nav className="flex gap-1 p-1 rounded-lg bg-white/5 mb-6 text-sm">
        {(['info','mint','deposit','withdraw','swap','redeem','channel'] as Tab[]).map(t => (
          <button key={t}
            className={`flex-1 px-3 py-2 rounded-md capitalize transition-colors ${
              tab===t ? 'bg-white/15' : 'hover:bg-white/10'
            }`}
            onClick={() => setTab(t)}>
            {t==='channel' ? 'BTC Channel' : t==='info' ? 'Dashboard' : t}
          </button>
        ))}
      </nav>

      {/* ── LP action surface (comfort mix + P&L) — on the rotation tabs ── */}
      {connected && (tab === 'deposit' || tab === 'withdraw') && (
        <div className="space-y-4 mb-6">
          <ComfortPanel
            safeUsd={Number(qdBal) / 1e18}
            ethUsd={(autoMan?.pooled ?? 0) * ethTwap}
            btcUsd={(btcLp?.pooledSats ?? 0) * btcTwap}
            connected={connected} />
          {/* Leverage overlay: live-position display + the WRITE surface (#65). */}
          <LeverageCard address={address} ethPxUsd={ethTwap} />
          <LeverageActionPanel
            connected={connected} address={address}
            pos={levPos} capBps={levCap} ethPxUsd={ethTwap} busy={busy}
            onOpen={doOpenLev} onAdjust={doAdjustLev} onClose={doCloseLev} />
          <PnLPanel address={address} />
        </div>
      )}

      {/* ── Dashboard (read-only protocol surface + regime) ──────────── */}
      {tab === 'info' && <InfoTab address={address} />}

      {/* ── Mint ─────────────────────────────────────────────────────── */}
      {tab === 'mint' && (
        <Section title="Mint QU!D">
          <p className="text-xs opacity-70 mb-3">
            Deposit a stable into the basket → receive QUI with a chosen maturity month.
            Pre-maturity QUI is non-redeemable but transferable.
          </p>

          <label className="block text-sm mb-1">Stable</label>
          <select
            value={mintToken?.address || ''}
            onChange={e => setMintToken(STABLES.find(s => s.address === e.target.value) || null)}
            className="w-full mb-3 p-2 rounded bg-black/30 border border-white/10">
            <option value="">— pick —</option>
            {STABLES.map(s => (
              <option key={s.address} value={s.address}>
                {s.symbol} · bal {fmt(Number(BigInt(stableBals[s.address] || '0')) / 10**s.decimals, 4)}
              </option>
            ))}
          </select>

          <label className="block text-sm mb-1">Amount</label>
          <div className="flex gap-2 mb-3">
            <input value={mintAmount} onChange={e => setMintAmount(e.target.value)}
              className="flex-1 p-2 rounded bg-black/30 border border-white/10" placeholder="0.00" />
            {mintToken && (
              <button onClick={() =>
                setMintAmount(ethers.formatUnits(BigInt(stableBals[mintToken.address] || '0'), mintToken.decimals))}
                className="px-3 rounded bg-white/10 hover:bg-white/20 text-xs">MAX</button>
            )}
          </div>

          <label className="block text-sm mb-1">Maturity: {maturityMonths} month{maturityMonths !== 1 ? 's' : ''}</label>
          <input type="range" min={1} max={36} value={maturityMonths}
            onChange={e => setMaturityMonths(Number(e.target.value))}
            className="w-full mb-1" />
          <div className="text-[10px] opacity-60 mb-4">
            Target month: {currentMonth + 1 + maturityMonths} (current month is {currentMonth})
          </div>

          <button onClick={doMint} disabled={busy || !mintToken || !mintAmount}
            className="w-full py-3 rounded-lg bg-gradient-to-r from-cyan-600 to-blue-600 hover:opacity-90 disabled:opacity-40 font-semibold">
            {busy ? 'Working…' : 'Mint QUI'}
          </button>
        </Section>
      )}

      {/* ── Deposit (ETH LP) ─────────────────────────────────────────── */}
      {tab === 'deposit' && (
        <Section title="Deposit to ETH LP (Vogue V4)">
          <div className="flex gap-1 p-1 rounded-lg bg-white/5 mb-4 text-xs">
            <button
              className={`flex-1 px-3 py-2 rounded-md ${depositSubTab==='auto' ? 'bg-white/15' : 'hover:bg-white/10'}`}
              onClick={() => setDepositSubTab('auto')}>
              Auto-managed (ERC4626)
            </button>
            <button
              className={`flex-1 px-3 py-2 rounded-md ${depositSubTab==='self' ? 'bg-white/15' : 'hover:bg-white/10'}`}
              onClick={() => setDepositSubTab('self')}>
              Self-managed (custom range)
            </button>
          </div>

          {depositSubTab === 'auto' ? (
            <>
              <p className="text-xs opacity-70 mb-3">
                Single-sided ETH placed out-of-range on the V4 vanilla ETH/USD pool —
                one shared vault, pro-rata fees + Galaxy/Morpho yield. ERC4626 shares.
                Combined ETH + WETH balance: <strong>{fmt(combinedEth)}</strong>.
              </p>

              {autoMan && (
                <div className="grid grid-cols-4 gap-2 mb-3 text-xs">
                  <Stat label="Your pooled" value={`${fmt(autoMan.pooled, 4)} ETH`} />
                  <Stat label="Fees (ETH)"  value={fmt(autoMan.feesEth, 6)} />
                  <Stat label="Fees (USD)"  value={fmtUSD(autoMan.feesUsd, 2)} />
                  <Stat label="USD owed"    value={fmtUSD(autoMan.usdOwed, 2)} />
                </div>
              )}

              <label className="block text-sm mb-1">Yield venue</label>
              <select value={depositVenue} onChange={e => setDepositVenue(Number(e.target.value))}
                className="w-full mb-1 p-2 rounded bg-black/30 border border-white/10 text-sm">
                {ETH_VENUES.map(v => <option key={v.id} value={v.id}>{v.label}</option>)}
              </select>
              <p className="text-[11px] opacity-50 mb-2">
                {ETH_VENUES[depositVenue]?.blurb} Your exit is served from this venue only.
              </p>
              {(depositVenue === 0 || depositVenue === 4) && (
                <label className="flex items-center gap-2 text-[11px] opacity-70 mb-4">
                  <input type="checkbox" disabled={busy} checked={instantExit}
                         onChange={e => setInstantExit(e.target.checked)} />
                  ether.fi exit: on your NEXT withdrawal, instant redeem (~0.3% fee) instead of the free withdrawal-NFT queue
                </label>
              )}

              <label className="block text-sm mb-1">Amount (ETH)</label>
              <div className="flex gap-2 mb-4">
                <input value={depositAmount} onChange={e => setDepositAmount(e.target.value)}
                  className="flex-1 p-2 rounded bg-black/30 border border-white/10" placeholder="0.00" />
                <button onClick={() => setDepositAmount(String(combinedEth))}
                  className="px-3 rounded bg-white/10 hover:bg-white/20 text-xs">MAX</button>
              </div>

              <button onClick={doDeposit} disabled={busy || !depositAmount}
                className="w-full py-3 rounded-lg bg-gradient-to-r from-purple-600 to-pink-600 hover:opacity-90 disabled:opacity-40 font-semibold">
                {busy ? 'Working…' : 'Deposit'}
              </button>
            </>
          ) : (
            <>
              <p className="text-xs opacity-70 mb-3">
                Open your own out-of-range V4 position at a chosen tick range.
                Non-fungible — per-position fees depend on whether the price
                crosses your range. 47-block timelock before you can pull (≈9.4 min).
              </p>

              <div className="flex gap-1 p-1 rounded-lg bg-white/5 mb-3 text-xs">
                <button
                  className={`flex-1 px-3 py-2 rounded-md ${oorSide==='eth' ? 'bg-white/15' : 'hover:bg-white/10'}`}
                  onClick={() => setOorSide('eth')}>ETH side</button>
                <button
                  className={`flex-1 px-3 py-2 rounded-md ${oorSide==='usd' ? 'bg-white/15' : 'hover:bg-white/10'}`}
                  onClick={() => setOorSide('usd')}>USD side</button>
              </div>

              {oorSide === 'usd' && (
                <>
                  <label className="block text-sm mb-1">Stable</label>
                  <select
                    value={oorStable?.address || ''}
                    onChange={e => setOorStable(STABLES.find(s => s.address === e.target.value) || null)}
                    className="w-full mb-3 p-2 rounded bg-black/30 border border-white/10">
                    <option value="">— pick —</option>
                    {STABLES.map(s => (
                      <option key={s.address} value={s.address}>
                        {s.symbol} · bal {fmt(Number(BigInt(stableBals[s.address] || '0')) / 10**s.decimals, 4)}
                      </option>
                    ))}
                  </select>
                </>
              )}

              <label className="block text-sm mb-1">
                Amount ({oorSide === 'eth' ? 'ETH' : oorStable?.symbol || 'stable'})
              </label>
              <input value={oorAmount} onChange={e => setOorAmount(e.target.value)}
                className="w-full mb-3 p-2 rounded bg-black/30 border border-white/10" placeholder="0.00" />

              <label className="block text-sm mb-1">
                Distance from current tick: {oorDistance > 0 ? '+' : ''}{oorDistance}% ({oorDistance * 100} ticks)
              </label>
              <input type="range" min={-50} max={50} step={1} value={oorDistance}
                onChange={e => setOorDistance(Number(e.target.value))}
                className="w-full mb-1" />
              <div className="text-[10px] opacity-60 mb-3">
                + above current price, − below. Contract auto-flips for token ordering.
              </div>

              <label className="block text-sm mb-1">
                Range width: {oorRange}% ({Math.round(oorRange * 100 / 50) * 50} ticks)
              </label>
              <input type="range" min={1} max={10} step={0.5} value={oorRange}
                onChange={e => setOorRange(Number(e.target.value))}
                className="w-full mb-4" />

              <button onClick={doOpenOutOfRange} disabled={busy || !oorAmount || (oorSide === 'usd' && !oorStable)}
                className="w-full py-3 rounded-lg bg-gradient-to-r from-purple-600 to-pink-600 hover:opacity-90 disabled:opacity-40 font-semibold">
                {busy ? 'Working…' : 'Open self-managed position'}
              </button>
            </>
          )}
        </Section>
      )}

      {/* ── Withdraw (ETH LP + BTC channel close, one screen) ────────── */}
      {tab === 'withdraw' && (
        <Section title="Withdraw">
          <div className="flex gap-1 p-1 rounded-lg bg-white/5 mb-4 text-xs">
            <button
              className={`flex-1 px-3 py-2 rounded-md ${withdrawSubTab==='auto' ? 'bg-white/15' : 'hover:bg-white/10'}`}
              onClick={() => setWithdrawSubTab('auto')}>
              ETH · Auto
            </button>
            <button
              className={`flex-1 px-3 py-2 rounded-md ${withdrawSubTab==='self' ? 'bg-white/15' : 'hover:bg-white/10'}`}
              onClick={() => setWithdrawSubTab('self')}>
              ETH · Self ({smPositions.length})
            </button>
            <button
              className={`flex-1 px-3 py-2 rounded-md ${withdrawSubTab==='btc' ? 'bg-white/15' : 'hover:bg-white/10'}`}
              onClick={() => setWithdrawSubTab('btc')}>
              BTC ({myChannels.length})
            </button>
          </div>

          {withdrawSubTab === 'btc' ? (
            <>
              <p className="text-xs opacity-70 mb-3">
                BTC LP withdrawal = closing your Lightning channel. The cooperative close tx
                (co-signed with the hop) + its SPV proof come from your LP node; paste them to
                record the close on-chain. Your sats settle to your Bitcoin address; BTC-leg fees
                are paid by the hop at close. Use force-close only after your self-refund time.
              </p>

              {btcLp && (btcLp.pooledSats > 0 || btcLp.feesSats > 0 || btcLp.feesUsd > 0) && (
                <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 mb-3 text-xs">
                  <Stat label="Your BTC LP" value={`${fmt(btcLp.pooledSats, 8)} ₿`} />
                  <Stat label="BTC fees (sats)" value={`${fmt(btcLp.feesSats, 8)} ₿`} />
                  <Stat label="USD-leg fees" value={fmtUSD(btcLp.feesUsd, 2)} />
                  <Stat label="USD owed" value={fmtUSD(btcLp.usdOwed, 2)} />
                </div>
              )}

              {myChannels.length === 0 ? (
                <p className="text-xs opacity-40 mb-3">No open channels for this address.</p>
              ) : (
                <div className="space-y-1 mb-3">
                  {myChannels.map(c => (
                    <button key={c.id} onClick={() => setCloseId(c.id)}
                      className={`w-full text-left p-2 rounded text-xs ${closeId===c.id ? 'bg-white/15' : 'bg-white/5 hover:bg-white/10'}`}>
                      <div className="font-mono">{short(c.id)}</div>
                      <div className="opacity-60">{fmt(Number(c.sats) / 1e8, 6)} ₿ · status {c.status}</div>
                    </button>
                  ))}
                </div>
              )}

              <label className="block text-sm mb-1">Channel id (bytes32)</label>
              <input value={closeId} onChange={e => setCloseId(e.target.value)}
                className="w-full mb-2 p-2 rounded bg-black/30 border border-white/10 text-xs font-mono" placeholder="0x…" />
              <label className="block text-sm mb-1">Raw close tx (hex)</label>
              <textarea value={closeRawTx} onChange={e => setCloseRawTx(e.target.value)}
                className="w-full mb-2 p-2 rounded bg-black/30 border border-white/10 text-xs font-mono h-16" placeholder="0x…" />
              <div className="grid grid-cols-2 gap-2 mb-2">
                <input value={closeBlockHash} onChange={e => setCloseBlockHash(e.target.value)}
                  className="p-2 rounded bg-black/30 border border-white/10 text-xs font-mono" placeholder="close block hash 0x…" />
                <input value={closeTxIndex} onChange={e => setCloseTxIndex(e.target.value)}
                  className="p-2 rounded bg-black/30 border border-white/10 text-xs" placeholder="tx index" />
              </div>
              <textarea value={closeProof} onChange={e => setCloseProof(e.target.value)}
                className="w-full mb-2 p-2 rounded bg-black/30 border border-white/10 text-xs font-mono h-12" placeholder='merkle proof ["0x…","0x…"]' />
              <p className="text-[11px] opacity-40 mb-3">
                One entrypoint: the contract reads the tx locktime to tell a cooperative close
                from a unilateral refund — no separate force-close needed.
              </p>

              <button onClick={doCloseChannel} disabled={busy || !closeId || !closeRawTx}
                className="w-full py-3 rounded-lg bg-gradient-to-r from-orange-500 to-amber-500 hover:opacity-90 disabled:opacity-40 font-semibold">
                {busy ? 'Working…' : 'Record close'}
              </button>
            </>
          ) : withdrawSubTab === 'auto' ? (
            <>
              <p className="text-xs opacity-70 mb-3">
                Pull ETH back from the V4 LP position. ERC4626-shaped:{' '}
                <code className="opacity-60">withdraw(assets, receiver, owner)</code>{' '}
                — owner must equal msg.sender (no allowance flow).
              </p>

              {autoMan && (
                <div className="mb-3 text-xs">
                  Your pooled ETH: <strong>{fmt(autoMan.pooled, 6)}</strong>
                  {autoMan.usdOwed > 0 && (
                    <span className="ml-3 opacity-70">
                      · USD owed (BTC-side swap-outs against ETH side):{' '}
                      <strong>{fmtUSD(autoMan.usdOwed)}</strong>
                    </span>
                  )}
                </div>
              )}

              <label className="block text-sm mb-1">Amount (ETH)</label>
              <div className="flex gap-2 mb-4">
                <input value={withdrawAmount} onChange={e => setWithdrawAmount(e.target.value)}
                  className="flex-1 p-2 rounded bg-black/30 border border-white/10" placeholder="0.00" />
                {autoMan && (
                  <button onClick={() => setWithdrawAmount(String(autoMan.pooled))}
                    className="px-3 rounded bg-white/10 hover:bg-white/20 text-xs">MAX</button>
                )}
              </div>

              <button onClick={doWithdraw} disabled={busy || !withdrawAmount}
                className="w-full py-3 rounded-lg bg-gradient-to-r from-purple-600 to-pink-600 hover:opacity-90 disabled:opacity-40 font-semibold">
                {busy ? 'Working…' : 'Withdraw'}
              </button>
            </>
          ) : (
            <>
              <p className="text-xs opacity-70 mb-3">
                Your individual V4 positions. Pull % of the liquidity and pick
                which side you want back (ETH or a specific stable).
              </p>

              {smPositions.length === 0 && (
                <div className="p-6 text-center text-sm opacity-60 rounded-lg bg-white/5">
                  No active self-managed positions.
                </div>
              )}

              {smPositions.map(p => {
                const idStr = String(p.id)
                const percent = pullPercents[idStr] ?? 100
                const tokenAddr = pullTokens[idStr] ?? ZERO_ADDR
                return (
                  <div key={idStr} className="p-3 mb-2 rounded-lg bg-white/5 border border-white/10">
                    <div className="flex justify-between text-xs mb-2">
                      <span className="font-mono">#{idStr}</span>
                      <span className="opacity-60">ticks [{p.lower}, {p.upper}]</span>
                    </div>
                    <div className="text-[10px] opacity-60 mb-2">
                      Liquidity {fmt(Number(p.liq) / 1e18, 4)} · opened at block {String(p.created)}
                    </div>
                    <div className="flex gap-2 items-center mb-2 text-xs">
                      <label className="w-12">Pull</label>
                      <input type="range" min={1} max={100} value={percent}
                        onChange={e => setPullPercents({ ...pullPercents, [idStr]: Number(e.target.value) })}
                        className="flex-1" />
                      <span className="w-10 text-right tabular-nums">{percent}%</span>
                    </div>
                    <div className="flex gap-2 mb-2 text-xs">
                      <label className="w-12 self-center">As</label>
                      <select value={tokenAddr}
                        onChange={e => setPullTokens({ ...pullTokens, [idStr]: e.target.value })}
                        className="flex-1 p-1.5 rounded bg-black/30 border border-white/10">
                        <option value={ZERO_ADDR}>ETH</option>
                        {STABLES.map(s => (
                          <option key={s.address} value={s.address}>{s.symbol}</option>
                        ))}
                      </select>
                    </div>
                    <button onClick={() => doPullPosition(p.id)} disabled={busy}
                      className="w-full py-2 rounded bg-gradient-to-r from-purple-600 to-pink-600 hover:opacity-90 disabled:opacity-40 text-sm">
                      Pull {percent}%
                    </button>
                  </div>
                )
              })}
            </>
          )}
        </Section>
      )}

      {/* ── Swap ─────────────────────────────────────────────────────── */}
      {tab === 'swap' && (
        <Section title="Swap">
          {/* USD→BTC and BTC→USD share ONE flippable card (see ⇅ below); the
              selector lists a single "BTC ⇄" entry for both directions. */}
          <div className="flex gap-1 p-1 rounded-lg bg-white/5 mb-4 text-xs">
            {([
              { k: 'usdToEth', label: 'USD→ETH' },
              { k: 'ethToUsd', label: 'ETH→USD' },
              { k: 'btc',      label: 'BTC ⇄'   },
              { k: 'usdToUsd', label: 'Stables' },
            ] as const).map(t => {
              const active = t.k === 'btc'
                ? (swapDirection === 'usdToBtc' || swapDirection === 'btcToUsd')
                : swapDirection === t.k
              return (
                <button key={t.k}
                  className={`flex-1 px-2 py-2 rounded-md text-[11px] ${active ? 'bg-white/15' : 'hover:bg-white/10'}`}
                  onClick={() => {
                    if (t.k === 'btc') {
                      if (swapDirection !== 'usdToBtc' && swapDirection !== 'btcToUsd') setSwapDirection('usdToBtc')
                    } else {
                      setSwapDirection(t.k)
                    }
                  }}>
                  {t.label}
                </button>
              )
            })}
          </div>

          {/* DEX-style direction flip — one card handles both BTC legs. */}
          {(swapDirection === 'usdToBtc' || swapDirection === 'btcToUsd') && (
            <div className="flex items-center justify-center gap-4 mb-4 p-2.5 rounded-lg bg-white/5">
              <span className="text-sm font-medium w-12 text-right">{swapDirection === 'usdToBtc' ? 'USD' : 'BTC'}</span>
              <button
                title="Flip direction"
                onClick={() => {
                  setSwapInQuote(null); setSwapInStatus(null)
                  setSwapDirection(swapDirection === 'usdToBtc' ? 'btcToUsd' : 'usdToBtc')
                }}
                className="w-8 h-8 rounded-full bg-white/10 hover:bg-white/20 flex items-center justify-center text-base leading-none">
                ⇅
              </button>
              <span className="text-sm font-medium w-12 text-left">{swapDirection === 'usdToBtc' ? 'BTC' : 'USD'}</span>
            </div>
          )}

          {swapDirection === 'usdToUsd' && (
            <>
              <label className="block text-sm mb-1">To stable</label>
              <select value={swapTokenOut?.address || ''}
                onChange={e => setSwapTokenOut(STABLES.find(s => s.address === e.target.value) || null)}
                className="w-full mb-3 p-2 rounded bg-black/30 border border-white/10">
                <option value="">— pick —</option>
                {STABLES.filter(s => s.address !== swapToken?.address).map(s => (
                  <option key={s.address} value={s.address}>{s.symbol}</option>
                ))}
              </select>
            </>
          )}

          {(
            <>
              <label className="block text-sm mb-1">
                {swapDirection === 'ethToUsd' || swapDirection === 'btcToUsd' ? 'Output stable' : 'Input stable'}
              </label>
              <select
                value={swapToken?.address || ''}
                onChange={e => setSwapToken(STABLES.find(s => s.address === e.target.value) || null)}
                className="w-full mb-3 p-2 rounded bg-black/30 border border-white/10">
                {STABLES.map(s => (
                  <option key={s.address} value={s.address}>
                    {s.symbol}
                    {swapDirection !== 'ethToUsd' &&
                      ` · bal ${fmt(Number(BigInt(stableBals[s.address] || '0')) / 10**s.decimals, 4)}`}
                  </option>
                ))}
              </select>
            </>
          )}

          <label className="block text-sm mb-1">
            Amount ({swapDirection === 'ethToUsd' ? 'ETH' : swapDirection === 'btcToUsd' ? 'BTC' : swapToken?.symbol || 'stable'})
          </label>
          <input value={swapAmount} onChange={e => setSwapAmount(e.target.value)}
            className="w-full mb-3 p-2 rounded bg-black/30 border border-white/10" placeholder="0.00" />

          {swapDirection !== 'btcToUsd' && (<>
          <label className="block text-sm mb-1">
            Min out (in {
              swapDirection === 'usdToEth' ? 'ETH (18 dec)' :
              swapDirection === 'usdToBtc' ? 'BTC (8 dec)' :
              `${swapToken?.symbol || 'stable'} (${swapToken?.decimals ?? 18} dec)`
            })
          </label>
          <input value={swapMinOut} onChange={e => setSwapMinOut(e.target.value)}
            className="w-full mb-1 p-2 rounded bg-black/30 border border-white/10" placeholder="0" />
          <div className="text-[10px] opacity-60 mb-4">
            Slippage floor. Set 0 to accept any output; tighten before high-volatility periods.
          </div>
          </>)}

          {swapDirection === 'usdToBtc' && (
            <div className="mb-4 space-y-2">
              <div className="p-3 rounded bg-amber-900/30 border border-amber-700/50 text-xs">
                <strong>USD → BTC:</strong> spend a stablecoin; QU!D delivers <strong>native BTC
                on-chain to your Bitcoin address</strong> (no Lightning wallet needed). The hop
                settles it in ~1 block.
              </div>
              <label className="block text-sm mb-1">Your Bitcoin address</label>
              <input value={swapBtcAddr} onChange={e => setSwapBtcAddr(e.target.value)}
                className="w-full p-2 rounded bg-black/30 border border-white/10 text-xs font-mono" placeholder="bc1… or 1… / 3…" />
              {swapBtcAddr.trim() && (
                addressToScriptPubKey(swapBtcAddr)
                  ? <p className="text-[11px] text-emerald-400">✓ valid address</p>
                  : <p className="text-[11px] text-rose-400">Not a valid Bitcoin address.</p>
              )}
            </div>
          )}

          {swapDirection === 'btcToUsd' && (
            <div className="mb-4 space-y-2">
              <div className="p-3 rounded bg-amber-900/30 border border-amber-700/50 text-xs">
                <strong>BTC → USD:</strong> get a Bitcoin address to send to from any wallet — no
                Lightning needed. QU!D watches your deposit, confirms it, and credits the stablecoin.
                A small fee is netted into the rate; tiny amounts are blocked (the fee would dominate).
              </div>
              {!swapInQuote ? (
                <button onClick={doRequestSwapIn} disabled={swapInBusy || !swapAmount || !swapToken}
                  className="w-full py-2.5 rounded-lg bg-white/15 hover:bg-white/25 disabled:opacity-40 text-sm font-medium">
                  {swapInBusy ? 'Requesting…' : 'Get deposit address'}
                </button>
              ) : (
                <div className="p-3 rounded-lg bg-white/5 text-xs space-y-1">
                  <div className="opacity-70">Send <strong>exactly {fmt(swapInQuote.exactSats / 1e8, 8)} ₿</strong> to:</div>
                  <div className="font-mono break-all p-2 rounded bg-black/30">{swapInQuote.depositAddress}</div>
                  <div className="opacity-60">You’ll receive ≈ {swapToken ? fmt(Number(BigInt(swapInQuote.minDeliveredUsd)) / 10 ** swapToken.decimals, 2) : '—'} {swapToken?.symbol}.</div>
                  <div className="flex items-center justify-between pt-1">
                    <span className="opacity-70">Status</span>
                    <span className={swapInStatus === 'settled' ? 'text-emerald-400' : swapInStatus === 'expired' || swapInStatus === 'failed' ? 'text-rose-400' : 'text-amber-400'}>
                      {swapInStatus === 'awaiting_deposit' ? 'waiting for your deposit…'
                        : swapInStatus === 'confirming' ? 'confirming (≈6 blocks)…'
                        : swapInStatus === 'settled' ? 'settled ✓ — USD credited'
                        : swapInStatus === 'expired' ? 'quote expired — start again'
                        : swapInStatus === 'failed' ? 'failed' : '…'}
                    </span>
                  </div>
                  <button onClick={() => { setSwapInQuote(null); setSwapInStatus(null) }}
                    className="text-[11px] opacity-60 hover:opacity-100 underline mt-1">new quote</button>
                </div>
              )}
            </div>
          )}

          {swapDirection !== 'btcToUsd' && (
            <button onClick={doSwap}
              disabled={busy || !swapAmount || (swapDirection === 'usdToBtc' && !addressToScriptPubKey(swapBtcAddr))}
              className="w-full py-3 rounded-lg bg-gradient-to-r from-emerald-600 to-cyan-600 hover:opacity-90 disabled:opacity-40 font-semibold">
              {busy ? 'Working…' : 'Swap'}
            </button>
          )}
        </Section>
      )}

      {/* ── Redeem ───────────────────────────────────────────────────── */}
      {tab === 'redeem' && (
        <Section title="Redeem QU!D">
          <p className="text-xs opacity-70 mb-3">
            Burns QUI for USDC (+ ETH fallback for shortfall). Redeem is clipped at{' '}
            <code>redeemableAmount()</code>; over-redeems leave un-burned QUI in your wallet.
          </p>

          <div className="grid grid-cols-3 gap-2 mb-3 text-xs">
            <Stat label="QUI balance" value={fmt(numQd)} />
            <Stat label="Mature" value={fmt(numMatureQd)} />
            <Stat label="Redeemable now" value={fmt(numRedeemable)} />
          </div>

          <label className="block text-sm mb-1">Amount (QUI)</label>
          <div className="flex gap-2 mb-4">
            <input value={redeemAmount} onChange={e => setRedeemAmount(e.target.value)}
              className="flex-1 p-2 rounded bg-black/30 border border-white/10" placeholder="0.00" />
            <button onClick={() => setRedeemAmount(String(Math.min(numMatureQd, numRedeemable)))}
              className="px-3 rounded bg-white/10 hover:bg-white/20 text-xs">MAX</button>
          </div>

          <button onClick={doRedeem} disabled={busy || !redeemAmount}
            className="w-full py-3 rounded-lg bg-gradient-to-r from-orange-600 to-red-600 hover:opacity-90 disabled:opacity-40 font-semibold">
            {busy ? 'Working…' : 'Redeem'}
          </button>
        </Section>
      )}

      {/* ── BTC Channel ──────────────────────────────────────────────── */}
      {tab === 'channel' && (
        <Section title="Open BTC Channel">
          <p className="text-xs opacity-70 mb-3">
            <strong>You run nothing.</strong> The live BTC-LP path is enclave-custody
            (Option B): you deposit BTC and sign <em>one</em> cold on-chain delegation
            that pins your <code>btcRecipientOf</code> payout address; the fleet enclave
            (holding both 2-of-2 key halves) then opens + operates the channel for you.
            <strong> No QU!D is minted on open</strong> — it records the locked sats and
            credits your BTC pool position. Every payout — cooperative close, splice-out,
            and the dead-man exit below — is <strong>pinned on-chain to your
            <code>btcRecipientOf</code></strong>, so the fleet can never redirect your funds.
          </p>

          <p className="text-xs opacity-70 mb-3">
            <strong>Custody backstop (dead-man exit).</strong> The fleet pre-signs a
            fully-signed, timelocked (CLTV) exit tx that pays your checkpoint balance to
            your <code>btcRecipientOf</code>, publishes its raw bytes on-chain, and
            refreshes it on a heartbeat that pushes the timelock forward. While the fleet
            is alive the timelock stays in the future, so the exit can&apos;t be broadcast
            (no griefing). If the fleet ever vanishes the heartbeat stops, the last
            timelock matures, and <strong>anyone</strong> — a keeper, a watchtower, or you
            via a stateless page hitting a public mempool API — can broadcast the
            already-public bytes to recover your BTC. No key, no signing, no download:
            Bitcoin&apos;s CLTV is the enforcement, the EVM is just the public bulletin board.
            The reference recovery client is the keyless <code>quid-recover-exit</code> tool
            (it reads the latest <code>DeadManExitEmitted</code> log for your channel via
            <code>eth_getLogs</code> and POSTs the raw tx to any public Esplora endpoint) —
            run it yourself, or let any watchtower/keeper run it for you.
          </p>

          <p className="text-xs opacity-50 mb-2">
            <strong>Legacy self-host / operator open</strong> (advanced — the delegated flow
            above needs none of this): paste the artifacts an LP node produced to submit an
            <code>openChannel</code> directly.
          </p>

          <label className="block text-xs mb-1">OpenParams (JSON)</label>
          <textarea value={ocParams} onChange={e => setOcParams(e.target.value)} rows={6}
            placeholder={'{\n  "fundingBlockHash": "0x…",\n  "fundingBlockHeight": 850000,\n  "fundingTxIndex": 3,\n  "lpPubkey": "0x…(33B)",\n  "hopPubkey": "0x…(33B)",\n  "amountSats": 1000000,\n  "fundingTaproot": "0x…(32B x-only Q)",\n  "hop": "0x…(hop EVM submitter addr)"\n}'}
            className="w-full mb-2 p-2 rounded bg-black/30 border border-white/10 font-mono text-[10px]" />

          <label className="block text-xs mb-1">rawFundingTx (hex)</label>
          <input value={ocRawTx} onChange={e => setOcRawTx(e.target.value)} placeholder="0x…"
            className="w-full mb-2 p-2 rounded bg-black/30 border border-white/10 font-mono text-[10px]" />

          <label className="block text-xs mb-1">fundingMerkleProof (JSON array of bytes32)</label>
          <input value={ocProof} onChange={e => setOcProof(e.target.value)} placeholder='["0x…","0x…"]'
            className="w-full mb-2 p-2 rounded bg-black/30 border border-white/10 font-mono text-[10px]" />

          <label className="block text-xs mb-1">lpAuth (signature hex)</label>
          <input value={ocLpAuth} onChange={e => setOcLpAuth(e.target.value)} placeholder="0x…(65B)"
            className="w-full mb-3 p-2 rounded bg-black/30 border border-white/10 font-mono text-[10px]" />

          <label className="block text-xs mb-1">lpBtcPayoutHash (P2WPKH, node-supplied)</label>
          <input value={ocLpBtcPayout} onChange={e => setOcLpBtcPayout(e.target.value)} placeholder="0x…(32B)"
            className="w-full mb-3 p-2 rounded bg-black/30 border border-white/10 font-mono text-[10px]" />

          {ocRecovered && (
            <div className="mb-3 p-2 rounded bg-black/30 border border-white/10 text-[10px] break-all">
              digest <code>{ocDigest}</code><br />
              channel owner (recovered from lpAuth): <code>{ocRecovered}</code>
            </div>
          )}

          <div className="flex gap-2 mb-4">
            <button onClick={doVerifyChannel} disabled={!ocParams || !ocRawTx || !ocLpAuth}
              className="flex-1 py-2 rounded bg-white/10 hover:bg-white/20 disabled:opacity-40 text-sm">
              Verify lpAuth → owner
            </button>
            <button onClick={doOpenChannel} disabled={busy || !ocParams || !ocRawTx || !ocLpAuth || !connected}
              title="The hop submits openChannel with your verified lpAuth (a direct user submit reverts, §9b)."
              className="flex-1 py-2 rounded bg-gradient-to-r from-amber-600 to-orange-600 hover:opacity-90 disabled:opacity-40 font-semibold text-sm">
              {busy ? 'Relaying…' : 'Open via hop'}
            </button>
          </div>
          {ocRelay && (
            <div className="mb-3 p-2 rounded bg-black/30 border border-white/10 text-[11px]">
              Hop relay: <strong className={ocRelay.status === 'opened' ? 'text-emerald-400'
                : ocRelay.status === 'rejected' ? 'text-red-400' : 'text-amber-300'}>{ocRelay.status}</strong>
              {ocRelay.channelId && <><br />channel <code className="break-all">{ocRelay.channelId}</code></>}
              {ocRelay.reason && <><br /><span className="opacity-70">{ocRelay.reason}</span></>}
            </div>
          )}
          <p className="text-[11px] opacity-50 mt-1">
            Channel open is <strong>hop-mediated</strong> (the hop submits it with your verified
            lpAuth — a direct submit reverts, §9b). Verify your lpAuth above, then the hop relays the open
            on-chain; the channel owner is the address recovered from lpAuth, not the submitter.
          </p>

          {/* Manual setBtcRecipient — useful before openChannel for stable→BTC swap-outs */}
          <details className="mb-4 p-3 rounded bg-white/5 border border-white/10 text-xs">
            <summary className="cursor-pointer">Set BTC recipient (P2WPKH pubkey hash)</summary>
            <p className="mt-2 opacity-70">
              Auto-set on channel open. Set manually here if you want to receive
              swap-out BTC before opening a channel.
            </p>
            <input value={btcRecipientHash} onChange={e => setBtcRecipientHash(e.target.value)}
              placeholder="0x… (20-byte RIPEMD160 hash, padded to 32)"
              className="w-full mt-2 mb-2 p-2 rounded bg-black/30 border border-white/10" />
            <button onClick={doSetBtcRecipient} disabled={busy || !btcRecipientHash}
              className="px-3 py-1.5 rounded bg-white/10 hover:bg-white/20 disabled:opacity-40">
              Set recipient
            </button>
          </details>
        </Section>
      )}

      {/* ── Waiver modal (first mint) ────────────────────────────────── */}
      {showWaiver && (
        <Modal onClose={() => setShowWaiver(false)} title="Disclaimer">
          <div className="text-sm space-y-3 max-h-96 overflow-y-auto pr-2">
            <p>QU!D is experimental. No team, no admin keys, no upgrades.</p>
            <p>
              You are minting a stablecoin-basket token backed by deposits across
              {' '}{STABLES.length} stables (USDC, USDT, DAI, USDS, USDe, crvUSD, FRAX,
              GHO, PYUSD, RLUSD, USDG, AUSD, BOLD). Some routes through yield
              venues (Morpho / Aave v4 / sDAI / sUSDe / Liquity SP).
            </p>
            <p>
              QUI has a maturity month per mint. Pre-maturity QUI is non-redeemable
              but transferable. At maturity, redemption clips to{' '}
              <code>Aux.redeemableAmount()</code>.
            </p>
            {/* CORRECTED 2026-07-26: this cited a weighted-median VOTE and `Basket.getHaircut()`.
                Neither exists — the vote subsystem was deleted (#12), and `getHaircut`/`K_btc`/
                `WEIGHTS_btc` are absent from evm/src entirely. The haircut is now driven by the
                ORACLE-measured depeg severity (`Aux.getDepegSeverityBps`, the single source of
                truth), not by any governance vote. */}
            <p>
              Depeg of any underlying stable haircuts redeemable QUI by that
              stable&apos;s oracle-measured severity (<code>Aux.getDepegSeverityBps()</code>).
              Worst-case recovery is the residual non-depegged basket value.
            </p>
            <p>
              You are solely responsible for the keys to your wallet, gas costs,
              and tax reporting on yield. No party is liable for contract bugs,
              oracle failures, or third-party venue insolvency.
            </p>
          </div>
          <label className="flex items-center gap-2 mt-4 text-sm">
            <input type="checkbox" checked={waiverChecked}
              onChange={e => setWaiverChecked(e.target.checked)} />
            I understand and accept these risks.
          </label>
          <button
            disabled={!waiverChecked}
            onClick={() => {
              try { localStorage.setItem('quid-waiver-v1', '1') } catch {}
              setWaiverAccepted(true); setShowWaiver(false)
            }}
            className="w-full mt-3 py-2 rounded bg-cyan-600 hover:bg-cyan-500 disabled:opacity-40">
            Accept and continue
          </button>
        </Modal>
      )}

      {/* ── About modal ──────────────────────────────────────────────── */}
      {showAbout && (
        <Modal onClose={() => setShowAbout(false)} title="About QU!D">
          <div className="text-sm space-y-3 max-h-96 overflow-y-auto pr-2">
            <p>
              QU!D (QUI) is a stablecoin-basket token with built-in yield, native
              ETH/BTC liquidity via Uniswap V4, and Bitcoin-native LP onboarding
              via 2-of-2 Lightning channels with on-chain SPV verification.
            </p>
            <p>
              <strong>Mint:</strong> deposit any whitelisted stable → receive QUI with a
              chosen maturity month. Aux routes the deposit through the basket's
              yield venues (depositors select their preference), and mints yield upfront.
            </p>
            <p>
              <strong>LP:</strong> Vogue runs a single-sided V4 position out-of-range
              on the vanilla ETH/USD and BTC/USD pools. ETH side earns trading
              fees + Morpho/Galaxy yield. BTC side earns trading fees settled as
              native sats (<code>btcFeesOwedSats</code>, paid by the hop at close).
            </p>
            <p>
              <strong>Swap:</strong> Aux.swap is the single entry — accepts QUID, any
              stable, or volatile (WETH / WBTC) and routes via the V4 vanilla pool
              with TWAP guarding, plus "smart order routed" multi-hop fallbacks, for
              when in-pool liquidity is thin.
            </p>
          </div>
        </Modal>
      )}

      <footer className="mt-8 pt-4 border-t border-white/5 text-xs opacity-50 text-center">
        Ethereum mainnet only · contracts at {short(CONTRACTS.aux)}
        {CONTRACTS.aux === ZERO_ADDR && ' (not yet deployed — addresses are placeholders)'}
      </footer>
    </main>
  )
}

// ═════════════════════════════════════════════════════════════════════
//   PRIMITIVES
// ═════════════════════════════════════════════════════════════════════
function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="p-5 rounded-xl bg-black/20 border border-white/5">
      <h2 className="text-lg font-semibold mb-4">{title}</h2>
      {children}
    </section>
  )
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="p-3 rounded-lg bg-white/5 border border-white/10">
      <div className="text-[10px] uppercase tracking-wider opacity-60">{label}</div>
      <div className="font-mono text-sm">{value}</div>
    </div>
  )
}

function Modal({ title, onClose, children }:
  { title: string; onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4">
      <div className="w-full max-w-md p-6 rounded-2xl bg-[#15171c] border border-white/10">
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-lg font-semibold">{title}</h3>
          <button onClick={onClose} className="opacity-60 hover:opacity-100">✕</button>
        </div>
        {children}
      </div>
    </div>
  )
}
