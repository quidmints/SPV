// SPDX-License-Identifier: MIT
import {Types} from "./Types.sol";
pragma solidity ^0.8.13;

import {BitcoinTx} from "./BitcoinTx.sol";
// (E128/§E140-r) `BitcoinTx._assertLegacy` REJECTS any witness-carrying tx, so it cannot parse a
// fully-signed key-path taproot exit at all — not even its locktime. `TxParser` can, and exposes
// `inputs[i].witnesses`, which is where a key-path Schnorr signature lives. Used ONLY for that:
// §E140-r2 measured that its `previousHash` is byte-REVERSED relative to its own `calculateTxId`
// and to our `BitcoinTx`, so it is not a drop-in for outpoint logic.
import {TxParser} from "@solarity/solidity-lib/libs/bitcoin/TxParser.sol";
import {MuSig2Agg} from "./MuSig2Agg.sol";
import {EndianConverter} from "@solarity/solidity-lib/libs/utils/EndianConverter.sol";

/// @title  ExitLib — BIP-341 verification of PRE-SIGNED Bitcoin spends: the dead-man channel exit
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
library ExitLib {
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
    function _fundingInput(TxParser.Transaction memory t, bytes32 txid, uint32 vout)
        private pure returns (uint idx)
    {
        for (uint i; i < t.inputs.length; ++i)
            if (EndianConverter.bytes32LEtoBE(t.inputs[i].previousHash) == txid
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
        if (!MuSig2Agg.schnorrVerify(c.q, r, sig, m)) revert ExitSignatureInvalid();
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
        sats = BitcoinTx.sumOutputValuesToScript(rawDepositTx, abi.encodePacked(hex"5120", q));
        if (sats == 0) revert DepositNotPaid();
    }

    /// @notice (E159) The x-only deposit key a swap's BTC must be sent to. Exposed because BOTH
    ///         sides need it and neither should guess: the seller must know where to pay, and the
    ///         settle path must know what to look for. One derivation, one source of truth.
    function swapInDepositKey(
        bytes32 internalKey, Types.Terms calldata terms, bytes32 userRefund, uint32 cltvHeight
    ) public view returns (bytes32) {
        return MuSig2Agg.taprootOutputKeyWithLeaf(
            internalKey, MuSig2Agg.tapLeafHash(_cltvRefundLeaf(terms, userRefund, cltvHeight)));
    }

    /// @notice (§T2) The terms a deposit address commits to. ONE leaf, no `tapBranch`: the prefix
    ///         rides in front of the refund script rather than adding a second branch, so the
    ///         control path and its hash shape are unchanged and only the leaf BYTES move.
    /// @dev    `sha256`, not `keccak256` — this value is pushed into a Bitcoin script and any
    ///         off-chain builder reproducing it works in Bitcoin's hash, so keccak here would make
    ///         the two derivations disagree while both looked correct.
    function termsCommitment(Types.Terms calldata terms) public pure returns (bytes32) {
        return sha256(abi.encode(terms.seller, terms.token, terms.minDeliveredUsd));
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
        return MuSig2Agg.taggedHash("TapSighash", abi.encodePacked(
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
