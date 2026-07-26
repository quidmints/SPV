#!/usr/bin/env bash
# Run the QU!D hop (quid-bridge-daemon). Usage: deploy/run-hop.sh [env-file]
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$REPO/deploy/hop.env}"

[ -f "$ENV_FILE" ] || { echo "env file not found: $ENV_FILE (copy deploy/hop.env.example)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

cd "$REPO/quid-ln"
echo "[run-hop] building quid-bridge-daemon (release)" >&2
cargo build --release -p quid-bridge --bin quid-bridge-daemon
exec ./target/release/quid-bridge-daemon
