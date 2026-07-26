#!/usr/bin/env bash
#
# Reproducible SGX enclave build → MRENCLAVE measurement (+ signing-toolchain smoke).
#
# WHY: the on-chain AttestedHopRegistry pins a whitelist of MRENCLAVE values; this
# script is how anyone proves "the pinned measurement == a build of the published
# commit" (and how CI catches SGX-fork / toolchain drift silently rotting the build).
#
# HARDWARE-FREE: build + .sgxs conversion + MRENCLAVE hash need NO SGX silicon —
# MRENCLAVE is a pure hash of the .sgxs layout. So this runs on a stock CI runner.
# The DCAP/attestation SMOKE (generating a real quote) DOES need SGX and lives in a
# separate, runner-gated job (see .github/workflows/enclave.yml) — NOT here.
#
# STATUS: authored 2026-07-25; the parsing step is locally verified, but the SGX
# build/elf2sgxs/sgxs-hash chain is VALIDATED ON FIRST CI RUN (no SGX toolchain on
# the author's box). Treat a first-run failure as a flag-tuning task, not a bug in
# intent.
set -euo pipefail

# Run from the SPV repo root regardless of cwd, then enter the Cargo workspace
# (quid-ln/) so its .cargo/config.toml — which supplies the mandatory SGX rustflags
# + the `-U_FORTIFY_SOURCE` CFLAG (secp256k1-sys __memcpy_chk link fix) — applies.
cd "$(dirname "$0")/../.."
cd quid-ln

CRATE=quid-bridge                      # the daemon crate IS the enclave ([package.metadata.fortanix-sgx])
CARGO_TOML="${CRATE}/Cargo.toml"
TARGET=x86_64-fortanix-unknown-sgx
PROFILE=release                        # prod-representative (not the dev debug build)

# Pull the enclave params from the SINGLE SOURCE OF TRUTH (the crate's
# [package.metadata.fortanix-sgx]) so the CI measurement can never silently drift
# from what prod actually signs. Values may be hex (0x..) or decimal; normalise to
# decimal via bash arithmetic, exactly as the repo's run-sgx-cargo passes them.
meta() { grep -E "^$1" "$CARGO_TOML" | head -1 | sed -E 's/[^=]*=[[:space:]]*([0-9xa-fA-F_]+).*/\1/' | tr -d '_'; }
HEAP=$((    $(meta 'heap-size')    ))
SSA=$((     $(meta 'ssaframesize') ))
STACK=$((   $(meta 'stack-size')   ))
THREADS=$(( $(meta 'threads')      ))
echo "enclave params (from ${CARGO_TOML}): heap=${HEAP} ssaframesize=${SSA} stack=${STACK} threads=${THREADS}"

echo "== [1/4] build the enclave (nightly SGX target; .cargo/config supplies rustflags + CFLAGS) =="
cargo +nightly build --"${PROFILE}" --target "${TARGET}" -p "${CRATE}"

ELF="target/${TARGET}/${PROFILE}/${CRATE}"
SGXS="target/${TARGET}/${PROFILE}/${CRATE}.sgxs"

echo "== [2/4] ELF → .sgxs  (ftxsgx-elf2sgxs; PROD measurement ⇒ NO --debug) =="
# The dev runner (run-sgx-cargo) passes --debug; PROD enclaves are signed NON-debug
# (deploy/PRODUCTION-LAUNCH.md). We deliberately omit --debug so this MRENCLAVE is
# the PROD measurement the registry whitelist should pin.
ftxsgx-elf2sgxs "${ELF}" --output "${SGXS}" \
  --heap-size    "${HEAP}" \
  --ssaframesize "${SSA}" \
  --stack-size   "${STACK}" \
  --threads      "${THREADS}"

echo "== [3/4] MRENCLAVE = sgxs-hash(.sgxs) — the value the AttestedHopRegistry whitelist pins =="
MRENCLAVE="$(sgxs-hash "${SGXS}")"
echo "MRENCLAVE=${MRENCLAVE}"
echo "${MRENCLAVE}" > "$(dirname "$0")/../../mrenclave.txt"
# Reproducibility gate: if the caller pins an expected measurement (a committed
# value or a var), FAIL on any mismatch — that is the whole point of the pipeline.
if [[ -n "${EXPECTED_MRENCLAVE:-}" ]]; then
  if [[ "${MRENCLAVE}" != "${EXPECTED_MRENCLAVE}" ]]; then
    echo "!! MRENCLAVE MISMATCH: got ${MRENCLAVE}, expected ${EXPECTED_MRENCLAVE}" >&2
    exit 1
  fi
  echo "MRENCLAVE matches the pinned value — reproducible."
fi

echo "== [4/4] signing-toolchain smoke (host-only; proves quid-sgxs-sign builds + runs) =="
# Generates a throwaway RSA-3072(exp=3) SIGSTRUCT signing key + prints its MRSIGNER;
# validates the SIGSTRUCT path compiles end-to-end. NOT the prod key (that stays
# offline/HSM). Real signing of the .sgxs with the prod key is a deploy step.
cargo run -p quid-sgxs-sign --bin gen-signer -- /tmp/ci-sgxs-signer.der

echo "OK: enclave measurement pipeline green (build + .sgxs + MRENCLAVE + sign smoke)."
