// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";

import {BasketLib} from "./imports/BasketLib.sol";
import {WAD, AlreadyInitialized, InsufficientAllowance} from "./imports/Types.sol";
import {ILevEquity, ILevClose} from "./imports/Interfaces.sol";
import {LevMath} from "./imports/LevMath.sol";
import {IDepositAdapter} from "./imports/Interfaces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SwapLib} from "./imports/SwapLib.sol";
import {QuidLib} from "./imports/QuidLib.sol";
import {RangeLib} from "./imports/RangeLib.sol";

import {Types} from "./imports/Types.sol";

import {Basket} from "./Basket.sol";
import {Shares} from "./Shares.sol";
import {Core} from "./Core.sol";
import {Aux} from "./Aux.sol";

contract Quid is Shares,
    Ownable {
    error WrongQuid();
    error NoPosition();
    error InsufficientBalance();
    error AllowanceFlow();
    error ZeroTwap();

    uint private locked = 1;
    function _lock()   private { require(locked == 1, "REENTRANCY"); locked = 2; }
    function _unlock() private { locked = 1; }
    modifier nonReentrant { _lock(); _; _unlock(); }

    Core public CORE; WETH9 WETH;

    uint public LAST_REPACK;

    Basket QUID; Aux AUX;

    address public constant ETHERFI_ADAPTER    = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address public constant ETHERFI_CURVE_POOL = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;
    address public constant ETHERFI_LP         = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address public constant ETHERFI_EETH       = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;

    address public WEETH;

    error NotSelf();
    error NotAux();

    function _onlyPinner() internal view override { require(msg.sender == DEPLOYER, "403"); }
    function _rangeAsset() internal view override returns (address) { return address(WETH); }

    function _etherfiCfg() internal view returns (SwapLib.OfframpCfg memory) {
        return SwapLib.OfframpCfg({
            weeth: WEETH, weth: address(WETH), curvePool: ETHERFI_CURVE_POOL, lp: ETHERFI_LP
        });
    }

    function _levManager() private view returns (address) {
        return QuidLib.levManager(address(AUX));
    }

    function _wethTwap() private view returns (uint) {
        return AUX.assetPrice(address(WETH));
    }

    function _auxRangeETH() private view returns (uint) {
        return AUX.rangeETH();
    }

    function _usdLegs6() private view returns (uint usd6, uint base6) {
        usd6 = _corePooledUsd6(); base6 = CORE.basketUsd();
    }

    function _corePooled()     private view returns (uint) { return CORE.POOLED(); }
    function _corePooledUsd6() private view returns (uint) { return CORE.POOLED_USD(); }
    function _corePrice()      private view returns (uint p) { (p,) = CORE.poolStats(); }

    function _mintQuid(address to, uint usd6) private {
        QUID.mint(to, usd6 * 1e12, address(QUID), 0);
    }

    function _ethCfg() internal view returns (QuidLib.EthCfg memory) {
        return QuidLib.EthCfg({
            weth: address(WETH), aux: address(AUX), curvePool: ETHERFI_CURVE_POOL,
            weeth: WEETH, eeth: ETHERFI_EETH, levManager: LEV_MANAGER
        });
    }

    function supplyEtherFi(uint amount) public returns (uint) {
        return QuidLib.supplyVenueBody(_ethCfg(), amount, address(this));
    }

    function offrampEtherFi(uint amount, address recipient) internal returns (uint served) {
        return QuidLib.offrampBody(amount, recipient, _etherfiCfg());
    }

    function rangeETH() public view returns (uint) {
        return QuidLib.rangeETH(_ethCfg());
    }

    function rangeOp(uint amount, uint8 op) public returns (uint sent) {
        if (msg.sender != address(this)) revert NotSelf();
        sent = SwapLib.rangeOpBody(amount, op, WETH, rangeETH());
    }

    function deliverableETH() external view returns (uint total) {
        return QuidLib.deliverableETH(_ethCfg());
    }

    function withdrawSelf(address token, uint amount, address to) external returns (uint sent) {
        if (msg.sender != address(this)) revert NotSelf();
        return _withdrawETH(token, amount, to);
    }

    function supplyFromAux(uint amount) external returns (uint) {
        if (msg.sender != address(AUX)) revert NotAux();
        return QuidLib.supplyVenueBody(_ethCfg(), amount, address(AUX));
    }

    function withdrawForAux(uint amount, address to) external returns (uint) {
        if (msg.sender != address(AUX)) revert NotAux();
        return _withdrawETH(address(WETH), amount, to);
    }

    function _withdrawETH(address token, uint amount, address to) internal returns (uint sent) {
        return QuidLib.withdrawETH(_ethCfg(), _etherfiCfg(), token, amount, to);
    }

    uint public bookmark;

    uint public venueFeesPerShare;
    mapping(address => uint) public venueBm;

    uint public totalLevPooled;

    function totalShares() public view returns (uint) {
        return lpShares;
    }

    function rangeOf(address lp) external view returns (uint) {
        uint p = autoManaged[lp].pooled;
        uint lev = levPooled[lp];
        return SwapLib.plainNet(p, lev);
    }

    mapping(address => address) public pinnedRecipient;
    mapping(address => address) public pendingRecipient;
    mapping(address => uint)    public recipientUnlockAt;
    uint public constant RECIPIENT_TIMELOCK = 3 days;

    error RecipientNotPinned();
    error RecipientTimelocked();
    event RecipientPinRequested(address indexed lp, address indexed to, uint effectiveAt);
    event RecipientPinned(address indexed lp, address indexed to);

    function pinRecipient(address to) external {
        if (pinnedRecipient[msg.sender] == address(0)) {
            pinnedRecipient[msg.sender] = to;
            emit RecipientPinned(msg.sender, to);
        } else {
            pendingRecipient[msg.sender] = to;
            recipientUnlockAt[msg.sender] = block.timestamp + RECIPIENT_TIMELOCK;
            emit RecipientPinRequested(msg.sender, to, block.timestamp + RECIPIENT_TIMELOCK);
        }
    }

    function applyPinnedRecipient() external {
        uint at = recipientUnlockAt[msg.sender];
        if (at == 0 || block.timestamp < at) revert RecipientTimelocked();
        address to = pendingRecipient[msg.sender];
        pinnedRecipient[msg.sender] = to;
        delete pendingRecipient[msg.sender];
        delete recipientUnlockAt[msg.sender];
        emit RecipientPinned(msg.sender, to);
    }

    function _requirePinnedRecipient(address owner, address receiver) internal view {
        address pin = pinnedRecipient[owner];
        if (pin != address(0) && receiver != pin) revert RecipientNotPinned();
    }

    mapping(address => uint) public lastDepositBlock;

    address immutable DEPLOYER;

    uint256 private immutable OOR_CHAINID;
    bytes32 private immutable OOR_DOMAIN_SEP;

    constructor()
        Ownable(msg.sender) {
        DEPLOYER = msg.sender;
        OOR_CHAINID = block.chainid;
        OOR_DOMAIN_SEP = _computeOorDomain();
    }

    receive() external payable {}

    function _computeOorDomain() private view returns (bytes32) {
        return keccak256(abi.encode(SwapLib.OOR_DOMAIN_TYPEHASH,
            keccak256("QuidOor"), keccak256("1"), block.chainid, address(this)));
    }

    function _oorDomain() private view returns (bytes32) {
        return block.chainid == OOR_CHAINID ? OOR_DOMAIN_SEP : _computeOorDomain();
    }

    function _onlyUs() private view {
        require(msg.sender == address(AUX)
             || msg.sender == address(CORE)
             || msg.sender == address(this), "403");
    }
    modifier onlyUs { _onlyUs(); _; }

    function setup(address _quid,
        address _aux, address _core) external onlyOwner {
        if (address(AUX) != address(0)) revert AlreadyInitialized();
        AUX = Aux(payable(_aux)); CORE = Core(_core);
        QUID = Basket(_quid);
        renounceOwnership();
        if (QUID.RANGE() != address(this)) revert WrongQuid();

        address weth;
        uint lo_; uint hi_;
        (weth, lo_, hi_) = QuidLib.setupBody(_aux, _core);

        RANGE_ANCHOR = (lo_ + hi_) / 2;
        WETH = WETH9(payable(weth));

        WEETH = IDepositAdapter(ETHERFI_ADAPTER).weETH();
        IERC20(weth).approve(ETHERFI_ADAPTER, type(uint).max);
        IERC20(ETHERFI_EETH).approve(ETHERFI_LP, type(uint).max);
    }

    function pendingRewards(address user) public view returns (uint ethReward, uint usdReward) {
        return _pendingFor(user);
    }

    function _refreshBookmarks(address user,
        uint tokAccum, uint usdAccum) internal {
        Types.Deposit storage LP = autoManaged[user];

        SwapLib.refreshBookmarks(LP, LP.pooled + levBuf[user], tokAccum, usdAccum);

        venueBm[user] = _venueAccrued(user, LP.pooled);
    }

    function _venueAccrued(address user, uint pooled) private view returns (uint) {
        return SoladyMath.fullMulDiv(
            SwapLib.plainNet(pooled, levPooled[user]), venueFeesPerShare, WAD);
    }

    function _creditShares(Types.Deposit storage LP, uint amount) private {
        LP.pooled += amount; lpShares += amount;
    }
    function _debitShares(Types.Deposit storage LP, uint amount) private {
        LP.pooled -= amount; lpShares -= amount;
    }

    function _settlePending(Types.Deposit storage LP,
        address user, address mintRecipient) internal {
        if (LP.pooled == 0) return;
        (uint tokR,
         uint usdR) = _pendingFor(user);
        if (tokR > 0) _creditShares(LP, tokR);
        if (mintRecipient != address(0)) {
            usdR += LP.usd_owed;
            if (usdR > 0) {
                LP.usd_owed = 0;

                _mintQuid(mintRecipient, usdR);
            }
        } else if (usdR > 0) {
            LP.usd_owed += usdR;
        }
    }

    function _pendingFor(address user)
        internal view returns (uint tokReward, uint usdReward) {
        Types.Deposit storage LP = autoManaged[user];

        (tokReward, usdReward) = SwapLib.pendingFor(LP, LP.pooled + levBuf[user], feesPerShare, USD_FEES);

        uint venueOwed = _venueAccrued(user, LP.pooled);
        if (venueOwed > venueBm[user]) tokReward += venueOwed - venueBm[user];
    }

    function _burnInRange(uint amount, address recipient)
        internal returns (uint sent) {
        return SwapLib.burnInRange(address(CORE), amount, recipient);
    }

    function _deliverVenueShortfall(uint amount, uint shortfall, uint plainDepth, address recipient)
        private returns (uint excess) {
        uint venueBal = _venueBalance();
        uint vaultShare = plainDepth > 0 ? SoladyMath.fullMulDiv(venueBal, amount, plainDepth) : venueBal;
        excess = Math.min(shortfall, vaultShare);
        if (excess > 0) excess = _sendETH(excess, recipient);
    }

    function _burnAndDeliverUsdLeg(uint burnAmt, uint claimAmt, address recipient)
        private returns (uint sent) {
        uint incrPre = _rangeIncrement6();
        sent = _burnInRange(burnAmt, recipient);
        sent += _payUsdLeg(incrPre, lpShares + claimAmt, claimAmt, recipient);
    }

    function _rangeIncrement6() private view returns (uint) {
        (uint usd6, uint base6) = _usdLegs6();
        return usd6 > base6 ? usd6 - base6 : 0;
    }

    function _payUsdLeg(uint incrPre, uint denom, uint claimAmt, address recipient)
        private returns (uint ethEquiv) {
        if (incrPre == 0 || denom == 0 || claimAmt == 0) return 0;
        uint owed6 = claimAmt >= denom ? incrPre : SoladyMath.fullMulDiv(incrPre, claimAmt, denom);
        if (owed6 == 0) return 0;

        uint px = _wethTwap();
        if (px == 0) revert ZeroTwap();
        _mintQuid(recipient, owed6);

        CORE.absorbPaidUsd(incrPre - owed6);
        ethEquiv = SoladyMath.fullMulDiv(owed6 * 1e12, 1e18, px);
    }

    function _withdraw(uint amount, address recipient) internal {

        AUX.tryCheckBacking();

        _reconcileLev(msg.sender);
        Types.Deposit storage LP = autoManaged[msg.sender];
        if (LP.pooled == 0) revert NoPosition();

        require(block.number > lastDepositBlock[msg.sender], "too soon");
        _rebalance();

        _settlePending(LP, msg.sender, address(0));

        if (levPooled[msg.sender] > 0 && amount > SwapLib.plainNet(LP.pooled, levPooled[msg.sender])) {
            ILevClose(_levManager()).closeLevFor(msg.sender, 0);
            _reconcileLev(msg.sender);
        }

        amount = Math.min(amount, SwapLib.plainNet(LP.pooled, levPooled[msg.sender]));

        if (amount > 0) {

            uint ethfiPart = amount;
            if (ethfiPart > 0) {
                uint incrPre = _rangeIncrement6();
                uint served = offrampEtherFi(ethfiPart, recipient);

                if (served > 0) {
                    _burnInRange(served, address(0));

                    _payUsdLeg(incrPre, lpShares, served, recipient);
                    _debitShares(LP, served);
                    amount -= served;
                } else if (incrPre > 0) {

                    uint usdEq = _payUsdLeg(incrPre, lpShares, ethfiPart, recipient);
                    if (usdEq > 0) {
                        _burnInRange(usdEq, address(0));
                        _debitShares(LP, usdEq);
                        amount -= usdEq;
                    }
                }
            }
        } if (amount > 0) {

            uint plainDepth = lpShares > totalLevPooled ?
                            lpShares - totalLevPooled : 0;

            _debitShares(LP, amount);

            uint deliverable = AUX.deliverableETH();
            uint firstBurn = amount > deliverable ? deliverable : amount;

            uint sent = firstBurn > 0 ? _burnAndDeliverUsdLeg(firstBurn, amount, recipient) : 0;

            if (amount > sent) { uint shortfall = amount - sent;
            {

                uint excess = _deliverVenueShortfall(amount, shortfall, plainDepth, recipient);
                sent += excess; shortfall -= excess;
            }

            if (shortfall > 0) _creditShares(LP, shortfall);

                                                    bookmark = _venueBalance();
            }
        }

        if (LP.pooled == 0 && LP.usd_owed > 0) {
            uint owed = LP.usd_owed; LP.usd_owed = 0;

            _mintQuid(recipient, owed);
        }
        _onExit(LP, msg.sender);
    }

    function _onExit(Types.Deposit storage LP,
                        address user) internal {
        if (LP.pooled == 0) {
            delete autoManaged[user];

            if (levBuf[user] > 0) { totalBuffer -= levBuf[user]; delete levBuf[user]; }

            if (lpShares == 0 && totalBuffer == 0) {
                feesPerShare = 0; USD_FEES = 0;
                venueFeesPerShare = 0; totalLevPooled = 0;
            }
        } else {
            _refreshBookmarks(user,
            feesPerShare, USD_FEES);
        }
    }

    function _modLpEth(uint deltaETH, uint deltaUSD, address pledge) private {
        CORE.modLP(-int256(deltaETH), -int256(deltaUSD), pledge);
    }

    function syncLev(address lp) external { _reconcileLev(lp); }

    function _reconcileLev(address lp) internal {
        address lm = _levManager();
        uint gross = lm == address(0) ? 0 : ILevEquity(lm).grossCollateral(lp);

        if (gross == 0 && levPooled[lp] == 0 && levBuf[lp] == 0 && levBufferUsd[lp] == 0) return;

        if (gross == levPooled[lp] + levBuf[lp] && levBufferUsd[lp] == QuidLib.bufTarget(lm, lp)) return;
        _doReconcile(lp, lm, gross);
    }

    function _doReconcile(address lp, address lm, uint gross) private {
        Types.Deposit storage LP = autoManaged[lp];
        Types.RangeP memory p;
        (p.spotPrice, p.loPrice, p.upPrice,,) = _rebalance();
        p.mgr = lm; p.gross = gross;
        _settlePending(LP, lp, address(0));
        (uint addedNet, uint burnedNet, uint bufAdded, uint bufBurned) = QuidLib.reconcileLegs(
            Types.RangeCfg(address(CORE), address(AUX), address(WETH)),
            LP, levPooled, levBufferUsd, levBuf, lp, p);
        lpShares = lpShares + addedNet - burnedNet;
        totalLevPooled = totalLevPooled + addedNet - burnedNet;
        totalBuffer = totalBuffer + bufAdded - bufBurned;
        _onExit(LP, lp);
    }

    function _depositImpl(uint amount, address pledge) internal {

        lastDepositBlock[pledge] = block.number;

        AUX.checkBacking();

        uint price = _wethTwap();

        if (price == 0) revert ZeroTwap();
        uint deltaETH; uint deltaUSD;

        if (amount == 0 &&
         msg.value == 0) return;

        Types.Deposit storage LP = autoManaged[pledge];
        _rebalance();

        amount = _depositETH(msg.sender, amount);

        if (amount == 0) return;

        _settlePending(LP, pledge, address(0));
        (deltaUSD, deltaETH) = this.addLiq(                      amount, price);
        if (deltaETH > 0) {
            _creditShares(LP, deltaETH);
            _refreshBookmarks(pledge,
            feesPerShare, USD_FEES);

            _modLpEth(deltaETH, deltaUSD, pledge);
        }
        uint unpaired = amount - deltaETH;
        if (unpaired > 0) {

            _creditShares(LP, unpaired);
            _refreshBookmarks(pledge, feesPerShare, USD_FEES);
        }

        bookmark = _venueBalance();
    }

    function _venueBalance() internal returns (uint) {
        return QuidLib._venueBalanceLib(address(this), address(AUX));
    }

    function soldFractionWad(uint syncKeyPx) public view returns (uint) {
        return SwapLib.soldFractionWad(syncKeyPx, _corePrice(), _lo(), _hi());
    }

    function rangePrice() external view returns (uint priceWad) {
        return _corePrice();
    }

    function addLiq(
        uint deltaTok, uint price) public
        onlyUs returns (uint usdOut, uint outDelta) {

        return QuidLib.addLiq(address(CORE), address(AUX), deltaTok, price, totalBuffer);
    }

    mapping(address => mapping(uint64 => bool)) public intentUsed;

    function fillIntent(SwapLib.OorIntent calldata i, bytes calldata sig, bytes[] calldata routes)
        external nonReentrant returns (bool) {
        (int usdDelta, int volDelta, uint wantUsd6) = SwapLib.fillIntentBody(
            intentUsed, i, sig, address(CORE), address(AUX), address(WETH), _oorDomain());
        if (wantUsd6 > 0) usdDelta = _settleSellIntent(i, wantUsd6, routes);

        CORE.settleOor(i.owner, usdDelta, volDelta, i.loadBalance);
        emit IntentFilled(i.owner, i.nonce, i.size, i.limitPx, i.buyVolatile);
        return true;
    }

    function _convertShortfall(SwapLib.OorIntent calldata i, uint short18, bytes[] calldata routes)
        private returns (uint) {
        return LevMath.convertShortfall(address(AUX), address(QUID), i.payoutToken, i.owner, short18, routes);
    }

    function _settleSellIntent(SwapLib.OorIntent calldata i, uint wantUsd6, bytes[] calldata routes)
        private returns (int) {

        if (AUX.toIndex(i.payoutToken) == 0) revert IntentUnpayable();

        Types.Deposit storage LP = autoManaged[i.owner];
        uint cap = SwapLib.plainNet(LP.pooled, levPooled[i.owner]);
        if (cap == 0) revert NoPosition();
        uint capUsd6 = (cap * i.limitPx / 1e18) / 1e12;
        uint ask6 = wantUsd6 < capUsd6 ? wantUsd6 : capUsd6;
        if (ask6 == 0) revert IntentUnpayable();

        uint sent = AUX.take(i.owner, BasketLib.from6(ask6, i.payoutToken), i.payoutToken, 0);
        uint proceeds6 = sent / 1e12;
        if (proceeds6 == 0) revert IntentUnpayable();

        if (proceeds6 < ask6) {
            if (!i.loadBalance) revert PartialFillNotConsented();
            if (routes.length > 0)
                proceeds6 += _convertShortfall(i, (ask6 - proceeds6) * 1e12, routes);
        }

        uint etherSold = (proceeds6 * 1e12) * 1e18 / i.limitPx;
        if (etherSold > cap) etherSold = cap;
        _debitShares(LP, etherSold);
        return int(proceeds6);
    }

    error IntentUnpayable();

    error PartialFillNotConsented();

    event IntentFilled(address indexed owner, uint64 indexed nonce, uint size, uint limitPx, bool buyVolatile);

    function _depositETH(address sender,
        uint amount) internal returns (uint sent) {
        return QuidLib.depositETH(address(WETH), address(AUX), address(this),
            sender, amount);
    }

    function unwindForRedeem(uint usdWanted) external onlyUs returns (uint usdFreed) {
        if (usdWanted == 0) return 0;
        uint usd6 = _corePooledUsd6();
        uint eth  = _corePooled();
        if (usd6 == 0 || eth == 0) return 0;
        _rebalance();

        _burnInRange(SoladyMath.fullMulDiv(usdWanted, eth, usd6 * 1e12), address(0));
        uint after6 = _corePooledUsd6();
        uint freed6 = usd6 > after6 ? usd6 - after6 : 0;
        usdFreed = freed6 * 1e12;
    }

    function creditFee(uint premium6) external onlyUs {
        (, uint usdInc) = SwapLib.feeIncrements(0, premium6, lpShares + totalBuffer);
        USD_FEES += usdInc;
    }

    function levManager() external view returns (address) {
        return LEV_MANAGER;
    }

    function sharesForShortfall() external view returns (uint) { return totalShares(); }

    function realInventory() external view returns (uint) { return _auxRangeETH(); }

    function onShortfall(address, uint) external {}

    function deliverVolatile(uint amount, address who) external onlyUs returns (uint) {
        return _sendETH(amount, who);
    }

    function _sendETH(uint howMuch,
       address toWhom) internal returns (uint sent) {
        return QuidLib.sendEth(address(WETH), address(this),
            address(AUX), howMuch, toWhom);
    }

    function _rebalance() internal returns (uint spotPrice,
        uint loPrice, uint upPrice, uint myLiquidity, uint anchorPrice) {
        QuidLib.RebalOut memory o = QuidLib.rebalanceBody(QuidLib.RebalIn({
            core: address(CORE), aux: address(AUX), ev: address(this), weth: address(WETH),
            lpShares: lpShares, totalLevPooled: totalLevPooled,
            totalBuffer: totalBuffer, loPrice: _lo(), upPrice: _hi(), bookmark: bookmark}));
        venueFeesPerShare += o.venueFeesPerShareInc;
        bookmark = o.newBookmark;

        feesPerShare += o.feesPerShareInc; USD_FEES += o.usdFeesInc;

        if (o.setLastRepack) LAST_REPACK = block.timestamp;
        RANGE_ANCHOR = o.spotPrice;
        return (o.spotPrice, o.loPrice, o.upPrice, o.myLiquidity, o.anchorPrice);
    }

    function repack() public onlyUs returns (uint spotPrice,
        uint loPrice, uint upPrice, uint myLiquidity, uint anchorPrice) {
        return _rebalance();
    }

    function reseat() public nonReentrant {
        _rebalance();
    }

    uint8  public constant decimals = 18;

    event Deposit(address indexed sender,
                  address indexed owner,
                uint assets, uint shares);

    event Withdraw(address indexed sender, address indexed receiver,
                   address indexed owner, uint assets, uint shares);

    string public constant name   = "QU!D Quid ETH LP";
    string public constant symbol = "vETH";

    function asset() external view returns (address) { return address(WETH); }

    function totalAssets() external view returns (uint) { return _auxRangeETH(); }

    function totalSupply() external view returns (uint) { return lpShares; }

    function balanceOf(address user) public view returns (uint) {
        return autoManaged[user].pooled;
    }

    function maxDeposit(address) external pure returns (uint) { return type(uint).max; }
    function maxMint(address) external pure returns (uint) { return type(uint).max; }
    function previewDeposit(uint assets) external view returns (uint) { return convertToShares(assets); }
    function previewMint(uint shares) external view returns (uint) { return convertToAssets(shares); }

    mapping(address => mapping(address => uint)) public allowance;
    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);

    function approve(address spender, uint amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint amount) external nonReentrant returns (bool) {
        _transferShares(msg.sender, to, amount);
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint amount) external nonReentrant returns (bool) {
        uint allowed = allowance[from][msg.sender];
        if (allowed != type(uint).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transferShares(from, to, amount);
        emit Transfer(from, to, amount);
        return true;
    }

    function _transferShares(address from, address to, uint amount) internal {
        if (amount > 0) _rebalance();
        lpShares += QuidLib.transferSharesBody(
            autoManaged, levPooled, levBuf, venueBm, from, to, amount, feesPerShare, USD_FEES, venueFeesPerShare);
    }

    function _pricingBacking() internal view returns (uint total) {
        total = _auxRangeETH();

        {
            (uint usd6, uint base6) = _usdLegs6();

            uint px = _wethTwap();
            if (px > 0 && usd6 != base6) {
                if (usd6 > base6) total += SoladyMath.fullMulDiv((usd6 - base6) * 1e12, 1e18, px);
                else {
                    uint down = SoladyMath.fullMulDiv((base6 - usd6) * 1e12, 1e18, px);
                    total = total > down ? total - down : 0;
                }
            }
        }
        address lm = _levManager();
        if (lm == address(0)) return total;

        try ILevEquity(lm).totalNetEquity() returns (uint live) {
            total = total > live ? total - live : 0;
        } catch {}
        total += totalLevPooled;
    }

    function _convert(uint amt, bool toShares) private view returns (uint) {
        uint total = _pricingBacking();
        if (lpShares == 0 || total == 0) return amt;
        return toShares ? SoladyMath.fullMulDiv(amt, lpShares, total)
                        : SoladyMath.fullMulDiv(amt, total, lpShares);
    }

    function convertToShares(uint assets) public view returns (uint) {
        return _convert(assets, true);
    }

    function convertToAssets(uint shares) public view returns (uint) {
        return _convert(shares, false);
    }

    function deposit(uint assets, address receiver)
        external payable nonReentrant returns (uint shares) {
        return _deposit4626(assets, receiver);
    }

    function _deposit4626(uint assets, address receiver)
        internal returns (uint shares) {
        require(receiver != address(0), "receiver");
        uint preShares = autoManaged[receiver].pooled;
        _depositImpl(assets, receiver);
        shares = autoManaged[receiver].pooled - preShares;
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint shares, address receiver)
        external payable nonReentrant returns (uint assets) {
        return _mint4626(shares, receiver);
    }

    function _mint4626(uint shares, address receiver) internal returns (uint assets) {
        assets = convertToAssets(shares);

        require(_deposit4626(assets, receiver) >= shares, "mint:short");
    }

    function redeem(uint shares, address receiver, address owner)
        external nonReentrant returns (uint assets) {

        if (owner != msg.sender) revert AllowanceFlow();
        _requirePinnedRecipient(owner, receiver);
        assets = convertToAssets(shares);
        _withdraw(assets, receiver);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function withdraw(uint assets, address receiver, address owner)
        external nonReentrant returns (uint shares) {
        if (owner != msg.sender) revert AllowanceFlow();
        _requirePinnedRecipient(owner, receiver);

        uint ceiling = autoManaged[msg.sender].pooled;
        if (assets > ceiling) assets = ceiling;
        shares = convertToShares(assets);
        _withdraw(assets, receiver);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function collectFees() external nonReentrant {
        Types.Deposit storage LP = autoManaged[msg.sender];
        if (LP.pooled == 0) revert NoPosition();
        _rebalance();
        uint eth_fees = feesPerShare;
        uint usd_fees = USD_FEES;
        _settlePending(LP, msg.sender, msg.sender);
        _refreshBookmarks(msg.sender, eth_fees, usd_fees);
    }

    uint private constant COMPOUND_GAS = 250_000;

    uint private constant COMPOUND_MAX_GASPRICE = 200 gwei;

    function compound(address lp) external nonReentrant {
        Types.Deposit storage LP = autoManaged[lp];
        if (LP.pooled == 0) return;
        _rebalance();
        uint eth_fees = feesPerShare;
        uint usd_fees = USD_FEES;
        (uint tokR, uint usdR) = _pendingFor(lp);

        uint gp  = tx.gasprice < COMPOUND_MAX_GASPRICE ? tx.gasprice : COMPOUND_MAX_GASPRICE;
        uint tip = gp * COMPOUND_GAS;
        if (tip > tokR / 2) tip = tokR / 2;

        uint sent = tip > 0 ? _burnInRange(tip, msg.sender) : 0;

        uint net = tokR > sent ? tokR - sent : 0;
        if (net > 0) _creditShares(LP, net);
        if (usdR > 0) LP.usd_owed += usdR;
        _refreshBookmarks(lp, eth_fees, usd_fees);
    }

    function rangeBounds() public view returns (uint lo, uint hi) {
        return SwapLib.updateBounds(RANGE_ANCHOR, SwapLib.RANGE_DELTA);
    }

    function _lo() internal view returns (uint) { (uint l,) = rangeBounds(); return l; }
    function _hi() internal view returns (uint) { (, uint h) = rangeBounds(); return h; }

}
