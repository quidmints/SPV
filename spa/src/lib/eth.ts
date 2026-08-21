'use client'

// Shared read/write plumbing for the dashboard components.
// page.tsx keeps its own local copies (unchanged); these serve the
// info tab, the regime brain, and the flow reconstruction.

import { ethers } from 'ethers'
import { ERC20_ABI, BASKET_ABI, AUX_ABI, RANGE_ABI, BTCCHANNELS_ABI, CORE_ABI,
  LEV_MANAGER_ABI, LEV_VENUE_ABI } from './abi'

export const ZERO_ADDR = '0x0000000000000000000000000000000000000000'

export const iface = new ethers.Interface([
  ...ERC20_ABI, ...BASKET_ABI, ...AUX_ABI, ...RANGE_ABI, ...BTCCHANNELS_ABI, ...CORE_ABI,
  ...LEV_MANAGER_ABI, ...LEV_VENUE_ABI,
])

export function hasWallet(): boolean {
  return typeof window !== 'undefined' && !!window.ethereum
}

export async function rpc(method: string, params: unknown[]): Promise<any> {
  return window.ethereum.request({ method, params })
}

export async function ethCall(to: string, data: string): Promise<string> {
  return rpc('eth_call', [{ to, data }, 'latest'])
}

// Decode a single-return eth_call. Returns null on any failure (undeployed
// contract, revert, decode mismatch) so callers degrade to '—' gracefully.
export async function readOne(to: string, fn: string, args: unknown[] = []): Promise<any> {
  if (!to || to === ZERO_ADDR || !hasWallet()) return null
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
  if (!hasWallet()) return []
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
