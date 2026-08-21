// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import "forge-std/Test.sol";

interface IOffchainOracle {
    function getRate(address src, address dst, bool useWrappers) external view returns (uint256);
    function getRateToEth(address src, bool useWrappers) external view returns (uint256);
}

/// @title §E232 — 1inch's OffchainOracle CANNOT BE READ ON-CHAIN. Measured in isolation.
///
/// @notice The ring needs a price source INDEPENDENT of Chainlink, because Chainlink is already the
///         ANCHOR `twapResolve` checks the reading against — source it from Chainlink too and the
///         deviation test compares Chainlink with Chainlink and can never fire (§E222).
///         1inch is the ideal candidate on every axis except one: it aggregates **14 registered DEX
///         oracles**, is verifiably NOT Chainlink republished (the two DISAGREE by ~0.08% on ETH/USD,
///         which is the proof), and returns a plain rate needing no `TickMath`.
///
/// 🔴 **AND IT COSTS MORE THAN A BLOCK.** That is the whole reason it is not the source.
///
/// ⚠️ WHY THIS TEST EXISTS RATHER THAN A COMMENT. The figure that first ruled 1inch out — 31,722,803
///    — was the WHOLE TEST's gas: fork setup, Chainlink reads, assertions. I attributed it to
///    `getRate` alone and reverted a commit on it. **The conclusion was right and the measurement was
///    not**, which is luck, not method. This brackets ONE call with `gasleft()` on either side, so it
///    measures the call and nothing else — and the true figure is HIGHER than the one I guessed.
///
/// ▶️ IT IS ALSO A TRIPWIRE POINTING THE RIGHT WAY: if 1inch ever optimises under the block limit,
///    this test FAILS and tells us the best available source just became usable.
contract OneInchGasProbe is Test {
    address constant O    = 0x0AdDd25a91563696D8567Df78D5A01C9a991F9B8;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant BLOCK_GAS_LIMIT = 30_000_000;

    function setUp() public {
        try vm.envString("ETH_RPC_URL") returns (string memory u) { vm.createSelectFork(u); }
        catch { vm.skip(true); }
    }

    /// @notice MEASURED 2026-08-21: `getRate` 33,573,664 · `getRateToEth` 28,776,424.
    ///         The first EXCEEDS a whole block; the second is ~96% of one for a single price read.
    ///         Either way it cannot sit on the swap path, where it would run on every fill.
    function test_OneInchCostsMoreThanABlock_soItCannotSourceTheRing() public view {
        uint g0 = gasleft();
        uint rate = IOffchainOracle(O).getRate(WETH, USDC, false);
        uint used = g0 - gasleft();
        assertGt(rate, 0, "premise: the oracle answered, so the gas figure is a real read");
        assertGt(used, BLOCK_GAS_LIMIT,
            "1inch getRate now fits in a block - it is the best available source, RECONSIDER IT (see the header)");

        g0 = gasleft();
        IOffchainOracle(O).getRateToEth(USDC, false);
        uint usedToEth = g0 - gasleft();
        // The cheaper single-leg call is still most of a block — recorded so nobody proposes it as
        // the affordable variant without measuring.
        assertGt(usedToEth, BLOCK_GAS_LIMIT / 2,
            "getRateToEth became cheap - re-measure both before ruling 1inch out again");
    }
}
