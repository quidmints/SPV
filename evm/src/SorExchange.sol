// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwap} from "./imports/ISwap.sol";

/// @notice Liquity V2 leverage-zapper exchange interface
///         (liquity/bold: contracts/src/Zappers/Interfaces/IExchange.sol).
///         The zapper calls these for the BOLD<->collateral swap leg of a
///         leveraged Trove open/adjust, from inside its flash-loan callback.
interface IExchange {
    function swapFromBold(uint256 _boldAmount, uint256 _minCollAmount) external;
    function swapToBold(uint256 _collAmount, uint256 _minBoldAmount) external returns (uint256);
}

/// @title  SorExchange
/// @notice Drop-in `IExchange` for Liquity V2's `LeverageWETHZapper`, routing the
///         BOLD<->WETH leg through QU!D's SOR (`Aux.swap`) instead of a Curve/UniV3
///         pool — named for its venue, like Liquity's own `CurveExchange`/
///         `UniV3Exchange`. BOLD is already a first-class QU!D basket stable, so a
///         lever-up deposits BOLD into the basket (SP-routed) and ships ETH out of
///         the LP pool; a delever reverses it. QU!D earns the SOR spread both ways.
///
///         Mirrors `CurveExchange`'s convention exactly: PULL the input from
///         msg.sender (the zapper) via transferFrom, swap, PUSH the output to
///         msg.sender. `Aux.swap` is ExactInput (like Curve, unlike UniV3's
///         ExactOutput), so the full input is consumed and there is no dust to
///         refund. Singleton: no DSProxy, no per-user deploy; deploy one
///         `LeverageWETHZapper(addressesRegistry, flashLoanProvider, thisExchange)`.
///
///         Reentrancy: both entries are called inside the zapper's flash-loan
///         callback; `Aux.swap` holds its own `nonReentrant` lock and its V4 unlock
///         hits `Aux.unlockCallback` (Aux's callback, not the zapper's) — no
///         cross-lock. Slippage: Aux prices at the internal TWAP, so on fast moves
///         the TWAP-priced output can miss the zapper's `minColl`/`minBold` and the
///         whole leverage tx reverts — leverage actions need a wider tolerance/retry.
contract SorExchange is IExchange {
    using SafeERC20 for IERC20;

    IERC20 public immutable BOLD;
    IERC20 public immutable WETH; // the WETHZapper collateral
    ISwap  public immutable AUX;  // Aux implements ISwap

    constructor(IERC20 _bold, IERC20 _weth, ISwap _aux) {
        BOLD = _bold;
        WETH = _weth;
        AUX = _aux;
    }

    /// @notice BOLD -> WETH (lever up). Void per `IExchange`; the zapper reads its
    ///         own collateral balance delta.
    function swapFromBold(uint256 _boldAmount, uint256 _minCollAmount) external {
        BOLD.safeTransferFrom(msg.sender, address(this), _boldAmount);
        BOLD.forceApprove(address(AUX), _boldAmount);
        uint256 ethOut = AUX.swap(address(BOLD), address(WETH), true, _boldAmount, _minCollAmount);
        WETH.safeTransfer(msg.sender, ethOut);
    }

    /// @notice WETH -> BOLD (delever / redeem). Returns BOLD out.
    function swapToBold(uint256 _collAmount, uint256 _minBoldAmount)
        external
        returns (uint256 boldOut)
    {
        WETH.safeTransferFrom(msg.sender, address(this), _collAmount);
        WETH.forceApprove(address(AUX), _collAmount);
        boldOut = AUX.swap(address(BOLD), address(WETH), false, _collAmount, _minBoldAmount);
        BOLD.safeTransfer(msg.sender, boldOut);
    }
}
