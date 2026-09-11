// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./Types.sol";
import {TxParser} from "@solarity/solidity-lib/libs/bitcoin/TxParser.sol";
import {EndianConverter} from "@solarity/solidity-lib/libs/utils/EndianConverter.sol";

import {EC256} from "@solarity/solidity-lib/libs/crypto/EC256.sol";
import {Math} from "@openzeppelin-submodule/utils/math/Math.sol";

library BitcoinTx {
    error InputOutOfRange();
    error TruncatedTx();
    error OutputNotFound();

    function txid(bytes calldata rawLegacy) public pure returns (bytes32) {
        return sha256(abi.encodePacked(sha256(rawLegacy)));
    }

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

    function _readLE(bytes calldata raw, uint offset, uint len)
        private pure returns (uint v)
    {
        for (uint i = 0; i < len; i++) {
            v |= uint(uint8(raw[offset + i])) << (8 * i);
        }
    }

    function _assertLegacy(bytes calldata raw) private pure {
        if (raw.length < 5 || raw[4] == 0x00) revert TruncatedTx();
    }

    function inputCount(bytes calldata raw) public pure returns (uint count) {
        _assertLegacy(raw);
        (count, ) = readVarInt(raw, 4);
    }

    function extractInputPrevOutpoint(bytes calldata raw, uint inputIndex)
        public pure returns (bytes32 hash, uint32 vout)
    {
        _assertLegacy(raw);
        uint offset = 4;
        (uint nIn, uint consumed) = readVarInt(raw, offset);
        if (inputIndex >= nIn) revert InputOutOfRange();
        offset += consumed;

        for (uint i = 0; i < inputIndex; i++) {
            offset += 32 + 4;
            (uint sigLen, uint sigLenBytes) = readVarInt(raw, offset);
            offset += sigLenBytes + sigLen + 4;
        }

        if (offset + 36 > raw.length) revert TruncatedTx();
        assembly {
            hash := calldataload(add(raw.offset, offset))
        }
        vout = uint32(_readLE(raw, offset + 32, 4));
    }

    function extractLocktime(bytes calldata raw) public pure returns (uint32 locktime) {
        if (raw.length < 4) revert TruncatedTx();
        locktime = uint32(_readLE(raw, raw.length - 4, 4));
    }

    function extractInput0Sequence(bytes calldata raw) public pure returns (uint32 seq) {
        _assertLegacy(raw);
        uint offset = 4;
        (uint nIn, uint consumed) = readVarInt(raw, offset);
        if (nIn == 0) revert TruncatedTx();
        offset += consumed;
        offset += 36;
        (uint sigLen, uint sigLenBytes) = readVarInt(raw, offset);
        offset += sigLenBytes + sigLen;
        if (offset + 4 > raw.length) revert TruncatedTx();
        seq = uint32(_readLE(raw, offset, 4));
    }

    function isCommitmentTx(bytes calldata raw) public pure returns (bool) {
        return (extractLocktime(raw) >> 24) == 0x20
            && (extractInput0Sequence(raw) >> 24) == 0x80;
    }

    uint8 private constant _SUM_TO      = 0;
    uint8 private constant _FIRST_TO    = 1;
    uint8 private constant _SUM_FOREIGN = 2;

    uint8 private constant _FIRST_TO_V1_OR_V2 = 3;

    function _scanOutputs(bytes calldata raw, bytes memory spk, uint8 mode, uint32 exceptVout)
        private pure returns (uint256 packed)
    {
        uint offset = _skipInputs(raw);
        (uint outputCount, uint consumed) = readVarInt(raw, offset);
        offset += consumed;

        if (mode == _SUM_FOREIGN && exceptVout >= outputCount) revert OutputNotFound();
        for (uint i = 0; i < outputCount; i++) {
            if (offset + 8 > raw.length) revert TruncatedTx();
            uint value = _readLE(raw, offset, 8);
            offset += 8;

            uint scriptLen;
            {   uint sLenBytes;
                (scriptLen, sLenBytes) = readVarInt(raw, offset);
                offset += sLenBytes;   }
            if (offset + scriptLen > raw.length) revert TruncatedTx();
            bool match_ = scriptLen == spk.length;
            if (match_) {
                for (uint j = 0; j < scriptLen; j++) {

                    if (raw[offset + j] != spk[j] &&
                        !(j == 0 && mode == _FIRST_TO_V1_OR_V2 && raw[offset] == 0x52))
                    { match_ = false; break; }
                }
            }
            if (mode == _SUM_FOREIGN) {
                if (i != exceptVout && !match_) packed += value;
            } else if (match_) {

                if (mode != _SUM_TO)
                    return (uint256(uint8(raw[offset])) << 96) | (uint256(i) << 64) | value;
                packed += value;
            }
            offset += scriptLen;
        }
        if (mode != _SUM_TO && mode != _SUM_FOREIGN) revert OutputNotFound();
    }

    function sumOutputValuesToScript(
        bytes calldata raw,
        bytes memory spk
    ) public pure returns (uint satoshis) {
        return _scanOutputs(raw, spk, _SUM_TO, 0);
    }

    function sumOutputValuesExcept(
        bytes calldata raw,
        uint32 exceptVout,
        bytes memory spk
    ) public pure returns (uint satoshis) {
        return _scanOutputs(raw, spk, _SUM_FOREIGN, exceptVout);
    }

    function findOutputByScript(
        bytes calldata raw,
        bytes memory expectedScriptPubKey
    ) public pure returns (uint32 vout, uint satoshis) {
        uint256 packed = _scanOutputs(raw, expectedScriptPubKey, _FIRST_TO, 0);
        return (uint32(packed >> 64), packed & type(uint64).max);
    }

    function _skipInputs(bytes calldata raw) private pure returns (uint offset) {
        _assertLegacy(raw);
        offset = 4;
        (uint nIn, uint consumed) = readVarInt(raw, offset);
        offset += consumed;
        for (uint i = 0; i < nIn; i++) {
            offset += 32 + 4;
            (uint sigLen, uint sigLenBytes) = readVarInt(raw, offset);
            offset += sigLenBytes + sigLen + 4;
        }
    }

    function buildTaprootScriptPubKey(bytes32 q) public pure returns (bytes memory) {

        return abi.encodePacked(hex"5120", q);
    }

    uint256 internal constant FIELD_SIZE =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    uint256 private constant SQRT_POWER =
        0x3FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBFFFFF0C;

    function evmAddressOfCompressed(bytes memory compressed) internal pure returns (address) {
        if (compressed.length != 33) return address(0);
        uint8 prefix = uint8(compressed[0]);
        if (prefix != 0x02 && prefix != 0x03) return address(0);
        uint256 x;
        assembly { x := mload(add(compressed, 33)) }
        if (x == 0 || x >= FIELD_SIZE) return address(0);
        uint256 ySq = addmod(mulmod(mulmod(x, x, FIELD_SIZE), x, FIELD_SIZE), 7, FIELD_SIZE);
        uint256 y = _modExp(ySq, SQRT_POWER);
        if (mulmod(y, y, FIELD_SIZE) != ySq) return address(0);

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

    function _modExp(uint256 base, uint256 exponent) private pure returns (uint256 result) {
        result = 1;
        base %= FIELD_SIZE;
        while (exponent != 0) {
            if (exponent & 1 == 1) result = mulmod(result, base, FIELD_SIZE);
            base = mulmod(base, base, FIELD_SIZE);
            exponent >>= 1;
        }
    }

    using EC256 for *;

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

    function taggedHash(string memory tag, bytes memory msg_) internal pure returns (bytes32) {
        bytes32 t_ = sha256(bytes(tag));
        return sha256(abi.encodePacked(t_, t_, msg_));
    }

    function decompress(bytes memory pk33) internal view returns (EC256.APoint memory pt) {
        require(pk33.length == 33, "BitcoinTx: pubkey must be 33 bytes");
        uint8 prefix = uint8(pk33[0]);
        require(prefix == 2 || prefix == 3, "BitcoinTx: bad SEC1 prefix");

        uint256 p = curve().p;
        uint256 x;
        assembly ("memory-safe") { x := mload(add(pk33, 33)) }
        require(x != 0 && x < p, "BitcoinTx: x out of field");

        uint256 ySq = addmod(mulmod(mulmod(x, x, p), x, p), 7, p);
        uint256 y = Math.modExp(ySq, (p + 1) >> 2, p);
        require(mulmod(y, y, p) == ySq, "BitcoinTx: x is not on the curve");

        require(y != 0, "BitcoinTx: degenerate point");

        if ((y & 1) != (prefix & 1)) y = p - y;
        pt = EC256.APoint({x: x, y: y});
    }

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

    function isTwoOfTwoOutputKey(
        bytes memory pkA33,
        bytes memory pkB33,
        bytes32 qXOnly
    ) public view returns (bool) {
        return computeOutputKey(pkA33, pkB33) == qXOnly;
    }

    function computeOutputKey(
        bytes memory pkA33,
        bytes memory pkB33
    ) public view returns (bytes32) {

        require(pkA33.length == 33 && pkB33.length == 33, "BitcoinTx: pubkey must be 33 bytes");

        AggVars memory v;
        v.ec = curve();

        (v.p1, v.p2) = _lessThan(pkA33, pkB33) ? (pkA33, pkB33) : (pkB33, pkA33);

        v.a1 = uint256(taggedHash(
            "KeyAgg coefficient",
            abi.encodePacked(taggedHash("KeyAgg list", abi.encodePacked(v.p1, v.p2)), v.p1)
        )) % v.ec.n;

        v.P1 = decompress(v.p1);
        v.P2 = decompress(v.p2);

        require(v.ec.isOnCurve(v.P1) && v.ec.isOnCurve(v.P2), "BitcoinTx: pubkey off curve");

        v.agg = v.ec.toAffine(
            v.ec.jMultShamir2(EC256.toJacobian(v.P1), EC256.toJacobian(v.P2), v.a1, 1)
        );

        if (v.agg.y % 2 != 0) v.agg.y = v.ec.p - v.agg.y;
        v.t = uint256(taggedHash("TapTweak", abi.encodePacked(bytes32(v.agg.x)))) % v.ec.n;

        return bytes32(v.ec.toAffine(
            v.ec.jAddPoint(EC256.toJacobian(v.agg), v.ec.jMultShamir(v.ec.jbasepoint(), v.t))
        ).x);
    }

    function tapLeafHash(bytes memory script) public pure returns (bytes32) {
        require(script.length < 0xfd, "BitcoinTx: leaf script too long");
        return taggedHash(
            "TapLeaf", abi.encodePacked(bytes1(0xc0), bytes1(uint8(script.length)), script));
    }

    function taprootOutputKeyWithLeaf(bytes32 internalX, bytes32 leafHash)
        public view returns (bytes32)
    {
        EC256.Curve memory ec = curve();

        EC256.APoint memory P = decompress(abi.encodePacked(bytes1(0x02), internalX));
        require(ec.isOnCurve(P), "BitcoinTx: internal key off curve");
        uint t = uint256(taggedHash(
            "TapTweak", abi.encodePacked(internalX, leafHash))) % ec.n;
        return bytes32(ec.toAffine(
            ec.jAddPoint(EC256.toJacobian(P), ec.jMultShamir(ec.jbasepoint(), t))
        ).x);
    }

    function schnorrVerify(bytes32 px, bytes32 rx, bytes32 sig, bytes32 m)
        public view returns (bool)
    {
        EC256.Curve memory ec = curve();
        if (uint256(rx) >= ec.p || uint256(sig) >= ec.n) return false;

        if (!isValidXOnlyKey(px)) return false;

        EC256.APoint memory P = decompress(abi.encodePacked(bytes1(0x02), px));

        uint e = uint256(taggedHash(
            "BIP0340/challenge", abi.encodePacked(rx, px, m))) % ec.n;

        EC256.APoint memory R = ec.toAffine(ec.jMultShamir2(
            ec.jbasepoint(), EC256.toJacobian(P), uint256(sig), e == 0 ? 0 : ec.n - e));

        if (R.x == 0 && R.y == 0) return false;
        if (R.y % 2 != 0) return false;
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

    function verifyExitStructure(
        bytes calldata signedExitTx, bytes32 fundingTxId, uint32 fundingVout,
        bytes calldata lpPayoutScript, uint64 cltvDeadline
    ) external pure returns (uint) {
        return _exitStructure(signedExitTx, fundingTxId, fundingVout, lpPayoutScript, cltvDeadline);
    }

    error ExitSignatureInvalid();
    error ExitWitnessMissing();

    struct ExitCheck {
        bytes32 fundingTxId;
        uint32  fundingVout;
        uint    fundingSats;
        bytes32 q;
        uint64  cltvDeadline;
    }

    function _fundingInput(TxParser.Transaction memory t, bytes32 fundingTxid, uint32 vout)
        private pure returns (uint idx)
    {
        for (uint i; i < t.inputs.length; ++i)
            if (EndianConverter.bytes32LEtoBE(t.inputs[i].previousHash) == fundingTxid
                && t.inputs[i].previousIndex == vout) return i;
        revert ExitNotForThisChannel();
    }

    function _keyPathSig(TxParser.Transaction memory t, uint idx)
        private pure returns (bytes32 r, bytes32 sig)
    {
        if (t.inputs[idx].witnesses.length != 1 || t.inputs[idx].witnesses[0].length != 64)
            revert ExitWitnessMissing();
        bytes memory w = t.inputs[idx].witnesses[0];
        assembly { r := mload(add(w, 32)) sig := mload(add(w, 64)) }
    }

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

    function _verifyExitSignature(
        bytes calldata signedExitTx,
        ExitCheck calldata c,
        uint64[] memory prevValues,
        bytes[] memory prevScripts
    ) private view {
        (TxParser.Transaction memory t, ) = TxParser.parseTransaction(signedExitTx);
        uint idx = _fundingInput(t, c.fundingTxId, c.fundingVout);

        prevValues[idx]  = uint64(c.fundingSats);

        prevScripts[idx] = abi.encodePacked(hex"5120", c.q);
        (bytes32 r, bytes32 sig) = _keyPathSig(t, idx);
        bytes32 m = _sighash(signedExitTx, prevValues, prevScripts, uint32(idx));
        if (!schnorrVerify(c.q, r, sig, m)) revert ExitSignatureInvalid();
    }

    error DepositNotPaid();

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

    function swapInDepositKey(
        bytes32 internalKey, Types.Terms calldata terms, bytes32 userRefund, uint32 cltvHeight
    ) public view returns (bytes32) {
        return taprootOutputKeyWithLeaf(
            internalKey, tapLeafHash(_cltvRefundLeaf(terms, userRefund, cltvHeight)));
    }

    function termsCommitment(Types.Terms calldata terms) public pure returns (bytes32) {
        return sha256(abi.encode(
            terms.seller, terms.token, terms.pricePerBtc, uint256(terms.slippageBps)));
    }

    function settleFloorUsd(Types.Terms calldata terms, uint sats) public pure returns (uint) {
        uint expected = (sats * terms.pricePerBtc) / 1e8;
        uint keep = terms.slippageBps >= 10_000 ? 0 : 10_000 - terms.slippageBps;
        return (expected * keep) / 10_000;
    }

    function _cltvRefundLeaf(Types.Terms calldata terms, bytes32 userRefund, uint32 cltvHeight)
        private pure returns (bytes memory)
    {
        bytes memory n = _scriptNum(cltvHeight);
        return abi.encodePacked(

            bytes1(0x20), termsCommitment(terms), bytes1(0x75),
            bytes1(uint8(n.length)), n,
            bytes1(0xb1),
            bytes1(0x75),
            bytes1(0x20), userRefund,
            bytes1(0xac)
        );
    }

    function _scriptNum(uint32 v) private pure returns (bytes memory out) {
        if (v == 0) return hex"00";
        uint8 n; uint32 t = v;
        while (t != 0) { n++; t >>= 8; }
        bool pad = (uint8(v >> (8 * (n - 1))) & 0x80) != 0;
        out = new bytes(pad ? n + 1 : n);
        for (uint8 i; i < n; ++i) out[i] = bytes1(uint8(v >> (8 * i)));
    }

    error ScriptTooLong();
    error PrevoutCountMismatch();

    function _le4(uint32 v) private pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(v)), bytes1(uint8(v >> 8)),
                                bytes1(uint8(v >> 16)), bytes1(uint8(v >> 24)));
    }
    function _le8(uint64 v) private pure returns (bytes memory o) {
        o = new bytes(8);
        for (uint i; i < 8; ++i) o[i] = bytes1(uint8(v >> (8 * i)));
    }

    function _cs(uint len) private pure returns (bytes memory) {
        if (len >= 0xfd) revert ScriptTooLong();
        return abi.encodePacked(bytes1(uint8(len)));
    }

    struct SigParts {
        bytes32 prevouts; bytes32 amounts; bytes32 spks; bytes32 seqs; bytes32 outs;
        uint32 version; uint32 locktime;
    }

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

    function taprootKeyPathSighash(
        bytes calldata rawTx,
        uint64[] calldata prevValues,
        bytes[] calldata prevScripts,
        uint32 inputIndex
    ) external pure returns (bytes32) {
        return _sighash(rawTx, prevValues, prevScripts, inputIndex);
    }

    function _sighash(
        bytes calldata rawTx, uint64[] memory prevValues, bytes[] memory prevScripts,
        uint32 inputIndex
    ) private pure returns (bytes32) {
        SigParts memory q = _sigParts(rawTx, prevValues, prevScripts);
        return taggedHash("TapSighash", abi.encodePacked(
            bytes1(0x00),
            bytes1(0x00),
            _le4(q.version), _le4(q.locktime),
            q.prevouts, q.amounts, q.spks, q.seqs, q.outs,
            bytes1(0x00),
            _le4(inputIndex)
        ));
    }

    error ExitNotForThisChannel();
    error ExitLocktimeMismatch();

    function _exitStructure(
        bytes calldata signedExitTx,
        bytes32 fundingTxId,
        uint32  fundingVout,
        bytes calldata lpPayoutScript,
        uint64  cltvDeadline
    ) internal pure returns (uint paidToLp) {
        (TxParser.Transaction memory t, ) = TxParser.parseTransaction(signedExitTx);

        if (t.locktime != cltvDeadline) revert ExitLocktimeMismatch();

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
