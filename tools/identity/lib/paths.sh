# Shell half of `lib/paths.js` — same three directories, same reason. See that file's header.
# Source it, do not re-derive: `SOURCE_DIR/../..` is a count that rotted once already.
_QUID_PATHS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${_QUID_PATHS_DIR}/../../.." && pwd)"
CONTRACTS_DIR="${ROOT}/evm"
FIXTURES_DIR="${ROOT}/evm/test/identity/fixtures"
CIRCUITS_DIR="${ROOT}/evm/noir"
