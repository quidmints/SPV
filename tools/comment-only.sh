#!/usr/bin/env bash
# Gate for a comments-only edit. Exits non-zero the moment a file fails.
#
# WHY THIS EXISTS RATHER THAN AN EYEBALL: the obvious check (compare brace counts)
# gives a FALSE ALARM whenever a comment contains a brace — a set literal like
# `{syncLev, bandPrice}` inside prose moved Interfaces.sol's count 49 -> 48 with
# zero code changed. And the obvious fix (diff the comment-stripped files) gives a
# false alarm the other way, because deleting a comment-only line also deletes the
# blank line stripping would have left behind. So: strip comments, drop blank
# lines, and require byte identity. That is the only form that is right both ways.
#
# Comment-only edits need no build here: foundry.toml sets bytecode_hash = "none"
# and cbor_metadata = false, so the deployed bytecode is unchanged by construction.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
REF="${REF:-HEAD}"
fail=0

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  mapfile -t files < <(git diff --name-only "$REF" -- '*.sol' '*.rs')
fi
[ ${#files[@]} -eq 0 ] && { echo "no .sol/.rs changes vs $REF"; exit 0; }

strip() {   # comments out, blank lines out
  perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//.*$}{}gm' | grep -v '^[[:space:]]*$'
}

for f in "${files[@]}"; do
  [ -f "$f" ] || { printf '%-46s SKIP (gone)\n' "$f"; continue; }
  if ! git cat-file -e "$REF:$f" 2>/dev/null; then
    printf '%-46s SKIP (new file)\n' "$f"; continue
  fi
  a=$(git show "$REF:$f" | strip)
  b=$(strip < "$f")
  if [ "$a" == "$b" ]; then
    printf '%-46s OK   %s\n' "$f" "$(git diff --numstat "$REF" -- "$f" | awk '{print "+"$1" -"$2}')"
  else
    printf '%-46s FAIL — code changed:\n' "$f"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -20
    fail=1
  fi
done
exit $fail
