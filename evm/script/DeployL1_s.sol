
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/console.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {Vogue} from "../src/Vogue.sol";

import {Basket} from "../src/Basket.sol";
import {Core} from "../src/Core.sol";
import {SorPath} from "../src/imports/SOR.sol";

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {Aux} from "../src/Aux.sol";
import {DeployLib} from "./DeployLib.sol";
import {EthVenue} from "../src/EthVenue.sol";
import {Vault} from "../src/Vault.sol";
import {BTCChannels} from "../src/BTCChannels.sol";
import {SPVGateway} from "../src/spv/SPVGateway.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

// ─── IL-protect (leverage overlay) — deployed IN THIS SAME SCRIPT, gated by DEPLOY_LEV ───
import {LevManager} from "../src/LevManager.sol";
import {BtcLevManager} from "../src/BtcLevManager.sol";
import {MorphoEscrowVenue, MarketParams} from "../src/MorphoEscrowVenue.sol";
import {ISwap} from "../src/imports/ISwap.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3Venue} from "../src/AaveV3Venue.sol";
import {RealRateBtcMorphoOracle} from "../src/imports/LevBase.sol";   // InverseRateMorphoOracle removed with the short subsystem (2026-07-24)

interface IAaveV3AddrProvider { function getPoolDataProvider() external view returns (address); }

interface IMorphoMkt {
    function createMarket(MarketParams memory m) external;
    function market(bytes32 id) external view returns (uint128,uint128,uint128,uint128,uint128,uint128);
}

contract Deploy is Script {

    IPoolManager public poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    // Morpho 4626 vault addresses for blacklistable stables that
    // don't have a natural integration with a specific lender
    // (USDC/USDT/PYUSD/RLUSD). For non-blacklistable stables we use the
    // protocol's own 4626 wrapper (sDAI / sUSDE). USDS uses the Morpho
    // USDS Flagship vault. PYUSD and RLUSD vaults may need to be set
    // post-deploy via Aux.setVault if Morpho hasn't listed them yet
    // — the setter is one-shot per stable.
    // USDC/USDT primaries (slot 0 + the SOR swap-source). Galaxy is the primary;
    // the other hardcoded curators are appended via setVault below (locked at
    // finalize). USDC: Galaxy/Euler/Sky/Wintermute/Rockaway (5). USDT: Galaxy/
    // Euler/Sky (3).
    address public morphoUsdcVault  = 0x91600E31fBeDc72433d4a57F16639cfe661Be7d8; // Galaxy USDC (primary)
    address public morphoUsdtVault  = 0x71ffB6a81786eC285D429d531Cf655107B9D878d; // Galaxy USDT (primary)
    address constant eulerUsdc      = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address constant skyUsdc        = 0x56bfa6f53669B836D1E0Dfa5e99706b12c373ecf;
    address constant wintermuteUsdc = 0x5dc53a23AdC9f2Bed98de6F59F7F309a7c71FF2B;
    address constant rockawayUsdc   = 0xd65d6E8dbC3Cd3D12418199E6f4014dB3aaa0097;
    address constant eulerUsdt      = 0x313603FA690301b0CaeEf8069c065862f9162162;
    address constant skyUsdt        = 0x23f5E9c35820f4baB695Ac1F19c203cC3f8e1e11;
    // Gauntlet-curated Morpho vaults (appended as additional curators, same as euler/sky above).
    address constant gauntletUsdc   = 0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e;
    address constant gauntletUsdt   = 0xE571B648569619566CF6ce1060C97B621CB635D3;
    //  `gauntlet` slot + Vault immutable + supplyGauntlet wrapper, so it's counted/withdrawn/health-checked
    //  identically to Galaxy/Euler. ETH venues are custodied on EthVenue, not via setVault.)
    // USDT0 (USD₮0) REMOVED (2026-07-22, on-chain verified): Tether's omnichain USDT is BY DESIGN not an
    // Ethereum-L1 ERC20 — L1 holds canonical USDT locked in the LayerZero OFT adapter; USDT0 tokens exist
    // only on the spoke chains. The previously-wired token (0x779Ded…3736) and "Gauntlet USDT0 vault"
    // (0xb7Df8d…5c08) have NO CODE on mainnet — a codeless basket stable reverts every all-stables loop
    // (get_deposits/TVL/redeem) the moment it's read: dead-on-arrival by construction. L1 USDT exposure is
    // already slot 1. (Every OTHER hardcoded address in this file was code+role verified the same day.)
    address public morphoPyusdVault = 0xb576765fB15505433aF24FEe2c0325895C559FB2;
    address public morphoRlusdVault = 0x6dC58a0FdfC8D694e571DC59B9A52EEEa780E6bf;
    address public morphoUsdsVault  = 0xE15fcC81118895b67b6647BBd393182dF44E11E0; // Sky Money USDS Flagship
    // ETH-side: WETH supplied to the Galaxy Morpho V2 vault. Standard
    // machine.

    // GHO is AAVE's native stablecoin → routes directly through AAVE v4
    // rather than a third-party Morpho curator. Spoke + Hub addresses
    // below are AAVE v4 mainnet. The reserve id is resolved at Aux
    // construction by `hub.getAssetId(GHO) → spoke.getReserveId(hub, id)`.
    address public aaveSpoke = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address public aaveHub   = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;

    // AAVE v3 mainnet (the DEEPEST WBTC/USDC book — data-verified 2026-07: ~$14-19B TVL) for the WBTC-fallback
    // BTC-leverage venue. Pool + PoolAddressesProvider (→ getPoolDataProvider() for the per-asset position reads
    // AaveV3Venue uses). Both fork-verified in test/AaveV3Venue.t.sol.
    address public aaveV3Pool         = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public aaveV3AddrProvider = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    // ─── Lev-overlay external infra (env-overridable; these are the LIVE mainnet defaults,
    //     verified on-chain + via the Morpho API 2026-07-21) ─────────────────────────────
    // Morpho Blue core + the canonical adaptive-curve IRM (the IRM of every live market below).
    address constant MORPHO_BLUE  = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant ADAPTIVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    // LIVE deep Morpho markets the long legs JOIN (createMarket is skipped when the id already
    // exists): weETH/USDC 86% (~$1.76M supplied) and WETH/USDC 86% (~$3.7M supplied). The oracle
    // addresses are those markets' OWN battle-tested oracles — matching them exactly is what makes
    // the deploy join the deep book instead of creating an empty twin.
    address constant WEETH_USDC_ORACLE = 0x5635a2F38c5dFd1d8fDB176d9CB5AEFA07bf6A68;
    address constant WETH_USDC_ORACLE  = 0x0F948CBa8231Db7898ef36A4212581Ad7b1B4580;
    uint256 constant MORPHO_LLTV_86 = 0.86e18;  // the Morpho-whitelisted LLTV every lev market uses (0.80 is not enabled)
    // The weETH-collateral / WETH-LOAN market: the one venue here whose debt is ETH-denominated, so an
    // ETH IL-protect borrow needs NO stable->WETH SOR round trip. Verified on-chain 2026-08-08 --
    // idToMarketParams(0x37e7484d...472ba7) returns exactly {WETH, weETH, this oracle, ADAPTIVE_IRM, 94.5%},
    // and keccak(abi.encode(those)) recomputes that id, so the five values ARE the market.
    // ⚠️ TWO SIBLING weETH/WETH MARKETS EXIST AT 86% LLTV AND ARE EMPTY ($0.0002 and $2,095 supplied).
    //    They are correctly formed, so a wrong oracle here yields a venue that passes every structural
    //    check and can never fill a borrow. The discriminator is LIQUIDITY, not well-formedness.
    // ── weETH dollar-borrow markets (Morpho, 86% LLTV). The marketId is `keccak256(abi.encode(mp))`,
    //    so `_mkMorphoVenue`'s id assert proves the whole param set — including irm/collateral, which
    //    are inferred rather than looked up.
    // ⚠️ The borrow tokens are the basket's OWN stables — `RLUSD` (18 dec) and `PYUSD` (6 dec) are
    //    already declared below as `IERC20`. Do not re-declare: the lev leg borrows a stable the
    //    basket already holds and prices, which is why no new token wiring is needed.
    address constant RLUSD_WEETH_ORACLE = 0x6ab351FfDe101BB24a97332f4f7162C1711f110b;
    bytes32 constant RLUSD_WEETH_MARKET_ID =
        0xea4bfb18df0ee6bffb7b3f0270899a8adb92ab6b684709634c8276128813cfd4;
    address constant PYUSD_WEETH_ORACLE = 0x221898dA0890Fc5fb6c890Fcdc051FA97946eE11;
    bytes32 constant PYUSD_WEETH_MARKET_ID =
        0x85d59152eeeab7ca024804895b358868d8dd1e134171be400d7792d5604a212c;

    address constant WEETH_WETH_ORACLE = 0xbDd2F2D473E8D63d1BFb0185B5bDB8046ca48a72;
    uint256 constant MORPHO_LLTV_945   = 0.945e18; // this market's own LLTV -- NOT the 86% the USDC legs use
    address constant CL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // Chainlink ETH/USD (8-dec)

    address public stabilityPool = 0x5721cbbd64fc7Ae3Ef44A0A3F9a790A9264Cf9BF;

    // ─── ETH backend: Galaxy Morpho V2 WETH vault ──────────────────────
    // Mainstream ERC4626, Galaxy as curator, yield from Morpho V2
    // adapter system (Aave / Morpho V1 markets / etc.). Single venue —
    // no state machine, no fallback path. If Galaxy itself becomes
    // unviable, the next deploy can swap the vault address; in the
    // interim, ERC4626 share revaluation surfaces any underperformance
    // through the standard deficit-reporting path.
    // Galaxy vault uses WETH as its underlying asset (not ETH).
    // Second WETH 4626 curator: Euler ETH (fungible with Galaxy in the ETH-venue
    // set — counted/withdrawn/health-checked identically). Depositors elect it
    // via VENUE_EULER (5).
    // Third WETH 4626 curator: Gauntlet WETH Morpho (fungible with Galaxy/Euler in
    // the ETH-venue set — counted/withdrawn/health-checked identically). Depositors
    // elect it via VENUE_GAUNTLET.

    // v3 router) is read from Aux's immutable constants at deploy (single source
    // of truth), so it can never drift from what the offramp uses.
    address constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    // ANGEL seed NFT: the Safe (deployer) MUST own Foundation tokenId Basket.ANGEL (16508). DeployLib approves
    // Aux for it mid-deploy and Basket's constructor requires that approval, so the commitment is enforced at
    // Basket's birth; Aux burns it (owner→DEAD) at finalize. No token-id/approve constants needed here.

    IERC20 public WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20 public GHO = IERC20(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
    IERC20 public DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 public USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 public USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    /// @notice PYUSD ERC20. No vault is wired at deploy: PYUSD does not
    /// yet have a Morpho vault listed. Anyone may call
    /// `Aux.setVault(PYUSD, vaultAddress)` once Morpho lists it.
    IERC20 public PYUSD = IERC20(0x6c3ea9036406852006290770BEdFcAbA0e23A0e8);
    IERC20 public USDS = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);
    IERC20 public USDE = IERC20(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
    IERC20 public BOLD = IERC20(0x6440f144b7e50D6a8439336510312d2F54beB01D);
    // Liquity V2 WETH-branch (fork-verified in test/LiquityVenue.t.sol) — the LONG BOLD-borrow lev venue's deps.
    address public liquityBorrowerOps = 0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65;
    address public liquityTroveManager = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    /// @notice RLUSD ERC20. Same story as PYUSD: vault wired post-deploy
    /// via permissionless `Aux.setVault` once Morpho lists it.
    IERC20 public RLUSD = IERC20(0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD);

    IERC4626 public SDAI = IERC4626(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
    IERC4626 public SUSDE = IERC4626(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);

    /// @notice USDG — Global Dollar by Paxos. Routes through AAVE v4
    /// alongside GHO (both first-class assets on the AAVE v4 spoke, which also
    /// lists WETH for ETH venue 2).
    IERC20 public USDG = IERC20(0xe343167631d89B6Ffc58B88d6b7fB0228795491D);

    /// @notice aUSD — Agora dollar. Standard Morpho 4626 vault wiring.
    IERC20 public AUSD = IERC20(0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a);
    address public morphoAusdVault = 0x32401B9fb79065Bc15949DE0BD43927492f02F0C;

    /// @notice cUSD — Cap USD (a stablecoin backed by a basket of regulated dollar
    /// stables). Fork-verified 2026-07-21 against mainnet: standard 18-dec ERC20 with
    /// permissionless transfers (transfer→fresh EOA and →contract both succeed) and NO
    /// blacklist/allowlist surface (only a global paused()==false, same trust surface as
    /// USDC/USDT). Its native ERC-4626 stcUSD (asset()==cUSD, convertToAssets(1e18)≈1.07)
    /// wires exactly like sDAI/sUSDE — no adapter needed. Priced by the Redstone cUSD/USD
    /// feed (AggregatorV3, 8-dec, ~$0.9998) so the mint depeg-gate reads it like any stable.
    IERC20 public CUSD = IERC20(0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC);
    IERC4626 public STCUSD = IERC4626(0x88887bE419578051FF9F4eb6C858A951921D8888);

    address[] public STABLECOINS;
    address[] public VAULTS;

    Basket public QUID;
    Core public CORE;
    Vogue public V4;
    Aux public AUX;
    LevManager public LEVM;           // lev overlay (0x0 when DEPLOY_LEV unset)
    BtcLevManager public BTCLEVM;
    Vault public ETH;   // merged Vault — ETH-venue face
    Vault public BTC;   // ...and BTC face (same instance, BTC == ETH)

    /// §J.2b: the vETH ERC-4626 IDENTITY (stateless projection over Vogue). Integrators PRICE against
    /// this and TRANSACT against Vogue, which is the two-asset band manager and not itself a 4626.

    function run() public {
        string memory privateKeyStr = vm.envString("PRIVATE_KEY");
        uint deployerPrivateKey;
        if (bytes(privateKeyStr).length > 2 &&
            bytes(privateKeyStr)[0] == 0x30 &&
            bytes(privateKeyStr)[1] == 0x78) {
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        } else {
            deployerPrivateKey = vm.parseUint(
                string(abi.encodePacked("0x", privateKeyStr)));
        }

        address deployer = vm.addr(deployerPrivateKey);
        console.log("=== Pre-broadcast ===");
        console.log("Deployer:", deployer);

        // NOTE: BOLD MUST be the LAST entry — Aux pins `stables[length-1]` as the
        // Liquity-SP-routed stable (get_deposits/calcSPValue, take/redeem at
        // Aux.sol:967/1119/1426). AUSD at 9, cUSD at 10, BOLD LAST at 11.
        STABLECOINS = [
            address(USDC), address(USDT),
            address(PYUSD), address(GHO),
            address(RLUSD), address(USDG),
            address(DAI), address(USDS),
            address(USDE), address(AUSD),
            address(CUSD),               // 10  cUSD — Cap USD (native stcUSD 4626 vault)
            address(BOLD)                // 11  BOLD — MUST stay last (SP-routed)
        ];

        vm.startBroadcast(deployerPrivateKey);

        VAULTS = [
            morphoUsdcVault,            // 0  USDC  -> Morpho USDC 4626 vault
            morphoUsdtVault,            // 1  USDT  -> Morpho USDT 4626 vault
            morphoPyusdVault,           // 2  PYUSD -> Morpho PYUSD 4626 vault
            address(0),                 // 3  GHO   -> AAVE v4 (not a 4626)
            morphoRlusdVault,           // 4  RLUSD -> Morpho RLUSD 4626 vault
            address(0),                 // 5  USDG  -> AAVE v4 (not a 4626)
            address(SDAI),              // 6  DAI   -> sDAI (native 4626)
            morphoUsdsVault,            // 7  USDS  -> Morpho USDS 4626 vault
            address(SUSDE),             // 8  USDE  -> sUSDE (native 4626)
            morphoAusdVault,            // 9  aUSD  -> Morpho aUSD 4626 vault
            address(STCUSD),            // 10 cUSD  -> stcUSD (native 4626, asset()==cUSD)
            stabilityPool               // 11 BOLD  -> Liquity SP (LAST = SP-routed, per Aux convention)
        ];
        // GHO and USDG route through AAVE v4 (their native venue), not
        // Morpho 4626 vaults — their slots above are address(0)
        // intentionally and Aux.setVault rejects a re-wiring attempt
        // for either. The AAVE spoke + hub are passed to Aux's
        // constructor below; Aux resolves and caches both reserve ids
        // there.
        //
        // Stables that don't yet have a Morpho vault (PYUSD, RLUSD if
        // those slots are address(0)) start unwired. Once Morpho lists
        // them, anyone can call `AUX.setVault(stable, vaultAddress)`,
        // which validates the vault implements the ERC4626 surface,
        // then sets it permanently. The setter is one-shot per stable
        // and blocks GHO/USDG explicitly.

        // ─── ONE canonical deploy + wiring (shared VERBATIM with test/Alles.t.sol
        //     setUp and script/DriverE2E.s.sol) — the single source of truth for
        //     the QU!D contract topology lives in src/DeployLib.sol. ───
        // Checkpoint init: operator supplies a recent Bitcoin block as the initial
        // trusted reference (genesis init would require processing ~800k+ blocks
        // before the gateway is usable). Export from a Bitcoin node:
        //   BTC_CHECKPOINT_HEADER (80-byte hex) / _HEIGHT (decimal) / _WORK.
        bytes memory checkpointHeader = vm.envBytes("BTC_CHECKPOINT_HEADER");
        uint64 checkpointHeight = uint64(vm.envUint("BTC_CHECKPOINT_HEIGHT"));
        uint256 checkpointWork = vm.envUint("BTC_CHECKPOINT_WORK");
        require(checkpointHeader.length == 80, "BTC_CHECKPOINT_HEADER: 80 bytes");
        require(checkpointHeight > 0, "BTC_CHECKPOINT_HEIGHT: required");
        // Operator hop node: the public half of a standard secp256k1 keypair the
        // operator generates on their own signing machine. Every BTCChannels fn is
        // permissionless (sigs gate them), so the hop's per-channel LDK funding key
        // is supplied per open; this is just the address that may rotate the hop.
        address operatorHop = vm.envOr("HOP_NODE_OPERATOR", deployer);
        // (E164) The two addresses that may operate a channel, pinned at construction and never
        // settable. Defaulting the fallback to the deployer is a DEV convenience — on mainnet both
        // must be real, separately-keyed operator addresses, or the fallback protects nothing.
        address mainHop_ = vm.envOr("HOP_MAIN", operatorHop);
        address fallbackHop_ = vm.envOr("HOP_FALLBACK", deployer);

        DeployLib.StackAddrs memory A = DeployLib.deployQuidStack(DeployLib.StackConfig({
            poolManager: poolManager,
            mainHop: mainHop_, fallbackHop: fallbackHop_,
            btcDepositKey: vm.envOr("BTC_DEPOSIT_KEY", bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798))),
            weth: address(WETH), wbtc: address(WBTC), gho: address(GHO), usdg: address(USDG),
            usdc: address(USDC), usdt: address(USDT), dai: address(DAI),
            usde: address(USDE), usds: address(USDS),
            morphoUsdcVault: morphoUsdcVault, morphoUsdtVault: morphoUsdtVault,
            morphoUsdsVault: morphoUsdsVault, sdai: address(SDAI), susde: address(SUSDE),
            aaveSpoke: aaveSpoke, aaveHub: aaveHub,
            nfpm: NFPM,
            stables: STABLECOINS, vaults: VAULTS,
            hopOperator: operatorHop,
            spvCheckpointHeader: checkpointHeader,
            spvCheckpointHeight: checkpointHeight,
            spvCheckpointWork: checkpointWork,
            // (E135) PRODUCTION MUST SUPPLY THESE: the headers following the checkpoint. They
            // catch the gateway up (it knows one block after init and cannot vouch for a tx in
            // any other) AND prove the checkpoint is canonical — an orphaned one cannot be
            // linked to, so the deploy reverts here instead of bricking silently later.
            spvCheckpointFollowers: _spvCheckpointFollowers(),
            allowUnburiedCheckpoint: false,   // (E135-b) PRODUCTION: the checkpoint MUST be buried; followers above prove it
            deployChannels: true
        }));
        V4 = Vogue(payable(A.v4));
        CORE = Core(A.core);
        AUX = Aux(payable(A.aux));
        QUID = Basket(A.quid);
        ETH = Vault(payable(A.vault));
        BTC = ETH;
        SPVGateway spvGateway = SPVGateway(A.spvGateway);
        BTCChannels btcChannels = BTCChannels(A.btcChannels);

        // ─── External anchors ──────────────────────────
        // Pin the Chainlink anchors so getTWAPforAsset cross-checks the internal
        // observation-ring TWAP against a live feed (defeats the multi-block
        // internal-TWAP grind; the body defers safely on stale/zero/reverting).
        // setAssetFeed/setStableFeed are onlyOwner + pin-once → MUST run here,
        // before the finalize renounce. OPERATOR: VERIFY every feed address
        // against docs.chain.link before mainnet — a wrong-but-live feed feeds
        // bad prices (it won't "defer"). ETH/USD + BTC/USD are the canonical
        // mainnet aggregators; add setStableFeed(<stable>, <USD feed>) per stable.
        AUX.setAssetFeed(address(WETH), CL_ETH_USD);                                 // ETH/USD
        AUX.setAssetFeed(address(WBTC), 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c); // BTC/USD
        // Per-stable USD feeds — the CRE-INDEPENDENT depeg backstop (FeeLib.liveDepegBps;
        // riskFactor = max(CRE severity, owner override, liveDepegBps)). This is NOT just
        // a fallback for missing CRE coverage: it works immediately at launch (no CRE
        // first-report dependency) and survives a CRE outage on the DEPOSIT path (creStale
        // only halts redemption). 10 of the 11 basket stables have a Chainlink USD feed —
        // ALL pinned here. Only BOLD has none (Liquity redemption floor; it does not
        // market-depeg → CRE-only is fine). The feed ADDRESSES come from two sources:
        //   • USDC/USDT/DAI: canonical EAC proxies, description()- AND historical-depeg-
        //     verified (USDC $0.907 / DAI $0.932 @ SVB blk 16,805,000, USDT $0.988 @ UST).
        //   • PYUSD/GHO/USDS/USDE: Chainlink Feed Registry getFeed(stable,USD).
        //   • RLUSD/USDG/AUSD: PROXY-ONLY feeds — they exist but are NOT in the legacy Feed
        //     Registry (getFeed reverts), so they're resolved from Chainlink's canonical
        //     data.eth ENS namespace (<feed>.data.eth) and verified on-chain (description +
        //     decimals + ~$1 spot, 2026-06). This is WHY they're pinned here rather than
        //     resolved from the Chainlink Feed Registry — which can't see proxy-only feeds.
        //     NOTE AUSD/USD reports 18 decimals (not 8); liveDepegBps reads decimals()
        //     dynamically, so the scaling is correct.
        // OPERATOR: re-verify every address against docs.chain.link before mainnet — a
        // wrong-but-live feed feeds bad prices (it won't "defer").
        AUX.setStableFeed(address(USDC),  0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6); // USDC/USD (canonical proxy)
        AUX.setStableFeed(address(USDT),  0x3E7d1eAB13ad0104d2750B8863b489D65364e32D); // USDT/USD (canonical proxy)
        AUX.setStableFeed(address(DAI),   0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9); // DAI/USD  (canonical proxy)
        AUX.setStableFeed(address(PYUSD), 0x39E31761911b9aaBAEF5fb81B18Fd1C24a60E884); // PYUSD/USD
        AUX.setStableFeed(address(GHO),   0xff221Bf2E61B62182210b3d42dE7f77da5b5b41F); // GHO/USD
        AUX.setStableFeed(address(USDS),  0x592700e4FcDd674dC54d2681DED3B63f54F63f9A); // USDS/USD
        AUX.setStableFeed(address(USDE),  0xcC16f670129f965b396f2e81312F6e339FFDB18e); // USDe/USD
        AUX.setStableFeed(address(RLUSD), 0x26C46B7aD0012cA71F2298ada567dC9Af14E7f2A); // RLUSD/USD (proxy-only, via ENS)
        AUX.setStableFeed(address(USDG),  0x14f0737d6b705259e521EA6E9E3506AC78dBd311); // USDG/USD  (proxy-only, via ENS)
        AUX.setStableFeed(address(AUSD),  0xB00341502DfEA6Ced8A5786b4059d29dA5E4D1FD); // AUSD/USD  (proxy-only, 18-dec, via ENS)
        AUX.setStableFeed(address(CUSD),  0x9A5a3c3Ed0361505cC1D4e824B3854De5724434A); // cUSD/USD (Redstone AggregatorV3, 8-dec, ~$1.00)
        // BOLD: no Chainlink feed exists → CRE-only (+ owner severityOverride). It does not
        // market-depeg (Liquity redemption floor), so the absence is fine. The basket set is
        // frozen at finalize, so no other stable can ever appear needing a feed — hence no
        // post-renounce feed-binding mechanism is needed.

        // ─── Hardcoded curator set (frozen at finalize) ─────────────────────
        // Galaxy primaries are wired via the VAULTS array at construction; append
        // the remaining hardcoded curators (USDC: +Euler/Sky/Wintermute/Rockaway
        // = 5; USDT: +Euler/Sky = 3). setVault is onlyOwner + self-checks
        // asset()==stable; the finalize renounce then freezes the set — no vaults
        // can be added after deployment.
        AUX.setVault(address(USDC), eulerUsdc);
        AUX.setVault(address(USDC), skyUsdc);
        AUX.setVault(address(USDC), wintermuteUsdc);
        AUX.setVault(address(USDC), rockawayUsdc);
        AUX.setVault(address(USDT), eulerUsdt);
        AUX.setVault(address(USDT), skyUsdt);
        AUX.setVault(address(USDC), gauntletUsdc);   // + Gauntlet-curated Morpho (USDC: 6 curators)
        AUX.setVault(address(USDT), gauntletUsdt);   // + Gauntlet-curated Morpho (USDT: 4 curators)

        // ─── DUAL-VENUE: add the AAVE-v4 spoke as a router venue for USDC/USDT ──
        // The automatic least-full router can now route USDC/USDT to AAVE-v4 in
        // ADDITION to their 4626 curators (curator-risk diversification). The
        // spoke is SHARED across GHO/USDG/USDC/USDT; setVault resolves the
        // per-stable reserve-id and approves the spoke. Not a depositor choice.
        AUX.setVault(address(USDC), aaveSpoke);
        AUX.setVault(address(USDT), aaveSpoke);

        // ─── IL-protect leverage overlay (opt-in, SAME script) ────────────
        // The ONE deploy script also stands up the ETH (weETH) + BTC (vBTC) leverage
        // managers + escrow venues and pins every link, when DEPLOY_LEV=1. Runs
        // BEFORE finalize so all GOV/owner pins land inside this broadcast. Skipped
        // (no lev-infra env required) for a core/fork deploy.
        _deployLeverageOverlay(deployer);

        // ─── All-or-nothing deploy finalize (NO governance handoff, adminless) ──────────
        // Every admin key is RENOUNCED — no multisig handoff. The ANGEL seed commitment already happened
        // mid-deploy: DeployLib approved Aux for the Foundation NFT and Basket's constructor REQUIRED that
        // approval, so a Safe that didn't own ANGEL could never have produced a live Basket. Finalize is two
        // Safe (owner) calls, each contract self-renouncing as its own owner (no _transferOwnership): AUX.finalize()
        // asserts EVERY cross-contract linkage equals Aux's owner-set view (a front-run malicious-but-non-zero pin
        // in an ungated setter reverts HERE), burns ANGEL (owner()→DEAD via Aux's approval), then renounces Aux;
        // then the Safe renounces Basket. The assert runs FIRST, so a mis-wire reverts before anything renounces
        // or burns → all-or-nothing. One-shot (ANGEL burned + owners zeroed) ⇒ renounced EXACTLY once. No skip:
        // the fork harness gives the deployer ANGEL up front, so this runs identically to production.
        // BTCChannels is NOT renounced: it owns rotateHopNode() — the operator's lever to replace a
        // lost/compromised hop key. Renouncing would strand the channel system on a dead hop. It stays
        // deployer-owned; the operator should transferOwnership to a multisig for production.
        AUX.finalize();                          // assert wiring + burn ANGEL + renounce Aux
        Ownable(address(QUID)).renounceOwnership();  // Safe renounces Basket (owner == deployer, no _transferOwnership)

        console.log("=== Deployed Addresses ===");
        console.log("V4 (Vogue):", address(V4));
        console.log("CORE (Core):", address(CORE));
        console.log("AUX:", address(AUX));
        console.log("QUID (Basket):", address(QUID));
        console.log("SPVGateway:", address(spvGateway));
        console.log("BTCChannels:", address(btcChannels));

        vm.stopBroadcast();

        // ─── Deployment record (COMMITTED — the SPA/indexer read THIS, never env) ───
        // Written on every run, including a broadcast-less dry-run: the simulated
        // addresses equal the later real broadcast's as long as the deployer's nonce
        // hasn't moved in between (CREATE addresses are pure f(deployer, nonce)).
        string memory j = "l1";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "deployer", deployer);
        vm.serializeAddress(j, "basket", address(QUID));
        vm.serializeAddress(j, "aux", address(AUX));
        vm.serializeAddress(j, "vogue", address(V4));
        vm.serializeAddress(j, "core", address(CORE));
        vm.serializeAddress(j, "vault", address(ETH));
        vm.serializeAddress(j, "spvGateway", address(spvGateway));
        vm.serializeAddress(j, "btcChannels", address(btcChannels));
        vm.serializeAddress(j, "levManager", address(LEVM));
        vm.serializeAddress(j, "btcLevManager", address(BTCLEVM));
        vm.writeJson(vm.serializeUint(j, "checkpointHeight", checkpointHeight), "deployments/l1.json");
    }

    /// @notice OPT-IN (`DEPLOY_LEV=1`) IL-protect overlay — deployed + wired IN THIS SAME SCRIPT (there is
    ///   NO separate deploy script). Stands up BOTH leverage managers and their escrow venues, and pins EVERY
    ///   link the running system needs so the feature is live the moment the deploy lands:
    ///     ETH (weETH collateral): LevManager (folded SOR + ether.fi mint/redeem legs) → Morpho + Euler escrow
    ///       venues → `pinVenues` (frozen) → `setFlashProvider` (Morpho, zero-fee de-lever) →
    ///       `setVogueSyncHook` (Vogue) → `Vault.setLevManager` (backing: vogueETH counts the book).
    ///     BTC (vBTC collateral == the Vault): BtcLevManager → Morpho (and optional Euler) escrow venue →
    ///       `pinVenue` (singular, frozen) → `setSyncHook`(Vault.syncLevBTC) → `Vault.setLevManagerBTC`
    ///       (backing: vogueBTC counts the book). No swapper / no flash — BTC acquisition is external+async.
    ///   Skipped when `DEPLOY_LEV` is unset, so a core / fork-e2e deploy needs no lev-infra env. External-infra
    ///   addresses come from env; the in-script tokens (weETH via the ETH venue, WBTC/USDC/AUX/V4) are reused.
    ///   GOV (`YB_GOV`, default = deployer) must be the broadcaster so the pin-once calls land, then has no
    ///   ongoing power (allowlist + hooks frozen). ENV (only when DEPLOY_LEV=1) — EVERY external address has a
    ///   LIVE mainnet default (the constants above), so a bare `DEPLOY_LEV=1` deploys the whole overlay;
    ///   overrides: MORPHO, MORPHO_ORACLE/IRM/LLTV (weETH long), MORPHO_WETH_ORACLE/IRM/LLTV (plain-WETH long),
    ///   MORPHO_VBTC_IRM/LLTV; optional YB_GOV. (The EULER_* pair vars and LEV_BTC_VENUE went with
    ///   Euler v2 borrowing, 2026-08-13.)
    ///   MORPHO_VBTC_ORACLE cannot pre-exist (it prices vBTC through AUX, deployed THIS broadcast) — unset ⇒ a
    ///   RealRateBtcMorphoOracle is deployed inline. (Down-side short venues REMOVED 2026-07-24 — up-side-only;
    ///   the short subsystem was an LVR leak, see docs §J.4. A directional-short product, if shipped, is a normal
    ///   position on an inverse venue added to the allowlist, per §K — not the removed hedge.)
    /// (E135) Raw 80-byte headers following `spvCheckpointHeader`, oldest first, supplied as a
    /// JSON array in `SPV_CHECKPOINT_FOLLOWERS`. They catch the gateway up — after init it
    /// knows ONE block and cannot vouch for a tx in any other — and, because an orphaned
    /// checkpoint cannot be linked to, submitting them makes a bad checkpoint fail the DEPLOY
    /// rather than brick the gateway silently later. Empty is allowed (leaves today's
    /// behaviour); a real deployment must set it.
    function _spvCheckpointFollowers() internal view returns (bytes[] memory) {
        string memory raw = vm.envOr("SPV_CHECKPOINT_FOLLOWERS", string(""));
        if (bytes(raw).length == 0) return new bytes[](0);
        return vm.parseJsonBytesArray(raw, "$");
    }

    function _deployLeverageOverlay(address deployer) internal {
        if (!vm.envOr("DEPLOY_LEV", false)) { console.log("[DEPLOY_LEV unset] leverage overlay skipped"); return; }
        address gov    = vm.envOr("YB_GOV", deployer);
        address morpho = vm.envOr("MORPHO", MORPHO_BLUE);
        address weeth  = EthVenue(payable(AUX.ethVenue())).WEETH();

        // ── ETH leverage: weETH-collateral leverage. Swaps reuse the basket SOR (stable↔WETH, sorSelfFunded) + the
        //    ether.fi adapter/redeemer (weETH↔WETH) — no bespoke swapper contract (RealWeethSwapper is gone). ──
        LevManager lm = new LevManager(weeth, address(AUX), address(WETH), gov, address(QUID));
        // ONE atomic pin-once: hook (Vogue) + flash (Morpho, zero-fee de-lever) + the audited venues (weETH
        // Morpho, weETH Euler, WETH Morpho, + optional WETH-debt short), then FROZEN. The venue array is built in
        // its own frame (_ethLevVenues) so this method stays within the legacy stack (no via_ir).
        lm.init(address(V4), morpho, _ethLevVenues(morpho, address(lm), weeth));
        // BACKING: vogueETH counts the ETH lev book. PINNED ON EthVenue, not the Vault — `_ethCfg`
        // lives there now, and `Core`/`VogueLib`/`BasketLib` all read `LEV_MANAGER()` THROUGH the
        // `ethVenue` pointer. Pinning the wrong one compiles and silently reads leverage as disabled.
        EthVenue(payable(AUX.ethVenue())).setLevManager(address(lm));

        // ── BTC lev: vBTC-collateral (vBTC == the Vault). External+async acquisition ⇒ no swapper/flash ──
        BtcLevManager bm = new BtcLevManager(address(ETH.VBTC()), address(AUX), address(WBTC), gov, address(QUID));
        address mvB;
        {
            // The vBTC oracle prices the Vault through AUX (deployed THIS broadcast) — it can only
            // exist inline. Env override kept for a re-deploy against an already-live stack.
            address vbOracle = vm.envOr("MORPHO_VBTC_ORACLE", address(0));
            if (vbOracle == address(0)) vbOracle = address(new RealRateBtcMorphoOracle(address(AUX), address(WBTC)));
            MarketParams memory mpB = MarketParams({
                loanToken: address(USDC),
                // §J.2: the collateral is the vBTC TOKEN, not the Vault. The Vault deploys VBtc in its
                // own constructor and no longer carries balances, so pointing this at `ETH` would give
                // the market a collateral token where every balance reads zero.
                collateralToken: address(ETH.VBTC()),
                oracle: vbOracle, irm: vm.envOr("MORPHO_VBTC_IRM", ADAPTIVE_IRM),
                lltv: vm.envOr("MORPHO_VBTC_LLTV", MORPHO_LLTV_86)
            });
            bytes32 idB = keccak256(abi.encode(mpB));
            (,,,,uint128 luB,) = IMorphoMkt(morpho).market(idB);
            if (luB == 0) IMorphoMkt(morpho).createMarket(mpB);
            mvB = address(new MorphoEscrowVenue(morpho, mpB, address(bm)));
        }
        // NO VENUE SELECTION. `LEV_BTC_VENUE` chose between Euler and Morpho; Euler v2 borrowing is
        // removed (owner, 2026-08-13), so the switch had one arm and the env var was friction pretending
        // to be configuration. Morpho is the BTC lev venue; Aave V3 remains for the WBTC fallback below.
        address pin = mvB;
        require(pin != address(0), "BTC lev venue not deployed");
        // WBTC-FALLBACK venue (#106/#81/#74): a REAL Aave v3 {collateral: WBTC, debt: USDC} escrow — the deepest
        // WBTC book, so the SPA routes sizeable positions here. The keeper's atomic `rebalanceWbtc` folds up /
        // flash-repay-first de-levers it fully on-chain (no channel-vBTC, no acquirer). Allowlisted ALONGSIDE the
        // native vBTC venue — `openBtcLev` branches on the venue's COLLATERAL() (WBTC ⇒ LP brings external WBTC).
        address wbtcV = address(new AaveV3Venue(
            aaveV3Pool, IAaveV3AddrProvider(aaveV3AddrProvider).getPoolDataProvider(),
            address(WBTC), address(USDC), address(bm), vm.envOr("AAVE_V3_WBTC_LT_BPS", uint256(7800))));
        address[] memory vsB = new address[](2); vsB[0] = pin; vsB[1] = wbtcV;
        bm.init(address(ETH), morpho, vsB);                // atomic pin-once: hook + Morpho flash provider + venue allowlist, FROZEN
        ETH.setLevManagerBTC(address(bm));                 // BACKING: vogueBTC counts the BTC lev book
        // Both lev-manager slots are one-shot pins (`LevManagerPinned`) and are the Vault's ONLY
        // owner-gated functions, so with both set the owner has nothing left to call. Renounce.
        Ownable(address(ETH)).renounceOwnership();

        LEVM = lm; BTCLEVM = bm;                           // recorded into deployments/l1.json
        console.log("LevManager (ETH weETH):", address(lm));
        console.log("BtcLevManager (vBTC):", address(bm));
    }

    /// @dev Create the Morpho market if unlisted, then a MorphoEscrowVenue bound to `mgr`. Own frame keeps the
    ///      market-existence check (id/lu temporaries) out of the caller's stack (no via_ir).
    /// @dev 🔴 A WRONG PARAM MUST NOT SILENTLY BECOME AN EMPTY MARKET. `market(id)` keys off
    ///      `keccak256(abi.encode(mp))`, so ONE wrong field — oracle, irm, lltv — is a DIFFERENT market
    ///      that does not exist yet. This used to `createMarket` it unconditionally and carry on, which
    ///      is how six weETH/USDC 86% markets exist on mainnet with FIVE of them at $0.00M: the deploy
    ///      would allowlist a venue over an empty twin and every borrow against it would find no
    ///      liquidity, with nothing having reverted.
    ///      Creation is now OPT-IN (`MORPHO_ALLOW_CREATE`, default false) so mainnet FAILS LOUD on a
    ///      typo'd constant, while a fresh chain / fork can still bootstrap deliberately.
    ///      ⚠️ Existence is NOT depth: `lu != 0` only proves the market was created. Borrowable depth
    ///      is IDLE liquidity (supply − borrow), and utilisation on these runs ~90%, so a market can
    ///      exist, look well-supplied, and still lend nothing. Pin depth separately.
    /// @dev Overload taking the market's KNOWN id. The id IS `keccak256(abi.encode(mp))`, so asserting it
    ///      proves EVERY field reconstructs the intended market — including the ones we infer rather than
    ///      look up (irm, collateralToken). A wrong inference reverts here instead of becoming a twin.
    function _mkMorphoVenue(address morpho, MarketParams memory mp, address mgr, bytes32 wantId)
        internal returns (address) {
        require(keccak256(abi.encode(mp)) == wantId, "morpho: params do not reconstruct the known marketId");
        return _mkMorphoVenue(morpho, mp, mgr);
    }

    function _mkMorphoVenue(address morpho, MarketParams memory mp, address mgr) internal returns (address) {
        bytes32 id = keccak256(abi.encode(mp));
        (,,,,uint128 lu,) = IMorphoMkt(morpho).market(id);
        if (lu == 0) {
            require(vm.envOr("MORPHO_ALLOW_CREATE", false),
                "morpho: market does not exist -- a wrong oracle/irm/lltv is a DIFFERENT market, not a missing one");
            IMorphoMkt(morpho).createMarket(mp);
        }
        return address(new MorphoEscrowVenue(morpho, mp, mgr));
    }

    /// @notice Build the ETH LevManager's frozen venue array in its own frame: [weETH Morpho, weETH Euler, WETH
    ///         Morpho]. WETH is
    ///         ETH-denominated and shares POOLED_ETH with weETH; the manager derives collateral type from the
    ///         venue's collateral token (WETH ⇒ 1:1 valuation + SOR-only legs, no ether.fi mint/redeem).
    ///
    /// ⚠️ RE-CORRECTED 2026-08-09 — an earlier correction on this line was itself WRONG and is retracted.
    ///    It claimed "`init` does NO such detection". THE `stable()==WETH` DETECTION DOES EXIST, one frame
    ///    down: `init` calls `LevMath.vetVenue(v, WETH, WETH, WEETH)` and `vetVenue` opens with
    ///    `if (ILevVenueColl(v).stable() == base) return true;` (LevMath.sol:254) where `base` IS `WETH`.
    ///    What is true is only the CONSEQUENCE: `init` DISCARDS the returned `isShort`, so no short
    ///    behaviour follows — the venue is simply allowlisted.
    ///
    /// 🔴 BUT THAT EARLY RETURN SKIPS THE COLLATERAL-SET GATE. For a WETH-DEBT venue, `vetVenue` returns
    ///    BEFORE `coll != c0 && coll != c1 -> revert BadCollateral()` (LevMath.sol:255-256). That gate is
    ///    the one LevManager.sol:206-208 calls "the rug the frozen allowlist stops": collateral outside
    ///    {WETH, weETH} "silently misvalues into phantom ETH backing" via `_collToEth`. So ANY WETH-debt
    ///    venue is allowlistable with ARBITRARY, UNVALIDATED collateral. The venue added below is benign
    ///    (its collateral IS weETH), but it is the FIRST venue to reach the allowlist through the
    ///    unchecked branch, and the hole is generic. Booked in QUEUE; do not add a second WETH-debt venue
    ///    until the gate covers this path.
    ///
    /// 📌 EVERY VENUE HERE BORROWS **USDC**, which is why an ETH-denominated IL-protect borrow currently pays
    ///    a stable→WETH SOR round trip. A weETH-collateral/WETH-loan Morpho market EXISTS and is deep
    ///    (id `0x37e7484d…472ba7`, 94.5% LLTV, 1,770 WETH liquid, verified on-chain 2026-08-08 — see QUEUE).
    ///    Adding it here removes that round trip entirely. The plumbing is already in place and inert:
    ///    `LevMath._stableToWethSor`/`_wethToStableDex` short-circuit when `stable == c.weth`, and
    ///    `_fromUsd`/`_toUsd18` are now price-aware, so a WETH loan token sizes off the ETH price rather
    ///    than silently assuming $1. NOT ADDED YET: it is a money-path change and needs its own verified run.
    function _ethLevVenues(address morpho, address lm, address weeth) internal returns (address[] memory vs) {
        // MORPHO ONLY. Euler v2 and Aave v4 BORROWING are removed; the BTC side keeps Aave V3 for WBTC.
        // RLUSD and PYUSD weETH markets — added because the market we shipped CANNOT LEND. Measured:
        //   weETH/USDC 86% (shipped)  supply $0.74M median, IDLE $0.17M, 100 of 100 weeks under $1M
        //   weETH/RLUSD 86%           supply $95.00M,       IDLE $9.66M
        //   weETH/PYUSD 86%           supply $47.14M,       IDLE $4.32M
        // BORROWABLE DEPTH IS IDLE, NOT SUPPLY (utilisation ~90% across all of them), so this takes the
        // dollar leg from ~$0.17M to ~$14.2M — roughly 85×. USDC is DEMOTED, not deleted: it is the only
        // 100-week dollar market, and thin-always is a measured fact while young-but-deep is an unknown.
        // ⚠️ RLUSD is 18-dec and PYUSD is 6-dec. `_fromUsd`/`_toUsd18` are decimals-aware via
        //    `IERC20(stable).decimals()`; never infer a stable's decimals from its slot.
        address mvR = _mkMorphoVenue(morpho, MarketParams({
            loanToken: address(RLUSD), collateralToken: weeth,
            oracle: RLUSD_WEETH_ORACLE, irm: vm.envOr("MORPHO_IRM", ADAPTIVE_IRM), lltv: MORPHO_LLTV_86
        }), lm, RLUSD_WEETH_MARKET_ID);
        address mvP = _mkMorphoVenue(morpho, MarketParams({
            loanToken: address(PYUSD), collateralToken: weeth,
            oracle: PYUSD_WEETH_ORACLE, irm: vm.envOr("MORPHO_IRM", ADAPTIVE_IRM), lltv: MORPHO_LLTV_86
        }), lm, PYUSD_WEETH_MARKET_ID);

        vs = new address[](2);
        // LONG Morpho venue {collateral: weETH, debt: WETH} -- the ETH-DENOMINATED-DEBT leg. Every other venue
        // above borrows USDC, which is what makes an ETH IL-protect borrow pay a stable->WETH SOR round trip;
        // 🔴 THE WETH-DEBT VENUE {loanToken: WETH, collateralToken: weETH} WAS DELETED HERE. It could not
        // hedge, and was added on the belief that it could. THE ALGEBRA: the band sold `soldFrac·E0` of ETH,
        // so it holds `E0(1−soldFrac)` ETH plus the USD proceeds; delta-1 requires netting `E0`.
        //   • Borrow WETH `soldFrac·E0` ⇒ hold `E0` but OWE `soldFrac·E0` ETH ⇒ net `E0(1−soldFrac)`.
        //     UNCHANGED — the debt cancels exactly what the borrow bought.
        //   • Borrow USD and buy ETH ⇒ hold `E0`, owe DOLLARS ⇒ net `E0`. RESTORED.
        // ⇒ THE LIABILITY MUST BE IN THE ASSET YOU ARE NOT LONG. A weETH/WETH market is a STAKING CARRY,
        //   not IL protect, and its depth is irrelevant — infinitely deep it would still hedge nothing.
        //   It was added to avoid the stable→WETH hop; it avoided the hop by not hedging.
        //   (BTC has no equivalent gap: its hedge also needs a dollar liability, which Aave V3 WBTC +
        //   the _hop1B/_hop2B stable→WBTC paths already provide.)
        // It was also NEVER EXERCISED — no test file imports from `script/`, so the green suite its commit
        // cited could not distinguish working from broken — and it was the ONLY venue reaching the
        // allowlist through `vetVenue`'s `stable() == base` early return, which skips the
        // `coll != c0 && coll != c1 → BadCollateral` gate. Deleting it removes that hole's only user.
        // USDC IS NOT AN ALLOWLISTED BORROW AT ALL. Both USDC markets are gone, not demoted: the
        // weETH/USDC 86% market has $0.17M idle across 100 of 100 weeks under $1M, so it cannot fund a
        // hedge at any size — an allowlisted venue that reverts on borrow is worse than no venue,
        // because the keeper spends a rebalance discovering it. WETH-collateral went with it (dominated:
        // same delta, same IL offset, minus the ether.fi ratchet).
        vs[0] = mvR; vs[1] = mvP;
    }

}
