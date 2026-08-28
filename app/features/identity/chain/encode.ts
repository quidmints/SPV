// Calldata encoders and pure helpers for the swap/LP app.
//
// PORTED VERBATIM from the module-level block of `SPV/spa/src/app/(app)/app/page.tsx` (lines
// 26-150), 2026-08-16. ⚠️ **A PORT, NOT A REFACTOR** — nothing in the body below is rewritten,
// because doing both at once means a behaviour change cannot be attributed to either.
//
// WHY IT MOVED OUT OF THE PAGE AT ALL: `page.tsx` IS the wallet app now, and this block is the
// part of it that has no view in it — `enc` is the calldata for every write the app makes, and
// the rest is arithmetic. Splitting it here means the screen rewrite (DOM+tailwind → RN, ~433 of
// the page's 1,678 component lines) cannot silently take the encoders with it.
//
// ⚠️ **`iface` BELOW IS A SECOND INTERFACE, AND IT IS DELIBERATE FOR NOW.** `eth.ts` exports one
// over a SUPERSET of these ABIs (+ CORE, + LEV_VENUE). Collapsing the two is right under "one
// declaration per interface" — but ethers resolves `encodeFunctionData(name, …)` by NAME and
// THROWS on an ambiguous fragment, so a same-named function in either added ABI would turn every
// encode into a runtime throw. Merge them as its own change, with the name collision checked
// first; do not fold it into the port.
import { ethers } from 'ethers'
import { ERC20_ABI, BASKET_ABI, AUX_ABI, VOGUE_ABI, BTCCHANNELS_ABI, LEV_MANAGER_ABI } from './abi.ts'
import { ethCall, waitTx } from './eth.ts'
import { isUsdtLike } from './chains.ts'
import { sendTx } from './protect.ts'

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
  redeemable:  () => iface.encodeFunctionData('redeemableAmount', []),
  twapAsset:   (asset: string, p: number) => iface.encodeFunctionData('getTWAPforAsset', [asset, p]),
  metrics:     (force: boolean) => iface.encodeFunctionData('get_metrics', [force]),
  deposits:    () => iface.encodeFunctionData('get_deposits', []),
  avgYield:    () => iface.encodeFunctionData('avgYield', []),
  // Vogue (ETH side ERC4626-shaped)
  vogueDeposit:  (a: bigint, r: string) => iface.encodeFunctionData('deposit(uint256,address)', [a, r]),
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
// ⚠️ THE PAGE'S LOCAL `ethCall` / `waitTx` ARE DELETED HERE, NOT PORTED. They were
// byte-equivalent copies of `eth.ts`'s talking straight to `window.ethereum` — and
// `eth.ts`'s own header named them: "page.tsx keeps its own local copies (unchanged)".
// That duplication was survivable while both spoke to the same injected wallet; it is NOT
// survivable now, because only one of the two got the React Native transport, so keeping
// them would leave the approval path reading through a `window` that does not exist.
// One declaration, in `eth.ts`.

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

