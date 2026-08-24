// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20M { function transferFrom(address,address,uint256) external returns (bool);
                    function transfer(address,uint256) external returns (bool);
                    function balanceOf(address) external view returns (uint256); }

/// @title  MockAggRouter — a stand-in for 1inch AggregationRouterV6 in tests
/// @notice §V-R1. The production router resolves routes OFF-CHAIN and is handed opaque calldata, so a
///         fork test cannot construct a real route deterministically: the quote depends on live pool
///         state at the fork block and on 1inch's own server. This mock makes the CONTRACT-SIDE
///         contract testable without pretending to test 1inch.
///
/// ⚠️ WHAT THIS DOES AND DOES NOT PROVE. It proves the three properties `_aggSwap` actually owns:
///     ① the call is made to the PINNED address with the caller's bytes,
///     ② the allowance is set to exactly `amountIn` and returned to zero on BOTH paths,
///     ③ the floor is enforced against a MEASURED balance delta, not a reported number.
///    It proves NOTHING about 1inch's routing quality, and a test using it must not claim otherwise.
///
/// ⚠️ THE `shortfallBps` KNOB IS THE POINT, not a convenience. Set it non-zero and the router delivers
///    LESS than asked — which is exactly the sandwich/stale-quote case the oracle floor exists to
///    reject. A mock that can only succeed would make the floor untestable, and an untested floor is
///    the whole security argument for accepting caller-supplied calldata.
contract MockAggRouter {
    uint256 public shortfallBps;          // 0 = fill in full; 10_000 = deliver nothing
    bool    public reverts;

    function setShortfall(uint256 bps) external { shortfallBps = bps; }
    function setReverts(bool r) external { reverts = r; }

    /// @dev The calldata shape is OURS, not 1inch's — the production router is called with opaque
    ///      bytes, so a mock is free to define its own encoding. Tests build it with `abi.encodeCall`.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 quotedOut) external {
        require(!reverts, "MockAggRouter: forced revert");
        IERC20M(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = quotedOut - (quotedOut * shortfallBps) / 10_000;
        if (out > 0) IERC20M(tokenOut).transfer(msg.sender, out);
    }

    /// @notice Fund the mock with the token it will pay out. A router holds no inventory in reality —
    ///         it routes through pools — so this is scaffolding, and a test that forgets it gets a
    ///         transfer failure rather than a silent zero fill.
    receive() external payable {}
}
