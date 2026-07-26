#!/usr/bin/env bash
#
# EIP-170 runtime-bytecode size gate for the QU!D Solidity contracts.
#
# WHY THIS EXISTS
# ---------------
# A contract whose *deployed* (runtime) bytecode exceeds the EIP-170 limit of
# 24,576 bytes is undeployable on Ethereum mainnet — the CREATE/CREATE2 simply
# reverts. The catch: `forge test` runs on an EVM that does NOT enforce EIP-170,
# so an oversize contract sails through the whole test suite and only blows up at
# real deployment. This script is the regression guard the team flagged as
# missing: it parses `forge build --sizes --json` and FAILS (non-zero exit) if
# ANY contract's runtime size is over the limit.
#
# We deliberately do not lean on `forge build --sizes` exit codes: at time of
# writing `forge` only WARNS on oversize unless extra flags are set, and the warn
# path is easy to regress. Parsing the JSON ourselves is the durable contract.
#
# USAGE
#   evm/scripts/ci/check-sizes.sh                # threshold 24576 (EIP-170)
#   EIP170_LIMIT=1000 evm/scripts/ci/check-sizes.sh   # lower it to test the fail path
#
# Must be run from the foundry project root (the dir with foundry.toml), or it
# will cd to the script's ../../ (the evm/ root) on its own.
set -euo pipefail

LIMIT="${EIP170_LIMIT:-24576}"

# Resolve the foundry project root (evm/) relative to this script so the gate
# works regardless of the caller's cwd (CI, local, etc).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

if ! command -v forge >/dev/null 2>&1; then
  echo "ERROR: forge not found on PATH" >&2
  exit 2
fi

echo "EIP-170 size gate: limit=${LIMIT} bytes (runtime)  project=${PROJECT_ROOT}"

# `forge build --sizes --json` emits a single JSON object on stdout:
#   { "ContractName": { "runtime_size": N, "init_size": N, ... }, ... }
# It also streams `forge lint` diagnostics as JSON lines to STDERR, which is just
# noise for this gate — drop it so CI logs stay readable. A genuine build failure
# still propagates via the non-zero exit (set -e / pipefail) and the build-only
# `forge build` step that runs ahead of this in CI surfaces compiler errors.
SIZES_JSON="$(forge build --sizes --json 2>/dev/null)"

# Parse + gate in python3 (robust: handles the object shape, missing keys, and
# prints a sorted table + an explicit list of any violators).
EIP170_LIMIT="${LIMIT}" python3 - "$SIZES_JSON" <<'PY'
import json
import os
import sys

limit = int(os.environ["EIP170_LIMIT"])
data = json.loads(sys.argv[1])

if not isinstance(data, dict):
    print(f"ERROR: unexpected forge --json shape: {type(data).__name__}", file=sys.stderr)
    sys.exit(2)

rows = []
for name, info in data.items():
    if not isinstance(info, dict):
        continue
    rt = info.get("runtime_size")
    if rt is None:
        continue
    rows.append((name, int(rt)))

if not rows:
    print("ERROR: no contracts with runtime_size found in forge output", file=sys.stderr)
    sys.exit(2)

rows.sort(key=lambda r: r[1], reverse=True)
violators = [(n, s) for (n, s) in rows if s > limit]

# Show the top of the table so the log is useful even on success.
print(f"{'contract':<40} {'runtime':>9} {'margin':>9}")
for name, size in rows[:15]:
    print(f"{name:<40} {size:>9} {limit - size:>9}")
if len(rows) > 15:
    print(f"... ({len(rows) - 15} more under limit)")

if violators:
    print("", file=sys.stderr)
    print(f"EIP-170 VIOLATION: {len(violators)} contract(s) exceed {limit} bytes runtime:", file=sys.stderr)
    for name, size in violators:
        print(f"  - {name}: {size} bytes (+{size - limit} over)", file=sys.stderr)
    print("", file=sys.stderr)
    print("Fix by extracting code into libraries (libs have headroom) — do NOT", file=sys.stderr)
    print("toggle via_ir/optimizer to work around it.", file=sys.stderr)
    sys.exit(1)

print(f"\nOK: all {len(rows)} contracts within EIP-170 limit ({limit} bytes).")
PY
