
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RangeLib} from "./imports/RangeLib.sol";
// §A.52: the canonical Aux view (was a file-local variant).
import {Core} from "./Core.sol";
import {Aux} from "./Aux.sol";
import {Basket} from "./Basket.sol";

import {SwapLib} from "./imports/SwapLib.sol";
import {BtcLib} from "./imports/BtcLib.sol";
import {VBtc} from "./VBtc.sol";
import {Types, AlreadyInitialized, BtcChannelsPinned, LevManagerPinned, NotBTCChannels, Unauthorized, WrongRangeManager} from "./imports/Types.sol";
import {Shares} from "./Shares.sol";

// §ETHVENUE-GHOSTS: the `solmate WETH as WETH9` import went with the dead `WETH` immutable — its only user.

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
//  pinned to the range manager — `DeployLib` runs `aux.setEthVenue(address(ETH))`. This header, its
//  `onlyUs` gate and every ETH function it named are gone; `contract Vault is Ownable,
//  ReentrancyGuard, Shares` and nothing else.
//  ⚠️ AN EXTRACTION LEAVES THE HANDLES AND THE COMMENTS BEHIND: grep the old collaborator's TYPE
//  after any move, not just the moved functions (`RANGE` outlived this one by eight days).
//
//  `setup(quid)` pins the basket and does the post-CORE-init `poolStats` read that seeds
//  RANGE_ANCHOR. The owner-gated surface is exactly `setup` and `setLevManager`, both one-shot.
//
//  GATES — TWO, both address-specific, neither widened:
//    • onlyUsBtc       = {Core(CORE), AUX, this} → repack · setBTCChannels · addLiq ·
//                                                   creditSkewPremium · onShortfall
//    • onlyBTCChannels = {btcChannels}           → requestDeposit/requestRedeem/resize ·
//                                                   swap-in/swap-out credit · pendingSwapOut
//  Address-specific gates mean every interface-wired caller (Aux.btc / Core.BTC /
//  BTCChannels.btc / Basket.BTC_VAULT) just points at this one address.
// ════════════════════════════════════════════════════════════════════════

// §ETHVENUE-GHOSTS — the Permit2 slice, the AAVE-v4 GHO spoke and ether.fi venue interfaces, and
// `arbETH`/`arbBTC` are ALL DELETED (the arb record is `Aux`'s §E233-sor block, under its "ETH yield
// venue (AAVE/ether.fi)" banner). Their docblocks outlived them here, reading as live ETH features
// inside a BTC-only contract. A docblock whose subject is gone reads as a feature you have not found.

/// BtcLevManager read surface: the leveraged book's collateral (vBTC, 8-dec sats). The collateral lives
/// on external Euler/Morpho per-LP (the Vault never holds it). The book is counted at NET equity
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
/// Declared once, in imports/Interfaces.sol (it was also BtcLib's `ILevBtc_V`).

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

    // §ETHVENUE-GHOSTS — `error NotSelf()` and `error NotAux()` DELETED: zero references anywhere in this
    // contract, and `git log -S` puts both squarely in the EthVenue extraction commits (a3225031,
    // 2ae0bbba, 8720a35d). The live declarations are `error NotSelf()` in `Aux` and `error NotSelf()`
    // / `error NotAux()` in `Quid`, which do still revert with them. ⚠️ This used to cite
    // `Aux.sol:204` and `Quid.sol:90-91`; BOTH had drifted by ~40 and ~25 lines within days. The
    // durable claim is the ZERO — zero references in THIS file — and the names, not the coordinates. An unused error costs no bytecode, so this is a rule-1 deletion and
    // not a size one — but a declared error IS api surface: it tells a reader this contract can
    // reject them that way, and neither of these can.
    error NoBtcPosition();

    Basket QUID;

    /// @notice BTC-side LP accounting — parallel to the ETH-side trio in Quid.
    /// `autoManaged[user].pooled` slot holds the user's pooled WBTC
    /// (8-dec, type-reused from Types.Deposit). `lpShares` is the sum.
    /// `feesPerShare` accumulates V4 BTC-side trading fees (in WBTC);
    /// `USD_FEES` accumulates V4 USD-side trading fees from the BTC pool.

    /// BTC IL-protect: per-LP LEVERED range slice (8-dec sats) — the mirror of Quid's `levPooled`.
    /// Backed by the BtcLevManager net-equity (not real channel sats), it earns V4 fees but is
    /// UNWIND-ONLY: it never leaves via a channel splice/close (there's no channel BTC behind it), only
    /// via `syncLev` shrinking to match the manager. Excluded from the LP's withdrawable balance.
    /// @notice full-2×: 6-dec USD counterpart of an LP's DEBT-funded BTC buffer leg. Post-fold it folds
    ///         into POOLED_USD (no separate LEV bucket) and is excluded from committed via the live-debt
    ///         subtraction in committedUsd18. Bounded by the LP's own debt (enforced in BtcLib.levAddBufBtc).
    /// @notice NET model (mirror of Quid.levBuf): per-LP debt-funded BTC BUFFER depth (8-dec sats). It is
    ///         fee-earning V4 depth but NOT equity — EXCLUDED from lpShares/pooled, INCLUDED in the GROSS
    ///         fee weight (pooled + levBuf) and the fee denominator (lpShares + totalBuffer).
    /// @notice Sum of every BTC LP's levBuf — the gross buffer total. Fee denom = lpShares + this.

    /// Self-managed BTC boundary positions (out-of-range single-sided orders),
    /// keyed by an ID counter; `positions` maps an owner to its position
    /// ids. These are user-facing and exit via the self-managed pull/close path.

    /// @notice BTC-leg trading fees ACCRUED to each LP, in native sats.
    ///
    /// @dev WHAT THIS IS: an UNFUNDED per-LP accrual, not a segregated balance. Nothing is
    ///      custodied against it and no sats sit idle anywhere. `settleBtcLp` credits each LP its
    ///      pro-rata share of the BTC-leg fee accumulator here (`SwapLib.pendingFor` over
    ///      `LP.pooled + levBuf`); the hop is the party that eventually FUNDS it in real BTC.
    ///      Unlike the USD leg it is never minted as QUID, because the fee is BTC rather than
    ///      basket dollars.
    ///
    /// @dev TWO SETTLEMENT PATHS, and the first is the LIVE PRIMARY ONE:
    ///      1. COMPOUND (default). On a GROW splice the hop funds real sats in and marks up to
    ///         (E145) HISTORICAL: the hop used to fund `feeSettleSats` into a grow-splice and
    ///         clears the counter, and the sats DO compound into `LP.pooled` — `requestDeposit`
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
    // (E145) `btcFeesOwedSats` DELETED. The BTC fee leg now compounds into `LP.pooled` in sats
    // as it is earned (see `BtcLib.settleBtcLp`), so there is no unsettled claim to hold,
    // no hop-funded grow-splice to settle it, and nothing to forfeit at close.

    /// @dev NOT suffixed `_BTC`, deliberately. Quid names its ETH range ticks `LOWER_PRICE`/
    ///      `UPPER_PRICE`; this contract owns the BTC range and names its own the same. Each range
    ///      answers for ITS asset, so `reanchorCompute` calls ONE accessor instead of selecting a
    ///      NAME by flag — which is all that `isBTC` was doing there (hence the try/catch around
    ///      every call: the wrong name simply does not exist on the other side).
    /// §ONE-ANCHOR — was `UPPER_PRICE` + `LOWER_PRICE`, always `updateBounds(anchor, RANGE_DELTA)`
    /// of one another. Two slots for one number; `rangeBounds()` derives the pair on read.


    error ZeroTwap();
    error Dust();          // boundary order too small to mint nonzero liquidity
    error NotOwner();      // pullBtc by a non-owner of the position
    error BadPercent();    // pullBtc percent must be 1..100
    error NotAStable();    // BTC self-managed positions are USD-funded (token != 0, no native)
    error SwapOutShort();

    address public btcChannels;

    /// BTC-side trusted callers: Core (CORE), Aux, self.
    /// @dev §MODFOLD — body in a `private view`, modifier is the JUMP (rule 8c: a modifier inlines
    ///      at every site; the `Error(string)` "403" encoding is the expensive half).
    ///      ⛔ KEEP THE MODIFIER — do not call `_onlyUsBtc()` from each body: a modifier is
    ///      positionally FIRST by construction, a body call can be reordered after a state read.
    function _onlyUsBtc() private view {
        require(msg.sender == address(AUX)
             || msg.sender == address(CORE)
             || msg.sender == address(this), "403");
    }
    modifier onlyUsBtc { _onlyUsBtc(); _; }

    /// BTC-LP deposit/redeem/resize are driven by channel locks, and the swap-in/swap-out credit is
    /// attested by the same contract, so both are gated to the pinned `BTCChannels` — never the
    /// public 4626 surface.
    /// @dev §MODFOLD — WAS **TWO** MODIFIERS, `onlyBtcChannels` and `onlyBTCChannels`, differing
    ///      only in the case of "BTC" (rule 2: one declaration per concept). They were the SAME
    ///      RULE — the older comment said so outright ("same gate, distinct name kept from Aux") —
    ///      and differed in exactly two ways, both resolved in favour of the surviving spelling:
    ///        1. REVERT DATA. The lowercase one raised `Error("403")`, this one raises the custom
    ///           `NotBTCChannels()`. The custom error is what `Aux` raises for the identical gate
    ///           (`Aux.sol`) and what the only tests asserting this gate expect
    ///           (`ReentrancyProbe.t.sol` on `creditSwapIn`/`creditSwapOut`). No test asserted the
    ///           string form on any of the three sites that carried it.
    ///        2. A `btcChannels != address(0)` CLAUSE, which discriminated only when
    ///           `msg.sender == address(0)` AND the pin was unset. `msg.sender` is never the zero
    ///           address in EVM execution — there is no account that can originate a call from it —
    ///           so the clause could not fire on chain, and an unset pin already rejects every real
    ///           caller through the address compare alone. Dropped under rule 1 (no unreachable
    ///           code) and rule 3 (a clamp that only looks like safety).
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
    receive() external payable {}
    fallback() external payable {}

    /// @notice BTC-side init (formerly BtcVault.setup): pin QUID, read the BTC
    ///         pool slot0 (needs CORE.setup done) and seed the BTC ticks. AUX/
    ///         CORE are constructor-set immutables, so only QUID is taken here.
    function setup(address _quid) external {
        if (msg.sender != owner()) revert Unauthorized();   // was front-runnable
        if (address(QUID) != address(0)) revert AlreadyInitialized();
        QUID = Basket(_quid);
        (uint priceWad,) = CORE.poolStats();
        // §ONE-ANCHOR — the seed IS the anchor. ⚠️ THIS NARROWS THE PRE-FIRST-REPACK RANGE: the old
        // line seeded at delta=200 (±2%) while EVERY other site uses RANGE_DELTA=20 (±0.2%), an
        // unexplained 10x the one-anchor form cannot express. The seed is superseded by the first
        // repack, which `checkBacking` triggers on the first operation, so the window is narrow --
        // but it IS a behaviour change, called out here rather than buried.
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

    /// @notice LIVE sum of the BTC leveraged book's net-equity (8-dec sats) — the BACKING term added to
    ///         `rangeBTC` (Core solvency). try/catch so a venue hiccup can't brick the backing read.
    function totalNetEquity() external view returns (uint) {
        if (LEV_MANAGER == address(0)) return 0;
        try ILevEquity(LEV_MANAGER).totalNetEquity() returns (uint ne) { return ne; } catch { return 0; }
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
        // Storage-mutation body in BtcLib.vbtcExposeBody (delegatecall — EIP-170); gate + emit stay here.
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
        // Storage-mutation body in BtcLib.vbtcUnexposeBody (delegatecall — EIP-170); gate + emit stay here.
        VBTC.burnFrom(msg.sender, sats);   // reverts if the manager lacks the sats — checked BEFORE the range moves
        BtcLib.vbtcUnexposeBody(levPooled, lp, sats);
        return true;
    }

    /// @notice BTC-side parallel of Quid.totalShares — a VIEW over lpShares.
    /// Re-arms the BTC shortfall/delivery trigger in Core.
    /// @notice §E5 (BTC mirror of `Quid.creditSkewPremium`) — route the retained scarcity premium
    ///         to BTC-range LPs via the same per-share accumulator their trading fees use. GROSS fee
    ///         weight (`lpShares + totalBuffer`), matching the `feeDenom` the rebalance body
    ///         already passes. `onlyUsBtc` because that is the gate naming CORE explicitly. SAME NAME as
    ///         `Quid.creditSkewPremium` so Core dispatches by ADDRESS through one interface and one call
    ///         site (rule 2: one declaration) — two branch-local calls cost 180 bytes of Core's EIP-170.
    function creditSkewPremium(uint premium6) external onlyUsBtc {
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
    ///         is added to match `POOLED` (which is GROSS -- `levAddBtc` pairs the gross buffer in),
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
    function onShortfall(address sender, uint shortfall) external onlyUsBtc {
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


    /// @notice (B) The BTC range's current spot √P (Q96) — recorded as `syncKeyPx` at `openBtcLev`. `isBTC` is
    ///         accepted for interface-parity with `Quid.rangePrice`; the Vault is BTC-only, so it always reads
    ///         the BTC pool.
    function rangePrice() external view returns (uint priceWad) {
        (priceWad,) = CORE.poolStats();
    }

    /// @notice (B) The BTC range's ACTUAL sold-volatile fraction (WAD) since `syncKeyPx` — mirror of
    ///         `Quid.soldFractionWad`, over the BTC ticks/ordering. Shared pure geometry lives in SwapLib.
    function soldFractionWad(uint syncKeyPx) external view returns (uint) {
        (uint priceWad,) = CORE.poolStats();
        return SwapLib.soldFractionWad(syncKeyPx, priceWad, _lo(), _hi());
    }



    // ──── shared masterchef engine — BTC-specialized (isBTC=true) ────────

    /// @dev BTC-LP fee settle. Per-LP pro-rata, with the two legs settled in
    ///      their NATIVE denominations: USD-leg → QUID (or banked to usd_owed
    ///      when payTo==0); BTC-leg → compounded into `pooled` in sats (E145), formerly
    ///      the hop at channel close.
    function _settleBtcLp(address lpEth, address payTo) internal {
        // (E145) The BTC leg now COMPOUNDS INTO `pooled` in sats rather than accruing to the
        // owed ledger, so `lpShares` — the SUM of every LP's `pooled` — must absorb it here
        // or the two drift apart. The backing is already in `POOLED` (see settleBtcLp).
        lpShares += BtcLib.settleBtcLp(autoManaged[lpEth],
            lpEth, payTo, address(QUID), feesPerShare, USD_FEES,
            autoManaged[lpEth].pooled + levBuf[lpEth]); // GROSS fee weight = net pooled + buffer
    }

    // (_distributeV4Fees folded into BtcLib.rebalanceBody — its only caller was _rebalance.)

    /// @notice BTC-side rebalance. Shares SwapLib.rebalanceCore with Quid; BTC
    ///         has no Morpho yield to sync and no _calcYield metric, so the
    ///         wrapper only reorders + distributes the repack/JIT fees and writes
    ///         the new range back.
    /// @dev Thin forwarder: the fat body (rebalanceCore + fee distribution + reseat/tick writeback) moved to
    ///      BtcLib.rebalanceBody (delegatecall — EIP-170). `feeDenom` = lpShares + totalBuffer (GROSS
    ///      fee weight); the value-type accumulators + ticks + reseat epoch are written back here. Logic unchanged.
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
    // both register/close are gated to BTCChannels, which calls them on open /
    // close. The V4 BTC side is purely virtual (modLP mints/burns mockBTC; no
    // real WBTC moves), so the locked sats stay self-custodied in the channel.

    // Renamed from BtcLpFeesOwed: the BTC-leg fee residual at a full exit is no longer
    // OWED to an external settler — it is FORGONE to the pool (dust; see _resize). Kept as
    // an observability signal so a NON-dust forgone amount (⇒ the fleet missed a pre-exit flush)
    // is alertable. The lp_fees.rs settler + the on-chain lpFeePaid dedup are retired.

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
    ///         CORRECTED 2026-07-26: the trailing clause used to say "the transient swap-in refill
    ///         bonus is the fast top-up BETWEEN LP-stake arrivals". That bonus was REMOVED
    ///         (`payRefillBonus`, 2026-07-22) precisely so the drain premium STAYS with LPs
    ///         (`retainSkewPremium` -> `Core.skewPremium*`), so there is no swapper-facing bonus to
    ///         top up with. THIS path (LP entry) is the refill; the remaining unbuilt piece is the
    ///         ACTIVE flash-serve (#100 / J.3), which is a flash-and-repay, NOT a bonus.
    /// @notice §EIP-7540 — THE BTC RANGE'S ASYNCHRONOUS DEPOSIT. Was `registerBtcLp`, which named the
    ///         MECHANISM (an LP registering with the channel set) rather than what it IS: a deposit
    ///         whose settlement is not available on call. The BTC range has always been async --
    ///         entry is a channel funding transaction, exit a cooperative close -- and 7540 exists
    ///         for exactly that shape. The old name hid the lifecycle from anyone reading the
    ///         interface; this one states it.
    /// @dev    ⚠️ THE SIGNATURE IS DELIBERATELY NOT 7540's `(uint256 assets, address controller,
    ///         address owner)`. This entrypoint is `onlyBTCChannels`, not integrator-facing: the
    ///         REQUEST is the on-chain funding transaction and `BTCChannels` is what observes it.
    ///         Taking the standard argument list would advertise a public request path that does
    ///         not exist. The NAME is adopted because it tells the truth about the lifecycle; the
    ///         signature is not, because it would tell a lie about the caller.
    function requestDeposit(address lpEth, uint sats) external nonReentrant onlyBTCChannels {
        // Whole body (checkBacking/TWAP/_rebalance-via-repack + settle + in-range
        // pairing + out-of-range remainder) in BtcLib.requestDeposit (delegatecall):
        // it operates on the Vault's storage via the passed refs and drives the tick
        // rebalance through the public repack self-call; the value-type lpShares
        // delta returns for the forwarder.
        lpShares += BtcLib.requestDeposit(
            _btcCfg(), autoManaged[lpEth],
            lpEth, sats, address(QUID), autoManaged[lpEth].pooled + levBuf[lpEth]); // GROSS fee weight
    }

    // ═══════════════════════════ BTC IL-PROTECT: levered range slice ═══════════════════════════
    // Mirror of Quid.syncLev/_levAdd/_levBurn over the BTC range. The BtcLevManager holds the LP's
    // vBTC collateral on external Euler/Morpho; its NET-of-debt equity (8-dec sats) is paired here as
    // TOKENLESS range depth so the LP earns V4 fees on its IL-protected position, backed by rangeBTC.

    /// @notice Re-sync `lp`'s levered BTC range slice to the BtcLevManager's authoritative net-equity.
    ///         Permissionless (like Quid.syncLev): it only moves the tokenless levered slice to match
    ///         the manager (the keeper pokes it via the manager's range). GROW pairs net-equity in-range
    ///         as depth; SHRINK/liquidation burns it. No new channel sats — backed by rangeBTC.
    /// §RANGE-MERGE — THE SAME `addLiq` FACE RANGE ALREADY HAS. The merged lev bodies size the
    ///         net-equity leg through `ICore(address(this)).addLiq(tok, price)`; ETH answered that
    ///         with `Quid.addLiq` and BTC with the LIBRARY function `addLiqChannel`, which is why
    ///         the two `levAddNet` bodies could not be one. Same signature, same return shape --
    ///         only the routing differs, and routing is exactly what belongs in the range.
    function addLiq(uint deltaTok, uint price) public onlyUsBtc returns (uint usdOut, uint outDelta) {
        return BtcLib.addLiqChannel(address(CORE), address(AUX), deltaTok, price);
    }

    function syncLev(address lp) external nonReentrant {   // §SLOP: one name across both ranges
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

    /// @notice Live θ for the BTC range (yield/(K·σ²)) at the Vault's CURRENT BTC range ticks. Asks Quid
    ///         (the range-θ math home) with the BTC ticks so BtcLib.addLiqChannel can risk-budget the
    ///         BTC range exactly like the ETH range -- without QuidLib linking QuidLib.
    function derivedThetaWad() external view returns (uint) {   // §SLOP: one name across both ranges
        return QuidLib.derivedThetaWad(address(CORE), _lo(), _hi());   // §ISBTC-SPLIT: OUR ring's variance, not the ETH range's
    }

    /// @notice The LVR coefficient for THIS range, WAD. §SLOP: one name across both ranges — `Quid`
    ///         has carried `kLvrWad()` since the θ work, and this is the BTC range's copy of it, not
    ///         a new accessor. ⚠️ I first added this to BOTH ranges as `lvrKWad()`, which duplicated
    ///         `Quid.kLvrWad()` under a transposed name; only the BTC half was ever missing.
    /// @dev    Same `(CORE, _lo(), _hi())` inputs and the same `QuidLib` body as θ above — this is
    ///         the `K` already sitting in θ's denominator, surfaced so the leverage overlay's
    ///         no-trade band `∛(g/(C·K))` reads the range's real geometry.
    function kLvrWad() external view returns (uint) {
        return QuidLib.kLvrWad(address(CORE), _lo(), _hi());
    }

    /// @dev Vault's BTC-side immutables gathered for the delegatecalled QuidLib
    ///      levered-range bodies (mirror of _ethCfg for the BTC cluster).
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
    /// @notice §EIP-7540 — THE BTC RANGE'S ASYNCHRONOUS REDEEM. Was `unregisterBtcLp`. Full close:
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
    ///         mints as QUID to the LP; the BTC-leg COMPOUNDS INTO `pooled` in sats (E145)
    ///         (paid natively by the hop at close, as always). The position
    ///         (`pooled`) is unchanged. `_settleBtcLp` self-rebaselines the fee
    ///         bookmark, so a repeated call yields nothing (no double-pay). Mirrors
    ///         the ETH-side collectFees; the LP claims their own (msg.sender) fees.
    function collectBtcFees() external nonReentrant {
        if (autoManaged[msg.sender].pooled == 0) revert NoBtcPosition();
        _rebalance();                     // harvest BTC pool fees into the accumulators
        _settleBtcLp(msg.sender, msg.sender); // USD-leg → QUID; BTC-leg → compounds into pooled; rebaselines
    }

    // ─── Self-managed BTC boundary orders (single-sided, USD-funded) ──────────
    // The BTC-pool twin of Quid's ETH `outOfRange`/`pull`: a user places a USD-
    // funded single-sided limit order on the USD/WBTC curve that fills as price
    // crosses, exiting via `pullBtc`. Geometry + sizing come from the SAME shared
    // SwapLib LP-engine helpers the ETH path uses (only the pool/ordering differ). USD-
    // funded ONLY — the BTC side is channel/sats-custodied, so there is no native
    // user-deposit leg (the ETH `token==0` branch has no BTC analogue); `token`
    // must be a basket stable, deposited via AUX exactly like the ETH USD branch.

    /// @notice Place a USD-funded single-sided boundary order on the BTC curve.
    /// @param amount  Stable amount to provide.
    /// @param token   Basket stable (must be nonzero — USD-funded only).
    /// @param distance Price offset from current (sign = side). §DE-TICK: a PRICE offset, not a
    ///        tick count -- there is no tick grid to quantise onto.
    /// @param range   Order width, as a price span.
    /// @return next   The new position id.
    function outOfRangeBtc(uint amount, address token, int distance, uint range)
        external nonReentrant returns (uint next) {
        // _rebalance stays in the Vault; the rest is BtcLib.outOfRangeBtc
        // (delegatecall) which writes selfManaged/positions via the passed
        // refs and returns the new id (ID is value-type). A revert rolls back
        // the _rebalance, so validating inside the lib is behavior-identical.
        (uint spotPrice, uint curLo, uint curUp,,) = _rebalance();
        next = BtcLib.outOfRangeBtc(_btcCfg(), selfManaged, positions,
            BtcLib.OorArgs({ amount: amount, token: token, distance: distance,
                range: range, owner: msg.sender, spotPrice: spotPrice, curLo: curLo,
                curUp: curUp, idBtc: ID }));
        ID = next;
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
        // Body in BtcLib.pullBtc (delegatecall); storage refs mutate in place.
        RangeLib.pull(address(CORE), oorBook, selfManaged, positions,
            id, percent, token, msg.sender);
    }

    /// @notice §E258 — this range executes NO resting orders, and the zero is the finding.
    /// @dev    Same asymmetry as `deliverVolatile` above, and it is the one asymmetry that decides
    ///         this: a BTC boundary order is **USD-funded only** (`outOfRangeBtc` reverts
    ///         `NotAStable` otherwise), so EVERY order on this range is a bid that fills INTO BTC —
    ///         and this range has no on-chain BTC delivery, because settlement is a Lightning
    ///         cooperative close. `Core._handleDelta` therefore hands the filled leg to a
    ///         `deliverVolatile` that returns 0, i.e. the fill would BURN it. The docblock on
    ///         `pullBtc` already records that loss for the OWNER-INITIATED close; auto-filling here
    ///         would convert a loss the owner currently chooses into one the protocol inflicts on
    ///         its own schedule. ⇒ **BTC orders are deliberately not indexed and never swept**, and
    ///         this stays zero until native delivery attributes the off-chain fill channel.
    function sweepOor(uint, uint) external pure returns (uint) { return 0; }


    /// @notice Repack the BTC pool's in-range LP position.
    function repack() public onlyUsBtc returns (uint spotPrice,
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
