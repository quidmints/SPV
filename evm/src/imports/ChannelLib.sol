// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Types} from "./Types.sol";
// §A.52: the canonical Aux view (was a file-local variant).
import {IAux} from "./Interfaces.sol";
import {IQuidTarget} from "./Interfaces.sol";
import {BitcoinTx} from "./BitcoinTx.sol";
// (E128/§E140-r) `BitcoinTx._assertLegacy` REJECTS any witness-carrying tx, so it cannot parse a
// fully-signed key-path taproot exit at all — not even its locktime. `TxParser` can, and exposes
// `inputs[i].witnesses`, which is where a key-path Schnorr signature lives. Used ONLY for that:
// §E140-r2 measured that its `previousHash` is byte-REVERSED relative to its own `calculateTxId`
// and to our `BitcoinTx`, so it is not a drop-in for outpoint logic.
import {TxParser} from "@solarity/solidity-lib/libs/bitcoin/TxParser.sol";
import {MuSig2Agg} from "./MuSig2Agg.sol";
import {EndianConverter} from "@solarity/solidity-lib/libs/utils/EndianConverter.sol";
import {ISPVGateway} from "../spv/interfaces/ISPVGateway.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BasketLib} from "./BasketLib.sol";
import {FeeLib} from "./FeeLib.sol";
import {IAaveV4Spoke} from "./Interfaces.sol";
import {IAaveV4Hub} from "./Interfaces.sol";
import {IEthVenue} from "./Interfaces.sol";

/// @notice Aux self-surface that depositBody calls back into (delegatecall →
///         msg.sender == address(this) == Aux on every self-call). The public
///         mapping getters are READS; the *Self entries are the self-gated
///         mutators (the same DELEGATECALL→self-CALL pattern takeBody uses).
/// @notice Aave-v4 reserve-id resolution + supply surface (subset of Aux.IAaveV4Spoke).

/// @notice Minimal interface for Liquity V2 StabilityPool
/// @dev 0x5721cbbd64fc7Ae3Ef44A0A3F9a790A9264Cf9BF (WETH)
interface IStabilityPool {
    function provideToSP(uint _topUp, bool _doClaim) external;
    function withdrawFromSP(uint _amount, bool _doClaim) external;
    function getCompoundedBoldDeposit(address _depositor) external view returns (uint);
    function getDepositorYieldGainWithPending(address _depositor) external view returns (uint);
}

/// @title  ChannelLib — bodies extracted from BTCChannels to free its
///         deployed bytecode under EIP-170. Same DELEGATECALL semantics
///         as SwapLib / BasketLib: external functions run in the calling
///         contract's storage context.
library ChannelLib {
    uint internal constant WAD = 1e18;

    // ─── Liquity StabilityPool (BOLD) cluster — relocated from BasketLib to
    // even out the EIP-170 budget. DELEGATECALL'd from Aux (address(this)==Aux),
    // so the SP venue calls + WETH/BOLD balance reads run against Aux's position.

    struct SPState {
        uint spValue;         // original principal tracking (not compounded yield)
        uint spTotalYield;    // cumulative harvested yield (USD value, WAD)
        uint spPrincipalTime; // cumulative (principal * seconds)
        uint spLastUpdate;    // last update timestamp
    }

    /// @notice Result from SP withdraw operation
    struct SPWithdrawResult {
        uint sent;            // BOLD amount being sent out
        uint toRedeposit;     // BOLD amount to redeposit (already done)
        uint wethGain;        // ETH collateral gained (caller handles swap)
        uint boldReceived;    // Total BOLD received from SP
        // Updated state values - caller must write these
        uint newSpValue;
        uint newSpTotalYield;
        uint newSpPrincipalTime;
        uint newSpLastUpdate;
    }

    /// @notice Calculate SP position
    //  & yield contribution in get_deposits
    /// @param sp StabilityPool address...
    /// @param depositor Address to check
    /// @param reserved Tranche amount
    /// @param state Current SP tracking state
    /// @return totalValue Position value (compounded + yield - reserved)
    /// @return yieldContrib Contribution to amounts[12] for weighted average
    function calcSPValue(address sp, address depositor,
        uint reserved, SPState memory state) external view returns
        (uint totalValue, uint yieldContrib) { if (sp == address(0)) return (0, 0);
        uint compounded = IStabilityPool(sp).getCompoundedBoldDeposit(depositor);
        uint yieldGain = IStabilityPool(sp).getDepositorYieldGainWithPending(depositor);
        totalValue = compounded + yieldGain; totalValue -= Math.min(totalValue, reserved);

        if (totalValue == 0) return (0, 0);
        // Calculate time-weighted APY for yield contribution
        uint currentPrincipalTime = state.spPrincipalTime +
        state.spValue * (block.timestamp - state.spLastUpdate);
        if (currentPrincipalTime > 0 && state.spTotalYield > 0) {
            uint rate = FullMath.mulDiv(state.spTotalYield,
                    WAD * 365 days, currentPrincipalTime);

            yieldContrib = FullMath.mulDiv(
               totalValue, WAD + rate, WAD);
        } else
            yieldContrib = totalValue;
            // no yield history, 1:1

    }

    /// @notice Execute SP withdrawal and return results with updated state
    /// @dev Performs withdrawFromSP and provideToSP, caller handles WETH swap
    /// @param sp StabilityPool address
    /// @param bold BOLD token address
    /// @param weth WETH token address
    /// @param amount Requested withdrawal amount
    /// @param ethPrice Current ETH price (WAD) for yield calculation
    /// @param state Current SP tracking state
    /// @return r Result with amounts and updated state values
    function withdrawFromSP(address sp, address bold,
        address weth, uint amount, uint ethPrice,
        SPState memory state) internal returns (SPWithdrawResult memory r) {
        uint compounded = IStabilityPool(sp).getCompoundedBoldDeposit(address(this));
        uint yieldGain = IStabilityPool(sp).getDepositorYieldGainWithPending(address(this));
        uint totalBold = compounded + yieldGain;
        if (totalBold == 0) return r;

        // Only from principal, not yield...
        amount = Math.min(amount, compounded);
        uint wethBefore = WETH9(payable(weth)).balanceOf(address(this));
        uint boldBefore = IERC20(bold).balanceOf(address(this));
        // Withdraw ONLY the requested `amount`, not the full
        // `compounded` principal. `_doClaim=true` still harvests the entire
        // collateral + BOLD yield gain regardless of the principal slice taken,
        // so the end-state is identical to a full-withdraw-then-redeposit — but
        // this leaves the untouched principal (`compounded - amount`) in place
        // instead of churning it out and back every partial redeem. That churn
        // reset the SP epoch, re-realized gains needlessly, and — worse — risked
        // STRANDING the whole principal as loose BOLD on Aux if the trailing
        // provideToSP reverted (SP paused / min-deposit). Now only the harvested
        // yield (`toRedeposit`) is re-provided, so a revert there strands at most
        // the yield, never the principal.
        IStabilityPool(sp).withdrawFromSP(amount, true);

        r.boldReceived = IERC20(bold).balanceOf(address(this)) - boldBefore;
        r.wethGain = WETH9(payable(weth)).balanceOf(address(this)) - wethBefore;

        // Send only from principal
        r.sent = Math.min(amount, r.boldReceived);
        // Redeposit everything else (includes all yield)
        r.toRedeposit = r.boldReceived - r.sent;

        r.newSpPrincipalTime = state.spPrincipalTime +
           state.spValue * (block.timestamp - state.spLastUpdate);
        r.newSpLastUpdate = block.timestamp;

        // Only ETH gains count as harvested (BOLD yield compounds)
        uint wethValueUSD = FullMath.mulDiv(r.wethGain, ethPrice, WAD);
        r.newSpTotalYield = state.spTotalYield + wethValueUSD;

        // Sent is all principal
        r.newSpValue = state.spValue > r.sent ? state.spValue - r.sent : 0;
        if (r.toRedeposit > 0) IStabilityPool(sp).provideToSP(r.toRedeposit, false);

    }

    /// @notice Immutables the supply dispatcher references (delegatecalled →
    ///         the library can't read Aux's immutables, so the wrapper passes them).
    struct SupplyCfg {
        address weth;
        address gho;
        address usdg;
        address aaveSpoke;
        uint256 ghoReserveId;
        uint256 usdgReserveId;
        address ethVenue;
        address bold;       // stables[stables.length-1] (SP-routed leg)
    }

    /// @notice Body of Aux._supply (delegatecall, address(this)==Aux). WRITE path
    ///         → the extra hop is fine. Dispatch is byte-for-byte the inline
    ///         version: WETH→EthVenue, GHO/USDG→Aave spoke, BOLD→Liquity SP
    ///         (writes `sp` via the storage ref), everything else→least-full
    ///         HEALTHY 4626/Aave member of the stable's set. vaultHealth/aaveBalance/
    ///         reserveId are read via Aux getters; the per-stable refresh routes
    ///         through refreshHoldingsSelf.
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
        if (token == cfg.gho || token == cfg.usdg) {
            if (cfg.aaveSpoke == address(0)) revert GHOIsAaveWired();
            uint256 reserveId = token == cfg.gho ? cfg.ghoReserveId : cfg.usdgReserveId;
            (, deposited) = IAaveV4Spoke(cfg.aaveSpoke).supply(
                reserveId, amount, address(this));
            aux.refreshHoldingsSelf(token);
            return deposited;
        }
        if (token == cfg.bold) { // BOLD → Liquity SP
            (sp.spValue, sp.spPrincipalTime, sp.spLastUpdate) =
                _depositToSPInline(vaults[token], amount, sp);
            return amount;
        }
        // Default: 4626 / Aave-member set. Route NEW deposits to the least-full
        // HEALTHY member; revert if every member is blocked.
        address[] memory vs = vaultsOf[token];
        if (vs.length == 0) revert VaultUnwired();
        address vault = address(0);
        uint lo = type(uint).max;
        for (uint j; j < vs.length; j++) {
            address vj = vs[j];
            uint bj;  // A reverting vault is skipped, never bricks routing
            if (vj == cfg.aaveSpoke) {
                bj = aux.aaveBalance(token);
            } else {
                (bool blocked,) = aux.vaultHealth(vj);
                if (blocked) continue;
                try IERC4626(vj).balanceOf(address(this)) returns (uint sh) {
                    try IERC4626(vj).convertToAssets(sh) returns (uint a) { bj = a; }
                    catch { continue; }
                } catch { continue; }
            }
            if (bj < lo) { lo = bj; vault = vj; }
        }
        if (vault == address(0)) revert VaultUnwired();
        if (vault == cfg.aaveSpoke) {
            (, deposited) = IAaveV4Spoke(cfg.aaveSpoke).supply(
                aux.reserveIdOf(token), amount, address(this));
        } else {
            deposited = IERC4626(vault).convertToAssets(
                    IERC4626(vault).deposit(amount, address(this)));
        }
        aux.refreshHoldingsSelf(token);
    }

    /// @notice Body of Aux._withdraw (delegatecall, address(this)==Aux). DRAIN
    ///         path → the extra hop is fine. Dispatch is byte-for-byte the inline
    ///         version: WETH→EthVenue, GHO/USDG→Aave (try/catch self-call to
    ///         _withdrawAaveUnsafe), BOLD→Liquity SP (writes `sp` + re-supplies the
    ///         WETH liquidation gain via supplySelf), everything else→the
    ///         multi-venue pro-rata draw (FeeLib.multiVaultWithdrawBody). Reuses
    ///         SupplyCfg (same immutable bundle).
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
        if (token == cfg.gho || token == cfg.usdg) {
            if (cfg.aaveSpoke == address(0)) return 0;
            uint256 reserveId = token == cfg.gho ? cfg.ghoReserveId : cfg.usdgReserveId;
            uint max = IAaveV4Spoke(cfg.aaveSpoke).getUserSuppliedAssets(
                reserveId, address(this));
            amount = amount > 0 ? Math.min(amount, max) : max;
            if (amount == 0) return 0;
            uint drawn;
            try aux._withdrawAaveUnsafe(reserveId, amount, to) returns (uint d) {
                drawn = d;
            } catch {
                drawn = 0;   // AAVE froze/paused → 0; caller's fallthrough covers it
            }
            aux.refreshHoldingsSelf(token);
            return drawn;
        }
        if (token == cfg.bold) { // BOLD → Liquity SP
            SPWithdrawResult memory r = withdrawFromSP(
                vaults[token], token, cfg.weth, amount,
                aux.getTWAPforAsset(cfg.weth, 0), sp);
            if (r.boldReceived == 0) return 0;
            sp.spLastUpdate = r.newSpLastUpdate;
            sp.spTotalYield = r.newSpTotalYield;
            sp.spPrincipalTime = r.newSpPrincipalTime;
            sp.spValue = r.newSpValue;
            // Re-supply liquidation yield (WETH branch bumps Vogue backing).
            if (r.wethGain > 0) aux.supplySelf(cfg.weth, r.wethGain);
            // §E91-ROOT — DELIVER. This branch un-deployed BOLD into `Aux` and returned `r.sent`
            // WITHOUT MOVING IT, so every caller was told a delivery happened that never did.
            // MEASURED: a volatile-IN swap burned the mock USD, `Core.swap` returned a non-zero
            // `max` (37943101858) and the recipient received ZERO — and `sent` being non-zero is
            // exactly why the aggregate `NothingDelivered` guard could not see it either.
            //   Every OTHER withdrawal path already delivers: the multi-venue leg below passes
            // `to` into `multiVaultWithdrawBody`, and `:297` uses this same guarded form. The
            // BOLD-SP branch was the lone exception.
            //   `withdrawFromSP` deliberately does NOT take a `to`: its job is the SP interaction
            // (claim, compute, redeposit the excess) and the caller already holds the recipient,
            // so threading the address inward would widen that function's responsibility and cost
            // a stack slot for nothing.
            if (to != address(this) && r.sent > 0) IERC20OZ(token).safeTransfer(to, r.sent);
            return r.sent;
        }
        // Default: multi-venue pro-rata draw across the stable's set.
        address[] memory vs = vaultsOf[token];
        if (vs.length == 0) revert VaultUnwired();
        sent = FeeLib.multiVaultWithdrawBody(vs, amount, to, cfg.aaveSpoke, token);
        aux.refreshHoldingsSelf(token);
    }

    /// @notice Shared AAVE-v4 withdraw+deliver leg — the bodies of
    ///         Aux._withdrawAaveUnsafe and Aux.withdrawAaveLeg folded into one.
    ///         DELEGATECALL'd (address(this)==Aux), so spoke.withdraw redeems
    ///         Aux's supplied position and the optional safeTransfer moves the
    ///         drawn `token` to `to`. Returns drawn (0 if unwired / zero-amount /
    ///         no-reserve — safe no-op guards; the callers only reach here wired).
    ///         The self-gate stays on the thin Aux wrappers.
    function aaveWithdrawTo(address spoke, uint256 reserveId, address token, uint amount, address to)
        external returns (uint drawn) {
        if (spoke == address(0) || amount == 0 || reserveId == 0) return 0;
        (, drawn) = IAaveV4Spoke(spoke).withdraw(reserveId, amount, address(this));
        if (to != address(this) && drawn > 0) IERC20OZ(token).safeTransfer(to, drawn);
    }

    /// @dev Inlined SP-deposit accounting (same as depositToSP) so supplyBody
    ///      updates `sp` in one delegatecall frame rather than a nested one.
    function _depositToSPInline(address sp_, uint amount, SPState storage state)
        private returns (uint newSpValue, uint newSpPrincipalTime, uint newSpLastUpdate) {
        newSpPrincipalTime = state.spPrincipalTime + state.spValue * (
                                 block.timestamp - state.spLastUpdate);
        newSpValue = state.spValue + amount;
        newSpLastUpdate = block.timestamp;
        IStabilityPool(sp_).provideToSP(amount, false);
    }


    // CANONICAL source for these constants — BTCChannels references them as
    // `ChannelLib.X` (single definition; no more "keep in sync" drift — the prior
    // STATUS_OPEN=1-here-vs-0-there mismatch that broke `whenOpen` is now impossible).
    // `internal constant` ⇒ inlined at the use site (delegatecall-safe).
    uint   internal constant MIN_CONFIRMATIONS = 6;
    uint8  internal constant STATUS_OPEN       = 0;
    uint8  internal constant STATUS_CLOSED     = 2;  // cooperative close or LP refund

    error InvalidParam();
    error BadSPV();
    error AmountMismatch();
    // setVaultBody errors (mirror Aux's; raised in Aux's context via delegatecall)
    error VaultUnwired();
    error VaultAlreadySet();
    error GHONotOnAAVE();
    error VaultAssetMismatch();
    error UnknownStable();
    error ZeroDeposit();
    error VaultBlocked();
    error GHOIsAaveWired();

    using SafeERC20 for IERC20OZ;

    /// @notice Body of Aux.deposit (delegatecall, address(this)==Aux; msg.sender
    ///         is the ORIGINAL caller — preserved across delegatecall, so the
    ///         `msg.sender == quid` seed-fee + full-refresh gates are identical to
    ///         the inline version). WRITE path → one extra delegatecall hop is
    ///         acceptable (NOT a hot read). All storage mutation routes through
    ///         Aux's self-gated entries (supplySelf/tipSelf/refresh*Self); all
    ///         reads use Aux's public getters. `nStables` = stables.length (the
    ///         existence-check bound), passed in to avoid a getStables() copy.
    function depositBody(
        address from, address token, uint amount,
        address quid, uint nStables
    ) external returns (uint usd) {
        IAux aux = IAux(address(this));
        if (aux.tokens(token) != address(0)) {
            // Direct vault-share deposit.
            amount = Math.min(
                IERC4626(token).convertToShares(amount),
                IERC4626(token).allowance(from, address(this)));
            usd = IERC4626(token).convertToAssets(amount);
            if (usd == 0) revert ZeroDeposit();
            // Apply the same per-vault health get_deposits does —
            // else mint at PAR against a blocked vault, redeem vs healthy backing.
            (bool blocked,) = aux.vaultHealth(token);
            if (blocked) revert VaultBlocked();
            IERC20OZ(token).safeTransferFrom(from, address(this), amount);
            token = aux.tokens(token);
            aux.refreshHoldingsSelf(token);   // Cache: stable moved by the deposit
        } else {
            // Registered-stable path (index lookup = existence check).
            uint index = aux.toIndex(token);
            if (!(index > 0 && index <= nStables)) revert UnknownStable();
            usd = Math.min(amount, IERC20(token).allowance(from, address(this)));
            IERC20OZ(token).safeTransferFrom(from, address(this), usd);
            if (usd == 0) revert ZeroDeposit();
            usd = aux.supplySelf(token, usd);
        }
        // (B) Accept a depegged stable at FAIR value (riskFactor-adjusted credit),
        // never minting unbacked QU!D; the haircut accrues to backing.
        uint rf = aux.riskFactor(token);
        if (rf < 10000) usd = FullMath.mulDiv(usd, rf, 10000);

        uint _target = IQuidTarget(quid).target();
        if (aux.trancheTotal() < _target && msg.sender == quid) {
            aux.get_metrics(false);
            uint fee = BasketLib.seedFee(usd, aux.trancheTotal(), _target, aux.avgYield());
            if (fee > 0) aux.tipSelf(fee, token, 1);
        }
        // Cache: a MINT (msg.sender==quid) full-refreshes ALL stables to
        // recapture yield drift; swap-ins rely on the per-stable refresh above.
        if (msg.sender == quid) aux.refreshAllHoldingsSelf();
    }

    struct SetVaultCfg {
        address aaveSpoke;
        address aaveHub;
        uint    nStables;   // stables.length at call time (for the index bound)
    }

    /// @notice Body of Aux.setVault (delegatecall, address(this)==Aux). The
    ///         onlyOwner gate + the GHO/USDG early-revert stay on the Aux
    ///         wrapper; all storage writes (vaultsOf/vaults/tokens/aaveReserveId)
    ///         + the venue reads + the selector-encoded approve run HERE in Aux's
    ///         storage context. Behavior-identical to the inline version.
    function setVaultBody(
        address stable, address vault, SetVaultCfg memory cfg,
        mapping(address => uint) storage toIndex,
        mapping(address => address[]) storage vaultsOf,
        mapping(address => uint256) storage aaveReserveId,
        mapping(address => address) storage tokens,
        mapping(address => address) storage vaults
    ) external {
        uint index = toIndex[stable];
        if (!(index > 0 && index <= cfg.nStables)) revert UnknownStable();
        if (vault == address(0)) revert VaultUnwired();
        address[] storage set = vaultsOf[stable];
        if (vault == cfg.aaveSpoke) {
            for (uint j; j < set.length; j++)
                if (set[j] == cfg.aaveSpoke) revert VaultAlreadySet();
            uint256 assetId = IAaveV4Hub(cfg.aaveHub).getAssetId(stable);
            uint256 rid = IAaveV4Spoke(cfg.aaveSpoke).getReserveId(cfg.aaveHub, assetId);
            if (rid == 0) revert GHONotOnAAVE();
            aaveReserveId[stable] = rid;
            stable.call(abi.encodeWithSelector(0x095ea7b3,
                                cfg.aaveSpoke, type(uint).max));
            if (vaults[stable] == address(0)) vaults[stable] = cfg.aaveSpoke; // primary
            set.push(cfg.aaveSpoke);
            return;
        }
        if (IERC4626(vault).asset() != stable) revert VaultAssetMismatch();
        for (uint j; j < set.length; j++)
            if (set[j] == vault) revert VaultAlreadySet();
        tokens[vault] = stable;
        if (vaults[stable] == address(0)) vaults[stable] = vault; // primary
        set.push(vault);
        stable.call(abi.encodeWithSelector(0x095ea7b3,
                            vault, type(uint).max));
    }

    /// @notice Body of Aux's constructor stable/vault wiring loops (delegatecall
    ///         works from a constructor too; runs in Aux's storage context). The
    ///         immutable assignments (WETH/WBTC/GHO/…) stay in the constructor —
    ///         only these storage-writing loops move. Selector-encoded approve
    ///         (NOT typed) tolerates USDT-style no-returndata approve.
    function initVaultsBody(
        address[] memory stables_, address[] memory vaults_, bytes[] memory paths_,
        mapping(address => uint) storage toIndex,
        mapping(address => address) storage tokens,
        mapping(address => address) storage vaults,
        mapping(address => address[]) storage vaultsOf,
        bytes[] storage pathEncodings
    ) external {
        uint len = vaults_.length - 1;
        for (uint i; i <= len; i++) {
            address stable = stables_[i];
            address vault = vaults_[i];
            toIndex[stable] = i + 1;
            if (vault != address(0)) {
                tokens[vault] = stable; vaults[stable] = vault;
                vaultsOf[stable].push(vault);
                stable.call(abi.encodeWithSelector(0x095ea7b3,
                                    vault, type(uint).max));
            }
        }
        for (uint i; i < paths_.length; i++) {
            pathEncodings.push(paths_[i]);
        }
    }

    /// @notice Body of BTCChannels.openChannel. Wrapper handles the
    ///         duplicate-check + storage write + event emission + the
    ///         btcRecipientOf bookkeeping; this library function does
    ///         the validation, SPV check, script reconstruction, and
    ///         builds the channel struct to return.
    /// @return channelId      Deterministic channel ID
    /// @return channel        Channel struct ready to write to storage
    function openChannelBody(
        Types.OpenParams calldata p,
        bytes calldata rawFundingTx,
        bytes32[] calldata fundingMerkleProof,
        address lpEth,
        ISPVGateway spv
    ) external view returns (
        bytes32 channelId,
        Types.BTCChannel memory channel
    ) {
        if (p.amountSats == 0) revert InvalidParam();
        if (p.lpPubkey.length != 33 || p.hopPubkey.length != 33) revert InvalidParam();

        // SPV-verify inclusion + locate the key-path P2TR funding output `0x5120||Q`.
        // Split into its own frame so this body stays within the legacy stack (no
        // via_ir crutch).
        bytes32 fundingTxId;
        uint32 vout;
        (fundingTxId, vout) = _verifyAndLocate(p, rawFundingTx, fundingMerkleProof, spv);

        // Bind `vout` into the id. `fundingTxId` alone is not a
        // unique outpoint — a funding tx can carry more than one channel output —
        // so keying on (lp, hop, txid) only would collapse two distinct channels
        // funded by the same tx onto one id (the second open reverting AlreadyOpen
        // and stranding its output). The full outpoint (txid, vout) is the unique
        // key. channelId is derived purely on-chain and is NOT part of the signed
        // lpAuth digest, so widening it is non-breaking.
        channelId = keccak256(abi.encode(p.lpPubkey, p.hopPubkey, fundingTxId, vout));

        // MULTI-HOP: the `hop` field is now READ (per-channel authority — no single
        // global `hopNode`), so it earns its storage slot. It is set by the caller
        // (E164) The `hop` field is gone — authority is the immutable MAIN_HOP/FALLBACK_HOP
        // pair, not per-channel state.
        channel = Types.BTCChannel({
            amountSats:     p.amountSats,
            fundingTxId:    fundingTxId,
            lpEth:          lpEth,
            fundingVout:    vout,
            status:         STATUS_OPEN,
            // (E153) Pin the key pair independently of the funding outpoint, which a splice
            // rotates. `channelId` above folds in the ORIGINAL outpoint and so cannot serve
            // as the key binding after a resize.
            keysHash:       keccak256(abi.encode(p.lpPubkey, p.hopPubkey))
        });
    }

    /// @notice Locate the channel's key-path P2TR funding output `0x5120||Q` in
    ///         `rawTx` and assert its value == expectedSats; return its index
    ///         (vout). NO SPV/inclusion check — the caller proves the tx separately
    ///         (splice verifies the splice tx spends the channel's prior funding
    ///         UTXO). Reused for the splice path (grow or shrink) so the script/
    ///         amount match stays identical to openChannelBody's. NOTE: lpPubkey/
    ///         hopPubkey are only length-validated HERE, and the funding output is located
    ///         purely by `Q` (key-path taproot reveals no script on-chain) — **but that is no
    ///         longer the whole story, and this note claimed it was.** The (keys ↔ Q) binding
    ///         is PROVEN on-chain by `MuSig2Agg.isTwoOfTwoOutputKey` at BOTH call sites
    ///         (`BTCChannels.openChannel` E142, `_verifySplice` E129). The retired text named
    ///         "the LP's lpAuth + off-chain MuSig2 keygen" as the binding; `lpAuth` no longer
    ///         exists as a parameter anywhere (E149).
    ///         ⚠️ DO NOT add a caller that skips the gate on the strength of THIS function's
    ///         laxity — the check lives at the call sites, deliberately.
    function locateChannelOutput(
        bytes calldata rawTx,
        bytes calldata lpPubkey,
        bytes calldata hopPubkey,
        bytes32 fundingTaproot,
        uint expectedSats
    ) external pure returns (uint32 vout) {
        if (lpPubkey.length != 33 || hopPubkey.length != 33) revert InvalidParam();
        // SIMPLE-TAPROOT: locate the key-path P2TR funding output `0x5120||Q`. No
        // secp256k1 EC math — Q is supplied (lpAuth-committed) and byte-matched.
        uint outputSats;
        (vout, outputSats) = BitcoinTx.findOutputByScript(
            rawTx, BitcoinTx.buildTaprootScriptPubKey(fundingTaproot));
        if (outputSats != expectedSats) revert AmountMismatch();
    }

    /// @dev SPV-verify the recomputed txid is in mainchain, then locate the
    ///      key-path P2TR funding output `0x5120||Q` (Q = p.fundingTaproot) and
    ///      assert its value == amountSats exactly. The contract does NO EC: Q is
    ///      lpAuth-committed + byte-matched (NOT reconstructed from the keys). In
    ///      its own private frame so openChannelBody compiles under the legacy
    ///      pipeline.
    function _verifyAndLocate(
        Types.OpenParams calldata p,
        bytes calldata rawFundingTx,
        bytes32[] calldata fundingMerkleProof,
        ISPVGateway spv
    ) private view returns (bytes32 fundingTxId, uint32 vout) {
        fundingTxId = BitcoinTx.txid(rawFundingTx);
        if (!spv.checkTxInclusion(
                fundingMerkleProof, p.fundingBlockHash, fundingTxId,
                p.fundingTxIndex, MIN_CONFIRMATIONS))
            revert BadSPV();

        // SIMPLE-TAPROOT: locate the key-path MuSig2 P2TR funding output
        // `0x5120||Q` (Q = p.fundingTaproot). The contract does NO EC math; Q is
        // lpAuth-committed (signed in the OpenParams digest) and byte-matched.
        uint outputSats;
        (vout, outputSats) = BitcoinTx.findOutputByScript(
            rawFundingTx,
            BitcoinTx.buildTaprootScriptPubKey(p.fundingTaproot)
        );
        if (outputSats != p.amountSats) revert AmountMismatch();
    }
}
