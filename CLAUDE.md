# SPV — working rules and environment facts

This file exists because these facts were living **only** in one machine's agent-memory directory.
`docs/actionable/SPRINT.md` tracks *what to build* — it is the ONLY file in `docs/actionable/` as of
2026-08-29; this file tracks *how to work here* and *what the
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

18. **BUILD ONLY THE BEST SOLUTION AVAILABLE — A WORKING FIX IS NOT AUTOMATICALLY THE RIGHT ONE**
    (owner, 2026-08-25). **Before landing anything, ask explicitly: is there a better version of this?**
    Not "does it pass" — *is this the best available*. A patch that works, is verified, and is green
    can still be the WRONG change if a smaller or more structural one exists.
    *Worked example (§BURN-RELEASES-NO-USD):* a burn passed `0` for the USD leg, so `committedUsd18`
    could never fall. I fixed it at the call site, measured two tests green, and was ready to ship —
    **it was the SECOND site-specific patch for the SAME class** (`levBurnAll` was the first). The
    root was one level down: `modLP` overloads `deltaUSD == 0` as a `keep` flag that is INERT on that
    path (it hardcodes `token = address(0)`, and `keep` only gates `token != address(0)`), so passing
    zero LOOKED deliberate. Deriving the leg in `Core` makes every call site unable to forget and
    makes both patches deletable. **The owner asked "is there a better one?" and there was.**
    ⇒ **THE TEST IS RULE 17'S, APPLIED BEFORE LANDING RATHER THAN AFTER: if the fix would still be
    needed after a root fix, it is a clamp.** Two patches for one class is the signal, and the second
    one is where it becomes unmistakable — do not wait for a third.
    ⚠️ **THIS DOES NOT LICENSE GOLD-PLATING OR SCOPE CREEP.** "Best" means the smallest change that
    removes the CAUSE, not the largest change that touches the most code. A root fix that cannot be
    verified is worse than a site fix that can — land the verifiable one, then replace it, and DELETE
    the clamp when the root lands. Leaving both is how a clamp becomes permanent.

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

20. **NEVER DISCHARGE A `SPRINT.md` QUESTION FROM PROSE — GO TO THE CODE** (owner, 2026-09-06:
    *"when sprint md asks a question never mark it off based on a comments reading. always check the
    code."*). A row that asks something is answered by a **grep, a slot read, a selector, a call, or a
    test** — never by a docblock, a commit message, a neighbouring row, or an earlier row's conclusion.
    Cite the file:line of the CODE you read, not of the sentence that told you about it.
    ⭐ **THE REASON IS RULE 19 ARRIVING FROM THE OTHER SIDE.** Rule 19 says a stale is dangerous because
    *"it answers the question"*. This is what that costs when the reader is **you, closing a row**: the
    comment is the very artifact most likely to be stale, because prose is not compiled and nothing
    fails when it rots. **Closing a question on a comment launders a stale into a ✅**, and rule 16 says
    a ✅ is how the next thread decides what not to re-read — so the error is then unreachable.
    ⚠️ **THIS APPLIES TO PROSE THIS TREE'S OWN AUTHORS WROTE, INCLUDING YOURS.** A row you wrote last
    session is prose. A commit message you wrote an hour ago is prose.
    *Worked examples, all found 2026-09-06 in one pass over ONE four-row table:*
    · **§OOR item 1** claimed *"`SwapLib.sol:1212` still `revert IntentSellLegUnbuilt()`"*. **Measured:
      `IntentSellLegUnbuilt` has ZERO occurrences in `evm/src` — not declared, never raised** — and
      `_settleSellIntent` is implemented and called. The leg was BUILT. The row had been true once.
    · **§OOR item 2** said BTC OOR has *"no path at all"*. **Measured: both ends exist** — `Core` is
      deployed twice so `settleOor` is on the BTC range too, and `requestSwapOutOnchain` +
      `refundExpiredSwapOut` are the delivery rail. Only the entrypoint is missing. The row mis-sized
      the job by describing a gap it had not walked.
    · **§OOR item 4** blamed *"`_aggSwap` is still `UNOSWAP_SELECTOR`-only"*. **Measured: it emits
      `UNOSWAP2_SELECTOR` whenever `dex2 != 0`** — the two-hop is built. The conclusion survived; the
      diagnosis was wrong, which is worse than being wrong outright because it sends the fix to the
      wrong file.
    · **§PLP-Y2** concluded *"the band does economic limiting AND rate limiting."* **Measured:
      `_bandFor` is reachable from exactly two sites**, so it gates the keeper paths and NONE of
      `deleverToVault` / `swapOutDeleverPooled` / `deleverBook` / `closeLev` / `closeLevFor`. True of
      the path that was read, generalised to paths that were not.
    📌 **Three of those four were wrong, in one table, all closable-looking from prose.** ⇒ when a row
    cites a **line number rather than a measurement**, treat it as unverified until you have re-read
    that line — line numbers rot fastest of all, because every edit above them moves them.

19. **REMOVE STALES AND SLOPS ALONG THE WAY** (owner, 2026-09-01). A stale is a statement the tree
    no longer supports: a docblock describing a branch that was collapsed away, an interface member
    for a deleted function, a ledger row whose claim has been falsified. **Fix it in the turn you
    walk past it** — the cost is seconds, and the cost of leaving it is that the NEXT reader trusts
    it. Rule 6 is *fix on detect* for defects; this is the same for prose, and prose is what the
    next thread reads first.
    ⭐ **A STALE IS MORE DANGEROUS THAN A GAP, BECAUSE IT ANSWERS THE QUESTION.** A reader who finds
    nothing goes and measures. A reader who finds a confident wrong sentence stops.
    *Worked examples, all found 2026-09-01 in one pass:*
    · `SwapLib.deleverEthOnDelivery` documented a *"0-debt LPs take the `swapOutDeliverUnlevered`
      branch instead"* — the §POOL-VENUE collapse replaced the per-LP walk with ONE pooled call and
      the branch went with it. The docblock is why nobody noticed the entrypoint had no caller.
    · `ICore.collectFees` still declared a function §V4-CUT had DELETED, so `ICore(core).collectFees()`
      compiled and would revert on a missing selector.
    · `LevMath.slipBpsForTest`'s docblock asserted *"`internal` cannot be reached from a test contract
      that does not inherit the library"* — **false**; internal library functions are callable as
      `Lib._fn()` by any importer. The false premise was the whole justification for the accessor.
    · Two ledger rows claimed `evm/slither-out/` was *"the only surviving mention"* of a deleted
      contract. **Measured: 0 mentions there, 1 in `src`.** The artifact was regenerated after the
      row was written, and the row outlived the fact.
    ⚠️ **VERIFY BEFORE DELETING, BOTH WAYS.** Three of the five above were found by measuring a
    claim that sounded right; the slither one was found by measuring a claim that was ALREADY
    labelled stale and turned out to be stale in the opposite direction.

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

### ⭐ THE WORKTREE IS NOW ONE COMMAND, AND THE REASON IT WAS NOT USED IS THAT IT WAS COLD (2026-09-06)

**The section above prescribes a worktree and nobody uses one — `git worktree list` returned ONE entry
today with several agents inside it.** The reason is in its own text: *"~6 min cold compile"*. A
6-minute tax on every isolation means isolation loses to the shared tree every time, so the rule is
correct and unused, which is the same shape as a gate whose only runner is a rule.

▶️ **`tools/lane.sh L3` — creates the worktree WARM. Every number measured, not estimated:**
| step | cost | note |
|---|---|---|
| `git worktree add -b lane/<N>` | **1s** | takes `HEAD`, so another lane's uncommitted edits are excluded BY CONSTRUCTION |
| copy `evm/out` + `evm/cache` | **0s** | 125M, free from page cache on this box |
| `evm/lib` (11 forge submodules) | 🔴 **THE ONE THAT BITES — see below** | a worktree creates the submodule DIRECTORIES and does not populate them |
| first `forge build` in the lane | ⭐ **`No files changed` — ZERO files compiled** | measured twice; against a lane built WITHOUT the copy, which compiled **41 then 183** |

🔴 **`evm/lib` IS THE TRAP, AND I WROTE THE WRONG CAUSE INTO THIS TABLE ONCE ALREADY — the correction
is the useful part.** An earlier revision of this row claimed *"it is a SYMLINK in this repo, so
vendored libs are already shared."* **Measured: `ls -ld evm/lib` on the parent is `drwxr-xr-x`, a
REAL DIRECTORY**, and `.gitmodules` declares 11 submodules under it. The symlink I saw belonged to a
throwaway probe worktree, not to the repo — **I generalised one tree's property to the repo's**, which
is the same shape as the external-probe class below. ⚠️ **A fresh worktree therefore needs
`git submodule update --init --recursive` (slow) or the parent's `evm/lib` copied in**, and until it
does, `forge build` fails with errors that **name files in `evm/` and read exactly like your own
defect.**

⭐ **MEASURE FILES COMPILED, NEVER SECONDS — AND THIS IS THE GENERAL RULE FOR THIS REPO, NOT A NOTE
ABOUT LANES.** I first tried to book a wall-clock speed-up and got **two readings for the SAME lane:
`No files changed` and 2m22s.** Both were true. The lane compiled **zero files both times**; the
2m22s was **pure contention**, because three `forge build`s were running at once — this file's own
rule says *"run ONE build at a time"* and I broke it while measuring the tool meant to reduce builds.
⇒ **Seconds measure the machine's load. `Compiling N files` measures the change.** The second is
contention-immune, is what you actually want to know, and is printed by every build for free.
📌 **It also retires the confound instead of scheduling a re-measure**: there was nothing to re-run,
because the right metric was already in both logs. ⚠️ **Apply this to any future build claim here —
the margin and pass-count rows below are the same discipline on other axes, and all three exist
because a number with a plausible provenance is the hardest kind to catch.**

✅ **ISOLATION VERIFIED BY A LEAK TEST, NOT ASSUMED** — `evm/src` and `evm/out` have different inodes
from the parent's, and `echo >> lane/evm/src/Quid.sol` left the parent's copy at **0** occurrences.
⚠️ **Re-run that leak test if `lane.sh` changes.** A lane that silently aliases the parent is strictly
worse than no lane: it gives the *appearance* of isolation while collisions continue.

### 🛤️ THE RECIPE: N THREADS IN PARALLEL THAT COMMIT WITHOUT OVERWRITING EACH OTHER

**Run this per thread. Nothing else in this file has to be remembered for the commits to be safe.**

```bash
tools/lane.sh L3                 # worktree + BRANCH lane/L3, warm, ~36s total
cd ../spv-L3                     # your own tree; nobody else writes here
<edit only files in your lane's collision domain — §LANES in SPRINT.md>
python3 tools/impacted-tests.py  # 6-31% of the suite, or "NO BUILD NEEDED" for prose
git add <paths by name>          # rule 14: NEVER -A, NEVER commit -a
git commit
```
**Integration, from the MAIN tree, one lane at a time so any conflict has a single author:**
```bash
git merge --no-ff lane/L3
git worktree remove ../spv-L3 && git branch -d lane/L3
```

⭐ **WHY A BRANCH PER LANE AND NOT `--detach`: GIT ENFORCES THE RULE INSTEAD OF YOU REMEMBERING IT.**
Checking the same branch out in two worktrees is refused outright —
`fatal: 'sprint-fold-and-destale' is already used by worktree at '/root/project/spv'` (measured
2026-09-06). ⇒ **two lanes CANNOT share a branch, so they cannot fast-forward over, amend, or clobber
each other's commits.** Per standing rule 17 that beats a rule asking people not to do it: the bad
state is unconstructible rather than merely forbidden.

🔴 **AND THE ONE RULE THE TOOLING CANNOT ENFORCE — BOOK IN `docs/actionable/lanes/L<n>.md`, NEVER IN
`SPRINT.md`. THIS IS MECHANICAL, NOT STYLISTIC, AND IT WAS MEASURED RATHER THAN ARGUED:**
two lanes each appended **one line** to `SPRINT.md`; the first `git merge --no-ff` was **clean** and
the second **CONFLICTED** (`CONFLICT (content): Merge conflict in docs/actionable/SPRINT.md`). Their
`lanes/LA.md` and `lanes/LB.md` merged clean both times, being different files.
⇒ **`SPRINT.md` is a 52,700-line append target that every lane wants**, which is exactly how
`fe9720ac` came to swallow a 228-line `§MASTER-ORDER` restructuring with no mention of it in its
message (§SESS-17 U6). **One merge pass folds the lane books at the end of the day.**

⚠️ **WHAT STILL COLLIDES, so it is not discovered late:** two lanes editing the **same contract** will
conflict at merge like any branch pair — that is what §LANES' collision-domain partition exists to
prevent, and it is why `LevManager` (227 bytes) and `SwapLib` are single-lane by physics rather than
by preference. **Partition first; the branch protocol protects the commits, not the design.**
📌 **The partition itself — which lane owns which files, and why `L4`/`L5` are serial — is
`§LANES-2026-09-06` in `SPRINT.md`.** This file is how to run a lane; that one is what goes in it.

### ⭐ AND THE METHOD LESSON, BECAUSE IT COST NOTHING ONLY BECAUSE THE RULE WAS OBEYED

**`lane.sh` shipped BROKEN and its own acceptance test caught it in one run.** The script created the
lane, printed a confident success banner, and produced a tree whose `forge build` failed with **11
solc errors naming files in `evm/`** — indistinguishable from a real defect in this repo's own code.
⇒ **The rule below — *"a gate you just wrote is unverified code on the same footing as anything else;
the acceptance test for a detector is the KNOWN POSITIVE, not a clean run"* — is what turned a
would-be multi-hour false trail into one command.**
🔑 **AND THE CONTROL IS WHAT NAMED THE CAUSE, not the error text.** The errors said *"Function has
override specified but does not override anything"*, which points at Solidity. Building the PARENT at
the same commit gave **0 errors**, and `openzeppelin-contracts` held **69 files in the lane against 86
in the parent** — so the fault was the environment, not the source. **Ask "would this look the same
if I were wrong?" before reading any compiler error as a code defect in a tree you just created.**
📌 **The `grep -c "^Error" <log>` exit-1 trap fired twice in the same session** and is already booked
below: on a CLEAN log it exits non-zero, so the harness reports the whole command as failed while the
build was green. **Read the captured count, never the pipeline's exit code.**

### ⭐ AND STOP RUNNING THE WHOLE SUITE — `tools/impacted-tests.py` ROUTES A CHANGE TO ITS OWN TESTS

A full `forge test` is ~250s and **70 of 155 `.t.sol` files reference no money-path contract at all**,
so most of that run cannot falsify most changes. The tool maps changed `evm/src` files → declared
symbols → +1 level of reverse-import → the suites that name them.

**Measured, and the acceptance test is the KNOWN POSITIVE per the rule below:**
- `LevManager.sol` → **10 / 155 suites (6%)**, and it selects `LevCascade.t.sol` and `LevYbReal.t.sol`
  — **the exact two test files the lane changing `LevManager` had edited.**
- `SwapLib.sol` → **49 / 156 (31%)** — correctly wider, because 8 contracts import it.
- `docs/actionable/SPRINT.md` → **NO BUILD NEEDED.** A prose lane never compiles at all.

⚠️ **IT IS A ROUTER, NOT A GATE, AND ITS FALSE-NEGATIVE CLASS IS NAMED IN THE FILE:** it matches by
SYMBOL, so it cannot see a test that reaches a contract through an address, a raw slot or a deploy
script. `UnificationControls.t.sol` (raw slot reads) and `Alles.t.sol` (deploy script) are therefore
in a hardcoded `ALWAYS` set, each with its reason. **The full suite still runs once before merge** —
a green targeted run says nothing about the suites it did not execute.

## Verification discipline

- 🔴🔴 **A NEGATIVE RESULT FROM AN EXTERNAL PROBE IS A PROPERTY OF YOUR QUERY, NOT OF THE WORLD.
  EVERY WRONG CONCLUSION IN THE 2026-08-29/09-01 SESSION WAS THIS ONE CLASS, FIVE TIMES, AND NOT
  ONE WAS CAUGHT BY ITS AUTHOR.** Everything else in this section is about greps INSIDE the repo;
  this is the gap that left. The shape is always the same: **run one query against an outside
  system, get an answer, and promote that answer's limits to the world's limits.**
  | what I concluded | from | what was true |
  |---|---|---|
  | 1inch only does `unoswap` | the one selector a quote returned | **six** selectors (`unoswap2/3`, `swap`, `ethUnoswap`, `unoswapTo`) |
  | GHO is Fluid-only | Kyber naming Fluid as *cheapest* | read *cheapest* as *only*; the GHO/crvUSD Curve pool holds 915,915 GHO |
  | Curve has ~2 usable pools | a two-entry hardcoded table | `find_pools_for_coins` (**PLURAL**) returns an array; the SINGULAR one returns dead pools |
  | every route must pivot through USDC | the routes a USDC-denominated query returned | the query fixed the pivot, not the venue |
  | source selection does not exist | the absence of a name I invented | it had never been built — a real gap, but concluded for the wrong reason |
  ⇒ **BEFORE CONCLUDING "X DOES NOT SUPPORT Y", ENUMERATE X'S INTERFACE — do not infer it from one
  call's output.** The selector list, the registry's full method set, the ABI, the docs index. Each
  of the five above was ~one minute of enumeration away, and each cost a wrong design decision.
  ⚠️ **AND THE PLURAL/SINGULAR TRAP GENERALISES:** when an external registry offers both
  `find_pool_for_*` and `find_pools_for_*`, the singular is almost always the legacy one. Check for
  a plural sibling before believing a thin result.

- ⚠️ **A GATE YOU JUST WROTE IS UNVERIFIED CODE ON THE SAME FOOTING AS ANYTHING ELSE — RUN IT
  AGAINST THE DEFECT IT WAS BUILT FOR AND CONFIRM IT SAYS SO.** `tools/check-orphans.py` reported
  **0 orphans on a tree that had three**, because `function borrowRateRay(` matches a call pattern —
  so **every declaration counted as its own caller**, and the interface declaration plus the
  implementation gave every member two. A gate that cannot fail is worse than no gate: it certifies.
  ⇒ **The acceptance test for a detector is the KNOWN POSITIVE, not a clean run.**
  ⚠️ **AND THE SAME HOUR, THE SAME ERROR ONE LEVEL DOWN — A CUSTOM ERROR IS NOT ONLY RAISED BY
  `revert`.** An ad-hoc scan for "error declarations nothing raises" matched `revert X(` and
  `X.selector` and reported **12 dead**. Eleven were. The twelfth,
  `SPVGateway.UnalignedCheckpointHeight`, is raised by **`require(cond, CustomError())`** — the
  Solidity ≥0.8.26 form — and deleting it broke the build.
  ⇒ **GREP FOR THE BARE CALL `\bName\s*\(` WITH DECLARATIONS SUBTRACTED, NEVER FOR `revert Name`.**
  Enumerating the ways a thing can be *used* is the same discipline as enumerating an external
  interface, arriving from the other side: both failures are one query mistaken for the whole space.
  ✅ The build caught it in one cycle, which is the argument for running the build BEFORE the
  cleanup commit rather than after a batch of them.

- 🔴 **BEFORE ADDING AN ACCESSOR OR HELPER, GREP FOR THE BODY YOU ARE ABOUT TO WRAP — NOT FOR THE
  NAME YOU ARE ABOUT TO CREATE.** A name-grep cannot find a duplicate that already exists under a
  different spelling, and it returns clean **precisely because** you are inventing the name. Grep the
  CALLEE instead: the library function, the state variable, the expression. **Measured 2026-08-26:**
  `Quid.kLvrWad()` had existed since the θ work; I added `Quid.lvrKWad()` — the same one-line body
  `QuidLib.kLvrWad(address(CORE), _lo(), _hi())` under transposed letters — plus a matching `ICore`
  declaration, and `grep lvrKWad` was empty every time I ran it. **One `grep -rn "QuidLib.kLvrWad"`
  would have shown the wrapper on line 1072.** Only the BTC half was ever missing.
  ⇒ **THE OWNER'S FRAMING IS THE TEST: "perhaps only semantically different but not functionally."**
  Two names for one body is worse than either name alone, because a reader who finds one concludes
  the other does not exist — and on a range pair it silently invites ETH and BTC to diverge.
  ⚠️ Same shape as the tombstone/fold traps below: **the grep that returns nothing is the dangerous
  one**, and this is the third distinct way this repo has produced that outcome.

- 🔴 **A SWEEP IS NOT A FINDING UNTIL ITS FALSE-POSITIVE CLASS IS NAMED. THREE SWEEPS IN ONE DAY
  (2026-08-23) EACH COLLAPSED THE MOMENT I LOOKED.** Raw counts were 47 assertion-free tests, 334
  duplicate-expression locals, and 3 foldable libraries. **Real counts: ~20 (and mostly deliberate),
  4, and 0.** The refinements that did it, each cheap and each found only by opening a file:
  *assertions live in helpers, sometimes TWO levels deep* · *`before`/`after` pairs read the same
  expression at different TIMES and that is correct* · *identical args to a NON-VIEW function are not
  identical results* · *"did not revert" is a legitimate assertion for a test named `_Accepts_`*.
  ⇒ **Report the refined number with the discarded class named, or the signal is ignored.** A row
  saying "334 findings" is read as noise and closed; one saying "4, and here is why the other 330 are
  correct" gets acted on.
- 🔴 **`import` TELLS YOU WHAT A FILE MENTIONS. ONLY A CALL-SITE GREP TELLS YOU WHAT IT USES.** Same
  day, three wrong conclusions from the same error: three TOMBSTONES were assigned to a work lane
  (items *mention* a deleted file because an obituary names its subject repeatedly); `Core` looked
  like the fix site for 10 items and was the fix site for **0** (it is where the σ² ARGUMENT happens —
  cited constantly, edited rarely); and `FeeLib`/`OracleLib` looked foldable at 1 importer each and
  have **5** and **2** real consumers. ⇒ **Before assigning work by file, `find` the file and grep its
  CALLS.**
- ⚠️ **A ONE-SIDED BOUND IS A RUBBER STAMP WHEN THE DEFECT DRIVES THE VALUE TOWARD THE ASSERTED SIDE**
  (§VACUOUS-BOUNDS). `assertLt(x, CEIL)` cannot fail if the bug makes `x` zero; `assertGt(x, 0)` cannot
  fail if the bug makes it huge. **The test's NAME is the tell — it claims what the assertion does not
  check.** `test_FlushRangeStillOwesOnlyTheBase` asserts only `assertLt(flush, 3e16)` while `flush` is
  **0**: it says *StillOwes* and never asserts the base is OWED. §E279's `assertGt(premium, 0)` was the
  same shape and hid a double-charge. ⛔ **AND THE INVERSE IS NOT A DEFECT:** a PREMISE guard asserting
  a curve is drained is correctly satisfied by 0, because there 0 IS the asserted condition. **The
  discriminator is whether the extreme value MEANS the thing the message says.**
- ⭐ **THE RATIO IS THE TELL: A MAGNITUDE MISS AND A WRONG-OPERAND MISS HAVE DIFFERENT SIGNATURES.**
  Six failures in one suite looked like one cluster; five were within a few percent of expectation and
  one was off by **~8×**. That one alone was a wrong-instance read (`ethPooled18` and `btcPooled18`
  assigned the IDENTICAL expression — §WRONG-RANGE, the class with a documented 246-failure body
  count). **Predicting the shape from the ratio, then confirming, beat grouping by symptom.**
  ⇒ **A CLUSTER IS A HYPOTHESIS, NOT A FINDING.** Six reds in one file were carried in the census as
  six defects; two turned out to be one non-defect and the rest shared only a filename.
- ⚠️ **BOOK THE MECHANISM, NOT THE CONFESSION.** A row headed *"LAZY `openChannel` — never started, and
  my ✅ was conditional"* survived months because its headline is about its AUTHOR'S PROCESS, so a
  sweep hunting testable claims slides past it — while its falsifiable half was one
  `grep -c "LAZY-OPEN"` away, returning **8**. **A status confession is not a status.**


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
  surfaced that in seconds, both times.
  ✅ **STATUS UPDATE 2026-08-28 — THAT GAP IS NOW CLOSED, SO THIS EXAMPLE IS HISTORICAL.** §W1 built
  the authorized trigger: `quid-bridge/src/sweep.rs` (`BuildSweep` / `execute_sweep`) and
  `quid-bridge-daemon.rs:264` (`QUID_SWEEP_AUTH` — operator-signed bundle, verify → network-check →
  consume the nonce ON-CHAIN → build → broadcast → exit). `create_sweep_tx` has REAL CALLERS now and
  should carry **no `dead_code` warning at all**. ⇒ If that warning ever returns, it is a REGRESSION
  (the trigger was unwired), not a marker — the opposite reading from the one above. **The rule
  stands; only its example has resolved.** **Rule 1 deletes UNREACHABLE code; it does not delete a
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
- 🔴 **AFTER ANY SOLIDITY CHANGE, RUN `tools/check-orphans.py` — AND LET ITS RESULT GATE THE COMMIT.**
  It fails when a member of one of OUR interfaces has no caller in `evm/src`: the *built-but-unwired*
  shape, where a feature's cheap measurement layer lands, its tests go green, and the expensive layer
  that would consume it never does. `forge build` and `forge test` are both blind to it — the name is
  present, the CALLER is missing.
  ⚠️ **THIS IS NOT WIRED TO CI, BECAUSE THERE IS NO CI: `9553d8e3` (2026-09-01) DELETED
  `.github/workflows/` — *"we do not use CI here"*.** A step added to `ci.yml` earlier the same day
  went with it. ⇒ **Every gate in this repo runs because this file tells you to run it.** Do not
  re-add a workflow file; add the command here instead.
  ⭐ **AND NOTE WHAT THIS CONCEDES ABOUT THE RULE ABOVE.** "Build a gate, not a rule" was the lesson
  of 2026-09-01 — and the gate's only runner is a rule. The distinction that survives is narrower and
  still real: a rule asking for a DISPOSITION ("notice when you leave something unwired") has now
  failed twice; a rule asking you to RUN ONE COMMAND with a binary result is a different instrument.
  Prefer the second whenever the question can be made mechanical.
  ⛔ Its allowlist `tools/orphans-allow.txt` REQUIRES a reason per entry. A CLASS 3 entry is a KNOWN
  DEFECT held open, not an exemption — removing one must mean fixing it, never silencing it.
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
  🔴 **UNRECONCILED, BOOKED 2026-08-23, AND DELIBERATELY NOT "FIXED" BY REPLACING ONE NUMBER WITH THE
  OTHER.** Today's control run at `9896c5be` is **432 passed / 55 failed / 2 skipped — 489 TOTAL tests
  across 83 suites.** Against `4,402 passed` that is an **order-of-magnitude** discrepancy in a state
  line, and **nobody has established which figure is wrong.** Three candidates, none yet tested:
  (a) the suite really did shrink by ~9× (2,000+ commits, several whole contracts folded away — but
  nothing in the log claims a deletion on that scale); (b) the two runs counted different things —
  `4,428` vs `3,107` in the very sentence above proves the counter is unstable, and a fuzz/invariant
  campaign counts as ONE test while its runs number in the thousands; (c) a mass `setUp` revert is
  silently dropping most suites today, which is the failure mode this trap-note exists to describe and
  would make **489 a floor, not a total** — SPRINT already records `509 tests against a historical
  ~4,316` for exactly this reason. ⚠️ **DO NOT QUOTE EITHER NUMBER AS THE BASELINE UNTIL ONE RUN
  RESOLVES IT.** ▶️ **ONE DISCRIMINATOR ALREADY RUN, AND IT KILLS (c): `evm/test` holds **80** `.t.sol`
  files against the run's **83 suites**, so essentially every test file produced a suite — the suites
  are NOT missing.** That leaves (a) and (b), and **(b) is the one to test first: 489 tests across 80
  files is ~6 per file, a plausible unit-test census; 4,402 across a comparable tree would be ~55 per
  file, which is not.** Check whether the 4,402 run counted fuzz/invariant RUNS rather than cases.
  ⚠️ **(a) is not absurd either, merely unmeasured — `Vault` lost its whole ETH-venue slice since, and
  `VEth`/`SOR`/`ExitLib`/`MuSig2Agg`/`ExternalTwap`/`FixedRateFill` are all gone as files.**
  ⇒ **A pass count is the single most-quoted state line in this file and the one with the least
  defensible provenance.**
  ⭐ **MEASURED 2026-08-25, AND IT IS DIRECT EVIDENCE FOR CANDIDATE (c): THE SAME TREE, THE SAME
  COMMIT, TWO ENDPOINTS, AND THE TOTAL MOVED 517 → 341 — A 34% SWING FROM THE RPC ALONE.**
  `eth.drpc.org` produced **32 `setUp()` failures**, every one a *"database error … connection
  reset"*, and ~176 tests simply never ran. The run still took **274s** and reported 40 failures, so
  it carried NONE of the tells: not the 7.58s dead-key signature, not a 429, and all **83 suites
  present**. A contaminated census looks exactly like a healthy one.
  ▶️ **THE ONE-LINE GUARD, RUN IT BEFORE QUOTING ANY TOTAL:**
  `grep -cE '\[FAIL.*\] setUp' <gate.log>` — **non-zero means the total is a FLOOR, not a total**,
  and the failure count is inflated by that many. Also `grep -cE 'HTTP error|database error|Rate
  limit|instantiate forked'`.
  ⚠️ **AND IT REVERSES A CONCLUSION IN THIS FILE:** the discriminator above says *"83 suites against
  80 `.t.sol` files, so the suites are NOT missing"* and uses that to kill (c). **Suite COUNT does not
  test (c) — a suite whose `setUp` reverts still REPORTS.** Compare TEST totals across two endpoints
  on one commit; that is what separated them here.
  ⇒ **`ethereum-rpc.publicnode.com` was the stable one for full-suite runs on this date; `eth.drpc.org`
  is fine for short targeted runs (~20s) and resets under sustained load.**
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
  They exist on **BOTH instances** — the BTC range is `new Core(cfg.wbtc, …)` (`DeployLib.sol:137`), so **the
  BTC accumulator is `feesPerShare` READ AT THE BTC ADDRESS.** The v4 cut ended the trading-fee SOURCE that
  fed it, not the accumulator. ⚠️ **AND THE RENAME CREATED A NEW WAY TO GET THE UNITS WRONG: the warning says
  multiply by the credit site's OWN share base, and "own" now means THAT INSTANCE'S — which the name used to
  tell you and no longer does. Reading the ETH instance's base against the BTC instance's accumulator is the
  successor to the exact bug this warning was written for.**
  **Live credit sites: `Vault.sol:351`, `Quid.sol:1180`, `Quid.sol:1276`** (`USD_FEES += usdInc`).
  ⇒ The hazard this note exists to prevent is unchanged and still real; only its coordinates rotted.
  **A trap-note that points at deleted symbols causes the exact misreading it was written to stop**,
  because the reader concludes the concern is obsolete rather than that the names moved.
- **THE STATUS-MARKER COLUMN OF THE ROWS FOLDED INTO `SPRINT.md` `§FROM-QUEUE` IS UNRELIABLE — PLAN FROM ROW BODIES.**
  `UNIT-A` still read 🔴🔴🔴 after it landed. Re-reading two rows overturned the plan twice running.
- ⚠️ **`Core` CANNOT AFFORD A GETTER — 🔴 THIS IS NOW FALSE ON ITS FACE AND IS KEPT ONLY FOR THE HALF THAT SURVIVED.** Measured 2026-08-05: a two-address getter costs **91 bytes**, a
  `(bool,bool)→address` one **98** — more than the 76 freed by deleting dead state. **`Core` has had ~13 KB free since §V4-CUT (§E344; 13,911 at `9896c5be`, **13,272 at `7e32eb48`** after §E345's +639), so the byte argument no longer bites; the STATE-ORDER coupling below is what still does, and it was never about bytecode.** The dust monitor
  reads mock addresses from RAW SLOTS (`UnificationControls.t.sol`) for exactly this reason, which
  couples the HARNESS (not the contract) to `Core`'s state ORDER: reorder it and tests fail with
  `unrecognized function selector 0x70a08231` four frames deep. A stale-slot guard now names it.

## Code navigation — read this before answering a "how does X work" question

⭐ **REBUILT 2026-08-29 at `16726eb2`, AND IT NOW CONTAINS SOLIDITY.** The graph lives at
**`SPV/graphify-out/graph.json`** — repo root, covering the whole tree. **26,655 nodes · 47,725 links ·
1,790 communities · `directed=true` · 0 dangling endpoints.** By language: **`.sol` 13,876 · `.rs` 4,406 ·
`.md` 3,877 · `.ts` 865 · `.js` 412 · `.py` 252 · `.go` 203**. By tree: `evm/` 14,394 · `quid-ln/` 4,127 ·
`docs/` 3,243 · `app/` 978 · `svm/` 462.

🔴 **THE OLD GRAPH AT `quid-ln/graphify-out/` IS DEAD. DELETE IT FROM YOUR MENTAL MODEL.** It was Rust-only,
63% vendored LDK, built at `892c5b78`, and it is now excluded from indexing by `.graphifyignore`. Every
statement in this section's previous revision — "contains ZERO Solidity", "never use it for Solidity",
"scope any query to `quid-hop/`" — described *that* file and is now false. Solidity is the **majority** of
this graph.

▶️ **USE `tools/graph.sh`, NOT `graphify` DIRECTLY — and the reason is two MECHANISMS, not a
disposition.** On 2026-09-06 a whole session grepped without asking the graph once, including while
hand-rolling a blast-radius scan `graphify affected` already does (rule 8, violated against an
instruction sitting in this file). *"Agents don't use it"* is a **status confession, and this file
says to book the mechanism instead** — so here are the two, each removed by the wrapper:

| mechanism | what it actually costs | removed by |
|---|---|---|
| **`graphify` is not on `PATH`** — it lives in a venv at an unmemorable path | the obvious `graphify explain Foo` returns **command not found**, the agent falls back to grep, **the grep works**, and it never comes back. The failed command is not the cost; the successful fallback is | `graph.sh` resolves the binary (`GRAPHIFY_BIN` to override) |
| 🔴 **the graph is STALE BY DEFAULT** — `built_at_commit 7c5bc10d` against `HEAD 5609531f` when measured | an agent who **does** follow the instruction gets a confident answer about a tree that no longer exists. Per rule 19 that is worse than no graph, and it teaches the wrong lesson about trusting the tool | `graph.sh` prints a loud staleness banner before every traversal; `GRAPH_STRICT=1` makes it an error; `--rebuild` fixes it and **verifies by reading `built_at_commit` back**, per trap 4 |

⇒ **That is the "prefer a command with a binary result over a disposition" rule below, applied to the
graph.** The disposition has now failed for weeks; the banner cannot be missed.
✅ **THE TWO AGREE, WHICH IS THE USEFUL PART — treat it as a mutual control rather than a duplication.**
`graphify affected "LevManager"` (depth 2) returns `LevCascade.t.sol`, `LevYbReal.t.sol` and
`LeverageCrossSubsidyProbe.t.sol` with `file:line` and edge type; the regex tool independently selects
all three. **Two methods, one answer, so neither is quietly wrong.**
⚠️ **AND THE REASON `impacted-tests.py` STILL DOES NOT DEPEND ON THE GRAPH — do not "fix" it:**
🔴 **the graph is STALE by default.** Measured 2026-09-06: `built_at_commit` = **`7c5bc10d`** against a
`HEAD` of **`f3ac46bb`** — dozens of commits behind, including every change made that day. A test
router must read the LIVE tree or it will route around the very file you just edited. ⇒ **the graph is
for UNDERSTANDING structure; the regex is for ROUTING a change that exists right now.** Different
freshness requirements, so both earn their place.
📌 **Trap 4 below is what catches this, and it costs one command** — read `built_at_commit` back out of
`graph.json` and compare with `git rev-parse --short HEAD` **before** believing any traversal, exactly
as it says. **A stale graph answers the question, which per rule 19 is worse than having no graph.**

**Ask the graph before you grep.** These four answer most structural questions in one call, and none of
them needs an LLM or an API key:

```
graphify explain  "Basket"            # node + every neighbour, with file:line and edge direction
graphify affected "OracleLib"         # reverse traversal — blast radius of a change
graphify path     "Quid" "Vault"      # how two things connect (add --undirected if it finds nothing)
graphify query    "who mints vUSD"    # BFS over the graph for a question, --budget N to cap tokens
```

`graphify` is **not on `PATH`** — it is `~/.local/share/graphify-venv/bin/graphify`, a source checkout at
`~/.local/share/graphify-src`, not a plain pip install. Run it from the repo root; `graph.json` is found
relative to cwd.

### The five traps, each of which produces a confident wrong answer

⚠️ **1. Communities are unlabeled — `Community 0`, `Community 1`, … 1,790 of them.** Naming them needs an
LLM backend (no API key is set; the `claude-cli` backend would spend Claude quota). So the "Community
Hubs (Navigation)" section of `GRAPH_REPORT.md` is **1,742 lines of placeholder and worth nothing**.
Navigate by `explain`/`affected` from a known symbol, never by community. To fix it once:
`graphify label . --backend=claude-cli`.

⛔ **2. Inheritance from vendored bases is ABSENT, and its absence looks like a finding.** `.graphifyignore`
excludes `evm/lib/`, so **333 of the 481 `is` clauses survive and the 148 that vanish are exactly the
vendored ones** — `ERC20`, `Ownable`, `Script`, `Test`, `OApp`. The build drops an edge whose target is
not a node, silently. **"No `inherits` edge" therefore means "inherits nothing *of ours*", never "inherits
nothing."** For the vendored half, `evm/slither-out/` (inheritance-graph printer) is still the source of
truth.

⚠️ **3. Solidity support is a LOCAL PATCH that an upgrade silently reverts.** graphify 0.9.51 has no
Solidity grammar; `tools/graphify-solidity/` supplies one. `pip install -U graphifyy` overwrites it, and a
graph rebuilt without it is **not visibly broken — it just has no Solidity in it.** Before trusting a
rebuild: `python3 tools/graphify-solidity/apply.py --check` (exit 1 = not patched). See that directory's
README for what is and isn't extracted — `using X for Y` and calls inside `assembly {}` are not.

⛔ **4. A rebuild can report success and change nothing.** The previously-recorded trap (`to_json` printed
the new node count, returned truthy, updated mtime, and left a 3-week-old graph in place) still stands.
**Verify a rebuild by reading `built_at_commit` back out of `graph.json`, never by the run's own output:**

```
python3 -c "import json;print(json.load(open('graphify-out/graph.json'))['built_at_commit'][:8])"
git rev-parse --short HEAD    # must match
```

⚠️ **5. Edge counts are not call counts, and `.sol` node counts are not contract counts.** `method` and
`contains` (23,240 of 47,725 links) are containment, not behaviour. A Solidity method node is labelled
`.name()` with a leading dot — that is graphify's convention for a member, not a typo.

⛔ **6. Names now collide ACROSS languages, and `path` resolves the collision silently.** One graph holds
`evm/`, `svm/` and `quid-ln/`, so `Quid` matches both `evm/src/Quid.sol` and `svm/programs/quid/Cargo.toml`.
`explain` refuses and lists the candidates — good. **`path` does not: it picks the higher-scoring node and
prints only `warning: target match was ambiguous`,** which is easy to read past, and then reports a path
between the wrong pair of things (or "no directed path found" for two nodes that are in fact adjacent).
**Pass the repo-relative path or the full node id** (`evm_src_quid_quid`) for any name that could exist in
two trees — which here is most of the money-path names.

### Rebuilding

```
graphify update . --force          # re-extract; --force is required or a smaller rebuild is refused
graphify cluster-only . --no-label --no-viz
```

`--no-viz` is not optional here: `graph.html` is skipped above ~5,000 nodes and this graph has 26,655.
**`update` inherits the `directed` flag from the existing `graph.json`** (upstream #2342) — building into
an empty directory silently produces an **undirected** graph, which cannot distinguish "what calls X" from
"what X calls". If you ever rebuild from scratch, set `"directed": true` in a seed `graph.json` first and
confirm it afterwards.

Scope is governed by **`.graphifyignore`** at the repo root (forge submodules under `evm/lib/`, vendored
`quid-ln/lib/`, `evm/slither-out/`, Noir verification-key artefacts). graphify already skips
`node_modules/`, `target/`, `out/` and `.gitignore`d paths on its own.

**Noir is still invisible.** The 128 `.nr` circuits under `evm/noir/` have no grammar and no upstream PR;
they are bare file nodes with no internal structure. Read them directly.

**For Solidity questions the graph cannot answer** — modifier semantics, storage layout, who can call what
and what it writes — `evm/slither-out/` remains the better tool. Regenerate with:

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
| `RangeState`, then `State` / `State.sol` | **`Shares` / `Shares.sol`** — ⚠️ **TWO HOPS** |

🔴 **AND THE SECOND HALF OF THE KEY, WHICH DID NOT EXIST UNTIL NOW: SIX LIBRARIES WERE *FOLDED INTO*
ANOTHER FILE, NOT RENAMED AND NOT DELETED. `docs/actionable/` CITES THEM ~190 TIMES AND EVERY ONE OF
THOSE GREPS RETURNS A COMMENT** (measured 2026-08-23 @`7e32eb48`: `ExternalTwap` 50, `FixedRateFill` 45,
`SOR` 41, `MuSig2Agg` 30, `ExitLib` 27, `ShareMath` 17). **This is the most dangerous class in the file**,
because unlike a tombstone the CODE IS STILL LIVE and the reader who greps the old name concludes the
feature was removed:

| the docs say | the tree has | fold |
|---|---|---|
| `ExitLib` / `ExitLib.sol` (`verifyDeadManExit`, `termsCommitment`, `settleFloorUsd`, `_cltvRefundLeaf`) | **`BitcoinTx`** (`imports/BitcoinTx.sol:661-837`) | §E318, one-way dep, 0 reverse refs |
| `MuSig2Agg` / `MuSig2Agg.sol` (`computeOutputKey`, `taprootOutputKeyWithLeaf`, `tapLeafHash`, `isTwoOfTwoOutputKey`, `decompress`) | **`BitcoinTx`** (`:424-525`) | §E312 |
| `ExternalTwap` / `ExternalTwap.sol` (`curvePriceWad`, `oneInchRateWad`) | **`OracleLib`** (`imports/OracleLib.sol:405`, `curvePriceWad` at `:428`/`:434`) | §E318 |
| `FixedRateFill` / `FixedRateFill.sol` (`quoteFill`, `quoteDrain`, `_applySkew`, `enforce`) | **`SwapLib`** (`imports/SwapLib.sol:2511`, `quoteFill` at `:2629`) | §E310 |
| `ShareMath` / `ShareMath.sol` | **`SwapLib`** | §E310 |
| `SortedSet.sol` (the FILE) | **`SortedSetLib`, declared in `imports/`** — symbol survives, file does not | — |

⚠️ **A FOLD DOES NOT SETTLE THE ROW'S VERDICT EITHER WAY, AND CONFLATING THE TWO IS THE TRAP.**
`FixedRateFill` is the worked example: the FILE is gone, and `SwapLib.quoteFill` still has **zero callers
in `src`, `test` and `script`** — so *"unwired, a marker for unbuilt work, do not delete"* is as true as
the day it was written. **Destale the coordinate; re-run the claim separately.**
⛔ **`SOR` / `SOR.sol` IS THE OPPOSITE CASE AND MUST NOT BE ADDED TO THE TABLE ABOVE: it is a genuine
TOMBSTONE** — the file is deleted, no successor holds its routing, and `evm/src` has no `_pickBestPath`
outside one `FeeLib.sol:147` comment. Its 41 citations are history.

⛔ **A RENAME TABLE IS ITSELF A DOCUMENT THAT GOES STALE, AND THIS ONE DID.** It read *"`RangeState` →
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
🔴 **RE-RUN 2026-08-23 @`7e32eb48`: 69 rows, and "TOMBSTONE" is now WRONG for a third of them — the
binary in the sentence above is the defect.** Classify into THREE buckets, in this order:
| bucket | how to tell | what to do |
|---|---|---|
| **VENDORED / NEVER OURS** (~24 rows) | it lives under `evm/lib`, or it is a Uniswap-v4 / v3 / OZ / solarity / Midnight / EtherFi name | leave it; the checker cannot see `lib/`. `TxMerkleProof.sol` and `AMerkleWhitelisted.sol` are both present at `evm/lib/solidity-lib/…`. ⚠️ `Something.sol` is this tool's own example string in this file |
| **FOLDED — CODE IS LIVE** (6 files, ~190 citations) | the successor file carries a `FOLDED IN` comment and the symbols still resolve | **destale the coordinate** — the six are in the fold table above. This is the bucket that misleads, because the grep looks identical to a tombstone |
| **TOMBSTONE — no successor** | nothing in `evm/src` implements it | leave it; the citation is history. Adds since this list was written: **`SOR.sol`** (routing, deleted outright — `_pickBestPath` survives only in a `FeeLib.sol:147` comment), plus the v4-cut casualties (`Amp.sol`, `Rover.sol`, `BatchLedger.sol`, `Court.sol`, `Jury.sol`, `Solver.sol`, `TxParser.sol`) |
⚠️ **Do NOT "fix" a vendored or tombstoned citation into a name that resolves to nothing** — that is
strictly worse than an obviously-old name, per the rename-table rule above. **Only the FOLDED bucket is
actionable.**

## The central structural fact — read this before proposing any refactor

**`isBTC` is polymorphism done by hand, and the duplication it implies is the codebase's biggest
single source of bulk.** ~5,500 lines sit in **four ETH/BTC pairs**:

| ETH side | BTC side | role |
|---|---|---|
| `Quid` 1,557 | `Vault` 991 | range manager — ⚠️ **but see the caveat below: this row is unconfirmed** |
| `LevManager` 908 | `BtcLevManager` 579 | lev manager (`§A.71`: `LevManager.Pos == BtcLevManager.Pos`) |
| `QuidLib` (was `QuidLib`) | `BtcLib` (was `BtcLib`) | delegatecall bodies — ⚠️ **RENAMED 2026-08-18**, and `QuidLib` folded INTO `QuidLib` and was deleted |
| ~~`VEth` 116~~ | `VBtc` 105 | ⛔ **THIS PAIR NO LONGER EXISTS — `VEth.sol` IS DELETED (2026-08-18: `ls` confirms, and the only `VEth` strings left in `evm/src` are 3 comments in `Quid.sol` recording the removal).** It is listed here only so the count of four is not read as current. See the RESOLVED note below: the ETH range manager IS the 4626, so there is no ETH face to pair with. |

**`Core` is the one place that got it right** — it parameterises the same distinction with a bool
(187 of the 359 `isBTC` occurrences; 13 files; 26 sit in `Interfaces.sol` signatures purely to pass
it through). Everything *above* `Core` forked into per-asset copies instead.

**The owner's target (2026-08-06):** *"there should just be one range manager, one lev manager, the
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

✅ **`Vault` WAS TWO THINGS FUSED. THE SPLIT IS DONE — `Vault` IS BTC-ONLY** (re-measured 2026-08-22).
The row below was written 2026-08-07 (11 ETH-named functions, 20 BTC-named, 24 state decls) and demanded
an extraction that has since happened: ETH-venue custody now lives in `EthVenue`. **Measured in
`Vault.sol` today, every ETH-venue symbol in the first row of the table is ZERO references** —
`supplyEtherFi` `supplyAaveEth` `supplyEulerEth` `offrampEtherFi` `aaveEthBalance` `deliverableETH`
`_supplyETH` `_withdrawETH` `ETHERFI` `WEETH` `AAVE_SPOKE`. `contract Vault is Ownable,
ReentrancyGuard, Shares` and nothing else.
⛔ **THE LAST TRACE OF THE FUSION WAS A `Quid` HANDLE, AND IT SURVIVED THE EXTRACTION BY 8 DAYS.**
`Vault` still declared `Quid internal immutable RANGE; // the ETH LP contract`, which is how a
BTC-only contract came to hold the ETH range manager. It had exactly two uses and both were leftovers:
a modifier `onlyUs` gating **zero** functions (every gated function uses `onlyUsBtc`) whose header
still described *"ETH-side venue ops (supply/withdraw/deliverable)"*, and one external call to
`RANGE.derivedThetaWadAt(...)` — a **one-line pass-through** to `QuidLib.derivedThetaWad(core, lo, up)`
reading no ETH state, which `Vault` was calling with its OWN core and OWN bounds. §E301 removed both;
deleting the now-callerless `derivedThetaWadAt` gave **`Quid` back 181 bytes** (86 → 267 margin).
⇒ **THE LESSON, AND IT IS THE ONE THIS FILE KEEPS RE-LEARNING: AN EXTRACTION LEAVES THE HANDLES
BEHIND.** The functions moved, the reference did not, and the stale comment beside it (*"the ETH LP
contract"*) made the reference read as load-bearing. Grep for the OLD collaborator's type after any
extraction, not just for the moved functions. The table below is kept as the record of what was split.
(original row, 2026-08-07):

| slice | what it is | members |
|---|---|---|
| **ETH venue custody** | 4626 venue positions | `supplyEtherFi` `supplyAaveEth` `supplyEulerEth` `offrampEtherFi` `_supplyETH` `_withdrawETH` `aaveEthBalance` `vogueETH` (`:444`) `deliverableETH` `_ethCfg` + every venue address (`AAVE_SPOKE` `ETHERFI_*` `WEETH`) |
| **BTC range accounting** | the actual counterpart of `Quid` | `registerBtcLp` `resize` `unregisterBtcLp` `exposeBtcToLev` `unexposeBtcFromLev` `syncLev` `_settleBtcLp` `settleBtcFeesOwed` `derivedThetaWadBtc` — plus the range state now inherited from `Shares.sol`'s `Shares`: `lpShares` `autoManaged` `levPooled` `totalBuffer` ⚠️ **SIX NAMES IN THIS ROW WENT STALE ON 2026-08-17/18 AND ARE CORRECTED ABOVE — `resizeBtcLp`→`resize`, `syncLevBTC`→`syncLev`, and `totalSharesBTC` `rangeBtcOf` `lpSharesBTC` `autoManagedBTC` `levPooledBTC` all now **0 references in `evm/src`**.** The BTC suffix was deleted (`d2dc8b78` *one name per concept, two instances*, `088d2640`, `e0d72836`) and the per-range state moved into `Shares`, ⛔ **AND "0 REFERENCES" MEANS RENAMED, NOT REMOVED — READ THIS BEFORE CONCLUDING ANYTHING FROM SUCH A GREP (owner's correction, 2026-08-18).** The BTC range is a SEPARATE INSTANCE carrying the SAME names without the suffix: `DeployLib.sol:136-137` constructs `new Core(cfg.weth, …)` **and** `new Core(cfg.wbtc, …)`, so **`lpShares` ON THE BTC INSTANCE *IS* WHAT `lpSharesBTC` NAMED** — same slot, same meaning, different address. ⇒ **THE DISCRIMINATOR MOVED FROM THE NAME TO THE ADDRESS, WHICH IS THE ENTIRE POINT OF THE `isBTC` REFACTOR.** Nothing was deleted; the suffix was, because the instance already carries the distinction. ⚠️ **A ZERO-HIT GREP FOR A SUFFIXED NAME IS EVIDENCE OF A RENAME, NEVER OF A REMOVAL — this file asserted the opposite until the owner caught it.** ⚠️ **THE ROW'S POINT SURVIVES INTACT AND IS WHY IT IS CORRECTED RATHER THAN DELETED: `Vault` IS still two things fused, and this list is still the BTC-range slice.** Only the spelling moved. |

⇒ **`Quid`'s pair is the BTC-range SLICE of `Vault`, not `Vault`.** The ETH-venue slice is a THIRD
concern with **no BTC counterpart — correctly**, because ETH venues are 4626 vaults while BTC custody
is Lightning channels (`BTCChannels`). That is the settlement asymmetry, and it is REAL.
🔴 **`VBtc` MUST SURVIVE THE CONSOLIDATION — do not "delete it into" the range manager.** The BTC range's
`asset()` is **not a real ERC-20 underlying**: it returns WBTC as a *pricing handle* (the venue prices
vBTC against WBTC via `getTWAPforAsset`) and `convertToAssets` is a pure identity because **vBTC IS
sats**. The real underlying is LN-custodied native BTC. So "one instance = one `asset()` = an honest
4626" holds for ETH (WETH is genuinely held and redeemable) and only **nominally** for BTC.
⚠️ **THE PRIVACY JUSTIFICATION FOR KEEPING `VBtc` IS DEAD — and `VBtc.sol:18-28` still asserts it.**
That header calls segregation *"a prerequisite, not cosmetics"* for the privacy story, naming a future
`redeemVBtc(sats, p2trScript)` and the `Σ outstanding vBTC ≤ Σ free channel capacity` invariant. But
`../ibiza` **already ruled that out** — `docs/actionable/TODO.md` (was `ibiza/TODO.md:2097`; RELOCATED 2026-08-30, line numbers shifted by the +39-line header — grep the quoted text, not the line): *"**2.4d vBTC through PP — RULED OUT.** It
is not a bearer instrument; there is nothing to anonymise"*, and `:2108-2115`: *"**NOBODY EVER HOLDS
vBTC** … it is an internal accounting token inside the leverage machinery, not a BTC wrapper anyone can
custody. **There is no vBTC holder population to build an anonymity set from.**"*
✅ **RESOLVED (owner, 2026-08-07) — AND THE REAL REASON IS NEITHER OF THE ONES THE CODE GIVES.**
`VEth` **deletes**; `VBtc` **survives**. The discriminator is simply *whether an ERC-20 underlying
already exists*:
  • **ETH — none needed.** WETH exists independently; wrapping/unwrapping is an edge detail. The range
    manager instance names `asset() = WETH` and IS the 4626 outright. `VEth` has no remaining job.
    ⭐ **THE MECHANICAL EXPRESSION OF THIS, MEASURED 2026-08-18 — and it is the sharpest form of the
    discriminator, so read it before re-opening the question a fourth time: `Quid`'s ERC-20 face is a
    PROJECTION OF RANGE STATE, while `VBtc`'s is a LEDGER.** `Quid.totalSupply()` returns `lpShares`,
    `Quid.balanceOf(u)` returns `autoManaged[u].pooled`, and `Quid.transfer` calls `_transferShares` —
    there is no balances mapping, because the range's own accounting IS the balance. `VBtc` declares
    `mapping(address => uint) balanceOf` and moves plain balances.
    ⇒ **`Quid.balanceOf ∥ VBtc.balanceOf` IS NOT A DUPLICATED PAIR LIKE `State`'s TWELVE.** Those twelve
    (`lpShares ∥ lpShares`, `feesPerShare ∥ feesPerShare`, …) are one concept declared twice. These two
    are a projection and a ledger — different things wearing one ERC-20 signature. **Folding them would
    duplicate state, which is the exact thing `Shares.sol`'s header says it exists to delete.**
    ⚠️ **AND DO NOT MOVE THE FACE INTO `State`:** an abstract base COPIES its bodies into every
    inheritor (measured +41 bytes, zero saved), and `State` is inherited by `Vault` too — which already
    has `VBtc` for that job. It would add bytes to the BTC range to remove none from anywhere.
  • **BTC — one must be MINTED.** The underlying is LN-custodied native BTC, which has **no EVM token**;
    WBTC is only a pricing handle and is never held. So the BTC range needs a **synthetic underlying to
    point `asset()` at**, and that is exactly what vBTC is (`ibiza/COMPLIANCE-THESIS.md:77`: *"a
    synthetic, sats-denominated token minted only against…"*).
⇒ `VBtc` exists because **the BTC range has no underlying unless it mints one** — NOT because anyone
holds it, custodies it, or anonymises it. An asymmetry with a real reason, and one that survives
instantiation rather than being dissolved by it.
⚠️ Follow-on to settle when this lands: today `VBtc.asset()` returns **WBTC** as a pricing handle. Under
this design vBTC IS the range's asset rather than having one, so that accessor's meaning has to be
revisited — do not carry it across unexamined.

🔴 **AND IT IS WORSE THAN STALE — `VBtc.sol:18-28` PROPOSES A FEATURE ibiza ANALYSED AS CROSS-LP THEFT.**
That header argues *"swap-out already proves the protocol can pay an arbitrary P2TR address whose owner
has no channel — so what is missing is an ENTRYPOINT plus a source-of-funds rule, not a capability"*,
and names `redeemVBtc(sats, p2trScript)`. `docs/actionable/TODO.md` (was `ibiza/TODO.md:2118-2132`; RELOCATED — grep the quote) rejects precisely that, quoting
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

⇒ ~~**Extra step, ordered FIRST:** extract ETH venue custody out of `Vault`.~~ ✅ **DONE** — see the
re-measurement at the head of this section. `Quid` ∥ `Vault` are now two range managers with no ETH-venue
slice fused into either, so the remaining question really is the one-implementation-two-instances merge.
✅ **THE "TWO POLYMORPHIC RANGE FACES" ARE MERGED, AND THIS PARAGRAPH WAS THIS FILE'S OWN TOMBSTONE
TRAP FIRING ON ITSELF (§E325, verified 2026-08-23).** It read: *"there are still TWO polymorphic range
faces over the same pair of objects — `IRangeManager` (7 members, state/control) and `IRange` (9,
settlement), zero overlap, both implemented by `Quid` and `Vault` … merging them is the §E21 move."*
🔴 **NEITHER SYMBOL HAS EVER BEEN DECLARED IN THIS TREE.** `grep -rnE "IRangeManager|\bIRange\b"
evm/{src,test,script}` returns only comments inside `Interfaces.sol`. The real pair was
**`IBandManager` (7) and `IBand` (9)**; `7f3b1f93` merged them, `c372f7b0` folded `IBand` into
**`ICore`**, and `1b21ca09` folded a second leftover `IBand` in. **Measured: `ICore` now declares 46
functions and carries all 16 members — `repack`, `rangeBounds`, `feesPerShare`, `USD_FEES`, `CORE`,
`derivedThetaWad`, `setBTCChannels`, `addLiq`, `creditSkewPremium`, `sweepOor`, `levManager`,
`levGrossNative`, `sharesForShortfall`, `realInventory`, `onShortfall`, `deliverVolatile`.**
⛔ **HOW THE STALENESS WAS MANUFACTURED, AND IT IS THE EXACT MECHANISM THIS FILE WARNS ABOUT TWO
SECTIONS DOWN:** the Band→Range rename (`1b21ca09`) rewrote the **dead** name `IBandManager` inside a
*comment* into `IRangeManager` — a name that resolves to nothing. *"Renaming a tombstone does not
destale it; it disguises it."* A disguised tombstone reads as outstanding work, and this one was
quoted as live for two days and nearly commissioned as a refactor.
⇒ **THE DISCRIMINATOR IS WHETHER THE NEW NAME EXISTS, NOT WHETHER THE OLD ONE LOOKS OLD** — already
stated in the RENAMES section, and violated here by the same commit that stated it.
✅ **BOTH REMAINING FOLDS LANDED 2026-08-25, AND A SWEEP SAYS NOTHING ELSE IS LEFT.** `IQuid`→`ICore`
(`derivedThetaWad` deduped as predicted; `unwindForRedeem`/`pendingRewards` moved across; 7 call sites
retargeted, 0 residual) and `ILevVenueColl`→`ILevVenue` (`stable()` deduped, `COLLATERAL()` moved; 13
refs retargeted). ⚠️ **The second was checked on IMPLEMENTOR, not on shared members** — `LevVenueBase`
provides both `COLLATERAL()` and `supply(address,uint256)` — because merging two faces that merely
share an address is the §EthVenue-split defect.
▶️ **AND THE SWEEP THAT CLOSES THE QUESTION, with its false-positive class named per the sweep rule:
7 signatures are declared in 2+ interfaces and REAL fold candidates are 0.** The discarded class is
*same member name, different implementor or different standard*: `decimals()` (Chainlink feed vs
ERC-20), `transferFrom` (ICollection vs IERC20Min), `rangeETH`/`deliverableETH` (`IAux` FORWARDS to
`IEthVenue` — two contracts, verified in a live trace), `LEV_MANAGER`, `subPendingSwapOut`, and
`swapOutDeleverAmt` (the arity split ruled out just below). ⇒ **Rule-2 consolidation of
`Interfaces.sol` is DONE at 37 interfaces; do not re-commission it.** ⛔ **`ILevManagerDeliver` ∥ `ILevEthDeliver` CANNOT merge** — `swapOutDelever` is
`(address,uint,uint)` on `BtcLevManager` and `(address,uint,address,uint)` on `LevManager`, so merging
creates an **overload**, which is what the `ICurvePool` note forbids (integer-literal inference picking
the wrong ABI). That arity split is also the blocker on collapsing the five lev faces into one.

## 🔴 SPLITTING ONE CONTRACT INTO TWO: audit ASSIGNMENTS, not call sites (measured 2026-08-15)

Extracting `EthVenue` out of `Vault` planted **three** instances of one bug, all of which COMPILED
CLEAN and reverted only at runtime, because in Solidity every contract handle is an `address` and the
compiler cannot tell two of them apart.

**THE ROOT: code that merged two identities because they SHARED AN ADDRESS.** `IBtcVault` had existed
as a separate interface precisely to mark that ETH-venue custody and the BTC range manager are
different things. It was deleted as "a second interface over one contract" — true while the address
was shared, false the moment it was not. ⇒ **MERGE ON WHAT THINGS ARE, NEVER ON WHAT ADDRESS THEY
CURRENTLY SHARE.** Same shape as `create_sweep_tx`: a marker for a gap that has not opened yet is
indistinguishable from duplication.

**THE AUDIT METHOD THAT FAILED:** I enumerated every `IRangeManager(x).member` / `IEthVenue(x).member`
call site and scored 29/29 correct — and that was TRUE. `IRangeManager(c.btcVault).repack(true)` is a
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
- 🔴 **THE AGENT SHELL'S CWD PERSISTS BETWEEN CALLS, SO A BARE `forge build` CAN RUN WHERE THERE IS NO
  `foundry.toml`, PRINT `Nothing to compile`, AND EXIT 0** (measured 2026-08-22, it produced a false
  "all gates green" on a money-path change). `foundry.toml` exists ONLY in `evm/`. One earlier
  `cd evm` makes bare `forge build` correct; one later `cd /…/SPV && python3 tools/…` silently moves
  it back, and every `forge` call after that is a no-op that still exits 0.
  ⚠️ **AND THE NEXT COMMAND LAUNDERS IT: `check-contract-sizes.py` reads `evm/out`, which the LAST
  REAL build left behind, so it reports plausible fresh-looking numbers for a build that never ran.**
  Same shape as "`evm/out` OUTLIVES `evm/src`" above, reached from a new direction — there the source
  vanished, here the compiler never ran, and both end in a green measurement describing nothing.
  ⇒ **`cd <abs>/evm && forge …` IN EVERY CALL, and treat `Nothing to compile` on a changed tree as a
  FAILURE, not a cache hit.** `forge test` is the louder tell: it runs zero tests and still exits 0.
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
  🔴 **IT FIRED AGAIN ON 2026-09-06, ON AN AUTHOR WHO HAD READ THIS BULLET THE SAME HOUR** — waiting
  for another lane's build to finish before measuring, with `until ! pgrep -f "forge build"`. **The
  loop's own command line contains `forge build`, so it matched itself and could never exit.**
  ⇒ **A WARNING IS NOT A MECHANISM, WHICH IS THE SAME LESSON AS THE GRAPH SECTION ABOVE.** If you
  must wait on a process, the working forms are **`pgrep -x solc-0.8.30`** (exact NAME match, so a
  shell running a pattern containing it does not match) or `pgrep -f pat | grep -qv "^$$\$"`.
  ⭐ **Better still, do not wait at all: the metric that made the wait unnecessary was already in the
  log.** I wanted a contention-free build time and the answer was `Compiling N files`, printed by
  every build — see the lane section above. **The best fix for a poll loop is usually a measurement
  that does not need one.**
- **Build+test in ONE call** (`forge build && forge test`) rather than two turns — it removes a whole
  turnaround per verification.

## Build environment

| | |
|---|---|
| solc | `0.8.30`, optimizer on, **200 runs** (`evm/foundry.toml`) |
| **foundry** | 🔴 **THIS TREE NEEDS A MODERN `forge` AND SAYS SO IN TWO PLACES, NEITHER OF WHICH THIS TABLE RECORDED UNTIL 2026-08-29.** A `forge 0.2.0 (2024-08-15)` **cannot load the config at all** — it panics `failed to extract foundry config: Unknown evm version: osaka` reading `evm/lib/openzeppelin-contracts/foundry.toml`, which is the **PINNED** submodule, so this is not drift and cannot be waited out. Independently, `foundry.toml`'s own `dynamic_test_linking = true` is a key that build predates. ⚠️ **THE FAILURE IS NOT A TEST FAILURE AND NAMES NOTHING IN THIS REPO** — it is a Rust panic with a backtrace and *"This is a bug, consider reporting it"*, arriving AFTER forge has spent minutes cloning missing submodules. ▶️ **`foundryup`.** CI has always been right: `foundry-rs/foundry-toolchain@v1` with `version: stable`. Measured working here 2026-08-29: **`1.6.0-nightly` (`5e88010a`)**. ⚠️ Two identity tests move with the toolchain and are NOT contract evidence — see §WARP-THE-PRECONDITION for the shape (a test whose PREMISE was a harness default). |
| **`evm/.env`** | ⚠️ **DOES NOT EXIST IN A FRESH CHECKOUT** (it is gitignored, and every row below that says *"`evm/.env` now points there"* describes one machine's file, not the repo). ⇒ **`ETH_RPC_URL` must be passed on the command line**, or `foundry.toml`'s `mainnet = "${ETH_RPC_URL}"` resolves to empty and every fork dies. |
| `via_ir` | **`false`, deliberately.** Stack-too-deep is solved by moving locals into struct fields (one memory pointer costs less stack than two values), not by turning on the IR pipeline. |
| remappings | `evm/remappings.txt` only — there is deliberately no `remappings = [...]` in `foundry.toml` |
| **EIP-170** | `forge test` does **not** enforce the 24,576-byte limit. **`forge build --sizes` does not either, for the contracts that matter most** — measured 2026-08-05: `Core` has **no row in that table at all** (278 rows; `SwapLib`, `Aux`, `BasketLib`, `LevManager`, `LevMath`, `QuidLib` all present). The cause is *not* library linking — `SwapLib`, `Aux`, `LevManager` and `Quid` are all linked and all appear — and remains **unknown**. **Use `python3 tools/check-contract-sizes.py` instead**: it reads `deployedBytecode.object` from `evm/out/**` for every contract declared in `evm/src`, which is exact (a link placeholder `__$…$__` is 40 hex chars = the 20 bytes its address occupies). 🔴🔴 **RE-MEASURED 2026-08-28 — THE BINDING CONTRACT IS `SwapLib`, AT 102 BYTES. THAT IS THE
TIGHTEST MARGIN EVER RECORDED IN THIS FILE, AND `SwapLib` IS NAMED NOWHERE ELSE IN IT AS A
CANDIDATE.** From a green build (`forge build --threads 1`, exit 0, 1,790 artifacts) after the ibiza
merge: **`SwapLib` 24,474 (102) · `BTCChannels` 23,217 (1,359) · `Quid` 23,123 (1,453) ·
`LevManager` 22,999 (1,577) · `BasketLib` 21,503 (3,073).**
⚠️ **THIS IS THE FOURTH CONSECUTIVE WRONG ANSWER THE ROW BELOW GIVES** — `Quid`, `BTCChannels`,
`LevManager`, and now none of those. 102 bytes is tighter than `LevMath`'s 73-byte low and `Quid`'s
190, and **this repo has already shipped a `Core` at −126 bytes with a fully green suite**, so the
suite will not catch the next addition.
⛔ **`SwapLib` IS ALSO THE FILE ANOTHER LANE IS ACTIVELY EDITING** (the §E308 load-balance work,
which had a stack-too-deep at `:1158` on 2026-08-28). **Anyone landing there has 102 bytes.** Fold
before adding, per rule 8c — folding N inlined bodies into one routine is what has historically given
this fleet its headroom back.
📊 **AND THE CENSUS CHANGED SHAPE: 950 DEPLOYABLE CONTRACTS, not the ~30 every earlier reading in
this row counted.** The identity stack folded into `evm/src/identity` (75 hand-written files, 31
concrete contracts) and its **109 generated Honk verifiers** all count now. Every margin table above
predates that, so a "top five" from before 2026-08-28 was drawn from a different population.
✅ **SETTLED THE SAME DAY, so it is not re-opened: the five Honk verifiers all fit comfortably** —
`NotaryActionHonkVerifier` 18,019 (6,557) · `WithdrawalHonkVerifier` 17,130 · `EscrowEnvelopeHonkVerifier`
17,129 · `TitleHolderHonkVerifier` 17,066 · `RagequitHonkVerifier` 17,065. The last four are pinned to
`optimizer_runs = 1` by `foundry.toml`; `NotaryAction` is NOT pinned and is still the largest, by ~900
bytes rather than the ~7,000 that would put it at risk. ⚠️ **It was flagged as suspect purely because
its SOURCE is 2,518 lines, identical to three that are pinned — and that inference was worthless:
runtime size tracks PUBLIC INPUT COUNT, not source length**, exactly as the `EscrowEnvelope`
restriction comment says. Measure before flagging.
(prior reading, kept for the rate-of-change record:) **2026-08-25 from a green build: `LevManager` 23,590 (**986**) · `BTCChannels` 22,979 (1,597) · `SwapLib` 22,368 (2,208) · `Quid` 21,625 (2,951) · `BasketLib` 21,503 (3,073). `LevManager` STILL BINDS but is no longer critical — the §RULE-8C folds (`nonReentrant`'s body hoisted out of 15 inline copies; five identical `NotGov` gates folded to `_onlyRange()`) gave back **+440 bytes**, 546 → 986.** Earlier the same day it read **24,030 / 546 to spare** with `Quid` at 21,512 (3,064).** ⚠️ **`LevManager` GREW +1,967 BYTES since 2026-08-23** (22,063 → 24,030) — the §C2.1 1inch plumbing threads a `bytes route` through `SellCtx`/`ExtractCfg`/`WbtcCfg` and every routed entrypoint, and calldata-carrying params are not free. **It has 546 bytes left, so the remaining routed entrypoints do NOT fit without a fold.** ⛔ **THE SENTENCE BELOW IS THE THIRD CONSECUTIVE WRONG ANSWER TO "WHICH CONTRACT BINDS" IN THIS FILE — `Quid`, then `BTCChannels`, now `LevManager` — WHICH IS THE POINT OF THE WARNING IT INTRODUCES, NOT A COUNTER-EXAMPLE TO IT.** (kept as written on 2026-08-23:)
🔴🔴 **THE BINDING CONTRACT IS `BTCChannels` (1,163). IT IS NOT `Quid`, AND EVERY ARGUMENT THAT REASONS FROM `Quid`'S MARGIN IS NOW WRONG.** `Quid` has **2,720** after the fleet's fold sweep — it lost **1,932 bytes** in one pass (§E347-QUID). **MEASURED MARGINS — RE-MEASURED 2026-08-23 from a GREEN batched build (`forge build` exit 0) after lanes A/B/C/D/E landed, 30 deployable contracts. RE-RUN THE SCRIPT; DO NOT TRUST ANY NUMBER WRITTEN HERE: `BTCChannels` 23,413 (1,163 left) · `LevManager` 22,063 (2,513) · `Quid` 21,856 (2,720) · `BasketLib` 21,713 (2,863) · `SwapLib` 21,434 (3,142) · `Aux` 21,002 (3,574) · `LevMath` 20,204 (4,372) · `BitcoinTx` 19,262 (5,314) · `QuidLib` 17,512 (7,064) · `BtcLevManager` 17,228 (7,348) · `BtcLib` 16,172 (8,404) · `ChannelLib` 16,037 (8,539) · `Vault` 11,833 (12,743) · `Core` 11,637 (12,939). Net across the fleet: −2,649 bytes.** 🔴 **THIS ROW WAS WRONG **THREE TIMES** ON 2026-08-23 ALONE, WHICH IS THE POINT OF ITS OWN WARNING, AND THE THIRD TIME IS THE INSTRUCTIVE ONE: §E344 published `Core` 10,665 (13,911) and `Quid` 24,104 (472); §E345 put **+639** on `Core` and §E346 took **−316** off `Quid` within hours; then the fold sweep moved `Quid` another −1,608 and `Vault` −842 — **and the sentence *"`Quid` is now the sole binding contract"* was written into this row and falsified the same day by its own author.** ⇒ **A MARGIN IS NOT A FACT ABOUT THE REPO, IT IS A READING WITH A TIMESTAMP. So is WHICH CONTRACT BINDS, and that is the half people quote from memory.** 🔴 **`Core` FELL 24,025 → ~11.6 KB IN ONE CUT (§V4-CUT: `contract Core {` no longer says `is SafeCallback`; the 12 `_unlockCallback` Actions and the tick/sqrt geometry went with it), SO EVERY "`Core` CANNOT AFFORD IT" ARGUMENT WRITTEN BEFORE 2026-08-23 IS OFF BY ~13 KB — see §E344. `LevMath` (24,503 / 73 as recently as 2026-08-15) has left the top five entirely at 20,204 / 4,372.** Prior 2026-08-15 reading, kept only as the record of how fast this moves: `LevMath` 24,503 (73) · `Quid` 24,386 (190) · `Core` 24,025 (551) · `BTCChannels` 23,939 (637) · `LevManager` 23,918 (658). Prior readings: 2026-08-14 LevManager 252 / Core 920 / LevMath 978 / BTCChannels 1,048 / Quid 1,267; 2026-08-12 Core 148 / LevManager 224 / LevMath 228 / Quid 968; 2026-08-05 Core 38 / LevManager 70 / LevMath 20 / Quid 416. **FOUR readings, no two alike** — headroom both returns (deletions: the WETH-4626 venue removal freed ~770 on `Core`, ~750 on `LevMath`) and DISAPPEARS (consolidations). **A stale margin is worse than none: it either blocks an affordable change or waves through an unaffordable one.**
⛔ **THE BINDING CONTRACT IS NO LONGER `Quid` — SEE THE ROW ABOVE. IT IS `BTCChannels` (1,163); `Quid` HAS 2,720, NOT THE `190` BELOW.** This line said `Quid (190)`, then `Quid (788)`, and is kept only as the record of how fast the answer moves. Re-measured 2026-08-16: **`LevMath` 24,068 (508 left)** — since fallen to **20,204 (4,372)**; it went 73 → 508 when `_toUsdc`/`_fromUsdc`'s per-stable `if` chains collapsed into one `_routeOf` table (§E210), **freeing 435 bytes**. That is the second time a *consolidation* handed back a large block on this contract, and it is the counter-example to the "consolidations cost bytes" reading of the `Quid` entry below: **folding a whole CONTRACT in costs bytes (its code must land somewhere); folding N INLINED BODIES into one routine gives them back.** `LevManager` is no longer tight either — it went 252 → 658 as the Uniswap/venue removals landed. ⚠️ **`Quid` LOST ~1,077 BYTES IN ONE CHANGE** (1,267 → 190): folding `VEth` in deleted a whole deployed contract, but its 4626 identity and ERC-20 mutators are bytecode that had to land somewhere, and it landed here. **Net tree code went DOWN while `Quid` went UP** — that is the axis a "we deleted a contract" summary hides, and it is exactly why the size gate runs BEFORE the suite. Do not plan an addition to `Quid` against any older figure. This repo has already shipped a `Core` at −126 bytes (undeployable) with a fully green suite; a ~52-byte addition to `Core` on 2026-08-05 consumed more than half the remaining margin before anyone measured it. |
| library bodies | Delegatecalled library functions must be `external`/`public`. That is why the external surface is large; it is not accidental API. |
| fork tests | 🔴🔴 **A PIN HAS A SHELF LIFE, AND IT IS SHORTER THAN A FULL SUITE. MEASURED BY BISECTION 2026-08-29: `ethereum-rpc.publicnode.com` SERVES STATE FOR 128 BLOCKS AND REFUSES AT 128.** `eth_getBalance` at head−0/8/16/32/48/64/96 all return a value; **head−128 returns `-32602 "Archive requests require a personal token"`**. 128 blocks is **~25 minutes**. ⇒ **A pin taken at head−20 is valid for ~108 blocks ≈ 21½ minutes of WALL CLOCK, and that clock starts when you compute it, not when the tests start forking.** A cold `forge build` spends several of those minutes and the suite spends ~12 more, so the pin can expire DURING the run — and what you see is **the suites that fork LAST failing `403 Archive requests require a personal token` while 850 earlier tests pass**. That is the most deceptive shape this file has recorded: it is not a mass failure, it is a TAIL, and every one of its members is a real fork test with a real name. **Measured: 10 such tests (`test_ClassifyAllVenues`, `test_Curve_*` ×3, `test_E294_*` ×3, `test_E69_IsRestoringNaturallyProfitable`, `test_aaveLegYieldFactorIsDimensionless`, `test_RepayFor_PermissionlessReducesLpDebt`) — ALL 35 tests in their six suites pass at a fresh pin, 0 failed.** ⇒ **TAKE THE PIN IMMEDIATELY BEFORE `forge test`, AFTER `forge build` HAS ALREADY RETURNED**, and treat a late-run 403 as an expired pin, never as a finding. ⛔ **AND NOTE WHAT THIS RETIRES: the "publicnode rate-limits under a full suite" reading below is at least partly THIS, misread.** A 403 whose body names an ARCHIVE TOKEN is not a rate limit, and re-running the same tests at a fresh pin is the one-command discriminator. ⚠️ **`FOUNDRY_RPC_ENDPOINTS_MAINNET` DOES NOT WORK — it is silently ignored.** `foundry.toml` resolves `mainnet = "${ETH_RPC_URL}"`, so the override is **`ETH_RPC_URL=<url> FORK_BLOCK=<n> forge test`**. Measured 2026-08-10: two full suites reported 3,318 and 1,623 failures, **all 403/429, zero assertions**, because the ignored variable left forge on the non-archival public node while `FORK_BLOCK` was pinned. **A PINNED BLOCK REQUIRES THE ARCHIVE ENDPOINT** (`ETH_RPC_URL=$ANKR_RPC_URL`); publicnode is keyless but head-only. Public nodes are not archival; a stale `FORK_BLOCK` fails to fetch rather than failing a test. ⚠️ **A DEAD RPC KEY LOOKS LIKE A BROKEN TEST SUITE.** On 2026-08-06 the ankr key in `evm/.env` returned `HTTP 401 "API key disabled"`, which fails inside `setUp()` — so **every fork test in the repo reported FAIL** with no assertion involved. Read the failure text before believing a mass regression: `could not instantiate forked environment` is an endpoint problem, not a code one. **Verified live and keyless 2026-08-06** (block 25,697,138): `ethereum-rpc.publicnode.com`, `rpc.flashbots.net`, `eth.drpc.org`. Dead: `eth.llamarpc.com` (521), `cloudflare-eth.com` (-32046). `foundry.toml:44` already names publicnode as the keyless fallback; `evm/.env` now points there. This is also the likeliest thing CI was mailing about. ⚠️ **BUT THE KEYLESS NODE RATE-LIMITS UNDER A FULL-SUITE RUN.** Measured 2026-08-08: three tests failed with `HTTP 429 "Rate limit exceeded"` from publicnode — `test_ClassifyAllVenues`, `test_RunSim_IL_Baseline_ChopIsBenign`, `testGrindRemoval_DrainPaysRetainedSkewPremium`. **That is an ENDPOINT failure wearing a test's name, same category as the 401 above**, and it moves between runs, so treat any `Max retries exceeded HTTP error 429` line as environmental before attributing it to code. ✅ **AND THE REPLACEMENT IS KEYLESS ARCHIVE — MEASURED 2026-08-25, SO THE DEAD KEY NO LONGER BLOCKS
`FORK_BLOCK`.** Three public endpoints serve HISTORICAL STATE with no API key. Probe used, and it is
the discriminator (a non-archive node errors or returns `0x0`):
`eth_getBalance(0x00000000219ab540356cBB839Cbe05303d7705Fa, 0xE4E1C0)` → **`0xab18b3546f81ce8715045`**
(~12.9M ETH, the real beacon-deposit balance at block 15,000,000).
| endpoint | archive | note |
|---|---|---|
| **`https://eth.merkle.io`** | ✅ | fastest of the three on probe (~250ms) |
| **`https://eth-pokt.nodies.app`** | ✅ | |
| **`https://rpc.mevblocker.io`** | ✅ | |
| `rpc.flashbots.net` | ⛔ | head-only: *"state at block … not available"* |
| `1rpc.io/eth`, `eth.rpc.blxrbdn.com` | ⛔ | *"historical state"* error |
| `ethereum-rpc.publicnode.com` | ⛔ | *"Archive requests require…"* — head-only, as recorded below |
| `eth.llamarpc.com`, `ethereum.blockpi.network` | ⛔ | HTTP 521, dead |
⛔ **BUT ARCHIVE-ON-A-PROBE IS NOT USABLE-FOR-A-SUITE, AND I LEARNED THAT BY BREAKING A CENSUS WITH
IT.** A full run on `eth.merkle.io` returned **190 tests in 29.51s with 141 environmental errors and
0 `setUp` failures** — the DEAD-RPC SIGNATURE this file already describes (519 → 190 in 7.58s), just
wearing a different endpoint's name. **A single `curl` proving archive capability says nothing about
sustained concurrent load.**
⛔⛔ **SECOND CORRECTION, AND IT KILLS THE PRACTICAL USE: ALL THREE FAIL UNDER A FORK TEST — EVEN A
SINGLE TARGETED ONE.** Tested `FORK_BLOCK=25800000` with `--match-test` on one test:
`eth.merkle.io` → *"could not instantiate forked environment … Max retries exceeded"*;
`eth-pokt.nodies.app` and `rpc.mevblocker.io` → *"database error: failed to get storage … Max retries
exceeded"*. **A fork test issues thousands of `eth_getStorageAt` calls, and a free endpoint throttles
long before that.** ⇒ **THEY ARE ARCHIVE-CAPABLE AND THROUGHPUT-USELESS.** Do not reach for them
expecting a pinned run to work; the capability probe and the workload are two different questions,
which is the same lesson as the census above arriving one level down.
⇒ ~~**SO THE HONEST STATE: THERE IS STILL NO USABLE ARCHIVE ENDPOINT IN THIS TREE**~~
✅✅ **RESOLVED 2026-09-05 — THE OWNER SUPPLIED A LIVE ANKR KEY, AND IT IS THE FIRST ENDPOINT IN THIS
TREE TO PASS BOTH TESTS.** Banked as **`ANKR_RPC_URL` in `evm/.env`** (gitignored, mode 600; verified
`git check-ignore` and 0 tracked files contain it — **NEVER `foundry.toml`, which is committed**).
**Both acceptance gates run, because this row exists to record that the first does not imply the
second:**
  1. **Archive capability** — CLAUDE.md's own discriminator,
     `eth_getBalance(0x00000000219ab540356cBB839Cbe05303d7705Fa, 0xE4E1C0)` → **`0xab18b3546f81ce8715045`**,
     the exact expected value.
  2. 🔑 **THROUGHPUT UNDER A REAL FORK SUITE AT A PAST PIN — the gate merkle.io, pokt and mevblocker all
     FAILED.** `ETH_RPC_URL=$ANKR_RPC_URL FORK_BLOCK=25800000 forge test --match-path
     test/CurveOfframp.t.sol` → **5 passed / 0 failed in 1.67s**, including
     `test_Curve_ExchangeActuallyFills`, which performs a REAL swap and asserts the measured balance
     delta. **No `database error`, no `Max retries exceeded`, no `could not instantiate forked
     environment`.**
⚠️ **THE FAST RUNTIME IS NOT THE MERKLE TELL HERE, AND THE DISCRIMINATOR IS THE ASSERTIONS.** A run that
never reaches the fork is fast AND vacuous (merkle: 190 tests in 29.51s with 141 environmental errors);
this one is fast and every test made a real venue read. **Check assertions, not just the clock.**
⇒ **`FORK_BLOCK` CAN NOW BE PINNED TO A PAST BLOCK**, which is what `§A.18`'s attribution discipline
needs and what the `§E155-rate` magnitude harness was blocked on (*"needs `FORK_BLOCK` set to a past
block plus `vm.rollFork` forward … Booked, not built"* — **now buildable**).
⚠️ **The two DEAD ankr keys below remain dead; this is a THIRD, new key.** Do not resurrect the old
URLs. ⚠️ **And treat any key that ever reaches a committed file as DISCLOSED and rotate it** — this repo
has shipped that mistake once (`foundry.toml`'s Ankr token, commit `0af7f6d`).
✅✅ **THE FLAKINESS IS SOLVED WITHOUT AN ARCHIVE KEY, AND THE FIX WAS ALREADY IN THE TREE — `ForkPin`
(`evm/test/utils/ForkPin.sol`). PIN `FORK_BLOCK` TO A *CURRENT* BLOCK.** Its own docstring gives the
recipe and I spent a day not using it:
```
FORK_BLOCK=$(cast block-number --rpc-url "$MAINNET_RPC")   # or head-20 via eth_blockNumber
FORK_BLOCK=$PIN ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test -j 8
```
⇒ **WHY IT ENDS THE FLAKINESS, AND IT IS NOT ONLY DETERMINISM:** every fork in the run uses ONE block,
so foundry's `~/.foundry/cache/rpc` (already **11 GB** here) caches that block's state to DISK. The
first run warms it; later runs read locally instead of re-fetching, which is what was rate-limiting
every endpoint. **A pinned block is servable by a NON-ARCHIVE node** as long as it is recent, so this
needs no key at all.
📉 **MEASURED 2026-08-25 at `FORK_BLOCK=25833279`: 480 passed / 39 failed / 519 total, and — for the
first time all day — `setUp` failures **0** and environmental errors **0**.** Unpinned runs the same
hour produced 32 `setUp` failures, totals swinging 341–517, and three stalled censuses.
⇒ **QUOTE A PASS COUNT ONLY FROM A PINNED RUN.** An unpinned total is not a measurement of the tree.
⚠️ Pin a block ~20 behind head so it is stable, and reuse the SAME pin across a comparison — that is
the whole point (`§A.18`: three correct fixes were each blamed for 31 failures a clean tree reproduced).

⇒ **AND THE ENDPOINT RULE, WHICH THE PIN MAKES ALMOST IRRELEVANT:**
  • **EVERYTHING → `https://ethereum-rpc.publicnode.com`** (head-only, but it survives the load).
⚠️ **THE THREE TELLS OF A CONTAMINATED RUN, CHECK ALL THREE BEFORE QUOTING ANY TOTAL:**
  1. `grep -cE '\[FAIL.*\] setUp'` non-zero ⇒ the total is a FLOOR (drpc did this: 517 → 341).
  2. `grep -cE 'HTTP error|database error|Rate limit|instantiate forked'` non-zero ⇒ same.
  3. **RUNTIME far below normal** ⇒ it never reached the fork (merkle did this: 29.51s for 190 tests).
     **A count can look plausible while the clock says the run never happened.**
⚠️ **And if a run STALLS rather than fails, the signature is ~0-1% CPU with elapsed time climbing;
`-j 4` (`forge test --threads`) reduces concurrent forks and helps, at the cost of wall time.**

🔴 **BOTH ANKR KEYS IN THE TREE ARE DEAD — RE-PROBED 2026-08-25, AND THIS TIME BOTH WERE CHECKED, NOT
ONE.** ⚠️ **STILL TRUE OF THOSE TWO, AND SUPERSEDED AS THE TREE'S STATE: a THIRD, live archive key was
supplied 2026-09-05 and is banked as `ANKR_RPC_URL` — see the ✅✅ row above. The two URLs named below
are still dead; do not probe them a fifth time.** `evm/.env` and `evm/.env.bak-*` hold **two distinct** ankr URLs and each returns
`{"error":"message: API key disabled, json-rpc code: -32051, rest code: 403"}`:
`ANKR_RPC_URL` (…da76c96bb15a0) and **`QUID_FORK_RPC` (…7231034d6c65c)**, the second of which this row
never mentioned. ⇒ **THERE IS NO ARCHIVE ENDPOINT IN THIS TREE**, so `FORK_BLOCK` cannot be pinned and
every fork run is head-only on a keyless node. *"API key disabled"* is an ACCOUNT state at the
provider — quota or billing — **not something a session can fix by changing the URL**, which is why
re-probing it a fourth time is not the answer; ask the owner for a live key.
🔴 **`ANKR_RPC_URL` IS DEAD AGAIN — measured 2026-08-24: `HTTP 401 {"error":"message: API key disabled"}`.**
**THIS IS THE SECOND TIME THE SAME KEY HAS DIED AND THE SECOND TIME IT COST A SESSION.** The 2026-08-06
note below records the identical symptom. ⇒ **DO NOT PREFIX RUNS WITH `ETH_RPC_URL=$ANKR_RPC_URL`.**
⚠️ **AND THE TRAP IS THE OVERRIDE, NOT THE FILE: `evm/.env` ALREADY POINTS `ETH_RPC_URL` AT THE KEYLESS
PUBLIC NODE AND IS CORRECT.** A whole session ran with `ETH_RPC_URL=$ANKR_RPC_URL` on every command
because this row advertised the archive key — so `.env` was right and every invocation overrode it.
**A dead key wearing a test suite's name: 519 tests became 190, the run finished in 7.58s instead of
~250s, and 56 "failures" were all `vm.createSelectFork: could not instantiate`.** The tell is the
RUNTIME, not the count — a fork suite that finishes in seconds never reached a fork.
▶️ **The archive key was banked as `ANKR_RPC_URL` in `evm/.env` (gitignored; NEVER put it in
`foundry.toml`, which is committed).** Verified live 2026-08-08 — `eth_blockNumber` → `0x1885000`, and `eth_getBalance` at block `0xF4240` returns a real value rather than a missing-trie-node error, so it **is** archive-capable. **It is deliberately NOT wired into `ETH_RPC_URL`:** publicnode stays primary, and this is for archive needs or when 429s appear — `FOUNDRY_RPC_ENDPOINTS_MAINNET=$ANKR_RPC_URL forge test` uses it for one run with no file edit. |
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
They are `§DE-TICK` / `§TICK-REMOVAL` markers recording the removal: *"range bounds as PRICES"*,
*"carries the PRICE now, not a sqrt price"*, *"`rangeTicks` deleted — it packed a range-edge PRICE LIMIT
for v4's swap"*.
⚠️ **THE HIT COUNT LIES BY VOLUME**: 185 reads as heavy usage, and the density exists *because* the
removal was documented carefully. **Filter comments before concluding anything about tick usage** — the
inverse of "an empty grep proves nothing", and it costs the same wrong conclusion.
⇒ **Range bounds are ABSOLUTE PRICES** (`loPrice`/`upPrice`); the fill settles at the oracle; out-of-range
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
- 📱 **THE LP SIGNER APP SPEC LIVES IN `docs/actionable/TODO.md` §3b** 🔴 **RELOCATED 2026-08-30 (owner direction) FROM `../ibiza/TODO.md` — the file moved INTO this repo because all the work happens here. The rest of this bullet still holds: ibiza owns the mobile client, SPV owns the protocol.** (owner, 2026-08-13:
  *"this shouldn't be in our own queue… it should be in the ibiza TODO.md"*). ibiza owns the mobile
  client (react-native/expo); SPV owns the protocol. **What the phone must do — the seed-derived
  secp256k1 key, the one-time MuSig2 ladder ceremony, TEE-wrapping at rest, the nonce-reuse rule,
  the three deployment targets, social recovery's exact place — is written there, self-contained.**
  ⚠️ **Do not restate it in `QUEUE.md`.** The SPV rows (§E170/§E171-r/§E174/§E187/§E188) now keep
  only the protocol-side facts and point at §3b; two copies of a spec drift, and the one that drifts
  is always the copy in the repo that cannot build the thing.
- `docs/informational/` **contradicts the contracts in ~10 verified places** (the range is ±0.2%, not
  ±2%; the short leg, `baseRate`, CRE, and the swap-in bonus are gone; the stable count moved).
  Never quote it without checking the code.
- `SPRINT.md` `§BUILD-QUEUE-FOLD` is a folded **append-only archive**: its evidence (traces,
  `file:line`, measurements) is authoritative, its **status markers are not**. Current status lives in
  `docs/actionable/SPRINT.md` itself and is updated in place. Some of its citations point at `/home/rico`
  paths from a different machine and cannot be opened from here.
