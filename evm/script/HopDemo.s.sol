// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {BTCChannels} from "../src/BTCChannels.sol";

/// Minimal SPV stub — settleSwapIn never touches it (only openChannel/close do).
contract MockSPV {
    fallback() external { assembly { return(0, 0) } }
}

/// Recording Aux: stands in for the real Aux on the daemon-demo EVM so we can
/// observe that the hop's autonomous settleSwapIn call lands a credit. The real
/// creditSwapIn economics are covered by the fork tests; here we prove the
/// LN→EVM BRIDGE (the daemon), not the basket math.
contract MockHopAux {
    // ── swap-IN (BTC→USD): the hop credits the seller after an HTLC settles ──
    address public lastSeller;
    uint    public lastSats;
    address public lastToken;
    uint    public credits;
    event Credited(address seller, uint sats, address token);
    function creditSwapIn(address seller, uint sats, address token) external {
        lastSeller = seller; lastSats = sats; lastToken = token; credits++;
        emit Credited(seller, sats, token);
    }

    // ── swap-OUT (USD→BTC): in production the V4 BTC pool obligates the hop to
    //    deliver native BTC; the daemon pays the swapper's LN invoice and marks
    //    it. (View-based so the daemon reads it with a plain cast call.) ──
    struct SwapOut { uint sats; string invoice; bool paid; }
    SwapOut[] public swapOuts;
    event SwapOutObligated(uint idx, uint sats);
    function obligateSwapOut(uint sats, string calldata invoice) external {
        swapOuts.push(SwapOut(sats, invoice, false));
        emit SwapOutObligated(swapOuts.length - 1, sats);
    }
    function swapOutCount() external view returns (uint) { return swapOuts.length; }
    function markSwapOutPaid(uint i) external { swapOuts[i].paid = true; }
}

/// Deploy the demo stack: MockSPV + MockHopAux + a REAL BTCChannels wired to
/// them, with hopNode = the broadcasting key (the daemon signs settleSwapIn with
/// it). Writes the addresses for the daemon to read.
contract HopDemo is Script {
    function run() external {
        uint pk = vm.envUint("PRIVATE_KEY");
        address hop = vm.addr(pk);
        vm.startBroadcast(pk);
        MockSPV spv = new MockSPV();
        MockHopAux aux = new MockHopAux();
        BTCChannels ch = new BTCChannels(address(spv), address(aux), address(aux), hop);
        vm.stopBroadcast();
        console.log("BTCChannels", address(ch));
        console.log("MockHopAux ", address(aux));
        console.log("hopNode    ", hop);
        vm.writeFile(
            string.concat(vm.projectRoot(), "/test/btc/hopdemo.addrs.json"),
            string.concat('{"ch":"', vm.toString(address(ch)),
                          '","aux":"', vm.toString(address(aux)),
                          '","hop":"', vm.toString(hop), '"}\n'));
    }
}
