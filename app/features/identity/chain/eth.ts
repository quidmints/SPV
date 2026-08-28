// Shared read plumbing for the swap/LP app.
//
// PORTED FROM `SPV/spa/src/lib/eth.ts` (2026-08-16), and the ONLY thing that changed is where
// `rpc` gets its transport. In the SPA that was `window.ethereum.request({ method, params })` —
// the injected browser wallet. React Native has no injected wallet, so the app supplies its own
// provider, and `ethers.JsonRpcProvider.send(method, params)` is the SAME SHAPE as
// `window.ethereum.request`. Everything below `rpc` is unchanged from the SPA, because it all
// went through `rpc` already — which is why the browser coupling was two functions and not a
// layer.
//
// ⚠️ READS AND WRITES DELIBERATELY DO NOT SHARE A TRANSPORT. This one is for reads and may point
// at any RPC. Writes go through `protect.ts`, which pins its own transport to the private relay
// so a broadcast cannot silently take the public path — see the note there.

import { ethers } from 'ethers'
import { ERC20_ABI, BASKET_ABI, AUX_ABI, VOGUE_ABI, BTCCHANNELS_ABI, CORE_ABI,
  LEV_MANAGER_ABI, LEV_VENUE_ABI } from './abi.ts'

export const ZERO_ADDR = '0x0000000000000000000000000000000000000000'

export const iface = new ethers.Interface([
  ...ERC20_ABI, ...BASKET_ABI, ...AUX_ABI, ...VOGUE_ABI, ...BTCCHANNELS_ABI, ...CORE_ABI,
  ...LEV_MANAGER_ABI, ...LEV_VENUE_ABI,
])

/// The read transport. Declared structurally rather than as `ethers.JsonRpcProvider` so a test
/// can supply a recorded one without standing up a provider — the surface really is this small.
export interface RpcTransport {
  send(method: string, params: unknown[]): Promise<any>
}

let transport: RpcTransport | null = null

/// Install the read transport. The app calls this once at boot with a
/// `new ethers.JsonRpcProvider(url)`; nothing in this file reaches for a global.
export function setRpcTransport(t: RpcTransport | null): void {
  transport = t
}

/// Whether reads can be served.
///
/// ⚠️ RENAMED FROM `hasWallet`, and the rename is the point. In the browser those were the same
/// question — the injected wallet was both the TRANSPORT and the ACCOUNT. In the app they are
/// not: the account is the wallet's own key and exists before any RPC is configured. Keeping the
/// old name would have made "no RPC yet" and "no account" indistinguishable at every call site.
export function hasRpc(): boolean {
  return transport !== null
}

export async function rpc(method: string, params: unknown[]): Promise<any> {
  if (!transport) throw new Error('chain: no RPC transport installed (call setRpcTransport first)')
  return transport.send(method, params)
}

export async function ethCall(to: string, data: string): Promise<string> {
  return rpc('eth_call', [{ to, data }, 'latest'])
}

// Decode a single-return eth_call. Returns null on any failure (undeployed
// contract, revert, decode mismatch) so callers degrade to '—' gracefully.
export async function readOne(to: string, fn: string, args: unknown[] = []): Promise<any> {
  if (!to || to === ZERO_ADDR || !hasRpc()) return null
  try {
    const data = iface.encodeFunctionData(fn, args)
    const res = await ethCall(to, data)
    if (!res || res === '0x') return null
    const dec = iface.decodeFunctionResult(fn, res)
    return dec.length === 1 ? dec[0] : dec
  } catch { return null }
}

export async function blockNumber(): Promise<number> {
  try { return Number(BigInt(await rpc('eth_blockNumber', []))) } catch { return 0 }
}

export async function getLogs(filter: {
  address?: string | string[]
  topics?: (string | string[] | null)[]
  fromBlock: number
  toBlock: number | 'latest'
}): Promise<any[]> {
  if (!hasRpc()) return []
  const toHex = (n: number | 'latest') => n === 'latest' ? 'latest' : '0x' + n.toString(16)
  try {
    return await rpc('eth_getLogs', [{
      ...filter,
      fromBlock: toHex(filter.fromBlock),
      toBlock: toHex(filter.toBlock),
    }]) || []
  } catch { return [] }
}

export async function waitTx(hash: string, timeoutSec = 90): Promise<void> {
  for (let i = 0; i < timeoutSec; i++) {
    await new Promise(r => setTimeout(r, 1000))
    const r = await rpc('eth_getTransactionReceipt', [hash])
    if (r?.status === '0x1') return
    if (r?.status === '0x0') throw new Error(`tx ${hash} reverted`)
  }
  throw new Error(`tx ${hash} timed out`)
}

export const padAddr = (a: string) => '0x' + a.toLowerCase().replace(/^0x/, '').padStart(64, '0')
export const TRANSFER_TOPIC = ethers.id('Transfer(address,address,uint256)')
