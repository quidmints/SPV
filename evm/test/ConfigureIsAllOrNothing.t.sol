// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {Aux} from "../src/Aux.sol";

/// @title `Aux.configure` — the batch must do exactly what the singular setters do, and must be
///        ALL-OR-NOTHING when any entry is already pinned.
///
/// §SETTER-FOLD collapsed 25 owner-only deploy calls into one. The risk that buys is a batch
/// that DIVERGES from the singular path, so both are pinned here against the same reads.
///
/// 🔴 THE ALL-OR-NOTHING TEST IS THE ONE THAT MATTERS. Pin-once exists so a feed cannot be
///    silently repointed. A batch that SKIPPED already-pinned entries would report success for
///    a wiring it did not perform — which is worse than 25 calls, because the operator has no
///    per-call receipt to inspect. So one pinned entry must revert the WHOLE batch, and nothing
///    from that batch may survive.
contract ConfigureIsAllOrNothing is AllesFixture {

    function _empty() internal pure returns (address[] memory) {
        return new address[](0);
    }

    /// The batch writes what the singular setters write.
    function test_ConfigureWiresFeedsTheSameWayTheSingularSetterDoes() public {
        address token = address(0xA11CE);
        address feed  = address(0xFEED01);
        assertEq(AUX.stableFeed(token), address(0), "precondition: unpinned");

        address[] memory t = new address[](1); t[0] = token;
        address[] memory f = new address[](1); f[0] = feed;

        vm.prank(AUX.owner());
        AUX.configure(Aux.Wiring({
            assetTokens: _empty(), assetFeeds: _empty(),
            stableTokens: t,       stableFeeds: f,
            vaultStables: _empty(), vaultAddrs: _empty(),
            quid: address(0), ethVenue: address(0), btcChannels: address(0)
        }));
        assertEq(AUX.stableFeed(token), feed, "configure did not pin the stable feed");
    }

    /// One already-pinned entry reverts everything, and the OTHER entries in the same batch
    /// must not have landed.
    function test_OnePinnedEntryRevertsTheWholeBatch() public {
        address pinned  = address(0xB0B01);
        address fresh   = address(0xB0B02);
        vm.prank(AUX.owner());
        AUX.setStableFeed(pinned, address(0xFEED02));       // pin one up front

        address[] memory t = new address[](2); t[0] = fresh;  t[1] = pinned;
        address[] memory f = new address[](2); f[0] = address(0xFEED03); f[1] = address(0xFEED04);

        vm.prank(AUX.owner());
        vm.expectRevert();                                   // FeedPinned()
        AUX.configure(Aux.Wiring({
            assetTokens: _empty(), assetFeeds: _empty(),
            stableTokens: t,       stableFeeds: f,
            vaultStables: _empty(), vaultAddrs: _empty(),
            quid: address(0), ethVenue: address(0), btcChannels: address(0)
        }));

        // the FRESH entry was processed BEFORE the pinned one and must have been rolled back
        assertEq(AUX.stableFeed(fresh), address(0),
                 "a partial write survived - the batch is not all-or-nothing");
    }

    /// Parallel arrays of different lengths are rejected rather than silently truncated.
    function test_MismatchedArrayLengthsRevert() public {
        address[] memory t = new address[](2); t[0] = address(1); t[1] = address(2);
        address[] memory f = new address[](1); f[0] = address(3);
        vm.prank(AUX.owner());
        vm.expectRevert();                                   // LengthMismatch()
        AUX.configure(Aux.Wiring({
            assetTokens: _empty(), assetFeeds: _empty(),
            stableTokens: t,       stableFeeds: f,
            vaultStables: _empty(), vaultAddrs: _empty(),
            quid: address(0), ethVenue: address(0), btcChannels: address(0)
        }));
    }

    /// It is owner-gated, exactly as the 25 calls it replaces were.
    function test_ConfigureIsOwnerGated() public {
        vm.prank(address(0xDEADBEEF));
        vm.expectRevert();
        AUX.configure(Aux.Wiring({
            assetTokens: _empty(), assetFeeds: _empty(),
            stableTokens: _empty(), stableFeeds: _empty(),
            vaultStables: _empty(), vaultAddrs: _empty(),
            quid: address(0), ethVenue: address(0), btcChannels: address(0)
        }));
    }
}
