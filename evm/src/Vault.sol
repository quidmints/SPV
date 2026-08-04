
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vogue} from "./Vogue.sol";
// §A.52: the canonical Aux view (was a file-local variant).
import {IAux} from "./imports/Interfaces.sol";
import {Core} from "./Core.sol";
import {Aux} from "./Aux.sol";
import {Basket} from "./Basket.sol";

import {SwapLib} from "./imports/SwapLib.sol";
import {VaultLib} from "./imports/VaultLib.sol";
import {BtcVaultLib} from "./imports/BtcVaultLib.sol";
import {VBtc} from "./VBtc.sol";
import {Types} from "./imports/Types.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IAaveV4Spoke} from "./imports/Interfaces.sol";
import {IWeETH} from "./imports/Interfaces.sol";
import {IRover} from "./imports/Interfaces.sol";
import {IDepositAdapter} from "./imports/Interfaces.sol";
import {IAaveV4Hub} from "./imports/Interfaces.sol";
import {ILevEquity} from "./imports/Interfaces.sol";
import {ILevEquityBtc} from "./imports/Interfaces.sol";

// ════════════════════════════════════════════════════════════════════════
//  Vault — the unified ETH-venue custody + BTC LP/hop side, merged from the
//  formerly-separate EthVenue and BtcVault (5→4 deployable contracts). The
//  two had disjoint state, disjoint function names, and only differed in
//  their "V4" handle (EthVenue→Vogue, BtcVault→Core); here Vogue stays
//  `V4` and Core is `CORE` (the slot EthVenue already carried). Both
//  init paths are preserved: the EthVenue constructor pins the ETH-venue
//  immutables + approvals; `setup(quid)` does BtcVault's post-CORE-init
//  poolStats read + BTC tick seed. Owner is NOT renounced (kept for the
//  one-shot setRover, per EthVenue's design — BtcVault's renounce dropped).
//
//  GATES stay SPLIT, byte-for-byte with the originals — no widening:
//    • onlyUs    = {Vogue(V4), AUX, this}      → arbETH (ETH side)
//    • onlyUsBtc = {Core(CORE), AUX, this} → repack / setBTCChannels
//    • onlyBtcChannels / onlyBTCChannels       → BTC LP register/close + swap
//  Address-specific gates mean every interface-wired caller (Aux.ethVenue /
//  Aux.btcVault / Vogue.EV / Core.BTCVAULT / BTCChannels.btcVault /
//  Basket.BTC_VAULT) just points at this one address — no caller changes.
// ════════════════════════════════════════════════════════════════════════

/// AAVE-v4 GHO spoke. Vault self-supplies WETH (ETH venue 2).

/// Canonical Permit2's allowance-grant surface — the ONLY part of it we need. Euler's `EVault.deposit`
/// pulls via `Permit2.transferFrom`, so the depositor must both approve Permit2 on the token AND grant
/// Permit2 an allowance naming the vault as spender. Declared minimally rather than importing
/// `IAllowanceTransfer` (which drags the whole permit/signature surface we never touch).
interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}


/// ether.fi venue (ETH-side, depositor-chosen). Stake WETH → weETH (restaking
/// yield); value weETH in ETH via getEETHByWeETH; instant-redeem (0.3%) as the
/// deterministic exit (see docs/ETH-MULTI-VENUE.md).
// Protocol-owned weETH/WETH v3 LP (Rover): deposit funds it (mints the position,
// weETH leg via the adapter), take pulls WETH back for the offramp (fee captured
// on our own position). See docs/ETHERFI.md.

/// Aux read surface the Vault needs: WBTC handle (for the shared arbBody
/// signature) and the Galaxy block flag (vault-health state stays Aux-owned).

/// LevManager read surface: the leveraged book's collateral (ETH, 1e18). The weETH lives on external
/// Euler/Morpho as per-LP collateral (the Vault never holds it). The book is counted at NET equity
/// (gross − debt) in both `vogueETH` and `lpShares`; the debt-funded buffer (gross − net) is EXCLUDED from
/// equity and tracked separately as fee-earning band depth (`Vogue.levBuf`/`Vault.levBufBTC` + `totalBuffer`),
/// so it earns fees on the gross weight but never inflates the LP's redeemable claim. The buffer's debt is
/// excluded from committed via `committedUsd18`'s live-debt subtraction (no separate POOLED_USD_*_LEV bucket),
/// so a venue liquidation un-pairs the buffer (`levBurnAll`) without stranding basket `POOLED_USD`.

/// BTC IL-protect: the BtcLevManager's per-LP net-of-debt equity IS protocol BTC backing (8-dec
/// sats), so `syncLevBTC` pairs it as tokenless band depth INTO `POOLED_BTC` (LP.pooled) — that is where
/// the net-equity is counted for solvency. `vogueBTC` is WBTC-only (swept donations + swap deltas) and is
/// NEVER credited the net-equity, so `POOLED_BTC + vogueBTC` (Core shortfall read) is single-counted. Net
/// (not gross): a venue liquidation can't strand POOLED_USD_BTC. Mirrors the ETH `ILevEquity` over the BTC band.
/// Declared once, in imports/Interfaces.sol (it was also BtcVaultLib's `ILevBtc_V`).

contract Vault is Ownable, ReentrancyGuard {

    // ─── ETH-venue immutables (formerly EthVenue) ───────────────────────
    Vogue     internal immutable V4;    // the ETH LP contract
    Core internal immutable CORE;  // the PM (was BtcVault's "V4")
    Aux       internal immutable AUX;
    WETH9     public    immutable WETH;


    address public immutable AAVE_SPOKE;
    /// @notice AAVE-v4 WETH reserve id (ETH venue 2). **0 IS A VALID RESERVE** (mainnet WETH is
    ///         asset 0 → reserve 0), so this is NOT a wiring flag — test `AAVE_SPOKE != 0` instead.
    uint256 public immutable WETH_RESERVE_ID;

    /// @notice WETH yield vault (Galaxy Morpho-V2 in production = 0x1878805799273d10aE96a58201A6f5254CF9824F).
    /// Injected via constructor so tests can swap in a liquid mock when
    /// the production venue is illiquid at the fork block.
    address public immutable GALAXY_VAULT;

    /// @notice Second WETH 4626 curator venue (Euler ETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2).
    /// FUNGIBLE with Galaxy: both are Morpho-style WETH 4626s, so vogueETH/
    /// deliverableETH count both, the withdraw ladder pulls from both, and the
    /// per-vault health/evacuate path treats both as ETH-venue vaults (NOT
    /// stables). 0 = disabled (tests that don't wire a second venue). Depositors
    /// elect it via VENUE_EULER; an Euler incident is written down per-vault via
    /// vaultBlocked[EULER_VAULT], same as Galaxy.
    address public immutable EULER_VAULT;

    /// @notice Third WETH 4626 curator venue (Gauntlet WETH Morpho = 0x43fCd85E8D9D003D515f886891B7C742AC9f92da).
    /// FUNGIBLE with Galaxy/Euler: same Morpho-style WETH 4626, so vogueETH/
    /// deliverableETH count it, the withdraw ladder pulls from it, and the
    /// per-vault health/evacuate path treats it as an ETH-venue vault. 0 =
    /// disabled. Depositors elect it via VENUE_GAUNTLET; a Gauntlet incident is
    /// written down per-vault via vaultBlocked[GAUNTLET_VAULT], same as Galaxy.
    address public immutable GAUNTLET_VAULT;

    // ether.fi (ETH-side venue, depositor-chosen). FIXED mainnet contracts, wired
    // IMMUTABLY in the constructor. The protocol holds only weETH; ETHERFI_LP/EETH
    // are the last-resort no-fee withdrawal NFT queue.
    address public constant ETHERFI_ADAPTER  = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    /// Canonical Permit2 — same address on every chain. Euler's EVault pulls deposits through it.
    address public constant PERMIT2          = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant ETHERFI_REDEEMER = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    address public constant ETHERFI_V3ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address public constant ETHERFI_POOL_A   = 0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3; // weETH/WETH 0.05%
    address public constant ETHERFI_POOL_B   = 0x202A6012894Ae5c288eA824cbc8A9bfb26A49b93; // weETH/WETH 0.01%
    address public constant ETHERFI_LP       = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address public constant ETHERFI_EETH     = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address public immutable WEETH;             // cached from the adapter at construction
    uint24  public immutable ETHERFI_POOL_FEE;  // fee tier of pool A
    uint24  public immutable ETHERFI_POOL_FEE2; // fee tier of pool B (0 = none)

    // ─── Rover (protocol-owned weETH/WETH LP) wiring ───────────────────
    address public ROVER;

    /// @notice The IL-protect orchestrator. Its leveraged book's LIVE net-equity counts in `vogueETH`.
    ///         Pinned once post-deploy (LevManager needs Aux/weETH first). 0 = leverage disabled.
    address public LEV_MANAGER;

    error NotVogueCore();
    error NotSelf();
    error Unauthorized();
    error RoverPinned();
    error LevManagerPinned();
    error NotAux();
    error NoBtcPosition();

    // ─── BTC-side state (formerly BtcVault) ─────────────────────────────
    Basket QUID;

    /// @notice BTC-side LP accounting — parallel to the ETH-side trio in Vogue.
    /// `autoManagedBTC[user].pooled` slot holds the user's pooled WBTC
    /// (8-dec, type-reused from Types.Deposit). `lpSharesBTC` is the sum.
    /// `feesPerShareBTC` accumulates V4 BTC-side trading fees (in WBTC);
    /// `USD_FEES_BTC` accumulates V4 USD-side trading fees from the BTC pool.
    mapping(address => Types.Deposit) public autoManagedBTC;
    uint public lpSharesBTC;
    uint public feesPerShareBTC;
    uint public USD_FEES_BTC;

    /// BTC IL-protect: per-LP LEVERED band slice (8-dec sats) — the mirror of Vogue's `levPooled`.
    /// Backed by the BtcLevManager net-equity (not real channel sats), it earns V4 fees but is
    /// UNWIND-ONLY: it never leaves via a channel splice/close (there's no channel BTC behind it), only
    /// via `syncLevBTC` shrinking to match the manager. Excluded from the LP's withdrawable balance.
    mapping(address => uint) public levPooledBTC;
    /// @notice full-2×: 6-dec USD counterpart of an LP's DEBT-funded BTC buffer leg. Post-fold it folds
    ///         into POOLED_USD_BTC (no separate LEV bucket) and is excluded from committed via the live-debt
    ///         subtraction in committedUsd18. Bounded by the LP's own debt (enforced in BtcVaultLib.levAddBufBtc).
    mapping(address => uint) public levBufferUsdBTC;
    /// @notice NET model (mirror of Vogue.levBuf): per-LP debt-funded BTC BUFFER depth (8-dec sats). It is
    ///         fee-earning V4 depth but NOT equity — EXCLUDED from lpSharesBTC/pooled, INCLUDED in the GROSS
    ///         fee weight (pooled + levBufBTC) and the fee denominator (lpSharesBTC + totalBufferBTC).
    mapping(address => uint) public levBufBTC;
    /// @notice Sum of every BTC LP's levBufBTC — the gross buffer total. Fee denom = lpSharesBTC + this.
    uint public totalBufferBTC;
    address public LEV_MANAGER_BTC;     // pin-once (setLevManagerBTC), distinct from the ETH LEV_MANAGER

    /// Self-managed BTC boundary positions (out-of-range single-sided orders),
    /// keyed by an ID_BTC counter; `positionsBtc` maps an owner to its position
    /// ids. These are user-facing and exit via the self-managed pull/close path.
    mapping(uint => Types.SelfManaged) public selfManagedBtc;
    mapping(address => uint[]) public positionsBtc;
    uint internal ID_BTC;

    /// @notice BTC-leg trading fees ACCRUED to each LP, in native sats.
    ///
    /// @dev WHAT THIS IS: an UNFUNDED per-LP accrual, not a segregated balance. Nothing is
    ///      custodied against it and no sats sit idle anywhere. `settleBtcLp` credits each LP its
    ///      pro-rata share of the BTC-leg fee accumulator here (`SwapLib.pendingFor` over
    ///      `LP.pooled + levBufBTC`); the hop is the party that eventually FUNDS it in real BTC.
    ///      Unlike the USD leg it is never minted as QUID, because the fee is BTC rather than
    ///      basket dollars.
    ///
    /// @dev TWO SETTLEMENT PATHS, and the first is the LIVE PRIMARY ONE:
    ///      1. COMPOUND (default). On a GROW splice the hop funds real sats in and marks up to
    ///         `grewBy` of them as `feeSettleSats` (`BTCChannels.splice`). `settleBtcFeesOwed`
    ///         clears the counter, and the sats DO compound into `LP.pooled` — `registerBtcLp`
    ///         already grew pooled by the full delta, so `delivered` stays invariant. Driven from
    ///         `quid-bridge/channel_driver.rs`, which reads this counter and settles
    ///         `min(owed, grewBy)` opportunistically whenever a grow is happening anyway.
    ///         This REPLACED the standalone settler (`run_lp_fee_settler`, deleted).
    ///      2. AT CLOSE. Whatever is still owed is paid by the hop when the channel closes
    ///         (`settleBtcLp`'s close path reads and deletes the counter).
    ///
    /// @dev CORRECTED 2026-08-01. This NatSpec previously read "NOT compounded into `pooled` ...
    ///      the hop settles it in native BTC at channel close", describing path 2 as if it were the
    ///      only one. That was stale from before the fee-splice landed and it caused a downstream
    ///      doc error; do not restore it.
    mapping(address => uint) public btcFeesOwedSats;

    int24 public UPPER_TICK_BTC;
    int24 public LOWER_TICK_BTC;

    /// @notice (B) Bumped whenever the BTC band ticks RECENTER (repack/reseat in `_rebalance(true)`). The
    ///         BtcLevManager re-anchors its `entrySqrtP`/`E0` when this advances past a position's epoch —
    ///         mirrors `Vogue.reseatEpoch` for the ETH band.
    uint64 public reseatEpochBTC;

    error BtcChannelsPinned();
    error AlreadyInitialized();
    error ZeroTwap();
    error Dust();          // boundary order too small to mint nonzero liquidity
    error NotOwner();      // pullBtc by a non-owner of the position
    error BadPercent();    // pullBtc percent must be 1..100
    error NotAStable();    // BTC self-managed positions are USD-funded (token != 0, no native)
    error NotBTCChannels();
    error SwapOutShort();

    address public btcChannels;

    /// ETH-side trusted callers: Vogue (V4), Aux, self.
    modifier onlyUs {
        if (msg.sender != address(V4)
         && msg.sender != address(AUX)
         && msg.sender != address(this))
            revert Unauthorized(); _;
    }

    /// BTC-side trusted callers: Core (CORE), Aux, self. Kept distinct
    /// from onlyUs so neither gate is widened by the merge.
    modifier onlyUsBtc {
        require(msg.sender == address(AUX)
             || msg.sender == address(CORE)
             || msg.sender == address(this), "403"); _;
    }

    /// BTC-LP register/decrement/exit are driven by channel locks, so they're
    /// gated to BTCChannels (not the public 4626 surface).
    modifier onlyBtcChannels() {
        require(msg.sender == btcChannels && btcChannels != address(0), "403"); _;
    }
    /// onlyBTCChannels (swap credit gate) — same gate, distinct name kept from Aux.
    modifier onlyBTCChannels() {
        if (msg.sender != btcChannels) revert NotBTCChannels(); _;
    }

    /// @notice Pins the ETH-venue wiring. AAVE-v4 WETH (ETH venue 2) is optional —
    /// resolved + approved only if the spoke lists WETH; else venue 2 stays inert.
    /// ether.fi is wired from the fixed mainnet adapter + v3 pool fees, with the
    /// standing approvals set once.
    constructor(address _vogue, address _core, address _aux,
        address _weth, address _aaveSpoke, address _aaveHub,
        address _galaxyVault, address _eulerVault, address _gauntletVault)
        Ownable(msg.sender) {
        V4 = Vogue(payable(_vogue));
        CORE = Core(_core);
        AUX = Aux(payable(_aux));
        VBTC = new VBtc(address(this), address(Aux(payable(_aux)).WBTC()));
        WETH = WETH9(payable(_weth));
        GALAXY_VAULT = _galaxyVault;
        EULER_VAULT = _eulerVault;
        GAUNTLET_VAULT = _gauntletVault;
        // The three WETH-4626 curator slots MUST be pairwise distinct. `VaultLib._vogueETH`
        // SUMS all three (`:97-98`) with no dedup, so aliasing two slots double-counts that
        // vault's WETH as backing — and vogueETH feeds the solvency/backing gate, so it would
        // silently overstate backing (measured: a 10 ETH SPLIT deposit reported vogueETH == 14
        // when gauntlet aliased euler). `_deliverableCap` and `_pull4626` iterate the same three
        // slots and mis-behave the same way. Cheapest correct-by-construction fix: make the
        // aliasing UNREACHABLE at deploy rather than dedup on every read (which would cost
        // bytecode on a hot path, in a contract set where LevManager has 70 bytes of headroom).
        // Zero is exempt — an unwired slot is legitimate and contributes nothing.
        require((_galaxyVault != _eulerVault    || _galaxyVault == address(0))
             && (_galaxyVault != _gauntletVault || _galaxyVault == address(0))
             && (_eulerVault  != _gauntletVault || _eulerVault  == address(0)),
            "vault:dupVenue");
        // NB: AAVE_SPOKE is assigned INSIDE the try below, not here — it doubles as the
        // "venue 2 is wired" flag, so it must stay 0 unless WETH actually resolved.

        if (_aaveSpoke != address(0) && _aaveHub != address(0)) {
            // AAVE-v4 WETH (ETH venue 2). Optional — unwired if WETH isn't listed.
            //
            // WIRING IS KEYED OFF `AAVE_SPOKE`, *NOT* off a nonzero reserve id. Reserve id 0 is a
            // LEGITIMATE reserve: on live mainnet WETH is asset 0 → reserve 0 (chain-verified, and
            // `AaveV4Venue` supplies/borrows against exactly that reserve in a passing fork test).
            // The former `WETH_RESERVE_ID != 0` test therefore read a perfectly-wired venue as
            // "absent" and silently disabled ETH venue 2 — masked for a long time by the old
            // fall-back-to-Galaxy sweep, and fatal once that sweep was removed.
            //
            // `getAssetId` REVERTS for an unlisted asset (it does NOT return 0), so the try/catch —
            // not a zero-check — is the real listedness probe. On revert we leave AAVE_SPOKE at 0
            // and venue 2 stays unwired, with no revert propagated to the deploy.
            try IAaveV4Hub(_aaveHub).getAssetId(address(WETH)) returns (uint256 assetId) {
                WETH_RESERVE_ID = IAaveV4Spoke(_aaveSpoke).getReserveId(_aaveHub, assetId);
                AAVE_SPOKE = _aaveSpoke;
                IERC20(address(WETH)).approve(_aaveSpoke, type(uint).max);
            } catch {}
        }

        // One-time unlimited WETH→Galaxy approval. WETH9 returns bool on approve
        // so a direct call is safe.
        IERC20(address(WETH)).approve(GALAXY_VAULT, type(uint).max);
        // Same standing approval for the second 4626 curator (Euler), if wired.
        if (_eulerVault != address(0)) {
            IERC20(address(WETH)).approve(_eulerVault, type(uint).max);
            // ── PERMIT2 (2026-07-26) — REQUIRED for the real Euler EVault, and the plain allowance
            //    above is NOT enough on its own. Euler's `EVault.deposit` pulls the asset through
            //    canonical Permit2, not `WETH.transferFrom`: the fork backtrace is
            //      Permit2.transferFrom <- EVault.deposit <- EthereumVaultConnector.call
            //      <- VaultLib.supplyVenueBody <- Vault.supplyEulerEth <- Vogue.deposit
            //    and a DIRECT transferFrom is never even attempted, so it routes via Permit2
            //    unconditionally when configured. Without these two grants every Euler deposit
            //    REVERTS — which also reverts every VENUE_SPLIT deposit, since SPLIT has an Euler leg
            //    and (post the no-sink refactor) fails loud instead of sweeping to Galaxy.
            //    Permit2 needs BOTH: an ERC-20 allowance to Permit2 itself, then a Permit2 allowance
            //    naming the vault as spender. Max uint160 amount / max uint48 expiration = standing.
            //    NEVER exercised before today: `supplyEulerEth` had only ever run against an injected
            //    stand-in vault, so this integration was unvalidated on mainnet — the same shape as
            //    the reserve-0 sentinel bug (code that never met its real counterparty).
            IERC20(address(WETH)).approve(PERMIT2, type(uint).max);
            IPermit2Approve(PERMIT2).approve(
                address(WETH), _eulerVault, type(uint160).max, type(uint48).max);
        }
        // Same standing approval for the third 4626 curator (Gauntlet), if wired.
        if (_gauntletVault != address(0))
            IERC20(address(WETH)).approve(_gauntletVault, type(uint).max);

        // ether.fi venue — immutable wiring. Cache weETH + the v3 pool fees from
        // the fixed mainnet contracts and set the standing approvals once.
        WEETH = IDepositAdapter(ETHERFI_ADAPTER).weETH();
        ETHERFI_POOL_FEE  = IUniswapV3Pool(ETHERFI_POOL_A).fee();
        ETHERFI_POOL_FEE2 = IUniswapV3Pool(ETHERFI_POOL_B).fee();
        IERC20(address(WETH)).approve(ETHERFI_ADAPTER, type(uint).max);
        IERC20(WEETH).approve(ETHERFI_V3ROUTER, type(uint).max);   // offramp swap
        IERC20(WEETH).approve(ETHERFI_REDEEMER, type(uint).max);   // instant redeem
        IERC20(ETHERFI_EETH).approve(ETHERFI_LP, type(uint).max);  // wait-path NFT
    }
    receive() external payable {}
    fallback() external payable {}

    /// @notice BTC-side init (formerly BtcVault.setup): pin QUID, read the BTC
    ///         pool slot0 (needs CORE.setup done) and seed the BTC ticks. AUX/
    ///         CORE are constructor-set immutables, so only QUID is taken here.
    ///         Owner is intentionally NOT renounced (setRover needs it).
    function setup(address _quid) external {
        if (msg.sender != owner()) revert Unauthorized();   // was front-runnable
        if (address(QUID) != address(0)) revert AlreadyInitialized();
        QUID = Basket(_quid);
        (uint160 sqrtPriceX96,,) = CORE.poolStats(0, 0, true);
        (LOWER_TICK_BTC,, UPPER_TICK_BTC,) = _updateTicks(sqrtPriceX96, 200);
    }

    // ════════════════════════════════════════════════════════════════
    //                    ETH yield-venue side (was EthVenue)
    // ════════════════════════════════════════════════════════════════

    /// @notice Pin the Rover LP (one-shot, no repoint). Deployed after the Vault
    ///         (Rover needs Aux for setAux), so wired post-deploy. Approves WETH
    ///         so `supplyEtherFiToRover` can fund the position.
    function setRover(address r) external onlyOwner {
        if (ROVER != address(0)) revert RoverPinned();
        ROVER = r;
        IERC20(address(WETH)).approve(r, type(uint).max);
    }

    /// @notice Pin the LevManager (one-shot, no repoint) so `vogueETH` counts the leveraged book's net-equity.
    function setLevManager(address m) external onlyOwner {
        if (LEV_MANAGER != address(0)) revert LevManagerPinned();
        LEV_MANAGER = m;
        // Cascade: allow the LevManager to call Rover.absorb (the down-leg's fee-internal rebalancing
        // hop for freed weETH). We are Rover's `AUX`, so Rover accepts this pin-once from us.
        if (ROVER != address(0)) IRover(ROVER).setLevManager(m);
    }

    /// @notice Pin the BtcLevManager (one-shot) so `vogueBTC` counts the BTC leveraged book's
    ///         net-equity and `syncLevBTC` can read the per-LP target. Distinct from the ETH LEV_MANAGER.
    function setLevManagerBTC(address m) external onlyOwner {
        if (LEV_MANAGER_BTC != address(0)) revert LevManagerPinned();
        LEV_MANAGER_BTC = m;
    }

    /// @notice LIVE sum of the BTC leveraged book's net-equity (8-dec sats) — the BACKING term added to
    ///         `vogueBTC` (Core solvency). try/catch so a venue hiccup can't brick the backing read.
    function totalNetEquityBtc() external view returns (uint) {
        if (LEV_MANAGER_BTC == address(0)) return 0;
        try ILevEquityBtc(LEV_MANAGER_BTC).totalNetEquityBtc() returns (uint ne) { return ne; } catch { return 0; }
    }

    /// @notice Fund Rover with WETH (it mints the weETH leg via the adapter +
    ///         provides the v3 position). Pulls the Vogue-approved WETH, then
    ///         Rover pulls it from us in `deposit`. Gated to Vogue.
    ///         NO exposure cap — over-allocation is a structural non-problem,
    ///         not a bounded one: the Rover refuses to transact off a pool
    ///         that isn't at the unmanipulable staking rate (fair-gated
    ///         repack, fair-floored swaps — see Rover._nearFair/_fairMinOut),
    ///         unwinds without a pool counterparty (decreaseLiquidity), and is
    ///         reachable by the withdraw ladder below — so a dead/shoved pool
    ///         degrades a venue-4 slice exactly like the plain ether.fi venue
    ///         (instant-redeem / wait-NFT), never into principal extraction.
    ///         Sizing is depositor self-selection, like every other venue.
    function supplyEtherFiToRover(uint amount) external returns (uint) {
        if (msg.sender != address(V4)) revert NotVogueCore();   // gate stays here
        return VaultLib.supplyVenueBody(_ethCfg(), 0, amount, address(V4));
    }

    /// @notice ETH-venue = ether.fi. Pull the Vogue-approved WETH and stake it
    ///         into weETH (restaking yield), held at the Vault and valued in
    ///         vogueETH() via getEETHByWeETH. Gated to Vogue (V4).
    function supplyEtherFi(uint amount) external returns (uint) {
        if (msg.sender != address(V4)) revert NotVogueCore();   // gate stays here
        return VaultLib.supplyVenueBody(_ethCfg(), 1, amount, address(V4));
    }

    /// @notice ETH-venue = AAVE-v4 (venue 2). Pull the Vogue-approved WETH and
    ///         supply it to the AAVE-v4 spoke's WETH reserve. Gated to Vogue.
    function supplyAaveEth(uint amount) external returns (uint) {
        if (msg.sender != address(V4)) revert NotVogueCore();   // gate stays here
        return VaultLib.supplyVenueBody(_ethCfg(), 2, amount, address(V4));
    }

    /// @notice OFFRAMP the ether.fi slice of a withdrawal: weETH → WETH for
    ///         `amount` ETH-worth, delivered to `recipient`. The ladder
    ///         (docs/ETH-MULTI-VENUE). Every call try/catch'd. Gated to Vogue.
    function offrampEtherFi(uint amount, address recipient, bool instant)
        external returns (uint served) {
        if (msg.sender != address(V4)) revert NotVogueCore();   // gate stays here
        return SwapLib.offrampBody(amount, recipient, instant, _etherfiCfg());
    }

    /// @dev ether.fi offramp config from Vault immutables/consts (the
    ///      delegatecalled library can't read them). Shared by offrampEtherFi +
    ///      the opportunistic sourcing.
    function _etherfiCfg() internal view returns (SwapLib.OfframpCfg memory) {
        return SwapLib.OfframpCfg({
            weeth: WEETH, rover: ROVER, weth: address(WETH), v3router: ETHERFI_V3ROUTER,
            redeemer: ETHERFI_REDEEMER, lp: ETHERFI_LP,
            poolFee: ETHERFI_POOL_FEE, poolFee2: ETHERFI_POOL_FEE2
        });
    }

    /// @dev ETH-venue immutables gathered for the delegatecalled VaultLib (it
    ///      can't read Vault's immutable slots). Shared by every VaultLib forward.
    function _ethCfg() internal view returns (VaultLib.EthCfg memory) {
        return VaultLib.EthCfg({
            weth: address(WETH), aux: address(AUX), galaxy: GALAXY_VAULT,
            euler: EULER_VAULT, gauntlet: GAUNTLET_VAULT, aaveSpoke: AAVE_SPOKE, wethReserveId: WETH_RESERVE_ID,
            rover: ROVER, weeth: WEETH, eeth: ETHERFI_EETH, levManager: LEV_MANAGER
        });
    }

    /// @notice WETH currently supplied to AAVE-v4 (yield-accrued). 0 if unwired.
    function aaveEthBalance() public view returns (uint) {
        return VaultLib.aaveBal(_ethCfg());
    }

    /// @notice Current ETH-equivalent backing on the ETH side — AGGREGATE across
    ///         the depositor-chosen venues: Galaxy + Euler (Morpho-style WETH
    ///         4626s) + ether.fi weETH valued in ETH + AAVE-v4 WETH + idle + Rover.
    ///         Body in VaultLib.vogueETH (delegatecall; see its docblock).
    function vogueETH() public view returns (uint) {
        return VaultLib.vogueETH(_ethCfg());
    }

    /// @notice Unified Vogue↔Vault op selector (ETH side only; the BTC ops that
    ///         shared this entry stayed in Aux's vogueBTC counter).
    /// @param  op    0=deposit, 1=take, 2=return current balance
    function vogueOp(bool /*isBTC*/, uint amount, uint8 op, bytes32 /*ctx*/)
        external returns (uint sent) {
        if (msg.sender != address(V4)) revert NotVogueCore();
        // Body in SwapLib.vogueOpBody (ETH-only; the dead BTC branches + result
        // struct were removed). isBTC/ctx stay in the signature for the V4 caller
        // ABI but are unused. The live ETH claim is read via vogueETH() (real 4626
        // shares), not a stored principal.
        sent = SwapLib.vogueOpBody(amount, op, WETH, vogueETH());
    }

    // REMOVED: _arbEth / arbETH — the ETH-pool shortfall buy from basket surplus.
    // Toxic (spent the shared safety margin to patch a usually-impermanent shortfall)
    // and now caller-less (Vogue._withdraw + Core.refillETH both removed). IL is borne
    // fairly via the share price (convertToAssets = pro-rata of vogueETH).

    /// @notice DELIVERABLE ETH backing for the redemption path. vogueETH
    ///         already writes Galaxy down to maxWithdraw WHEN BLOCKED, but values it
    ///         at convertToAssets when UNBLOCKED — so a frozen-but-unflagged Galaxy
    ///         would let the redemption ETH leg over-burn QU!D for ETH it can't
    ///         source. This caps the Galaxy term at maxWithdraw ALWAYS, so the ETH
    ///         leg DEFERS the undeliverable slice (the ETH analog of _illiquidLoss).
    ///         weETH/AAVE/idle/Rover legs stay — their freeze is a narrower residual.
    ///         Body in VaultLib.deliverableETH (delegatecall; see its docblock).
    function deliverableETH() external view returns (uint total) {
        return VaultLib.deliverableETH(_ethCfg());
    }

    // (arbETH removed — see note above deliverableETH.)

    // ─── Self-gated supply/withdraw trampolines ──────────────────────────────
    /// @notice Self-gated wrappers for the WETH supply/withdraw branches.
    ///         DELEGATECALL'd library functions (vogueOpBody / arbBody) reach
    ///         back here via IAux(address(this)).X(...) — msg.sender ==
    ///         address(this) so the gate passes.
    function supplySelf(address token, uint amount) external returns (uint deposited) {
        if (msg.sender != address(this)) revert NotSelf();
        return _supplyETH(token, amount);
    }

    function withdrawSelf(address token, uint amount, address to) external returns (uint sent) {
        if (msg.sender != address(this)) revert NotSelf();
        return _withdrawETH(token, amount, to);
    }

    /// @notice Aux-gated WETH supply. Aux's basket-side `_supply(WETH)` (the
    ///         BOLD/SP liquidation re-supply) routes here: pull the WETH gain
    ///         from Aux (standing approval) then run the same Galaxy/AAVE-incident
    ///         deposit. Returns the deposited amount.
    function supplyFromAux(uint amount) external returns (uint) {
        if (msg.sender != address(AUX)) revert NotAux();   // gate stays here
        return VaultLib.supplyVenueBody(_ethCfg(), 4, amount, address(AUX));
    }

    /// @notice Aux-gated WETH withdraw. Aux's basket-side `_withdraw(WETH)`
    ///         (redemption / take / ETH-fallback legs) routes here. Runs the
    ///         idle→ether.fi→Galaxy→AAVE ladder and delivers `to`.
    function withdrawForAux(uint amount, address to) external returns (uint) {
        if (msg.sender != address(AUX)) revert NotAux();
        return _withdrawETH(address(WETH), amount, to);
    }

    /// @notice WETH supply — default Galaxy (Morpho 4626) + increments principal.
    ///         Only the WETH branch lives here; body in VaultLib.supplyETH.
    function _supplyETH(address token, uint amount) internal returns (uint deposited) {
        return VaultLib.supplyETH(_ethCfg(), token, amount);
    }

    /// @notice ETH-venue = Euler (second WETH 4626 curator). Pull the
    ///         Vogue-approved WETH and deposit to Euler. Gated to Vogue (V4).
    ///         FUNGIBLE: counted in vogueETH and pulled by the withdraw ladder
    ///         like Galaxy; no separate per-LP slice (Galaxy carries none either).
    function supplyEulerEth(uint amount) external returns (uint) {
        if (msg.sender != address(V4)) revert NotVogueCore();   // gate stays here
        return VaultLib.supplyVenueBody(_ethCfg(), 3, amount, address(V4));
    }

    /// @notice ETH-venue = Gauntlet (third WETH 4626 curator). Pull the
    ///         Vogue-approved WETH and deposit to Gauntlet. Gated to Vogue (V4).
    ///         FUNGIBLE: counted in vogueETH and pulled by the withdraw ladder
    ///         like Galaxy/Euler; no separate per-LP slice.
    function supplyGauntlet(uint amount) external returns (uint) {
        if (msg.sender != address(V4)) revert NotVogueCore();   // gate stays here
        return VaultLib.supplyVenueBody(_ethCfg(), 5, amount, address(V4));
    }

    /// @notice WETH withdraw — idle-then-Galaxy(+ether.fi opportunistic)+AAVE+Rover
    ///         ladder. Body in VaultLib.withdrawETH (delegatecall; see its docblock).
    function _withdrawETH(address token, uint amount, address to)
        internal returns (uint sent) {
        return VaultLib.withdrawETH(_ethCfg(), _etherfiCfg(), token, amount, to);
    }

    // ─── Vault-health ETH-venue hook (state stays Aux-owned) ─────────────────
    /// @notice ETH-VENUE incident drain for a WETH 4626 curator (Galaxy or
    ///         Euler): pull the WITHDRAWABLE WETH to the AAVE haven (or hold at
    ///         the Vault if AAVE-WETH is unwired). Gated to Aux — Aux's
    ///         evacuate/poke path drives this per-vault (vault-health state lives
    ///         in Aux, but the ETH-venue positions are custodied here). MUST be a
    ///         wired ETH 4626 (Galaxy/Euler) — a stable vault is never routed here.
    function evacuateVenue(address vault) external {
        if (msg.sender != address(AUX)) revert NotAux();
        VaultLib.evacuate(_ethCfg(), vault);
    }

    /// @notice ETH 4626 venue position read for Aux's permissionless poke
    ///         (illiquidity check reads the holder's balance/maxWithdraw; the
    ///         holder is the Vault). Returns (reported, liquid) in WETH terms.
    function venuePosition(address vault) external view returns (uint reported, uint liquid) {
        if (vault == address(0)) return (0, 0);
        reported = IERC4626(vault).convertToAssets(IERC4626(vault).balanceOf(address(this)));
        // Shares the ONE `withdrawable` definition with the four VaultLib consumers. This read is the
        // liquidity ratio behind the PERMISSIONLESS `Aux.pokeVaultHealth`, so a wrong definition here
        // is not a mis-report — it BLOCKS and then EVACUATES the venue. A Morpho-V2 vault runs ~0 idle
        // by policy (Galaxy: 8971 WETH held, 0 idle), so the old raw `maxWithdraw` read it as
        // permanently illiquid and any caller could have drained a healthy venue on that false signal.
        // WIRED 2026-07-26 — the paragraph above described this fix but the code below it still read a
        // raw `maxWithdraw`, so the hazard it warns about was LIVE: real Galaxy reports `maxWithdraw`
        // AND `maxRedeem` of 0 against a fully withdrawable position, i.e. 0% liquid, and anyone could
        // have used that false signal to block-then-evacuate a healthy venue through the permissionless
        // poke. `_withdrawableOf` returns the reported position for a Morpho-V2 impl and the honest
        // `maxWithdraw` for everything else. It is itself GUARDED, so a venue whose view reverts
        // (Euler's real EVault does — `EVC.getControllers` inside `maxWithdraw`) reads as 0 liquid
        // rather than making the poke revert; 0 is the conservative side here too.
        liquid = VaultLib._withdrawableOf(vault, address(this));
    }

    // ════════════════════════════════════════════════════════════════
    //                        BTC side (was BtcVault)
    // ════════════════════════════════════════════════════════════════

    function setBTCChannels(address b) external onlyUsBtc {
        if (btcChannels != address(0)) revert BtcChannelsPinned();
        btcChannels = b;
    }

    // ═══════════════════════ vBTC — the TOKEN face now lives in `VBtc` (§J.2) ═══════════════════════
    // The EVM representation of LN-custodied BTC used as the BTC IL-protect collateral. The ERC-20 + 4626
    // face (supply, balances, transferability) was SEGREGATED out of this contract into `VBtc.sol`; what
    // stays HERE is the BAND ACCOUNTING (`autoManagedBTC`, `levPooledBTC`) plus the expose/unexpose gate.
    // THE SPLIT IS EXACT, not a redesign: `exposeBtcToLev` still performs the whole funded→lev
    // reclassification and its `InsufficientChannelBtc` check — it delegates ONLY the supply mutation, so
    // `LP.pooled` stays untouched and the single-count property that made the original merge worth having
    // is preserved. WHY: supply-level invariants (a future `redeemVBtc(sats, p2trScript)`, and
    // `Σ outstanding vBTC ≤ Σ free channel capacity`) belong WITH supply, not buried in band accounting.

    /// The vBTC token. Deployed BY this contract, so `VBtc.VAULT == address(this)` holds BY CONSTRUCTION —
    /// no setter, no deploy-ordering hazard, and supply authority can never be misconfigured. Venues and
    /// the Morpho market take THIS address as `collateralToken` (it is the token; the Vault is not).
    VBtc public immutable VBTC;

    error NotLevManagerBtc();
    error InsufficientChannelBtc();

    /// @notice SAME-BTC leverage (replaces the "LP pre-holds vBTC + transferFrom" roundtrip): reclassify
    ///   `sats` of the LP's FREE channel band BTC — already POOLED_BTC depth via `registerBtcLp` — as the
    ///   levered slice, and mint the matching vBTC face to the LevManager for venue collateral. NO new BTC
    ///   enters the pool: the channel BTC was already banked, so `LP.pooled` is UNCHANGED (no double-count) —
    ///   only `levPooledBTC` grows (funded→lev, withdrawal-excluded). vBTC is thus only ever "minted" against
    ///   real channel BTC (here), never conjured. Inverse of
    ///   `unexposeBtcFromLev`. Gated to the pinned LevManager (the sole leverage authority).
    function exposeBtcToLev(address lp, uint sats) external returns (bool) {
        if (msg.sender != LEV_MANAGER_BTC) revert NotLevManagerBtc();
        // Storage-mutation body in BtcVaultLib.vbtcExposeBody (delegatecall — EIP-170); gate + emit stay here.
        BtcVaultLib.vbtcExposeBody(autoManagedBTC, levPooledBTC, lp, sats);
        VBTC.mintTo(msg.sender, sats);   // the Transfer event is the TOKEN's to emit, not ours
        return true;
    }

    /// @notice Close-side inverse: burn the `sats` vBTC the manager withdrew from the venue and convert the
    ///   LP's levered slice back to FREE channel band depth (lev→funded). `LP.pooled` is UNCHANGED, so the
    ///   LP's band position simply un-freezes — grown by leverage gain / shrunk by loss (the LP bears its
    ///   own leverage P&L), since a preceding `syncLevBTC` marked `levPooledBTC` to the live net-equity == `sats`.
    ///   The LP never receives loose vBTC (that would double-claim the same channel BTC).
    function unexposeBtcFromLev(address lp, uint sats) external returns (bool) {
        if (msg.sender != LEV_MANAGER_BTC) revert NotLevManagerBtc();
        // Storage-mutation body in BtcVaultLib.vbtcUnexposeBody (delegatecall — EIP-170); gate + emit stay here.
        VBTC.burnFrom(msg.sender, sats);   // reverts if the manager lacks the sats — checked BEFORE the band moves
        BtcVaultLib.vbtcUnexposeBody(levPooledBTC, lp, sats);
        return true;
    }

    /// @notice BTC-side parallel of Vogue.totalShares — a VIEW over lpSharesBTC.
    /// Re-arms the BTC shortfall/delivery trigger in Core.
    /// @notice §E5 (BTC mirror of `Vogue.creditSkewPremium`) — route the retained scarcity premium
    ///         to BTC-band LPs via the same per-share accumulator their trading fees use. GROSS fee
    ///         weight (`lpSharesBTC + totalBufferBTC`), matching the `feeDenom` the rebalance body
    ///         already passes. `onlyUsBtc` because that is the gate naming CORE explicitly. SAME NAME as
    ///         `Vogue.creditSkewPremium` so Core dispatches by ADDRESS through one interface and one call
    ///         site (rule 2: one declaration) — two branch-local calls cost 180 bytes of Core's EIP-170.
    function creditSkewPremium(uint premium6) external onlyUsBtc {
        (, uint usdInc) = SwapLib.feeIncrements(0, premium6, lpSharesBTC + totalBufferBTC);
        USD_FEES_BTC += usdInc;
    }

    function totalSharesBTC() public view returns (uint) {
        return lpSharesBTC;
    }

    /// @notice The LP's UNLEVERED band-BTC depth (`pooled` minus the leverage slice), in 8-dec sats — the E0
    ///         the BTC IL-protect sizes its debt against (`BtcLevManager` reads it at `openBtcLev`). Mirror of
    ///         `Vogue.bandEthOf`; sizing to this FIXED base (not the buffer's growing collateral) is the
    ///         1/(1−t) over-hedge fix.
    function bandBtcOf(address lp) external view returns (uint) {
        uint p = autoManagedBTC[lp].pooled;
        uint lev = levPooledBTC[lp];
        return SwapLib.plainNet(p, lev);
    }

    /// @dev Read Core's BTC pool ordering. Cached on the Core side.
    function token1isBTC() internal view returns (bool) {
        return CORE.token1isBTC();
    }

    /// @notice (B) The BTC band's current spot √P (Q96) — recorded as `entrySqrtP` at `openBtcLev`. `isBTC` is
    ///         accepted for interface-parity with `Vogue.bandSqrtP`; the Vault is BTC-only, so it always reads
    ///         the BTC pool.
    function bandSqrtP(bool /*isBTC*/) external view returns (uint160 sqrtP) {
        (sqrtP,,) = CORE.poolStats(0, 0, true);
    }

    /// @notice (B) The BTC band's ACTUAL sold-volatile fraction (WAD) since `entrySqrtP` — mirror of
    ///         `Vogue.soldFractionWad`, over the BTC ticks/ordering. Shared pure geometry lives in SwapLib.
    function soldFractionWad(uint160 entrySqrtP) external view returns (uint) {
        (uint160 sqrtP,,) = CORE.poolStats(0, 0, true);
        return SwapLib.soldFractionWad(entrySqrtP, sqrtP, LOWER_TICK_BTC, UPPER_TICK_BTC, token1isBTC());
    }


    /// @notice (B) The BTC band reseat epoch (bumps on tick recenter) — mirror of `Vogue.reseatEpoch`.
    function reseatEpoch() external view returns (uint64) {
        return reseatEpochBTC;
    }

    // ──── shared masterchef engine — BTC-specialized (isBTC=true) ────────

    /// @dev BTC-LP fee settle. Per-LP pro-rata, with the two legs settled in
    ///      their NATIVE denominations: USD-leg → QUID (or banked to usd_owed
    ///      when payTo==0); BTC-leg → native sats (btcFeesOwedSats), settled by
    ///      the hop at channel close.
    function _settleBtcLp(address lpEth, address payTo) internal {
        BtcVaultLib.settleBtcLp(autoManagedBTC[lpEth], btcFeesOwedSats,
            lpEth, payTo, address(QUID), feesPerShareBTC, USD_FEES_BTC,
            autoManagedBTC[lpEth].pooled + levBufBTC[lpEth]); // GROSS fee weight = net pooled + buffer
    }

    // (_distributeV4Fees folded into BtcVaultLib.rebalanceBody — its only caller was _rebalance.)

    /// @notice BTC-side rebalance. Shares SwapLib.rebalanceCore with Vogue; BTC
    ///         has no Morpho yield to sync and no _calcYield metric, so the
    ///         wrapper only reorders + distributes the repack/JIT fees and writes
    ///         the new range back.
    /// @dev Thin forwarder: the fat body (rebalanceCore + fee distribution + reseat/tick writeback) moved to
    ///      BtcVaultLib.rebalanceBody (delegatecall — EIP-170). `feeDenom` = lpSharesBTC + totalBufferBTC (GROSS
    ///      fee weight); the value-type accumulators + ticks + reseat epoch are written back here. Logic unchanged.
    function _rebalance(bool isBTC) internal returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity, uint resolvedTwap) {
        BtcVaultLib.RebalOut memory o = BtcVaultLib.rebalanceBody(
            _btcCfg(), isBTC, LOWER_TICK_BTC, UPPER_TICK_BTC,
            feesPerShareBTC, USD_FEES_BTC, reseatEpochBTC, lpSharesBTC + totalBufferBTC);
        feesPerShareBTC = o.feesPerShareBTC; USD_FEES_BTC = o.usdFeesBtc;
        reseatEpochBTC = o.reseatEpochBTC;
        LOWER_TICK_BTC = o.tickLower; UPPER_TICK_BTC = o.tickUpper;
        return (o.sqrtPriceX96, o.tickLower, o.tickUpper, o.myLiquidity, o.resolvedTwap);
    }

    // (S4) public paddedSqrtPrice removed — dead (Core uses VOGUE.paddedSqrtPrice;
    // _rebalance here calls SwapLib.paddedSqrtPrice directly).

    function _updateTicks(uint160 sqrtPriceX96, uint delta)
        internal pure returns (int24 tickLower, uint160 lower,
                             int24 tickUpper, uint160 upper) {
        return SwapLib.updateTicks(sqrtPriceX96, delta);
    }

    // ──── BTC LP path (parallel to ETH) ────
    //
    // A BTC-LP position is created/sized by LOCKING NATIVE SATS IN A CHANNEL —
    // both register/close are gated to BTCChannels, which calls them on open /
    // close. The V4 BTC side is purely virtual (modLP mints/burns mockBTC; no
    // real WBTC moves), so the locked sats stay self-custodied in the channel.

    // Renamed from BtcLpFeesOwed: the BTC-leg fee residual at a full exit is no longer
    // OWED to an external settler — it is FORGONE to the pool (dust; see _resizeBtcLp). Kept as
    // an observability signal so a NON-dust forgone amount (⇒ the fleet missed a pre-exit flush)
    // is alertable. The lp_fees.rs settler + the on-chain lpFeePaid dedup are retired.
    event BtcLpFeesForgone(address indexed lpEth, uint sats);

    /// @notice Channel lock → BTC-pool LP position. `sats` are already locked in
    ///         the channel, so we just add the virtual liquidity + shares.
    /// @dev    THE PRIMARY RESERVOIR REFILL (the "pump"). The native-BTC reservoir is
    ///         virtual — the LP band channels ARE the buffer — so it refills the ORDINARY
    ///         way: LPs stake channel BTC through this path (minted 1:1 as vBTC), pulled in
    ///         when the pool is scarce because scarcity ⇒ a higher swap-skew ⇒ more fee
    ///         capture for the entering LP. That mechanism already exists; there is NO
    ///         bespoke pump/keeper/RFQ — the reservoir self-refills through ordinary LP
    ///         entry. The on-chain swap skew (see {SwapLib-wellSkew}) only PRICES the
    ///         scarcity so this entry is attractive exactly when the reservoir needs it.
    ///         CORRECTED 2026-07-26: the trailing clause used to say "the transient swap-in refill
    ///         bonus is the fast top-up BETWEEN LP-stake arrivals". That bonus was REMOVED
    ///         (`payRefillBonus`, 2026-07-22) precisely so the drain premium STAYS with LPs
    ///         (`retainSkewPremium` -> `Core.skewPremium*`), so there is no swapper-facing bonus to
    ///         top up with. THIS path (LP entry) is the refill; the remaining unbuilt piece is the
    ///         ACTIVE flash-serve (#100 / J.3), which is a flash-and-repay, NOT a bonus.
    function registerBtcLp(address lpEth, uint sats) external nonReentrant onlyBtcChannels {
        // Whole body (checkBacking/TWAP/_rebalance-via-repack + settle + in-range
        // pairing + out-of-range remainder) in BtcVaultLib.registerBtcLp (delegatecall):
        // it operates on the Vault's storage via the passed refs and drives the tick
        // rebalance through the public repack self-call; the value-type lpSharesBTC
        // delta returns for the forwarder.
        lpSharesBTC += BtcVaultLib.registerBtcLp(
            _btcCfg(), autoManagedBTC[lpEth], btcFeesOwedSats,
            lpEth, sats, address(QUID), autoManagedBTC[lpEth].pooled + levBufBTC[lpEth]); // GROSS fee weight
    }

    /// @notice Clear up to `sats` of the LP's owed BTC-leg fees — called by BTCChannels when the hop FUNDS
    ///         those fees into a grow-splice: they compound into the LP's `pooled` via `registerBtcLp`, and the
    ///         bigger pooled share grows the LP's cooperative-close payout to `btcRecipientOf`. This retired the
    ///         standalone settler (`run_lp_fee_settler`, deleted from quid-bridge). NOTE: an earlier version of
    ///         this line said the hop also keysends the same sats onto the LP's Lightning balance off-chain —
    ///         that leg is OBSOLETE under the delegation model, where the LP runs no Lightning node at all.
    ///         CLAMPED: can never clear more than is owed (BTCChannels already caps `sats` at the spliced `delta`,
    ///         so the hop can only clear fees it actually funded in — no theft, no over-settle).
    function settleBtcFeesOwed(address lpEth, uint sats) external onlyBtcChannels {
        uint owed = btcFeesOwedSats[lpEth];
        btcFeesOwedSats[lpEth] = owed > sats ? owed - sats : 0;
    }

    // ═══════════════════════════ BTC IL-PROTECT: levered band slice ═══════════════════════════
    // Mirror of Vogue.syncLev/_levAdd/_levBurn over the BTC band. The BtcLevManager holds the LP's
    // vBTC collateral on external Euler/Morpho; its NET-of-debt equity (8-dec sats) is paired here as
    // TOKENLESS band depth so the LP earns V4 fees on its IL-protected position, backed by vogueBTC.

    /// @notice Re-sync `lp`'s levered BTC band slice to the BtcLevManager's authoritative net-equity.
    ///         Permissionless (like Vogue.syncLev): it only moves the tokenless levered slice to match
    ///         the manager (the keeper pokes it via the manager's hook). GROW pairs net-equity in-range
    ///         as depth; SHRINK/liquidation burns it. No new channel sats — backed by vogueBTC.
    function syncLevBTC(address lp) external nonReentrant {
        // Whole body (skip-check + _rebalance-via-repack + fee-settle + FULL-RESYNC:
        // burn all, re-add gross as two legs) in BtcVaultLib.syncLevBTC (delegatecall)
        // over the Vault's storage via the passed refs (incl. levBufferUsdBTC).
        // Returns (added, burned); the forwarder applies the value-type delta.
        BtcVaultLib.LevDelta memory d = BtcVaultLib.syncLevBTC(
            _btcCfg(), autoManagedBTC[lp], levPooledBTC, levBufferUsdBTC, levBufBTC, btcFeesOwedSats,
            lp, LEV_MANAGER_BTC, address(QUID));
        lpSharesBTC = lpSharesBTC + d.addedNet - d.burnedNet;         // NET equity leg
        totalBufferBTC = totalBufferBTC + d.bufAdded - d.bufBurned;   // GROSS buffer depth (fee weight)
    }

    /// @notice Live θ for the BTC band (yield/(K·σ²)) at the Vault's CURRENT BTC band ticks. Asks Vogue
    ///         (the band-θ math home) with the BTC ticks so BtcVaultLib.addLiqChannel can risk-budget the
    ///         BTC band exactly like the ETH band -- without VaultLib linking VogueLib.
    function derivedThetaWadBtc() external view returns (uint) {
        return V4.derivedThetaWadAt(LOWER_TICK_BTC, UPPER_TICK_BTC, true);
    }

    /// @dev Vault's BTC-side immutables gathered for the delegatecalled VaultLib
    ///      levered-band bodies (mirror of _ethCfg for the BTC cluster).
    function _btcCfg() internal view returns (BtcVaultLib.BtcCfg memory) {
        return BtcVaultLib.BtcCfg({ core: address(CORE), aux: address(AUX) });
    }

    // Per-channel swap-out PROCEEDS settlement moved into BtcVaultLib.settleDelivered
    // (called from resizeBtcLpTail): an on-chain delivery (exactUsd>0) pays the LP
    // exactly the swapper's recorded USD from POOLED_USD_BTC + clears pendingSwapOutUsd;
    // a close/withdrawal splice (exactUsd==0) is all native.

    /// @notice Channel close → exit the LP's FULL BTC position. `lpPayoutSats` is the
    ///         BTC paid to the LP in the close tx (read on-chain via _lpFinalBalance):
    ///         the rest of the funding (funded − lpPayout) was delivered to swappers
    ///         and settles as the LP's QUI proceeds.
    function unregisterBtcLp(address lpEth, uint lpPayoutSats)
        external nonReentrant onlyBtcChannels {
        _resizeBtcLp(lpEth, 0, lpPayoutSats, true, 0);   // full close — all native
    }

    /// @notice Splice-OUT (partial close) → shrink the LP's position by `shrinkSats`
    ///         of funding, WITHOUT retiring the channel. `lpPayoutSats` is the BTC paid
    ///         to the LP in the splice tx (read via _lpFinalBalance); the rest of the
    ///         removed funding (shrinkSats − lpPayout) settles as QUI proceeds. Same
    ///         shape as a full close — just a slice.
    /// `exactUsd` > 0 ⇒ on-chain swap-out delivery: pay the LP exactly that USD as
    /// proceeds. `exactUsd` == 0 ⇒ LP-withdrawal splice-out: all native, no proceeds.
    function resizeBtcLp(address lpEth, uint shrinkSats, uint lpPayoutSats, uint exactUsd)
        external nonReentrant onlyBtcChannels {
        _resizeBtcLp(lpEth, shrinkSats, lpPayoutSats, false, exactUsd);
    }

    /// @dev Shared per-channel exit body. `full` = whole-channel close (shrinkSats :=
    ///      funded); else a partial splice-out shrinking by `shrinkSats`. `lpPayoutSats`
    ///      = BTC the LP took in the close/splice tx; `shrinkSats − lpPayout` is the
    ///      DOLLAR (delivered) slice. ONE settlement model for close and splice-out:
    ///      read the LP's BTC payout from the tx, the remainder is delivered.
    function _resizeBtcLp(address lpEth, uint shrinkSats, uint lpPayoutSats, bool full, uint exactUsd)
        internal {
        // MULTI-HOP: LP.pooled includes the LEVERED slice (levPooledBTC), which has NO channel BTC
        // behind it. Channel funding is only the FREE part — the funded/lev prologue, clamp, the
        // _rebalance (via repack self-call) and the settlement/native-lev-burn/finalize tail all live
        // in BtcVaultLib.resizeBtcLp (delegatecall over the Vault's slots). The guards run BEFORE repack
        // (no rebalance when there's nothing to do); the value-type lpSharesBTC + accumulators apply here.
        // DELIVERY-SIDE de-lever: when this native swap-out delivery (exactUsd>0, partial) draws on the LP's
        // LEVERED slice past the free channel band (shrinkSats > funded = pooled − levPooled), de-lever the
        // shortfall with the delivery's OWN proceeds — repay the LP's debt, free + un-encumber the matching vBTC
        // (lev→funded) so the clamp below delivers the full shrink. Those proceeds became debt-reduction, so we
        // hand resizeBtcLp the FUNDED remainder and settleDelivered mints QUI for that only (single-pay).
        //
        // THIS SPLIT *IS* #104 "internalize-A" — do NOT add a separate internalizeTap path. Single-pay is
        // structural: `delevUsd + (exactUsd - delevUsd) == exactUsd` with delevUsd clamped to [0, exactUsd]
        // (SwapLib.deleverOnDelivery), disjoint sat ranges (funded->QUI, want->de-lever), one-LP-per-slice, the
        // swapId consumed (deliver/reverse mutually exclusive). A second payment path would REINTRODUCE the
        // double-pay this eliminates. If the basket can't source the venue debt-stable, deleverOnDelivery REVERTS
        // (DeleverStableUnavailable) rather than mint unbacked QUI — correct, NOT a gap to "fix" with a flash
        // fallback: delivery is inherently two-phase (the splice pays the swapper BEFORE this settles), so a
        // revert just re-tries the EVM leg against a still-valid SPV proof after the basket refills; the swapper
        // already holds their BTC and nothing is lost. Fork-proved: testReal_DeliverSideDelever_SwapOutTapsLeveredSlice.
        uint delevUsd;
        if (!full && exactUsd > 0 && LEV_MANAGER_BTC != address(0))
            delevUsd = SwapLib.deleverOnDelivery(address(CORE), address(AUX), LEV_MANAGER_BTC,
                autoManagedBTC, levPooledBTC, lpEth, shrinkSats, lpPayoutSats, exactUsd);
        BtcVaultLib.ResizeOut memory o = BtcVaultLib.resizeBtcLp(
            address(CORE), address(QUID), autoManagedBTC, levPooledBTC, levBufBTC, btcFeesOwedSats,
            lpEth, shrinkSats, lpPayoutSats, full, exactUsd - delevUsd);
        lpSharesBTC -= o.sharesRemoved;            // NET equity
        totalBufferBTC -= o.bufRemoved;            // GROSS buffer freed on full close
        if (o.cleared) {
            // FEES-IN-CHANNEL: the BTC-leg fee is settled DURING the position's life by
            // the fee-splice (feeSettleSats compounds owed → LP.pooled), and the fleet flushes
            // any remainder before an exit (the channel STRETCHES to fit — capacity is grown by
            // splice). So at a clean exit only sub-economic DUST can remain, and its sats are
            // ALREADY in POOLED_BTC — deleting the owed-ledger entry (in BtcVaultLib) FORGOES
            // them to the pool (they accrue to the remaining LPs) instead of a separate
            // hop-funded settler payout. This retires the `lp_fees.rs` settler + its on-chain
            // `lpFeePaid` dedup. A NON-dust remainder here means the fleet failed to flush
            // pre-exit (an operational bug, NOT a value leak — the sats stay in the pool);
            // BtcLpFeesForgone surfaces it for monitoring. Force-close loses the residual either
            // way (a dead hop can't flush — and the settler WAS the hop's wallet).
            if (o.owed > 0) emit BtcLpFeesForgone(lpEth, o.owed);
            // Only zero the accumulators when NO fee-earning depth remains (net + gross buffer).
            if (lpSharesBTC == 0 && totalBufferBTC == 0) { feesPerShareBTC = 0; USD_FEES_BTC = 0; }
        }
    }

    /// @notice Harvest accrued BTC-LP fees WITHOUT closing the channel. The USD-leg
    ///         mints as QUID to the LP; the BTC-leg accrues to `btcFeesOwedSats`
    ///         (paid natively by the hop at close, as always). The position
    ///         (`pooled`) is unchanged. `_settleBtcLp` self-rebaselines the fee
    ///         bookmark, so a repeated call yields nothing (no double-pay). Mirrors
    ///         the ETH-side collectFees; the LP claims their own (msg.sender) fees.
    function collectBtcFees() external nonReentrant {
        if (autoManagedBTC[msg.sender].pooled == 0) revert NoBtcPosition();
        _rebalance(true);                     // harvest BTC pool fees into the accumulators
        _settleBtcLp(msg.sender, msg.sender); // USD-leg → QUID; BTC-leg → btcFeesOwedSats; rebaselines
    }

    // ─── Self-managed BTC boundary orders (single-sided, USD-funded) ──────────
    // The BTC-pool twin of Vogue's ETH `outOfRange`/`pull`: a user places a USD-
    // funded single-sided limit order on the USD/WBTC curve that fills as price
    // crosses, exiting via `pullBtc`. Geometry + sizing come from the SAME shared
    // SwapLib LP-engine helpers the ETH path uses (only the pool/ordering differ). USD-
    // funded ONLY — the BTC side is channel/sats-custodied, so there is no native
    // user-deposit leg (the ETH `token==0` branch has no BTC analogue); `token`
    // must be a basket stable, deposited via AUX exactly like the ETH USD branch.

    /// @notice Place a USD-funded single-sided boundary order on the BTC curve.
    /// @param amount  Stable amount to provide.
    /// @param token   Basket stable (must be nonzero — USD-funded only).
    /// @param distance Ticks from current price (±100..±5000, step 100; sign = side).
    /// @param range   Order width in ticks (100..1000, step 50).
    /// @return next   The new position id.
    function outOfRangeBtc(uint amount, address token, int24 distance, int24 range)
        external nonReentrant returns (uint next) {
        // _rebalance stays in the Vault; the rest is BtcVaultLib.outOfRangeBtc
        // (delegatecall) which writes selfManagedBtc/positionsBtc via the passed
        // refs and returns the new id (ID_BTC is value-type). A revert rolls back
        // the _rebalance, so validating inside the lib is behavior-identical.
        (uint160 sqrtP, int24 curLo, int24 curUp,,) = _rebalance(true);
        next = BtcVaultLib.outOfRangeBtc(_btcCfg(), selfManagedBtc, positionsBtc,
            BtcVaultLib.OorArgs({ amount: amount, token: token, distance: distance,
                range: range, owner: msg.sender, sqrtP: sqrtP, curLo: curLo,
                curUp: curUp, idBtc: ID_BTC }));
        ID_BTC = next;
    }

    /// @notice Close (or partially reduce) a self-managed BTC boundary order.
    /// @param id      Position id.
    /// @param percent 1..100 of the position to pull.
    /// @param token   Payout token for the removed liquidity (the filled side).
    /// @dev KNOWN (deferred): if the order FILLED into BTC, that filled
    ///      leg is currently BURNED in Core._settleTokSide (native BTC delivery is
    ///      ETH-only there) — the owner loses the filled BTC. Native delivery needs
    ///      the hop to attribute the OFF-CHAIN fill channel to compensate the
    ///      delivering LP (no on-chain proceeds are generated by a native burn), so
    ///      it's hop-trusted, not part of the provable proceeds collapse.
    function pullBtc(uint id, int percent, address token) external nonReentrant {
        // Body in BtcVaultLib.pullBtc (delegatecall); storage refs mutate in place.
        BtcVaultLib.pullBtc(address(CORE), selfManagedBtc, positionsBtc,
            id, percent, token, msg.sender);
    }


    /// @notice Repack the BTC pool's in-range LP position.
    function repack(bool isBTC) public onlyUsBtc returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity, uint resolvedTwap) {
        return _rebalance(isBTC);
    }

    // ──── BTC swap-IN / swap-OUT credit ────
    //
    // Thin wrappers; the bodies live in SwapLib.creditSwapInBody /
    // creditSwapOutBody. The onlyBTCChannels gate stays HERE; the library bodies
    // carry no gate. The bodies' Aux-side callbacks (toIndex / getTWAPforAsset /
    // deposit) target AUX explicitly (passed in).

    /// @notice Settle a BTC→USD swap-IN. Returns the sats actually converted (< `sats` on an inventory-bounded
    ///         partial), so the hop refunds the `sats − consumedSats` remainder to the seller.
    function creditSwapIn(address seller, uint sats, address token, uint minDeliveredUsd)
        external onlyBTCChannels returns (uint consumedSats) {
        // core = Core (POOLED_*/token1is reads); v4 = this Vault (its
        // repack(bool) drives the BTC rebalance); aux = Aux (the
        // toIndex/getTWAPforAsset/deposit callbacks must target Aux).
        return SwapLib.creditSwapInBody(seller, sats, token, minDeliveredUsd,
            address(CORE), address(this), address(AUX.WBTC()), address(AUX));
    }

    /// @notice Swap-OUT (USD→BTC): the on-curve MIRROR of creditSwapIn. Returns
    ///         `sats` bought AND `usd6` = the exact 6-dec USD pulled in (recorded
    ///         as the obligation's proceeds, paid to the delivering LP).
    function creditSwapOut(address swapper, address token, uint usdAmount, uint minSats)
        external onlyBTCChannels returns (uint sats, uint usd6) {
        return SwapLib.creditSwapOutBody(swapper, token, usdAmount, minSats,
            address(CORE), address(AUX));
    }

    /// @notice Record / clear an on-chain swap-out obligation's USD in Core's
    ///         pendingSwapOutUsd (BTCChannels can't call Core's onlyUs setter, so
    ///         it routes through this onlyBTCChannels wrapper; Vault is onlyUs on
    ///         Core). `addPendingSwapOut` fires at requestSwapOutOnchain; the match
    ///         is `subPendingSwapOut` on REVERSAL (settleSwapIn) — the DELIVERY
    ///         match is done inside `_settleDelivered` (CORE.subPendingSwapOut).
    function addPendingSwapOut(uint usd6) external onlyBTCChannels { CORE.addPendingSwapOut(usd6); }
    function subPendingSwapOut(uint usd6) external onlyBTCChannels { CORE.subPendingSwapOut(usd6); }
}
