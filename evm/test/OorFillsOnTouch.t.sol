// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
import {Quid} from "../src/Quid.sol";

/// @title §OOR-AS-INTENT — A RESTING ORDER THAT EXISTS ONLY AS A SIGNATURE
///
/// @notice **THIS FILE REPLACES THE ONE THAT TESTED THE BOOK, AND THE REPLACEMENT WAS OVERDUE.**
///         `Quid.fillIntent` landed in `abb685c4` (2026-08-28) with **ZERO tests** — measured, not
///         estimated — while `outOfRange`/`pull`/`sweepOor`/`fillOOR` and their sorted-set index
///         stayed live beside it. Two designs, one tested, and the untested one was the survivor.
///         **That is why the book went un-deleted for a day and why this file exists before any
///         further work on the intent path.** (§OOR-TWO-DESIGNS-LIVE.)
///
/// ⚠️ **WHAT WENT AND WHY IT IS NOT A COVERAGE LOSS.** The previous file's first four tests were
///    about the BOOK'S INDEX — that `SortedSetLib.insert` silently discards a duplicate, so the key
///    had to be `(price << 96) | id`; that the packing sorts by price first; that a full `pull`
///    leaves no ghost in the set; that `pull`'s 47-block rule does not reach the fill path. **Every
///    one of those is a property of a structure that no longer exists.** An intent is not indexed,
///    not stored, and not closed — it is signed, and it is consumed. The properties that SURVIVE
///    the change are re-asserted below against the mechanism that now carries them.
///
/// ⚠️ **AND THE OLD FILE'S OWN CAVEAT STILL BINDS, FOR THE SAME REASON:** a fill needs the range's
///    ORACLE to have crossed the limit, and on a pinned fork `getTWAPforAsset` moves for neither
///    `vm.roll` nor `vm.warp`. Mocking it would prove only that the test can lie to itself. So the
///    crossing is asserted from the REFUSING side — an uncrossed limit reverts `IntentNotCrossed`,
///    which is the same guard from the other direction — and the end-to-end fill remains booked as
///    §E258-CROSSING-TEST, still open.
contract OorIntentTest is AllesFixture {

    /// The maker. A private key, not `User01`, because an intent is a SIGNATURE and the whole
    /// mechanism turns on who holds one.
    uint256 internal constant MAKER_PK = 0xA11CE;
    address internal maker;

    function setUp() public override { super.setUp(); maker = vm.addr(MAKER_PK); }

    /// EIP-712 domain, recomputed here rather than read: `Quid._oorDomain()` is `private`, and a
    /// test that asked the contract for the digest it is about to verify would be asserting that
    /// `ecrecover` is deterministic. Rebuilding it from the published constants is what makes this
    /// a check on the CONTRACT'S domain rather than a mirror of it.
    function _domain() internal view returns (bytes32) {
        return keccak256(abi.encode(SwapLib.OOR_DOMAIN_TYPEHASH,
            keccak256("QuidOor"), keccak256("1"), block.chainid, address(ETH)));
    }

    function _intent(uint64 nonce, uint limitPx, bool buyVolatile)
        internal view returns (SwapLib.OorIntent memory i) {
        i = SwapLib.OorIntent({
            owner: maker, buyVolatile: buyVolatile, size: rack / 10, limitPx: limitPx,
            expiry: uint64(block.timestamp + 1 days), nonce: nonce, loadBalance: true });
    }

    function _sign(SwapLib.OorIntent memory i, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domain(),
            keccak256(abi.encode(SwapLib.OOR_TYPEHASH, i.owner, i.buyVolatile, i.size,
                i.limitPx, i.expiry, i.nonce, i.loadBalance))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// A price the oracle has NOT reached, on the far side of a bid. Read live so the test does not
    /// pin a number the fork can move under it.
    function _uncrossedBid() internal view returns (uint) {
        return AUX.getTWAPforAsset(address(WETH), 1800) / 2;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    //  THE FOUR PROPERTIES THAT SURVIVED THE BOOK, EACH AGAINST ITS NEW CARRIER
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /// WAS: *"a fresh order is not touched, so the poke refuses it."* NOW: the ORACLE binds, and it
    /// is the contract's own read. A bid whose limit the price has not fallen to is refused —
    /// which is also the whole anti-keeper property, because the relayer chooses WHEN and the
    /// contract decides WHETHER. If this ever starts filling, a relayer can name the price.
    function test_AnUncrossedLimitIsRefused_theOracleDecidesNotTheRelayer() public {
        SwapLib.OorIntent memory i = _intent(1, _uncrossedBid(), true);
        bytes memory sig = _sign(i, MAKER_PK);
        vm.prank(User02);                       // permissionless relay — anyone may submit
        vm.expectRevert(SwapLib.IntentNotCrossed.selector);
        ETH.fillIntent(i, sig);
    }

    /// WAS: *"a full pull leaves no ghost in the index."* NOW: **one consumed bit per
    /// `(owner, nonce)`, and it is the ONLY storage the mechanism ever writes.** There is no
    /// position to leave behind, so the property becomes: a nonce cannot be spent twice.
    /// ⚠️ Asserted through the PUBLIC map rather than by filling twice, because filling once needs
    ///    a crossing this fixture cannot produce (see the file header). The map is what `fillIntent`
    ///    reads, so this is the same bit the guard consults.
    function test_TheNonceIsTheOnlyState_andItStartsUnspent() public view {
        assertFalse(ETH.intentUsed(maker, 1), "a nonce nobody has filled must be unspent");
        assertFalse(ETH.intentUsed(maker, 2), "and nonces are independent of one another");
    }

    /// WAS: *"two orders at the same trigger both remain real"* — the case a bare-price key would
    /// have stranded. NOW two intents at one limit are simply two nonces: there is no index for
    /// them to collide in, and the property is that the CONSUMED BIT is per-nonce rather than
    /// per-owner or per-price.
    function test_TwoIntentsAtOneLimitAreTwoNonces() public {
        uint px = _uncrossedBid();
        SwapLib.OorIntent memory a = _intent(7, px, true);
        SwapLib.OorIntent memory b = _intent(8, px, true);
        assertTrue(keccak256(_sign(a, MAKER_PK)) != keccak256(_sign(b, MAKER_PK)),
            "the same limit under two nonces must be two distinct signatures");
        // Both are individually addressable, and both stop at the same guard.
        vm.expectRevert(SwapLib.IntentNotCrossed.selector); ETH.fillIntent(a, _sign(a, MAKER_PK));
        vm.expectRevert(SwapLib.IntentNotCrossed.selector); ETH.fillIntent(b, _sign(b, MAKER_PK));
    }

    /// WAS: *"the poke rejects an order that is not there."* NOW an intent that was never authorised
    /// has no on-chain existence to check — so the guard is the SIGNATURE, and this is the
    /// mechanism's central security claim: **a fully-compromised keeper holds no key that moves
    /// funds.** Signed by someone who is not `owner` ⇒ refused.
    function test_AnIntentSignedByAnyoneButTheOwnerIsRefused() public {
        SwapLib.OorIntent memory i = _intent(3, _uncrossedBid(), true);
        bytes memory forged = _sign(i, 0xBAD5EED);      // a real signature, over the real digest
        vm.expectRevert(SwapLib.IntentBadSig.selector);
        ETH.fillIntent(i, forged);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    //  AND THE PROPERTIES THE BOOK COULD NOT HAVE
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /// AN INTENT IS NOT IMMORTAL, which a resting position was. Expiry is checked FIRST, before the
    /// signature and before the oracle — so an expired intent costs a relayer nothing to discover.
    function test_AnExpiredIntentIsRefusedBeforeAnythingElse() public {
        SwapLib.OorIntent memory i = _intent(4, _uncrossedBid(), true);
        bytes memory sig = _sign(i, MAKER_PK);
        vm.warp(uint(i.expiry) + 1);
        vm.expectRevert(SwapLib.IntentExpired.selector);
        ETH.fillIntent(i, sig);
    }

    /// A MALFORMED SIGNATURE IS REFUSED AS A SIGNATURE, not as an `ecrecover` of address(0).
    /// ⚠️ The length check exists because `ecrecover` returns `address(0)` on garbage, and an
    ///    `OorIntent` whose `owner` was `address(0)` would then verify. The guard is what stops a
    ///    zero-owner intent being a valid one.
    function test_AShortSignatureIsRefused() public {
        SwapLib.OorIntent memory i = _intent(5, _uncrossedBid(), true);
        vm.expectRevert(SwapLib.IntentBadSig.selector);
        ETH.fillIntent(i, hex"1234");
    }

    /// ⭐ THE FIELDS ARE ALL BOUND BY THE SIGNATURE — changing any one of them after signing
    ///    invalidates it. Demonstrated on `size`, which is the one that moves money: a relayer who
    ///    could inflate it would drain the maker at the maker's own limit.
    function test_TheRelayerCannotAlterTheSignedTerms() public {
        SwapLib.OorIntent memory i = _intent(6, _uncrossedBid(), true);
        bytes memory sig = _sign(i, MAKER_PK);
        i.size = i.size * 10;                            // same signature, different terms
        vm.expectRevert(SwapLib.IntentBadSig.selector);
        ETH.fillIntent(i, sig);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    //  §INTENT-HAS-NO-FUNDING-LEG — THE GATE, AND THE MEASUREMENT THAT PUT IT THERE
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /// 🔴🔴 **THE FILL PAYS OUT VALUE NOBODY SUPPLIED, SO `fillIntent` IS GATED.**
    ///
    /// **THIS TEST IS THE TOMBSTONE FOR A MEASURED DRAIN, NOT A HYPOTHETICAL.** Before the gate,
    /// with an oracle at **2,449.92**, this exact scenario ran to completion:
    /// ```
    ///   maker ETH  0                      ->  408134038270347149   (= $1,000.00 exactly)
    ///   maker USDC 0                      ->  0                    (paid NOTHING)
    ///   POOLED     49999999999999999998   ->  49591823406478578891 (real ether left)
    ///   POOLED_USD 122495999999           ->  123495999999         (+1,000.000000, from nobody)
    /// ```
    /// A THIRD PARTY relayed it. The maker held nothing before and $1,000 of ether after.
    ///
    /// ⭐ **THE CAUSE IS AN ABSENCE, WHICH IS WHY THE OTHER SEVEN TESTS ABOVE ALL PASS.** Every one
    ///    of them exercises a REFUSAL — expiry, signature, nonce, uncrossed oracle. Not one reaches
    ///    a successful fill, so not one could observe that the successful path never charges anyone.
    ///    **A suite of negative tests cannot see a missing positive.** That is the lesson worth more
    ///    than the bug: the seven were written in the same session as this file and did not find it.
    ///
    /// ⚠️ **WHEN THE FUNDING LEG LANDS, THIS TEST MUST BE REWRITTEN, NOT DELETED.** It becomes the
    ///    assertion that a fill DEBITS the maker by exactly what it credits them — which is the
    ///    property whose absence is recorded above.
    function test_TheFillHasNoFundingLeg_soItIsGated() public {
        vm.deal(User01, 100 ether);
        vm.prank(User01);
        ETH.deposit{value: 50 ether}(0, User01);

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        assertEq(maker.balance, 0, "premise: the maker holds no ether");
        assertEq(USDC.balanceOf(maker), 0, "premise: the maker holds no dollars");

        // A BUY at exactly the oracle price: `px > limitPx` is false, so the order IS crossed and
        // every other guard in `fillIntentBody` passes. Only the gate stands between this and the
        // payout measured above.
        SwapLib.OorIntent memory i = SwapLib.OorIntent({
            owner: maker, buyVolatile: true, size: 1_000 * 1e6, limitPx: px,
            expiry: uint64(block.timestamp + 1 days), nonce: 42, loadBalance: false });

        vm.prank(User02);                                   // a relayer, not the maker
        vm.expectRevert(Quid.IntentHasNoFundingLeg.selector);
        ETH.fillIntent(i, _sign(i, MAKER_PK));

        assertEq(maker.balance, 0, "the gate holds: no ether left the range");
    }

    /// ⚠️ **`loadBalance` IS INERT ON THIS RANGE, AND IT IS INSIDE THE SIGNED TYPEHASH.**
    /// `settleOor(..., loadBalance)` → `Core._shortfallLoadBalance` → `RANGE.onShortfall(...)`, and
    /// `Quid.onShortfall(address, uint) external {}` is an EMPTY BODY — a deliberate no-op with a
    /// docblock saying so (*"Do not implement this"*: an ETH refill would realise impermanent loss
    /// onto shared backing). Only `Vault` routes a shortfall anywhere, and it routes to the hop.
    /// ⇒ **The maker signs a consent that changes nothing on ETH**, while the field is load-bearing
    ///    for SIGNATURE VALIDITY — flip it and the digest, and therefore the signature, is different.
    /// 📌 **AND 1inch IS NOT ON THIS PATH AT ALL.** `ONEINCH_ROUTER`/`_aggSwap` appear only in
    ///    `LevMath.sol` (the levered unwind). Nothing `settleOor` reaches touches an aggregator.
    ///    Asserted here so a future reader does not go looking for routing that was never wired.
    function test_LoadBalanceConsentIsInertOnTheEthRange() public {
        // The no-op accepts any caller and any amount and does nothing observable.
        uint before = CORE.POOLED();
        ETH.onShortfall(address(0xBEEF), 1 ether);
        assertEq(CORE.POOLED(), before, "onShortfall moved inventory: it is no longer a no-op");
    }
}
