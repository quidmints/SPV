// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  BandBacking — the joint state two band instances still share after the `isBTC` split
///
/// @notice **WHY THIS EXISTS, AND WHY THE SPLIT IS NOT COMPLETE WITHOUT IT.** Removing `isBTC` makes
///         each band its own instance owning its own `POOLED_*`, ring and accumulators. But two of
///         the old `Core`'s behaviours were genuinely JOINT, and both would break SILENTLY under
///         independent instances:
///
///         1. **THE SOLVENCY BOUND IS A SUM.** `committedUsd18()` was
///            `_bandEquityUsd18(false) + _bandEquityUsd18(true)`, gated by
///            `require(committedUsd18() <= haircutTvl)`. There is deliberately NO per-band cap and NO
///            fixed ETH/BTC split — either band may draw the whole free surplus while the other is
///            idle. Two independent instances would each gate against the FULL TVL as though the
///            sibling did not exist, **double-committing the same backing**. Nothing reverts; the
///            basket is simply over-committed.
///
///         2. **THE SKEW AMPLIFIER READS ACROSS** (§E53). `SwapLib._sharedScarcityWad` amplifies by
///            `1 + other/both`, because the same dollar of exposure is dearer to carry once the
///            sibling has claimed part of the shared backing. An instance that cannot see its
///            sibling reads `other = 0` forever and **under-prices every skew**. Also silent.
///
///         ⇒ Each instance reports ITS OWN equity here; neither needs to know the other exists.
///         The coupling lives in one place instead of being threaded through every signature as a
///         boolean — which is the whole point: the asymmetry was never the problem, the RUNTIME
///         SELECTOR was.
///
/// @dev    ⚠️ THE STALENESS RULE THIS INHERITS FROM §A.16b, ONE LEVEL UP. A sum of per-band figures
///         is only meaningful if every term is on the same clock. If one band reports live while the
///         other's figure is stale, the total is a number that was never simultaneously true — and
///         the bound would pass against backing that does not exist. `report` is therefore PUSH, at
///         the moment the band's own equity changes, never a lazy pull.
contract BandBacking {
    /// Committed equity (USD 1e18) most recently reported by each registered band.
    mapping(address => uint256) public committedOf;
    /// Registered bands. Small and fixed (two today); enumerated so `total` cannot miss one.
    address[] public bands;
    mapping(address => bool) public isBand;

    /// One-shot registrar. Bands are deployed after this contract, so registration cannot fold into
    /// the constructor; it is frozen once `seal()` is called so the band set cannot grow silently.
    address public immutable DEPLOYER;
    bool public sealed_;

    event Registered(address indexed band);
    event Reported(address indexed band, uint256 equityUsd18);
    event Sealed(uint256 count);

    error NotDeployer();
    error NotBand();
    error AlreadySealed();
    error NotSealed();
    error AlreadyRegistered();

    constructor() { DEPLOYER = msg.sender; }

    function register(address band) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (sealed_) revert AlreadySealed();
        if (isBand[band]) revert AlreadyRegistered();
        isBand[band] = true;
        bands.push(band);
        emit Registered(band);
    }

    /// @notice Freeze the band set. After this the accountant's denominator cannot change, which is
    ///         what lets `total()` be trusted as a complete sum rather than a partial one.
    function seal() external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (sealed_) revert AlreadySealed();
        sealed_ = true;
        emit Sealed(bands.length);
    }

    /// @notice A band pushes its own committed equity. PUSH, not pull — see the staleness note.
    function report(uint256 equityUsd18) external {
        if (!isBand[msg.sender]) revert NotBand();
        committedOf[msg.sender] = equityUsd18;
        emit Reported(msg.sender, equityUsd18);
    }

    /// @notice Total committed equity across every band. The old `committedUsd18()`.
    function total() public view returns (uint256 t) {
        if (!sealed_) revert NotSealed();   // a partial sum would UNDER-report and pass a bound it should fail
        uint256 n = bands.length;
        for (uint256 i; i < n; ++i) t += committedOf[bands[i]];
    }

    /// @notice What every OTHER band holds — the §E53 scarcity input, from the caller's perspective.
    /// @dev    Deliberately derived by SUBTRACTION from the same `total()` the bound uses, so the
    ///         amplifier and the solvency gate can never disagree about the denominator. Computing
    ///         it independently is how two views of "the same" quantity drift apart.
    function otherThan(address band) external view returns (uint256) {
        uint256 t = total();
        uint256 mine = committedOf[band];
        return t > mine ? t - mine : 0;
    }

    /// @notice The old `require(committedUsd18() <= haircutTvl)`, now enforced in ONE place for all
    ///         bands rather than once per band against the full TVL.
    function requireBacked(uint256 haircutTvl) external view {
        require(total() <= haircutTvl, "backing");
    }
}
