#!/usr/bin/env bash
# Regenerate the passport registration verifiers (NoirRegisterIdentity_*.sol) on OUR toolchain.
#
# WHY THIS EXISTS. The 76 committed `contracts/passport/verifiers2/noir/NoirRegisterIdentity_*.sol`
# arrived with the fork import and were built by rarimo on **noir 1.0.0-beta.1** (read from their own
# artifacts, not assumed). A verifier is generated from a circuit's VK, the VK follows the constraint
# system, and the constraint system follows the compiler - so those verifiers do not accept proofs
# produced by our patched beta.26. They must be rebuilt here, and nothing did that.
#
# WHY IT WAS THOUGHT IMPOSSIBLE, AND WHY IT IS NOT. Each profile is an instantiation of
# `noir_dl::not_passports_zk_circuits::register_identity` with FOURTEEN generic arguments, five of
# which (EC_LEN, SA_LEN, DG15_LEN, N, plus the exact DG1_LEN) are DER byte lengths of a real
# passport. The file names carry only some of them, and only as 64-byte buckets, so they cannot be
# inverted - which is why this looked like it needed 76 physical documents.
#
# IT NEEDS NONE. Every compiled Noir artifact embeds its own sources in `file_map` for debugging, so
# rarimo's published `registerIdentity_*.json` release assets each contain the exact `main.nr` they
# were built from - the full 14-tuple and the circuit's own `//name` comment, verbatim. The tuples in
# `passport-profiles.json` were read out of those artifacts. No document was used, and none is needed.
#
# THE MANIFEST IS THE INPUT, and it quarantines what it cannot vouch for: three published assets
# embed a DIFFERENT circuit than their file name claims (one is a byte-identical duplicate of another
# profile). Regenerating those from their artifacts would emit a verifier that rejects every proof
# for that profile, silently, so they are held back rather than guessed at.
#
# TOOLCHAIN: the same guard as codegen-verifiers.sh - nargo 1.0.0-beta.26+quid-icefix1 and the bb
# with `~/.bb` on PATH. Stock beta.26 ICEs on this dependency tree; that is what the patch is for.
#
#   ./codegen-passport-verifiers.sh              # every clean profile
#   ./codegen-passport-verifiers.sh 1_256_3_4    # only profiles whose name contains this
set -euo pipefail

CIRCUITS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${CIRCUITS_DIR}/passport-profiles.json"
DEST="${CIRCUITS_DIR}/../contracts/contracts/passport/verifiers2/noir"
WORK="${CIRCUITS_DIR}/.passport-build"
# Where each profile's verification key is kept, so a template-only regeneration never pays for
# write_vk twice. Committed: they are small, they are the expensive artifact, and they are stable
# across bb versions in a way the generated Solidity is not.
VK_DEST="${CIRCUITS_DIR}/passport-vks"
FILTER="${1:-}"

# BOTH COMPILERS ARE ACCEPTED HERE, AND ONLY HERE, BECAUSE IT WAS MEASURED. The passport profile
# crates compile on STOCK beta.26 as well as on our patched build - that is exactly why the
# BigNumParams accommodation was kept in noir_dl_lib - and the two produce a BYTE-IDENTICAL compiled
# artifact for these circuits (md5 8ea5345bad87c71a45808ae4b6179c99 either way, checked 2026-08-03 on
# 25_384_3_5_576_248_20_3768_3_2008). The patch fixes an ICE; where there is no ICE there is no
# difference. This matters because the largest profiles cannot be built on macOS at all (bb does
# whole-file CRS I/O in one syscall and macOS caps that at INT_MAX), so they are built in Linux
# containers carrying stock nargo. The bb pin is NOT relaxed - a different bb changes the VK.
REQUIRED_NARGO="1.0.0-beta.26+quid-icefix1"
STOCK_NARGO="1.0.0-beta.26"
# See codegen-verifiers.sh for why two versions are accepted: their EVM verification keys are
# byte-identical, so nothing already generated needs regenerating, and 6.0.0-nightly is needed only
# for the IVC/chonk path, which 5.1.0 cannot build at all.
REQUIRED_BB="6.0.0-nightly.20260804"
actual_nargo="$(nargo --version 2>/dev/null | sed -n 's/^nargo version = //p' | head -1)"
actual_bb="$(bb --version 2>/dev/null | head -1)"
if { [ "${actual_nargo}" != "${REQUIRED_NARGO}" ] && [ "${actual_nargo}" != "${STOCK_NARGO}" ]; } \
   || [ "${actual_bb}" != "${REQUIRED_BB}" ]; then
  echo "TOOLCHAIN MISMATCH - refusing to emit verifiers." >&2
  echo "  nargo required ${REQUIRED_NARGO} (or stock ${STOCK_NARGO})  found '${actual_nargo:-<not on PATH>}'" >&2
  echo "  bb    required ${REQUIRED_BB}  found '${actual_bb:-<not on PATH>}'" >&2
  echo "  (bb lives in ~/.bb, which is not on PATH by default)" >&2
  exit 1
fi

# ONLY_FILE lets a caller name profiles EXACTLY, one per line. The substring FILTER is convenient
# but unsafe for scripted batches - "1_256_3_3_576_248_NA" is a substring of
# "11_256_3_3_576_248_NA", so a filter meant for one profile silently builds two.
if [ -n "${ONLY_FILE:-}" ]; then
  names=$(python3 -c "
import json
m=json.load(open('${MANIFEST}'))['profiles']
want=[l.strip() for l in open('${ONLY_FILE}') if l.strip()]
missing=[w for w in want if w not in m]
if missing: raise SystemExit('not in manifest: %s' % missing[:3])
print('\n'.join(want))")
else
names=$(python3 -c "
import json,sys
m=json.load(open('${MANIFEST}'))
f='${FILTER}'
print('\n'.join(n for n in m['profiles'] if not f or f in n))")
fi

[ -n "${names}" ] || { echo "no profiles matched '${FILTER}'" >&2; exit 1; }
echo "profiles to build: $(echo "${names}" | wc -l | tr -d ' ')"

mkdir -p "${WORK}/src"
rm -f "${WORK}/failures.txt"
cat > "${WORK}/Nargo.toml" <<'TOML'
[package]
name = "register_identity_profile"
type = "bin"
authors = [""]

[dependencies]
noir_dl = { path = "../noir_dl_lib" }
TOML

built=0
for name in ${names}; do
  echo "=== ${name} ==="

  # main.nr is written from the manifest tuple - the same shape rarimo's own generator emits, minus
  # its `test_main` module, which needs witness inputs we deliberately do not have.
  python3 - "${name}" "${MANIFEST}" > "${WORK}/src/main.nr" <<'PY'
import json,sys
name,man=sys.argv[1],sys.argv[2]
g=json.load(open(man))['profiles'][name]['generics']
order=["DG1_LEN","DG15_LEN","EC_LEN","SA_LEN","N","EC_FIELD_SIZE","DG_HASH_ALGO","HASH_ALGO",
       "SIG_TYPE","DG1_SHIFT","DG15_SHIFT","EC_SHIFT","AA_SIG_TYPE","AA_SHIFT"]
v={k:g[k] for k in order}
# A ZERO-LENGTH ARRAY CANNOT BE A main() PARAMETER on beta.26 - "Invalid entry point type: [u8; 0]".
# rarimo's beta.1 sources declare `dg15: [u8; 0]` for every profile without Active Authentication
# (33 of the 75), so their main.nr cannot be reproduced verbatim on our compiler. Our own
# register_identity crate already solved this: omit the parameter and bind an empty local, which
# leaves the CIRCUIT identical because DG15_LEN is a generic either way - the array carries no data.
dg15_param = "" if v['DG15_LEN']==0 else f"\n\tdg15: [u8; {v['DG15_LEN']}],"
dg15_local = "\tlet dg15: [u8; 0] = [];\n" if v['DG15_LEN']==0 else ""
print(f"""//registerIdentity_{name}
use noir_dl::not_passports_zk_circuits::register_identity;

fn main(
\tdg1: [u8; {v['DG1_LEN']}],{dg15_param}
\tec: [u8; {v['EC_LEN']}],
\tsa: [u8; {v['SA_LEN']}],
\tpk: [Field; {v['N']}],
\treduction_pk: [Field; {v['N']}],
\tsig: [Field; {v['N']}],
\tsk_identity: Field,
\ticao_root: Field,
\tinclusion_branches: [Field; 80]) -> pub (Field, Field, Field, Field, Field){{
{dg15_local}\tlet tmp = register_identity::<{', '.join(str(v[k]) for k in order)}>(
\tdg1, dg15, ec, sa, pk, reduction_pk, sig, sk_identity, icao_root, inclusion_branches);
\t(tmp.0, tmp.1, tmp.2, tmp.3, icao_root)
}}""")
PY

  # CONTINUE-ON-FAILURE, deliberately, and only for the CRS ceiling described below. Every failure
  # is recorded and re-reported at the end: a pass that stops at the first blocked profile cannot
  # tell you how many others are fine, and silently skipping them would be worse than either.
  if ! ( cd "${WORK}" && nargo compile ); then
    # REPORT AT THE MOMENT OF FAILURE, not only in the summary. A failure recorded silently and
    # printed 20 minutes later reads, in a live log, exactly like success.
    echo "!! FAILED_COMPILE ${name}" | tee -a "${WORK}/failures.txt" >&2; continue
  fi
  artifact="${WORK}/target/register_identity_profile.json"
  [ -f "${artifact}" ] || { echo "ERROR: ${name} produced no artifact" >&2; exit 1; }

  # bb cannot materialise a CRS larger than 2^24 points on macOS: it writes the decompressed
  # bn254_g1.dat in ONE call, and a single write of exactly 2 GiB fails with EINVAL ("Invalid
  # argument"). That is a host limitation, not a circuit or parameter problem - the same profile
  # builds on Linux, or on any host where ~/.bb-crs/bn254_g1.dat already exists (bb reads it and
  # never writes). Reproduced with a cleared cache, twice.
  if ! ( cd "${WORK}" && bb write_vk -t evm -b "${artifact}" -o target ); then
    # REPORT AT THE MOMENT OF FAILURE, not only in the summary. A failure recorded silently and
    # printed 20 minutes later reads, in a live log, exactly like success.
    echo "!! FAILED_WRITE_VK ${name}" | tee -a "${WORK}/failures.txt" >&2; continue
  fi
  out="${DEST}/NoirRegisterIdentity_${name}.sol"
  ( cd "${WORK}" && bb write_solidity_verifier -t evm -k target/vk -o "${out}" )

  # KEEP THE KEY. `write_vk` is the entire cost of this script - it is what needs 32 GiB of container
  # swap for the heavy profiles - and `write_solidity_verifier` is a seconds-long reformat of it.
  # ${WORK} holds ONE key slot that every profile overwrites, so before this the keys were discarded
  # and re-emitting a verifier meant paying the 32 GiB again.
  #
  # THE KEY IS WHAT SURVIVES A bb BUMP AND THE VERIFIER IS NOT. Measured: `write_vk -t evm` gives a
  # BYTE-IDENTICAL key under 5.1.0 and 6.0 (2.18ef), while the emitted Solidity moved 2,491 -> 2,518
  # lines with 99 lines differing. So a future toolchain bump only needs the templates re-emitted
  # from these keys, and that is seconds per profile with no swap and no container.
  mkdir -p "${VK_DEST}"
  cp "${WORK}/target/vk" "${VK_DEST}/${name}.vk"

  # bb emits every verifier as `HonkVerifier`; both flavours are handled, and an unrenamed file is a
  # hard failure rather than a silent collision with every other verifier in the project.
  # PORTABLE RENAME. `sed -i ''` is BSD syntax and GNU sed reads the '' as a FILENAME, so the macOS
  # form silently fails on Linux - where the heavy profiles have to be built. python3 behaves
  # identically on both, and this script now runs in both places.
  python3 - "${out}" "NoirRegisterIdentity_${name}" <<'PYRENAME'
import sys
path,new=sys.argv[1],sys.argv[2]
s=open(path).read()
if 'contract HonkVerifier is' in s:
    open(path,'w').write(s.replace('contract HonkVerifier is', f'contract {new} is', 1))
PYRENAME
  grep -q "contract NoirRegisterIdentity_${name} is" "${out}" || {
    echo "ERROR: ${name} verifier was not renamed - refusing to leave a colliding contract" >&2
    exit 1
  }
  built=$((built+1))
done

echo
echo "regenerated ${built} passport verifiers into ${DEST}"
if [ -s "${WORK}/failures.txt" ]; then
  echo
  echo "!! $(wc -l < "${WORK}/failures.txt" | tr -d ' ') PROFILES DID NOT BUILD - their .sol is UNCHANGED:"
  cat "${WORK}/failures.txt"
  exit 1
fi
echo "NEXT: forge build --sizes   (EIP-170 is 24,576 bytes and these are close to it)"
