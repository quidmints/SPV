// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {DeployLib} from "../src/DeployLib.sol";
import {Basket} from "../src/Basket.sol";
import {Aux} from "../src/Aux.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Deploy target for the Rust channel-DRIVER e2e (quid-bridge/tests/driver_e2e.rs),
// run against a REAL `anvil` MAINNET FORK — NOT a mocked JSON-RPC and NOT a plain
// anvil. The driver submits REAL openChannel / recordClose / requestSwapOutOnchain
// / deliverSwapOutOnchain to the REAL BTCChannels + REAL SPVGateway + the REAL
// Vault stack deployed here.
//
// There is NO StubVault anymore: the SAME shared `DeployLib.deployQuidStack`
// sequence that production (`DeployL1_s.sol`) and the mainnet-fork forge suite
// (`Alles.t.sol`) use stands up the full Vogue/Core/Aux/Basket/Vault topology, so
// the driver e2e exercises the REAL curve economics (creditSwapOut, POOLED_USD_BTC
// pairing, proceeds settlement) — not a divergent double that could drift.
//
//   * SPVGateway — the REAL contract, init at the BITCOIN REGTEST GENESIS (height
//     0). The test's relayer feeds the live regtest header chain (blocks 1..tip)
//     via addBlockHeaderBatch, so checkTxInclusion validates the funding / close /
//     splice SPV proofs for real.
//   * Vault (merged ETH+BTC) — the REAL contract. registerBtcLp (fired by the
//     driver's openChannel) pairs POOLED_USD_BTC against the basket TVL seeded
//     below; requestSwapOutOnchain → creditSwapOut fills the swapper on the REAL
//     BTC curve; deliverSwapOutOnchain settles the LP's proceeds.
//   * BTCChannels — the REAL contract; hopNode = the deployer (PRIVATE_KEY), so
//     the driver's hot key (QUID_HOT_KEY = same key) passes the onlyHop gate.
//
// Seeding: the deployer (anvil acct #0) is pre-funded with USDC by driver-e2e.sh
// (impersonate a mainnet whale). This script votes the BTC share, mints QU!D to
// give the basket TVL (so the driver's registerBtcLp pairs a real POOLED_USD_BTC),
// and leaves the deployer with residual USDC + a standing AUX approval so the Rust
// swap-out (sent from the same acct #0) can pull its committed USD on the real
// vault.
//
// Env: PRIVATE_KEY (hop/deployer). Run via regtest/driver-e2e.sh (mainnet fork).
// ─────────────────────────────────────────────────────────────────────────────

contract Deploy is Script {
    // Bitcoin regtest genesis block header (80 bytes) — deterministic, identical
    // for every regtest instance (matches OpenChannelE2E.t.sol's fixture). The
    // Rust relayer feeds regtest blocks 1..tip on top of this, so the gateway must
    // start at h0 (NOT a mainnet checkpoint).
    bytes constant REGTEST_GENESIS_HEADER =
        hex"0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4adae5494dffff7f2002000000";

    // ── Canonical mainnet addresses (same set as DeployL1_s.sol / Alles.t.sol) ──
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC  = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
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

    address constant SDAI  = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant morphoUsdcVault  = 0xA2EAaD0D586cF9FD73bb2c09cF6A7E3e187D68cd;
    address constant morphoUsdtVault  = 0x71ffB6a81786eC285D429d531Cf655107B9D878d;
    address constant pyusdMorpho      = 0xb576765fB15505433aF24FEe2c0325895C559FB2;
    address constant morphoRlusdVault = 0x6dC58a0FdfC8D694e571DC59B9A52EEEa780E6bf;
    address constant morphoUsdsVault  = 0xE15fcC81118895b67b6647BBd393182dF44E11E0;
    address constant morphoAusdVault  = 0x32401B9fb79065Bc15949DE0BD43927492f02F0C;
    address constant stabilityPool    = 0x5721cbbd64fc7Ae3Ef44A0A3F9a790A9264Cf9BF;
    address constant aaveSpoke = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address constant aaveHub   = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
    address constant GALAXY_VAULT = 0x1878805799273d10aE96a58201A6f5254CF9824F;
    address constant EULER_VAULT  = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
    address constant GAUNTLET_VAULT = 0x43fCd85E8D9D003D515f886891B7C742AC9f92da;

    function run() external {
        uint pk = vm.envUint("PRIVATE_KEY");
        address hop = vm.addr(pk);

        // BOLD MUST stay last (Aux pins stables[length-1] as the SP-routed stable).
        address[] memory stables = new address[](11);
        stables[0]=USDC; stables[1]=USDT; stables[2]=PYUSD; stables[3]=GHO;
        stables[4]=RLUSD; stables[5]=USDG; stables[6]=DAI; stables[7]=USDS;
        stables[8]=USDE; stables[9]=AUSD; stables[10]=BOLD;
        address[] memory vaults = new address[](11);
        vaults[0]=morphoUsdcVault; vaults[1]=morphoUsdtVault; vaults[2]=pyusdMorpho;
        vaults[3]=address(0);      vaults[4]=morphoRlusdVault; vaults[5]=address(0);
        vaults[6]=SDAI;            vaults[7]=morphoUsdsVault;   vaults[8]=SUSDE;
        vaults[9]=morphoAusdVault; vaults[10]=stabilityPool;

        vm.startBroadcast(pk);

        // ── The ONE shared deploy (same as production / the forge suite) ──
        DeployLib.StackAddrs memory A = DeployLib.deployQuidStack(DeployLib.StackConfig({
            poolManager: POOL_MANAGER,
            weth: WETH, wbtc: WBTC, gho: GHO, usdg: USDG,
            usdc: USDC, usdt: USDT, dai: DAI, usde: USDE, usds: USDS,
            morphoUsdcVault: morphoUsdcVault, morphoUsdtVault: morphoUsdtVault,
            morphoUsdsVault: morphoUsdsVault, sdai: SDAI, susde: SUSDE,
            aaveSpoke: aaveSpoke, aaveHub: aaveHub,
            galaxyVault: GALAXY_VAULT, eulerVault: EULER_VAULT, gauntletVault: GAUNTLET_VAULT,
            nfpm: address(0),
            stables: stables, vaults: vaults,
            hopOperator: hop,
            spvCheckpointHeader: REGTEST_GENESIS_HEADER,
            spvCheckpointHeight: 0,
            spvCheckpointWork: 0,
            spvCheckpointFollowers: new bytes[](0),   // (E135) no catch-up needed here
            deployChannels: true
        }));

        // ── Seed the basket so the driver's registerBtcLp pairs POOLED_USD_BTC and
        //    the swap-out fills > 0 on the REAL curve. ──
        Basket quid = Basket(A.quid);
        IERC20(USDC).approve(A.aux, type(uint).max); // standing approval (reused by the Rust swap-out from this acct)
        quid.mint(hop, 150_000e6, USDC, 0);          // TVL: the BTC band pairs against this

        vm.stopBroadcast();

        console.log("QUID_SPV_GATEWAY", A.spvGateway);
        console.log("QUID_BTC_CHANNELS", A.btcChannels);
        console.log("QUID_VAULT", A.vault);
        console.log("QUID_AUX", A.aux);
        console.log("QUID_USDC", USDC);
        console.log("hopNode", hop);
    }
}
