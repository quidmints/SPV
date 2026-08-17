
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Aux} from "./Aux.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {SortedSetLib} from "./imports/SortedSet.sol";

import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {ICollection} from "./imports/Interfaces.sol";

contract Basket is ERC20, ERC6909, 
    ReentrancyGuard, Ownable {
    using SortedSetLib for SortedSetLib.Set;
    error InsufficientUnlocked();
    error Unauthorized();

    uint internal _deployed;
    uint constant CAP = 600_000 * 1e18;
    uint internal seeded;
    /// @notice The seeded QUID tranche total (EXCLUDED from redeemable TVL). Was a separate `uint public target`
    ///         storage slot that moved by the EXACT same delta as `seeded` at every seed-mint (+normalized) and
    ///         seed-drain (−min(·,seed)) — a provable duplicate (the `×4yr/1.2` scaling the old comment hinted at
    ///         was never applied). Collapsed to a view alias so `ChannelLib.seedFee` (IQuidTarget.target()) keeps
    ///         working with zero redundant SSTOREs. #18.
    function target() external view returns (uint) { return seeded; }
    Aux public AUX;
    address payable public VOGUE;
    // ─── Safe/deployer seed commitment: the Foundation (F8N) ANGEL NFT ───
    // The Safe approves the already-deployed Aux for ANGEL (DeployLib, mid-deploy), and Basket's constructor
    // REQUIRES that approval — so Basket can't be born unless the seed is committed (this IS the deployer gate).
    // The Safe keeps owning ANGEL; Aux burns it (owner→DEAD via the approval) at finalize. No pull, no holding,
    // no predicted address — Aux is already deployed when approved.
    address constant F8N = 0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405;
    uint public constant ANGEL = 16508; // NFT tokenId (public so the deploy reads the same id)
    // `onlyUs` wraps the public `auth` view — the SAME predicate serves both this
    // modifier and external callers (Aux/Vogue) that check `auth()` directly, so
    // there is no duplicated inline gate to fold into a private helper.
    modifier onlyUs() {
        if (!auth(msg.sender)) revert Unauthorized(); _;
    }
    function auth(address who) public view returns (bool) {
        // AUDIT (2026-06): LINK removed — it is the depeg-oracle forwarder and
        // NEVER mints (it only ever read depeg state). §SCRUB: this named `onReport` alongside
        // `isDepegged`/`getDepegSeverityBps` as the forwarder's calls; that CRE `onReport` path is
        // RETIRED (see `Aux`: "the `onReport` forwarder path was RETIRED -- vault health is now
        // driven [...]"), and Basket never declared it. The audit conclusion below is unchanged --
        // the over-privilege was real and LINK is still correctly absent. Granting a
        // rotatable forwarder address an (unused) mint capability was an
        // over-privilege; minting is AUX (creditLPForSwap) + V4 (fees) +
        // BTC_VAULT (the regrouped BTC-LP fee/close mints, previously V4's).
        return (who == address(AUX) || who == VOGUE || who == BTC_VAULT);
    } // BTC_VAULT is Vault.sol — the BTC-side vault (band + channels). It also HOSTS both
      // LevManagers (ETH LEV_MANAGER + BTC LEV_MANAGER) as a deploy consolidation, but the
      // ETH band liquidity itself lives in Vogue (V4). The name reflects its primary BTC role.

    /// @notice BtcVault — the regrouped BTC side. Its BTC-LP fee + close-time
    ///         USD-leg mints (formerly Vogue's) need the same auth Vogue has.
    ///         Pinned once.
    address public BTC_VAULT;
    error BtcVaultPinned();
    function setBtcVault(address b) external {
        if (msg.sender != owner()) revert Unauthorized();
        if (BTC_VAULT != address(0)) revert BtcVaultPinned();
        BTC_VAULT = b;
    }

    mapping(uint => uint) public totalSupplies;
    mapping(address => uint) internal tranche;

    // Basket composition (the stable set + tranche rules) is fixed at deploy: ownership
    // is renounced after `setup`, so there is no on-chain curation/governance surface to
    // re-weight, add, or remove stables post-launch. Any change is a fresh deploy.
    // (L2-basket bridge feature removed — QU!D has no admin/governance, so the
    // owner-gated `setL2Basket` mint-against-bridge-receipt surface was deleted
    // along with `isL2Basket` / `l2Deposits`. Basket ownership is renounced after
    // `setup`. If an L2 expansion is ever needed it will be a separate deploy.)

    // ─── tranche-supply view ──────────────────────────────────────
    // ALL burns (to == address(0)) gate on maturity via BasketLib.matureBatches
    // — no bypass. There is no maturity exemption for any address: the old
    // `burnable`/`setBurnable` allowlist + its only intended user (the stripped
    // Stay/Clutch engine) are gone. A user therefore cannot bypass the maturity
    // lockup by routing QUI through any contract, and no privileged address can
    // early-burn an immature vintage.

    /// @notice The TRANCHE seed reserve: the cumulative seed-phase BONUS QU!D
    /// (the senior / bootstrap tranche) that is term-locked and is NOT part of the
    /// matured, 1:1-USD-backed pool. This mirrors Aux's `trancheTotal` (the senior
    /// tranche EXCLUDED from redeemable TVL): `seeded` is incremented on each
    /// seed-bonus mint and drained on seed burn, so it is the outstanding
    /// tranche bonus at any time. The matured 1:1-backed pool is
    /// `totalSupply - trancheTotal()`.
    ///
    /// DISTINCT from `immatureSupply()` — that is the FULL future-maturity cohort
    /// (months [currentMonth+1, currentMonth+13]), which also includes NORMALLY
    /// backed future-dated mints; `trancheTotal()` is ONLY the senior seed
    /// tranche. NOTE: `seeded`/`target`/`tranche[]` all accrue the full seed
    /// mint (principal + the 100%-APR bonus) and drain by the full burned
    /// amount — so trancheTotal() is the outstanding senior-tranche SUPPLY, of
    /// which the unbacked slice is the bonus part; the CAP therefore bounds the
    /// whole senior tranche (⇒ the unbacked bonus ⊆ CAP too).
    /// (The prior implementation summed the future vintages — i.e. it silently
    /// returned `immatureSupply()` — conflating the two; corrected here per the
    /// old-Aux `trancheTotal` semantics.)
    ///
    /// External / UI view; no internal accounting consumes it.
    function trancheTotal() external view returns (uint) {
        return seeded;
    }

    /// @notice Constructor wires Vogue + Aux and REQUIRES the Safe's ANGEL approval to Aux (the seed commitment,
    ///         made mid-deploy by DeployLib) — so Basket cannot exist unless the seed is committed. Aux burns
    ///         ANGEL and renounces at finalize; Basket is renounced by the Safe there too.
    constructor(address _vogue, address _aux)
        ERC20("QU!D", "QUI")
        Ownable(msg.sender) {
        VOGUE = payable(_vogue);
        AUX = Aux(payable(_aux));
        _deployed = block.timestamp;
        // The ANGEL commitment: the Safe must have approved Aux for the F8N ANGEL NFT BEFORE Basket is born —
        // so Basket refuses to exist unless the seed is committed. The Safe still OWNS ANGEL (only approved, not
        // moved); Aux burns it deployer→DEAD at finalize via this approval. No pull, no holding, no predicted
        // address: the already-deployed Aux is the approve target, and this check makes the commitment atomic
        // with Basket's birth. This IS the deployer gate — no separate owner check needed anywhere else.
        require(ICollection(F8N).getApproved(ANGEL) == address(AUX), "angel");
    }

    /// @notice Term-locked (immature) QUI balance — vintages in
    /// [currentMonth+1, currentMonth+13]. Consumed by redeem/mature
    /// accounting (matureSupply = totalSupply − immatureSupply). Bounded
    /// 13-iteration loop (mint vintages are clamped to this window in
    /// _finishMint).
    function immatureBalanceOf(address who) public view returns (uint bal) {
        uint cm = currentMonth();
        for (uint m = cm + 1; m <= cm + 13; ++m) bal += balanceOf[who][m];
    }

    /// @notice Total immature QUI supply — the future-maturity cohort over
    /// [currentMonth+1, currentMonth+13]; matureSupply subtracts it from total.
    function immatureSupply() public view returns (uint s) {
        uint cm = currentMonth();
        for (uint m = cm + 1; m <= cm + 13; ++m) s += totalSupplies[m];
    }

    /// @notice MATURE QU!D supply — vintages [0, currentMonth], i.e. dollar-redeemable RIGHT NOW. This is the
    ///         SENIOR claim: the shares-based redeem/swap value QU!D over `matureSupply` (not total), so mature QD
    ///         redeems at PAR and is NOT diluted by the immature forward-yield bonus (unvested = junior, it drifts
    ///         and redeems at its share only once it matures). `= totalSupply − immatureSupply` (mint clamps every
    ///         vintage into [nextMonth, nextMonth+12] ⊆ [cm+1, cm+13], so nothing matures beyond that window) —
    ///         O(1) + the 13-iter immature loop, never the unbounded 0..currentMonth sum.
    function matureSupply() public view returns (uint) {
        uint imm = immatureSupply();
        uint ts = totalSupply();
        return ts > imm ? ts - imm : 0;
    }

    // ─── Everything below is unchanged from the original Basket.sol ──

    mapping(address => SortedSetLib.Set) private perMonth;
    function currentMonth() public view returns (uint month) {
        month = (block.timestamp - _deployed) / BasketLib.MONTH;
    }

    function turn(address from, uint value) external
        onlyUs returns (uint sent, uint seedBurned) {
        uint seedBefore = tranche[from];
        sent = _transferHelper(from, address(0), value);
        seedBurned = seedBefore - tranche[from];
    }

    function _mint(address receiver,
        uint when, uint amount)
        internal override {
        totalSupplies[when] += amount;
        perMonth[receiver].insert(when);
        super._update(address(0), receiver, amount);
        balanceOf[receiver][when] += amount;
        emit Transfer(msg.sender, address(0),
                    receiver, when, amount);
    }


    function mint(address pledge, uint amount,
        address token, uint when) external
        nonReentrant returns (uint normalized) {
        uint nextMonth = currentMonth() + 1;
        if (auth(msg.sender)) { // ETH LP swap fee dollar half...
            // protocol-internal mint + Aux.creditLPForSwap for BTC
            // swap-out reissuance; Vogue for V4 fee distribution.
            // The supply cap is the structural defense against a
            // compromised hop signer: even with valid LP+hop
            // signatures, a protocol mint can only credit up to the
            // headroom that prior burns or backing growth opened.
            //
            // Calibration window: cap skipped during first 12 months
            // from deploy. Otherwise Vogue fee mints during
            // calibration would clamp to zero whenever seed bonuses
            // have temporarily pushed supply > backing — LPs would
            // lose their earned fees. After calibration, cap is
            // strict on protocol-internal mints (no minimum floor —
            // these don't carry depositor principal).
            if (currentMonth() >= 12) {
                (uint total,) = AUX.get_metrics(true);
                total -= Math.min(total, AUX.depegLoss()); // mint↔redeem symmetry: PAR backing minus the redemption depeg haircut
                // ...AND the DELIVERABILITY haircut: bind on what venues can actually pay out NOW
                // (maxWithdraw), not stale PAR (convertToAssets). Without this, a frozen-but-IMPAIRED venue
                // (reports high convertToAssets it can never deliver) lets fee/swap mints over-issue
                // redeemable-now QUI — and unlike an illiquid-but-solvent freeze that thaws, an impaired one
                // NEVER self-heals, so the over-issuance is permanent. The excess still DEFERS to a forward
                // maturity below (matures if/when the venue recovers; never, if truly impaired) — symmetric
                // with redeem's `_illiquidLoss` haircut, so mint and redeem value backing identically.
                // §E203 — the FLAGGING variant. This gate is non-view and already runs the whole
                // per-vault deliverability loop, so starting the health clock here costs nothing.
                // Scope is narrow by construction: protocol-internal mints only (the `auth` branch),
                // and only after month 12 (the enclosing guard). Redeem remains the primary driver.
                total -= Math.min(total, AUX.illiquidLossFlagging());
                
                uint headroom = total > totalSupply()
                              ? total - totalSupply() : 0;
                if (amount > headroom) {
                    // REDEEMABILITY GATE: only `headroom` worth of QUI is backed
                    // by available dollars right now, so only that slice may be
                    // redeemable-now (matures at nextMonth). DEFER the excess to a
                    // forward maturity — redeemable LATER, once burns/backing
                    // growth open headroom — instead of SHRINKING it away (which
                    // silently burned the LP's earned fees / swap claim). The
                    // deferred slice is immature, so it can't redeem against
                    // dollars that aren't there: redeemable-now supply stays ≤
                    // available dollars, while the full claim is preserved.
                    if (headroom > 0) _mint(pledge, 
                        nextMonth, headroom);
                        
                    _mint(pledge, nextMonth + 1, 
                           amount - headroom);
                    return amount;
                }
            }
            if (amount > 0) _mint(pledge, 
                nextMonth, amount);
                    return amount;
        }
        uint deposited = AUX.deposit(
               pledge, token, amount);

        normalized = _finishMint(pledge, deposited,
                          IERC20(token).decimals(), 
                                  when, nextMonth);
    }

    function _finishMint(address pledge, uint deposited,
        uint decimals, uint when, uint nextMonth) 
        internal returns (uint normalized) {
        // force-fresh metrics (true) so this mint's headroom is sized against
        // LIVE par backing, not a ≤10-min-stale cache. 18-dec (basket TVL)...
        (uint total, uint avgYield) = AUX.get_metrics(true); // matching totalSupply().
        // Discount PAR backing by the redemption depeg haircut so the 1:1 cap below
        // never mints the forward-yield slice against a depegged holding's phantom
        // par value (mint↔redeem symmetry; ≈0 when nothing is depegged).
        total -= Math.min(total, AUX.depegLoss());
        // NOTE: intentionally does NOT subtract illiquidLoss here (unlike the protocol-mint path ~line 283).
        // Depositor QUI is immature/forward-locked: illiquid-but-solvent backing THAWS over the tenor, so it
        // still backs the forward yield; only depeg (a PERMANENT value loss) shortens the horizon. The protocol
        // path subtracts illiquid because its QUI is redeemable-NOW. Mint over-mints at 1:1 by design; the
        // over-mint is absorbed at REDEEM, which values one basket share (min($1, solvent/mature)) — the two
        // sides do NOT value backing identically, and should not.
        // Forward-projection horizon. The bootstrap year (currentMonth < 12) has
        // NO yield snapshots yet, so it may project a full year forward — the
        // cold-start incentive, and the only way to offer term before we can
        // observe yield.
        //
        // AFTER year 1, snapshots exist: projecting a year out mints QUI against
        // optimistic forward yield (the cap then claws it back). How far forward
        // we let one cohort lock is a function of how much over-collateralization
        // buffer is live to absorb that pre-spend — longer locks ONLY when the
        // buffer supports it. `total` here is the depeg-adjusted REAL backing
        // (line above), so this gates on deliverable headroom, not par. The 1:1
        // cap below still binds the bonus to headroom regardless; this bounds the
        // TENOR so a thin buffer can't be stretched into long-dated cohorts.
        uint maxFwd;
        if (currentMonth() < 12) {
            maxFwd = 12;
        } else {
            uint bufBps = total > totalSupply()
                ? (total - totalSupply()) * 10_000 / total : 0;
            maxFwd = bufBps >= 500 ? 12       // ≥5% buffer → up to a full year
                   : bufBps >= 300 ? 6        // ≥3% → half year
                   : bufBps >= 150 ? 3        // ≥1.5% → a quarter
                   : 1;                       // thin buffer → ~1mo floor (prior)
        }
        uint month = Math.max(Math.min(when,
                nextMonth + maxFwd), nextMonth);
        bool isSeed = month == 13 && seeded < CAP;
        uint tgtMonth = month; // preserve the requested target across a re-projection
        (normalized, month) = BasketLib.calcMintYield(deposited,
            decimals, tgtMonth, nextMonth, avgYield, isSeed);
        // §E2-#1 — ENTER AT THE MARK. A redeem values one mature QU!D at
        // `min($1, solvent/matureSupply)` (BasketLib:847). When that mark is BELOW par, minting
        // `normalized` 1:1 hands the new depositor shares already worth less than they paid, and
        // their deposit LIFTS the mark for everyone else — the incoming depositor silently
        // subsidises the incumbents. Issuing at the mark instead keeps `perShare` INVARIANT across
        // the mint (new solvent/new mature == old solvent/old mature), which is the share-price
        // -preserving issuance a 4626 does by construction; nobody is diluted in either direction.
        // `normalized/perShare` reduces to `normalized*mature/total` exactly, since perShare is
        // `total*WAD/mature` in this branch — one mulDiv, no new import, and NO-OP whenever the
        // basket is whole (`total >= mature`), which is why the healthy path is untouched.
        // ⚠️ This does NOT touch the forward-yield BOND over-mint that :263-267 defends: that is
        // IMMATURE supply and is absent from `mature` until it vests. Entry pricing and the bond
        // are separate axes. The redemption-seniority problem (a vintage maturing and dropping the
        // mark for holders who were already in) is STILL OPEN — see §E2-seniority.
        // `total == 0` is skipped rather than clamped: with no backing there is no mark to enter
        // at, and dividing by it would mint unbounded shares.
        uint mature = matureSupply();
        // §E2-HAIRCUT — mark up against the PRE-DEPOSIT basket: `total` is read AFTER `AUX.deposit`
        // credited this deposit, so using it puts the depositor's own dollars in the denominator of
        // their own mark-up. Mutates `total` (two locals were stack-too-deep; `bufBps` already
        // consumed it and nothing below reads it).
        total -= Math.min(total, decimals < 18 ? deposited * (10 ** (18 - decimals)) : deposited);
        if (mature > 0 && total > 0 && total < mature)
            normalized = Math.mulDiv(normalized, mature, total);

        // CAP is a HARD bound on the senior seed tranche, not a soft eligibility
        // gate. `seeded < CAP` only decides eligibility; it does NOT clamp the
        // amount, so without the check below ONE seed-window deposit mints
        // principal×(1 + 100%·t) — with the 1:1 claw-back SKIPPED (calibrating,
        // below) — and pushes `seeded` arbitrarily past CAP. That excess is
        // unbacked QUI that matures at month 13 and redeems against the basket,
        // draining honest depositors. Whole-mint gate: if this seed mint would
        // breach CAP, drop the ENTIRE mint to the normal projection (yield =
        // avgYield + 1:1 claw-back) rather than partially seeding. `seeded`
        // accrues the full `normalized` below, so gate on that same quantity to
        // keep `seeded ≤ CAP` exact; the non-seed path still mints ≥ principal,
        // so the depositor never loses principal.
        if (isSeed && seeded + normalized > CAP) {
            isSeed = false;
            (normalized, month) = BasketLib.calcMintYield(deposited,
                decimals, tgtMonth, nextMonth, avgYield, false);
            // re-mark the re-projection too, so the CAP gate above and `seeded` below both see the
            // FINAL quantity — inflating after the gate is what lets `seeded` slip past CAP.
            if (mature > 0 && total > 0 && total < mature)
                normalized = Math.mulDiv(normalized, mature, total);
        }

        // ── 1:1 cap with adaptive yield shrink ────────────────────────
        // Target invariant after calibration: totalSupply + normalized
        // ≤ total. If the full yield bump pushes over, shrink
        // `normalized` to fit instead of reverting. If even 1:1 doesn't
        // fit (basket underwater), mint baseAmount anyway — can't steal
        // the depositor's principal.
        //
        // Calibration window — cap is SKIPPED when either:
        //   (a) isSeed (seeded < CAP): bootstrap incentive — yield
        //       is a fixed 100% APR constant during this phase.
        //   (b) currentMonth() < 12 (first 12 months from deploy):
        //       avgYield is still being revealed via the time gradient.
        //       12 months = max vintage span; after that, the earliest
        //       deposits' projected yield should have materialized.
        // After both conditions fail, avgYield is calibrated and the
        // cap enforces no long-term oversupply.
        // NO mint-side 1:1 cap: the bond OVER-MINTS the projected yield
        // upfront — that IS the bond. The removed `if (!calibrating) shrink normalized to
        // headroom` broke it for every post-month-12 deposit. The safety is on the REDEEM side,
        // NOT the mint, and NOT any per-redeemer time formula: QUI is minted into a future
        // maturity VINTAGE and burns GATE on maturity (BasketLib.matureBatches) — immature
        // (future-yield) vintages are term-LOCKED, you can't redeem them early. A MATURE redeem
        // pays your share of the SOLVENT basket: min($1, solvent / matureSupply). Because the
        // avgYield projection can overshoot what the vaults actually deliver (their reported yield
        // AND their basket balance drift), solvent < matureSupply is possible — so matured is NOT
        // always 1:1, and that SHARED solvency haircut is exactly what absorbs the over-mint. The
        // whole mature pool marks to real backing; nobody is time-pro-rated. Matches the reference
        // (old/evm Basket.mint mints full `normalized`). The seed-tranche CAP gate above is kept.
        if (isSeed) { seeded += normalized;
            tranche[pledge] += normalized;
        }
        _mint(pledge, month, normalized);
    }

    function transfer(address to,
        uint value) public override returns (bool) {
        require(value == _transferHelper(msg.sender,
                          to, value)); return true;
    }

    function transfer(address to, uint256, uint256 amount)
        public override returns (bool) {
        require(amount == _transferHelper(msg.sender, to, amount));
        return true;
    }

    function transferFrom(address from, address to, uint256, uint256 amount)
        public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _transferHelper(from, to, amount); return true;
    }

    function transferFrom(address from,
        address to, uint value) public
        override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transferHelper(from, to, value); return true;
    }

    function _transferHelper(address from, address to,
        uint amount) internal returns (uint sent) {
        if (super.balanceOf(from) < amount)
            revert InsufficientUnlocked();

        uint[] memory batches = perMonth[from].getSortedSet();
        bool turning = to == address(0); int i = turning
            ? BasketLib.matureBatches(
                        batches, block.timestamp, _deployed):
                                     int(batches.length - 1);
        sent = _moveBatches(from, to, amount, turning, batches, i);
        if (sent > 0) { super._update(from, to, sent);
            if (tranche[from] > 0) {
                uint seed = Math.min(sent,
                  tranche[from]);
                tranche[from] -= seed;
                if (to == address(0)) {
                    // Drain seeded too. A drained `seeded < CAP` cannot
                    // reopen the seed mint path: seed QUI is term-locked to
                    // month 13, so `seeded` only drains AT month 13 — by
                    // which point nextMonth (= currentMonth+1) > 13 forces
                    // `month = max(min(when,·), nextMonth) > 13`, so the
                    // `month == 13` eligibility in _finishMint is already
                    // permanently false. seeded → 0 is the natural end-state
                    // of the seed phase.
                    seeded -= Math.min(seeded, seed);
                } else tranche[to] += seed;
            }
        }
    }

    /// @dev Per-batch FIFO/LIFO move (the transfer/burn loop) in its own frame so
    ///      _transferHelper's locals don't pin the legacy stack across it — no
    ///      via_ir crutch.
    function _moveBatches(address from, address to, uint amount, bool turning,
        uint[] memory batches, int i) private returns (uint sent) {
        while (amount > 0 && i >= 0) {
            uint k = batches[uint(i)];
            uint amt = balanceOf[from][k];
            if (amt > 0) {
                amt = Math.min(amount, amt);
                balanceOf[from][k] -= amt;
                if (!turning) {
                    perMonth[to].insert(k);
                    balanceOf[to][k] += amt;
                } else
                    totalSupplies[k] -= amt;
                if (balanceOf[from][k] == 0)
                    perMonth[from].remove(k);
                amount -= amt; sent += amt;
            } i -= 1;
        }
    }
}
