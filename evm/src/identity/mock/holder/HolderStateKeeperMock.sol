// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {DynamicSet} from "@solarity/solidity-lib/libs/data-structures/DynamicSet.sol";

import {HolderStateKeeper} from "../../holder/HolderStateKeeper.sol";

contract HolderStateKeeperMock is HolderStateKeeper {
    using DynamicSet for DynamicSet.StringSet;

    function mockAddRegistrations(string[] memory keys_, address[] memory values_) external {
        for (uint256 i = 0; i < keys_.length; i++) {
            require(_registrationKeys.add(keys_[i]), "HolderStateKeeperMock: duplicate registration");
            _registrations[keys_[i]] = values_[i];
            _registrationExists[values_[i]] = true;
        }
    }

    function _authorizeUpgrade(address) internal pure virtual override {}
}
