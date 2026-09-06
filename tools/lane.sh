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

cat <<EOF

lane $LANE ready at $DEST

  cd $DEST/evm && forge build           # ~35s warm, not ~342s cold
  python3 tools/impacted-tests.py       # what actually needs running
  git commit -- <paths by name>         # rule 14: NEVER add -A, NEVER commit -a

  🔴 BOOK FINDINGS IN docs/actionable/lanes/$LANE.md, NEVER IN SPRINT.md.
     This is mechanical, not stylistic. MEASURED 2026-09-06: two lanes that each
     appended one line to SPRINT.md merged clean the FIRST time and CONFLICTED the
     second. Their lanes/*.md files merged clean both times, being different files.

  Integrate (from the main tree, one lane at a time, so a conflict has one author):
     git merge --no-ff lane/$LANE
  When done:
     git worktree remove $DEST && git branch -d lane/$LANE
EOF
