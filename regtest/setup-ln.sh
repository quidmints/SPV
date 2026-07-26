#!/usr/bin/env bash
# Download LND (lnd + lncli static binaries) into ./.lnd-dist/. No build, no deps.
set -euo pipefail
source "$(dirname "$0")/env.sh"

if [ -x "$LND" ]; then echo "lnd already present: $("$LND" --version)"; exit 0; fi
command -v jq >/dev/null || { echo "jq is required (apt install jq / brew install jq)" >&2; exit 1; }

T="lnd-$LND_PLAT-$LND_VERSION.tar.gz"   # LND_PLAT: env.sh platform table
mkdir -p "$HARNESS_DIR/.lnd-dist"; cd "$HARNESS_DIR/.lnd-dist"
echo "downloading $T (~44MB) ..."
curl -fsSLO "https://github.com/lightningnetwork/lnd/releases/download/$LND_VERSION/$T"
tar -xzf "$T"; rm -f "$T"
echo "installed: $("$LND" --version)"
