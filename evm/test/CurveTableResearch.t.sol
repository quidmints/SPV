// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {ICurvePool, USDC} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IMetaReg {
    function find_pool_for_coins(address f, address t, uint256 i) external view returns (address);
    function get_coin_indices(address p, address f, address t) external view returns (int128, int128, bool);
}
interface IERC20R { function decimals() external view returns (uint8); function symbol() external view returns (string memory); }

/// @notice §SESS-24 — **RESEARCH ARTIFACT: which stables can be quoted against Curve, with indices
///         VERIFIED AGAINST `coins()` RATHER THAN TAKEN FROM THE REGISTRY.**
///
/// `_routeOf` covers 2 of 14. §SESS-23 made it a FLOOR reference, so each row it gains is basis points.
/// ⚠️ **THE REGISTRY IS NOT THE AUTHORITY.** `find_pool_for_coins(…, 0)` returns *a* pool, not the
///    deepest — measured: for PYUSD it returns `0x61fA2c94…`, which is NOT the `0x383E6b44…` this tree
///    already verified. And the tree's own warning is explicit: *"The ORDERING was read from the chain,
///    not assumed — a wrong index swaps the wrong pair at size and there is no id to assert against."*
///    ⇒ every candidate below is re-checked with `coins(i)`/`coins(j)` directly.
/// ⚠️ **`is_underlying` DISQUALIFIES A POOL.** `curveExchange` calls `exchange`, not
///    `exchange_underlying`; a metapool row would quote a price the swap cannot execute.
contract CurveTableResearch is ForkPin {
    IMetaReg constant MR = IMetaReg(0xF98B45FA17DE75FB1aD0e7aFD971b0ca00e379fC);

    function setUp() public { vm.selectFork(_forkMainnet()); }

    function _probe(string memory name, address tok) internal view {
        uint8 dec = IERC20R(tok).decimals();
        uint256 dx = 10_000 * (10 ** dec);
        console2.log("=====", name);
        for (uint256 c; c < 6; ++c) {
            address p;
            try MR.find_pool_for_coins(tok, USDC, c) returns (address a) { p = a; } catch { }
            if (p == address(0)) continue;
            int128 i; int128 j; bool underlying;
            try MR.get_coin_indices(p, tok, USDC) returns (int128 a, int128 b, bool u) { (i,j,underlying)=(a,b,u); }
            catch { console2.log("  pool (no indices):", p); continue; }
            // VERIFY against the pool itself, never the registry.
            address ci; address cj;
            try ICurvePool(p).coins(uint256(int256(i))) returns (address a) { ci = a; } catch {}
            try ICurvePool(p).coins(uint256(int256(j))) returns (address a) { cj = a; } catch {}
            bool idxOk = (ci == tok && cj == USDC);
            // ⚠️ **DISTINGUISH REVERT FROM ZERO.** A pool whose `get_dy` REVERTS has the wrong
            //    signature for us (crypto/NG variants take `uint256` indices) and is unusable; one that
            //    RETURNS zero is merely empty. Collapsing both to 0 would have hidden which.
            uint256 dy; bool reverted;
            try ICurvePool(p).get_dy(i, j, dx) returns (uint256 d) { dy = d; } catch { reverted = true; }
            if (!idxOk || underlying) continue;                 // metapool / mis-indexed: not a candidate
            console2.log("  CANDIDATE pool:", p);
            console2.log("    i,j:", vm.toString(int256(i)), vm.toString(int256(j)));
            console2.log("    get_dy reverted?", reverted);
            console2.log("    get_dy(10k) USDC out (6dec):", dy);
        }
    }

    function test_EnumerateCurveRoutesForEveryStable() public view {
        _probe("USDT",   0xdAC17F958D2ee523a2206206994597C13D831ec7);
        _probe("PYUSD",  0x6c3ea9036406852006290770BEdFcAbA0e23A0e8);
        _probe("GHO",    0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
        _probe("RLUSD",  0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD);
        _probe("USDG",   0xe343167631d89B6Ffc58B88d6b7fB0228795491D);
        _probe("DAI",    0x6B175474E89094C44Da98b954EedeAC495271d0F);
        _probe("USDS",   0xdC035D45d973E3EC169d2276DDab16f1e407384F);
        _probe("USDE",   0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
        _probe("AUSD",   0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a);
        _probe("CRVUSD", 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
        _probe("BOLD",   0x6440f144b7e50D6a8439336510312d2F54beB01D);
    }
}
