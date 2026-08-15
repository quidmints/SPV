// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Alles} from "./Alles.t.sol";

/// @notice §E199. THE DUAL-VENUE AAVE LEG IS WIRED IN PRODUCTION AND EXERCISED BY NOTHING.
///
///         `DeployL1_s:404-405` calls `setVault(USDC, aaveSpoke)` and `setVault(USDT, aaveSpoke)`;
///         `Alles.t.sol:514-521` gives both their Morpho vaults only. Worse, **no test in the repo
///         deposits USDT at all** — the second-largest stable in the basket had zero deposit coverage.
///         This builds the production wiring through the real owner-gated `setVault` and proves a
///         deposit completes with the spoke in the set.
///
///         ⚠️ USDT RETURNS NO BOOL, so a standard `IERC20.approve` reverts on return-data decode. My
///         first version of this probe hit that and I mis-read it as the SUPPLY PATH failing — and
///         booked that in §E199 as a defect. It is not: with a low-level approve the mint succeeds.
///         The retraction is the reason this file exists as a test rather than a finding.
contract AaveLegDeposit is Alles {
    function test_aaveLegDepositCompletes_withTheSpokeInTheSet() public {
        address spoke = AUX.AAVE_SPOKE();
        vm.startPrank(AUX.owner());
        AUX.setVault(address(USDT), spoke);
        vm.stopPrank();
        emit log_named_uint("USDT reserveId", AUX.reserveIdOf(address(USDT)));
        emit log_named_uint("aaveBalance(USDT)", AUX.aaveBalance(address(USDT)));

        address[] memory vs = AUX.getVaults(address(USDT));
        emit log_named_uint("USDT vault-set size", vs.length);
        for (uint i; i < vs.length; i++)
            emit log_named_address(vs[i] == spoke ? "  member: SPOKE" : "  member: 4626", vs[i]);

        deal(address(USDT), User02, 10_000 * USDC_PRECISION);
        vm.startPrank(User02);
        // USDT returns NO bool, so a standard IERC20.approve reverts on decode. This is the bug my
        // first probe hit and mistook for the supply path failing.
        (bool ok,) = address(USDT).call(abi.encodeWithSignature("approve(address,uint256)", address(AUX), type(uint).max));
        require(ok, "usdt approve");
        uint before = QUID.balanceOf(User02);
        QUID.mint(User02, 10_000 * USDC_PRECISION, address(USDT), 0);
        vm.stopPrank();
        assertGt(QUID.balanceOf(User02), before,
            "USDT deposit minted nothing with the aave spoke in the vault set");
    }
}
