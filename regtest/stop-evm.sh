#!/usr/bin/env bash
# Stop the demo anvil EVM.
set -uo pipefail
if pkill -f "anvil --port 8545"; then echo "stopped anvil"; else echo "anvil not running"; fi
