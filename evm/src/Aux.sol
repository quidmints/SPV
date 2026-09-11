// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Quid} from "./Quid.sol";
import {Basket} from "./Basket.sol";

import {Core} from "./Core.sol";
import {FeeLib} from "./imports/FeeLib.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {ChannelLib} from "./imports/ChannelLib.sol";
import {ISwap} from "./imports/Interfaces.sol";
import {SwapLib} from "./imports/SwapLib.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

import {IAaveV4Spoke, IAaveV4Hub, ICollection, IEthVenue, ICore, IBTCChannels} from "./imports/Interfaces.sol";
import {Types, BadAsset, BtcChannelsPinned, GHOIsAaveWired, GHONotOnAAVE, InvalidParam, Unauthorized} from "./imports/Types.sol";

contract Aux is
    Ownable, ReentrancyGuard, ISwap {
    address[] public stables;

    Quid internal immutable RANGE;
    Core internal immutable CORE;

    Core internal immutable BTC_CORE;

    WETH9 public immutable WETH;
    IERC20 public immutable WBTC;

    Basket internal QUID;

    BasketLib.Metrics internal metrics;

    ChannelLib.SPState internal sp;

    uint public rangeBTC;

    mapping(address => uint) public tranche;
    mapping(address => address) public vaults;
    mapping(address => address) public tokens;
    mapping(address => uint) public toIndex;

    mapping(address => address[]) public vaultsOf;

    uint public trancheTotal;

    address public immutable GHO;
    address public immutable USDG;
    address public immutable AAVE_SPOKE;
    address public immutable AAVE_HUB;
    uint256 public immutable GHO_RESERVE_ID;
    uint256 public immutable USDG_RESERVE_ID;

    mapping(address => uint256) public aaveReserveId;

    mapping(address => address) public stableFeed;

    uint public constant STABLE_FEED_MAX_AGE = 27 hours;

    uint public constant ASSET_FEED_MAX_AGE = 4 hours;
    error FeedPinned();

    function _setStableFeed(address token, address feed) private {
        if (stableFeed[token] != address(0)) revert FeedPinned();
        stableFeed[token] = feed;
    }

    mapping(address => address) public assetPriceFeed;

    function _setAssetFeed(address asset, address feed) private {
        if (assetPriceFeed[asset] != address(0)) revert FeedPinned();
        assetPriceFeed[asset] = feed;
    }

    function riskFactor(address token) public view returns (uint) {
        return FeeLib.riskFactor(token, address(this));
    }

    function getDepegSeverityBps(address token) public view returns (uint) {
        address feed = stableFeed[token];
        return feed == address(0) ? 0 : FeeLib.liveDepegBps(feed, STABLE_FEED_MAX_AGE);
    }

    error LengthMismatch();

    struct Wiring {
        address[] assetTokens;   address[] assetFeeds;
        address[] stableTokens;  address[] stableFeeds;
        address[] vaultStables;  address[] vaultAddrs;
        address quid; address ethVenue; address btcChannels;
    }
    error QuidPinned();
    error NoBtcRecipient();
    error NotSelf();
    error OverCommitted();
    error BtcInflowsViaChannels();
    error UnknownStable();

    function _requireUs() private view {
        if (msg.sender != address(RANGE)
         && msg.sender != address(CORE)
         && msg.sender != address(BTC_CORE)

         && msg.sender != address(QUID)
         && msg.sender != ethVenue

         && msg.sender != CORE.btc()

         && msg.sender != address(this))
            revert Unauthorized();
    }
    modifier onlyUs { _requireUs(); _; }

    function _onlySelf() private view {
        if (msg.sender != address(this)) revert NotSelf();
    }

    struct AuxInit {
        address range;
        address core;
        address btcCore;
        address weth;
        address wbtc;
        address gho;
        address usdg;
        address aaveSpoke;
        address aaveHub;
        address[] stables;
        address[] vaults;
    }

    constructor(AuxInit memory a)
        Ownable(msg.sender)
        {
        WETH = WETH9(payable(a.weth));
        if (a.wbtc != address(0)) WBTC = IERC20(a.wbtc);

        RANGE = Quid(payable(a.range));
        CORE = Core(a.core);
        BTC_CORE = Core(a.btcCore);

        GHO = a.gho;
        USDG = a.usdg;
        AAVE_SPOKE = a.aaveSpoke;
        AAVE_HUB = a.aaveHub;
        if (a.aaveSpoke != address(0) && a.aaveHub != address(0)) {
            if (a.gho != address(0)) {
                uint256 ghoAssetId = IAaveV4Hub(a.aaveHub).getAssetId(a.gho);
                GHO_RESERVE_ID = IAaveV4Spoke(a.aaveSpoke).getReserveId(a.aaveHub, ghoAssetId);
                if (GHO_RESERVE_ID == 0) revert GHONotOnAAVE();
                IERC20(a.gho).approve(a.aaveSpoke, type(uint).max);
            }
            if (a.usdg != address(0)) {
                uint256 usdgAssetId = IAaveV4Hub(a.aaveHub).getAssetId(a.usdg);
                USDG_RESERVE_ID = IAaveV4Spoke(a.aaveSpoke).getReserveId(a.aaveHub, usdgAssetId);
                if (USDG_RESERVE_ID == 0) revert GHONotOnAAVE();
                IERC20(a.usdg).approve(a.aaveSpoke, type(uint).max);
            }
        }

        if (a.stables.length != a.vaults.length) revert LengthMismatch();
        sp.spLastUpdate = block.timestamp; stables = a.stables;
        metrics.last = 1;
        metrics.trackingStart = block.timestamp;

        ChannelLib.initVaultsBody(
            a.stables, a.vaults, toIndex, tokens, vaults, vaultsOf);

    } receive() external payable {}

    mapping(address => BasketLib.VaultHealth) public vaultHealth;

    function vaultBlocked(address vault) external view returns (bool) {
        return vaultHealth[vault].blocked;
    }

    mapping(address => BasketLib.Holding) public storedHoldings;

    function _refreshHoldings(address stable) internal {
        BasketLib.refreshHoldingsBody(stable, storedHoldings, toIndex, stables.length);
    }

    uint public holdingsRefreshedAt;
    uint internal constant HOLDINGS_MAX_STALE = 1 hours;

    function _refreshAllHoldings() internal {
        BasketLib.refreshAllHoldingsBody(storedHoldings, stables);
        holdingsRefreshedAt = block.timestamp;
    }

    function _requireFreshHoldings() internal {
        if (block.timestamp - holdingsRefreshedAt > HOLDINGS_MAX_STALE) _refreshAllHoldings();
    }

    function setVaultHealth(address vault, bool blocked)
        external {
        require(msg.sender == owner(), "403");

        BasketLib.setVaultHealthBody(vault, blocked, vaultHealth);
    }

    function pokeVaultHealth(address vault) external nonReentrant {
        BasketLib.pokeVaultHealthBody(vault, _vaultHealthCfg(),
            vaultHealth, vaultsOf, tokens);
        _refreshHoldings(tokens[vault]);
    }

    function _vaultHealthCfg() internal view returns (BasketLib.VaultHealthCfg memory) {
        return BasketLib.VaultHealthCfg({ ethVenue: ethVenue });
    }

    function evacuate(address vault) external nonReentrant onlyOwner {
        BasketLib.evacuateBody(vault, _vaultHealthCfg(),
            vaultHealth, vaultsOf, tokens);
        _refreshHoldings(tokens[vault]);
    }

    function _setVault(address stable, address vault) private {
        if (stable == GHO || stable == USDG) revert GHOIsAaveWired();

        ChannelLib.setVaultBody(stable, vault, ChannelLib.SetVaultCfg(
            AAVE_SPOKE, AAVE_HUB, stables.length),
            toIndex, vaultsOf, aaveReserveId, tokens, vaults);
    }

    function sweep(address token) external nonReentrant {

        (uint vbtcDelta, uint swept) = SwapLib.sweepBody(
            token, address(WETH), address(WBTC), GHO, USDG);
        if (vbtcDelta > 0) rangeBTC += vbtcDelta;
        if (swept > 0) emit Swept(token, swept);
        _refreshHoldings(token);
    }

    event Swept(address indexed token, uint amount);

    function get_metrics(bool force)
        public returns (uint, uint) {
        BasketLib.Metrics memory stats = metrics;
        uint elapsed = block.timestamp - stats.last;
        if (force || elapsed > 10 minutes) {
            (uint[16] memory amounts, uint[16] memory yieldW,,) = get_deposits();
            uint raw = amounts[15];

            metrics = BasketLib.computeMetrics(stats,
                elapsed, raw, yieldW[0], amounts[15]);
        } return (metrics.total, metrics.yield);
    }

    function get_metricsWith(uint raw, uint rateWeighted)
        external onlyUs returns (uint, uint) {
        BasketLib.Metrics memory stats = metrics;
        uint elapsed = block.timestamp - stats.last;
        metrics = BasketLib.computeMetrics(stats, elapsed, raw, rateWeighted, raw);
        return (metrics.total, metrics.yield);
    }

    function depegLoss() external returns (uint) { return BasketLib.depegLoss(); }
    function illiquidLoss() external view returns (uint) { return BasketLib.illiquidLoss(); }

    function illiquidLossFlagging() external returns (uint) { return BasketLib.illiquidLossFlagging(); }

    function getStables() external view
        returns (address[] memory) { return stables;
    }

    function getVaults(address stable) external view
        returns (address[] memory) { return vaultsOf[stable];
    }

    function configure(Wiring calldata w) external onlyOwner {
        uint n = w.assetTokens.length;
        if (n != w.assetFeeds.length) revert LengthMismatch();
        for (uint i; i < n; ++i) _setAssetFeed(w.assetTokens[i], w.assetFeeds[i]);

        n = w.stableTokens.length;
        if (n != w.stableFeeds.length) revert LengthMismatch();
        for (uint i; i < n; ++i) _setStableFeed(w.stableTokens[i], w.stableFeeds[i]);

        n = w.vaultStables.length;
        if (n != w.vaultAddrs.length) revert LengthMismatch();
        for (uint i; i < n; ++i) _setVault(w.vaultStables[i], w.vaultAddrs[i]);

        if (w.quid != address(0))        _pinQuid(w.quid);
        if (w.ethVenue != address(0))    _pinEthVenue(w.ethVenue);
        if (w.btcChannels != address(0)) _pinBtcChannels(w.btcChannels);
    }

    function wire(address quid_, address ethVenue_, address btcChannels_) public onlyOwner {
        if (quid_ != address(0))        _pinQuid(quid_);
        if (ethVenue_ != address(0))    _pinEthVenue(ethVenue_);
        if (btcChannels_ != address(0)) _pinBtcChannels(btcChannels_);
    }

    function finalize() external onlyOwner {
        BasketLib.assertFullyWired(address(QUID), ethVenue, _btcChannels, address(CORE), address(RANGE));

        if (assetPriceFeed[address(WETH)] == address(0)
         || assetPriceFeed[address(WBTC)] == address(0)) revert InvalidParam();

        ICollection(F8N).transferFrom(owner(), DEAD, QUID.ANGEL());
        renounceOwnership();
    }

    function _pinQuid(address _quid) private {
        if (address(QUID) != address(0)) revert QuidPinned();
        QUID = Basket(_quid);
        WETH.approve(address(RANGE), type(uint).max);

    }

    address constant F8N  = 0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function _rangeOf(address asset) private view returns (Core) {
        if (asset == address(WBTC)) return BTC_CORE;
        if (asset == address(WETH)) return CORE;
        revert BadAsset();
    }

    function assetPrice(address asset) public view returns (uint price) {
        (price,) = assetPriceStale(asset);
    }

    function assetPriceStale(address asset)
        public view returns (uint price, bool stale) {
        (price, stale) = SwapLib.anchorPrice18(
            assetPriceFeed[asset], asset == address(WBTC), ASSET_FEED_MAX_AGE);
    }

    function quoteSwapOut(address, uint)
        external returns (uint feeWad, uint redeemable) {
        feeWad = SwapLib.MIN_SWAP_SKEW_WAD;
        redeemable = BasketLib.redeemableBody(address(BTC_CORE));
    }

    function swap(address token, address asset, bool forVolatile,
        uint amount, uint minOut, bool loadBalance) public payable
        returns (uint max) {
        return swapTo(token, asset, forVolatile, amount, minOut, msg.sender, loadBalance);
    }

    function swapTo(address token, address asset, bool forVolatile,
        uint amount, uint minOut, address recipient, bool loadBalance) public payable nonReentrant
        returns (uint max) {

        return SwapLib.swapToBody(
            SwapLib.SwapReq(token, asset, forVolatile, amount, minOut, recipient, loadBalance, address(0), 0),
            SwapLib.SwapToCfg({
                weth: address(WETH), wbtc: address(WBTC), quid: address(QUID),

                core: address(_rangeOf(asset)),

                range: asset == address(WBTC) ? CORE.btc() : address(RANGE),
                btcChannels: _btcChannels
            }),
            stables
        );
    }

    function _depositVol(address asset, address sender, uint amount)
        external payable returns (uint) {
        _onlySelf();
        return _supply(asset, _deposit(asset, sender, amount));
    }
    function bumpQuidBTC(uint amount) external {
        _onlySelf();
        rangeBTC += amount;
    }

    error VaultUnwired();
    error VaultAlreadySet();
    error VaultAssetMismatch();
    error StableMissing();
    error ZeroDeposit();
    error ZeroSent();
    error VaultBlocked();

    function auxSwap(
        address tokenIn,
        address tokenOut,
        uint    amountIn,
        address recipient,
        uint    minOut
    ) external nonReentrant returns (uint amountOut) {

        return SwapLib.auxSwapBody(
            tokenIn, tokenOut, amountIn, recipient, minOut,
            toIndex[tokenIn], toIndex[tokenOut],
            address(this)
        );
    }

    address public ethVenue;
    error EthVenuePinned();
    function _pinEthVenue(address e) private {
        if (ethVenue != address(0)) revert EthVenuePinned();
        ethVenue = e;

        IERC20(address(WETH)).approve(e, type(uint).max);
    }

    function rangeETH() public view returns (uint) {
        return IEthVenue(ethVenue).rangeETH();
    }

    function deliverableETH() public view returns (uint) {
        return IEthVenue(ethVenue).deliverableETH();
    }

    function btcShortfall(address sender, uint shortfall) external onlyUs {
        if (sender == address(this)) return;
        bytes32 recipient = IBTCChannels(_btcChannels).btcRecipientOf(sender);
        if (recipient == bytes32(0)) {

            emit BTCShortfallDropped(sender, shortfall);
            return;
        }
        emit BTCHopRequest(recipient, shortfall);
    }

    event BTCShortfallDropped(address indexed sender, uint256 shortfall);

    event BTCHopRequest(bytes32 indexed recipient, uint256 amount);

    function spendClaim(address owner, uint usd6) external nonReentrant returns (uint funded6) {
        if (msg.sender != address(RANGE)) revert Unauthorized();
        return BasketLib.spendClaimBody(owner, usd6, address(QUID));
    }

    function redeem(uint amount) external nonReentrant {
        _redeemAs(amount, msg.sender, msg.sender);
    }

    function redeemTo(uint amount, address recipient) external nonReentrant {
        require(recipient != address(0), "bad-recipient");
        _redeemAs(amount, msg.sender, recipient);
    }

    function _redeemAs(uint amount, address source, address recipient) internal {

        _requireFreshHoldings();

        netIssuanceUsd -= int256(amount);
        BasketLib.redeemAsBody(BasketLib.RedeemArgs(
            amount, source, recipient,
            address(CORE), address(QUID), address(RANGE), address(WETH)));

        _refreshAllHoldings();
    }

    function redeemableAmount() external returns (uint) {

        return BasketLib.redeemableBody(address(BTC_CORE));
    }

    function get_deposits() public
        returns (uint[16] memory amounts, uint[16] memory yieldW, uint avgYieldOut, uint depegLossOut) {
        (amounts, yieldW, depegLossOut) = BasketLib.get_deposits(
            address(this), stables, storedHoldings, tranche);

        uint nStables = stables.length;
        if (nStables > 0) {
            address stable = stables[nStables - 1];
            address vault = vaults[stable];
            (uint spTotal, uint spYieldWeighted) = ChannelLib.calcSPValue(
                vault, address(this), tranche[stable], sp);
            if (spTotal > 0) {
                amounts[15] += spTotal;
                amounts[nStables] = spTotal;

                uint sev = getDepegSeverityBps(stable);
                if (sev > 0) {
                    uint loss = SoladyMath.fullMulDiv(spTotal, sev > 10000 ? 10000 : sev, 10000);
                    spYieldWeighted = spYieldWeighted > loss ? spYieldWeighted - loss : 0;
                    depegLossOut += loss;
                }
                amounts[0]  += spYieldWeighted;
                yieldW[nStables]  = spYieldWeighted;
            }
        }
        avgYieldOut = metrics.yield;
    }

    function avgYield()
        external view returns (uint) {
        return BasketLib.avgYield(metrics);
    }

    function take(address who, uint amount, address token, uint seed)
        public onlyUs returns (uint sent) {
        return BasketLib.takeBody(_takeArgs(who, amount, token, seed));
    }

    function _takeArgs(address who, uint amount, address token, uint seed)
        internal view returns (BasketLib.TakeArgs memory) {

        return BasketLib.TakeArgs(
            who, amount, token, seed,
            address(WETH), address(QUID),
            toIndex[token], stables, address(this),
            false
        );
    }

    function takeToSettle(address who, uint amount, address token) external onlyUs returns (uint sent) {
        BasketLib.TakeArgs memory a = _takeArgs(who, amount, token, 0);
        a.softBacking = true;
        return BasketLib.takeBody(a);
    }

    function takeWith(address who, uint amount, address token, uint seed,
        uint[16] memory amounts, uint[16] memory yieldW) public onlyUs returns (uint sent) {
        return BasketLib.takeBodyWith(
            _takeArgs(who, amount, token, seed), amounts, yieldW);
    }

    mapping(address => uint256) public committedOf;
    event Reported(address indexed range, uint256 equityUsd18);

    function report(uint256 equityUsd18) external {
        if (msg.sender != address(CORE) && msg.sender != address(BTC_CORE)) revert Unauthorized();
        committedOf[msg.sender] = equityUsd18;
        emit Reported(msg.sender, equityUsd18);
    }

    function committedTotal() public view returns (uint256) {
        return committedOf[address(CORE)] + committedOf[address(BTC_CORE)];
    }

    function checkBacking() external returns (uint committedSum, uint totalLiquid) {
        return _checkBacking();
    }

    function _checkBacking()
        internal returns (uint committedSum, uint totalLiquid) {
        (committedSum, totalLiquid) = _backingCore();

        if (committedSum > totalLiquid) revert OverCommitted();
    }

    function tryCheckBacking() external returns (uint committedSum, uint totalLiquid) {
        return _backingCore();
    }

    function _backingCore()
        internal returns (uint committedSum, uint totalLiquid) {

        return BasketLib.backingCoreBody(address(CORE), address(BTC_CORE), address(RANGE), CORE.btc());
    }

    function _withdraw(address token, uint amount, address to)
        internal returns (uint sent) {

        return ChannelLib.withdrawBody(token, amount, to, _supplyCfg(), vaults, vaultsOf, sp);
    }

    function deposit(address from,
        address token, uint amount) public
        returns (uint usd) {

        usd = ChannelLib.depositBody(from, token, amount, address(QUID), stables.length);

        if (msg.sender == address(QUID))
            netIssuanceUsd += int256(BasketLib.scaleTokenAmount(usd, token, true));
        return usd;
    } function _tip(uint cut, address token, int sign) internal {

        trancheTotal = BasketLib.tipBody(tranche, trancheTotal, cut, token, sign);
    }

    function _withdrawAaveUnsafe(uint256 reserveId, uint amount, address to) external returns (uint drawn) {
        _onlySelf();

        return ChannelLib.aaveWithdrawTo(
            AAVE_SPOKE, reserveId, reserveId == GHO_RESERVE_ID ? GHO : USDG, amount, to);
    }

    function withdrawAaveLeg(address stable, uint amount, address to)
        external returns (uint drawn) {
        _onlySelf();

        return ChannelLib.aaveWithdrawTo(
            AAVE_SPOKE, _reserveIdOf(stable), stable, amount, to);
    }

    function supplySelf(address token, uint amount) external returns (uint deposited) {
        _onlySelf();
        return _supply(token, amount);
    }

    function withdrawSelf(address token, uint amount, address to) external returns (uint sent) {
        _onlySelf();
        return _withdraw(token, amount, to);
    }

    function flagIlliquidSelf(address vault, bool illiquid) external {
        _onlySelf();
        BasketLib.flagIlliquidBody(vault, illiquid, vaultHealth);
    }

    function tipSelf(uint cut, address token, int sign) external {
        _onlySelf();
        _tip(cut, token, sign);
    }

    function refreshHoldingsSelf(address stable) external {
        _onlySelf();
        _refreshHoldings(stable);
    }
    function refreshAllHoldingsSelf() external {
        _onlySelf();
        _refreshAllHoldings();
    }

    function _reserveIdOf(address token) internal view returns (uint256) {
        return token == GHO  ? GHO_RESERVE_ID
             : token == USDG ? USDG_RESERVE_ID
             : aaveReserveId[token];
    }

    function _aaveReserve(address token) internal view returns (uint256) {
        if (AAVE_SPOKE == address(0)) return 0;
        return _reserveIdOf(token);
    }

    function _aaveUser(address token, bool wantShares) private view returns (uint) {
        uint256 reserveId = _aaveReserve(token);
        if (reserveId == 0) return 0;
        return wantShares
            ? IAaveV4Spoke(AAVE_SPOKE).getUserSuppliedShares(reserveId, address(this))
            : IAaveV4Spoke(AAVE_SPOKE).getUserSuppliedAssets(reserveId, address(this));
    }

    function aaveBalance(address token) public view returns (uint) {
        return _aaveUser(token, false);
    }

    function aaveShares(address token) public view returns (uint) {
        return _aaveUser(token, true);
    }

    function _deposit(address asset, address sender, uint amount)
        internal returns (uint sent) {

        sent = SwapLib.depositBody(asset, address(WETH), sender, amount);
        if (sent == 0) revert ZeroSent();
    }

    address internal _btcChannels;

    int256 public netIssuanceUsd;

    function setBTCChannels(address b) external { wire(address(0), address(0), b); }

    function _pinBtcChannels(address b) private {
        if (_btcChannels != address(0)) revert BtcChannelsPinned();
        _btcChannels = b;

        ICore(CORE.btc()).setBTCChannels(b);
    }

    function _supply(address token, uint amount) internal returns (uint deposited) {

        return ChannelLib.supplyBody(token, amount, _supplyCfg(), vaults, vaultsOf, sp);
    }

    function _supplyCfg() private view returns (ChannelLib.SupplyCfg memory) {
        return ChannelLib.SupplyCfg(
            address(WETH), GHO, USDG, AAVE_SPOKE,
            GHO_RESERVE_ID, USDG_RESERVE_ID, ethVenue,
            stables[stables.length - 1]);
    }

    function reserveIdOf(address token) external view returns (uint256) {
        return _reserveIdOf(token);
    }

}
