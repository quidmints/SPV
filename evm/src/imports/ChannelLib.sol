// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Types, BadSPV, InvalidParam} from "./Types.sol";
import {WAD} from "./Types.sol";

import {IAux, IStabilityPool} from "./Interfaces.sol";
import {IBasket} from "./Interfaces.sol";
import {BitcoinTx} from "./BitcoinTx.sol";

import {ISPVGateway} from "../spv/interfaces/ISPVGateway.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BasketLib} from "./BasketLib.sol";
import {FeeLib} from "./FeeLib.sol";
import {IEthVenue} from "./Interfaces.sol";

library ChannelLib {

    struct SPState {
        uint spValue;
        uint spTotalYield;
        uint spPrincipalTime;
        uint spLastUpdate;
    }

    struct SPWithdrawResult {
        uint sent;
        uint toRedeposit;
        uint wethGain;
        uint boldReceived;

        uint newSpValue;
        uint newSpTotalYield;
        uint newSpPrincipalTime;
        uint newSpLastUpdate;
    }

    function calcSPValue(address sp, address depositor,
        uint reserved, SPState memory state) external view returns
        (uint totalValue, uint yieldContrib) { if (sp == address(0)) return (0, 0);
        uint compounded = IStabilityPool(sp).getCompoundedBoldDeposit(depositor);
        uint yieldGain = IStabilityPool(sp).getDepositorYieldGainWithPending(depositor);
        totalValue = compounded + yieldGain; totalValue -= Math.min(totalValue, reserved);

        if (totalValue == 0) return (0, 0);

        uint currentPrincipalTime = state.spPrincipalTime +
        state.spValue * (block.timestamp - state.spLastUpdate);
        if (currentPrincipalTime > 0 && state.spTotalYield > 0) {
            uint rate = SoladyMath.fullMulDiv(state.spTotalYield,
                    WAD * 365 days, currentPrincipalTime);

            yieldContrib = SoladyMath.fullMulDiv(
               totalValue, WAD + rate, WAD);
        } else
            yieldContrib = totalValue;

    }

    function withdrawFromSP(address sp, address bold,
        address weth, uint amount, uint ethPrice,
        SPState memory state) internal returns (SPWithdrawResult memory r) {
        uint compounded = IStabilityPool(sp).getCompoundedBoldDeposit(address(this));
        uint yieldGain = IStabilityPool(sp).getDepositorYieldGainWithPending(address(this));
        uint totalBold = compounded + yieldGain;
        if (totalBold == 0) return r;

        amount = Math.min(amount, compounded);
        uint wethBefore = WETH9(payable(weth)).balanceOf(address(this));
        uint boldBefore = IERC20(bold).balanceOf(address(this));

        IStabilityPool(sp).withdrawFromSP(amount, true);

        r.boldReceived = IERC20(bold).balanceOf(address(this)) - boldBefore;
        r.wethGain = WETH9(payable(weth)).balanceOf(address(this)) - wethBefore;

        r.sent = Math.min(amount, r.boldReceived);

        r.toRedeposit = r.boldReceived - r.sent;

        r.newSpPrincipalTime = state.spPrincipalTime +
           state.spValue * (block.timestamp - state.spLastUpdate);
        r.newSpLastUpdate = block.timestamp;

        uint wethValueUSD = SoladyMath.fullMulDiv(r.wethGain, ethPrice, WAD);
        r.newSpTotalYield = state.spTotalYield + wethValueUSD;

        r.newSpValue = state.spValue > r.sent ? state.spValue - r.sent : 0;
        if (r.toRedeposit > 0) IStabilityPool(sp).provideToSP(r.toRedeposit, false);

    }

    struct SupplyCfg {
        address weth;
        address ethVenue;
        address bold;
    }

    function supplyBody(
        address token, uint amount, SupplyCfg memory cfg,
        mapping(address => address) storage vaults,
        mapping(address => address[]) storage vaultsOf,
        SPState storage sp
    ) external returns (uint deposited) {
        if (amount == 0) return 0;
        IAux aux = IAux(address(this));
        if (token == cfg.weth) {
            return IEthVenue(cfg.ethVenue).supplyFromAux(amount);
        }
        if (token == cfg.bold) {
            (sp.spValue, sp.spPrincipalTime, sp.spLastUpdate) =
                _depositToSPInline(vaults[token], amount, sp);
            return amount;
        }

        address[] memory vs = vaultsOf[token];
        if (vs.length == 0) revert VaultUnwired();
        address vault = address(0);
        uint lo = type(uint).max;
        for (uint j; j < vs.length; j++) {
            address vj = vs[j];
            uint bj;
            (bool blocked,) = aux.vaultHealth(vj);
            if (blocked) continue;
            try IERC4626(vj).balanceOf(address(this)) returns (uint sh) {
                try IERC4626(vj).convertToAssets(sh) returns (uint a) { bj = a; }
                catch { continue; }
            } catch { continue; }
            if (bj < lo) { lo = bj; vault = vj; }
        }
        if (vault == address(0)) revert VaultUnwired();
        deposited = IERC4626(vault).convertToAssets(
                IERC4626(vault).deposit(amount, address(this)));
        aux.refreshHoldingsSelf(token);
    }

    function withdrawBody(
        address token, uint amount, address to, SupplyCfg memory cfg,
        mapping(address => address) storage vaults,
        mapping(address => address[]) storage vaultsOf,
        SPState storage sp
    ) external returns (uint sent) {
        if (amount == 0) return 0;
        IAux aux = IAux(address(this));
        if (token == cfg.weth) {
            return IEthVenue(cfg.ethVenue).withdrawForAux(amount, to);
        }
        if (token == cfg.bold) {
            SPWithdrawResult memory r = withdrawFromSP(
                vaults[token], token, cfg.weth, amount,
                aux.assetPrice(cfg.weth), sp);
            if (r.boldReceived == 0) return 0;
            sp.spLastUpdate = r.newSpLastUpdate;
            sp.spTotalYield = r.newSpTotalYield;
            sp.spPrincipalTime = r.newSpPrincipalTime;
            sp.spValue = r.newSpValue;

            if (r.wethGain > 0) aux.supplySelf(cfg.weth, r.wethGain);

            if (to != address(this) && r.sent > 0) IERC20OZ(token).safeTransfer(to, r.sent);
            return r.sent;
        }

        address[] memory vs = vaultsOf[token];
        if (vs.length == 0) revert VaultUnwired();
        sent = FeeLib.multiVaultWithdrawBody(vs, amount, to);
        aux.refreshHoldingsSelf(token);
    }

    function _depositToSPInline(address sp_, uint amount, SPState storage state)
        private returns (uint newSpValue, uint newSpPrincipalTime, uint newSpLastUpdate) {
        newSpPrincipalTime = state.spPrincipalTime + state.spValue * (
                                 block.timestamp - state.spLastUpdate);
        newSpValue = state.spValue + amount;
        newSpLastUpdate = block.timestamp;
        IStabilityPool(sp_).provideToSP(amount, false);
    }

    uint   internal constant MIN_CONFIRMATIONS = 6;
    uint8  internal constant STATUS_OPEN       = 0;
    uint8  internal constant STATUS_CLOSED     = 2;

    error AmountMismatch();

    error VaultUnwired();
    error VaultAlreadySet();
    error VaultAssetMismatch();
    error ApproveFailed();
    error UnknownStable();
    error ZeroDeposit();
    error VaultBlocked();

    using SafeERC20 for IERC20OZ;

    function depositBody(
        address from, address token, uint amount,
        address quid, uint nStables
    ) external returns (uint usd) {
        IAux aux = IAux(address(this));

        address underlying = aux.tokens(token);
        if (underlying != address(0)) {

            amount = Math.min(
                IERC4626(token).convertToShares(amount),
                IERC4626(token).allowance(from, address(this)));
            usd = IERC4626(token).convertToAssets(amount);
            if (usd == 0) revert ZeroDeposit();

            (bool blocked,) = aux.vaultHealth(token);
            if (blocked) revert VaultBlocked();
            IERC20OZ(token).safeTransferFrom(from, address(this), amount);
            token = underlying;
            aux.refreshHoldingsSelf(token);
        } else {

            uint index = aux.toIndex(token);
            if (!(index > 0 && index <= nStables)) revert UnknownStable();
            usd = Math.min(amount, IERC20(token).allowance(from, address(this)));
            IERC20OZ(token).safeTransferFrom(from, address(this), usd);
            if (usd == 0) revert ZeroDeposit();
            usd = aux.supplySelf(token, usd);
        }

        uint rf = aux.riskFactor(token);
        if (rf < 10000) usd = SoladyMath.fullMulDiv(usd, rf, 10000);

        uint _target = IBasket(quid).target();
        if (aux.trancheTotal() < _target && msg.sender == quid) {
            aux.get_metrics(false);
            uint fee = BasketLib.seedFee(usd, aux.trancheTotal(), _target, aux.avgYield());
            if (fee > 0) aux.tipSelf(fee, token, 1);
        }

        if (msg.sender == quid) aux.refreshAllHoldingsSelf();
    }

    function setVaultBody(
        address stable, address vault, uint nStables,
        mapping(address => uint) storage toIndex,
        mapping(address => address[]) storage vaultsOf,
        mapping(address => address) storage tokens,
        mapping(address => address) storage vaults
    ) external {
        uint index = toIndex[stable];
        if (!(index > 0 && index <= nStables)) revert UnknownStable();
        if (vault == address(0)) revert VaultUnwired();
        address[] storage set = vaultsOf[stable];
        if (IERC4626(vault).asset() != stable) revert VaultAssetMismatch();
        for (uint j; j < set.length; j++)
            if (set[j] == vault) revert VaultAlreadySet();
        tokens[vault] = stable;
        if (vaults[stable] == address(0)) vaults[stable] = vault;
        set.push(vault);
        _approveMax(stable, vault);
    }

    function _approveMax(address token, address spender) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(0x095ea7b3, spender, type(uint).max));
        if (!ok) revert ApproveFailed();
        if (ret.length == 0) { if (token.code.length == 0) revert ApproveFailed(); }
        else if (!abi.decode(ret, (bool))) revert ApproveFailed();
    }

    function initVaultsBody(
        address[] memory stables_, address[] memory vaults_,
        mapping(address => uint) storage toIndex,
        mapping(address => address) storage tokens,
        mapping(address => address) storage vaults,
        mapping(address => address[]) storage vaultsOf
    ) external {
        uint len = vaults_.length - 1;
        for (uint i; i <= len; i++) {
            address stable = stables_[i];
            address vault = vaults_[i];
            toIndex[stable] = i + 1;
            if (vault != address(0)) {
                tokens[vault] = stable; vaults[stable] = vault;
                vaultsOf[stable].push(vault);
                _approveMax(stable, vault);
            }
        }
    }

    function lpEthOf(bytes calldata lpPubkey) external pure returns (address) {
        return BitcoinTx.evmAddressOfCompressed(lpPubkey);
    }

    function lpToRemoteOutputKey(bytes memory lpPaymentPoint)
        public view returns (bytes32)
    {
        if (lpPaymentPoint.length != 33) revert InvalidParam();

        bytes32 xOnly;
        assembly { xOnly := mload(add(lpPaymentPoint, 33)) }
        bytes memory leaf = abi.encodePacked(
            bytes1(0x20), xOnly,
            bytes1(0xad),
            bytes1(0x51),
            bytes1(0xb2)
        );
        return BitcoinTx.taprootOutputKeyWithLeaf(
            SIMPLE_TAPROOT_NUMS_X, BitcoinTx.tapLeafHash(leaf));
    }

    bytes32 internal constant SIMPLE_TAPROOT_NUMS_X =
        0xdca094751109d0bd055d03565874e8276dd53e926b44e3bd1bb6bf4bc130a279;

    function openChannelBody(
        Types.OpenParams calldata p,
        bytes calldata rawFundingTx,
        bytes32[] calldata fundingMerkleProof,
        address lpEth,
        ISPVGateway spv,
        bytes memory fundingSpk
    ) external view returns (
        bytes32 channelId,
        Types.BTCChannel memory channel
    ) {
        if (p.amountSats == 0) revert InvalidParam();
        // §PQ-SEAM: the 33-byte secp shape is checked by the CALLER, on the v1 branch only — a
        // post-quantum funding key is not 33 bytes and this check was a second secp assumption.

        bytes32 fundingTxId;
        uint32 vout;
        (fundingTxId, vout) = _verifyAndLocate(p, rawFundingTx, fundingMerkleProof, spv, fundingSpk);

        channelId = keccak256(abi.encode(p.lpPubkey, p.hopPubkey, fundingTxId, vout));

        channel = Types.BTCChannel({
            amountSats:     p.amountSats,
            fundingTxId:    fundingTxId,
            lpEth:          lpEth,
            fundingVout:    vout,
            status:         STATUS_OPEN,
            form:           0,

            keysHash:       keccak256(abi.encode(p.lpPubkey, p.hopPubkey)),

            lpToRemoteKey:  bytes32(0)
        });
    }

    function locateChannelOutput(
        bytes calldata rawTx,
        bytes calldata lpPubkey,
        bytes calldata hopPubkey,
        bytes32 fundingTaproot,
        uint expectedSats
    ) external pure returns (uint32 vout) {
        if (lpPubkey.length != 33 || hopPubkey.length != 33) revert InvalidParam();

        uint outputSats;
        (vout, outputSats) = BitcoinTx.findOutputByScript(
            rawTx, BitcoinTx.buildTaprootScriptPubKey(fundingTaproot));
        if (outputSats != expectedSats) revert AmountMismatch();
    }

    function _verifyAndLocate(
        Types.OpenParams calldata p,
        bytes calldata rawFundingTx,
        bytes32[] calldata fundingMerkleProof,
        ISPVGateway spv,
        bytes memory fundingSpk
    ) private view returns (bytes32 fundingTxId, uint32 vout) {
        fundingTxId = BitcoinTx.txid(rawFundingTx);
        if (!spv.checkTxInclusion(
                fundingMerkleProof, p.fundingBlockHash, fundingTxId,
                p.fundingTxIndex, MIN_CONFIRMATIONS))
            revert BadSPV();

        uint outputSats;
        // §PQ-SEAM: the caller supplies the script. `BTCChannels` owns the POLICY (which form, which
        // verifier); this library only matches bytes, which is why it no longer names taproot.
        (vout, outputSats) = BitcoinTx.findOutputByScript(rawFundingTx, fundingSpk);
        if (outputSats != p.amountSats) revert AmountMismatch();
    }
}
