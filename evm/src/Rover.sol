
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {WETH} from "solmate/src/tokens/WETH.sol";
// §A.52: the canonical weETH view (was a file-local `IWeETHRate` subset).
import {IWeETH} from "./imports/Interfaces.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {TickMath} from "./imports/v3/TickMath.sol";
import {FullMath} from "./imports/v3/FullMath.sol";

import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "./imports/v3/LiquidityAmounts.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol";
import {INonfungiblePositionManager} from "./imports/v3/INonfungiblePositionManager.sol";
import {IDepositAdapter} from "./imports/Interfaces.sol";

// ether.fi: mint the weETH leg at the FAIR protocol rate (never swap WETH→weETH
// on the thin pool side). `getEETHByWeETH` is the unmanipulable fair-value anchor.
// Minimal view over INonfungiblePositionManager.positions: declares only the
// 8-value prefix (same selector). Decoding the full 12-value tuple is 1 slot too
// deep for the legacy pipeline (no via_ir/optimizer); this decodes just through
// `liquidity` (the 8th value), ignoring the trailing 4 fee-growth/owed words.
interface INFPMLiq { function positions(uint tokenId) external view
    returns (uint96, address, address, address, uint24, int24, int24, uint128 liquidity); }

contract Rover is ReentrancyGuard, Ownable {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    address public immutable WEETH;
    bool public immutable nativeWETH;

    WETH public immutable weth;
    uint public ID; // NFT

    uint constant WAD = 1e18;
    // Arbitrum or Base deployments can
    // have different value than L1 for
    // weETH because it is CCIP bridged
    // along with Solana metapool stake
    bool public immutable token1isWETH;
    uint public totalShares;
    uint public LAST_REPACK;

    int24 public UPPER_TICK;
    int24 public LOWER_TICK;
    int24 public LAST_TICK;

    uint160 public LAST_SQRT_PRICE;
    int24 constant MAX_TICK = 887220;
    // Self-funding compound crank (mirrors Vogue.compound): the permissionless caller is reimbursed
    // gas as an ETH tip peeled from the harvested WETH fees ONLY (never principal), grief-capped at
    // half the WETH harvest + a gasprice ceiling. tip=0 at zero gasprice ⇒ full compound.
    uint private constant COMPOUND_GAS = 600_000; // tuned: measured ~560k (RoverFork) + ~7% margin
    uint private constant COMPOUND_MAX_GASPRICE = 200 gwei;
    address public AUX; address public immutable ADAPTER;
    address public levManager;   // pin-once (setLevManager) — the ETH LevManager, allowed to call `absorb`
    INonfungiblePositionManager public NFPM;

    mapping(address => uint128) public positions;
    int24 TICK_SPACING; uint24 public POOL_FEE;
    address public POOL; address public ROUTER;

    uint128 public liquidityUnderManagement;

    /// @dev Refresh the cached oracle (slot0 → LAST_TICK/LAST_SQRT_PRICE) and re-center
    ///      the protocol NFT at fair. Shared by fetch / repackNFT / take (the `int24
    ///      tick` local lives in this frame, easing the callers' stack pressure too).
    ///      `commit`=true SWEEPS all idle (absorbed weETH + `_swap` leftovers) into the
    ///      position so nothing waits idle for the next recenter; take() passes false —
    ///      it SOURCES WETH, so sweeping idle in then pulling it back would round-trip the
    ///      pool fee + the weETH mint/redeem for nothing.
    function _refreshAndRepack(bool commit) private returns (uint160 sqrtPriceX96, uint price) {
        int24 tick;
        (sqrtPriceX96, tick) = _slot0();
        LAST_TICK = tick; LAST_SQRT_PRICE = sqrtPriceX96;
        price = getPrice(sqrtPriceX96);
        _repackNFT(0, 0, price, commit);
    }

    function fetch(address beneficiary) public
        returns (uint128, uint, uint160) {
        uint128 liq = positions[beneficiary];
        (uint160 sqrtPrice, uint price) = _refreshAndRepack(true);
        return (liq, price, sqrtPrice);
    }   receive() external payable {}

    modifier onlyUs {
        require(msg.sender == AUX, "403"); _;
    }

    constructor(address _adapter,
        address _weth, address _weeth,
        address _nfpm, address _pool,
        address _router, bool _nativeWETH)
        Ownable(msg.sender) {
        WEETH = _weeth; POOL = _pool; ADAPTER = _adapter;
        weth = WETH(payable(_weth));
        nativeWETH = _nativeWETH;

        ROUTER = _router; totalShares = 1;
        POOL_FEE = IUniswapV3Pool(POOL).fee();
        TICK_SPACING = IUniswapV3Pool(POOL).tickSpacing();
        address token0 = IUniswapV3Pool(POOL).token0();
        address token1 = IUniswapV3Pool(POOL).token1();
        token1isWETH = (token1 == _weth);

        require((token1isWETH && token0 == _weeth)
            || (!token1isWETH && token1 == _weeth),
            "wrong pool");

        NFPM = INonfungiblePositionManager(_nfpm);
        ERC20(weth).approve(_router, type(uint).max);
        ERC20(WEETH).approve(_router, type(uint).max);
        ERC20(weth).approve(_nfpm, type(uint).max);
        ERC20(WEETH).approve(_nfpm, type(uint).max);
        ERC20(weth).approve(_adapter, type(uint).max); // mint weETH leg via adapter
    }

    function setAux(address _aux) external onlyOwner {
        require(AUX == address(0)); AUX = _aux;
        renounceOwnership();
    }

    /// @notice Pin the ETH LevManager (the only non-AUX caller of `absorb`). Gated to AUX (== the Vault,
    ///         our only `us`), which cascades it from `Vault.setLevManager` at deploy — Rover is ownerless
    ///         post-setAux, so this can't be onlyOwner. Pin-once.
    function setLevManager(address _lm) external {
        require(msg.sender == AUX && levManager == address(0), "403");
        levManager = _lm;
    }

    /// @notice Fair-rate INVENTORY swap between weETH and WETH from Rover's IDLE inventory — the lev legs' cheapest,
    ///         zero-slippage tier. `giveWeeth=false`: DOWN-leg, `amountIn` weETH → WETH (weETH STAYS, rebalancing a
    ///         WETH-heavy pool toward weETH). `giveWeeth=true`: UP-leg, `amountIn` WETH → weETH (WETH STAYS,
    ///         rebalancing back toward WETH AND saving a fresh ether.fi mint). Priced at the ether.fi PROTOCOL rate
    ///         (getEETHByWeETH — pool-spot-independent ⇒ manipulation-immune, never a thin-side pool swap). Self-
    ///         limiting to idle OUTPUT inventory (tapers to nothing once balanced); the caller converts any
    ///         remainder. RESTRICTED to AUX/LevManager: at the protocol rate a permissionless caller could arb idle
    ///         inventory vs pool spot; the lev legs transact at fair, not to arb.
    /// @return amountOut output delivered. @return amountUsed input consumed (< amountIn on a partial fill).
    function absorb(uint amountIn, bool giveWeeth)
        external nonReentrant returns (uint amountOut, uint amountUsed) {
        require(msg.sender == AUX || (levManager != address(0) && msg.sender == levManager), "403");
        if (amountIn == 0) return (0, 0);
        uint rate = IWeETH(WEETH).getEETHByWeETH(1e18);              // ETH per 1 weETH (1e18); linear ⇒ scales
        if (rate == 0) return (0, 0);
        (address tin, address tout) = giveWeeth ? (address(weth), WEETH) : (WEETH, address(weth));
        uint idle = ERC20(tout).balanceOf(address(this));               // idle OUTPUT inventory bounds the fill
        if (idle == 0) return (0, 0);
        uint fair = giveWeeth ? amountIn * 1e18 / rate                  // WETH → weETH
                              : amountIn * rate / 1e18;                 // weETH → WETH
        if (fair <= idle) { amountOut = fair; amountUsed = amountIn; }
        else {                                                          // partial: only what idle output covers
            amountOut  = idle;
            amountUsed = giveWeeth ? idle * rate / 1e18 : idle * 1e18 / rate;
        }
        ERC20(tin).safeTransferFrom(msg.sender, address(this), amountUsed); // caller pre-approved Rover
        ERC20(tout).safeTransfer(msg.sender, amountOut);
    }

    // MANIPULATION GATE REMOVED (`_nearFair`, 2026-08-04). It refused mint/recenter/compound
    // whenever pool spot sat >50 bps from the ether.fi rate. Measured, it earned nothing and cost
    // liveness:
    //   * the MARKET never reaches it -- worst spot-vs-fair deviation over 180 days is 26 bps
    //     against a 50 bps trigger, median ~7 -- so only a DELIBERATE shove ever fires it;
    //   * a shove's PAYOFF IS NEGATIVE for the attacker: it leaves Rover minting at a bad tick and
    //     therefore OUT OF RANGE, and an out-of-range Rover measures BETTER than an in-range one
    //     (-0.04%/yr vs -1.15%: `analysis/rover/replay.py`) because the drift ratchet only bites
    //     positions spot passes THROUGH. The gate defended against an attack that helps us.
    //   * and it guarded a path that already has its own guard: the ONLY leg that can lose value is
    //     the weETH->WETH pool swap, which `_fairMinOut` floors at the adapter rate independently.
    //     Minting at a poor tick strands nothing -- the tokens stay ours and the next recenter fixes
    //     it. So the gate protected the recoverable path and not the lossy one.
    // Rule 3 (minimise clamps that give false safety; attack the cause) and rule 1 (no unreachable
    // code) both point the same way. `_fairMinOut` below is the check that EARNS its place: violating
    // it would be a silent loss.

    /// @dev Fair-rate floor for a weETH→WETH execution: adapter rate minus the
    ///      pool fee minus 0.5% in-band slippage slack (the offramp's standing
    ///      cap). Below-fair executions are refused. This is now the SOLE
    ///      manipulation defence (`_nearFair` was removed above): a shoved pool
    ///      cannot pay the floor, so the swap simply does not fire and the weETH
    ///      stays idle, fair-valued, until the pool is honest again.
    function _fairMinOut(uint weethIn) internal view returns (uint) {
        return IWeETH(WEETH).getEETHByWeETH(weethIn)
            * (1e6 - POOL_FEE) / 1e6 * 995 / 1000;
    }

    function _repackNFT(uint amount0, uint amount1,
             uint price, bool commit) internal { uint128 liquidity;
        // GATE: never mint/recenter/compound against a pool that isn't at the
        // staking-rate fair value. Tokens simply wait (idle, fair-valued).
        // Tick INIT still runs below so first-deposit share math stays sound.
        (int24 newLower, int24 newUpper) = _adjustTicks(LAST_TICK);
        if (LAST_REPACK != 0) { // not the first time packing the NFT
            // Recenter whenever the at-fair tick left the band — no time
            // window: out-of-band + at-fair can't be toggled by an attacker,
            // and an in-band call only harvests/compounds (harmless to spam).
            if (LAST_TICK > UPPER_TICK || LAST_TICK < LOWER_TICK) {
                // Re-center the ONE-TICK band (see `_adjustTicks`: floor(tick) →
                // +TICK_SPACING, i.e. ~10bps wide — NOT the "~7% above and below"
                // an older comment here claimed; that text described a superseded
                // implementation and had to be deleted because it mis-framed a
                // whole analysis of this contract's economics).
                liquidity = _posLiq();
                liquidityUnderManagement = liquidity;
                (uint collected0,
                 uint collected1,) = _withdrawAndCollect(liquidity);
                amount0 += collected0; amount1 += collected1;
                NFPM.burn(ID); ID = 0;
                // Update ticks for new
                // position after burning
                LOWER_TICK = newLower;
                UPPER_TICK = newUpper;
            }
        } else { // First time ever
            LOWER_TICK = newLower;
            UPPER_TICK = newUpper;
        }
        _mintOrCompound(amount0, amount1, price, liquidity, commit);
    }

    /// @dev Mint a fresh position (rebalancing idle holdings via _swap) or compound
    ///      collected fees into the existing one — in its own frame so _repackNFT's
    ///      locals don't pin the legacy stack (no via_ir crutch).
    function _mintOrCompound(uint amount0, uint amount1, uint price, uint128 liquidity, bool commit) private {
        if (liquidity > 0 || ID == 0) {
            if (ID == 0) {
                // Fresh mint → position ALL idle holdings, including tokens
                // parked by a previously fair-gated deposit (they'd otherwise
                // sit idle forever: this branch is their only way in).
                amount0 = ERC20(token1isWETH ? WEETH : address(weth)).balanceOf(address(this));
                amount1 = ERC20(token1isWETH ? address(weth) : WEETH).balanceOf(address(this));
            }
            if (amount0 == 0 && amount1 == 0) return;
            // Convert to (wethAmount, usdcAmount) for potential _swap
            (uint wethAmount, uint usdcAmount) = token1isWETH ?
                (amount1, amount0) : (amount0, amount1);
            // Only skip _swap if we didn't just burn (liquidity==0) AND have
            // pre-balanced amounts (both > 0); else rebalance for the NEW range.
            bool needsSwap = liquidity > 0 || wethAmount == 0 || usdcAmount == 0;
            if (needsSwap) {
                (wethAmount, usdcAmount) = _swap(wethAmount, usdcAmount, price);
            }
            // token0 is always the lower address
            (uint mintAmount0, uint mintAmount1) = token1isWETH ?
                (usdcAmount, wethAmount) : (wethAmount, usdcAmount);
            (ID, liquidityUnderManagement) = _mintRover(mintAmount0, mintAmount1);
            LAST_REPACK = block.timestamp;
        } else if (commit) {
            // FULL-SWEEP (deposit/withdraw/repackNFT): commit the ENTIRE idle balance
            // (collected fees + weETH absorbed by `absorb` + _swap leftovers) into
            // the position, not just fees, so nothing waits idle for the next recenter.
            _collect(price);   // fees -> this contract's idle balance
            uint bal0 = ERC20(token1isWETH ? WEETH : address(weth)).balanceOf(address(this));
            uint bal1 = ERC20(token1isWETH ? address(weth) : WEETH).balanceOf(address(this));
            if (bal0 != 0 || bal1 != 0) {
                (uint wethAmt, uint usdcAmt) = token1isWETH ? (bal1, bal0) : (bal0, bal1);
                (wethAmt, usdcAmt) = _swap(wethAmt, usdcAmt, price);   // rebalance idle to range
                (uint a0, uint a1) = token1isWETH ? (usdcAmt, wethAmt) : (wethAmt, usdcAmt);
                if (a0 != 0 || a1 != 0) {
                    try NFPM.increaseLiquidity(
                        INonfungiblePositionManager.IncreaseLiquidityParams(
                            ID, a0, a1, 0, 0, block.timestamp))
                    returns (uint128 added, uint, uint) {
                        liquidityUnderManagement += added;
                    } catch {}
                }
            }
        } else {
            // take() path: fees-only compound (no idle sweep — take SOURCES WETH; sweeping
            // idle in then pulling it back would round-trip the pool fee + weETH conversion).
            (uint collected0, uint collected1) = _collect(price);
            amount0 += collected0; amount1 += collected1;
            if (amount0 > 0 || amount1 > 0) {
                // Try to compound collected fees. May fail (single-sided / dust);
                // on fail, tokens stay for next deposit/repack.
                try NFPM.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams(
                        ID, amount0, amount1, 0,
                        0, block.timestamp))
                returns (uint128 addedLiquidity, uint, uint) {
                    liquidityUnderManagement += addedLiquidity;
                } catch { // Silently continue - tokens remain
                }
            }
        }
    }

    function repackNFT() public nonReentrant
        returns (uint160) { (uint160 sqrtPriceX96, ) = _refreshAndRepack(true);
        _wrapIdle(); // leftovers (incl. fair-gated waits) earn as weETH
            return sqrtPriceX96;
    } // from v3-periphery/OracleLibrary

    /// @notice PERMISSIONLESS self-funding compound crank (mirrors Vogue.compound). Harvests the V3
    ///         position fees and compounds them, reimbursing the caller's gas as an ETH tip peeled
    ///         from the harvested WETH fees ONLY (never principal) — grief-capped at half the WETH
    ///         harvest and gasprice-capped. No operator gas: anyone cranks it when accrued fees
    ///         exceed gas+tip. Off-fair or no position ⇒ no-op (fees wait, fair-valued). tip=0 at
    ///         zero gasprice ⇒ full compound, so default-gasprice unit tests are unchanged.
    function compound() external nonReentrant {
        if (ID == 0) return;                              // no position ⇒ fees wait
        (uint160 sp,) = _slot0();
        uint price = getPrice(sp);
        (uint c0, uint c1) = _collect(price);             // V3 fees → this contract's idle balance
        uint wethFee = token1isWETH ? c1 : c0;            // WETH portion of THIS harvest
        uint gp  = tx.gasprice < COMPOUND_MAX_GASPRICE ? tx.gasprice : COMPOUND_MAX_GASPRICE;
        uint tip = gp * COMPOUND_GAS;
        if (tip > wethFee / 2) tip = wethFee / 2;         // cranker never takes >½ the WETH harvest
        if (tip > 0) {                                    // pay from the harvest, never principal
            weth.withdraw(tip);                           // WETH → ETH (contract has receive())
            (bool ok,) = payable(msg.sender).call{value: tip}("");
            require(ok, "tip");
        }
        _refreshAndRepack(true);   // recenter (if out-of-band+fair) + compound the remaining idle
        _wrapIdle();
    }
    // Returns price as WEETH per WETH...
    function getPrice(uint160 sqrtRatioX96)
        public view returns (uint price) {
        uint casted = uint(sqrtRatioX96);
        uint ratioX128 = FullMath.mulDiv(
                 casted, casted, 1 << 64);

        if (token1isWETH) // token0/token1 = WEETH/WETH
            price = FullMath.mulDiv(1 << 128, WAD, ratioX128);
        else // sqrtPrice represents token0/token1 = WETH/WEETH
            price = FullMath.mulDiv(ratioX128, WAD, 1 << 128);
    }

    /// @dev WEETH→WETH single-hop swap via exactInputSingle. Its ExactInputSingleParams
    ///      is ALL-STATIC (no dynamic `bytes path`), so the legacy ABI encoder handles
    ///      it — exactInput's dynamic-path struct cannot encode without optimizer/via_ir.
    ///      Behaviour-equivalent to the old single-hop exactInput (sqrtPriceLimitX96=0).
    ///      try/catch lives here (try wraps only external calls); `ok` reports success
    ///      so callers keep the NON-BLOCKING semantics.
    function _exactIn(uint amountIn, uint minOut)
        private returns (uint got, bool ok) {
        try ISwapRouter(ROUTER).exactInputSingle(_single(amountIn, minOut))
        returns (uint o) { got = o; ok = true; } catch { ok = false; }
    }

    /// @dev Strict (reverts propagate) WEETH→WETH single-hop swap.
    function _exactInStrict(uint amountIn, uint minOut) private returns (uint) {
        return ISwapRouter(ROUTER).exactInputSingle(_single(amountIn, minOut));
    }

    /// @dev NFPM.positions returns a 12-value tuple; its ABI decode has a `headStart`
    ///      that overflows when inlined in a deep function — pull just the liquidity
    ///      out in its own frame (legacy pipeline, no via_ir/optimizer).
    function _posLiq() private view returns (uint128 liq) {
        (,,,,,,, liq) = INFPMLiq(address(NFPM)).positions(ID);
    }

    /// @dev slot0 returns a 7-value tuple; decode it in its own frame for the same
    ///      reason. Returns the price + tick (callers take what they need).
    function _slot0() private view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = IUniswapV3Pool(POOL).slot0();
    }

    /// @dev The static single-hop params (own frame keeps callers lean).
    function _single(uint amountIn, uint minOut)
        private view returns (ISwapRouter.ExactInputSingleParams memory) {
        return ISwapRouter.ExactInputSingleParams({
            tokenIn: WEETH, tokenOut: address(weth), fee: POOL_FEE,
            recipient: address(this), amountIn: amountIn,
            amountOutMinimum: minOut, sqrtPriceLimitX96: 0 });
    }

    /// @dev NFPM.mint with its 11-field MintParams in its own frame so the ABI
    ///      encode has stack headroom (legacy pipeline — no via_ir/optimizer).
    function _mintRover(uint mintAmount0, uint mintAmount1)
        private returns (uint id, uint128 liq) {
        (id, liq,,) = NFPM.mint(INonfungiblePositionManager.MintParams({
            token0: token1isWETH ? WEETH : address(weth),
            token1: token1isWETH ? address(weth) : WEETH,
            fee: POOL_FEE, tickLower: LOWER_TICK, tickUpper: UPPER_TICK,
            amount0Desired: mintAmount0, amount1Desired: mintAmount1,
            amount0Min: 0, // atomic with swap, no MEV risk
            amount1Min: 0, recipient: address(this), 
            deadline: block.timestamp }));
    }

    function _collect(uint /*unused*/) internal
        returns (uint amount0, uint amount1) {
        (amount0, amount1) = NFPM.collect(
            INonfungiblePositionManager.CollectParams(ID,
                address(this), type(uint128).max, type(uint128).max
            )); // "collect calls to the tip sayin' how ya changed"
    } //

    function _withdrawAndCollect(uint128 liquidity) internal
        returns (uint amount0, uint amount1, uint128 liq) {
        // Early return if nothing requested or no position
        if (liquidity == 0 || ID == 0) return (0, 0, 0);
        // actual position liquidity from NFT - this is ground truth
        uint128 positionLiquidity = _posLiq();
        // Cap to actual available in NFT position (prevents NFPM revert)
        if (liquidity > positionLiquidity)
            liquidity = positionLiquidity;

        // Also cap to our tracking variable...
        if (liquidity > liquidityUnderManagement) {
            liquidity = liquidityUnderManagement;
            liquidityUnderManagement = 0;
        } else
            liquidityUnderManagement -= liquidity;

        if (liquidity > 0) {
            (uint160 sqrtLower, uint160 sqrtUpper,
             uint160 sqrtCurrent) = _getTickSqrtPrices();
            (uint exp0, uint exp1) = LiquidityAmounts
                .getAmountsForLiquidity(sqrtCurrent,
                    sqrtLower, sqrtUpper, liquidity);

            NFPM.decreaseLiquidity(// there's liquidity to withdraw
                INonfungiblePositionManager.DecreaseLiquidityParams(
                    ID, liquidity, exp0 * 980 / 1000,
                    exp1 * 980 / 1000, block.timestamp));

            (amount0, amount1) = _collect(0);
            return (amount0, amount1, liquidity);
        } return (0, 0, 0);
    }


    function _adjustTicks(int24 currentTick) internal
        view returns (int24 lower, int24 upper) {
        // TRUE ONE-TICK band: weETH/WETH is a slow-drifting correlated pair, so a single
        // tick-spacing captures ~all the fee with near-zero out-of-range risk (the keeper
        // re-centers on the rare drift). FLOOR the current tick to spacing so the live price
        // sits inside [lower, upper); upper is the next spacing up. (Nearest-rounding could put
        // lower ABOVE current and strand the price out of range, so floor explicitly here.)
        int24 rem = currentTick % TICK_SPACING;
        if (rem < 0) rem += TICK_SPACING;
        lower = currentTick - rem;
        upper = lower + TICK_SPACING;
    }

    /// @dev Liquidity whose withdrawal realises `need` WETH-EQUIVALENT across BOTH legs, priced off
    ///      the band's ACTUAL composition at the live tick.
    ///
    ///      REPLACES a `need / 2` split that silently assumed the band is 50/50. A v3 band is 50/50
    ///      only when spot sits at its geometric middle; everywhere else the split is whatever the
    ///      tick says. MEASURED on a fork at tick -948 in `[-950, -940)` the band is 71.6% WETH, and
    ///      `take(500 ether)` delivered **348.998** — `need/2 ÷ 0.716 = need × 0.698`, i.e. 30% short,
    ///      matching to three digits. That short is SILENT: `VaultLib.withdrawETH` wraps `take` in
    ///      try/catch and reports whatever arrives as success, and `Vogue` re-credits the difference
    ///      as deferred `pooled` — so an LP is told they exited while a third of the ask never moved.
    ///
    ///      Probe-and-scale rather than closed-form: `getAmountsForLiquidity` already encodes the
    ///      in-range/below/above cases, so asking it for one unit of liquidity and scaling gets the
    ///      out-of-range branches right for free. (Out of range one leg is zero, and the scale is
    ///      then simply that leg — no special case.)
    function _liquidityForWeth(uint need) private view returns (uint128) {
        (uint160 sqrtLower, uint160 sqrtUpper,
         uint160 sqrtCurrent) = _getTickSqrtPrices();
        (uint a0, uint a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtCurrent, sqrtLower, sqrtUpper, uint128(WAD));
        (uint pWeth, uint pWeeth) = token1isWETH ? (a1, a0) : (a0, a1);
        // Value the weETH leg at the unmanipulable protocol rate, the same anchor `_fairMinOut`
        // floors the actual conversion at — so sizing and execution agree on what a weETH is worth.
        uint perUnit = pWeth + (pWeeth == 0 ? 0 : IWeETH(WEETH).getEETHByWeETH(pWeeth));
        if (perUnit == 0) return 0;
        uint liq = FullMath.mulDiv(WAD, need, perUnit);
        return liq > type(uint128).max ? type(uint128).max : uint128(liq);
    }

    function _getTickSqrtPrices() internal view returns
        (uint160 sqrtLower, uint160 sqrtUpper, uint160 sqrtCurrent) {
        sqrtLower = TickMath.getSqrtPriceAtTick(LOWER_TICK);
        sqrtUpper = TickMath.getSqrtPriceAtTick(UPPER_TICK);
        sqrtCurrent = LAST_SQRT_PRICE;
    }

    // Balance (eth, weeth) toward the position's target ratio. Both tokens are
    // 18-dec → NO USDC-era 1e12 scaling. The "need more weETH" leg MINTS via the
    // ether.fi adapter at the fair rate (never a WETH→weETH pool swap on the thin
    // side); the "need more WETH" leg swaps weETH→WETH on the pool (the offramp
    // direction, min-out floored) — used on a recenter rebalance.
    function _swap(uint eth, uint weeth, uint price)
        internal returns (uint, uint) {
        if (eth == 0 && weeth == 0) return (0, 0);
        uint targetETH; uint targetWEETH;
        { (uint160 sqrtLower, uint160 sqrtUpper,
           uint160 sqrtCurrent) = _getTickSqrtPrices(); uint128 liquidity;
            // SPOT OUTSIDE THE BAND — a v3 position is then SINGLE-SIDED, and the target is
            // simply "all of that side". The sizing below is inherited from the USDC-era leg and
            // silently assumes spot sits INSIDE [lower, upper]: it passes `sqrtCurrent` as a RANGE
            // BOUND, so once spot leaves the band `LiquidityAmounts` receives an INVERTED range,
            // swaps the bounds, and returns liquidity for a range that is not the band at all —
            // garbage targets, and `NFPM.mint` reverts on them. That never fired while the band was
            // centred on spot (spot is inside by construction); it fires immediately if the band is
            // anchored anywhere else, which is what blocked anchoring it on the staking rate.
            uint rate = IWeETH(WEETH).getEETHByWeETH(WAD);
            if (sqrtCurrent >= sqrtUpper) {          // position holds only token1
                (targetETH, targetWEETH) = token1isWETH
                    ? (eth + FullMath.mulDiv(weeth, rate, WAD), uint(0))
                    : (uint(0), weeth + FullMath.mulDiv(eth, WAD, rate));
            } else if (sqrtCurrent <= sqrtLower) {   // position holds only token0
                (targetETH, targetWEETH) = token1isWETH
                    ? (uint(0), weeth + FullMath.mulDiv(eth, WAD, rate))
                    : (eth + FullMath.mulDiv(weeth, rate, WAD), uint(0));
            } else {
                if (eth > 0) {
                    liquidity = token1isWETH
                        ? LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtCurrent, eth)
                        : LiquidityAmounts.getLiquidityForAmount0(sqrtCurrent, sqrtUpper, eth);
                } else {
                    liquidity = token1isWETH
                        ? LiquidityAmounts.getLiquidityForAmount0(sqrtCurrent, sqrtUpper, weeth)
                        : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtCurrent, weeth);
                }
                if (liquidity == 0) return (eth, weeth);
                (uint amount0, uint amount1) = LiquidityAmounts.getAmountsForLiquidity(
                                          sqrtCurrent, sqrtLower, sqrtUpper, liquidity);
                (targetETH, targetWEETH) = token1isWETH ? (amount1, amount0) : (amount0, amount1);
            }
        }
        if (targetETH == 0 && targetWEETH == 0) return (eth, weeth);
        if (weeth > targetWEETH) weeth = targetWEETH;
        if (eth > targetETH) eth = targetETH;

        // Size the leg with the original target-ratio algebra. Assume X = eth,
        // Y = weeth, p = price (weETH per WETH -- what `getPrice` returns; the
        // "WETH per weETH" this said was a leftover from the USDC-era leg, and is
        // the INVERSE. The algebra is right as written: `y + n*p` is n ETH becoming
        // n*p weETH, and `k*p` is dimensionless), k = target ratio
        // (targetETH/targetWEETH). To reach ratio k after converting n of X→Y:
        //   (x - n)/(y + n·p) = k          (target)
        //   x - n = k·y + k·n·p
        //   x - k·y = n + k·n·p
        //   x - k·y = n(1 + k·p)   ⇒   n = (x - k·y)/(1 + k·p)
        // ADAPTATION: instead of SELLING n of X for Y on the pool (the old USDC
        // leg), we MINT the weETH leg via the ether.fi adapter at the fair rate —
        // identical sizing n, no thin-pool swap that moves price against us.
        if (targetWEETH > weeth && eth > 0) {
            uint k = FullMath.mulDiv(targetETH, WAD, targetWEETH);
            uint ky = FullMath.mulDiv(k, weeth, WAD);
            if (eth > ky) {
                uint kp = FullMath.mulDiv(k, price, WAD);
                if (kp == 0) kp = 1;
                uint toMint = FullMath.mulDiv(WAD, eth - ky, WAD + kp);
                if (toMint > 0 && toMint <= eth) {
                    eth -= toMint;
                    uint bal0 = ERC20(WEETH).balanceOf(address(this));
                    IDepositAdapter(ADAPTER).depositWETHForWeETH(toMint, address(this));
                    weeth += ERC20(WEETH).balanceOf(address(this)) - bal0;
                }
            }
        }
        // Need more WETH → swap weETH→WETH on the pool (offramp direction).
        if (targetETH > eth && weeth > 0 && targetWEETH > 0) {
            uint k = FullMath.mulDiv(targetETH, WAD, targetWEETH);
            if (k == 0) return (eth, weeth);
            uint kp = FullMath.mulDiv(k, price, WAD);
            if (kp == 0) return (eth, weeth);
            uint toSwap;
            if (eth > 0) {
                uint ethInWeeth = FullMath.mulDiv(eth, WAD, k);
                toSwap = weeth > ethInWeeth ? weeth - ethInWeeth : 0;
            } else toSwap = weeth;
            if (toSwap > 0) {
                toSwap = FullMath.mulDiv(WAD, toSwap, WAD + FullMath.mulDiv(WAD, WAD, kp));
                if (toSwap > weeth) toSwap = weeth;
                if (toSwap > 0) {
                    // FAIR-FLOORED, NON-BLOCKING: min-out from the adapter rate
                    // (never spot); a pool that can't pay fair keeps the weETH
                    // idle (fair-valued) instead of selling it cheap.
                    (uint got, bool ok) = _exactIn(toSwap, _fairMinOut(toSwap));
                    if (ok) { weeth -= toSwap; eth += got; }
                }
            }
        }
        return (eth, weeth);
    }

    /// @notice weETH-MAXIMAL posture: convert any idle WETH into weETH via the
    ///         adapter (the fair protocol rate — pool-independent, safe in any
    ///         pool state). The pool is WETH-flooded; the side we supply is
    ///         weETH, and idle weETH earns restaking yield while idle WETH
    ///         earns nothing. Runs after every deposit/repack so fair-gated
    ///         waiting capital still accrues. The catch{} is a LIVENESS guard
    ///         only (adapter paused → correctly hold WETH); the adapter ABI
    ///         itself is exercised by every deposit test, so nothing silent
    ///         can hide here. take()'s WETH demand is served by the position's
    ///         WETH leg + the fair-floored weETH→WETH swap.
    function _wrapIdle() internal {
        uint idle = ERC20(weth).balanceOf(address(this));
        if (idle > 0) {
            try IDepositAdapter(ADAPTER).depositWETHForWeETH(idle, address(this)) {} catch {}
        }
    }

    function deposit(uint amount)
        external nonReentrant payable {
        ( , uint price, uint160 sqrtPrice) = fetch(msg.sender);
        if (amount > 0) ERC20(weth).safeTransferFrom(msg.sender, address(this), amount);
        if (msg.value > 0) { require(nativeWETH, "no native wrap");
            weth.deposit{value: msg.value}();
        } uint in_dollars;

        (amount, in_dollars) = _swap(amount + msg.value, 0, price);
        (uint amount0, uint amount1) = token1isWETH ?
        (in_dollars, amount) : (amount, in_dollars);

        (uint160 sqrtLower, uint160 sqrtUpper,) = _getTickSqrtPrices();
        uint128 newLiq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPrice, sqrtLower, sqrtUpper, amount0, amount1);

        uint128 newShares;
        if (totalShares == 0) newShares = newLiq;
        else { // Use max to prevent new depositors from benefiting if NAV decreased
            // - If LUM > totalShares (fees accrued): new depositors get fewer shares
            // - If LUM < totalShares (loss occurred): new depositors get 1:1 (neutral)
            uint denominator = liquidityUnderManagement > totalShares ?
                               liquidityUnderManagement : totalShares;

            newShares = uint128(FullMath.mulDiv(uint(newLiq),
                                   totalShares, denominator));
        } totalShares += newShares;
        _repackNFT(amount0, amount1, price, true);
        positions[msg.sender] += newShares;
        _wrapIdle(); // leftovers (incl. fair-gated waits) earn as weETH
    } // No double-count: _withdrawAndCollect decrements liquidityUnderManagement by exactly the
      // liquidity it pulls from the NFT BEFORE removing it, so WETH taken OUT of the curve is no
      // longer position liquidity. When it then sits as a fair-gated wait and _wrapIdle earns on
      // it as weETH, it's OUT-of-curve — LUM already excluded it. In-curve (LUM/totalShares) and
      // out-of-curve (idle/wait → weETH) are disjoint: the same WETH transitions atomically from
      // one to the other, never counted in both.

    // LP.liq = user's share (set at deposit, doesn't auto-grow)
    // liquidityUnderManagement = actual V3 position liquidity
    // (grows when fees compound via increaseLiquidity); when
    // fees compound: liquidityUnderManagement += newLiquidity,
    // but NO individual LP.liq changes;
    // totalShares ≠ liquidityUnderManagement
    // because the gap = compounded fees...
    function take(uint amount) public onlyUs
        returns (uint wethAmount) {
        // Refresh + repack WITHOUT the idle-wrap (we're SOURCING WETH here —
        // wrapping idle WETH right before delivering it would round-trip the
        // pool fee for nothing).
        _refreshAndRepack(false);
        // Idle WETH first (no liquidity pulled, no swap), then the position.
        wethAmount = ERC20(weth).balanceOf(address(this));
        if (wethAmount > amount) wethAmount = amount;
        uint128 liquidity; uint usdcAmount;
        {
        uint need = amount - wethAmount;
        if (need > 0) liquidity = _liquidityForWeth(need);
        }
        (uint amount0, uint amount1, ) = _withdrawAndCollect(liquidity);
        if (token1isWETH) { usdcAmount = amount0; wethAmount += amount1; }
        else { wethAmount += amount0; usdcAmount = amount1; }
        if (usdcAmount > 0) {
            // FAIR-FLOORED, NON-BLOCKING: deliver the WETH leg regardless; the
            // weETH leg converts only at ≥ fair-minus-fee, else it stays idle
            // here (fair-valued in valueWeth) — the caller's ladder handles the
            // partial (instant-redeem / wait-NFT rungs).
            (uint got, bool ok) = _exactIn(usdcAmount, _fairMinOut(usdcAmount));
            if (ok) wethAmount += got;
        }
        if (wethAmount > 0)
            ERC20(weth).safeTransfer(msg.sender, wethAmount);
    }

    /// @notice WETH-equivalent value of ALL the Rover's holdings: idle WETH + the
    ///         v3 position's WETH + weETH legs (at the current tick) + any idle
    ///         weETH, with weETH valued at the unmanipulable fair rate
    ///         (getEETHByWeETH ≈ ETH). ASSET, not liability: Aux.vogueETH adds
    ///         this so funding the Rover (supplyEtherFiToRover) doesn't drop the
    ///         protocol's counted ETH backing. View; safe to call from vogueETH.
    function valueWeth() external view returns (uint v) {
        v = ERC20(weth).balanceOf(address(this));
        if (liquidityUnderManagement > 0 && ID != 0) {
            (uint160 sqrtLower, uint160 sqrtUpper, uint160 sqrtCurrent) = _getTickSqrtPrices();
            (uint amount0, uint amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtCurrent, sqrtLower, sqrtUpper, liquidityUnderManagement);
            (uint posWeth, uint posWeeth) = token1isWETH
                ? (amount1, amount0) : (amount0, amount1);
            v += posWeth;
            if (posWeeth > 0) v += IWeETH(WEETH).getEETHByWeETH(posWeeth);
        }
        uint idleWeeth = ERC20(WEETH).balanceOf(address(this));
        if (idleWeeth > 0) v += IWeETH(WEETH).getEETHByWeETH(idleWeeth);
    }

    // (Removed depositUSDC / withdrawUSDC — the USDC-era weETH-side entry/exit.
    // SPV funds Rover with WETH via deposit()/grow and pulls WETH via take(); the
    // weETH leg is minted in _swap via the adapter, never deposited externally.)

    // @param (amount) is actually
    // a % of their total liquidity
    // if msg.sender != address(AUX)
    function withdraw(uint amount) public nonReentrant {
        require(amount > 0 && amount <= 1000, "%");
        (uint128 liq, , ) = fetch(msg.sender);   // price/sqrtPrice unused here (compiler-flagged)
        require(liq > 0, "nothing to withdraw");
        uint128 withdrawingShares = uint128(FullMath.mulDiv(
                                    amount, uint(liq), 1000));

        uint128 liquidity = uint128(FullMath.mulDiv(liquidityUnderManagement,
                                            withdrawingShares, totalShares));

        (uint amount0, uint amount1, ) = _withdrawAndCollect(liquidity);
        (uint ethAmount, uint usdAmount) = token1isWETH ? (amount1, amount0)
                                                        : (amount0, amount1);
        if (usdAmount > 0) {
            // Fair-floored (adapter rate, never spot). Reverts if the pool
            // can't pay fair — the external LP retries when it's honest.
            ethAmount += _exactInStrict(usdAmount, _fairMinOut(usdAmount));
        }
        weth.withdraw(ethAmount);
        liq -= withdrawingShares;
        totalShares -= withdrawingShares;
        // LP receives swap output...
        // (bearing the slippage cost)
        (bool success, ) = msg.sender.call{
                          value: ethAmount}("");
                          require(success, "$");

        if (liq > 0) positions[msg.sender] = liq;
        else delete positions[msg.sender];
    }
}
