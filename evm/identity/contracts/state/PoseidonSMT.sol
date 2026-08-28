// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {RootValidity} from "./RootValidity.sol";
import {SparseMerkleTree} from "@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol";

import {IEvidenceRegistry} from "@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol";

import {StateKeeper} from "./StateKeeper.sol";

import {PoseidonUnit2L, PoseidonUnit3L} from "../libraries/Poseidon.sol";

contract PoseidonSMT is Initializable, UUPSUpgradeable {
    using SparseMerkleTree for SparseMerkleTree.Bytes32SMT;

    uint256 public constant ROOT_VALIDITY = 1 hours;

    address public stateKeeper;
    address public evidenceRegistry;

    mapping(bytes32 => uint256) internal _roots;

    SparseMerkleTree.Bytes32SMT internal _bytes32Tree;

    event RootUpdated(bytes32 root);

    modifier onlyStateKeeper() {
        _onlyStateKeeper();
        _;
    }

    modifier withRootUpdate() {
        _saveRoot();
        _;
        _commitRoot();
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function __PoseidonSMT_init(
        address stateKeeper_,
        address evidenceRegistry_,
        uint256 treeHeight_
    ) external initializer {
        require(treeHeight_ <= type(uint32).max, "PoseidonSMT: tree height overflows uint32");
        _bytes32Tree.initialize(uint32(treeHeight_));
        _bytes32Tree.setHashers(_hash2, _hash3);

        stateKeeper = stateKeeper_;
        evidenceRegistry = evidenceRegistry_;
    }

    /**
     * @notice Adds the new element to the tree.
     */
    function add(
        bytes32 keyOfElement_,
        bytes32 element_
    ) external virtual onlyStateKeeper withRootUpdate {
        _bytes32Tree.add(keyOfElement_, element_);
    }

    /**
     * @notice Removes the element from the tree.
     */
    function remove(bytes32 keyOfElement_) external virtual onlyStateKeeper withRootUpdate {
        _bytes32Tree.remove(keyOfElement_);
    }

    /**
     * @notice Updates the element in the tree.
     */
    function update(
        bytes32 keyOfElement_,
        bytes32 newElement_
    ) external virtual onlyStateKeeper withRootUpdate {
        _bytes32Tree.update(keyOfElement_, newElement_);
    }

    /**
     * @notice Gets Merkle (inclusion/exclusion) proof of the element.
     */
    function getProof(bytes32 key_) external view virtual returns (SparseMerkleTree.Proof memory) {
        return _bytes32Tree.getProof(key_);
    }

    /**
     * @notice Gets the SMT root
     */
    function getRoot() external view virtual returns (bytes32) {
        return _bytes32Tree.getRoot();
    }

    /**
     * @notice Gets the node info by its key.
     */
    function getNodeByKey(
        bytes32 key_
    ) external view virtual returns (SparseMerkleTree.Node memory) {
        return _bytes32Tree.getNodeByKey(key_);
    }

    /**
     * @notice Check if the SMT root is valid. Zero root is always invalid and latest root is always a valid one.
     * @dev The rule itself lives in {RootValidity} - see that library for why it is shared rather
     *      than written out here (sec. 2.18o).
     */
    function isRootValid(bytes32 root_) external view virtual returns (bool) {
        return RootValidity.isValid(root_, isRootLatest(root_), _roots[root_], ROOT_VALIDITY);
    }

    /**
     * @notice When `root_` STOPPED being current, or 0 if it never has.
     *
     * READ THE DIRECTION CAREFULLY - it is the opposite of what the name suggests. `withRootUpdate`
     * calls `_saveRoot()` BEFORE mutating the tree, so the timestamp stamped is the OUTGOING root's,
     * and it records the moment that root was superseded. That is what makes `isRootValid`'s
     * `_roots[root_] + ROOT_VALIDITY > block.timestamp` mean "superseded less than an hour ago",
     * which is the grace window it is meant to be. The CURRENT root has no entry at all, which is
     * why `isRootLatest` is checked first there and must be here too.
     *
     * ADDED so a consumer can require a root be no older than some event of its own, which
     * `isRootValid` cannot express - it only answers "within ROOT_VALIDITY". IdentityRegistry needs
     * exactly that: a root superseded at or before a document revocation still proves that document
     * CURRENT, and would otherwise stay usable for the rest of the window (sec. 2.18b).
     *
     * A VIEW ONLY - no new storage, so the proxy layout is untouched.
     */
    function getRootTimestamp(bytes32 root_) external view virtual returns (uint256) {
        return _roots[root_];
    }

    /**
     * @notice Check if the SMT root is a latest one
     */
    function isRootLatest(bytes32 root_) public view virtual returns (bool) {
        return _bytes32Tree.getRoot() == root_;
    }

    function _saveRoot() internal {
        _roots[_bytes32Tree.getRoot()] = block.timestamp;
    }

    function _commitRoot() internal virtual {
        bytes32 root_ = _bytes32Tree.getRoot();

        IEvidenceRegistry(evidenceRegistry).addStatement(root_, bytes32(block.timestamp));

        emit RootUpdated(root_);
    }

    function _onlyStateKeeper() internal view {
        require(stateKeeper == msg.sender, "PoseidonSMT: not a state keeper");
    }

    function _hash2(bytes32 element1_, bytes32 element2_) internal pure returns (bytes32) {
        return bytes32(PoseidonUnit2L.poseidon([uint256(element1_), uint256(element2_)]));
    }

    function _hash3(
        bytes32 element1_,
        bytes32 element2_,
        bytes32 element3_
    ) internal pure returns (bytes32) {
        return
            bytes32(
                PoseidonUnit3L.poseidon(
                    [uint256(element1_), uint256(element2_), uint256(element3_)]
                )
            );
    }

    function _onlyOwner() internal view {
        require(StateKeeper(stateKeeper).isOwner(msg.sender), "PoseidonSMT: not an owner");
    }

    function _authorizeUpgrade(address) internal virtual override onlyOwner {}

    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}
