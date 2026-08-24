// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;


import {Quid} from "../src/Quid.sol";
import {OracleLib} from "../src/imports/OracleLib.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
import {Core} from "../src/Core.sol";
import {Aux} from "../src/Aux.sol";
import {Basket} from "../src/Basket.sol";
import {Vault} from "../src/Vault.sol";
import {SPVGateway} from "../src/spv/SPVGateway.sol";
import {BTCChannels} from "../src/BTCChannels.sol";

/// @dev The Foundation (F8N) ANGEL seed NFT: the Safe approves Aux for it mid-deploy (below), and Basket's
///      constructor requires that approval — so the seed commitment is atomic with Basket's birth, with NO
///      predicted address (Aux is already deployed when approved). Aux burns it deployer→DEAD at finalize.
interface IF8N { function approve(address to, uint256 tokenId) external; }
address constant F8N_COLLECTION = 0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405;
uint constant ANGEL_ID = 16508; // == Basket.ANGEL

/// @title DeployLib — the ONE canonical QU!D contract-deploy + wiring sequence.
/// @notice The exact `new`s + setup/wiring that stand up the core QU!D stack
///         (Quid/Core/Aux/Basket/Vault + optional Rover + SPVGateway/BTCChannels
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
        // §V4-ZERO — was `IPoolManager poolManager`. The stack needed it for ONE deploy-time read:
        // two reference-pool `slot0`s, to seed each range's ring. That read is Chainlink now, so the
        // config carries the two feeds and no ETH type appears in the deploy at all.
        address ethFeed;
        address btcFeed;
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
        // ── AAVE ETH ──
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
        address ETH;
        address core;
        address aux;
        address quid;
        address vault;
        address ethVenue;
        address spvGateway;
        address btcChannels;
        /// §RANGEBACKING-FOLD — the BTC range's Core instance. The `rangeBacking` address is gone with
        /// the contract: the joint committed figure lives on `Aux`, which is already in this struct.
        address btcCore;
    }

    /// @notice Deploy + wire the core QU!D stack in the exact production order.
    function deployQuidStack(StackConfig memory cfg) internal returns (StackAddrs memory a) {
        Quid ETH = new Quid();
        // §RANGEBACKING-FOLD — TWO INSTANCES, AND THE ACCOUNTANT IS `Aux`.
        // `Core` is single-asset, so the stack deploys one per range. The ONE thing they still share
        // — the joint committed equity that `require(committedUsd18() <= haircutTvl)` gates on —
        // is held by `Aux`, which is where the gate that reads it already lives.
        // ⚠️ THE REGISTER/SEAL CEREMONY IS GONE, AND THE INVARIANT IT PROTECTED IS STRONGER FOR IT.
        // `RangeBacking.total()` had to REFUSE before `seal()` because a partial sum under-reports
        // and would pass a bound it should fail. Aux takes both range addresses in its CONSTRUCTOR,
        // so the denominator is complete from birth and there is no window to seal shut.
        // ⚠️ SCOPED (`via_ir = false`): `btcCore` is dead after this block, and freeing its slot is
        // what keeps this already stack-tight frame compiling. The address survives on the returned
        // struct, which is memory and costs no stack.
        Core core;
        {
            // §ISBTC-ZERO — no flag. Each instance is told its ASSET and its RISK PROFILE
            // directly: BTC locks capital through ~1hr of confirmations and pays an on-chain
            // splice fee; ETH settles in ~one block with neither. VOL_DECIMALS is read from the
            // asset token itself, so it cannot be mistyped here.
            core          = new Core(cfg.weth, SwapLib.ethRisk());
            Core btcCore  = new Core(cfg.wbtc, SwapLib.btcRisk());
            a.btcCore = address(btcCore);
            // §E222 — NO OBSERVATION SOURCE IS PINNED. A single Curve 3-coin pool was pinned here and is
            // REMOVED ON THE OWNER'S INSTRUCTION (2026-08-21, said three times).
            // ⇒ CONSEQUENCE, STATED RATHER THAN LEFT TO BE FOUND: `_observeIfSourced` returns early,
            //   the ring is never written, `ringVariance` returns 0, and §E213's sentinel prices
            //   unmeasured variance at the CEILING. Safe, and silent — so it is written down here.
            // ⚠️ WHY NOT JUST RE-PIN IT: a single pool makes THAT pool's depth and its own depeg mode
            //   an input to σ², the skew and liquidation. `OracleLib`'s own header states the rule
            //   ("correlated sources are one source") and one venue fails it on its own terms.
            // ⛔ RULED OUT, so nobody re-tries them: 1inch's OffchainOracle iterates 14 venues at
            //   31,722,803 gas — above the 30M block limit, unexecutable on the swap path. A v3 TWAP
            //   needs `1.0001^tick`, i.e. `TickMath`, which the ETH cut removed.
            // ▶️ WHAT WOULD WORK: several on-pool EMAs in DIFFERENT quote assets, median-of-N with a
            //   spread cap. Measured 2026-08-21 — WETH/USDC $2,384.81 · WETH/USDT $2,386.52 ·
            //   WETH/crvUSD $2,384.83, a 7.2 bps spread, one storage read each. The index is PER-POOL
            //   (the WETH index differs BETWEEN Curve pools), so it must be pinned
            //   WITH the source or a shared index prices ETH as WBTC.
            // ⚠️ The BTC instance is deliberately left unset: every on-chain venue quotes WRAPPED
            // BTC, so observing one makes a WBTC depeg indistinguishable from bitcoin moving. Unset
            // ⇒ σ² unmeasured ⇒ §E213 at the ceiling, which is the honest reading. The BTC anchor is
            // unaffected and already wrapper-free (Chainlink BTC/USD).
        }
        Aux aux = new Aux(Aux.AuxInit({
            range: address(ETH), core: address(core), btcCore: a.btcCore,
            weth: cfg.weth, wbtc: cfg.wbtc,
            gho: cfg.gho, usdg: cfg.usdg,
            aaveSpoke: cfg.aaveSpoke, aaveHub: cfg.aaveHub,
            stables: cfg.stables, vaults: cfg.vaults
        }));
        // Seed commitment: the Safe (this deploy's caller, ANGEL's owner) approves the now-deployed Aux for the
        // ANGEL NFT — no predicted address needed. Basket's constructor requires this approval, so it can't be
        // born without the seed committed; Aux burns ANGEL deployer→DEAD at finalize via the same approval.
        IF8N(F8N_COLLECTION).approve(address(aux), ANGEL_ID);
        Basket quid = new Basket(address(ETH), address(aux));

        // Reference V4 PoolKeys — Core reads their slot0 ticks at setup and seeds
        // VANILLA_ETH / VANILLA_BTC at live market prices (built in its own frame).
        // §V4-CUT — THE DEPLOYER READS THE REFERENCE POOLS, NOT `Core`. This lookup is a read of
        // pools we do not own and is needed exactly ONCE, to seed each range's ring; keeping it
        // inside `Core` forced that contract to carry an IPoolManager and two PoolKeys forever for
        // a deploy-time question. Each instance now receives its seed PRICE.
        // ⚠️ SCOPED (`via_ir = false`): the two PoolKeys and two seed prices are dead the moment
        // both setups have run, and this frame is already at the stack limit -- MEASURED, it
        // overflowed at `_newVault` before the block was added.
        {
        (uint seedEth, uint seedBtc) = OracleLib.seedPrices(cfg.ethFeed, cfg.btcFeed);
        core.setup(address(ETH), address(aux), address(quid), seedEth);   // ETH range manager IS Quid
        // §E222 — NO OBSERVATION SOURCE IS PINNED, ON THE OWNER'S INSTRUCTION (2026-08-21).
        // A single Curve 3-coin pool was pinned here and is REMOVED: pricing the range off one pool
        // makes that pool's depth and its own depeg mode an input to σ², the skew and liquidation —
        // and `OracleLib`'s own header says a single venue is one observer, not an independent one.
        // Two candidates were tried and both are ruled out: 1inch's OffchainOracle costs 31,722,803
        // gas per read against a 30M block limit (unexecutable), and a single pool is this.
        // ⇒ WITH NO SOURCE, `_observeIfSourced` RETURNS IMMEDIATELY: the ring is never written,
        //   `ringVariance` returns 0, and §E213's sentinel prices unmeasured variance at the CEILING.
        //   That is deliberate and it is the honest state — it is also what BOTH instances now do, so
        //   the BTC/ETH asymmetry the old comment described no longer exists.
        // ⚠️ THE CIRCULARITY §E222 NAMES IS GONE EITHER WAY: the ring is no longer self-written from
        //   `getTWAPforAsset`. What is open is finding a source that is neither a single venue nor
        //   unaffordable. The ANCHORS are untouched and already wrapper-free (Chainlink "ETH / USD"
        //   and "BTC / USD").
        // 🔴 THE BTC INSTANCE WAS NEVER SET UP, AND IT COST 1,828 TEST FAILURES. The isBTC split
        // built both ranges (above) but only the ETH one was
        // ever configured -- so the BTC Core had no AUX, no BASKET and, decisively, an UNSEEDED
        // observation ring. `OracleLib.observe` then computed `(st.index + 1) % st.cardinality`
        // with `cardinality == 0`, i.e. a modulo by zero, which is what every `repack(true)` path
        // hit. `setup` is instance-aware (it seeds only ITS OWN ring), so this is the missing call,
        // not a workaround. Nothing else routed to the BTC instance until `Aux.rangeOf` started
        // dispatching WBTC to it, which is why the gap stayed invisible.
        Core(a.btcCore).setup(address(0), address(aux), address(quid), seedBtc);   // BTC range pins in setBtcVault (Vault deployed later)
        }
        ETH.setup(address(quid), address(aux), address(core));
        // §FOLD-WIRE — QUID now; the ETH venue follows once `ETH.setup` has set WETH.
        aux.wire(address(quid), address(0), address(0));

        // ── Vault (BTC LP/hop side); ETH yield-venue custody now lives in Quid ──
        // §ISBTC-SPLIT — THE BTC RANGE MANAGER TAKES THE BTC CORE. This passed `core` (the ETH
        // instance) while `Vault.sol` states outright "the instance IS the BTC one", so the code
        // assumed one wiring and the deploy supplied another -- the comment was right and the
        // assignment was wrong, which is the exact shape CLAUDE.md records for this split.
        Vault BTC = _newVault(cfg, a.btcCore, address(aux));  // own frame (no via_ir)
        // The ETH-venue pointers now target the CUSTODY contract, not the Vault. Every
        // `ICore(...)` call site follows the pin, so nothing else moves.
        // §ETHVENUE-FOLD — the ETH yield venue IS Quid. One fewer deployable contract, and one
        // fewer pin: `setEthVenueContract` is gone with the separate address it existed to name.
        // `aux.setEthVenue` still runs, now pointing at the range manager itself.
        aux.wire(address(0), address(ETH), address(0));   // MUST run after ETH.setup (WETH set)
        BTC.setup(address(quid));                // reads BTC pool slot0 (needs CORE.setup)
        core.setBtcVault(address(BTC));
        Core(a.btcCore).setBtcVault(address(BTC));   // the BTC instance needs the same pin
        quid.setBtcVault(address(BTC));

        a.ETH = address(ETH);
        a.core = address(core);
        a.aux = address(aux);
        a.quid = address(quid);
        a.vault = address(BTC);
        a.ethVenue = address(ETH);


        // ── native BTC LP infrastructure (SPV gateway + per-LP channel registry) ──
        if (cfg.deployChannels) {
            (a.spvGateway, a.btcChannels) = _deployChannels(cfg, address(aux), address(BTC));
        }
    }

    /// @dev SPV gateway + BTCChannels + the Aux pin, in its own frame.
    /// @dev `new Vault(...)` in its OWN frame (no via_ir) — it tips deployQuidStack's stack inline.
    function _newVault(StackConfig memory cfg, address core, address aux) internal returns (Vault) {
        return new Vault(core, aux, cfg.weth);
    }

    function _deployChannels(StackConfig memory cfg, address aux, address BTC)
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
        // BTCChannels binds `btc = _range` (the 3rd arg). The BTC side was regrouped
        // into the merged Vault (`BTC`) — creditSwapOut / requestDeposit / resize all
        // live there (Quid/`ETH` has none). So the BtcVault is `BTC`, NOT `ETH`: passing ETH
        // pointed btc at Quid, whose fallback returns empty ⇒ creditSwapOut decode-
        // reverts (swap-out) and requestDeposit silently no-ops (open). Mirrors the canonical
        // BtcLpMintStress._deployChannels wiring (`new BTCChannels(spv, ETH)`).
        // (E164) MAIN_HOP + FALLBACK_HOP are pinned at construction and can never be added to:
        // a governed hop set is a Safe that can grant itself channels, which is the lever a
        // 4-of-7 compromise pulls. `cfg` carries both so a deployment names them explicitly
        // rather than inheriting a default nobody chose.
        BTCChannels c = new BTCChannels(address(spv), BTC, cfg.mainHop, cfg.fallbackHop,
                                        cfg.btcDepositKey);
        // WIRING INVARIANT (regression guard): btc MUST be the merged Vault `BTC` —
        // where creditSwapOut / requestDeposit / resize live. A prior version passed
        // `ETH` (Quid, which has none), silently breaking ALL BTC swap-out (creditSwapOut
        // decode-reverts) and no-op'ing requestDeposit on open. Assert at deploy so any
        // future miswire fails LOUDLY here (incl. production DeployL1_s) instead of on the
        // first live swap-out. Covers the gap that shipped it: forge tests deploy channels
        // by hand, so nothing exercised deployQuidStack(deployChannels:true) until now.
        require(address(c.btc()) == BTC, "DeployLib: btc must be the Vault");
        Aux(payable(aux)).wire(address(0), address(0), address(c));
        gw = address(spv);
        ch = address(c);
    }

    /// @dev The two reference PoolKeys (ETH/USDT + USDC/WBTC), built in their own
    ///      frame to keep `deployQuidStack`'s stack shallow (no via_ir).
    // §V4-ZERO — `_refKeys` DELETED. It built two `PoolKey`s naming Uniswap pools this protocol does
    // not own, trade on, or validate, purely so a deploy could read their `slot0` once. The seed now
    // comes from the same Chainlink feeds every runtime TWAP is anchored against.

    // §E233-sor — THE 8 SOR PATH BUILDERS ARE DELETED (`_buildSORPaths`, `_ethPaths`, `_btcPaths`,
    // `_hop1`/`_hop2`/`_hop1B`/`_hop2B`/`_hop3B`) along with `imports/SOR.sol` and the four `Aux`
    // entrypoints that consumed them. They encoded multi-hop routes for a router that no longer
    // exists, into an `_pathEncodings` array nothing read.
    // The stable->volatile route the basket still needs is §V-R1 (1inch AggregationRouterV6).

}
