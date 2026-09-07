// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SwapLib} from "./SwapLib.sol";
import {NotOpen, BadTarget} from "./Types.sol";
import { IERC20Min } from "./Interfaces.sol";
import {Types} from "./Types.sol";
import {RangeLib} from "./RangeLib.sol";
import {LevMath} from "./LevMath.sol";
import {ICore} from "./Interfaces.sol";   
import {IBasket} from "./Interfaces.sol";
import {ILevEquity} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";
// External surfaces used below all come from Interfaces.sol now (§A.52):
//   • ILevEquity — BtcLevManager's per-LP book (`grossCollateral`, `debtUsd`).
//   • ICore      — the Vault's own engine surface, reached by self-call because these bodies are
//                      DELEGATECALL'd (address(this)==Vault) and the value-type fee accumulators
//                      can't be handed over as storage refs.
//                      ⚠️ NOT `IEthVenue`, which is the ETH-VENUE CUSTODY face (rangeETH,
//                      deliverableETH, supplyEtherFi), is implemented at a DIFFERENT ADDRESS since
//                      the EthVenue extraction, and appears nowhere in this library. The misreading
//                      to head off is that the two share an address.
//   • IAux       — the Aux surface (`checkBacking`, `getTWAPforAsset`, `WBTC` below).
// The Basket mint callback stays local: `mint` is Basket's only member any consumer in this
// subtree needs, and it is declared exactly once tree-wide, so there is nothing to dedup.
/// @title  BtcLib — the BTC range / leverage / channel accounting extracted from QuidLib for EIP-170
///         headroom. DELEGATECALL'd by the Vault: `address(this)`==Vault, so all storage and
///         custody are the Vault's. Pairs with QuidLib, the ETH range's mirror.
library BtcLib {

    // Errors declared here so a revert from these delegatecalled bodies carries the SAME 4-byte
    // selector as the range's own (selectors are name-derived). `ZeroTwap` and
    // `InsufficientChannelBtc` are Vault's, and the only two any body below raises; the other four
    // carry Quid's names.
    error Dust();
    error NotOwner();
    error BadPercent();
    error NotAStable();
    error ZeroTwap();
    error InsufficientChannelBtc();   // mirror Vault's selector (name-derived) for the delegatecalled expose body

    /// @notice Body of Vault._settleBtcLp. Per-LP pro-rata: USD-leg → QUID (or banked to `usd_owed`
    ///         when payTo==0); BTC-leg → COMPOUNDED INTO `LP.pooled` in native sats, as the body
    ///         below does and explains (E145).
    function settleBtcLp(
        Types.Deposit storage LP,
        address /*lpEth*/, address payTo, address quid,   // §V4-RESIDUE 2026-08-18: `lpEth` unread
        // here — the attribution it carried is done by the CALLER before this body runs.
        uint feesPerShare, uint usdFees, uint weight
    ) public returns (uint compoundedSats) {
        // `weight` is the GROSS fee depth: net pooled + the debt-funded levered buffer (levBuf).
        if (weight == 0) return 0;
        (uint tokR, uint usdR) = SwapLib.pendingFor(LP, weight, feesPerShare, usdFees);
        // (E145) THE BTC LEG COMPOUNDS INTO THE POSITION, IN SATS: the claim is settled by growing
        // `LP.pooled`, which is why this leg needs no owed-ledger of its own.
        // ⚠️ THE BACKING IS ALREADY THERE, which is what makes this two writes and not three:
        //    `Core._handleDelta` adds to `POOLED` when tokens ENTER the pool (in-range, fee
        //    included) and subtracts when they leave, and no fee-collection path takes them back
        //    out. The sats stay in `POOLED` by design: creating the CLAIM does not remove its
        //    BACKING. Compounding therefore needs only `LP.pooled` + the caller's share total.
        // ⚠️ AND IT KEEPS THE FEE DENOMINATED IN SATS. A USD conversion was built and reverted:
        //    it silently changed what a BTC LP earns. The point of this leg is BTC exposure.
        if (tokR > 0) { LP.pooled += tokR; compoundedSats = tokR; }
        if (payTo != address(0)) {                    // USD-leg → QUID
            usdR += LP.usd_owed;
            LP.usd_owed = 0;
            // §A.57: `usdR` is 6-dec USD (the V4 USD-side token is 6-dec; `feeIncrements` does not
            // scale), but QU!D is 18-dec. Minting it raw under-paid LP fee revenue by 1e12x. Mirrors
            // the sibling `settleDelivered`, which already does `exactUsd * 1e12`.
            if (usdR > 0) IBasket(quid).mint(payTo, usdR * 1e12, quid, 0);
        } else if (usdR > 0) {
            LP.usd_owed += usdR;
        }
        SwapLib.refreshBookmarks(LP, weight, feesPerShare, usdFees);
    }

    /// @notice Per-channel swap-out PROCEEDS settlement; its only caller is `resizeBtcLpTail`
    ///         below. exactUsd>0 ⇒ on-chain delivery: pay the LP its exact recorded proceeds
    ///         from POOLED_USD + clear the obligation + mint QUI. exactUsd==0 ⇒
    ///         close/withdrawal: all native, and `deliveredRaw` comes straight back.
    function settleDelivered(address lpEth, uint deliveredRaw, uint exactUsd,
        address core, address quid) public returns (uint deliveredSlice) {
        deliveredSlice = deliveredRaw;
        if (exactUsd == 0) return deliveredSlice; // close/withdrawal: all native
        ICore(core).drawPooledUsdBtc(exactUsd);          // proceeds leave POOLED_USD
        ICore(core).subPendingSwapOut(exactUsd);         // obligation cleared (matches request +=)
        IBasket(quid).mint(lpEth, exactUsd * 1e12, quid, 0); // 6-dec → 18-dec QUI
    }

    /// @notice Body of `Vault.addLiq` (and called directly by `requestDeposit` below) —
    ///         channel-lock liquidity sizer. Shared solvency `surplus` sizing plus BOTH clamps
    ///         `SwapLib.addLiqBody` applies to either range: the physical backing HEADROOM and
    ///         the theta risk budget, measured here against `btcThetaBacking() + sats` (a BTC
    ///         range bears IL exactly like an ETH range -- the asset never changes the yield/vol
    ///         tradeoff). The theta-shed remainder is still tracked as fee-earning share by the
    ///         caller.
    function addLiqChannel(address core, address aux, uint sats, uint price)
        public returns (uint usdOut, uint outDelta) {
        // §DELTATOK-FOLD — THE BODY IS `SwapLib.addLiqBody`, SHARED WITH `QuidLib.addLiq`. The two
        // were the same seven statements, including the §E270 recompute and its comment; only the θ
        // and `backing` scalars below ever differed, and that asymmetry is REAL (a BTC range's
        // IL-bearing capital is `btcThetaBacking`, not `rangeETH`).
        // θ is read HERE, not in the shared body: `ICore(address(this))` is `Vault` only under this
        // library's delegatecall — see the warning on `addLiqBody`.
        uint thetaEff = ICore(address(this)).derivedThetaWad();
        if (thetaEff == 0) thetaEff = 1e18;        // fail OPEN, matching ETH's `_liveTheta`
        // `+ sats`: THIS add is not yet credited to `lpShares` at clamp time, so the backing it
        // brings must be counted or the range clamps against its own pre-deposit size.
        return SwapLib.addLiqBody(core, aux, sats, price,
            thetaEff, ICore(core).btcThetaBacking() + sats);
    }

    /// @dev Scalar args for the resize/close tail, bundled to keep the Vault
    ///      forwarder + this body off the legacy stack.
    struct ResizeArgs {
        address lpEth;
        uint    shrinkSats;     // already clamped to funded (or := funded on full)
        uint    lpPayoutSats;
        bool    full;
        uint    exactUsd;
        uint    inrange;        // LP.pooled at entry (net: channel funding + net levered slice)
        uint    lev;            // levPooled[lpEth] at entry (NET levered slice, in pooled)
        uint    buf;            // levBuf[lpEth] at entry (debt-funded buffer, NOT in pooled)
        uint spotPrice;
        uint    loPrice;
        uint    upPrice;
        uint    feesPerShare;
        uint    usdFees;      // §RANGE-MERGE: the BTC suffix is redundant inside a BTC library
    }

    /// @dev resize/resizeBtcLpTail output as ONE struct (single memory pointer) rather than four
    ///      stack-slot returns — keeps both off the legacy-pipeline stack (no via_ir). The Vault
    ///      forwarder applies `lpShares = lpShares + feeCompounded - sharesRemoved` and
    ///      `totalBuffer -= bufRemoved`.
    /// @dev `feeCompounded` (E145): sats the BTC fee leg compounded into `LP.pooled` during
    ///      this resize. The forwarder must ADD it to `lpShares` alongside subtracting
    ///      `sharesRemoved`, or the sum drifts from the positions it totals.
    struct ResizeOut { uint sharesRemoved; bool cleared; uint bufRemoved; uint feeCompounded; }

    /// @notice The tail of `resize` below — its only caller — picking up after that body's
    ///         funded/lev prologue and repack. Settles fees, pays the swap-out proceeds,
    ///         burns the native (+ full-close lev) range depth, decrements the position and
    ///         finalizes. The Vault forwarder applies `lpShares = lpShares + feeCompounded -
    ///         sharesRemoved` and `totalBuffer -= bufRemoved`, and on `cleared` zeroes the fee
    ///         accumulators if no fee-earning depth remains.
    function resizeBtcLpTail(
        address core, address quid,
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBuf,
        ResizeArgs memory a
    ) public returns (ResizeOut memory o) {
        Types.Deposit storage LP = autoManaged[a.lpEth];
        {   // settlement + native burn scoped so its locals free before the tail
            // GROSS fee weight = net pooled + the debt-funded buffer (levBuf).
            o.feeCompounded = settleBtcLp(LP, a.lpEth, a.lpEth, quid, a.feesPerShare, a.usdFees, LP.pooled + a.buf); // (E145)
            uint deliveredRaw = a.shrinkSats > a.lpPayoutSats ? a.shrinkSats - a.lpPayoutSats : 0;
            uint deliveredSlice = settleDelivered(a.lpEth, deliveredRaw, a.exactUsd, core, quid);
            uint nativeSlice = a.shrinkSats - deliveredSlice;
            SwapLib.burnInRange(core, nativeSlice, address(0));
            // Full channel close burns BOTH levered legs' V4 depth: the net slice (a.lev) and the
            // debt-funded buffer (a.buf). The buffer leaves totalBuffer via the bufRemoved return.
            if (a.full && a.lev > 0)
                SwapLib.burnInRange(core, a.lev, address(0));
            if (a.full && a.buf > 0) {
                SwapLib.burnInRange(core, a.buf, address(0));
                o.bufRemoved = a.buf;
            }
        }
        // (E145) A FULL CLOSE MUST RETIRE `LP.pooled` AS IT STANDS, NOT A PRE-COMPUTED FIGURE.
        // `a.inrange` is captured BEFORE `settleBtcLp` runs, and settling now COMPOUNDS the
        // BTC-leg fee into `pooled` — so closing on the stale figure stranded exactly the
        // compounded sats in a retired position (`testCrossChain_FullE2E` caught 419 left
        // behind). Reading `LP.pooled` here is also strictly more correct than it was before:
        // it cannot disagree with the thing it is emptying.
        o.sharesRemoved = a.full ? LP.pooled : a.shrinkSats;
        LP.pooled -= o.sharesRemoved;
        if (a.full) { levPooled[a.lpEth] = 0; levBuf[a.lpEth] = 0; }
        // Finalize: full exit publishes/clears the owed BTC-leg fee + retires the
        // slot; a partial splice rebaselines the remainder's fee bookmarks.
        if (LP.pooled == 0) {
            delete autoManaged[a.lpEth];       // retire the slot
            o.cleared = true;
        } else {
            // Partial splice leaves the buffer intact (levBuf unchanged): gross weight = pooled + a.buf.
            SwapLib.refreshBookmarks(LP, LP.pooled + a.buf, a.feesPerShare, a.usdFees);
        }
    }

    /// @notice Full body of Vault._resize: the funded/lev prologue + clamp +
    ///         early-returns + repack (self-call) + tail. `full` = whole-channel close
    ///         (shrinkSats := funded); else a partial splice-out. The forwarder applies
    ///         `lpShares = lpShares + feeCompounded - sharesRemoved` and
    ///         `totalBuffer -= bufRemoved`, and on `cleared` resets the accumulators once no
    ///         fee-earning depth is left. The guards run BEFORE repack (no rebalance when
    ///         there's nothing to do).
    function resize(
        address core, address quid,
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBuf,
        address lpEth, uint shrinkSats, uint lpPayoutSats, bool full, uint exactUsd
    ) public returns (ResizeOut memory o) {
        // Route everything through the ResizeArgs memory slot so the input scalars go
        // dead early (keeps this frame off the legacy stack — no via_ir). `funded` is
        // the only extra local.
        ResizeArgs memory a;
        a.lpEth = lpEth; a.lpPayoutSats = lpPayoutSats; a.full = full; a.exactUsd = exactUsd;
        a.inrange = autoManaged[lpEth].pooled;  // in-range share (channel funding + NET levered slice)
        a.lev = levPooled[lpEth];               // NET levered slice (in pooled)
        a.buf = levBuf[lpEth];                  // debt-funded buffer (NOT in pooled)
        {
            uint funded = a.inrange > a.lev ? a.inrange - a.lev : 0;  // true channel funding
            if (funded == 0 && a.lev == 0 && a.buf == 0) return o;
            if (full) {
                a.shrinkSats = funded;             // whole channel position (lev + buffer handled separately)
            } else {
                if (shrinkSats == 0) return o;
                a.shrinkSats = shrinkSats > funded ? funded : shrinkSats;
            }
        }
        (a.spotPrice, a.loPrice, a.upPrice,,) = ICore(address(this)).repack();
        a.feesPerShare = ICore(address(this)).feesPerShare();
        a.usdFees = ICore(address(this)).USD_FEES();
        return resizeBtcLpTail(core, quid, autoManaged, levPooled, levBuf, a);
    }

    // ════════════════════════════════════════════════════════════════════
    //  BTC IL-PROTECT: levered range slice. `syncLev` below is the body of
    //  Vault.syncLev; the per-leg add/burn bodies it drives live in RangeLib.
    //  Reference-type state (the LP Deposit + the levPooled/levBuf/levBufferUsd
    //  mappings) is passed by STORAGE REF so the library writes the Vault's slots
    //  via delegatecall; the value-type lpShares and totalBuffer are mutated by
    //  RETURNING the four deltas, which the thin Vault forwarder applies
    //  (`lpShares = lpShares + d.addedNet - d.burnedNet`).
    // ════════════════════════════════════════════════════════════════════

    /// @dev syncLev's four signed deltas, returned as ONE struct (a single memory pointer) rather than
    ///      four stack-slot returns — keeps syncLev off the legacy-pipeline stack (no via_ir). The Vault
    ///      forwarder applies lpShares += addedNet - burnedNet and totalBuffer += bufAdded - bufBurned.
    struct LevDelta { uint addedNet; uint burnedNet; uint bufAdded; uint bufBurned; }

    /// @notice Full body of Vault.requestDeposit (prologue + rebalance moved here):
    ///         checkBacking + repack self-call, then settle existing fees, THEN the TWAP read
    ///         (deliberately after the settle — see the body), then pair the in-range slice + track
    ///         the out-of-range remainder as shares. Returns the lpShares increase: the fee the
    ///         settle compounded into `pooled`, + deltaBTC + unpaired.
    function requestDeposit(
        Types.RangeCfg memory c,
        Types.Deposit storage LP,
        address lpEth, uint sats, address quid, uint weight
    ) public returns (uint sharesAdded) {
        // `weight` = pooled + levBuf[lpEth] (the GROSS fee weight at entry, precomputed by the forwarder to
        // keep this frame off the legacy stack). Channel register grows only `pooled` (net) by deltaBTC, so the
        // post-pair weight is `weight + deltaBTC`; the buffer is constant through a register.
        if (sats == 0 || lpEth == address(0)) return 0;
        IAux(c.aux).checkBacking();
        // Bundle the pool range + fresh fee accumulators into one memory slot so this
        // frame stays off the legacy stack (no via_ir). _rebalance (via repack) already
        // accrued any V4 fees into the accumulators; read them fresh.
        Types.RangeP memory p;
        // (§BOOKMARK-OMITS-THE-COMPOUNDED-FEE) Capture the levered buffer BEFORE anything mutates
        // `LP.pooled`. Every bookmark refresh below re-reads `LP.pooled` and adds this back, so the
        // stored weight is the true GROSS one at the moment it is written.
        (p.spotPrice, p.loPrice, p.upPrice,,) = ICore(address(this)).repack();
        p.feesPerShare = ICore(address(this)).feesPerShare();
        p.usdFees = ICore(address(this)).USD_FEES();
        p.buf = weight - LP.pooled;
        sharesAdded += settleBtcLp(LP, lpEth, address(0), quid, p.feesPerShare, p.usdFees, weight); // (E145) fee compounds into pooled
        // price computed AFTER the settle so it isn't live across it (legacy-pipeline stack). A price==0
        // revert here still rolls back the settle's state, so behavior is unchanged.
        uint price = IAux(c.aux).getTWAPforAsset(IAux(c.aux).WBTC(), 1800);
        if (price == 0) revert ZeroTwap();
        (uint deltaUSD, uint deltaBTC) = addLiqChannel(c.core, c.aux, sats, price);
        // In-range pairing extracted to its own frame (legacy-pipeline stack: the modLP call otherwise
        // overflows requestDeposit). Grows pooled + refreshes the bookmark at the post-pair GROSS weight.
        if (deltaBTC > 0) sharesAdded += _pairRegLeg(c.core, LP, p, deltaBTC, deltaUSD, lpEth);
        uint unpaired = sats - deltaBTC;
        if (unpaired > 0) {
            // Out-of-range portion: backed by the channel sats (off-chain), tracked as share so it earns
            // fees and exits in full.
            LP.pooled += unpaired; sharesAdded += unpaired;
            // (§BOOKMARK-OMITS-THE-COMPOUNDED-FEE) `LP.pooled + buf`, not `weight + sats`. The old
            // form omitted the fee `settleBtcLp` compounded into `pooled`, leaving the bookmark below
            // the true position — see `_pairRegLeg` for the full reasoning. ⚠️ BOTH SITES NEED THIS,
            // not just the last one: when `unpaired == 0` only `_pairRegLeg`'s refresh runs.
            SwapLib.refreshBookmarks(LP, LP.pooled + p.buf, p.feesPerShare, p.usdFees);
        }
    }

    /// @dev In-range channel-register leg in its own frame (legacy stack): pair `deltaBTC`, refresh the
    ///      bookmark at the post-pair GROSS weight (weight + deltaBTC), and modLP. Returns the shares added.
    function _pairRegLeg(
        address core, Types.Deposit storage LP, Types.RangeP memory p,
        uint deltaBTC, uint deltaUSD, address lpEth
    ) private returns (uint) {
        LP.pooled += deltaBTC;
        // (§BOOKMARK-OMITS-THE-COMPOUNDED-FEE) RE-READ `LP.pooled`; do NOT use the caller's `weight`.
        // `settleBtcLp` has already COMPOUNDED the BTC-leg fee into `pooled` (§E145), so `weight` is
        // stale by exactly that amount — and `refreshBookmarks` stores `w·feesPerShare`, so a stale
        // `w` leaves the LP with a bookmark BELOW its true position and the next settlement pays the
        // difference again out of other LPs' fees. The sibling refresh at the tail of
        // `resizeBtcLpTail` re-reads `LP.pooled` for this reason; this path did not.
        // `buf` (levBuf) is constant through
        // a register, which is what makes `LP.pooled + buf` the exact GROSS weight.
        SwapLib.refreshBookmarks(LP, LP.pooled + p.buf, p.feesPerShare, p.usdFees);
        ICore(core).modLP(-int256(deltaBTC), -int256(deltaUSD), lpEth);   // ENTERS ⇒ negative
        return deltaBTC;
    }

    /// @notice Full body of Vault.syncLev (skip-check + rebalance moved here):
    ///         reconcile range CAPACITY to the manager's GROSS target; skip when both
    ///         the gross depth AND the buffer-USD target are already in sync. On work,
    ///         repack (self-call), then settle fees + FULL-RESYNC the slice to GROSS
    ///         (net + debt-funded buffer) as two legs — the net leg pairs basket-surplus
    ///         USD, the buffer leg pairs its OWN debt (folded into POOLED_USD, excluded from committed via
    ///         committedUsd18's live-debt subtraction). Mirrors ETH.
    ///         Returns the signed lpShares change split as (added, burned).
    function syncLev(
        Types.RangeCfg memory c,
        Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, address mgr, address quid
    ) public returns (LevDelta memory d) {
        // NET model (mirror of Quid): levPooled is the NET leg (in pooled/lpShares); levBuf is the
        // debt-funded buffer (fee weight only). Live gross depth = their sum.
        uint gross = mgr == address(0) ? 0 : ILevEquity(mgr).grossCollateral(lp);
        // ⭐ THE ALL-ZERO FAST PATH — mirror of `Quid._reconcileLev`'s. An LP that has never levered
        //    has nothing to reconcile, and the general check below would still pay for a `debtUsd`
        //    external call to learn that. Three local SLOADs answer it, which is what makes this
        //    callable UNCONDITIONALLY from the BTC crystallisation points rather than gated on the
        //    stale mirror it exists to refresh.
        if (gross == 0 && levPooled[lp] == 0 && levBuf[lp] == 0 && levBufferUsd[lp] == 0) return d;
        if (gross == levPooled[lp] + levBuf[lp] &&
            levBufferUsd[lp] == (mgr == address(0) ? 0 : ILevEquity(mgr).debtUsd(lp) / 1e12)) return d;
        // Precompute the GROSS fee weight while the stack is still empty (before p) so the 8-arg settle call
        // below doesn't compute pooled+levBuf inline at its peak. Build p field-by-field (NOT a struct
        // literal) so external-call temporaries free between assignments — both keep this off the legacy stack.
        uint w = LP.pooled + levBuf[lp];
        Types.RangeP memory p;
        (p.spotPrice, p.loPrice, p.upPrice,,) = ICore(address(this)).repack();
        p.feesPerShare = ICore(address(this)).feesPerShare();
        p.usdFees = ICore(address(this)).USD_FEES();
        p.mgr = mgr; p.gross = gross;
        // 🔴 §E145 — **THE FEE COMPOUND WAS ASSIGNED OVER.** This read `d.addedNet += settleBtcLp(...)`
        //    and then `(d.addedNet, d.bufAdded) = RangeLib.levAddGross(...)` — a PLAIN ASSIGNMENT that
        //    discards the compounded fee the line above just earned. The forwarder applies
        //    `lpShares + d.addedNet - d.burnedNet`, so the lost term makes `lpShares` drift BELOW the
        //    sum of the positions it totals — the exact drift `Vault._resize` documents guarding
        //    against ("fees compounded into `pooled` during this resize must be added, or `lpShares`
        //    drifts below the sum of positions it totals").
        //    ⚠️ The `+=` on the first line is what makes the bug invisible: it LOOKS accumulative, and
        //    the overwrite is three lines away on a tuple destructure, which cannot be written as `+=`.
        uint feeCompounded = settleBtcLp(LP, lp, address(0), quid, p.feesPerShare, p.usdFees, w);
        (d.burnedNet, d.bufBurned) = RangeLib.levBurnAll(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
        (d.addedNet, d.bufAdded)   = RangeLib.levAddGross(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
        d.addedNet += feeCompounded;   // restore the term the destructure above cannot carry
    }

    // ════════════════════════════════════════════════════════════════════
    //  vBTC RANGE BODIES (BTC-lev collateral). The ERC-20 face lives in `VBtc.sol`
    //  (§J.2) and owns its own balances, so nothing token-side is delegatecall'd:
    //  what is here is range accounting ONLY, the funded↔lev reclassification.
    //  DELEGATECALL'd, so the passed-by-STORAGE-REF mappings are the Vault's real slots.
    //  vBTC is sats-denominated (8-dec); supply moves only via the SAME-BTC
    //  expose/unexpose path, gated to the LevManager in the Vault forwarder.
    // ════════════════════════════════════════════════════════════════════

    /// @notice Body of Vault.exposeBtcToLev — reclassify `sats` of the LP's FREE channel range BTC as the levered
    ///         slice (funded→lev; LP.pooled untouched, single-count). The matching vBTC SUPPLY mutation is the
    ///         token's own (`VBtc.mintTo`, called by the Vault forwarder right after this) — this body owns range
    ///         state only. The `NotLevManagerBtc` gate stays in the Vault forwarder.
    function vbtcExposeBody(
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levPooled,
        address lp, uint sats
    ) public {
        uint pooled = autoManaged[lp].pooled;
        uint free = SwapLib.plainNet(pooled, levPooled[lp]);
        if (sats == 0 || sats > free) revert InsufficientChannelBtc();
        levPooled[lp] += sats;                            // funded → lev; LP.pooled untouched (single-count)
    }

    /// @notice Body of Vault.unexposeBtcFromLev — convert the LP's levered slice back to FREE channel range depth
    ///         (lev→funded; LP.pooled untouched). The burn is the token's own (`VBtc.burnFrom`), and the Vault
    ///         forwarder runs it BEFORE this so an under-funded manager reverts without the range having moved.
    function vbtcUnexposeBody(
        mapping(address => uint) storage levPooled,
        address lp, uint sats
    ) public {
        uint lev = levPooled[lp];
        levPooled[lp] = sats >= lev ? 0 : lev - sats;      // lev → funded; LP.pooled untouched
    }

    /// @dev rebalanceBody output — the 5 caller returns + the fee increments the forwarder adds to
    ///      `feesPerShare` / `USD_FEES`. One memory pointer keeps the frame off the
    ///      legacy stack (no via_ir).
    /// ⚠️ §REBAL-VERB: the fee fields are INCREMENTS, exactly as in `QuidLib.RebalOut`, and both
    ///    forwarders therefore apply them with `+=` (`Vault._rebalance`). They must NOT become
    ///    absolutes: two structs sharing one name while one is assigned and the other added is
    ///    silent money loss in whichever direction a future fold gets wrong.
    struct RebalOut {
        uint spotPrice; uint    loPrice; uint    upPrice; uint myLiquidity; uint resolvedTwap;
        uint feesPerShareInc; uint usdFeesInc;
    }

    /// @notice Body of Vault._rebalance (BTC side): `SwapLib.rebalanceCore` — the oracle read, the
    ///         stale-feed reseat and the repack/re-range — then the range is copied into `o`.
    ///         `feeDenom` (= lpShares + totalBuffer, the GROSS fee weight, read by the forwarder at
    ///         the call) is no longer consumed: the JIT distribution below was the only thing that
    ///         spent it, so nothing in this body writes the two fee increments. The forwarder applies
    ///         those increments (`+=`) and `RANGE_ANCHOR`.
    function rebalanceBody(
        Types.RangeCfg memory c, uint loPrice, uint upPrice,
        uint feeDenom
    ) public returns (RebalOut memory o) {
        // BTC has no vault yield to sync (no WBTC supply); skip _syncYield.
        SwapLib.Rebalanced memory r = SwapLib.rebalanceCore(
            c.core, c.aux, IAux(c.aux).WBTC(), upPrice, loPrice);
        // ⛔ (§V4-CUT) NO FEE DISTRIBUTION HAPPENS HERE, so `o.feesPerShareInc`/`o.usdFeesInc` come
        // back zero. Whatever wires a BTC fee source up again needs a `!r.didRepack` guard on the
        // distribution: a repack and a fee accrual are NOT mutually exclusive, and paying fees out
        // on a repack-and-reseat is the bug such a guard exists to prevent.
        o.spotPrice = r.spotPrice; o.loPrice = r.loPrice; o.upPrice = r.upPrice;
        o.myLiquidity = r.myLiquidity; o.resolvedTwap = r.resolvedTwap;
    }




    // ── §FOLD-LEGS — THE FOUR VENUE LEGS, ASSET-AGNOSTIC ─────────────────────────────────────────
    // These lived ONLY on `BtcLevManager` and read as BTC-specific. They are not: every one is a
    // generic venue operation whose sole asset-specific input is the COLLATERAL TOKEN, which is now a
    // parameter. `leverBorrow`/`repay` do not touch the collateral at all -- they move the venue's
    // STABLE in and out -- which is why the BTC lever cycle survived the volatile venue's removal untouched
    // while the ETH atomic path did not.
    //
    // ⚠️ EVENTS ARE DECLARED HERE AND STILL EMIT FROM THE MANAGER'S ADDRESS -- delegatecall preserves
    // `address(this)`. The topics are unchanged because the declarations are byte-identical to the
    // manager's, so no client ABI moves. If you edit an event here, you have edited the manager's ABI.
    //
    // ⚠️ `_syncRange` IS NOT CALLED FROM HERE. It try/catches a call to `RANGE` and returning a flag for
    // the caller to act on would be the same code in a worse place, so the WRAPPER pokes the range
    // after this returns. That ordering matters: the poke must happen AFTER the venue state moves.

    event Borrowed(address indexed lp, uint stableOut);
    event Supplied(address indexed lp, uint vbtcIn);
    event Withdrawn(address indexed lp, uint vbtcOut);
    event Repaid(address indexed lp, uint stableIn);

    /// @notice Borrow the venue's stable toward the IL target and hand it to the LP.
    /// @dev    `room` is computed by the CALLER (`debtDeltaToTarget` routes through the `_collToBase`
    ///         virtual). Clamping `want` to `room` is what makes an over-ask harmless: it can only
    ///         reach the target, never pass it -- so this stays safe even though `stableUsd` is
    ///         caller-supplied.
    function leverBorrow(
        mapping(address => Types.Pos) storage pos,
        address aux, address lp, uint stableUsd, bool levUp, uint room
    ) external returns (uint got) {
        Types.Pos memory q = pos[lp];
        if (!q.open) revert NotOpen();
        if (!levUp || room == 0) revert BadTarget();
        uint want = stableUsd > room ? room : stableUsd;
        got = q.venue.borrow(lp, LevMath._fromUsd(aux, q.venue.stable(), want));
        if (got > 0) IERC20Min(q.venue.stable()).transfer(lp, got);
        emit Borrowed(lp, got);
    }

    /// @notice Pull `amount` of COLLATERAL from the LP and supply it as isolated collateral.
    /// @param  coll the collateral token — weETH on the ETH side, vBTC on the BTC side. The ONLY
    ///         asset-specific input, and the reason this body was never BTC-specific.
    function leverSupply(
        mapping(address => Types.Pos) storage pos,
        address coll, address lp, uint amount
    ) external {
        Types.Pos memory q = pos[lp];
        if (!q.open) revert NotOpen();
        IERC20Min(coll).transferFrom(lp, address(this), amount);
        IERC20Min(coll).transfer(address(q.venue), amount);
        q.venue.supply(lp, amount);
        emit Supplied(lp, amount);
    }

    /// @notice Withdraw collateral from the venue to the LP (to burn/sell externally, then repay).
    function deleverWithdraw(
        mapping(address => Types.Pos) storage pos,
        address coll, address lp, uint amount
    ) external returns (uint out) {
        if (!pos[lp].open) revert NotOpen();
        out = pos[lp].venue.withdraw(lp, amount);
        if (out > 0) IERC20Min(coll).transfer(lp, out);
        emit Withdrawn(lp, out);
    }

    /// @notice Repay debt from the LP's own stable.
    /// @dev    CAPPED AT `debtOf` BEFORE the transfer, so an over-repay cannot pull more stable than
    ///         the debt needs — the LP is never charged for value the venue will not credit. The
    ///         `amt == 0` early return still emits, so a no-op repay is observable rather than silent.
    function repay(
        mapping(address => Types.Pos) storage pos,
        address aux, address lp, uint stableUsd
    ) external returns (uint repaid) {
        Types.Pos memory q = pos[lp];
        if (!q.open) revert NotOpen();
        uint amt = LevMath._fromUsd(aux, q.venue.stable(), stableUsd);
        uint debt = q.venue.debtOf(lp);
        if (amt > debt) amt = debt;
        if (amt == 0) { emit Repaid(lp, 0); return 0; }
        IERC20Min(q.venue.stable()).transferFrom(lp, address(q.venue), amt);
        repaid = q.venue.repay(lp, amt);
        emit Repaid(lp, repaid);
    }
}
