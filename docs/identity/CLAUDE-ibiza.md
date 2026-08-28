# ibiza — standing rules

Loaded automatically at the start of every session. `README.md` explains what this repo is and what
came from upstream; `TODO.md` is the tracker. **This file is about how to work here.**

Every rule below was written after it was broken, on 2026-08-02, in a thread that took five passes
to find what one pass should have caught.

---

## 1. Lift a finding to a task IN THE SAME TURN, or it does not exist

The single most expensive failure here. A stables leg that was never wired, a mapped-but-unexecuted
cleanup of 23 vendored files, an unrotated credential, an ECDSA soundness hole — **every one had
been STATED in a reply and never booked.** Recorded somewhere, actionable nowhere.

If you say "worth checking", "still needs", "I didn't", "someone should" — create the task before
you send the message. Not after. Not "at the end". A finding in prose is a finding that dies with
the context window.

## 2. Run the control before concluding from an absent result

An empty grep, a zero count, a passing test — none of these prove anything on their own. **Ask:
would this measurement look the same if I were wrong?** Three wrong conclusions in one day:

- "`RootValidity` is tested" — two suites were NAMED after it and neither imported it.
- "the bisect was superseded" — never checked what it was for.
- "35 verifiers are dead, refs=0" — the LIVE verifiers also scored 0, because verifiers are wired by
  ADDRESS at deploy time. The metric could not distinguish dead from unwired.

The control for the last one was a single command: check whether the thing you claim is alive scores
the same as the thing you claim is dead.

## 3. A dismissal is a conclusion

"That's a false positive" needs the same evidence as a finding. Twice in one day a real finding was
waved away with a plausible explanation that was never checked — and the second time, the dismissal
itself had already been committed to a document.

## 4. Vendored code needs READING, not just building

`noir_dl_lib` was ported to a new compiler, had a module deleted, had its dependencies bumped, and
passed 77 tests — **without being read.** It contained the vendor's own
`// TODO: NONE OF THIS IS CONSTRAINED YET. FIX!` on the ECDSA scalar decomposition: a
signature-forgery hole, reachable, in shipped circuits. No transcript scan could ever have found it,
because nobody had mentioned it.

In a ZK circuit, **every `unsafe { }` is an UNCONSTRAINED prover-supplied value** and needs a
constraint immediately after it. `tools/scan-loose-ends.py` lists them all.

## 5. Read the recorded exit code, never the harness summary

A background task reported "exit code 0" for a run that exited **101** — that is the wrapper's exit,
not the command's. A `grep | tail -1` turned "70 passed, 7 failed" into "70 tests passed". Write
`echo "EXIT=$?" >> log` and read THAT line. Never let a summarising pipe decide whether a suite is
green.

## 6. Never commit an unverified constraint on a money or proof path

A plausible-but-wrong constraint is worse than a documented open hole, because it looks fixed. One
was committed on 2026-08-02 and broke `main`; the fix took three attempts. If the verification run
has not finished, **do not commit** — say the run is in flight.

## 7. Regenerate only what changed

Re-proving unchanged circuits is churn — ZK proofs are non-deterministic, so the bytes differ every
run — and one target (`title_holder`) actually FAILS when re-proved. Artifact generation is a
5-step pipeline; `codegen-verifiers.sh` is step 4 and `tools/prove-escrow-fixtures.sh` is step 5.
Skipping step 5 produces `SumcheckFailed()` nowhere near the cause.

## 8. Another thread may be in this tree

Check `git status` before staging. **Never `git add -A`** — stage your own files by name, and commit
without `-a`, or you will sweep someone else's staged work into your commit. If there is an unpushed
commit that is not yours, do not amend or rebase it.

---

## Before closing a thread

**⚠️ IBIZA HAS NO TRANSCRIPT DIRECTORY.** Sessions are filed by the directory the CLI is launched
from, not the repo being edited, and the CLI is always launched from the SPV checkout. So every ibiza
conversation ever held sits under `~/.claude/projects/-Users-ricktobacco-Documents-quidmint-SPV*/`.
Auditing ibiza from inside ibiza returns a clean result for the wrong reason — the same shape as
`refs=0` on verifiers, a measurement that cannot see what it claims to cover.

**GLOB ALL PROJECT DIRECTORIES, NOT ONE.** I wrote "exactly one directory" here and committed it
while the very command that produced it printed `project dirs: 2`. **Worktree-isolated agents get
their OWN project directory** — `…SPV--claude-worktrees-<branch>/` — so a loop over a single hard-coded
path silently skips them. There are currently 11 transcripts across 2 directories, and the worktree
one holds the rover-weeth discussion that `scan_prompts` was written for. Use `*/`:

```sh
for t in ~/.claude/projects/*/*.jsonl; do   # ALL dirs — worktrees have their own
  python3 tools/scan-loose-ends.py --transcript "$t" --against TODO.md --root .
done
```

**`--against` is the half that matters most**, and it answers a different question from the families:
they score what the MODEL said and never booked; `--against` scores what the USER ASKED FOR and
never got. A prompt can be entirely unaddressed and never trip a vocabulary family, because its
sentences read as ordinary prose — that is how a design intent stayed unbooked through 454 prompts.
It is a READING LIST, not a defect list: read every row.

**⚠️ AND SCORE AGAINST THE RIGHT TRACKER.** Both repos share these transcripts, so running
`--against TODO.md` over an SPV-work session marks every SPV topic as "uncovered" — because it IS
uncovered by ibiza's tracker, and correctly so. Measured: the worst-scoring prompt across 477 was a
Rover/etherfi liquidity question, which is not an ibiza gap at all. **A high score means "not in THIS
doc", never "unbooked anywhere."** Triage by repo first, or score the same transcript against
`../SPV/docs/actionable/QUEUE.md` too and treat only prompts uncovered by BOTH as real.

## Legacy note

```sh
python3 tools/scan-loose-ends.py --transcript ~/.claude/projects/<proj>/<session>.jsonl
```

Nine vocabulary families plus a code scan, cross-checked against the tracker. It over-reports
deliberately: a false candidate costs a glance, a missed one costs a thread.

## Toolchain

`nargo` here is a LOCALLY PATCHED beta.26 reporting `1.0.0-beta.26+quid-icefix1` (fixes an ICE filed
as noir-lang/noir#13440). The suffix is load-bearing — an unmarked patched build is indistinguishable
from the release and would slip past the guard in `codegen-verifiers.sh`. **CI and other machines
will fail that guard, correctly.** The circuits still build on stock beta.26. Stock binary:
`~/.nargo/bin/nargo.beta26-release.bak`. `bb` 6.0.0-nightly is an npm package pinned in `backend/circuits/package.json`: `npm install` there, then `export PATH="$PWD/node_modules/.bin:$PATH"`.
