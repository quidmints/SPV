#!/usr/bin/env bash
# lane.sh — spin up an isolated, WARM lane worktree.  usage: tools/lane.sh L3 [ref]
#
# WHY: `git worktree list` returning ONE entry with several agents inside it is
# negative parallelism, not zero parallelism. Measured 2026-09-06: three collisions in
# one session — `fe9720ac` swallowed a 228-line SPRINT.md restructuring with no mention
# of it in its message, and HEAD moved twice more mid-edit. CLAUDE.md rule 14b records
# the same class breaking `main`.
#
# WHY WARM: a cold `forge build` is ~342s, so a naive worktree taxes every lane 6
# minutes and nobody uses it twice. Copying the parent's artifacts first makes the
# lane's first build ~35s. ALL FOUR NUMBERS BELOW WERE MEASURED, NOT ESTIMATED:
#
#   git worktree add       1s
#   evm/out + evm/cache    0s   (125M; page cache makes it free on this box)
#   evm/lib                0s   ⭐ it is a SYMLINK in this repo, so it is already shared
#                               and needs no submodule init — the one thing that would
#                               otherwise cost minutes per lane
#   first `forge build`   ~35s  (0 errors; solc compiled 129 files, not 1,875)
#
# ISOLATION IS VERIFIED, NOT ASSUMED — `evm/src` and `evm/out` have different inodes
# from the parent's, and an edit made in the lane does NOT appear in the parent. That
# leak test is the acceptance test for this script; re-run it if you change anything
# here, because a lane that silently aliases the parent is strictly worse than no lane.
set -euo pipefail

LANE="${1:?usage: tools/lane.sh L3 [ref]}"
REF="${2:-HEAD}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${LANE_ROOT:-$(dirname "$ROOT")}/spv-$LANE"

[ -e "$DEST" ] && { echo "refusing: $DEST exists (it may hold uncommitted lane work)"; exit 1; }

# A BRANCH PER LANE, not --detach. This is what makes concurrent commits safe: a lane
# commits to `lane/<N>` and can therefore never fast-forward, amend or clobber another
# lane's work, and integration becomes an explicit merge someone reads.
#
# ⭐ AND GIT ENFORCES IT RATHER THAN ASKING YOU TO REMEMBER: checking the SAME branch
#    out in two worktrees is refused outright --
#      fatal: 'sprint-fold-and-destale' is already used by worktree at '/root/project/spv'
#    (measured 2026-09-06). So the shared-branch mistake is unconstructible, which per
#    standing rule 17 beats a rule telling people not to make it.
#
# REF is HEAD, not the working tree: another lane's UNCOMMITTED edits are excluded BY
# CONSTRUCTION, which is the property CLAUDE.md's 2026-08-10 note relies on.
git -C "$ROOT" worktree add -b "lane/$LANE" "$DEST" "$REF"

[ -f "$ROOT/evm/.env" ] && cp "$ROOT/evm/.env" "$DEST/evm/.env"   # gitignored; does not travel
cp -r "$ROOT/evm/out"   "$DEST/evm/out"   2>/dev/null || true      # warm start
cp -r "$ROOT/evm/cache" "$DEST/evm/cache" 2>/dev/null || true

# 🔴 THE STEP THAT IS NOT OPTIONAL, AND THE ONE THIS SCRIPT SHIPPED BROKEN WITHOUT.
# `git worktree add` creates the 11 forge submodule DIRECTORIES under evm/lib and does
# NOT populate them. Measured 2026-09-06: a lane built with 11 solc errors --
#   Error (7792): Function has override specified but does not override anything.
# -- which name files in evm/ and read exactly like your own defect. The control is
# what identified it: the PARENT built 0 errors at the same commit, and the lane's
# openzeppelin-contracts held 69 files against the parent's 86.
# `git submodule update --init --recursive` also works and is far slower.
cp -a "$ROOT/evm/lib/." "$DEST/evm/lib/" 2>/dev/null || true

# 🛤️ THE TWO SHARED DOCS DO NOT TRAVEL INTO THE LANE — THEY ARE SYMLINKS TO THE PARENT.
# Measured 2026-09-07: `lane/VERIFY` forked at 09:39 and was 26 commits / 46 files behind
# by the afternoon, and the files it was stale ON were CLAUDE.md and SPRINT.md -- the two
# that tell a thread how to work. That is not a long-branch problem that a shorter lane
# fixes; it is a CHURN problem, and the churn is measured:
#
#   commits touching SPRINT.md   756  \
#   commits touching CLAUDE.md    93   > 831 of 2,249 commits in 30 days = 37%
#   integration branch runs 40-67 commits/day
#
# ⇒ ANY branch, of ANY lifetime, is stale on these two within hours. No merge cadence
# fixes a file that every branch must read fresh and that 37% of commits write.
# ⭐ So the lane does not get a COPY to go stale: it gets the parent's file. There is
#    nothing to sync because there is only one of each. Per rule 17 the stale-doc state
#    is now unconstructible rather than forbidden.
#
# `--skip-worktree` FIRST, then the symlink, or git reports the substitution as a
# modification. The index is per-worktree, so this does not leak into the parent.
#
# ✅ VERIFIED 2026-09-07, not assumed -- parent advanced v1->v4 while a lane was open:
#      the lane read v4 with ZERO sync, and `git status` in the lane was CLEAN;
#      `git merge --no-ff lane/L1` into the parent left the parent's docs AT v4 -- the
#      lane's side is unchanged from the merge base, so 3-way keeps the parent's copy
#      and the lane's code change still arrives. THE MERGE-BACK DOES NOT CLOBBER.
#
# ⚠️ THE THREE FAILURE MODES, stated because they are the reason to say no:
#   1. `git checkout <branch> -- CLAUDE.md` inside a lane -- the old catch-up reflex --
#      SILENTLY replaces the symlink with a real file. Content stays correct, so it
#      degrades quietly back to the copy model rather than to something wrong.
#   2. after that, `git merge <integration>` in the lane fails "local changes would be
#      overwritten". Recoverable, noisy.
#   3. editing CLAUDE.md THROUGH the symlink writes into the PARENT tree, outside any
#      lane branch. ⇒ doc edits are a parent-tree action, one author at a time. Book
#      findings in lanes/$LANE.md, which is a real file in the lane and merges clean.
#
# ⛔ AND THE ONE LANE THAT MUST *NOT* GET THE SYMLINKS — A LANE AT A PAST REF.
# `tools/lane.sh L9 <ref>` is a real and different use: a lane at an OLD commit, to attribute a
# failing test by control rather than by argument. That lane is a SNAPSHOT, and handing it today's
# CLAUDE.md/SPRINT.md would make it lie about what was true at that commit -- the exact confound a
# control run exists to remove. ⇒ symlink ONLY when the lane is at the parent's current HEAD;
# a historical lane keeps its own honest copies and is stale ON PURPOSE.
if [ "$(git -C "$ROOT" rev-parse "$REF")" = "$(git -C "$ROOT" rev-parse HEAD)" ]; then
  for doc in CLAUDE.md docs/actionable/SPRINT.md; do
    [ -f "$ROOT/$doc" ] || continue
    git -C "$DEST" update-index --skip-worktree "$doc"
    ln -sfn "$ROOT/$doc" "$DEST/$doc"
  done
  DOCS_ARE_LINKED=1
else
  DOCS_ARE_LINKED=0
  echo "note: lane is at $REF, not HEAD -- CLAUDE.md/SPRINT.md kept as REAL FILES at that commit."
  echo "      A control lane must not be handed today's docs. Read the parent's copies for process."
fi

cat <<EOF

lane $LANE ready at $DEST

  cd $DEST/evm && forge build           # ~35s warm, not ~342s cold
  python3 tools/impacted-tests.py       # what actually needs running
  git commit -- <paths by name>         # rule 14: NEVER add -A, NEVER commit -a

  🔴 BOOK FINDINGS IN docs/actionable/lanes/$LANE.md, NEVER IN SPRINT.md.
     This is mechanical, not stylistic. MEASURED 2026-09-06: two lanes that each
     appended one line to SPRINT.md merged clean the FIRST time and CONFLICTED the
     second. Their lanes/*.md files merged clean both times, being different files.

  $([ "$DOCS_ARE_LINKED" = 1 ] && echo "🛤️ CLAUDE.md and SPRINT.md here are SYMLINKS to the parent" || echo "⛔ HISTORICAL LANE ($REF): CLAUDE.md and SPRINT.md are that commit's OWN copies")
  🛤️ When linked (a HEAD lane), CLAUDE.md and docs/actionable/SPRINT.md are the parent's, so
     they are never stale and there is nothing to sync -- 37% of commits touch those two
     files and a lane went 26 commits behind in one morning. Read them normally.
     ⚠️ DO NOT \`git checkout <branch> -- CLAUDE.md\` in this lane: it silently replaces
     the symlink with a copy and you are back to catching up. And an edit through the
     symlink writes into the PARENT -- doc edits belong to the parent tree, one author.

  🔴 AND CHECK WHO ELSE IMPORTS WHAT YOU ARE ABOUT TO CHANGE. The lane partition is cut
     on FILES; the compiler is not. \`evm/src/imports/LevMath.sol\` is L4's and is imported
     by three of L5's files -- a signature change there merges CLEAN and breaks the
     PARENT's build. See SPRINT.md §LANES' compile-coupling note before touching a header.
       grep -rl 'imports/<TheFile>' evm/src --include='*.sol'

  Integrate (from the main tree, one lane at a time, so a conflict has one author):
     git merge --no-ff lane/$LANE
  When done:
     git worktree remove $DEST && git branch -d lane/$LANE
EOF
