# SPV — working rules and environment facts

This file exists because these facts were living **only** in one machine's agent-memory directory.
`docs/actionable/QUEUE.md` tracks *what to build*; this file tracks *how to work here* and *what the
environment actually is*. Every line below was verified in-repo, not recalled.

## Standing rules (from the repo owner; they apply to every task, not just the one that prompted them)

1. **No unreachable code.** If a branch can't be hit, delete it — don't leave it "for safety".
2. **One declaration per interface, in a shared file.** `src/imports/Interfaces.sol` is canonical.
   No per-file `IFoo_` variants.
3. **Minimise clamps that give a false sense of safety.** Attack the cause, not the symptom.
   *Inverse:* a check **earns** its place when violating it would be **silent** and produce
   plausible-but-wrong output. The discriminator is whether the failure announces itself.
4. **Never mask the question.** A tolerance, guard, or skip that makes a test pass is the tell that
   the real defect is still there.
5. **Don't mock.** Use real addresses. Inherited or vendored code is not exempt from testing.
6. **Fix on detect.** Don't file a follow-up for something you can fix now.
7. **No cryptic names.**
8. **Don't hand-roll** what an existing library or tool already does.
8b. **MINTING QU!D IS A LAST RESORT** (owner, 2026-08-09): *"we should only be minting QU!D at
    all anywhere in the scope if it's the only elegant way out of a grotesquely awkward
    alternative."* A mint creates a liability against the basket; paying with value that
    ALREADY EXISTS never does. Before adding one, show the non-minting route is grotesque, not
    merely inconvenient. *Worked example (E145-r):* forgone BTC-leg fees could be paid by
    minting QU!D at the BTC price — but those sats are **already in `POOLED_BTC`**, so settling
    in sats is both simpler and liability-free. The mint was ruled out on this rule alone.
    ⚠️ Note what this does NOT say: the seven existing mint sites are not thereby wrong — the
    fee/redeem legs pay a 6-dec USD claim in an 18-dec token and have no pre-existing balance
    to draw on. The rule bites on NEW mints, and on any mint added because it was the first
    idea rather than the last.
8c. **PREFER A `private view` CHECK OVER A MODIFIER** (owner, 2026-08-10). A modifier's body is
    **inlined at every use site**, so N uses means N copies in bytecode; a function is one routine
    and N jumps. *Measured (E164):* replacing four per-channel gates with one `onlyHop` modifier
    grew `BTCChannels` by **968 bytes** — on a contract whose deploy margin is the binding
    constraint. The same check as `_onlyHop()` gave 200 back. Modifiers read well and cost size.
8d. **LAND IT, DO NOT REVERT IT** (owner, 2026-08-10, said twice). When a change breaks tests, the
    job is to make it land SECURELY — find the missing guard, signal or discriminator. **Before
    touching `git checkout`, state explicitly whether the change is WRONG or merely INCOMPLETE.**
    Reverting is correct ONLY for the first. *Worked example (§E2-HAIRCUT):* I reverted a
    pre-deposit-basis fix because a control asserting "mints exactly 1:1" failed — but that control
    encodes the OLD model, and in that fixture the basket was SHORT before the deposit and whole only
    BECAUSE of it, so the new number was arguably CORRECT and the assertion stale. **A test failing
    is not evidence the change is wrong; it is evidence the change and the test disagree.** Say which
    one is wrong, with a reason, or keep the change and instrument.

9. **Price every fix on every axis** before calling it done: correctness (tested, not reasoned),
   cost/frequency, blast radius, second-order effects, other callers, reversibility. The regression
   is always on the axis nobody measured. If an axis can't be measured yet, say so explicitly.
10. **One money-path change per test run**, with a falsifiable prediction stated first. Two at once
    and failures can't be attributed.
11. **Commit every completed unit immediately**, and commit *before* starting a long-running build or
    test — a command chained to its own commit dies on the tool timeout, the edit lands, the record
    is lost.

12. **Lift a finding to a task IN THE SAME TURN, or it does not exist.** If you write "worth
    checking", "still needs", "I didn't" — book it before sending the message. A finding in prose
    dies with the context window. Four real items were lost this way on 2026-08-02, each already
    written down somewhere: recorded somewhere, actionable nowhere.
13. **A dismissal is a conclusion.** "That's a false positive" needs the same evidence as a finding.
    Twice in one day a real finding was waved away with a plausible explanation that was never
    checked — and the second time the dismissal had already been committed to a document.
14. **Another thread may be in this tree.** Check `git status` before staging. **Never `git add -A`,
    never commit with `-a`** — stage your own files by name, or you will sweep someone else's
    staged work into your commit. If there is an unpushed commit that is not yours, do not amend or
    rebase it; pushing it is fine and backs it up.
15. **Never commit an unverified change on a money or proof path.** A plausible-but-wrong constraint
    is worse than a documented open hole, because it looks fixed. One was committed on 2026-08-02
    and broke `main`. If the verification run has not finished, say it is in flight and wait.
16. **CLOSE ONLY WHAT IS AXIOMATIC.** Mark an item ✅ **only if no later decision can reopen it** —
    it is true by construction, by measurement that cannot go stale, or because the code it described
    no longer exists. Everything else stays OPEN with its current state written next to it, however
    much progress it has. **A design decision is not a closure**: while options are still being
    weighed, every item downstream of them is still live, because reversing the decision reopens them.
    Anything landed *conditional* on a choice not yet made is ⏸️, never ✅.
    *Why:* a ✅ is how the next thread decides what not to re-read. A premature one deletes the item
    from the project's attention while the work is still undone, and the loss is silent — the exact
    failure mode rules 12 and 13 exist to prevent, arriving through the status column instead of prose.

## Verification discipline

- **An empty grep proves nothing.** Never assert absence from a search. **Run the CONTROL before
  concluding: would this measurement look the same if I were wrong?** On 2026-08-02, "35 verifiers
  are unreferenced, therefore dead" collapsed when the LIVE verifiers scored identically — they are
  wired by address, not by symbol, so the metric could not distinguish dead from unwired.
- **A comment describes past state.** Audit by structure (`^interface`, `^function`), never by a type
  name — a name matches its own obituary.
- **Report pass/fail from a single run.** Capture once to a file; never enumerate one run's failures
  with a second invocation.
- **Line count is not identity.** Same-named, same-sized files can be complementary halves — `diff`
  before calling anything a duplicate, and find the *live* copy before editing.
- **Check the mechanism before building around it.** The fix is usually smaller, or somewhere else.
- **EXISTING MACHINERY IS POSITIVE EVIDENCE. Weigh it against your own search.** If you conclude a
  path is unreachable, ask what the code that serves it is *for* — nobody builds an owed ledger, a
  settlement entrypoint, an event and a daemon for a case that cannot occur. On 2026-08-09 three
  independent strands and one measurement said the BTC fee leg never accrues; the machinery around it
  said otherwise and was right. `creditSwapIn` sells into the pool via `onlyBTCChannels`, bypassing
  the user-path guard entirely. **Each strand was true and they were jointly wrong**, because all
  three were about the *user* path and the seller was the *protocol*.
- **A NAMED-BUT-UNEXECUTED CHECK IS A FINDING THAT WILL BE LOST.** Rule 12 says lift a finding to a
  task in the same turn; this is its other half — **if the task you booked is the one that would
  FALSIFY your conclusion, execute it before building on the conclusion.** The same session wrote
  "I have not enumerated those", consolidated that admission into a summary, committed a test
  assertion encoding the unverified conclusion, and moved on to four other items. The check was
  written down three times and run zero times.
- **Count self-caught vs prompted corrections.** Five wrong conclusions were overturned on
  2026-08-09; **zero were caught by the author.** If a session's corrections all arrive from outside,
  its verification loop is not working, and the remaining unexecuted checks are the exposure.
- **After any Solidity change, run `tools/check-client-abis.py`** — and let its result GATE the commit.
  `forge` + `tsc` both green does **not** mean the TypeScript clients still work. ⚠️ **In this tree
  `tsc` cannot run at all: `spa/` has NO `node_modules`, so the ABI checker is the ONLY client-side
  gate available.** That is why its coverage matters: until 2026-08-10 it skipped any declared name
  matching nothing in `evm/out` as "not ours", so **argument drift was caught while a function being
  DELETED OUTRIGHT was invisible** — the SPA was encoding a call to a removed `Vogue.exitInstant`
  (§E154-client-ghosts). Unmatched names are now `ORPHAN` failures. **Chaining the check ahead of a
  commit in one command is not gating it — I read "2 drifted" and committed anyway.**

## Traps verified on 2026-08-10 — each cost a wrong conclusion, all are cheap to avoid

- **A SHARED TREE INVALIDATES EVERY FULL-SUITE NUMBER, AND IT IS NOT OBVIOUS.** Another thread's
  UNCOMMITTED edits produced **180 `BufferOverflow` failures** in tests I never touched, and two runs
  90s apart counted **4,428** vs **3,107** total tests (a reverting `setUp` drops its whole suite from
  the count, so counts swing wildly). ⇒ **If `git status` shows files that are not yours, set the
  worktree up BEFORE the first measurement, not after three ambiguous runs:**
  `git worktree add --detach <path> HEAD` — their work is uncommitted, so HEAD excludes it BY
  CONSTRUCTION — then copy the gitignored `evm/.env`. Cost: ~6 min cold compile (342s vs ~105s warm).
  **Clean baseline that day: 4,402 passed / 1 failed**, the failure being `testRoundTripNoRaceNoDrain`
  at `499224755743233795668` — pre-existing, and byte-identical across every arm all day.
- **`redeemableAmount()` IS CACHE-SENSITIVE** — `get_metrics`/`get_deposits` are NOT `view`. Without
  refreshing first it reports a collapse to **0** indistinguishable from a real defect.
- **`USD_FEES`, `USD_FEES_BTC`, `feesPerShareBTC` ARE PER-SHARE ACCUMULATORS, NOT DOLLARS**
  (`SwapLib.sol:1392` credits `mulDiv(usd6, WAD, totalShares)`). For dollars, multiply back by the
  credit site's OWN share base (`Vault.sol:640`: `lpSharesBTC + totalBufferBTC`).
- **`docs/actionable/QUEUE.md`'s STATUS-MARKER COLUMN IS UNRELIABLE — PLAN FROM ROW BODIES.**
  `UNIT-A` still read 🔴🔴🔴 after it landed. Re-reading two rows overturned the plan twice running.
- **`Core` CANNOT AFFORD A GETTER.** Measured: a two-address getter costs **91 bytes**, a
  `(bool,bool)→address` one **98** — more than the 76 freed by deleting dead state. The dust monitor
  reads mock addresses from RAW SLOTS (`UnificationControls.t.sol`) for exactly this reason, which
  couples the HARNESS (not the contract) to `Core`'s state ORDER: reorder it and tests fail with
  `unrecognized function selector 0x70a08231` four frames deep. A stale-slot guard now names it.

## Code navigation — read this before answering a "how does X work" question

⚠️ **`graphify-out/graph.json` contains ZERO Solidity.** Measured 2026-08-03: 17,624 nodes, of which
12,953 are `.rs`, 33 `.sh`, 5 `.h`, and **none `.sol`**. It indexed `quid-ln/` including vendored
`lib/rust-lightning`, and skipped `evm/src/` entirely. This matters because the graphify skill instructs
a session to answer any codebase question from that graph *before doing anything else* when
`graphify-out/graph.json` exists — so a question about `Vogue`, `Aux`, `LevManager` or anything else
on the money path would be answered from a graph that does not contain it. **Use the graph for the Rust
bridge. Never use it for Solidity.**

**For Solidity, use `evm/slither-out/` instead.** Slither understands inheritance, modifiers, state
variables and cross-contract call flow, which a generic AST walker does not. Regenerate with:

```
mkdir -p evm/slither-out && cd evm/slither-out
slither .. --print call-graph,inheritance-graph,contract-summary,function-summary,\
vars-and-auth,modifiers,entry-points,require,variable-order,human-summary,loc \
  --filter-paths "lib/|test/|node_modules" > all-printers.txt 2>&1
```

One invocation compiles once and emits every printer. `vars-and-auth` is the one to reach for when the
question is *who can call what and what does it write* — it is the fastest check on the
ownership/renounce posture that `docs/FAQ.md` Part 6 argues to counsel. `.dot` files render with
`dot -Tsvg`. Slither is also a static analyser, so a bare `slither ..` surfaces real findings on the
same compile.

## The central structural fact — read this before proposing any refactor

**`isBTC` is polymorphism done by hand, and the duplication it implies is the codebase's biggest
single source of bulk.** ~5,500 lines sit in **four ETH/BTC pairs**:

| ETH side | BTC side | role |
|---|---|---|
| `Vogue` 1,557 | `Vault` 991 | band manager — ⚠️ **but see the caveat below: this row is unconfirmed** |
| `LevManager` 908 | `BtcLevManager` 579 | lev manager (`§A.71`: `LevManager.Pos == BtcLevManager.Pos`) |
| `VogueLib` 694 | `BtcVaultLib` 603 | delegatecall bodies |
| `VEth` 116 | `VBtc` 105 | ERC-4626 faces |

**`Core` is the one place that got it right** — it parameterises the same distinction with a bool
(187 of the 359 `isBTC` occurrences; 13 files; 26 sit in `Interfaces.sol` signatures purely to pass
it through). Everything *above* `Core` forked into per-asset copies instead.

**The owner's target (2026-08-06):** *"there should just be one band manager, one lev manager, the
entire codebase needs to be slimmed as much as humanly possible without breaking anything and
respecting any discrepancies/asymmetries that must be there for a reason."* One implementation, two
instances — at which point `isBTC` has nothing to select between and deletes itself. ERC-4626 agrees:
it is **defined** around one `asset()`, so one vault / one asset / one instance makes the standard and
the architecture stop fighting. **Full plan, evidence ledger and pass order: task §J.2.**

⚠️ **Two traps this framing exists to prevent.** (1) A *face-level* refactor (just `VEth`/`VBtc`)
looks like the job and removes **nothing** from `Core` — it leaves all four pairs intact. (2) The
size gaps (1,557 vs 991) prove something differs but **not which kind**: every asymmetry must be
classified as a REAL per-asset requirement or as DRIFT before anything merges. Known-real, do not
dedupe away: the gross-vs-net pooled comparison (`Core.sol:691-694`), 8-vs-18 decimals with vBTC's
identity conversions, vBTC having no bearer redemption (`§A.19b`/`§A.45`), and LN-cooperative-close
vs on-chain-WETH settlement.

⚠️ **`VEth.sol:19-27` asserts the vETH/vBTC asymmetry is structural. Five measurements contradict it**
(and `§A.16b`, read 2026-08-07, turns out to be a **clock-consistency** invariant — numerator and
denominator must share a reconciliation clock — **not** a storage-locality one, so its stated objection
to relocating vETH balances does not follow). Treat that header as a record of a decision, not a
derivation. The real constraint it leaves behind: any relocation must preserve the **recorded-vs-live**
lev distinction, or the socialised-liquidation race in `§A.16b` reopens.

🔴 **`Vault` IS TWO THINGS FUSED, AND MUST BE SPLIT BEFORE ANYTHING CAN BE MERGED** (measured
2026-08-07 by classifying its whole surface — 11 ETH-named functions, 20 BTC-named, 24 state decls):

| slice | what it is | members |
|---|---|---|
| **ETH venue custody** | 4626 venue positions | `supplyEtherFi` `supplyAaveEth` `supplyEulerEth` `offrampEtherFi` `_supplyETH` `_withdrawETH` `aaveEthBalance` `vogueETH` (`:444`) `deliverableETH` `_ethCfg` + every venue address (`AAVE_SPOKE` `GALAXY_VAULT` `EULER_VAULT` `GAUNTLET_VAULT` `ETHERFI_*` `WEETH`) |
| **BTC band accounting** | the actual counterpart of `Vogue` | `registerBtcLp` `resizeBtcLp` `unregisterBtcLp` `exposeBtcToLev` `unexposeBtcFromLev` `syncLevBTC` `totalSharesBTC` `bandBtcOf` `_settleBtcLp` `settleBtcFeesOwed` `derivedThetaWadBtc` `lpSharesBTC` `autoManagedBTC` `levPooledBTC` |

⇒ **`Vogue`'s pair is the BTC-band SLICE of `Vault`, not `Vault`.** The ETH-venue slice is a THIRD
concern with **no BTC counterpart — correctly**, because ETH venues are 4626 vaults while BTC custody
is Lightning channels (`BTCChannels`). That is the settlement asymmetry, and it is REAL.
🔴 **`VBtc` MUST SURVIVE THE CONSOLIDATION — do not "delete it into" the band manager.** The BTC band's
`asset()` is **not a real ERC-20 underlying**: it returns WBTC as a *pricing handle* (the venue prices
vBTC against WBTC via `getTWAPforAsset`) and `convertToAssets` is a pure identity because **vBTC IS
sats**. The real underlying is LN-custodied native BTC. So "one instance = one `asset()` = an honest
4626" holds for ETH (WETH is genuinely held and redeemable) and only **nominally** for BTC.
⚠️ **THE PRIVACY JUSTIFICATION FOR KEEPING `VBtc` IS DEAD — and `VBtc.sol:18-28` still asserts it.**
That header calls segregation *"a prerequisite, not cosmetics"* for the privacy story, naming a future
`redeemVBtc(sats, p2trScript)` and the `Σ outstanding vBTC ≤ Σ free channel capacity` invariant. But
`../ibiza` **already ruled that out** — `ibiza/TODO.md:2097`: *"**2.4d vBTC through PP — RULED OUT.** It
is not a bearer instrument; there is nothing to anonymise"*, and `:2108-2115`: *"**NOBODY EVER HOLDS
vBTC** … it is an internal accounting token inside the leverage machinery, not a BTC wrapper anyone can
custody. **There is no vBTC holder population to build an anonymity set from.**"*
✅ **RESOLVED (owner, 2026-08-07) — AND THE REAL REASON IS NEITHER OF THE ONES THE CODE GIVES.**
`VEth` **deletes**; `VBtc` **survives**. The discriminator is simply *whether an ERC-20 underlying
already exists*:
  • **ETH — none needed.** WETH exists independently; wrapping/unwrapping is an edge detail. The band
    manager instance names `asset() = WETH` and IS the 4626 outright. `VEth` has no remaining job.
  • **BTC — one must be MINTED.** The underlying is LN-custodied native BTC, which has **no EVM token**;
    WBTC is only a pricing handle and is never held. So the BTC band needs a **synthetic underlying to
    point `asset()` at**, and that is exactly what vBTC is (`ibiza/COMPLIANCE-THESIS.md:77`: *"a
    synthetic, sats-denominated token minted only against…"*).
⇒ `VBtc` exists because **the BTC band has no underlying unless it mints one** — NOT because anyone
holds it, custodies it, or anonymises it. An asymmetry with a real reason, and one that survives
instantiation rather than being dissolved by it.
⚠️ Follow-on to settle when this lands: today `VBtc.asset()` returns **WBTC** as a pricing handle. Under
this design vBTC IS the band's asset rather than having one, so that accessor's meaning has to be
revisited — do not carry it across unexamined.

🔴 **AND IT IS WORSE THAN STALE — `VBtc.sol:18-28` PROPOSES A FEATURE ibiza ANALYSED AS CROSS-LP THEFT.**
That header argues *"swap-out already proves the protocol can pay an arbitrary P2TR address whose owner
has no channel — so what is missing is an ENTRYPOINT plus a source-of-funds rule, not a capability"*,
and names `redeemVBtc(sats, p2trScript)`. `ibiza/TODO.md:2118-2132` rejects precisely that, quoting
`BTCChannels.sol:477-496`: *"We REJECT any other output: without this, a malicious LP could route its
withdrawal to a script != `btcRecipientOf`, making `_lpFinalBalance` read 0 → `delivered = shrinkSats`
→ **over-claim the SHARED swap-out proceeds pool (cross-LP theft)**."* The contract cannot see WHO was
paid, only HOW MUCH reached the committed script; `btcRecipientOf` is ONE source of truth for both
cooperative-close attribution and the splice path. ibiza's verdict: *"Unbinding it to gain anonymity
would trade a cryptoeconomic invariant for a privacy property — the wrong direction."*
⇒ **Do not implement `redeemVBtc(sats, p2trScript)` on the strength of that header.** Reconcile the two
documents first — and note the header's premise ("swap-out already pays arbitrary P2TR") needs checking
against whether the SWAP-OUT path and an LP WITHDRAWAL path have the same attribution guarantees.

⇒ **A CROSS-REPO STALE RATIONALE**: SPV's contract justifies its own existence with a design the
consuming repo has retired. Neither file knows about the other. Do NOT keep `VBtc` on privacy grounds,
and do NOT delete it on those grounds either — **the surviving question is the OTHER blocker its header
names: an open Morpho/Euler market, where a liquidator who seizes vBTC has no way to exit.** Settle THAT
before deciding, and reconcile the two documents whichever way it goes.

⇒ **Extra step, ordered FIRST:** extract ETH venue custody out of `Vault`. Only then does
`Vogue` ∥ `Vault`-BTC-slice become one band manager with two instances. The 1,557-vs-991 size gap is
explained by this fusion, not by drift — which is exactly why every gap must be classified before
merging.

## Build environment

| | |
|---|---|
| solc | `0.8.30`, optimizer on, **200 runs** (`evm/foundry.toml`) |
| `via_ir` | **`false`, deliberately.** Stack-too-deep is solved by moving locals into struct fields (one memory pointer costs less stack than two values), not by turning on the IR pipeline. |
| remappings | `evm/remappings.txt` only — there is deliberately no `remappings = [...]` in `foundry.toml` |
| **EIP-170** | `forge test` does **not** enforce the 24,576-byte limit. **`forge build --sizes` does not either, for the contracts that matter most** — measured 2026-08-05: `Core` has **no row in that table at all** (278 rows; `SwapLib`, `Aux`, `BasketLib`, `LevManager`, `LevMath`, `VogueLib` all present). The cause is *not* library linking — `SwapLib`, `Aux`, `LevManager` and `Vogue` are all linked and all appear — and remains **unknown**. **Use `python3 tools/check-contract-sizes.py` instead**: it reads `deployedBytecode.object` from `evm/out/**` for every contract declared in `evm/src`, which is exact (a link placeholder `__$…$__` is 40 hex chars = the 20 bytes its address occupies). **MEASURED MARGINS — the previous "all three sit within ~150 bytes" was off by an order of magnitude: `LevMath` 24,556 (20 left) · `Core` 24,538 (38) · `LevManager` 24,506 (70) · `Vogue` 24,160 (416) · `Aux` 22,847 (1,729) · `SwapLib` 22,678 (1,898).** ⚠️ **Treat `LevMath`, `Core` and `LevManager` as frozen for additions.** This repo has already shipped a `Core` at −126 bytes (undeployable) with a fully green suite; a ~52-byte addition to `Core` on 2026-08-05 consumed more than half the remaining margin before anyone measured it. |
| library bodies | Delegatecalled library functions must be `external`/`public`. That is why the external surface is large; it is not accidental API. |
| fork tests | ⚠️ **`FOUNDRY_RPC_ENDPOINTS_MAINNET` DOES NOT WORK — it is silently ignored.** `foundry.toml` resolves `mainnet = "${ETH_RPC_URL}"`, so the override is **`ETH_RPC_URL=<url> FORK_BLOCK=<n> forge test`**. Measured 2026-08-10: two full suites reported 3,318 and 1,623 failures, **all 403/429, zero assertions**, because the ignored variable left forge on the non-archival public node while `FORK_BLOCK` was pinned. **A PINNED BLOCK REQUIRES THE ARCHIVE ENDPOINT** (`ETH_RPC_URL=$ANKR_RPC_URL`); publicnode is keyless but head-only. Public nodes are not archival; a stale `FORK_BLOCK` fails to fetch rather than failing a test. ⚠️ **A DEAD RPC KEY LOOKS LIKE A BROKEN TEST SUITE.** On 2026-08-06 the ankr key in `evm/.env` returned `HTTP 401 "API key disabled"`, which fails inside `setUp()` — so **every fork test in the repo reported FAIL** with no assertion involved. Read the failure text before believing a mass regression: `could not instantiate forked environment` is an endpoint problem, not a code one. **Verified live and keyless 2026-08-06** (block 25,697,138): `ethereum-rpc.publicnode.com`, `rpc.flashbots.net`, `eth.drpc.org`. Dead: `eth.llamarpc.com` (521), `cloudflare-eth.com` (-32046). `foundry.toml:44` already names publicnode as the keyless fallback; `evm/.env` now points there. This is also the likeliest thing CI was mailing about. ⚠️ **BUT THE KEYLESS NODE RATE-LIMITS UNDER A FULL-SUITE RUN.** Measured 2026-08-08: three tests failed with `HTTP 429 "Rate limit exceeded"` from publicnode — `test_ClassifyAllVenues`, `test_RunSim_IL_Baseline_ChopIsBenign`, `testGrindRemoval_DrainPaysRetainedSkewPremium`. **That is an ENDPOINT failure wearing a test's name, same category as the 401 above**, and it moves between runs, so treat any `Max retries exceeded HTTP error 429` line as environmental before attributing it to code. ▶️ **A replacement archive key is banked as `ANKR_RPC_URL` in `evm/.env` (gitignored; NEVER put it in `foundry.toml`, which is committed).** Verified live 2026-08-08 — `eth_blockNumber` → `0x1885000`, and `eth_getBalance` at block `0xF4240` returns a real value rather than a missing-trie-node error, so it **is** archive-capable. **It is deliberately NOT wired into `ETH_RPC_URL`:** publicnode stays primary, and this is for archive needs or when 429s appear — `FOUNDRY_RPC_ENDPOINTS_MAINNET=$ANKR_RPC_URL forge test` uses it for one run with no file edit. |
| Rust (`quid-ln`) | **Does not build on macOS at all** — `quid-cvm` is Linux-only and transitive. Use the image: `docker build -t quid-ln:dev quid-ln` then `docker run --rm -v "$PWD/quid-ln":/w -w /w quid-ln:dev`. **VERIFIED GREEN: 624 passed / 0 failed (2026-08-07).** Was recorded as 532; the count grew AND the tree was red in between — two `quid-tls` shared-seed snapshot tests encoded pre-`QUID-REALM` values (see `quid-tls/src/shared_seed/certs.rs`). A recorded pass count goes stale silently; re-run before trusting it. `quid-ln/Dockerfile` is the single source for the commands — it pins rust 1.90 to `rust-toolchain.toml` and bakes Bitcoin Core **30.2, the same version `regtest/env.sh` uses** (a split would mean Docker and host harnesses disagreeing on consensus). |
| Docker VM memory | `docker info` MemTotal is a **VM allocation, not host free RAM** — closing apps does nothing. Default is ~2 GB; **raised to ~5 GB 2026-08-02, and measured at ~13.6 GB on 2026-08-08** (`docker info` MemTotal 13,618,397,184 — re-read it rather than trusting this line, which was already stale once). Change at Docker Desktop → Settings → Resources → Memory. **Not scriptable:** `~/Library/Group Containers/group.com.docker/settings.json` is TCC-protected, so a shell gets `Operation not permitted` even as its owner without Full Disk Access. ⚠️ **Under-memory `rustc` is OOM-killed with NO diagnostic** — just `process didn't exit successfully`, no error code or span. That reads exactly like a compile error and is not one. Escape hatch: `-e CARGO_BUILD_JOBS=1 -e RUSTFLAGS="-C debuginfo=0"`. |

## Decimal bases — the single most common source of bugs here

Three bases coexist: **6** (USD stables), **8** (sats/WBTC), **18** (ETH/QU!D/internal USD).

The WBTC price carries a **×1e10 lift** (`usd·1e28`), which closes the 8↔18 gap — so a flat `/1e30`
or `1e18` scale is correct for **both** assets, and adding a second `×1e10` somewhere "to fix BTC"
double-counts it.

**Never infer a stable's decimals from its slot index.** A positional divisor
(`i < 4 || i == 11 ? 1e12 : 1`) shipped once and broke when a 6-dec stable joined at a later slot;
`IERC20(stable).decimals()` is the fix, not the complexity (`src/imports/BasketLib.sol:282`).

## Cross-repo

- **`../ibiza` consumes SPV as a pinned git submodule** and depends on exactly four Vogue/Basket
  signatures staying permissionless and stable. Changing them is a breaking change for a repo that
  isn't in this working tree.
- `docs/informational/` **contradicts the contracts in ~10 verified places** (the band is ±0.2%, not
  ±2%; the short leg, `baseRate`, CRE, and the swap-in bonus are gone; the stable count moved).
  Never quote it without checking the code.
- `docs/actionable/BUILD-QUEUE-AND-107.md` is an **append-only archive**: its evidence (traces,
  `file:line`, measurements) is authoritative, its **status markers are not**. Current status lives in
  `docs/actionable/QUEUE.md` and is updated in place. Some of its citations point at `/home/rico`
  paths from a different machine and cannot be opened from here.
