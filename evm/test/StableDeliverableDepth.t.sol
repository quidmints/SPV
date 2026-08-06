// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./Alles.t.sol";
import {VaultLib} from "../src/imports/VaultLib.sol";

interface I4626Depth {
    function maxWithdraw(address owner) external view returns (uint);
    function convertToAssets(uint shares) external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
}

interface IDecimals { function decimals() external view returns (uint8); }

/// @title  E101 — how much of the stable leg is actually withdrawable in one block?
/// @notice `_illiquidLoss` DEFERS the undeliverable slice instead of burning it, citing the
///         Aave-v4 GHO reserve at "~78% utilized" (`BasketLib.sol:723-724`). Nobody had
///         measured the DEPTH, so "the deferral is proportionate" was a claim about an
///         unsampled distribution.
///
/// ⚠️ THE CONTROL, and it already caught one wrong answer. A first version of this test read
///    raw `maxWithdraw` and reported a vault at 0% coverage. That is an ARTEFACT:
///    `BasketLib.sol:762-767` records that 6 of 8 registered stable vaults are Morpho-V2 whose
///    max-views are "IDLE-ONLY and report 0 against a fully withdrawable position", holding
///    ~124M of ~126M stable TVL. A maxWithdraw-based metric scores "genuinely illiquid" and
///    "Morpho-V2" IDENTICALLY, so it cannot answer this question at all. `_withdrawableOf` is
///    the ONE definition the contract itself uses; both are printed so the gap stays visible.
contract StableDeliverableDepth is Alles {

    struct Acc {
        uint own18;          // par value of every vault position we hold
        uint deliv18;        // the slice withdrawable NOW, same state
        uint rawDeliv18;     // what a naive maxWithdraw reader would have concluded
        uint seen;
        uint rationed;       // withdrawable < own
        uint empty;          // withdrawable == 0 against a live position
        uint rawZero;        // maxWithdraw == 0 against a live position (the artefact count)
    }

    function _scanVault(Acc memory a, address v, uint scale, uint8 dec) private {
        uint own;
        try I4626Depth(v).balanceOf(address(AUX)) returns (uint sh) {
            if (sh == 0) return;
            try I4626Depth(v).convertToAssets(sh) returns (uint x) { own = x; } catch { return; }
        } catch { return; }
        if (own == 0) return;

        uint deliv = VaultLib._withdrawableOf(v, address(AUX));
        uint raw;
        try I4626Depth(v).maxWithdraw(address(AUX)) returns (uint m) { raw = m; } catch { raw = 0; }

        a.seen++;
        if (deliv == 0) a.empty++;
        else if (deliv < own) a.rationed++;
        if (raw == 0) a.rawZero++;

        a.own18      += own * scale;
        a.deliv18    += (deliv > own ? own : deliv) * scale;
        a.rawDeliv18 += (raw   > own ? own : raw)   * scale;

        emit log_named_address("  vault", v);
        emit log_named_decimal_uint("    own (par)   ", own, dec);
        emit log_named_decimal_uint("    withdrawable", deliv, dec);
        emit log_named_decimal_uint("    rawMaxWithdr", raw, dec);
        emit log_named_uint("    coverage bps", (deliv > own ? own : deliv) * 10_000 / own);
    }

    function test_E101_PerVaultDeliverableCoverage() public {
        Acc memory a;
        address[] memory stables = AUX.getStables();
        emit log_named_uint("stables in basket", stables.length);

        for (uint i = 0; i < stables.length; i++) {
            uint8 dec = IDecimals(stables[i]).decimals();
            address[] memory vs = AUX.getVaults(stables[i]);
            for (uint j = 0; j < vs.length; j++) {
                if (vs[j] != address(0)) _scanVault(a, vs[j], 10 ** (18 - dec), dec);
            }
        }

        emit log("---- AGGREGATE ----");
        emit log_named_uint("vaults with a position", a.seen);
        emit log_named_uint("  rationed (withdrawable < own)", a.rationed);
        emit log_named_uint("  zero-withdrawable", a.empty);
        emit log_named_uint("  maxWithdraw==0 ARTEFACTS", a.rawZero);
        emit log_named_decimal_uint("own total    (18d)", a.own18, 18);
        emit log_named_decimal_uint("withdrawable (18d)", a.deliv18, 18);
        if (a.own18 > 0) {
            emit log_named_uint("DELIVERABLE FRACTION bps", a.deliv18 * 10_000 / a.own18);
            emit log_named_uint("  (naive maxWithdraw would say)", a.rawDeliv18 * 10_000 / a.own18);
        }
        emit log_named_decimal_uint("AUX.illiquidLoss()", AUX.illiquidLoss(), 18);

        // ⚠️ Say out loud what this run can and cannot support.
        if (a.seen == 0) emit log("VOID: no vault position - this run measured NOTHING");
        if (a.seen < 4) emit log("NOTE: fixture holds few vault positions - NOT a sample of a live basket");
    }
}
