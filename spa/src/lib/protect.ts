'use client'

// ════════════════════════════════════════════════════════════════════════
//   FRONTRUNNING PROTECTION — route every state-changing tx through a private,
//   MEV-protected relay so it skips the PUBLIC mempool (where searchers can
//   sandwich / frontrun it) and goes straight to block builders.
//
//   Free relay, configurable:  Flashbots Protect (default) or MEV Blocker
//   (NEXT_PUBLIC_PROTECT_RPC_URL). Both are free and private.
//
//   HONEST CONSTRAINT: with an EOA wallet (MetaMask), `eth_sendTransaction`
//   signs AND broadcasts in the wallet, so the dApp can't force the broadcast
//   path per-call. The only programmatic lever is switching the wallet's
//   mainnet RPC to the relay via `wallet_addEthereumChain` (best-effort — the
//   user must accept). A HARD guarantee needs the AA layer (a dApp-controlled
//   ERC-4337 bundler that submits through the private relay) — see the AA TODO.
//   Until then this is defense-in-depth, and QU!D's pools are internal +
//   TWAP-priced so the classic sandwich surface is already minimal.
// ════════════════════════════════════════════════════════════════════════

export const PROTECT = {
  url:  process.env.NEXT_PUBLIC_PROTECT_RPC_URL  || 'https://rpc.flashbots.net',
  name: process.env.NEXT_PUBLIC_PROTECT_RPC_NAME || 'Ethereum (Flashbots Protect)',
}

let enabled = false
let attempted = false

export function protectionEnabled(): boolean { return enabled }

// Point the wallet's mainnet RPC at the private relay (idempotent; prompts once
// per session). If the user declines we don't nag — sends still work, just
// without the private path (best-effort).
export async function enableProtection(force = false): Promise<boolean> {
  if (typeof window === 'undefined' || !window.ethereum) return false
  if (enabled) return true
  if (attempted && !force) return false
  attempted = true
  try {
    await window.ethereum.request({
      method: 'wallet_addEthereumChain',
      params: [{
        chainId: '0x1',
        chainName: PROTECT.name,
        rpcUrls: [PROTECT.url],
        nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
        blockExplorerUrls: ['https://etherscan.io'],
      }],
    })
    enabled = true
  } catch { enabled = false }
  return enabled
}

export interface Tx { from: string; to: string; data?: string; value?: string; gas?: string }

// THE single chokepoint for every state-changing tx. Ensures the private relay
// is the broadcast RPC, then sends. All SPA writes route through here so the
// frontrunning protection can't be bypassed by an un-wrapped call site.
export async function sendTx(tx: Tx): Promise<string> {
  await enableProtection()
  return window.ethereum.request({ method: 'eth_sendTransaction', params: [tx] })
}
