// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./Types.sol";
import {TxParser} from "@solarity/solidity-lib/libs/bitcoin/TxParser.sol";
import {EndianConverter} from "@solarity/solidity-lib/libs/utils/EndianConverter.sol";

import {EC256} from "@solarity/solidity-lib/libs/crypto/EC256.sol";
import {Math} from "@openzeppelin-submodule/utils/math/Math.sol";

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
    function txid(bytes calldata rawLegacy) public pure returns (bytes32) {
        return sha256(abi.encodePacked(sha256(rawLegacy)));
    }

    // ─── VarInt ────────────────────────────────────────────────────────

    /// @dev Read a Bitcoin VarInt at `offset`. Returns (value, bytesConsumed).
    /// ⚠️ (E140) `private`, NOT `internal` — MEASURED, not assumed. §E140 expected a
    /// "duplicated `BitcoinTx` surface" to delete once `TxParser` took over witness
    /// parsing. Counting real callers says otherwise: **every other function here has at
    /// least one live use**, so there is no dead surface to subtract. `readVarInt` was the
    /// only one used purely INTERNALLY — **zero call sites outside this file**, which is the half
    /// that justifies `private`; the in-file count is 15 today and is deliberately NOT pinned here,
    /// because an absolute count in a comment rots on the next edit (it said 13). Re-derive with
    /// `grep -c readVarInt`. **The claim that survives edits is the ZERO, not the 13.** So the
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
    function inputCount(bytes calldata raw) public pure returns (uint count) {
        _assertLegacy(raw);
        (count, ) = readVarInt(raw, 4);
    }

    /// @dev Extract input[i].prev_outpoint = (hash, index).
    function extractInputPrevOutpoint(bytes calldata raw, uint inputIndex)
        public pure returns (bytes32 hash, uint32 vout)
    {
        _assertLegacy(raw);
        uint offset = 4;  // skip version
        (uint nIn, uint consumed) = readVarInt(raw, offset);   // §DEDUP-NAMES: was `inputCount`, which shadowed the FUNCTION `inputCount()` in this same library
        if (inputIndex >= nIn) revert InputOutOfRange();
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
    function extractLocktime(bytes calldata raw) public pure returns (uint32 locktime) {
        if (raw.length < 4) revert TruncatedTx();
        locktime = uint32(_readLE(raw, raw.length - 4, 4));
    }

    /// @dev Extract input[0]'s nSequence (the 4 LE bytes after the first input's
    ///      36-byte outpoint + its script_sig).
    function extractInput0Sequence(bytes calldata raw) public pure returns (uint32 seq) {
        _assertLegacy(raw);
        uint offset = 4; // skip version
        (uint nIn, uint consumed) = readVarInt(raw, offset);   // §DEDUP-NAMES: was `inputCount`, which shadowed the FUNCTION `inputCount()` in this same library
        if (nIn == 0) revert TruncatedTx();
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
    function isCommitmentTx(bytes calldata raw) public pure returns (bool) {
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
    ) public pure returns (uint satoshis) {
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
    ) public pure returns (uint satoshis) {
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
    ) public pure returns (uint32 vout, uint satoshis) {
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
        (uint nIn, uint consumed) = readVarInt(raw, offset);   // §DEDUP-NAMES: was `inputCount`, which shadowed the FUNCTION `inputCount()` in this same library
        offset += consumed;
        for (uint i = 0; i < nIn; i++) {
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
    ///      root, BIP341 §158). `Q` is supplied and the funding output is byte-matched
    ///      against `0x5120||Q`. Consensus does the spend-time verification.
    ///      🔑 **THE 2-of-2 GUARANTEE RESTS ON THE KeyAgg GATE, NOT ON AN LP SIGNATURE.**
    ///      This said it "rests on the LP's lpAuth consent to Q" — **that is false since §E183
    ///      item 1 deleted `lpEth`/`lpSig` from `OpenAuth`; the LP signs nothing on the EVM at
    ///      open.** What binds Q is algebraic: `MuSig2Agg.isTwoOfTwoOutputKey` PROVES
    ///      `Q == TapTweak(KeyAgg(lpPubkey, hopPubkey))` on-chain (§E129/§E142), so a supplied Q
    ///      that is not the two-party aggregate is rejected without anyone having to have signed
    ///      for it. `BTCChannels.sol:66-69` already carried this correction; these three files did
    ///      not, which is how one true note and three false ones coexisted.
    ///      NOT an on-chain script reconstruction (key-path taproot reveals no script).
    ///      A key-path close carries only a 64-byte Schnorr sig (no witnessScript),
    ///      so the funding output can only ever be identified by this scriptPubKey,
    ///      never by reconstructing a redeem script from a spend witness.
    function buildTaprootScriptPubKey(bytes32 q) public pure returns (bytes memory) {
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
    /// (§E183 item 1) THE EVM ADDRESS OF A 33-BYTE COMPRESSED secp256k1 KEY — DERIVED, NOT SUPPLIED.
    ///
    /// Bitcoin and Ethereum share secp256k1, so an LP's channel key already determines its EVM
    /// address; supplying `lpEth` alongside it was asking for a fact the key states. Deriving it is
    /// what lets `openChannel` drop the LP's ECDSA signature entirely — the goal §E183 item 1 set
    /// and §E157 did not reach: *prove `Q == KeyAgg(lpPubkey, hopPubkey)` ⇒ `lpPubkey` is proven ⇒
    /// `lpEth` is DERIVABLE ⇒ the LP signs NOTHING on the EVM.*
    ///
    /// ⚠️ **THE ON-CURVE CHECK IS NOT OPTIONAL AND IS NOT DECORATION.** `y` is recovered as a
    /// modular square root and then VERIFIED (`y*y == ySq`). Skip it and a caller supplies an `x`
    /// with no square root, gets a junk `y`, and derives an address IT controls — crediting itself
    /// for someone else's sats. That is the same class §E130 closed for payout keys, arriving
    /// through the identity side instead.
    ///
    /// Returns `address(0)` on any malformed input so the caller decides the revert. Costs one
    /// square-and-multiply (~256 `mulmod`s), which is noise beside the ~631k of the KeyAgg gate
    /// this open already pays.
    function evmAddressOfCompressed(bytes memory compressed) internal pure returns (address) {
        if (compressed.length != 33) return address(0);
        uint8 prefix = uint8(compressed[0]);
        if (prefix != 0x02 && prefix != 0x03) return address(0);
        uint256 x;
        assembly { x := mload(add(compressed, 33)) }   // 32 length + 1 prefix byte
        if (x == 0 || x >= FIELD_SIZE) return address(0);
        uint256 ySq = addmod(mulmod(mulmod(x, x, FIELD_SIZE), x, FIELD_SIZE), 7, FIELD_SIZE);
        uint256 y = _modExp(ySq, SQRT_POWER);
        if (mulmod(y, y, FIELD_SIZE) != ySq) return address(0);   // x has no square root: not a key
        // The prefix names the parity of `y`; the root we computed may be the other one.
        if ((y & 1) != (uint256(prefix) & 1)) y = FIELD_SIZE - y;
        return address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
    }

    function isValidXOnlyKey(bytes32 xOnly) public pure returns (bool) {
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

    // ═══ §E312 — `MuSig2Agg` FOLDED IN; the file is deleted ═══
    // Both are Bitcoin primitives and the dependency ran ONE WAY: `MuSig2Agg` used
    // `BitcoinTx`, never the reverse (BitcoinTx named it only in comments), so folding
    // dissolves the edge instead of creating a cycle. Its `BitcoinTx.` calls are now direct.
    /// @title  MuSig2Agg — prove a taproot output key IS the 2-of-2 of two named pubkeys
    /// @notice Closes the gap `BTCChannels.sol` has always admitted: *"The contract does NO
    ///         secp256k1 EC, so it does NOT prove Q == KeyAgg(lpPubkey, hopPubkey)"*. Until now
    ///         `lpPubkey`/`hopPubkey` were only LENGTH-validated (`ChannelLib.sol:601` on the open
    ///         path, `:658` in `locateChannelOutput`, `:562` for the hop half on rekey — the
    ///         citation here used to read `:494`, which drifted onto `_approveMax`'s
    ///         `ret.length == 0` and reads as an unrelated ERC-20 guard) and the
    ///         funding output was located purely by the caller-supplied `Q` — so a hop could
    ///         open, or splice into, a `Q` it solely controls. In fleet mode the operator holds
    ///         both halves and can do that alone (E129).
    ///
    ///         ⚠️ NO NEW DEPENDENCY, AND NO VENDORING. The solarity solidity-lib is already a
    ///         remapped dependency (it supplies `BlockHeader`/`TxMerkleProof` to the SPV
    ///         gateway) and ships an AUDITED, curve-parameterised `EC256`. Its `jMultShamir2`
    ///         computes `u1·P1 + u2·P2` in one pass — which IS 2-key KeyAgg. That removes the
    ///         need for Chainlink's witness pattern (whose lifted code drops an on-curve check)
    ///         and for crysol (unaudited). secp256k1 is just parameters here: a=0, b=7.
    using EC256 for *;

    /// secp256k1. `a = 0`, `b = 7`, and n/p/G are the standard constants.
    function curve() internal pure returns (EC256.Curve memory) {
        return EC256.Curve({
            a:  0,
            b:  7,
            p:  0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F,
            n:  0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141,
            gx: 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
            gy: 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
        });
    }

    /// @dev BIP-340 tagged hash: `SHA256(SHA256(tag) || SHA256(tag) || msg)`.
    ///      SHA256 is precompile 0x02, so this is cheap.
    function taggedHash(string memory tag, bytes memory msg_) internal pure returns (bytes32) {
        bytes32 t_ = sha256(bytes(tag));
        return sha256(abi.encodePacked(t_, t_, msg_));
    }

    /// @notice Decompress a 33-byte SEC1 pubkey. Reverts if the bytes are not a curve point.
    /// @dev The y-parity is the prefix byte (0x02 even, 0x03 odd), and `y = ±sqrt(x³+7)`.
    ///      p ≡ 3 (mod 4) so the root is `(x³+7)^((p+1)/4)`; squaring it back is what makes
    ///      this a decision rather than a guess — a non-residue still yields a value.
    function decompress(bytes memory pk33) internal view returns (EC256.APoint memory pt) {
        require(pk33.length == 33, "BitcoinTx: pubkey must be 33 bytes");
        uint8 prefix = uint8(pk33[0]);
        require(prefix == 2 || prefix == 3, "BitcoinTx: bad SEC1 prefix");

        uint256 p = curve().p;
        uint256 x;
        assembly ("memory-safe") { x := mload(add(pk33, 33)) }   // bytes 1..32
        require(x != 0 && x < p, "BitcoinTx: x out of field");

        uint256 ySq = addmod(mulmod(mulmod(x, x, p), x, p), 7, p);
        uint256 y = Math.modExp(ySq, (p + 1) >> 2, p);   // p ≡ 3 (mod 4)
        require(mulmod(y, y, p) == ySq, "BitcoinTx: x is not on the curve");
        // `y == 0` would be an order-2 point. secp256k1's group order is PRIME, so none
        // exists and `x³+7 == 0` has no on-curve solution — but the code should not rely on
        // an unstated theorem, and the check costs nothing.
        require(y != 0, "BitcoinTx: degenerate point");

        if ((y & 1) != (prefix & 1)) y = p - y;                  // match the declared parity
        pt = EC256.APoint({x: x, y: y});
    }

    /// @notice TRUE iff `qXOnly` is the BIP-341 output key of the MuSig2 2-of-2 over these
    ///         two pubkeys — i.e. `Q = KeyAgg(KeySort(pk1, pk2)) + H_TapTweak(x)·G`.
    /// @dev The whole point: it can only be true if BOTH named keys are inside `Q`.
    /// @dev Locals in a struct: one memory pointer costs less stack than a dozen values.
    ///      (House rule — stack-too-deep is solved this way here, never with via_ir.)
    struct AggVars {
        EC256.Curve ec;
        bytes p1;
        bytes p2;
        uint256 a1;
        EC256.APoint P1;
        EC256.APoint P2;
        EC256.APoint agg;
        uint256 t;
    }

    /// @dev `public`, not `internal`, so this DEPLOYS AS A LINKED LIBRARY and is delegatecalled
    ///      rather than inlined. Inlined it added ~4.8 KB to `BTCChannels` and pushed it 1,344
    ///      bytes OVER EIP-170 — which `forge test` does not enforce and only
    ///      `forge build --sizes` reveals. Same pattern the codebase already uses for SwapLib
    ///      and LevMath; the large external surface is deliberate, not accidental API.
    function isTwoOfTwoOutputKey(
        bytes memory pkA33,
        bytes memory pkB33,
        bytes32 qXOnly
    ) public view returns (bool) {
        return computeOutputKey(pkA33, pkB33) == qXOnly;
    }

    /// @notice The same aggregate, RETURNED rather than compared: the BIP-341 output key of
    ///         the MuSig2 2-of-2 over these two pubkeys.
    /// @dev    Exists because a test fixture that wants a channel the gate will ACCEPT has to
    ///         be able to build a genuine `Q`, and the alternative — a hardcoded triple — pins
    ///         every splice fixture to one key pair. Note the circularity this creates and why
    ///         it is safe: fixtures built with this function cannot detect a bug IN it, so the
    ///         correctness of the aggregation is pinned independently by
    ///         `MuSig2Agg.t.sol`'s BIP-327 reference vector, which is ground truth from
    ///         outside this repo. Fixtures prove the WIRING; the vector proves the MATH.
    function computeOutputKey(
        bytes memory pkA33,
        bytes memory pkB33
    ) public view returns (bytes32) {
        // ⚠️ VALIDATE LENGTH BEFORE SORTING. `_cmp` walks 33 bytes, so a short array used to
        // panic inside the comparison rather than reverting with a reason — an unclear
        // failure on the validation path itself.
        require(pkA33.length == 33 && pkB33.length == 33, "BitcoinTx: pubkey must be 33 bytes");

        AggVars memory v;
        v.ec = curve();

        // BIP-327 KeySort: lexicographic over the 33-byte encodings.
        (v.p1, v.p2) = _lessThan(pkA33, pkB33) ? (pkA33, pkB33) : (pkB33, pkA33);

        // ⚠️ THE "SECOND KEY" RULE, which the BIP-327 vectors caught me getting wrong.
        //    `key_agg_coeff_internal` returns 1 — NOT a hash — for the second key (the first
        //    entry differing from `pubkeys[0]`). Hashing both yields a plausible-looking
        //    aggregate that is simply a different point: invisible by inspection.
        //
        // ⚠️ AND THE RULE HAS A CASE THIS IMPLEMENTATION DOES NOT REPRODUCE: `pkA33 == pkB33`.
        //    BIP-327's `GetSecondKey` returns ⊥ when every key is equal, so NEITHER entry gets
        //    the coefficient 1 and BIP-327 computes `2a·P`. The line below assigns 1 to `v.p2`
        //    unconditionally, so we compute `(a1 + 1)·P` — a DIFFERENT point, and one no
        //    BIP-327 signer will ever produce.
        //    ⇒ **The divergence FAILS CLOSED against the attack this gate exists to stop.** A
        //    channel is only accepted if the Bitcoin funding output equals what this function
        //    computes, and the real MuSig2 signers are BIP-327, so a degenerate pair produces an
        //    on-chain `Q` we reject rather than one we wrongly accept. The mirror case — a hop
        //    naming its OWN key for BOTH halves and funding the `Q` this function returns — is a
        //    channel whose `lpEth` (`ChannelLib.lpEthOf(p.lpPubkey)`) IS the hop, so the only
        //    party whose custody a sole key-holder could take is itself. There is no second party
        //    to defraud, which is why the open path does not reject `lpPubkey == hopPubkey`: a
        //    revert there would be a bound on a state with no victim (standing rule 3).
        //    ▶️ **RE-DERIVE THIS BEFORE ADDING ANY CALLER THAT DOES NOT DERIVE ITS COUNTERPARTY
        //    IDENTITY FROM `lpPubkey`.** The safety here is not in the arithmetic; it is in
        //    `lpEth` being a FUNCTION of `lpPubkey`, so equal keys collapse the two roles into
        //    one identity. A caller that names the LP separately breaks that and reopens it.
        v.a1 = uint256(taggedHash(
            "KeyAgg coefficient",
            abi.encodePacked(taggedHash("KeyAgg list", abi.encodePacked(v.p1, v.p2)), v.p1)
        )) % v.ec.n;

        v.P1 = decompress(v.p1);
        v.P2 = decompress(v.p2);
        // Explicit, because assuming it is how crysol shipped a broken `isOnCurve`.
        require(v.ec.isOnCurve(v.P1) && v.ec.isOnCurve(v.P2), "BitcoinTx: pubkey off curve");

        // a1·P1 + 1·P2 in one Shamir pass — this IS 2-key KeyAgg.
        v.agg = v.ec.toAffine(
            v.ec.jMultShamir2(EC256.toJacobian(v.P1), EC256.toJacobian(v.P2), v.a1, 1)
        );

        // BIP-341 tweaks the EVEN-Y LIFT of the aggregate, not the aggregate as computed.
        // Skipping this was the second bug the vectors caught — wrong for half of all pairs.
        if (v.agg.y % 2 != 0) v.agg.y = v.ec.p - v.agg.y;
        v.t = uint256(taggedHash("TapTweak", abi.encodePacked(bytes32(v.agg.x)))) % v.ec.n;

        return bytes32(v.ec.toAffine(
            v.ec.jAddPoint(EC256.toJacobian(v.agg), v.ec.jMultShamir(v.ec.jbasepoint(), v.t))
        ).x);
    }

    /// @notice (E159) BIP-341 TapLeaf hash for ONE script leaf:
    ///         `tagged_hash("TapLeaf", leafVersion || compactSize(script) || script)`.
    /// @dev Leaf version is fixed at 0xc0 (the only version taproot defines today). Scripts
    ///      longer than 252 bytes revert rather than emitting a wrong compact size — a
    ///      silently mis-encoded length would hash to a plausible leaf that simply is not the
    ///      one on chain, which is the failure this whole path exists to make impossible.
    function tapLeafHash(bytes memory script) public pure returns (bytes32) {
        require(script.length < 0xfd, "BitcoinTx: leaf script too long");
        return taggedHash(
            "TapLeaf", abi.encodePacked(bytes1(0xc0), bytes1(uint8(script.length)), script));
    }

    /// @notice (E159) BIP-341 output key for an internal key committing to a SINGLE leaf:
    ///         `Q = lift_x_even(P) + H_TapTweak(x(P) || leafHash)·G`.
    /// @dev Differs from `computeOutputKey` in exactly two ways, both load-bearing: the
    ///      internal key is GIVEN (not aggregated from two pubkeys), and the TapTweak hash
    ///      commits to the merkle root as well as the key. `computeOutputKey` passes only the
    ///      key because a channel funding output has an EMPTY tree; a swap-in deposit has the
    ///      user's CLTV refund leaf, so omitting the root here would compute the key for a
    ///      DIFFERENT (key-path-only) address that no deposit will ever pay.
    function taprootOutputKeyWithLeaf(bytes32 internalX, bytes32 leafHash)
        public view returns (bytes32)
    {
        EC256.Curve memory ec = curve();
        // Even-Y lift of the x-only internal key, exactly as BIP-341 specifies.
        EC256.APoint memory P = decompress(abi.encodePacked(bytes1(0x02), internalX));
        require(ec.isOnCurve(P), "BitcoinTx: internal key off curve");
        uint t = uint256(taggedHash(
            "TapTweak", abi.encodePacked(internalX, leafHash))) % ec.n;
        return bytes32(ec.toAffine(
            ec.jAddPoint(EC256.toJacobian(P), ec.jMultShamir(ec.jbasepoint(), t))
        ).x);
    }

    /// @notice (E128) BIP-340 Schnorr verification: `s·G == R + e·P`, with `R.x == r` and R even-Y.
    /// @param px x-only public key (the taproot output key `Q` for a key-path spend)
    /// @param rx signature's R.x  · @param sig signature's s  · @param m the 32-byte message
    ///
    /// @dev ⚠️ WHY THIS IS HAND-WRITTEN RATHER THAN IMPORTED (§E128-r/§E128-r2): **no EVM Schnorr
    ///      library verifies BITCOIN signatures.** Chronicle's Scribe, ERC-7816 and crysol all
    ///      standardise a DIFFERENT scheme — a shared lineage that is not BIP-340 — so their
    ///      contracts verify the wrong thing. Only the CURVE arithmetic is borrowed (solarity's
    ///      audited `EC256`); the protocol layer is ours, exactly as with KeyAgg.
    ///
    /// @dev ⚠️ RETURNS FALSE, NEVER REVERTS, on every malformed input. BIP-340 defines an
    ///      out-of-range `r`/`s`, an off-curve key, an infinite `R` and an odd-Y `R` as INVALID
    ///      SIGNATURES — not as errors. Reverting instead would make a bad signature
    ///      indistinguishable from a bad call at the call site.
    function schnorrVerify(bytes32 px, bytes32 rx, bytes32 sig, bytes32 m)
        public view returns (bool)
    {
        EC256.Curve memory ec = curve();
        if (uint256(rx) >= ec.p || uint256(sig) >= ec.n) return false;

        // ⚠️ THE ON-CURVE TEST MUST COME **BEFORE** `decompress`, WHICH REVERTS. I wrote this
        // the other way round — decompress, then `isOnCurve` — and the off-curve test failed with
        // `MuSig2Agg: x is not on the curve` instead of returning false, making the check
        // UNREACHABLE. BIP-340 classifies an unliftable x as an INVALID SIGNATURE, not an error.
        if (!isValidXOnlyKey(px)) return false;
        // lift_x: BIP-340 keys are x-only and always the EVEN-Y point.
        EC256.APoint memory P = decompress(abi.encodePacked(bytes1(0x02), px));

        uint e = uint256(taggedHash(
            "BIP0340/challenge", abi.encodePacked(rx, px, m))) % ec.n;

        // R = s·G − e·P, computed as s·G + (n−e)·P in ONE Shamir pass.
        // e == 0 would make the second scalar `n`, which is ≡ 0 but not necessarily handled as
        // such by the ladder — so it is normalised here rather than relied upon.
        EC256.APoint memory R = ec.toAffine(ec.jMultShamir2(
            ec.jbasepoint(), EC256.toJacobian(P), uint256(sig), e == 0 ? 0 : ec.n - e));

        if (R.x == 0 && R.y == 0) return false;   // point at infinity
        if (R.y % 2 != 0) return false;           // BIP-340 requires even-Y R
        return bytes32(R.x) == rx;
    }

    function _lessThan(bytes memory a, bytes memory b) private pure returns (bool) {
        return uint256(keccak256(a)) == uint256(keccak256(b))
            ? false
            : _cmp(a, b);
    }

    function _cmp(bytes memory a, bytes memory b) private pure returns (bool) {
        for (uint256 i = 0; i < 33; ++i) {
            if (uint8(a[i]) != uint8(b[i])) return uint8(a[i]) < uint8(b[i]);
        }
        return false;
    }


    // ═══ §E318 — `ExitLib` FOLDED IN (one-way dep, 0 reverse refs). The cycle that blocked this
    // earlier went through `MuSig2Agg`; §E312 removed that path by folding it into `BitcoinTx` first. ═══
    /// @notice SECTION (was `ExitLib`'s title):  ExitLib — BIP-341 verification of PRE-SIGNED Bitcoin spends: the dead-man channel exit
    ///         (§E128) and the on-chain swap-in deposit address (§E159).
    ///
    /// 🔴 WHY IT IS ITS OWN LIBRARY AND NOT PART OF `ChannelLib`. It was written into `ChannelLib` and
    /// pushed it to **25,868 bytes — 1,292 OVER EIP-170**, i.e. undeployable, while every test stayed
    /// green: `forge test` does not enforce the limit and `forge build --sizes` omits library-linked
    /// contracts entirely, so only `tools/check-contract-sizes.py` could see it. The split is not a
    /// size hack, though — the boundary is real. `ChannelLib` is the EVM-side channel/venue bookkeeping
    /// (SPV open, Aave/Euler/Liquity bodies); this is pure Bitcoin consensus arithmetic with no storage
    /// and no protocol state, exercised standalone by `ExitStructure` / `TapSighash` /
    /// `DeadManExitVerify` / `SwapInDeposit`. Two linked libraries also mean two 24 KB budgets.
    ///
    /// Delegatecalled from `BTCChannels`, so the `external` surface is required, not incidental.
    /// Kept as an external entrypoint: §E128's structural half is independently useful and is
    /// what `ExitStructure.t.sol` pins.
    function verifyExitStructure(
        bytes calldata signedExitTx, bytes32 fundingTxId, uint32 fundingVout,
        bytes calldata lpPayoutScript, uint64 cltvDeadline
    ) external pure returns (uint) {
        return _exitStructure(signedExitTx, fundingTxId, fundingVout, lpPayoutScript, cltvDeadline);
    }

    error ExitSignatureInvalid();    // BIP-340 verification failed against the funding key Q
    error ExitWitnessMissing();      // the funding input carries no 64-byte key-path signature

    /// @notice (E128) FULL verification of a pre-signed dead-man exit: structure, sighash and
    ///         signature. This is what turns `emitDeadManExit` from "record whatever bytes the hop
    ///         supplies" into a checked guarantee.
    ///
    /// @dev 🔑 THE CONTRACT SUPPLIES THE FUNDING PREVOUT ITSELF rather than trusting the caller's
    ///      array. `Prevouts::All` commits to every spent output's value and script; the FUNDING
    ///      one is known on-chain (`amountSats`, and `0x5120||Q`), so it is overwritten here. Only
    ///      the OTHER inputs — in practice the shared freshness UTXO — come from the caller, and a
    ///      wrong value there forges nothing: the sighash differs and verification simply fails.
    ///      Leaving the funding prevout caller-supplied would have let a hop compute a sighash
    ///      over a DIFFERENT amount, sign that, and pass.
    ///
    /// @param q  the funding output key `Q` — recomputed by the caller from the channel's pinned
    ///           pubkeys, never supplied loose.
    /// (E128) What the chain already knows about the channel being armed. Bundled because the
    /// verifier otherwise exceeds the legacy stack, and the house fix is a struct, not `via_ir`.
    struct ExitCheck {
        bytes32 fundingTxId;
        uint32  fundingVout;
        uint    fundingSats;   // the funding prevout's value, from the channel record
        bytes32 q;             // the funding output key, recomputed from the pinned pubkeys
        uint64  cltvDeadline;
    }

    /// @dev Own frame: locate the input spending the channel's funding outpoint.
    function _fundingInput(TxParser.Transaction memory t, bytes32 fundingTxid, uint32 vout)
        private pure returns (uint idx)
    {
        for (uint i; i < t.inputs.length; ++i)
            if (EndianConverter.bytes32LEtoBE(t.inputs[i].previousHash) == fundingTxid
                && t.inputs[i].previousIndex == vout) return i;
        revert ExitNotForThisChannel();
    }

    /// @dev Own frame: the key-path witness is exactly ONE 64-byte Schnorr signature under
    ///      SIGHASH_DEFAULT. Anything else is not a key-path spend of this output.
    function _keyPathSig(TxParser.Transaction memory t, uint idx)
        private pure returns (bytes32 r, bytes32 sig)
    {
        if (t.inputs[idx].witnesses.length != 1 || t.inputs[idx].witnesses[0].length != 64)
            revert ExitWitnessMissing();
        bytes memory w = t.inputs[idx].witnesses[0];
        assembly { r := mload(add(w, 32)) sig := mload(add(w, 64)) }
    }

    /// @notice (E128) FULL verification of a pre-signed dead-man exit — structure, sighash AND
    ///         signature. This is what turns `emitDeadManExit` from "record whatever bytes the hop
    ///         supplies" into a checked guarantee. Returns the sats the exit pays the LP.
    ///
    /// @dev 🔑 THE CONTRACT PINS THE FUNDING PREVOUT ITSELF rather than trusting the caller's
    ///      array. `Prevouts::All` commits to every spent output's value and script; the FUNDING
    ///      one is known on-chain, so it is overwritten here. Only the OTHER inputs — in practice
    ///      the shared freshness UTXO — come from the caller, and a wrong value there forges
    ///      nothing: the sighash differs and verification fails. Leaving it caller-supplied would
    ///      have let a hop compute a sighash over a DIFFERENT amount, sign THAT, and pass.
    function verifyDeadManExit(
        bytes calldata signedExitTx,
        ExitCheck calldata c,
        bytes calldata lpPayoutScript,
        uint64[] memory prevValues,
        bytes[] memory prevScripts
    ) external view returns (uint paidToLp) {
        paidToLp = _exitStructure(
            signedExitTx, c.fundingTxId, c.fundingVout, lpPayoutScript, c.cltvDeadline);
        _verifyExitSignature(signedExitTx, c, prevValues, prevScripts);
    }

    /// @dev Own frame — the signature half alone exceeds the legacy stack when inlined above.
    ///      Re-parses rather than threading the parsed tx through, which would cost more stack
    ///      than the parse costs gas at this call frequency (once per arm).
    function _verifyExitSignature(
        bytes calldata signedExitTx,
        ExitCheck calldata c,
        uint64[] memory prevValues,
        bytes[] memory prevScripts
    ) private view {
        (TxParser.Transaction memory t, ) = TxParser.parseTransaction(signedExitTx);
        uint idx = _fundingInput(t, c.fundingTxId, c.fundingVout);
        // Pin the FUNDING prevout to what the chain knows; only the others are caller-supplied.
        prevValues[idx]  = uint64(c.fundingSats);
        prevScripts[idx] = abi.encodePacked(hex"5120", c.q);
        (bytes32 r, bytes32 sig) = _keyPathSig(t, idx);
        bytes32 m = _sighash(signedExitTx, prevValues, prevScripts, uint32(idx));
        if (!schnorrVerify(c.q, r, sig, m)) revert ExitSignatureInvalid();
    }

    error DepositNotPaid();          // no output pays the recomputed deposit address

    /// @notice (E159) Recompute an on-chain swap-in DEPOSIT address and return the sats paid to it.
    ///
    /// 🔴 WHY THIS EXISTS: `settleSwapIn` credits the SHARED pool on the hop's WORD — no proof any
    ///    BTC arrived. A compromised hop can attest swap-ins for sats that never existed and drain
    ///    `POOLED_USD` to its liquidity limit, harming QU!D holders and other LPs who never
    ///    opted into that trust. This is the on-chain rail's half of the fix: prove the deposit.
    ///
    /// 🔑 WHY THE ADDRESS IS RECOMPUTED RATHER THAN SUPPLIED. If the caller named the script, a hop
    ///    could SPV-prove a genuine payment to a script IT controls and collect USD for BTC that
    ///    never entered protocol custody — the proof would be real and worthless. Deriving it from
    ///    a PINNED internal key plus the swap's own refund leaf makes "is this OUR address" a
    ///    computation rather than a claim.
    ///
    /// ⚠️ THE LEAF IS THE PER-SWAP IDENTITY. With one pinned internal key, two swaps differ only by
    ///    their CLTV refund leaf — `<cltv> OP_CLTV OP_DROP <userRefund> OP_CHECKSIG`, exactly what
    ///    `quid-bridge/src/swap_in_onchain.rs::refund_leaf` builds. Same refund key AND same height
    ///    would collide to one address, so the caller must not reuse both.
    ///
    /// ⚠️ SPV INCLUSION IS **NOT** CHECKED HERE — the caller proves the tx is in a block. This
    ///    returns only "what this tx pays the derived address", so a green result on an unproven
    ///    transaction means nothing.
    function verifySwapInDeposit(
        bytes32 internalKey,
        Types.Terms calldata terms,
        bytes32 userRefund,
        uint32  cltvHeight,
        bytes calldata rawDepositTx
    ) external view returns (uint sats) {
        bytes32 q = swapInDepositKey(internalKey, terms, userRefund, cltvHeight);
        sats = sumOutputValuesToScript(rawDepositTx, abi.encodePacked(hex"5120", q));
        if (sats == 0) revert DepositNotPaid();
    }

    /// @notice (E159) The x-only deposit key a swap's BTC must be sent to. Exposed because BOTH
    ///         sides need it and neither should guess: the seller must know where to pay, and the
    ///         settle path must know what to look for. One derivation, one source of truth.
    function swapInDepositKey(
        bytes32 internalKey, Types.Terms calldata terms, bytes32 userRefund, uint32 cltvHeight
    ) public view returns (bytes32) {
        return taprootOutputKeyWithLeaf(
            internalKey, tapLeafHash(_cltvRefundLeaf(terms, userRefund, cltvHeight)));
    }

    /// @notice (§T2) The terms a deposit address commits to. ONE leaf, no `tapBranch`: the prefix
    ///         rides in front of the refund script rather than adding a second branch, so the
    ///         control path and its hash shape are unchanged and only the leaf BYTES move.
    /// @dev    `sha256`, not `keccak256` — this value is pushed into a Bitcoin script and any
    ///         off-chain builder reproducing it works in Bitcoin's hash, so keccak here would make
    ///         the two derivations disagree while both looked correct.
    function termsCommitment(Types.Terms calldata terms) public pure returns (bytes32) {
        return sha256(abi.encode(
            terms.seller, terms.token, terms.pricePerBtc, uint256(terms.slippageBps)));
    }

    /// @notice (§T2) The settle floor, DERIVED from the committed rate and the PROVEN sats.
    /// @dev Byte-for-byte the arithmetic of `quid-hop::swap::swap_in_floor_usd`, which is the
    ///      quote the hop showed the seller: `sats/1e8 · pricePerBtc`, less `slippageBps`.
    ///      ⚠️ **DERIVED, NOT SUPPLIED — that is the security property.** The hop used to pass
    ///      `minDeliveredUsd` as calldata, so it could quote one floor to the seller and settle
    ///      against another. Now the address commits the RATE, the chain applies it to sats it has
    ///      SPV-proven, and there is no floor parameter left for anyone to substitute.
    function settleFloorUsd(Types.Terms calldata terms, uint sats) public pure returns (uint) {
        uint expected = (sats * terms.pricePerBtc) / 1e8;
        uint keep = terms.slippageBps >= 10_000 ? 0 : 10_000 - terms.slippageBps;
        return (expected * keep) / 10_000;
    }

    /// @dev `<cltvHeight> OP_CHECKLOCKTIMEVERIFY OP_DROP <userRefund> OP_CHECKSIG`, byte-identical
    ///      to the Rust builder. The height is a MINIMAL script number — Bitcoin's encoding, not a
    ///      fixed width — and a wrong encoding changes the leaf hash and therefore the ADDRESS,
    ///      silently deriving somewhere no deposit will ever land.
    function _cltvRefundLeaf(Types.Terms calldata terms, bytes32 userRefund, uint32 cltvHeight)
        private pure returns (bytes memory)
    {
        bytes memory n = _scriptNum(cltvHeight);
        return abi.encodePacked(
            // (§T2) TERMS PREFIX — `PUSH32 <termsCommitment> OP_DROP`. It is a pure commitment: the
            // script drops it immediately, so it changes NO spending condition and the refund path
            // below still works exactly as before. What it changes is the ADDRESS, which is the
            // point — settle under different terms and you derive a different address, so
            // `verifySwapInDeposit` finds no payment there and reverts. The binding is enforced by
            // Bitcoin's own hashing rather than by a check anyone could forget to call.
            bytes1(0x20), termsCommitment(terms), bytes1(0x75),
            bytes1(uint8(n.length)), n,     // PUSH<len> <height, little-endian, minimal>
            bytes1(0xb1),                   // OP_CHECKLOCKTIMEVERIFY
            bytes1(0x75),                   // OP_DROP
            bytes1(0x20), userRefund,       // PUSH32 <x-only refund key>
            bytes1(0xac)                    // OP_CHECKSIG
        );
    }

    /// @dev Bitcoin script number: little-endian, minimal, with a 0x00 pad when the high bit of the
    ///      top byte is set (otherwise it would read as negative).
    function _scriptNum(uint32 v) private pure returns (bytes memory out) {
        if (v == 0) return hex"00";
        uint8 n; uint32 t = v;
        while (t != 0) { n++; t >>= 8; }
        bool pad = (uint8(v >> (8 * (n - 1))) & 0x80) != 0;
        out = new bytes(pad ? n + 1 : n);
        for (uint8 i; i < n; ++i) out[i] = bytes1(uint8(v >> (8 * i)));
    }

    error ScriptTooLong();           // a script needs a multi-byte compact size (not supported)
    error PrevoutCountMismatch();    // one value + one scriptPubKey per input, exactly

    /// @dev Little-endian encoders. Bitcoin serialises every integer LE; the EVM is BE, and every
    ///      one of these that is written by hand is a place a sighash silently diverges.
    function _le4(uint32 v) private pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(v)), bytes1(uint8(v >> 8)),
                                bytes1(uint8(v >> 16)), bytes1(uint8(v >> 24)));
    }
    function _le8(uint64 v) private pure returns (bytes memory o) {
        o = new bytes(8);
        for (uint i; i < 8; ++i) o[i] = bytes1(uint8(v >> (8 * i)));
    }
    /// Compact size, single-byte form only. Reverts above 252 rather than emitting a wrong
    /// prefix — a mis-sized script hashes to a plausible-but-different sighash, which presents
    /// as "this valid signature does not verify".
    function _cs(uint len) private pure returns (bytes memory) {
        if (len >= 0xfd) revert ScriptTooLong();
        return abi.encodePacked(bytes1(uint8(len)));
    }

    /// @notice (E128) BIP-341 key-path sighash, `SIGHASH_DEFAULT`, no annex — the exact mode the
    ///         fleet signs a dead-man exit with (`quid-ln/src/deadman_exit.rs:24`: *"a single
    ///         64-byte Schnorr signature (SIGHASH_DEFAULT)"*, over `Prevouts::All`).
    ///
    /// @param prevValues   each input's prevout amount, in input order
    /// @param prevScripts  each input's prevout scriptPubKey, in input order
    ///
    /// @dev ⚠️ WHY THE CALLER SUPPLIES THE PREVOUTS AND WHY THAT IS SAFE: `Prevouts::All` commits
    ///      to every spent output's VALUE and SCRIPT, and those live in earlier transactions, not
    ///      in this one. A caller who supplies them wrongly does not forge anything — the sighash
    ///      simply differs and the signature fails to verify. Lying costs the liar.
    ///
    /// @dev ⚠️ THE COMMITMENT IS TO **EVERY** PREVOUT, NOT JUST THE SPENT ONE. That is precisely
    ///      what makes the freshness UTXO work: spending that one outpoint invalidates every
    ///      emitted exit at once (`deadman_exit.rs:67-71`). Hashing only input `inputIndex` would
    ///      produce a sighash that verifies here and is meaningless on Bitcoin.
    /// (E128) The five `SHA256` commitments a BIP-341 SigMsg is built from, in ONE memory struct.
    /// Held together because assembling them as locals blows the legacy stack, and the house fix
    /// is a struct field, never `via_ir`.
    struct SigParts {
        bytes32 prevouts; bytes32 amounts; bytes32 spks; bytes32 seqs; bytes32 outs;
        uint32 version; uint32 locktime;
    }

    /// @dev Own frame, for the same stack reason. Builds every `Prevouts::All` commitment.
    function _sigParts(
        bytes calldata rawTx, uint64[] memory prevValues, bytes[] memory prevScripts
    ) private pure returns (SigParts memory q) {
        (TxParser.Transaction memory t, ) = TxParser.parseTransaction(rawTx);
        if (prevValues.length != t.inputs.length || prevScripts.length != t.inputs.length)
            revert PrevoutCountMismatch();
        q.version = t.version;
        q.locktime = t.locktime;

        bytes memory prevouts; bytes memory amounts; bytes memory spks; bytes memory seqs;
        for (uint i; i < t.inputs.length; ++i) {
            // Back to INTERNAL byte order: TxParser hands `previousHash` back reversed (§E140-r2).
            prevouts = abi.encodePacked(prevouts,
                EndianConverter.bytes32LEtoBE(t.inputs[i].previousHash),
                _le4(t.inputs[i].previousIndex));
            amounts  = abi.encodePacked(amounts, _le8(prevValues[i]));
            spks     = abi.encodePacked(spks, _cs(prevScripts[i].length), prevScripts[i]);
            seqs     = abi.encodePacked(seqs, _le4(t.inputs[i].sequence));
        }
        bytes memory outs;
        for (uint i; i < t.outputs.length; ++i)
            outs = abi.encodePacked(outs, _le8(t.outputs[i].value),
                                    _cs(t.outputs[i].script.length), t.outputs[i].script);

        q.prevouts = sha256(prevouts); q.amounts = sha256(amounts);
        q.spks = sha256(spks); q.seqs = sha256(seqs); q.outs = sha256(outs);
    }

    /// @notice (E128) BIP-341 key-path sighash, `SIGHASH_DEFAULT`, no annex — the exact mode the
    ///         fleet signs a dead-man exit with (`quid-ln/src/deadman_exit.rs:24`: *"a single
    ///         64-byte Schnorr signature (SIGHASH_DEFAULT)"*, over `Prevouts::All`).
    ///
    /// @param prevValues   each input's prevout amount, in input order
    /// @param prevScripts  each input's prevout scriptPubKey, in input order
    ///
    /// @dev ⚠️ WHY THE CALLER SUPPLIES THE PREVOUTS, AND WHY THAT IS SAFE: `Prevouts::All` commits
    ///      to every spent output's VALUE and SCRIPT, which live in EARLIER transactions, not in
    ///      this one. A caller who supplies them wrongly forges nothing — the sighash simply
    ///      differs and the signature fails to verify. Lying costs the liar.
    ///
    /// @dev ⚠️ THE COMMITMENT IS TO **EVERY** PREVOUT, NOT ONLY THE SPENT ONE. That is exactly what
    ///      makes the freshness UTXO work: spending that one outpoint invalidates every emitted
    ///      exit at once (`deadman_exit.rs:67-71`). Hashing only `inputIndex` would produce a
    ///      sighash that verifies here and means nothing on Bitcoin.
    function taprootKeyPathSighash(
        bytes calldata rawTx,
        uint64[] calldata prevValues,
        bytes[] calldata prevScripts,
        uint32 inputIndex
    ) external pure returns (bytes32) {
        return _sighash(rawTx, prevValues, prevScripts, inputIndex);
    }

    /// @dev The same computation, callable INSIDE the library — a library cannot `this.`-call its
    ///      own external functions, and `verifyDeadManExit` must reuse this after pinning the
    ///      funding prevout.
    function _sighash(
        bytes calldata rawTx, uint64[] memory prevValues, bytes[] memory prevScripts,
        uint32 inputIndex
    ) private pure returns (bytes32) {
        SigParts memory q = _sigParts(rawTx, prevValues, prevScripts);
        return taggedHash("TapSighash", abi.encodePacked(
            bytes1(0x00),          // epoch
            bytes1(0x00),          // hash_type = SIGHASH_DEFAULT
            _le4(q.version), _le4(q.locktime),
            q.prevouts, q.amounts, q.spks, q.seqs, q.outs,
            bytes1(0x00),          // spend_type: key path, no annex
            _le4(inputIndex)
        ));
    }

    error ExitNotForThisChannel();   // no input spends the channel's funding outpoint
    error ExitLocktimeMismatch();    // nLockTime != the deadline the contract recorded

    /// @notice (E128) STRUCTURAL verification of a pre-signed dead-man exit. Returns the sats the
    ///         tx pays to the LP's committed payout script.
    ///
    /// 🔴 WHY THIS MATTERS: `emitDeadManExit` accepts `signedExitTx` and only EMITS it — nothing
    ///    parses or checks it. Since §E156 armed the exit at open, those bytes are the LP's ONLY
    ///    fleet-independent escape, and they are unverified. A hop can arm every channel with
    ///    garbage and the chain records it as protection.
    ///
    /// ⚠️ BYTE ORDER IS THE TRAP (§E140-r2). `TxParser` returns `previousHash` in DISPLAY (BE)
    ///    order, while our `fundingTxId` is stored in INTERNAL (LE) order — the raw serialized
    ///    bytes. Comparing them directly is always false, and fails SILENTLY: no revert, no
    ///    compile error, just a check that never matches. `bytes32LEtoBE` is a byte reversal and
    ///    therefore its own inverse, so applying it to TxParser's output returns internal order.
    ///
    /// ⚠️ WHAT THIS DOES **NOT** DO: it never checks the SIGNATURE. A structurally perfect exit
    ///    with invalid witness bytes passes here and is unbroadcastable in reality. Structure is
    ///    the cheap half; BIP-340 verification over the BIP-341 sighash is the other half and is
    ///    NOT here. Do not read a passing structural check as "the LP has a working escape".
    function _exitStructure(
        bytes calldata signedExitTx,
        bytes32 fundingTxId,
        uint32  fundingVout,
        bytes calldata lpPayoutScript,
        uint64  cltvDeadline
    ) internal pure returns (uint paidToLp) {
        (TxParser.Transaction memory t, ) = TxParser.parseTransaction(signedExitTx);

        // The exit must mature at exactly the deadline the contract itself recorded — the same
        // discriminator `recordDeadManExit` uses, checked now rather than at retirement.
        if (t.locktime != cltvDeadline) revert ExitLocktimeMismatch();

        // Scan ALL inputs: the exit carries the funding input plus (optionally) the freshness
        // input, and their order is not guaranteed.
        bool spends;
        for (uint i; i < t.inputs.length; ++i) {
            if (EndianConverter.bytes32LEtoBE(t.inputs[i].previousHash) == fundingTxId
                && t.inputs[i].previousIndex == fundingVout) { spends = true; break; }
        }
        if (!spends) revert ExitNotForThisChannel();

        bytes32 want = keccak256(lpPayoutScript);
        for (uint i; i < t.outputs.length; ++i)
            if (keccak256(t.outputs[i].script) == want) paidToLp += t.outputs[i].value;
    }


}
