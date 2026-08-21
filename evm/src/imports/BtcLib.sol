// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SwapLib} from "./SwapLib.sol";
import {NotOpen, BadTarget} from "./Types.sol";
import {ILevVenue, IERC20Min} from "./Interfaces.sol";
import {Types} from "./Types.sol";
import {BandLib} from "./BandLib.sol";
import {LevMath} from "./LevMath.sol";
import {ICore} from "./Interfaces.sol";
import {IBand} from "./Interfaces.sol";
import {IBasketMint} from "./Interfaces.sol";
import {ILevEquity} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";
import {QuidLib} from "./QuidLib.sol";

// External surfaces used below all come from Interfaces.sol now (§A.52):
//   • ILevEquityBtc — BtcLevManager's per-LP book (was `ILevBtc_V`, a 3-of-4 subset).
//   • IEthVenue     — the Vault's own surface, reached by self-call because these bodies are
//                      DELEGATECALL'd (address(this)==Vault) and the value-type fee accumulators
//                      can't be handed over as storage refs (was `IVaultCtx_V`).
//   • IAux      — the Aux surface (was `IAuxBtc_V` + `IAuxDeposits_V`, both strict subsets;
//                      IAuxDeposits_V's lone `get_deposits` is byte-identical to IAux's).
// The Basket mint callback stays local: `mint` is Basket's only member any consumer in this
// subtree needs, and it is declared exactly once tree-wide, so there is nothing to dedup.
/// @title  BtcLib — the BTC band / leverage / channel accounting extracted from QuidLib
///         (now purely the ETH venue custody ladder) for EIP-170 headroom. DELEGATECALL'd by the
///         Vault exactly as the BTC bodies were when they lived in QuidLib: `address(this)`==Vault,
///         so all storage/custody are the Vault's. Byte-identical to the former in-QuidLib BTC
///         bodies -- only the home moved. Pairs with QuidLib (the ETH band's mirror).
library BtcLib {

    // Mirror Vault's custom errors so reverts from delegatecalled bodies carry the SAME 4-byte selector.
    error Dust();
    error NotOwner();
    error BadPercent();
    error NotAStable();
    error ZeroTwap();
    error InsufficientChannelBtc();   // mirror Vault's selector (name-derived) for the delegatecalled expose body

    /// @notice Body of Vault._settleBtcLp. Per-LP pro-rata: USD-leg → QUID (or
    ///         banked to usd_owed when payTo==0); BTC-leg → native sats
    ///         (btcFeesOwedSats), settled by the hop at channel close.
    function settleBtcLp(
        Types.Deposit storage LP,
        address /*lpEth*/, address payTo, address quid,   // §V4-RESIDUE 2026-08-18: `lpEth` unread here — the
        // attribution it carried is done by the CALLER before this body runs. Name commented rather than the
        // parameter removed: this is a `public` library function, so dropping it would change the SELECTOR and
        // every delegatecall encoding with it, for a warning.
        uint feesPerShare, uint usdFees, uint weight
    ) public returns (uint compoundedSats) {
        // `weight` is the GROSS fee depth: net pooled + the debt-funded levered buffer (levBuf).
        if (weight == 0) return 0;
        (uint tokR, uint usdR) = SwapLib.pendingFor(LP, weight, feesPerShare, usdFees);
        // (E145) THE BTC LEG COMPOUNDS INTO THE POSITION, IN SATS. It used to accrue to
        // `btcFeesOwedSats`, a ledger only a hop-funded GROW-SPLICE could settle
        // (`feeSettleSats <= grewBy`) — so it rode an unrelated operation, could not be enforced
        // without making the LP's EXIT depend on hop liveness, and was DELETED at close.
        // MEASURED: 209 sats per 500k-sat swap-in accrued, and on exit NO remaining LP's claim
        // moved — it was simply dropped.
        // ⚠️ THE BACKING IS ALREADY THERE, which is what makes this two writes and not three:
        //    `Core._settleTokSide` adds to `POOLED` when tokens ENTER the pool (`inRange`,
        //    fee included) and subtracts when they leave — but fee COLLECTION passes
        //    `inRange=false` (`_handleCollect`), so the subtraction never fires. The sats stay in
        //    `POOLED` by design: the guard exists so creating the CLAIM does not remove its
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
            if (usdR > 0) IBasketMint(quid).mint(payTo, usdR * 1e12, quid, 0);
        } else if (usdR > 0) {
            LP.usd_owed += usdR;
        }
        SwapLib.refreshBookmarks(LP, weight, feesPerShare, usdFees);
    }

    /// @notice Body of Vault._settleDelivered — per-channel swap-out PROCEEDS
    ///         settlement. exactUsd>0 ⇒ on-chain delivery: pay the LP its exact
    ///         recorded proceeds from POOLED_USD + clear the obligation +
    ///         mint QUI. exactUsd==0 ⇒ close/withdrawal: all native.
    function settleDelivered(address lpEth, uint deliveredRaw, uint exactUsd,
        address core, address quid) public returns (uint deliveredSlice) {
        deliveredSlice = deliveredRaw;
        if (exactUsd == 0) return deliveredSlice; // close/withdrawal: all native
        ICore(core).drawPooledUsdBtc(exactUsd);          // proceeds leave POOLED_USD
        ICore(core).subPendingSwapOut(exactUsd);         // obligation cleared (matches request +=)
        IBasketMint(quid).mint(lpEth, exactUsd * 1e12, quid, 0); // 6-dec → 18-dec QUI
    }

    /// @notice Body of Vault._addLiqChannel — channel-lock liquidity sizer.
    ///         Shared solvency `surplus` + BTC-cap logic, and the SAME theta
    ///         risk-budget clamp the ETH band applies (QuidLib.addLiq). Only the
    ///         PHYSICAL-inventory clamp is skipped -- the volatile backing is the
    ///         LP's LOCKED channel sats, so there is no shared-inventory headroom
    ///         to respect; but the band's IL exposure is throttled by theta
    ///         identically (a BTC band bears IL exactly like an ETH band -- the
    ///         asset never changes the yield/vol tradeoff). The theta-shed
    ///         remainder is still tracked as fee-earning share by the caller.
    function addLiqChannel(address core, address aux, uint sats, uint price)
        public returns (uint usdOut, uint outDelta) {
        (uint[15] memory deposits,,,) = IAux(aux).get_deposits();
        uint committedBoth = ICore(core).committedUsd18();
        (uint deltaTok, uint targetUSD, uint surplus) =
            SwapLib.sizeBySurplus(deposits[14], committedBoth, sats, price);
        if (surplus == 0) return (0, 0);
        uint capped = _thetaClampBtc(core, deltaTok, sats);   // own frame (legacy stack)
        // §E270 — RECOMPUTE, matching ETH, rather than rescaling by the clamp ratio. DRIFT, not a
        // per-asset requirement: `sizeBySurplus` maintains `targetUSD == deltaOut*price/WAD` on BOTH
        // exits, so the two forms are the same quantity — and recomputing has one rounding instead of
        // compounding the earlier one and dividing by a `deltaTok` itself rounded in the clamped case.
        if (capped < deltaTok) {
            deltaTok = capped;
            targetUSD = SwapLib.usdForTok(deltaTok, price);
        }
        usdOut = targetUSD / 1e12;
        if (usdOut == 0) return (0, 0);
        outDelta = deltaTok;
    }

    /// @dev BTC band theta clamp in its OWN frame (legacy-pipeline stack). Caps the paired depth at
    ///      `theta * backing` -- the live yield/(K*sigma^2) throttle over the BTC band's own ticks +
    ///      variance ring (Vault.derivedThetaWadBtc asks Quid). Fails OPEN (theta>=1e18 -> no-op),
    ///      including when yield is unmeasured (theta 0 -> 1e18), matching ETH's _liveTheta. `available`
    ///      base is the full `deltaTok` (locked backing skips the physical clamp); only theta bites here.
    ///      BACKING = `Core.btcThetaBacking()` (aggregate locked sats lpShares + gross buffer -- the ONE
    ///      source of truth shared with the reseat clamp in QuidLib.addLiq, so a repack can't re-throttle
    ///      the band this add just built) + THIS add's `sats` (requestDeposit/levAddBtc credit lpShares
    ///      only AFTER this clamp -- unlike ETH, where _depositETH bumps bandETH BEFORE addLiq; add it here
    ///      for parity + first-deposit bootstrap). NOT bandBTC: that is a disjoint WBTC-donation pool,
    ///      structurally unrelated to the band's risk capital -- basing theta on it throttled the band to ~0
    ///      whenever donations were thin (the opposite of what scarcity should do).
    function _thetaClampBtc(address core, uint deltaTok, uint sats) private view returns (uint) {
        uint thetaEff = IBand(address(this)).derivedThetaWad();
        if (thetaEff == 0) thetaEff = 1e18;
        // ONE principle (SwapLib.clampByBacking): bound by both the physical backing headroom AND theta —
        // shared verbatim with the reseat clamp (QuidLib.addLiq) and the ETH band. backing = the native
        // capital (Core.btcThetaBacking = lpShares + gross buffer) + THIS add's `sats` (not yet credited
        // to lpShares at clamp time — see the long note above).
        return SwapLib.clampByBacking(thetaEff, ICore(core).btcThetaBacking() + sats, ICore(core).POOLED(), deltaTok);
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
        uint    usdFees;      // §BAND-MERGE: the BTC suffix is redundant inside a BTC library
    }

    /// @dev resize/resizeBtcLpTail output as ONE struct (single memory pointer) rather than four
    ///      stack-slot returns — keeps both off the legacy-pipeline stack (no via_ir). The Vault forwarder
    ///      applies lpShares -= sharesRemoved, totalBuffer -= bufRemoved, and on `cleared` emits owed.
    /// @dev `feeCompounded` (E145): sats the BTC fee leg compounded into `LP.pooled` during
    ///      this resize. The forwarder must ADD it to `lpShares` alongside subtracting
    ///      `sharesRemoved`, or the sum drifts from the positions it totals.
    struct ResizeOut { uint sharesRemoved; bool cleared; uint owed; uint bufRemoved; uint feeCompounded; }

    /// @notice Body of Vault._resize AFTER the funded/lev prologue + _rebalance
    ///         (both stay in the Vault). Settles fees, pays the swap-out proceeds,
    ///         burns the native (+ full-close lev) band depth, decrements the
    ///         position and finalizes. Returns (sharesRemoved, cleared, owed): the
    ///         forwarder applies `lpShares -= sharesRemoved`, and on `cleared`
    ///         FORGOES the residual `owed` to the pool (dust; the sats are already in
    ///         POOLED, so deleting the owed-ledger here donates them — emits
    ///         BtcLpFeesForgone for monitoring) + zeros the accumulators if it was the last LP.
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
    ///         (shrinkSats := funded); else a partial splice-out. Returns
    ///         (sharesRemoved, cleared, owed) — the forwarder applies
    ///         `lpShares -= sharesRemoved` and on `cleared` emits + resets. The
    ///         guards run BEFORE repack (no rebalance when there's nothing to do),
    ///         preserving the former in-Vault ordering exactly.
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
        (a.spotPrice, a.loPrice, a.upPrice,,) = IBand(address(this)).repack();
        a.feesPerShare = IBand(address(this)).feesPerShare();
        a.usdFees = IBand(address(this)).USD_FEES();
        return resizeBtcLpTail(core, quid, autoManaged, levPooled, levBuf, a);
    }

    // ════════════════════════════════════════════════════════════════════
    //  BTC IL-PROTECT: levered band slice. Bodies of Vault._levAddBTC /
    //  _levBurnBTC extracted to free bytecode. Reference-type state (the LP
    //  Deposit + levPooled mapping) is passed by STORAGE REF so the library
    //  writes the Vault's slots via delegatecall; the value-type lpShares is
    //  mutated by RETURNING the delta (added/burned), which the thin Vault
    //  forwarder applies (`lpShares += levAddBtc(...)` / `-= levBurnBtc(...)`).
    // ════════════════════════════════════════════════════════════════════

    /// @dev Vault's BTC-side immutables the levered-band bodies touch.
    // §BAND-MERGE — `Types.BandCfg` moved to `Types.BandCfg` (shared). It was `LevCfg` minus the
    // asset, which this side then re-read from Aux on every use.

    /// @dev Current pool range + BTC fee accumulators, bundled into one memory
    ///      slot so the levered-band bodies stay off the legacy stack (avoids
    ///      stack-too-deep without via_ir; mirrors the "own frame" discipline).
    // §BAND-MERGE — `Types.BandP` moved to `Types.BandP` (shared with the ETH side).

    /// @dev syncLev's four signed deltas, returned as ONE struct (a single memory pointer) rather than
    ///      four stack-slot returns — keeps syncLev off the legacy-pipeline stack (no via_ir). The Vault
    ///      forwarder applies lpShares += addedNet - burnedNet and totalBuffer += bufAdded - bufBurned.
    struct LevDelta { uint addedNet; uint burnedNet; uint bufAdded; uint bufBurned; }

    /// @dev Scalar args for outOfRangeBtc, bundled into one memory slot to keep
    ///      the Vault forwarder + this body off the legacy stack.
    struct OorArgs {
        uint    amount;
        address token;
        int     distance;
        uint    range;
        address owner;    // msg.sender (preserved across delegatecall)
        uint spotPrice;
        uint curLo;
        uint curUp;
        uint    idBtc;    // current ID (value-type; new id returned)
    }

    /// @notice Body of Vault.outOfRangeBtc after _rebalance (which stays in the
    ///         Vault; its spotPrice/ticks arrive via `a`). Places a USD-funded
    ///         single-sided BTC boundary order; returns the new position id (the
    ///         forwarder writes it back to ID). Byte-identical.
    function outOfRangeBtc(
        Types.BandCfg memory c,
        mapping(uint => Types.SelfManaged) storage selfManaged,
        mapping(address => uint[]) storage positions,
        OorArgs memory a
    ) public returns (uint next) {
        if (a.token == address(0)) revert NotAStable();
        SwapLib.validateOorParams(a.range, a.distance);
        SwapLib.Oor memory t = SwapLib.oorBounds(a.spotPrice, a.range, a.distance, a.curLo, a.curUp);
        // Deposit the stable backing via AUX (pool-agnostic), normalize to 6-dec USD.
        uint amt = SwapLib.scaleTo6(IAux(c.aux).deposit(a.owner, a.token, a.amount), a.token);
        uint liquidity = SwapLib.sizeOorUsd(amt, t);
        // `liquidity` is still the sizer's own VALIDITY CHECK -- a range that can hold nothing
        // yields zero -- even though the POSITION is now stored as an amount.
        if (liquidity == 0) revert Dust();
        next = a.idBtc + 1;
        selfManaged[next] = Types.SelfManaged({
            created: block.number, owner: a.owner,
            // §E258 — `usdFunded: true` UNCONDITIONALLY, and that is not a shortcut: this path
            // opens with `if (a.token == address(0)) revert NotAStable()`, so a BTC boundary order
            // cannot be funded any other way. It is recorded rather than assumed because the field
            // is what `pull` needs in order to stop taking the payout side from its caller.
            // ⚠️ DELIBERATELY NOT INDEXED into `oorBook` — see `Vault.sweepOor` for why filling a
            // BTC order automatically would burn the leg it fills into.
            usdFunded: true,
            lower: t.newLo, upper: t.newUp, amt: int(amt) });   // §V4-CUT: the AMOUNT, not liquidity
        positions[a.owner].push(next);
        // `liquidity` is still computed and still gates on Dust -- it is the sizer's own validity
        // check (a range that can hold nothing yields zero) -- but the POSITION is the amount.
        ICore(c.core).outOfRange(a.owner, int(amt), t.newLo, t.newUp, address(0));
    }

    /// @notice Body of Vault.pullBtc — close/partially-reduce a self-managed BTC
    ///         boundary order. `owner` = msg.sender (preserved across delegatecall).
    ///         Byte-identical (same reverts, same swap-and-pop, same CORE call).

    /// @notice Full body of Vault.requestDeposit (prologue + rebalance moved here):
    ///         checkBacking + TWAP + repack self-call, then settle existing fees,
    ///         pair the in-range slice + track the out-of-range remainder as shares.
    ///         Returns the lpShares increase (deltaBTC + unpaired). Byte-identical.
    function requestDeposit(
        Types.BandCfg memory c,
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
        Types.BandP memory p;
        (p.spotPrice, p.loPrice, p.upPrice,,) = IBand(address(this)).repack();
        p.feesPerShare = IBand(address(this)).feesPerShare();
        p.usdFees = IBand(address(this)).USD_FEES();
        sharesAdded += settleBtcLp(LP, lpEth, address(0), quid, p.feesPerShare, p.usdFees, weight); // (E145) fee compounds into pooled
        // price computed AFTER the settle so it isn't live across it (legacy-pipeline stack). A price==0
        // revert here still rolls back the settle's state, so behavior is unchanged.
        uint price = IAux(c.aux).getTWAPforAsset(IAux(c.aux).WBTC(), 1800);
        if (price == 0) revert ZeroTwap();
        (uint deltaUSD, uint deltaBTC) = addLiqChannel(c.core, c.aux, sats, price);
        // In-range pairing extracted to its own frame (legacy-pipeline stack: the modLP call otherwise
        // overflows requestDeposit). Grows pooled + refreshes the bookmark at the post-pair GROSS weight.
        if (deltaBTC > 0) sharesAdded += _pairRegLeg(c.core, LP, p, weight, deltaBTC, deltaUSD, lpEth);
        uint unpaired = sats - deltaBTC;
        if (unpaired > 0) {
            // Out-of-range portion: backed by the channel sats (off-chain), tracked as share so it earns
            // fees and exits in full. Final GROSS weight = (old pooled + sats) + buf = weight + sats.
            LP.pooled += unpaired; sharesAdded += unpaired;
            SwapLib.refreshBookmarks(LP, weight + sats, p.feesPerShare, p.usdFees);
        }
    }

    /// @dev In-range channel-register leg in its own frame (legacy stack): pair `deltaBTC`, refresh the
    ///      bookmark at the post-pair GROSS weight (weight + deltaBTC), and modLP. Returns the shares added.
    function _pairRegLeg(
        address core, Types.Deposit storage LP, Types.BandP memory p,
        uint weight, uint deltaBTC, uint deltaUSD, address lpEth
    ) private returns (uint) {
        LP.pooled += deltaBTC;
        SwapLib.refreshBookmarks(LP, weight + deltaBTC, p.feesPerShare, p.usdFees);
        ICore(core).modLP(-int256(deltaBTC), -int256(deltaUSD), lpEth);   // ENTERS ⇒ negative
        return deltaBTC;
    }

    /// @notice Full body of Vault.syncLev (skip-check + rebalance moved here):
    ///         reconcile band CAPACITY to the manager's GROSS target; skip when both
    ///         the gross depth AND the buffer-USD target are already in sync. On work,
    ///         repack (self-call), then settle fees + FULL-RESYNC the slice to GROSS
    ///         (net + debt-funded buffer) as two legs — the net leg pairs basket-surplus
    ///         USD, the buffer leg pairs its OWN debt (folded into POOLED_USD, excluded from committed via
    ///         committedUsd18's live-debt subtraction). Mirrors ETH.
    ///         Returns the signed lpShares change split as (added, burned).
    function syncLev(
        Types.BandCfg memory c,
        Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, address mgr, address quid
    ) public returns (LevDelta memory d) {
        // NET model (mirror of Quid): levPooled is the NET leg (in pooled/lpShares); levBuf is the
        // debt-funded buffer (fee weight only). Live gross depth = their sum.
        uint gross = mgr == address(0) ? 0 : ILevEquity(mgr).grossCollateral(lp);
        if (gross == levPooled[lp] + levBuf[lp] &&
            levBufferUsd[lp] == (mgr == address(0) ? 0 : ILevEquity(mgr).debtUsd(lp) / 1e12)) return d;
        // Precompute the GROSS fee weight while the stack is still empty (before p) so the 8-arg settle call
        // below doesn't compute pooled+levBuf inline at its peak. Build p field-by-field (NOT a struct
        // literal) so external-call temporaries free between assignments — both keep this off the legacy stack.
        uint w = LP.pooled + levBuf[lp];
        Types.BandP memory p;
        (p.spotPrice, p.loPrice, p.upPrice,,) = IBand(address(this)).repack();
        p.feesPerShare = IBand(address(this)).feesPerShare();
        p.usdFees = IBand(address(this)).USD_FEES();
        p.mgr = mgr; p.gross = gross;
        d.addedNet += settleBtcLp(LP, lp, address(0), quid, p.feesPerShare, p.usdFees, w); // (E145) fee compounds into pooled
        (d.burnedNet, d.bufBurned) = BandLib.levBurnAll(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
        (d.addedNet, d.bufAdded)   = BandLib.levAddGross(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
    }

    /// @dev Grow the full-2× BTC slice as two legs: net-equity (into pooled/lpShares) + the debt-funded
    ///      buffer (into levBuf/totalBuffer, NOT equity). Returns (addedNet, bufAdded). Per-leg frames.

    /// @dev NET-equity BTC leg — basket-surplus USD. Grows pooled/lpShares (equity) + levPooled (the
    ///      unwind-only net slice) + V4 depth.

    /// @dev modLP for the NET BTC leg in its own frame (legacy-pipeline stack: the 7-arg call otherwise
    ///      overflows levAddNetBtc). Net leg pairs basket surplus (no debt-funded buffer USD).

    /// @dev BUFFER BTC leg — the debt-funded half. Fee-earning V4 DEPTH but NOT equity: grows levBuf (fee
    ///      weight + totalBuffer via the return) and the V4 position, but NOT pooled/levPooled. USD =
    ///      buffer sats at price, CAPPED at the LP's debt (debt-backed; buffer USD folds into POOLED_USD).

    /// @dev modLP for the BUFFER BTC leg in its own frame (legacy stack). Buffer USD folds into POOLED_USD.

    // ════════════════════════════════════════════════════════════════════
    //  vBTC BAND BODIES (BTC-lev collateral). The ERC-20 face that used to
    //  live here moved to `VBtc.sol` (§J.2) along with the Vault's supply
    //  slots, so `vbtcTransfer`/`vbtcTransferFrom` are GONE — VBtc owns its
    //  own balances and does not need a delegatecall'd body. What remains is
    //  band accounting ONLY: the funded↔lev reclassification. DELEGATECALL'd,
    //  so the passed-by-STORAGE-REF mappings are the Vault's real slots.
    //  vBTC is sats-denominated (8-dec); supply moves only via the SAME-BTC
    //  expose/unexpose path, gated to the LevManager in the Vault forwarder.
    // ════════════════════════════════════════════════════════════════════

    /// @notice Body of Vault.exposeBtcToLev — reclassify `sats` of the LP's FREE channel band BTC as the levered
    ///         slice (funded→lev; LP.pooled untouched, single-count). The matching vBTC SUPPLY mutation is the
    ///         token's own (`VBtc.mintTo`, called by the Vault forwarder right after this) — this body owns band
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

    /// @notice Body of Vault.unexposeBtcFromLev — convert the LP's levered slice back to FREE channel band depth
    ///         (lev→funded; LP.pooled untouched). The burn is the token's own (`VBtc.burnFrom`), and the Vault
    ///         forwarder runs it BEFORE this so an under-funded manager reverts without the band having moved.
    function vbtcUnexposeBody(
        mapping(address => uint) storage levPooled,
        address lp, uint sats
    ) public {
        uint lev = levPooled[lp];
        levPooled[lp] = sats >= lev ? 0 : lev - sats;      // lev → funded; LP.pooled untouched
    }

    /// @dev rebalanceBody output — the 5 caller returns + the 3 value-type storage slots the forwarder writes
    ///      back (feesPerShare, USD_FEES, reseatEpochBTC). One memory pointer keeps the frame off the
    ///      legacy stack (no via_ir).
    struct RebalOut {
        uint spotPrice; uint    loPrice; uint    upPrice; uint myLiquidity; uint resolvedTwap;
        uint feesPerShare; uint usdFees;
    }

    /// @notice Body of Vault._rebalance (BTC side) — VERBATIM relocation (SwapLib.rebalanceCore + the repack/JIT
    ///         fee distribution + reseat-epoch bump + tick writeback). `feeDenom` = lpShares + totalBuffer
    ///         (the GROSS fee weight, read by the forwarder at the SAME point — rebalanceCore does not touch it).
    ///         The former `_distributeV4Fees` (its ONLY caller was here) is folded in: both branches just add
    ///         `SwapLib.feeIncrements(fees, usd, feeDenom)` to the accumulators (the dead `bool` arg dropped). The
    ///         forwarder writes back feesPerShare/USD_FEES/reseatEpochBTC/LOWER_TICK_BTC/UPPER_TICK_BTC.
    function rebalanceBody(
        Types.BandCfg memory c, uint loPrice, uint upPrice,
        uint feesPerShare, uint usdFees, uint feeDenom
    ) public returns (RebalOut memory o) {
        // BTC has no vault yield to sync (no WBTC supply); skip _syncYield.
        SwapLib.Rebalanced memory r = SwapLib.rebalanceCore(
            c.core, c.aux, IAux(c.aux).WBTC(), upPrice, loPrice);
        o.feesPerShare = feesPerShare; o.usdFees = usdFees;
        if (r.didRepack) {
            // §DE-TICK: `repack`/`reseat` return zero fee legs (v4 collects nothing), so this
            // reordered two zeros. Canonical (USD, tok) taken directly -- see QuidLib's note.
            uint feesTok = r.fees1;
            uint feesUsd = r.fees0;
            (uint tokInc, uint usdInc) = SwapLib.feeIncrements(feesTok, feesUsd, feeDenom);
            o.feesPerShare += tokInc; o.usdFees += usdInc;
        } else if (r.jitFees) {
            // collectFees returns canonical (feesUSD, feesTok) — USD first.
            (uint tokInc, uint usdInc) = SwapLib.feeIncrements(r.jitFeesTok, r.jitFeesUsd, feeDenom);
            o.feesPerShare += tokInc; o.usdFees += usdInc;
        }
        o.spotPrice = r.spotPrice; o.loPrice = r.loPrice; o.upPrice = r.upPrice;
        o.myLiquidity = r.myLiquidity; o.resolvedTwap = r.resolvedTwap;
    }

    /// @notice Body of Vault._levBurnBTC — shrink the levered slice by up to `rem`
    ///         sats (burn band depth without delivery). Returns the sats actually
    ///         burned, subtracted from lpShares by the forwarder. Byte-identical.
    /// @dev Burn the ENTIRE full-2× BTC slice tokenlessly (no delivery — equity sits on the venue). The buffer
    ///      USD (`levBufferUsd`) un-pairs from POOLED_USD as part of the gross burn,
    ///      the net-leg USD from the
    ///      basket bucket — so a venue liquidation leaves the basket intact. Full-resync burn.

    /// @dev modLP burn (no delivery) for a levered BTC slice in its own frame (legacy stack). Recipient is
    ///      address(0) (tokenless burn); buffer USD un-pairs from POOLED_USD as part of the gross burn.


    // ═════════ §FOLD-BOOK — WAS `LevBookLib`'s VENUE LEGS ═════════
    // Split by CALLER, which is also the semantic split: every one is reached only from
    // `BtcLevManager`.


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
    // ⚠️ `_syncBand` IS NOT CALLED FROM HERE. It try/catches a call to `BAND` and returning a flag for
    // the caller to act on would be the same code in a worse place, so the WRAPPER pokes the band
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
