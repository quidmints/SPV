// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

interface IERC4626D {
    function convertToAssets(uint256) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function asset() external view returns (address);
}
interface IERC20D { function transfer(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }

/// EMPIRICAL per-venue donation-inflation classification against LIVE mainnet vaults (no mocks). For each 4626
/// the basket uses, donate 100% of its totalAssets and measure convertToAssets(1e18). A vault that tracks cash
/// internally (Euler, sDAI's DSR) is IMMUNE — share price unchanged; a balanceOf-based 4626 (naive MetaMorpho
/// idle, sUSDe) INFLATES. This tells us EXACTLY which legs need a growth cap (finding #4), not a blanket claim.
contract VaultDonationClassify is Test {
    // Basket's real 4626 legs (from DeployL1_s) + the two well-known share-price vaults.
    address constant galaxyUsdc     = 0x91600E31fBeDc72433d4a57F16639cfe661Be7d8; // MetaMorpho
    address constant eulerUsdc      = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9; // Euler v2
    address constant skyUsdc        = 0x56bfa6f53669B836D1E0Dfa5e99706b12c373ecf;
    address constant gauntletUsdc   = 0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e; // MetaMorpho
    address constant morphoUsds     = 0xE15fcC81118895b67b6647BBd393182dF44E11E0; // MetaMorpho
    address constant morphoAusd     = 0x32401B9fb79065Bc15949DE0BD43927492f02F0C; // MetaMorpho
    address constant SDAI           = 0x83F20F44975D03b1b09e64809B757c47f942BEeA; // Maker DSR
    address constant SUSDE          = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497; // Ethena

    function setUp() public { vm.createSelectFork(vm.rpcUrl("mainnet")); }

    function test_ClassifyAllVenues() public {
        string[8] memory names = ["galaxyUsdc (MetaMorpho)","eulerUsdc (Euler v2)","skyUsdc","gauntletUsdc (MetaMorpho)","morphoUsds (MetaMorpho)","morphoAusd (MetaMorpho)","sDAI (Maker DSR)","sUSDe (Ethena)"];
        address[8] memory vs = [galaxyUsdc, eulerUsdc, skyUsdc, gauntletUsdc, morphoUsds, morphoAusd, SDAI, SUSDE];
        for (uint i; i < vs.length; i++) {
            try this.probeExt(names[i], vs[i]) {} catch { emit log_string("----------------------------------------"); emit log_named_string("VAULT (reverted - skipped)", names[i]); }
        }
    }

    function probeExt(string memory name, address v) external { _probe(name, v); }

    function _probe(string memory name, address v) internal {
        emit log_string("----------------------------------------");
        emit log_named_string("VAULT", name);
        try IERC4626D(v).convertToAssets(1e18) returns (uint a0) {
            address asset = IERC4626D(v).asset();
            uint ta = IERC4626D(v).totalAssets();
            uint donation = ta == 0 ? 1e24 : ta; // 100% of totalAssets (maximal signal)
            deal(asset, address(this), donation);
            IERC20D(asset).transfer(v, donation);
            uint a1 = IERC4626D(v).convertToAssets(1e18);
            emit log_named_uint("  totalAssets", ta);
            emit log_named_uint("  cta(1e18) before", a0);
            emit log_named_uint("  cta(1e18) after 100% donation", a1);
            if (a1 > a0) emit log_named_uint("  >>> INFLATED bps", (a1 - a0) * 10000 / a0);
            else         emit log_string   ("  >>> IMMUNE (share price unchanged)");
        } catch {
            emit log_string("  (no convertToAssets - not a standard 4626)");
        }
    }
}
