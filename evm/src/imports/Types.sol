// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILevVenue} from "./Interfaces.sol";

uint256 constant WAD = 1e18;

uint256 constant FLOW_HALFLIFE = 48 hours;

error NotOpen();
error BadTarget();

error AlreadyInitialized();
error AlreadyOpen();
error BadAsset();
error BadSPV();
error BtcChannelsPinned();
error BtcVaultPinned();
error ChannelKeysMismatch();
error InsufficientAllowance();
error InvalidParam();
error LevManagerPinned();
error NotBTCChannels();
error NotFlash();
error Reentrancy();
error Unauthorized();
error VenueNotAllowed();
error WrongRangeManager();

library Types {

    struct Pos { ILevVenue venue; uint128 ilBasisPx; uint128 entryEquity; uint syncKeyPx; bool open; }

    struct RangeCfg { address core; address aux; address asset; }

    struct RangeP {
        uint    spotPrice;
        uint    loPrice;
        uint    upPrice;
        address mgr;
        uint    gross;
        uint    usdFees;

        uint    buf;
    }

    struct Deposit { uint pooled;
        uint usd_owed;
        uint fees_usd;
    }

    struct BTCChannel {
        uint    amountSats;
        bytes32 fundingTxId;
        address lpEth;
        uint32  fundingVout;
        uint8   status;
        uint8   form;

        bytes32 keysHash;

        bytes32 lpToRemoteKey;
    }

    struct OpenParams {
        bytes32 fundingBlockHash;
        uint64  fundingBlockHeight;
        uint    fundingTxIndex;

        bytes   lpPubkey;
        bytes   hopPubkey;

        bytes   lpIdentityPubkey;
        uint    amountSats;
        bytes32 fundingTaproot;
    }

    struct OpenAuth {
        bytes32 btcRecipient;

        bytes   btcRecipientPoP;

        bytes   lpPaymentPoint;
    }

    struct ExitArming {

        uint64[] prevValues;
        bytes[]  prevScripts;
        uint64 cltvDeadline;
        uint   checkpointSats;
        bytes  signedExitTx;

    }

    struct Terms {
        address seller;
        address token;
        uint    pricePerBtc;
        uint16  slippageBps;
    }

    struct TxProof {
        bytes     rawTx;
        bytes32   blockHash;
        bytes32[] merkleProof;
        uint      txIndex;
    }

    struct DepositProof {
        bytes32   userRefund;
        uint32    cltvHeight;
        bytes32   blockHash;
        uint      txIndex;
        bytes32[] merkleProof;
    }

    struct AuxContext {
        address asset;
        address vault;
        address core;
        bool nativeWETH;
    }

    struct RouteParams {

        bool    inputIsUsd;
        address token;
        uint    amount;
        uint    pooled;
        uint    fillPrice;
        address recipient;

        bool    loadBalance;
    }

}

library SortedSetLib {
    struct Set {
        uint[] sortedArray;
        mapping(uint => bool) exists;
    }

    function insert(Set storage self, uint value) internal {
        if (self.exists[value]) return;

        self.exists[value] = true;
        (uint index, ) = binarySearch(self, value);

        self.sortedArray.push(0);

        for (uint i = self.sortedArray.length - 1; i > index; i--) {
            self.sortedArray[i] = self.sortedArray[i - 1];
        }
        self.sortedArray[index] = value;
    }

    function remove(Set storage self, uint value) internal {
        require(self.exists[value], "Value does not exist");

        (uint index, ) = binarySearch(self, value);
        require(index < self.sortedArray.length
         && self.sortedArray[index] == value, "Value not found");

        self.sortedArray[index] = type(uint).max;
        delete self.exists[value];

        compactArray(self);
    }

    function binarySearch(Set storage self,
        uint value) internal view returns (uint, bool) {
        uint left = 0; uint right = self.sortedArray.length;

        while (left < right) {
            uint mid = left + (right - left) / 2;
            if (self.sortedArray[mid] == value) {
                return (mid, true);
            }
            else if (self.sortedArray[mid] < value) {
                left = mid + 1;
            }
            else {
                right = mid;
            }
        }
        return (left, false);
    }

    function compactArray(Set storage self)
        internal { uint newLength = 0;

        uint[] memory newArray = new uint[](self.sortedArray.length);
        for (uint i = 0; i < self.sortedArray.length; i++) {
            if (self.sortedArray[i] != type(uint).max) {
                newArray[newLength] = self.sortedArray[i];
                newLength++;
            }
        }

        self.sortedArray = new uint[](newLength);
        for (uint i = 0; i < newLength; i++) {
            self.sortedArray[i] = newArray[i];
        }
    }

    function getSortedSet(Set storage self)
        internal view returns (uint[] memory) {
        return self.sortedArray;
    }
}
