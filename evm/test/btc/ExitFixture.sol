// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Types} from "../../src/imports/Types.sol";

interface BTCChannelsLike {
    function setBtcRecipient(bytes32, bytes calldata) external;
    function btcRecipientOf(address) external view returns (bytes32);
}

/// @notice (E128) Test-side helper for channels that must be opened with a GENUINELY SIGNED
///         dead-man exit.
///
///         WHY EVERY CHANNEL-OPENING TEST NEEDS THIS NOW: `_armDeadManExit` verifies the exit —
///         structure, BIP-341 sighash, BIP-340 signature — so a placeholder `hex"00"` no longer
///         opens a channel. That is the guarantee working: until E128 the LP's only
///         fleet-independent escape was whatever bytes the hop supplied, and a hop could arm
///         every channel with garbage while the chain recorded it as protection.
///
///         ⚠️ WHY FFI RATHER THAN A CHECKED-IN FIXTURE TABLE. The sighash commits to the funding
///         OUTPOINT and AMOUNT. A static table would force Python to replicate each test's
///         funding-tx construction byte-for-byte and stay in sync with it forever — the kind of
///         coupling that breaks silently, since a stale entry produces a signature that simply
///         does not verify. Asking Python to sign for the txid the TEST built removes it.
///
///         ⚠️ THE KEYS MUST BE OWNED. `_validCompressedPubkey("label")` yields a point with no
///         known discrete log, so no exit can ever be signed for the resulting `Q`. These come
///         from `channel_keypair`, whose secret we hold, and `aggregate_secret` handles the two
///         parity flips BIP-327/341 force.
abstract contract ExitFixture is Test {
    function _gen() private view returns (string memory) {
        return string.concat(vm.projectRoot(), "/test/btc/gen_deadman_exit_fixture.py");
    }

    /// The channel's per-channel funding pubkeys AND their MuSig2/taproot aggregate `Q`, all
    /// derived from secrets this repo owns.
    function ownedChannelKeys(string memory label)
        internal returns (bytes memory lp33, bytes memory hop33, bytes32 q)
    {
        string[] memory cmd = new string[](5);
        cmd[0] = "python3"; cmd[1] = _gen(); cmd[2] = "keys"; cmd[3] = label; cmd[4] = label;
        bytes memory out = vm.ffi(cmd);
        require(out.length == 98, "keys: expected 33+33+32 bytes");
        lp33 = new bytes(33); hop33 = new bytes(33);
        for (uint i; i < 33; ++i) { lp33[i] = out[i]; hop33[i] = out[33 + i]; }
        bytes32 qq;
        assembly { qq := mload(add(out, 98)) }   // 32 bytes ending at offset 98
        q = qq;
    }

    /// A signed exit spending `(txid, vout)` worth `sats`, paying `payoutScript`, maturing at
    /// `deadline`. `fee` is deducted, so the LP receives `sats - fee`.
    function signedExit(
        string memory label, bytes32 txid, uint32 vout, uint sats,
        bytes memory payoutScript, uint64 deadline, uint fee
    ) internal returns (bytes memory) {
        string[] memory cmd = new string[](11);
        cmd[0] = "python3"; cmd[1] = _gen(); cmd[2] = "sign";
        cmd[3] = label; cmd[4] = label;
        cmd[5] = vm.toString(txid);
        cmd[6] = vm.toString(uint(vout));
        cmd[7] = vm.toString(sats);
        cmd[8] = vm.toString(payoutScript);
        cmd[9] = vm.toString(uint(deadline));
        cmd[10] = vm.toString(fee);
        return vm.ffi(cmd);
    }

    /// (E128) Sign for a channel whose keys came from ANOTHER label convention — notably
    /// `open_channel_fixture.json`, which uses `quid-fixture-{lp,hop}-{seed}-{sats}`. Verified:
    /// those labels reproduce the fixture's recorded pubkeys exactly, so the aggregate secret is
    /// ours and its channel CAN be armed.
    function signedExitFull(
        string memory lpLabel, string memory hopLabel, bytes32 txid, uint32 vout, uint sats,
        bytes memory payoutScript, uint64 deadline, uint fee
    ) internal returns (bytes memory) {
        string[] memory cmd = new string[](11);
        cmd[0] = "python3"; cmd[1] = _gen(); cmd[2] = "signfull";
        cmd[3] = lpLabel; cmd[4] = hopLabel;
        cmd[5] = vm.toString(txid);
        cmd[6] = vm.toString(uint(vout));
        cmd[7] = vm.toString(sats);
        cmd[8] = vm.toString(payoutScript);
        cmd[9] = vm.toString(uint(deadline));
        cmd[10] = vm.toString(fee);
        return vm.ffi(cmd);
    }

    /// (E138) Set a swap user's payout key WITH its proof. One helper because the key and the
    /// proof must come from the SAME derivation — inlining both was what produced a nest of
    /// parentheses that compiled to the wrong shape.

    /// (E185) The swap-out destination script, read from the CONTRACT's own registration.
    ///
    /// `requestSwapOutOnchain` no longer takes a script — it derives one from
    /// `btcRecipientOf[msg.sender]`, which `setBtcRecipient` already proved on-curve (§E130)
    /// and under the caller's control (§E138). Tests must therefore ask the contract what the
    /// destination IS rather than inventing one, or the delivery-side hash match fails.
    /// ⚠️ No FFI here on purpose: this is a plain view read, so it is safe under a pending
    /// `vm.prank`/`vm.expectRevert`, unlike `payoutKeyOnly`.
    function _swapperScript(address ch_, address who) internal view returns (bytes memory) {
        return abi.encodePacked(hex"5120", BTCChannelsLike(ch_).btcRecipientOf(who));
    }

    /// (E138) Derive the payout key AND its proof-of-possession — every FFI this path needs, and
    /// nothing that touches sender state. Split out because a cheatcode call CONSUMES a pending
    /// `prank`/`expectRevert`, so the arming must happen strictly after the last shell-out.
    function _recipientArgs(address ch_, bytes memory seed, address who)
        internal returns (bytes32 k, bytes memory pop)
    {
        _btcChannels = ch_;   // the PoP digest binds it; must be set before `_popFor`
        k = payoutKeyOnly(seed);
        pop = _popFor(k, who);
    }

    /// ⚠️ THIS HELPER PRANKS ITSELF — CALLERS MUST NOT WRAP IT IN ONE. Every call site used to read
    /// `vm.prank(who); _setRecipient(ch, seed, msg.sender)`, which was wrong twice over once E138
    /// added an FFI here: the shell-out ate the prank, so `setBtcRecipient` arrived from the TEST
    /// CONTRACT, and `msg.sender` inside a test function is the runner's default sender rather than
    /// the pranked actor — so the proof-of-possession was bound to a third address again. Taking
    /// the actor as a parameter and pranking after the last FFI makes both unrepresentable.
    function _setRecipient(address ch_, bytes memory seed, address who) internal {
        (bytes32 k, bytes memory pop) = _recipientArgs(ch_, seed, who);
        vm.prank(who);
        BTCChannelsLike(ch_).setBtcRecipient(k, pop);
    }

    /// (E138/E157) The whole `OpenAuth`, in ONE frame. Four call sites were building this literal
    /// inline with a nested `_popFor(...)`, which pushed two of them over the legacy stack — and
    /// four copies of the same three fields is exactly the duplication that drifts.
    function mkAuth(address lpEth, bytes32 payout, bytes memory lpSig)
        internal returns (Types.OpenAuth memory)
    {
        return Types.OpenAuth({
            lpEth: lpEth, btcRecipient: payout, lpSig: lpSig,
            btcRecipientPoP: _popFor(payout, lpEth)});
    }

    /// (E138) The proof-of-possession for a payout key ALREADY derived by `payoutKeyOnly`.
    /// Re-derives from the same key so open and close cannot drift: the label is recovered by
    /// asking the generator for the key whose PoP this is, then asserting it matches.
    function _popFor(bytes32 payoutKey, address lpEth) internal returns (bytes memory pop) {
        bytes32 k;
        (k, pop) = ownedPayout(_labelOfPayout[payoutKey], _popDigest(lpEth));
        require(k == payoutKey, "E138: PoP does not match the derived payout key");
    }

    /// The contract's PoP digest, mirrored so tests sign exactly what it checks.
    function _popDigest(address lpEth) internal view returns (bytes32) {
        return sha256(abi.encode(
            keccak256("BTCChannels.btcRecipient.pop.v1"), block.chainid, _btcChannels, lpEth));
    }

    /// Label used to derive each payout key, so its PoP can be produced later.
    mapping(bytes32 => string) internal _labelOfPayout;
    address internal _btcChannels;   // set by the test before opening

    /// (E138) The OWNED payout key for an arbitrary seed, WITHOUT a proof — for the many sites
    /// that only need to rebuild the expected payout script (close/splice assertions). Open and
    /// close MUST agree, so both route through this one derivation: the label is `keccak256` of
    /// the seed, so any call with the same seed yields the same key.
    function payoutKeyOnly(bytes memory seed) internal returns (bytes32 k) {
        return payoutKeyForLabel(vm.toString(keccak256(seed)));
    }

    /// (E138) The same thing for a key whose label is FIXED because something outside Solidity
    /// also derives it — the regtest fixture's splice payout is baked into
    /// `gen_open_channel_fixture.py`, so the label is the contract between the two generators and
    /// cannot be a hash of an arbitrary seed.
    function payoutKeyForLabel(string memory label) internal returns (bytes32 k) {
        (k, ) = ownedPayout(label, bytes32(0));
        _labelOfPayout[k] = label;      // remembered so `_popFor` can re-derive
    }

    /// (E138) The same key PLUS its proof-of-possession for `lpEth` — needed at open.
    function payoutWithPoP(bytes memory seed, bytes32 popDigest)
        internal returns (bytes32 k, bytes memory pop)
    {
        return ownedPayout(vm.toString(keccak256(seed)), popDigest);
    }

    /// (E138) An OWNED payout key and its proof-of-possession for `lpEth`.
    ///
    /// ⚠️ WHY TESTS CANNOT KEEP USING `_validXOnly(...)`: those are valid curve points with NO
    /// known secret, so possession can never be proven for them. `btcRecipientOf` is pinned by
    /// close, splice-out AND the dead-man exit, so a key nobody controls takes every escape route
    /// at once — which is exactly what E138 makes unrepresentable.
    function ownedPayout(string memory label, bytes32 popDigest)
        internal returns (bytes32 xOnly, bytes memory pop)
    {
        string[] memory cmd = new string[](5);
        cmd[0] = "python3"; cmd[1] = _gen(); cmd[2] = "payoutpop";
        cmd[3] = label; cmd[4] = vm.toString(popDigest);
        bytes memory out = vm.ffi(cmd);
        require(out.length == 96, "payoutpop: expected 32 + 64 bytes");
        assembly { xOnly := mload(add(out, 32)) }
        pop = new bytes(64);
        for (uint i; i < 64; ++i) pop[i] = out[32 + i];
    }

    /// (E165) Wrap one already-built rung as a ladder. Kept separate from `armingSet` because
    /// several helpers build their arming from context the fixture base cannot see.
    function _ladder(Types.ExitArming memory one)
        internal pure returns (Types.ExitArming[] memory set)
    {
        set = new Types.ExitArming[](1);
        set[0] = one;
    }

    /// (E165) `openChannel` takes a LADDER now — the LP pre-signs every shape it will ever need in
    /// ONE act, then goes offline. Most tests only need a single rung, so this wraps one.
    function armingSet(
        string memory label, bytes32 txid, uint32 vout, uint sats,
        bytes memory payoutScript, uint64 deadline, uint fee
    ) internal returns (Types.ExitArming[] memory set) {
        set = new Types.ExitArming[](1);
        set[0] = armingFor(label, txid, vout, sats, payoutScript, deadline, fee);
    }

    /// The whole arming struct, ready to hand to `openChannel` / `emitDeadManExit`.
    ///
    /// ⚠️ `checkpointSats` IS 0, DELIBERATELY, AND IT IS NOT THE SAME AS `sats`. The checkpoint is
    /// the balance the fleet ATTESTS, and `recordClose`'s stale-close guard is SKIPPED while it is
    /// zero (`ckpt != 0`). Setting it to the funded amount here — which is what the LP's balance
    /// genuinely is at open — made every test that closes for LESS than it funded trip `StaleClose`,
    /// because nothing in a test refreshes the checkpoint the way the production heartbeat does.
    /// Tests that WANT the guard exercised set it explicitly; that is what `armingWithCheckpoint`
    /// is for, and it keeps the guard's coverage deliberate rather than incidental.
    function armingFor(
        string memory label, bytes32 txid, uint32 vout, uint sats,
        bytes memory payoutScript, uint64 deadline, uint fee
    ) internal returns (Types.ExitArming memory) {
        return armingWithCheckpoint(label, txid, vout, sats, payoutScript, deadline, fee, 0);
    }

    function armingWithCheckpoint(
        string memory label, bytes32 txid, uint32 vout, uint sats,
        bytes memory payoutScript, uint64 deadline, uint fee, uint checkpointSats
    ) internal returns (Types.ExitArming memory) {
        return Types.ExitArming({
            prevValues:   new uint64[](1),   // overwritten by the contract with what it knows
            prevScripts:  new bytes[](1),
            cltvDeadline: deadline,
            checkpointSats: checkpointSats,
            signedExitTx: signedExit(label, txid, vout, sats, payoutScript, deadline, fee)
        });
    }
}
