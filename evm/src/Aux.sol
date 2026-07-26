
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vogue} from "./Vogue.sol";
import {Basket} from "./Basket.sol";

import {Core} from "./Core.sol";
import {FeeLib} from "./imports/FeeLib.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {ChannelLib} from "./imports/ChannelLib.sol";
import {ISwap} from "./imports/ISwap.sol";
import {SOR, SorPath} from "./imports/SOR.sol";
import {SwapLib} from "./imports/SwapLib.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";


/// AAVE-v4 GHO spoke. Aux self-supplies via the self-allow trampoline.
interface IAaveV4Spoke {
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
        external returns (uint256, uint256);
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)
        external returns (uint256, uint256);
    function getReserveId(address hub, uint256 assetId) external view returns (uint256);
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
    /// Scaled (principal-basis) supply shares — the Aave-v4 analog of a 4626's
    /// share balance. `suppliedAssets/suppliedShares` is the reserve's liquidity
    /// index = its cumulative yield factor (same role as 4626 share price).
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);
}

interface IAaveV4Hub {
    function getAssetId(address underlying) external view returns (uint256);
}

/// Read-only view into BTCChannels for swap-out recipient resolution.
interface IBTCChannels {
    function btcRecipientOf(address user) external view returns (bytes32);
}

/// BtcVault (regrouped BTC side). Aux drives the BTC pool's repack from the
/// public WBTC swap path + the backing-invariant healer, and pins the
/// BTCChannels address on it (mirroring the old V4.setBTCChannels). The BTC
/// LP accounting + swap-credit live entirely on BtcVault.
interface IBtcVault {
    function repack(bool isBTC) external returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity);
    function setBTCChannels(address b) external;
}

/// EthVenue — the ETH yield-venue custody (Galaxy/AAVE/ether.fi WETH), carved
/// out of Aux. Aux keeps thin forwarders (vogueETH/arbETH) for callers that
/// must not change target (BasketLib IAux read, Core), drives the Galaxy
/// vault-health drain (state stays Aux-owned), and reads GALAXY_VAULT off it.
interface IEthVenue {
    function vogueETH() external view returns (uint);
    function deliverableETH() external view returns (uint);
    function GALAXY_VAULT() external view returns (address);
    function EULER_VAULT() external view returns (address);
    function GAUNTLET_VAULT() external view returns (address);
    function supplyFromAux(uint amount) external returns (uint);
    function withdrawForAux(uint amount, address to) external returns (uint);
    function ROVER() external view returns (address);
    function btcChannels() external view returns (address);
}

// Deploy-finalize helpers (see Aux.finalize; linkage asserts live in BasketLib.assertFullyWired).
interface ICollection { function transferFrom(address from, address to, uint256 tokenId) external; }

// (ether.fi / Rover interfaces moved to EthVenue with the venue custody; the
//  Chainlink IAggregatorV3 anchor interface moved to SwapLib with twapAnchorBody.)
contract Aux is // Auxiliary
    Ownable, ReentrancyGuard, SafeCallback, ISwap {
    address[] public stables;

    // Immutable handles. USDC is stables[0] by convention; anywhere
    // code needs the USDC address (ERC-3009, _ensureUSDC) it reads
    // stables[0].
    Vogue internal immutable V4;
    Core internal immutable CORE;
    WETH9 public immutable WETH;
    IERC20 public immutable WBTC;
    // The pool manager lives in SafeCallback's base (ImmutableState) as the
    // inherited `poolManager` immutable — used directly, no local duplicate.

    // QUID (Basket) is set in setQuid after Basket itself is deployed —
    // can't be immutable (circular construction). Pinned-after-set
    // via the QuidPinned guard.
    Basket internal QUID;

    BasketLib.Metrics internal metrics;

    ChannelLib.SPState internal sp;

    // _vogueETHPrincipal + the ETH-venue (Galaxy/AAVE/ether.fi) custody moved
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


    /// @notice SOR path encodings. Each = abi.encode(SorPath) — drains one
    ///         source stable through V4 hops to a terminal (typically WETH).
    ///         Set once at deploy; auxSwap picks best path per call.
    bytes[] internal _pathEncodings;

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
    error BadV4Terminal();
    error BadV4SourceVault();
    error BadV4Last();
    error GHOIsAaveWired();
    error UnknownStable();
    // Body extracted to a private function (deployed ONCE) so the 13 onlyUs sites carry a cheap CALL
    // instead of inlining the 5-address comparison chain each — reclaims ~1 KB of Aux EIP-170 headroom.
    function _requireUs() private view {
        if (msg.sender != address(V4)
         && msg.sender != address(CORE)
         && msg.sender != address(QUID)
         && msg.sender != ethVenue          // the merged Vault (ETH+BTC): arbBody
                                             // delegatecalls into SwapLib with
                                             // address(this)==Vault, so its auxSwap
                                             // callback arrives as msg.sender==Vault.
                                             // Without this the basket→WETH arb (and
                                             // the Vogue/Core shortfall fills) silently
                                             // revert→catch→0. One address (ethVenue)
                                             // covers ETH and BTC arb.
         && msg.sender != address(this))
            revert Unauthorized();
    }
    modifier onlyUs { _requireUs(); _; }

    /// @notice V4 unlock callback. Walks UnlockData.keys hop-by-hop.
    ///         Source vault routes blacklistable stables PM-direct (vault →
    ///         PoolManager via 4626.redeem with receiver=PM, so Aux never
    ///         holds the underlying). Terminal must be WETH or WBTC.
    ///         Gate (msg.sender == poolManager) is in SafeCallback's
    ///         onlyPoolManager modifier on the public `unlockCallback`;
    ///         this override does the routing work.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        // Body extracted to SOR.unlockBody (delegatecall — address(this)
        // stays Aux, so PoolManager settle/take/swap are attributed to
        // the unlock initiator). Keeps Aux under the EIP-170 limit.
        return SOR.unlockBody(data, address(WETH), address(WBTC), poolManager);
    }

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
        address poolManager;
        address weth;
        address wbtc;
        address gho;
        address usdg;
        address aaveSpoke;
        address aaveHub;
        address[] stables;
        address[] vaults;
        bytes[] paths;
    }

    constructor(AuxInit memory a)
        Ownable(msg.sender)
        SafeCallback(IPoolManager(a.poolManager)) {
        WETH = WETH9(payable(a.weth));
        if (a.wbtc != address(0)) WBTC = IERC20(a.wbtc);

        V4 = Vogue(payable(a.vogue));
        CORE = Core(a.core);

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
        // Writes toIndex/tokens/vaults/vaultsOf + copies the SOR _pathEncodings;
        // selector-encoded approve (tolerates USDT-style no-returndata) preserved.
        ChannelLib.initVaultsBody(
            a.stables, a.vaults, a.paths,
            toIndex, tokens, vaults, vaultsOf, _pathEncodings);
        // WETH→Galaxy / ether.fi venue wiring (approvals, weETH cache, v3 pool
        // fees) moved to EthVenue, which now custodies the ETH-side positions.
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
    function _refreshAllHoldings() internal {
        BasketLib.refreshAllHoldingsBody(storedHoldings, stables);
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
        // GALAXY_VAULT / AAVE-WETH wiring moved to EthVenue (which custodies the
        // ETH-side position). The Galaxy evac/poke leg runs THERE (gated to Aux);
        // the cfg only needs the galaxyVault id (to recognise that vault) +
        // ethVenue (to drive its drain) — aaveSpoke/wethReserveId are unused now
        // for the Galaxy leg but kept zeroed for struct shape.
        return BasketLib.VaultHealthCfg({
            galaxyVault:   IEthVenue(ethVenue).GALAXY_VAULT(),
            ethVenue:      ethVenue,
            eulerVault:    IEthVenue(ethVenue).EULER_VAULT(),
            gauntletVault: IEthVenue(ethVenue).GAUNTLET_VAULT()
        });
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
    ///         - `token == 0`: native ETH → wrap → Galaxy via _supply
    ///         - WETH: → Galaxy via _supply (bumps _vogueETHPrincipal)
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
            (uint[15] memory amounts,,,) = get_deposits();
            uint raw = amounts[14];
            metrics = BasketLib.computeMetrics(stats,
                elapsed, raw, amounts[0], amounts[14]);
        } return (metrics.total, metrics.yield);
    }

    /// @notice get_metrics(force=true) with PRE-FETCHED deposit totals. The redeem path
    ///         already ran a fresh get_deposits() this call (freshness); it threads
    ///         that pass's `raw`(=amounts[14]) and `yieldWeighted`(=amounts[0]) here so
    ///         the par-backing metric is recomputed WITHOUT a second get_deposits scan.
    ///         Identical to get_metrics(true): the values are exactly what the forced
    ///         refresh would have fetched (no state change between), and the same
    ///         `metrics` write + yield-accumulator advance happen. onlyUs — an untrusted
    ///         caller passing fabricated totals would poison the metrics cache.
    function get_metricsWith(uint raw, uint yieldWeighted)
        external onlyUs returns (uint, uint) {
        BasketLib.Metrics memory stats = metrics;
        uint elapsed = block.timestamp - stats.last;
        metrics = BasketLib.computeMetrics(stats, elapsed, raw, yieldWeighted, raw);
        return (metrics.total, metrics.yield);
    }

    /// @notice Redemption-side depeg haircut, exposed so the QUID mint path can
    ///         discount its redeemability headroom by the SAME loss redemption
    ///         applies — mint↔redeem symmetry (never mint QUI against the par-phantom
    ///         value of a depegged holding). Non-view (get_deposits refreshes).
    function depegLoss() external returns (uint) { return BasketLib.depegLoss(); }
    function illiquidLoss() external view returns (uint) { return BasketLib.illiquidLoss(); }

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
        BasketLib.assertFullyWired(address(QUID), ethVenue, _btcChannels, address(CORE), address(V4));
        // Burn the committed ANGEL seed NFT: the deploy approved THIS Aux for it (and the Safe/owner() still
        // holds it — only approved, never moved), so we transfer the Safe's ANGEL straight to DEAD via that
        // approval. Runs BEFORE renounce (uses owner()); one-shot (ANGEL gone ⇒ a re-call reverts on transfer).
        ICollection(F8N).transferFrom(owner(), DEAD, QUID.ANGEL());
        renounceOwnership();
    }

    function _pinQuid(address _quid) private {
        if (address(QUID) != address(0)) revert QuidPinned();
        QUID = Basket(_quid);
        WETH.approve(address(V4), type(uint).max);
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
    function getTWAPforAsset(address asset, uint32 period)
        public view returns (uint price) {
        price = SwapLib.twapBody(address(CORE), 
                address(WETH), asset, period);

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
        price = SwapLib.twapBody(address(CORE), 
                address(WETH), asset, period);
                
        (price, stale) = SwapLib.twapResolve(assetPriceFeed[asset], price,
            asset == address(WBTC), TWAP_MAX_DEVIATION_BPS, ASSET_FEED_MAX_AGE);
    }

    /// @notice The live inventory-skew (WAD) the well applies to `asset`'s swap-OUT — the
    ///         pool's reservation-price / RFQ taker-limit offset. Exposed on the SAME unified
    ///         seam as getTWAPforAsset/resolvedTwap so Bebop's RFQ engine AND Khalani's
    ///         Arcadia solver quote against the EXACT number a swap executes at (base × (1−skew)),
    ///         instead of re-deriving it and drifting from settlement. 0 = flush (band price
    ///         stands); rises to the cap when the deliverable inventory is scarce. Read-only.
    function wellSkew(address asset) public view returns (uint) {
        return SwapLib.wellSkew(address(CORE), getTWAPforAsset(asset, 1800), asset == address(WBTC));
    }

    /// @notice The flat swap fee (V4 pool tier, parts-per-million — 420 = 0.042%) every
    ///         stable↔volatile swap pays, exposed on the unified seam so an RFQ maker / solver
    ///         reconstructs the full fill: out ≈ base·(1 − wellSkew)·(1 − swapFeePpm/1e6), then
    ///         the `riskFactor(token)` depeg haircut. The swap fee is FLAT (calcFeeL1 is the
    ///         redeem/draw degradation fee, not charged here); the DYNAMIC axes are wellSkew
    ///         (inventory) + riskFactor (depeg). Mirrors the pool tier set in Core's pool key.
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
            SwapLib.SwapReq(token, asset, forVolatile, amount, minOut, recipient, address(0)),
            SwapLib.SwapToCfg({
                weth: address(WETH), wbtc: address(WBTC), quid: address(QUID),
                core: address(CORE), v4: address(V4), btcVault: ethVenue,
                btcChannels: _btcChannels
            }),
            stables
        );
    }

    /// @notice Self-gated trampolines for swapToBody (delegatecall self-calls).
    ///         (tipSelf already exists below; swapToBody reuses it.)
    function _depositVol(bool isBTC, address sender, uint amount)
        external payable returns (uint) {
        if (msg.sender != address(this)) revert NotSelf();
        return _deposit(isBTC, sender, amount);
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


    // ─── SOR auxSwap ─────────────────────────────────────────────────────
    /// @notice SOR swap entry. Picks the source path whose stable carries the
    ///         highest basket concentration/outflow fee FIRST — `FeeLib.calcFeeL1`,
    ///         computed LIVE from current deposits (see SwapLib._pickBestPath). This
    ///         "fee" is the basket-concentration signal, NOT a V4 pool fee tier (all
    ///         path pools are fee=100); the highest-fee source = the stable the
    ///         protocol is most over-weight in / most wants to shed, so every
    ///         ETH-sourcing op doubles as a rebalance toward target weights. If that
    ///         path fails or is under minOut, falls back to iterating `_pathEncodings`
    ///         in DEPLOY ORDER (most-blacklistable-source-first, per SOR.sol) — the
    ///         runtime fee-pick and the deploy-order fallback are consistent layers,
    ///         not a contradiction. Each attempt try/catch'd; all-fail reverts.
    ///         Caller-agnostic recipient. Used by user routes + internal arbETH/arbBTC.
    ///         Body extracted to SOR.sorAuxSwapBody; wrapper holds the
    ///         nonReentrant lock and passes `_pathEncodings` (memory copy
    ///         of the state array) plus `stables` and `LINK`.
    function auxSwap(
        uint amountIn,
        address output,
        address recipient,
        uint    minOut
    ) external onlyUs nonReentrant returns (uint outAmount) {
        // onlyUs. This overload redeems the protocol's OWN 4626
        // shares and delivers `output` to `recipient` WITHOUT charging msg.sender
        // — ungated it was a direct drain of all routable backing. Every real
        // caller (arbBody's self-call msg.sender==this, Core/Vogue) is onlyUs.
        return SOR.sorAuxSwapBody(
            amountIn, output, recipient, minOut,
            _pathEncodings
        );
    }

    /// @dev External-but-self-only wrapper around the path execution.
    ///      try/catch in auxSwap catches reverts from any path attempt.
    function _tryPath(
        bytes calldata encodedPath,
        uint amountIn, address output,
        address recipient, uint minOut
    ) external returns (uint outAmount) {
        if (msg.sender != address(this)) revert NotSelf();
        // SOR executes in Aux's context (library); the unlock callback
        // for any V4 hops hits Aux.unlockCallback.
        return SOR.executePath(
            encodedPath, amountIn, recipient, minOut, poolManager
        );
    }

    error NoSelfFundedPath();
    /// @notice CALLER-FUNDED SOR swap for the leverage — the caller sends its OWN `amountIn` of
    ///         `sourceAsset` (externally-borrowed dollars), routed through the SAME deployed real-Uniswap-V4
    ///         SOR hops to `output` (WETH), WITHOUT redeeming any basket 4626: it overrides the path source to
    ///         `SOR.SELF_FUNDED` so `unlockBody` settles the provided funds directly. Never touches the
    ///         reserve — the toxicity boundary. This lets `LevManager` delete its bespoke `RealWeethSwapper`
    ///         and reuse the basket's routing (multi-pool, best-path). Output → msg.sender; minOut bounds it.
    function sorSelfFunded(address sourceAsset, uint amountIn, address output, uint minOut)
        external nonReentrant returns (uint outAmount) {
        IERC20(sourceAsset).transferFrom(msg.sender, address(this), amountIn);
        // Body reused from SOR.sorSelfFundedBody (delegatecall — the SAME `_pathEncodings` → `_tryPath` loop
        // as sorAuxSwapBody, no duplicate) for EIP-170 relief; `_pathEncodings` passed as a memory copy exactly
        // as the sorAuxSwapBody wrapper does. Returns 0 if no path matched.
        outAmount = SOR.sorSelfFundedBody(sourceAsset, amountIn, output, msg.sender, minOut, _pathEncodings);
        if (outAmount == 0) revert NoSelfFundedPath();
    }

    error NoReversePath();
    /// @notice CALLER-FUNDED **REVERSE** SOR swap: `sourceVol` (WETH or WBTC) -> `targetStable` via the SAME
    ///         real-Uniswap-V4 hops as the stable's forward path, run backwards (the leverage de-lever leg — sell
    ///         freed volatile back to the borrowed stable). The caller sends its OWN `amountIn` of `sourceVol`;
    ///         routed WITHOUT touching the reserve (the toxicity boundary), multi-hop. Output -> msg.sender; minOut
    ///         bounds it. Symmetric to `sorSelfFunded` (stable -> volatile) — one bidirectional caller-funded SOR
    ///         serving BOTH the ETH (WETH) and BTC (WBTC) de-lever, no bespoke DEX code.
    function sorSelfFundedReverse(address sourceVol, address targetStable, uint amountIn, uint minOut)
        external nonReentrant returns (uint outAmount) {
        IERC20(sourceVol).transferFrom(msg.sender, address(this), amountIn);
        outAmount = SOR.sorSelfFundedReverseBody(sourceVol, targetStable, amountIn, msg.sender, minOut, _pathEncodings);
        if (outAmount == 0) revert NoReversePath();
    }

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

    // ─── ETH yield venue (Galaxy/AAVE/ether.fi) — REGROUPED into EthVenue ────
    // The WETH-side custody (Galaxy 4626 shares, AAVE WETH, weETH) + its ops
    // (supplyETH/withdrawETH, supplyEtherFi/supplyAaveEth, offrampEtherFi,
    // _sourceWethFromEtherfi, supplyEtherFiToRover, setRover, vogueOp, vogueETH,
    // aaveEthBalance, arbETH) now live on EthVenue. Aux keeps a pinned handle +
    // thin forwarders only where callers must not change target.

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
    ///         redeem) is cherry-pick-free and pays only the directional baseRate;
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
        BasketLib.redeemAsBody(BasketLib.RedeemArgs(
            amount, source, recipient,
            address(CORE), address(QUID), address(V4), address(WETH), preferred));
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
                    uint loss = FullMath.mulDiv(spTotal, sev > 10000 ? 10000 : sev, 10000);
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
        // baseRate for BOTH draw modes (pro-rata AND targeted) — a targeted redeem is
        // still a redemption. A swap taking USD out as one specific stable
        // (token!=QUID) is normal flow, not a redemption, so brBps=0.
        return BasketLib.takeBody(_takeArgs(who, amount, token, seed, preferred));
    }

    /// @dev Shared TakeArgs builder for take()/5 and takeWith()/7 (identical
    ///      12-field construction). Accrues the directional baseRate HERE (state
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
    ///         the same TakeArgs as take()/5 — the directional baseRate still accrues.
    function takeWith(address who, uint amount, address token, uint seed, address preferred,
        uint[15] memory amounts, uint[15] memory yieldW) public onlyUs returns (uint sent) {
        return BasketLib.takeBodyWith(
            _takeArgs(who, amount, token, seed, preferred), amounts, yieldW);
    }

    // ─── Directional redemption fee: Liquity-style decaying baseRate ──────────
    // baseRate storage (`_br`) + `_touchBaseRate` + BR_DECAY/BR_MAX_MIN REMOVED here — the Liquity-style
    // directional redemption velocity toll. See `_takeArgs` above for the full rationale: QU!D has no peg-arb
    // loop to defend (unlike Liquity), so the toll had no peg to protect; peg-defense redemptions are scheduled
    // by 6909. Outflow control is now the depeg haircut only.

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
        return BasketLib.backingCoreBody(address(CORE), address(V4), ethVenue);
    }

    /// @notice Asset-withdraw dispatcher (mirror of _supply). WETH idle-
    ///         then-Galaxy + decrements principal. GHO via AAVE-v4 try/catch
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
    function _deposit(bool isBTC, address sender, uint amount)
        internal returns (uint sent) {
        // Body reused from SwapLib.depositBody (delegatecall) for EIP-170 relief. `msg.value` is preserved
        // through the delegatecall (same call context) so the ETH-wrap path stays correct; address(this)==Aux
        // holds the value + the pulled tokens. ZeroSent revert kept here (selector preserved).
        sent = SwapLib.depositBody(isBTC ? address(WBTC) : address(WETH), address(WETH), sender, amount);
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
    // `ethVenue` pin (formerly a duplicate `btcVault` slot held equal to it via a
    // wire assertion). swapTo / _backingCore / the BTCChannels pin all read it.

    function setBTCChannels(address b) external onlyOwner {
        if (_btcChannels != address(0)) revert BtcChannelsPinned();
        _btcChannels = b;
        // Pin the BTCChannels address on BtcVault (its onlyBtcChannels /
        // onlyBTCChannels gates read it). Channel sats and POOLED_USD_BTC are
        // independent accounting domains (channels store sats for routing/
        // swap-out, the V4 BTC pool holds mockBTC/mockUSD_BTC for spot
        // liquidity).
        IBtcVault(ethVenue).setBTCChannels(b);
    }

    // Rover (protocol-owned weETH/WETH LP) wiring + setRover/supplyEtherFiToRover
    // moved to EthVenue (the ETH-venue custody home).

    // creditSwapIn / creditSwapOut (BTC swap-IN/OUT settle) REGROUPED into
    // BtcVault.sol. Their bodies (SwapLib.creditSwap{In,Out}Body) now run in
    // BtcVault's context; the onlyBTCChannels gate moved with them.


    /// @notice Asset-supply dispatcher. WETH → Galaxy (Morpho 4626) +
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
