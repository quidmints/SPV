// Bitcoin address → scriptPubKey (for requestSwapOutOnchain's `swapperScript`).
// Supports P2WPKH/P2WSH/P2TR (bech32/bech32m) and P2PKH/P2SH (base58check).
// Money path: a wrong script sends BTC to the wrong/unspendable place, so this is
// verified against known address→script vectors (see btcaddress.test).

import { ethers } from 'ethers'

const BECH32 = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

function polymod(values: number[]): number {
  let chk = 1
  for (const v of values) {
    const b = chk >> 25
    chk = ((chk & 0x1ffffff) << 5) ^ v
    for (let i = 0; i < 5; i++) if ((b >> i) & 1) chk ^= GEN[i]
  }
  return chk
}
function hrpExpand(hrp: string): number[] {
  const out: number[] = []
  for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) >> 5)
  out.push(0)
  for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) & 31)
  return out
}
function convertBits(data: number[], from: number, to: number, pad: boolean): number[] | null {
  let acc = 0, bits = 0
  const out: number[] = []
  const maxv = (1 << to) - 1
  const maxAcc = (1 << (from + to - 1)) - 1
  for (const v of data) {
    if (v < 0 || (v >> from) !== 0) return null
    acc = ((acc << from) | v) & maxAcc
    bits += from
    while (bits >= to) { bits -= to; out.push((acc >> bits) & maxv) }
  }
  if (pad) { if (bits) out.push((acc << (to - bits)) & maxv) }
  else if (bits >= from || ((acc << (to - bits)) & maxv)) return null
  return out
}
function decodeSegwit(addr: string): { version: number; program: number[] } | null {
  const lower = addr.toLowerCase()
  const pos = lower.lastIndexOf('1')
  if (pos < 1) return null
  const hrp = lower.slice(0, pos)
  if (hrp !== 'bc' && hrp !== 'tb' && hrp !== 'bcrt') return null
  const data: number[] = []
  for (const c of lower.slice(pos + 1)) { const d = BECH32.indexOf(c); if (d < 0) return null; data.push(d) }
  if (data.length < 6) return null
  const spec = polymod(hrpExpand(hrp).concat(data))   // 1 = bech32, 0x2bc830a3 = bech32m
  const version = data[0]
  if (version === 0 && spec !== 1) return null
  if (version !== 0 && spec !== 0x2bc830a3) return null
  if (version > 16) return null
  const program = convertBits(data.slice(1, -6), 5, 8, false)
  if (!program) return null
  if (program.length < 2 || program.length > 40) return null
  if (version === 0 && program.length !== 20 && program.length !== 32) return null
  return { version, program }
}

const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
function decodeBase58Check(addr: string): Uint8Array | null {
  let num = 0n
  for (const c of addr) { const d = B58.indexOf(c); if (d < 0) return null; num = num * 58n + BigInt(d) }
  let hexStr = num.toString(16); if (hexStr.length % 2) hexStr = '0' + hexStr
  const body = num === 0n ? [] : (hexStr.match(/.{2}/g) || []).map(h => parseInt(h, 16))
  for (const c of addr) { if (c === '1') body.unshift(0); else break }   // leading '1' = 0x00
  const arr = new Uint8Array(body)
  if (arr.length < 5) return null
  const payload = arr.slice(0, -4), checksum = arr.slice(-4)
  const h = ethers.getBytes(ethers.sha256(ethers.sha256(payload)))
  for (let i = 0; i < 4; i++) if (h[i] !== checksum[i]) return null
  return payload
}

const toHex = (b: number[] | Uint8Array) => '0x' + Array.from(b).map(x => x.toString(16).padStart(2, '0')).join('')

export function addressToScriptPubKey(addr: string): string | null {
  try {
    const a = addr.trim()
    if (!a) return null
    if (/^(bc1|tb1|bcrt1)/i.test(a)) {
      const d = decodeSegwit(a); if (!d) return null
      const verByte = d.version === 0 ? 0x00 : 0x50 + d.version   // OP_0 / OP_1..OP_16
      return toHex([verByte, d.program.length, ...d.program])
    }
    const payload = decodeBase58Check(a); if (!payload) return null
    const version = payload[0], hash = Array.from(payload.slice(1))
    if (hash.length !== 20) return null
    if (version === 0x00 || version === 0x6f) return toHex([0x76, 0xa9, 0x14, ...hash, 0x88, 0xac]) // P2PKH
    if (version === 0x05 || version === 0xc4) return toHex([0xa9, 0x14, ...hash, 0x87])             // P2SH
    return null
  } catch { return null }
}

// Random 32-byte swapId (dedup key for requestSwapOutOnchain).
export function randomSwapId(): string {
  const b = new Uint8Array(32)
  crypto.getRandomValues(b)
  return toHex(b)
}
