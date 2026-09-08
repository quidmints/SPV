
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RangeLib} from "./imports/RangeLib.sol";
import {Core} from "./Core.sol";
import {Aux} from "./Aux.sol";
import {Basket} from "./Basket.sol";

import {SwapLib} from "./imports/SwapLib.sol";
import {BtcLib} from "./imports/BtcLib.sol";
import {VBtc} from "./VBtc.sol";
import {Types, AlreadyInitialized, BtcChannelsPinned, NotBTCChannels, Unauthorized} from "./imports/Types.sol";
import {Shares} from "./Shares.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {ILevEquity} from "./imports/Interfaces.sol";
import {QuidLib} from "./imports/QuidLib.sol";

// ════════════════════════════════════════════════════════════════════════
//  Vault — THE BTC RANGE MANAGER, and only that. `Quid` is the ETH-side counterpart; the two are
//  one implementation waiting to become two instances (CLAUDE.md's §J.2 consolidation).
//
//  🔴 §E301/§ETHVENUE-GHOSTS — NO ETH-VENUE CUSTODY LIVES HERE, and do NOT go looking for
//  `EthVenue.sol`: it does not exist either. ETH-venue custody was extracted out of this contract
//  and then folded into `Quid` (the ETH range manager IS the ETH venue), so `Aux.ethVenue` is
//  pinned to the range manager — `DeployLib` runs `aux.wire(0, address(ETH), 0)`. This header, the
//  ETH-VENUE gate it described and every ETH function that gate named are gone; `contract Vault is
//  Ownable, ReentrancyGuard, Shares` and nothing else.
//  ⚠️ **THAT DELETED GATE WAS ALSO SPELLED `onlyUs`, AND THE NAME IS LIVE AGAIN — DO NOT READ THIS
//  PARAGRAPH AS SAYING THE MODIFIER BELOW IS DEAD.** §E301 removed an ETH-venue `onlyUs` that gated
//  ZERO functions; the `onlyUs` modifier below is the BTC range's own gate, renamed here from
//  `onlyUsBtc` (§FOLD-BLOCKER: one name per concept, two instances — the same direction as
//  `resizeBtcLp`→`resize` and `syncLevBTC`→`syncLev`). Same concept as `Quid.onlyUs`, different
//  instance, and it gates the five functions listed under GATES below.
//  ⚠️ AN EXTRACTION LEAVES THE HANDLES AND THE COMMENTS BEHIND: grep the old collaborator's TYPE
//  after any move, not just the moved functions (`RANGE` outlived this one by eight days).
//
//  `setup(quid)` pins the basket and does the post-CORE-init `poolStats` read that seeds
//  RANGE_ANCHOR. The owner-gated surface is exactly `setup` and `setLevManager`, both one-shot.
//
//  GATES — TWO, both address-specific, neither widened:
//    • onlyUs       = {Core(CORE), AUX, this} → repack · setBTCChannels · addLiq ·
//                                                   creditSkewPremium · onShortfall
//    • onlyBTCChannels = {btcChannels}           → requestDeposit/requestRedeem/resize ·
//                                                   swap-in/swap-out credit · pendingSwapOut
//  Address-specific gates mean every interface-wired caller (Aux.btc / Core.BTC /
//  BTCChannels.btc / Basket.BTC_VAULT) just points at this one address.
// ════════════════════════════════════════════════════════════════════════

/// BtcLevManager read surface: the leveraged book's collateral (vBTC, 8-dec sats). The collateral lives
/// on external Morpho per-LP (the Vault never holds it). The book is counted at NET equity
/// (gross − debt) in both `POOLED` and `lpShares`; the debt-funded buffer (gross − net) is EXCLUDED from
/// equity and tracked separately as fee-earning range depth (`Quid.levBuf`/`Vault.levBuf` + `totalBuffer`),
/// so it earns fees on the gross weight but never inflates the LP's redeemable claim. The buffer's debt is
/// excluded from committed via `committedUsd18`'s live-debt subtraction (no separate POOLED_USD_*_LEV bucket),
/// so a venue liquidation un-pairs the buffer (`levBurnAll`) without stranding basket `POOLED_USD`.

/// BTC IL-protect: the BtcLevManager's per-LP net-of-debt equity IS protocol BTC backing (8-dec
/// sats), so `syncLev` pairs it as tokenless range depth INTO `POOLED` (LP.pooled) — that is where
/// the net-equity is counted for solvency. `rangeBTC` is WBTC-only (swept donations + swap deltas) and is
/// NEVER credited the net-equity, so `POOLED + rangeBTC` (Core shortfall read) is single-counted. Net
/// (not gross): a venue liquidation can't strand POOLED_USD. Mirrors the ETH `ILevEquity` over the BTC range.
/// Declared once, in imports/Interfaces.sol.

    // §E252 — the THIRTEEN shared range-state declarations moved to `State` (Shares.sol).
    // They were byte-identical in both managers; the merge aligns STORAGE LAYOUT, which is the
    // precondition for one implementation with two instances. No bytecode changes: state emits none.
contract Vault is Ownable, ReentrancyGuard, Shares {

    // ─── immutables ─────────────────────────────────────────────────────
    /// @dev ⛔ MUST STAY PUBLIC. While `internal`, nothing outside could address the BTC `Core`, so
    ///      cross-range isolation tests read the ETH core TWICE and compared a value to itself —
    ///      vacuously true. An instance you cannot address is an instance you cannot check.
    Core public immutable CORE;  // the PM (was BtcVault's "RANGE")
    Aux       internal immutable AUX;
    // 🔴 §ETHVENUE-GHOSTS — `WETH9 public immutable WETH` is DELETED: zero reads here, and every
    //    tree-wide `.WETH()` resolves on `Aux`. ⛔ The constructor still TAKES that third address
    //    (unnamed) so `DeployLib`'s `new Vault(core, aux, cfg.weth)` still binds — a constructor is
    //    a signature. Do not drop the parameter without changing `DeployLib` in the same commit.









    /// @notice The IL-protect orchestrator (`Shares.LEV_MANAGER`). Its leveraged book's LIVE
    ///         net-equity counts in `POOLED` (§SLOP: said `rangeETH`, which is Quid's ETH-side
    ///         accessor, not this contract's). Pinned once post-deploy by `setLevManager`, which
    ///         checks the manager's own `ORACLE_KEY` is WBTC — so the ETH one cannot be installed
    ///         here. 0 = leverage disabled. (§ETHVENUE-GHOSTS: this line read "LevManager needs Aux/weETH
    ///         first", which is the ETH manager's construction ordering, not the BTC one's.)

    error NoBtcPosition();

    Basket QUID;

    /// @notice BTC-side LP accounting — parallel to the ETH-side trio in Quid.
    /// `autoManaged[user].pooled` slot holds the user's pooled WBTC
    /// (8-dec, type-reused from Types.Deposit). `lpShares` is the sum.
    /// `feesPerShare` accumulates BTC-side RANGE trading fees (in WBTC);
    /// `USD_FEES` accumulates USD-side RANGE trading fees from the BTC range.
    /// Both accrue from RANGE fills, which settle AT ORACLE against inventory — there is no
    /// Uniswap v4 pool anywhere in this tree, so nothing here is a pool-fee accrual.

    /// BTC IL-protect: per-LP LEVERED range slice (8-dec sats) — the mirror of Quid's `levPooled`.
    /// Backed by the BtcLevManager net-equity (not real channel sats), it earns RANGE fees but is
    /// UNWIND-ONLY: it never leaves via a channel splice/close (there's no channel BTC behind it), only
    /// via `syncLev` shrinking to match the manager. Excluded from the LP's withdrawable balance.
    /// @notice full-2×: 6-dec USD counterpart of an LP's DEBT-funded BTC buffer leg. Post-fold it folds
    ///         into POOLED_USD (no separate LEV bucket) and is excluded from committed via the live-debt
    ///         subtraction in committedUsd18. Bounded by the LP's own debt (enforced in BtcLib.levAddBufBtc).
    /// @notice NET model (mirror of Quid.levBuf): per-LP debt-funded BTC BUFFER depth (8-dec sats). It is
    ///         fee-earning RANGE depth but NOT equity — EXCLUDED from lpShares/pooled, INCLUDED in the GROSS
    ///         fee weight (pooled + levBuf) and the fee denominator (lpShares + totalBuffer).
    /// @notice Sum of every BTC LP's levBuf — the gross buffer total. Fee denom = lpShares + this.

    /// @dev NOT suffixed `_BTC`, deliberately — and do not add the suffix back. `Quid` names its
    ///      ETH-range accessors exactly as this contract names its BTC ones, so a cross-range caller
    ///      (`LevMath.reanchorCompute`) calls ONE `rangePrice()`/`rangeBounds()` pair on whichever
    ///      range it holds instead of selecting a NAME by flag — which is all that `isBTC` was doing
    ///      there. Each range answers for ITS asset; the CONTRACT IDENTITY carries the suffix.
    /// §ONE-ANCHOR — ONE stored number, `RANGE_ANCHOR` (declared in `Shares`); `rangeBounds()`
    /// derives the pair on read as `updateBounds(anchor, RANGE_DELTA)`.


    error ZeroTwap();
    error SwapOutShort();

    address public btcChannels;

    /// BTC-side trusted callers: Core (CORE), Aux, self.
    /// @dev §MODFOLD — body in a `private view`, modifier is the JUMP (rule 8c: a modifier inlines
    ///      at every site; the `Error(string)` "403" encoding is the expensive half).
    ///      ⛔ KEEP THE MODIFIER — do not call `_onlyUs()` from each body: a modifier is
    ///      positionally FIRST by construction, a body call can be reordered after a state read.
    function _onlyUs() private view {
        require(msg.sender == address(AUX)
             || msg.sender == address(CORE)
             || msg.sender == address(this), "403");
    }
    modifier onlyUs { _onlyUs(); _; }

    /// BTC-LP deposit/redeem/resize are driven by channel locks, and the swap-in/swap-out credit is
    /// attested by the same contract, so both are gated to the pinned `BTCChannels` — never the
    /// public 4626 surface.
    /// @dev §MODFOLD — ONE declaration of this gate, in one spelling (rule 2: one name per
    ///      concept). It is a bare address compare raising the custom `NotBTCChannels()`, which is
    ///      what the only tests asserting the gate expect (`ReentrancyProbe.t.sol` on
    ///      `creditSwapIn`/`creditSwapOut`) — not an `Error(string)`. `Aux` has NO counterpart gate
    ///      to match: `Vault._onlyBTCChannels` holds the comparison for the whole tree now, and
    ///      Aux's `_btcChannels` is a READ HANDLE only.
    ///      ⛔ Do NOT add a `btcChannels != address(0)` clause. It would discriminate only when
    ///      `msg.sender == address(0)` AND the pin were unset. `msg.sender` is never the zero
    ///      address in EVM execution — there is no account that can originate a call from it — so
    ///      the clause cannot fire on chain, and an unset pin already rejects every real caller
    ///      through the address compare alone. Rule 1 (no unreachable code), rule 3 (a clamp that
    ///      only looks like safety).
    function _onlyBTCChannels() private view {
        if (msg.sender != btcChannels) revert NotBTCChannels();
    }
    modifier onlyBTCChannels() { _onlyBTCChannels(); _; }

    /// @notice Pins the engine + Aux handles and DEPLOYS the vBTC token face, so
    ///         `VBtc.VAULT == address(this)` holds by construction (no setter, no deploy-ordering
    ///         hazard, supply authority cannot be misconfigured).
    /// @dev    The third parameter is UNNAMED and unused. It was `address _weth`, assigned to a
    ///         `WETH` immutable this contract never read; see the note above the `AUX` slot. It is
    ///         kept in the signature so `DeployLib`'s `new Vault(core, aux, cfg.weth)` still binds.
    ///         §ETHVENUE-GHOSTS — the docblock here previously described AAVE-v4 WETH resolution, an optional
    ///         "venue 2", and ether.fi adapter wiring with standing approvals. The constructor did
    ///         none of those even before the extraction removed the venues.
    constructor(address _core, address _aux, address)
        Ownable(msg.sender) {
        CORE = Core(_core);
        AUX = Aux(payable(_aux));
        VBTC = new VBtc(address(this), address(Aux(payable(_aux)).WBTC()));
    }
    /// @notice Bare-ETH receipt, and NOTHING ELSE.
    /// 🔴 **A `fallback() external payable {}` STOOD ON THE NEXT LINE AND HAS BEEN DELETED.**
    ///      It sat directly beside this `receive()`, which already handles every bare-ETH send —
    ///      so the fallback's ONLY effect was to swallow calls carrying a selector this contract
    ///      does not implement and return SUCCESS. That converts a client calling a deleted
    ///      entrypoint from a loud revert into a silent no-op, on a custody contract. CLAUDE.md
    ///      records exactly that happening to `Quid.exitInstant` (§E154-client-ghosts).
    ///      ⛔ Do not restore it. `receive()` is what bare ETH needs; a fallback is what hides
    ///      a mistake.
    receive() external payable {}

    /// @notice BTC-side init (formerly BtcVault.setup): pin QUID, read the BTC
    ///         range price via `CORE.poolStats()` (needs CORE.setup done) and seed `RANGE_ANCHOR`.
    ///         (There is no `slot0` and no pool to read one from; `poolStats` returns the observation
    ///         ring's `obsState.lastPrice`.) AUX/
    ///         CORE are constructor-set immutables, so only QUID is taken here.
    function setup(address _quid) external {
        if (msg.sender != owner()) revert Unauthorized();   // was front-runnable
        if (address(QUID) != address(0)) revert AlreadyInitialized();
        QUID = Basket(_quid);
        (uint priceWad,) = CORE.poolStats();
        // §ONE-ANCHOR — the seed IS the anchor: bounds are DERIVED on read as
        // `updateBounds(RANGE_ANCHOR, SwapLib.RANGE_DELTA)`, so ONE width governs the whole tree and
        // this seed cannot disagree with it. ⛔ Do not re-introduce a literal delta beside this line:
        // that is what the one-anchor form exists to delete. (`SwapLib.RANGE_DELTA = 200`, ±2%.)
        RANGE_ANCHOR = priceWad;
    }

    // ════════════════════════════════════════════════════════════════
    //                    BTC leverage book — the pin and its live read
    //  §ETHVENUE-GHOSTS: this banner said "ETH yield-venue side (was EthVenue)". There is no ETH yield venue
    //  here; the two functions below are `setLevManager` and `totalNetEquity`, both BTC. The banner
    //  outlived the section it named, so it filed BTC code under an ETH heading.
    // ════════════════════════════════════════════════════════════════

    /// @notice Pin the BtcLevManager (one-shot) so `rangeBTC` counts the BTC leveraged book's
    ///         net-equity and `syncLev` can read the per-LP target. Distinct from the ETH LEV_MANAGER.
    /// @dev §LEV-FOLD-2 — THE IDENTITY CHECK THAT REPLACES THE SUFFIXED SELECTORS. Until this
    ///      commit the only thing stopping a BTC lev manager being pinned to the ETH range (or the
    ///      reverse) was that the two managers exposed DIFFERENT selectors, so a wrong-range read
    ///      reverted. That is a clamp: it fires per call, forever, and only when the caller reaches
    ///      for the suffixed name. Folding the two interfaces into one removes it -- so the bad
    ///      state is made UNCONSTRUCTIBLE here instead, once, at the pin. A manager carries its own
    ///      range asset in `ORACLE_KEY` (immutable, set at construction: WETH for the ETH book,
    ///      WBTC for the BTC one), so the wrong one simply cannot be installed.
    ///      Standing rule 17: the root fix is the one that makes the previous guard DELETABLE.
    /// §FOLD-PINLEV — setter in `Shares`; these two lines are all that is BTC-specific.
    function _onlyPinner() internal view override { _checkOwner(); }
    function _rangeAsset() internal view override returns (address) { return address(AUX.WBTC()); }

    /// @notice LIVE sum of the BTC leveraged book's net-equity (8-dec sats), read straight off the
    ///         pinned manager. A VIEW ONLY — no protocol path calls it. The net-equity reaches
    ///         solvency by `syncLev` pairing it into `POOLED`; `rangeBTC` is NEVER credited it (see
    ///         the `ILevEquity` note at the top), so this must not be added to a backing read a
    ///         second time. try/catch so a venue hiccup can't brick it.
    function totalNetEquity() external view returns (uint) {
        if (LEV_MANAGER == address(0)) return 0;
        try ILevEquity(LEV_MANAGER).totalNetEquity() returns (uint ne) { return ne; } catch { return 0; }
    }



    // ════════════════════════════════════════════════════════════════
    //                        BTC side (was BtcVault)
    // ════════════════════════════════════════════════════════════════

    function setBTCChannels(address b) external onlyUs {
        if (btcChannels != address(0)) revert BtcChannelsPinned();
        btcChannels = b;
    }

    // ═══════════════════════ vBTC — the TOKEN face now lives in `VBtc` (§J.2) ═══════════════════════
    // The EVM representation of LN-custodied BTC used as the BTC IL-protect collateral. The ERC-20 + 4626
    // face (supply, balances, transferability) was SEGREGATED out of this contract into `VBtc.sol`; what
    // stays HERE is the RANGE ACCOUNTING (`autoManaged`, `levPooled`) plus the expose/unexpose gate.
    // THE SPLIT IS EXACT, not a redesign: `exposeBtcToLev` still performs the whole funded→lev
    // reclassification and its `InsufficientChannelBtc` check — it delegates ONLY the supply mutation, so
    // `LP.pooled` stays untouched and the single-count property that made the original merge worth having
    // is preserved. WHY: supply-level invariants (a future `redeemVBtc(sats, p2trScript)`, and
    // `Σ outstanding vBTC ≤ Σ free channel capacity`) belong WITH supply, not buried in range accounting.

    /// The vBTC token. Deployed BY this contract, so `VBtc.VAULT == address(this)` holds BY CONSTRUCTION —
    /// no setter, no deploy-ordering hazard, and supply authority can never be misconfigured. Venues and
    /// the Morpho market take THIS address as `collateralToken` (it is the token; the Vault is not).
    VBtc public immutable VBTC;

    error NotLevManagerBtc();
    error InsufficientChannelBtc();

    /// @notice SAME-BTC leverage (replaces the "LP pre-holds vBTC + transferFrom" roundtrip): reclassify
    ///   `sats` of the LP's FREE channel range BTC — already POOLED depth via `requestDeposit` — as the
    ///   levered slice, and mint the matching vBTC face to the LevManager for venue collateral. NO new BTC
    ///   enters the pool: the channel BTC was already banked, so `LP.pooled` is UNCHANGED (no double-count) —
    ///   only `levPooled` grows (funded→lev, withdrawal-excluded). vBTC is thus only ever "minted" against
    ///   real channel BTC (here), never conjured. Inverse of
    ///   `unexposeBtcFromLev`. Gated to the pinned LevManager (the sole leverage authority).
    function exposeBtcToLev(address lp, uint sats) external returns (bool) {
        if (msg.sender != LEV_MANAGER) revert NotLevManagerBtc();
        // Storage-mutation body in BtcLib.vbtcExposeBody (delegatecall — EIP-170); gate + the vBTC supply call stay here.
        BtcLib.vbtcExposeBody(autoManaged, levPooled, lp, sats);
        VBTC.mintTo(msg.sender, sats);   // the Transfer event is the TOKEN's to emit, not ours
        return true;
    }

    /// @notice Close-side inverse: burn the `sats` vBTC the manager withdrew from the venue and convert the
    ///   LP's levered slice back to FREE channel range depth (lev→funded). `LP.pooled` is UNCHANGED, so the
    ///   LP's range position simply un-freezes — grown by leverage gain / shrunk by loss (the LP bears its
    ///   own leverage P&L), since a preceding `syncLev` marked `levPooled` to the live net-equity == `sats`.
    ///   The LP never receives loose vBTC (that would double-claim the same channel BTC).
    function unexposeBtcFromLev(address lp, uint sats) external returns (bool) {
        if (msg.sender != LEV_MANAGER) revert NotLevManagerBtc();
        // Storage-mutation body in BtcLib.vbtcUnexposeBody (delegatecall — EIP-170); gate + the vBTC supply call stay here.
        VBTC.burnFrom(msg.sender, sats);   // reverts if the manager lacks the sats — checked BEFORE the range moves
        BtcLib.vbtcUnexposeBody(levPooled, lp, sats);
        return true;
    }

    /// @notice BTC-side parallel of Quid.totalShares — a VIEW over lpShares.
    /// @notice §E5 (BTC mirror of `Quid.creditSkewPremium`) — route the retained scarcity premium
    ///         to BTC-range LPs via the same per-share accumulator their trading fees use. GROSS fee
    ///         weight (`lpShares + totalBuffer`), matching the `feeDenom` the rebalance body
    ///         already passes. `onlyUs` because that is the gate naming CORE explicitly. SAME NAME as
    ///         `Quid.creditSkewPremium` so Core dispatches by ADDRESS through one interface and one call
    ///         site (rule 2: one declaration) — two branch-local calls cost 180 bytes of Core's EIP-170.
    function creditSkewPremium(uint premium6) external onlyUs {
        (, uint usdInc) = SwapLib.feeIncrements(0, premium6, lpShares + totalBuffer);
        USD_FEES += usdInc;
    }

    // ─── ICore — the BTC range's face (see docs/actionable/IRANGE-THE-RANGE-MANAGER-FACE.md) ───
    // The mirror of Quid's block. `Core` asks ONE interface; the per-asset facts live here.

    /// @notice This range's leverage manager. Distinct from the ETH one by design.
    function levManager() external view returns (address) { return LEV_MANAGER; }

    /// @notice Gross levered collateral in the range's NATIVE unit -- SATS here.
    // §FOLD-LEVGROSS — `levGrossNative` now lives ONCE on `Shares`, the base that already
    // declares `LEV_MANAGER`. Both ranges inherit it; neither declares its own copy.


    /// @notice Share base for the shortfall trigger. `totalShares` is NET, so the levered buffer
    ///         is added to match `POOLED` (which is GROSS -- `syncLev` pairs the gross buffer in),
    ///         keeping the comparison gross-to-gross. The ETH side is net-vs-net and correctly adds
    ///         nothing; that asymmetry is real, not drift.
    function sharesForShortfall() external view returns (uint) {
        return totalShares() + totalBuffer;
    }

    /// @notice REAL inventory: pooled sats PLUS the off-pool WBTC the protocol holds (swept
    ///         donations and swap deltas, accrued in `rangeBTC`). BTC has no yield venue, so this
    ///         is the analogue of the ETH side's venue retention.
    function realInventory() external view returns (uint) {
        return CORE.POOLED() + AUX.rangeBTC();
    }

    /// @notice Route the shortfall to the hop -- real-BTC delivery on L1, consuming NO basket
    ///         stables. That is the legitimate delivery rail, which is why BTC acts here and ETH
    ///         deliberately does not (see Quid's counterpart).
    function onShortfall(address sender, uint shortfall) external onlyUs {
        AUX.btcShortfall(sender, shortfall);
    }

    /// @notice 🔴 A DELIBERATE NO-OP. The BTC range settles by LIGHTNING COOPERATIVE CLOSE, not an
    ///         on-chain transfer, so there is nothing for the contract to send here. One of the four
    ///         known-REAL ETH/BTC asymmetries (CLAUDE.md). Do not "implement" this.
    function deliverVolatile(uint, address) external pure returns (uint) { return 0; }

    function totalShares() public view returns (uint) {
        return lpShares;
    }

    /// @notice The LP's UNLEVERED range-BTC depth (`pooled` minus the leverage slice), in 8-dec sats — the E0
    ///         the BTC IL-protect sizes its debt against (`BtcLevManager` reads it at `openBtcLev`). Mirror of
    ///         `Quid.rangeOf`; sizing to this FIXED base (not the buffer's growing collateral) is the
    ///         1/(1−t) over-hedge fix.
    function rangeOf(address lp) external view returns (uint) {
        uint p = autoManaged[lp].pooled;
        uint lev = levPooled[lp];
        return SwapLib.plainNet(p, lev);
    }


    /// @notice (B) The BTC range's current spot price (WAD USD per BTC, the observation ring's basis)
    ///         — recorded as `syncKeyPx` at `openBtcLev`. NO-ARG, exactly like `Quid.rangePrice`, so
    ///         `LevMath.reanchorCompute` calls the one name on whichever range it holds; the Vault is
    ///         BTC-only, so it always reads the BTC pool.
    function rangePrice() external view returns (uint priceWad) {
        (priceWad,) = CORE.poolStats();
    }

    /// @notice (B) The BTC range's ACTUAL sold-volatile fraction (WAD) since `syncKeyPx` — mirror of
    ///         `Quid.soldFractionWad`, over the BTC range bounds/ordering. Shared pure geometry lives in SwapLib.
    function soldFractionWad(uint syncKeyPx) external view returns (uint) {
        (uint priceWad,) = CORE.poolStats();
        return SwapLib.soldFractionWad(syncKeyPx, priceWad, _lo(), _hi());
    }



    // ──── shared masterchef engine — BTC-specialized (isBTC=true) ────────

    /// @dev BTC-LP fee settle. Per-LP pro-rata, with the two legs settled in
    ///      their NATIVE denominations: USD-leg → QUID (or banked to usd_owed
    ///      when payTo==0); BTC-leg → compounded into `pooled` in sats (E145).
    function _settleBtcLp(address lpEth, address payTo) internal {
        // (E145) The BTC leg now COMPOUNDS INTO `pooled` in sats rather than accruing to the
        // owed ledger, so `lpShares` — the SUM of every LP's `pooled` — must absorb it here
        // or the two drift apart. The backing is already in `POOLED` (see settleBtcLp).
        lpShares += BtcLib.settleBtcLp(autoManaged[lpEth],
            lpEth, payTo, address(QUID), feesPerShare, USD_FEES,
            autoManaged[lpEth].pooled + levBuf[lpEth]); // GROSS fee weight = net pooled + buffer
    }


    /// @notice BTC-side rebalance. Shares SwapLib.rebalanceCore with Quid; BTC
    ///         has no Morpho yield to sync and no _calcYield metric, so the
    ///         wrapper only reorders + distributes the repack/JIT fees and writes
    ///         the new range back.
    /// @dev Thin forwarder: the fat body (rebalanceCore + fee distribution + reseat/bounds writeback) moved to
    ///      BtcLib.rebalanceBody (delegatecall — EIP-170). `feeDenom` = lpShares + totalBuffer (GROSS
    ///      fee weight); the reseat-epoch bump and the range writes happen inside that body, and only the
    ///      value-type accumulators + `RANGE_ANCHOR` come back to be applied here. Logic unchanged.
    function _rebalance() internal returns (uint spotPrice,
        uint loPrice, uint upPrice, uint myLiquidity, uint resolvedTwap) {
        BtcLib.RebalOut memory o = BtcLib.rebalanceBody(
            _btcCfg(), _lo(), _hi(), lpShares + totalBuffer);
        // §REBAL-VERB: `+=` on increments, matching Quid._rebalance. Exactly equivalent to the old
        // `= o.feesPerShare` because the library seeded its output from these same two slots.
        feesPerShare += o.feesPerShareInc; USD_FEES += o.usdFeesInc;
        RANGE_ANCHOR = o.spotPrice;   // §ONE-ANCHOR
        return (o.spotPrice, o.loPrice, o.upPrice, o.myLiquidity, o.resolvedTwap);
    }




    // ──── BTC LP path (parallel to ETH) ────
    //
    // A BTC-LP position is created/sized by LOCKING NATIVE SATS IN A CHANNEL —
    // `requestDeposit` and `requestRedeem`/`resize` are all gated to BTCChannels,
    // which calls them on open / close. The BTC RANGE side is purely virtual (modLP mints/burns mockBTC; no
    // real WBTC moves), so the locked sats stay self-custodied in the channel.


    /// @notice Channel lock → BTC-pool LP position. `sats` are already locked in
    ///         the channel, so we just add the virtual liquidity + shares.
    /// @dev    THE PRIMARY RESERVOIR REFILL (the "pump"). The native-BTC reservoir is
    ///         virtual — the LP range channels ARE the buffer — so it refills the ORDINARY
    ///         way: LPs stake channel BTC through this path (minted 1:1 as vBTC), pulled in
    ///         when the pool is scarce because scarcity ⇒ a higher swap-skew ⇒ more fee
    ///         capture for the entering LP. That mechanism already exists; there is NO
    ///         bespoke pump/keeper/RFQ — the reservoir self-refills through ordinary LP
    ///         entry. The on-chain swap skew (see {SwapLib-wellSkew}) only PRICES the
    ///         scarcity so this entry is attractive exactly when the reservoir needs it.
    ///         ⛔ THERE IS NO SWAPPER-FACING REFILL BONUS, and do not add one: the drain premium
    ///         STAYS with LPs (`SwapLib.retainSkewPremium` -> `Core.skewPremium`). THIS path (LP
    ///         entry) is the refill; the remaining unbuilt piece is the ACTIVE flash-serve
    ///         (#100 / J.3), which is a flash-and-repay, NOT a bonus.
    /// @notice §EIP-7540 — THE BTC RANGE'S ASYNCHRONOUS DEPOSIT. This range is async by
    ///         construction -- entry is a channel funding transaction, exit a cooperative close --
    ///         and 7540 names exactly that shape: a deposit whose settlement is not available on
    ///         call. The name states the LIFECYCLE rather than the mechanism, which is what a
    ///         reader of the interface needs.
    /// @dev    ⚠️ THE SIGNATURE IS DELIBERATELY NOT 7540's `(uint256 assets, address controller,
    ///         address owner)`. This entrypoint is `onlyBTCChannels`, not integrator-facing: the
    ///         REQUEST is the on-chain funding transaction and `BTCChannels` is what observes it.
    ///         Taking the standard argument list would advertise a public request path that does
    ///         not exist. The NAME is adopted because it tells the truth about the lifecycle; the
    ///         signature is not, because it would tell a lie about the caller.
    function requestDeposit(address lpEth, uint sats) external nonReentrant onlyBTCChannels {
        // Whole body (checkBacking/TWAP/_rebalance-via-repack + settle + in-range
        // pairing + out-of-range remainder) in BtcLib.requestDeposit (delegatecall):
        // it operates on the Vault's storage via the passed refs and drives the range
        // rebalance through the public repack self-call; the value-type lpShares
        // delta returns for the forwarder.
        lpShares += BtcLib.requestDeposit(
            _btcCfg(), autoManaged[lpEth],
            lpEth, sats, address(QUID), autoManaged[lpEth].pooled + levBuf[lpEth]); // GROSS fee weight
    }

    // ═══════════════════════════ BTC IL-PROTECT: levered range slice ═══════════════════════════
    // Mirror of Quid.syncLev/_levAdd/_levBurn over the BTC range. The BtcLevManager holds the LP's
    // vBTC collateral on external Morpho; its NET-of-debt equity (8-dec sats) is paired here as
    // TOKENLESS range depth so the LP earns RANGE fees on its IL-protected position, backed by rangeBTC.

    /// @notice Re-sync `lp`'s levered BTC range slice to the BtcLevManager's authoritative net-equity.
    ///         Permissionless (like Quid.syncLev): it only moves the tokenless levered slice to match
    ///         the manager (the keeper pokes it via the manager's range). GROW pairs net-equity in-range
    ///         as depth; SHRINK/liquidation burns it. No new channel sats — backed by rangeBTC.
    /// §RANGE-MERGE — THE SAME `addLiq` FACE RANGE ALREADY HAS. The merged lev bodies size the
    ///         net-equity leg through `ICore(address(this)).addLiq(tok, price)`; ETH answered that
    ///         with `Quid.addLiq` and BTC with the LIBRARY function `addLiqChannel`, which is why
    ///         the two `levAddNet` bodies could not be one. Same signature, same return shape --
    ///         only the routing differs, and routing is exactly what belongs in the range.
    function addLiq(uint deltaTok, uint price) public onlyUs returns (uint usdOut, uint outDelta) {
        return BtcLib.addLiqChannel(address(CORE), address(AUX), deltaTok, price);
    }

    function syncLev(address lp) external nonReentrant {   // §SLOP: one name across both ranges
        _syncLev(lp);
    }

    /// @dev §SLOP — the internal half, so the BTC crystallisation points can reconcile BEFORE they
    ///      settle. They cannot call `syncLev` itself: it is `nonReentrant` and so are they.
    /// 🔴 **WHY THEY MUST: THE BTC FEE WEIGHT IS `pooled + levBuf[lpEth]`** (`_settleBtcLp` and
    ///      `requestDeposit` both pass it), so a stale mirror crystallises fees on a stale weight —
    ///      the same defect the ETH side had, and the same reason it is fixed the same way. The
    ///      VENUE is already live (`collateralOf` and `debtOf` are pro-rata slices of the pooled
    ///      position, so a seizure or interest reaches every LP with no per-LP bookkeeping); only
    ///      this range's mirror of it lags, and only because nothing forced it forward before a
    ///      payout.
    ///      ⇒ Reconcile first, settle second. Then a BTC LP's crystallisation is accurate whenever it
    ///      happens, regardless of when that LP last moved — which is the ETH guarantee, on BTC.
    function _syncLev(address lp) internal {
        // Whole body (skip-check + _rebalance-via-repack + fee-settle + FULL-RESYNC:
        // burn all, re-add gross as two legs) in BtcLib.syncLev (delegatecall)
        // over the Vault's storage via the passed refs (incl. levBufferUsd).
        // Returns (added, burned); the forwarder applies the value-type delta.
        BtcLib.LevDelta memory d = BtcLib.syncLev(
            _btcCfg(), autoManaged[lp], levPooled, levBufferUsd, levBuf,
            lp, LEV_MANAGER, address(QUID));
        lpShares = lpShares + d.addedNet - d.burnedNet;         // NET equity leg
        totalBuffer = totalBuffer + d.bufAdded - d.bufBurned;   // GROSS buffer depth (fee weight)
    }

    /// @notice Live θ for the BTC range (yield/(K·σ²)) at the Vault's CURRENT BTC range BOUNDS. Asks Quid
    ///         (the range-θ math home) with the BTC bounds (`_lo()`/`_hi()`, absolute WAD prices — there
    ///         are no ticks) so BtcLib.addLiqChannel can risk-budget the
    ///         BTC range exactly like the ETH range -- without QuidLib linking QuidLib.
    function derivedThetaWad() external view returns (uint) {   // §SLOP: one name across both ranges
        return QuidLib.derivedThetaWad(address(CORE), _lo(), _hi());   // §ISBTC-SPLIT: OUR ring's variance, not the ETH range's
    }

    /// @notice The LVR coefficient for THIS range, WAD. §SLOP: ONE name across both ranges — `Quid`
    ///         has carried `kLvrWad()` since the θ work, and this is the BTC range's instance of it,
    ///         not a new accessor. Do not spell it any other way here.
    /// @dev    Same `(CORE, _lo(), _hi())` inputs and the same `QuidLib` body as θ above — this is
    ///         the `K` already sitting in θ's denominator, surfaced so the leverage overlay's
    ///         no-trade band `∛(g/(C·K))` reads the range's real geometry.
    function kLvrWad() external view returns (uint) {
        return QuidLib.kLvrWad(address(CORE), _lo(), _hi());
    }

    /// @dev Vault's BTC-side immutables gathered for the delegatecalled `BtcLib` bodies
    ///      (`requestDeposit`, `syncLev`, `rebalanceBody`) — mirror of `Quid._ethCfg`.
    function _btcCfg() internal view returns (Types.RangeCfg memory) {
        return Types.RangeCfg({ core: address(CORE), aux: address(AUX), asset: address(AUX.WBTC()) });
    }

    // Per-channel swap-out PROCEEDS settlement moved into BtcLib.settleDelivered
    // (called from resizeBtcLpTail): an on-chain delivery (exactUsd>0) pays the LP
    // exactly the swapper's recorded USD from POOLED_USD + clears pendingSwapOutUsd;
    // a close/withdrawal splice (exactUsd==0) is all native.

    /// @notice Channel close → exit the LP's FULL BTC position. `lpPayoutSats` is the
    ///         BTC paid to the LP in the close tx (read on-chain via _lpFinalBalance):
    ///         the rest of the funding (funded − lpPayout) was delivered to swappers
    ///         and settles as the LP's QUI proceeds.
    /// @notice §EIP-7540 — THE BTC RANGE'S ASYNCHRONOUS REDEEM. Full close:
    ///         the position is retired and the sats are paid out by a Lightning cooperative close,
    ///         which is why this cannot be the synchronous 4626 `redeem` -- the assets are claimable
    ///         only after L1 confirmations. Same signature note as `requestDeposit`.
    function requestRedeem(address lpEth, uint lpPayoutSats)
        external nonReentrant onlyBTCChannels {
        _resize(lpEth, 0, lpPayoutSats, true, 0);   // full close — all native
    }

    /// @notice Splice-OUT (partial close) → shrink the LP's position by `shrinkSats`
    ///         of funding, WITHOUT retiring the channel. `lpPayoutSats` is the BTC paid
    ///         to the LP in the splice tx (read via _lpFinalBalance); the rest of the
    ///         removed funding (shrinkSats − lpPayout) settles as QUI proceeds. Same
    ///         shape as a full close — just a slice.
    /// `exactUsd` > 0 ⇒ on-chain swap-out delivery: pay the LP exactly that USD as
    /// proceeds. `exactUsd` == 0 ⇒ LP-withdrawal splice-out: all native, no proceeds.
    function resize(address lpEth, uint shrinkSats, uint lpPayoutSats, uint exactUsd)
        external nonReentrant onlyBTCChannels {
        _resize(lpEth, shrinkSats, lpPayoutSats, false, exactUsd);
    }

    /// @dev Shared per-channel exit body. `full` = whole-channel close (shrinkSats :=
    ///      funded); else a partial splice-out shrinking by `shrinkSats`. `lpPayoutSats`
    ///      = BTC the LP took in the close/splice tx; `shrinkSats − lpPayout` is the
    ///      DOLLAR (delivered) slice. ONE settlement model for close and splice-out:
    ///      read the LP's BTC payout from the tx, the remainder is delivered.
    function _resize(address lpEth, uint shrinkSats, uint lpPayoutSats, bool full, uint exactUsd)
        internal {
        // MULTI-HOP: LP.pooled includes the LEVERED slice (levPooled), which has NO channel BTC
        // behind it. Channel funding is only the FREE part — the funded/lev prologue, clamp, the
        // _rebalance (via repack self-call) and the settlement/native-lev-burn/finalize tail all live
        // in BtcLib.resize (delegatecall over the Vault's slots). The guards run BEFORE repack
        // (no rebalance when there's nothing to do); the value-type lpShares + accumulators apply here.
        // DELIVERY-SIDE de-lever: when this native swap-out delivery (exactUsd>0, partial) draws on the LP's
        // LEVERED slice past the free channel range (shrinkSats > funded = pooled − levPooled), de-lever the
        // shortfall with the delivery's OWN proceeds — repay the LP's debt, free + un-encumber the matching vBTC
        // (lev→funded) so the clamp below delivers the full shrink. Those proceeds became debt-reduction, so we
        // hand resize the FUNDED remainder and settleDelivered mints QUI for that only (single-pay).
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
        // §SLOP — RECONCILE BEFORE ANY OF THIS READS THE MIRROR. Every quantity below is derived from
        // `LP.pooled` and `levPooled`/`levBuf`: `deleverOnDelivery` sizes the shortfall off
        // `pooled − levPooled`, `BtcLib.resize` settles fees on `pooled + levBuf`, and the clamp
        // decides how much is deliverable. If the venue moved underneath them — a seizure, accrued
        // interest — those are stale, and this is the LP's EXIT, i.e. the last moment it can be
        // corrected for them. The ETH twin does the same at the head of `_withdraw`.
        _syncLev(lpEth);
        uint delevUsd;
        if (!full && exactUsd > 0 && LEV_MANAGER != address(0))
            delevUsd = SwapLib.deleverOnDelivery(address(CORE), address(AUX), LEV_MANAGER,
                autoManaged, levPooled, lpEth, shrinkSats, lpPayoutSats, exactUsd);
        BtcLib.ResizeOut memory o = BtcLib.resize(
            address(CORE), address(QUID), autoManaged, levPooled, levBuf,
            lpEth, shrinkSats, lpPayoutSats, full, exactUsd - delevUsd);
        // (E145) fees compounded into `pooled` during this resize must be added, or `lpShares`
        // drifts below the sum of positions it totals. Net movement, in one write.
        lpShares = lpShares + o.feeCompounded - o.sharesRemoved;   // NET equity
        totalBuffer -= o.bufRemoved;            // GROSS buffer freed on full close
        if (o.cleared) {
            // Only zero the accumulators when NO fee-earning depth remains (net + gross buffer).
            if (lpShares == 0 && totalBuffer == 0) { feesPerShare = 0; USD_FEES = 0; }
        }
    }

    /// @notice Harvest accrued BTC-LP fees WITHOUT closing the channel. The USD-leg
    ///         mints as QUID to the LP; the BTC-leg COMPOUNDS INTO `pooled` in sats
    ///         (E145). The position (`pooled`) is unchanged. `_settleBtcLp`
    ///         self-rebaselines the fee bookmark, so a repeated call yields nothing
    ///         (no double-pay). Mirrors
    ///         the ETH-side collectFees; the LP claims their own (msg.sender) fees.
    function collectFees() external nonReentrant {
        if (autoManaged[msg.sender].pooled == 0) revert NoBtcPosition();
        _rebalance();                     // harvest BTC pool fees into the accumulators
        _syncLev(msg.sender);             // reconcile the levered mirror BEFORE settling on its weight
        _settleBtcLp(msg.sender, msg.sender); // USD-leg → QUID; BTC-leg → compounds into pooled; rebaselines
    }

    /// @notice Permissionless, keeper-crankable fee compounding for a BTC LP — the twin of
    ///         `Quid.compound`, which had no counterpart here.
    /// @dev    ⚠️ **E145 READS LIKE THIS IS UNNECESSARY AND IT IS NOT.** "The BTC leg compounds
    ///         into `LP.pooled` in sats as it is earned" describes the leg's DESTINATION once
    ///         settlement runs, never its TRIGGER.
    ///         `_settleBtcLp` had exactly ONE external caller, `collectFees`, and that is
    ///         `msg.sender`-scoped. So a passive BTC LP who never called it donated its fee
    ///         compounding to the pool for as long as it stayed passive — the identical gap
    ///         `Quid.compound` exists to close, on the side that had no crank.
    ///
    /// @dev    🔑 **`payTo` IS `lp`, NOT `msg.sender`, AND THAT ONE ARGUMENT IS THE WHOLE
    ///         SECURITY DIFFERENCE FROM `collectFees`.** This entrypoint names its subject, so
    ///         passing the caller would let anyone crank a stranger's position and receive the
    ///         USD leg as freshly-minted QUID. The BTC leg cannot be misdirected (it compounds
    ///         into the LP's own `pooled`); the USD leg can, and this is the only thing stopping it.
    ///
    /// @dev    NO SELF-FUNDING TIP, deliberately — do not "complete" this by copying the ETH
    ///         one's. `Quid.compound` pays its cranker by burning a slice of the range as NATIVE
    ///         ETH (`_burnInRange`), which works because that range's token leg IS WETH. This
    ///         range's token leg is SATS: burning in-range yields vBTC, and there is no on-chain
    ///         sats→ETH primitive to pay gas with. Minting QUID for a tip is refused under
    ///         standing rule 8b — it would create a liability to pay a gas bill. The fleet
    ///         already cranks the whole book and reimburses its own gas via §87, so an untipped
    ///         permissionless crank costs nothing that is not already paid for.
    ///         Keeper-safe no-op on an empty position, matching `Quid.compound` rather than
    ///         `collectFees`' revert: a batch crank must skip, not abort the batch.
    function compound(address lp) external nonReentrant {
        if (autoManaged[lp].pooled == 0) return;
        _rebalance();
        _syncLev(lp);
        _settleBtcLp(lp, lp);
    }

    // ─── §OOR-BOOK-DELETED — THIS RANGE HAS NO BOUNDARY-ORDER PATH AT ALL, AND THAT IS THE
    //     HONEST STATE, NOT AN OMISSION. No resting-order state is declared for it anywhere
    //     (`Shares` holds no `positions`/`ID`), so there is nothing here that can be opened and
    //     then never filled. The ETH side's boundary path is `Quid.fillIntent` — a signed intent
    //     with zero resting storage — and the BTC twin of it is NOT a second book: it is an intent
    //     whose fill becomes a `BTCChannels.requestSwapOutOnchain` obligation, which already
    //     carries real delivery AND the hop-independent `refundExpiredSwapOut` recovery.
    //     See §BTC-DELIVERY-IS-BUILT.
    //     ⛔ Do not re-add a book here. The thing to add is the intent.








    /// @notice Repack the BTC pool's in-range LP position.
    function repack() public onlyUs returns (uint spotPrice,
        uint loPrice, uint upPrice, uint myLiquidity, uint resolvedTwap) {
        return _rebalance();
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
        // core = Core (POOLED_*/token1is reads); rangeVault = this Vault (its
        // no-arg `repack()` drives the BTC rebalance); aux = Aux (the
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
    ///         match is done inside `BtcLib.settleDelivered` (CORE.subPendingSwapOut).
    function addPendingSwapOut(uint usd6) external onlyBTCChannels { CORE.addPendingSwapOut(usd6); }
    function subPendingSwapOut(uint usd6) external onlyBTCChannels { CORE.subPendingSwapOut(usd6); }

    /// @notice This range's range, DERIVED from the one stored anchor: `[p·(1−δ), p·(1+δ)]`.
    /// @dev    §ONE-ANCHOR. Every consumer wanted the PAIR (`soldFractionWad`, `derivedThetaWad`,
    ///         `kLvrWad`, the rebalance body), which is why storing two looked natural. But the pair
    ///         is a function of ONE number, and two slots that must move together are two slots that
    ///         can fail to. Deriving is also cheaper: two `mulDiv`s against a cold SLOAD, and a
    ///         repack writes one slot instead of two.
    function rangeBounds() public view returns (uint lo, uint hi) {
        return SwapLib.updateBounds(RANGE_ANCHOR, SwapLib.RANGE_DELTA);
    }

    function _lo() internal view returns (uint) { (uint l,) = rangeBounds(); return l; }
    function _hi() internal view returns (uint) { (, uint h) = rangeBounds(); return h; }

}
