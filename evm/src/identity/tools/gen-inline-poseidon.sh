#!/usr/bin/env bash
# Regenerate contracts/libraries/inline/PoseidonT*Inline.sol from lib/poseidon-solidity.
# THREE mechanical edits; the arithmetic is untouched. See the generated headers for why each is
# required. ALWAYS run: forge test --match-contract PoseidonInlineDifferentialTest
# That suite MUST call the libraries from a caller with pre-allocated memory - testing them in
# isolation puts the array at 0x80 by luck and certifies a broken library (this happened).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 tools/gen_inline_poseidon.py
