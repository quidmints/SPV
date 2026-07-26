// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Minimal harness exposing the BTCChannels anti-rollback freshness surface
/// (`commitFreshness` + `freshnessSeq`) so the bridge `BtcChannelsFreshnessLedger`
/// can be driven against a REAL anvil node. Same strict-monotonic guard as
/// `BTCChannels.commitFreshness`; ungated here — the hop-gating is proven against
/// the real BTCChannels in `BtcLpMintStress.testCommitFreshness_HopGated_Monotonic`.
contract FreshnessTarget {
    mapping(bytes32 => uint64) public freshnessSeq;
    mapping(address => uint64) public managerFreshnessSeq;
    error FreshnessNotMonotonic();
    error ManagerFreshnessNotMonotonic();

    function commitFreshness(bytes32 channelId, uint64 seq) external {
        if (seq <= freshnessSeq[channelId]) revert FreshnessNotMonotonic();
        freshnessSeq[channelId] = seq;
    }

    function commitManagerFreshness(uint64 seq) external {
        if (seq <= managerFreshnessSeq[msg.sender]) revert ManagerFreshnessNotMonotonic();
        managerFreshnessSeq[msg.sender] = seq;
    }
    // (#69) the lpFeePaid / markLpFeePaid mock was removed with the LP-fee settler.
}
