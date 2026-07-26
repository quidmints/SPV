#!/usr/bin/env bash
# Run a QU!D liquidity provider (quid-lp-daemon): an LN node connected to the
# hop + the lpAuth responder. Usage: deploy/run-lp.sh [env-file]
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$REPO/deploy/lp.env}"

[ -f "$ENV_FILE" ] || { echo "env file not found: $ENV_FILE (copy deploy/lp.env.example)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

cd "$REPO/quid-ln"
echo "[run-lp] building quid-lp-daemon (release)" >&2
cargo build --release -p quid-bridge --bin quid-lp-daemon
exec ./target/release/quid-lp-daemon
