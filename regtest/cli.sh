#!/usr/bin/env bash
# Thin bitcoin-cli wrapper bound to the harness datadir + wallet.
# e.g.  ./cli.sh getblockcount   ./cli.sh getbalance   ./cli.sh -generate 1
set -euo pipefail
source "$(dirname "$0")/env.sh"
wcli "$@"   # `wcli` (node + wallet) lives in env.sh — one definition, every script
