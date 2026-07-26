// ════════════════════════════════════════════════════════════════════════
//   CONFIG — everything from env, with sane defaults.
//
//   Contract addresses MIRROR spa/src/lib/chains.ts. They are zero-address
//   placeholders pre-deploy (that's expected); fill them in post-deployment
//   via the QUID_* env vars below — a single set lights the indexer up. The
//   indexer treats a 0x0 address as "skip this asset" (matches flow.ts).
// ════════════════════════════════════════════════════════════════════════

export const ZERO_ADDR = '0x0000000000000000000000000000000000000000'

export interface StableToken {
  symbol: string
  address: string
  decimals: number
}

// 11 stables — verbatim from spa/src/lib/chains.ts (mainnet addresses + decimals,
// BOLD last). Stables are valued at par ≈ $1 (matches flow.ts: USD = token units).
const STABLES_DEFAULT: StableToken[] = [
  { symbol: 'USDC',  address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', decimals: 6 },
  { symbol: 'USDT',  address: '0xdAC17F958D2ee523a2206206994597C13D831ec7', decimals: 6 },
  { symbol: 'PYUSD', address: '0x6c3ea9036406852006290770BEdFcAbA0e23A0e8', decimals: 6 },
  { symbol: 'GHO',   address: '0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f', decimals: 18 },
  { symbol: 'RLUSD', address: '0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD', decimals: 18 },
  { symbol: 'USDG',  address: '0xe343167631d89B6Ffc58B88d6b7fB0228795491D', decimals: 6 },
  { symbol: 'DAI',   address: '0x6B175474E89094C44Da98b954EedeAC495271d0F', decimals: 18 },
  { symbol: 'USDS',  address: '0xdC035D45d973E3EC169d2276DDab16f1e407384F', decimals: 18 },
  { symbol: 'USDE',  address: '0x4c9EDD5852cd905f086C759E8383e09bff1E68B3', decimals: 18 },
  { symbol: 'AUSD',  address: '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a', decimals: 6 },
  { symbol: 'BOLD',  address: '0x6440f144b7e50D6a8439336510312d2F54beB01D', decimals: 18 },
]

const env = (k: string, d: string): string => {
  const v = process.env[k]
  return v === undefined || v === '' ? d : v
}
const envInt = (k: string, d: number): number => {
  const v = process.env[k]
  if (v === undefined || v === '') return d
  const n = Number(v)
  return Number.isFinite(n) ? Math.floor(n) : d
}

export interface Config {
  rpcUrl: string
  // Protocol address set whose inbound/outbound Transfers count as flow.
  contracts: {
    basket: string
    aux: string
    vogue: string
    btcChannels: string
    weth: string
  }
  stables: StableToken[]
  startBlock: number
  confirmations: number  // depth below head that we treat as final
  chunkSize: number      // getLogs block-range chunk
  pollMs: number         // live-poll interval
  port: number
  dbPath: string
}

export function loadConfig(): Config {
  const stables = STABLES_DEFAULT.map(s => ({
    ...s,
    // Per-stable override (rarely needed): QUID_STABLE_USDC=0x... etc.
    address: env(`QUID_STABLE_${s.symbol}`, s.address),
  }))

  return {
    rpcUrl: env('RPC_URL', 'http://127.0.0.1:8545'),
    contracts: {
      basket:      env('QUID_BASKET',       ZERO_ADDR),
      aux:         env('QUID_AUX',          ZERO_ADDR),
      vogue:       env('QUID_VOGUE',        ZERO_ADDR),
      btcChannels: env('QUID_BTC_CHANNELS', ZERO_ADDR),
      // WETH defaults to canonical mainnet WETH (chains.ts), env-overridable.
      weth:        env('QUID_WETH',         '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'),
    },
    stables,
    // START_BLOCK should be the protocol's deploy block post-deploy; 0 means
    // "from genesis" which is impractical on a full node — set it explicitly.
    startBlock:    envInt('START_BLOCK', 0),
    confirmations: envInt('CONFIRMATIONS', 12),
    chunkSize:     envInt('CHUNK_SIZE', 2000),
    pollMs:        envInt('POLL_MS', 12000),
    port:          envInt('PORT', 4000),
    dbPath:        env('DB_PATH', './quid-index.db'),
  }
}

// The protocol address set (lowercased, 0x0 filtered) — into-set = inflow,
// out-of-set = outflow, exactly as flow.ts's PROTOCOL().
export function protocolAddrs(c: Config): string[] {
  return [c.contracts.basket, c.contracts.aux, c.contracts.vogue]
    .map(a => a.toLowerCase())
    .filter(a => a && a !== ZERO_ADDR)
}
