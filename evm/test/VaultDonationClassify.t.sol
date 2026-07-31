// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {ForkPin} from "./utils/ForkPin.sol";

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
///
/// The classification is not decorative: `BasketLib._valueStable` values every stable leg through
/// `convertToAssets`, so a venue whose share price can be pushed by a transfer is a venue whose share price can
/// push the basket's recognised backing. What the numbers must never show is a share price rising by MORE than
/// the donation's own arithmetic share of the vault — that would be value created from nothing rather than a
/// gift being recognised (the same line `EconAttackProbe.testB_BackingInflationByDonation` draws at the basket
/// level, drawn here per venue).
contract VaultDonationClassify is ForkPin {
    // Basket's real 4626 legs, matching script/DeployL1_s.sol: the primary vault per stable from VAULTS[]
    // PLUS every additional curator appended by the setVault calls (USDC has 6, USDT has 4). The AAVE-v4
    // spoke legs (GHO/USDG, and the USDC/USDT spoke entries) are NOT 4626s and have no share price to
    // donate into, so they are out of scope here by construction.
    address constant galaxyUsdc     = 0x91600E31fBeDc72433d4a57F16639cfe661Be7d8; // MetaMorpho (USDC primary)
    address constant eulerUsdc      = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9; // Euler v2
    address constant skyUsdc        = 0x56bfa6f53669B836D1E0Dfa5e99706b12c373ecf;
    address constant wintermuteUsdc = 0x5dc53a23AdC9f2Bed98de6F59F7F309a7c71FF2B;
    address constant rockawayUsdc   = 0xd65d6E8dbC3Cd3D12418199E6f4014dB3aaa0097;
    address constant gauntletUsdc   = 0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e; // MetaMorpho
    address constant galaxyUsdt     = 0x71ffB6a81786eC285D429d531Cf655107B9D878d; // MetaMorpho (USDT primary)
    address constant eulerUsdt      = 0x313603FA690301b0CaeEf8069c065862f9162162;
    address constant skyUsdt        = 0x23f5E9c35820f4baB695Ac1F19c203cC3f8e1e11;
    address constant gauntletUsdt   = 0xE571B648569619566CF6ce1060C97B621CB635D3;
    address constant morphoPyusd    = 0xb576765fB15505433aF24FEe2c0325895C559FB2; // MetaMorpho
    address constant morphoRlusd    = 0x6dC58a0FdfC8D694e571DC59B9A52EEEa780E6bf; // MetaMorpho
    address constant morphoUsds     = 0xE15fcC81118895b67b6647BBd393182dF44E11E0; // MetaMorpho
    address constant morphoAusd     = 0x32401B9fb79065Bc15949DE0BD43927492f02F0C; // MetaMorpho
    address constant SDAI           = 0x83F20F44975D03b1b09e64809B757c47f942BEeA; // Maker DSR
    address constant SUSDE          = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497; // Ethena
    address constant STCUSD         = 0x88887bE419578051FF9F4eb6C858A951921D8888; // Cap USD
    address constant MORPHO_BLUE    = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb; // aUSD donation source

    uint constant N = 17;

    struct Probe {
        uint a0;         // convertToAssets(1e18) before the donation
        uint a1;         // convertToAssets(1e18) after
        uint totalAssets;
        uint totalSupply; // shares outstanding BEFORE the donation (a gift mints none)
        uint donation;
        uint balBefore;  // vault's own asset balance before
        uint balAfter;   // ... and after (proves the donation LANDED)
    }

    function setUp() public { vm.selectFork(_forkMainnet()); }

    function test_ClassifyAllVenues() public {
        string[N] memory names = [
            "galaxyUsdc (MetaMorpho)","eulerUsdc (Euler v2)","skyUsdc","wintermuteUsdc","rockawayUsdc",
            "gauntletUsdc (MetaMorpho)","galaxyUsdt (MetaMorpho)","eulerUsdt","skyUsdt","gauntletUsdt",
            "morphoPyusd (MetaMorpho)","morphoRlusd (MetaMorpho)","morphoUsds (MetaMorpho)",
            "morphoAusd (MetaMorpho)","sDAI (Maker DSR)","sUSDe (Ethena)","stcUSD (Cap)"
        ];
        address[N] memory vs = [
            galaxyUsdc, eulerUsdc, skyUsdc, wintermuteUsdc, rockawayUsdc,
            gauntletUsdc, galaxyUsdt, eulerUsdt, skyUsdt, gauntletUsdt,
            morphoPyusd, morphoRlusd, morphoUsds, morphoAusd, SDAI, SUSDE, STCUSD
        ];
        // Where the donated assets come from. address(0) = `deal` (works for every token whose
        // balance lives in a plain mapping). aUSD is namespaced-storage (ERC-7201) and `deal`
        // cannot find its balance slot at all — "stdStorage: Failed to write value". Sourcing the
        // donation from a real on-chain holder instead is what keeps that venue CLASSIFIED rather
        // than silently dropped; an unfundable token is a harness problem, and answering
        // "unknown" for a live basket leg because of one is not acceptable.
        address[N] memory funders;
        funders[13] = MORPHO_BLUE; // aUSD: Morpho Blue custodies the aUSD markets' cash
        uint classified; uint inflating;
        for (uint i; i < N; i++) {
            emit log_string("----------------------------------------");
            emit log_named_string("VAULT", names[i]);
            // The probe runs in its OWN frame so one uncooperative venue cannot abort the sweep,
            // but the verdict is taken on the RETURNED measurements out here — assertions inside a
            // try/catch are exactly how a sweep like this stays green while classifying nothing.
            try this.probeExt(vs[i], funders[i]) returns (Probe memory p) {
                emit log_named_uint("  totalAssets", p.totalAssets);
                emit log_named_uint("  cta(1e18) before", p.a0);
                emit log_named_uint("  cta(1e18) after 100% donation", p.a1);

                // PREMISE 1: this must be a live, priceable 4626. A vault reporting a zero share
                // price is either not a 4626 or not deployed at this fork block, and "IMMUNE"
                // would be a reading of nothing.
                assertGt(p.a0, 0, string.concat("PREMISE: share price must be readable: ", names[i]));
                // PREMISE 2: THE DONATION MUST HAVE LANDED. This is the whole load-bearing step —
                // a transfer that silently moved nothing makes every venue look immune, which is
                // the flattering answer and the wrong one.
                assertEq(p.balAfter - p.balBefore, p.donation,
                    string.concat("PREMISE: the donation must reach the vault: ", names[i]));
                assertGt(p.donation, 0, string.concat("PREMISE: donation must be non-zero: ", names[i]));

                // SAFETY: a donation is a GIFT, so a share price that rises is not by itself an
                // attack. The attack is a share price rising by MORE than the donation's own
                // arithmetic share — value from nothing, which would let a depositor mint against
                // backing nobody contributed. A gift mints no shares, so the most a fully
                // balanceOf-tracking 4626 can report is (assets + donation) / supply. Every term
                // is a LIVE measurement; nothing here is a chosen constant.
                //
                // Cross-multiplied rather than `a0 * (ta + donation) / ta`: that form truncates
                // TWICE (a0 is already a floor), which puts the ceiling one wei UNDER the honest
                // answer and made a perfectly-conforming sUSDe read as a violation by 1 wei. The
                // bound below is exact, so it neither forgives a real overshoot nor invents one.
                if (p.totalSupply > 0) {
                    assertLe(p.a1 * p.totalSupply, 1e18 * (p.totalAssets + p.donation),
                        string.concat("share price rose beyond the donation's own face value: ", names[i]));
                }
                if (p.a1 > p.a0) {
                    inflating++;
                    emit log_named_uint("  >>> INFLATED bps", (p.a1 - p.a0) * 10000 / p.a0);
                } else {
                    emit log_string("  >>> IMMUNE (share price unchanged)");
                }
                classified++;
            } catch (bytes memory reason) {
                emit log_named_bytes("  (probe REVERTED) reason", reason);
            }
        }
        emit log_named_uint("venues classified", classified);
        emit log_named_uint("venues that INFLATE on donation", inflating);

        // PREMISE 3: the sweep must cover every venue it claims to. The old form swallowed a
        // reverting vault into a log line, so this test could classify ZERO venues and still
        // report PASS — the name says ClassifyAllVenues, so an unclassified venue is a failure,
        // not a footnote. A basket leg nobody can classify is a leg whose donation behaviour is
        // unknown, which is the same exposure as one known to be bad.
        assertEq(classified, N, "every basket 4626 leg must be classifiable (an unprobed leg is an unknown leg)");
    }

    /// Donate up to 100% of `totalAssets` into `v` and return the before/after measurements.
    /// External so the caller can isolate a reverting venue; it deliberately makes NO judgement —
    /// the caller does. `funder` of address(0) mints via `deal`; otherwise the donation is pulled
    /// from that live holder and CLAMPED to what it actually has (the classification needs a large
    /// donation, not exactly 100%, and every bound the caller checks is derived from `p.donation`).
    function probeExt(address v, address funder) external returns (Probe memory p) {
        p.a0 = IERC4626D(v).convertToAssets(1e18);
        address asset = IERC4626D(v).asset();
        p.totalAssets = IERC4626D(v).totalAssets();
        p.totalSupply = IERC4626D(v).totalSupply();
        p.donation = p.totalAssets == 0 ? 1e24 : p.totalAssets; // 100% of totalAssets (maximal signal)
        p.balBefore = IERC20D(asset).balanceOf(v);
        if (funder == address(0)) {
            deal(asset, address(this), p.donation);
        } else {
            uint have = IERC20D(asset).balanceOf(funder);
            if (have < p.donation) p.donation = have;
            vm.prank(funder);
            (bool fok, bytes memory fret) = asset.call(abi.encodeWithSelector(0xa9059cbb, address(this), p.donation));
            require(fok && (fret.length == 0 || abi.decode(fret, (bool))), "funder transfer failed");
        }
        // RAW call, not `IERC20D.transfer`: USDT (and other pre-EIP20 tokens) return NO data
        // from `transfer`, so a typed `returns (bool)` call reverts on ABI decode. Every USDT
        // leg the basket holds was being swallowed by the sweep's catch and reported as
        // "reverted - skipped" for that reason alone — a harness artifact reading as a venue
        // that could not be classified.
        (bool ok, bytes memory ret) = asset.call(abi.encodeWithSelector(0xa9059cbb, v, p.donation));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "donation transfer failed");
        p.balAfter = IERC20D(asset).balanceOf(v);
        p.a1 = IERC4626D(v).convertToAssets(1e18);
    }
}
