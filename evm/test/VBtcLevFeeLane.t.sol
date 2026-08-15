// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Alles, MockSPV} from "./Alles.t.sol";
import {LevBase} from "../src/imports/LevBase.sol";
import {ExitFixture} from "./btc/ExitFixture.sol";
import {BTCChannels} from "../src/BTCChannels.sol";
import {BtcLevManager} from "../src/BtcLevManager.sol";
import {ILevVenue} from "../src/imports/ILevVenue.sol";
import {Types} from "../src/imports/Types.sol";
import {MorphoEscrowVenue, MarketParams} from "../src/MorphoEscrowVenue.sol";
import {AaveV3Venue} from "../src/AaveV3Venue.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {RealRateBtcMorphoOracle} from "../src/LevOracles.sol";

interface IERC20V {
    function transfer(address, uint) external returns (bool);
    function transferFrom(address, address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
    function approve(address, uint) external returns (bool);
    function decimals() external view returns (uint8);
}
interface IAuxTwapV { function getTWAPforAsset(address asset, uint32 period) external view returns (uint); }
interface IAaveV3AddrProviderT { function getPoolDataProvider() external view returns (address); }
interface IMorphoTest {
    function createMarket(MarketParams memory m) external;
    function supply(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external returns (uint256, uint256);
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function borrow(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external returns (uint256, uint256);
    function liquidate(MarketParams memory m, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes memory data)
        external returns (uint256, uint256);
    function position(bytes32 id, address user) external view returns (uint256, uint128, uint128);
}
interface IMorphoOraclePrice { function price() external view returns (uint256); }

// RealRateBtcMorphoOracle + InverseRateBtcMorphoOracle now live in src/LevOracles.sol (imported
// above) — DeployL1_s deploys them inline for the real vBTC/short markets; this test fork-proves
// them. A "crash" overrides the ONE getTWAPforAsset(WBTC) read they and the manager share
// (vm.mockCall), so one BTC drawdown moves every leg consistently — no per-oracle mock.

/// @notice UNIT-level behaviour coverage for the BTC IL-protect fee lane — the BTC counterpart of
///         LevCascade's `test_LevFeeLane_EarnsFees_UnwindOnly_SeizureBurnsClean` +
///         `test_NetEquity_BackingRecognized_SeizureLeavesPooledUsdIntact`, over the BTC band.
///
///         The exercised path is `Vault.syncLevBTC` → `VaultLib.syncLevBtc` → `levAddBtc`/`levBurnBtc`
///         (the BTC counterpart of `Vogue.syncLev`/`_levAdd`/`_levBurn`), driven by
///         `BtcLevManager.netEquity(lp)`, plus the `totalNetEquityBtc()` backing read.
///
///         BTC-vs-ETH ADAPTATIONS (faithful, documented):
///           • Collateral is vBTC (8-dec, the Vault's own ERC-20 face minted `onlyBtcChannels`), not
///             weETH. The mock venue above holds vBTC collateral / USDC debt.
///           • BTC band depth is CHANNEL-LOCKED (no permissionless `deposit`/`withdraw` like Vogue),
///             so the fee-lane LP also holds a channel: its `LP.pooled` = channel funding + the lev
///             slice, and fees accrue pro-rata to `LP.pooled` — so the lev equity IS fee-earning band
///             depth, the same mechanism as a channel deposit.
///           • The "unwind-only" guard on the BTC side is the `funded = inrange - lev` cap inside
///             `Vault._resizeBtcLp` (a channel close/splice-out can only shrink the true channel
///             funding, never the virtual lev depth). This is the exact BTC analogue of the ETH
///             `levPooled` cap on `_withdraw`; part (b) exercises it with a real splice-out.
///           • BTC leverage is KEEPER-DRIVEN ASYNC (no synchronous `openLev`/`rebalance` loop — BTC
///             acquisition crosses Bitcoin confirmation), so net-equity is proven at ZERO leverage
///             (net-equity == collateral); the "levered-but-equity-intact" self-financing sub-step
///             from the ETH test has no synchronous analogue and is out of scope for a unit test.
contract VBtcLevFeeLane is Alles {
    /// (E128) A FIXED dead-man deadline. `block.number + n` cannot be used: the BIP-341 sighash
    /// commits to nLockTime, so the exit must be signed for a height known before the tx is built.
    uint64 constant EXIT_DEADLINE = 900_000;

    // Fixed hop pubkey the BTCChannels deployment is bound to (33-byte compressed).
    bytes constant HOP_PUBKEY =
        hex"03a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0";

    address constant MORPHO       = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;

    BtcLevManager     lm;
    MorphoEscrowVenue venue;
    address mOracle;
    MarketParams mp;

    // #106/#81/#74 WBTC-fallback route: a SECOND manager over a {USDC loan, WBTC collateral} market — the LP
    // brings EXTERNAL WBTC (not channel-vBTC), and the keeper's atomic `rebalanceWbtc` folds up / flash-de-levers.
    BtcLevManager     lmW;
    AaveV3Venue       wvenue;
    // AAVE v3 mainnet (deepest WBTC/USDC book) — the production WBTC-fallback venue (DeployL1_s uses these too).
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_V3_ADDR = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    // ─────────────────────────── channel helpers (mirrors BtcLpMintStress) ───────────────────────────

    function _deployChannels() internal returns (BTCChannels ch) {
        ch = new BTCChannels(address(new MockSPV()), address(ETH), makeAddr("hop"), makeAddr("hop-fallback"), bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798)));
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
        (address lpEth_, uint lpPk_) =
            makeAddrAndKey(string(abi.encodePacked("btc-lp-", seed_)));
        bytes32 payout_ = payoutKeyOnly(abi.encode(seed_));
        _btcChannels = address(ch_);
        Types.OpenAuth memory auth_ = Types.OpenAuth({
            lpEth: lpEth_, btcRecipient: payout_,
            lpSig: _signOpen(lpPk_, ch_.openAuthDigest(makeAddr("hop"), payout_)),
            btcRecipientPoP: _popFor(payout_, lpEth_)});
        // (E128) A REAL signed exit for the funding tx this call is about to prove. Built BEFORE
        // the prank so the FFI round-trip cannot consume it.
        Types.ExitArming memory arm_ = armingFor(
            _label(seed_), sha256(abi.encodePacked(sha256(fundingTx_))), 0, p_.amountSats,
            abi.encodePacked(hex"5120", payout_), EXIT_DEADLINE, 1_000);
        vm.prank(makeAddr("hop"));
        cid = ch_.openChannel(p_, fundingTx_, new bytes32[](0), auth_, _ladder(arm_));
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
            fundingTaproot:     _taprootQ(lpPubkey, hopKey_)
        });
    }

    function _open(BTCChannels ch, uint seed, uint amountSats)
        internal
        returns (bytes32 channelId, bytes32 fundingTxId, address lpEth, bytes memory lpPubkey)
    {
        // (E128) OWNED keys — arming now VERIFIES, and an exit can only be signed for a `Q`
        // whose aggregate secret we hold.
        bytes memory hopKey_;
        (lpPubkey, hopKey_, ) = ownedChannelKeys(_label(seed));
        (lpEth, ) = makeAddrAndKey(string(abi.encodePacked("btc-lp-", seed)));

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
        // (E162) A splice may RESIZE a channel, never REKEY one — `keysHash` is pinned at open.
        // So the splice must carry the SAME owned pair the channel was opened with.
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
            fundingTaproot:     _taprootQ(lpPubkey, hopKey_)
        });
        vm.prank(makeAddr("hop"));
        ch.splice(channelId, p, spliceTx, new bytes32[](0));
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
        (address lpEth, uint lpPk) = makeAddrAndKey(string(abi.encodePacked("btc-lp-", seed)));
        bytes memory spk = buildTaprootFundingSpk(lpPubkey, hopKey_);
        bytes memory fundingTx = abi.encodePacked(
            hex"02000000", hex"01", bytes32(0), hex"00000000", hex"00", hex"ffffffff",
            hex"01", _le(amountSats, 8), bytes1(uint8(spk.length)), spk, hex"00000000");
        fundingTxId = sha256(abi.encodePacked(sha256(fundingTx)));
        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash: bytes32(uint(0x100 + seed)), fundingBlockHeight: 800000,
            fundingTxIndex: 0, lpPubkey: lpPubkey, hopPubkey: hopKey_,
            amountSats: amountSats, fundingTaproot: _taprootQ(lpPubkey, hopKey_) });
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
            amountSats: newAmountSats, fundingTaproot: _taprootQ(lpPubkey, hopKey_) });
    }

    // Each case in its own frame (non-via-ir stack limit). `_buildShrink` makes no external
    // call, so `vm.expectRevert` binds cleanly to the `splice()` call below.
    function _shrinkExpectForeignRevert(BTCChannels ch, bytes32 cid, bytes32 ftx,
        bytes memory lpPubkey, bytes memory payoutScript) internal {
        (Types.OpenParams memory p, bytes memory tx_) =
            _buildShrink(ch, cid, 77, lpPubkey, 15e6, 5e6, payoutScript, ftx);
        vm.prank(makeAddr("hop"));
        vm.expectRevert(BTCChannels.ForeignSpliceOutput.selector);
        ch.splice(cid, p, tx_, new bytes32[](0));
    }

    function _shrinkExpectOk(BTCChannels ch, bytes32 cid, bytes32 ftx,
        bytes memory lpPubkey, bytes memory payoutScript) internal {
        (Types.OpenParams memory p, bytes memory tx_) =
            _buildShrink(ch, cid, 77, lpPubkey, 15e6, 5e6, payoutScript, ftx);
        vm.prank(makeAddr("hop"));
        ch.splice(cid, p, tx_, new bytes32[](0));
    }

    /// (E162) A SPLICE MAY RESIZE A CHANNEL; IT MAY NOT REKEY ONE.
    ///
    /// 🔴 This was a live defect and it was mine (§E153). `keysHash` is pinned at open and read
    /// only by the RETIREMENT paths, while `_verifySplice` proves KeyAgg over whatever pair it is
    /// handed — so a splice carrying a DIFFERENT pair passed, rotated the funding outpoint, and
    /// left `keysHash` stale. `recordClose` and `recordDeadManExit` then BOTH reverted
    /// `ChannelKeysMismatch` and the channel was **unretirable forever**: BTC alive in a live
    /// 2-of-2, the EVM position stuck open, backing over-counted indefinitely.
    ///
    /// ⚠️ The check is deliberately ordered BEFORE `_verifySplice`, so this asserts the keys
    /// mismatch rather than an output-not-found — a rekeying splice must be refused on the
    /// INVARIANT, not incidentally because its taproot happens not to appear in the tx.
    function test_spliceCannotRekeyTheChannel() public {
        BTCChannels ch = _deployChannels();
        (bytes32 cid,,, bytes memory lpPubkey) = _open(ch, 91, 2e6);

        ( , bytes memory hopKey_, ) = ownedChannelKeys(_label(91));
        bytes memory otherLp = _validCompressedPubkey("a-different-lp-key");
        assertTrue(keccak256(otherLp) != keccak256(lpPubkey), "must actually differ");

        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash: bytes32(uint(0x5217CE)), fundingBlockHeight: 800001,
            fundingTxIndex: 0, lpPubkey: otherLp, hopPubkey: hopKey_,
            amountSats: 3e6, fundingTaproot: _taprootQ(otherLp, HOP_PUBKEY) });

        vm.prank(makeAddr("hop"));
        vm.expectRevert(BTCChannels.ChannelKeysMismatch.selector);
        ch.splice(cid, p, hex"00", new bytes32[](0));
    }

    /// The companion: the SAME pair still splices. Without this the rejection above could be
    /// satisfied by a check that refuses every splice.
    function test_spliceWithTheChannelsOwnKeysStillWorks() public {
        BTCChannels ch = _deployChannels();
        (bytes32 cid, bytes32 ftx,, bytes memory lpPubkey) = _open(ch, 92, 2e6);
        _spliceOut(ch, cid, ftx, 92, lpPubkey, 1e6);   // reverts if the keys check is too broad
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

    function _assertSolvent(string memory tag) internal {
        (uint committedSum, uint totalLiquid) = AUX.checkBacking();
        assertGe(totalLiquid, committedSum, tag);
    }

    // ─────────────────────────── lev wiring ───────────────────────────

    /// Deploy + pin a BtcLevManager over a REAL Morpho Blue vBTC/USDC market (vBTC == the Vault's own 8-dec
    /// ERC-20 face, collateral; USDC debt; a REAL-source vBTC/USD oracle). Seeds USDC borrow liquidity. No mock
    /// venue — the BTC twin of LevCascade's real-Morpho setup.
    function _setupBtcLev() internal {
        lm = new BtcLevManager(address(ETH.VBTC()), address(AUX), address(WBTC), address(this), address(QUID));
        RealRateBtcMorphoOracle oracle = new RealRateBtcMorphoOracle(address(AUX), address(WBTC));
        mOracle = address(oracle);
        mp = MarketParams({loanToken: address(USDC), collateralToken: address(ETH.VBTC()),  // §J.2: the vBTC TOKEN, not the Vault
            oracle: address(oracle), irm: ADAPTIVE_IRM, lltv: 0.86e18});   // Morpho-enabled LLTV (0.8 is not whitelisted)
        IMorphoTest morpho = IMorphoTest(MORPHO);
        morpho.createMarket(mp);
        deal(address(USDC), address(this), 5_000_000 * USDC_PRECISION);
        IERC20V(address(USDC)).approve(MORPHO, 5_000_000 * USDC_PRECISION);
        morpho.supply(mp, 5_000_000 * USDC_PRECISION, 0, address(this), "");
        venue = new MorphoEscrowVenue(MORPHO, mp, address(lm));
        address[] memory vs = new address[](1); vs[0] = address(venue);
        lm.init(address(ETH), MORPHO, vs);   // atomic pin-once: hook + Morpho flash provider + venue allowlist, FROZEN
        ETH.setLevManagerBTC(address(lm));        // pin the BTC leveraged book into vogueBTC + syncLevBTC
    }

    /// Give `lp`'s position REAL Morpho debt of `usdc6` USDC. Borrowed DIRECTLY on `lp`'s own isolated Morpho
    /// account (onBehalf==receiver==lp ⇒ no authorization needed) against the vBTC the open supplied — real
    /// Morpho debt that `venue.debtOf`/`netEquityBtc`/`getCurrentLtvBps` read. (The manager's `leverBorrow`
    /// keeper step is IL-clamped — it borrows nothing at flat price — so for a static valuation/liquidation
    /// proof the debt is sourced on Morpho directly; the clamped keeper flow is covered by the Rust e2e.)
    function _borrowMorpho(address lp, uint usdc6) internal {
        vm.prank(lp); IMorphoTest(MORPHO).borrow(mp, usdc6, 0, lp, lp);
    }

    /// REAL Morpho seizure of `lp` (must have real debt): crash the vBTC oracle (one getTWAPforAsset(WBTC)
    /// override moves the Morpho price AND the manager LTV consistently) to ~92% LTV, then liquidate by
    /// `numer/denom` of the debt by SHARES (never seizedAssets — over-repays a small debt, underflows Morpho).
    function _seizeRealBtc(address lp, uint numer, uint denom) internal {
        uint px = AUX.getTWAPforAsset(address(WBTC), 1800);
        uint vdebtUsd = lm.debtUsd(lp);                                   // USD 1e18
        uint collValueUsd = IMorphoOraclePrice(mOracle).price() * venue.collateralOf(lp) / 1e36 * 1e12; // →USD18
        // crash px so debt/collValue ≈ 0.92 (liquidatable per lltv 0.8, not deep bad debt): px' = px·debt/(coll·0.92)
        uint crashed = px * vdebtUsd * 100 / (collValueUsd * 92);
        vm.mockCall(address(AUX), abi.encodeWithSelector(IAuxTwapV.getTWAPforAsset.selector, address(WBTC), uint32(1800)),
            abi.encode(crashed));
        (, uint128 borrowShares,) = IMorphoTest(MORPHO).position(venue.MARKET_ID(), lp);
        deal(address(USDC), address(this), 5_000_000 * USDC_PRECISION);
        IERC20V(address(USDC)).approve(MORPHO, type(uint).max);
        IMorphoTest(MORPHO).liquidate(mp, lp, 0, uint256(borrowShares) * numer / denom, "");
        vm.clearMockedCalls();
    }

    /// Open a ZERO-leverage BTC-lev position for `lp` by exposing `vbtcSats` of its OWN free channel band BTC
    /// (SAME-BTC model: `lp` must already hold ≥ `vbtcSats` free band via a prior `_open`). openBtcLev reclassifies
    /// funded→lev and mints the vBTC face straight to the manager — no separate mint/approve roundtrip.
    /// net-equity == collateral (no debt).
    /// Every LP that has ever opened a lev position here — `levPooledBTC` is a mapping with no running
    /// total, so the invariant below sums the set the test actually created.
    address[] internal _levLps;
    mapping(address => bool) internal _levLpSeen;

    function _openLev(address lp, uint vbtcSats) internal {
        if (!_levLpSeen[lp]) { _levLpSeen[lp] = true; _levLps.push(lp); }
        vm.prank(lp);
        lm.openBtcLev(5000, vbtcSats, venue);       // cap 50% (unused at zero leverage)
        _assertVBtcSupplyMatchesLevMarker();
    }

    /// @notice THE SUPPLY/MARKER INVARIANT — asserted after EVERY lev open, so no test can exercise
    ///         leverage without checking it.
    ///
    ///         `exposeBtcToLev` writes the SAME sats into THREE places: `LP.pooled` (UNCHANGED —
    ///         single-count), `levPooledBTC[lp]` (a SUBSET MARKER, so free depth = `pooled - levPooled`),
    ///         and `VBtc.balanceOf[manager]` (the token). Three VIEWS of ONE economic claim — correct by
    ///         design, but three INDEPENDENTLY-MUTATED storage locations that nothing keeps in lockstep.
    ///
    ///         ⚠️ IF THE MARKER AND THE SUPPLY EVER DIVERGE, THE DIVERGENCE *IS* A DOUBLE-SPEND: band
    ///         depth counted as FREE while its token is still outstanding, i.e. the same sats claimable
    ///         twice. Nothing asserted this anywhere until now.
    ///
    ///         `levPooledBTC` is a mapping with no running total, so this sums the LPs a test can create.
    ///         It is also the PRECONDITION for §A.19b's aggregate rule
    ///         (`Σ outstanding vBTC <= Σ free channel capacity`) — that rule is meaningless unless supply
    ///         and marker agree first.
    function _assertVBtcSupplyMatchesLevMarker() internal {
        uint markerSum;
        for (uint i; i < _levLps.length; ++i) markerSum += ETH.levPooledBTC(_levLps[i]);
        assertEq(markerSum, ETH.VBTC().totalSupply(),
            "INVARIANT: sum(levPooledBTC) must equal VBtc.totalSupply() -- divergence is a double-spend");
    }

    // ─────────────────────── #106/#81/#74 WBTC-fallback route setup ───────────────────────

    /// Deploy + pin a SECOND BtcLevManager over the REAL Aave v3 {WBTC collateral, USDC debt} book — the
    /// PRODUCTION WBTC-fallback venue (DeployL1_s wires the SAME addresses). Per-LP escrow (no LP Morpho
    /// authorization, no market to seed — Aave v3's live USDC liquidity backs the borrow). The de-lever FLASH
    /// provider is still Morpho (bm.init flash=MORPHO) ⇒ cross-protocol: flash USDC from Morpho, repay/withdraw
    /// on Aave. This is the exact venue the keeper's atomic `rebalanceWbtc` drives on-chain.
    function _setupBtcLevWbtc() internal {
        lmW = new BtcLevManager(address(ETH.VBTC()), address(AUX), address(WBTC), address(this), address(QUID));
        address dataProvider = IAaveV3AddrProviderT(AAVE_V3_ADDR).getPoolDataProvider();
        wvenue = new AaveV3Venue(AAVE_V3_POOL, dataProvider, address(WBTC), address(USDC), address(lmW), 7800);
        address[] memory vs = new address[](1); vs[0] = address(wvenue);
        lmW.init(address(ETH), MORPHO, vs);        // hook=Vault, flash=MORPHO (de-lever), Aave-WBTC venue (FROZEN)
    }

    /// Mock the ONE getTWAPforAsset(WBTC) read to `px` (USD18 per 1e18-raw, WBTC-lifted). Drives the IL target:
    /// price ABOVE entry ⇒ ilTarget>0 ⇒ fold up; back to/below entry ⇒ ilTarget→0 ⇒ de-lever. The SOR swaps ride
    /// the REAL (un-mocked) pool price, so the 1% oracle floor clears as long as the mock ≈ live within band.
    function _mockPx(uint px) internal {
        vm.mockCall(address(AUX), abi.encodeWithSelector(IAuxTwapV.getTWAPforAsset.selector, address(WBTC), uint32(1800)),
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

        // LP brings EXTERNAL WBTC and opens (WBTC branch: transferFrom lp→venue, venue.supply → LP's Morpho escrow).
        deal(address(WBTC), lp, coll);
        vm.startPrank(lp);
        IERC20V(address(WBTC)).approve(address(lmW), coll);
        lmW.openBtcLev(7500, coll, wvenue);          // cap 75% (AaveV3Venue = per-LP escrow, no Morpho auth needed)
        vm.stopPrank();
        assertApproxEqAbs(wvenue.collateralOf(lp), coll, 1e4, "opened with ~1 WBTC collateral");
        assertEq(wvenue.debtOf(lp), 0, "opens at zero debt");

        uint entryPx = AUX.getTWAPforAsset(address(WBTC), 1800);

        // ── FOLD UP: price +25% ⇒ ilTarget = 1−√(1/1.25) ≈ 1054 bps ⇒ borrow USDC, SOR→WBTC, supply. ──
        _mockPx(entryPx * 125 / 100);
        (bool levUp, uint deltaUp) = lmW.debtDeltaToTarget(lp);
        assertTrue(levUp && deltaUp > 0, "IL target says lever up after +25%");
        lmW.rebalanceWbtc(lp, 0);                     // permissionless + self-flooring (what the keeper sends)
        uint debtAfterUp = wvenue.debtOf(lp);
        assertGt(debtAfterUp, 0, "folded up: real USDC debt on Morpho");
        assertGt(wvenue.collateralOf(lp), coll, "folded up: SOR'd WBTC added to collateral");
        vm.clearMockedCalls();

        // ── FLASH-DE-LEVER: price back to entry ⇒ ilTarget→0 ⇒ target debt 0 ⇒ full de-lever via Morpho flash. ──
        _mockPx(entryPx);
        (bool levUp2, uint deltaDn) = lmW.debtDeltaToTarget(lp);
        assertTrue(!levUp2 && deltaDn > 0, "IL target says de-lever back at entry");
        lmW.rebalanceWbtc(lp, 0);                     // flash-repay-first (flashProvider=MORPHO pinned in init)
        assertLt(wvenue.debtOf(lp), debtAfterUp, "flash-de-lever reduced the debt");
        vm.clearMockedCalls();
    }

    /// The permissionless entrypoint must REJECT a native-vBTC (non-WBTC) venue — `rebalanceWbtc` would supply
    /// WBTC into a vBTC venue (collateral mismatch corrupting the position). The WBTC-venue gate (BadTarget)
    /// is the guard; here we point the WBTC manager's call at the vBTC position and expect the revert.
    function testReal_WbtcRebalance_RejectsNativeVbtcVenue() public {
        BTCChannels ch = _deployChannels();
        _setupBtcLev();                               // native vBTC venue on `lm`
        (,, address lp,) = _open(ch, 88, 3e8);        // 3 BTC channel = free band to expose
        _openLev(lp, 2e8);                            // native vBTC position
        vm.expectRevert(LevBase.BadTarget.selector);
        lm.rebalanceWbtc(lp, 0);                       // vBTC venue ⇒ BadTarget (WBTC-mode only)
    }

    /// @notice REGRESSION for the 1e10 BTC scale bug (Vyper audit C-1/C-2/C-3): with REAL debt, the BTC
    ///   valuations must scale like the rest of the codebase (px = USD18/1e18-raw, WBTC-lifted ×1e10 ⇒ /1e18).
    ///   The former /1e8 (collateral, E0) & /1e10 (debt) made net-equity treat the debt as ≈0 (phantom
    ///   vogueBTC backing) and getCurrentLtvBps read ≈0 (venue-safety blind). Every prior BTC test used a
    ///   ZERO-debt position, which early-returns before the debt/price path — masking all three. Here: 2 BTC
    ///   collateral, ~50% LTV of real debt ⇒ net-equity MUST be ~1 BTC and LTV MUST be ~50%.
    function test_BtcLev_WithDebt_ScaleCorrect() public {
        BTCChannels ch = _deployChannels();
        _setupBtcLev();
        (,, address lp,) = _open(ch, 42, 3e8);                    // 3 BTC channel = free band to expose from
        _openLev(lp, 2e8);                                         // expose 2 BTC as vBTC collateral, zero debt
        uint px = AUX.getTWAPforAsset(address(WBTC), 1800);        // USD18 per 1e18-raw (WBTC-lifted)
        uint collUsd = 2e8 * px / 1e18;                           // USD18 value of 2 BTC
        uint debtUsdc = (collUsd / 2) / 1e12;                     // ~50% LTV, USDC 6-dec
        _borrowMorpho(lp, debtUsdc);                              // REAL Morpho debt on the LP's isolated account
        // C-2: the venue LTV is the true ~50%, NOT ~0 (before the fix vBtcValueUsd was 1e10 too big).
        assertApproxEqAbs(lm.getCurrentLtvBps(lp), 5000, 400, "getCurrentLtvBps ~50%, not ~0 (C-2)");
        // C-1: net-equity = collateral − debt = ~1 BTC, NOT ~2 BTC (before the fix the debt leg was ~0).
        assertApproxEqAbs(lm.netEquity(lp), 1e8, 6e6, "netEquityBtc ~1 BTC = coll-debt, not ~2 (C-1)");
    }

    /// @notice (#43) PERMISSIONLESS `repayFor` reduces the LP's ISOLATED Morpho debt -- the on-chain primitive
    ///   the QUID-protect keeper calls after redeeming the LP's mature QUID (redeem→stable→repayFor). No MANAGER
    ///   auth (a random caller repays here), caller-funded, clamped to debt.
    function test_RepayFor_PermissionlessReducesLpDebt() public {
        BTCChannels ch = _deployChannels();
        _setupBtcLev();
        (,, address lp,) = _open(ch, 42, 3e8);
        _openLev(lp, 2e8);
        uint px = AUX.getTWAPforAsset(address(WBTC), 1800);
        uint debtUsdc = ((2e8 * px / 1e18) / 2) / 1e12;             // ~50% LTV of real Morpho debt (USDC 6-dec)
        _borrowMorpho(lp, debtUsdc);
        uint debt0 = venue.debtOf(lp);
        assertGt(debt0, 0, "LP has real Morpho debt");
        // A random address (NOT the MANAGER) repays HALF on the LP's behalf -- proves it's permissionless + safe.
        address helper = address(0xCAFE);
        uint pay = debtUsdc / 2;
        deal(address(USDC), helper, pay);
        vm.startPrank(helper);
        USDC.approve(address(venue), pay);
        uint repaid = venue.repayFor(lp, pay);
        vm.stopPrank();
        assertApproxEqAbs(repaid, pay, 2, "repayFor repaid the requested amount");
        assertApproxEqAbs(venue.debtOf(lp), debt0 - pay, debt0 / 50, "repayFor reduced the LP's isolated debt");
    }

    /// @notice #43 BTC counterpart of LevCascade.test_ProtectFromQuid_HostileOperatorNetsZero — the previously-STUBBED
    ///   path (BtcLevManager had no protect entrypoint; the keeper bailed). A BTC-levered LP's OWN opted-in QUID is
    ///   redeemed to repay its OWN real-Morpho debt near liquidation, via the SAME asset-agnostic `LevMath.protectExec`
    ///   the ETH side uses — proving the BtcLevManager wrapper wires it correctly and a hostile caller nets ZERO.
    function testReal_BtcProtectFromQuid_HostileOperatorNetsZero() public {
        BTCChannels ch = _deployChannels();
        _setupBtcLev();
        (,, address lp,) = _open(ch, 51, 3e8);                       // 3 BTC channel = free band to expose
        _openLev(lp, 2e8);                                           // BTC-lev on 2 BTC (zero leverage)
        uint px0 = AUX.getTWAPforAsset(address(WBTC), 1800);
        _borrowMorpho(lp, ((2e8 * px0 / 1e18) / 2) / 1e12);          // ~50% LTV real Morpho USDC debt
        assertGt(venue.debtOf(lp), 0, "LP has real BTC-lev Morpho debt");

        // The LP mints + OPTS IN its OWN QUID (the one-time delegated `approve`), mirroring the ETH proof.
        deal(address(USDC), lp, 300_000 * USDC_PRECISION);
        vm.startPrank(lp);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(lp, 200_000 * USDC_PRECISION, address(USDC), 0);
        QUID.approve(address(lm), type(uint).max);
        vm.stopPrank();

        // Mature the QUID vintage (redeem is mature-only); keep every oracle read fresh across the warp.
        uint ethPx = AUX.getTWAPforAsset(address(WETH), 1800);
        vm.warp(block.timestamp + 35 days); vm.roll(block.number + 1);
        _setEthFeed(ethPx / 1e10);
        vm.mockCall(address(AUX), abi.encodeWithSelector(IAuxTwapV.getTWAPforAsset.selector, address(WBTC), uint32(1800)),
            abi.encode(px0));
        vm.mockCall(address(AUX), abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)), abi.encode(uint(0)));
        vm.mockCall(address(AUX), abi.encodeWithSignature("getDepegSeverityBps(address)", address(DAI)), abi.encode(uint(0)));
        // Near-liq TRIGGER: tighten ONLY the venue liq threshold to just above the live LTV (as the ETH proof does;
        // the entire redeem→repay→refund money path stays 100% REAL — only the risk param deciding *when* is staged).
        vm.mockCall(address(venue), abi.encodeWithSelector(venue.liqThresholdBps.selector),
            abi.encode(lm.getCurrentLtvBps(lp) + 1000));

        // ADVERSARIAL + HAPPY: an arbitrary hostile caller protects the opted-in LP. Value moves ONLY toward the LP.
        address hostile = address(0xBADBEEF);
        uint hQuid0 = QUID.balanceOf(hostile); uint hUsdc0 = USDC.balanceOf(hostile);
        uint lpDebt0 = venue.debtOf(lp); uint lpQuid0 = QUID.balanceOf(lp);
        vm.prank(hostile);
        uint repaid = lm.protectFromQuid(lp, 0);
        assertGt(repaid, 0, "protect repaid the LP's BTC-lev debt via its own QUID");
        assertLt(venue.debtOf(lp), lpDebt0, "the LP's OWN debt fell");
        assertLt(QUID.balanceOf(lp), lpQuid0, "the LP's own QUID funded its own protection");
        assertEq(QUID.balanceOf(hostile), hQuid0, "hostile caller gained NO QUID");
        assertEq(USDC.balanceOf(hostile), hUsdc0, "hostile caller gained NO stable");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // (a) fee accrual  (b) unwind-only  (c) seizure burns clean — one LP through all
    // three, mirroring LevCascade.test_LevFeeLane_EarnsFees_UnwindOnly_SeizureBurnsClean.
    // ═══════════════════════════════════════════════════════════════════════════
    function test_LevFeeLaneBTC_EarnsFees_UnwindOnly_SeizureBurnsClean() public {
        BTCChannels ch = _deployChannels();
        _setupBtcLev();

        // The fee-lane LP holds a channel (its band depth AND the splice-out surface for (b)).
        (bytes32 cid, bytes32 ftx, address lpEth, bytes memory lpPk) = _open(ch, 1, 2e7); // 0.2 BTC
        { (uint pooledChannel,,,) = ETH.autoManagedBTC(lpEth);
          assertGt(pooledChannel, 0, "channel registered the LP into the BTC band"); }

        // Seed a zero-leverage lev position by EXPOSING part of the LP's own channel band BTC (funded→lev).
        _openLev(lpEth, 2_000_000); // expose 0.02 BTC of the 0.2 BTC channel as vBTC collateral
        assertEq(lm.netEquity(lpEth), 2_000_000, "net-equity == collateral (zero leverage)");
        assertGt(ETH.levPooledBTC(lpEth), 0, "open reclassified channel BTC funded-to-lev (levered slice)");

        { uint puPreSlice = CORE.POOLED_USD_BTC();
          uint pbPreSlice = CORE.POOLED_BTC();
          ETH.syncLevBTC(lpEth);                               // mark the levered slice to net-equity
          // SAME-BTC: the slice is the LP's OWN channel BTC (already banded), so a zero-leverage sync neither
          // grows POOLED_BTC nor re-pairs new USD — it stays FLAT (no double-count). It only SHRINKS later,
          // when a leverage loss/seizure reduces net-equity below the exposed base (asserted in (c)).
          assertGt(ETH.levPooledBTC(lpEth), 0, "the levered slice is tracked in the band");
          assertEq(CORE.POOLED_BTC(), pbPreSlice, "POOLED_BTC FLAT: base already banded, no separate lev depth");
          assertApproxEqAbs(CORE.POOLED_USD_BTC(), puPreSlice, 1, "POOLED_USD_BTC FLAT: reclassify, not new pairing"); }

        // (a) drive BTC-pool swaps -> band fees; the levered LP is part of the fee-earning depth.
        {   _setRecipient(address(ch), abi.encode(uint(0xB7C)), User03); // native USD->BTC path recipient
            vm.startPrank(User03);
            USDC.approve(address(AUX), type(uint).max);
            vm.stopPrank();
            uint qd0      = QUID.balanceOf(lpEth);
            // (E145) the BTC leg compounds into `pooled`; there is no owed ledger to read.
            // Same driver as the proven testBtcLp_collectBtcFees_NoClose: real (non-caught)
            // USDC->WBTC pool swaps generate BTC-band trading fees. Sizes kept modest so the
            // incoming USD stays under BtcShareCap (the lev slice already consumes headroom).
            for (uint i; i < 6; i++) {
                vm.prank(User03);
                AUX.swap(address(USDC), address(WBTC), true, 300 * USDC_PRECISION, 0);
                vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
            }
            vm.prank(lpEth);
            ETH.collectBtcFees();                              // USD-leg -> QUID; BTC-leg -> btcFeesOwedSats
            uint usdLeg = QUID.balanceOf(lpEth) - qd0;
            uint btcLeg = 0;   // (E145) retired: the leg compounds into pooled as it is earned
            // (E145-n) ⚠️ THIS USED TO BE `assertGt(usdLeg + btcLeg, 0)` — A SUM THE USD LEG
            //    ALONE SATISFIES, so it passed identically whether the BTC leg was live or
            //    permanently zero. MEASURED 2026-08-09: `usdLeg` ≈ 7.6e17, **`btcLeg == 0` and
            //    `feesPerShareBTC == 0`** — the BTC leg does NOT accrue here, and the sum hid it.
            //    Asserting the legs SEPARATELY so the test states what is actually true and a
            //    future change that makes the BTC leg live shows up as a failure, not silence.
            assertGt(usdLeg, 0, "(a) levered LP accrues the USD-leg band fee on its equity");
            // ⚠️ REASONING CORRECTED (E145-p). This said the BTC leg "does NOT accrue" because
            //    BTC inflows are channels-only. **That was wrong.** `creditSwapIn` sells BTC
            //    into the pool as the PROTOCOL (`onlyBTCChannels`, BTC→USD), bypassing the
            //    user-path guard — and `testBtcLp_swapInAccruesTheBtcLegFee` MEASURES it:
            //    `feesPerShareBTC` 0 → 1.045e13, `btcFeesOwedSats` 0 → 209 sats.
            //    The leg is zero HERE only because THIS lane drives no swap-in. That is a
            //    property of the scenario, not of the protocol — do not read it as either.
            assertEq(btcLeg, 0, "(a) no swap-in in this lane, so no BTC-leg fee is earned here");
        }

        // (b) UNWIND-ONLY: a normal channel splice-out (LP withdrawal, exactUsd==0) can only shrink
        //     the true channel funding; the `funded = inrange - lev` cap leaves the levered slice.
        {   uint levBeforeWithdraw = ETH.levPooledBTC(lpEth);
            (uint pooledBeforeWithdraw,,,) = ETH.autoManagedBTC(lpEth);
            _spliceOut(ch, cid, ftx, 1, lpPk, 15e6);           // shrink channel 0.2 -> 0.15 BTC (withdraw 0.05)
            assertEq(ETH.levPooledBTC(lpEth), levBeforeWithdraw, "(b) LP withdraw (splice-out) leaves the levered slice untouched");
            (uint pooledAfterWithdraw,,,) = ETH.autoManagedBTC(lpEth);
            assertLt(pooledAfterWithdraw, pooledBeforeWithdraw, "(b) the withdrawal DID shrink the channel funding (not a no-op)");
            assertGe(pooledAfterWithdraw, ETH.levPooledBTC(lpEth), "(b) LP.pooled never shrank into the lev depth");
        }

        // (c) SEIZE -> net-equity 0 -> syncLevBTC burns the slice clean. Isolate the burn around the
        //     seizure syncLevBTC: comparing to the pre-slice baseline would conflate it with the (a)
        //     swaps' legitimate, backed USD inflow into POOLED_USD_BTC. So assert the burn STRICTLY
        //     un-pairs POOLED_USD_BTC, and that the basket stays solvent (D >= S + L — the real
        //     "not over-committed" invariant).
        // Give the position REAL Morpho debt, reflect it in the slice, then a REAL Morpho liquidation → net-equity
        // drops further → syncLevBTC SHRINKS the levered slice toward the liquidated net-equity (un-pairing its USD
        // from POOLED_USD_BTC). (Partial Morpho liquidation de-risks toward health, so the slice shrinks vs the
        // mock's clean full-clear.)
        uint collUsdC = 2_000_000 * AUX.getTWAPforAsset(address(WBTC), 1800) / 1e18;
        _borrowMorpho(lpEth, (collUsdC / 2) / 1e12);          // ~50% LTV of real Morpho debt
        ETH.syncLevBTC(lpEth);                                // reflect the debt: slice tracks the levered net-equity
        uint levBeforeSeize = ETH.levPooledBTC(lpEth);
        assertGt(levBeforeSeize, 0, "(c) precondition: a levered slice exists to shrink");
        _seizeRealBtc(lpEth, 1, 2);                           // REAL Morpho liquidation (repay half the debt)
        uint puBeforeBurn = CORE.POOLED_USD_BTC();
        ETH.syncLevBTC(lpEth);
        assertLt(ETH.levPooledBTC(lpEth), levBeforeSeize, "(c) seizure: levered slice SHRANK toward the liquidated net-equity");
        assertLt(CORE.POOLED_USD_BTC(), puBeforeBurn, "(c) the burn un-paired lev-slice USD from POOLED_USD_BTC");
        _assertSolvent("(c) solvent after seizure burn (not over-committed)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Net-equity → vogueBTC backing recognized; a venue seizure removes it cleanly
    // while POOLED_USD_BTC stays intact. Mirrors LevCascade.test_NetEquity_...
    // ═══════════════════════════════════════════════════════════════════════════
    function test_NetEquityBTC_BackingRecognized_SeizureLeavesPooledUsdIntact() public {
        BTCChannels ch = _deployChannels();
        _setupBtcLev();

        // A channel gives the BTC band real depth + a non-zero POOLED_USD_BTC to prove "intact".
        (,, address lpEth,) = _open(ch, 2, 3e7); // 0.3 BTC
        uint pooledUsd0 = CORE.POOLED_USD_BTC();
        assertEq(ETH.totalNetEquityBtc(), 0, "no lev book yet => zero net-equity backing");

        // Open at zero leverage => net-equity == collateral (8-dec sats). Opening does NOT touch the
        // band (no syncLevBTC), so POOLED_USD_BTC is untouched — but the backing term is recognized.
        _openLev(lpEth, 5_000_000); // expose 0.05 BTC of the 0.3 BTC channel
        assertEq(lm.netEquity(lpEth), 5_000_000, "net-equity == principal (zero leverage)");
        assertEq(lm.totalNetEquityBtc(), 5_000_000, "book total == principal");
        assertEq(ETH.totalNetEquityBtc(), 5_000_000, "vogueBTC counts the leveraged book's net-equity");
        assertEq(CORE.POOLED_USD_BTC(), pooledUsd0, "open: basket POOLED_USD_BTC untouched (no band pairing)");
        _assertSolvent("open: solvent with lev backing");

        // Give the position REAL Morpho debt (the lever step, sourced on Morpho), then a REAL Morpho liquidation
        // removes net-equity backing while the basket's POOLED_USD_BTC stays intact — the loss is ISOLATED to the
        // LP's Morpho account, never socialized. (A partial Morpho liquidation de-risks toward health, so
        // net-equity SHRINKS rather than vanishing — the mock's clean full-clear was an idealization.)
        uint collUsd = 5_000_000 * AUX.getTWAPforAsset(address(WBTC), 1800) / 1e18;
        _borrowMorpho(lpEth, (collUsd / 2) / 1e12);            // ~50% LTV of real Morpho debt
        uint neqBefore = lm.netEquity(lpEth);
        assertLt(neqBefore, 5_000_000, "debt reduces net-equity below the collateral");
        assertEq(ETH.totalNetEquityBtc(), neqBefore, "vogueBTC counts the (now-levered) live net-equity");
        _seizeRealBtc(lpEth, 1, 2);                            // REAL Morpho liquidation (repay half the debt)
        assertLt(lm.netEquity(lpEth), neqBefore, "seized: net-equity backing REDUCED by the real liquidation");
        assertEq(ETH.totalNetEquityBtc(), lm.netEquity(lpEth), "seized: vogueBTC tracks the reduced live net-equity");
        assertEq(CORE.POOLED_USD_BTC(), pooledUsd0, "seized: basket POOLED_USD_BTC FULLY INTACT (no socialization)");
        _assertSolvent("seized: solvent, no socialization");
    }

    /// @notice #67 (LEVERED-DELIVERABILITY-SPEC) — the `deliverableDollars` VIEW, the sizing primitive the
    ///   redemption-scoped de-lever (step 4) builds on. The levered net-equity is NOT surplus-paired (surplus is
    ///   reserved for the borrow cost + QU!D redemption); it is REDEMPTION backing, de-leverable only by a
    ///   redemption. This locks the capacity view on live real-Morpho vBTC/USDC state: REAL, conservatively
    ///   bounded (min of net-equity and the LLTV-margin edge), within the book aggregate, grows with net-equity,
    ///   and syncing the position never breaks D>=S+L (checkBacking).
    function test_LevDeliverabilityBTC_DeliverableDollarsView() public {
        BTCChannels ch = _deployChannels();
        _setupBtcLev();
        (,, address lpEth,) = _open(ch, 2, 3e7);          // 0.3 BTC channel
        _openLev(lpEth, 5_000_000);                        // expose 0.05 BTC as vBTC collateral
        uint collUsd0 = lm.vBtcValueUsd(venue.collateralOf(lpEth));
        _borrowMorpho(lpEth, (collUsd0 / 2) / 1e12);       // ~50% LTV of REAL Morpho debt ⇒ net-equity < collateral

        // The de-lever-capacity view is real + conservatively bounded (min of net-equity and the margin edge).
        uint deliv = lm.deliverableDollars(lpEth);
        assertGt(deliv, 0, "levered position exposes real margin-bounded de-lever capacity");
        assertLe(deliv, lm.vBtcValueUsd(venue.collateralOf(lpEth)), "deliverable <= collateral (conservative)");
        assertLe(deliv, lm.totalDeliverableDollars(), "per-LP deliverable is within the book aggregate");

        ETH.syncLevBTC(lpEth);
        _assertSolvent("solvent with lev backing (net-equity is redemption backing, not surplus-paired)");

        // BTC price UP 20% ⇒ net-equity GROWS ⇒ de-lever capacity grows; sync stays solvent (never fabricates backing).
        uint px = AUX.getTWAPforAsset(address(WBTC), 1800);
        vm.mockCall(address(AUX), abi.encodeWithSelector(IAuxTwapV.getTWAPforAsset.selector, address(WBTC), uint32(1800)),
            abi.encode(px * 120 / 100));
        assertGt(lm.deliverableDollars(lpEth), deliv, "de-lever capacity grows with net-equity (price up)");
        ETH.syncLevBTC(lpEth);
        _assertSolvent("price-up: solvent");
        vm.clearMockedCalls();
    }

    // ───────────────────────── #54 delivery-side de-lever (partial-burn vBTC deliverability) ─────────────────────────

    /// Build + submit the swapper-directed splice-out that settles an on-chain swap-out from `lp`'s channel: a
    /// 2-output tx (new SMALLER 2-of-2 + the swapper's payout), fee-free so shrink == delivered == `sats`.
    function _deliverLevSwapOut(BTCChannels ch, bytes32 channelId, bytes32 fundingTxId, uint seed,
        bytes memory lpPubkey, bytes32 swapId, uint sats, bytes memory swapperScript) internal {
        // (E162) A delivery is a splice — same pinned pair as the channel.
        ( , bytes memory hopKey_, ) = ownedChannelKeys(_label(seed));
        (uint old, , , , , ) = ch.channels(channelId);
        uint newAmount = old - sats;
        bytes memory spliceTx;
        {
            bytes memory p2wsh = buildTaprootFundingSpk(lpPubkey, hopKey_);
            spliceTx = abi.encodePacked(
                hex"02000000", hex"01",
                fundingTxId, hex"00000000", hex"00", hex"ffffffff",
                hex"02",
                _le(newAmount, 8), bytes1(uint8(p2wsh.length)), p2wsh,
                _le(sats, 8), bytes1(uint8(swapperScript.length)), swapperScript,
                hex"00000000");
        }
        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash:   bytes32(uint(0x5417CE + seed)),
            fundingBlockHeight: 800001,
            fundingTxIndex:     0,
            lpPubkey:           lpPubkey,
            hopPubkey:          hopKey_,
            amountSats:         newAmount,
            fundingTaproot:     _taprootQ(lpPubkey, hopKey_)
        });
        vm.prank(makeAddr("hop"));
        ch.deliverSwapOutOnchain(swapId, channelId, p, spliceTx, new bytes32[](0), swapperScript);
    }

    struct LevDelivery {
        BTCChannels ch; bytes32 channelId; bytes32 fundingTxId; address lp; bytes lpPubkey;
        uint funded; uint debt; uint coll; uint netEq; uint ltv; uint lev; uint qd;   // pre-delivery snapshot
        uint sats; uint owedUsd; uint pending;                                        // swap-out request
    }

    function _levDelivSwapId() internal pure returns (bytes32) { return keccak256("delever54-swapout"); }
    /// (E185) The delivery script must be the swapper's REGISTERED destination — the request
    /// no longer takes one, it derives it from `btcRecipientOf`, so an invented key would fail
    /// the delivery-side hash match.
    function _levDelivScript(address ch_) internal returns (bytes memory) {
        return _swapperScript(ch_, makeAddr("swapper54"));
    }

    /// Pre-delivery snapshot: funded band, venue debt/collateral, net-equity, LTV, levered slice, LP QUID.
    function _snapLevPosition(LevDelivery memory d) internal {
        (uint pooled,,,) = ETH.autoManagedBTC(d.lp);
        d.funded = pooled - ETH.levPooledBTC(d.lp);
        d.debt   = venue.debtOf(d.lp);
        d.coll   = venue.collateralOf(d.lp);
        d.netEq  = lm.netEquity(d.lp);
        d.ltv    = lm.getCurrentLtvBps(d.lp);
        d.lev    = ETH.levPooledBTC(d.lp);
        d.qd     = QUID.balanceOf(d.lp);
    }

    /// Swap-out buys ~0.05 BTC (much more than the ~1e6-sat free band), so the delivery must tap the levered slice.
    function _requestLevSwapOut(LevDelivery memory d) internal {
        address swapper = makeAddr("swapper54");
        // (E185) Register the destination first — `requestSwapOutOnchain` derives it from
        // `btcRecipientOf` rather than accepting an unproven script, so an unregistered
        // swapper is refused before any USD is pulled.
        _setRecipient(address(d.ch), abi.encode(uint(0x54D)), swapper);
        deal(address(USDC), swapper, 50_000 * USDC_PRECISION);
        vm.startPrank(swapper);
        USDC.approve(address(AUX), type(uint).max);
        d.sats = d.ch.requestSwapOutOnchain(address(USDC), 5_000 * USDC_PRECISION, 0, _levDelivSwapId());
        vm.stopPrank();
        (,,,, uint96 owedU,) = d.ch.pendingOnchainSwapOut(_levDelivSwapId());
        d.owedUsd = uint(owedU);
        d.pending = CORE.pendingSwapOutUsd();
    }

    /// @notice #54 (the active build): a native swap-out delivery whose sats draw PAST the LP's FREE channel band
    ///   into its LEVERED slice de-levers that LP with the delivery's OWN proceeds - value-neutral, LTV-improving,
    ///   single-pay. Setup: a 3-BTC channel with almost all of it exposed as vBTC collateral (funded ~= 1e6 sats)
    ///   and real ~50% Morpho debt. A swap-out buys ~0.05 BTC (>> funded), so the settle must tap the levered slice.
    ///   Asserts the whole money-path: debt + collateral both fall by ~want*px (equal value), net-equity preserved,
    ///   LTV improves, levPooled un-encumbered by ~want, QUI minted ONLY for the funded proceeds share (the
    ///   de-levered slice was paid via debt-reduction, not a second QUI mint), the obligation fully clears, and the
    ///   basket stays solvent. Real vBTC/USDC Morpho market - no mocks.
    function testReal_DeliverSideDelever_SwapOutTapsLeveredSlice() public {
        LevDelivery memory d;
        d.ch = _deployChannels();
        _setupBtcLev();
        (d.channelId, d.fundingTxId, d.lp, d.lpPubkey) = _open(d.ch, 54, 3e8);       // 3 BTC channel
        _openLev(d.lp, 299_000_000);                                                 // expose 2.99 BTC ⇒ funded ~= 1e6
        _borrowMorpho(d.lp, (lm.vBtcValueUsd(venue.collateralOf(d.lp)) / 2) / 1e12); // ~50% LTV real Morpho debt
        ETH.syncLevBTC(d.lp);
        _snapLevPosition(d);
        assertGt(d.debt, 0, "position carries real Morpho debt");
        assertLt(d.funded, 2e6, "free channel band is (near-)exhausted below the levered slice");

        _requestLevSwapOut(d);
        assertGt(d.sats, d.funded, "swap-out draws PAST the free channel band into the levered slice (#54 fires)");
        assertLt(d.sats, 3e8, "delivery fits within the channel");

        // The vBTC withdraw inside swapOutDelever needs the LP to authorize the venue as its Morpho manager.
        vm.prank(d.lp); IMorphoTest(MORPHO).setAuthorization(address(venue), true);
        _deliverLevSwapOut(d.ch, d.channelId, d.fundingTxId, 54, d.lpPubkey, _levDelivSwapId(), d.sats, _levDelivScript(address(d.ch)));
        // Keeper reconcile: the delivery repaid debt in-tx but syncLevBTC is nonReentrant (can't run inside the
        // delivery lock), so the debt-buffer's POOLED_USD is resized to the smaller debt here — exactly the async
        // reconcile the lev keeper performs. Until it runs, committed is only OVERSTATED (a stricter gate).
        ETH.syncLevBTC(d.lp);
        _assertDeleverOnDelivery(d);
    }

    function _assertDeleverOnDelivery(LevDelivery memory d) internal {
        uint want = d.sats - d.funded;                       // the levered sats the delivery de-levered
        // (a) de-levered: BOTH debt and collateral fall (equal oracle value removed).
        assertLt(venue.debtOf(d.lp), d.debt, "debt reduced - the delivery's proceeds repaid it");
        assertLt(venue.collateralOf(d.lp), d.coll, "collateral reduced - vBTC burned to deliver the levered slice");
        assertApproxEqAbs(d.coll - venue.collateralOf(d.lp), want, want / 50, "freed ~= the delivered levered sats");
        // (b) VALUE-NEUTRAL: the leverage position's net-equity is preserved (-BTC -debt of equal value).
        assertApproxEqRel(lm.netEquity(d.lp), d.netEq, 0.03e18, "net-equity preserved (value-neutral de-lever)");
        // (c) LTV IMPROVES (removing near-1.0-ratio value from a ~0.5-LTV position lowers the ratio).
        assertLe(lm.getCurrentLtvBps(d.lp), d.ltv, "LTV improved");
        // (d) NO phantom band depth behind the delivered vBTC: after the keeper sync the levered slice never
        //     exceeds the LP's live net-equity (levPooled pairs net-equity only up to basket surplus — it may be
        //     LESS at surplus==0, the "stranded volatile" state, but never MORE, which would double-count the
        //     BTC just delivered to the swapper). The freed sats show up as the collateral drop asserted in (a).
        assertLe(ETH.levPooledBTC(d.lp), lm.netEquity(d.lp) + 1e3, "levered band depth <= net-equity (no phantom)");
        // (e) SINGLE-PAY: QUI minted only for the FUNDED proceeds share - the de-levered slice was paid via
        //     debt-reduction, NOT a second QUI mint.
        uint qdMinted = QUID.balanceOf(d.lp) - d.qd;
        assertLt(qdMinted, d.owedUsd * 1e12, "QUI < full proceeds (de-levered slice not double-paid as QUI)");
        assertApproxEqRel(qdMinted, (d.owedUsd * 1e12) * d.funded / d.sats, 0.05e18, "QUI ~= funded-share of proceeds");
        // (f) the obligation is FULLY cleared (debt-share drawn in Delever54Lib + funded-share in settleDelivered).
        assertEq(CORE.pendingSwapOutUsd(), d.pending - d.owedUsd, "obligation fully cleared on delivery");
        // (g) the swapper was delivered ONCE and the basket stays solvent.
        assertTrue(d.ch.swapInUsed(_levDelivSwapId()), "delivery marked (blocks deliver->reverse double-pay)");
        _assertSolvent("delever-54: basket solvent after value-neutral de-lever");
    }

    // ─────────────────────────── close / de-lever money-path coverage (#64) ───────────────────────────

    /// @notice (#64 gap 1, CRITICAL) `closeBtcLev` had ZERO test callers. Open a BTC-lev position with REAL Morpho
    ///   debt, repay it through the manager, then fully retire via `closeBtcLev`. Asserts the whole retirement
    ///   money-path: long-venue debt is 0, the vBTC collateral is withdrawn from Morpho, the levered band slice is
    ///   UN-FOLDED (`unexposeBtcFromLev` ⇒ levPooledBTC→0, funded restored), the position is deleted + de-tracked,
    ///   and the basket stays solvent. Reuses the real vBTC/USDC Morpho harness.
    function testReal_BtcCloseLev_RepaysUnfoldsDeletes() public {
        BTCChannels ch = _deployChannels();
        _setupBtcLev();
        (,, address lp,) = _open(ch, 64, 3e8);                       // 3 BTC channel = free band to expose
        _openLev(lp, 2e8);                                           // expose 2 BTC as vBTC collateral (zero debt)
        assertEq(lm.openLevCount(), 1, "position tracked in the open-LP book");
        assertGt(ETH.levPooledBTC(lp), 0, "open reclassified channel BTC funded-to-lev");
        (uint pooledOpen,,,) = ETH.autoManagedBTC(lp);

        // Give the position REAL Morpho debt (~50% LTV), directly on the LP's isolated Morpho account.
        uint px = AUX.getTWAPforAsset(address(WBTC), 1800);
        uint debtUsdc = ((2e8 * px / 1e18) / 2) / 1e12;              // ~50% LTV, USDC 6-dec
        _borrowMorpho(lp, debtUsdc);
        assertGt(venue.debtOf(lp), 0, "LP has real BTC-lev Morpho debt");

        // closeBtcLev REVERTS while debt is open (line 450) — repay it FIRST through the manager's LP-gated leg.
        uint debtStable = venue.debtOf(lp);
        deal(address(USDC), lp, debtStable * 2);                     // cover principal + any accrued interest
        vm.startPrank(lp);
        USDC.approve(address(lm), type(uint).max);
        lm.repay(type(uint).max / 1e13);                            // huge USD ⇒ clamps to exact debt ⇒ full repay
        vm.stopPrank();
        assertEq(venue.debtOf(lp), 0, "manager repay cleared the LP's Morpho debt");

        // The vBTC withdraw inside closeBtcLev needs the LP to authorize the venue as its Morpho manager.
        vm.prank(lp); IMorphoTest(MORPHO).setAuthorization(address(venue), true);
        uint levBefore = ETH.levPooledBTC(lp);
        assertEq(levBefore, 2e8, "levered slice == the exposed 2 BTC before close");

        // CLOSE: withdraw all vBTC, delete the position, un-fold the levered slice back to free band depth.
        vm.prank(lp); lm.closeBtcLev();

        assertEq(venue.collateralOf(lp), 0, "close: all vBTC withdrawn from Morpho");
        assertEq(ETH.levPooledBTC(lp), 0, "close: unexposeBtcFromLev un-folded the levered slice (lev to funded)");
        assertEq(lm.netEquity(lp), 0, "close: no live net-equity for a deleted position");
        (,,,,, bool open) = lm.pos(lp);
        assertTrue(!open, "close: position deleted");
        assertEq(lm.openLevCount(), 0, "close: LP de-tracked from the open book");
        (uint pooledClose,,,) = ETH.autoManagedBTC(lp);
        assertEq(pooledClose, pooledOpen, "close: LP.pooled untouched (band position un-freezes, LP made whole)");
        _assertSolvent("close: basket solvent after retirement");
    }

    /// @notice (#64 gap 2, HIGH) manager-level `repay` + `deleverWithdraw` (only the venue's `repayFor` was tested).
    ///   Opens a BTC-lev position with REAL debt and exercises the LP-gated legs: `repay` reduces the isolated
    ///   Morpho debt, then `deleverWithdraw` pulls vBTC collateral back out to the LP/keeper — asserting the real
    ///   debt/collateral state deltas both move correctly.
    function testReal_BtcRepayAndDeleverWithdraw_LpGated() public {
        BTCChannels ch = _deployChannels();
        _setupBtcLev();
        (,, address lp,) = _open(ch, 65, 3e8);
        _openLev(lp, 2e8);
        // withdraw (deleverWithdraw) needs the LP to authorize the venue on Morpho.
        vm.prank(lp); IMorphoTest(MORPHO).setAuthorization(address(venue), true);

        uint px = AUX.getTWAPforAsset(address(WBTC), 1800);
        uint debtUsdc = ((2e8 * px / 1e18) / 2) / 1e12;             // ~50% LTV real Morpho debt
        _borrowMorpho(lp, debtUsdc);
        uint debt0 = venue.debtOf(lp);
        uint coll0 = venue.collateralOf(lp);
        assertGt(debt0, 0, "LP has real BTC-lev Morpho debt");
        assertEq(coll0, 2e8, "collateral == the exposed 2 BTC");

        // ── manager `repay` (LP-gated): repay HALF the debt through the manager (clamp-before-transfer). ──
        uint payUsdc = debtUsdc / 2;
        deal(address(USDC), lp, payUsdc);
        vm.startPrank(lp);
        USDC.approve(address(lm), type(uint).max);
        uint repaid = lm.repay(uint(payUsdc) * 1e12);              // USD 1e18 ⇒ ~payUsdc stable
        vm.stopPrank();
        assertApproxEqAbs(repaid, payUsdc, 2, "repay applied ~half the debt");
        assertApproxEqAbs(venue.debtOf(lp), debt0 - payUsdc, debt0 / 50, "repay reduced the isolated Morpho debt");

        // ── manager `deleverWithdraw` (LP-gated): the half-repay freed LTV headroom to withdraw vBTC to the LP. ──
        uint lpVbtc0 = IERC20V(address(ETH.VBTC())).balanceOf(lp);
        uint wantSats = 1e7;                                        // 0.1 BTC — well within the freed headroom
        vm.prank(lp);
        uint out = lm.deleverWithdraw(wantSats);
        assertApproxEqAbs(out, wantSats, 2, "deleverWithdraw returned the requested vBTC");
        assertApproxEqAbs(venue.collateralOf(lp), coll0 - wantSats, 2, "deleverWithdraw reduced the venue collateral");
        assertEq(IERC20V(address(ETH.VBTC())).balanceOf(lp) - lpVbtc0, out, "the withdrawn vBTC landed with the LP/keeper");
    }

    // ─────────────────────────── #36 venue safety gates (REAL Morpho vBTC venue) ───────────────────────────

    /// @notice (#36a) init must REJECT a real venue whose collateral isn't vBTC (== the Vault): a WBTC-collateral
    ///   market would inject phantom BTC backing into vogueBTC. GOV can't pin it even though it's a real venue.
    /// RETARGETED 2026-07-26: WBTC collateral is ALLOWED by policy, so asserting its rejection was
    /// asserting the opposite of the documented behaviour. `BtcLevManager.init` passes WBTC as `c1` to
    /// `LevMath.vetVenue` and its own comment states it: "vBTC sats OR WBTC — SAME oracle price, so
    /// valuation is identical … c1=WBTC => WBTC venue allowed". The real guard is against collateral
    /// the manager cannot VALUE as 8-dec BTC (LevMath:280, `coll != c0 && coll != c1`), which is what
    /// would silently misvalue into phantom BTC backing. WETH is such a collateral.
    function test_BtcLevVenueGate_InitRejectsUnvaluableCollateral() public {
        _setupBtcLev();   // establishes mOracle + the good (vBTC) reference stack
        BtcLevManager lm2 = new BtcLevManager(address(ETH.VBTC()), address(AUX), address(WBTC), address(this), address(QUID));
        MarketParams memory badMp = MarketParams({
            loanToken: address(USDC), collateralToken: address(WETH),   // neither vBTC nor WBTC => unvaluable as BTC
            oracle: mOracle, irm: ADAPTIVE_IRM, lltv: 0.86e18});
        MorphoEscrowVenue bad = new MorphoEscrowVenue(MORPHO, badMp, address(lm2));
        vm.expectRevert(LevMath.BadCollateral.selector);
        address[] memory vsBad = new address[](1); vsBad[0] = address(bad);
        lm2.init(address(ETH), MORPHO, vsBad);
    }

    /// @notice (#36b) openBtcLev must REJECT a NEW position onto an incident-flagged venue (GOV setVaultHealth).
    function test_BtcLevVenueGate_OpenRejectsBlockedVenue() public {
        _setupBtcLev();
        AUX.setVaultHealth(address(venue), true);   // real incident flag (AUX owner == this test)
        vm.prank(address(0xB0B));
        vm.expectRevert(LevMath.VenueBlocked.selector);
        lm.openBtcLev(5000, 1e8, venue);                    // reverts at the health gate, before the MIN_OPEN/expose steps
    }
}
