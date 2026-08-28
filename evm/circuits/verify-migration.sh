#!/usr/bin/env bash
# Verify a toolchain/dependency migration against MIGRATION-BASELINE.txt.
#
# WHY THIS EXISTS. A migration can pass every casual check while silently losing coverage: a test
# that is RENAMED or fails to COMPILE simply stops running, and "N tests passed" still looks green
# with a smaller N. That is not hypothetical here - the documented count for noir_dl_lib was 49 when
# the real roster is 80, so a 49-passing gate would have accepted the loss of 31 tests.
#
# So this compares test NAMES, set-wise, and fails on ANY name present in the baseline and absent now.
# It also reports ADDED names (not a failure, but they must be intentional) and re-checks source
# checksums to produce the exhaustive list of files needing a literal-by-literal diff.
#
# Usage:  ./verify-migration.sh          (run from backend/circuits, after migrating)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
B=MIGRATION-BASELINE.txt
[ -f "$B" ] || { echo "FATAL: $B missing - the baseline cannot be recreated after migrating."; exit 1; }

fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

for crate in pp noir_dl_lib; do
  echo "== $crate"
  (cd "$crate" && nargo test 2>&1) | sed 's/\x1b\[[0-9;]*m//g' > "$tmp/$crate.out"
  grep -oE 'Testing [^ ]+ \.\.\.' "$tmp/$crate.out" | sed 's/Testing //; s/ \.\.\.//' | sort -u > "$tmp/$crate.now"
  awk "/^## $crate test roster/{f=1;next} /^## /{f=0} f&&/^  [a-zA-Z]/{gsub(/^  /,\"\");print}" "$B" \
    | grep -v '^TOTAL' | sort -u > "$tmp/$crate.base"

  missing=$(comm -23 "$tmp/$crate.base" "$tmp/$crate.now")
  added=$(comm -13 "$tmp/$crate.base" "$tmp/$crate.now")
  if [ -n "$missing" ]; then
    echo "   ❌ TESTS SILENTLY DROPPED ($(echo "$missing"|wc -l|tr -d ' ')):"
    echo "$missing" | sed 's/^/      /'
    fail=1
  fi
  [ -n "$added" ] && { echo "   ⚠️  new tests (confirm intentional):"; echo "$added" | sed 's/^/      /'; }

  if grep -q "test failed\|tests failed\|error:" "$tmp/$crate.out"; then
    echo "   ❌ FAILURES OR COMPILE ERRORS - a test that does not compile does not run:"
    grep -E "^\[.*\] Testing .* FAIL|error:" "$tmp/$crate.out" | head -8 | sed 's/^/      /'
    fail=1
  fi
  [ -z "$missing" ] && ! grep -q "error:" "$tmp/$crate.out" && \
    echo "   ✅ all $(wc -l < "$tmp/$crate.base" | tr -d ' ') baseline tests present and green"
done

echo "== source files whose contents changed (each needs a literal-by-literal diff vs git)"
changed=0
while read -r h f; do
  [ -f "$f" ] || { echo "   ❌ DELETED: $f"; fail=1; continue; }
  n=$(shasum -a 256 "$f" | cut -c1-16)
  [ "$n" = "$h" ] || { echo "   ~ $f"; changed=$((changed+1)); }
done < <(grep -E "^  [0-9a-f]{16}  " "$B" | sed 's/^  //')
echo "   ($changed changed - expected for a type migration; diff each for NUMERIC literal changes)"

echo
[ $fail -eq 0 ] && echo "RESULT: no coverage lost." || echo "RESULT: ❌ MIGRATION NOT VERIFIED."
exit $fail
