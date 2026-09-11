// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBtc, IPqVerifier} from "./imports/Interfaces.sol";
import {Types, AlreadyOpen, BadSPV, ChannelKeysMismatch, InvalidParam} from "./imports/Types.sol";
import {ISPVGateway} from "./spv/interfaces/ISPVGateway.sol";
import {BitcoinTx} from "./imports/BitcoinTx.sol";
import {ChannelLib} from "./imports/ChannelLib.sol";

contract BTCChannels {

    uint private locked = 1;
    function _lock()   private { require(locked == 1, "REENTRANCY"); locked = 2; }
    function _unlock() private { locked = 1; }
    modifier nonReentrant { _lock(); _; _unlock(); }

    ISPVGateway     public immutable spv;

    IBtc public immutable btc;

    mapping(bytes32 => Types.BTCChannel) public channels;

    mapping(bytes32 => bool) public fundingOutpointUsed;

    uint public totalSatsLocked;

    mapping(bytes32 => uint64) public freshnessSeq;

    mapping(address => uint64) public managerFreshnessSeq;

    mapping(bytes32 => bool) public migrationNonceUsed;

    mapping(address => bytes32) public btcRecipientOf;

    /// §PQ-SEAM. Set once, beside `btcRecipientOf`, by whichever possession proof verified. See
    /// `_lpPayoutScript` for why the form is stored rather than derived or threaded.
    mapping(address => bool) public btcRecipientIsV2;

    mapping(address => bool) public btcRecipientLocked;

    mapping(address => bool) public hasOpenBtcChannel;

    mapping(bytes32 => mapping(uint64 => bool)) public exitArmedOnOutpoint;

    mapping(bytes32 => uint) public checkpointOf;
    mapping(bytes32 => uint) public paidOutSinceCheckpoint;

    mapping(bytes32 => uint) public pendingClaimSats;

    mapping(bytes32 => bool) public swapInUsed;

    mapping(bytes32 => bool) public swapOutUsed;

    struct PendingOnchainSwapOut {
        address swapper; uint64 sats; uint32 requestBlock; bytes32 swapperScriptHash;
        uint96 usd; address token;
    }
    mapping(bytes32 => PendingOnchainSwapOut) public pendingOnchainSwapOut;

    event BtcRecipientRegistered(address indexed owner, bytes32 pubkeyHash);
    error NotPubkeyHash();

    error NotSwapper();
    error NotChannelHop();

    error OutpointReused();
    error SwapInReplay();
    error SwapInPartialRejected();
    error NothingToClaim();

    error ClaimNotRegistered();

    error WrongBtcRecipient();
    error OneChannelPerLp();
    error BtcRecipientLockedErr();
    error WrongStatus();
    error WrongPrevOutpoint();
    error SpliceUnchanged();

    error SpliceIsNotAClose();
    error SpliceKeyNotTwoOfTwo();
    error FundingKeyNotTwoOfTwo();
    error ForeignSpliceOutput();

    error DeepestRungNotFundingOnly();
    error FreshnessNotMonotonic();
    error FreshnessJumpTooLarge();
    error ManagerFreshnessNotMonotonic();
    error MigrationNonceAlreadyUsed();

    error LadderTooDeep();

    uint internal constant MAX_LADDER_RUNGS = 16;
    error LadderTooShallow();

    event ChannelOpened(
        bytes32 indexed channelId,
        address indexed lpEth,
        address indexed hop,
        uint    sats,
        bytes   lpPubkey,
        bytes   hopPubkey,
        bytes32 fundingTxId,
        uint32  fundingVout,
        bytes32 fundingBlockHash,
        uint64  fundingBlockHeight
    );
    event ChannelClosed(bytes32 indexed channelId, uint satsReturned);
    event FreshnessCommitted(bytes32 indexed channelId, uint64 seq);
    event ManagerFreshnessCommitted(address indexed hop, uint64 seq);
    event MigrationNonceConsumed(bytes32 indexed nonce, address indexed hop);
    event ChannelSpliced(
        bytes32 indexed channelId,
        address indexed lpEth,
        bool    isGrow,
        uint    deltaSats,
        uint    newTotalSats,
        bytes32 newFundingTxId,
        uint32  newFundingVout
    );

    event SwapOutRequestedOnchain(
        address indexed swapper, uint256 sats, address token, bytes32 indexed swapId, bytes swapperScript
    );

    event SwapOutDeliveredOnchain(
        bytes32 indexed swapId, bytes32 indexed channelId, address indexed lpEth, uint256 sats,
        bytes32 newFundingTxId, uint32 newFundingVout
    );

    event SwapInSettled(
        address indexed seller, bytes32 indexed paymentHash, uint256 sats, uint256 consumedSats, address token
    );

    event DeadManExitEmitted(
        bytes32 indexed channelId,
        address indexed lpEth,
        uint64  cltvDeadline,
        uint    checkpointSats,
        bytes   signedExitTx
    );
    error SwapOutReplay();

    error SwapOutDust();
    error NotExpired();
    uint constant SWAPOUT_REFUND_BLOCKS = 7200;
    error NoSuchSwapOut();
    error SwapOutNotDelivered();
    error NotAShrink();

    function _whenOpen(bytes32 channelId) private view {
        if (channels[channelId].status != ChannelLib.STATUS_OPEN) revert WrongStatus();
    }

    function _requireClaimRegistered(bytes32 channelId) private view {
        if (pendingClaimSats[channelId] != 0) revert ClaimNotRegistered();
    }

    function _verifyTxSpendsChannel(
        bytes32 channelId,
        bytes calldata rawTx,
        bytes32 blockHash,
        bytes32[] calldata merkleProof,
        uint    txIndex
    ) internal view returns (bytes32 txId) {
        Types.BTCChannel storage ch = channels[channelId];
        txId = BitcoinTx.txid(rawTx);
        if (!spv.checkTxInclusion(merkleProof, blockHash, txId, txIndex, ChannelLib.MIN_CONFIRMATIONS))
            revert BadSPV();

        uint nIn = BitcoinTx.inputCount(rawTx);
        bool spends;
        for (uint i; i < nIn; i++) {
            (bytes32 prevHash, uint32 prevVout) =
                BitcoinTx.extractInputPrevOutpoint(rawTx, i);
            if (prevHash == ch.fundingTxId && prevVout == ch.fundingVout) {
                spends = true;
                break;
            }
        }
        if (!spends) revert WrongPrevOutpoint();
    }

    function _useOutpoint(bytes32 fundingTxId, uint32 vout) internal {
        bytes32 op = _outpointKey(fundingTxId, vout);
        if (fundingOutpointUsed[op]) revert OutpointReused();
        fundingOutpointUsed[op] = true;
    }

    function _outpointKey(bytes32 fundingTxId, uint32 vout) private pure returns (bytes32) {
        return keccak256(abi.encode(fundingTxId, vout));
    }

    function _currentOutpointKey(bytes32 channelId) private view returns (bytes32) {
        Types.BTCChannel storage ch = channels[channelId];
        return _outpointKey(ch.fundingTxId, ch.fundingVout);
    }

    function _finalizeClose(bytes32 channelId, uint lpPayoutSats)
        internal returns (uint totalSats) {
        Types.BTCChannel storage ch = channels[channelId];
        totalSats = ch.amountSats;
        ch.status = ChannelLib.STATUS_CLOSED;
        hasOpenBtcChannel[ch.lpEth] = false;
        totalSatsLocked -= totalSats;

        if (lpPayoutSats > totalSats) {
            emit PayoutExceededChannel(channelId, ch.lpEth, lpPayoutSats - totalSats);
            lpPayoutSats = totalSats;
        }

        bool claimed = pendingClaimSats[channelId] == 0;
        delete pendingClaimSats[channelId];
        if (claimed) btc.requestRedeem(ch.lpEth, lpPayoutSats);
    }

    function _lpFinalBalance(address lpEth, bytes calldata rawCloseTx)
        internal view returns (uint) {

        return BitcoinTx.sumOutputValuesToScript(rawCloseTx, _lpPayoutScript(lpEth));
    }

    function _withdrawalPayout(address lpEth, bytes calldata rawSpliceTx, uint32 fundingVout)
        private view returns (uint) {
        bytes memory p2tr = _lpPayoutScript(lpEth);
        if (BitcoinTx.sumOutputValuesExcept(rawSpliceTx, fundingVout, p2tr) != 0)
            revert ForeignSpliceOutput();
        return BitcoinTx.sumOutputValuesToScript(rawSpliceTx, p2tr);
    }

    /// §PQ-SEAM. **The form follows the DESTINATION, not the caller's context, and that is why it is
    /// one stored bit rather than a threaded argument.** `btcRecipientOf` is keyed by address and is
    /// read from four places — two channel paths, the splice withdrawal, and the swap-out destination
    /// at `requestSwapOutOnchain`, which has no channel to take a form from. A bit set once at
    /// registration makes all four correct with no signature change; the raw `bytes32` cannot be
    /// classified by inspection, because roughly half of all merkle roots are also valid x-only keys
    /// by chance.
    function _lpPayoutScript(address lpEth) private view returns (bytes memory) {
        if (btcRecipientIsV2[lpEth])
            return IPqVerifier(pqVerifier).payoutScript(btcRecipientOf[lpEth]);
        return abi.encodePacked(bytes1(0x51), bytes1(0x20), btcRecipientOf[lpEth]);
    }

    /// §PQ-SEAM. The ONLY authority this contract has ever had, and it can do exactly one thing:
    /// name the post-quantum verifier, once. It is the operator Safe that already authorises
    /// enclave-image migration (`OPERATOR_SAFE` / `guard_prod_trust_anchors`), so this reuses a trust
    /// anchor rather than creating one — but note it was previously enforced only in Rust, so this IS
    /// the first ON-CHAIN governance surface here.
    address public immutable PQ_ADMIN;

    /// §PQ-SEAM. `address(0)` until P2MR/OP_CAT activate, and while it is zero **no v2 channel can be
    /// opened at all** — which is what stops witness v2 being accepted while it is still
    /// anyone-can-spend. Write-once: a replaceable verifier would let the admin re-point the referee
    /// for channels it has already been judging.
    address public pqVerifier;

    error PqVerifierPinned();
    error NotPqAdmin();
    event PqVerifierSet(address verifier);

    function setPqVerifier(address v) external {
        if (msg.sender != PQ_ADMIN) revert NotPqAdmin();
        if (pqVerifier != address(0) || v == address(0)) revert PqVerifierPinned();
        pqVerifier = v;
        emit PqVerifierSet(v);
    }

    /// §PQ-SEAM. Which script this channel's funding output must pay, and the `form` that answer
    /// implies. **The form is DERIVED FROM THE BITCOIN TRANSACTION, never claimed in `OpenParams`** —
    /// the output either pays the secp taproot script or the verifier's, and whichever it pays is
    /// what the channel IS. That is why no field was added to `OpenParams` and no cross-language
    /// struct hash moved.
    /// ⚠️ Own frame: `openChannel` is already at the legacy stack limit (`via_ir = false`).
    function _fundingForm(Types.OpenParams calldata p)
        private view returns (bytes memory spk, uint8 form)
    {
        address v = pqVerifier;
        if (v != address(0) && p.lpPubkey.length != 33) {
            spk = IPqVerifier(v).fundingScript(p.lpPubkey, p.hopPubkey);
            form = 1;
        } else {
            if (p.lpPubkey.length != 33 || p.hopPubkey.length != 33) revert InvalidParam();
            spk = BitcoinTx.buildTaprootScriptPubKey(p.fundingTaproot);
        }
    }

    constructor(address _spv, address _btcVault, address _mainHop, address _fallbackHop,
                bytes32 _btcDepositKey, address _pqAdmin)
    {
        if (_mainHop == address(0) || _fallbackHop == address(0) || _mainHop == _fallbackHop)
            revert InvalidParam();
        spv = ISPVGateway(_spv);
        btc = IBtc(_btcVault);
        MAIN_HOP = _mainHop;
        FALLBACK_HOP = _fallbackHop;
        BTC_DEPOSIT_KEY = _btcDepositKey;
        PQ_ADMIN = _pqAdmin;
    }

    address public immutable MAIN_HOP;
    address public immutable FALLBACK_HOP;

    bytes32 public immutable BTC_DEPOSIT_KEY;

    function _onlyHop() private view {
        if (msg.sender != MAIN_HOP && msg.sender != FALLBACK_HOP) revert NotChannelHop();
    }

    function openChannel(
        Types.OpenParams calldata p,
        bytes calldata rawFundingTx,
        bytes32[] calldata fundingMerkleProof,
        Types.OpenAuth calldata auth,
        Types.ExitArming[] calldata exits
    ) external nonReentrant returns (bytes32 channelId)
    {

        _onlyHop();

        if (keccak256(p.lpIdentityPubkey) != keccak256(p.lpPubkey) &&
            keccak256(p.lpIdentityPubkey) != keccak256(p.hopPubkey)) revert InvalidParam();
        address lpEth = ChannelLib.lpEthOf(p.lpIdentityPubkey);
        if (lpEth == address(0)) revert InvalidParam();

        if (hasOpenBtcChannel[lpEth]) revert OneChannelPerLp();

        if (btcRecipientLocked[lpEth] && btcRecipientOf[lpEth] != auth.btcRecipient)
            revert WrongBtcRecipient();

        _registerBtcRecipient(lpEth, auth.btcRecipient,
            _requireRecipientPoP(lpEth, auth.btcRecipient, auth.btcRecipientPoP,
                                 keccak256(auth.lpPaymentPoint)));
        btcRecipientLocked[lpEth] = true;

        Types.BTCChannel memory channel;
        {
            (bytes memory fundingSpk, uint8 form) = _fundingForm(p);
            (channelId, channel) = ChannelLib.openChannelBody(
                p, rawFundingTx, fundingMerkleProof, lpEth, spv, fundingSpk
            );
            channel.form = form;
            // The secp MuSig2 2-of-2 proof is the v1 binding between the two keys and the funding
            // output. On v2 that binding IS `IPqVerifier.fundingScript`, which the output was just
            // matched against — running the secp check there would reject a valid PQ channel.
            if (form == 0) _proveFundingKeys(p);
        }
        if (channels[channelId].amountSats != 0) revert AlreadyOpen();

        _useOutpoint(channel.fundingTxId, channel.fundingVout);

        channel.lpToRemoteKey = ChannelLib.lpToRemoteOutputKey(auth.lpPaymentPoint);
        channels[channelId] = channel;
        hasOpenBtcChannel[channel.lpEth] = true;
        totalSatsLocked += channel.amountSats;

        _armLadder(channelId, p, exits);

        try btc.requestDeposit(channel.lpEth, channel.amountSats) {

        } catch {
            pendingClaimSats[channelId] = channel.amountSats;
            emit ChannelClaimDeferred(channelId, channel.lpEth, channel.amountSats);
        }

        _emitOpened(channelId, channel, p);
    }

    function registerChannelClaim(bytes32 channelId) external nonReentrant {
        uint sats = pendingClaimSats[channelId];
        if (sats == 0) revert NothingToClaim();

        uint total = channels[channelId].amountSats;
        if (sats > total) sats = total;
        delete pendingClaimSats[channelId];
        if (sats == 0) revert NothingToClaim();
        btc.requestDeposit(channels[channelId].lpEth, sats);
    }

    function _emitOpened(
        bytes32 channelId,
        Types.BTCChannel memory channel,
        Types.OpenParams calldata p
    ) private {
        emit ChannelOpened(
            channelId, channel.lpEth, msg.sender, channel.amountSats,
            p.lpPubkey, p.hopPubkey, channel.fundingTxId, channel.fundingVout,
            p.fundingBlockHash, p.fundingBlockHeight
        );
    }

    function splice(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32[] calldata spliceMerkleProof,
        Types.ExitArming[] calldata exits
    ) external nonReentrant {
        _whenOpen(channelId);
        _onlyHop();

        if (p.amountSats == channels[channelId].amountSats
            && keccak256(abi.encode(p.lpPubkey, p.hopPubkey)) == channels[channelId].keysHash)
            revert SpliceUnchanged();

        uint grewBy = _applySplice(channelId, p, rawSpliceTx, spliceMerkleProof);

        channels[channelId].keysHash = keccak256(abi.encode(p.lpPubkey, p.hopPubkey));

        _armLadder(channelId, p, exits);

        if (grewBy != 0) btc.requestDeposit(channels[channelId].lpEth, grewBy);

    }

    event PayoutExceededChannel(bytes32 indexed channelId, address indexed lpEth, uint over);

    event ChannelClaimDeferred(bytes32 indexed channelId, address indexed lpEth, uint sats);

    function _applySplice(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32[] calldata spliceMerkleProof
    ) private returns (uint grewBy) {
        Types.BTCChannel storage ch = channels[channelId];
        uint old = ch.amountSats;
        (bytes32 newTxId, uint32 newVout) =
            _verifySplice(channelId, p, rawSpliceTx, spliceMerkleProof);
        ch.fundingTxId = newTxId;
        ch.fundingVout = newVout;
        ch.amountSats  = p.amountSats;
        _useOutpoint(newTxId, newVout);
        if (p.amountSats > old) {
            uint delta = p.amountSats - old;
            totalSatsLocked += delta;
            grewBy = delta;
            emit ChannelSpliced(channelId, ch.lpEth, true, delta, p.amountSats, newTxId, newVout);
        } else if (p.amountSats < old) {
            _shrinkSplice(channelId, p, rawSpliceTx, newTxId, newVout, old);
        } else {

            emit ChannelSpliced(channelId, ch.lpEth, false, 0, p.amountSats, newTxId, newVout);
        }
    }

    function _shrinkSplice(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32 newTxId,
        uint32 newVout,
        uint old
    ) private {
        address lpEth = channels[channelId].lpEth;
        uint shrinkSats = old - p.amountSats;
        totalSatsLocked -= shrinkSats;
        uint lpPayoutSats = _withdrawalPayout(lpEth, rawSpliceTx, newVout);

        if (lpPayoutSats > old) {
            emit PayoutExceededChannel(channelId, lpEth, lpPayoutSats - old);
            lpPayoutSats = old;
        }
        paidOutSinceCheckpoint[channelId] += lpPayoutSats;
        _requireClaimRegistered(channelId);
        btc.resize(lpEth, shrinkSats, lpPayoutSats, 0);
        emit ChannelSpliced(channelId, lpEth, false, shrinkSats, p.amountSats, newTxId, newVout);
    }

    function emitDeadManExit(
        bytes32 channelId,
        Types.OpenParams calldata p,
        Types.ExitArming calldata exit
    ) external {
        _whenOpen(channelId);
        _onlyHop();

        _requireChannelKeys(channelId, p);

        if (exit.checkpointSats < checkpointOf[channelId]) revert CheckpointRegression();
        _armDeadManExit(channelId, p, exit);
        checkpointOf[channelId] = exit.checkpointSats;
    }

    function _proveFundingKeys(Types.OpenParams calldata p) private view {
        if (!BitcoinTx.isTwoOfTwoOutputKey(p.lpPubkey, p.hopPubkey, p.fundingTaproot))
            revert FundingKeyNotTwoOfTwo();
    }

    function _armLadder(
        bytes32 channelId, Types.OpenParams calldata p, Types.ExitArming[] calldata exits
    ) private {

        if (exits.length < 2) revert LadderTooShallow();

        if (exits.length > MAX_LADDER_RUNGS) revert LadderTooDeep();

        if (exits[exits.length - 1].prevValues.length != 1) revert DeepestRungNotFundingOnly();

        uint hi;
        for (uint i; i < exits.length; ++i) {
            if (i != 0 && exits[i].cltvDeadline <= exits[i - 1].cltvDeadline)
                revert LadderTooShallow();
            _armDeadManExit(channelId, p, exits[i]);
            if (exits[i].checkpointSats > hi) hi = exits[i].checkpointSats;
        }
        checkpointOf[channelId] = hi;
    }

    /// §PQ-SEAM. A v2 channel's exit: shared structure check, then the verifier's signature check.
    /// ⚠️ Own frame — `_armDeadManExit` is already at the legacy stack limit (`via_ir = false`).
    function _verifyExitPq(
        bytes32 channelId, Types.OpenParams calldata p, Types.ExitArming calldata exit
    ) private view returns (uint paid) {
        paid = BitcoinTx.exitStructure(
            exit.signedExitTx,
            BitcoinTx.ExitCheck({
                fundingTxId: channels[channelId].fundingTxId,
                fundingVout: channels[channelId].fundingVout,
                fundingSats: channels[channelId].amountSats,
                q:           bytes32(0),
                cltvDeadline: exit.cltvDeadline
            }),
            _lpPayoutScript(channels[channelId].lpEth));
        if (!IPqVerifier(pqVerifier).verifyExit(
                exit.signedExitTx, p.lpPubkey, p.hopPubkey, exit.prevValues, exit.prevScripts))
            revert BitcoinTx.ExitSignatureInvalid();
    }

    function _armDeadManExit(
        bytes32 channelId,
        Types.OpenParams calldata p,
        Types.ExitArming calldata exit
    ) private {

        if (exit.cltvDeadline == 0) revert InvalidParam();

        // §PQ-SEAM. The structure check is shared; only the signature scheme differs. A v2 channel's
        // 2-of-2 is not a secp MuSig2 aggregate, so `schnorrVerify` over a BIP-341 key-path sighash
        // would reject every valid PQ exit.
        uint paid = channels[channelId].form == 1
          ? _verifyExitPq(channelId, p, exit)
          : BitcoinTx.verifyDeadManExit(
            exit.signedExitTx,
            BitcoinTx.ExitCheck({
                fundingTxId: channels[channelId].fundingTxId,
                fundingVout: channels[channelId].fundingVout,
                fundingSats: channels[channelId].amountSats,
                q:           BitcoinTx.computeOutputKey(p.lpPubkey, p.hopPubkey),
                cltvDeadline: exit.cltvDeadline
            }),
            _lpPayoutScript(channels[channelId].lpEth),
            exit.prevValues, exit.prevScripts
        );
        if (paid < exit.checkpointSats) revert ExitUnderpaysCheckpoint();

        exitArmedOnOutpoint[_currentOutpointKey(channelId)][exit.cltvDeadline] = true;
        paidOutSinceCheckpoint[channelId] = 0;
        emit DeadManExitEmitted(channelId, channels[channelId].lpEth,
            exit.cltvDeadline, exit.checkpointSats, exit.signedExitTx);
    }

    function _verifySplice(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32[] calldata spliceMerkleProof
    ) private view returns (bytes32 newTxId, uint32 newVout) {
        newTxId = _verifyTxSpendsChannel(
            channelId, rawSpliceTx, p.fundingBlockHash, spliceMerkleProof, p.fundingTxIndex);
        newVout = ChannelLib.locateChannelOutput(
            rawSpliceTx, p.lpPubkey, p.hopPubkey, p.fundingTaproot, p.amountSats);

        if (!BitcoinTx.isTwoOfTwoOutputKey(p.lpPubkey, p.hopPubkey, p.fundingTaproot))
            revert SpliceKeyNotTwoOfTwo();
    }

    uint64 private constant MAX_FRESHNESS_JUMP = 1_000_000;

    function commitFreshness(bytes32 channelId, uint64 seq) external {
        _onlyHop();
        if (seq <= freshnessSeq[channelId]) revert FreshnessNotMonotonic();
        if (seq - freshnessSeq[channelId] > MAX_FRESHNESS_JUMP) revert FreshnessJumpTooLarge();
        freshnessSeq[channelId] = seq;
        emit FreshnessCommitted(channelId, seq);
    }

    function commitManagerFreshness(uint64 seq) external {
        if (seq <= managerFreshnessSeq[msg.sender]) revert ManagerFreshnessNotMonotonic();

        if (seq - managerFreshnessSeq[msg.sender] > MAX_FRESHNESS_JUMP) revert FreshnessJumpTooLarge();
        managerFreshnessSeq[msg.sender] = seq;
        emit ManagerFreshnessCommitted(msg.sender, seq);
    }

    function markMigrationNonceUsed(bytes32 nonce) external {
        _onlyHop();
        if (migrationNonceUsed[nonce]) revert MigrationNonceAlreadyUsed();
        migrationNonceUsed[nonce] = true;
        emit MigrationNonceConsumed(nonce, msg.sender);
    }

    function _requireNotSplice(
        bytes32 channelId, Types.OpenParams calldata p, bytes calldata rawTx
    ) private view {
        _requireChannelKeys(channelId, p);
        if (BitcoinTx.sumOutputValuesToScript(rawTx,
                abi.encodePacked(hex"5120",
                    BitcoinTx.computeOutputKey(p.lpPubkey, p.hopPubkey))) > 0)
            revert SpliceIsNotAClose();
    }

    function _requireChannelKeys(bytes32 channelId, Types.OpenParams calldata p) private view {
        if (keccak256(abi.encode(p.lpPubkey, p.hopPubkey)) != channels[channelId].keysHash)
            revert ChannelKeysMismatch();
    }

    error ExitUnderpaysCheckpoint();
    error CheckpointRegression();

    function recordClose(
        bytes32 channelId,
        Types.OpenParams calldata p,
        Types.TxProof calldata proof
    ) external nonReentrant {
        _whenOpen(channelId);
        bytes calldata rawCloseTx = proof.rawTx;

        _requireNotSplice(channelId, p, rawCloseTx);
        _verifyTxSpendsChannel(channelId, rawCloseTx,
            proof.blockHash, proof.merkleProof, proof.txIndex);

        bool coop = BitcoinTx.extractLocktime(rawCloseTx) == 0;

        if (!coop && !BitcoinTx.isCommitmentTx(rawCloseTx)) revert NotForceClose();
        uint lpPayoutSats = coop
            ? _lpFinalBalance(channels[channelId].lpEth, rawCloseTx)
            : channels[channelId].amountSats;

        uint ckpt = checkpointOf[channelId];
        if (msg.sender != channels[channelId].lpEth
            && coop && ckpt != 0 && lpPayoutSats + paidOutSinceCheckpoint[channelId] < ckpt)
            revert StaleClose();
        uint total = _finalizeClose(channelId, lpPayoutSats);
        emit ChannelClosed(channelId, total);
    }

    error NotForceClose();
    error StaleClose();

    function recordDeadManExit(
        bytes32 channelId,
        Types.OpenParams calldata p,
        Types.TxProof calldata proof
    ) external nonReentrant {
        _whenOpen(channelId);
        bytes calldata rawExitTx = proof.rawTx;
        address lpEth = channels[channelId].lpEth;

        uint64 deadline = BitcoinTx.extractLocktime(rawExitTx);

        if (!exitArmedOnOutpoint[_currentOutpointKey(channelId)][deadline]) revert NotDeadManExit();
        _requireNotSplice(channelId, p, rawExitTx);
        _verifyTxSpendsChannel(channelId, rawExitTx, proof.blockHash, proof.merkleProof, proof.txIndex);

        uint total = _finalizeClose(channelId, _lpFinalBalance(lpEth, rawExitTx));
        emit ChannelClosed(channelId, total);
    }

    error NotDeadManExit();

    function recordForceClosePermissionless(
        bytes32 channelId,
        Types.TxProof calldata proof
    ) external nonReentrant {
        _whenOpen(channelId);
        bytes calldata rawCloseTx = proof.rawTx;
        if (!BitcoinTx.isCommitmentTx(rawCloseTx)) revert NotForceClose();
        _verifyTxSpendsChannel(channelId, rawCloseTx, proof.blockHash, proof.merkleProof, proof.txIndex);

        _emitForceCloseLpOutput(channelId, rawCloseTx);

        uint total = _finalizeClose(channelId, channels[channelId].amountSats);
        emit ChannelClosed(channelId, total);
    }

    event ForceCloseLpOutput(
        bytes32 indexed channelId, address indexed lpEth,
        uint lpPaidSats, uint checkpointSats, uint paidOutSats
    );

    function _emitForceCloseLpOutput(bytes32 channelId, bytes calldata rawCloseTx) private {
        Types.BTCChannel storage ch = channels[channelId];
        uint paid;

        if (ch.lpToRemoteKey != bytes32(0))
            paid = BitcoinTx.sumOutputValuesToScript(
                rawCloseTx, abi.encodePacked(hex"5120", ch.lpToRemoteKey));
        emit ForceCloseLpOutput(
            channelId, ch.lpEth, paid, checkpointOf[channelId], paidOutSinceCheckpoint[channelId]);
    }

    error SwapInDepositReplay();

    function settleSwapInProven(
        Types.Terms calldata terms,
        Types.DepositProof calldata proof,
        bytes calldata rawDepositTx
    ) external nonReentrant {
        _onlyHop();
        (bytes32 txid, uint sats) = _provenDeposit(terms, proof, rawDepositTx);

        uint consumed = btc.creditSwapIn(
            terms.seller, sats, terms.token, BitcoinTx.settleFloorUsd(terms, sats));
        emit SwapInSettled(terms.seller, txid, sats, consumed, terms.token);
    }

    function _provenTxid(
        bytes32 blockHash, uint txIndex, bytes32[] calldata merkleProof, bytes calldata rawTx
    ) private returns (bytes32 txid) {
        txid = BitcoinTx.txid(rawTx);
        if (swapInUsed[txid]) revert SwapInDepositReplay();
        swapInUsed[txid] = true;
        if (!spv.checkTxInclusion(merkleProof, blockHash, txid, txIndex,
                                  ChannelLib.MIN_CONFIRMATIONS)) revert BadSPV();
    }

    function _provenDeposit(
        Types.Terms calldata terms, Types.DepositProof calldata proof, bytes calldata rawDepositTx
    )
        private returns (bytes32 txid, uint sats)
    {
        txid = _provenTxid(proof.blockHash, proof.txIndex, proof.merkleProof, rawDepositTx);
        sats = BitcoinTx.verifySwapInDeposit(
            BTC_DEPOSIT_KEY, terms, proof.userRefund, proof.cltvHeight, rawDepositTx);
    }

    function reverseSwapOut(bytes32 swapId, uint minDeliveredUsd, bool requireFull)
        external nonReentrant returns (uint consumed)
    {
        _onlyHop();
        if (swapId == bytes32(0) || swapInUsed[swapId]) revert SwapInReplay();
        PendingOnchainSwapOut memory so = pendingOnchainSwapOut[swapId];
        if (so.sats == 0) revert NotAReversal();
        swapInUsed[swapId] = true;
        delete pendingOnchainSwapOut[swapId];
        btc.subPendingSwapOut(so.usd);
        consumed = btc.creditSwapIn(so.swapper, so.sats, so.token, minDeliveredUsd);

        if (requireFull && consumed < so.sats) revert SwapInPartialRejected();
        emit SwapInSettled(so.swapper, swapId, so.sats, consumed, so.token);
    }

    error NotAReversal();

    function refundExpiredSwapOut(bytes32 swapId, uint minDeliveredUsd)
        external nonReentrant {
        PendingOnchainSwapOut memory so = pendingOnchainSwapOut[swapId];
        if (so.sats == 0) revert SwapOutReplay();
        if (msg.sender != so.swapper) revert NotSwapper();
        if (block.number < uint(so.requestBlock) + SWAPOUT_REFUND_BLOCKS) revert NotExpired();
        if (swapInUsed[swapId]) revert SwapInReplay();
        swapInUsed[swapId] = true;
        delete pendingOnchainSwapOut[swapId];
        btc.subPendingSwapOut(so.usd);
        btc.creditSwapIn(so.swapper, so.sats, so.token, minDeliveredUsd);
    }

    function requestSwapOutOnchain(
        address token, uint usdAmount, uint minSats, bytes32 swapId
    ) external nonReentrant returns (uint sats) {
        if (swapId == bytes32(0) || swapOutUsed[swapId]) revert SwapOutReplay();

        if (swapInUsed[swapId]) revert SwapOutReplay();

        if (btcRecipientOf[msg.sender] == bytes32(0)) revert NotPubkeyHash();
        bytes memory swapperScript = _lpPayoutScript(msg.sender);
        swapOutUsed[swapId] = true;
        uint usd6;
        (sats, usd6) = btc.creditSwapOut(msg.sender, token, usdAmount, minSats);

        if (sats == 0) revert SwapOutDust();

        if (sats > type(uint64).max || usd6 > type(uint96).max) revert InvalidParam();
        pendingOnchainSwapOut[swapId] = PendingOnchainSwapOut({
            swapper:           msg.sender,
            sats:              uint64(sats),
            requestBlock:      uint32(block.number),
            swapperScriptHash: keccak256(swapperScript),
            usd:               uint96(usd6),
            token:             token
        });

        btc.addPendingSwapOut(usd6);
        emit SwapOutRequestedOnchain(msg.sender, sats, token, swapId, swapperScript);
    }

    function deliverSwapOutOnchain(
        bytes32 swapId,
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32[] calldata spliceMerkleProof,
        bytes calldata swapperScript,

        Types.ExitArming[] calldata exits
    ) external nonReentrant {
        _whenOpen(channelId);
        _onlyHop();

        _requireChannelKeys(channelId, p);

        PendingOnchainSwapOut memory so = pendingOnchainSwapOut[swapId];
        if (so.sats == 0) revert NoSuchSwapOut();

        if (swapInUsed[swapId]) revert SwapOutReplay();
        if (keccak256(swapperScript) != so.swapperScriptHash) revert InvalidParam();

        if (BitcoinTx.sumOutputValuesToScript(rawSpliceTx, swapperScript) < so.sats)
            revert SwapOutNotDelivered();

        _deliverSwapOut(swapId, channelId, p, rawSpliceTx, spliceMerkleProof);

        _armLadder(channelId, p, exits);
    }

    function _deliverSwapOut(
        bytes32 swapId,
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32[] calldata spliceMerkleProof
    ) private {
        Types.BTCChannel storage ch = channels[channelId];
        if (p.amountSats >= ch.amountSats) revert NotAShrink();
        (bytes32 newTxId, uint32 newVout) = _verifySplice(channelId, p, rawSpliceTx, spliceMerkleProof);
        uint shrinkSats = ch.amountSats - p.amountSats;
        ch.fundingTxId = newTxId;
        ch.fundingVout = newVout;
        ch.amountSats  = p.amountSats;
        _useOutpoint(newTxId, newVout);
        totalSatsLocked -= shrinkSats;

        _settleSwapOutSlice(swapId, channelId, ch.lpEth, shrinkSats, newTxId, newVout);
    }

    function _settleSwapOutSlice(
        bytes32 swapId,
        bytes32 channelId,
        address lpEth,
        uint shrinkSats,
        bytes32 newTxId,
        uint32 newVout
    ) private {
        PendingOnchainSwapOut memory so = pendingOnchainSwapOut[swapId];
        uint sats = so.sats;

        paidOutSinceCheckpoint[channelId] += shrinkSats;

        _requireClaimRegistered(channelId);
        btc.resize(lpEth, shrinkSats, shrinkSats > sats ? shrinkSats - sats : 0, so.usd);

        swapInUsed[swapId] = true;
        delete pendingOnchainSwapOut[swapId];
        emit SwapOutDeliveredOnchain(swapId, channelId, lpEth, uint96(sats), newTxId, newVout);
    }

    function setBtcRecipient(bytes32 xOnlyKey, bytes calldata pop) external {

        if (btcRecipientLocked[msg.sender]) revert BtcRecipientLockedErr();

        _registerBtcRecipient(msg.sender, xOnlyKey,
            _requireRecipientPoP(msg.sender, xOnlyKey, pop, bytes32(0)));
    }

    function btcRecipientPoPDigest(address lpEth, bytes32 bindHash) public view returns (bytes32) {

        return sha256(abi.encode(block.chainid, address(this), lpEth, bindHash));
    }

    /// §PQ-SEAM. Returns TRUE when the destination proved itself under the post-quantum scheme.
    ///
    /// 🔑 **THE PROOF IS THE DISCRIMINATOR, NOT THE SHAPE.** A 32-byte destination cannot be
    /// classified by looking at it — about half of all merkle roots are on-curve x-only keys by
    /// chance — so the form is decided by WHICH PROOF VERIFIES. v1 is tried first, so behaviour is
    /// byte-identical while `pqVerifier` is unset and for every existing secp holder afterwards.
    /// ⛔ **A destination that proves NEITHER is refused.** There is no unproven registration path:
    /// §E138 exists because test keys were valid points with no known secret, and an LP who registers
    /// a destination it does not control is the one who loses the payout.
    function _requireRecipientPoP(address lpEth, bytes32 xOnlyKey, bytes calldata sig, bytes32 bindHash)
        private view returns (bool isV2) {
        bytes32 digest = btcRecipientPoPDigest(lpEth, bindHash);
        if (sig.length == 64) {
            bytes32 r; bytes32 s_;
            assembly { r := calldataload(sig.offset) s_ := calldataload(add(sig.offset, 32)) }
            if (BitcoinTx.schnorrVerify(xOnlyKey, r, s_, digest)) return false;
        }
        address v = pqVerifier;
        if (v == address(0) || !IPqVerifier(v).verifyPossession(xOnlyKey, digest, sig))
            revert NotPubkeyHash();
        return true;
    }

    function _registerBtcRecipient(address who, bytes32 xOnlyKey, bool isV2) internal {
        if (xOnlyKey == bytes32(0)) revert NotPubkeyHash();

        // §PQ-SEAM. The on-curve check is the v1 destination-validity rule; on v2 the verifier's
        // `payoutScript` IS the rule and reverts on a malformed destination. Possession has already
        // been proved under whichever scheme set `isV2`, so this only has to reject a shape the
        // payout path could not later build a script from.
        if (isV2) IPqVerifier(pqVerifier).payoutScript(xOnlyKey);
        else if (!BitcoinTx.isValidXOnlyKey(xOnlyKey)) revert NotPubkeyHash();
        btcRecipientIsV2[who] = isV2;
        btcRecipientOf[who] = xOnlyKey;
        emit BtcRecipientRegistered(who, xOnlyKey);
    }
}
