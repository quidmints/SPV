// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture, MockSPV} from "./Alles.t.sol";
import {IMorphoStaticTyping as IMorphoTest, MarketParams} from "../src/imports/Interfaces.sol";
import {BTCChannels} from "../src/BTCChannels.sol";
import {BtcLevManager} from "../src/BtcLevManager.sol";
import {ILevVenue, ILevPooled} from "../src/imports/Interfaces.sol";
// §LEV-DELEVER-CLUSTER (bottom of this file) — the ETH `LevManager` de-lever legs. `RealRateMorphoOracle`
// is a FILE-LEVEL contract in LevCascade.t.sol, so this import reuses the proven real-source weETH/USDC
// Morpho oracle WITHOUT inheriting `LevCascadeProbe` (which is also a suite of 18 fork tests).
import {LevManager} from "../src/LevManager.sol";
import {RealRateMorphoOracle} from "./LevCascade.t.sol";
import {Types, ChannelKeysMismatch} from "../src/imports/Types.sol";
import {MorphoEscrowVenue} from "../src/imports/LevVenueBase.sol";
import {AaveV3Venue} from "../src/imports/LevVenueBase.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {RealRateBtcMorphoOracle} from "../src/imports/LevBase.sol";

interface IERC20V {
    function transfer(address, uint) external returns (bool);
    function transferFrom(address, address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
    function approve(address, uint) external returns (bool);
    function decimals() external view returns (uint8);
}
interface IAuxTwapV { function assetPrice(address asset) external view returns (uint); }
interface IAaveV3AddrProviderT { function getPoolDataProvider() external view returns (address); }

/// @notice The BTC channel seam (splice / rekey / shutdown-key payout) plus the BTC leverage book,
///         fork-proved against the REAL Aave v3 {WBTC collateral, USDC debt} venue that `DeployL1_s`
///         wires — the only BTC lev venue there is.
///
///         🔴 BTC LEVERAGE COLLATERAL IS WBTC THE LP BRINGS, AND NOTHING ELSE (owner ruling,
///         2026-09-07). Channel BTC is never posted as collateral: `vBTC.balanceOf` is a PROJECTION of
///         `Vault.sharesOf` with no ledger behind it, and an escrow venue must physically custody what
///         it supplies. `BtcLevManager.init` vets every venue as WBTC-collateral
///         (`test_BtcLevVenueGate_InitRejectsNonWbtcCollateral` is the regression), so a position's
///         collateral both enters and leaves through the caller.
///
///         BTC-vs-ETH ADAPTATION: BTC leverage is KEEPER-DRIVEN ASYNC (BTC acquisition crosses Bitcoin
///         confirmation), so the valuation/protect proofs below open at ZERO leverage and source debt
///         through the venue's own `onlyManager` leg; `testReal_WbtcLev_FoldUp_Then_FlashDelever` is
///         the one that drives the synchronous fold-up / flash-de-lever end to end.
contract VBtcLevFeeLane is AllesFixture {

    /// §E329 — this file tests the BTC range, so its `CORE` is the BTC instance. See
    /// `BtcLpMintStress` for why reading the ETH one is silent rather than an error.
    function setUp() public override { super.setUp(); CORE = BTC.CORE(); }
    /// (E128) A FIXED dead-man deadline. `block.number + n` cannot be used: the BIP-341 sighash
    /// commits to nLockTime, so the exit must be signed for a height known before the tx is built.
    uint64 constant EXIT_DEADLINE = 900_000;

    // Fixed hop pubkey the BTCChannels deployment is bound to (33-byte compressed).
    bytes constant HOP_PUBKEY =
        hex"03a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0";

    address constant MORPHO       = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;

    // #106/#81/#74 — the LP brings EXTERNAL WBTC, and the keeper's atomic `rebalanceWbtc` folds up /
    // flash-de-levers the position on-chain.
    BtcLevManager     lmW;
    AaveV3Venue       wvenue;
    // AAVE v3 mainnet (deepest WBTC/USDC book) — the production BTC lev venue (DeployL1_s uses these too).
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_V3_ADDR = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    // ─────────────────────────── channel helpers (mirrors BtcLpMintStress) ───────────────────────────

    function _deployChannels() internal returns (BTCChannels ch) {
        ch = new BTCChannels(address(new MockSPV()), address(BTC), makeAddr("hop"), makeAddr("hop-fallback"), bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798)), address(0));
        _btcChannels = address(ch);   // (E138) PoP digest binds this address
        AUX.setBTCChannels(address(ch));
    }

    /// (E157) The open + its consent in their OWN FRAME — inlined twice it blew the legacy stack,
    /// and the house fix is a frame, not `via_ir`.
    /// One label per channel seed. Kept in its own frame so building it inline does not push the
    /// callers over the legacy stack.
    function _label(uint seed) private view returns (string memory) {
        return string.concat("levfee-", vm.toString(seed));
    }

    /// (E128/E157) Everything the submission needs, derived from `seed_` rather than passed:
    /// four callers were each holding `lpPk`, `lpEth` and `payout` live across the call, which is
    /// what pushed `_open` over the legacy stack. They all come from the same seed anyway.
    function _openWithConsent(
        BTCChannels ch_, Types.OpenParams memory p_, bytes memory fundingTx_, uint seed_
    ) private returns (bytes32 cid) {
        address lpEth_ = _lpEthOfLabel(_label(seed_));
        bytes32 payout_ = payoutKeyOnly(abi.encode(seed_));
        _btcChannels = address(ch_);
        Types.OpenAuth memory auth_ = Types.OpenAuth({ btcRecipient: payout_,
            btcRecipientPoP: _popFor(payout_, lpEth_, keccak256(p_.lpPubkey)),
            lpPaymentPoint: p_.lpPubkey});
        // (E128) A REAL signed ladder for the funding tx this call is about to prove. Built BEFORE
        // the prank so the FFI round-trips cannot consume it. (§SPRINT-B4) `armingSet` signs TWO
        // rungs at distinct deadlines — `_armLadder` rejects a single window.
        Types.ExitArming[] memory exits_ = armingSet(
            _label(seed_), sha256(abi.encodePacked(sha256(fundingTx_))), 0, p_.amountSats,
            abi.encodePacked(hex"5120", payout_), EXIT_DEADLINE, 1_000);
        vm.prank(makeAddr("hop"));
        cid = ch_.openChannel(p_, fundingTx_, new bytes32[](0), auth_, exits_);
    }

    function _signOpen(uint pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// (E128) Own frame: the funding tx + open params. Keeps `_open` under the legacy stack once
    /// the owned keys and the signed arming are also live in it.
    function _mkFundingLev(uint seed, uint amountSats, bytes memory lpPubkey, bytes memory hopKey_)
        private view returns (Types.OpenParams memory p, bytes memory fundingTx, bytes32 fundingTxId)
    {
        bytes memory p2wsh = buildTaprootFundingSpk(lpPubkey, hopKey_);
        fundingTx = abi.encodePacked(
            hex"02000000", hex"01",
            bytes32(0), hex"00000000", hex"00", hex"ffffffff",
            hex"01", _le(amountSats, 8), bytes1(uint8(p2wsh.length)), p2wsh,
            hex"00000000");
        fundingTxId = sha256(abi.encodePacked(sha256(fundingTx)));
        p = Types.OpenParams({
            fundingBlockHash:   bytes32(uint(0x100 + seed)),
            fundingBlockHeight: 800000,
            fundingTxIndex:     0,
            lpPubkey:           lpPubkey,
            hopPubkey:          hopKey_,
            amountSats:         amountSats,
            fundingTaproot:     _taprootQ(lpPubkey, hopKey_), lpIdentityPubkey: lpPubkey });
    }

    function _open(BTCChannels ch, uint seed, uint amountSats)
        internal
        returns (bytes32 channelId, bytes32 fundingTxId, address lpEth, bytes memory lpPubkey)
    {
        // (E128) OWNED keys — arming now VERIFIES, and an exit can only be signed for a `Q`
        // whose aggregate secret we hold.
        bytes memory hopKey_;
        (lpPubkey, hopKey_, ) = ownedChannelKeys(_label(seed));
        lpEth = _lpEthOfLabel(_label(seed));

        Types.OpenParams memory p;
        bytes memory fundingTx;
        (p, fundingTx, fundingTxId) = _mkFundingLev(seed, amountSats, lpPubkey, hopKey_);
        bytes32 payout = payoutKeyOnly(abi.encode(seed));
        // (E157) The LP signs once, for THIS channel, and the hop submits it with the open.
        channelId = _openWithConsent(ch, p, fundingTx, seed);
    }

    /// Splice-OUT (partial LP withdrawal) shrinking `channelId` to `newAmountSats`. exactUsd==0 path:
    /// all-native withdrawal (no proceeds), so it must clamp to the true channel funding.
    function _spliceOut(BTCChannels ch, bytes32 channelId, bytes32 fundingTxId, uint seed,
        bytes memory lpPubkey, uint newAmountSats) internal returns (bytes32 newTxId) {
        // (§SPLICE-ROTATES-BOTH-FUNDING-KEYS) This helper keeps the SAME pair deliberately: it is
        // the resize-only control. Rotation is exercised by the two rotation tests below, which a
        // pure-resize helper must not silently cover.
        ( , bytes memory hopKey_, ) = ownedChannelKeys(_label(seed));
        bytes memory spliceTx;
        {
            bytes memory p2wsh = buildTaprootFundingSpk(lpPubkey, hopKey_);
            spliceTx = abi.encodePacked(
                hex"02000000", hex"01",
                fundingTxId, hex"00000000", hex"00", hex"ffffffff",
                hex"01", _le(newAmountSats, 8), bytes1(uint8(p2wsh.length)), p2wsh,
                hex"00000000");
        }
        newTxId = sha256(abi.encodePacked(sha256(spliceTx)));
        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash:   bytes32(uint(0x5217CE + seed)),
            fundingBlockHeight: 800001,
            fundingTxIndex:     0,
            lpPubkey:           lpPubkey,
            hopPubkey:          hopKey_,
            amountSats:         newAmountSats,
            fundingTaproot:     _taprootQ(lpPubkey, hopKey_), lpIdentityPubkey: lpPubkey });
        // (§E233-ladder) THE SPLICE CARRIES ITS OWN FRESH LADDER, signed against the ROTATED outpoint
        // (`newTxId`:0) and the POST-shrink amount — the rungs armed at open spend the outpoint this
        // very tx consumes, so they are dead the moment it confirms. Built BEFORE the prank because
        // `armingSet` shells out over FFI and the round-trip consumes a one-shot prank.
        Types.ExitArming[] memory exits_ = armingSet(
            _label(seed), newTxId, 0, newAmountSats,
            abi.encodePacked(hex"5120", payoutKeyOnly(abi.encode(seed))),
            EXIT_DEADLINE + 1, 1_000);
        vm.prank(makeAddr("hop"));
        ch.splice(channelId, p, spliceTx, new bytes32[](0), exits_);
    }

    // ── Cross-side SEAM coverage: distinct funding vs shutdown/payout keys + a real
    //    LP-payout OUTPUT. The single-key, no-payout-output fixtures masked the whole
    //    withdrawal-guard path (the P2TR migration broke 0 tests precisely because of
    //    that gap). This exercises `_withdrawalPayout` for the first time, and pins the
    //    requirement the real Rust `initiate_splice_out` violates (it pays the FUNDING
    //    key; the guard demands `btcRecipientOf` = the SHUTDOWN key). See
    //    [[project-quid-seam-bugs-crossside]].
    function _p2tr(bytes32 xOnlyKey) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"5120", xOnlyKey);
    }

    function _openWithPayout(BTCChannels ch, uint seed, uint amountSats, bytes32 payoutKey)
        internal returns (bytes32 channelId, bytes32 fundingTxId, bytes memory lpPubkey)
    {
        // (E128) OWNED keys — arming now VERIFIES, and an exit can only be signed for a `Q`
        // whose aggregate secret we hold.
        bytes memory hopKey_;
        (lpPubkey, hopKey_, ) = ownedChannelKeys(_label(seed));
        address lpEth = _lpEthOfLabel(_label(seed));
        bytes memory spk = buildTaprootFundingSpk(lpPubkey, hopKey_);
        bytes memory fundingTx = abi.encodePacked(
            hex"02000000", hex"01", bytes32(0), hex"00000000", hex"00", hex"ffffffff",
            hex"01", _le(amountSats, 8), bytes1(uint8(spk.length)), spk, hex"00000000");
        fundingTxId = sha256(abi.encodePacked(sha256(fundingTx)));
        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash: bytes32(uint(0x100 + seed)), fundingBlockHeight: 800000,
            fundingTxIndex: 0, lpPubkey: lpPubkey, hopPubkey: hopKey_,
            amountSats: amountSats, fundingTaproot: _taprootQ(lpPubkey, hopKey_), lpIdentityPubkey: lpPubkey });
        // (E157) The open's own consent pins btcRecipientOf=payoutKey (the SHUTDOWN key) and names
        // the hop. btcRecipientOf is exactly what the shrink guard (_withdrawalPayout) enforces in
        // the seam test below — so signing the WRONG key here would surface there, not here.
        channelId = _openWithConsent(ch, p, fundingTx, seed);
    }

    // Build+sign a 2-output shrink splice (new funding + LP payout) WITHOUT submitting,
    // so a test can put `vm.expectRevert` immediately before the `splice()` external call
    // (else expectRevert is consumed by the `spliceDigest` view).
    /// (E162) Same rule as `_spliceOut`: a shrink is a splice, so it must carry the channel's OWN
    /// pinned pair. Re-derived from the seed rather than passed, to keep the signature stable.
    function _buildShrink(BTCChannels ch, bytes32 channelId, uint seed, bytes memory lpPubkey,
        uint newAmountSats, uint withdrawSats, bytes memory payoutScript, bytes32 fundingTxId)
        internal returns (Types.OpenParams memory p, bytes memory spliceTx)
    {
        ( , bytes memory hopKey_, ) = ownedChannelKeys(_label(seed));
        bytes memory fundingSpk = buildTaprootFundingSpk(lpPubkey, hopKey_);
        spliceTx = abi.encodePacked(
            hex"02000000", hex"01", fundingTxId, hex"00000000", hex"00", hex"ffffffff",
            hex"02",  // TWO outputs: the new (smaller) funding + the LP payout
            _le(newAmountSats, 8), bytes1(uint8(fundingSpk.length)), fundingSpk,
            _le(withdrawSats, 8), bytes1(uint8(payoutScript.length)), payoutScript,
            hex"00000000");
        p = Types.OpenParams({
            fundingBlockHash: bytes32(uint(0x5217CE + seed)), fundingBlockHeight: 800001,
            fundingTxIndex: 0, lpPubkey: lpPubkey, hopPubkey: hopKey_,
            amountSats: newAmountSats, fundingTaproot: _taprootQ(lpPubkey, hopKey_), lpIdentityPubkey: lpPubkey });
    }

    // Each case in its own frame (non-via-ir stack limit). `_buildShrink` makes no external
    // call, so `vm.expectRevert` binds cleanly to the `splice()` call below.
    function _shrinkExpectForeignRevert(BTCChannels ch, bytes32 cid, bytes32 ftx,
        bytes memory lpPubkey, bytes memory payoutScript) internal {
        (Types.OpenParams memory p, bytes memory tx_) =
            _buildShrink(ch, cid, 77, lpPubkey, 15e6, 5e6, payoutScript, ftx);
        vm.prank(makeAddr("hop"));
        vm.expectRevert(BTCChannels.ForeignSpliceOutput.selector);
        // (§E233-ladder) `stubLadder` — `_applySplice` rejects the foreign output before any arming runs.
        ch.splice(cid, p, tx_, new bytes32[](0), stubLadder());
    }

    function _shrinkExpectOk(BTCChannels ch, bytes32 cid, bytes32 ftx,
        bytes memory lpPubkey, bytes memory payoutScript) internal {
        (Types.OpenParams memory p, bytes memory tx_) =
            _buildShrink(ch, cid, 77, lpPubkey, 15e6, 5e6, payoutScript, ftx);
        // (§E233-ladder) A SUCCEEDING splice must carry a REAL ladder for the rotated outpoint — the
        // shrink tx's funding output is vout 0 (the LP payout is vout 1), and the post-shrink
        // amount is what the rungs must attest. Built before the prank: `armingSet` goes out over
        // FFI and the round-trip would consume a one-shot prank.
        Types.ExitArming[] memory exits_ = armingSet(
            _label(77), sha256(abi.encodePacked(sha256(tx_))), 0, 15e6,
            payoutScript, EXIT_DEADLINE + 1, 1_000);
        vm.prank(makeAddr("hop"));
        ch.splice(cid, p, tx_, new bytes32[](0), exits_);
    }

    /// (§SPLICE-ROTATES-BOTH-FUNDING-KEYS) WHAT REFUSES A ROTATION INTO A PAIR THE HOP CHOSE.
    ///
    /// ⛔ THIS TEST USED TO BE `test_spliceCannotRekeyTheChannel` AND ASSERTED
    /// `ChannelKeysMismatch` FROM `_requireChannelKeys`. **That check is deleted, and it was never
    /// what made a rotation safe.** It compared PUBLIC values for equality; and it was
    /// unsatisfiable against our own LN stack, which rotates BOTH funding pubkeys on every splice
    /// (`new_funding_pubkey(prev_funding_txid)`), so no real splice could ever have passed it.
    ///
    /// 🔑 THE GATE THAT ACTUALLY HOLDS IS THE CHAIN: `_verifySplice` → `_verifyTxSpendsChannel`
    /// SPV-proves the transaction SPENDS this channel's funding outpoint, and that outpoint is a
    /// key-path taproot 2-of-2 whose spend REQUIRES THE LP'S MuSig2 PARTIAL — which, under BIP-341
    /// `Prevouts::All`, commits to the outputs and therefore to the exact new pair. A hop holding
    /// one half cannot produce such a transaction for ANY pair. **So the assertion is that a
    /// splice not spending this channel's outpoint is refused**, which is the on-chain fact the
    /// deleted equality check was standing in front of.
    function test_spliceMustSpendThisChannelsFundingOutpoint() public {
        BTCChannels ch = _deployChannels();
        (bytes32 cid,,, bytes memory lpPubkey) = _open(ch, 91, 2e6);

        ( , bytes memory hopKey_, ) = ownedChannelKeys(_label(91));
        // A well-formed splice paying to a valid `Q` for THIS channel's own pair — every check
        // except the one under test passes, so the rejection cannot be incidental.
        bytes32 foreignFunding = keccak256("an outpoint this channel never had");
        bytes memory tx_ = _buildRekey(foreignFunding, lpPubkey, hopKey_, 3e6);
        Types.OpenParams memory p = _rekeyParams(lpPubkey, hopKey_, 3e6);

        vm.prank(makeAddr("hop"));
        vm.expectRevert(BTCChannels.WrongPrevOutpoint.selector);
        ch.splice(cid, p, tx_, new bytes32[](0), stubLadder());
    }


    // ─────────────────────────────────────────────────────────────────────────────
    //  (§E182) REKEY — what `splice` is forbidden to do, done deliberately and gated.
    //
    //  The two tests above pin that a splice may NOT rotate keys. These pin the entrypoint that
    //  MAY, and the gate it has to pass. `_requireChannelKeys` states the danger in its own words:
    //  *"a compromised hop splices to keys it solely controls and CUTS THE LP OUT of its own
    //  2-of-2."* The rotation is safe because the LP HALF IS IMMUTABLE and the LP CO-SIGNS.
    // ─────────────────────────────────────────────────────────────────────────────

    /// Build the rotation splice: same size, same LP key, a DIFFERENT hop key, paying to the new
    /// aggregate `Q`. Same shape as `_spliceOut`, except the hop half deliberately moves.
    function _buildRekey(bytes32 ftx, bytes memory lpPubkey, bytes memory newHopKey, uint sats)
        internal view returns (bytes memory spliceTx)
    {
        bytes memory spk = buildTaprootFundingSpk(lpPubkey, newHopKey);
        spliceTx = abi.encodePacked(
            hex"02000000", hex"01", ftx, hex"00000000", hex"00", hex"ffffffff",
            hex"01", _le(sats, 8), bytes1(uint8(spk.length)), spk, hex"00000000");
    }

    function _rekeyParams(bytes memory lpPubkey, bytes memory newHopKey, uint sats)
        internal view returns (Types.OpenParams memory)
    {
        return Types.OpenParams({
            fundingBlockHash: bytes32(uint(0x5217CE)), fundingBlockHeight: 800001,
            fundingTxIndex: 0, lpPubkey: lpPubkey, hopPubkey: newHopKey,
            amountSats: sats, fundingTaproot: _taprootQ(lpPubkey, newHopKey), lpIdentityPubkey: lpPubkey });
    }

    /// ⚠️ ONE STRUCT, BECAUSE THESE TESTS OVERFLOW THE LEGACY STACK OTHERWISE. A rotation case
    /// carries a channel id, a funding txid, THREE pubkeys, an amount and a signing key; held as
    /// separate locals that is past the limit and the first version failed to compile with *"Stack
    /// too deep"*. One memory pointer costs less stack than the fields it carries — the same fix
    /// the contract itself uses instead of turning on `via_ir`.
    struct RekeyCase {
        bytes32 cid;
        bytes32 ftx;
        bytes   lpPubkey;   // the LP half — moved ONLY by the test that must be rejected for it
        bytes   oldHop;     // the hop key pinned at open
        bytes   newHop;     // the hop key being rotated in
        uint    sats;
        // (§E233-ladder) The fresh ladder's provenance. A rekey rotates the outpoint AND the aggregate, so
        // its rungs must be signed under the MIXED pair (this channel's LP half, the INCOMING hop
        // half) — which is what `signedExitFull` takes two labels for. `lpLabel` is the seed label
        // the channel was opened with; `hopLabel` is the label the new hop key came from.
        string  lpLabel;
        string  hopLabel;
        bytes   payoutScript;   // the LP's committed P2TR the exit must pay
    }

    /// Build + sign + submit a rotation, in its own frame.
    ///
    /// ⚠️ `expectRevert_` is set HERE rather than by the caller, and that is deliberate: the tx and
    /// the signature are built FIRST, so `vm.expectRevert` lands immediately before the `rekey`
    /// call and cannot be swallowed by an FFI or cheatcode round-trip on the way. This fixture
    /// already records that failure mode a few tests above — *"else expectRevert is consumed by
    /// the `spliceDigest` view"* — so the shape is copied rather than rediscovered.
    function _submitRekey(BTCChannels ch, RekeyCase memory c, bool expectRevert_) internal {
        bytes memory tx_ = _buildRekey(c.ftx, c.lpPubkey, c.newHop, c.sats);
        Types.OpenParams memory p = _rekeyParams(c.lpPubkey, c.newHop, c.sats);
        // (§E233-ladder) THE LADDER IS CHOSEN BY WHETHER ARMING IS REACHABLE, and that is a statement
        // about the contract, not a convenience. All three rejection cases are refused by
        // `_authorizeRekey`/`_applySplice`, i.e. strictly upstream of `_armLadder`, so a
        // real FFI-signed rung would be paid for and never verified. `stubLadder` is unsignable, so
        // if that order ever changes the test fails on `BufferOverflow` instead of passing for a new
        // reason.
        Types.ExitArming[] memory exits_ = expectRevert_
            ? stubLadder()
            // The positive case: signed under the MIXED pair — this channel's LP half and the
            // INCOMING hop half — against the rotated outpoint (`tx_`'s vout 0) and the new amount.
            // (§SPRINT-B4) Two rungs at distinct deadlines, each independently signed.
            : _rekeyLadder(c, tx_);
        if (expectRevert_) vm.expectRevert();
        vm.prank(makeAddr("hop"));
        ch.splice(c.cid, p, tx_, new bytes32[](0), exits_);
    }

    /// (§SPLICE-ROTATES-BOTH-FUNDING-KEYS) THE PIN MOVED — asserted through a path that still
    /// CHECKS the pin, which `splice` deliberately no longer does.
    ///
    /// ⛔ BOTH ROTATION TESTS USED TO ASSERT THIS BY RE-SUBMITTING THE STALE PAIR TO `splice` AND
    /// EXPECTING `ChannelKeysMismatch`. **That probe died with the fold** and the tests failed with
    /// `TruncatedTx()` — `splice` dropped `_requireChannelKeys`, so the stale pair now sails past
    /// the pin and dies parsing the `hex"00"` placeholder instead. The PROPERTY was still true; the
    /// instrument was measuring nothing. ⚠️ Note the failure mode: had the placeholder been a
    /// well-formed transaction, the call could have SUCCEEDED and the test would have reported a
    /// missing revert — i.e. it would have accused the contract of not re-pinning.
    ///
    /// ✅ `emitDeadManExit` is the right probe and a STRICTLY BETTER one: `_requireChannelKeys` is
    /// its FIRST gate after `_whenOpen`/`_onlyHop` (`:1477`), so a stale pair is refused on the pin
    /// with no transaction bytes to parse — and it is one of the paths §E153's *unretirable
    /// forever* regression actually broke, so this asserts the property where it MATTERS rather
    /// than where it was convenient to observe.
    function _assertPinMovedTo(BTCChannels ch, bytes32 cid, bytes memory staleLp, bytes memory staleHop)
        private
    {
        // Built BEFORE `expectRevert`: `_rekeyParams` does an FFI round-trip (`_taprootQ`), which
        // would CONSUME the expectation if it ran between the cheatcode and the call. This fixture
        // has been bitten by that before, and the symptom reads exactly like a missing re-pin.
        Types.OpenParams memory stalePair = _rekeyParams(staleLp, staleHop, 1e6);
        Types.ExitArming memory stub = stubLadder()[0];
        vm.prank(makeAddr("hop"));
        vm.expectRevert(ChannelKeysMismatch.selector);
        ch.emitDeadManExit(cid, stalePair, stub);
    }

    /// (§SPRINT-B4) The rekey's 2-rung ladder in its OWN frame (legacy stack, no `via_ir`):
    /// two mixed-pair `signedExitFull` signatures over the rotated outpoint, one spacing apart.
    function _rekeyLadder(RekeyCase memory c, bytes memory tx_)
        private returns (Types.ExitArming[] memory)
    {
        bytes32 txid = sha256(abi.encodePacked(sha256(tx_)));
        return ladder2(
            signedExitFullArming(c.lpLabel, c.hopLabel, txid, 0, c.sats,
                c.payoutScript, EXIT_DEADLINE + 2, 1_000),
            signedExitFullArming(c.lpLabel, c.hopLabel, txid, 0, c.sats,
                c.payoutScript, EXIT_DEADLINE + 2 + LADDER_SPACING, 1_000));
    }

    /// 🔴 (§E233-ladder) THE DEFECT THIS EXISTS TO CATCH: a splice rotated the funding outpoint, every rung
    /// pre-signed at open became a spend of a SPENT output, and `exitArmedAt[channelId][deadline]`
    /// went on reading `true` for all of them. The flag an observer checks to decide whether an LP
    /// has a non-custodial escape was SILENTLY FALSE — and in the LP-hosted deployment, where
    /// `run_deadman_exit_heartbeat` does not run at all, the channel genuinely had no escape from
    /// the first splice onward, permanently. Splice is the only capacity mechanism there is.
    ///
    /// Three assertions, and the third is the one that distinguishes a fix from a mask:
    ///  1. the open-time deadline is armed for the channel's scope at open;
    ///  2. after the splice it is NOT — and the splice's OWN ladder is, so there is no block in
    ///     which the channel is escape-less (`splice` arms in the same transaction that rotates);
    ///  3. the old entry is still THERE under the OLD outpoint key. It was retired by being made
    ///     UNREACHABLE, not by a clearing loop over a mapping nobody can enumerate — which is why
    ///     the fix costs zero writes and cannot miss a rung.
    ///
    /// ⚠️ 2 IS ASSERTED VIA `armedNow`, WHICH HASHES THE CHANNEL'S CURRENT OUTPOINT. Reading the
    /// raw getter with `channelId` would return `false` for every input and the test would pass for
    /// the wrong reason — the same trap the rename to `exitArmedOnOutpoint` exists to make loud.
    function test_spliceRetiresTheOldLadderAndArmsTheNew() public {
        BTCChannels ch = _deployChannels();
        (bytes32 cid, bytes32 ftx,, bytes memory lpPubkey) = _open(ch, 88, 20e6);
        assertTrue(armedNow(address(ch), cid, EXIT_DEADLINE),
            "precondition: openChannel arms the ladder for the OPEN outpoint");

        _spliceOut(ch, cid, ftx, 88, lpPubkey, 15e6);

        assertFalse(armedNow(address(ch), cid, EXIT_DEADLINE),
            "a rotation RETIRES the rungs signed against the pre-splice outpoint");
        assertTrue(armedNow(address(ch), cid, EXIT_DEADLINE + 1),
            "the splice arms its own ladder, so the channel is never without an escape");
        assertTrue(ch.exitArmedOnOutpoint(keccak256(abi.encode(ftx, uint32(0))), EXIT_DEADLINE),
            "the old rung is unreachable, not deleted -- retirement costs zero writes");
    }

    /// ✅ THE POSITIVE CASE, and it asserts the thing §E153 got wrong rather than just "no revert".
    /// A rotation that forgets to re-pin `keysHash` leaves the channel UNRETIRABLE FOREVER: both
    /// retirement paths run `_requireChannelKeys`, so they would reject the very pair the funds now
    /// sit under. So the assertion is not that `rekey` returned — it is that the channel is still
    /// OPERABLE UNDER THE NEW PAIR afterwards, and no longer operable under the old one.
    function test_rekeyRotatesTheHopHalfAndRepinsKeysHash() public {
        BTCChannels ch = _deployChannels();
        RekeyCase memory c;
        (c.cid, c.ftx,, c.lpPubkey) = _open(ch, 93, 2e6);
        ( , c.oldHop, ) = ownedChannelKeys(_label(93));
        ( , c.newHop, ) = ownedChannelKeys(_label(94));
        c.sats = 2e6;
        // (§E233-ladder) The rotation must carry a ladder valid under the NEW aggregate, so the fixture
        // needs both halves' provenance and the payout the exit pays. Seed 93 opened the channel.
        // ⚠️ THE ROLE SUFFIX IS PART OF THE LABEL HERE. `signedExitFull` → the generator's
        // `signfull`, which calls `channel_keypair(label)` VERBATIM; `signedExit` → `sign`, which
        // appends `-lp`/`-hop` itself. Passing the bare base label derives two keys that are not
        // this channel's, and the failure is `ExitSignatureInvalid()` — a correct rejection of a
        // signature over the wrong `Q`, which reads exactly like a broken contract. Measured.
        c.lpLabel = string.concat(_label(93), "-lp");
        c.hopLabel = string.concat(_label(94), "-hop");
        c.payoutScript = abi.encodePacked(hex"5120", payoutKeyOnly(abi.encode(uint(93))));
        assertTrue(keccak256(c.newHop) != keccak256(c.oldHop), "hop half must actually move");

        _submitRekey(ch, c, false);

        _assertPinMovedTo(ch, c.cid, c.lpPubkey, c.oldHop);
    }

    /// (§SPLICE-ROTATES-BOTH-FUNDING-KEYS) ✅ THE LDK SHAPE: **BOTH HALVES ROTATE, AND THE
    /// CHANNEL ABSORBS IT.**
    ///
    /// ⛔ THIS TEST USED TO BE `test_rekeyRefusesToMoveTheLpHalf` AND ASSERTED THE OPPOSITE. The
    /// inversion is the whole point of the fix: LDK derives a fresh funding pubkey for EACH side on
    /// every splice — `send_splice_init` (`channel.rs:13021`) and the `splice_ack` handler
    /// (`:13137`) both call `ChannelSigner::new_funding_pubkey(prev_funding_txid)`, tweaking by
    /// `SHA256(prev_txid ‖ base_secret)`. **So a pin that forbade the LP half from moving forbade
    /// every splice our own stack produces**, and every gate it guarded — including both retirement
    /// paths — would have shut on any spliced channel (§E153's *unretirable forever*, reached
    /// through a different door).
    ///
    /// The safety that used to be attributed to the pin is unchanged and comes from the chain: this
    /// transaction spends the channel's 2-of-2, which no hop can do alone.
    /// ⇒ Asserts what §E153 got wrong — not that the call returned, but that the channel is
    /// OPERABLE UNDER THE NEW PAIR afterwards and no longer under the old one.
    function test_spliceAbsorbsAnLdkRotationOfBothHalves() public {
        BTCChannels ch = _deployChannels();
        RekeyCase memory c;
        bytes memory realLp;
        (c.cid, c.ftx,, realLp) = _open(ch, 95, 2e6);
        ( , c.oldHop, ) = ownedChannelKeys(_label(95));
        // BOTH halves move, to an OWNED pair — the ladder must verify under the new aggregate, so
        // the new LP half needs real key material, not just a well-formed pubkey.
        (c.lpPubkey, c.newHop, ) = ownedChannelKeys(_label(96));
        c.sats = 2e6;
        c.lpLabel = string.concat(_label(96), "-lp");
        c.hopLabel = string.concat(_label(96), "-hop");
        c.payoutScript = abi.encodePacked(hex"5120", payoutKeyOnly(abi.encode(uint(95))));
        assertTrue(keccak256(c.lpPubkey) != keccak256(realLp), "the LP half must actually move");
        assertTrue(keccak256(c.newHop) != keccak256(c.oldHop), "the hop half must actually move");

        _submitRekey(ch, c, false);

        _assertPinMovedTo(ch, c.cid, realLp, c.oldHop);
    }



    function test_Seam_WithdrawalPayout_MustMatchShutdownKey_NotFundingKey() public {
        BTCChannels ch = _deployChannels();
        bytes32 shutdownKey = payoutKeyOnly(abi.encode(uint(77))); // = btcRecipientOf
        (bytes32 cid, bytes32 ftx, bytes memory lpPubkey) = _openWithPayout(ch, 77, 20e6, shutdownKey);
        bytes32 fundingKey = keccak256(abi.encode("lp-funding-xonly", uint(77)));
        assertTrue(fundingKey != shutdownKey, "keys must be distinct to test the seam");
        // Pay the FUNDING key (what Rust initiate_splice_out builds) ≠ btcRecipientOf → rejected.
        _shrinkExpectForeignRevert(ch, cid, ftx, lpPubkey, _p2tr(fundingKey));
        // Pay btcRecipientOf (the shutdown key) → accepted.
        _shrinkExpectOk(ch, cid, ftx, lpPubkey, _p2tr(shutdownKey));
    }

    // ─────────────────────────── lev wiring ───────────────────────────

    /// Open a BTC-lev position for `lp`: the caller brings EXTERNAL WBTC, which `openBtcLev` pulls
    /// straight into the venue. Zero leverage ⇒ net-equity == collateral.
    function _openWbtcLev(address lp, uint sats) internal {
        deal(address(WBTC), lp, sats);
        vm.startPrank(lp);
        IERC20V(address(WBTC)).approve(address(lmW), sats);
        lmW.openBtcLev(sats, wvenue);
        vm.stopPrank();
    }

    /// Give `lp`'s position REAL Aave debt of `usdc6` through the venue's own `onlyManager` leg — the
    /// keeper's `rebalanceWbtc` borrows nothing at a flat price (IL-clamped), and these tests are about
    /// the valuation/repay legs, not about how the debt got there. The venue pays the MANAGER, so the
    /// stable is handed on to `lp`: a fixture has to reproduce WHERE THE MONEY ENDED UP.
    function _borrowWbtcVenue(address lp, uint usdc6) internal {
        vm.prank(address(lmW)); wvenue.borrow(lp, usdc6);
        vm.prank(address(lmW)); IERC20V(address(USDC)).transfer(lp, usdc6);
    }

    /// Deploy + pin a BtcLevManager over the REAL Aave v3 {WBTC collateral, USDC debt} book — the
    /// PRODUCTION venue (DeployL1_s wires the SAME addresses; no market to seed, Aave v3's live USDC
    /// liquidity backs the borrow). The de-lever FLASH provider is Morpho (init flash=MORPHO) ⇒
    /// cross-protocol: flash USDC from Morpho, repay/withdraw on Aave. This is the exact venue the
    /// keeper's atomic `rebalanceWbtc` drives on-chain.
    function _setupBtcLevWbtc() internal {
        lmW = new BtcLevManager(address(AUX), address(WBTC), address(this), address(QUID));
        address dataProvider = IAaveV3AddrProviderT(AAVE_V3_ADDR).getPoolDataProvider();
        wvenue = new AaveV3Venue(AAVE_V3_POOL, dataProvider, address(WBTC), address(USDC), address(lmW), 7800);
        address[] memory vs = new address[](1); vs[0] = address(wvenue);
        lmW.init(address(BTC), MORPHO, vs);        // hook=Vault, flash=MORPHO (de-lever), Aave-WBTC venue (FROZEN)
    }

    /// Mock the ONE assetPrice(WBTC) read to `px` (USD18 per 1e18-raw, WBTC-lifted). Drives the IL target:
    /// price ABOVE entry ⇒ ilTarget>0 ⇒ fold up; back to/below entry ⇒ ilTarget→0 ⇒ de-lever. The SOR swaps ride
    /// the REAL (un-mocked) pool price, so the 1% oracle floor clears as long as the mock ≈ live within range.
    function _mockPx(uint px) internal {
        vm.mockCall(address(AUX), abi.encodeWithSelector(IAuxTwapV.assetPrice.selector, address(WBTC), uint32(1800)),
            abi.encode(px));
    }

    /// #106/#81/#74 — the WBTC-fallback money path the Rust keeper's `rebalanceWbtc(lp,0)` triggers, end to end
    /// on a REAL Morpho market + REAL UniV3-backed SOR: open (LP brings external WBTC) → price rises → atomic
    /// `rebalanceWbtc` FOLDS UP (real USDC borrow → SOR USDC→WBTC → supply) → price falls back → atomic
    /// `rebalanceWbtc` FLASH-repay-first DE-LEVERS (Morpho flash USDC → repay → withdraw WBTC → SOR WBTC→USDC
    /// → return flash). Direction is decided on-chain from `debtDeltaToTarget`; the keeper only picks WHEN.
    function testReal_WbtcLev_FoldUp_Then_FlashDelever() public {
        _setupBtcLevWbtc();
        address lp = makeAddr("wbtcLp");
        uint coll = 1e8; // 1 WBTC (8-dec)

        // LP brings EXTERNAL WBTC and opens: transferFrom lp→venue, then venue.supply into the Aave escrow.
        deal(address(WBTC), lp, coll);
        vm.startPrank(lp);
        IERC20V(address(WBTC)).approve(address(lmW), coll);
        lmW.openBtcLev(coll, wvenue);          // cap 75% (AaveV3Venue = per-LP escrow, no Morpho auth needed)
        vm.stopPrank();
        assertApproxEqAbs(wvenue.collateralOf(lp), coll, 1e4, "opened with ~1 WBTC collateral");
        assertEq(wvenue.debtOf(lp), 0, "opens at zero debt");

        uint entryPx = AUX.assetPrice(address(WBTC));

        // ── FOLD UP: price +25% ⇒ ilTarget = 1−√(1/1.25) ≈ 1054 bps ⇒ borrow USDC, SOR→WBTC, supply. ──
        _mockPx(entryPx * 125 / 100);
        (bool levUp, uint deltaUp) = lmW.debtDeltaToTarget(lp);
        assertTrue(levUp && deltaUp > 0, "IL target says lever up after +25%");
        lmW.rebalanceWbtc(lp, 0, DEX_WBTC_USDC, 0, "");                     // permissionless + self-flooring (what the keeper sends)
        uint debtAfterUp = wvenue.debtOf(lp);
        assertGt(debtAfterUp, 0, "folded up: real USDC debt on Morpho");
        assertGt(wvenue.collateralOf(lp), coll, "folded up: swapped WBTC added to collateral");
        vm.clearMockedCalls();

        // ── FLASH-DE-LEVER: price back to entry ⇒ ilTarget→0 ⇒ target debt 0 ⇒ full de-lever via Morpho flash. ──
        _mockPx(entryPx);
        (bool levUp2, uint deltaDn) = lmW.debtDeltaToTarget(lp);
        assertTrue(!levUp2 && deltaDn > 0, "IL target says de-lever back at entry");
        lmW.rebalanceWbtc(lp, 0, DEX_WBTC_USDC, 0, "");                     // flash-repay-first (flashProvider=MORPHO pinned in init)
        assertLt(wvenue.debtOf(lp), debtAfterUp, "flash-de-lever reduced the debt");
        vm.clearMockedCalls();
    }

    /// @notice §WBTC-MODE-CANNOT-CLOSE — the retirement money path, which had NO coverage before this.
    ///   `AaveV3Venue.withdraw` ends `e.withdrawColl(w, MANAGER)`, so the close hands the manager WBTC and
    ///   the manager hands it to the caller: collateral leaves by the door it came in.
    /// ⛔ THIS IS NOT THE LP PRODUCT PATH, and the fixture must not be read as evidence that it is. An LP
    ///   deposits Lightning BTC and never WBTC (owner, 2026-09-07), so `makeAddr("wbtcCloseLp")` here is
    ///   just *someone holding WBTC* — which `openBtcLev` admits permissionlessly. The test proves the
    ///   close works for a position that can exist; §BTC-IL-PROTECT-IS-INERT is why no real LP has one.
    function testReal_WbtcLev_CloseReturnsTheLpsOwnWbtc() public {
        _setupBtcLevWbtc();
        // PIN THE MANAGER AS PRODUCTION DOES (`DeployL1_s`: `ETH.setLevManager(address(bm))`), so the
        // `_syncRange` legs on either side of the close run against a wired range rather than no-oping.
        BTC.setLevManager(address(lmW));
        address lp = makeAddr("wbtcCloseLp");
        uint coll = 1e8;                                     // 1 WBTC (8-dec)

        deal(address(WBTC), lp, coll);
        vm.startPrank(lp);
        IERC20V(address(WBTC)).approve(address(lmW), coll);
        lmW.openBtcLev(coll, wvenue);                        // transferFrom lp → venue
        vm.stopPrank();
        // PREMISE — the LP really parted with the WBTC, or "it came back" is a reading of nothing.
        assertEq(IERC20V(address(WBTC)).balanceOf(lp), 0, "PREMISE: the open must take the LP's WBTC");
        assertApproxEqAbs(wvenue.collateralOf(lp), coll, 1e4, "PREMISE: collateral is posted");
        assertEq(wvenue.debtOf(lp), 0, "PREMISE: opens at zero debt, so close needs no unwind");

        vm.prank(lp);
        lmW.closeBtcLev();

        assertApproxEqAbs(IERC20V(address(WBTC)).balanceOf(lp), coll, 1e4,
            "the LP must get its OWN WBTC back");
        assertEq(wvenue.collateralOf(lp), 0, "position fully withdrawn from the venue");
    }

    /// @notice §WBTC-MODE-CANNOT-CLOSE §2 — the delivery-side refusal, and it must stay a REVERT rather
    ///   than become a silent truncation. `swapOutDelever`'s `freeSats` leg frees BTC the range can DELIVER;
    ///   a position collateralised in WBTC cannot deliver its backing as BTC without a conversion that is
    ///   not built, so the manager says so loudly. The repay leg (`stableUsd`) is unaffected and still runs.
    function testReal_WbtcLev_SwapOutDeleverRefusesTheSliceLoudly() public {
        _setupBtcLevWbtc();
        // PIN THE MANAGER AS PRODUCTION DOES (`DeployL1_s`: `ETH.setLevManager(address(bm))`), so the
        // refusal below is the manager's, not the fixture's wiring answering a different question.
        BTC.setLevManager(address(lmW));
        address lp = makeAddr("wbtcSliceLp");
        uint coll = 1e8;
        deal(address(WBTC), lp, coll);
        vm.startPrank(lp);
        IERC20V(address(WBTC)).approve(address(lmW), coll);
        lmW.openBtcLev(coll, wvenue);
        vm.stopPrank();

        // Zero `freeSats` is the funded-only case and must still be accepted (it is how a de-lever with
        // nothing to un-encumber calls through) — assert that BEFORE asserting the refusal, so the revert
        // below is attributable to the slice and not to the gate rejecting everything.
        vm.prank(lmW.RANGE());
        lmW.swapOutDelever(lp, 0, 0);

        vm.prank(lmW.RANGE());
        vm.expectRevert(BtcLevManager.WbtcSliceNotDeliverable.selector);
        lmW.swapOutDelever(lp, 0, 5e7);
    }

    /// @notice REGRESSION for the 1e10 BTC scale bug (Vyper audit C-1/C-2/C-3): with REAL debt, the BTC
    ///   valuations must scale like the rest of the codebase (px = USD18/1e18-raw, WBTC-lifted ×1e10 ⇒ /1e18).
    ///   The former /1e8 (collateral, E0) & /1e10 (debt) made net-equity treat the debt as ≈0 (phantom
    ///   rangeBTC backing) and getCurrentLtvBps read ≈0 (venue-safety blind). A ZERO-debt position
    ///   early-returns before the debt/price path and masks all three, so this one carries real debt:
    ///   2 BTC collateral, ~50% LTV ⇒ net-equity MUST be ~1 BTC and LTV MUST be ~50%.
    function test_BtcLev_WithDebt_ScaleCorrect() public {
        _setupBtcLevWbtc();
        address lp = makeAddr("scaleLp");
        _openWbtcLev(lp, 2e8);                                     // 2 WBTC collateral, zero debt
        uint px = AUX.assetPrice(address(WBTC));        // USD18 per 1e18-raw (WBTC-lifted)
        uint collUsd = 2e8 * px / 1e18;                            // USD18 value of 2 BTC
        _borrowWbtcVenue(lp, (collUsd / 2) / 1e12);                // ~50% LTV, USDC 6-dec
        // C-2: the venue LTV is the true ~50%, NOT ~0 (before the fix collValueUsd was 1e10 too big).
        assertApproxEqAbs(lmW.getCurrentLtvBps(lp), 5000, 400, "getCurrentLtvBps ~50%, not ~0 (C-2)");
        // C-1: net-equity = collateral − debt = ~1 BTC, NOT ~2 BTC (before the fix the debt leg was ~0).
        assertApproxEqAbs(lmW.netEquity(lp), 1e8, 6e6, "netEquityBtc ~1 BTC = coll-debt, not ~2 (C-1)");
    }

    /// @notice #43 BTC counterpart of LevCascade.test_ProtectFromQuid_HostileOperatorNetsZero — the previously-STUBBED
    ///   path (BtcLevManager had no protect entrypoint; the keeper bailed). A BTC-levered LP's OWN opted-in QUID is
    ///   redeemed to repay its OWN real Aave debt near liquidation, via the SAME asset-agnostic `LevMath.protectExec`
    ///   the ETH side uses — proving the BtcLevManager wrapper wires it correctly and a hostile caller nets ZERO.
    function testReal_BtcProtectFromQuid_HostileOperatorNetsZero() public {
        _setupBtcLevWbtc();
        address lp = makeAddr("protectLp");
        _openWbtcLev(lp, 2e8);                                       // 2 WBTC, zero debt
        uint px0 = AUX.assetPrice(address(WBTC));
        _borrowWbtcVenue(lp, ((2e8 * px0 / 1e18) / 2) / 1e12);       // ~50% LTV real Aave USDC debt
        assertGt(wvenue.debtOf(lp), 0, "LP has real BTC-lev debt");

        // The LP mints + OPTS IN its OWN QUID (the one-time delegated `approve`), mirroring the ETH proof.
        deal(address(USDC), lp, 300_000 * USDC_PRECISION);
        vm.startPrank(lp);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(lp, 200_000 * USDC_PRECISION, address(USDC), 0);
        QUID.approve(address(lmW), type(uint).max);
        vm.stopPrank();

        // Mature the QUID vintage (redeem is mature-only); keep every oracle read fresh across the warp.
        uint ethPx = AUX.assetPrice(address(WETH));
        vm.warp(block.timestamp + 35 days); vm.roll(block.number + 1);
        _setEthFeed(ethPx / 1e10);
        _mockPx(px0);
        vm.mockCall(address(AUX), abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)), abi.encode(uint(0)));
        vm.mockCall(address(AUX), abi.encodeWithSignature("getDepegSeverityBps(address)", address(DAI)), abi.encode(uint(0)));
        // Near-liq TRIGGER: tighten ONLY the venue liq threshold to just above the live LTV (as the ETH proof does;
        // the entire redeem→repay→refund money path stays 100% REAL — only the risk param deciding *when* is staged).
        vm.mockCall(address(wvenue), abi.encodeWithSelector(wvenue.liqThresholdBps.selector),
            abi.encode(lmW.getCurrentLtvBps(lp) + 1000));

        // ADVERSARIAL + HAPPY: an arbitrary hostile caller protects the opted-in LP. Value moves ONLY toward the LP.
        address hostile = address(0xBADBEEF);
        uint hQuid0 = QUID.balanceOf(hostile); uint hUsdc0 = USDC.balanceOf(hostile);
        uint lpDebt0 = wvenue.debtOf(lp); uint lpQuid0 = QUID.balanceOf(lp);
        vm.prank(hostile);
        uint repaid = lmW.protectFromQuid(lp, 0);
        assertGt(repaid, 0, "protect repaid the LP's BTC-lev debt via its own QUID");
        assertLt(wvenue.debtOf(lp), lpDebt0, "the LP's OWN debt fell");
        assertLt(QUID.balanceOf(lp), lpQuid0, "the LP's own QUID funded its own protection");
        assertEq(QUID.balanceOf(hostile), hQuid0, "hostile caller gained NO QUID");
        assertEq(USDC.balanceOf(hostile), hUsdc0, "hostile caller gained NO stable");
    }

    // ─────────────────────────── close / de-lever money-path coverage (#64) ───────────────────────────

    /// @notice (#64 gap 2, HIGH) the manager-level LP-gated legs `repay` + `deleverWithdraw`. Opens a
    ///   position with REAL Aave debt, repays half through the manager, then withdraws collateral back to
    ///   the LP — asserting both real debt/collateral deltas. `deleverWithdraw` returns WBTC because WBTC
    ///   is what the venue custodies; a position's collateral leaves by the door it came in.
    function testReal_BtcRepayAndDeleverWithdraw_LpGated() public {
        _setupBtcLevWbtc();
        address lp = makeAddr("repayWithdrawLp");
        _openWbtcLev(lp, 2e8);

        uint px = AUX.assetPrice(address(WBTC));
        uint debtUsdc = ((2e8 * px / 1e18) / 2) / 1e12;             // ~50% LTV of real Aave debt
        _borrowWbtcVenue(lp, debtUsdc);
        uint debt0 = wvenue.debtOf(lp);
        uint coll0 = wvenue.collateralOf(lp);
        assertGt(debt0, 0, "LP has real BTC-lev Aave debt");
        assertApproxEqAbs(coll0, 2e8, 1e4, "collateral == the 2 WBTC supplied");

        // ── manager `repay` (LP-gated): repay HALF the debt through the manager (clamp-before-transfer). ──
        uint payUsdc = debtUsdc / 2;
        deal(address(USDC), lp, payUsdc);
        vm.startPrank(lp);
        USDC.approve(address(lmW), type(uint).max);
        uint repaid = lmW.repay(uint(payUsdc) * 1e12);              // USD 1e18 ⇒ ~payUsdc stable
        vm.stopPrank();
        assertApproxEqAbs(repaid, payUsdc, 2, "repay applied ~half the debt");
        assertApproxEqAbs(wvenue.debtOf(lp), debt0 - payUsdc, debt0 / 50, "repay reduced the venue debt");

        // ── manager `deleverWithdraw` (LP-gated): the half-repay freed LTV headroom to withdraw WBTC. ──
        uint lpWbtc0 = IERC20V(address(WBTC)).balanceOf(lp);
        uint wantSats = 1e7;                                        // 0.1 BTC — well within the freed headroom
        vm.prank(lp);
        uint out = lmW.deleverWithdraw(wantSats);
        assertApproxEqAbs(out, wantSats, 2, "deleverWithdraw returned the requested sats");
        assertApproxEqAbs(wvenue.collateralOf(lp), coll0 - wantSats, 1e4, "deleverWithdraw reduced the venue collateral");
        assertEq(IERC20V(address(WBTC)).balanceOf(lp) - lpWbtc0, out, "the withdrawn WBTC landed with the LP");
    }

    // ─────────────────────────── #36 venue safety gates (REAL venues) ───────────────────────────

    /// @notice (#36a) `init` must REJECT any venue whose collateral is not WBTC. The manager values
    ///   collateral as 8-dec BTC at the ONE `assetPrice(WBTC)` read, so any other token silently
    ///   misvalues into phantom BTC backing for rangeBTC — `LevMath.vetVenue`'s `coll != c0 && coll != c1`
    ///   is the guard and `BtcLevManager.init` passes WBTC for both.
    /// ⛔ THE SECOND HALF IS THE OWNER RULING (2026-09-07), NOT A DUPLICATE OF THE FIRST: a venue whose
    ///   collateral is the vBTC token must be rejected too. Lightning-custodied BTC as collateral to borrow
    ///   dollars to buy more Lightning BTC is a toxic loop, and vBTC is a PROJECTION of Vault shares that no
    ///   escrow can physically custody. Deleting this assertion is how that market comes back.
    function test_BtcLevVenueGate_InitRejectsNonWbtcCollateral() public {
        BtcLevManager lm2 = new BtcLevManager(address(AUX), address(WBTC), address(this), address(QUID));
        address oracle = address(new RealRateBtcMorphoOracle(address(AUX), address(WBTC)));
        address[] memory vs = new address[](1);

        vs[0] = address(new MorphoEscrowVenue(MORPHO, MarketParams({
            loanToken: address(USDC), collateralToken: address(WETH),
            oracle: oracle, irm: ADAPTIVE_IRM, lltv: 0.86e18}), address(lm2)));
        vm.expectRevert(LevMath.BadCollateral.selector);
        lm2.init(address(BTC), MORPHO, vs);

        vs[0] = address(new MorphoEscrowVenue(MORPHO, MarketParams({
            loanToken: address(USDC), collateralToken: address(BTC.VBTC()),
            oracle: oracle, irm: ADAPTIVE_IRM, lltv: 0.86e18}), address(lm2)));
        vm.expectRevert(LevMath.BadCollateral.selector);
        lm2.init(address(BTC), MORPHO, vs);
    }

    /// @notice (#36b) openBtcLev must REJECT a NEW position onto an incident-flagged venue (GOV setVaultHealth).
    function test_BtcLevVenueGate_OpenRejectsBlockedVenue() public {
        _setupBtcLevWbtc();
        AUX.setVaultHealth(address(wvenue), true);   // real incident flag (AUX owner == this test)
        vm.prank(address(0xB0B));
        vm.expectRevert(LevMath.VenueBlocked.selector);
        lmW.openBtcLev(1e8, wvenue);                 // reverts at the health gate, before MIN_OPEN/transfer
    }
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// §LEV-DELEVER-CLUSTER — the ETH `LevManager` de-lever legs, which had ZERO coverage of any kind:
// `grep -rl 'deleverToVault\|deleverBook' evm/test/` returned NOTHING, and `grep -rn 'closeLev('
// evm/test/` returned NOTHING. Three money-path defects shipped through that hole, and each of the
// three is a single assertion away from being caught. They are asserted HERE rather than in the
// BTC suite above because the paths are ETH-side; the fixture is the minimum LevCascadeProbe stack
// (real Morpho weETH/USDC market, real flash provider, real range) and is DELIBERATELY NOT reached
// by inheriting `LevCascadeProbe` — that contract is also a suite of 18 fork tests, and inheriting
// it re-runs every one of them (its own §POOL-VENUE note records exactly that measurement).
// ═════════════════════════════════════════════════════════════════════════════════════════════════
contract EthLevDeleverLegs is AllesFixture {
    address constant WEETH_E        = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant MORPHO_E       = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM_E = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address constant CL_ETH_USD_E   = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // Fields, not deep locals — same non-via_ir stack discipline the sibling fixtures keep.
    LevManager        elm;
    MorphoEscrowVenue evenue;
    MarketParams      emp;

    address constant LP_A = address(0xE7BEEF1);
    address constant LP_B = address(0xE7BEEF2);
    address constant SINK = address(0x5117BEEF);   // stands in for the redeem sink (`BasketLib`)

    /// Real Morpho weETH/USDC market + a real `LevManager` pinned to the REAL ETH range and the REAL
    /// zero-fee Morpho flash provider. Mirrors `LevCascadeProbe._setupLev` minus the parts these tests
    /// do not exercise.
    function _setupEthLev() internal {
        // Real basket depth, so `syncLev` has something to pair the levered slice against.
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();

        emp = MarketParams({
            loanToken: address(USDC), collateralToken: WEETH_E,
            oracle: address(new RealRateMorphoOracle(WEETH_E, CL_ETH_USD_E)),
            irm: ADAPTIVE_IRM_E, lltv: 0.86e18});
        IMorphoTest morpho = IMorphoTest(MORPHO_E);
        morpho.createMarket(emp);
        deal(address(USDC), address(this), 5_000_000 * USDC_PRECISION);
        IERC20V(address(USDC)).approve(MORPHO_E, 5_000_000 * USDC_PRECISION);
        morpho.supply(emp, 5_000_000 * USDC_PRECISION, 0, address(this), "");

        elm = new LevManager(WEETH_E, address(AUX), address(WETH), address(this), address(QUID));
        evenue = new MorphoEscrowVenue(MORPHO_E, emp, address(elm));
        address[] memory vs = new address[](1); vs[0] = address(evenue);
        elm.init(address(ETH), MORPHO_E, vs);   // RANGE = the ETH range (the only `deleverToVault` caller)
        EV.setLevManager(address(elm));         // pin the leveraged book into rangeETH
        // Pin the ETH/USD anchor, or `assetPrice` can answer 0 and the sizing divides by it.
        _setEthFeed(AUX.assetPrice(address(WETH)) / 1e10);
        _auxSetAssetFeed(address(WETH), ETH_FEED);
    }

    /// Open a ZERO-leverage position for `lp` (mirrors `LevCascadeProbe._rangeE0` + `_openLevOnly`).
    function _openEth(address lp, uint sizeEth) internal {
        vm.deal(lp, sizeEth + 1 ether);
        vm.prank(lp); ETH.deposit{value: sizeEth}(0, lp);
        deal(WEETH_E, lp, sizeEth);
        vm.prank(lp); IMorphoTest(MORPHO_E).setAuthorization(address(evenue), true);
        vm.startPrank(lp);
        IERC20V(WEETH_E).approve(address(elm), sizeEth);
        elm.openLev(ILevVenue(address(evenue)), sizeEth);
        vm.stopPrank();
    }

    /// Give `lp` REAL Morpho debt through the venue's own `onlyManager` leg — the same shape the BTC
    /// fixture above uses, and for the same reason: the keeper's IL-clamped `rebalance` borrows nothing
    /// at a flat price, and these tests are about the DE-lever, not about how the debt got there.
    /// The venue pays the MANAGER, so the stable is handed on to `lp` (see `_borrowMorpho`'s note).
    function _borrowEth(address lp, uint usdc6) internal {
        vm.prank(address(elm)); evenue.borrow(lp, usdc6);
        vm.prank(address(elm)); IERC20V(address(USDC)).transfer(lp, usdc6);
    }

    /// @notice (#43) PERMISSIONLESS `repayFor` reduces the LP's share of the venue debt — the on-chain
    ///   primitive the QUID-protect keeper calls after redeeming the LP's mature QUID
    ///   (redeem→stable→repayFor). No MANAGER auth (a random caller repays here), caller-funded, clamped
    ///   to the LP's debt. It lives on `MorphoEscrowVenue`, so it is proved here rather than on the BTC
    ///   leg, whose only venue is `AaveV3Venue`.
    function test_RepayFor_PermissionlessReducesLpDebt() public {
        _setupEthLev();
        _openEth(LP_A, 5 ether);
        uint debtUsdc = 6_000 * USDC_PRECISION;
        _borrowEth(LP_A, debtUsdc);
        uint debt0 = evenue.debtOf(LP_A);
        assertGt(debt0, 0, "LP has real Morpho debt");

        // A random address (NOT the MANAGER) repays HALF on the LP's behalf -- proves it's permissionless + safe.
        address helper = address(0xCAFE);
        uint pay = debtUsdc / 2;
        deal(address(USDC), helper, pay);
        vm.startPrank(helper);
        USDC.approve(address(evenue), pay);
        uint repaid = evenue.repayFor(LP_A, pay);
        vm.stopPrank();
        assertApproxEqAbs(repaid, pay, 2, "repayFor repaid the requested amount");
        assertApproxEqAbs(evenue.debtOf(LP_A), debt0 - pay, debt0 / 50, "repayFor reduced the LP's debt");
    }

    // ─────────────────────────────────── F12 + F13 ───────────────────────────────────

    /// 🔴 §F12 — **THE UNIT.** `deleverToVault` returned `_lastFreed` raw, and `_lastFreed` is what
    ///    `LevMath._sellAndPay` handed the sink: `stableOut - assets`, in the venue stable's NATIVE
    ///    units (6-dec for USDC). `deleverBook` passes it straight on to `BasketLib:1175`'s
    ///    `if (freed < need) freed += _deleverBookForRedeem(...)`, where `need` and the seeding
    ///    `unwindForRedeem` are BOTH USD 1e18. A $25,000 extraction therefore reported `2.5e10` —
    ///    numerically indistinguishable from ZERO against an 18-dec `need`. The LP's levered net equity
    ///    fell by $25,000 and the book credited ~nothing, so `freed < need` stayed true and the next
    ///    redeem tore down more of the same LP's leverage, again for no credit. Nothing was stolen (the
    ///    dollars land in Aux and are sweepable) — it is repeated uncompensated destruction of a
    ///    position, which is why a unit assertion is the whole defence.
    ///
    /// 🔴 §F13 — **THE CAP.** `LevMath._repayAndPull` deliberately over-withdraws the paired collateral
    ///    by `10_000/(10_000 - maxSlippageBps)` = **+1.0101 %** at `MAX_SLIPPAGE_BPS = 100`, "so the sale
    ///    covers `assets` at worst execution". `_sellAndPay` then hands the ENTIRE `stableOut - assets` to
    ///    its recipient. For mode 0 that recipient is the LP and the unused buffer goes home; the WBTC
    ///    mirror (`LevMath.flashDeleverWbtcSettle`) likewise returns it to the LP. For mode 2 the
    ///    recipient was `vault`, so the redeem sink was paid the buffer as well — uncapped by the
    ///    `extractUsd` that sized the withdraw, out of the LP's residual equity, on every call.
    ///
    /// ⚠️ THE TWO ARE ASSERTED IN ONE TEST ON PURPOSE: they are the two halves of one sentence, "how
    ///    much left the LP and how much is reported to the book", and pre-fix each one's error hides in
    ///    the other's units.
    function testReal_DeleverToVault_ReportsUsd18_AndNeverPaysTheSinkPastWhatItSized() public {
        _setupEthLev();
        _openEth(LP_A, 5 ether);
        _borrowEth(LP_A, 6_000 * USDC_PRECISION);            // real Morpho debt ⇒ a value-neutral tap exists
        assertGt(evenue.debtOf(LP_A), 0, "fixture: the position is levered");

        uint want  = 500e18;                                  // $500, in the USD 1e18 the range asks in
        uint sized = elm.deliverableDollars(LP_A);            // the #67 bound `deleverToVault` clamps to
        if (want < sized) sized = want;
        assertGt(sized, 0, "fixture: something is deliverable");

        uint sinkBefore = IERC20V(address(USDC)).balanceOf(SINK);
        uint lpBefore   = IERC20V(address(USDC)).balanceOf(LP_A);
        vm.prank(address(ETH));                               // RANGE — the only permitted caller
        uint freed = elm.deleverToVault(want, SINK, 0);
        uint sinkGot = IERC20V(address(USDC)).balanceOf(SINK) - sinkBefore;
        uint lpGot   = IERC20V(address(USDC)).balanceOf(LP_A) - lpBefore;

        assertGt(freed, 0, "the tap sourced something (otherwise the rest of this proves nothing)");
        assertGt(sinkGot, 0, "and the sink was actually paid");
        // §F12 — the returned figure is the USD VALUE of what the sink received, not its native count.
        // Pre-fix this held `sinkGot` itself and the two sides differed by exactly 1e12.
        assertApproxEqRel(freed, sinkGot * 1e12, 0.01e18,
            "deleverToVault must return USD 1e18, NOT the venue stable's native units");
        assertGt(freed, sinkGot,
            "a 6-dec figure handed to an 18-dec comparison IS the bug -- they can never be equal");
        // §F13 — the sink may not be paid one unit past what `deleverToVault` sized. Pre-fix it was
        // paid ~1.9% more (the worked case: $190 over a sized $10,000).
        assertLe(sinkGot, sized / 1e12 + 1,
            "the redeem sink was paid MORE than the extractUsd that sized the withdraw");
        // ...and the buffer that the sale did not consume goes back to the LP whose collateral it was.
        // The buffer is 1.0101% of the withdraw against real-market slippage of a few bps on a $500
        // sale, so a zero here means the refund leg did not run, not that there was nothing to refund.
        assertGt(lpGot, 0, "the unconsumed slippage buffer must return to the LP, never to the sink");
    }

    // ─────────────────────────────────── F14 ───────────────────────────────────

    /// 🔴 §F14 — **`_closeLev` HAD NO POST-CONDITION AND ITS SIBLING DOES.**
    ///    `LevMath.deleverFlashBody` returns SILENTLY on three conditions (`repayUsd == 0`,
    ///    `flashProvider == address(0)`, `debt == 0`), leaving the debt untouched and reporting nothing.
    ///    `_closeLev` then withdrew ALL of the LP's collateral and dropped the slot — it could not tell
    ///    "repaid" from "did nothing". Under §POOL-VENUE the venue holds ONE shared position, so
    ///    `venue.withdraw` burns only THIS LP's units while Morpho's health check is against the POOL:
    ///    **with another LP's collateral present it PASSES, and the closing LP walks with everything
    ///    while its debt stays socialised across whoever is left.** `_deleverOne` has asserted
    ///    `debtOf(lp) < debtBefore` all along; the close had nothing.
    ///
    /// ⚠️ THE SECOND LP IS THE TEST, NOT SET DRESSING. With one LP the pool's own health check refuses
    ///    the withdraw and the close reverts on its own — which is exactly why this never surfaced.
    ///
    /// The flash is neutered with a `mockCall` rather than by re-`init`ing a manager with a zero
    /// `flashProvider`, because that reproduces the silent return on the LIVE configuration (`init`
    /// DOES accept a zero `flashProvider` with no check — `LevMath.sol`'s claim that it "refuses" one is
    /// false — but `DeployL1_s` pins real Morpho, so the config route is not the live one).
    function testReal_CloseLev_RefusesToDropTheSlotWhenTheFlashRepaidNothing() public {
        _setupEthLev();
        _openEth(LP_A, 5 ether);
        _openEth(LP_B, 5 ether);                              // §POOL-VENUE: a SECOND LP's collateral in the pool
        _borrowEth(LP_A, 6_000 * USDC_PRECISION);
        _borrowEth(LP_B, 6_000 * USDC_PRECISION);
        uint poolDebt  = ILevPooled(address(evenue)).totalDebt();
        uint lpDebt    = evenue.debtOf(LP_A);
        uint lpColl    = evenue.collateralOf(LP_A);
        uint lpWeeth   = IERC20V(WEETH_E).balanceOf(LP_A);
        assertGt(lpDebt, 0, "fixture: the closing LP owes the pool");
        assertGt(evenue.debtOf(LP_B), 0, "fixture: and it is not the only one who does");

        // The flash becomes a NO-OP: `deleverFlashBody` calls it and returns, nothing is repaid, and —
        // this is the defect — nothing says so.
        vm.mockCall(MORPHO_E, abi.encodeWithSignature("flashLoan(address,uint256,bytes)"), "");
        vm.prank(LP_A);
        vm.expectRevert(LevManager.NoRepay.selector);   // §EIP-170 — the string literal became a custom error
        elm.closeLev(0, DEX_WETH_USDC);
        vm.clearMockedCalls();

        // NOTHING MOVED, and that is the point. Before the post-condition existed this call SUCCEEDED:
        // LP_A left with all of its collateral and `pos[LP_A]` was deleted, while `poolDebt` stood.
        (,,,, bool stillOpen) = elm.pos(LP_A);
        assertTrue(stillOpen, "the refused close left the position OPEN");
        assertEq(evenue.debtOf(LP_A), lpDebt, "the debt is exactly where it was");
        assertEq(evenue.collateralOf(LP_A), lpColl, "so is the collateral");
        assertEq(IERC20V(WEETH_E).balanceOf(LP_A), lpWeeth, "and none of it reached the LP");
        assertEq(ILevPooled(address(evenue)).totalDebt(), poolDebt,
            "the pool's debt was never socialised onto the LPs who stayed");
    }

    /// The other half of §F14, and the reason the ceil (`d + 1`) exists: a REAL close still clears the
    /// debt and drops the slot. `deleverFlashBody` sizes the flash as `LevMath._fromUsd(repayUsd)`, which
    /// FLOORS — at a non-par loan price the `_fromUsd(_toUsd18(debtOf))` round trip lands one unit short,
    /// which drops `LevVenueBase._repayCreditingLp` out of its by-SHARES branch (the one that "lands on
    /// ZERO") into the by-ASSETS branch. One wei of USD-1e18 pushes the floor back onto `debtOf`, and
    /// `deleverFlashBody`'s existing clamp means it can never flash MORE than the debt.
    /// ⚠️ THIS IS THE FIRST TEST IN THE TREE TO CALL `closeLev` AT ALL (`grep -rn 'closeLev(' evm/test/`
    ///    was empty), which is the same hole §F14 came through.
    function testReal_CloseLev_ClearsTheDebtAndDropsTheSlot() public {
        _setupEthLev();
        _openEth(LP_A, 5 ether);
        _openEth(LP_B, 5 ether);
        _borrowEth(LP_A, 4_000 * USDC_PRECISION);
        assertGt(evenue.debtOf(LP_A), 0, "fixture: the closing LP owes the pool");

        vm.prank(LP_A);
        elm.closeLev(0, DEX_WETH_USDC);

        // ⛔ NOT A TOLERANCE — `1` is the EXACT bound the unit ledger admits. The by-SHARES repay clears
        //    the LP's Morpho shares; `_burnUnits` is the floor inverse of the floor `_unitSlice` that
        //    produced them, so at most ONE unit can survive the round trip, and one unit prices back
        //    through `_sharesToAssetsUp` to at most one native unit ($0.000001). A FAILURE HERE IS
        //    ITSELF THE FINDING: it would mean the unit-burn residue is larger than one unit, which is
        //    the exact premise on which `_closeLev`'s post-condition is `< debtBefore` and not `== 0`.
        assertLe(evenue.debtOf(LP_A), 1,
            "close: the ceiled repay lands ON the debt, leaving at most the one-unit burn residue");
        assertEq(evenue.collateralOf(LP_A), 0, "close: all collateral withdrawn");
        assertGt(IERC20V(WEETH_E).balanceOf(LP_A), 0, "close: and returned to the LP");
        (,,,, bool open) = elm.pos(LP_A);
        assertTrue(!open, "close: a voluntary close drops the slot");
    }
}
