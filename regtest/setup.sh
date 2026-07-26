#!/usr/bin/env bash
# Download a pinned, checksum-verified bitcoin-core into ./.bitcoin-core/.
# No sudo, no system install — everything stays under regtest/. Idempotent.
set -euo pipefail
source "$(dirname "$0")/env.sh"

if [ -x "$BITCOIND" ]; then
  echo "bitcoind already present: $("$BITCOIND" --version | head -1)"
  exit 0
fi

case "$(uname -m)" in
  x86_64|amd64)   ARCH="x86_64-linux-gnu" ;;
  aarch64|arm64)  ARCH="aarch64-linux-gnu" ;;
  *) echo "unsupported arch $(uname -m) — install bitcoin-core $BITCOIN_VERSION manually into $CORE_DIR" >&2; exit 1 ;;
esac

TARBALL="bitcoin-$BITCOIN_VERSION-$ARCH.tar.gz"
BASE="https://bitcoincore.org/bin/bitcoin-core-$BITCOIN_VERSION"
mkdir -p "$HARNESS_DIR/.bitcoin-core"
cd "$HARNESS_DIR/.bitcoin-core"

echo "downloading $TARBALL (~40MB) ..."
curl -fsSLO "$BASE/$TARBALL"
curl -fsSLO "$BASE/SHA256SUMS"

echo "verifying SHA256 ..."
grep " $TARBALL\$" SHA256SUMS | sha256sum -c -

tar -xzf "$TARBALL"
rm -f "$TARBALL" SHA256SUMS
echo "installed: $("$BITCOIND" --version | head -1)"
