
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vogue} from "./Vogue.sol";
import {Basket} from "./Basket.sol";

import {Core} from "./Core.sol";
import {FeeLib} from "./imports/FeeLib.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {ChannelLib} from "./imports/ChannelLib.sol";
import {ISwap} from "./imports/ISwap.sol";
import {SwapLib} from "./imports/SwapLib.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

import {IAaveV4Spoke, IAaveV4Hub, ICollection, IEthVenue, IBandManager, IBTCChannels} from "./imports/Interfaces.sol";


/// AAVE-v4 GHO spoke. Aux self-supplies via the self-allow trampoline.

/// EthVenue — the ETH yield-venue custody (AAVE-v4 WETH + ether.fi weETH). Aux keeps thin
/// forwarders (vogueETH) for callers that must not change target (BasketLib IAux read, Core),
/// and owns the vault-health state for the basket's stable 4626s.

// Deploy-finalize helpers (see Aux.finalize; linkage asserts live in BasketLib.assertFullyWired).

// (ether.fi interfaces moved to EthVenue with the venue custody; the
//  Chainlink IAggregatorV3 anchor interface moved to SwapLib with twapAnchorBody.)
contract Aux is // Auxiliary
    Ownable, ReentrancyGuard, ISwap {
    address[] public stables;

    // Immutable handles. USDC is stables[0] by convention; anywhere
    // code needs the USDC address (ERC-3009, _ensureUSDC) it reads
    // stables[0].
    Vogue internal immutable VOGUE;
    Core internal immutable CORE;
    /// §ISBTC-SPLIT — the BTC band INSTANCE. `CORE` is the ETH band; both are constructed in
    /// `DeployLib` and registered with the same `BandBacking`. Aux needs the handle because the
    /// skew is now read FROM the instance rather than selected by a flag passed alongside one
    /// address: without it, a WBTC quote would silently be priced by the ETH band's inventory —
    /// a plausible number for the wrong band, which is the failure mode that announces nothing.
    Core internal immutable BTC_CORE;
    /// §ISBTC-SPLIT — ASSET → BAND INSTANCE. Every read path needs to reach the band that owns the
    /// inventory and the oracle ring for `asset`. Doing that with `asset == address(WBTC) ? … : …`
    /// is the hand-rolled dispatch this refactor removes, moved one level up: a literal comparison
    /// re-decided on every quote. The pairing is a WIRING fact, so it is stated ONCE here, at
    /// construction, and every call site is a lookup. Adding a third band is then a wiring change,
    /// not an edit to every read.
    // §BANDOF-DELETE — was `mapping(address => Core) bandOf`, a mapping with exactly TWO entries,
    // written once at construction, in a contract that ALREADY holds both values as immutables
    // (`CORE`, `BTC_CORE`). A storage slot, two SSTOREs at deploy and an SLOAD on every price read,
    // to answer a question two immutable comparisons answer for free. `_bandOf` below replaces it.
    WETH9 public immutable WETH;
    IERC20 public immutable WBTC;
    // §V4-ZERO — the inherited `poolManager` immutable is GONE with `SafeCallback`. Nothing in this
    // tree unlocks a PoolManager, so the base class was holding an address for a call that never
    // happens.

    // QUID (Basket) is set in setQuid after Basket itself is deployed —
    // can't be immutable (circular construction). Pinned-after-set
    // via the QuidPinned guard.
    Basket internal QUID;

    BasketLib.Metrics internal metrics;

    ChannelLib.SPState internal sp;

    // _vogueETHPrincipal + the ETH-venue (AAVE/ether.fi) custody moved
    // to EthVenue (the venue carve). `ethVenue` is pinned once below.

    /// @notice Accumulator of WBTC ERC20 (BitGo) held by Aux on behalf
    ///         of Vogue's BTC LPs — the V4 BTC pool's reserve buffer.
    ///         NOT to be confused with the native-BTC sats locked in
    ///         BTCChannels' 2-of-2 key-path P2TR outputs; those are tracked
    ///         independently in `BTCChannels.totalSatsLocked` and the
    ///         per-channel `lpAmountSats` / `hopAmountSats` fields.
    ///         The two systems share a 1e8 scale (sats ≈ WBTC sub-unit)
    ///         but operate over disjoint pools of assets.
    uint public vogueBTC;

    mapping(address => uint) public tranche;
    mapping(address => address) public vaults;
    mapping(address => address) public tokens;
    mapping(address => uint) public toIndex;

    // Multi-venue: the SET of 4626 vaults a stable may be split across.
    // `vaults[stable]` remains the primary (== vaultsOf[stable][0]); the
    // set is what _supply/_withdraw/_take iterate over for the per-vault
    // (inner) pro-rata dimension. Each entry is self-validated by
    // asset()==stable in setVault. Cap bounds the inner loop.
    mapping(address => address[]) public vaultsOf;

    uint public trancheTotal;

    /// @notice AAVE v4 wiring — GHO + USDG. Both are first-class assets
    ///         on the AAVE v4 spoke (which also lists WETH — see WETH_RESERVE_ID,
    ///         ETH venue 2); reserve IDs cached at deploy.
    ///         Aux supplies on its own behalf — supply(reserveId, amount,
    ///         address(this)) — same direct pattern as the original.
    address public immutable GHO;
    address public immutable USDG;
    address public immutable AAVE_SPOKE;
    address public immutable AAVE_HUB;
    uint256 public immutable GHO_RESERVE_ID;
    uint256 public immutable USDG_RESERVE_ID;

    /// @notice Generalized AAVE-v4 reserve-id per stable, for the DUAL-VENUE
    ///         stables (USDC/USDT) whose Aave spoke is one MEMBER of vaultsOf
    ///         alongside their 4626 curators. GHO/USDG keep their immutable
    ///         GHO_RESERVE_ID / USDG_RESERVE_ID (resolved at construction).
    ///         Wired in setVault when the spoke is added to a stable's set.
    mapping(address => uint256) public aaveReserveId;
    // WETH_RESERVE_ID (AAVE-v4 WETH / ETH venue 2) moved to EthVenue.

    // ─── Depeg boundary (THE single in/out signal) ───────────────────
    //
    // `riskFactor(token)` is the ONE depeg boundary, consumed identically by
    // deposit (B), redemption (C), and get_deposits:
    //   riskFactor <  10000  ⟺  IN a depeg (the stable's feed is below peg by
    //                            more than the deadband)
    //   riskFactor == 10000  ⟺  OUT (no discount anywhere)
    //
    // Severity is sourced ON-CHAIN from the per-stable Chainlink feed via
    // `getDepegSeverityBps` below (→ FeeLib.liveDepegBps). The off-chain Chainlink
    // CRE that once pushed this signal was REMOVED — the pinned feeds ARE the
    // signal now (downside-only, deadbanded, defers on a stale/dead feed). No
    // governance override and no hysteresis state: each read reflects the live
    // price, so the boundary tracks the current peg directly.

    // Per-stable live USD price feed (Chainlink), pinned at deploy (10 of 11 basket
    // stables; only BOLD has none — it doesn't market-depeg). PIN-ONCE (an owner
    // can't later repoint a stable at a hostile feed). Read by getDepegSeverityBps.
    mapping(address => address) public stableFeed;
    // 27h = a 24h Chainlink stable-feed heartbeat + 3h slack, so a healthy feed
    // isn't spuriously marked stale right before its heartbeat refresh (which would
    // briefly drop the live depeg backstop). Asset anchors (ETH/USD, BTC/USD) update
    // far more often, so this ceiling never constrains them; a truly dark feed still
    // defers safely (liveDepegBps/twapAnchorBody return 0 past the ceiling).
    uint public constant STABLE_FEED_MAX_AGE = 27 hours;
    // Asset anchors (ETH/USD, BTC/USD) heartbeat far faster than stables (~1h on
    // mainnet, plus deviation-triggered updates), so they get a much TIGHTER
    // freshness ceiling than the 27h stable-coin heartbeat. Reusing the 27h stable
    // age for assets let a frozen ETH/BTC feed be accepted as "fresh" for over a
    // day (bounded impact: swap mispricing / LP-position sizing during a multi-hour
    // freeze — never an over-mint, since QUI mints are oracle-free and committed USD
    // is capped at real stable TVL). 4h = generous margin over the ~1h heartbeat
    // (tolerates brief hiccups) while bounding asset-valuation staleness. A truly
    // dark feed past this still DEFERS safely to the internal TWAP.
    uint public constant ASSET_FEED_MAX_AGE = 4 hours;
    error FeedPinned();

    function setStableFeed(address token, address feed) external onlyOwner {
        if (stableFeed[token] != address(0)) revert FeedPinned();
        stableFeed[token] = feed;
    }

    // NOTE: no post-renounce feed-binding hook. Every basket stable that can depeg
    // already has its Chainlink feed pinned at deploy (10 of 11, incl. the proxy-only
    // RLUSD/USDG/AUSD resolved via data.eth ENS). The only unpinned stable is BOLD,
    // which doesn't market-depeg (Liquity redemption floor) — so there is nothing a
    // post-renounce binder would ever usefully wire, and the basket set is frozen at
    // deploy (no new stables can appear). A permissionless binder was considered and
    // removed as dead weight + needless surface.

    // Per-asset EXTERNAL price feed (Chainlink ETH/USD, WBTC/USD) that
    // anchors the internal observation-ring TWAP. The internal TWAP feeds
    // mint/redeem/arb/swap valuation; a multi-block grind moves the pool's spot
    // AND its own TWAP together, so a spot-vs-own-TWAP guard can't see it — but it
    // CAN'T move Chainlink. getTWAPforAsset cross-checks the two and reverts if
    // they diverge beyond TWAP_MAX_DEVIATION_BPS. OPT-IN per asset (unset → no
    // check, behavior unchanged) + PIN-ONCE + a stale feed DEFERS (anchor
    // unavailable → fall back to the internal TWAP, never bricks on a dead feed).
    mapping(address => address) public assetPriceFeed;
    uint public constant TWAP_MAX_DEVIATION_BPS = 500; // 5% = manipulation territory

    function setAssetFeed(address asset, address feed) external onlyOwner {
        if (assetPriceFeed[asset] != address(0)) revert FeedPinned();
        assetPriceFeed[asset] = feed;
    }

    function riskFactor(address token) public view returns (uint) {
        return FeeLib.riskFactor(token, address(this));
    }

    /// @notice Depeg severity (bps below peg) for `token`, sourced from its pinned
    ///         Chainlink feed. 0 = healthy / no feed / stale / within deadband. This
    ///         IS the depeg signal (the off-chain CRE was removed); `riskFactor`,
    ///         the FeeLib fee model, and the swap/redeem libs all read it here by
    ///         calling `getDepegSeverityBps` on Aux (the address they're handed).
    function getDepegSeverityBps(address token) public view returns (uint) {
        address feed = stableFeed[token];
        return feed == address(0) ? 0 : FeeLib.liveDepegBps(feed, STABLE_FEED_MAX_AGE);
    }


    // §E233-sor — the `_pathEncodings` doc block stood here, describing state that is deleted.
    // `SorPath` was its element type and died with `SOR.sol`; nothing replaced either, because the
    // array had no reader outside the three SOR bodies.

    error LengthMismatch();
    error Unauthorized();
    error QuidPinned();
    error BadAsset();
    error NoBtcRecipient();
    error NotSelf();
    error OverCommitted();
    error BtcChannelsPinned();
    error BtcInflowsViaChannels();
    error GHONotOnAAVE();
    // §SLOP — `BadV4Terminal`, `BadV4SourceVault`, `BadV4Last` DELETED: all three were SOR's
    // path-VALIDATION errors (`git log -S` traces them to the v4-cut commits `4d1256fa`/`22c67108`),
    // and with `SOR.sol` gone none can be reverted. Zero reverts each, verified comments-stripped.
    error GHOIsAaveWired();
    error UnknownStable();
    // Body extracted to a private function (deployed ONCE) so the 13 onlyUs sites carry a cheap CALL
    // instead of inlining the 5-address comparison chain each — reclaims ~1 KB of Aux EIP-170 headroom.
    function _requireUs() private view {
        if (msg.sender != address(VOGUE)
         && msg.sender != address(CORE)
         && msg.sender != address(BTC_CORE)  // §ISBTC-SPLIT — THE BTC BAND IS A SECOND ADDRESS NOW.
                                             // `Core._settleUsdSide` calls `AUX.take` (onlyUs) to pay
                                             // the USD leg, and `Core.swap` calls `btcShortfall`
                                             // (onlyUs); with only the ETH instance listed, BOTH
                                             // reverted for the BTC band -- it could not pay out or
                                             // signal. Note the warning already written below about
                                             // the venue carve: "true only while they WERE one
                                             // address". The same thing happened again one level up
                                             // when Core itself became two instances.
         && msg.sender != address(QUID)
         && msg.sender != ethVenue          // ETH-venue custody: it delegatecalls into
                                             // SwapLib/VaultLib with address(this)==EthVenue,
                                             // so its auxSwap callback arrives as msg.sender
                                             // ==EthVenue. Without this the basket→WETH arb
                                             // and the Vogue/Core shortfall fills silently
                                             // revert→catch→0.
         && msg.sender != CORE.btcVault()   // BTC band manager: same delegatecall shape on the
                                             // BTC side (BtcVaultLib/SwapLib run as the Vault).
                                             // ⚠️ TWO ENTRIES, NOT ONE, SINCE THE VENUE CARVE —
                                             // this used to read "one address (ethVenue) covers
                                             // ETH and BTC arb", true only while they WERE one
                                             // address. Read from Core so there is no second pin.
         && msg.sender != address(this))
            revert Unauthorized();
    }
    modifier onlyUs { _requireUs(); _; }

    /// @notice V4 unlock callback. Walks UnlockData.keys hop-by-hop.
    // §V4-ZERO — `_unlockCallback` DELETED with the `SafeCallback` base. It existed so a v4
    // PoolManager could call back into Aux mid-unlock to settle/take. Nothing unlocks a PoolManager
    // here, so the override was an entrypoint for a caller that does not exist. The v4 hop routing it
    // forwarded to (`SOR.unlockBody`) goes with the 1inch replacement.

    /// @notice init (plug) Aux with addresses
    /// @param _vogue       Vogue contract (V4 LP wrapper)
    /// @notice Constructor. Pins Vogue/Core/V4 wiring + GHO/AAVE-v4 venue.
    /// Constraints: stables[0] must be USDC (ERC-3009 source). WBTC is
    /// transient only (single-tx legs, never inventory; native BTC backs
    /// `vogueBTC` via BTCChannels). GHO's vault slot is 0 (goes through
    /// AAVE-v4 spoke, not a 4626 curator). _paths are SOR encodings; set
    /// once, iterated at runtime by auxSwap.
    /// @dev Constructor wiring bundled into one struct. Twelve flat
    /// params decode into twelve stack slots — one slot too deep for the
    /// legacy (non-via_ir) codegen. A single `memory` struct decodes as
    /// one pointer, so the arg-decode stays shallow. Fields mirror the
    /// former positional params 1:1.
    struct AuxInit {
        address vogue;
        address core;
        address btcCore;
        address weth;
        address wbtc;
        address gho;
        address usdg;
        address aaveSpoke;
        address aaveHub;
        address[] stables;
        address[] vaults;
    }

    constructor(AuxInit memory a)
        Ownable(msg.sender)
        {
        WETH = WETH9(payable(a.weth));
        if (a.wbtc != address(0)) WBTC = IERC20(a.wbtc);

        VOGUE = Vogue(payable(a.vogue));
        CORE = Core(a.core);
        BTC_CORE = Core(a.btcCore);
        // §ISBTC-SPLIT: state the asset→band pairing ONCE, here, where the wiring is already known.
        // `a.wbtc` is optional (guarded above), so the BTC row is only written when there IS a BTC
        // asset — an unwired asset then resolves to address(0) and the read reverts LOUDLY rather
        // than silently answering from the wrong band, which is the failure this replaces.

        // GHO + USDG + WETH AAVE wiring. All are first-class assets on the
        // AAVE v4 spoke; reserve ids are deterministic per (hub, asset),
        // so we resolve and cache them once at construction. Reverting if
        // either asset isn't listed catches misconfiguration at deploy
        // rather than at first use.
        GHO = a.gho;
        USDG = a.usdg;
        AAVE_SPOKE = a.aaveSpoke;
        AAVE_HUB = a.aaveHub;
        if (a.aaveSpoke != address(0) && a.aaveHub != address(0)) {
            if (a.gho != address(0)) {
                uint256 ghoAssetId = IAaveV4Hub(a.aaveHub).getAssetId(a.gho);
                GHO_RESERVE_ID = IAaveV4Spoke(a.aaveSpoke).getReserveId(a.aaveHub, ghoAssetId);
                if (GHO_RESERVE_ID == 0) revert GHONotOnAAVE();
                IERC20(a.gho).approve(a.aaveSpoke, type(uint).max);
            }
            if (a.usdg != address(0)) {
                uint256 usdgAssetId = IAaveV4Hub(a.aaveHub).getAssetId(a.usdg);
                USDG_RESERVE_ID = IAaveV4Spoke(a.aaveSpoke).getReserveId(a.aaveHub, usdgAssetId);
                if (USDG_RESERVE_ID == 0) revert GHONotOnAAVE();
                IERC20(a.usdg).approve(a.aaveSpoke, type(uint).max);
            }
        }
        // Else: testnet / fork without AAVE — the _supply / _withdraw
        // branches reject AAVE-routed supplies if wiring is incomplete.
        // (AAVE-v4 WETH / ETH venue 2 wiring moved to EthVenue.)

        if (a.stables.length != a.vaults.length) revert LengthMismatch();
        sp.spLastUpdate = block.timestamp; stables = a.stables;
        metrics.last = 1;
        metrics.trackingStart = block.timestamp;
        // Storage-writing wiring loops extracted to ChannelLib.initVaultsBody
        // (delegatecall works from a constructor; runs in Aux's storage context).
        // Writes toIndex/tokens/vaults/vaultsOf. §E233-sor: the SOR path copy is gone with
        // `_pathEncodings` -- three parameters narrower, because nothing reads them any more.
        // selector-encoded approve (tolerates USDT-style no-returndata) preserved.
        ChannelLib.initVaultsBody(
            a.stables, a.vaults, toIndex, tokens, vaults, vaultsOf);
        // ETH venue wiring (approvals, weETH cache) moved to EthVenue, which
        // now custodies the ETH-side positions.
    } receive() external payable {}

    // ─── CRE vault-health watcher (the "dollars are there" venue check) ──
    // Per-VENUE state (distinct from the per-TOKEN depeg signal in Link),
    // BINARY (mirrors the depeg model): an incident BLOCKS the vault (valued at
    // maxWithdraw, no new deposits routed) and the permissionless poke
    // auto-recovers it when liquid again; serious → evacuate (below). The
    // former graded haircut was the dead CRE-onReport vestige — removed.
    mapping(address => BasketLib.VaultHealth) public vaultHealth;

    function vaultBlocked(address vault) external view returns (bool) {
        return vaultHealth[vault].blocked;
    }
    // (S1) vaultHealthHaircutBps / vaultFlaggedAt getters removed — dead
    // duplicates of the auto-generated `vaultHealth(vault)` tuple; relieves the
    // Aux EIP-170 ceiling.

    // ─── Stored-holdings cache ──────────────────────────────────────────
    // Per-stable cached value of the EXPENSIVE vault-sum (BasketLib._valueStable
    // = Σ convertToAssets/aaveBalance over the stable's venues, decimal-scaled).
    // Recomputed for the ONE mutated stable on a balance change, summed from
    // storage on reads — moving the external-call cost off the hot read path
    // (every swap/mint/redeem/checkBacking/LP-op calls get_deposits). The CHEAP
    // per-read adjustments (tranche subtraction, depeg discount) stay LIVE.
    // READ FLIPPED (step 5 DONE): get_deposits now SERVES the vault-sum from this
    // cache (BasketLib.sol:205-207), not the old live convertToAssets loop — that's
    // the realized gas win. Maintained on every mutator (_refreshHoldings) + full-
    // refreshed at mint/redeem; the reconciliation invariant
    // `test_HoldingsCache_ReconcilesToLive` gates it (cache == live vault-sum after
    // any op), so a missed mutator surfaces as a test failure, not silent under-backing.
    mapping(address => BasketLib.Holding) public storedHoldings;

    /// @notice Thin wrappers; the bodies live in BasketLib (delegatecall →
    ///         address(this)==Aux, storage-ref mappings resolve to Aux's slots)
    ///         to keep Aux under EIP-170. Per-mutation refresh of one stable;
    ///         full refresh at mint/redeem.
    function _refreshHoldings(address stable) internal {
        BasketLib.refreshHoldingsBody(stable, storedHoldings, toIndex, stables.length);
    }
    /// @notice Wall-clock of the last FULL holdings refresh, and the maximum age a redeem will value
    ///         against. §A.5e: `redeemAsBody` values off the `storedHoldings` CACHE and the refresh ran
    ///         only AFTER it returned — order was value → draw → refresh — so a redeemer inside that
    ///         window valued against stale-HIGH backing and OVER-DREW, concentrating the loss on
    ///         remaining holders. Detection was never the gap (`pokeVaultHealth` reads live); the cache was.
    ///
    ///         ONE global marker, not a per-`Holding` timestamp: the redeem quote reads the AGGREGATE
    ///         (`amounts[14]`, accumulated from every stable in `get_deposits`), so freshness is an
    ///         all-or-nothing property of the whole basket and 12 extra slots would buy nothing.
    uint public holdingsRefreshedAt;
    uint internal constant HOLDINGS_MAX_STALE = 1 hours;

    function _refreshAllHoldings() internal {
        BasketLib.refreshAllHoldingsBody(storedHoldings, stables);
        holdingsRefreshedAt = block.timestamp;
    }

    /// @dev SYNCHRONOUS staleness guard for any path that VALUES against the cache. Refreshes in-line
    ///      when the cache is older than the bound, then proceeds — it does NOT revert, so there is no
    ///      liveness cliff: the redeem heals its own staleness. Cost is amortised, because the refresh
    ///      only fires when the bound is actually breached; scheduling `pokeVaultHealth` (§S39 GAP-1)
    ///      makes that rare, but is a COMPLEMENT and never a substitute — an async poke cannot close a
    ///      synchronous window (the user's §J.3 constraint).
    function _requireFreshHoldings() internal {
        if (block.timestamp - holdingsRefreshedAt > HOLDINGS_MAX_STALE) _refreshAllHoldings();
    }

    // Hardening: the irreversible, fund-MOVING evacuate is SPLIT from the
    // cheap, reversible block+haircut and DWELL-gated. A single report (even a
    // forged one from a compromised forwarder) can now only block + haircut and
    // START the evac clock — it can NOT instantly drain a vault's real balance
    // into others. The haircut already protects backing VALUATION immediately;
    // moving the funds is the part that needs a reaction window. The owner keeps
    // an un-dwelled emergency override for a genuine fast failure.
    uint public constant EVAC_DWELL = 30 minutes;
    // (flaggedAt now lives in vaultHealth[vault].flaggedAt — see VaultHealth.)

    /// @notice MANUAL vault-health override (owner-only). The automated CRE
    ///         `onReport` forwarder path was RETIRED — vault health is now driven
    ///         on-chain by the permissionless `pokeVaultHealth` (illiquidity tier)
    ///         plus this owner lever (attested haircut/block) and `evacuate`. No
    ///         off-chain forwarder, no `vaultWatcher` key to compromise.
    function setVaultHealth(address vault, bool blocked)
        external {
        require(msg.sender == owner(), "403");
        // Body extracted to BasketLib.setVaultHealthBody (delegatecall —
        // address(this) stays Aux, so the mapping-storage refs resolve to
        // Aux's own slots). Gate stays HERE. Manual block/unblock override
        // (the graded haircut was the dead CRE-onReport vestige — removed).
        BasketLib.setVaultHealthBody(vault, blocked, vaultHealth);
    }

    /// @notice PERMISSIONLESS on-chain vault-health trigger — the trust-minimized
    ///         replacement for the retired `onReport`. The illiquidity tier of cre/vaulthealth.Decide
    ///         reads ONLY on-chain ground truth (ERC4626 convertToAssets /
    ///         maxWithdraw), so it needs no off-chain quorum: anyone can replicate
    ///         it here and it can't lie. This RESOLVES the single-watcher-key
    ///         finding — a stuck/captured CRE forwarder can no longer prevent the
    ///         protective block+evacuate of a verifiably illiquid vault.
    ///         SAFETY: it can only TIGHTEN (block + dwell→evacuate when liquidity
    ///         is genuinely impaired); it NEVER unblocks or haircuts — unblocking
    ///         and the depeg/impairment haircut are separate paths now (unblock =
    ///         this poke's own auto-unblock once liquid, or owner setVaultHealth;
    ///         haircut = the on-chain live depeg feed). The 30-min cross-poke dwell
    ///         + the unfakeable liquidity read make a grief call impossible (the
    ///         worst it can do is rescue a truly illiquid vault).
    ///         Body extracted to BasketLib.pokeVaultHealthBody; permissionless
    ///         (no role gate) so the wrapper holds only the nonReentrant lock.
    function pokeVaultHealth(address vault) external nonReentrant {
        BasketLib.pokeVaultHealthBody(vault, _vaultHealthCfg(),
            vaultHealth, vaultsOf, tokens);
        _refreshHoldings(tokens[vault]); // cache: a poke may evacuate (tokens[v]==0 → no-op for ETH venues)
    }

    /// @dev Vault-health config from Aux immutables (the delegatecalled
    ///      library can't read them). Shared by poke / evacuate.
    function _vaultHealthCfg() internal view returns (BasketLib.VaultHealthCfg memory) {
        // The WETH-4626 curator venues were deleted 2026-08-14 (their VENUE_* selectors were already
        // gone, so no deposit could reach them), so the health path has no ETH branch left: every vault
        // it sees is a basket STABLE vault held by Aux. `ethVenue` is all the cfg still carries.
        return BasketLib.VaultHealthCfg({ ethVenue: ethVenue });
    }

    /// @notice EVACUATE a deteriorating vault into the healthy ones (the
    ///         security dividend of multi-venue): block it, pull the protocol's
    ///         balance, and **spread it EQUALLY** across the stable's other
    ///         available (unblocked) vaults — maximal diversification of the
    ///         recovery, not dumped into one. The incident vault stays blocked
    ///         (no deposits back) until the permissionless poke auto-unblocks
    ///         it once liquid again, or an owner setVaultHealth(vault, false)
    ///         pre-renounce recovery call (the depeg-style recovery,
    ///         conservative like depeg recovery). Best-effort: a frozen/illiquid
    ///         vault reverts the redeem → it stays blocked + haircut'd (loss
    ///         socialized) — catches SLOW failures; the haircut handles fast ones.
    /// @notice Owner-only emergency override (genuine fast failure). The
    ///         automated evac runs through pokeVaultHealth's dwell-gated path
    ///         above (permissionless), so this owner-only call is the un-dwelled
    ///         manual escape hatch, not the routine path.
    ///         Body extracted to BasketLib.evacuateBody; the onlyOwner gate +
    ///         nonReentrant lock stay HERE.
    function evacuate(address vault) external nonReentrant onlyOwner {
        BasketLib.evacuateBody(vault, _vaultHealthCfg(),
            vaultHealth, vaultsOf, tokens);
        _refreshHoldings(tokens[vault]); // cache: evac moved this stable across its vaults
    }

    /// @notice Permissionless 4626 vault setter. For stables registered
    ///         with vault=address(0), anyone may wire the vault once.
    ///         Validation against Hub.asset() makes correctness self-
    ///         enforced; the (stable→vault) wiring is then immutable.
    function setVault(address stable, address vault) external onlyOwner {
        // Multi-venue: append up to MAX_VAULTS self-validated 4626 vaults to the
        // stable's set (the inner pro-rata dimension). The first becomes the
        // primary (`vaults[stable]`). onlyOwner + asset()==stable self-check; the
        // deploy wires the full HARDCODED curator set, then the finalize RENOUNCE
        // locks ownership permanently — no vaults can be added after deployment.
        // GHO + USDG route via AAVE, wired at construction. Block here
        // to prevent partial-wiring footgun.
        if (stable == GHO || stable == USDG) revert GHOIsAaveWired();
        // Body extracted to ChannelLib.setVaultBody to free Aux bytecode.
        // onlyOwner gate + GHO/USDG early-revert stay HERE; the DELEGATECALL runs
        // the storage writes (vaultsOf/vaults/tokens/aaveReserveId) + venue reads
        // + selector-encoded approve in Aux's storage context. The shared AAVE-v4
        // spoke member-vs-4626-venue dispatch (no tokens[spoke] reverse-map) is
        // preserved inside the body. No vault-count cap — setVault is onlyOwner, so
        // the set size is the deployer's choice; loops iterate the real set length.
        ChannelLib.setVaultBody(stable, vault, ChannelLib.SetVaultCfg(
            AAVE_SPOKE, AAVE_HUB, stables.length),
            toIndex, vaultsOf, aaveReserveId, tokens, vaults);
    }

    /// @notice Permissionless sweep — supply any free balance of `token`
    ///         sitting on Aux into its canonical destination so donations
    ///         and dust are absorbed into the basket instead of being lost.
    ///         - `token == 0`: native ETH → wrap → the ETH venue via _supply
    ///         - WETH: → the ETH venue via _supply (bumps _vogueETHPrincipal)
    ///         - WBTC: bumped into vogueBTC accumulator (no vault exists)
    ///         - registered stables: → vault via _supply
    ///         Unknown tokens revert — sweep is not a free transfer surface.
    ///         nonReentrant: prevents being called mid-deposit between
    ///         transferFrom and _supply, which would double-supply the
    ///         in-flight amount.
    function sweep(address token) external nonReentrant {
        // Body extracted to SwapLib.sweepBody to free Aux bytecode.
        (uint vbtcDelta, uint swept) = SwapLib.sweepBody(
            token, address(WETH), address(WBTC), GHO, USDG);
        if (vbtcDelta > 0) vogueBTC += vbtcDelta;
        if (swept > 0) emit Swept(token, swept);
        _refreshHoldings(token);       // cache: sweep supplied free balance to a vault
    }

    event Swept(address indexed token, uint amount);

    function get_metrics(bool force)
        public returns (uint, uint) {
        BasketLib.Metrics memory stats = metrics;
        uint elapsed = block.timestamp - stats.last;
        if (force || elapsed > 10 minutes) {
            (uint[15] memory amounts, uint[15] memory yieldW,,) = get_deposits();
            uint raw = amounts[14];
            // yieldW[0] is the balance-weighted ANNUALISED-RATE numerator; amounts[0] is the
            // cumulative share-price sum and is NOT a rate (§E155-overreport).
            metrics = BasketLib.computeMetrics(stats,
                elapsed, raw, yieldW[0], amounts[14]);
        } return (metrics.total, metrics.yield);
    }

    /// @notice get_metrics(force=true) with PRE-FETCHED deposit totals. The redeem path
    ///         already ran a fresh get_deposits() this call (freshness); it threads
    ///         that pass's `raw`(=amounts[14]) and `rateWeighted`(=**yieldW[0]**) here so
    ///         the par-backing metric is recomputed WITHOUT a second get_deposits scan.
    /// 🔴 **THE SECOND ARGUMENT IS `yieldW[0]` (Σ balance×rate), *NEVER* `amounts[0]` (Σ yieldWeighted).**
    ///         This docblock and the parameter name both said `amounts[0]` until 2026-08-16 — they were
    ///         left behind by §E155-overreport's fix, which corrected `computeMetrics` and both call
    ///         sites but not the surface that DOCUMENTS what to pass. `amounts[0]` is a cumulative
    ///         SHARE-PRICE LEVEL; `computeMetrics` consumes this slot as an ANNUAL RATE. Passing the
    ///         level measured **18.72% against a 3.10% true APR — 6.04× over-issuance**, with PYUSD
    ///         alone contributing 101.49% of which 99.80pp was a base offset no annualisation removes.
    ///         **Nothing reverts if you get this wrong: the mint simply issues ~6× the intended bond
    ///         premium as a permanent liability against the basket.** Both live callers are correct
    ///         (`SwapLib:530` and `BasketLib:1022`); this comment was the only thing still pointing
    ///         at the defect, which is the exact "a comment describes past state" trap — here armed.
    ///         Identical to get_metrics(true): the values are exactly what the forced
    ///         refresh would have fetched (no state change between), and the same
    ///         `metrics` write + yield-accumulator advance happen. onlyUs — an untrusted
    ///         caller passing fabricated totals would poison the metrics cache.
    function get_metricsWith(uint raw, uint rateWeighted)
        external onlyUs returns (uint, uint) {
        BasketLib.Metrics memory stats = metrics;
        uint elapsed = block.timestamp - stats.last;
        metrics = BasketLib.computeMetrics(stats, elapsed, raw, rateWeighted, raw);
        return (metrics.total, metrics.yield);
    }

    /// @notice Redemption-side depeg haircut, exposed so the QUID mint path can
    ///         discount its redeemability headroom by the SAME loss redemption
    ///         applies — mint↔redeem symmetry (never mint QUI against the par-phantom
    ///         value of a depegged holding). Non-view (get_deposits refreshes).
    function depegLoss() external returns (uint) { return BasketLib.depegLoss(); }
    function illiquidLoss() external view returns (uint) { return BasketLib.illiquidLoss(); }
    /// @notice §E203 — flagging variant for the NON-VIEW mint path; see BasketLib.illiquidLossFlagging.
    function illiquidLossFlagging() external returns (uint) { return BasketLib.illiquidLossFlagging(); }

    function getStables() external view
        returns (address[] memory) { return stables;
    }

    /// @notice The full vault SET for a stable (the inner pro-rata
    ///         dimension). Entries are Morpho-style 4626 vaults; an
    ///         entry == AAVE_SPOKE marks the stable's Aave-v4 position
    ///         (read via aaveBalance, not convertToAssets). With one
    ///         entry this is the legacy single-vault case.
    function getVaults(address stable) external view
        returns (address[] memory) { return vaultsOf[stable];
    }

    function setQuid(address _quid) external onlyOwner { _pinQuid(_quid); }

    /// @notice Deploy-finalize (Safe/deployer only): assert EVERY cross-contract linkage EQUALS Aux's owner-set
    ///         view — catching a front-runner's malicious-but-non-zero pin in an ungated setter — then BURN the
    ///         committed ANGEL seed NFT and renounce Aux. Paired in DeployL1_s with `QUID.renounceOwnership()`
    ///         (the Safe renounces Basket). Both are called BY THE DEPLOYER (each contract self-renounces as its
    ///         own owner — no `_transferOwnership`), and the assert runs FIRST, so a mis-wired deploy reverts
    ///         before anything is burned/renounced (all-or-nothing). One-shot: ANGEL is gone + owner zeroed ⇒
    ///         a re-call reverts. The ANGEL was approved to THIS Aux mid-deploy (DeployLib) and required by
    ///         Basket's constructor, so a Safe that didn't own it could never have produced a live Basket.
    function finalize() external onlyOwner {
        BasketLib.assertFullyWired(address(QUID), ethVenue, _btcChannels, address(CORE), address(VOGUE));
        // Burn the committed ANGEL seed NFT: the deploy approved THIS Aux for it (and the Safe/owner() still
        // holds it — only approved, never moved), so we transfer the Safe's ANGEL straight to DEAD via that
        // approval. Runs BEFORE renounce (uses owner()); one-shot (ANGEL gone ⇒ a re-call reverts on transfer).
        ICollection(F8N).transferFrom(owner(), DEAD, QUID.ANGEL());
        renounceOwnership();
    }

    function _pinQuid(address _quid) private {
        if (address(QUID) != address(0)) revert QuidPinned();
        QUID = Basket(_quid);
        WETH.approve(address(VOGUE), type(uint).max);
        // Stable→vault approvals are wired in the constructor loop; this only
        // pins QUID and adds the V4-side WETH approval (V4 wasn't known at
        // construction time).
    }

    // ─── All-or-nothing deploy finalize (replaces the governance handoff) ────
    // The ANGEL seed NFT (F8N tokenId Basket.ANGEL) was approved to THIS Aux mid-deploy (DeployLib) and REQUIRED
    // by Basket's constructor, so the commitment is enforced at Basket's birth (a Safe that didn't own it could
    // never produce a live Basket). At finalize (above), Aux asserts every cross-contract linkage EQUALS its
    // owner-set view — catching a deploy-block front-runner who pinned a malicious-but-non-zero address into an
    // UNGATED pin-once setter (Vogue.setEthVenueContract / Core.setBtcVault) — then burns ANGEL (owner→DEAD via
    // the approval) and renounces Aux. Reverts (no burn/renounce) if anything is mis-wired → all-or-nothing.
    address constant F8N  = 0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD; // ANGEL burn sink (ERC-721 reverts on address(0))

    /// @dev §BANDOF-DELETE — the asset picks its band, from immutables rather than a mapping.
    /// @dev ⚠️ IT REVERTS ON AN UNKNOWN ASSET, AND THAT IS THE POINT. The mapping returned
    ///      `address(0)` for anything unwired, which failed loudly downstream. A bare
    ///      `asset == WBTC ? BTC_CORE : CORE` would instead return the ETH band for an unknown
    ///      asset -- a VALID-LOOKING handle carrying the wrong band's price and pooled state, which
    ///      is the silent-wrong-band class this tree has already shipped three times. So the
    ///      replacement is stricter than what it replaces, not merely cheaper.
    ///      A `private view`, not a modifier: a modifier inlines at every use site (rule 8c).
    function _bandOf(address asset) private view returns (Core) {
        if (asset == address(WBTC)) return BTC_CORE;
        if (asset == address(WETH)) return CORE;
        revert BadAsset();
    }

    function getTWAPforAsset(address asset, uint32 period)
        public view returns (uint price) {
        price = SwapLib.twapBody(address(_bandOf(asset)), period);   // §ISBTC-SPLIT: the asset picks the band

        (price,) = SwapLib.twapResolve(assetPriceFeed[asset], price, 
                    asset == address(WBTC), TWAP_MAX_DEVIATION_BPS, 
                    ASSET_FEED_MAX_AGE); // 
    }

    /// @notice Like getTWAPforAsset but also reports `stale` = the internal TWAP
    ///         diverged >5% from a fresh Chainlink (returned price IS Chainlink).
    ///         The curve-reseat auto-heal (LpEngine.rebalanceCore) keys off this:
    ///         move the pool spot onto `price` only in this dislocation regime.
    function resolvedTwap(address asset, uint32 period)
        public view returns (uint price, bool stale) {
        price = SwapLib.twapBody(address(_bandOf(asset)), period);   // §ISBTC-SPLIT: the asset picks the band

        (price, stale) = SwapLib.twapResolve(assetPriceFeed[asset], price,
            asset == address(WBTC), TWAP_MAX_DEVIATION_BPS, ASSET_FEED_MAX_AGE);
    }

    /// @notice The live inventory-skew (WAD) the well applies to `asset`'s swap-OUT — the
    ///         pool's reservation-price / RFQ taker-limit offset. Exposed on the SAME unified
    ///         seam as getTWAPforAsset/resolvedTwap so Bebop's RFQ engine AND Khalani's
    ///         Arcadia solver read the same curve settlement uses. `base·(1 − wellSkew(asset, size))`
    ///         is the fill. 0 = flush (band price stands); rises to the cap as deliverable inventory
    ///         becomes scarce. Read-only.
    ///
    ///         🔴 THE SIZE ARGUMENT IS MANDATORY BY DESIGN — THE ZERO-SIZE FORM WAS RETIRED, NOT KEPT
    ///         ALONGSIDE. There used to be a `wellSkew(address)` that passed `drainUsd6 = 0` and
    ///         returned the INSTANTANEOUS rate, and its docblock claimed solvers "quote against the
    ///         EXACT number a swap executes at". True before §E68, false after: settlement charges
    ///         the INTEGRAL of the pole over the path the swap itself walks (q0→q1), and the starting
    ///         rate is the CHEAPEST point on that path. MEASURED on a $1m band: a 10% drain filled
    ///         **1.11×** worse than that quote and a 90% drain **4.12×** worse, the error widening
    ///         toward the pole — exactly where being wrong costs most.
    ///         ⚠️ It was first fixed by ADDING this overload and documenting the old one as narrow.
    ///         That left the footgun loaded: the defect was consumers reading the size-blind form, so
    ///         leaving it callable preserved the exact mistake. Deleting it makes the wrong quote
    ///         UNCONSTRUCTIBLE rather than merely discouraged (standing rule 17). The indicative case
    ///         is now spelled `wellSkew(asset, 0)` — same number, but the caller has to say that a
    ///         zero-size quote is what they meant.
    ///         📌 The justification for keeping it — "consumers pinned to the original signature" —
    ///         was never checked and was false: zero references in `quid-ln` and `spa`, and every
    ///         call site was a test.
    /// @param asset      volatile side (WETH/WBTC)
    /// @param drainUsd6  the swap's volatile-side draw, 6-dec USD — the same base settlement uses;
    ///                   pass 0 for the flush/indicative rate, which is the `size → 0` limit
    function wellSkew(address asset, uint drainUsd6) public view returns (uint) {
        // §ISBTC-SPLIT: the asset picks the BAND INSTANCE via the wiring-time lookup, and the
        // `isBTC` argument is gone -- the instance knows what it is.
        return SwapLib.wellSkew(address(_bandOf(asset)), getTWAPforAsset(asset, 1800), drainUsd6);
    }

    /// @notice The flat swap fee (parts-per-million — 420 = 0.042%) every stable↔volatile swap pays,
    ///         exposed on the unified seam so an RFQ maker / solver can reconstruct the fill:
    ///
    ///             out ≈ base·(1 − swapFeePpm/1e6),  then the `riskFactor(token)` depeg haircut.
    ///
    /// 🔴 §V4-CUT — **THE SKEW TERM IS GONE FROM THIS COMPOSITION, AND NO SIGNATURE DIFF CAN SHOW
    ///         THAT.** It used to read `out ≈ base·(1 − wellSkew)·(1 − fee/1e6)`, which was true
    ///         while v4 discovered the price along a curve. Settlement is now AT ORACLE: the skew is
    ///         the ATTRIBUTION KEY for the restoration cost, not a price adjustment, so it does not
    ///         appear in the fill. A solver still applying the old formula UNDER-PREDICTS `out` by
    ///         the whole skew factor — same selector, same units, wrong meaning, and INVISIBLE to
    ///         `tools/check-client-abis.py`, which compares signatures rather than semantics.
    ///         ⇒ Any solver-facing quote path must be updated in this same cut, not after it.
    ///
    /// ⚠️ AND THE NUMBER IS NOW **OUR POLICY, NOT A MIRROR**. This used to say "Mirrors the pool tier
    ///         set in Core's pool key" — `OracleLib:180`'s `k.fee = 420`. v4 charged it and
    ///         `_handleCollect` harvested it; with v4 gone the FILL charges it (`Core.swap`), so 420
    ///         is a parameter we own and must justify, not a reflection of someone else's tier.
    ///
    ///         The fee is FLAT (`calcFeeL1` is the redeem/draw degradation fee, not charged here);
    ///         the remaining DYNAMIC axis is `riskFactor` (depeg).
    function swapFeePpm() external pure returns (uint24) { return 420; }

    // _buildContext moved into SwapLib.swapToBody (the only consumer) — its
    // AuxContext is now constructed inline there.

    /// @notice Generic swap entry. Output goes to msg.sender.
    function swap(address token, address asset, bool forVolatile,
        uint amount, uint minOut) public payable
        returns (uint max) {
        return swapTo(token, asset, forVolatile, amount, minOut, msg.sender);
    }

    /// @notice Swap with explicit recipient. Useful when the caller is
    ///         blacklisted by a stable issuer and wants proceeds to land
    ///         at a fresh address (similar motivation to redeem's recipient
    ///         overload), or for any case where caller≠destination.
    /// @param token         input stable, QUID, or zero (when paying volatile)
    /// @param asset         volatile side — WETH or WBTC
    /// @param forVolatile   true: stable→volatile; false: volatile→stable
    function swapTo(address token, address asset, bool forVolatile,
        uint amount, uint minOut, address recipient) public payable nonReentrant
        returns (uint max) {
        // Body extracted to SwapLib.swapToBody (delegatecall — address(this)==Aux,
        // msg.value/msg.sender forwarded) to free Aux bytecode. The public entry +
        // nonReentrant lock stay HERE; behavior is verbatim. (B) depeg-fair pricing,
        // the BTC-recipient gate, the runtime backing invariant, the QUID-turn seed
        // un-tip, and the routeSwap call all run inside the body.
        return SwapLib.swapToBody(
            SwapLib.SwapReq(token, asset, forVolatile, amount, minOut, recipient, address(0), 0),
            SwapLib.SwapToCfg({
                weth: address(WETH), wbtc: address(WBTC), quid: address(QUID),
                // §ISBTC-SPLIT — THE SWAP SETTLES AGAINST THE BAND THAT OWNS THE ASSET. This read
                // `address(CORE)` for every asset, so a WBTC swap priced and settled against the ETH
                // band's inventory: `POOLED`, `POOLED_USD`, the skew and the backing gate all came
                // from the wrong instance. MEASURED: with the BTC band's own POOLED at 0, every BTC
                // swap returned out == 0 and reverted `SlippageMaxS()` -- ~593 failures, all BTC.
                // The read paths (`getTWAPforAsset`, `resolvedTwap`, `wellSkew`) were dispatched by
                // `bandOf` already; this is the WRITE half of the same dispatch, and splitting them
                // is what let reads and settlement disagree about which band they were talking to.
                core: address(_bandOf(asset)),
                // §SLOP: the asset picks the BAND MANAGER too, through the same wiring-time knowledge.
                band: asset == address(WBTC) ? CORE.btcVault() : address(VOGUE),
                btcChannels: _btcChannels
            }),
            stables
        );
    }

    /// @notice Self-gated trampolines for swapToBody (delegatecall self-calls).
    ///         (tipSelf already exists below; swapToBody reuses it.)
    function _depositVol(address asset, address sender, uint amount)
        external payable returns (uint) {
        if (msg.sender != address(this)) revert NotSelf();
        return _deposit(asset, sender, amount);
    }
    function bumpVogueBTC(uint amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        vogueBTC += amount;
    }

    error VaultUnwired();
    error VaultAlreadySet();
    error VaultAssetMismatch();
    error StableMissing();
    error ZeroDeposit();
    error ZeroSent();
    error VaultBlocked();


    // ─── §E233-sor — THE SOR IS DELETED: PLUMBING FOR A CAPABILITY THAT WAS ALREADY GONE ───
    // Removed: `auxSwap(uint,address,address,uint)` (the `onlyUs` 4-arg overload), `_tryPath`,
    // `sorSelfFunded`, `sorSelfFundedReverse`, the `_pathEncodings` array they iterated, and
    // `imports/SOR.sol`.
    //
    // ⚠️ WHAT SURVIVES, AND WHY THE NAME IS A TRAP: `auxSwap(address,address,uint,address,uint)`
    // directly below shares ONLY its name. It is SwapLib-backed, permissionless, and LIVE
    // CLIENT-FACING -- the SPA encodes it by full signature for stable->stable. Deleting
    // `auxSwap` BY NAME would have taken out the app's swap.
    //
    // RULE 1 (unreachable), measured not assumed: zero callers in src/test/script of
    // `executePath`/`sorSelfFunded*` and zero selector-encoded references; checked for INTERNAL
    // dot-less calls too, which a `.auxSwap(` grep structurally cannot see, and only the
    // declarations matched. The 4-arg overload was `onlyUs`, so with no protocol caller nothing
    // COULD reach it. `_pathEncodings` was written once at construction and read only by the
    // three SOR bodies -- write-only state after this.
    //
    // ▶️ THE ROUTE THAT MUST COME BACK IS BOOKED, NOT DROPPED: a stable->volatile path for the
    // basket is §V-R1 (1inch AggregationRouterV6). Recorded at the site the code occupied, so the
    // gap is visible here and not only in the queue.

    /// @notice Stable→stable swap leg. Same surface name as the
    /// @notice Stable→stable leg via basket vaults (not V4): user → vault →
    ///         vault → recipient. Fee + haircut via FeeLib.applyFeeAndHaircut
    ///         on tokenOut. tokenIn must NOT be blacklistable (Aux holds it
    ///         transiently between transferFrom and _supply — blacklistables
    function auxSwap(
        address tokenIn,
        address tokenOut,
        uint    amountIn,
        address recipient,
        uint    minOut
    ) external nonReentrant returns (uint amountOut) {
        // Body extracted to SwapLib.auxSwapBody. Wrapper holds the
        // `nonReentrant` lock and pre-reads cheap state (toIndex). The depeg
        // severity is read back via getDepegSeverityBps on Aux itself, so the
        // library is handed `address(this)`. State mutations route via supplySelf /
        // withdrawSelf (self-gated, see Aux.supplySelf docblock).
        return SwapLib.auxSwapBody(
            tokenIn, tokenOut, amountIn, recipient, minOut,
            toIndex[tokenIn], toIndex[tokenOut],
            address(this)
        );
    }

    // ─── ETH yield venue (AAVE/ether.fi) — REGROUPED into EthVenue ──────────
    // The WETH-side custody (AAVE WETH, weETH) + its ops
    // (supplyETH/withdrawETH, supplyEtherFi/supplyAaveEth, offrampEtherFi,
    // aaveEthBalance) now live on the ETH band manager. Aux keeps a pinned handle +
    // thin forwarders only where callers must not change target.
    // §E233-sor — THIS LINE LISTED `arbETH` AS ONE OF THEM, TWICE WRONG: `arbETH` does not exist
    // (its forwarder and both callers -- Core.refillETH, Vogue._withdraw -- were removed, as noted
    // below), and `EthVenue` no longer exists either, having been folded into `Vogue`. A comment
    // naming a deleted function AND a deleted contract is how a reader concludes a capability is
    // present when nothing implements it.

    /// @notice EthVenue — pinned once, then driven for the ETH-venue ops.
    address public ethVenue;
    error EthVenuePinned();
    function setEthVenue(address e) external onlyOwner {
        if (ethVenue != address(0)) revert EthVenuePinned();
        ethVenue = e;
        // Standing WETH approval so EthVenue.supplyFromAux can pull the BOLD/SP
        // liquidation WETH gain (the only Aux→EthVenue WETH supply path).
        IERC20(address(WETH)).approve(e, type(uint).max);
    }

    /// @notice Current ETH-equivalent backing on the ETH side — forwards to
    ///         EthVenue.vogueETH(). Kept reachable because BasketLib (IAux read),
    ///         Vogue, and front-ends read it at this address.
    function vogueETH() public view returns (uint) {
        return IEthVenue(ethVenue).vogueETH();
    }

    function deliverableETH() public view returns (uint) {
        return IEthVenue(ethVenue).deliverableETH();
    }

    // REMOVED: arbETH forwarder — its only callers (Core.refillETH, Vogue._withdraw)
    // were removed as the toxic surplus-funded make-whole. No replacement: ETH-pool
    // shortfalls are borne fairly via the share price, never patched from surplus.

    /// @notice BTC shortfall settlement. ONLY path: emit the Lightning hop request
    ///         (real BTC sent on L1 by the hop daemon, consuming NO basket stables —
    ///         settlement, not subsidy). With NO registered recipient there is nothing
    ///         to deliver here, so it is a no-op (the BTC pool composition reconciles
    ///         fairly at settlement). The old WBTC-from-free-backing fallback — the BTC
    ///         analog of refillETH (arbBody = "arbBTC") — was REMOVED: it spent the
    ///         SHARED safety margin to deliver WBTC for a usually-impermanent shortfall,
    ///         compensating the flow at every claimholder's expense (toxic).
    function btcShortfall(address sender, uint shortfall) external onlyUs {
        if (sender == address(this)) return;
        bytes32 recipient = IBTCChannels(_btcChannels).btcRecipientOf(sender);
        if (recipient == bytes32(0)) return;
        unchecked { btcHopRequestId++; }
        emit BTCHopRequest(btcHopRequestId, recipient, shortfall);
    }

    /// @notice Emitted when the V4 BTC pool obligates us to send native
    ///         BTC to a recipient. Hop node listens and executes on-L1.
    event BTCHopRequest(uint256 indexed requestId, bytes32 indexed recipient, uint256 amount);
    uint256 public btcHopRequestId;

    /// @notice Convert Basket tokens into dollars. Proceeds land at the
    /// caller's address.
    /// @param amount of tokens to redeem, 1e18
    function redeem(uint amount) external nonReentrant {
        _redeemAs(amount, msg.sender, msg.sender, address(0));
    }

    /// @notice Targeted redemption: shed `preferred` (a basket stable) FIRST, then
    ///         pro-rata for any remainder. The strict pro-rata default (the 1-arg
    ///         redeem) is cherry-pick-free. §SCRUB: this said it "pays only the directional
    ///         baseRate" -- `baseRate` was REMOVED (recorded below in this same file) and no code
    ///         implements it, so the sentence described a toll that is not charged.
    ///         naming a `preferred` stable additionally pays the per-stable
    ///         concentration fee on that leg — the redemption mirror of choosing an
    ///         output stable on a swap. Lets a holder shed a depegged/low-yield leg.
    function redeem(uint amount, address preferred) external nonReentrant {
        _redeemRequire(preferred);
        _redeemAs(amount, msg.sender, msg.sender, preferred);
    }

    /// @notice Redeem to a DIFFERENT recipient. `source` stays msg.sender — you can
    ///         only ever burn your OWN QUI (turn burns msg.sender's mature batches),
    ///         so this can never drain another holder. It just retargets the payout.
    ///         The mirror of swapTo's recipient overload (whose docblock already
    ///         cites "redeem's recipient overload"): a holder blacklisted by a stable
    ///         issuer (USDC/USDT) can take proceeds at a fresh address instead of
    ///         being stranded. `preferred` (0 = pro-rata) behaves as in redeem/2.
    function redeemTo(uint amount, address recipient, address preferred) external nonReentrant {
        require(recipient != address(0), "bad-recipient");
        _redeemRequire(preferred);
        _redeemAs(amount, msg.sender, recipient, preferred);
    }

    /// @dev Shared targeted-draw validation: `preferred` must be a real basket stable
    ///      (not the volatile WETH leg, not QUID), or address(0) for pure pro-rata.
    function _redeemRequire(address preferred) internal view {
        if (preferred != address(0)) {
            require(preferred != address(WETH) && toIndex[preferred] > 0, "bad-preferred");
        }
    }

    function _redeemAs(uint amount, address source, address recipient, address preferred) internal {
        // Depeg severity is read live from each stable's pinned Chainlink feed
        // (getDepegSeverityBps → liveDepegBps) inside redeemAsBody's haircut, so
        // there is no off-chain "signal dark" state to gate on anymore. A stale or
        // dead feed defers to 0 (no haircut) by design — see liveDepegBps; a real
        // depeg keeps the feed fresh (it updates on deviation).
        // Body extracted to BasketLib.redeemAsBody. Redemption is STABLES-ONLY: when the
        // free stables can't cover it, redeemAsBody unwinds the band to free QU!D's own committed
        // dollars (Vogue.unwindForRedeem) -- no volatile leg, no LP ETH sold.
        // §A.5e: value against a bounded-fresh cache. MUST precede redeemAsBody — that is the whole bug.
        _requireFreshHoldings();
        BasketLib.redeemAsBody(BasketLib.RedeemArgs(
            amount, source, recipient,
            address(CORE), address(QUID), address(VOGUE), address(WETH), preferred));
        // cache: redeem does a FULL refresh to recapture yield drift across
        // ALL stables (the pro-rata draw touched some; this covers the rest).
        _refreshAllHoldings();
    }

    /// @notice Max QUI that can currently be redeemed in one call. View
    /// counterpart to the input-clip in `_redeemAs`. Front-ends should
    /// call this and clamp the user's slider; on-chain `redeem(amount)`
    /// also clips internally so a stale read is safe (just leaves QUI on
    /// the user's wallet rather than reverting).
    function redeemableAmount() external returns (uint) {
        return BasketLib.redeemableBody(address(CORE));
    }

    function get_deposits() public
        returns (uint[15] memory amounts, uint[15] memory yieldW, uint avgYield, uint depegLoss) {
        (amounts, yieldW, depegLoss) = BasketLib.get_deposits(
            address(this), stables, storedHoldings, tranche);

        // BOLD is convention-pinned as the LAST entry in `stables`
        // (SP-routed). amounts[13] is its canonical accounting slot.
        uint nStables = stables.length; // cache the storage-array length (one SLOAD)
        if (nStables > 0) {
            address stable = stables[nStables - 1];
            address vault = vaults[stable];
            (uint spTotal, uint spYieldWeighted) = ChannelLib.calcSPValue(
                vault, address(this), tranche[stable], sp);
            if (spTotal > 0) {
                amounts[14] += spTotal;
                amounts[13]  = spTotal;
                // Apply depeg-yield discount for the BOLD/SP group. #U2: read the ONE severity source directly
                // (getDepegSeverityBps, as the per-stable loop does) instead of the riskFactor complement — same
                // haircut (riskFactor == 10000 − severity), one accessor, no double-negation.
                uint sev = getDepegSeverityBps(stable);
                if (sev > 0) {
                    uint loss = SoladyMath.fullMulDiv(spTotal, sev > 10000 ? 10000 : sev, 10000);
                    spYieldWeighted = spYieldWeighted > loss ? spYieldWeighted - loss : 0;
                    depegLoss += loss; // include BOLD/SP's depeg slice in the returned total
                }
                amounts[0]  += spYieldWeighted;
                yieldW[13]   = spYieldWeighted;
            }
        }
        avgYield = metrics.yield;
    }

    function avgYield()
        external view returns (uint) {
        return BasketLib.avgYield(metrics);
    }

    /// @notice External drain entry. WETH path goes direct to _withdraw;
    ///         other stables route through the FeeLib-driven fallthrough
    ///         loop. Calls _checkBacking after any drain to enforce
    ///         POOLED_USD ≤ basket TVL — auto-triggers repack if needed.
    ///         Called by Core.swap (V4 USD-side delta) and by
    ///         _redeemAs (basket redemption).
    function take(address who, uint amount, address token, uint seed)
        public onlyUs returns (uint sent) {
        return take(who, amount, token, seed, address(0));
    }

    /// @notice Targeted-draw overload. `preferred` (a basket stable, or address(0)
    ///         for pure pro-rata) is shed FIRST, then the remainder pro-rata —
    ///         the redemption analog of the swap path's named-stable take. Only the
    ///         redeem path passes a non-zero `preferred`; Core's swap drain uses the
    ///         4-arg form (preferred=0). Behavior with preferred=0 is byte-identical
    ///         to the prior pro-rata redeem (regression-safe).
    function take(address who, uint amount, address token, uint seed, address preferred)
        public onlyUs returns (uint sent) {
        // Body extracted to BasketLib.takeBody. Wrapper holds the onlyUs
        // gate, pre-reads cheap state (toIndex, stables) and DELEGATECALLs the
        // library. Library calls back via withdrawSelf / tipSelf / checkBacking
        // (all self-gated) and reads depeg severity via getDepegSeverityBps on Aux
        // (handed `address(this)`).
        // DIRECTIONAL fee: the redemption path (token==QUID) accrues the decaying
        // §SCRUB: this said the fee covered `baseRate` for BOTH draw modes. `baseRate` is gone; the
        // pro-rata/targeted distinction below is real, the toll is not. A targeted redeem is
        // still a redemption. A swap taking USD out as one specific stable
        // (token!=QUID) is normal flow, not a redemption, so brBps=0.
        return BasketLib.takeBody(_takeArgs(who, amount, token, seed, preferred));
    }

    /// @dev Shared TakeArgs builder for take()/5 and takeWith()/7 (identical
    ///      12-field construction). §SCRUB: claimed it "accrues the directional baseRate HERE" --
    ///      nothing accrues, `baseRate` having been removed. Kept the construction note, which is
    ///      true, and dropped the accrual, which named a deleted mechanism at a specific site (state
    ///      mutation) so both callers stay thin — one copy of the struct build.
    function _takeArgs(address who, uint amount, address token, uint seed, address preferred)
        internal view returns (BasketLib.TakeArgs memory) {
        // baseRate REMOVED. It was a Liquity-style DIRECTIONAL redemption velocity toll: a decaying rate
        // (12h half-life via BR_DECAY) that heated by `redeemedUsd/(2·supply)` on every QUID redemption to
        // tax repeated/fast redeems, clamped at MAX_FEE, applied only on `token==QUID` draws. Liquity needs it
        // because its redemptions DEFEND the LUSD peg (redeem LUSD→ETH at $1 to push the peg back up), so the
        // toll makes peg-defense redemption spam costly. QU!D has NO such peg-arb loop: redemption is a NAV
        // basket-share claim (min($1, solvent/mature)) on a mock/onlyUs pool, not a market-peg defense — so the
        // toll had no peg to protect. Peg-defense redemptions are scheduled instead by 6909. Outflow control is
        // now the depeg haircut only (during a depeg).
        return BasketLib.TakeArgs(
            who, amount, token, seed,
            address(WETH), address(QUID),
            toIndex[token], stables, address(this),
            preferred, toIndex[preferred], false          // softBacking: strict for every user-facing drain
        );
    }

    /// @notice Trusted swap-out SETTLE drain (delivery-side de-lever): shed `amount`-USD of the named `token`
    ///         to `who` (the lev venue) with a SOFT terminal backing check. Same shared drain body as take(); the
    ///         only difference is the terminal check uses the non-reverting tryCheckBacking, because this drain is
    ///         IMMEDIATELY offset by an in-tx debt-repay so solvency holds at the FINAL state, not the mid-drain
    ///         instant. onlyUs (the Vault settle path routes through Core, which is `us`).
    function takeToSettle(address who, uint amount, address token) external onlyUs returns (uint sent) {
        BasketLib.TakeArgs memory a = _takeArgs(who, amount, token, 0, address(0));
        a.softBacking = true;
        return BasketLib.takeBody(a);
    }

    /// @notice take() with PRE-FETCHED deposit vectors. The redeem path already
    ///         fetched get_deposits once (for the depeg haircut); threading the same
    ///         (amounts, yieldW) here lets takeBodyWith skip a second full basket scan.
    ///         Only used when no seed was burned (tranche unchanged by the turn,
    ///         so the pre-burn fetch is exactly what a fresh fetch would return). Builds
    ///         the same TakeArgs as take()/5. §SCRUB: "the directional baseRate still accrues" was
    ///         the strongest of the four stale claims -- "still" asserts a live mechanism by name.
    function takeWith(address who, uint amount, address token, uint seed, address preferred,
        uint[15] memory amounts, uint[15] memory yieldW) public onlyUs returns (uint sent) {
        return BasketLib.takeBodyWith(
            _takeArgs(who, amount, token, seed, preferred), amounts, yieldW);
    }

    // ─── REMOVED: the directional redemption fee (Liquity-style decaying baseRate) ────────────
    // baseRate storage (`_br`) + `_touchBaseRate` + BR_DECAY/BR_MAX_MIN REMOVED here — the Liquity-style
    // directional redemption velocity toll. See `_takeArgs` above for the full rationale: QU!D has no peg-arb
    // loop to defend (unlike Liquity), so the toll had no peg to protect; peg-defense redemptions are scheduled
    // by 6909. Outflow control is now the depeg haircut only.

    // ─── The band accountant. Was a separate `BandBacking` contract; folded in here ───────────
    //
    /// §BANDBACKING-FOLD — THE JOINT COMMITTED FIGURE LIVES WHERE THE GATE LIVES. Two band
    /// instances each own their own `POOLED_*` and accumulators, but the solvency bound is a SUM:
    /// there is deliberately NO per-band cap, so either band may draw the whole free surplus while
    /// the other is idle. Two instances each gating against the FULL TVL would double-commit the
    /// same backing WITHOUT reverting.
    ///
    /// That coupling used to be a whole contract (`BandBacking`: a registry, a `seal()`, a
    /// `bands` array, an `isBand` map, a `DEPLOYER` pin and five errors) whose entire job was to
    /// hold two numbers and add them. It is deleted, because **Aux already IS this contract**: the
    /// gate that consumes the sum is `_checkBacking` twelve lines below, and Aux already holds
    /// `CORE` and `BTC_CORE` as immutables.
    ///
    /// ⇒ The band set is fixed at Aux's CONSTRUCTION rather than registered-then-sealed, which is
    /// strictly stronger: there is no window in which the denominator is partial. `BandBacking`
    /// needed `total()` to revert unless sealed for exactly that reason — a partial sum
    /// UNDER-reports and passes a bound it should fail. Here the sum cannot be partial.
    mapping(address => uint256) public committedOf;
    event Reported(address indexed band, uint256 equityUsd18);

    /// @notice A band pushes its OWN committed equity. PUSH, not pull.
    /// @dev    ⚠️ THE STALENESS RULE (§A.16b one level up): a sum of per-band figures is only
    ///         meaningful if every term is on the same clock. If one band reports live while the
    ///         other's figure is stale, the total is a number that was never simultaneously true,
    ///         and the bound would pass against backing that does not exist. So this is pushed at
    ///         the moment the band's equity changes, never lazily pulled.
    function report(uint256 equityUsd18) external {
        if (msg.sender != address(CORE) && msg.sender != address(BTC_CORE)) revert Unauthorized();
        committedOf[msg.sender] = equityUsd18;
        emit Reported(msg.sender, equityUsd18);
    }

    /// @notice Total committed equity across both bands — the old `committedUsd18()`.
    function committedTotal() public view returns (uint256) {
        return committedOf[address(CORE)] + committedOf[address(BTC_CORE)];
    }

    // §BANDBACKING-FOLD — `otherThan` IS NOT PORTED, because it had ZERO callers. It was written as
    // the §E53 shared-scarcity input, but `SwapLib._sharedScarcityWad` never used it: that function
    // derives the sibling itself, as `ICore.committedUsd18() - ICore.bandEquityUsd18()`. The two
    // agree on the denominator (which was `otherThan`'s whole justification) because the subtraction
    // is against the same total the bound reads — so the accessor was a second way to compute a
    // number nobody asked it for. Carrying it across would have moved dead code into a contract with
    // a hard EIP-170 budget (standing rule 1).

    /// @notice Structural invariant enforcer. Permissionless. Auto-triggers
    ///         Vogue.repack when POOLED_USD is over-committed vs total
    ///         backing; reverts OverCommitted if the invariant remains
    ///         violated after both sides have repacked (structural
    ///         insolvency — caller must surface to user).
    /// @return committedSum scaled to 18-dec, after any repack that ran
    /// @return totalLiquid  18-dec total backing across all stable sources
    function checkBacking() external returns (uint committedSum, uint totalLiquid) {
        return _checkBacking();
    }

    function _checkBacking()
        internal returns (uint committedSum, uint totalLiquid) {
        (committedSum, totalLiquid) = _backingCore();
        // STRICT: after the core's repack attempts, if invariant still
        // violated the protocol is structurally over-committed. Reverts
        // here protect DRAIN paths (redemption, arb, LP withdraw) from
        // moving value out of an already-deficient basket. ADD paths
        // (deposit, BTC swap-out reissuance) use `tryCheckBacking` so
        // new value can come in to heal the basket.
        if (committedSum > totalLiquid) revert OverCommitted();
    }

    /// @notice Same backing logic without the terminal revert. ADD-side
    ///         callers (deposit) use this so over-commit doesn't deadlock
    ///         the recovery path. Caller MUST treat
    ///         `committedSum > totalLiquid` as a real condition to make
    ///         decisions against (it's the same signal _checkBacking
    ///         would have reverted on).
    function tryCheckBacking() external returns (uint committedSum, uint totalLiquid) {
        return _backingCore();
    }

    /// @notice Shared body: read state, attempt up to two repacks to
    ///         restore the invariant, return current values regardless.
    function _backingCore()
        internal returns (uint committedSum, uint totalLiquid) {
        // Body extracted to BasketLib.backingCoreBody to free Aux bytecode.
        return BasketLib.backingCoreBody(address(CORE), address(BTC_CORE), address(VOGUE), CORE.btcVault());
    }

    /// @notice Asset-withdraw dispatcher (mirror of _supply). WETH idle-
    ///         then-venue + decrements principal. GHO via AAVE-v4 try/catch
    ///         (paused reserve doesn't brick basket loop). BOLD via SP +
    ///         re-supply WETH gain. Other stables: 4626 redeem.
    function _withdraw(address token, uint amount, address to)
        internal returns (uint sent) {
        // Body extracted to ChannelLib.withdrawBody (delegatecall → Aux's storage).
        // DRAIN path; WETH/GHO-USDG/BOLD-SP/multi-venue dispatch preserved verbatim
        // (incl. the AAVE try/catch fallthrough + SP WETH-gain re-supply).
        return ChannelLib.withdrawBody(
            token, amount, to,
            ChannelLib.SupplyCfg(
                address(WETH), GHO, USDG, AAVE_SPOKE,
                GHO_RESERVE_ID, USDG_RESERVE_ID, ethVenue,
                stables[stables.length - 1]),
            vaults, vaultsOf, sp);
    }

    /// @notice Deposit entry. NO `nonReentrant` — external callers
    ///         (`Basket.mint`, `Vogue.outOfRange`, `swapTo`) already hold
    ///         their own locks; adding one here deadlocks the `swapTo` →
    ///         `deposit` path. Venues are trusted (no re-entry).
    function deposit(address from,
        address token, uint amount) public
        returns (uint usd) {
        // Body extracted to ChannelLib.depositBody to free Aux bytecode. WRITE
        // path → the one extra delegatecall hop is acceptable (NOT a hot read).
        // address(this)==Aux and msg.sender is preserved across delegatecall, so
        // the QUID seed-fee + full-refresh gates are unchanged; all mutation
        // routes via supplySelf/tipSelf/refresh*Self, all reads via Aux getters.
        return ChannelLib.depositBody(from, token, amount, address(QUID), stables.length);
    } function _tip(uint cut, address token, int sign) internal {
        // Body in BasketLib.tipBody (delegatecall — EIP-170 headroom); tranche mapping mutated via storage ref,
        // trancheTotal (value type) written back here. Logic unchanged.
        trancheTotal = BasketLib.tipBody(tranche, trancheTotal, cut, token, sign);
    }


    /// @notice Internal-but-external trampoline so the try/catch in
    ///         `_withdraw`'s GHO/USDG branch can capture reverts
    ///         (Solidity's try/catch only works on external calls).
    ///         `onlySelf` gate.
    function _withdrawAaveUnsafe(uint256 reserveId, uint amount, address to) external returns (uint drawn) {
        if (msg.sender != address(this)) revert NotSelf();
        // Body folded into ChannelLib.aaveWithdrawTo (shared with withdrawAaveLeg);
        // reserveId maps to its GHO/USDG token for the post-withdraw transfer.
        return ChannelLib.aaveWithdrawTo(
            AAVE_SPOKE, reserveId, reserveId == GHO_RESERVE_ID ? GHO : USDG, amount, to);
    }

    /// @notice Withdraw a DUAL-VENUE stable's Aave-v4 leg (USDC/USDT). The
    ///         generalized twin of `_withdrawAaveUnsafe`: it takes the STABLE
    ///         (not a raw reserveId) so the post-withdraw transfer routes the
    ///         correct token. Self-gated (called by multiVaultWithdrawBody via
    ///         the library delegatecall → msg.sender == address(this)). Unlike
    ///         the GHO/USDG branch in `_withdraw`, this is NOT try/catch-wrapped
    ///         here — the caller (multiVaultWithdrawBody) reads the deliverable
    ///         balance first and only requests what the leg can give, and the
    ///         pro-rata sweep absorbs any per-venue shortfall.
    function withdrawAaveLeg(address stable, uint amount, address to)
        external returns (uint drawn) {
        if (msg.sender != address(this)) revert NotSelf();
        // Body folded into ChannelLib.aaveWithdrawTo (shared with _withdrawAaveUnsafe);
        // the dual-venue stable IS its own post-withdraw transfer token.
        return ChannelLib.aaveWithdrawTo(
            AAVE_SPOKE, _reserveIdOf(stable), stable, amount, to);
    }

    /// @notice Self-gated wrappers for `_supply` / `_withdraw` / `_tip`.
    ///         DELEGATECALL'd library functions reach back here via
    ///         `IAux(address(this)).X(...)` — msg.sender = address(this)
    ///         so the gate passes. Direct EOA / contract / venue-callback
    ///         calls all fail the gate (msg.sender is the caller's own
    ///         address, never Aux's). Must be `external` (not `public`);
    ///         must NOT carry `nonReentrant` (outer entry holds the lock).
    function supplySelf(address token, uint amount) external returns (uint deposited) {
        if (msg.sender != address(this)) revert NotSelf();
        return _supply(token, amount);
    }

    function withdrawSelf(address token, uint amount, address to) external returns (uint sent) {
        if (msg.sender != address(this)) revert NotSelf();
        return _withdraw(token, amount, to);
    }

    /// @notice §E197 — self-gated vault-health FLAG, called by the delegatecalled redeem/redeemable
    ///         bodies when the deliverability loop they already run sees a leg below `LIQ_TOL_BPS`.
    ///         DETECTION ONLY: blocks and starts the evac dwell, never moves funds. This is what
    ///         replaces a poke SCHEDULE — the measurement was already being made on every redeem and
    ///         thrown away, so the health clock now starts on organic traffic instead of waiting for
    ///         somebody to call `pokeVaultHealth`. Evacuation still requires that deliberate call.
    function flagIlliquidSelf(address vault, bool illiquid) external {
        if (msg.sender != address(this)) revert NotSelf();
        BasketLib.flagIlliquidBody(vault, illiquid, vaultHealth);
    }

    function tipSelf(uint cut, address token, int sign) external {
        if (msg.sender != address(this)) revert NotSelf();
        _tip(cut, token, sign);
    }

    /// @notice Self-gated cache refreshers — let ChannelLib.depositBody
    ///         (delegatecall, msg.sender==this) invoke the internal refreshes.
    function refreshHoldingsSelf(address stable) external {
        if (msg.sender != address(this)) revert NotSelf();
        _refreshHoldings(stable);
    }
    function refreshAllHoldingsSelf() external {
        if (msg.sender != address(this)) revert NotSelf();
        _refreshAllHoldings();
    }

    /// @notice Resolve a token's AAVE-v4 reserve-id. GHO/USDG use their
    ///         construction-time immutables; dual-venue stables (USDC/USDT)
    ///         use the generalized `aaveReserveId` mapping wired in setVault.
    ///         Returns 0 for tokens with no Aave leg (caller treats as "not
    ///         on AAVE").
    function _reserveIdOf(address token) internal view returns (uint256) {
        return token == GHO  ? GHO_RESERVE_ID
             : token == USDG ? USDG_RESERVE_ID
             : aaveReserveId[token];
    }

    /// @notice Live AAVE-routed asset balance. Returns 0 for tokens with no
    ///         Aave leg. Used by BasketLib.get_deposits / _valueStable (the
    ///         spoke leg) for GHO/USDG AND the dual-venue USDC/USDT.
    /// @dev AAVE-v4 reserve id for `token`, or 0 if the spoke is unwired OR the token
    ///      has no reserve — the shared guard for aaveBalance/aaveShares. (When this is
    ///      nonzero, AAVE_SPOKE is guaranteed nonzero too, so the callers' spoke calls
    ///      are safe.)
    function _aaveReserve(address token) internal view returns (uint256) {
        if (AAVE_SPOKE == address(0)) return 0;
        return _reserveIdOf(token);
    }

    function aaveBalance(address token) public view returns (uint) {
        uint256 reserveId = _aaveReserve(token);
        if (reserveId == 0) return 0;
        return IAaveV4Spoke(AAVE_SPOKE).getUserSuppliedAssets(
            reserveId, address(this));
    }

    /// @notice Scaled supply shares (principal basis) for the yield factor — the
    ///         Aave-v4 analog of a 4626 `balanceOf`. Mirrors `aaveBalance`'s
    ///         reserve-id resolution. `aaveBalance/aaveShares` = liquidity index.
    function aaveShares(address token) public view returns (uint) {
        uint256 reserveId = _aaveReserve(token);
        if (reserveId == 0) return 0;
        return IAaveV4Spoke(AAVE_SPOKE).getUserSuppliedShares(
            reserveId, address(this));
    }

    /// @notice Fused volatile-deposit helper. ETH path accepts native via
    /// msg.value (wraps to WETH); BTC path only takes WBTC ERC-20.
    ///         `amount` is the TOTAL deposit (msg.value counts toward it,
    ///         matching Vogue._depositETH convention). Caller passes
    ///         amount=total; msg.value covers some/all of it.
    function _deposit(address asset, address sender, uint amount)
        internal returns (uint sent) {
        // Body reused from SwapLib.depositBody (delegatecall) for EIP-170 relief. `msg.value` is preserved
        // through the delegatecall (same call context) so the ETH-wrap path stays correct; address(this)==Aux
        // holds the value + the pulled tokens. ZeroSent revert kept here (selector preserved).
        // §ISBTC-SPLIT: the caller HAS the asset -- passing a boolean so this could look the same
        // address back up was the hand-rolled dispatch one layer down.
        sent = SwapLib.depositBody(asset, address(WETH), sender, amount);
        if (sent == 0) revert ZeroSent();
    }

    // ─── Native BTC LP integration ──────────────────────────────────
    // Hooks called by BTCChannels.sol (gated via onlyBTCChannels).
    // creditLPForSwap settles the LP's QUID credit after they prove a
    // swap-out BTC delivery via SPV. Swap-out user burned the same
    // amount upstream → total supply conserved. LP BTC stays in their
    // own 2-of-2 channel; Aux never touches it.
    address internal _btcChannels;

    error NotBTCChannels();
    modifier onlyBTCChannels() {
        if (msg.sender != _btcChannels) revert NotBTCChannels(); _;
    }

    // The BTC side rides the SAME merged Vault as the ETH side, so it reuses the
    // `ethVenue` pin — the ETH-VENUE CUSTODY contract. Distinct from Core's `btcVault` since the
    // venue carve; anything BTC-band must go through `CORE.btcVault()`, not this.

    function setBTCChannels(address b) external onlyOwner {
        if (_btcChannels != address(0)) revert BtcChannelsPinned();
        _btcChannels = b;
        // Pin the BTCChannels address on BtcVault (its onlyBtcChannels /
        // onlyBTCChannels gates read it). Channel sats and POOLED_USD are
        // independent accounting domains (channels store sats for routing/
        // swap-out, the V4 BTC pool holds mockBTC/mockUSD_BTC for spot
        // liquidity).
        // ON THE BTC VAULT, not `ethVenue`: those were one address until the venue carve, and
        // `setBTCChannels` is a BTC-BAND function. Read the vault from Core so there is no second pin.
        IBandManager(CORE.btcVault()).setBTCChannels(b);
    }

    // moved to EthVenue (the ETH-venue custody home).

    // creditSwapIn / creditSwapOut (BTC swap-IN/OUT settle) REGROUPED into
    // BtcVault.sol. Their bodies (SwapLib.creditSwap{In,Out}Body) now run in
    // BtcVault's context; the onlyBTCChannels gate moved with them.


    /// @notice Asset-supply dispatcher. WETH → the ETH venue (weETH) +
    ///         increments _vogueETHPrincipal. GHO → AAVE-v4 spoke. BOLD
    ///         → Liquity SP. Other stables → vaults[token] (ERC4626).
    ///         Returns the deposited amount in token-native units.
    function _supply(address token, uint amount) internal returns (uint deposited) {
        // Body extracted to ChannelLib.supplyBody (delegatecall → Aux's storage).
        // WRITE path; dispatch + least-full-healthy routing preserved verbatim.
        return ChannelLib.supplyBody(token, amount, ChannelLib.SupplyCfg(
            address(WETH), GHO, USDG, AAVE_SPOKE, GHO_RESERVE_ID, 
            USDG_RESERVE_ID, ethVenue, stables[stables.length - 1]), 
            vaults, vaultsOf, sp);
    }

    /// @notice Public twin of `_reserveIdOf` — lets ChannelLib.supplyBody resolve
    ///         the dual-venue Aave reserve-id via a self-call (delegatecall).
    function reserveIdOf(address token) external view returns (uint256) {
        return _reserveIdOf(token);
    }

}
