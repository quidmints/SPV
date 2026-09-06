#!/usr/bin/env bash
# graph.sh — ask the code graph, with the two things that stop people asking it removed.
#
#   tools/graph.sh explain  Basket
#   tools/graph.sh affected OracleLib          # reverse traversal = blast radius
#   tools/graph.sh path     evm_src_quid_quid evm_src_vault_vault
#   tools/graph.sh query    "who mints vUSD"
#   tools/graph.sh --rebuild                   # re-extract, then verify it actually moved
#
# WHY THIS EXISTS, AND IT IS NOT A CONVENIENCE WRAPPER. CLAUDE.md has told agents to
# "ask the graph before you grep" for weeks, and on 2026-09-06 a whole session grepped
# without asking it once -- including while hand-rolling a blast-radius scan that
# `graphify affected` already does, which is standing rule 8 violated against an
# instruction sitting in the file. Two MECHANISMS explain that better than the
# disposition does, and this script removes both:
#
#   1. `graphify` IS NOT ON PATH. It lives in a venv at an unmemorable path, so the
#      obvious `graphify explain Foo` returns "command not found" -- and the cost of
#      that is not the failed command, it is that the agent falls back to grep, the
#      grep works, and it never comes back.
#   2. THE GRAPH IS STALE BY DEFAULT. Measured 2026-09-06: built_at_commit 7c5bc10d
#      against a HEAD of f3ac46bb, dozens of commits behind. Per standing rule 19 a
#      stale answer is worse than no answer, because it answers the question -- so an
#      agent who DOES follow the instruction can be quietly misled, which teaches
#      exactly the wrong lesson about trusting the tool.
#
# ⇒ The freshness check is therefore the POINT of this script, not a nicety: it is what
#   makes "ask the graph" a command with a binary result instead of a disposition.
#   CLAUDE.md already draws that distinction -- "a rule asking for a DISPOSITION has now
#   failed twice; a rule asking you to RUN ONE COMMAND with a binary result is a
#   different instrument. Prefer the second whenever the question can be made
#   mechanical." This is that preference applied to the graph.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${GRAPHIFY_BIN:-$HOME/.local/share/graphify-venv/bin/graphify}"
JSON="$ROOT/graphify-out/graph.json"

[ -x "$BIN" ] || { echo "graphify not at $BIN — set GRAPHIFY_BIN"; exit 127; }

built=$(python3 -c "import json;print(json.load(open('$JSON')).get('built_at_commit','?')[:8])" 2>/dev/null || echo "?")
head=$(git -C "$ROOT" rev-parse --short HEAD)

if [ "${1:-}" = "--rebuild" ]; then
  # --force is required or a smaller rebuild is refused; --no-viz is not optional above
  # ~5,000 nodes and this graph has ~27,000.
  "$BIN" update "$ROOT" --force
  "$BIN" cluster-only "$ROOT" --no-label --no-viz
  # VERIFY BY READING THE FILE BACK, never by the run's own output: CLAUDE.md trap 4
  # records a rebuild that printed a new node count, returned truthy, updated mtime and
  # left a three-week-old graph in place.
  now=$(python3 -c "import json;print(json.load(open('$JSON')).get('built_at_commit','?')[:8])")
  echo "built_at_commit: $built -> $now   (HEAD $head)"
  [ "$now" = "$head" ] || { echo "🔴 REBUILD DID NOT TAKE — see CLAUDE.md trap 4"; exit 1; }
  exit 0
fi

if [ "$built" != "$head" ]; then
  cat >&2 <<EOF
🔴 GRAPH IS STALE: built_at_commit $built, HEAD $head.
   A stale graph ANSWERS THE QUESTION, which standing rule 19 makes worse than no graph
   -- a reader who finds nothing goes and measures; one who finds a confident wrong
   sentence stops. Structure that has not changed since $built is still reliable; a file
   touched since then is not.
   Refresh with:  tools/graph.sh --rebuild
   Proceeding anyway (set GRAPH_STRICT=1 to make this an error):
EOF
  [ "${GRAPH_STRICT:-0}" = "1" ] && exit 1
fi

# Pass through. Note `path` resolves an ambiguous name SILENTLY (CLAUDE.md trap 6) --
# pass a repo-relative path or a full node id for any name that exists in evm/, svm/
# and quid-ln/, which is most of the money-path names.
exec "$BIN" "$@"
