// Contract ABIs against SPV/evm/src/* (the merged-port contracts).
// Surface is intentionally trimmed: no Rover/V3, no Hook (predictions),
// no leverETH/leverUSD wait-path. Only what the SPA tabs call.

export const ERC20_ABI = [
  'function balanceOf(address owner) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
  'function name() view returns (string)',
  // For the flow subgraph-lite: net inflow/outflow is reconstructed from
  // Transfer logs to/from the protocol addresses (no on-chain flow events needed).
  'event Transfer(address indexed from, address indexed to, uint256 value)',
] as const

// Core = the range ENGINE (`rangeCore`; there is no Uniswap v4). Only the oracle ring is
// consumed here —
// observe() returns cumulative usd18 PRICE·seconds (it returned Uniswap-style
// tickCumulatives before the tick removal). `regime.decodeTwapLogPrices` differences them into
// TWAP prices and takes their natural log, which is the series the regime brain is
// calibrated on (tick units were dropped with the tick removal), from which it derives
// realized vol + trend (sub-spread chop /
// supra-spread oscillation / one-way trend).
export const CORE_ABI = [
  // §E63 — ONE dispatched observe. These were two entries differing only in which ring they
  // read, mirroring a duplication that also existed on-chain (two selectors, two dispatch
  // entries, one behaviour). Both sides now take the band as an argument.
  // (2026-08-15) Was `int56[] tickCumulatives`, inherited from Uniswap v3's observe. The tick
  // removal made the observation ring store PLAIN PRICES, so `Core.observe` now returns
  // `uint192[]`. Both are 32-byte words, so the old declaration did not revert — it decoded
  // each price as a signed 56-bit value, wrapping large prices into wrong and possibly
  // NEGATIVE numbers in the UI. Silent, which is why the ABI gate is the only thing that
  // catches it here: `spa/` has no node_modules, so `tsc` cannot run in this tree.
  // §E235 — THE `isBTC` ARGUMENT IS GONE, AND SO IS THE DISPATCH IT SELECTED. The isBTC split
  // made the range an INSTANCE (`Core` is the same bytecode deployed twice, `DeployLib.sol:139-140`),
  // so `Core.observe(uint32[])` (`Core.sol:1767`) reads its own ring and there is nothing left to
  // select. Call it on the ETH engine's address for ETH and the BTC engine's for BTC.
  'function observe(uint32[] secondsAgos) view returns (uint192[] prices)',
  // Internal pool state — the REAL committed-vs-backing + in-range fractions.
  'function committedUsd18() view returns (uint)',     // USD committed to the in-range pools
  // §E235 — ONE PAIR, NOT FOUR ACCESSORS. `POOLED_ETH`/`POOLED_BTC`/`POOLED_USD_ETH`/
  // `POOLED_USD_BTC` were four selectors on one contract; there is now exactly ONE `POOLED()` and
  // ONE `POOLED_USD()` per instance (`Core.sol:68,71`) and TWO instances. The range comes from
  // WHICH ADDRESS you call, never from a name suffix.
  // ⛔ The suffixed names are what took the SPA down before: they decode to nothing and the read
  // throws, or worse, answer off the wrong engine.
  'function POOLED() view returns (uint)',              // in-range volatile leg (this instance's asset)
  'function POOLED_USD() view returns (uint)',          // USD committed, this instance's pool
  // BTC LP is delivery/fee-driven (no continuous LVR). Proceeds settle EXACTLY at
  // on-chain swap-out delivery, so there's no global delivered/proceeds counter;
  // pendingSwapOutUsd = 6-dec USD of UNDELIVERED swap-out obligations — a live
  // "swap-out demand" gauge (and the swap-in solvency-gate denominator).
  'function pendingSwapOutUsd() view returns (uint)',   // 6-dec USD, undelivered swap-outs
] as const

// Basket = QU!D ERC20 + ERC6909 maturities. Only the SPA-relevant surface.
export const BASKET_ABI = [
  // ERC20
  'function balanceOf(address owner) view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function decimals() view returns (uint8)',
  // Mint entrypoint — `when` is the target maturity month (absolute, not delta)
  'function mint(address pledge, uint amount, address token, uint when) returns (uint normalized)',
  'function currentMonth() view returns (uint)',
  // ERC6909 — maturity-bucket balance for redemption gating
  'function balanceOf(address owner, uint256 id) view returns (uint256)',
  // Term-locked (immature) QD. Basket has NO totalMatureBalanceOf getter —
  // mature is derived client-side as balanceOf(owner) − immatureBalanceOf(owner).
  'function immatureBalanceOf(address owner) view returns (uint256)',
  // Redeemable-when schedule: per-maturity-month supply (protocol stickiness).
  // totalSupplies[m] = QD that unlocks at month m; immatureSupply = Σ future
  // buckets; redeemable-NOW = totalSupply − immatureSupply.
  'function totalSupplies(uint month) view returns (uint)',
  'function immatureSupply() view returns (uint)',
] as const

// Aux = orchestration hub. swap/redeem/metrics/btc-recipient checks live here.
export const AUX_ABI = [
  // Swap (5-arg shape):
  //   token        = input stable or QUID (or zero when paying volatile)
  //   asset        = WETH or WBTC — the volatile side. WBTC (BitGo) is the BTC
  //                  range's volatile/pricing leg and SOR inventory; it is
  //                  Aux-internal and never delivered to users (BTC payout is
  //                  native, via the hop). There is no separate "lnBTC" token.
  //   forVolatile  = true: stable→volatile  | false: volatile→stable
  //   amount       = input amount (in input-token units)
  //   minOut       = slippage floor (output-token units)
  'function swap(address token, address asset, bool forVolatile, uint amount, uint minOut) payable returns (uint max)',
  'function swapTo(address token, address asset, bool forVolatile, uint amount, uint minOut, address recipient) payable returns (uint max)',

  // Redeem QUID for USDC (+ ETH fallback for shortfall) at user's address.
  'function redeem(uint amount)',
  // Max redeemable RIGHT NOW (call via eth_call; not view due to lazy accrual reads).
  'function redeemableAmount() returns (uint)',

  // Pricing & metrics. There is NO ETH-only getTWAP convenience on Aux — the
  // ETH TWAP is getTWAPforAsset(WETH, period), the same accessor used for BTC.
  'function getTWAPforAsset(address asset, uint32 period) returns (uint)',
  'function get_metrics(bool force) returns (uint total, uint yield_)',
  // per-stable deposit amounts + yield weights (uint[13]: stables + aggregate slots),
  // basket avg yield, and the redemption depeg loss. DO NOT use uint[14]/3-tuple — the
  // contract returns uint[13] + a 4th `depegLoss`; a wrong arity misaligns the decode.
  'function get_deposits() returns (uint[15] amounts, uint[15] yieldW, uint avgYield, uint depegLoss)',
  'function avgYield() view returns (uint)',
  'function riskFactor(address token) view returns (uint)',
  // Stable↔stable swap (e.g. USDC→DAI) routed through the basket vaults.
  'function auxSwap(address tokenIn, address tokenOut, uint amountIn, address recipient, uint minOut) returns (uint amountOut)',
  // Protocol-total ETH currently in the ETH range (for the info tab).
  // ⛔ THE NAME IS `rangeETH`, NOT `vogueETH` — `Quid.sol:215`, forwarded by `Aux.sol:1035`.
  // Total BTC is BTCChannels.totalSatsLocked(); there is no Aux.rangeBTC().
  'function rangeETH() view returns (uint)',
  // The REAL over-collateralization read: committedSum vs totalLiquid (18-dec).
  // tryCheckBacking is the non-reverting variant (runs a repack; eth_call it).
  // Headroom = (totalLiquid − committedSum) / totalLiquid — the actual "buffer".
  'function tryCheckBacking() returns (uint committedSum, uint totalLiquid)',

  // Stable bookkeeping (helpers for the mint tab)
  'function getStables() external view returns (address[])',

  // Deposit (stable → QUID via Basket.mint usually; Aux.deposit is the
  // protocol-internal entry — exposed here for read/debug only)
  'function deposit(address from, address token, uint amount) returns (uint usd)',

  // References. `WBTC()` returns the single BTC ERC20 (BitGo WBTC) — the BTC
  // range's volatile/pricing leg. No distinct "lnBTC" token exists.
  'function WETH() view returns (address)',
  'function WBTC() view returns (address)',
] as const

// `Quid` = the ETH range manager (`evm/src/Quid.sol:38`). ONE LP mode reaches this file:
//   • Auto-managed — ERC4626-shaped; one shared single-sided vault per pool,
//     pro-rata fee accumulators. owner==msg.sender enforced (AllowanceFlow).
// §OOR-BOOK-DELETED (2026-08-29) — there WAS a second, "self-managed": per-position and
// NFT-like, `outOfRange` opening at a user-chosen range and `pull` withdrawing by
// id+percent+token, behind a 47-block timelock. **It is gone from the contracts.** Its successor
// is a signed EIP-712 intent, `Quid.fillIntent` (`Quid.sol:1246`), which costs nothing on chain
// until it fills — a wallet SIGNING flow, not a transaction. ⚠️ DO NOT ADD A `fillIntent`
// DECLARATION UNTIL THAT SIGNING FLOW EXISTS; an encoder with no caller is the
// §E154-client-ghosts shape.
// The "BTC path" goes through BTCChannels.openChannel, not a depositBTC on this contract.
export const RANGE_ABI = [
  // Auto-managed (ERC4626 shape on the ETH side).
  // ⛔ THERE IS NO VENUE ARGUMENT AND NO VENUE ENUM. This comment used to read "the ETH
  // yield-VENUE rides each deposit call: 0=Split(Galaxy+AAVE,default) 1=ether.fi 2=AAVE-v4
  // 3=Galaxy 4=ether.fi Rover 5=Euler". **None of those codes exist** — `evm/src` has no
  // `VENUE_*` constant, no `Rover`, and no `setEthVenue`/`setWithdrawInstant`. §ETHVENUE-FOLD
  // collapsed the axis: every ETH deposit's WETH goes to ONE destination, ether.fi weETH
  // (`imports/QuidLib.sol:109-113`), and a zero placement reverts `VenueUnavailable`. The two
  // declarations below were already correct at 2 args; only the prose was stale — the dangerous
  // direction, since a reader who trusted it would add a third argument and every deposit reverts.
  // See `spec.md §4.1`.
  'function deposit(uint assets, address receiver) payable returns (uint shares)',
  'function mint(uint shares, address receiver) payable returns (uint assets)',
  'function withdraw(uint assets, address receiver, address owner) returns (uint shares)',
  'function redeem(uint shares, address receiver, address owner) returns (uint assets)',
  // Auto-getter for `mapping(address => Types.Deposit)`. Types.Deposit field
  // order is (pooled, usd_owed, fees_tok, fees_usd) — fees_tok is the token-side
  // fee leg (ETH for the ETH pool, BTC for the BTC pool). DO NOT reorder.
  'function autoManaged(address user) view returns (uint pooled, uint usd_owed, uint fees_tok, uint fees_usd)',
  // §E235 — `autoManagedBTC` AND `lpSharesBTC` WERE DELETED, NOT RENAMED. Both range managers
  // declare the SAME names on DIFFERENT addresses (`Quid.sol` for ETH, `Vault.sol` for BTC), so
  // the BTC reads stop being separate selectors and become the ETH ones called on the vault's
  // address. Declaring the suffixed forms made every BTC read answer off the ETH engine — a live
  // call, a plausible number, the wrong range.
  'function totalShares() view returns (uint)',
  'function lpShares() view returns (uint)',
  // §OOR-BOOK-DELETED (2026-08-29) — `outOfRange`, `pull`, `positions` and `selfManaged` were
  // declared here and are GONE from the contracts. `outOfRange` was doubly wrong: the declaration
  // said 4 args while `encode.ts` passed 5 (a `venue` that never existed), so the encoder threw
  // before it could even reach a nonexistent selector.
  'function feesPerShare() view returns (uint)',

  // Events — LP flow (consumed by the net-flow reconstruction)
  'event Deposit(address indexed sender, address indexed owner, uint assets, uint shares)',
  'event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint assets, uint shares)',
] as const

// BTCChannels — the channel registry. lpEth = recovered signer of lpAuth.
// OpenParams struct shape (must match the CURRENT Types.OpenParams — taproot
// channels are folded into the default build, so there is a 7th `fundingTaproot`
// field; the channel is a funding/close anchor only, disputes are Bitcoin-native):
//   bytes32 fundingBlockHash
//   uint64  fundingBlockHeight
//   uint    fundingTxIndex
//   bytes   lpPubkey            // 33-byte compressed secp256k1
//   bytes   hopPubkey           // 33-byte hop LDK funding pubkey (snapshot at open)
//   uint    amountSats          // LP's locked sats == BTC pool-backing position
//   bytes32 fundingTaproot      // 32-byte x-only MuSig2 key-path aggregate Q
export const BTCCHANNELS_ABI = [
  // openChannel takes lpAuth: the LP signs openChannelDigest(p, rawFundingTx, hop)
  // with the EVM key that should OWN the channel + pool position. `hop` is the EVM
  // address that will SUBMIT the open (msg.sender), bound into the digest so a
  // valid lpAuth can't be replayed through a different submitter (multi-hop open —
  // there is no longer a single global hopNode; whoever submits becomes THIS
  // channel's hop). The recovered signer (not msg.sender) becomes lpEth. Compute
  // the digest on-chain via openChannelDigest so the client signs exactly what the
  // contract checks. OpenParams: 7 fields incl. hopPubkey + fundingTaproot.
  'function openChannelDigest(tuple(bytes32 fundingBlockHash, uint64 fundingBlockHeight, uint fundingTxIndex, bytes lpPubkey, bytes hopPubkey, uint amountSats, bytes32 fundingTaproot) p, bytes rawFundingTx, address hop) view returns (bytes32)',
  // openChannel takes lpBtcPayoutHash (5th arg) and is HOP-ONLY submit (§9b spoof
  // fix) — the hop relays it, not the user's wallet (full hop-mediated flow = task #8).
  // Close folded into ONE entrypoint: recordClose branches on the tx locktime
  // (cooperative vs unilateral-refund). forceCloseByLP/recordForceClose are GONE.
  // (E153) recordClose is PERMISSIONLESS and now takes OpenParams: it reconstructs the
  // channel's 2-of-2 from lpPubkey/hopPubkey (checked against the keysHash pinned at open)
  // to tell a SPLICE from a CLOSE. Only those two fields are read; the rest may be zero.
  'function recordClose(bytes32 channelId, tuple(bytes32 fundingBlockHash, uint64 fundingBlockHeight, uint fundingTxIndex, bytes lpPubkey, bytes hopPubkey, uint amountSats, bytes32 fundingTaproot) p, bytes rawCloseTx, bytes32 closeBlockHash, bytes32[] merkleProof, uint txIndex)',
  // (E154) There is NO `recordSpliceOut`. It was declared here but has never existed on any
  // contract in recorded history — LP partial withdrawal is served by `splice`, which resizes the
  // position against the same SPV proof. The checker could not see it: an unmatched NAME was
  // skipped as "not ours", so the worst drift (function absent entirely) was the invisible kind.
  // USD→BTC swap-OUT. NOTE: the current contract exposes ONE swap-out entrypoint,
  // the on-chain rail below (`requestSwapOutOnchain`). The former separate Lightning
  // `requestSwapOut(...BOLT11 invoice...)` function was REMOVED — a swapper who wants
  // LN delivery is served by the hop off-chain against the same on-chain request /
  // the swap-in reversal path (settleSwapIn), so there is no distinct BOLT11 EVM call.
  // On-chain swap-out for a user who has a Bitcoin ADDRESS (or an LN swapper the hop
  // fills off-chain). The hop delivers via a splice-out paying `swapperScript` (the
  // address as a 22–34 byte scriptPubKey). swapId = caller-chosen unique dedup key.
  'function requestSwapOutOnchain(address token, uint usdAmount, uint minSats, bytes32 swapId) returns (uint sats)',

  // Set the BTC recipient (P2WPKH pubkey hash) for swap-out routing.
  'function setBtcRecipient(bytes32 xOnlyKey, bytes pop)',
  'function btcRecipientOf(address user) view returns (bytes32)',

  // Hop info — protocol-published. Both hopBitcoinPubkey() (d5e7783) AND the global
  // hopNode() getter are REMOVED: the hop pubkey is an OpenParams field (p.hopPubkey,
  // node-supplied at open) and there is no single global hop — each channel binds its
  // own opening hop (channels().hop). LDK rotates funding keys per channel + splice.
  'function totalSatsLocked() view returns (uint)',
  // (E164) `openChannelsOf` is GONE. It gated `settleSwapIn`/`markMigrationNonceUsed` on
  // "owns an open channel = has real BTC locked" — a proxy for "is a genuine hop" that a
  // two-address check makes redundant. It was declared here and never called.

  // Channel state (storage getter) — CURRENT BTCChannel struct (field order:
  // amountSats, fundingTxId, lpEth, fundingVout, status, hop). `selfRefundTime` was
  // removed (standard-LDK cut, no CLTV self-refund); `hop` is this channel's opening
  // hop (multi-hop). Decode by POSITION: status is index 4, hop is index 5.
  // (E153) `keysHash` = keccak256(lpPubkey, hopPubkey), pinned at open. It binds the keys
  // independently of the funding outpoint, which a splice rotates.
  // (E164) `hop` removed: authority is the immutable MAIN_HOP/FALLBACK_HOP pair, not
  // per-channel state. Which of the two opened a channel survives in ChannelOpened.
  // (§FORCE-CLOSE-SKIPS-THE-STALE-GUARD) `lpToRemoteKey` is the LP's `to_remote` taproot output
  // key, derived at open from its Lightning payment basepoint. A force-close commitment's LP output
  // is `0x5120 || lpToRemoteKey`, which is how the contract measures what that close actually paid.
  // 🔴 **THIS DECLARATION WAS SIX WORDS UNTIL 2026-09-09 AND THE CONTRACT HAS RETURNED SEVEN
  // SINCE `lpToRemoteKey` LANDED.** `spa/src/lib/abi.ts` was updated; this file was not, and nothing
  // noticed for the reason §T9 keeps rediscovering: `tools/check-client-abis.py` hardcodes the
  // `spa/` path and has never read `app/` at all, so this fork drifts un-gated. It survived only
  // because ethers tolerates trailing return data — a decode that ignores a word it does not know
  // about is right up until the day a field is INSERTED rather than appended.
  'function channels(bytes32 channelId) view returns (uint amountSats, bytes32 fundingTxId, address lpEth, uint32 fundingVout, uint8 status, bytes32 keysHash, bytes32 lpToRemoteKey)',

  // (§T2) The fleet's PINNED swap-in deposit internal key, `immutable` on `BTCChannels`
  // (`BTCChannels.sol:820`) and the value `_provenDeposit` derives every settle's address from.
  // 🔑 **THIS IS WHAT MAKES `verifyQuotedDepositAddress` EXECUTABLE.** That verifier needs an
  // `internalX` that the hop does not supply, or it proves only that the hop is self-consistent.
  // Reading it here means the one input the wallet cannot own comes from the CHAIN instead — the
  // same place the settle path reads it — so a hop running unknown code still cannot quote an
  // address that survives the check.
  'function BTC_DEPOSIT_KEY() view returns (bytes32)',

  // SELF_REFUND_MIN_SECS / MIN_CONFIRMATIONS are `uint constant` (no `public`),
  // so they have NO on-chain getter — not callable, intentionally omitted.

  // Events. ChannelOpened gained a 3rd INDEXED arg `address indexed hop` (multi-hop:
  // watchers topic-filter their own channels), so lpEth stays at topics[2], hop is
  // topics[3], and the topic0 signature is now
  //   ChannelOpened(bytes32,address,address,uint256,bytes,bytes,bytes32,uint32,bytes32,uint64)
  'event ChannelOpened(bytes32 indexed channelId, address indexed lpEth, address indexed hop, uint sats, bytes lpPubkey, bytes hopPubkey, bytes32 fundingTxId, uint32 fundingVout, bytes32 fundingBlockHash, uint64 fundingBlockHeight)',
  'event ChannelClosed(bytes32 indexed channelId, uint satsReturned)',
] as const

// LevManager — the opt-in YB leverage overlay (task #19/#25). One ISOLATED
// position per LP on an external venue (Euler/Morpho): the LP supplies equity
// (weETH/WETH); a keeper borrows a stable and re-buys ETH as the band SELLS on a
// rally, cancelling that IL up to the LP's chosen cap. On a FALL the target LTV
// goes to 0 (it de-levers) so the LP is never levered into a crash. The SPA reads
// these to render the plain "how's my cushion" card — none of the bps are the
// headline; they live only in the collapsed advanced detail.
//   NOTE: getCurrentLtvBps/ilTargetLtvBps/netEquityUsd are NOT `view` (they read
//   the mutating getTWAPforAsset oracle ring), but eth_call executes them and
//   returns the value without persisting, so readOne() reads them fine.
export const LEV_MANAGER_ABI = [
  // pos(address) public mapping getter — Pos is a stable 6-tuple.
  'function pos(address lp) view returns (address venue, uint64 targetLtvCapBps, uint128 entryPriceWad, uint128 e0Eth, uint160 entrySqrtP, bool open)',
  'function getCurrentLtvBps(address lp) returns (uint256)',   // venue-safety LTV (debt / actual collateral), bps
  'function ilTargetLtvBps(address lp) returns (uint256)',     // IL-cancelling target (band's sold fraction, capped), bps
  'function netEquityUsd(address lp) returns (uint256)',       // collateral − debt, USD 1e18
  'function debtUsd(address lp) view returns (uint256)',       // outstanding debt, USD 1e18
  'function grossCollateralEth(address lp) view returns (uint256)', // gross collateral, ETH 1e18
  'function netEquity(address lp) view returns (uint256)',          // net equity, ETH 1e18
  'function TARGET_LTV_CAP_BPS() view returns (uint256)',      // hard leverage cap (bps LTV)
  // ── WRITE (the #65 leverage-choice txs). openLev opens a position at ZERO leverage on the chosen borrow venue
  //    with `collWeeth` of the venue's collateral (weETH or WETH) already approved+pulled; the keeper then levers
  //    it to the LP's cap as the band sells. setTargetLtv picks the leverage level (≤ TARGET_LTV_CAP_BPS; 5000 =
  //    2× IL-neutral, higher = opt-in directional). closeLev fully unwinds (short first, then long) back to the LP.
  'function openLev(uint64 targetLtvBps, address venue, uint256 collWeeth, uint256[] minWethOut)',
  'function setTargetLtv(uint64 capBps)',
  'function closeLev(uint256 minOut)',
] as const

// The per-LP borrow venue adapter (Euler/Morpho) — only the risk-param the SPA
// needs for the liquidation-buffer read. venue = pos(lp).venue.
export const LEV_VENUE_ABI = [
  'function liqThresholdBps() view returns (uint256)',  // venue LLTV in bps (8000 = 80%)
] as const
