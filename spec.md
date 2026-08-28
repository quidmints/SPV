# spec.md — the map

**What lives where, across every repository this project spans, and how to read
`docs/informational/` without being misled by it.**

This file is a navigator. It holds no design of its own: anything it says about how the protocol
works is a one-line orientation with a pointer, never the explanation. The explanations live in the
documents and the code this file points at, and when the two disagree the code wins.

> ⚠️ **What this replaced.** Until 2026-08-28 `spec.md` was a 2,206-line *dashboard* specification —
> a Kalman/HMM signal surface, a pool-flow microsignal, a regime replay benchmarked against DCA and
> Saylor. It came from the `dashboard/` context bundle next door and it described a read surface for
> a protocol that no longer exists in that shape: Uniswap v4 primary with Rover legacy, stored range
> bounds, a surplus-funded IL make-whole, a ±2% range. All four are gone from the tree. It was not
> stale in places; it was about something else.

---

## 1. The repositories

Everything sits under `~/projects`. Only four of these are ours and active.

### 1.1 Ours, active

| directory | remote | what it is |
|---|---|---|
| **`SPV`** | `quidmints/SPV` | The protocol. Solidity, the Rust Lightning stack, the SVM program, the landing page. This repo. §2 breaks it down. |
| **`ibiza`** | `quidmints/ibiza` | Identity and privacy. A fork of **Privacy Pools** and **rarimo/rarime** merged onto one Foundry + Noir/Honk stack. Its own `README.md` explains the name and what was forked; `TODO.md` is its tracker and holds current state. Its stated purpose is to generate demand for SPV. |
| **`seeker-main`** | — (mirrored to `quidmints/quid` `dev`) | The Solana Mobile app. Expo + Mobile Wallet Adapter against the SVM program. **Not a git repo locally.** Parity against the program is asserted by `SPV/svm/tests/seeker-parity.ts`. |
| **`app`** | — | Working directory for the React Native wallet. `SCOPE.md` is a parity punchlist against the Lexe Flutter app; holds `rarime-rn-sdk-main`, `interledger`, `qr-protocol`, `companion`. |

### 1.2 Ours, superseded — kept for history, do not build on

| directory | what it was |
|---|---|
| **`old`** | The pre-port monorepo: `evm/`, a keeper, a Next.js front end, and `docs/WP.md` + `docs/legal.md`. The origin of the `LP.pooled`-in-token design. |
| **`port`** | The intermediate port into what is now `SPV/evm`. `SESSION-CHANGES.md`, `OPEN_ISSUES.md`, `LP-OPERATIONAL.md`. ⚠️ **`SPV` is the source of truth — do not judge it by diffing against `old/` or `port/`.** |
| **`dashboard`, `dashboard (2)`** | The context bundle the old `spec.md` was generated from. |
| **`quid-svm`** | Standalone checkout of the SVM program. The live copy is the `SPV/svm` subtree. |
| **`latest`** | Empty. |

### 1.3 Not ours — reference or vendored. Never edit these.

| directory | what it is | our relationship to it |
|---|---|---|
| **`PP`** | 0xbow's Privacy Pool Protocol — circuits, contracts, relayer, SDK. | Upstream of ibiza's `contracts/pool`. ibiza ported it Circom→Noir/Honk and replaced the ASP association-set check with an identity predicate. |
| **`lexe`** | Lexe's public monorepo: a Flutter app over Rust (`app-rs`) behind `flutter_rust_bridge`. | **Reference for *what* to build, never imported.** `SPV/quid-ln` is our fork of the Rust; the RN wallet re-implements the UI and bridges to ours. |
| **`spv-gateway-master`** | ERC-8002, a singleton SPV gateway for verifying Bitcoin transactions on-chain. Draft ERC, Sepolia only. | The design `SPV/evm/src/spv/SPVGateway.sol` implements. |
| **`midnight`** | Morpho Midnight — fixed-rate, fixed-maturity isolated lending. | Evaluated. ⚠️ **Take the pieces, not the repo:** vendoring it wholesale forced a hand-rewrite of `UtilsLib.msb` because its `clz` is an Osaka opcode and we pin cancun. Its `TickLib` is irrelevant to us; we have no ticks. |
| **`yb-core`, `ybamm`** | YieldBasis. Constant 2× leverage makes LP value linear in price, so the curvature that produces impermanent loss is gone rather than averaged away. | The comparison case. We take the opposite side: bear the loss unleveraged rather than pay to hedge the curvature. |
| **`eulerswap-hook`** | A dynamic-fee auction hook for EulerSwap. | Evaluated. We are not building a fee hook. |
| **`quid-forks`** | Our patched forks of `tokio`, `ring`, `mio`, `hyper-util`, `axum-server`, `nostr`, `rust-sgx`, `rust-esplora-client`. | Required to build `quid-ln` under SGX. |

---

## 2. Inside SPV

| path | what it is | its own docs |
|---|---|---|
| `evm/` | The Solidity. `src/` is the protocol, `script/DeployL1_s.sol` + `DeployLib.sol` the one canonical deploy. | — |
| `quid-ln/` | The Rust: bridge, hop, LP daemon, watchtower, enclave. Our fork of Lexe's stack. ⚠️ Does not build on macOS; use `quid-ln/Dockerfile`. | `ops/README.md` |
| `svm/` | The Solana program and its tests. | `SOL-STAR-REFERENCE.md` |
| `spa/` | The landing page, plus `/app` as a transitional browser build of the depositor surface. | `spa/README.md`, `FRONTEND-TODO.md` |
| `indexer/` | A small self-hosted indexer for protocol events. | `indexer/README.md` |
| `regtest/` | A reproducible Bitcoin regtest node and the scripts that drive it. | `regtest/README.md` |
| `deploy/` | Provisioning: deploy the L1 contracts, run the hop and LP daemons. | `deploy/README.md`, **`PRODUCTION-LAUNCH.md`** (start there) |
| `sims/`, `analysis/` | The economic simulations the IL and LVR numbers come from. | — |
| `tools/` | The gates. See §3. | — |

---

## 3. Which document answers which question

**Precedence, highest first.** The contracts in `evm/src` are canonical for behaviour. `CLAUDE.md` is
canonical for how to work here and for environment facts. `docs/actionable/QUEUE.md` is canonical for
status. This file is canonical only for where things are.

| question | go to |
|---|---|
| How do I work in this tree? What is the build environment? | **`CLAUDE.md`** — standing rules, verification discipline, the trap notes, size and RPC facts |
| What is the current status of X? | **`docs/actionable/QUEUE.md`**, updated in place |
| What is the ordered remainder for the next thread? | **`docs/actionable/SPRINT.md`** |
| Why was X built this way? What is the evidence? | **`docs/actionable/BUILD-QUEUE-AND-107.md`** — append-only archive. Its **evidence is authoritative, its status markers are not** |
| What is QU!D, for a reader who is not in the code? | **`docs/FAQ.md`** — 2,323 lines, the outward-facing document. Parts 1 and 5 are the product; Part 6 is legal |
| How does the economics work? | `docs/informational/` — **but read §4 below first** |
| How do I deploy or run the daemons? | `deploy/PRODUCTION-LAUNCH.md` |
| What must the front end enforce? | `spa/FRONTEND-TODO.md` |
| What is ibiza doing, and what does it owe us? | `../ibiza/README.md`, `../ibiza/TODO.md` (§3b is the mobile LP-signer spec) |

**Navigating the code itself.** For **Solidity**, use `evm/slither-out/` — Slither understands
inheritance, modifiers and cross-contract flow. ⛔ **Do not use `graphify-out/graph.json` for
Solidity: it contains none.** It indexes the Rust, and 63% of what it indexes is vendored LDK.

**The gates, and both are needed.** `tools/check-contract-sizes.py` for EIP-170 (`forge build --sizes`
does not report every contract that matters). `tools/check-client-abis.py` for client drift, and
`npx tsc --noEmit` in `spa/` for everything that checker cannot see — it reads one file, does not
parse TSX, and does not read the deploy record. `tools/check-doc-symbols.py` after any rename.

---

## 4. `docs/informational/` — how to read it

### 4.1 Read this before opening any file in that folder

**It contradicts the contracts in about ten verified places, and it is prose that was written to be
persuasive.** Several files carry an `OVERRULED` banner written by a later thread. The banners are
accurate but they are not sufficient: a banner tells you the *conclusion* was overruled while the
body still reads as current, and the numbers inside are keyed to a range the protocol no longer has.

Three rules that make the folder usable:

1. **Never quote it without checking the code.** §4.3 is the standing ledger of what it gets wrong.
2. **Read the banner as a scope limit, not a delete.** An overruled design conclusion usually sits on
   top of empirical work that is still good. The banner tells you which half is which.
3. **Every θ, K and LVR figure in the folder assumes a ±2% range.** The deployed range is **±0.2%**
   (`SwapLib.RANGE_DELTA = 20`). Treat those numbers as historical measurements, not as a live
   safety argument.

### 4.2 The files

| file | what it covers | state |
|---|---|---|
| **`POSITIONING.md`** | The instrument as a discountable dated claim, why leverage is a view rather than a default, and the field: Cork, Bunni, Pendle, mStable. | ✅ **The most reliable file in the folder.** Self-audited against the code with `file:line`, and it carries its own corrections ledger. Start here. |
| **`VAULT-WATCHER.md`** | Vault health: `Aux.pokeVaultHealth`, permissionless and binary, and the argument for why *illiquidity is not insolvency* and a graded haircut would double-count. | ✅ Matches the code. |
| **`ETH-VENUES.md`** | Where a deposited ETH goes and how it exits. | ✅ 22 lines and correct. ⚠️ **It contradicts `docs/FAQ.md`, and it is the one that is right** — the FAQ lists six deposit venue codes; `QuidLib.sol:140` says *"ONE DESTINATION: every ETH deposit becomes weETH. No venue choice, no default, no dispatch."* |
| **`FEES-OUTFLOWS-TWAP.md`** | The stable outflow fee, and the reuse of a time-weighted *yield* where the volatile side uses a price TWAP. | 🟠 **Read below the retraction banner.** `BASE = 3` bps, `MAX_FEE = 30` bps, `calcFeeL1`/`scaledFeeL1` and the depeg haircut all survive. The `baseRate` third term and the off-chain CRE feed are gone. So the composite is **two** terms, not three. |
| **`IL-VIA-BONDS.md`** | 933 lines. The widest-ranging file: the cold start (§5), the numismatic principle (§7), what this does for Lightning's dead-capital problem (§8), the YieldBasis comparison (§9), the ether.fi offramp ladder (§10), multi-vault as the response to detection (§11). | 🔴 **OVERRULED on its central claim** — the basket's surplus does not absorb the LP's IL; `arbETH` is removed and the LP bears its own through the share price. §§5, 7, 8, 9 do not depend on that claim and are still the best statement of each. |
| **`IL-CERTIFICATION.md`** | The empirical backtest: measured K over the COVID crash, the 2020-03-12 crash day, the solvency table, and the sustainability inequality θ ≤ yield/(K·σ² − f). | 🔴 **OVERRULED as a safety argument, valuable as data.** Every figure is on the ±2% basis. |
| **`IL-FINDINGS-2026-06.md`** | Corrections to the above, from running the sims: no external arbitrage in our pool, IL is impermanent and realized at withdrawal, the LP break-even, and the verdict that removed `arbETH`. | 🟠 **Empirical findings valid, design conclusions overruled.** §2's retraction of the over-realization finding is the useful part. |
| **`DISCRETION-AND-THE-CLOCK.md`** | Where treasury policy ends and an unpriced option written by depositors begins. The line: discretion over hedging our own book is permitted, discretion over *when a customer is paid* is not. | ✅ Sound, and the reasoning is general. ⚠️ **It is about the SVM side** — the symbols it cites (`rate_bps`, `crowding_bps`, `sol_star_haircut_bps`) live in `svm/programs/quid/src`. |

### 4.3 The contradictions ledger

What the folder, and in three cases `docs/FAQ.md`, still asserts that the tree does not.

| claim | where | the code |
|---|---|---|
| the range is ~2%, via `_updateTicks(sqrtPriceX96, 200)` | throughout `informational/` | `RANGE_DELTA = 20` ⇒ **±0.2%** (`imports/SwapLib.sol:824`). No such call has ever existed, and there are no ticks — the ~185 `tick` matches in `evm/src` are all comments recording their removal |
| the depositor chooses an ETH venue (codes 0/2/3/4/5/6) | `docs/FAQ.md` | one destination, weETH, no dispatch (`imports/QuidLib.sol:140-145`) |
| `setTargetLtv(capBps)` lets the depositor set direction | `docs/FAQ.md` | deleted (§E358, `imports/LevBase.sol:404`). IL-protect is protocol-wide with one cap, `TARGET_LTV_CAP_BPS = 7500` |
| eleven stablecoins | `docs/FAQ.md` | **fourteen**, which is the `uint[15]` layout maximum — slot 0 is the yield-weighted sum, 1..13 the deposits, 14 the total. A fifteenth silently overwrites the total `FeeLib.calcFeeL1` divides by (`script/DeployL1_s.sol:239-254`) |
| the outflow fee has three terms including `baseRate` | `FEES-OUTFLOWS-TWAP.md` | removed; reason recorded at `Core.sol:200` |
| depeg severity is the worse of a CRE report and a live feed | `FEES-OUTFLOWS-TWAP.md` | the CRE is gone; the pinned per-stable Chainlink feeds are the signal |
| the swap-in bonus compensates a JIT actor | `POSITIONING.md` §3 (self-corrected) | `payRefillBonus` deleted 2026-07-22 |
| the basket's surplus absorbs the LP's IL | `IL-VIA-BONDS.md`, `IL-CERTIFICATION.md` | R1 — the LP bears its own via the share price |
| range bounds are stored | several | `deltaBps`/`pLower`/`pUpper` deleted; composition is width-independent |
| `SPV`'s repo must contain zero references to PP | `../ibiza/PP-SPV-BUFFER-DESIGN.md` §1 | superseded by the decision to bring the pool contracts in |
| `BatchVerifierLib.PUB_LEN` is 7, so the batch path bypasses the predicate | `docs/actionable/SPRINT.md` | `PUB_LEN = 8` in both batch libraries; `s[7]` is the blacklist root and is re-anchored per withdrawal |
| `tsc` cannot run in this tree because `spa/` has no `node_modules` | `CLAUDE.md` | it has them, and running it found four client defects the ABI checker was green through |

⚠️ **Six libraries were *folded into* another file rather than renamed or deleted, and this is the
most dangerous class of stale reference here** — the code is live and a grep for the old name returns
a comment, so the reader concludes the feature was removed. `ExitLib` and `MuSig2Agg` are in
`BitcoinTx`; `ExternalTwap` is in `OracleLib`; `FixedRateFill` and `ShareMath` are in `SwapLib`.
`SOR.sol` is the opposite case and a genuine tombstone. The full table is in `CLAUDE.md`.

---

## 5. What crosses a repository boundary

Four couplings, and each is a thing that breaks silently.

1. **`ibiza` consumes `SPV`.** It pinned this repo as a git submodule and hand-declared `ISpvVogue` /
   `ISpvBasket` as subsets of our contracts. **Both are now deleted** (`ibiza@8fa5e9e`), addresses are
   injected at runtime instead, and the integration returns when SPV is ready. The design rationale
   is `ibiza/PP-SPV-BUFFER-DESIGN.md`; read it knowing §1's optics premise is superseded.
2. **`ibiza` owns the mobile client; `SPV` owns the protocol.** The LP signer app spec is
   `ibiza/TODO.md` §3b and is deliberately **not** restated in `QUEUE.md` — two copies drift, and the
   one that drifts is always the copy in the repo that cannot build the thing.
3. **`seeker-main` tracks the SVM program.** `svm/tests/seeker-parity.ts` asserts it. ⚠️ **That guard
   only runs if you point it at the app:** `findSeeker()` searches `svm/seeker` and `<repo>/seeker`,
   and the app is outside this repo. Run it as
   `QUID_SEEKER_DIR=/home/rico/projects/seeker-main`, after an `anchor build` — otherwise both sides
   of the comparison are missing and every assertion skips silently while reporting green.
4. **Pushing to any `quidmints/*` remote needs the SSH alias.** `git@github-quidmints:quidmints/<repo>.git`;
   a plain `github.com` remote is refused.

---

## 6. Code that cites this file

Three Solidity comments used to cite `spec.md §3.8` for the fees-versus-LVR test. That number
described the old dashboard document's LP-economics section and does not exist here, so the citations
were repointed rather than orphaned: the question *"did realized fees cover the IL we bore?"* is
answered by `QuidLib.derivedThetaWad` itself — realized retained premium over `K·σ²`, where a result
below `1e18` means they did not. ⚠️ **Do not re-add a numbered cross-reference into this file.** It is
a map; its section numbers move when a repository does, and a comment pinned to one goes stale the
next time anything is reorganised.
