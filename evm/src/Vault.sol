
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vogue} from "./Vogue.sol";
import {BandLib} from "./imports/BandLib.sol";
// §A.52: the canonical Aux view (was a file-local variant).
import {Core} from "./Core.sol";
import {Aux} from "./Aux.sol";
import {Basket} from "./Basket.sol";

import {SwapLib} from "./imports/SwapLib.sol";
import {BtcVaultLib} from "./imports/BtcVaultLib.sol";
import {VBtc} from "./VBtc.sol";
import {Types} from "./imports/Types.sol";
import {BandState} from "./Shares.sol";

import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {ILevEquity} from "./imports/Interfaces.sol";

// ════════════════════════════════════════════════════════════════════════
//  Vault — the unified ETH-venue custody + BTC LP/hop side, merged from the
//  formerly-separate EthVenue and BtcVault (5→4 deployable contracts). The
//  two had disjoint state, disjoint function names, and only differed in
//  their "V4" handle (EthVenue→Vogue, BtcVault→Core); here Vogue stays
//  `V4` and Core is `CORE` (the slot EthVenue already carried). Both
//  init paths are preserved: the EthVenue constructor pins the ETH-venue
//  immutables + approvals; `setup(quid)` does BtcVault's post-CORE-init
//  poolStats read + BTC tick seed. Ownership is renounced at deploy, once both
//  lev-manager slots are pinned — they are the only owner-gated functions here.
//
//  GATES stay SPLIT, byte-for-byte with the originals — no widening:
//    • onlyUs    = {Vogue(V4), AUX, this}      → ETH-side venue ops (supply/withdraw/deliverable)
//      §E233-sor: this line named `arbETH`, which DOES NOT EXIST -- `Aux` states its forwarder was
//      REMOVED along with its only callers (Core.refillETH, Vogue._withdraw). The gate is real; the
//      consumer it cited is not, and a gate documented by a dead caller reads as dead surface.
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

/// ether.fi venue (ETH-side, depositor-chosen). Stake WETH → weETH (restaking
/// yield); value weETH in ETH via getEETHByWeETH. ⚠️ THERE IS NO DETERMINISTIC EXIT: the instant-redeem
/// (0.3%) this line used to name was removed 2026-08-05/06 (zero measured capacity). The exit is the
/// two-rung offramp ladder — v3 pool sale, else a multi-day wait NFT (`VaultLib.offrampBody`).

/// Aux read surface the Vault needs: WBTC handle (for the shared arbBody
/// signature); vault-health state stays Aux-owned.

/// §SLOP — THIS PARAGRAPH WAS ETH-SIDE TEXT LEFT IN THE BTC CONTRACT by the EthVenue fusion. It said
/// the book's collateral is "ETH, 1e18", that "the weETH lives on external Euler/Morpho", and that net
/// equity counts "in `vogueETH`". None of that is this contract: `vogueETH` is VOGUE's accessor, and
/// line 70 below states what actually happens here — `syncLev` pairs the BTC book as tokenless depth
/// INTO `POOLED`. Corrected rather than deleted, because the SHAPE it describes is right and is what
/// makes the two bands mirror images.
/// BtcLevManager read surface: the leveraged book's collateral (vBTC, 8-dec sats). The collateral lives
/// on external Euler/Morpho per-LP (the Vault never holds it). The book is counted at NET equity
/// (gross − debt) in both `POOLED` and `lpShares`; the debt-funded buffer (gross − net) is EXCLUDED from
/// equity and tracked separately as fee-earning band depth (`Vogue.levBuf`/`Vault.levBuf` + `totalBuffer`),
/// so it earns fees on the gross weight but never inflates the LP's redeemable claim. The buffer's debt is
/// excluded from committed via `committedUsd18`'s live-debt subtraction (no separate POOLED_USD_*_LEV bucket),
/// so a venue liquidation un-pairs the buffer (`levBurnAll`) without stranding basket `POOLED_USD`.

/// BTC IL-protect: the BtcLevManager's per-LP net-of-debt equity IS protocol BTC backing (8-dec
/// sats), so `syncLev` pairs it as tokenless band depth INTO `POOLED` (LP.pooled) — that is where
/// the net-equity is counted for solvency. `vogueBTC` is WBTC-only (swept donations + swap deltas) and is
/// NEVER credited the net-equity, so `POOLED + vogueBTC` (Core shortfall read) is single-counted. Net
/// (not gross): a venue liquidation can't strand POOLED_USD. Mirrors the ETH `ILevEquity` over the BTC band.
/// Declared once, in imports/Interfaces.sol (it was also BtcVaultLib's `ILevBtc_V`).

    // §E252 — the THIRTEEN shared band-state declarations moved to `BandState` (Shares.sol).
    // They were byte-identical in both managers; the merge aligns STORAGE LAYOUT, which is the
    // precondition for one implementation with two instances. No bytecode changes: state emits none.
contract Vault is Ownable, ReentrancyGuard, BandState {

    // ─── ETH-venue immutables (formerly EthVenue) ───────────────────────
    Vogue     internal immutable VOGUE;    // the ETH LP contract
    /// @dev PUBLIC, and the getter earns its ~50 bytes. While this was `internal` NOTHING outside
    ///      could reach THIS band's engine -- `IBandManager` had no `core()` either -- so a test
    ///      wanting to compare the two bands had no handle for the second one and read the ETH core
    ///      TWICE. That is how `PooledUsdRepackMatrix`'s cross-band isolation assertions became
    ///      comparisons of a value to itself: vacuously true, in the very file whose docblock warns
    ///      that an unseeded band makes isolation assertions vacuous. The seeding was fixed; the
    ///      READS still both pointed here. An instance you cannot address is an instance you cannot
    ///      check is separate.
    Core public immutable CORE;  // the PM (was BtcVault's "VOGUE")
    Aux       internal immutable AUX;
    WETH9     public    immutable WETH;









    /// @notice The IL-protect orchestrator. Its leveraged book's LIVE net-equity counts in `POOLED`
    ///         (§SLOP: said `vogueETH`, which is Vogue's ETH-side accessor, not this contract's).
    ///         Pinned once post-deploy (LevManager needs Aux/weETH first). 0 = leverage disabled.

    // §SLOP — `NotVogueCore` DELETED: zero reverts. `git log -S` traces it to `a3225031`
    // ("Extract ETH-venue custody out of Vault into EthVenue") and `8720a35d` ("EthVenue IS Vogue"),
    // i.e. it gated a split that was subsequently folded back -- the gate went, the error stayed.
    error NotSelf();
    error Unauthorized();
    error LevManagerPinned();
    error WrongBandManager();
    error NotAux();
    error NoBtcPosition();

    // ─── BTC-side state (formerly BtcVault) ─────────────────────────────
    Basket QUID;

    /// @notice BTC-side LP accounting — parallel to the ETH-side trio in Vogue.
    /// `autoManaged[user].pooled` slot holds the user's pooled WBTC
    /// (8-dec, type-reused from Types.Deposit). `lpShares` is the sum.
    /// `feesPerShare` accumulates V4 BTC-side trading fees (in WBTC);
    /// `USD_FEES` accumulates V4 USD-side trading fees from the BTC pool.

    /// BTC IL-protect: per-LP LEVERED band slice (8-dec sats) — the mirror of Vogue's `levPooled`.
    /// Backed by the BtcLevManager net-equity (not real channel sats), it earns V4 fees but is
    /// UNWIND-ONLY: it never leaves via a channel splice/close (there's no channel BTC behind it), only
    /// via `syncLev` shrinking to match the manager. Excluded from the LP's withdrawable balance.
    /// @notice full-2×: 6-dec USD counterpart of an LP's DEBT-funded BTC buffer leg. Post-fold it folds
    ///         into POOLED_USD (no separate LEV bucket) and is excluded from committed via the live-debt
    ///         subtraction in committedUsd18. Bounded by the LP's own debt (enforced in BtcVaultLib.levAddBufBtc).
    /// @notice NET model (mirror of Vogue.levBuf): per-LP debt-funded BTC BUFFER depth (8-dec sats). It is
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
    // as it is earned (see `BtcVaultLib.settleBtcLp`), so there is no unsettled claim to hold,
    // no hop-funded grow-splice to settle it, and nothing to forfeit at close.

    /// @dev NOT suffixed `_BTC`, deliberately. Vogue names its ETH band ticks `LOWER_PRICE`/
    ///      `UPPER_PRICE`; this contract owns the BTC band and names its own the same. Each hook
    ///      answers for ITS asset, so `reanchorCompute` calls ONE accessor instead of selecting a
    ///      NAME by flag — which is all that `isBTC` was doing there (hence the try/catch around
    ///      every call: the wrong name simply does not exist on the other side).
    /// §ONE-ANCHOR — was `UPPER_PRICE` + `LOWER_PRICE`, always `updateBounds(anchor, BAND_DELTA)`
    /// of one another. Two slots for one number; `bandBounds()` derives the pair on read.


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
        if (msg.sender != address(VOGUE)
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
    constructor(address _vogue, address _core, address _aux, address _weth)
        Ownable(msg.sender) {
        VOGUE = Vogue(payable(_vogue));
        CORE = Core(_core);
        AUX = Aux(payable(_aux));
        VBTC = new VBtc(address(this), address(Aux(payable(_aux)).WBTC()));
        WETH = WETH9(payable(_weth));

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
        // §ONE-ANCHOR — the seed IS the anchor. ⚠️ THIS NARROWS THE PRE-FIRST-REPACK BAND: the old
        // line seeded at delta=200 (±2%) while EVERY other site uses BAND_DELTA=20 (±0.2%), an
        // unexplained 10x the one-anchor form cannot express. The seed is superseded by the first
        // repack, which `checkBacking` triggers on the first operation, so the window is narrow --
        // but it IS a behaviour change, called out here rather than buried.
        BAND_ANCHOR = priceWad;
    }

    // ════════════════════════════════════════════════════════════════
    //                    ETH yield-venue side (was EthVenue)
    // ════════════════════════════════════════════════════════════════

    /// @notice Pin the BtcLevManager (one-shot) so `vogueBTC` counts the BTC leveraged book's
    ///         net-equity and `syncLev` can read the per-LP target. Distinct from the ETH LEV_MANAGER.
    /// @dev §LEV-FOLD-2 — THE IDENTITY CHECK THAT REPLACES THE SUFFIXED SELECTORS. Until this
    ///      commit the only thing stopping a BTC lev manager being pinned to the ETH band (or the
    ///      reverse) was that the two managers exposed DIFFERENT selectors, so a wrong-band read
    ///      reverted. That is a clamp: it fires per call, forever, and only when the caller reaches
    ///      for the suffixed name. Folding the two interfaces into one removes it -- so the bad
    ///      state is made UNCONSTRUCTIBLE here instead, once, at the pin. A manager carries its own
    ///      band asset in `ORACLE_KEY` (immutable, set at construction: WETH for the ETH book,
    ///      WBTC for the BTC one), so the wrong one simply cannot be installed.
    ///      Standing rule 17: the root fix is the one that makes the previous guard DELETABLE.
    function setLevManager(address m) external onlyOwner {
        if (LEV_MANAGER != address(0)) revert LevManagerPinned();
        if (ILevEquity(m).ORACLE_KEY() != address(AUX.WBTC())) revert WrongBandManager();
        LEV_MANAGER = m;
    }

    /// @notice LIVE sum of the BTC leveraged book's net-equity (8-dec sats) — the BACKING term added to
    ///         `vogueBTC` (Core solvency). try/catch so a venue hiccup can't brick the backing read.
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
    // stays HERE is the BAND ACCOUNTING (`autoManaged`, `levPooled`) plus the expose/unexpose gate.
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
    ///   `sats` of the LP's FREE channel band BTC — already POOLED depth via `requestDeposit` — as the
    ///   levered slice, and mint the matching vBTC face to the LevManager for venue collateral. NO new BTC
    ///   enters the pool: the channel BTC was already banked, so `LP.pooled` is UNCHANGED (no double-count) —
    ///   only `levPooled` grows (funded→lev, withdrawal-excluded). vBTC is thus only ever "minted" against
    ///   real channel BTC (here), never conjured. Inverse of
    ///   `unexposeBtcFromLev`. Gated to the pinned LevManager (the sole leverage authority).
    function exposeBtcToLev(address lp, uint sats) external returns (bool) {
        if (msg.sender != LEV_MANAGER) revert NotLevManagerBtc();
        // Storage-mutation body in BtcVaultLib.vbtcExposeBody (delegatecall — EIP-170); gate + emit stay here.
        BtcVaultLib.vbtcExposeBody(autoManaged, levPooled, lp, sats);
        VBTC.mintTo(msg.sender, sats);   // the Transfer event is the TOKEN's to emit, not ours
        return true;
    }

    /// @notice Close-side inverse: burn the `sats` vBTC the manager withdrew from the venue and convert the
    ///   LP's levered slice back to FREE channel band depth (lev→funded). `LP.pooled` is UNCHANGED, so the
    ///   LP's band position simply un-freezes — grown by leverage gain / shrunk by loss (the LP bears its
    ///   own leverage P&L), since a preceding `syncLev` marked `levPooled` to the live net-equity == `sats`.
    ///   The LP never receives loose vBTC (that would double-claim the same channel BTC).
    function unexposeBtcFromLev(address lp, uint sats) external returns (bool) {
        if (msg.sender != LEV_MANAGER) revert NotLevManagerBtc();
        // Storage-mutation body in BtcVaultLib.vbtcUnexposeBody (delegatecall — EIP-170); gate + emit stay here.
        VBTC.burnFrom(msg.sender, sats);   // reverts if the manager lacks the sats — checked BEFORE the band moves
        BtcVaultLib.vbtcUnexposeBody(levPooled, lp, sats);
        return true;
    }

    /// @notice BTC-side parallel of Vogue.totalShares — a VIEW over lpShares.
    /// Re-arms the BTC shortfall/delivery trigger in Core.
    /// @notice §E5 (BTC mirror of `Vogue.creditSkewPremium`) — route the retained scarcity premium
    ///         to BTC-band LPs via the same per-share accumulator their trading fees use. GROSS fee
    ///         weight (`lpShares + totalBuffer`), matching the `feeDenom` the rebalance body
    ///         already passes. `onlyUsBtc` because that is the gate naming CORE explicitly. SAME NAME as
    ///         `Vogue.creditSkewPremium` so Core dispatches by ADDRESS through one interface and one call
    ///         site (rule 2: one declaration) — two branch-local calls cost 180 bytes of Core's EIP-170.
    function creditSkewPremium(uint premium6) external onlyUsBtc {
        (, uint usdInc) = SwapLib.feeIncrements(0, premium6, lpShares + totalBuffer);
        USD_FEES += usdInc;
    }

    // ─── IBand — the BTC band's face (see docs/actionable/IBAND-THE-BAND-MANAGER-FACE.md) ───
    // The mirror of Vogue's block. `Core` asks ONE interface; the per-asset facts live here.

    /// @notice This band's leverage manager. Distinct from the ETH one by design.
    function levManager() external view returns (address) { return LEV_MANAGER; }

    /// @notice Gross levered collateral in the band's NATIVE unit -- SATS here.
    function levGrossNative() external view returns (uint) {
        if (LEV_MANAGER == address(0)) return 0;
        try ILevEquity(LEV_MANAGER).totalGrossCollateral() returns (uint g) { return g; }
        catch { return 0; }
    }

    /// @notice Share base for the shortfall trigger. `totalShares` is NET, so the levered buffer
    ///         is added to match `POOLED` (which is GROSS -- `levAddBtc` pairs the gross buffer in),
    ///         keeping the comparison gross-to-gross. The ETH side is net-vs-net and correctly adds
    ///         nothing; that asymmetry is real, not drift.
    function sharesForShortfall() external view returns (uint) {
        return totalShares() + totalBuffer;
    }

    /// @notice REAL inventory: pooled sats PLUS the off-pool WBTC the protocol holds (swept
    ///         donations and swap deltas, accrued in `vogueBTC`). BTC has no yield venue, so this
    ///         is the analogue of the ETH side's venue retention.
    function realInventory() external view returns (uint) {
        return CORE.POOLED() + AUX.vogueBTC();
    }

    /// @notice Route the shortfall to the hop -- real-BTC delivery on L1, consuming NO basket
    ///         stables. That is the legitimate delivery rail, which is why BTC acts here and ETH
    ///         deliberately does not (see Vogue's counterpart).
    function onShortfall(address sender, uint shortfall) external onlyUsBtc {
        AUX.btcShortfall(sender, shortfall);
    }

    /// @notice 🔴 A DELIBERATE NO-OP. The BTC band settles by LIGHTNING COOPERATIVE CLOSE, not an
    ///         on-chain transfer, so there is nothing for the contract to send here. One of the four
    ///         known-REAL ETH/BTC asymmetries (CLAUDE.md). Do not "implement" this.
    function deliverVolatile(uint, address) external pure returns (uint) { return 0; }

    function totalShares() public view returns (uint) {
        return lpShares;
    }

    /// @notice The LP's UNLEVERED band-BTC depth (`pooled` minus the leverage slice), in 8-dec sats — the E0
    ///         the BTC IL-protect sizes its debt against (`BtcLevManager` reads it at `openBtcLev`). Mirror of
    ///         `Vogue.bandOf`; sizing to this FIXED base (not the buffer's growing collateral) is the
    ///         1/(1−t) over-hedge fix.
    function bandOf(address lp) external view returns (uint) {
        uint p = autoManaged[lp].pooled;
        uint lev = levPooled[lp];
        return SwapLib.plainNet(p, lev);
    }

    // §DE-TICK — `token1isVol()` DELETED. It forwarded Core's v4 leg ordering, which no longer
    // exists: `Delta`'s fields are named for what they hold and the OOR guard is symmetric.

    /// @notice (B) The BTC band's current spot √P (Q96) — recorded as `entryPrice` at `openBtcLev`. `isBTC` is
    ///         accepted for interface-parity with `Vogue.bandPrice`; the Vault is BTC-only, so it always reads
    ///         the BTC pool.
    function bandPrice() external view returns (uint priceWad) {
        (priceWad,) = CORE.poolStats();
    }

    /// @notice (B) The BTC band's ACTUAL sold-volatile fraction (WAD) since `entryPrice` — mirror of
    ///         `Vogue.soldFractionWad`, over the BTC ticks/ordering. Shared pure geometry lives in SwapLib.
    function soldFractionWad(uint entryPrice) external view returns (uint) {
        (uint priceWad,) = CORE.poolStats();
        return SwapLib.soldFractionWad(entryPrice, priceWad, _lo(), _hi());
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
        lpShares += BtcVaultLib.settleBtcLp(autoManaged[lpEth],
            lpEth, payTo, address(QUID), feesPerShare, USD_FEES,
            autoManaged[lpEth].pooled + levBuf[lpEth]); // GROSS fee weight = net pooled + buffer
    }

    // (_distributeV4Fees folded into BtcVaultLib.rebalanceBody — its only caller was _rebalance.)

    /// @notice BTC-side rebalance. Shares SwapLib.rebalanceCore with Vogue; BTC
    ///         has no Morpho yield to sync and no _calcYield metric, so the
    ///         wrapper only reorders + distributes the repack/JIT fees and writes
    ///         the new range back.
    /// @dev Thin forwarder: the fat body (rebalanceCore + fee distribution + reseat/tick writeback) moved to
    ///      BtcVaultLib.rebalanceBody (delegatecall — EIP-170). `feeDenom` = lpShares + totalBuffer (GROSS
    ///      fee weight); the value-type accumulators + ticks + reseat epoch are written back here. Logic unchanged.
    function _rebalance() internal returns (uint spotPrice,
        uint loPrice, uint upPrice, uint myLiquidity, uint resolvedTwap) {
        BtcVaultLib.RebalOut memory o = BtcVaultLib.rebalanceBody(
            _btcCfg(), _lo(), _hi(),
            feesPerShare, USD_FEES, lpShares + totalBuffer);
        feesPerShare = o.feesPerShare; USD_FEES = o.usdFees;   // §BAND-MERGE: RebalOut's fields lost the redundant BTC suffix
        BAND_ANCHOR = o.spotPrice;   // §ONE-ANCHOR
        return (o.spotPrice, o.loPrice, o.upPrice, o.myLiquidity, o.resolvedTwap);
    }

    // (S4) public paddedSqrtPrice removed — dead (Core uses VOGUE.paddedSqrtPrice;
    // _rebalance here calls SwapLib.paddedSqrtPrice directly).

    /// §DE-TICK — forwards to the price-space band-bound helper. Was `_updateTicks`.
    function _updateBounds(uint price, uint delta)
        internal pure returns (uint lower, uint upper) {
        return SwapLib.updateBounds(price, delta);
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
    /// @notice §EIP-7540 — THE BTC BAND'S ASYNCHRONOUS DEPOSIT. Was `registerBtcLp`, which named the
    ///         MECHANISM (an LP registering with the channel set) rather than what it IS: a deposit
    ///         whose settlement is not available on call. The BTC band has always been async --
    ///         entry is a channel funding transaction, exit a cooperative close -- and 7540 exists
    ///         for exactly that shape. The old name hid the lifecycle from anyone reading the
    ///         interface; this one states it.
    /// @dev    ⚠️ THE SIGNATURE IS DELIBERATELY NOT 7540's `(uint256 assets, address controller,
    ///         address owner)`. This entrypoint is `onlyBtcChannels`, not integrator-facing: the
    ///         REQUEST is the on-chain funding transaction and `BTCChannels` is what observes it.
    ///         Taking the standard argument list would advertise a public request path that does
    ///         not exist. The NAME is adopted because it tells the truth about the lifecycle; the
    ///         signature is not, because it would tell a lie about the caller.
    function requestDeposit(address lpEth, uint sats) external nonReentrant onlyBtcChannels {
        // Whole body (checkBacking/TWAP/_rebalance-via-repack + settle + in-range
        // pairing + out-of-range remainder) in BtcVaultLib.requestDeposit (delegatecall):
        // it operates on the Vault's storage via the passed refs and drives the tick
        // rebalance through the public repack self-call; the value-type lpShares
        // delta returns for the forwarder.
        lpShares += BtcVaultLib.requestDeposit(
            _btcCfg(), autoManaged[lpEth],
            lpEth, sats, address(QUID), autoManaged[lpEth].pooled + levBuf[lpEth]); // GROSS fee weight
    }

    // ═══════════════════════════ BTC IL-PROTECT: levered band slice ═══════════════════════════
    // Mirror of Vogue.syncLev/_levAdd/_levBurn over the BTC band. The BtcLevManager holds the LP's
    // vBTC collateral on external Euler/Morpho; its NET-of-debt equity (8-dec sats) is paired here as
    // TOKENLESS band depth so the LP earns V4 fees on its IL-protected position, backed by vogueBTC.

    /// @notice Re-sync `lp`'s levered BTC band slice to the BtcLevManager's authoritative net-equity.
    ///         Permissionless (like Vogue.syncLev): it only moves the tokenless levered slice to match
    ///         the manager (the keeper pokes it via the manager's hook). GROW pairs net-equity in-range
    ///         as depth; SHRINK/liquidation burns it. No new channel sats — backed by vogueBTC.
    /// §BAND-MERGE — THE SAME `addLiq` FACE VOGUE ALREADY HAS. The merged lev bodies size the
    ///         net-equity leg through `IBand(address(this)).addLiq(tok, price)`; ETH answered that
    ///         with `Vogue.addLiq` and BTC with the LIBRARY function `addLiqChannel`, which is why
    ///         the two `levAddNet` bodies could not be one. Same signature, same return shape --
    ///         only the routing differs, and routing is exactly what belongs in the band.
    function addLiq(uint deltaTok, uint price) public onlyUsBtc returns (uint usdOut, uint outDelta) {
        return BtcVaultLib.addLiqChannel(address(CORE), address(AUX), deltaTok, price);
    }

    function syncLev(address lp) external nonReentrant {   // §SLOP: one name across both bands
        // Whole body (skip-check + _rebalance-via-repack + fee-settle + FULL-RESYNC:
        // burn all, re-add gross as two legs) in BtcVaultLib.syncLev (delegatecall)
        // over the Vault's storage via the passed refs (incl. levBufferUsd).
        // Returns (added, burned); the forwarder applies the value-type delta.
        BtcVaultLib.LevDelta memory d = BtcVaultLib.syncLev(
            _btcCfg(), autoManaged[lp], levPooled, levBufferUsd, levBuf,
            lp, LEV_MANAGER, address(QUID));
        lpShares = lpShares + d.addedNet - d.burnedNet;         // NET equity leg
        totalBuffer = totalBuffer + d.bufAdded - d.bufBurned;   // GROSS buffer depth (fee weight)
    }

    /// @notice Live θ for the BTC band (yield/(K·σ²)) at the Vault's CURRENT BTC band ticks. Asks Vogue
    ///         (the band-θ math home) with the BTC ticks so BtcVaultLib.addLiqChannel can risk-budget the
    ///         BTC band exactly like the ETH band -- without VaultLib linking VogueLib.
    function derivedThetaWad() external view returns (uint) {   // §SLOP: one name across both bands
        return VOGUE.derivedThetaWadAt(address(CORE), _lo(), _hi());   // §ISBTC-SPLIT: OUR ring's variance, not the ETH band's
    }

    /// @dev Vault's BTC-side immutables gathered for the delegatecalled VaultLib
    ///      levered-band bodies (mirror of _ethCfg for the BTC cluster).
    function _btcCfg() internal view returns (Types.BandCfg memory) {
        return Types.BandCfg({ core: address(CORE), aux: address(AUX), asset: address(AUX.WBTC()) });
    }

    // Per-channel swap-out PROCEEDS settlement moved into BtcVaultLib.settleDelivered
    // (called from resizeBtcLpTail): an on-chain delivery (exactUsd>0) pays the LP
    // exactly the swapper's recorded USD from POOLED_USD + clears pendingSwapOutUsd;
    // a close/withdrawal splice (exactUsd==0) is all native.

    /// @notice Channel close → exit the LP's FULL BTC position. `lpPayoutSats` is the
    ///         BTC paid to the LP in the close tx (read on-chain via _lpFinalBalance):
    ///         the rest of the funding (funded − lpPayout) was delivered to swappers
    ///         and settles as the LP's QUI proceeds.
    /// @notice §EIP-7540 — THE BTC BAND'S ASYNCHRONOUS REDEEM. Was `unregisterBtcLp`. Full close:
    ///         the position is retired and the sats are paid out by a Lightning cooperative close,
    ///         which is why this cannot be the synchronous 4626 `redeem` -- the assets are claimable
    ///         only after L1 confirmations. Same signature note as `requestDeposit`.
    function requestRedeem(address lpEth, uint lpPayoutSats)
        external nonReentrant onlyBtcChannels {
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
        external nonReentrant onlyBtcChannels {
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
        // in BtcVaultLib.resize (delegatecall over the Vault's slots). The guards run BEFORE repack
        // (no rebalance when there's nothing to do); the value-type lpShares + accumulators apply here.
        // DELIVERY-SIDE de-lever: when this native swap-out delivery (exactUsd>0, partial) draws on the LP's
        // LEVERED slice past the free channel band (shrinkSats > funded = pooled − levPooled), de-lever the
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
        BtcVaultLib.ResizeOut memory o = BtcVaultLib.resize(
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
    function outOfRangeBtc(uint amount, address token, int distance, uint range)
        external nonReentrant returns (uint next) {
        // _rebalance stays in the Vault; the rest is BtcVaultLib.outOfRangeBtc
        // (delegatecall) which writes selfManaged/positions via the passed
        // refs and returns the new id (ID is value-type). A revert rolls back
        // the _rebalance, so validating inside the lib is behavior-identical.
        (uint spotPrice, uint curLo, uint curUp,,) = _rebalance();
        next = BtcVaultLib.outOfRangeBtc(_btcCfg(), selfManaged, positions,
            BtcVaultLib.OorArgs({ amount: amount, token: token, distance: distance,
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
        // Body in BtcVaultLib.pullBtc (delegatecall); storage refs mutate in place.
        BandLib.pull(address(CORE), selfManaged, positions,
            id, percent, token, msg.sender);
    }


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

    /// @notice This band's range, DERIVED from the one stored anchor: `[p·(1−δ), p·(1+δ)]`.
    /// @dev    §ONE-ANCHOR. Every consumer wanted the PAIR (`soldFractionWad`, `derivedThetaWad`,
    ///         `kLvrWad`, the rebalance body), which is why storing two looked natural. But the pair
    ///         is a function of ONE number, and two slots that must move together are two slots that
    ///         can fail to. Deriving is also cheaper: two `mulDiv`s against a cold SLOAD, and a
    ///         repack writes one slot instead of two.
    function bandBounds() public view returns (uint lo, uint hi) {
        return SwapLib.updateBounds(BAND_ANCHOR, SwapLib.BAND_DELTA);
    }

    function _lo() internal view returns (uint) { (uint l,) = bandBounds(); return l; }
    function _hi() internal view returns (uint) { (, uint h) = bandBounds(); return h; }

}
