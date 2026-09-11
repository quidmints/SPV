// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockHeader} from "@solarity/solidity-lib/libs/bitcoin/BlockHeader.sol";

interface ISPVGateway {

    error PrevBlockDoesNotExist(bytes32 prevBlockHash);

    error BlockAlreadyExists(bytes32 blockHash);

    error EmptyBlockHeaderArray();

    error InvalidBlockHeadersOrder();

    error InvalidTarget(bytes32 blockTarget, bytes32 networkTarget);

    error InvalidBlockHash(bytes32 actualBlockHash, bytes32 blockTarget);

    error InvalidBlockTime(uint32 blockTime, uint32 medianTime);

    event MainchainHeadUpdated(
        uint64 indexed newMainchainHeight,
        bytes32 indexed newMainchainHead
    );

    event BlockHeaderAdded(uint64 indexed blockHeight, bytes32 indexed blockHash);

    struct BlockData {
        bytes32 prevBlockHash;
        bytes32 merkleRoot;
        uint32 version;
        uint32 time;
        uint32 nonce;
        bytes4 bits;
        uint64 blockHeight;

        uint256 cumulativeWork;
    }

    struct BlockInfo {
        BlockData mainBlockData;
        bool isInMainchain;
        uint256 cumulativeWork;
    }

    function addBlockHeaderBatch(bytes[] calldata blockHeaderRawArray_) external;

    function addBlockHeader(bytes calldata blockHeaderRaw_) external;

    function checkTxInclusion(
        bytes32[] memory merkleProof_,
        bytes32 blockHash_,
        bytes32 txId_,
        uint256 txIndex_,
        uint256 minConfirmationsCount_
    ) external view returns (bool);

    function getMainchainHead() external view returns (bytes32);

    function getMainchainHeight() external view returns (uint64);

    function getBlockInfo(bytes32 blockHash_) external view returns (BlockInfo memory blockInfo_);

    function getBlockHeader(
        bytes32 blockHash
    ) external view returns (BlockHeader.HeaderData memory);

    function getBlockStatus(bytes32 blockHash_) external view returns (bool, uint64);

    function getBlockMerkleRoot(bytes32 blockHash_) external view returns (bytes32);

    function getBlockHeight(bytes32 blockHash_) external view returns (uint64);

    function getBlockHash(uint64 blockHeight_) external view returns (bytes32);

    function getBlockTarget(bytes32 blockHash_) external view returns (bytes32);

    function blockExists(bytes32 blockHash_) external view returns (bool);

    function isInMainchain(bytes32 blockHash_) external view returns (bool);
}
