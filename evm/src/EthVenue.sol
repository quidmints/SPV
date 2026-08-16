// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vogue} from "./Vogue.sol";
import {SwapLib} from "./imports/SwapLib.sol";
import {VaultLib} from "./imports/VaultLib.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDepositAdapter, ILevEquity} from "./imports/Interfaces.sol";

/// @title  EthVenue — custody of the ETH yield position (ether.fi weETH + AAVE-v4 WETH + idle).
///
/// @notice This contract IS the holder: every `address(this)` in the bodies below resolves here, so the
///         weETH, the AAVE-v4 supply and any idle WETH sit at this address. It is the counterpart of
///         nothing on the BTC side — BTC custody is Lightning channels (`BTCChannels`), not 4626
///         venues, and that asymmetry is real.
///
///         WHY IT IS SEPARATE. `Vault` was two unrelated things fused: ETH-VENUE CUSTODY (this) and
///         BTC BAND ACCOUNTING (`registerBtcLp`, `autoManaged`, `levPooled`, …). `Vogue`'s true
///         counterpart is the BTC-band slice, not the whole of `Vault`, so the band managers cannot be
///         compared — let alone unified — while a third concern rides along. Measured before the split:
///         0 of the 15 functions here referenced any BTC band state.
///
///         The seam already existed: `IEthVenue` is the canonical interface, `Aux` holds an `ethVenue`
///         pointer and `Vogue` an `EV` pointer, both of which simply used to be the Vault's address.
///         Moving the implementation repoints those pins; it does not re-type any call site.
///
/// @dev    THE BODIES LIVE IN `VaultLib` AND ARE DELEGATECALLED, so `address(this)` inside them is this
///         contract and the library can read none of the immutables below — hence `_ethCfg` /
///         `_etherfiCfg`, which gather them into memory structs for every forward.
contract EthVenue is Ownable {
    /// The ETH LP contract. Gates the depositor-facing entries.
    // §NAMING — was `V4`, which read as Uniswap v4. It is the Vogue band manager and always
    // was; there is no Uniswap anywhere in this contract. ("AAVE-v4" below is Aave's v4, unrelated.)
    Vogue   internal immutable VOGUE;
    /// The basket. Gates the basket-side supply/withdraw legs.
    address public   immutable AUX;
    WETH9   public   immutable WETH;

    // ether.fi — fixed mainnet contracts, wired immutably in the constructor. It is the ONLY ETH
    // yield venue: `VaultLib.supplyVenueBody` routes every inflow here unconditionally. The Aave-v4
    // WETH-supply leg was deleted with this extraction — nothing had supplied it since the venue
    // selector went, and its own measurement said it lost ~2.46 points a year against holding weETH.
    address public constant ETHERFI_ADAPTER    = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address public constant ETHERFI_CURVE_POOL = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;
    address public constant ETHERFI_LP         = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address public constant ETHERFI_EETH       = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address public immutable WEETH;             // cached from the adapter at construction

    /// The IL-protect orchestrator. Its levered book's LIVE net-equity counts in `vogueETH`.
    /// Pinned once post-deploy (LevManager needs Aux/weETH first). 0 = leverage disabled.
    address public LEV_MANAGER;

    error NotVogueCore();
    error NotSelf();
    error NotAux();
    error LevManagerPinned();
    error WrongBandManager();

    constructor(address _vogue, address _aux, address _weth) Ownable(msg.sender) {
        VOGUE   = Vogue(payable(_vogue));
        AUX  = _aux;
        WETH = WETH9(payable(_weth));

        // ether.fi — cache weETH from the adapter and set the standing approvals once.
        WEETH = IDepositAdapter(ETHERFI_ADAPTER).weETH();
        IERC20(address(WETH)).approve(ETHERFI_ADAPTER, type(uint).max);
        IERC20(ETHERFI_EETH).approve(ETHERFI_LP, type(uint).max);  // wait-path NFT
    }

    receive() external payable {}

    /// @notice Pin the LevManager (one-shot, no repoint) so `vogueETH` counts the leveraged book's
    ///         net-equity. The only owner-gated function here, so the deploy renounces after it.
    /// @dev §LEV-FOLD-2 — THE IDENTITY CHECK THAT REPLACES THE SUFFIXED SELECTORS. Until this
    ///      commit the only thing stopping a BTC lev manager being pinned to the ETH band (or the
    ///      reverse) was that the two managers exposed DIFFERENT selectors, so a wrong-band read
    ///      reverted. That is a clamp: it fires per call, forever, and only when the caller reaches
    ///      for the suffixed name. Folding the two interfaces into one removes it -- so the bad
    ///      state is made UNCONSTRUCTIBLE here instead, once, at the pin. A manager carries its own
    ///      band asset in `ORACLE_KEY` (immutable, set at construction: WETH for the ETH book,
    ///      WBTC for the BTC one), so the wrong one simply cannot be installed.
    ///      Standing rule 17: the root fix is the one that makes the previous guard DELETABLE.
    function setLevManager(address m) external onlyOwner {
        if (LEV_MANAGER != address(0)) revert LevManagerPinned();
        if (ILevEquity(m).ORACLE_KEY() != address(WETH)) revert WrongBandManager();
        LEV_MANAGER = m;
    }

    /// @dev ether.fi offramp config. Shared by `offrampEtherFi` and the opportunistic sourcing.
    function _etherfiCfg() internal view returns (SwapLib.OfframpCfg memory) {
        return SwapLib.OfframpCfg({
            weeth: WEETH, weth: address(WETH), curvePool: ETHERFI_CURVE_POOL, lp: ETHERFI_LP
        });
    }

    /// @dev Immutables gathered for the delegatecalled `VaultLib` (it cannot read immutable slots).
    function _ethCfg() internal view returns (VaultLib.EthCfg memory) {
        return VaultLib.EthCfg({
            weth: address(WETH), aux: AUX, curvePool: ETHERFI_CURVE_POOL,
            weeth: WEETH, eeth: ETHERFI_EETH, levManager: LEV_MANAGER
        });
    }

    /// @notice Pull the Vogue-approved WETH and stake it into weETH (restaking yield), held here and
    ///         valued in `vogueETH()` via `getEETHByWeETH`.
    function supplyEtherFi(uint amount) external returns (uint) {
        if (msg.sender != address(VOGUE)) revert NotVogueCore();
        return VaultLib.supplyVenueBody(_ethCfg(), amount, address(VOGUE));
    }

    /// @notice OFFRAMP the ether.fi slice of a withdrawal: weETH → WETH for `amount` ETH-worth,
    ///         delivered to `recipient`. Every call try/catch'd.
    function offrampEtherFi(uint amount, address recipient) external returns (uint served) {
        if (msg.sender != address(VOGUE)) revert NotVogueCore();
        return VaultLib.offrampBody(amount, recipient, _etherfiCfg());
    }

    /// @notice Current ETH-equivalent backing: ether.fi weETH valued in ETH + idle WETH, PLUS the
    ///         levered book's net-equity. Body in `VaultLib.vogueETH`.
    function vogueETH() public view returns (uint) {
        return VaultLib.vogueETH(_ethCfg());
    }

    /// @notice Vogue↔venue op selector. @param op 1 = take ETH, 2 = read the current claim.
    ///         (op 0 was the deposit route into a curated WETH vault; that venue is gone.)
    function vogueOp(uint amount, uint8 op) external returns (uint sent) {
        if (msg.sender != address(VOGUE)) revert NotVogueCore();
        // The live ETH claim is read via vogueETH() (real 4626 shares), not a stored principal.
        sent = SwapLib.vogueOpBody(amount, op, WETH, vogueETH());
    }

    /// @notice DELIVERABLE ETH backing for the redemption path. `vogueETH` values a blocked venue at
    ///         maxWithdraw but an unblocked one at convertToAssets, so a frozen-but-unflagged venue
    ///         would let the redemption ETH leg over-burn QU!D for ETH it cannot source. The
    ///         weETH/AAVE/idle legs are capped at what is actually withdrawable, so the ETH leg DEFERS
    ///         the undeliverable slice (the ETH analog of `_illiquidLoss`).
    function deliverableETH() external view returns (uint total) {
        return VaultLib.deliverableETH(_ethCfg());
    }

    /// @notice Self-gated wrapper. The DELEGATECALL'd library bodies reach back in via
    ///         `IAux(address(this)).withdrawSelf(...)` — `msg.sender == address(this)`, so this passes.
    function withdrawSelf(address token, uint amount, address to) external returns (uint sent) {
        if (msg.sender != address(this)) revert NotSelf();
        return _withdrawETH(token, amount, to);
    }

    /// @notice Aux-gated WETH supply. Aux's basket-side `_supply(WETH)` (the BOLD/SP liquidation
    ///         re-supply) routes here: pull the WETH gain from Aux (standing approval), then run the
    ///         same weETH deposit as every other ETH inflow.
    function supplyFromAux(uint amount) external returns (uint) {
        if (msg.sender != AUX) revert NotAux();
        return VaultLib.supplyVenueBody(_ethCfg(), amount, AUX);
    }

    /// @notice Aux-gated WETH withdraw. Aux's basket-side `_withdraw(WETH)` (redemption / take /
    ///         ETH-fallback legs) routes here. Runs the withdraw ladder and delivers to `to`.
    function withdrawForAux(uint amount, address to) external returns (uint) {
        if (msg.sender != AUX) revert NotAux();
        return _withdrawETH(address(WETH), amount, to);
    }

    /// @notice WETH withdraw — the ladder in `VaultLib.withdrawETH`. Only WETH is served.
    function _withdrawETH(address token, uint amount, address to) internal returns (uint sent) {
        return VaultLib.withdrawETH(_ethCfg(), _etherfiCfg(), token, amount, to);
    }

}
