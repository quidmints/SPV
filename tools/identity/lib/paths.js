/*
 * ONE ANSWER TO "WHERE DOES THE IDENTITY STACK LIVE", because there were THREE.
 *
 * The identity fold (`1624ee30`) moved the sources to `evm/src/identity`, the tests to
 * `evm/test/identity`, the fixtures to `evm/test/identity/fixtures` and the circuits to
 * `evm/noir`. Nothing that WRITES those fixtures was re-pathed, so as of 2026-08-29:
 *
 *   the readers (19 .sol files)  said  test/fixtures/…                 (fixed, §IDENTITY-FIXTURE-PATHS)
 *   evm/noir/codegen-verifiers.sh said  evm/src/identity/../test/fixtures  = evm/src/test/fixtures
 *   tools/identity/*.{js,sh}     said  tools/backend/contracts/test/fixtures
 *
 * Three components, three different opinions, and only the files themselves were right. Each was
 * a plausible reading of a layout that no longer exists, and none of them errors in a way that
 * names the cause — a generator writes its output happily into a directory it just created.
 *
 * ⇒ THE POINT OF THIS MODULE IS THAT THERE CANNOT BE A FOURTH. Import it; do not re-derive a path
 *   with `path.join(__dirname, '..', …)`, because the number of `..`s is a function of where the
 *   caller sits and that is exactly what rotted.
 */
const path = require('path');

// `tools/identity/lib/paths.js` → up three to the repo root. This is the ONLY place that count
// appears, which is the whole idea.
const ROOT = path.resolve(__dirname, '..', '..', '..');

module.exports = {
  ROOT,
  /** Solidity sources + tests (`forge` runs with this as its cwd). */
  CONTRACTS_DIR: path.join(ROOT, 'evm'),
  /** Where every committed proof / witness / params fixture lives. */
  FIXTURES_DIR:  path.join(ROOT, 'evm', 'test', 'identity', 'fixtures'),
  /** Noir packages: `<CIRCUITS_DIR>/<name>/Nargo.toml`. */
  CIRCUITS_DIR:  path.join(ROOT, 'evm', 'noir'),
};
