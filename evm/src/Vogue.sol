
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {SwapLib} from "./imports/SwapLib.sol";
import {VogueLib} from "./imports/VogueLib.sol";

import {Types} from "./imports/Types.sol";
import {Core} from "./Core.sol";
import {Basket} from "./Basket.sol";
import {Aux} from "./Aux.sol";
import {ILevHost} from "./imports/Interfaces.sol";

/// EthVenue — the ETH yield-venue custody (Galaxy/AAVE/ether.fi WETH) carved out
/// of Aux. Vogue routes its WETH venue ops here. vogueETH() is still read via AUX
/// (a thin forwarder), so only the WRITE ops (vogueOp/supply*/offramp/arb) re-point.
interface IEthVenueV {
    function vogueOp(bool isBTC, uint amount, uint8 op, bytes32 ctx) external returns (uint);
    function supplyEtherFi(uint amount) external returns (uint);
    function supplyAaveEth(uint amount) external returns (uint);
    function supplyEulerEth(uint amount) external returns (uint);
    function supplyGauntlet(uint amount) external returns (uint);
    function offrampEtherFi(uint amount, address recipient, bool instant) external returns (uint);
    function supplyEtherFiToRover(uint amount) external returns (uint);
}

/// IL-protect fee lane: Vogue reads the LevManager through the Vault's already-secure one-shot pin
/// (`ethVenue.LEV_MANAGER()`), so `syncLev` needs NO new trust surface of its own (Vogue renounces ownership
/// at setup). `netEquityEth(lp)` is the LIVE net-of-debt equity the levered slice is sized to.
// §4.2 / #109: force-close an LP's OWN in-band levered slice on band-exit (gated to the vogueSyncHook == this
// Vogue). Repays debt + hands the freed collateral (LP's full residual) back to the LP. See §G.7.
interface ILevClose  { function closeLevFor(address lp, uint256 minOut) external; }
interface ILevEquityV {
    function netEquityEth(address lp) external view returns (uint);   // coll − debt (band-backing, NET)
    function grossCollateralEth(address lp) external view returns (uint); // full 2× collateral (band CAPACITY)
    function debtUsd(address lp) external view returns (uint);        // the short-stable leg (buffer USD, 1e18)
    function totalNetEquityEth() external view returns (uint);        // aggregate lev net-equity (excl from venue yield)
}

contract Vogue is
    Ownable, ReentrancyGuard {
    error AlreadyInitialized();
    error WrongV4();
    error Dust();
    error NoPosition();
    error InsufficientBalance();
    error AllowanceFlow();
    error ZeroTwap();
    error NotOwner();
    error BadPercent();

    uint constant WAD = 1e18;
    Core V4; WETH9 WETH;

    // ETH-venue pick (depositor-chosen, no primary), passed PER DEPOSIT via the
    // 3-arg deposit/mint overloads — no standing per-address setting, no separate
    // setter tx. The 2-arg 4626 entrypoints route to the SPLIT default.

    // RESOLVED 2026-07-27 (was the last surviving user [TODO]). The concern was that an LP withdraws
    // only from the venues they directed to, while their FEE slices were never part of that deposit and
    // we do not track where those slices landed. USER'S CALL: let withdrawals source fee value from ANY
    // venue — the direction constraint existed only so nobody is forced into ether.fi's wait time, and
    // anything broader is unnecessarily heavy.
    //
    // VERIFIED: THE CODE ALREADY DOES EXACTLY THIS.
    //  • Non-ether.fi venues are FUNGIBLE on exit — "Galaxy + Euler are fungible; pull from each at its
    //    maxWithdraw" (VaultLib) — so a withdrawal already sources from whichever venue can pay.
    //  • `ethfiBacked` is annotated "the ONLY" per-LP isolated slice, and an LP with `ethfiBacked == 0`
    //    "skips this and never touches the offramp/wait/fee".
    //  • That slice is credited ONLY on the deposit path (`ethfiBacked[pledge] += min(placed, sent)`),
    //    sized by principal actually routed to ether.fi/Rover. FEES ARE NEVER ADDED TO IT, so accrued
    //    fee value can never drag an LP into the offramp.
    // ⇒ ether.fi isolation is principal-only and opt-in by routing; everything else is fungible. No code
    //   change was required — the design already matched the intent.  

    // Venue codes (per-deposit; NO default sink): 0 = SPLIT (equal 5-way, below), 2 = AAVE-v4 (spoke
    // supply/withdraw — 4626-LIKE, aToken/spoke, not a true ERC4626), 3 = Galaxy (its OWN Morpho WETH
    // 4626 vault), 4 = ether.fi (routed through the protocol-owned Rover weETH/WETH v3 LP; attributed to
    // the ether.fi slice, exits via the offramp ladder's Rover rung), 5 = Euler, 6 = Gauntlet.
    // There is deliberately NO ether.fi venue code (the old "1"): per the venue TODO above, ether.fi is
    // NEVER a distinct user choice — it always goes through Rover, and direct weETH is used INTERNALLY
    // only as the Rover-self-liquidated fallback (VogueLib._supplyEtherFi). And NO always-live sink:
    // Galaxy AND Gauntlet are Morpho CURATED vaults (Aave/Euler curated too), so a chosen venue (or a
    // SPLIT leg) that places 0 REVERTS — it is NEVER swept to Galaxy or any other default.
    uint8 constant VENUE_SPLIT   = 0; // DEFAULT — equal 5-way {AAVE, Euler, Rover(ether.fi), Galaxy, Gauntlet}; diversify curator risk
    uint8 constant VENUE_AAVE    = 2; // AAVEv4
    uint8 constant VENUE_GALAXY  = 3; // Galaxy — its OWN Morpho WETH 4626 vault (a normal venue, NOT a fallback sink)
    uint8 constant VENUE_ROVER   = 4; // ether.fi, via the protocol-owned weETH/WETH v3 LP (Rover)
    uint8 constant VENUE_EULER   = 5; // Euler ETH (WETH 4626 curator; fungible w/ Galaxy)
    uint8 constant VENUE_GAUNTLET= 6; // Gauntlet (2nd Morpho WETH 4626 curator; fungible w/ Galaxy)

    mapping(address => uint) public ethfiBacked; // ether.fi/Rover (weETH) slice — the ONLY
    // per-LP venue attribution kept. This slice exits via the offramp ladder (isolated,
    // ether.fi-sourced) so its per-LP size must be tracked. The other venues (AAVE, Euler,
    // Galaxy, Gauntlet) are FUNGIBLE ERC-4626 WETH positions withdrawn from the pooled book,
    // so they need NO per-LP attribution — a nested lpVenue map/list/totals would be
    // net-added state for no functional gain. The former write-only `aaveBacked` map (never
    // read anywhere) was removed.

    // Per-LP attribution applies ONLY to the ether.fi slice (above): that exit is served from your
    // own weETH/Rover position. Every other venue is fungible pooled 4626 WETH — no per-LP venue tie.

    // ether.fi-slice exit preference is PER-TX (no stored setting): ERC-4626 withdraw/redeem
    // default to WAIT (instant=false — no forced ~0.3% redeem; the unserved slice retries
    // later); an LP who wants the instant redeem in the rare both-pools-drained anomaly calls
    // `exitInstant` for that one tx. No-op for LPs with no ether.fi slice. (Replaces the
    // former `withdrawInstant` mapping + setWithdrawInstant — a stored flag was unnecessary
    // for an edge-case-only, per-tx choice.)

    bool public token1isETH;
    // range = between ticks
    int24 public UPPER_TICK;
    int24 public LOWER_TICK;
    uint public LAST_REPACK;
    // ^ timestamp allows us
    // to measure APY% for
    uint public USD_FEES;
    Basket QUID; Aux AUX;

    /// @notice EthVenue — the ETH yield-venue custody (Galaxy/AAVE/ether.fi),
    ///         carved out of Aux. Vogue routes its WETH venue ops (vogueOp,
    ///         supplyEtherFi/supplyAaveEth, offrampEtherFi, arbETH) here. Pinned
    ///         once via setEthVenue (after EthVenue is deployed). vogueETH() is
    ///         still read at AUX (a thin forwarder) so existing reads are intact.
    IEthVenueV public EV;
    error EthVenuePinned();
    function setEthVenueContract(address e) external {
        // Kept as its own one-shot setter (NOT folded into setup): EthVenue is deployed
        // AFTER Vogue.setup runs — setup sets WETH, which the max-approval below needs —
        // so the pin is necessarily a post-setup deploy step, not mergeable into setup().
        require(msg.sender == DEPLOYER, "403");   // Vogue is ownerless post-setup (renounced) → deployer-gate
        if (address(EV) != address(0)) revert EthVenuePinned();
        EV = IEthVenueV(e);
        // Standing WETH approval so EthVenue can pull the depositor's WETH on
        // supplyEtherFi/supplyAaveEth/vogueOp/supplyEtherFiToRover (mirrors the
        // prior AUX approval). WETH is set in setup(), which must run first.
        WETH.approve(e, type(uint).max);
    }

    /// @notice ETH-yield accounting. Single venue (Morpho 4626 wethVault
    /// — see Aux.wethVault). The previous per-venue maps (lpShares/
    /// feesPerShare/bookmark indexed by a uint8 tag, plus the
    /// lpVenue[user] selector and the VENUE_MORPHO constant) were
    /// scaffolding for a multi-venue future that hasn't materialized;
    /// every keyed access was uniformly `[VENUE_MORPHO]`. Collapsed to
    /// plain uints. If multi-venue support is ever needed, the
    /// mapping form can be re-introduced.
    uint public feesPerShare;
    uint public bookmark;
    uint public lpShares;

    /// @notice SEPARATE accumulator for VENUE (Morpho WETH) appreciation, distinct from the
    ///         V4-trading-fee `feesPerShare`. Venue yield is funded ONLY by PLAIN LP deposits (the
    ///         lev slice's capital lives in the external lev venue; the buffer is band depth), so it
    ///         accrues over PLAIN depth (`lpShares - totalLevPooled`) and is paid on weight
    ///         `pooled - levPooled` -- never diluting plain LPs to the lev/buffer depth. Trading fees
    ///         stay on gross depth (the buffer IS real V4 depth). `venueBm` is the per-LP bookmark.
    uint public venueFeesPerShare;
    mapping(address => uint) public venueBm;
    /// @notice Sum of every levered LP's `levPooled` (the net-equity band leg). Plain depth for the
    ///         venue-yield denominator is `lpShares - totalLevPooled` (moves in lockstep with the lev
    ///         reconcile, so it is invariant under lev changes and tracks only plain deposits).
    uint public totalLevPooled;

    /// @notice The NET-equity portion of an LP's `pooled` that is LEVERAGE-backed (the IL-protect fee lane,
    ///         synced to the LevManager net-equity by `syncLev`). `pooled`/`lpShares` are NET (equity): this
    ///         net leg IS counted in them, but is UNWIND-ONLY: `_withdraw` excludes it (redeemed via
    ///         `LevManager.closeLev`, never the free ladder), so a levered claim never competes with unlevered
    ///         LPs for deliverable ETH.
    mapping(address => uint) public levPooled;

    /// @notice The DEBT-FUNDED BUFFER band depth of a levered LP (gross collateral - net equity), in band-ETH.
    ///         It is NOT equity, so it is EXCLUDED from `pooled`/`lpShares` (net), but it IS real V4 band depth,
    ///         so it earns band fees: the per-LP fee WEIGHT is `pooled + levBuf` and the fee denominator is
    ///         `lpShares + totalBuffer` (both GROSS). This is how the leverage keeps its yield on the 2x depth
    ///         while the LP's share accounting stays net. Cleared (with the net leg) on reconcile/close.
    mapping(address => uint) public levBuf;
    /// @notice Sum of every levered LP's `levBuf` — the gross buffer total. Fee denominator = lpShares + this.
    uint public totalBuffer;

    /// @notice The 6-dec USD counterpart of an LP's DEBT-funded BUFFER band leg. Post-fold there is no
    ///         separate POOLED_USD_ETH_LEV bucket: the buffer USD folds into POOLED_USD like any in-range USD
    ///         and is EXCLUDED from committed because committedUsd18
    ///         subtracts live debt (committed = POOLED_USD − debt = net equity). A venue liquidation un-pairs
    ///         it without stranding basket USD. Bounded by the LP's own debt by construction (`levAddBuf`
    ///         sizes it to the buffer collateral at the band price, capped at debtUsd).
    mapping(address => uint) public levBufferUsd;

    /// @notice Bumped whenever the band ticks RECENTER (repack/reseat in `_rebalance`). A reseat realizes the
    ///         band's IL and moves the ticks, so the IL-protect re-anchors its `entrySqrtP`/`E0` when this
    ///         advances past a position's recorded epoch — otherwise the sold-fraction would be measured
    ///         across a tick-config change and mis-hedge.
    uint64 public reseatEpoch;

    // V4.POOLED_ETH() = principal + ALL compounded fees (even unclaimed)
    // The previous singular `totalShares` is now exposed via this
    // view because Core reads `VOGUE.totalShares()`.
    function totalShares() public view returns (uint) {
        return lpShares;
    }

    /// @notice The LP's UNLEVERED band-ETH depth (`pooled` minus the leverage slice) — the `E0` the leverage
    ///         IL-protect must size its debt against (`LevManager` reads this at `openLev`). At open the
    ///         leverage slice is 0, so this is the LP's raw band deposit. Sizing the IL hedge to THIS fixed
    ///         base (not the buffer's own growing collateral) is what avoids the 1/(1−t) over-hedge.
    function bandEthOf(address lp) external view returns (uint) {
        uint p = autoManaged[lp].pooled;
        uint lev = levPooled[lp];
        return SwapLib.plainNet(p, lev);
    }

    // BTC LP accounting (autoManagedBTC/lpSharesBTC/feesPerShareBTC/USD_FEES_BTC/
    // btcFeesOwedSats + UPPER_TICK_BTC/LOWER_TICK_BTC) lives entirely in
    // BtcVault.sol — Vogue is the ETH vault; its helpers are ETH-only now.

    mapping(address => Types.Deposit) public autoManaged;

    // ─── §A.5f (subset): TIMELOCKED WITHDRAWAL-RECIPIENT PIN ────────────────
    // THREAT: the hosted fleet keeper HOLDS THE LP KEY (BtcLevManager:361), and `withdraw`/`redeem`
    // leave `receiver` arbitrary — so a compromised keeper can send an LP's funds anywhere. Nothing
    // off-chain constrains this: the Rust `Scope` layer is coarse API-client auth with no notion of
    // EVM actions, so today the ONLY constraint is that the enclave runs attested code.
    //
    // WHY A TIMELOCK AND NOT JUST A PIN. A pin that the LP key can SET, the LP key can also UNSET —
    // a keeper would simply unpin, then withdraw. The delay is the entire mechanism: a stolen key may
    // REQUEST a change but cannot act on it inside the window, which is the LP's chance to notice and
    // exit. This is a genuine SUBSET of §A.5f, not a substitute for per-action authorisation.
    //
    // ADDITIVE BY CONSTRUCTION: zero == unpinned == unrestricted, which is every existing LP, so no
    // current behaviour changes and no call site moves.
    mapping(address => address) public pinnedRecipient;
    mapping(address => address) public pendingRecipient;
    mapping(address => uint)    public recipientUnlockAt;
    uint public constant RECIPIENT_TIMELOCK = 3 days;

    error RecipientNotPinned();
    error RecipientTimelocked();
    event RecipientPinRequested(address indexed lp, address indexed to, uint effectiveAt);
    event RecipientPinned(address indexed lp, address indexed to);

    /// @notice Pin (or re-point) the only address this LP's withdrawals may pay.
    ///         FIRST pin applies IMMEDIATELY — going from unrestricted to restricted cannot make an
    ///         LP worse off, and making opt-in instant is what gets it adopted. Every SUBSEQUENT
    ///         change is delayed, because that is the direction an attacker needs.
    function pinRecipient(address to) external {
        if (pinnedRecipient[msg.sender] == address(0)) {
            pinnedRecipient[msg.sender] = to;
            emit RecipientPinned(msg.sender, to);
        } else {
            pendingRecipient[msg.sender] = to;
            recipientUnlockAt[msg.sender] = block.timestamp + RECIPIENT_TIMELOCK;
            emit RecipientPinRequested(msg.sender, to, block.timestamp + RECIPIENT_TIMELOCK);
        }
    }

    /// @notice Apply a previously requested re-point, once its window has elapsed.
    function applyPinnedRecipient() external {
        uint at = recipientUnlockAt[msg.sender];
        if (at == 0 || block.timestamp < at) revert RecipientTimelocked();
        address to = pendingRecipient[msg.sender];
        pinnedRecipient[msg.sender] = to;
        delete pendingRecipient[msg.sender];
        delete recipientUnlockAt[msg.sender];
        emit RecipientPinned(msg.sender, to);
    }

    /// @dev Unpinned (zero) LPs are unaffected — this is the additive default.
    function _requirePinnedRecipient(address owner, address receiver) internal view {
        address pin = pinnedRecipient[owner];
        if (pin != address(0) && receiver != pin) revert RecipientNotPinned();
    }

    mapping(uint => Types.SelfManaged) public selfManaged;
    /// (JIT-lock) block of the position's most recent auto-managed deposit; `_withdraw`
    /// refuses a same-block exit so an atomic deposit→swap→withdraw can't snipe a swap fee.
    mapping(address => uint) public lastDepositBlock;
    // ^ key is tokenId of ID++ for that position
    uint internal ID;
    // ^ always grows

    mapping(address => uint[]) public positions;
    // ^ allows several selfManaged positions...

    /// @notice The deployer — gates `setEthVenueContract`, the post-`setup` pin that grants EV an unlimited
    ///         WETH approval + drives every WETH venue op. `setup` RENOUNCES ownership, so that pin can't use
    ///         onlyOwner; this immutable survives the renounce and keeps the pin front-run-proof (a hostile
    ///         pre-pin would drain Vogue's WETH). Captured at construction; equals the wiring caller in both
    ///         the deploy script and tests.
    address immutable DEPLOYER;
    constructor()
        Ownable(msg.sender) {
        DEPLOYER = msg.sender;
    }   fallback() external payable {}

     modifier onlyUs {
        require(msg.sender == address(AUX)
             || msg.sender == address(V4)
             || msg.sender == address(this), "403"); _;
    }

    function setup(address _quid,
        address _aux, address _core) external onlyOwner {
        if (address(AUX) != address(0)) revert AlreadyInitialized();
        AUX = Aux(payable(_aux)); V4 = Core(_core);
        QUID = Basket(_quid);
        renounceOwnership();
        if (QUID.V4() != address(this)) revert WrongV4();
        WETH = WETH9(payable(address(AUX.WETH())));
        WETH.approve(address(AUX), type(uint).max);
        (uint160 sqrtPriceX96,,) = V4.poolStats(0, 0, false);
        token1isETH = V4.token1isETH();
        (LOWER_TICK,, UPPER_TICK,) = _updateTicks(
                                sqrtPriceX96, SwapLib.BAND_DELTA);
    }


    /// @notice Create a single-sided liquidity position outside the current price range
    /// @dev Automatically adjusts for token ordering to ensure valid positions
    /// @param amount Amount of tokens to deposit (0 if sending ETH as msg.value)
    /// @param token Token address (address(0) for ETH, or stablecoin address for USD)
    /// @param distance Distance from current price in ticks
    /// positive = subtract (below), negative = add (above)
    /// @param range Width of the position in ticks
    /// @return next The ID of the newly created position
    /// @notice Per-deposit venue variant (same idea as the LP deposit
    ///         overload): the self-managed position's ETH backing earns at the
    ///         caller-chosen venue instead of pinning Galaxy. No wall
    ///         attribution (there's no pledge): exits via pull() are served by
    ///         the generic withdraw ladder, which reaches every venue.
    function outOfRange(uint amount, address token,
        int24 distance, int24 range, uint8 venue) 
        external nonReentrant payable returns (uint next) {
        return _outOfRange(amount, token, distance, range, venue);
    }

    function _outOfRange(uint amount, address token,
        int24 distance, int24 range, uint8 venue) internal
        returns (uint next) {
        SwapLib.validateOorParams(range, distance);

        SwapLib.Oor memory t;
        {   // geometry in a scope so currentSqrtPrice frees before sizing.
            // §J.8b: was an inline copy of `SwapLib.oorTicks` (identical branch structure, identical
            // alignment, same width 10) plus a local `_outOfRangeTicks`. The BTC path
            // (`BtcVaultLib.outOfRangeBtc`) already called the shared helper, so ONE definition now
            // computes the out-of-range geometry for both assets — the same consolidation §A.56 did
            // for the SIZING half. NOTE: `oorTicks` negates `distance` internally from `token1is`,
            // so the caller must NOT pre-negate it (doing both would place the order on the wrong
            // side of spot).
            (uint160 currentSqrtPrice, int24 curLo, int24 curUp,,) = _rebalance();
            t = SwapLib.oorTicks(currentSqrtPrice, range, distance, token1isETH, curLo, curUp);
        }
        // Backing deposit + single-sided sizing lives in VogueLib (EIP-170
        // headroom); self-managed positions take no wall attribution (pledge==0).
        uint128 liquidity = VogueLib.sizeOutOfRange(
            address(WETH), address(AUX), address(EV), ethfiBacked,
            amount, token, token1isETH, venue, t);
        if (liquidity == 0) revert Dust();

        next = ++ID;
        selfManaged[next] = Types.SelfManaged({
            created: block.number, owner: msg.sender,
            lower: t.newLo, upper: t.newUp,
            liq: int(uint(liquidity)) });
        positions[msg.sender].push(next);
        V4.outOfRange(false, msg.sender,
            int(uint(liquidity)),
            t.newLo, t.newUp,
            address(0));
    } // Re-audited 2026-07-24 (self-managed OOR position create): internally consistent.
    // tick ordering — newUpper-newLower == range, aligned to width=10 and range a multiple
    // of 50 ≥ 100, so lower<upper always (no degenerate/inverted band); liquidity cast
    // int(uint(uint128)) is always +, passed positive = a MINT (correct); V4.outOfRange args
    // (ETH pool, sender, +liq, newLo<newUp, token=address(0)) — the address(0) is CORRECT:
    // on a mint the USD side is settled by minting mock-USD, and `token` is only read on the
    // usdDelta>0 BURN branch (Core._settleUsdSide); real-token delivery is on pull(), and the
    // stablecoin for the USD side was already pulled in sizeOutOfRange; dust guard fires before
    // any write; ++ID unique/monotonic; state-before-external-call under nonReentrant.


    function pendingRewards(address user) public view returns (uint ethReward, uint usdReward) {
        return _pendingFor(user);
    }

    /// @dev Shared body for ETH/BTC pending rewards. Picks the right
    ///      LP mapping + fee accumulators based on isBTC. ETH yield is
    ///      from Morpho (Galaxy); BTC LPs earn USD fees only (no native
    ///      BTC yield source — feesPerShareBTC holds V4 trading fees in
    ///      WBTC raw).
    /// @dev Refresh LP's fee bookmarks against current per-share accumulators.
    ///      Called whenever LP.pooled changes (deposit, withdraw, reward
    ///      settlement) to mark the LP as up-to-date through this point.
    function _refreshBookmarks(address user, 
        uint tokAccum, uint usdAccum) internal {
        Types.Deposit storage LP = autoManaged[user];
        // GROSS fee weight = net pooled + the debt-funded levered buffer (see levBuf) -- TRADING fees.
        SwapLib.refreshBookmarks(LP, LP.pooled + levBuf[user], tokAccum, usdAccum);
        // VENUE yield: PLAIN weight only (excludes the lev slice's net-equity + buffer).
        uint plainW = SwapLib.plainNet(LP.pooled, levPooled[user]);
        venueBm[user] = FullMath.mulDiv(plainW, venueFeesPerShare, WAD);
    }

    /// @dev Settle pending rewards. `mintRecipient == address(0)` accumulates
    ///      usd into `LP.usd_owed` (deposit-side semantics); non-zero mints
    ///      outstanding USD to that address (withdraw-side). Tok reward
    ///      always compounds into LP.pooled + lpShares (or BTC variant).
    function _settlePending(Types.Deposit storage LP,
        address user, address mintRecipient) internal {
        if (LP.pooled == 0) return;
        (uint tokR, 
         uint usdR) = _pendingFor(user);
        if (tokR > 0) {
            LP.pooled += tokR;
            lpShares  += tokR;
        }
        if (mintRecipient != address(0)) {
            usdR += LP.usd_owed;
            if (usdR > 0) {
                LP.usd_owed = 0;
                // §A.57: 6-dec USD fee accumulator → 18-dec QU!D. Same fix as BtcVaultLib.settleBtcLp;
                // both paths shared the missing scale-up, so both move together.
                QUID.mint(mintRecipient,
                usdR * 1e12, address(QUID), 0);
            }
        } else if (usdR > 0) {
            LP.usd_owed += usdR;
        }
    }

    function _pendingFor(address user)
        internal view returns (uint tokReward, uint usdReward) {
        Types.Deposit storage LP = autoManaged[user];
        // TRADING fees (V4): gross band-depth weight (buffer IS real V4 depth).
        (tokReward, usdReward) = SwapLib.pendingFor(LP, LP.pooled + levBuf[user], feesPerShare, USD_FEES);
        // VENUE yield: PLAIN weight only. The lev slice earns its own yield via the
        // LevManager, not this Morpho position, so crediting it here would skim plain LPs.
        uint plainW = SwapLib.plainNet(LP.pooled, levPooled[user]);
        uint venueOwed = FullMath.mulDiv(plainW, venueFeesPerShare, WAD);
        if (venueOwed > venueBm[user]) tokReward += venueOwed - venueBm[user];
    }

    // _settleBtcLp regrouped into BtcVault.sol.

    /// @dev Burn `amount` of in-range virtual liquidity (capped at the pool's
    ///      active slice) and return what was actually delivered. ETH passes the
    ///      LP's recipient (WETH paid out on-chain); BTC passes address(0) — the
    ///      native sats return via the cooperative-close tx, so nothing is
    ///      delivered here, only the mockBTC is burned. Shared by _withdraw (ETH)
    ///      and unregisterBtcLp (BTC); the orchestration around it diverges
    ///      (fee model, native-vs-on-chain delivery, the BTC-only per-channel
    ///      claim), which is why the two callers stay distinct.
    function _burnInRange(uint160 sqrtPriceX96, uint amount,
        int24 tickLower, int24 tickUpper, address recipient)
        internal returns (uint sent) {
        return SwapLib.burnInRange(address(V4), false, sqrtPriceX96, amount,
                                    tickLower, tickUpper, recipient);
    }

    /// @dev Shared body. `recipient` receives the ETH; the accrued-fee QD is
    /// COMPOUNDED (deferred to `usd_owed`) on a PARTIAL exit and only MINTED out
    /// on a FULL exit — see JIT-DEPTH-GUARANTEE.md §4.1. `msg.sender` is the
    /// position owner (kept for accounting).
    ///
    /// JIT-DEPTH §4 folding status (docs/actionable/JIT-DEPTH-GUARANTEE.md):
    ///   • §4.1 compound-QD-on-partial  — DONE (below: settle→usd_owed, mint only on full exit)
    ///   • §4.3 CEI-ordering            — DONE (debit pooled/lpShares BEFORE the ETH sends,
    ///                                     re-credit the undelivered shortfall)
    ///   • §4.2 cover-open-levers-first — ✅ **DONE (#109). INLINE WIRING IS LIVE** — see `_withdraw` below:
    ///     when the ask exceeds the LP's FREE (non-levered) balance it calls
    ///     `ILevClose(levManager).closeLevFor(msg.sender, 0)` then `_reconcileLev(msg.sender)`, i.e. a
    ///     past-free withdraw crystallizes the whole in-band lever (full-close, not partial — that IS the
    ///     opt-in). `closeLevFor` stays gated to the GOV-pinned vogueSyncHook OR GOV, and `closeLev`'s
    ///     LP-only msg.sender gate is untouched.
    ///     **CORRECTED 2026-07-26 — this comment previously read "PRIMITIVE BUILT, INLINE WIRING DEFERRED"
    ///     and listed two blocking forks. That text outlived the code and is what caused #109 to be tracked as
    ///     in_progress while it was in fact shipped** (the exact "anchor claims to HEAD, never to comments"
    ///     trap the build-queue STANDING LAW names). For the record, the two forks resolved as: (a) minOut —
    ///     the inline call passes `0`, deliberately, because the slice is closed at the LP's own request during
    ///     THEIR withdraw, and the swap is bounded by the venue's own oracle/LTV rather than a caller floor;
    ///     (b) re-entrancy — `closeLevFor`'s flash callback re-enters `syncLev` under this contract's
    ///     nonReentrant lock, so it is try/caught and the band slice is cleared here by the explicit
    ///     `_reconcileLev` instead of by the hook. The withdraw still CAPS at `pooled − levPooled`, so a
    ///     levered claim can never pull unlevered ETH.
    ///   • §2  JIT depth-guarantee core — DEFERRED (backing-model fork): the spec's redeem→addLiq top-up does
    ///     NOT compose backing-neutrally. `addLiq` headroom is surplus = TVL − committed (independent of QUID
    ///     supply S); `Aux.redeem`/`redeemAsBody` pays real stables OUT of the vaults (TVL↓), SHRINKING that
    ///     surplus rather than funding it, while the true D≥S+L requirement is unchanged. A bare `Basket.turn`
    ///     burn (S↓, TVL unchanged) is the neutral primitive the doc's math actually describes. See the
    ///     swap-out path notes in SwapLib.swapToBody + the JIT-DEPTH handoff.

    /// @dev Venue-shortfall delivery frame, extracted from _withdraw to stay within the legacy
    ///      stack (no via_ir): the LP's pro-rata share of the PLAIN venue balance, capped by what
    ///      POOLED_ETH can't already cover. Returns the ETH actually sent to `recipient`.
    function _deliverVenueShortfall(uint amount, uint shortfall, uint plainDepth, address recipient)
        private returns (uint excess) {
        uint venueBal = _venueBalance();
        uint vaultShare = plainDepth > 0 ? FullMath.mulDiv(venueBal, amount, plainDepth) : venueBal;
        uint inPool = V4.POOLED_ETH();
        excess = Math.min(shortfall, vaultShare > inPool ? vaultShare - inPool : 0);
        if (excess > 0) excess = _sendETH(excess, recipient);
    }

    function _withdraw(uint amount, address recipient, bool instant) internal {
        // LENIENT: LP withdrawal SHRINKS POOLED_USD (Core lines
        // 512-513) → shrinks committedSum → heals over-commit. Allow
        // the repack attempt to run but don't gate the exit on its
        // success. Tradeoff: first-out LPs are made whole at the
        // expense of remaining-LP backing share. Accepted for liveness:
        // gridlock during a stress event is worse than first-out
        // unfairness, and once enough LPs exit, the invariant restores.
        AUX.tryCheckBacking();

        // full-2×: self-heal a levered position seized by an EXTERNAL venue liquidation BEFORE this LP extracts
        // value — reconciles the (possibly stale) levered slice to the live gross so the withdrawal cap
        // (`pooled − levPooled`) and fee accrual use post-seizure truth, not vanished backing. Early-outs (cheap)
        // for non-levered LPs and for a levered LP already in sync.
        if (levPooled[msg.sender] > 0) _reconcileLev(msg.sender);
        Types.Deposit storage LP = autoManaged[msg.sender];
        if (LP.pooled == 0) revert NoPosition();

        // (JIT-lock) refuse a same-block exit — see _depositImpl. Blocks the atomic
        // deposit→swap→withdraw JIT fee-snipe the composition audit found on this 4626 path.
        require(block.number > lastDepositBlock[msg.sender], "too soon");
        (uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper,,) = _rebalance();
        // §4.1 COMPOUND-not-transfer: settle with mintRecipient==0 so the USD fee leg
        // ACCRUES to `usd_owed` (a deferred, unrealized claim — strictly conservative, no
        // mint) rather than being minted out. The token (ETH) leg still compounds into
        // pooled/lpShares unconditionally (inside _settlePending). On a FULL exit the
        // accrued usd_owed is realized (minted to `recipient`) just before _onExit clears
        // the slot — see the mint-out block below.
        _settlePending(LP, msg.sender, address(0));

        // #109 (§G.7): a withdraw that reaches PAST the LP's FREE (plain) depth into their OWN in-band levered
        // slice AUTO-DE-LEVERS it. `levPooled>0` ⟺ in-band ⟺ auto-close candidate (2× auto-banded OR a
        // directional lever the LP CHOSE to band — both opted in); an out-of-band directional lever has
        // levPooled==0 and is structurally untouched. `closeLevFor` repays debt and hands the freed collateral
        // (weETH/WETH — the LP's FULL residual: YB guarantee, or directional upside) straight to the LP, so the
        // levered value IS delivered. Fires ONLY when the ask exceeds free depth (know-WHEN-to-delever; a
        // free-only withdraw never touches the lever). minOut=0 is BOUNDED: closeLev returns equity as UNSOLD
        // collateral — only the debt-repay swap sells, and it self-floors to ≤MAX_SLIPPAGE_BPS via the flash-
        // coverage requirement (the op reverts past it). The callback's syncLev re-entrancy is nonReentrant-
        // BLOCKED under this withdraw lock (LevManager try/catches it → the slice stays stale for the tx), so
        // reconcile INLINE right after to burn the now-0 levPooled leg (net-equity==0 post-close) BEFORE the cap
        // re-reads to the full remaining pooled. Full-close (not partial): reuses the existing closeLevFor
        // primitive — a past-free withdraw crystallizes the whole in-band lever, which is the opt-in.
        if (levPooled[msg.sender] > 0 && amount > SwapLib.plainNet(LP.pooled, levPooled[msg.sender])) {
            ILevClose(VogueLib.levManager(address(AUX))).closeLevFor(msg.sender, 0);
            _reconcileLev(msg.sender);                      // hook re-entrancy was blocked → clear the slice here
        }
        // Cap withdrawal at the user's FREE (non-levered) balance. The levered slice (levPooled) leaves via the
        // auto-close above (or LP-initiated LevManager.closeLev) — repay debt → withdraw collateral — never the
        // free ladder, so a levered claim can never pull deliverable ETH that backs unlevered LPs.
        amount = Math.min(amount, SwapLib.plainNet(LP.pooled, levPooled[msg.sender]));
        // HARD WALL: the ether.fi slice exits via the offramp ladder (ether.fi-
        // sourced + isolated). Gauntlet or Galaxy/AAVEv4 LP (ethfiBacked==0) 
        // skips this and never touches the offramp/wait/fee. 
        // Served slice burns its virtual liquidity with 
        // no on-chain delivery (WETH came from ether.fi).
        if (amount > 0 && ethfiBacked[msg.sender] > 0) {
            uint ethfiPart = FullMath.mulDiv(amount, 
                ethfiBacked[msg.sender], LP.pooled);
            // Defense-in-depth: the slice must never exceed the withdrawal
            // (ethfiBacked ≤ pooled is the deposit-side invariant; a violation
            // would otherwise underflow `amount -= served` below).
            if (ethfiPart > amount) ethfiPart = amount;
            if (ethfiPart > 0) {
                uint served = EV.offrampEtherFi(ethfiPart, recipient, instant);
                if (served > 0) {
                    _burnInRange(sqrtPriceX96, served,
                    tickLower, tickUpper, address(0));
                    ethfiBacked[msg.sender] -= Math.min(served, 
                    ethfiBacked[msg.sender]);

                    LP.pooled -= served; 
                    lpShares -= served;
                    amount -= served;
                }
            }
        } if (amount > 0) {
            // CAP the in-range burn at the ETH venue's instantly-DELIVERABLE
            // capacity. Burning virtual liquidity we can't back with real ETH
            // would zero the LP's `pooled` while delivering only a partial
            // amount (Core.modLP returns the virtual size, not what takeETH
            // actually sent) — a PERMANENT BAG. Capping makes virtual-burn ==
            // real-delivery; whatever can't be delivered now STAYS as `pooled`,
            // a recoverable deferral the LP re-withdraws once the venue thaws —
            // the LP-side analog of the redemption path's _illiquidLoss. When
            // the venue is healthy `deliverable` >> one LP's slice, so this is a
            // no-op on the normal path (the LP gets all their ETH + fees).
            //
            // §4.3 CEI: the per-LP venue pro-rata denominator (`plainDepth`) must reflect
            // PRE-debit depth (the LP's claim on the venue is proportional to its share of
            // total plain depth INCLUDING the slice being withdrawn), so capture it BEFORE
            // the debit below.
            uint plainDepth = lpShares > totalLevPooled ?
                            lpShares - totalLevPooled : 0;

            // §4.3 CEI: DEBIT the intended withdrawal from per-LP + global share state
            // BEFORE any ETH leaves the contract, so a re-entrant observes the debited
            // position (not the lagging pre-send value). The undelivered shortfall is
            // RE-CREDITED after the sends — net decrement == what was actually delivered,
            // byte-for-byte the same end state as the prior send-then-debit ordering, but
            // with no window where a reentrant sees full `pooled` after ETH already left.
            LP.pooled -= amount; lpShares -= amount;

            uint deliverable = AUX.deliverableETH();
            uint firstBurn = amount > deliverable ? deliverable : amount;
            uint sent = firstBurn > 0 ? _burnInRange(sqrtPriceX96, firstBurn,
                                        tickLower, tickUpper, recipient) : 0;

            if (amount > sent) { uint shortfall = amount - sent;
            { // Venue-share delivery — extracted to _deliverVenueShortfall (own frame, no via_ir).
              // `_venueBalance` is the PLAIN venue ETH (excludes the levered net-equity, backed
              // EXTERNALLY on Euler/Morpho). `amount` (capped at pooled-levPooled above) <= plainDepth,
              // so the share never over-delivers.
                uint excess = _deliverVenueShortfall(amount, shortfall, plainDepth, recipient);
                sent += excess; shortfall -= excess;
            } // the LP receives only what its OWN in-range burn + venue
             // share can deliver — already IL-adjusted, since convertToAssets =
            // pro-rata of vogueETH (the loss is socialized fairly via the share
           // price, no first-out advantage). Any residual is VENUE ILLIQUIDITY
          // only; it stays as LP.pooled (recoverable deferral, re-withdrawn on
         // venue thaw). NO surplus-funded make-whole here that would compensate
        // a first-out LP at the shared backing's expense for this claim must
       // divide over depth (`lpShares - totalLevPooled`), NOT gross `lpShares`
      // exactly the denominator uses for venue YIELD. Gross would dilute LPs.
     // whatever the burn + venue-share could NOT deliver stays
    // as the LP's recoverable `pooled` deferral (re-withdrawn on venue thaw).
            if (shortfall > 0) { LP.pooled += shortfall; lpShares += shortfall; }
                                                    bookmark = _venueBalance();
            }
        }
        // §4.1 MINT-OUT ON FULL EXIT: the USD fee leg was accrued to usd_owed (not minted)
        // above. When the position has FULLY exited (pooled hit 0) realize it now — mint the
        // owed QD to `recipient` BEFORE _onExit deletes the slot (which would otherwise drop
        // usd_owed). A PARTIAL exit leaves usd_owed as the deferred claim (claimable later via
        // collectFees or the eventual full exit). Backing-neutral: a mint against already-earned
        // basket-USD fees, identical to the prior per-withdraw mint, just deferred to full exit.
        if (LP.pooled == 0 && LP.usd_owed > 0) {
            uint owed = LP.usd_owed; LP.usd_owed = 0;
            // §A.57/C5: `usd_owed` is 6-dec; QU!D is 18-dec. This was the FOURTH sibling of the same
            // mint and the ONLY one missing the scale-up (cf. `_settlePending:439`,
            // `BtcVaultLib.settleBtcLp:57`, `settleDelivered:74`). Without it, an LP whose fees were
            // DEFERRED by a partial exit and who then FULLY exits was paid 1e-12 of the leg.
            QUID.mint(recipient, owed * 1e12, address(QUID), 0);
        }
        _onExit(LP, msg.sender);
    }

    /// @dev Called at the end of a withdrawal. If the LP's position dropped
    ///      to zero, clear their slot; if they were the last LP, zero out
    ///      both per-share accumulators so a future LP joining doesn't see
    ///      stale historical fees attributed to no one. Otherwise refresh
    ///      bookmarks against the current accumulators.
    function _onExit(Types.Deposit storage LP, 
                        address user) internal {
        if (LP.pooled == 0) {
            delete autoManaged[user];
            // Hygiene: clear the per-LP venue attribution so a stale residual
            // (e.g. an instant-redeem haircut leaving ethfiBacked > 0) can't
            // mis-route a later re-deposit's exit venue.
            delete ethfiBacked[user];
            // Defensive: a fully-exited position carries no buffer depth (levBurnAll
            // already zeroed it on close); clear any residual so totalBuffer stays exact.
            if (levBuf[user] > 0) { totalBuffer -= levBuf[user]; delete levBuf[user]; }
            // Only zero the accumulators when NO fee-earning depth remains — net shares
            // AND the gross buffer (levered LPs may still hold buffer with 0 net pooled).
            if (lpShares == 0 && totalBuffer == 0) {
                feesPerShare = 0; USD_FEES = 0; 
                venueFeesPerShare = 0; totalLevPooled = 0;
            }
        } else {
            _refreshBookmarks(user, 
            feesPerShare, USD_FEES);
        }
    }

    /// @dev The 7-arg in-range modLP in its own frame so _depositImpl stays within
    ///      the legacy stack (no via_ir crutch). Mirrors Vault._modLpBtc.
    function _modLpEth(uint160 sqrtP, uint deltaETH, uint deltaUSD,
        int24 tickLower, int24 tickUpper, address pledge) private {
        V4.modLP(false, sqrtP, deltaETH, deltaUSD, tickLower, tickUpper, pledge);
    }
    /// @notice Reconcile `lp`'s LEVERED band position to its LIVE net-equity — the IL-protect fee lane.
    ///         PERMISSIONLESS (keeper/monitor/anyone): when the leverage's net-equity GROWS, mint band depth
    ///         for `lp` so the levered weETH earns band fees via the SAME machinery as a weETH deposit
    ///         (settle → addLiq → pooled/lpShares/levPooled += → modLP); when it SHRINKS or is liquidated,
    ///         burn that depth WITHOUT delivery (the equity is on the venue, not here), un-pairing POOLED_USD
    ///         back to the basket — so a venue liquidation leaves the basket fully intact. The minted slice is
    ///         UNWIND-ONLY (`levPooled`, excluded from `_withdraw`): it leaves via `LevManager.closeLev`, never
    ///         the free ladder, so it never introduces leverage-induced deferral. No tokens move here — the
    ///         backing is the net-equity already counted in `vogueETH` (so addLiq's headroom includes it).
    /// @notice Permissionless reconcile of `lp`'s levered band slice to the LIVE gross collateral. Anyone (keeper,
    ///         monitor, or the LP) may poke it; it is ALSO called lazily at the entry of `_withdraw` so a position
    ///         seized by an EXTERNAL venue liquidation self-heals before the LP can extract value — closing the
    ///         "external liquidation → stale slice earns fees on vanished backing" gap on-chain, not by poke-hope.
    function syncLev(address lp) external { _reconcileLev(lp); }

    function _reconcileLev(address lp) internal {
        address lm = VogueLib.levManager(address(AUX));
        uint gross = lm == address(0) ? 0 : ILevEquityV(lm).grossCollateralEth(lp);
        // full-2×: reconcile band CAPACITY to the GROSS collateral. `levPooled` is the NET leg and `levBuf`
        // the debt-funded buffer, so the live gross depth is their sum. Skip only when the gross depth AND
        // the buffer-USD target are already in sync (nothing to do).
        if (gross == levPooled[lp] + levBuf[lp] && levBufferUsd[lp] == VogueLib.bufTarget(lm, lp)) return;
        _doReconcile(lp, lm, gross);
    }

    /// @dev Own frame (stack) for the reconcile tail: rebalance, settle, then
    ///      delegatecall the burn/add legs. lpShares is value-type — applied here
    ///      from the returned (added, burned) deltas.
    function _doReconcile(address lp, address lm, uint gross) private {
        Types.Deposit storage LP = autoManaged[lp];
        VogueLib.LevP memory p;
        (p.sqrtP, p.tickLower, p.tickUpper,,) = _rebalance();
        p.lm = lm; p.gross = gross;
        _settlePending(LP, lp, address(0));          // settle fees up to now (→ usd_owed) before pooled moves
        (uint addedNet, uint burnedNet, uint bufAdded, uint bufBurned) = VogueLib.reconcileLegs(
            VogueLib.LevCfg(address(V4), address(AUX), address(WETH)),
            LP, levPooled, levBufferUsd, levBuf, lp, p);
        lpShares = lpShares + addedNet - burnedNet;       // NET equity leg
        totalLevPooled = totalLevPooled + addedNet - burnedNet; // the levered share of lpShares
        totalBuffer = totalBuffer + bufAdded - bufBurned; // GROSS buffer depth (fee weight)
        _onExit(LP, lp);                              // refresh bookmarks (or clear the slot if fully exited)
    }

    function _depositImpl(uint amount, address pledge, uint8 venue) internal {
        // (JIT-lock) Stamp the receiving position's deposit block. `_withdraw`
        // refuses a same-block exit, so `deposit → Aux.swap → withdraw` can't be
        // composed atomically to snipe a victim swap's fee (the ONE composition the
        // audit found open on the auto-managed 4626 path; `onlyUs` never blocked it —
        // only this lock does). Keyed on the RECEIVER so a throwaway-receiver bypass is
        // also stamped. Residual: dust-depositing to a victim delays them one block, but
        // that gifts the victim capital + costs gas each block — self-defeating grief.
        lastDepositBlock[pledge] = block.number;

        // Verify cross-pool backing invariant BEFORE any new commit
        // STRICT: LP deposit grows POOLED_USD → grows committedSum. A
        // new entry into an over-committed pool worsens the invariant.
        // Reverts if backing can't be restored.
        AUX.checkBacking();

        uint price = AUX.getTWAPforAsset(
                     address(WETH), 1800);
        
        if (price == 0) revert ZeroTwap();
        uint deltaETH; uint deltaUSD;
        
        if (amount == 0 && 
         msg.value == 0) return;

        // _repack MUST run before _depositETH so that _syncYield reads
        // the pre-deposit balance. Otherwise the deposit is
        // misattributed as yield, inflating ETH_FEES.
        Types.Deposit storage LP = autoManaged[pledge];
        (uint160 sqrtPriceX96, int24 tickLower,
         int24 tickUpper,,) = _rebalance();

        // _depositETH pulls WETH from msg.sender (payer), routes it to the
        // per-deposit chosen venue, and attributes the slice (hard-wall)...
        amount = _depositETH(msg.sender, pledge, amount, venue);

        // Guard: if nothing was pulled, no bookmark update is needed.
        // Without this early-return, _settlePending would compound pending
        // rewards into LP.pooled without _refreshBookmarks running
        // (since both deltaETH and unpaired would be 0). The next settle
        // would then over-credit the LP by the just-compounded amount,
        // since the bookmark would lag pooled by exactly that delta.
        // (BTC side gets the same guard in the channel-lock LP path.)
        if (amount == 0) return;
        // (venue attribution happens inside _depositETH, consistent with where
        // the WETH was actually placed. The yield bookmark is reset to the
        // REALIZED aggregate venue balance at the end of this function — see note.)

        // _rebalance (above) already accrued V4 fees + venue yield into
        // feesPerShare/USD_FEES, and neither _settlePending nor addLiq writes them
        // — so read the accumulators directly (the old pre-settle snapshot was
        // redundant; its two locals only pinned the stack). Mirrors registerBtcLp.
        _settlePending(LP, pledge, address(0));
        (deltaUSD, deltaETH) = this.addLiq(
                      amount, price, false);
        if (deltaETH > 0) {
            LP.pooled += deltaETH;
            lpShares += deltaETH;
            _refreshBookmarks(pledge, 
            feesPerShare, USD_FEES);

            _modLpEth(sqrtPriceX96, deltaETH, deltaUSD, 
                        tickLower, tickUpper, pledge);
        }
        uint unpaired = amount - deltaETH;
        if (unpaired > 0) {
            // Universal retention. Unpaired ETH stays on deposit at the
            // venue (Galaxy) earning Morpho yield. LP shares grow by
            // the unpaired amount so the deposit isn't silently
            // discarded and the LP can withdraw + earn fees
            // proportionally. Withdrawals always honour the full
            // pooled position regardless of pairing state.
            LP.pooled += unpaired;
            lpShares += unpaired;
            _refreshBookmarks(pledge, feesPerShare, USD_FEES);
        }
        // Re-sync the yield bookmark to the REALIZED aggregate venue balance
        // (NOT `+= amount`): for multi-venue / ether.fi deposits the staked or
        // supplied value can differ from `amount` by dust, and `_syncYield` would
        // otherwise book that delta as pro-rata yield. Runs for fully-paired
        // deposits too (the previous code only reset on the unpaired branch).
        bookmark = _venueBalance();
    }

    /// @dev Live PLAIN-venue ETH balance for the venue-yield sync + withdrawal delivery. `vogueOp`
    ///      op=2 returns vogueETH -- ALL plain venues (Galaxy/Euler/weETH/AAVE/idle/Rover, incl
    ///      ether.fi) PLUS the lev net-equity. SUBTRACT the lev net-equity so this is the
    ///      pure plain-venue value: the lev collateral earns its own yield via the LevManager, so
    ///      including it would (a) skim plain LPs' venue yield and (b) make a lev open/close appear
    ///      as fake venue yield in _syncYield. No-op when no leverage (totalNetEquityEth == 0).
    function _venueBalance() internal returns (uint) {
        uint total = EV.vogueOp(false, 0, 2, bytes32(0));   // vogueETH (all plain venues + lev net-equity)
        address lm = VogueLib.levManager(address(AUX));
        if (lm != address(0)) {
            try ILevEquityV(lm).totalNetEquityEth() returns (uint n) { total = total > n ? total - n : 0; } catch {}
        }
        return total;
    }

    // ───────── θ DERIVED LIVE from the sizing inequality (no owner, no synthetic const) ─────────
    // (The earlier owner-set ThetaMode/setThetaMode scaffold was REMOVED — dead code: setup()
    //  renounces ownership so it was permanently uncallable. θ is now derived live below.)
    // The owner-set thetaWad above is DEAD (setup() renounces ownership), so it is pinned at 1e18
    // (reckless). The real, un-stuck θ is COMPUTED from the certified inequality θ = yield/(K·σ²−f)
    // using on-chain avgYield + realized variance from the price oracle — it self-adjusts with
    // yield and vol, needs no owner, and uses no synthetic value. (f omitted = conservative: fees
    // only shrink LVR, so dropping them yields a SMALLER, safer θ.)
    // K = the LVR coefficient (annual LVR_rate = K·σ²). NO HARDCODE: K is NOT a free constant — for a
    // concentrated-liquidity band it is a CLOSED-FORM function of the band's own geometry, computed LIVE
    // from the on-chain ticks in `_kLvrWad()` below. The earlier 0.71/2.24 sim-fit constants are gone.
    /// @notice The LIVE LVR coefficient K (WAD) for the pool's current band — read the real, dynamic
    ///         number (front-end / probe / monitoring). 0 ⇒ band unset/degenerate (caller fails open).
    ///         Body in VogueLib (EIP-170 headroom); band ticks passed in.
    function kLvrWad(bool isBTC) external view returns (uint) {
        return VogueLib.kLvrWad(address(V4), LOWER_TICK, UPPER_TICK, isBTC);
    }

    /// @notice (A) The band's LIVE realized concavity α (WAD). Body in VogueLib.
    function realizedAlphaWad(bool isBTC) public view returns (uint) {
        return VogueLib.realizedAlphaWad(address(V4), LOWER_TICK, UPPER_TICK, isBTC);
    }

    /// @notice (B) The band's ACTUAL sold-volatile fraction (WAD) since `entrySqrtP` — the ground-truth IL the
    ///         hedge must cancel, straight from the concentrated-position geometry, so it reflects the real
    ///         (drifting) α with NO sqrt/pow and NO α parameter. Held-volatile amount is ∝ (1/√P − 1/√P_b)
    ///         when the volatile is token0 (sold as √P RISES) or ∝ (√P − √P_a) when it's token1 (sold as √P
    ///         FALLS); soldFrac = 1 − amount_now/amount_entry. VALID WITHIN ONE TICK-CONFIG ONLY — a reseat
    ///         recenters the ticks and realizes IL, so the CALLER must re-anchor `entrySqrtP` on reseat.
    ///         Returns 0 on the non-IL side (up-side-only, matching the current target) or a degenerate band.
    ///         ETH band (the BTC parallel lives on the Vault with the BTC ticks/ordering).
    function soldFractionWad(uint160 entrySqrtP) public view returns (uint) {
        (uint160 sqrtP,,) = V4.poolStats(0, 0, false);
        return SwapLib.soldFractionWad(entrySqrtP, sqrtP, LOWER_TICK, UPPER_TICK, token1isETH);
    }

    /// @notice The band's current spot √P (Q96) — the leverage records this as its `entrySqrtP` at open so
    ///         `soldFractionWad` can measure the IL from the true band price (not the oracle).
    function bandSqrtP(bool isBTC) external view returns (uint160 sqrtP) {
        (sqrtP,,) = V4.poolStats(0, 0, isBTC);
    }

    /// @notice θ derived live: yield / (K·σ²), clamped to ≤1. Body in VogueLib
    ///         (EIP-170 headroom); band ticks + Core/Aux handles passed in.
    function derivedThetaWad(bool isBTC) public view returns (uint) {
        return VogueLib.derivedThetaWad(address(V4), LOWER_TICK, UPPER_TICK, isBTC);
    }

    /// @notice θ for an EXPLICIT band range. The BTC band ticks live in the Vault (LOWER_TICK_BTC/
    ///         UPPER_TICK_BTC), so it passes them in here -- Vogue stays the single home of the band-θ
    ///         math for BOTH pools, and the Vault needs no VogueLib link of its own.
    function derivedThetaWadAt(int24 lo, int24 up, bool isBTC) public view returns (uint) {
        return VogueLib.derivedThetaWad(address(V4), lo, up, isBTC);
    }

    /// @notice Annualized realized variance (WAD) from Core's oracle ring. Body in VogueLib.
    function realizedVarianceWad(bool isBTC) public view returns (uint) {
        return VogueLib.realizedVarianceWad(address(V4), isBTC);
    }

    /// @notice Size how much of the volatile asset (`deltaTok`) + paired
    ///         synthetic USD to commit into the in-range V4 position. Returns
    ///         the LARGEST pairing that fits BOTH bounds below; the
    ///         requested amount is clamped DOWN to fit.
    ///
    ///         THE TWO BOUNDS:
    ///         (1) `surplus` — free basket backing = TVL − already-committed USD
    ///             (both pools). SOLVENCY bound: the position's USD leg is
    ///             synthetic mockUSD redeemable against the basket, so committing
    ///             beyond `surplus` would make POOLED_USD > TVL — quoting AMM
    ///             depth backed by dollars that don't exist, breaking D ≥ S+L.
    ///             (BTC allocation is demand-driven within this same ≤TVL bound —
    ///             no separate BTC-share cap.)
    ///         (2) `available` — volatile-asset inventory free to pair (venue
    ///             holdings − what's already in-range). PHYSICAL: can't pair more
    ///             token than is held.
    ///
    ///         WHAT HAPPENS TO THE EXCESS (deltaTok beyond the clamp): NOTHING is
    ///         lost or moved. The unpaired token stays at the yield venue (the
    ///         "Universal retention" — still LP-owned, still earning venue yield,
    ///         and bearing NO IL because it isn't in the short-gamma position);
    ///         the uncommitted basket USD stays as general backing. The clamp is
    ///         precisely the IL-footprint bound: only the paired slice is the LP
    ///         overlay, the rest is the IL-free yield reserve.
    ///
    ///         ROUNDING: every mulDiv floors → commits ≤ requested, never more
    ///         (conservative; can only under-pair by dust, never over-commit).
    function addLiq(
        uint deltaTok, uint price, bool isBTC) public
        onlyUs returns (uint usdOut, uint outDelta) {
        // Body in VogueLib (EIP-170 headroom). The onlyUs guard stays here; the
        // delegatecalled body preserves address(this) == Vogue for the θ self-call.
        // Pass totalBuffer so addLiq sizes headroom on GROSS band backing (Vogue is ETH-only).
        return VogueLib.addLiq(address(V4), address(AUX), deltaTok, price, isBTC, totalBuffer);
    }

    // _addLiqChannel (channel-lock liquidity sizer) regrouped into BtcVault.sol.

     // pull liquidity from. . .
    /// @dev Thin forwarder: body in VogueLib.pullBody (delegatecall — EIP-170); the nonReentrant guard stays here,
    ///      storage refs (selfManaged/positions) mutate in place. Logic unchanged.
    function pull(uint id, // existing self-managed position
        int percent, address token) external nonReentrant {
        VogueLib.pullBody(address(V4), selfManaged, positions, id, percent, token, msg.sender);
    }

    // _distributeV4Fees + _calcYield folded into VogueLib.rebalanceBody (their ONLY caller was _rebalance; the
    // APY `yield` _calcYield computed was already discarded there). The token-canonical reorder + fee-increment
    // distribution now live in the library body; LAST_REPACK is stamped by the _rebalance forwarder.

    /// @dev Thin forwarder: the venue-routing body lives in VogueLib (EIP-170
    ///      headroom). Delegatecall preserves msg.value/address(this), so the WETH
    ///      wrap + venue placement + per-LP wall attribution behave identically.
    function _depositETH(address sender, address pledge,
        uint amount, uint8 venue) internal returns (uint sent) {
        return VogueLib.depositETH(address(WETH), address(AUX), address(EV),
            ethfiBacked, sender, pledge, amount, venue);
    }

    /// @notice Pull ETH from the basket and send to recipient. Used by
    /// Core for swap-out flows.
    function takeETH(uint howMuch, address recipient)
       external onlyUs returns (uint sent) {
       return _sendETH(howMuch, recipient);
    }

    /// @notice Redemption unwind. QU!D's dollars work as the band's USD side (capital
    ///         efficiency); when a redemption exceeds the FREE stables, free them back out by
    ///         BURNING in-range band liquidity -- this shrinks POOLED_USD (committedUsd18 down,
    ///         so the redeemer's usdAvailable rises for the subsequent take()). Reuses the
    ///         LP-withdraw burn primitive (_burnInRange) with recipient=0: the paired ETH is NOT
    ///         paid out (Core._settleTokSide gates delivery on `who != 0`), so it stays in the
    ///         venue -- LP EQUITY NEUTRAL (vogueETH/lpShares unchanged; only the band's mock
    ///         mirror shrinks, returning ETH from in-band to in-venue). Bounded by POOLED_ETH
    ///         (_burnInRange caps at it), so a truly insolvent basket simply frees all it can and
    ///         QU!D bears the residual via the haircut. onlyUs -- Aux drives it inside redeemAsBody.
    /// @param usdWanted 18-dec USD shortfall to free. @return usdFreed 18-dec USD actually freed.
    function unwindForRedeem(uint usdWanted) external onlyUs returns (uint usdFreed) {
        if (usdWanted == 0) return 0;
        uint usd6 = V4.POOLED_USD_ETH();     // band's in-range USD leg (6-dec)
        uint eth  = V4.POOLED_ETH();         // band's in-range ETH leg (18-dec)
        if (usd6 == 0 || eth == 0) return 0; // empty band -> free stables only
        (uint160 sqrtP, int24 tickLower, int24 tickUpper,,) = _rebalance();
        // ROOT-PRECISE: size the ETH removal by the band's OWN in-range USD/ETH ratio, NOT an external TWAP.
        // Removing the fraction `usdWanted/(usd6·1e12)` of the position releases EXACTLY `usdWanted` USD (plus
        // the paired ETH, which stays in-venue). ETH to pull = usdWanted·eth/(usd6·1e12); _burnInRange caps at
        // POOLED_ETH. This frees precisely what redemption asks (no over/under-free) with ZERO oracle dependency
        // — so a dead TWAP no longer zeroes the unwind, and the mixed USD/ETH release no longer under-delivers.
        _burnInRange(sqrtP, FullMath.mulDiv(usdWanted, eth, usd6 * 1e12), tickLower, tickUpper, address(0));
        uint after6 = V4.POOLED_USD_ETH();
        usdFreed = usd6 > after6 ? (usd6 - after6) * 1e12 : 0;
    }

    /// @notice Sync Morpho wethVault appreciation into the per-LP fees
    /// accumulator. NOT an aToken-era artifact — the bookmark/feesPerShare
    /// pattern is what attributes 4626 share appreciation to LPs (since
    /// the share count is fixed at Aux, only the per-share value moves;
    /// LPs don't hold shares directly, they hold a `pooled` claim
    /// against the shared Aux position). Removing this would leave
    /// Morpho appreciation unclaimable by LPs.
    // _syncYield folded into VogueLib.rebalanceBody (its ONLY caller was _rebalance). The plain-venue
    // appreciation accrual over PLAIN depth into venueFeesPerShare is unchanged; `_venueBalance` (below) STAYS
    // because _withdraw/_depositImpl also call it.

    function _sendETH(uint howMuch,
       address toWhom) internal returns (uint sent) {
        uint alreadyInETH = address(this).balance;
        if (alreadyInETH >= howMuch) sent = howMuch;
        else { uint needed = howMuch - alreadyInETH;
            uint inWETH = WETH.balanceOf(address(this));
            if (needed > inWETH) {
                uint got = EV.vogueOp(false,
                       needed - inWETH, 1, bytes32(0));
                             inWETH += got;
                // §M.1 (✅ VERIFIED 2026-07-27 by testReal_DeleverEthBacking_SwapOutTapsLeveredSlice, real
                // Morpho/Euler fork — value-neutrality, LTV improvement and no-phantom-depth all asserted):
                // the WETH venue base
                // (deliverableETH, net-equity-excluded) is exhausted but POOLED_ETH priced the swap against the
                // levered slice too — so de-lever the levered book with the swap's OWN proceeds, turning the §M
                // phantom depth into REAL deliverable ETH. VALUE-NEUTRAL per LP; NOT the removed toxic arbETH
                // (which spent shared basket surplus) — SwapLib.deleverEthOnDelivery repays each LP's OWN debt.
                // Delivers freed WETH to Vogue (address(this)) → folded into the unwrap below. Delegatecall keeps
                // the walk's bytecode OUT of Vogue (EIP-170).
                if (inWETH < needed) {
                    address mgr = ILevHost(address(EV)).LEV_MANAGER();
                    if (mgr != address(0)) {
                        uint px = AUX.getTWAPforAsset(address(WETH), 1800);   // USD 1e18 / WETH
                        inWETH += SwapLib.deleverEthOnDelivery(mgr, address(AUX), px, needed - inWETH, address(this));
                    }
                }
            }  WETH.withdraw(inWETH);
            sent = inWETH + alreadyInETH;
        }
        (bool success, ) = payable(toWhom).call{
                                   value: sent }("");
        // Revert on a failed send so the unlock rolls back
        // atomically — vs the old swallow that left the unwrapped ETH stranded
        // at the contract while reporting sent=0.
        require(success, "ethSend");
    }


    // ════════════════════════════════════════════════════════════════
    //  BTC LP path REGROUPED into BtcVault.sol (registerBtcLp /
    //  unregisterBtcLp / resizeBtcLp / _resizeBtcLp). The shared isBTC-
    //  parameterized helpers above stay here for the ETH side; the BTC
    //  repack is now driven by BtcVault.repack(true).
    // ════════════════════════════════════════════════════════════════


    /// @notice ETH (isBTC=false) is the live entrypoint; the wrapper keeps the
    ///         `bool isBTC` shape so the same calls and the JIT/repack flow read
    ///         identically to the pre-library code. The SHARED skeleton (range
    ///         read, TWAP manipulation guard, V4.repack, JIT-defense collect)
    ///         lives in SwapLib.rebalanceCore; only the ETH-only steps stay
    ///         here: the Morpho _syncYield pre-sync, the _calcYield post-metric
    ///         (LAST_REPACK + avgYield), and the per-pool fee reorder/distribute.
    /// @dev Thin forwarder: the fee/yield harvest cluster (_syncYield + rebalanceCore + _calcYield/
    ///      _distributeV4Fees) moved to VogueLib.rebalanceBody (delegatecall — EIP-170; relocates the inlined
    ///      rebalanceCore). It mutates only value-type accumulators, returned as increments/flags applied here.
    ///      Byte-identical: same ordering (_syncYield reads venue balance BEFORE rebalanceCore), same arithmetic;
    ///      the discarded `_calcYield` APY return is dropped. `_venueBalance` STAYS (its other callers use it).
    function _rebalance() internal returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity, uint resolvedTwap) {
        VogueLib.RebalOut memory o = VogueLib.rebalanceBody(VogueLib.RebalIn({
            core: address(V4), aux: address(AUX), ev: address(EV), weth: address(WETH),
            token1isETH: token1isETH, lpShares: lpShares, totalLevPooled: totalLevPooled,
            totalBuffer: totalBuffer, lowerTick: LOWER_TICK, upperTick: UPPER_TICK, bookmark: bookmark}));
        venueFeesPerShare += o.venueFeesPerShareInc;             // _syncYield accrual
        bookmark = o.newBookmark;
        feesPerShare += o.feesPerShareInc; USD_FEES += o.usdFeesInc; // _distributeV4Fees
        
        if (o.setLastRepack) LAST_REPACK = block.timestamp;      // _calcYield's live effect
        if (o.reseatBump) reseatEpoch++;                         // ticks recentered → re-anchor signal
        LOWER_TICK = o.tickLower; UPPER_TICK = o.tickUpper;      // write the (possibly new) range back
        return (o.sqrtPriceX96, o.tickLower, o.tickUpper, o.myLiquidity, o.resolvedTwap);
    }

    /// @notice Repack the ETH pool's in-range LP position when it drifts
    ///         outside the LP range. The `bool` arg is retained only for the
    ///         Core IVogueRepack interface (BtcVault repacks the BTC
    ///         pool); Vogue is ETH-only. Returns the post-repack pool state.
    function repack(bool /*isBTC*/) public onlyUs returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity, uint resolvedTwap) {
        return _rebalance();
    }

    /// @notice PERMISSIONLESS deadlock-recovery poke. The auto-heal lives in
    ///         `SwapLib.rebalanceCore` (folded into the repack-first of every
    ///         swap/deposit/withdraw): when the internal TWAP is >5% off Chainlink
    ///         the curve spot is moved onto the oracle so swaps resume at the real
    ///         price. This entry just runs that rebalance WITHOUT a swap, so anyone
    ///         can unstick the pool even if no one is trading. No-op when aligned.
    function reseat() public nonReentrant {
        _rebalance();
    }

    function paddedSqrtPrice(uint160 sqrtPriceX96,
        bool up, uint delta) public pure returns (uint160) {
        return SwapLib.paddedSqrtPrice(sqrtPriceX96, up, delta);
    }


    function _updateTicks(uint160 sqrtPriceX96, uint delta)
        internal pure returns (int24 tickLower, uint160 lower,
                             int24 tickUpper, uint160 upper) {
        return SwapLib.updateTicks(sqrtPriceX96, delta);
    }

    // ════════════════════════════════════════════════════════════════
    //          ERC-20 TRANSFER FACE + NATIVE LP ENTRYPOINTS
    // ════════════════════════════════════════════════════════════════
    //
    // Makes Vogue LP positions transferable. The underlying autoManaged
    // mapping + lpShares + feesPerShare + USD_FEES accumulators are
    // PRESERVED EXACTLY — this layer adds standard ERC-20 transfer/
    // approve plus the deposit/redeem entrypoints.
    //
    // §J.2b — THE ERC-4626 VIEWS ARE NO LONGER HERE. `asset`, `totalAssets`,
    // `convertTo*`, `preview*`, `max*`, `name` and `symbol` moved to
    // `VEth.sol`, because Vogue is the band manager for BOTH asset classes
    // (its math is parameterised by `isBTC` throughout) and so cannot
    // honestly implement a single-asset 4626. `VEthIdentity.t.sol` asserts
    // that Vogue returns EMPTY for each of those selectors.
    // What stays here is deliberate: the ERC-20 face is the TRANSFER
    // AUTHORITY over `autoManaged[].pooled`, which is load-bearing band
    // state, and the entrypoints carry the per-deposit `venue` selector and
    // the payable ETH path. `VEth` is a stateless PROJECTION that reads
    // both back through this contract — it owns no balances of its own.
    //
    // Yield attribution preservation invariant:
    //   On any transfer, BOTH parties' pending rewards are settled
    //   (compounded into pooled / accumulated in usd_owed) BEFORE
    //   the principal moves. The transferred pooled therefore
    //   carries no entitlement to past rewards — they're already
    //   credited to the sender. The receiver starts earning on the
    //   transferred principal from the current accumulator bookmark.
    //
    // V4 position ownership: Core's V4 positions use salt=0 (read
    // _modifyLiquidity at line ~561). All LP capital sits in ONE
    // collective V4 position per range, with autoManaged tracking
    // per-LP proportional ownership. ERC-20 transfer just rebalances
    // the mapping — no V4-side coordination needed.

    uint8  public constant decimals = 18;




    event Deposit(address indexed sender, 
                  address indexed owner, 
                uint assets, uint shares);

    event Withdraw(address indexed sender, address indexed receiver,
                   address indexed owner, uint assets, uint shares);
    
    // BtcLpFeesOwed event regrouped into BtcVault.sol.
    /// @notice ERC-20 balance = LP's principal in pool. This is the
    /// already-compounded value; pending rewards (not yet credited)
    /// are revealed via previewRedeem / pendingRewards.
    // ─── §J.2c: the TOKEN FACE lives on `VEth`, the STATE lives here ──────────────
    // `Vogue` manages BOTH asset classes, so an ERC-20 face on it is ill-defined by
    // construction: `transferFrom` moved ETH-band shares while nothing in the signature
    // said WHICH, and BTC band shares (`Vault.autoManagedBTC`) have no transfer face at
    // all. The mutators therefore move to `VEth`, which is unambiguously the vETH token;
    // Vogue keeps the state and stays the authority.
    //
    // One-shot pin, mirroring `setEthVenueContract`: `VEth` is deployed AFTER Vogue, so
    // this cannot fold into `setup()`.
    address public VETH;
    error VEthPinned();
    function setVEth(address v) external {
        require(msg.sender == DEPLOYER, "403");   // Vogue is ownerless post-setup (renounced)
        if (VETH != address(0)) revert VEthPinned();
        VETH = v;
    }

    /// @notice Move band shares on `VEth`'s behalf. The ONLY external door to
    ///         `_transferShares`, and it is gated to `VEth` so "which shares?" can no
    ///         longer be asked of Vogue. Allowance accounting lives on `VEth` (it is the
    ///         token's own approval semantics); this call is the authority half only.
    function transferSharesFor(address from, address to, uint amount) external nonReentrant {
        require(msg.sender == VETH, "403");
        _transferShares(from, to, amount);
    }

    function balanceOf(address user) public view returns (uint) {
        return autoManaged[user].pooled;
    }

    /// @notice ERC-20 supply = sum of all LPs' pooled.
    function totalSupply() public view returns (uint) {
        return lpShares;
    }

    // §J.2c: `approve` / `transfer` / `transferFrom` MOVED TO `VEth`, together with the
    // `allowance` storage and the `Approval`/`Transfer` events. Vogue keeps the STATE and stays
    // the transfer AUTHORITY (`transferSharesFor` above, gated to `VEth`), but no longer presents
    // a token face — so "which asset's shares am I moving?" can no longer be asked of a contract
    // that manages two. `balanceOf`/`totalSupply` remain as plain ACCESSORS (59 test sites read
    // them, and `VEth` re-exposes both as the canonical token face); without the mutators they
    // are no longer an ERC-20 surface, just reads.

    /// @dev Move `amount` of pooled from `from` to `to`. Settles
    /// pending rewards on BOTH sides first so the moved principal
    /// carries no past-rewards claim. Self-transfers rejected: would
    /// double-settle the same position (second settle reads inflated
    /// pooled against the not-yet-refreshed bookmark → phantom
    /// reward = R × feePerShare / WAD).
    /// @dev Thin forwarder: the settle-both-sides + move-principal + refresh body moved to
    ///      VogueLib.transferSharesBody (delegatecall — EIP-170). Value-type `lpShares` growth returns as a delta
    ///      applied here; the Transfer event stays here (emitted for amount==0 too — Transfer(from,to,0)). Logic
    ///      unchanged (pendingRewards reached via self-staticcall; _refreshBookmarks replicated in the lib).
    function _transferShares(address from, address to, uint amount) internal {
        lpShares += VogueLib.transferSharesBody(
            autoManaged, levPooled, levBuf, venueBm, from, to, amount, feesPerShare, USD_FEES, venueFeesPerShare);
    }

    // ─── share math (NOT a 4626 — see VEth.sol) ─────────────────────
    // Vogue is the band manager for BOTH asset classes (its math is parameterised by `isBTC`
    // throughout), so it cannot honestly implement ERC-4626, which is defined around ONE `asset()`.
    // §J.2b moved that identity — `asset`, `totalAssets`, `name`, `symbol`, and the whole
    // `max*`/`preview*` surface — to `VEth.sol`, which reads it all back THROUGH this contract.
    // What stays here is the share MATH and the entrypoints, which are the protocol's native LP API
    // (per-deposit `venue` selector, payable ETH path, `_depositImpl`/`_withdraw` machinery).

    /// @dev Pricing backing: `vogueETH` with the levered book restated onto the SAME CLOCK as the
    ///      denominator. `vogueETH` adds `totalNetEquityEth()` read LIVE from the venues
    ///      (`VaultLib:150`), but the matching term inside `lpShares` is `totalLevPooled`, which is
    ///      STORED and only refreshed by `_reconcileLev`/`syncLev` — i.e. on the levered LP's own next
    ///      action. Live numerator over lazy denominator is the whole defect (§A.16b): an external
    ///      Morpho liquidation cut the numerator instantly while the denominator still carried the
    ///      seized collateral, so the price fell 32% for EVERY holder and a passive LP absorbed ~half
    ///      of a liquidation it had no part in.
    ///
    ///      Swapping the LIVE term for the RECORDED one makes both sides move together: while the book
    ///      is stale the price is simply unchanged, and when reconciliation lands, the levered LP's own
    ///      shares burn alongside the backing. NOT the same as netting the levered book OUT — that was
    ///      tried and REVERTED (§A.16d): the levered capital is commingled in the band, so removing it
    ///      strips backing that genuinely supports plain claims (measured: 69% under-pricing).
    ///      In steady state (`totalNetEquityEth == totalLevPooled`) this is EXACTLY `vogueETH`, so
    ///      normal-case pricing is byte-identical to before.
    function _pricingBacking() internal view returns (uint total) {
        total = AUX.vogueETH();
        address lm = VogueLib.levManager(address(AUX));
        if (lm == address(0)) return total;
        // GUARDED like every other lev read: a broken manager must not brick share pricing.
        try ILevEquityV(lm).totalNetEquityEth() returns (uint live) {
            total = total > live ? total - live : 0;   // drop the LIVE term
            total += totalLevPooled;                   // restore the RECORDED one (denominator's clock)
        } catch {}
    }

    function convertToShares(uint assets) 
        public view returns (uint) {
        uint total = _pricingBacking();
        if (lpShares == 0 || total == 0) return assets;
        return FullMath.mulDiv(assets, lpShares, total);
    }

    function convertToAssets(uint shares) public view returns (uint) {
        uint total = _pricingBacking();
        if (lpShares == 0 || total == 0) return shares;
        return FullMath.mulDiv(shares, total, lpShares);
    }

    // ─── ERC-4626 deposit / redeem (thin wrappers) ──────────────────
    // The standard 4626 entrypoints. They route into the existing
    // _depositImpl / _withdraw paths so the full machinery still runs
    // (checkBacking, _rebalance, addLiq, JIT-defense, AUX.take, etc.).

    function deposit(uint assets, address receiver)
        external payable nonReentrant returns (uint shares) {
        return _deposit4626(assets, receiver, VENUE_SPLIT);
    }

    /// @notice Per-deposit venue variant — the venue rides the deposit call
    ///         (0 = SPLIT 5-way, 2 = AAVE-v4, 3 = Galaxy, 4 = ether.fi via Rover,
    ///         5 = Euler, 6 = Gauntlet; there is deliberately no "1"/ether.fi code —
    ///         ether.fi always routes through Rover). No standing preference, no separate tx.
    function deposit(uint assets, address receiver, uint8 venue)
        external payable nonReentrant returns (uint shares) {
        return _deposit4626(assets, receiver, venue);
    }

    function _deposit4626(uint assets, address receiver, uint8 venue)
        internal returns (uint shares) {
        require(receiver != address(0), "receiver");
        uint preShares = autoManaged[receiver].pooled;
        _depositImpl(assets, receiver, venue);
        shares = autoManaged[receiver].pooled - preShares;
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint shares, address receiver)
        external payable nonReentrant returns (uint assets) {
        return _mint4626(shares, receiver, VENUE_SPLIT);
    }

    /// @notice Per-deposit venue variant of mint (see deposit overload).
    function mint(uint shares, address receiver, uint8 venue)
        external payable nonReentrant returns (uint assets) {
        return _mint4626(shares, receiver, venue);
    }

    function _mint4626(uint shares, 
        address receiver, uint8 venue)
        internal returns (uint assets) {
        require(receiver != address(0), "receiver");
        assets = convertToAssets(shares);
        uint preShares = autoManaged[receiver].pooled;
        
        _depositImpl(assets, receiver, venue);
        uint actualShares = autoManaged[receiver].pooled - preShares;
        // 4626-compliance: mint must yield AT LEAST the requested shares.
        // If the caller's allowance/balance falls short, _depositImpl pulls
        // less than `assets` and actualShares < shares — revert to surface
        // the underdelivery rather than silently returning a stale `assets`.
        require(actualShares >= shares, "mint:short");
        emit Deposit(msg.sender, receiver, assets, actualShares);
    }

    function redeem(uint shares, address receiver, address owner)
        external nonReentrant returns (uint assets) {
        // Direct-owner-only path. Allowance flow not supported on Vogue:
        // _withdraw reads autoManaged[msg.sender], so debiting `owner`'s
        // position requires msg.sender == owner. Front-ends wanting to
        // act on behalf of `owner` must first transferFrom the LP shares
        // to msg.sender, then redeem normally. Reverts AllowanceFlow on
        // owner != msg.sender to keep the surface honest.
        if (owner != msg.sender) revert AllowanceFlow();
        _requirePinnedRecipient(owner, receiver);
        assets = convertToAssets(shares);
        _withdraw(assets, receiver, false);   // 4626 path defaults to WAIT (no forced haircut)
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function withdraw(uint assets, address receiver, address owner)
        external nonReentrant returns (uint shares) {
        if (owner != msg.sender) revert AllowanceFlow();
        _requirePinnedRecipient(owner, receiver);
        // CAP FIRST, then convert (2026-07-26). `convertToShares` used to run on the RAW `assets`, so
        // the standard "exit everything" sentinel `withdraw(type(uint).max)` REVERTED with no message:
        // it is `FullMath.mulDiv(assets, lpShares, vogueETH())`, whose overflow guard is a bare
        // `require`, and `type(uint).max * lpShares` trips it unconditionally. 10+ call sites use the
        // sentinel, so this reverted in NORMAL operation.
        //
        // The cap is the LP's FULL position (≡ `maxWithdraw`), NOT their free/plain slice. That
        // distinction is load-bearing: `_withdraw` fires #109's auto-de-lever on the strict test
        // `amount > plainNet(pooled, levPooled)` (:504) and only THEN clamps (:511), re-reading
        // `plainNet` after `_reconcileLev` has zeroed the closed slice. Capping to `plainNet` here
        // would make that test unsatisfiable by construction and silently disable auto-de-lever on
        // the whole 4626 path — a levered LP could never exit past their free depth. Capping to the
        // full position keeps `amount > plainNet` reachable, bounds the conversion, and makes the
        // sentinel mean "exit my entire position", which is exactly what `maxWithdraw` advertises.
        // UNITS: cap in POOLED units, which is what `_withdraw` itself clamps in (`amount` vs
        // `plainNet(LP.pooled, levPooled)`, :511) — NOT through `convertToAssets`. Routing the cap
        // through the share-conversion made the payout depend on `vogueETH()`, so once the redeem
        // turns had unwound the band the ceiling floored to 0 and a full-exit LP received NOTHING
        // (measured: `test_RunSim_AllExit_Normal`, LP1 got 0 of 8 ETH — a test that PASSES upstream).
        // Capping at the raw `pooled` reproduces upstream's effective behaviour exactly (upstream left
        // `assets` huge and let `_withdraw` clamp it) while still bounding `convertToShares`, and it
        // keeps `amount > plainNet` reachable whenever `levPooled > 0` so #109 still fires.
        uint ceiling = autoManaged[msg.sender].pooled;
        if (assets > ceiling) assets = ceiling;
        shares = convertToShares(assets);
        _withdraw(assets, receiver, false);   // 4626 path defaults to WAIT (no forced haircut)
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Edge-case exit identical to `withdraw` but opts INTO the instant ether.fi
    ///         redeem (~0.3%) for THIS tx only — used in the rare both-pools-drained anomaly.
    ///         Per-tx replacement for the former withdrawInstant stored flag; owner is always
    ///         msg.sender (no allowance flow, mirroring withdraw/redeem).
    function exitInstant(uint assets, address receiver)
        external nonReentrant returns (uint shares) {
        shares = convertToShares(assets);
        _withdraw(assets, receiver, true);
        emit Withdraw(msg.sender, receiver, msg.sender, assets, shares);
    }

    /// @notice Harvest accrued fees WITHOUT withdrawing the position. The USD-leg
    ///         mints as QUID to the LP; the token-leg (ETH fees) compounds into the
    ///         position — the same realization withdraw/deposit perform, just
    ///         position-preserving. Mirrors the deposit's settle→rebaseline exactly,
    ///         so a repeated call yields nothing (no double-pay).
    function collectFees() external nonReentrant {
        Types.Deposit storage LP = autoManaged[msg.sender];
        if (LP.pooled == 0) revert NoPosition();
        _rebalance();                                // harvest pool fees into the accumulators
        uint eth_fees = feesPerShare;
        uint usd_fees = USD_FEES;
        _settlePending(LP, msg.sender, msg.sender);  // mint usd_owed+pending QUID; token-leg compounds
        _refreshBookmarks(msg.sender, eth_fees, usd_fees);   // rebaseline → next pending is 0
    }

    /// @notice PERMISSIONLESS auto-compound of `lp`'s accrued fees — WITHOUT any
    ///         action from the LP. Anyone (a keeper, a monitor, or the LP) may
    ///         crank it: it harvests pool fees into the accumulators, folds `lp`'s
    ///         owed TOKEN leg into their `pooled` (so from now on it earns
    ///         fees-on-fees — the actual compounding), and accrues the USD leg to
    ///         `usd_owed`. Compounding is otherwise gated on `_settlePending`,
    ///         which only runs when the LP is TOUCHED (their own collectFees /
    ///         deposit / withdraw, or an incidental levered-slice syncLev poke),
    ///         so a plain LP who never touches their position silently donates the
    ///         compounding on their unclaimed fees to the rest of the pool.
    ///
    ///         Crucially this moves NOTHING out of the contract: `mintRecipient`
    ///         is `address(0)`, so the USD leg only accrues to the LP's own
    ///         `usd_owed` and the token leg only grows the LP's own `pooled`. It is
    ///         therefore pure benefit to `lp` with NO theft or grief vector — no
    ///         revocable-client scope / opt-in is needed to let a keeper crank
    ///         every LP on a schedule. Same three-call shape as `collectFees`; the
    ///         arbitrary-`lp` `_settlePending`/`_refreshBookmarks` path is already
    ///         proven by the permissionless `syncLev` reconcile. No-op (not revert)
    ///         on an empty position so a keeper can sweep a list cheaply.
    /// Conservative gas an on-chain `compound` crank burns; the self-funding tip reimburses up to
    /// this × a grief-capped gasprice out of the LP's OWN harvested token-leg — so the keeper needs
    /// ZERO operator gas subsidy (the operator covers no gas at all).
    uint private constant COMPOUND_GAS = 140_000;
    /// Anti-grief ceiling on the gasprice the tip pays for: a caller can't inflate `tx.gasprice`
    /// to skim more of the LP's fees as "gas".
    uint private constant COMPOUND_MAX_GASPRICE = 200 gwei;

    /// @notice Permissionless, keeper-crankable fee compounding for a plain ETH LP — folds owed
    ///         token-leg fees into `pooled` (fees-on-fees) so a passive LP no longer donates that
    ///         compounding to the pool. SELF-FUNDING: reimburses the caller's gas as an ETH tip
    ///         skimmed from the LP's OWN harvested token-leg (grief-capped, ≤ half the harvest so the
    ///         LP always keeps the majority), unwrapped from the JUST-HARVESTED WETH (in-flight — no
    ///         idle WETH is ever held, per the Rover ethos). Below the floor ⇒ keeper-safe no-op:
    ///         the fees stay pending and compound later (a bigger crank, or when the LP itself touches
    ///         its position). Backing-consistent: `pooled` grows by exactly `tokR − tipSent`, and
    ///         exactly `tipSent` WETH leaves, so `pooled` ↔ backing stays matched.
    function compound(address lp) external nonReentrant {
        Types.Deposit storage LP = autoManaged[lp];
        if (LP.pooled == 0) return;                  // nothing to compound — keeper-safe no-op
        (uint160 sqrtP, int24 tickLower, int24 tickUpper,,) = _rebalance(); // repack-first: roll pool fees into feesPerShare
        uint eth_fees = feesPerShare;
        uint usd_fees = USD_FEES;
        (uint tokR, uint usdR) = _pendingFor(lp);    // token-leg (WETH-units) + USD-leg owed

        // SELF-FUNDING TIP. The token leg is NEVER free WETH — like every LP fee it lives as band
        // liquidity (see _settlePending: `LP.pooled += tokR`), so there is nothing to unwrap. Instead the
        // cranker is paid by burning a `tip`-sized sliver of the band to itself as native ETH — the SAME
        // _burnInRange primitive _withdraw uses to deliver an LP's ETH. The tip is grief-capped at half the
        // harvest and comes out of THIS LP's realized fees only (the LP compounds `tokR − sent`, other LPs'
        // feesPerShare bookmarks are untouched), so backing == claims is preserved and no operator gas is
        // ever needed. Zero gasprice (default in unit tests) ⇒ tip 0 ⇒ full compound, unchanged behaviour.
        uint gp  = tx.gasprice < COMPOUND_MAX_GASPRICE ? tx.gasprice : COMPOUND_MAX_GASPRICE;
        uint tip = gp * COMPOUND_GAS;
        if (tip > tokR / 2) tip = tokR / 2;          // cranker never takes more than half the harvest

        // Burn-to-cranker FIRST so `sent` (capped at the band's active slice) is the truth for the
        // accounting below; the whole fn is nonReentrant so the native-ETH send can't re-enter.
        uint sent = tip > 0 ? _burnInRange(sqrtP, tip, tickLower, tickUpper, msg.sender) : 0;

        // EFFECTS: compound only what was NOT paid to the cranker; carry the USD leg (nothing leaves).
        uint net = tokR > sent ? tokR - sent : 0;
        if (net > 0) { LP.pooled += net; lpShares += net; }
        if (usdR > 0) LP.usd_owed += usdR;
        _refreshBookmarks(lp, eth_fees, usd_fees);   // rebaseline → next pending is 0
    }
}
