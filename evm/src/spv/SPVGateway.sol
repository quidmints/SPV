// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {BlockHeader} from "@solarity/solidity-lib/libs/bitcoin/BlockHeader.sol";
import {TxMerkleProof} from "@solarity/solidity-lib/libs/bitcoin/TxMerkleProof.sol";
import {EndianConverter} from "@solarity/solidity-lib/libs/utils/EndianConverter.sol";

import {LibSort} from "solady/src/utils/LibSort.sol";

import {TargetsHelper} from "./libs/TargetsHelper.sol";

import {ISPVGateway} from "./interfaces/ISPVGateway.sol";

contract SPVGateway is ISPVGateway, Initializable {
    using BlockHeader for bytes;
    using TargetsHelper for bytes32;
    using EndianConverter for bytes32;

    uint8 public constant MEDIAN_PAST_BLOCKS = 11;

    bytes32 public constant SPV_GATEWAY_STORAGE_SLOT =
        keccak256("spv.gateway.spv.gateway.storage");

    struct SPVGatewayStorage {
        mapping(bytes32 => BlockData) blocksData;
        mapping(uint64 => bytes32) blocksHeightToBlockHash;
        bytes32 mainchainHead;
    }

    modifier broadcastMainchainUpdateEvent() {
        bytes32 currentMainchain_ = getMainchainHead();
        _;
        bytes32 newMainchainHead_ = getMainchainHead();

        if (currentMainchain_ != newMainchainHead_) {
            emit MainchainHeadUpdated(getBlockHeight(newMainchainHead_), newMainchainHead_);
        }
    }

    /// @notice Start the header chain from a DEPLOYER-CHOSEN CHECKPOINT.
    ///
    ///         ⚠️ THIS IS A REAL TRUST ASSUMPTION AND IT USED TO BE OBSCURED. A companion
    ///         `__SPVGateway_init_genesis()` hardcoding Bitcoin block 0 sat here until
    ///         2026-08-08, called by NOTHING — production goes through this function
    ///         (`DeployLib.sol:160`, from `cfg.spvCheckpointHeader`) and so does every test.
    ///         Both carried `initializer`, so once this ran the genesis one could never fire:
    ///         unreachable by construction. Its presence implied the gateway syncs from
    ///         genesis. **It does not.** Everything FORWARD of the checkpoint is trustless by
    ///         proof-of-work; the checkpoint itself is trusted because the deployer picked it.
    function __SPVGateway_init(
        bytes calldata blockHeaderRaw_,
        uint64 blockHeight_,
        uint256 cumulativeWork_
    ) external initializer {
        (BlockHeader.HeaderData memory blockHeader_, bytes32 blockHash_) = _parseBlockHeaderRaw(
            blockHeaderRaw_
        );

        _initialize(blockHeader_, blockHash_, blockHeight_, cumulativeWork_);
    }

    function _getSPVGatewayStorage() private pure returns (SPVGatewayStorage storage _spvs) {
        bytes32 slot_ = SPV_GATEWAY_STORAGE_SLOT;

        assembly {
            _spvs.slot := slot_
        }
    }

    /// @inheritdoc ISPVGateway
    function addBlockHeaderBatch(
        bytes[] calldata blockHeaderRawArray_
    ) external broadcastMainchainUpdateEvent {
        (
            BlockHeader.HeaderData[] memory blockHeaders_,
            bytes32[] memory blockHashes_
        ) = _parseBlockHeadersRaw(blockHeaderRawArray_);

        uint64 firstBlockHeight_ = getBlockHeight(blockHeaders_[0].prevBlockHash) + 1;
        bytes32 currentTarget_ = getBlockTarget(blockHeaders_[0].prevBlockHash);

        for (uint64 i = 0; i < blockHeaderRawArray_.length; ++i) {
            uint64 currentBlockHeight_ = firstBlockHeight_ + i;

            currentTarget_ = _retargetIfEpochBoundary(currentTarget_, currentBlockHeight_);

            uint32 medianTime_;

            if (i < MEDIAN_PAST_BLOCKS) {
                medianTime_ = _getStorageMedianTime(blockHeaders_[i], currentBlockHeight_);
            } else {
                medianTime_ = _getMemoryMedianTime(blockHeaders_, i);
            }

            _validateBlockRules(blockHeaders_[i], blockHashes_[i], currentTarget_, medianTime_);

            _addBlock(blockHeaders_[i], blockHashes_[i], currentBlockHeight_,
                _nextCumulativeWork(blockHeaders_[i].prevBlockHash, currentTarget_));
        }
    }

    /// @inheritdoc ISPVGateway
    function addBlockHeader(
        bytes calldata blockHeaderRaw_
    ) external broadcastMainchainUpdateEvent {
        (BlockHeader.HeaderData memory blockHeader_, bytes32 blockHash_) = _parseBlockHeaderRaw(
            blockHeaderRaw_
        );

        require(
            blockExists(blockHeader_.prevBlockHash),
            PrevBlockDoesNotExist(blockHeader_.prevBlockHash)
        );

        uint64 blockHeight_ = getBlockHeight(blockHeader_.prevBlockHash) + 1;
        bytes32 currentTarget_ = getBlockTarget(blockHeader_.prevBlockHash);

        currentTarget_ = _retargetIfEpochBoundary(currentTarget_, blockHeight_);

        _validateBlockRules(
            blockHeader_,
            blockHash_,
            currentTarget_,
            _getStorageMedianTime(blockHeader_, blockHeight_)
        );

        _addBlock(blockHeader_, blockHash_, blockHeight_,
            _nextCumulativeWork(blockHeader_.prevBlockHash, currentTarget_));
    }

    /// @inheritdoc ISPVGateway
    function checkTxInclusion(
        bytes32[] calldata merkleProof_,
        bytes32 blockHash_,
        bytes32 txId_,
        uint256 txIndex_,
        uint256 minConfirmationsCount_
    ) external view returns (bool) {
        (bool isInMainchain_, uint256 confirmationsCount_) = getBlockStatus(blockHash_);

        if (!isInMainchain_ || confirmationsCount_ < minConfirmationsCount_) {
            return false;
        }

        // AUDIT (SPV-H1): reject empty proofs. With `merkleProof_.length == 0`,
        // `TxMerkleProof.verify` degenerates to `txId_ == merkleRoot`, which only
        // holds for a single-transaction (coinbase-only) block. Every tx this
        // gateway vouches for — channel funding and channel close — is a spend,
        // never a block's sole/coinbase tx, so a zero-length proof is always a
        // forgery attempt (claim an arbitrary txid equals a root in a block the
        // submitter shaped). A real inclusion proof for these is length ≥ 1.
        if (merkleProof_.length == 0) {
            return false;
        }

        bytes32 leRoot_ = getBlockMerkleRoot(blockHash_).bytes32BEtoLE();

        return TxMerkleProof.verify(merkleProof_, leRoot_, txId_, txIndex_);
    }

    /// @inheritdoc ISPVGateway
    function getMainchainHead() public view returns (bytes32) {
        return _getSPVGatewayStorage().mainchainHead;
    }

    /// @inheritdoc ISPVGateway
    function getMainchainHeight() public view returns (uint64) {
        return getBlockHeight(_getSPVGatewayStorage().mainchainHead);
    }

    /// @inheritdoc ISPVGateway
    function getBlockInfo(bytes32 blockHash_) external view returns (BlockInfo memory blockInfo_) {
        if (!blockExists(blockHash_)) {
            return blockInfo_;
        }

        BlockData memory blockData_ = _getSPVGatewayStorage().blocksData[blockHash_];

        blockInfo_ = BlockInfo({
            mainBlockData: blockData_,
            isInMainchain: isInMainchain(blockHash_),
            cumulativeWork: blockData_.cumulativeWork
        });
    }

    /// @inheritdoc ISPVGateway
    function getBlockHeader(
        bytes32 blockHash_
    ) public view returns (BlockHeader.HeaderData memory) {
        BlockData storage blockData = _getSPVGatewayStorage().blocksData[blockHash_];

        return
            BlockHeader.HeaderData({
                version: blockData.version,
                prevBlockHash: blockData.prevBlockHash,
                merkleRoot: blockData.merkleRoot,
                time: blockData.time,
                bits: blockData.bits,
                nonce: blockData.nonce
            });
    }

    /// @inheritdoc ISPVGateway
    function getBlockStatus(bytes32 blockHash_) public view returns (bool, uint64) {
        if (!isInMainchain(blockHash_)) {
            return (false, 0);
        }

        return (true, getMainchainHeight() - getBlockHeight(blockHash_));
    }

    /// @inheritdoc ISPVGateway
    function getBlockMerkleRoot(bytes32 blockHash_) public view returns (bytes32) {
        return _getSPVGatewayStorage().blocksData[blockHash_].merkleRoot;
    }

    /// @inheritdoc ISPVGateway
    function getBlockHeight(bytes32 blockHash_) public view returns (uint64) {
        return _getSPVGatewayStorage().blocksData[blockHash_].blockHeight;
    }

    /// @inheritdoc ISPVGateway
    function getBlockHash(uint64 blockHeight_) public view returns (bytes32) {
        return _getSPVGatewayStorage().blocksHeightToBlockHash[blockHeight_];
    }

    /// @inheritdoc ISPVGateway
    function getBlockTarget(bytes32 blockHash_) public view returns (bytes32) {
        return TargetsHelper.bitsToTarget(_getSPVGatewayStorage().blocksData[blockHash_].bits);
    }


    /// @inheritdoc ISPVGateway
    function blockExists(bytes32 blockHash_) public view returns (bool) {
        return _getBlockHeaderTime(blockHash_) > 0;
    }

    /// @inheritdoc ISPVGateway
    function isInMainchain(bytes32 blockHash_) public view returns (bool) {
        return getBlockHash(getBlockHeight(blockHash_)) == blockHash_;
    }

    function _initialize(
        BlockHeader.HeaderData memory blockHeader_,
        bytes32 blockHash_,
        uint64 blockHeight_,
        uint256 cumulativeWork_
    ) internal onlyInitializing {
        // Seed the checkpoint block with its ABSOLUTE cumulative work; every later
        // block accrues parent + own work per-block (see _nextCumulativeWork).
        _addBlock(blockHeader_, blockHash_, blockHeight_, cumulativeWork_);

        emit MainchainHeadUpdated(blockHeight_, blockHash_);
    }

    function _addBlock(
        BlockHeader.HeaderData memory blockHeader_,
        bytes32 blockHash_,
        uint64 blockHeight_,
        uint256 cumulativeWork_
    ) internal {
        SPVGatewayStorage storage $ = _getSPVGatewayStorage();

        $.blocksData[blockHash_] = BlockData({
            prevBlockHash: blockHeader_.prevBlockHash,
            merkleRoot: blockHeader_.merkleRoot,
            version: blockHeader_.version,
            time: blockHeader_.time,
            nonce: blockHeader_.nonce,
            bits: blockHeader_.bits,
            blockHeight: blockHeight_,
            cumulativeWork: cumulativeWork_
        });

        _updateMainchainHead(blockHeader_, blockHash_, blockHeight_);

        emit BlockHeaderAdded(blockHeight_, blockHash_);
    }

    /// Cumulative work of a block extending `prevBlockHash_`, mined at `blockTarget_`:
    /// the parent's stored cumulative work + this block's work. (The checkpoint block
    /// in `_initialize` is seeded with its absolute cumulative work instead.)
    function _nextCumulativeWork(
        bytes32 prevBlockHash_,
        bytes32 blockTarget_
    ) internal view returns (uint256) {
        return _getSPVGatewayStorage().blocksData[prevBlockHash_].cumulativeWork
            + blockTarget_.countBlockWork();
    }

    function _updateMainchainHead(
        BlockHeader.HeaderData memory blockHeader_,
        bytes32 blockHash_,
        uint64 blockHeight_
    ) internal {
        SPVGatewayStorage storage $ = _getSPVGatewayStorage();

        bytes32 mainchainHead = $.mainchainHead;

        if (blockHeader_.prevBlockHash == mainchainHead || mainchainHead == 0) {
            $.mainchainHead = blockHash_;
            $.blocksHeightToBlockHash[blockHeight_] = blockHash_;

            return;
        }

        uint256 mainchainCumulativeWork_ = _getBlockCumulativeWork(mainchainHead);
        uint256 newBlockCumulativeWork_ = _getBlockCumulativeWork(blockHash_);

        if (newBlockCumulativeWork_ > mainchainCumulativeWork_) {
            $.mainchainHead = blockHash_;
            $.blocksHeightToBlockHash[blockHeight_] = blockHash_;

            bytes32 prevBlockHash_ = blockHeader_.prevBlockHash;
            uint64 prevBlockHeight_ = blockHeight_ - 1;

            do {
                $.blocksHeightToBlockHash[prevBlockHeight_] = prevBlockHash_;

                prevBlockHash_ = _getSPVGatewayStorage().blocksData[prevBlockHash_].prevBlockHash;

                unchecked {
                    --prevBlockHeight_;
                }
            } while (getBlockHash(prevBlockHeight_) != prevBlockHash_ && prevBlockHash_ != 0);
        }
    }

    /// At an epoch boundary, recompute the difficulty target from the epoch's elapsed
    /// time (Bitcoin's 2016-block retarget); unchanged mid-epoch. Cumulative work is
    /// now tracked PER-BLOCK in `_addBlock`/`_nextCumulativeWork`, so this no longer
    /// touches any global accumulator (which mis-counted fork-choice across boundaries).
    function _retargetIfEpochBoundary(
        bytes32 currentTarget_,
        uint64 blockHeight_
    ) internal view returns (bytes32) {
        if (TargetsHelper.isTargetAdjustmentBlock(blockHeight_)) {
            currentTarget_ = TargetsHelper.countNewRoundedTarget(
                currentTarget_,
                _getEpochPassedTime(blockHeight_)
            );
        }

        return currentTarget_;
    }

    function _parseBlockHeadersRaw(
        bytes[] calldata blockHeaderRawArray_
    )
        internal
        view
        returns (BlockHeader.HeaderData[] memory blockHeaders_, bytes32[] memory blockHashes_)
    {
        require(blockHeaderRawArray_.length > 0, EmptyBlockHeaderArray());

        blockHeaders_ = new BlockHeader.HeaderData[](blockHeaderRawArray_.length);
        blockHashes_ = new bytes32[](blockHeaderRawArray_.length);

        for (uint256 i = 0; i < blockHeaderRawArray_.length; ++i) {
            (blockHeaders_[i], blockHashes_[i]) = _parseBlockHeaderRaw(blockHeaderRawArray_[i]);

            if (i == 0) {
                require(
                    blockExists(blockHeaders_[i].prevBlockHash),
                    PrevBlockDoesNotExist(blockHeaders_[i].prevBlockHash)
                );
            } else {
                require(
                    blockHeaders_[i].prevBlockHash == blockHashes_[i - 1],
                    InvalidBlockHeadersOrder()
                );
            }
        }
    }

    function _parseBlockHeaderRaw(
        bytes calldata blockHeaderRaw_
    ) internal view returns (BlockHeader.HeaderData memory blockHeader_, bytes32 blockHash_) {
        (blockHeader_, blockHash_) = blockHeaderRaw_.parseBlockHeader(true);

        _onlyNonExistingBlock(blockHash_);
    }

    function _getStorageMedianTime(
        BlockHeader.HeaderData memory blockHeader_,
        uint64 blockHeight_
    ) internal view returns (uint32) {
        if (blockHeight_ == 1) {
            return blockHeader_.time;
        }

        bytes32 toBlockHash_ = blockHeader_.prevBlockHash;

        if (blockHeight_ - 1 < MEDIAN_PAST_BLOCKS) {
            return _getBlockHeaderTime(toBlockHash_);
        }

        uint256[] memory blocksTime_ = new uint256[](MEDIAN_PAST_BLOCKS);
        bool needsSort_;

        for (uint256 i = MEDIAN_PAST_BLOCKS; i > 0; --i) {
            uint32 currentTime_ = _getBlockHeaderTime(toBlockHash_);

            blocksTime_[i - 1] = currentTime_;
            toBlockHash_ = _getSPVGatewayStorage().blocksData[toBlockHash_].prevBlockHash;

            if (i < MEDIAN_PAST_BLOCKS && currentTime_ > blocksTime_[i]) {
                needsSort_ = true;
            }
        }

        return _getMedianTime(blocksTime_, needsSort_);
    }

    function _getMemoryMedianTime(
        BlockHeader.HeaderData[] memory blockHeaders_,
        uint64 to_
    ) internal pure returns (uint32) {
        if (blockHeaders_.length < MEDIAN_PAST_BLOCKS) {
            return 0;
        }

        uint256[] memory blocksTime_ = new uint256[](MEDIAN_PAST_BLOCKS);
        bool needsSort_;

        for (uint256 i = 0; i < MEDIAN_PAST_BLOCKS; ++i) {
            uint32 currentTime_ = blockHeaders_[to_ - MEDIAN_PAST_BLOCKS + i].time;

            blocksTime_[i] = currentTime_;

            if (i > 0 && currentTime_ < blocksTime_[i - 1]) {
                needsSort_ = true;
            }
        }

        return _getMedianTime(blocksTime_, needsSort_);
    }

    function _getEpochPassedTime(uint64 blockHeight_) internal view virtual returns (uint32) {
        uint32 epochStartTime_ = _getBlockHeaderTime(
            getBlockHash(blockHeight_ - TargetsHelper.DIFFICULTY_ADJUSTMENT_INTERVAL)
        );
        uint32 epochEndTime_ = _getBlockHeaderTime(getBlockHash(blockHeight_ - 1));

        return epochEndTime_ - epochStartTime_;
    }

    function _getBlockCumulativeWork(bytes32 blockHash_) internal view returns (uint256) {
        return _getSPVGatewayStorage().blocksData[blockHash_].cumulativeWork;
    }

    function _getBlockHeaderTime(bytes32 blockHash_) internal view returns (uint32) {
        return _getSPVGatewayStorage().blocksData[blockHash_].time;
    }

    function _onlyNonExistingBlock(bytes32 blockHash_) internal view {
        require(!blockExists(blockHash_), BlockAlreadyExists(blockHash_));
    }

    function _validateBlockRules(
        BlockHeader.HeaderData memory blockHeader_,
        bytes32 blockHash_,
        bytes32 target_,
        uint32 medianTime_
    ) internal pure {
        bytes32 blockTarget_ = TargetsHelper.bitsToTarget(blockHeader_.bits);

        require(target_ == blockTarget_, InvalidTarget(blockTarget_, target_));
        require(blockHash_ <= blockTarget_, InvalidBlockHash(blockHash_, blockTarget_));
        require(
            blockHeader_.time >= medianTime_,
            InvalidBlockTime(blockHeader_.time, medianTime_)
        );
    }

    function _getMedianTime(
        uint256[] memory blocksTime_,
        bool needsSort_
    ) internal pure returns (uint32) {
        if (needsSort_) {
            LibSort.insertionSort(blocksTime_);
        }

        return uint32(blocksTime_[MEDIAN_PAST_BLOCKS / 2]);
    }
}
