// QU!D SPA — Ethereum mainnet only.
// (Multi-chain / Solana support dropped vs old/.)

export interface Contracts {
  basket:      string  // QU!D token + mint entrypoint
  aux:         string  // swap / redeem / metrics
  vogue:       string  // V4 LP manager (ETH side; BTC side via autoManagedBTC / btcFeesOwedSats)
  vogueCore:   string  // V4 pool state (POOLED_ETH, POOLED_BTC, POOLED_USD_*, swapUsdBtc)
  btcChannels: string  // Bitcoin SPV channel registry
  levManager:  string  // YB leverage overlay (per-LP isolated IL-protect position; ETH side)
  weth:        string
  // wbtc = BitGo WBTC, the SINGLE BTC ERC20 in the system (what Aux.WBTC()
  // returns). It is the V4 BTC pool's volatile/pricing leg, the SOR fallback
  // inventory, and the TWAP source — purely Aux-internal. It is NEVER held by
  // or delivered to users: the design is wrapless. A user's BTC stake is QUID
  // (minted at channel open); BTC-leg fees accrue as native sats
  // (Vogue.btcFeesOwedSats); swap-out delivers NATIVE BTC via the hop to
  // btcRecipientOf. There is no "lnBTC" token and no planned ERC20 split.
  wbtc:        string  // BitGo WBTC — internal pricing/pool/SOR leg only (8 dec)
  weeth:       string  // weETH — the collateral weETH-leverage venues pledge (18 dec)
}

export interface StableToken {
  symbol:   string
  address:  string
  decimals: number
  isVault?: boolean
}

// Ethereum mainnet — chain id 1.
export const CHAIN_ID = 1
export const CHAIN_HEX = '0x1'
export const CHAIN_NAME = 'Ethereum'
export const EXPLORER = 'https://etherscan.io'

// Contract addresses — SUPPLIED AT RUNTIME, not compiled in.
//
// 🔴 **THIS USED TO IMPORT SPV's `evm/deployments/l1.json` THROUGH A PINNED SUBMODULE, AND THAT
// GLUE IS DELETED (2026-08-19).** The import was a build-time dependency on another repo's deploy
// record: a redeploy in SPV did not reach this app until somebody bumped the submodule, and when
// the submodule went away the wallet stopped compiling. Owner's call — "bad glue".
//
// ⇒ **The wallet now has NO build-time dependency on SPV.** Addresses default to the zero address,
// which every read path already treats as "not deployed" (`eth.ts:readOne` returns null for
// `ZERO_ADDR`), so an unconfigured app renders empty rather than dialling a wrong contract. The
// SPV integration comes back as a WIRING step — `bootChain({ contracts })` — once SPV's addresses
// are ready, with no code change here.
//
// ⚠️ The old `process.env.NEXT_PUBLIC_*` overrides are gone with it, and they were already inert:
// `NEXT_PUBLIC_*` is a Next build-time inlining convention that Expo does not perform, so every
// one of them read `undefined`. Pointing a build at a local anvil fork is now `setContracts`,
// which actually works, rather than an env var that silently did nothing.
const ZERO = '0x0000000000000000000000000000000000000000'

const isAddress = (v: string | undefined): v is string =>
  !!v && /^0x[0-9a-fA-F]{40}$/.test(v)

export const CONTRACTS: Contracts = {
  // Deployed per-environment; zero until `setContracts` is called.
  basket: ZERO,
  aux: ZERO,
  vogue: ZERO,
  vogueCore: ZERO,
  btcChannels: ZERO,
  levManager: ZERO,
  // Public token addresses, not deploy records — these are facts about mainnet, so they are
  // defaulted rather than injected. Override for a fork like any other entry.
  weth: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
  // The one BTC ERC20: BitGo WBTC, what Aux.WBTC() returns. Used only as the pricing leg —
  // never user-facing, since BTC delivery is native.
  wbtc: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599',
  // weETH (ether.fi) — the collateral the weETH-leverage venues pledge.
  weeth: '0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee',
}

/// Install deployed addresses. Mutates in place rather than replacing, so modules that imported
/// `CONTRACTS` keep a live reference — the same reason `PROTECT` is mutated in `protect.ts`.
///
/// ⚠️ Malformed entries are REJECTED, not coerced to zero. A typo'd address that silently became
/// `ZERO` would read as "not deployed" and render an empty screen, which looks like a chain
/// problem rather than a config one.
export function setContracts(next: Partial<Contracts>): void {
  for (const [k, v] of Object.entries(next)) {
    if (!isAddress(v)) throw new Error(`setContracts: ${k} is not a 20-byte address: ${v}`)
    ;(CONTRACTS as unknown as Record<string, string>)[k] = v
  }
}

// WBTC has 8 decimals. swap-out minOut is denominated in these raw WBTC units
// (the V4 pricing leg), even though delivery is native BTC via the hop.
export const WBTC_DECIMALS = 8

// 12 stables in DeployL1_s.sol order (verified 2026-07-22), **BOLD LAST** —
// the Aux runtime treats stables[length-1] as the Liquity stability pool
// route (BOLD/SP special-case). USDT0 was REMOVED from the deploy (no L1
// ERC20 exists — Ethereum uses canonical USDT behind the LayerZero adapter).
export const STABLES: StableToken[] = [
  { symbol: 'USDC',  address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', decimals: 6 },
  { symbol: 'USDT',  address: '0xdAC17F958D2ee523a2206206994597C13D831ec7', decimals: 6 },
  { symbol: 'PYUSD', address: '0x6c3ea9036406852006290770BEdFcAbA0e23A0e8', decimals: 6 },
  { symbol: 'GHO',   address: '0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f', decimals: 18 },
  { symbol: 'RLUSD', address: '0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD', decimals: 18 }, // verify on-chain
  { symbol: 'USDG',  address: '0xe343167631d89B6Ffc58B88d6b7fB0228795491D', decimals: 6 },  // verify on-chain
  { symbol: 'DAI',   address: '0x6B175474E89094C44Da98b954EedeAC495271d0F', decimals: 18 },
  { symbol: 'USDS',  address: '0xdC035D45d973E3EC169d2276DDab16f1e407384F', decimals: 18 },
  { symbol: 'USDE',  address: '0x4c9EDD5852cd905f086C759E8383e09bff1E68B3', decimals: 18 },
  { symbol: 'AUSD',  address: '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a', decimals: 6 },  // verify decimals on-chain
  { symbol: 'cUSD',  address: '0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC', decimals: 18 }, // Cap USD (18-dec, verified on-chain)
  { symbol: 'BOLD',  address: '0x6440f144b7e50D6a8439336510312d2F54beB01D', decimals: 18 }, // MUST be last
]

// USDT (and tokens with the same `approve != 0 only if current == 0` quirk)
// require an explicit reset-to-0 before raising the allowance. The mint flow
// (and any other approve-then-call) must handle this case.
export const USDT_QUIRK: Set<string> = new Set([
  '0xdAC17F958D2ee523a2206206994597C13D831ec7'.toLowerCase(), // USDT
])

export const isUsdtLike = (addr: string): boolean =>
  USDT_QUIRK.has(addr.toLowerCase())

// Hop API — the off-chain endpoint that mediates BTC↔USD swap-IN (the EVM can't
// initiate an inbound BTC swap alone). Empty until deployed; the swap-in UI shows
// "coming online" while unset. Token gates issuance (anti-spam), not custody.
export const HOP_API: { url: string; token: string } = {
  url:   process.env.NEXT_PUBLIC_HOP_API_URL   ?? '',
  token: process.env.NEXT_PUBLIC_HOP_API_TOKEN ?? '',
}

// Self-hosted indexer (SPV/indexer/) — serves net-flow over unbounded history
// from a DB instead of the SPA's bounded client-side getLogs. Empty → flow.ts
// falls back to the live getLogs reconstruction (bounded window, still works).
export const INDEXER_URL: string = process.env.NEXT_PUBLIC_INDEXER_URL ?? ''

// ETH yield venue, chosen PER auto-LP deposit (rides the deposit call; no setter).
// Matches Vogue's VENUE_* constants. Only the ether.fi (Rover) slice is hard-walled per-LP
// (exit served from your own weETH position); the other venues are fungible pooled 4626 WETH.
export interface EthVenue { id: number; label: string; blurb: string }
// NOTE: direct ether.fi (weETH) is NOT user-selectable — it is the protocol's INTERNAL
// fallback, used only if the Rover NFT has self-liquidated. ether.fi exposure is chosen
// via 'ether.fi Rover'. Split routes an equal fifth to Rover, so it too earns the slice.
export const ETH_VENUES: EthVenue[] = [
  { id: 0, label: 'Split (5-way)',         blurb: 'Default — equal split across AAVE, Euler, Rover, Galaxy, Gauntlet; diversifies curator risk.' },
  { id: 2, label: 'AAVE v4',               blurb: 'Aave-v4 spoke supply.' },
  { id: 3, label: 'Galaxy',                blurb: 'All-Galaxy (Morpho curator).' },
  { id: 4, label: 'ether.fi Rover',        blurb: 'ether.fi via the protocol weETH/WETH LP.' },
  { id: 5, label: 'Euler',                 blurb: 'Euler ETH (4626 curator, fungible w/ Galaxy).' },
  { id: 6, label: 'Gauntlet',              blurb: 'Gauntlet (second Morpho WETH 4626 curator, fungible w/ Galaxy).' },
]

// ── Leverage BORROW venues (task #65) — the external isolated-lending markets the
// YB overlay borrows a stable against your ETH collateral on. This is DISTINCT
// from ETH_VENUES above (which are the basket YIELD venues). Each entry is the
// LevManager venue-ADAPTER address, env-driven; entries whose address is unset or
// zero are filtered out (graceful pre-deploy, same handling as CONTRACTS). weETH
// venues pledge weETH (which keeps earning staking yield while it's collateral);
// the rest pledge plain WETH.
// NOTE: static `process.env.NEXT_PUBLIC_*` member access is REQUIRED — Next.js
// only inlines those at build; a dynamic `process.env[k]` is NOT replaced.
export interface LevVenue { id: number; label: string; address: string; collateral: 'WETH' | 'weETH'; blurb: string }
// ⚠️ SAME INERT-ENV PROBLEM AS `CONTRACTS` HAD, AND NOT YET FIXED THE SAME WAY. These read
// `process.env.NEXT_PUBLIC_LEV_VENUE_*`, which Expo never inlines, so every address is `undefined`
// and **`LEV_VENUES` is empty in the app today** — the UI correctly shows no lev venues rather
// than wrong ones. When lev venues are wired, give them the `setContracts` treatment (runtime
// injection) rather than restoring env reads that cannot work here.
const levVenue = (
  id: number, label: string, env: string | undefined,
  collateral: 'WETH' | 'weETH', blurb: string,
): LevVenue | null => {
  const address = isAddress(env) ? env : ZERO
  return address === ZERO ? null : { id, label, address, collateral, blurb }
}
export const LEV_VENUES: LevVenue[] = [
  levVenue(0, 'Morpho — weETH', process.env.NEXT_PUBLIC_LEV_VENUE_MORPHO_WEETH, 'weETH',
    'Morpho Blue isolated market; pledge weETH (keeps earning ether.fi staking yield as collateral).'),
  levVenue(1, 'Euler — weETH',  process.env.NEXT_PUBLIC_LEV_VENUE_EULER_WEETH,  'weETH',
    'Euler v2 isolated vault; pledge weETH.'),
  levVenue(2, 'Morpho — WETH',  process.env.NEXT_PUBLIC_LEV_VENUE_MORPHO_WETH,  'WETH',
    'Morpho Blue isolated market; pledge plain WETH.'),
  levVenue(3, 'Aave v4 — WETH', process.env.NEXT_PUBLIC_LEV_VENUE_AAVE_WETH,    'WETH',
    'Aave v4 spoke supply; pledge WETH.'),
  levVenue(4, 'Liquity — WETH', process.env.NEXT_PUBLIC_LEV_VENUE_LIQUITY_WETH, 'WETH',
    'Liquity v2 trove (debt is BOLD, face-value minted); pledge WETH.'),
].filter((v): v is LevVenue => v !== null)
