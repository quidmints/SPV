// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

interface ICurveAddressProvider { function get_address(uint256 id) external view returns (address); }
interface ICurveMetaRegistry {
    /// ⚠️ PLURAL. The SINGULAR `find_pool_for_coins` returns dead/low-liquidity pools and was the
    ///    source of the "Curve has ~2 usable pools" conclusion this repo shipped a design on.
    function find_pools_for_coins(address from, address to) external view returns (address[] memory);
    function get_balances(address pool) external view returns (uint256[8] memory);
    function get_coins(address pool) external view returns (address[8] memory);
}
interface IUniV3Factory { function getPool(address a, address b, uint24 fee) external view returns (address); }
interface IUniV3Pool { function liquidity() external view returns (uint128); }
interface IERC20D { function decimals() external view returns (uint8); function balanceOf(address) external view returns (uint256); }

/// @notice §PERMITTED-POOL-SET — ENUMERATE, ON-CHAIN, EVERY POOL THE PROTOCOL WOULD NEED IF THE
///         KEEPER MAY ONLY NAME POOLS FROM A FIXED SET.
///
/// 🔴 WHY THIS IS A TEST AND NOT A LIST I TYPED. Five wrong conclusions in this project came from
///    treating one query's answer as the shape of the world (§EXTERNAL-PROBE in CLAUDE.md), and
///    "here are the pool addresses" written from memory is the purest form of that. Every address
///    below is DISCOVERED and its liquidity MEASURED; the run's log IS the candidate set.
///
/// ⭐ WHAT THE SET IS FOR. Today `LevMath._routeOf` knows exactly TWO pools (RLUSD, PYUSD) plus USDC
///    as hub, so 8 of the 11 basket stables are unroutable and their slices are skipped and refunded.
///    A fixed permitted set is simultaneously the security fix (a hacked enclave can name only real,
///    vetted pools — pool WORDS alone do not bound it, since an attacker can deploy a contract that
///    answers `token0()`) and the coverage fix.
contract PermittedPoolSet is Test {
    address constant CURVE_ADDRESS_PROVIDER = 0x0000000022D53366457F9d5E68Ec105046FC4383;
    address constant UNIV3_FACTORY          = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    address constant WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC  = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant USDC  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT  = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI   = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDE  = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant USDS  = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant GHO   = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address constant USDG  = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;
    address constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant AUSD  = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant BOLD  = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    ICurveMetaRegistry reg;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        // DISCOVERED, not typed: id 7 is the MetaRegistry in Curve's AddressProvider.
        address r = ICurveAddressProvider(CURVE_ADDRESS_PROVIDER).get_address(7);
        emit log_named_address("Curve MetaRegistry (AddressProvider id 7)", r);
        reg = ICurveMetaRegistry(r);
    }

    function _name(address t) internal pure returns (string memory) {
        if (t == USDC) return "USDC"; if (t == USDT) return "USDT"; if (t == DAI)  return "DAI";
        if (t == USDE) return "USDe"; if (t == USDS) return "USDS"; if (t == GHO)  return "GHO";
        if (t == USDG) return "USDG"; if (t == PYUSD) return "PYUSD"; if (t == RLUSD) return "RLUSD";
        if (t == AUSD) return "AUSD"; if (t == BOLD) return "BOLD"; if (t == WETH) return "WETH";
        if (t == WBTC) return "WBTC"; if (t == WEETH) return "weETH"; return "?";
    }

    /// Deepest Curve pool for a pair, by the smaller side's balance (a pool is only as useful as its
    /// thinner leg — ranking on the fat leg picks pools you cannot actually trade size through).
    function _bestCurve(address a, address b) internal view returns (address best, uint256 depth) {
        try reg.find_pools_for_coins(a, b) returns (address[] memory pools) {
            for (uint i; i < pools.length; ++i) {
                address p = pools[i];
                if (p == address(0)) continue;
                uint256 ba = IERC20D(a).balanceOf(p) / (10 ** IERC20D(a).decimals());
                uint256 bb = IERC20D(b).balanceOf(p) / (10 ** IERC20D(b).decimals());
                uint256 d = ba < bb ? ba : bb;
                if (d > depth) { depth = d; best = p; }
            }
        } catch {}
    }

    function test_EnumerateStableToUsdcHubPools() public {
        address[10] memory xs = [USDT, DAI, USDE, USDS, GHO, USDG, PYUSD, RLUSD, AUSD, BOLD];
        emit log("stable -> USDC : deepest Curve pool (depth = smaller leg, whole tokens)");
        for (uint i; i < xs.length; ++i) {
            (address p, uint256 d) = _bestCurve(xs[i], USDC);
            emit log_named_string("  pair", _name(xs[i]));
            emit log_named_address("    pool ", p);
            emit log_named_uint("    depth", d);
        }
    }

    function test_EnumerateWeethAndVolatileLegs() public {
        (address p, uint256 d) = _bestCurve(WEETH, WETH);
        emit log_named_address("weETH/WETH curve pool", p);
        emit log_named_uint("weETH/WETH depth", d);

        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        address[3] memory pairs0 = [USDC, USDC, WETH];
        address[3] memory pairs1 = [WETH, WBTC, WBTC];
        for (uint j; j < 3; ++j) {
            emit log_named_string("univ3 pair", string.concat(_name(pairs0[j]), "/", _name(pairs1[j])));
            for (uint f; f < fees.length; ++f) {
                address pool = IUniV3Factory(UNIV3_FACTORY).getPool(pairs0[j], pairs1[j], fees[f]);
                if (pool == address(0)) continue;
                emit log_named_uint("   fee", fees[f]);
                emit log_named_address("   pool", pool);
                emit log_named_uint("   liquidity", uint256(IUniV3Pool(pool).liquidity()));
            }
        }
    }
}
