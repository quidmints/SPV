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
14b. 🔴 **`git rm` STAGES IMMEDIATELY — SO A DELETION IS A LANDMINE FOR WHOEVER COMMITS NEXT**
    (measured 2026-08-15, it broke `main`). Rule 14 warns about sweeping someone else's work into
    YOUR commit. This is the MIRROR IMAGE and nobody plans for it: three `git rm`-staged deletions
    (`VEth.sol`, `VEthIdentity.t.sol`, `LevOracles.sol`) sat in the index while the code REPLACING
    them was still unstaged. Another thread committed, picked up the whole index, and landed my
    deletions inside `8debdb7` — *"Routing fees are absent by design: the node is unannounced"*, a
    Lightning change. For that window `main` had the contract DELETED, `Quid` without the
    replacement face, and `DeployL1_s` importing a file that no longer existed: **it could not
    compile, and the history attributes a Solidity deletion to a commit about Lightning.**
    ⇒ **A DELETION AND ITS REPLACEMENT MUST BE STAGED AND COMMITTED TOGETHER**, or the deletion
    waits. If you must remove a file early, use `rm` (leaves it unstaged) and `git rm` only in the
    same breath as the commit. **`git status --short` showing no `D ` rows does NOT mean your
    deletion is safe — it can mean someone already committed it for you.** Check `git log -- <path>`.
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

17. **A ROOT FIX MAKES THE PREVIOUS FIX DELETABLE; A CLAMP ADDS ANOTHER BOUND** (owner,
    2026-08-14, promoted to a standing rule). This is the operational test for standing rule 3 —
    apply it to your own landed work, not only to proposals. *Worked example (§T1-f-root):* pool
    inventory and LP sats shared one funding UTXO, so **every** payout path had to subtract to
    work out who owned what — close, shrink, and the exit rung each needed their own bound, and
    each was a place to get it wrong. I landed `poolOwnedSats` to make the divergence observable,
    which was a good instrument for a condition that **should not be reachable at all**. The root
    fix — pool sats may only enter where no LP can claim them — makes that ledger and both bounds
    **delete themselves**.
    ⇒ **When you find yourself adding a second guard for the same class of thing, stop and ask
    what state makes both necessary.** If the answer is "the state is wrong", fix the state:
    prefer making the bad state UNCONSTRUCTIBLE over making it DETECTABLE. A clamp that survives
    a root fix was never the fix.
    ⚠️ The inverse still holds (rule 3): an instrument that makes a *silent* failure observable
    earns its place **while the root is still reachable** — `poolOwnedSats` was correct to land
    and is correct to remove, in that order.

## 🔴 RULES 11 AND 15 CONTRADICT EACH OTHER IN A SHARED TREE. THE WORKTREE IS THE RESOLUTION (2026-08-21)

Rule 11 says **commit before a long build**, because the edit outlives the command. Rule 15 says
**never commit an unverified money-path change**, because a plausible-but-wrong constraint is worse
than a documented hole. In a tree several threads share, **both cannot be obeyed**: verifying first
means holding the work uncommitted across a multi-minute build, which is exactly when another thread's
`reset`/`checkout` can erase it.

**It fired on 2026-08-21 and cost a full build cycle.** Four `BTCChannels.sol` edits (the §LAZY-OPEN
split) were made, `forge build` returned exit 0, and `check-contract-sizes.py` measured the change at
**+331 bytes**. Another thread then reset `evm/`, and `git status` showed only the two *Rust* files as
dirty — the Solidity was gone from the working tree AND absent from `HEAD`.

⇒ **THE RESOLUTION, AND IT SATISFIES BOTH RULES RATHER THAN PICKING ONE:**
```
git worktree add --detach <path> origin/main    # isolated: no other thread writes here
<make the money-path edits>
git commit                                       # LOCAL only — preserves the work (rule 11)
<build + test>                                   # verify in isolation
git push origin HEAD:main                        # only now does main see it (rule 15)
```
A local commit in a detached worktree is not a publication, so "commit early" stops meaning "publish
unverified". **Do money-path work in a worktree from the start** — retrofitting one after the loss
costs the whole cold compile (~6 min) a second time.

🔴 **AND ITS TWIN, WHICH COST A CLOBBERED `main` THE SAME DAY: `git reset --soft <base>` STAGES THE
REVERSAL OF EVERYTHING BETWEEN `<base>` AND YOUR TREE — AND IN A WORKTREE THAT HAS BEEN RESET BACK
AND FORTH, `<base>` IS NOT WHATEVER `origin/main` HAPPENS TO BE.** Squashing two WIP commits, I reset
`--soft` to *the `origin/main` I had reset to for the baseline arm* — but the tree was back on a
PINNED ref whose parent predated that commit. The diff therefore carried my 3 files **plus the
reversal of every commit in between**, and it went out as **26 files, 969 insertions / 922 deletions**,
reverting `CLAUDE.md`, `spec.md`, `FAQ.md`, `PRODUCTION-LAUNCH.md`, ten `docs/actionable/` files
including `QUEUE.md` and `SPRINT.md`, and another thread's TriCrypto scrub.
⇒ **THE TELL WAS PRINTED AND I READ PAST IT.** The commit echoed `M CLAUDE.md`, `M docs/FAQ.md`,
`M deploy/PRODUCTION-LAUNCH.md` — **files I had never opened** — and I pushed anyway. Same
"read the effect, not the exit code" rule as everything else here, arriving through the staged list.
⇒ **BEFORE ANY SQUASH: `git diff --cached --name-only`, AND CONFIRM EVERY PATH IS ONE YOU EDITED.**
Better, skip the squash entirely — `git reset --soft $(git merge-base HEAD origin/main)` names the
real parent, or just push the WIP commits as they stand. A tidy history is not worth a reverted `main`.
⚠️ **THE REPAIR THAT WORKS, since `git revert` would also undo your own change:** restore every
unintended path from the commit BEFORE yours (`git checkout <prev> -- <path>`), re-apply your own
files from your commit, then verify with `git diff --stat <prev> origin/main` — it must list ONLY
your files. Stage by name, per rule 14; the bulk-stage flags are refused by a hook here anyway.

⛔ **AND THE TRAP THAT MADE IT INVISIBLE, WHICH IS THE PART WORTH REMEMBERING: `evm/out` OUTLIVES
`evm/src`.** The size check ran AFTER the reset and still reported the new number, because it reads
`deployedBytecode.object` from artifacts the deleted source had already produced. **A green
measurement can describe code that is no longer in the tree.** The same applies to any `forge test`
started before a reset — it recompiles from the reverted source, so its result is not about your
change either, and it will look like a clean pass.
⇒ **AFTER ANY SUSPICIOUS `git status`, RE-GREP THE SOURCE FOR YOUR OWN SYMBOL BEFORE TRUSTING ANY
NUMBER YOU JUST MEASURED** — `grep -c "<newSymbol>" <file>` returning 0 while the build was green is
the signature of this, and nothing else produces it.

## Verification discipline

- 🔴 **CLOSING THE WORK IS NOT CLOSING THE ROW, AND THE ROW IS THE HALF THE NEXT THREAD READS.**
  Measured 2026-08-21: **three stale rows found in three consecutive questions**, all the same shape
  — the fix was landed, the commit message described it, and the ledger row still said 🔴.
  `§MIDNIGHT-SUBMODULE-HALF-DONE` read *"the change CANNOT BE PUSHED"* after the change was pushed;
  `#20` read *"I broke ibiza's wallet fixture"* after it was fixed; `D8` read *"`origin/main` DOES
  NOT BUILD"* after a pinned rebuild exited 0. **None was found by the author** — each surfaced only
  because the owner asked what a row was.
  ⇒ **A commit is not a closure. The unit of work is code + row, in the SAME commit.** Landing the
  code and leaving the row is how a fixed thing keeps being re-read as broken, which costs the next
  thread the same investigation twice — the exact waste rule 12 exists to prevent, arriving from the
  opposite direction.
  ▶️ **The cheap sweep that finds these, and it takes seconds:** grep the OPEN rows for their own
  falsifiable claims — *"does not build"*, *"zero references"*, *"NOT BUILT"*, *"cannot"*, *"never"* —
  and re-run each. A row that states a testable fact is a row that can be tested; one that cannot be
  tested that way was never a status, it was an opinion.
  ⚠️ **Corollary, from the same three: a booking written from a SYMPTOM outlives its fix.** `#20` was
  booked as *"ibiza pins the old output key"* — the visible thing — when the defect was the field
  list its commitment hashed. The pin was correct all along, so fixing the real defect left the row
  pointing at something that was never wrong. **Book the mechanism; the symptom is what you noticed,
  not what is broken.**



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
- ⛔ **A `dead_code` WARNING IN THIS REPO IS SOMETIMES A DELIBERATE MARKER FOR A GAP. `git log -S`
  THE SYMBOL BEFORE DELETING IT.** `create_sweep_tx` has now been deleted **twice** and restored
  twice by people reading "never used" as litter — and the restoring commit (`36d0de2`) says so
  outright: *"the dead_code warning therefore returns, and it is now accurate: it marks a real gap
  (missing authorized trigger), not litter to delete."* One `git log -S "<symbol>"` would have
  surfaced that in seconds, both times. **Rule 1 deletes UNREACHABLE code; it does not delete a
  maintained, tested function whose caller is a security feature nobody has built yet** — that
  distinction is the whole difference, and "the seed migrates so a sweep is unnecessary" was the
  plausible-sounding argument that got it wrong the second time (it covers the successor-enclave
  case, not decommissioning or evacuation to an address the seed does not derive).
- ⚠️ **TEST THE CRATE YOU EDITED.** That deletion was "verified" with
  `cargo test -p quid-hop -p quid-bridge` while the edit was in **`quid-ln`**, whose test at
  `wallet.rs:2701` calls the deleted function. The run was green because the crate was never
  compiled. A green suite is what an uncompiled crate produces.
- ⛔ **AND `cargo check` NEVER BUILDS TEST TARGETS — SO IT CANNOT SEE A BROKEN TEST, EVER.** Same
  trap as above, different mechanism, and it caught the same author again on 2026-08-17. §E183
  deleted `lp_eth`/`lp_sig` from `OpenAuth`; the change was verified with
  `cargo check -p quid-bridge --bins` → **exit 0**, and `main` then carried a `quid-bridge` whose
  tests did not compile (`E0560` ×2, `E0609` in `vault.rs`'s `e166_consent_tests`) until someone
  ran `cargo test`. **`--bins` is not a narrower `cargo test`; `check` is a different question.**
  ⇒ **Deleting a struct field is a whole-crate edit no matter how local it looks** — the fields you
  remove are constructed in fixtures, and fixtures live in the one target `check` skips. Use
  `cargo test -p <crate>`, or at minimum `cargo check -p <crate> --all-targets`.
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
  DELETED OUTRIGHT was invisible** — the SPA was encoding a call to a removed `Quid.exitInstant`
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
- **`USD_FEES` AND `feesPerShare` ARE PER-SHARE ACCUMULATORS, NOT DOLLARS.** For dollars, multiply
  back by the credit site's OWN share base — never read one as a dollar figure.
  ⚠️ **RE-DERIVED 2026-08-18: FOUR OF THIS NOTE'S FIVE SYMBOLS NO LONGER EXIST.** It named
  `USD_FEES_BTC`, `feesPerShareBTC`, `lpSharesBTC` and `totalBufferBTC` — **all now 0 references in
  `evm/src`** — and cited `SwapLib.sol:1392`, which today is the line `uint q;`. The BTC-side
  accumulators were fed by **v4 pool trading fees only**, so the v4 cut removed that FEED along with
  the `isBTC` fork; `USD_FEES` (32 refs) and `feesPerShare` survive without the suffix.
  ⛔ **DO NOT READ THAT AS "THE BTC ACCUMULATORS WERE DELETED" (owner's correction, 2026-08-18).**
  They exist on **BOTH instances** — the BTC band is `new Core(cfg.wbtc, …)` (`DeployLib.sol:137`), so **the
  BTC accumulator is `feesPerShare` READ AT THE BTC ADDRESS.** The v4 cut ended the trading-fee SOURCE that
  fed it, not the accumulator. ⚠️ **AND THE RENAME CREATED A NEW WAY TO GET THE UNITS WRONG: the warning says
  multiply by the credit site's OWN share base, and "own" now means THAT INSTANCE'S — which the name used to
  tell you and no longer does. Reading the ETH instance's base against the BTC instance's accumulator is the
  successor to the exact bug this warning was written for.**
  **Live credit sites: `Vault.sol:351`, `Quid.sol:1180`, `Quid.sol:1276`** (`USD_FEES += usdInc`).
  ⇒ The hazard this note exists to prevent is unchanged and still real; only its coordinates rotted.
  **A trap-note that points at deleted symbols causes the exact misreading it was written to stop**,
  because the reader concludes the concern is obsolete rather than that the names moved.
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
`graphify-out/graph.json` exists — so a question about `Quid`, `Aux`, `LevManager` or anything else
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

## ✅ RENAMES: THE DOCS ARE DESTALED — THIS TABLE IS NOW A KEY FOR READING GIT HISTORY (2026-08-21)

`22ec766f` renamed the core contracts and every document kept the old names. **That is fixed: 1,020
substitutions across 20 tracked `.md` files, so a name in the docs now resolves in the tree.** This
table stays because it is still needed for **commits, PR bodies and archived output written before
the destale** — and because `../ibiza` pins this repo as a submodule and may still use the old names.

| written before the destale | the tree has |
|---|---|
| `Vogue` / `Vogue.sol` / `VogueCore.sol` / `IVogue` | **`Quid` / `Quid.sol` / `IQuid`** (QU!D stays the token) |
| `VogueLib` / `VogueLib.sol` | **`QuidLib` / `QuidLib.sol`** |
| `VaultLib` / `VaultLib.sol` | **`QuidLib`** — FOLDED IN and deleted, not renamed |
| `BtcVaultLib` / `BtcVaultLib.sol` | **`BtcLib` / `BtcLib.sol`** |
| `BandState`, then `State` / `State.sol` | **`Shares` / `Shares.sol`** — ⚠️ **TWO HOPS** |

⛔ **A RENAME TABLE IS ITSELF A DOCUMENT THAT GOES STALE, AND THIS ONE DID.** It read *"`BandState` →
`State`"* until 2026-08-21; the contract was then renamed **`State` → `Shares`** (so file and contract
finally agree — `Shares.sol` had been declaring `contract State`), which left the key pointing at a
symbol that no longer existed. **It went stale the moment its own advice was followed.** If you rename
anything, this table is part of the change.

🔴 **WHAT WAS DELIBERATELY *NOT* RENAMED, AND WHY IT MUST STAY THAT WAY.** A blind `Vogue`→`Quid` pass
would have rewritten ~20 more tokens into names that **resolve to nothing**, which is strictly worse
than an obviously-old name: a reader trusts `IQuidShares` and searches for it, where `IVogueShares`
announces its own age. **Measured before the pass: `quidETH` `quidBTC` `quidSyncHook` `quidOp`
`quidAvail` `quidWithdraw` `quidCoreBtc` all have ZERO references in `evm/src`, and `IQuidCore`
`IQuidShares` `IQuidLP` are declared ZERO times.** They are DELETED symbols, not renamed ones. Left
as-is on purpose: **`onlyVogue`, `IVogueCore`, `IVogueShares`, `IVogueLP`, `IVogue_VG`,
`IVogueView_VG`, `NotVogueCore`**, the 211 lowercase `vogue*` members (`vogueETH` alone was 77), and
every `Vogue`-named test.
⇒ **THE DISCRIMINATOR IS WHETHER THE NEW NAME EXISTS, NOT WHETHER THE OLD ONE IS OLD.** Renaming a
tombstone does not destale it; it disguises it.

⚠️ **`docs/actionable/wip/UNIT-A-derive-fee-bound.patch` STILL SAYS `BtcVaultLib` AND MUST.** It is a
diff — rewriting a symbol inside it means it no longer applies. Patches are frozen by construction.

▶️ **`tools/check-doc-symbols.py` reports every `Something.sol` the docs cite that is not in the tree.
The renames are now clear; what it still lists are genuine TOMBSTONES** — `VEth.sol`, `LevBookLib.sol`,
`LevOracles.sol`, `TickLib.sol`, `Midnight.sol`, `AttestedHopRegistry.sol`, `QuidLens.sol`,
`EthVenue.sol` — files that were deleted with no successor, so the citation is history, not rot. **Run
it after any rename, and classify each new row as RENAME or TOMBSTONE before touching anything.**

## The central structural fact — read this before proposing any refactor

**`isBTC` is polymorphism done by hand, and the duplication it implies is the codebase's biggest
single source of bulk.** ~5,500 lines sit in **four ETH/BTC pairs**:

| ETH side | BTC side | role |
|---|---|---|
| `Quid` 1,557 | `Vault` 991 | band manager — ⚠️ **but see the caveat below: this row is unconfirmed** |
| `LevManager` 908 | `BtcLevManager` 579 | lev manager (`§A.71`: `LevManager.Pos == BtcLevManager.Pos`) |
| `QuidLib` (was `QuidLib`) | `BtcLib` (was `BtcLib`) | delegatecall bodies — ⚠️ **RENAMED 2026-08-18**, and `QuidLib` folded INTO `QuidLib` and was deleted |
| ~~`VEth` 116~~ | `VBtc` 105 | ⛔ **THIS PAIR NO LONGER EXISTS — `VEth.sol` IS DELETED (2026-08-18: `ls` confirms, and the only `VEth` strings left in `evm/src` are 3 comments in `Quid.sol` recording the removal).** It is listed here only so the count of four is not read as current. See the RESOLVED note below: the ETH band manager IS the 4626, so there is no ETH face to pair with. |

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
| **ETH venue custody** | 4626 venue positions | `supplyEtherFi` `supplyAaveEth` `supplyEulerEth` `offrampEtherFi` `_supplyETH` `_withdrawETH` `aaveEthBalance` `vogueETH` (`:444`) `deliverableETH` `_ethCfg` + every venue address (`AAVE_SPOKE` `ETHERFI_*` `WEETH`) |
| **BTC band accounting** | the actual counterpart of `Quid` | `registerBtcLp` `resize` `unregisterBtcLp` `exposeBtcToLev` `unexposeBtcFromLev` `syncLev` `_settleBtcLp` `settleBtcFeesOwed` `derivedThetaWadBtc` — plus the band state now inherited from `Shares.sol`'s `Shares`: `lpShares` `autoManaged` `levPooled` `totalBuffer` ⚠️ **SIX NAMES IN THIS ROW WENT STALE ON 2026-08-17/18 AND ARE CORRECTED ABOVE — `resizeBtcLp`→`resize`, `syncLevBTC`→`syncLev`, and `totalSharesBTC` `bandBtcOf` `lpSharesBTC` `autoManagedBTC` `levPooledBTC` all now **0 references in `evm/src`**.** The BTC suffix was deleted (`d2dc8b78` *one name per concept, two instances*, `088d2640`, `e0d72836`) and the per-band state moved into `Shares`, ⛔ **AND "0 REFERENCES" MEANS RENAMED, NOT REMOVED — READ THIS BEFORE CONCLUDING ANYTHING FROM SUCH A GREP (owner's correction, 2026-08-18).** The BTC band is a SEPARATE INSTANCE carrying the SAME names without the suffix: `DeployLib.sol:136-137` constructs `new Core(cfg.weth, …)` **and** `new Core(cfg.wbtc, …)`, so **`lpShares` ON THE BTC INSTANCE *IS* WHAT `lpSharesBTC` NAMED** — same slot, same meaning, different address. ⇒ **THE DISCRIMINATOR MOVED FROM THE NAME TO THE ADDRESS, WHICH IS THE ENTIRE POINT OF THE `isBTC` REFACTOR.** Nothing was deleted; the suffix was, because the instance already carries the distinction. ⚠️ **A ZERO-HIT GREP FOR A SUFFIXED NAME IS EVIDENCE OF A RENAME, NEVER OF A REMOVAL — this file asserted the opposite until the owner caught it.** ⚠️ **THE ROW'S POINT SURVIVES INTACT AND IS WHY IT IS CORRECTED RATHER THAN DELETED: `Vault` IS still two things fused, and this list is still the BTC-band slice.** Only the spelling moved. |

⇒ **`Quid`'s pair is the BTC-band SLICE of `Vault`, not `Vault`.** The ETH-venue slice is a THIRD
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
    ⭐ **THE MECHANICAL EXPRESSION OF THIS, MEASURED 2026-08-18 — and it is the sharpest form of the
    discriminator, so read it before re-opening the question a fourth time: `Quid`'s ERC-20 face is a
    PROJECTION OF BAND STATE, while `VBtc`'s is a LEDGER.** `Quid.totalSupply()` returns `lpShares`,
    `Quid.balanceOf(u)` returns `autoManaged[u].pooled`, and `Quid.transfer` calls `_transferShares` —
    there is no balances mapping, because the band's own accounting IS the balance. `VBtc` declares
    `mapping(address => uint) balanceOf` and moves plain balances.
    ⇒ **`Quid.balanceOf ∥ VBtc.balanceOf` IS NOT A DUPLICATED PAIR LIKE `State`'s TWELVE.** Those twelve
    (`lpShares ∥ lpShares`, `feesPerShare ∥ feesPerShare`, …) are one concept declared twice. These two
    are a projection and a ledger — different things wearing one ERC-20 signature. **Folding them would
    duplicate state, which is the exact thing `Shares.sol`'s header says it exists to delete.**
    ⚠️ **AND DO NOT MOVE THE FACE INTO `State`:** an abstract base COPIES its bodies into every
    inheritor (measured +41 bytes, zero saved), and `State` is inherited by `Vault` too — which already
    has `VBtc` for that job. It would add bytes to the BTC band to remove none from anywhere.
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
`Quid` ∥ `Vault`-BTC-slice become one band manager with two instances. The 1,557-vs-991 size gap is
explained by this fusion, not by drift — which is exactly why every gap must be classified before
merging.

## 🔴 SPLITTING ONE CONTRACT INTO TWO: audit ASSIGNMENTS, not call sites (measured 2026-08-15)

Extracting `EthVenue` out of `Vault` planted **three** instances of one bug, all of which COMPILED
CLEAN and reverted only at runtime, because in Solidity every contract handle is an `address` and the
compiler cannot tell two of them apart.

**THE ROOT: code that merged two identities because they SHARED AN ADDRESS.** `IBtcVault` had existed
as a separate interface precisely to mark that ETH-venue custody and the BTC band manager are
different things. It was deleted as "a second interface over one contract" — true while the address
was shared, false the moment it was not. ⇒ **MERGE ON WHAT THINGS ARE, NEVER ON WHAT ADDRESS THEY
CURRENTLY SHARE.** Same shape as `create_sweep_tx`: a marker for a gap that has not opened yet is
indistinguishable from duplication.

**THE AUDIT METHOD THAT FAILED:** I enumerated every `IBandManager(x).member` / `IEthVenue(x).member`
call site and scored 29/29 correct — and that was TRUE. `IBandManager(c.btcVault).repack(true)` is a
correct call site; the defect was that `c.btcVault` had been ASSIGNED the ETH-venue address upstream.
⇒ **WHEN TWO IDENTITIES SEPARATE, GREP THE ASSIGNMENTS**: `grep -rn "btcVault:" src` and
`grep -rn "ethVenue" src`, then classify each by what the CONSUMER does with it. The worst instance
passed `ethVenue` into a parameter LITERALLY NAMED `btcVault` (`BasketLib.backingCoreBody`), which
then called `repack(true)` on it.

**THE THREE, and what found each:** `Aux.setBTCChannels` targeting `ethVenue` (found by TRACE);
`btcVault: ethVenue` in the swap cfg (TRACE); `backingCoreBody(…, ethVenue)` (GREP — only after the
second trace taught me what to grep for). Reasoning found none of them; `forge test -vvv` and one
grep found all three. A bare `EvmError: Revert` on ~23 suites is ONE broken `setUp`, not 23 bugs —
trace one and the rest usually collapse.

**AND THE COMMENTS WERE RIGHT WHILE THE CODE WAS WRONG:** "Pin the BTCChannels address on BtcVault"
sat directly above a call to `ethVenue`. When one address serves two roles, prose stays true and code
silently drifts.

## Tooling traps — measured 2026-08-15. EVERY ONE FAILED SILENTLY (exit 0, no output, wrong result)

One session lost roughly an hour to these, and **not one was the compiler reporting something true**.
The common shape: a tool that reports success while doing nothing, or a check whose own exit code
lies. ⇒ **VERIFY THE EFFECT WITH AN INDEPENDENT GREP, NEVER THE TOOL'S EXIT CODE.**

- 🔴 **A LIBRARY FUNCTION THAT REVERTS AT ~195 GAS IS A STALE DEPLOYMENT, NOT A BUG IN YOUR CODE**
  (measured 2026-08-16). After renaming `OracleLib.initPool` → `seedRing`, every fixture's `setUp`
  died with a bare `EvmError: Revert` on `OracleLib::seedRing() [delegatecall]` at **195 gas** —
  while `deployMocks` and `prepRefs` succeeded **at the same library address in the same trace**,
  and `out/OracleLib.sol/OracleLib.json` listed `seedRing` in `methodIdentifiers`. So: linking fine,
  artifact fine, deployed dispatcher missing the selector. **`forge test` printed `No files changed,
  compilation skipped` and it was WRONG** — a preceding `forge build` had reported 0 errors.
  ⇒ **`forge test --force` fixed it instantly** (`seedRing` then ran at 66,773 gas and `setUp`
  passed, reaching real assertions 182,000 trace-lines later).
  ⚠️ **THE TELL IS THE GAS NUMBER.** ~195 gas is the dispatcher falling through to its revert
  because no selector matched; a real revert inside the body costs far more. A no-code address
  would *also* trip solc's `extcodesize` guard at a similar cost — same remedy either way.
  ⇒ **After renaming or changing the signature of any `external` library function, run the suite
  with `--force` once before believing ANY result.** This is the EVM twin of "a green suite is what
  an uncompiled crate produces": here the suite is RED, and red for a reason that is not your code,
  which wastes the same time in the opposite direction.

- 🔴 **`Error: Error writing output JSON.` IS A CROSS-FILE ARITY MISMATCH. IT IS NOT ABOUT JSON**
  (measured 2026-08-16; it cost this session hours, twice, and it has now been diagnosed wrongly on
  two separate days). solc emits **no file, no line, no symbol, no cause** — just those two lines.
  The actual defect: `SwapLib.wellSkew` dropped a parameter and `Aux.sol` still called the old
  4-argument form. **Within ONE file the identical mistake reports normally as `Error (6160): Wrong
  argument count`**; only across a file boundary does it degrade into the JSON message.
  ⚠️ **RULED OUT, so do not spend time there again:** disk space (427 GB free), invalid UTF-8 or
  control bytes in the source (verified byte-wise), duplicate contract names, brace balance,
  `deny_warnings`, and stack-too-deep. The previous session's diagnosis — "a duplicate function
  declaration inside an interface" — is the SAME UNDERLYING CLASS (a declaration solc cannot
  reconcile), not a second unrelated cause.
  ⇒ **THE BISECT THAT WORKS, and it is cheap because the failing compile aborts in ~2s:**
  `git stash push <file>` to a known-green HEAD and build to confirm the control; reapply the diff
  ONE hunk group at a time; and when a hunk fails, **rename the changed symbol** — if the error
  turns into ordinary diagnostics, the fault is a caller you have not updated, and the ordinary
  diagnostics will now name it. **Grep every call site across `src/`, `test/` AND `script/` when you
  change any signature** — that is the whole fix, and it is faster than any of the above.
  ⚠️ **AN ANALYSIS ERROR MASKS IT.** While ANY undeclared-identifier error remains, solc never
  reaches codegen and you see normal diagnostics — so "the JSON error went away" after an edit can
  simply mean you introduced an earlier error. It reappears the moment analysis passes.

- 🔴 **`gen_deadman_exit_fixture.py`'s TWO SIGNING MODES TAKE LABELS UNDER DIFFERENT CONVENTIONS, AND
  MIXING THEM UP REPORTS AS A CONTRACT BUG** (measured 2026-08-17). `sign <lp> <hop> …` appends the
  role itself — `channel_keypair(f"{lp}-lp")` — while `signfull <lp> <hop> …` uses what it is given
  **verbatim** (it exists for `open_channel_fixture.json`'s `quid-fixture-{lp,hop}-{seed}-{sats}`
  labels, which already carry the role). So `signedExitFull(_label(93), _label(94), …)` signs under
  the aggregate of two keys that are **not the channel's**, and `_armDeadManExit` rejects it with
  **`ExitSignatureInvalid()`** — a *correct* rejection of a signature over the wrong `Q`, which reads
  exactly like a broken contract or a broken taproot tweak. Pass `string.concat(label, "-lp")` /
  `"-hop"` to `signedExitFull`. ⚠️ The tell is that `ownedChannelKeys(label)` (which calls `keys
  <label> <label>`) DOES append the roles, so the same base label means different keys depending on
  which helper consumes it, and nothing in either signature says so.
- **USE THE `Edit` TOOL FOR EDITS, NOT `python3 - <<EOF` OR `sed`.** `Edit` does exact string
  replacement and **ERRORS IF THE STRING IS NOT FOUND** — which is exactly the verification that
  python `assert`s were hand-rolling and that `sed` cannot do at all. One call, no interpreter spawn,
  no regex engine.
- 🔴 **CATASTROPHIC REGEX BACKTRACKING LOOKS LIKE A HUNG MACHINE.** `(?:    ///[^\n]*\n|    //[^\n]*\n)*`
  followed by `.*?\n    \}\n` under `re.S` ran for **40 MINUTES** on one file. It was blamed on
  machine contention twice. If a python edit "hangs", it is the pattern, not the box. Line-based
  `awk`/`Edit` does the same job instantly.
- **BSD `sed` ON macOS IS NOT GNU `sed`, AND FAILS SILENTLY:** `\(a\|b\)` alternation needs `-E`;
  **`\b` IS A LITERAL BACKSPACE, NOT A WORD BOUNDARY** (use `[[:<:]]`/`[[:>:]]`, or don't use sed).
  Both reported success and changed zero lines.
- 🔴 **IN zsh, `"$var:refs/…"` SILENTLY EATS CHARACTERS — `:r` IS A PARAMETER MODIFIER, AND A GIT
  REFSPEC IS THE PERFECT TRAP FOR IT** (measured 2026-08-16, it broke 9 of 10 backup pushes).
  `git push origin "$r:refs/heads/$r"` does NOT expand to `wt3:refs/heads/wt3`. zsh reads `${r:r}`
  — the *remove-extension* modifier — consumes the `r` of `refs`, and git receives
  `wt3efs/heads/wt3`. Other modifiers (`:h` head, `:t` tail, `:e` extension, `:a` absolute, `:l`/`:u`
  case) are the same hazard, so `:head`, `:tag`, `:extra` are all live minefields after a bare `$var`.
  ⚠️ **THE REASON IT COST AN HOUR IS THE FAILURE SHAPE, NOT THE BUG.** With stderr suppressed the
  loop printed ten clean `FAILED` lines and a `pushed=0 failed=10` tally — which reads as a
  credentials or network problem, i.e. one cause for all ten, so you go looking at the remote. The
  two that "worked" were the ones typed as full literals with no `$var:`. ⇒ **ALWAYS `${var}:` WITH
  BRACES IN A REFSPEC**, and never suppress stderr on a push. Verify with `git ls-remote`, never
  with the loop's own tally — the same "read the effect, not the exit code" rule as everything else
  in this section.
- **`grep -A5 "^Error (" file` EXITS NON-ZERO ON A CLEAN BUILD LOG** — no matches is failure to grep.
  Twice read as "the build was killed". Check the build's OWN exit code, captured separately.
- **`forge build 2>&1 | grep …; echo $(forge build …)` RUNS THE COMPILER TWICE.** Every "one build"
  in that shape is two, at ~8 min each. Capture ONCE to a file, then read the file as many times as
  needed.
- 🔴 **DO NOT `pkill -f "forge build"` — IT ORPHANS `solc`.** Overlapping builds leave two
  `solc-0.8.30 --standard-json` children; killing the parent forge leaves them running and the log
  stops dead at `Compiling N files with Solc`, which reads exactly like an OOM or a crash. **Run ONE
  build at a time and never launch a second while one is in flight.**
- **DO NOT POLL FOR BACKGROUND COMMANDS — THE HARNESS NOTIFIES ON COMPLETION.** `until … sleep 60`
  loops have their own timeout, so when they expire the harness backgrounds *them* too and they
  accumulate: three such waiters were found alive after 15+ hours. Worse, `until ! pgrep -f 'forge
  test'` **MATCHES ITSELF** (its own command line contains the pattern), so it can never exit.
  Wait on a FILE (`until [ -s f ]`) if you must wait at all, never on process state.
- **Build+test in ONE call** (`forge build && forge test`) rather than two turns — it removes a whole
  turnaround per verification.

## Build environment

| | |
|---|---|
| solc | `0.8.30`, optimizer on, **200 runs** (`evm/foundry.toml`) |
| `via_ir` | **`false`, deliberately.** Stack-too-deep is solved by moving locals into struct fields (one memory pointer costs less stack than two values), not by turning on the IR pipeline. |
| remappings | `evm/remappings.txt` only — there is deliberately no `remappings = [...]` in `foundry.toml` |
| **EIP-170** | `forge test` does **not** enforce the 24,576-byte limit. **`forge build --sizes` does not either, for the contracts that matter most** — measured 2026-08-05: `Core` has **no row in that table at all** (278 rows; `SwapLib`, `Aux`, `BasketLib`, `LevManager`, `LevMath`, `QuidLib` all present). The cause is *not* library linking — `SwapLib`, `Aux`, `LevManager` and `Quid` are all linked and all appear — and remains **unknown**. **Use `python3 tools/check-contract-sizes.py` instead**: it reads `deployedBytecode.object` from `evm/out/**` for every contract declared in `evm/src`, which is exact (a link placeholder `__$…$__` is 40 hex chars = the 20 bytes its address occupies). **MEASURED MARGINS — RE-MEASURED 2026-08-15 (35 deployable contracts). RE-RUN THE SCRIPT; DO NOT TRUST ANY NUMBER WRITTEN HERE: `LevMath` 24,503 (73 left) · `Quid` 24,386 (190) · `Core` 24,025 (551) · `BTCChannels` 23,939 (637) · `LevManager` 23,918 (658).** Prior readings: 2026-08-14 LevManager 252 / Core 920 / LevMath 978 / BTCChannels 1,048 / Quid 1,267; 2026-08-12 Core 148 / LevManager 224 / LevMath 228 / Quid 968; 2026-08-05 Core 38 / LevManager 70 / LevMath 20 / Quid 416. **FOUR readings, no two alike** — headroom both returns (deletions: the WETH-4626 venue removal freed ~770 on `Core`, ~750 on `LevMath`) and DISAPPEARS (consolidations). **A stale margin is worse than none: it either blocks an affordable change or waves through an unaffordable one.**
🔴 **THE BINDING CONTRACT IS NOW `Quid` (190), AND IT IS ALONE.** Re-measured 2026-08-16: **`LevMath` 24,068 (508 left)** — it went 73 → 508 when `_toUsdc`/`_fromUsdc`'s per-stable `if` chains collapsed into one `_routeOf` table (§E210), **freeing 435 bytes**. That is the second time a *consolidation* handed back a large block on this contract, and it is the counter-example to the "consolidations cost bytes" reading of the `Quid` entry below: **folding a whole CONTRACT in costs bytes (its code must land somewhere); folding N INLINED BODIES into one routine gives them back.** `LevManager` is no longer tight either — it went 252 → 658 as the Uniswap/venue removals landed. ⚠️ **`Quid` LOST ~1,077 BYTES IN ONE CHANGE** (1,267 → 190): folding `VEth` in deleted a whole deployed contract, but its 4626 identity and ERC-20 mutators are bytecode that had to land somewhere, and it landed here. **Net tree code went DOWN while `Quid` went UP** — that is the axis a "we deleted a contract" summary hides, and it is exactly why the size gate runs BEFORE the suite. Do not plan an addition to `Quid` against any older figure. This repo has already shipped a `Core` at −126 bytes (undeployable) with a fully green suite; a ~52-byte addition to `Core` on 2026-08-05 consumed more than half the remaining margin before anyone measured it. |
| library bodies | Delegatecalled library functions must be `external`/`public`. That is why the external surface is large; it is not accidental API. |
| fork tests | ⚠️ **`FOUNDRY_RPC_ENDPOINTS_MAINNET` DOES NOT WORK — it is silently ignored.** `foundry.toml` resolves `mainnet = "${ETH_RPC_URL}"`, so the override is **`ETH_RPC_URL=<url> FORK_BLOCK=<n> forge test`**. Measured 2026-08-10: two full suites reported 3,318 and 1,623 failures, **all 403/429, zero assertions**, because the ignored variable left forge on the non-archival public node while `FORK_BLOCK` was pinned. **A PINNED BLOCK REQUIRES THE ARCHIVE ENDPOINT** (`ETH_RPC_URL=$ANKR_RPC_URL`); publicnode is keyless but head-only. Public nodes are not archival; a stale `FORK_BLOCK` fails to fetch rather than failing a test. ⚠️ **A DEAD RPC KEY LOOKS LIKE A BROKEN TEST SUITE.** On 2026-08-06 the ankr key in `evm/.env` returned `HTTP 401 "API key disabled"`, which fails inside `setUp()` — so **every fork test in the repo reported FAIL** with no assertion involved. Read the failure text before believing a mass regression: `could not instantiate forked environment` is an endpoint problem, not a code one. **Verified live and keyless 2026-08-06** (block 25,697,138): `ethereum-rpc.publicnode.com`, `rpc.flashbots.net`, `eth.drpc.org`. Dead: `eth.llamarpc.com` (521), `cloudflare-eth.com` (-32046). `foundry.toml:44` already names publicnode as the keyless fallback; `evm/.env` now points there. This is also the likeliest thing CI was mailing about. ⚠️ **BUT THE KEYLESS NODE RATE-LIMITS UNDER A FULL-SUITE RUN.** Measured 2026-08-08: three tests failed with `HTTP 429 "Rate limit exceeded"` from publicnode — `test_ClassifyAllVenues`, `test_RunSim_IL_Baseline_ChopIsBenign`, `testGrindRemoval_DrainPaysRetainedSkewPremium`. **That is an ENDPOINT failure wearing a test's name, same category as the 401 above**, and it moves between runs, so treat any `Max retries exceeded HTTP error 429` line as environmental before attributing it to code. ▶️ **A replacement archive key is banked as `ANKR_RPC_URL` in `evm/.env` (gitignored; NEVER put it in `foundry.toml`, which is committed).** Verified live 2026-08-08 — `eth_blockNumber` → `0x1885000`, and `eth_getBalance` at block `0xF4240` returns a real value rather than a missing-trie-node error, so it **is** archive-capable. **It is deliberately NOT wired into `ETH_RPC_URL`:** publicnode stays primary, and this is for archive needs or when 429s appear — `FOUNDRY_RPC_ENDPOINTS_MAINNET=$ANKR_RPC_URL forge test` uses it for one run with no file edit. |
| Rust (`quid-ln`) | **Does not build on macOS at all** — `quid-cvm` is Linux-only and transitive. Use the image: `docker build -t quid-ln:dev quid-ln` then `docker run --rm -v "$PWD/quid-ln":/w -w /w quid-ln:dev`. **VERIFIED GREEN: 624 passed / 0 failed (2026-08-07).** Was recorded as 532; the count grew AND the tree was red in between — two `quid-tls` shared-seed snapshot tests encoded pre-`QUID-REALM` values (see `quid-tls/src/shared_seed/certs.rs`). A recorded pass count goes stale silently; re-run before trusting it. `quid-ln/Dockerfile` is the single source for the commands — it pins rust 1.90 to `rust-toolchain.toml` and bakes Bitcoin Core **30.2, the same version `regtest/env.sh` uses** (a split would mean Docker and host harnesses disagreeing on consensus). |
| Docker VM memory | `docker info` MemTotal is a **VM allocation, not host free RAM** — closing apps does nothing. Default is ~2 GB; **raised to ~5 GB 2026-08-02, and measured at ~13.6 GB on 2026-08-08** (`docker info` MemTotal 13,618,397,184 — re-read it rather than trusting this line, which was already stale once). Change at Docker Desktop → Settings → Resources → Memory. **Not scriptable:** `~/Library/Group Containers/group.com.docker/settings.json` is TCC-protected, so a shell gets `Operation not permitted` even as its owner without Full Disk Access. ⚠️ **Under-memory `rustc` is OOM-killed with NO diagnostic** — just `process didn't exit successfully`, no error code or span. That reads exactly like a compile error and is not one. Escape hatch: `-e CARGO_BUILD_JOBS=1 -e RUSTFLAGS="-C debuginfo=0"`. |

## Before writing ANY primitive: four libraries are already linked

⛔ **DO NOT ROLL YOUR OWN** (owner, 2026-08-21: *"do not roll your own code from scratch, copy over
audited files"*). `evm/remappings.txt` already links **solady**, **@solarity/solidity-lib**,
**OpenZeppelin** and **morpho-blue**. Grep those before reaching for anything.
- **Merkle proofs / trees → `@solarity/solidity-lib`**, already used by `ChannelLib`, `ExitLib`,
  `MuSig2Agg`, `SPVGateway`, `ISPVGateway`. It has `libs/bitcoin/TxMerkleProof.sol` (`processProof`),
  `access/AMerkleWhitelisted.sol`, and Cartesian / Incremental / Sparse Merkle trees.
  ⚠️ I was one command from copying Midnight's `HashLib` in beside it — **a second Merkle
  implementation next to one we already depend on**, which is the duplication this whole refactor
  exists to delete. Check what the tree ALREADY links before proposing an import.
- **Fixed-point → solady's `FixedPointMathLib`** (`SoladyMath.fullMulDiv` throughout).
- **Morpho Blue → `lib/morpho-blue`**, vendored as tracked files. `LevVenueBase` imports its
  `IMorphoStaticTyping`/`MarketParams`/`MarketParamsLib` rather than restating them; 15 hand-rolled
  Morpho declarations were collapsed to 2, and those 2 are Morpho **Vaults V2**, a different protocol.
⚠️ **TAKE THE PIECES, NOT THE REPO.** Vendoring Midnight wholesale forced a hand-rewrite of
`UtilsLib.msb` because its `clz` is an **Osaka** opcode and we pin solc 0.8.30 / cancun. The offer path
never touches `UtilsLib` — taking less would have meant hand-rolling nothing.

## ⛔ THERE ARE NO TICKS. THE GREP SAYS OTHERWISE AND IT IS WRONG.

`evm/src` has **~185 case-insensitive `tick` matches and EVERY ONE IS A COMMENT.** Zero live tick code.
They are `§DE-TICK` / `§TICK-REMOVAL` markers recording the removal: *"band bounds as PRICES"*,
*"carries the PRICE now, not a sqrt price"*, *"`bandTicks` deleted — it packed a band-edge PRICE LIMIT
for v4's swap"*.
⚠️ **THE HIT COUNT LIES BY VOLUME**: 185 reads as heavy usage, and the density exists *because* the
removal was documented carefully. **Filter comments before concluding anything about tick usage** — the
inverse of "an empty grep proves nothing", and it costs the same wrong conclusion.
⇒ **Band bounds are ABSOLUTE PRICES** (`loPrice`/`upPrice`); the fill settles at the oracle; out-of-range
orders carry absolute `lower`/`upper`. **Midnight's `TickLib` is therefore irrelevant to us** — it
quantises onto a log grid in a (0,1) DISCOUNT domain and we neither quantise nor price in discounts. I
nearly booked "tick normalisation" as unavoidable new work; there is none, because there is no tick on
our side to normalise to.

## Decimal bases — the single most common source of bugs here

Three bases coexist: **6** (USD stables), **8** (sats/WBTC), **18** (ETH/QU!D/internal USD).

The WBTC price carries a **×1e10 lift** (`usd·1e28`), which closes the 8↔18 gap — so a flat `/1e30`
or `1e18` scale is correct for **both** assets, and adding a second `×1e10` somewhere "to fix BTC"
double-counts it.

**Never infer a stable's decimals from its slot index.** A positional divisor
(`i < 4 || i == 11 ? 1e12 : 1`) shipped once and broke when a 6-dec stable joined at a later slot;
`IERC20(stable).decimals()` is the fix, not the complexity (`src/imports/BasketLib.sol:282`).

## Working facts that lived ONLY in agent memory (folded in 2026-08-21, then the memory deleted)

This section exists for the same reason the file does. 69 memories were scanned against the repo;
**two automated coverage tests both SATURATED** (mean 0.96, median 1.00 against a 3.7 MB corpus — any
keyword hits, so neither could discriminate), so the decision was made on principle instead: the repo
is the source of truth, a memory that DUPLICATES it is redundant, and a memory that does NOT is the
very failure this file was created to end. Four were not in the repo. They are here now.

🔴 **PUSHING TO ANY `quidmints/*` REPO NEEDS THE SSH ALIAS — a plain github.com remote FAILS.**
Use `git@github-quidmints:quidmints/<repo>.git`. A `git@github.com:quidmints/…` remote errors with
*"Permission to quidmints/<repo> denied to tobaccorico"*. `~/.ssh/config` carries a
`Host github-quidmints` block (`HostName github.com`, `IdentityFile ~/.ssh/id_rsa`,
`IdentitiesOnly yes`) — a LOCAL alias only; GitHub sees an ordinary github.com push.

✍️ **PROSE RULES FOR ANYTHING OUTWARD-FACING** (applications, pitches, docs for non-engineers).
No antithesis or corrective negation (*"not X, but Y"*), no paragraph pinning, parataxis, summary
beats, negative parallelism, anaphora, contrasting pairs, rule of three, em dashes, throat-clearing
openers, landing sentences, setup/payoff, or parallel structures inside one paragraph. Vary sentence
length unpredictably. No stacked noun phrases and no filler intensifiers (*genuinely, really,
truly*). Write for non-crypto readers, stay at investor altitude, mine the uploaded context, and
consolidate into ONE document rather than many.

💰 **SIX FACTS ARE LOAD-BEARING IN ANY QU!D PITCH — and all six were silently lost in one compression
pass** (2026-08-01, Alliance application). Audit for them before calling a draft done: (1) **BTC yield
~20% vs Lombard/Babylon's ~2%** — always marked a DESIGN figure, never a measurement, because there is
no live TVL; (2) *"the only insurance against a depeg is holding basket shares"*; (3) the dated
liability curve; (4) the design is determinate; (5) Perena/Panoptic; (6) Thorchain.

🏦 **THE MORTGAGE PRODUCT IS A DISTRIBUTOR MODEL — QU!D does NOT originate or underwrite.** The chain
splits five ways and four need a licence (origination, underwriting, servicing, registering the lien).
The fifth is CAPITAL, which is QU!D's role: a licensed originator finds the borrower, values the
property, sets terms and creates the lien; the reserve funds the loan and holds the paper.
Refinancing is the entry product. **Why it matters: DURATION** — every reserve asset is overnight and
crypto-native while the liabilities are dated. ⚠️ ibiza's *"nobody underwrites"* is
JURISDICTION-SCOPED, not a contradiction of this.

## Cross-repo

- **`../ibiza` consumes SPV as a pinned git submodule** and depends on exactly four Quid/Basket
  signatures staying permissionless and stable. Changing them is a breaking change for a repo that
  isn't in this working tree.
- 📱 **THE LP SIGNER APP SPEC LIVES IN `../ibiza/TODO.md` §3b, NOT HERE** (owner, 2026-08-13:
  *"this shouldn't be in our own queue… it should be in the ibiza TODO.md"*). ibiza owns the mobile
  client (react-native/expo); SPV owns the protocol. **What the phone must do — the seed-derived
  secp256k1 key, the one-time MuSig2 ladder ceremony, TEE-wrapping at rest, the nonce-reuse rule,
  the three deployment targets, social recovery's exact place — is written there, self-contained.**
  ⚠️ **Do not restate it in `QUEUE.md`.** The SPV rows (§E170/§E171-r/§E174/§E187/§E188) now keep
  only the protocol-side facts and point at §3b; two copies of a spec drift, and the one that drifts
  is always the copy in the repo that cannot build the thing.
- `docs/informational/` **contradicts the contracts in ~10 verified places** (the band is ±0.2%, not
  ±2%; the short leg, `baseRate`, CRE, and the swap-in bonus are gone; the stable count moved).
  Never quote it without checking the code.
- `docs/actionable/BUILD-QUEUE-AND-107.md` is an **append-only archive**: its evidence (traces,
  `file:line`, measurements) is authoritative, its **status markers are not**. Current status lives in
  `docs/actionable/QUEUE.md` and is updated in place. Some of its citations point at `/home/rico`
  paths from a different machine and cannot be opened from here.
