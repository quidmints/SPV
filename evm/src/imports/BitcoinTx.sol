// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title BitcoinTx — on-chain Bitcoin transaction parsing + script construction
/// @notice Used by BTCChannels for airtight verification of funding txs at
///         open time and commitment txs at dispute time. All multi-byte
///         integers in Bitcoin tx serialization are little-endian.
///
///         "Internal byte order" vs "display order": Bitcoin stores txids and
///         hashes in tx serialization in one byte order (used for Merkle tree
///         computation in block headers and for SPV proofs). Block explorers
///         and RPC reverse these for human display. THIS LIBRARY USES INTERNAL
///         ORDER THROUGHOUT — the same order the SPV gateway uses.
///
///         Pass LEGACY-serialized tx bytes (no segwit marker/flag/witness).
///         The txid computed from segwit serialization would be the wtxid and
///         would not match the block's Merkle tree.
library BitcoinTx {
    error InputOutOfRange();
    error TruncatedTx();
    error OutputNotFound();

    // ─── txid + byte-order ─────────────────────────────────────────────

    /// @dev Compute the Bitcoin txid from raw legacy-serialized tx bytes.
    function txid(bytes calldata rawLegacy) internal pure returns (bytes32) {
        return sha256(abi.encodePacked(sha256(rawLegacy)));
    }

    // ─── VarInt ────────────────────────────────────────────────────────

    /// @dev Read a Bitcoin VarInt at `offset`. Returns (value, bytesConsumed).
    /// ⚠️ (E140) `private`, NOT `internal` — MEASURED, not assumed. §E140 expected a
    /// "duplicated `BitcoinTx` surface" to delete once `TxParser` took over witness
    /// parsing. Counting real callers says otherwise: **every other function here has at
    /// least one live use**, so there is no dead surface to subtract. `readVarInt` was the
    /// only one used purely INTERNALLY (13 call sites in this file, zero outside), so the
    /// whole available subtraction is this visibility tightening.
    /// ⇒ §E140 is CLOSED BY MEASUREMENT: the two parsers are not redundant. `TxParser`
    /// reads witness-carrying txs (which `_assertLegacy` rejects outright), and §E140-r2
    /// already established that outpoint logic must NOT move, because `TxParser`'s
    /// `previousHash` is byte-REVERSED relative to our `txid`.
    function readVarInt(bytes calldata raw, uint offset)
        private pure returns (uint value, uint consumed)
    {
        if (offset >= raw.length) revert TruncatedTx();
        uint8 first = uint8(raw[offset]);
        if (first < 0xfd) {
            return (uint(first), 1);
        } else if (first == 0xfd) {
            if (offset + 3 > raw.length) revert TruncatedTx();
            return (_readLE(raw, offset + 1, 2), 3);
        } else if (first == 0xfe) {
            if (offset + 5 > raw.length) revert TruncatedTx();
            return (_readLE(raw, offset + 1, 4), 5);
        } else {
            if (offset + 9 > raw.length) revert TruncatedTx();
            return (_readLE(raw, offset + 1, 8), 9);
        }
    }

    /// @dev Read `len` bytes little-endian as a uint starting at `offset`.
    function _readLE(bytes calldata raw, uint offset, uint len)
        private pure returns (uint v)
    {
        for (uint i = 0; i < len; i++) {
            v |= uint(uint8(raw[offset + i])) << (8 * i);
        }
    }

    // ─── Input / locktime extraction ───────────────────────────────────

    /// @dev Reject SEGWIT-serialized tx bytes. The whole library assumes LEGACY
    ///      serialization (input-count varint at offset 4); a segwit tx has the
    ///      marker byte 0x00 there. A real legacy tx never has input-count 0 (a
    ///      0-input tx is invalid), so 0x00 at offset 4 is an unambiguous segwit
    ///      marker. Callers already SPV-bind the bytes via txid() (legacy double-
    ///      SHA256 ≠ a segwit blob's wtxid), but this makes the parser SELF-defending
    ///      so a future non-SPV caller can't be silently mis-parsed.
    function _assertLegacy(bytes calldata raw) private pure {
        if (raw.length < 5 || raw[4] == 0x00) revert TruncatedTx();
    }

    /// @dev Number of inputs (the input-count varint following the 4-byte version).
    function inputCount(bytes calldata raw) internal pure returns (uint count) {
        _assertLegacy(raw);
        (count, ) = readVarInt(raw, 4);
    }

    /// @dev Extract input[i].prev_outpoint = (hash, index).
    function extractInputPrevOutpoint(bytes calldata raw, uint inputIndex)
        internal pure returns (bytes32 hash, uint32 vout)
    {
        _assertLegacy(raw);
        uint offset = 4;  // skip version
        (uint inputCount, uint consumed) = readVarInt(raw, offset);
        if (inputIndex >= inputCount) revert InputOutOfRange();
        offset += consumed;

        for (uint i = 0; i < inputIndex; i++) {
            offset += 32 + 4;  // prev_outpoint
            (uint sigLen, uint sigLenBytes) = readVarInt(raw, offset);
            offset += sigLenBytes + sigLen + 4;  // script_sig + sequence
        }

        if (offset + 36 > raw.length) revert TruncatedTx();
        assembly {
            hash := calldataload(add(raw.offset, offset))
        }
        vout = uint32(_readLE(raw, offset + 32, 4));
    }

    /// @dev Extract the locktime (last 4 bytes, little-endian).
    function extractLocktime(bytes calldata raw) internal pure returns (uint32 locktime) {
        if (raw.length < 4) revert TruncatedTx();
        locktime = uint32(_readLE(raw, raw.length - 4, 4));
    }

    /// @dev Extract input[0]'s nSequence (the 4 LE bytes after the first input's
    ///      36-byte outpoint + its script_sig).
    function extractInput0Sequence(bytes calldata raw) internal pure returns (uint32 seq) {
        _assertLegacy(raw);
        uint offset = 4; // skip version
        (uint inputCount, uint consumed) = readVarInt(raw, offset);
        if (inputCount == 0) revert TruncatedTx();
        offset += consumed;
        offset += 36; // input[0] prev_outpoint (txid 32 + vout 4)
        (uint sigLen, uint sigLenBytes) = readVarInt(raw, offset);
        offset += sigLenBytes + sigLen; // script_sig
        if (offset + 4 > raw.length) revert TruncatedTx();
        seq = uint32(_readLE(raw, offset, 4));
    }

    /// @dev Whether `raw` is a BOLT #3 COMMITMENT transaction, identified by its
    ///      distinctive obscured-commitment-number encoding: nLockTime's top byte is
    ///      0x20 AND the (single funding) input's nSequence top byte is 0x80
    ///      (BOLT #3, "Commitment Transaction": locktime = 0x20000000 | lower-24 of
    ///      the obscured number; sequence = 0x80000000 | upper-24). A cooperative
    ///      close (locktime 0), a splice (locktime = a block height, top byte 0x00),
    ///      and a swap-out delivery all FAIL this check — so a permissionless
    ///      force-retire gated on it cannot be abused by replaying a splice/coop/
    ///      deliver tx to retire a LIVE channel. (A force-close commitment tx is
    ///      public on-chain once broadcast, so any keeper can prove it.)
    function isCommitmentTx(bytes calldata raw) internal pure returns (bool) {
        return (extractLocktime(raw) >> 24) == 0x20
            && (extractInput0Sequence(raw) >> 24) == 0x80;
    }

    // ─── Output search by scriptPubKey ────────────────────────────────

    /// @notice Sum of the values of ALL outputs paying `spk` (0 if none). Summing every
    ///         match (not first-only) stops a close tx from under-reporting a payee's
    ///         total by splitting it across multiple outputs to the same script
    ///         (under-reported LP balance → over-claim). NOTE: kept as its own loop
    ///         (not folded with findOutputByScript via a shared `_scanOutputs`) — the
    ///         3-tuple helper return tipped the legacy stack in a downstream caller and
    ///         via_ir is off-limits.
    function sumOutputValuesToScript(
        bytes calldata raw,
        bytes memory spk
    ) internal pure returns (uint satoshis) {
        uint offset = _skipInputs(raw);
        (uint outputCount, uint consumed) = readVarInt(raw, offset);
        offset += consumed;
        for (uint i = 0; i < outputCount; i++) {
            if (offset + 8 > raw.length) revert TruncatedTx();
            uint value = _readLE(raw, offset, 8);
            offset += 8;
            (uint scriptLen, uint sLenBytes) = readVarInt(raw, offset);
            offset += sLenBytes;
            if (offset + scriptLen > raw.length) revert TruncatedTx();
            if (scriptLen == spk.length) {
                bool match_ = true;
                for (uint j = 0; j < scriptLen; j++) {
                    if (raw[offset + j] != spk[j]) { match_ = false; break; }
                }
                if (match_) satoshis += value;
            }
            offset += scriptLen;
        }
    }

    /// @notice Sum of the values of all outputs that are NEITHER output index
    ///         `exceptVout` NOR a payment to `spk`. Used by the splice-withdrawal
    ///         anti-redirection guard: a SHRINK splice legitimately has exactly the new
    ///         (smaller) funding output (`exceptVout`) plus the LP's payout to its
    ///         committed P2WPKH (`spk`); any other ("foreign") output means the LP is
    ///         routing channel value somewhere the EVM doesn't attribute, so callers
    ///         require this to be 0. Like `sumOutputValuesToScript`, it sums ALL such
    ///         outputs (not first-only) so the check can't be evaded by splitting.
    function sumOutputValuesExcept(
        bytes calldata raw,
        uint32 exceptVout,
        bytes memory spk
    ) internal pure returns (uint satoshis) {
        uint offset = _skipInputs(raw);
        (uint outputCount, uint consumed) = readVarInt(raw, offset);
        offset += consumed;
        // The excepted index must be a real output; otherwise the caller's "new funding
        // output" reference is bogus and every output would be counted as foreign. Fail
        // closed rather than silently treating an out-of-range index as "exclude nothing".
        if (exceptVout >= outputCount) revert OutputNotFound();
        for (uint i = 0; i < outputCount; i++) {
            if (offset + 8 > raw.length) revert TruncatedTx();
            uint value = _readLE(raw, offset, 8);
            offset += 8;
            (uint scriptLen, uint sLenBytes) = readVarInt(raw, offset);
            offset += sLenBytes;
            if (offset + scriptLen > raw.length) revert TruncatedTx();
            if (i != exceptVout) {
                bool match_ = scriptLen == spk.length;
                if (match_) {
                    for (uint j = 0; j < scriptLen; j++) {
                        if (raw[offset + j] != spk[j]) { match_ = false; break; }
                    }
                }
                if (!match_) satoshis += value; // a foreign (non-payout, non-funding) output
            }
            offset += scriptLen;
        }
    }

    /// @dev Find the FIRST output matching `expectedScriptPubKey`. Returns
    ///      (vout, satoshis). Reverts `OutputNotFound` if no match.
    ///
    /// ⚠ LP-side footgun (not protocol-exploitable): if the funding tx accidentally
    ///    includes TWO outputs to the same `wsh(...)` scriptPubKey with values X and Y,
    ///    this returns (vout=0, satoshis=X) and the channel is credited X. The LP locked
    ///    X+Y on Bitcoin but earns QUID/yield against only X; the extra Y is recoverable
    ///    only via the LP-refund timelock branch (after `selfRefundTime`). The LP only
    ///    hurts itself, but every off-chain funding-tx constructor MUST enforce "exactly
    ///    one output to the channel scriptPubKey" — the SPA's openChannel flow and any
    ///    BIP-380 descriptor wallet driving this MUST check.
    function findOutputByScript(
        bytes calldata raw,
        bytes memory expectedScriptPubKey
    ) internal pure returns (uint32 vout, uint satoshis) {
        uint offset = _skipInputs(raw);
        (uint outputCount, uint consumed) = readVarInt(raw, offset);
        offset += consumed;
        for (uint i = 0; i < outputCount; i++) {
            if (offset + 8 > raw.length) revert TruncatedTx();
            uint value = _readLE(raw, offset, 8);
            offset += 8;
            (uint scriptLen, uint sLenBytes) = readVarInt(raw, offset);
            offset += sLenBytes;
            if (offset + scriptLen > raw.length) revert TruncatedTx();
            if (scriptLen == expectedScriptPubKey.length) {
                bool match_ = true;
                for (uint j = 0; j < scriptLen; j++) {
                    if (raw[offset + j] != expectedScriptPubKey[j]) { match_ = false; break; }
                }
                if (match_) return (uint32(i), value);
            }
            offset += scriptLen;
        }
        revert OutputNotFound();
    }

    /// @dev Skip version + input section. Returns offset of output_count.
    function _skipInputs(bytes calldata raw) private pure returns (uint offset) {
        _assertLegacy(raw);
        offset = 4;
        (uint inputCount, uint consumed) = readVarInt(raw, offset);
        offset += consumed;
        for (uint i = 0; i < inputCount; i++) {
            offset += 32 + 4;
            (uint sigLen, uint sigLenBytes) = readVarInt(raw, offset);
            offset += sigLenBytes + sigLen + 4;
        }
    }

    // ─── Taproot funding scriptPubKey ─────────────────────────────────

    /// @dev Build the SIMPLE-TAPROOT (BOLT #995) channel-funding scriptPubKey: a
    ///      key-path-only P2TR output `OP_1 (0x51) PUSH32 (0x20) || Q` (34 bytes),
    ///      where `Q` is the 32-byte x-only MuSig2 key-path aggregate
    ///      `Q = lift_x(KeyAgg(KeySort(lp,hop))) + H_TapTweak(agg)·G` (empty merkle
    ///      root, BIP341 §158). The contract does **NO** secp256k1 EC math — `Q` is
    ///      supplied (committed in the LP's lpAuth over OpenParams) and the funding
    ///      output is byte-matched against `0x5120||Q`. Consensus does the
    ///      spend-time verification; the 2-of-2 guarantee rests on the LP's lpAuth
    ///      consent to Q + the off-chain MuSig2 keygen in which the LP itself
    ///      recomputes Q from its own and the hop's key — NOT on any
    ///      on-chain script reconstruction (key-path taproot reveals no script).
    ///      A key-path close carries only a 64-byte Schnorr sig (no witnessScript),
    ///      so the funding output can only ever be identified by this scriptPubKey,
    ///      never by reconstructing a redeem script from a spend witness.
    function buildTaprootScriptPubKey(bytes32 q) internal pure returns (bytes memory) {
        // OP_1 PUSH32 <32-byte x-only Q>.
        return abi.encodePacked(hex"5120", q);
    }

    /// secp256k1 field prime p.
    uint256 internal constant FIELD_SIZE =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    /// (p+1)/4 — the square-root exponent, valid because p ≡ 3 (mod 4).
    uint256 private constant SQRT_POWER =
        0x3FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBFFFFF0C;

    /// @notice (E130/E131) True iff `xOnly` is a REAL BIP-340 x-only public key — i.e.
    ///         `lift_x` would succeed, so `0x5120||xOnly` is a SPENDABLE taproot output.
    ///
    ///         ⚠️ WHY THIS EXISTS. Nothing used to check this. `btcRecipientOf` was
    ///         validated only as `!= 0`, and `swapperScript` only for its `0x51 0x20`
    ///         prefix — so 32 arbitrary bytes became a payout script. An invalid key makes
    ///         the output UNSPENDABLE and the funds paid to it are burned, unrecoverably,
    ///         with nothing detecting it until a payout is attempted and already on-chain.
    ///         **The base rate is not small: `x` is a valid coordinate only when `x³+7` is
    ///         a quadratic residue mod p, and p ≡ 3 (mod 4) makes that a coin flip — about
    ///         HALF of all 32-byte values are invalid.** A typo or a truncated hex string
    ///         hits it half the time.
    ///
    ///         Method: reject `x == 0` and `x >= p`, then take the candidate root
    ///         `y = (x³+7)^((p+1)/4)` via the `modexp` precompile and verify `y² == x³+7`.
    ///         The verification step is what makes it a decision rather than a guess — for
    ///         a non-residue the exponentiation still returns a value, it just does not
    ///         square back.
    /// @notice (E130/E131) True iff `xOnly` is a REAL BIP-340 x-only public key — i.e.
    ///         `lift_x` would succeed, so `0x5120||xOnly` is a SPENDABLE taproot output.
    ///
    ///         ⚠️ WHY THIS EXISTS. Nothing used to check this. `btcRecipientOf` was validated
    ///         only as `!= 0`, and `swapperScript` only for its `0x51 0x20` PREFIX — so 32
    ///         arbitrary bytes became a payout script. An invalid key makes the output
    ///         UNSPENDABLE and anything paid to it is burned, unrecoverably, with nothing
    ///         detecting it until a payout is attempted and already on-chain.
    ///         **The base rate is not small: `x` is a valid coordinate only when `x³+7` is a
    ///         quadratic residue mod p, and p ≡ 3 (mod 4) makes that a coin flip — about HALF
    ///         of all 32-byte values are invalid.** A typo or a truncated hex string hits it
    ///         half the time. (Measured: 107 of 200 arbitrary samples accepted.)
    ///
    ///         Method: reject `x == 0` and `x >= p`, take the candidate root
    ///         `y = (x³+7)^((p+1)/4)`, and verify `y² == x³+7`. The verification is what makes
    ///         it a decision rather than a guess — for a non-residue the exponentiation still
    ///         returns a value, it just does not square back.
    function isValidXOnlyKey(bytes32 xOnly) internal pure returns (bool) {
        uint256 x = uint256(xOnly);
        if (x == 0 || x >= FIELD_SIZE) return false;
        uint256 ySq = addmod(mulmod(mulmod(x, x, FIELD_SIZE), x, FIELD_SIZE), 7, FIELD_SIZE);
        uint256 y = _modExp(ySq, SQRT_POWER);
        return mulmod(y, y, FIELD_SIZE) == ySq;
    }

    /// @dev `pure`: the square root is square-and-multiply in-EVM rather than the `modexp`
    ///      precompile (0x05). ~256 `mulmod`s, a few thousand gas, on a one-time registration.
    ///
    ///      ⛔ **THE REASON THIS COMMENT USED TO GIVE IS REFUTED BY THIS REPO'S OWN TESTS, and
    ///      is removed rather than softened (E144).** It said the precompile is unusable on a
    ///      mainnet fork because the first touch of `0x…05` triggers an account fetch a public
    ///      node 403s, and — flatly — that *"`vm.makePersistent` does not avoid the initial
    ///      fetch"*. **It does, if it runs BEFORE `createFork`:** `test/utils/ForkPin.sol:42-43`
    ///      does `vm.deal(address(5), 0)` + `vm.makePersistent(address(5))` in that order, and
    ///      `ModexpOnFork.t.sol` asserts the precompile then works on a fork. The ORDERING was
    ///      the trick; the comment recorded the state before that was found.
    ///
    ///      ⚠️ **BUT DO NOT CONVERT THIS TO `Math.modExp` ON THAT BASIS ALONE.** The real
    ///      blocker is unexplained and still open: swapping it reproduces `NoBtcRecipient()`
    ///      **even with the precompile reachable** (E141). Nobody has chased why. Until someone
    ///      does, this stays — and note the asymmetry it leaves, which is REAL and UNEXPLAINED,
    ///      not a style choice: `MuSig2Agg.decompress` computes the SAME square root via
    ///      `Math.modExp` and is green. **Two sibling paths, two methods, one unexplained
    ///      behavioural difference.** Whoever resolves `NoBtcRecipient()` should unify them.
    function _modExp(uint256 base, uint256 exponent) private pure returns (uint256 result) {
        result = 1;
        base %= FIELD_SIZE;
        while (exponent != 0) {
            if (exponent & 1 == 1) result = mulmod(result, base, FIELD_SIZE);
            base = mulmod(base, base, FIELD_SIZE);
            exponent >>= 1;
        }
    }


    /// @dev Bitcoin's HASH160: RIPEMD160(SHA256(data)). Standard pubkey
    ///      hashing for P2WPKH outputs. Used by Aux.onChannelOpen to
    ///      derive a deterministic BTC recipient from the channel's
    ///      lpPubkey, so the swap-out hop request can settle to a
    ///      P2WPKH output the LP controls without further on-chain
    ///      registration.
}
