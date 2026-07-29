// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
interface ISPq2 { function getCompoundedBoldDeposit(address) external view returns (uint); }
contract ZZBoldProbe is Alles {
    function test_probe() public {
        address bold = AUX.getStables()[AUX.getStables().length - 1];
        address sp = AUX.getVaults(bold)[0];
        emit log_named_address("bold", bold);
        emit log_named_address("sp", sp);
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        vm.prank(User02); V4.deposit{value: 400 ether}(0, User02);
        emit log_named_uint("SP before", ISPq2(sp).getCompoundedBoldDeposit(address(AUX)));
        emit log_named_uint("AUX bold bal before", IERC20(bold).balanceOf(address(AUX)));
        deal(bold, User03, 4000e18);
        vm.startPrank(User03);
        IERC20(bold).approve(address(AUX), 4000e18);
        uint w = AUX.swap(bold, address(WETH), true, 4000e18, 0);
        vm.stopPrank();
        emit log_named_uint("weth out", w);
        emit log_named_uint("SP after", ISPq2(sp).getCompoundedBoldDeposit(address(AUX)));
        emit log_named_uint("AUX bold bal after", IERC20(bold).balanceOf(address(AUX)));
        (uint cb,) = AUX.storedHoldings(bold);
        emit log_named_uint("storedHoldings bold", cb);
    }
}
