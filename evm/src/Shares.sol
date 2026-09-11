// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./imports/Types.sol";
import {ILevEquity} from "./imports/Interfaces.sol";
import {LevManagerPinned, WrongRangeManager} from "./imports/Types.sol";

abstract contract Shares {

    address public LEV_MANAGER;

    function _onlyPinner() internal view virtual;

    function _rangeAsset() internal view virtual returns (address);

    function setLevManager(address m) external {
        _onlyPinner();
        if (LEV_MANAGER != address(0)) revert LevManagerPinned();
        if (ILevEquity(m).ORACLE_KEY() != _rangeAsset()) revert WrongRangeManager();
        LEV_MANAGER = m;
    }

    function levGrossNative() external view returns (uint) {
        address m = LEV_MANAGER;
        if (m == address(0)) return 0;
        try ILevEquity(m).totalGrossCollateral() returns (uint g) { return g; } catch { return 0; }
    }

    mapping(address => Types.Deposit) public autoManaged;

    uint public lpShares;

    uint public feesPerShare;
    uint public USD_FEES;

    mapping(address => uint) public levPooled;
    mapping(address => uint) public levBuf;
    mapping(address => uint) public levBufferUsd;
    uint public totalBuffer;

    uint public RANGE_ANCHOR;
}
