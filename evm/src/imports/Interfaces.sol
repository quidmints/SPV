// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

type Id is bytes32;

struct MarketParams { address loanToken; address collateralToken; address oracle; address irm; uint256 lltv; }

/// §PQ-SEAM — the one-shot pluggable Bitcoin script/signature verifier.
///
/// Every member takes and returns `bytes` so NO output format or signature scheme is presumed: the
/// contract deploys once, P2MR and OP_CAT are not final, and a seam that encoded today's guess would
/// be the same dead end as enumerating the forms inline.
///
/// ⛔ **THE SECP PATH IS NOT REPLACED BY THIS AND MUST NEVER BE.** A channel's `form` is fixed at open
/// and never rewritten, so v1 channels keep using the built-in secp path for their entire life —
/// close, splice and exit. Switching secp off would strand every LP funded before activation, and on
/// a contract that deploys once the code cannot be removed either. Legacy-forever, not dead.
interface IPqVerifier {
    /// The scriptPubKey a v2 channel's funding output must pay, from the two funding keys.
    function fundingScript(bytes calldata lpKey, bytes calldata hopKey)
        external view returns (bytes memory);

    /// The scriptPubKey a v2 payout destination resolves to. MUST revert if `dest` is not
    /// well-formed under the active scheme — this is what replaces `isValidXOnlyKey`.
    function payoutScript(bytes32 dest) external view returns (bytes memory);

    /// Does `proof` prove control of `dest` over `digest`? Replaces the BIP-340 possession proof,
    /// which no post-quantum destination can produce.
    function verifyPossession(bytes32 dest, bytes32 digest, bytes calldata proof)
        external view returns (bool);

    /// Is `signedTx` validly signed by the channel's 2-of-2 under the active scheme? Replaces
    /// `schnorrVerify` over the BIP-341 key-path sighash.
    function verifyExit(
        bytes calldata signedTx, bytes calldata lpKey, bytes calldata hopKey,
        uint64[] calldata prevValues, bytes[] calldata prevScripts
    ) external view returns (bool);
}

interface IMorphoBase {
    function createMarket(MarketParams memory marketParams) external;
    function supply(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external returns (uint256 assetsSupplied, uint256 sharesSupplied);
    function borrow(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function repay(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function supplyCollateral(MarketParams memory m, uint256 assets, address onBehalf, bytes memory data) external;
    function withdrawCollateral(MarketParams memory m, uint256 assets, address onBehalf, address receiver) external;
    function liquidate(MarketParams memory m, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes memory data)
        external returns (uint256, uint256);
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function accrueInterest(MarketParams memory marketParams) external;
}

interface IMorphoStaticTyping is IMorphoBase {
    function position(Id id, address user)
        external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(Id id) external view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares,
        uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee);
    function idToMarketParams(Id id)
        external view returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv);
}

interface IOracle { function price() external view returns (uint256); }

library MarketParamsLib {
    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;
    function id(MarketParams memory marketParams) internal pure returns (Id marketParamsId) {
        assembly ("memory-safe") { marketParamsId := keccak256(marketParams, MARKET_PARAMS_BYTES_LENGTH) }
    }
}

interface IVaultV2 { function liquidityAdapter() external view returns (address); }

interface IWeETH {
    function getEETHByWeETH(uint _weETHAmount) external view returns (uint);
    function getWeETHByeETH(uint _eETHAmount) external view returns (uint);
    function unwrap(uint _weETHAmount) external returns (uint);
}

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function coins(uint256 i) external view returns (address);

    function balances(uint256 i) external view returns (uint256);
}

address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;


bytes4 constant UNOSWAP_SELECTOR = 0x83800a8e;

bytes4 constant UNOSWAP2_SELECTOR = 0x8770ba91;

bytes4 constant SWAP_SELECTOR   = 0x07ed2379;

address constant DAI_USDS        = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;
bytes4  constant SKY_USDS_TO_DAI = 0x68f30150;
bytes4  constant SKY_DAI_TO_USDS = 0xf2c07aae;
address constant USDS_TOKEN      = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

uint256 constant PROTO_UNIV2   = 0;
uint256 constant PROTO_CURVE   = 2;
uint256 constant HOP_I_OFFSET  = 160;
uint256 constant HOP_J_OFFSET  = 168;
uint256 constant PROTO_UNIV3   = 1;
uint256 constant ZERO_FOR_ONE  = uint256(1) << 247;

uint256 constant DEFAULT_UNWIND_DEX =
    (PROTO_UNIV3 << 253) | uint256(uint160(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640));

uint256 constant DEFAULT_WBTC_DEX =
    (PROTO_UNIV3 << 253) | uint256(uint160(0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35));
address constant WBTC_TOKEN = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

interface IUniV3PoolMin {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant RLUSD_TOKEN                = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
address constant PYUSD_TOKEN                = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
address constant CURVE_USDC_RLUSD      = 0xD001aE433f254283FeCE51d4ACcE8c53263aa186;
int128  constant CRV_RLUSD_IDX         = 1;
int128  constant CRV_RLUSD_USDC_IDX    = 0;
address constant CURVE_PYUSD_USDC      = 0x383E6b4437b59fff47B619CBA855CA29342A8559;
int128  constant CRV_PYUSD_IDX         = 0;
int128  constant CRV_PYUSD_USDC_IDX    = 1;

address constant CURVE_3POOL           = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
address constant USDT_TOKEN            = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
int128  constant CRV_USDT_IDX          = 2;
int128  constant CRV_USDT_USDC_IDX     = 1;
address constant DAI_TOKEN             = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
int128  constant CRV_DAI_IDX           = 0;
int128  constant CRV_DAI_USDC_IDX      = 1;
address constant CRVUSD_TOKEN          = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

address constant CURVE_BOLD_USDC       = 0xEFc6516323FbD28e80B85A497B65A86243a54B3E;
int128  constant CRV_BOLD_IDX          = 0;
int128  constant CRV_BOLD_USDC_IDX     = 1;
address constant BOLD_TOKEN            = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
address constant CURVE_CRVUSD_USDC     = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
int128  constant CRV_CRVUSD_IDX        = 1;
int128  constant CRV_CRVUSD_USDC_IDX   = 0;

interface IEtherFiLiquidityPool { function requestWithdraw(address r, uint a) external returns (uint); }

interface IDepositAdapter {
    function depositWETHForWeETH(uint _amount, address _referral) external;
    function weETH() external view returns (address);
}

interface ILevEquity {

    function ORACLE_KEY() external view returns (address);
    function totalGrossCollateral() external view returns (uint256);
    function totalNetEquity() external view returns (uint256);
    function netEquity(address lp) external view returns (uint);
    function grossCollateral(address lp) external view returns (uint);
    function debtUsd(address lp) external view returns (uint);
    function totalDebtUsd() external view returns (uint256);
}

interface ILevClose { function closeLevFor(address lp, uint256 minOut) external; }

interface ILevPooled {
    function repayPool(uint256 stableAmount) external returns (uint256 repaid);
    function withdrawPool(uint256 collAmount) external returns (uint256 got);
    function totalDebt() external view returns (uint256);
    function totalCollateral() external view returns (uint256);
}

interface ICollection {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function getApproved(uint tokenId) external view returns (address);
}

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns ( uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface ISwap {
    function swap(address token, address asset, bool forVolatile, uint256 amount, uint256 minOut, bool loadBalance)
        external payable returns (uint256);

    function assetPrice(address asset) external view returns (uint256 price);
    function assetPriceStale(address asset) external view returns (uint256 price, bool stale);

}

interface IAux is ISwap {

    function assetPriceFeed(address asset) external view returns (address);
    function vaults(address) external returns (address);
    function tranche(address) external returns (uint);
    function take(address who, uint amount, address token, uint seed) external returns (uint);
    function takeWith(address who, uint amount, address token, uint seed, uint[16] memory amounts) external returns (uint);
    function riskFactor(address token) external view returns (uint);
    function getDepegSeverityBps(address token) external view returns (uint);
    function get_metrics(bool force) external returns (uint total, uint avgYield);
    function get_metricsWith(uint raw, uint rateWeighted) external returns (uint total, uint avgYield);
    function rangeETH() external view returns (uint);
    function deliverableETH() external view returns (uint);
    function get_deposits() external returns (uint[16] memory amounts, uint[16] memory yieldW, uint avgYield, uint depegLoss);
    function getStables() external view returns (address[] memory);
    function getVaults(address stable) external view returns (address[] memory);
    function ethVenue() external view returns (address);
    function deposit(address from, address token, uint amount) external returns (uint);
    function avgYield() external view returns (uint);
    function vaultBlocked(address vault) external view returns (bool);
    function toIndex(address token) external view returns (uint);
    function supplySelf(address token, uint amount) external returns (uint);
    function withdrawSelf(address token, uint amount, address to) external returns (uint);
    function checkBacking() external returns (uint committedSum, uint totalLiquid);
    function takeToSettle(address who, uint amount, address token) external returns (uint);
    function WBTC() external view returns (address);

    function WETH() external view returns (address);
    function tokens(address vault) external view returns (address);
    function illiquidLoss() external view returns (uint);
    function illiquidLossFlagging() external returns (uint);
    function flagIlliquidSelf(address vault, bool illiquid) external;

    function spendClaim(address owner, uint usd6) external returns (uint funded6);
    function _depositVol(address asset, address sender, uint amount) external payable returns (uint sent);
    function tipSelf(uint cut, address token, int sign) external;
    function bumpQuidBTC(uint amount) external;
    function vaultHealth(address) external view returns (bool blocked, uint40 flaggedAt);
    function trancheTotal() external view returns (uint);
    function refreshHoldingsSelf(address stable) external;
    function refreshAllHoldingsSelf() external;
    function tryCheckBacking() external returns (uint committedSum, uint totalLiquid);
    function redeem(uint amount) external;
}

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint256);
}

interface IWETH9 is IERC20Min { function deposit() external payable; function withdraw(uint256) external; }

interface ILevVenue {

    function supply(address lp, uint256 collAmount) external returns (uint256 supplied);

    function borrow(address lp, uint256 stableAmount) external returns (uint256 borrowed);

    function accrue() external;

    function repay(address lp, uint256 stableAmount) external returns (uint256 repaid);

    function withdraw(address lp, uint256 collAmount) external returns (uint256 withdrawn);

    function debtOf(address lp) external view returns (uint256);

    function collateralOf(address lp) external view returns (uint256);

    function stable() external view returns (address);

    function COLLATERAL() external view returns (address);

    function liqThresholdBps() external view returns (uint256);

    function position() external view returns (VenuePosition memory);

    function supplyHeadroom() external view returns (uint256);

    function positionOf(address lp) external view returns (VenuePosition memory);

    function borrowRateRay(uint256 extraBorrow) external view returns (uint256);
}

interface ICore {
    function drawPooledUsdBtc(uint usd6) external;
    function subPendingSwapOut(uint usd6) external;
    function committedUsd18() external view returns (uint);
    function modLP(int256 delta, int256 deltaUSD, address sender) external returns (uint sent);

    function settleOor(address owner, int256 usdDelta, int256 volDelta, bool loadBalance) external;
    function POOLED() external view returns (uint);
    function btcBacking() external view returns (uint);
    function poolStats() external view returns (uint priceWad, uint liquidity);

    function POOLED_USD() external view returns (uint);

    function basketUsd() external view returns (uint);
    function pendingSwapOutUsd() external view returns (uint);
    function levClaimUsd6() external view returns (uint);

    function recordFee(uint256 premiumUsd, uint256 premiumNative) external;
    function retainedNativeFee() external view returns (uint256);
    function refundUnfilled(address token, uint amount, address to) external;
    function repack(uint anchorPrice) external returns (uint price);

    function btc() external view returns (address);

    function rangeEquityUsd18() external view returns (uint);
    function swap(address recipient, bool inputIsUsd, address token, uint amount, bool loadBalance) external returns (uint);

    function addLiq(uint deltaTok, uint price) external returns (uint usdOut, uint outDelta);

    function creditFee(uint premium6) external;

    function levManager() external view returns (address);

    function levGrossNative() external view returns (uint);

    function sharesForShortfall() external view returns (uint);

    function realInventory() external view returns (uint);

    function onShortfall(address sender, uint shortfall) external;

    function deliverVolatile(uint amount, address who) external returns (uint sent);

    function repack() external returns (uint price, uint lower, uint upper, uint liquidity, uint);

    function rangeBounds() external view returns (uint lo, uint hi);
    function feesPerShare() external view returns (uint);
    function USD_FEES() external view returns (uint);

    function CORE() external view returns (address);

    function unwindForRedeem(uint usdWanted) external returns (uint usdFreed);
    function pendingRewards(address user) external view returns (uint ethReward, uint usdReward);
    function setBTCChannels(address b) external;

    function syncLev(address lp) external;
    function soldFractionWad(uint syncKeyPx) external view returns (uint256);
    function rangePrice() external view returns (uint);
}

interface IEthVenue {
    function rangeETH() external view returns (uint);
    function deliverableETH() external view returns (uint);
    function supplyFromAux(uint amount) external returns (uint);
    function withdrawForAux(uint amount, address to) external returns (uint);
    function rangeOp(uint amount, uint8 op) external returns (uint);
    function supplyEtherFi(uint amount) external returns (uint);

    function LEV_MANAGER() external view returns (address);
}

interface IBTCChannels {
    function btcRecipientOf(address user) external view returns (bytes32);

    function btcRecipientPoPDigest(address lpEth, bytes32 bindHash) external view returns (bytes32);
}

interface ILevSweep { function deleverBook(uint256 usdWanted, address sink, uint256 minOut) external returns (uint256 freed); }

interface IWiredBasket { function AUX() external view returns (address);
                         function BTC_VAULT() external view returns (address); }

interface IWiredVault { function btcChannels() external view returns (address);
                        function LEV_MANAGER() external view returns (address); }

interface IBasket {
    function turn(address from, uint value) external returns (uint sent, uint seedBurned);
    function matureSupply() external view returns (uint);
    function immatureBalanceOf(address who) external view returns (uint);

    function target() external view returns (uint);

    function mint(address pledge, uint amount, address token, uint when) external returns (uint);
}

interface ILevManagerDeliver {
    function swapOutDeleverAmt(address lp, uint maxUsd18)
        external view returns (address venue, address stable, uint amtNative);
    function swapOutDelever(address lp, uint stableUsd, uint freeSats)
        external returns (uint usedUsd);

    function consolidateForRepay(address lp, address refundTo) external returns (uint sent);
}

interface ILevEthDeliver {
    function swapOutDeleverAmt(address lp, uint maxUsd18)
        external view returns (address venue, address stable, uint amtNative);

    function poolVenue() external view returns (address);

    function swapOutDeleverPooled(address venue, uint stableUsd, address recipient, uint minWethOut,
        uint askNative) external returns (uint usedUsd, uint wethDelivered);
    function swapOutDeliverUnlevered(address lp, uint wethWanted, address recipient, uint minWethOut)
        external returns (uint wethDelivered);
}

interface IBtc {

    function requestDeposit(address lpEth, uint sats) external;
    function requestRedeem(address lpEth, uint lpPayoutSats) external;

    function resize(address lpEth, uint shrinkSats, uint lpPayoutSats, uint exactUsd) external;

    function creditSwapIn(address seller, uint sats, address token, uint minDeliveredUsd) external returns (uint consumedSats);
    function creditSwapOut(address swapper, address token, uint usdAmount, uint minSats)
        external returns (uint sats, uint usd6);

    function addPendingSwapOut(uint usd6) external;
    function subPendingSwapOut(uint usd6) external;
}

interface IVBtcRange {
    function totalShares() external view returns (uint);
    function sharesOf(address lp) external view returns (uint);
    function transferShares(address from, address to, uint amount) external;
    function redeemVBtc(address holder, uint sats) external;
}

interface IStabilityPool {
    function provideToSP(uint _topUp, bool _doClaim) external;
    function withdrawFromSP(uint _amount, bool _doClaim) external;
    function getCompoundedBoldDeposit(address _depositor) external view returns (uint);
    function getDepositorYieldGainWithPending(address _depositor) external view returns (uint);
}

interface ICurveOracle {
    function price_oracle(uint256 k) external view returns (uint256);
    function price_oracle() external view returns (uint256);
}

interface IOffchainOracle {
    function getRate(address srcToken, address dstToken, bool useWrappers)
        external view returns (uint256 weightedRate);

    function getRateToEth(address srcToken, bool useWrappers) external view returns (uint256);
}

struct VenuePosition {
    uint256 collateral;
    uint256 debt;
    uint256 liqThresholdBps;
}

struct MorphoMarket {
    uint128 totalSupplyAssets; uint128 totalSupplyShares;
    uint128 totalBorrowAssets; uint128 totalBorrowShares;
    uint128 lastUpdate;        uint128 fee;
}

interface IIrm {
    function borrowRateView(MarketParams memory marketParams, MorphoMarket memory market)
        external view returns (uint256);
}

