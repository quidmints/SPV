// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

import {Vogue} from "../src/Vogue.sol";
import {Core} from "../src/Core.sol";
import {Aux} from "../src/Aux.sol";
import {Basket} from "../src/Basket.sol";
import {Vault} from "../src/Vault.sol";
import {SPVGateway} from "../src/spv/SPVGateway.sol";
import {BTCChannels} from "../src/BTCChannels.sol";
import {SorPath} from "../src/imports/SOR.sol";

/// @dev The Foundation (F8N) ANGEL seed NFT: the Safe approves Aux for it mid-deploy (below), and Basket's
///      constructor requires that approval — so the seed commitment is atomic with Basket's birth, with NO
///      predicted address (Aux is already deployed when approved). Aux burns it deployer→DEAD at finalize.
interface IF8N { function approve(address to, uint256 tokenId) external; }
address constant F8N_COLLECTION = 0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405;
uint constant ANGEL_ID = 16508; // == Basket.ANGEL

/// @title DeployLib — the ONE canonical QU!D contract-deploy + wiring sequence.
/// @notice The exact `new`s + setup/wiring that stand up the core QU!D stack
///         (Vogue/Core/Aux/Basket/Vault + optional Rover + SPVGateway/BTCChannels
///         + the SOR path table). It is the single source of truth shared by:
///           • the production script `src/DeployL1_s.sol` (`vm.startBroadcast`),
///           • the mainnet-fork test setUp in `test/Alles.t.sol` (whale-funded),
///           • the cross-side driver harness `script/DriverE2E.s.sol`.
///
///         There are NO cheatcodes here — every caller supplies its own
///         environment (fork+whale-fund for tests, broadcast for the scripts).
///         The DEPLOY ORDER + WIRING are load-bearing and preserved verbatim
///         (e.g. `AUX.setEthVenue` MUST run after `V4.setup`; BOLD MUST stay
///         last in `cfg.stables`; the BtcVault `setup` reads the BTC pool slot0
///         and so must follow `CORE.setup`). Everything caller-specific (feeds,
///         extra curators, leverage overlay, finalize/renounce, whale funding,
///         basket seeding) stays in the caller, AFTER this sequence.
///
///         `deployQuidStack` runs in the CALLER's context (an internal library
///         function is inlined), so `msg.sender` for every `new`/owner-set is the
///         caller's broadcaster/test contract — ownership is identical to a
///         hand-written deploy.
library DeployLib {
    /// @dev Everything the shared deploy needs; each caller populates it from its
    ///      own env/constants. Token/vault addresses are inputs (they legitimately
    ///      use a different Morpho USDC vault than production).
    struct StackConfig {
        IPoolManager poolManager;
        // ── tokens (canonical mainnet in every caller) ──
        address weth;
        address wbtc;
        address gho;
        address usdg;
        address usdc;
        address usdt;
        address dai;
        address usde;
        address usds;
        // ── SOR source vaults (differ between callers) ──
        address morphoUsdcVault;
        address morphoUsdtVault;
        address morphoUsdsVault;
        address sdai;
        address susde;
        // ── AAVE v4 ──
        address aaveSpoke;
        address aaveHub;
        // ── ETH-venue WETH 4626s (mock in tests, real in prod) ──
        address nfpm;
        // ── basket set (order load-bearing: BOLD LAST) ──
        address[] stables;
        address[] vaults;
        // ── native BTC channel infra ──
        address hopOperator;
        bytes spvCheckpointHeader;
        uint64 spvCheckpointHeight;
        uint256 spvCheckpointWork;
        // (E135) The headers that FOLLOW the checkpoint, submitted at deploy. See below —
        // this is not an added constraint, it is the catch-up the gateway needs anyway.
        bytes[] spvCheckpointFollowers;
        // (E135-b) Waiver for the burial requirement below. There is no default: every
        // `StackConfig` literal must name it, so a deploy CANNOT omit it by accident — the
        // compiler makes the choice conscious. Production sets FALSE.
        bool allowUnburiedCheckpoint;
        // ── optional add-ons (tests deploy their own doubles per-test) ──
        bool deployChannels;
        /// (E164) The ONLY two addresses that may operate a channel, pinned at construction.
        /// Named here so a deployment chooses them explicitly — there is no setter, by design.
        address mainHop;
        address fallbackHop;
        /// (E159) The fleet's pinned x-only swap-in deposit key. Every deposit address is derived
        /// from it, so a swap-in credit can be PROVEN against a Bitcoin block instead of attested.
        bytes32 btcDepositKey;
    }

    /// @dev The deployed core-stack addresses. `rover`/`spvGateway`/`btcChannels`
    ///      are 0 when the corresponding flag was false.
    struct StackAddrs {
        address v4;
        address core;
        address aux;
        address quid;
        address vault;
        address spvGateway;
        address btcChannels;
    }

    /// @notice Deploy + wire the core QU!D stack in the exact production order.
    function deployQuidStack(StackConfig memory cfg) internal returns (StackAddrs memory a) {
        Vogue v4 = new Vogue();
        Core core = new Core(cfg.poolManager);
        Aux aux = new Aux(Aux.AuxInit({
            vogue: address(v4), core: address(core),
            poolManager: address(cfg.poolManager),
            weth: cfg.weth, wbtc: cfg.wbtc,
            gho: cfg.gho, usdg: cfg.usdg,
            aaveSpoke: cfg.aaveSpoke, aaveHub: cfg.aaveHub,
            stables: cfg.stables, vaults: cfg.vaults,
            paths: _buildSORPaths(cfg)
        }));
        // Seed commitment: the Safe (this deploy's caller, ANGEL's owner) approves the now-deployed Aux for the
        // ANGEL NFT — no predicted address needed. Basket's constructor requires this approval, so it can't be
        // born without the seed committed; Aux burns ANGEL deployer→DEAD at finalize via the same approval.
        IF8N(F8N_COLLECTION).approve(address(aux), ANGEL_ID);
        Basket quid = new Basket(address(v4), address(aux));

        // Reference V4 PoolKeys — Core reads their slot0 ticks at setup and seeds
        // VANILLA_ETH / VANILLA_BTC at live market prices (built in its own frame).
        (PoolKey memory refKeyETH, PoolKey memory refKeyBTC) = _refKeys(cfg);
        core.setup(address(v4), address(aux), address(quid), refKeyETH, refKeyBTC);
        v4.setup(address(quid), address(aux), address(core));
        aux.setQuid(address(quid));

        // ── merged Vault (ETH yield-venue custody + BTC LP/hop side) ──
        Vault eth = _newVault(cfg, address(v4), address(core), address(aux));  // own frame (no via_ir)
        aux.setEthVenue(address(eth));           // MUST run after V4.setup (WETH set)
        v4.setEthVenueContract(address(eth));
        eth.setup(address(quid));                // reads BTC pool slot0 (needs CORE.setup)
        core.setBtcVault(address(eth));
        quid.setBtcVault(address(eth));

        a.v4 = address(v4);
        a.core = address(core);
        a.aux = address(aux);
        a.quid = address(quid);
        a.vault = address(eth);

        // ether.fi Rover deploy REMOVED 2026-08-05 — the contract is gone.

        // ── native BTC LP infrastructure (SPV gateway + per-LP channel registry) ──
        if (cfg.deployChannels) {
            (a.spvGateway, a.btcChannels) = _deployChannels(cfg, address(aux), address(v4), address(eth));
        }
    }

    /// @dev SPV gateway + BTCChannels + the Aux pin, in its own frame.
    /// @dev `new Vault(...)` in its OWN frame (no via_ir) — the 9-arg ctor tips deployQuidStack's stack inline.
    function _newVault(StackConfig memory cfg, address v4, address core, address aux) internal returns (Vault) {
        return new Vault(v4, core, aux, cfg.weth, cfg.aaveSpoke, cfg.aaveHub);
    }

    function _deployChannels(StackConfig memory cfg, address aux, address /*v4*/, address eth)
        private returns (address gw, address ch)
    {
        SPVGateway spv = new SPVGateway();
        spv.__SPVGateway_init(cfg.spvCheckpointHeader, cfg.spvCheckpointHeight, cfg.spvCheckpointWork);
        // (E135) CATCH THE GATEWAY UP AT DEPLOY, and get the checkpoint check for free.
        //
        // `checkTxInclusion` requires the tx's block to already be known, and after init the
        // gateway knows EXACTLY ONE block. So it must be caught up before it can vouch for
        // anything — today that happens by accident, whenever some keeper first submits
        // headers. Doing it here is not an added constraint; it is the same mandatory work,
        // earlier.
        //
        // ⚠️ AND IT IS WHAT CATCHES A BAD CHECKPOINT. `_initialize` takes `(header, height,
        // cumulativeWork)` on trust — it cannot know Bitcoin's tip. If the checkpoint is
        // orphaned (too shallow, and a routine 1-2 block reorg took it), these followers
        // CANNOT link to it and this call REVERTS, failing the deploy loudly. Left to a
        // keeper instead, the same break surfaces much later as a `prevBlockHash` mismatch
        // nobody attributes to the checkpoint — possibly after channels already depend on
        // the gateway, and `initializer` means it can never be re-initialised.
        //
        // Deliberately NOT a contract-level clamp: an earlier attempt made
        // `checkTxInclusion` refuse to answer until the checkpoint was 100 blocks buried,
        // which is a liveness constraint invented to guard a deploy-time mistake. This
        // attacks the cause instead, and costs nothing on-chain.
        //
        // Empty is permitted (tests, and regtest fixtures with short chains) — that leaves
        // the gateway exactly as un-caught-up as it is today, no worse. A PRODUCTION deploy
        // must supply them, both to function and to prove the checkpoint is canonical.
        // (E135-b) BURIAL IS NOW REQUIRED, NOT ADVISED. This used to be `if (length != 0)`
        // with a comment saying "A PRODUCTION deploy must supply them" — a property true by
        // CONVENTION, with nothing failing when the convention lapsed.
        // ⚠️ NOT A DEPTH CLAMP (those were rejected, correctly). A non-empty follower batch is
        //    SELF-PROVING: N valid PoW headers extending the checkpoint cannot exist unless
        //    Bitcoin produced them, so requiring one cannot be satisfied by a lie and costs
        //    nothing beyond the headers a deploy needs anyway.
        // WHY IT MATTERS: `_initialize` validates nothing, and `initializer` means it can
        // never re-run. Pin a checkpoint too shallow, let a ROUTINE 1-2 block reorg orphan it,
        // and every later `addBlockHeader` fails its `prevBlockHash` link — a normal Bitcoin
        // event permanently bricks the gateway and the whole BTC path.
        require(cfg.spvCheckpointFollowers.length != 0 || cfg.allowUnburiedCheckpoint,
            "DeployLib: checkpoint unburied (supply spvCheckpointFollowers, or waive it)");
        if (cfg.spvCheckpointFollowers.length != 0) {
            spv.addBlockHeaderBatch(cfg.spvCheckpointFollowers);
        }
        // BTCChannels binds `btcVault = _vogue` (the 3rd arg). The BTC side was regrouped
        // into the merged Vault (`eth`) — creditSwapOut / registerBtcLp / resizeBtcLp all
        // live there (Vogue/`v4` has none). So the BtcVault is `eth`, NOT `v4`: passing v4
        // pointed btcVault at Vogue, whose fallback returns empty ⇒ creditSwapOut decode-
        // reverts (swap-out) and registerBtcLp silently no-ops (open). Mirrors the canonical
        // BtcLpMintStress._deployChannels wiring (`new BTCChannels(spv, ETH)`).
        // (E164) MAIN_HOP + FALLBACK_HOP are pinned at construction and can never be added to:
        // a governed hop set is a Safe that can grant itself channels, which is the lever a
        // 4-of-7 compromise pulls. `cfg` carries both so a deployment names them explicitly
        // rather than inheriting a default nobody chose.
        BTCChannels c = new BTCChannels(address(spv), eth, cfg.mainHop, cfg.fallbackHop,
                                        cfg.btcDepositKey);
        // WIRING INVARIANT (regression guard): btcVault MUST be the merged Vault `eth` —
        // where creditSwapOut / registerBtcLp / resizeBtcLp live. A prior version passed
        // `v4` (Vogue, which has none), silently breaking ALL BTC swap-out (creditSwapOut
        // decode-reverts) and no-op'ing registerBtcLp on open. Assert at deploy so any
        // future miswire fails LOUDLY here (incl. production DeployL1_s) instead of on the
        // first live swap-out. Covers the gap that shipped it: forge tests deploy channels
        // by hand, so nothing exercised deployQuidStack(deployChannels:true) until now.
        require(address(c.btcVault()) == eth, "DeployLib: btcVault must be the Vault");
        Aux(payable(aux)).setBTCChannels(address(c));
        gw = address(spv);
        ch = address(c);
    }

    /// @dev The two reference PoolKeys (ETH/USDT + USDC/WBTC), built in their own
    ///      frame to keep `deployQuidStack`'s stack shallow (no via_ir).
    function _refKeys(StackConfig memory cfg)
        private pure returns (PoolKey memory refKeyETH, PoolKey memory refKeyBTC)
    {
        refKeyETH = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(cfg.usdt),
            fee: uint24(500), tickSpacing: int24(10), hooks: IHooks(address(0))
        });
        refKeyBTC = PoolKey({
            currency0: Currency.wrap(cfg.wbtc),
            currency1: Currency.wrap(cfg.usdc),
            fee: uint24(3000), tickSpacing: int24(60), hooks: IHooks(address(0))
        });
    }

    // ─── SOR paths for `auxSwap` — multi-hop V4 routes through the stable-stable
    //     pools. Passed straight into Aux's constructor (no on-chain mutation
    //     surface). USDT is the ETH-hub; ETH is the BTC-hub. See the extensive
    //     PoolId-verification notes in git history (DeployL1_s pre-extraction). ───
    function _buildSORPaths(StackConfig memory cfg) internal pure returns (bytes[] memory paths) {
        // PoolKeys are built inline via `_pk` (each consumed immediately by the
        // `_hop*` call), and the ETH / BTC path halves run in their OWN frames, so
        // no long-lived PoolKey local accumulates — keeps within the legacy stack
        // (no via_ir; fixed by extraction per repo LAW).
        paths = new bytes[](12);
        _ethPaths(cfg, paths);
        _btcPaths(cfg, paths);
    }

    /// @dev A V4 PoolKey with sorted currencies + given (fee, tickSpacing), no hooks.
    function _pk(address c0, address c1, uint24 fee, int24 tickSpacing)
        private pure returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(c0), currency1: Currency.wrap(c1),
            fee: fee, tickSpacing: tickSpacing, hooks: IHooks(address(0))
        });
    }

    /// @dev WETH-terminal SOR paths (arbETH iterates these). Fees/tickSpacings are
    ///      the deployer-verified mainnet pool params (USDe/USDT=45/1, USDC/USDT=8/1,
    ///      DAI/USDT=68/1, USDT/USDS=5/1, ETH/USDT=500/10, USDC/ETH=500/10).
    function _ethPaths(StackConfig memory cfg, bytes[] memory paths) private pure {
        paths[0] = _hop2(cfg.usdc, cfg.morphoUsdcVault,
            _pk(cfg.usdc, cfg.usdt, 8, 1), _pk(address(0), cfg.usdt, 500, 10), cfg.usdt, cfg.weth);
        paths[1] = _hop2(cfg.usds, cfg.morphoUsdsVault,
            _pk(cfg.usdt, cfg.usds, 5, 1), _pk(address(0), cfg.usdt, 500, 10), cfg.usdt, cfg.weth);
        paths[2] = _hop2(cfg.dai, cfg.sdai,
            _pk(cfg.dai, cfg.usdt, 68, 1), _pk(address(0), cfg.usdt, 500, 10), cfg.usdt, cfg.weth);
        paths[3] = _hop2(cfg.usde, cfg.susde,
            _pk(cfg.usde, cfg.usdt, 45, 1), _pk(address(0), cfg.usdt, 500, 10), cfg.usdt, cfg.weth);
        paths[4] = _hop1(cfg.usdt, cfg.morphoUsdtVault, _pk(address(0), cfg.usdt, 500, 10), cfg.weth);
        paths[5] = _hop1(cfg.usdc, cfg.morphoUsdcVault, _pk(address(0), cfg.usdc, 500, 10), cfg.weth);
    }

    /// @dev WBTC-terminal SOR paths (arbBTC iterates these), cheapest first
    ///      (USDC/WBTC=3000/60, ETH/WBTC=3000/60).
    function _btcPaths(StackConfig memory cfg, bytes[] memory paths) private pure {
        paths[6] = _hop1B(cfg.usdc, cfg.morphoUsdcVault, _pk(cfg.wbtc, cfg.usdc, 3000, 60), cfg.wbtc);
        paths[7] = _hop2B(cfg.usdc, cfg.morphoUsdcVault,
            _pk(address(0), cfg.usdc, 500, 10), _pk(address(0), cfg.wbtc, 3000, 60), cfg.wbtc);
        paths[8] = _hop2B(cfg.usdt, cfg.morphoUsdtVault,
            _pk(address(0), cfg.usdt, 500, 10), _pk(address(0), cfg.wbtc, 3000, 60), cfg.wbtc);
        paths[9] = _hop3B(cfg.usds, cfg.morphoUsdsVault,
            _pk(cfg.usdt, cfg.usds, 5, 1), _pk(address(0), cfg.usdt, 500, 10),
            _pk(address(0), cfg.wbtc, 3000, 60), cfg.usdt, cfg.wbtc);
        paths[10] = _hop3B(cfg.dai, cfg.sdai,
            _pk(cfg.dai, cfg.usdt, 68, 1), _pk(address(0), cfg.usdt, 500, 10),
            _pk(address(0), cfg.wbtc, 3000, 60), cfg.usdt, cfg.wbtc);
        paths[11] = _hop3B(cfg.usde, cfg.susde,
            _pk(cfg.usde, cfg.usdt, 45, 1), _pk(address(0), cfg.usdt, 500, 10),
            _pk(address(0), cfg.wbtc, 3000, 60), cfg.usdt, cfg.wbtc);
    }

    /// @dev 2-hop path: sourceStable → USDT → ETH (native, wrapped at Aux).
    function _hop2(address sourceStable, address sourceVault,
                   PoolKey memory firstHop, PoolKey memory ethUsdtHop,
                   address usdt, address weth) private pure returns (bytes memory)
    {
        PoolKey[] memory keys = new PoolKey[](2);
        keys[0] = firstHop; keys[1] = ethUsdtHop;
        address[] memory tokens = new address[](3);
        tokens[0] = sourceStable; tokens[1] = usdt; tokens[2] = address(0);
        return abi.encode(SorPath({
            sourceAsset: sourceStable, sourceVault: sourceVault,
            tokens: tokens, keys: keys, output: weth
        }));
    }

    /// @dev 1-hop path: sourceStable → ETH directly.
    function _hop1(address sourceStable, address sourceVault, PoolKey memory ethUsdtHop, address weth)
        private pure returns (bytes memory)
    {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = ethUsdtHop;
        address[] memory tokens = new address[](2);
        tokens[0] = sourceStable; tokens[1] = address(0);
        return abi.encode(SorPath({
            sourceAsset: sourceStable, sourceVault: sourceVault,
            tokens: tokens, keys: keys, output: weth
        }));
    }

    /// @dev 1-hop BTC path: sourceStable → WBTC directly (e.g. USDC/WBTC).
    function _hop1B(address sourceStable, address sourceVault, PoolKey memory stableWbtcHop, address wbtc)
        private pure returns (bytes memory)
    {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = stableWbtcHop;
        address[] memory tokens = new address[](2);
        tokens[0] = sourceStable; tokens[1] = wbtc;
        return abi.encode(SorPath({
            sourceAsset: sourceStable, sourceVault: sourceVault,
            tokens: tokens, keys: keys, output: wbtc
        }));
    }

    /// @dev 2-hop BTC path: sourceStable → ETH → WBTC.
    function _hop2B(address sourceStable, address sourceVault,
                    PoolKey memory stableEthHop, PoolKey memory ethWbtcHop, address wbtc)
        private pure returns (bytes memory)
    {
        PoolKey[] memory keys = new PoolKey[](2);
        keys[0] = stableEthHop; keys[1] = ethWbtcHop;
        address[] memory tokens = new address[](3);
        tokens[0] = sourceStable; tokens[1] = address(0); tokens[2] = wbtc;
        return abi.encode(SorPath({
            sourceAsset: sourceStable, sourceVault: sourceVault,
            tokens: tokens, keys: keys, output: wbtc
        }));
    }

    /// @dev 3-hop BTC path: sourceStable → USDT → ETH → WBTC.
    function _hop3B(address sourceStable, address sourceVault,
                    PoolKey memory stableUsdtHop, PoolKey memory usdtEthHop,
                    PoolKey memory ethWbtcHop, address usdt, address wbtc)
        private pure returns (bytes memory)
    {
        PoolKey[] memory keys = new PoolKey[](3);
        keys[0] = stableUsdtHop; keys[1] = usdtEthHop; keys[2] = ethWbtcHop;
        address[] memory tokens = new address[](4);
        tokens[0] = sourceStable; tokens[1] = usdt;
        tokens[2] = address(0);   tokens[3] = wbtc;
        return abi.encode(SorPath({
            sourceAsset: sourceStable, sourceVault: sourceVault,
            tokens: tokens, keys: keys, output: wbtc
        }));
    }
}
