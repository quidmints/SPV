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

# HEAD, not the working tree: another lane's UNCOMMITTED edits are excluded BY
# CONSTRUCTION, which is the property CLAUDE.md's 2026-08-10 note relies on.
git -C "$ROOT" worktree add --detach "$DEST" "$REF"

[ -f "$ROOT/evm/.env" ] && cp "$ROOT/evm/.env" "$DEST/evm/.env"   # gitignored; does not travel
cp -r "$ROOT/evm/out"   "$DEST/evm/out"   2>/dev/null || true      # warm start
cp -r "$ROOT/evm/cache" "$DEST/evm/cache" 2>/dev/null || true

cat <<EOF

lane $LANE ready at $DEST

  cd $DEST/evm && forge build           # ~35s warm, not ~342s cold
  python3 tools/impacted-tests.py       # what actually needs running
  git commit -- <paths by name>         # rule 14: NEVER add -A, NEVER commit -a

  Book findings in docs/actionable/lanes/$LANE.md, NEVER in SPRINT.md — every lane
  wants that file and it is the collision that ate fe9720ac.

  When done:  git worktree remove $DEST
EOF
