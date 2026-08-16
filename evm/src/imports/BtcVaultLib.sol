// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SwapLib} from "./SwapLib.sol";
import {Types} from "./Types.sol";
import {LevMath} from "./LevMath.sol";
import {ICore} from "./Interfaces.sol";
import {IBandManager} from "./Interfaces.sol";
import {IBasketMint} from "./Interfaces.sol";
import {ILevEquityBtc} from "./Interfaces.sol";
import {IEthVenue} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";

// External surfaces used below all come from Interfaces.sol now (§A.52):
//   • ILevEquityBtc — BtcLevManager's per-LP book (was `ILevBtc_V`, a 3-of-4 subset).
//   • IEthVenue     — the Vault's own surface, reached by self-call because these bodies are
//                      DELEGATECALL'd (address(this)==Vault) and the value-type fee accumulators
//                      can't be handed over as storage refs (was `IVaultCtx_V`).
//   • IAux      — the Aux surface (was `IAuxBtc_V` + `IAuxDeposits_V`, both strict subsets;
//                      IAuxDeposits_V's lone `get_deposits` is byte-identical to IAux's).
// The Basket mint callback stays local: `mint` is Basket's only member any consumer in this
// subtree needs, and it is declared exactly once tree-wide, so there is nothing to dedup.
/// @title  BtcVaultLib — the BTC band / leverage / channel accounting extracted from VaultLib
///         (now purely the ETH venue custody ladder) for EIP-170 headroom. DELEGATECALL'd by the
///         Vault exactly as the BTC bodies were when they lived in VaultLib: `address(this)`==Vault,
///         so all storage/custody are the Vault's. Byte-identical to the former in-VaultLib BTC
///         bodies -- only the home moved. Pairs with VogueLib (the ETH band's mirror).
library BtcVaultLib {

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
        address lpEth, address payTo, address quid,
        uint feesPerShareBTC, uint usdFeesBtc, uint weight
    ) public returns (uint compoundedSats) {
        // `weight` is the GROSS fee depth: net pooled + the debt-funded levered buffer (levBufBTC).
        if (weight == 0) return 0;
        (uint tokR, uint usdR) = SwapLib.pendingFor(LP, weight, feesPerShareBTC, usdFeesBtc);
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
        SwapLib.refreshBookmarks(LP, weight, feesPerShareBTC, usdFeesBtc);
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
    ///         risk-budget clamp the ETH band applies (VogueLib.addLiq). Only the
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
        // targetUSD scales linearly with deltaTok (= deltaTok*price/WAD), so rescale by the clamp ratio.
        if (capped < deltaTok) { targetUSD = targetUSD * capped / deltaTok; deltaTok = capped; }
        usdOut = targetUSD / 1e12;
        if (usdOut == 0) return (0, 0);
        outDelta = deltaTok;
    }

    /// @dev BTC band theta clamp in its OWN frame (legacy-pipeline stack). Caps the paired depth at
    ///      `theta * backing` -- the live yield/(K*sigma^2) throttle over the BTC band's own ticks +
    ///      variance ring (Vault.derivedThetaWadBtc asks Vogue). Fails OPEN (theta>=1e18 -> no-op),
    ///      including when yield is unmeasured (theta 0 -> 1e18), matching ETH's _liveTheta. `available`
    ///      base is the full `deltaTok` (locked backing skips the physical clamp); only theta bites here.
    ///      BACKING = `Core.btcThetaBacking()` (aggregate locked sats lpSharesBTC + gross buffer -- the ONE
    ///      source of truth shared with the reseat clamp in VogueLib.addLiq, so a repack can't re-throttle
    ///      the band this add just built) + THIS add's `sats` (registerBtcLp/levAddBtc credit lpSharesBTC
    ///      only AFTER this clamp -- unlike ETH, where _depositETH bumps vogueETH BEFORE addLiq; add it here
    ///      for parity + first-deposit bootstrap). NOT vogueBTC: that is a disjoint WBTC-donation pool,
    ///      structurally unrelated to the band's risk capital -- basing theta on it throttled the band to ~0
    ///      whenever donations were thin (the opposite of what scarcity should do).
    function _thetaClampBtc(address core, uint deltaTok, uint sats) private view returns (uint) {
        uint thetaEff = IBandManager(address(this)).derivedThetaWadBtc();
        if (thetaEff == 0) thetaEff = 1e18;
        // ONE principle (SwapLib.clampByBacking): bound by both the physical backing headroom AND theta —
        // shared verbatim with the reseat clamp (VogueLib.addLiq) and the ETH band. backing = the native
        // capital (Core.btcThetaBacking = lpSharesBTC + gross buffer) + THIS add's `sats` (not yet credited
        // to lpSharesBTC at clamp time — see the long note above).
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
        uint    lev;            // levPooledBTC[lpEth] at entry (NET levered slice, in pooled)
        uint    buf;            // levBufBTC[lpEth] at entry (debt-funded buffer, NOT in pooled)
        uint sqrtP;
        uint    tickLower;
        uint    tickUpper;
        uint    feesPerShareBTC;
        uint    usdFeesBtc;
    }

    /// @dev resizeBtcLp/resizeBtcLpTail output as ONE struct (single memory pointer) rather than four
    ///      stack-slot returns — keeps both off the legacy-pipeline stack (no via_ir). The Vault forwarder
    ///      applies lpSharesBTC -= sharesRemoved, totalBufferBTC -= bufRemoved, and on `cleared` emits owed.
    /// @dev `feeCompounded` (E145): sats the BTC fee leg compounded into `LP.pooled` during
    ///      this resize. The forwarder must ADD it to `lpSharesBTC` alongside subtracting
    ///      `sharesRemoved`, or the sum drifts from the positions it totals.
    struct ResizeOut { uint sharesRemoved; bool cleared; uint owed; uint bufRemoved; uint feeCompounded; }

    /// @notice Body of Vault._resizeBtcLp AFTER the funded/lev prologue + _rebalance
    ///         (both stay in the Vault). Settles fees, pays the swap-out proceeds,
    ///         burns the native (+ full-close lev) band depth, decrements the
    ///         position and finalizes. Returns (sharesRemoved, cleared, owed): the
    ///         forwarder applies `lpSharesBTC -= sharesRemoved`, and on `cleared`
    ///         FORGOES the residual `owed` to the pool (dust; the sats are already in
    ///         POOLED, so deleting the owed-ledger here donates them — emits
    ///         BtcLpFeesForgone for monitoring) + zeros the accumulators if it was the last LP.
    function resizeBtcLpTail(
        address core, address quid,
        mapping(address => Types.Deposit) storage autoManagedBTC,
        mapping(address => uint) storage levPooledBTC,
        mapping(address => uint) storage levBufBTC,
        ResizeArgs memory a
    ) public returns (ResizeOut memory o) {
        Types.Deposit storage LP = autoManagedBTC[a.lpEth];
        {   // settlement + native burn scoped so its locals free before the tail
            // GROSS fee weight = net pooled + the debt-funded buffer (levBufBTC).
            o.feeCompounded = settleBtcLp(LP, a.lpEth, a.lpEth, quid, a.feesPerShareBTC, a.usdFeesBtc, LP.pooled + a.buf); // (E145)
            uint deliveredRaw = a.shrinkSats > a.lpPayoutSats ? a.shrinkSats - a.lpPayoutSats : 0;
            uint deliveredSlice = settleDelivered(a.lpEth, deliveredRaw, a.exactUsd, core, quid);
            uint nativeSlice = a.shrinkSats - deliveredSlice;
            SwapLib.burnInRange(core, true, a.sqrtP, nativeSlice, a.tickLower, a.tickUpper, address(0));
            // Full channel close burns BOTH levered legs' V4 depth: the net slice (a.lev) and the
            // debt-funded buffer (a.buf). The buffer leaves totalBufferBTC via the bufRemoved return.
            if (a.full && a.lev > 0)
                SwapLib.burnInRange(core, true, a.sqrtP, a.lev, a.tickLower, a.tickUpper, address(0));
            if (a.full && a.buf > 0) {
                SwapLib.burnInRange(core, true, a.sqrtP, a.buf, a.tickLower, a.tickUpper, address(0));
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
        if (a.full) { levPooledBTC[a.lpEth] = 0; levBufBTC[a.lpEth] = 0; }
        // Finalize: full exit publishes/clears the owed BTC-leg fee + retires the
        // slot; a partial splice rebaselines the remainder's fee bookmarks.
        if (LP.pooled == 0) {
            delete autoManagedBTC[a.lpEth];       // retire the slot
            o.cleared = true;
        } else {
            // Partial splice leaves the buffer intact (levBufBTC unchanged): gross weight = pooled + a.buf.
            SwapLib.refreshBookmarks(LP, LP.pooled + a.buf, a.feesPerShareBTC, a.usdFeesBtc);
        }
    }

    /// @notice Full body of Vault._resizeBtcLp: the funded/lev prologue + clamp +
    ///         early-returns + repack (self-call) + tail. `full` = whole-channel close
    ///         (shrinkSats := funded); else a partial splice-out. Returns
    ///         (sharesRemoved, cleared, owed) — the forwarder applies
    ///         `lpSharesBTC -= sharesRemoved` and on `cleared` emits + resets. The
    ///         guards run BEFORE repack (no rebalance when there's nothing to do),
    ///         preserving the former in-Vault ordering exactly.
    function resizeBtcLp(
        address core, address quid,
        mapping(address => Types.Deposit) storage autoManagedBTC,
        mapping(address => uint) storage levPooledBTC,
        mapping(address => uint) storage levBufBTC,
        address lpEth, uint shrinkSats, uint lpPayoutSats, bool full, uint exactUsd
    ) public returns (ResizeOut memory o) {
        // Route everything through the ResizeArgs memory slot so the input scalars go
        // dead early (keeps this frame off the legacy stack — no via_ir). `funded` is
        // the only extra local.
        ResizeArgs memory a;
        a.lpEth = lpEth; a.lpPayoutSats = lpPayoutSats; a.full = full; a.exactUsd = exactUsd;
        a.inrange = autoManagedBTC[lpEth].pooled;  // in-range share (channel funding + NET levered slice)
        a.lev = levPooledBTC[lpEth];               // NET levered slice (in pooled)
        a.buf = levBufBTC[lpEth];                  // debt-funded buffer (NOT in pooled)
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
        (a.sqrtP, a.tickLower, a.tickUpper,,) = IBandManager(address(this)).repack(true);
        a.feesPerShareBTC = IBandManager(address(this)).feesPerShareBTC();
        a.usdFeesBtc = IBandManager(address(this)).USD_FEES_BTC();
        return resizeBtcLpTail(core, quid, autoManagedBTC, levPooledBTC, levBufBTC, a);
    }

    // ════════════════════════════════════════════════════════════════════
    //  BTC IL-PROTECT: levered band slice. Bodies of Vault._levAddBTC /
    //  _levBurnBTC extracted to free bytecode. Reference-type state (the LP
    //  Deposit + levPooledBTC mapping) is passed by STORAGE REF so the library
    //  writes the Vault's slots via delegatecall; the value-type lpSharesBTC is
    //  mutated by RETURNING the delta (added/burned), which the thin Vault
    //  forwarder applies (`lpSharesBTC += levAddBtc(...)` / `-= levBurnBtc(...)`).
    // ════════════════════════════════════════════════════════════════════

    /// @dev Vault's BTC-side immutables the levered-band bodies touch.
    struct BtcCfg {
        address core;
        address aux;
    }

    /// @dev Current pool range + BTC fee accumulators, bundled into one memory
    ///      slot so the levered-band bodies stay off the legacy stack (avoids
    ///      stack-too-deep without via_ir; mirrors the "own frame" discipline).
    struct LevParams {
        uint sqrtP;
        uint    tickLower;
        uint    tickUpper;
        uint    feesPerShareBTC;
        uint    usdFeesBtc;
        address mgr;      // full-2×: BtcLevManager (net-equity/debt reads for the two-leg split)
        uint    gross;    // full-2×: GROSS collateral target (sats) = net-equity + the debt-funded buffer
    }

    /// @dev syncLevBTC's four signed deltas, returned as ONE struct (a single memory pointer) rather than
    ///      four stack-slot returns — keeps syncLevBTC off the legacy-pipeline stack (no via_ir). The Vault
    ///      forwarder applies lpSharesBTC += addedNet - burnedNet and totalBufferBTC += bufAdded - bufBurned.
    struct LevDelta { uint addedNet; uint burnedNet; uint bufAdded; uint bufBurned; }

    /// @dev Scalar args for outOfRangeBtc, bundled into one memory slot to keep
    ///      the Vault forwarder + this body off the legacy stack.
    struct OorArgs {
        uint    amount;
        address token;
        int     distance;
        uint    range;
        address owner;    // msg.sender (preserved across delegatecall)
        uint sqrtP;
        uint curLo;
        uint curUp;
        uint    idBtc;    // current ID_BTC (value-type; new id returned)
    }

    /// @notice Body of Vault.outOfRangeBtc after _rebalance (which stays in the
    ///         Vault; its sqrtP/ticks arrive via `a`). Places a USD-funded
    ///         single-sided BTC boundary order; returns the new position id (the
    ///         forwarder writes it back to ID_BTC). Byte-identical.
    function outOfRangeBtc(
        BtcCfg memory c,
        mapping(uint => Types.SelfManaged) storage selfManagedBtc,
        mapping(address => uint[]) storage positionsBtc,
        OorArgs memory a
    ) public returns (uint next) {
        if (a.token == address(0)) revert NotAStable();
        SwapLib.validateOorParams(a.range, a.distance);
        bool t1 = ICore(c.core).token1isVol();
        SwapLib.Oor memory t = SwapLib.oorBounds(a.sqrtP, a.range, a.distance, t1, a.curLo, a.curUp);
        // Deposit the stable backing via AUX (pool-agnostic), normalize to 6-dec USD.
        uint amt = SwapLib.scaleTo6(IAux(c.aux).deposit(a.owner, a.token, a.amount), a.token);
        uint liquidity = SwapLib.sizeOorUsd(amt, t, t1);
        // `liquidity` is still the sizer's own VALIDITY CHECK -- a range that can hold nothing
        // yields zero -- even though the POSITION is now stored as an amount.
        if (liquidity == 0) revert Dust();
        next = a.idBtc + 1;
        selfManagedBtc[next] = Types.SelfManaged({
            created: block.number, owner: a.owner,
            lower: t.newLo, upper: t.newUp, amt: int(amt) });   // §V4-CUT: the AMOUNT, not liquidity
        positionsBtc[a.owner].push(next);
        // `liquidity` is still computed and still gates on Dust -- it is the sizer's own validity
        // check (a range that can hold nothing yields zero) -- but the POSITION is the amount.
        ICore(c.core).outOfRange(a.owner, int(amt), t.newLo, t.newUp, address(0));
    }

    /// @notice Body of Vault.pullBtc — close/partially-reduce a self-managed BTC
    ///         boundary order. `owner` = msg.sender (preserved across delegatecall).
    ///         Byte-identical (same reverts, same swap-and-pop, same CORE call).
    function pullBtc(
        address core,
        mapping(uint => Types.SelfManaged) storage selfManagedBtc,
        mapping(address => uint[]) storage positionsBtc,
        uint id, int percent, address token, address owner
    ) public {
        Types.SelfManaged storage position = selfManagedBtc[id];
        if (position.owner != owner) revert NotOwner();
        require(block.number >= position.created + 47, "too soon");
        if (percent == 0 || percent > 100) revert BadPercent();
        int closed = position.amt * percent / 100;
        if (closed == 0) revert Dust();
        uint lower = position.lower;
        uint upper = position.upper;
        uint[] storage myIds = positionsBtc[owner];
        uint lastIndex = myIds.length > 0 ? myIds.length - 1 : 0;
        if (percent == 100) {
            delete selfManagedBtc[id];
            for (uint i = 0; i <= lastIndex; i++) {
                if (myIds[i] == id) {
                    if (i < lastIndex) myIds[i] = myIds[lastIndex];
                    myIds.pop(); break;
                }
            }
        } else {
            position.amt -= closed;
            if (position.amt == 0) revert Dust();
        }
        ICore(core).outOfRange(owner, -closed, lower, upper, token);
    }

    /// @notice Full body of Vault.registerBtcLp (prologue + rebalance moved here):
    ///         checkBacking + TWAP + repack self-call, then settle existing fees,
    ///         pair the in-range slice + track the out-of-range remainder as shares.
    ///         Returns the lpSharesBTC increase (deltaBTC + unpaired). Byte-identical.
    function registerBtcLp(
        BtcCfg memory c,
        Types.Deposit storage LP,
        address lpEth, uint sats, address quid, uint weight
    ) public returns (uint sharesAdded) {
        // `weight` = pooled + levBufBTC[lpEth] (the GROSS fee weight at entry, precomputed by the forwarder to
        // keep this frame off the legacy stack). Channel register grows only `pooled` (net) by deltaBTC, so the
        // post-pair weight is `weight + deltaBTC`; the buffer is constant through a register.
        if (sats == 0 || lpEth == address(0)) return 0;
        IAux(c.aux).checkBacking();
        // Bundle the pool range + fresh fee accumulators into one memory slot so this
        // frame stays off the legacy stack (no via_ir). _rebalance (via repack) already
        // accrued any V4 fees into the accumulators; read them fresh.
        LevParams memory p;
        (p.sqrtP, p.tickLower, p.tickUpper,,) = IBandManager(address(this)).repack(true);
        p.feesPerShareBTC = IBandManager(address(this)).feesPerShareBTC();
        p.usdFeesBtc = IBandManager(address(this)).USD_FEES_BTC();
        sharesAdded += settleBtcLp(LP, lpEth, address(0), quid, p.feesPerShareBTC, p.usdFeesBtc, weight); // (E145) fee compounds into pooled
        // price computed AFTER the settle so it isn't live across it (legacy-pipeline stack). A price==0
        // revert here still rolls back the settle's state, so behavior is unchanged.
        uint price = IAux(c.aux).getTWAPforAsset(IAux(c.aux).WBTC(), 1800);
        if (price == 0) revert ZeroTwap();
        (uint deltaUSD, uint deltaBTC) = addLiqChannel(c.core, c.aux, sats, price);
        // In-range pairing extracted to its own frame (legacy-pipeline stack: the modLP call otherwise
        // overflows registerBtcLp). Grows pooled + refreshes the bookmark at the post-pair GROSS weight.
        if (deltaBTC > 0) sharesAdded += _pairRegLeg(c.core, LP, p, weight, deltaBTC, deltaUSD, lpEth);
        uint unpaired = sats - deltaBTC;
        if (unpaired > 0) {
            // Out-of-range portion: backed by the channel sats (off-chain), tracked as share so it earns
            // fees and exits in full. Final GROSS weight = (old pooled + sats) + buf = weight + sats.
            LP.pooled += unpaired; sharesAdded += unpaired;
            SwapLib.refreshBookmarks(LP, weight + sats, p.feesPerShareBTC, p.usdFeesBtc);
        }
    }

    /// @dev In-range channel-register leg in its own frame (legacy stack): pair `deltaBTC`, refresh the
    ///      bookmark at the post-pair GROSS weight (weight + deltaBTC), and modLP. Returns the shares added.
    function _pairRegLeg(
        address core, Types.Deposit storage LP, LevParams memory p,
        uint weight, uint deltaBTC, uint deltaUSD, address lpEth
    ) private returns (uint) {
        LP.pooled += deltaBTC;
        SwapLib.refreshBookmarks(LP, weight + deltaBTC, p.feesPerShareBTC, p.usdFeesBtc);
        ICore(core).modLP(deltaBTC, deltaUSD, lpEth);
        return deltaBTC;
    }

    /// @notice Full body of Vault.syncLevBTC (skip-check + rebalance moved here):
    ///         reconcile band CAPACITY to the manager's GROSS target; skip when both
    ///         the gross depth AND the buffer-USD target are already in sync. On work,
    ///         repack (self-call), then settle fees + FULL-RESYNC the slice to GROSS
    ///         (net + debt-funded buffer) as two legs — the net leg pairs basket-surplus
    ///         USD, the buffer leg pairs its OWN debt (folded into POOLED_USD, excluded from committed via
    ///         committedUsd18's live-debt subtraction). Mirrors ETH.
    ///         Returns the signed lpSharesBTC change split as (added, burned).
    function syncLevBTC(
        BtcCfg memory c,
        Types.Deposit storage LP,
        mapping(address => uint) storage levPooledBTC,
        mapping(address => uint) storage levBufferUsdBTC,
        mapping(address => uint) storage levBufBTC,
        address lp, address mgr, address quid
    ) public returns (LevDelta memory d) {
        // NET model (mirror of Vogue): levPooledBTC is the NET leg (in pooled/lpSharesBTC); levBufBTC is the
        // debt-funded buffer (fee weight only). Live gross depth = their sum.
        uint gross = mgr == address(0) ? 0 : ILevEquityBtc(mgr).grossCollateralBtc(lp);
        if (gross == levPooledBTC[lp] + levBufBTC[lp] &&
            levBufferUsdBTC[lp] == (mgr == address(0) ? 0 : ILevEquityBtc(mgr).debtUsd(lp) / 1e12)) return d;
        // Precompute the GROSS fee weight while the stack is still empty (before p) so the 8-arg settle call
        // below doesn't compute pooled+levBufBTC inline at its peak. Build p field-by-field (NOT a struct
        // literal) so external-call temporaries free between assignments — both keep this off the legacy stack.
        uint w = LP.pooled + levBufBTC[lp];
        LevParams memory p;
        (p.sqrtP, p.tickLower, p.tickUpper,,) = IBandManager(address(this)).repack(true);
        p.feesPerShareBTC = IBandManager(address(this)).feesPerShareBTC();
        p.usdFeesBtc = IBandManager(address(this)).USD_FEES_BTC();
        p.mgr = mgr; p.gross = gross;
        d.addedNet += settleBtcLp(LP, lp, address(0), quid, p.feesPerShareBTC, p.usdFeesBtc, w); // (E145) fee compounds into pooled
        (d.burnedNet, d.bufBurned) = levBurnAllBtc(c, LP, levPooledBTC, levBufferUsdBTC, levBufBTC, lp, p);
        (d.addedNet, d.bufAdded)   = levAddGrossBtc(c, LP, levPooledBTC, levBufferUsdBTC, levBufBTC, lp, p);
    }

    /// @dev Grow the full-2× BTC slice as two legs: net-equity (into pooled/lpSharesBTC) + the debt-funded
    ///      buffer (into levBufBTC/totalBufferBTC, NOT equity). Returns (addedNet, bufAdded). Per-leg frames.
    function levAddGrossBtc(
        BtcCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooledBTC,
        mapping(address => uint) storage levBufferUsdBTC,
        mapping(address => uint) storage levBufBTC,
        address lp, LevParams memory p
    ) public returns (uint addedNet, uint bufAdded) {
        if (p.gross == 0) return (0, 0);
        uint netEq = ILevEquityBtc(p.mgr).netEquity(lp);
        addedNet = levAddNetBtc(c, LP, levPooledBTC, levBufBTC, lp, netEq, p);
        if (p.gross > netEq) bufAdded = levAddBufBtc(c, LP, levBufferUsdBTC, levBufBTC, lp, p.gross - netEq, p);
    }

    /// @dev NET-equity BTC leg — basket-surplus USD. Grows pooled/lpSharesBTC (equity) + levPooledBTC (the
    ///      unwind-only net slice) + V4 depth.
    function levAddNetBtc(
        BtcCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooledBTC,
        mapping(address => uint) storage levBufBTC,
        address lp, uint netEq, LevParams memory p
    ) public returns (uint added) {
        if (netEq == 0) return 0;
        uint price = IAux(c.aux).getTWAPforAsset(IAux(c.aux).WBTC(), 1800);
        if (price == 0) return 0;
        (uint deltaUSD, uint deltaBTC) = addLiqChannel(c.core, c.aux, netEq, price);
        if (deltaBTC == 0) return 0;
        LP.pooled += deltaBTC; levPooledBTC[lp] += deltaBTC;
        SwapLib.refreshBookmarks(LP, LP.pooled + levBufBTC[lp], p.feesPerShareBTC, p.usdFeesBtc);
        _modLpNetBtc(c.core, p, deltaBTC, deltaUSD, lp);   // extracted (legacy stack)
        return deltaBTC;
    }

    /// @dev modLP for the NET BTC leg in its own frame (legacy-pipeline stack: the 7-arg call otherwise
    ///      overflows levAddNetBtc). Net leg pairs basket surplus (no debt-funded buffer USD).
    function _modLpNetBtc(address core, LevParams memory p, uint deltaBTC, uint deltaUSD, address lp) private {
        ICore(core).modLP(deltaBTC, deltaUSD, lp);
    }

    /// @dev BUFFER BTC leg — the debt-funded half. Fee-earning V4 DEPTH but NOT equity: grows levBufBTC (fee
    ///      weight + totalBufferBTC via the return) and the V4 position, but NOT pooled/levPooledBTC. USD =
    ///      buffer sats at price, CAPPED at the LP's debt (debt-backed; buffer USD folds into POOLED_USD).
    function levAddBufBtc(
        BtcCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levBufferUsdBTC,
        mapping(address => uint) storage levBufBTC,
        address lp, uint bufSats, LevParams memory p
    ) public returns (uint added) {
        uint bufUsd = _bufUsdBtc(c.aux, bufSats, p.mgr, lp);
        if (bufUsd == 0) return 0;
        levBufBTC[lp] += bufSats; levBufferUsdBTC[lp] += bufUsd;   // depth + fee weight, NOT equity
        SwapLib.refreshBookmarks(LP, LP.pooled + levBufBTC[lp], p.feesPerShareBTC, p.usdFeesBtc);
        _modLpBufBtc(c.core, p, bufSats, bufUsd, lp);   // extracted (legacy stack); buffer USD folds into POOLED_USD
        return bufSats;
    }

    /// @dev modLP for the BUFFER BTC leg in its own frame (legacy stack). Buffer USD folds into POOLED_USD.
    function _modLpBufBtc(address core, LevParams memory p, uint bufSats, uint bufUsd, address lp) private {
        ICore(core).modLP(bufSats, bufUsd, lp);
    }
    function _bufUsdBtc(address aux, uint bufSats, address mgr, address lp) private view returns (uint bufUsd) {
        uint price = IAux(aux).getTWAPforAsset(IAux(aux).WBTC(), 1800);
        if (price == 0) return 0;
        bufUsd = LevMath.capBufferUsd(bufSats, price, ILevEquityBtc(mgr).debtUsd(lp));
    }

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
        mapping(address => Types.Deposit) storage autoManagedBTC,
        mapping(address => uint) storage levPooledBTC,
        address lp, uint sats
    ) public {
        uint pooled = autoManagedBTC[lp].pooled;
        uint free = SwapLib.plainNet(pooled, levPooledBTC[lp]);
        if (sats == 0 || sats > free) revert InsufficientChannelBtc();
        levPooledBTC[lp] += sats;                            // funded → lev; LP.pooled untouched (single-count)
    }

    /// @notice Body of Vault.unexposeBtcFromLev — convert the LP's levered slice back to FREE channel band depth
    ///         (lev→funded; LP.pooled untouched). The burn is the token's own (`VBtc.burnFrom`), and the Vault
    ///         forwarder runs it BEFORE this so an under-funded manager reverts without the band having moved.
    function vbtcUnexposeBody(
        mapping(address => uint) storage levPooledBTC,
        address lp, uint sats
    ) public {
        uint lev = levPooledBTC[lp];
        levPooledBTC[lp] = sats >= lev ? 0 : lev - sats;      // lev → funded; LP.pooled untouched
    }

    /// @dev rebalanceBody output — the 5 caller returns + the 3 value-type storage slots the forwarder writes
    ///      back (feesPerShareBTC, USD_FEES_BTC, reseatEpochBTC). One memory pointer keeps the frame off the
    ///      legacy stack (no via_ir).
    struct RebalOut {
        uint sqrtPriceX96; uint    tickLower; uint    tickUpper; uint myLiquidity; uint resolvedTwap;
        uint feesPerShareBTC; uint usdFeesBtc;
    }

    /// @notice Body of Vault._rebalance (BTC side) — VERBATIM relocation (SwapLib.rebalanceCore + the repack/JIT
    ///         fee distribution + reseat-epoch bump + tick writeback). `feeDenom` = lpSharesBTC + totalBufferBTC
    ///         (the GROSS fee weight, read by the forwarder at the SAME point — rebalanceCore does not touch it).
    ///         The former `_distributeV4Fees` (its ONLY caller was here) is folded in: both branches just add
    ///         `SwapLib.feeIncrements(fees, usd, feeDenom)` to the accumulators (the dead `bool` arg dropped). The
    ///         forwarder writes back feesPerShareBTC/USD_FEES_BTC/reseatEpochBTC/LOWER_TICK_BTC/UPPER_TICK_BTC.
    function rebalanceBody(
        BtcCfg memory c, bool isBTC, uint lowerTick, uint upperTick,
        uint feesPerShareBTC, uint usdFeesBtc, uint feeDenom
    ) public returns (RebalOut memory o) {
        // BTC has no vault yield to sync (no WBTC supply); skip _syncYield.
        SwapLib.Rebalanced memory r = SwapLib.rebalanceCore(
            c.core, c.aux, IAux(c.aux).WBTC(), isBTC, upperTick, lowerTick);
        o.feesPerShareBTC = feesPerShareBTC; o.usdFeesBtc = usdFeesBtc;
        if (r.didRepack) {
            bool t1 = ICore(c.core).token1isVol();
            uint feesTok = t1 ? r.fees1 : r.fees0;
            uint feesUsd = t1 ? r.fees0 : r.fees1;
            (uint tokInc, uint usdInc) = SwapLib.feeIncrements(feesTok, feesUsd, feeDenom);
            o.feesPerShareBTC += tokInc; o.usdFeesBtc += usdInc;
        } else if (r.jitFees) {
            // collectFees returns canonical (feesUSD, feesTok) — USD first.
            (uint tokInc, uint usdInc) = SwapLib.feeIncrements(r.jitFeesTok, r.jitFeesUsd, feeDenom);
            o.feesPerShareBTC += tokInc; o.usdFeesBtc += usdInc;
        }
        o.sqrtPriceX96 = r.sqrtPriceX96; o.tickLower = r.tickLower; o.tickUpper = r.tickUpper;
        o.myLiquidity = r.myLiquidity; o.resolvedTwap = r.resolvedTwap;
    }

    /// @notice Body of Vault._levBurnBTC — shrink the levered slice by up to `rem`
    ///         sats (burn band depth without delivery). Returns the sats actually
    ///         burned, subtracted from lpSharesBTC by the forwarder. Byte-identical.
    /// @dev Burn the ENTIRE full-2× BTC slice tokenlessly (no delivery — equity sits on the venue). The buffer
    ///      USD (`levBufferUsdBTC`) un-pairs from POOLED_USD as part of the gross burn,
    ///      the net-leg USD from the
    ///      basket bucket — so a venue liquidation leaves the basket intact. Full-resync burn.
    function levBurnAllBtc(
        BtcCfg memory c,
        Types.Deposit storage LP,
        mapping(address => uint) storage levPooledBTC,
        mapping(address => uint) storage levBufferUsdBTC,
        mapping(address => uint) storage levBufBTC,
        address lp, LevParams memory p
    ) public returns (uint netBurned, uint bufBurned) {
        uint netRem = levPooledBTC[lp];
        if (netRem > LP.pooled) netRem = LP.pooled;   // net leg is in pooled; never burn beyond the position
        bufBurned = levBufBTC[lp];
        uint grossRem = netRem + bufBurned;
        if (grossRem == 0) { levBufferUsdBTC[lp] = 0; return (0, 0); }
        _burnLpBtc(c.core, p, grossRem);   // extracted (legacy stack); burn gross depth
        LP.pooled -= netRem; levPooledBTC[lp] -= netRem;  // net leg leaves pooled/lpSharesBTC
        levBufBTC[lp] = 0; levBufferUsdBTC[lp] = 0;        // buffer leaves totalBufferBTC (bufBurned)
        // levBufBTC[lp] is now 0, so the GROSS fee weight is simply LP.pooled.
        SwapLib.refreshBookmarks(LP, LP.pooled, p.feesPerShareBTC, p.usdFeesBtc);
        return (netRem, bufBurned);
    }

    /// @dev modLP burn (no delivery) for a levered BTC slice in its own frame (legacy stack). Recipient is
    ///      address(0) (tokenless burn); buffer USD un-pairs from POOLED_USD as part of the gross burn.
    function _burnLpBtc(address core, LevParams memory p, uint grossRem) private {
        ICore(core).modLP(grossRem, 0, address(0));
    }
}
