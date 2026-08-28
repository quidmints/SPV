#!/usr/bin/env bash
# Build the passport verifiers that macOS cannot build, in a pinned Linux container.
#
#   ./build-passport-verifiers-docker.sh                 # the profiles listed below
#   ./build-passport-verifiers-docker.sh <name> [<name>] # specific profiles
#
# See passport-verifiers.Dockerfile for WHY these five cannot be built natively - it is a 2 GiB
# single-syscall limit on macOS, not a memory problem, and no RAM or swap setting reaches it.
#
# The CRS lives in a NAMED VOLUME so the ~2 GiB download happens once and survives container removal.
# The repo is mounted, so the generated .sol land straight in the working tree and show up in
# `git status` exactly as the natively-built ones do.
set -euo pipefail

CIRCUITS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CIRCUITS_DIR}/../.." && pwd)"
# No bb version in the tag: bb comes from the mounted repo, so the image only pins nargo.
IMAGE="ibiza-passport-verifiers:beta26"

# The profiles that need a 2^25-point CRS. Everything else builds natively; there is no reason to
# pay container startup and a re-download for them.
DEFAULT_PROFILES=(
  25_384_3_5_576_248_20_3768_3_2008
  26_512_3_3_336_248_NA
  26_512_3_3_336_264_1_1968_2_256
  27_512_3_4_336_248_NA
  28_384_3_3_576_264_24_2024_4_2792
)
if [ "$#" -gt 0 ]; then PROFILES=("$@"); else PROFILES=("${DEFAULT_PROFILES[@]}"); fi

command -v docker >/dev/null || { echo "docker is not on PATH" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "the docker daemon is not responding - is Docker Desktop running?" >&2; exit 1; }

# CHECK MEMORY BEFORE SPENDING TWENTY MINUTES ON IT. An under-provisioned VM does not fail cleanly,
# it gets the process OOM-killed - the same trap this project already hit with cargo under Docker.
# HOW MUCH MEMORY, MEASURED RATHER THAN GUESSED. bb's peak is set by the circuit's polynomials
# (2^25 field elements x 32 bytes each), so it does NOT respond to any scheduling knob. All of these
# were tried against a known-failing profile and NONE moved the peak off 11.2 GiB:
#   HARDWARE_CONCURRENCY=2   (bb honours it - "num threads: 2" - and the peak did not change)
#   BB_STORAGE_BUDGET        (no effect; an earlier claim that it halved memory was a false positive
#                             from comparing two DIFFERENT circuits)
#   --cpuset-cpus            (silently ignored - bb reads host CPU count, still reported 8 threads)
#   3 GiB of VM swap         (kernel OOM-killed with 2.7 GiB of it still FREE: the allocation
#                             outran reclaim, so swap does not rescue this)
#   pre-seeding a 2^25 CRS   (bb dies before it reaches the CRS)
# The kernel's own record is the authority: anon-rss:11690980kB, task=bb, global_oom.
#
# 72 of the 75 profiles build in a ~10 GiB VM. THREE DO NOT AND CANNOT HERE - they need roughly
# 13-14 GiB, which is not safe to allocate on a 16 GB host:
#   25_384_3_5_576_248_20_3768_3_2008, 27_512_3_4_336_248_NA, 28_384_3_3_576_264_24_2024_4_2792
# Those three want a bigger machine, not a different setting.
mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
mem_gib=$(( mem_bytes / 1073741824 ))
echo "Docker VM memory: ${mem_gib} GiB"
if [ "${mem_gib}" -lt 9 ]; then
  cat >&2 <<EOF

REFUSING TO START: the VM has ${mem_gib} GiB. Most profiles need ~10 GiB; the three named above need ~13-14.

  Docker Desktop -> Settings -> Resources -> Memory: ~10 GiB
  (or less memory plus 4 GiB of Swap - VM swap is a file on disk, so it costs disk, not host RAM)

That setting is GUI-only and cannot be scripted. Nothing has been built; rerun when it is raised.
EOF
  exit 1
fi

echo "building ${IMAGE} (cached after the first run)"
docker build --platform linux/amd64 -f "${CIRCUITS_DIR}/passport-verifiers.Dockerfile" -t "${IMAGE}" "${CIRCUITS_DIR}"

printf '%s\n' "${PROFILES[@]}" > "${CIRCUITS_DIR}/.docker-profiles.txt"
trap 'rm -f "${CIRCUITS_DIR}/.docker-profiles.txt"' EXIT

# SWAP THE GUI WILL NOT GIVE YOU (2026-08-03). Docker Desktop caps the swap slider at 4 GB, and
# `~/Library/Group Containers/group.com.docker/` is TCC-protected, so the setting cannot be scripted -
# a shell gets "Operation not permitted" even as its owner.
#
# BUT SWAP IS A KERNEL PROPERTY OF THE VM, NOT A DESKTOP SETTING. A privileged container can add a
# swapfile to that kernel, and every container then sees it. Measured: 3071 MB -> 5119 MB with a 2 GB
# file, on an ext4 volume with ~79 GB free. So the ceiling is disk, not the slider.
#
# It MUST live on a named volume: /tmp and the overlay root cannot host a swapfile, and `swapon`
# rejects them with the unhelpful "Invalid argument".
BB_SWAP_GB="${BB_SWAP_GB:-32}"

# MEMORY, AND THE LEVER THAT ACTUALLY EXISTS (found 2026-08-10, TODO sec. 2.18gn).
#
# bb 6.0 stores its polynomials in a FileBackedMemory arena with a fixed storage budget. Its own help:
#   --storage_budget    "Storage budget for FileBackedMemory (e.g. '500m', '2g'). When exceeded,
#                        falls back to RAM (REQUIRES --slow_low_memory)."
#   --slow_low_memory   "Enable low memory mode (can be 2x slower or more)."
#
# ⚠️ WITHOUT `--slow_low_memory` THERE IS NO FALLBACK, SO EXCEEDING THE BUDGET IS AN ASSERTION, NOT A
# SLOWDOWN: `Assertion failed: (aligned_local + bytes <= bound)`, thrown out of libc++abi with no
# mention of memory anywhere in the message. That is what blocked the two 2^25 profiles - it reads
# like a compiler or circuit defect and is neither. Swap does not help, because the bound is a fixed
# arena rather than exhaustible memory, which is why the 32 GiB swapfile below made no difference to
# them while it rescued the earlier OOM cases.
#
#   BB_SLOW_LOW_MEMORY=1 BB_STORAGE_BUDGET=8g ./build-passport-verifiers-docker.sh <profile>
#
# Both are passed through to the container below. Empty by default: low-memory mode is 2x slower or
# worse, so it is opt-in for the profiles that need it rather than on for all 78.

# CORES: all of them, and THREAD COUNT IS NOT THE LEVER - the table above already settled it.
# `HARDWARE_CONCURRENCY=2` was tried, bb honoured it ("num threads: 2"), and the peak did not move,
# because the peak is the circuit's polynomials (2^25 x 32 bytes each), not per-thread scratch.
# One refinement to the table, measured 2026-08-03: `--cpuset-cpus=0-1` DOES change what the
# container sees (`nproc` reports 2) whereas `--cpus=2` does not (still 8) - so the flag is not
# "silently ignored" at the container level. It changes nothing that matters, because the memory is
# not per-thread. BB_CPUSET is left available; do not expect it to rescue an OOM.
BB_CPUSET="${BB_CPUSET:-}"
CPUSET_ARG=()
[ -n "${BB_CPUSET}" ] && CPUSET_ARG=(--cpuset-cpus="${BB_CPUSET}")

docker volume create ibiza-swap >/dev/null

echo "building ${#PROFILES[@]} profile(s) in the container"
echo "  swap: ${BB_SWAP_GB} GiB on the ibiza-swap volume; cores: ${BB_CPUSET:-all}"

# --privileged is required for `swapon`, and is the whole reason it is here. This is a local build
# container over a mounted source tree; it signs nothing and holds no key.
docker run --rm --platform linux/amd64 \
  --privileged \
  ${CPUSET_ARG[@]+"${CPUSET_ARG[@]}"} \
  -v "${REPO_ROOT}":/repo \
  -v ibiza-bb-crs:/root/.bb-crs \
  -v ibiza-swap:/swap \
  -w /repo/backend/circuits \
  -e ONLY_FILE=/repo/backend/circuits/.docker-profiles.txt \
  -e BB_SLOW_LOW_MEMORY="${BB_SLOW_LOW_MEMORY:-}" \
  -e BB_STORAGE_BUDGET="${BB_STORAGE_BUDGET:-}" \
  -e BB_MSM_LEGACY="${BB_MSM_LEGACY:-}" \
  "${IMAGE}" \
  bash -lc '
    set -e
    # bb from the MOUNTED repo, not the image. The npm package ships a native linux binary; the
    # .bin/ shim needs node, so the platform binary is symlinked under a name on PATH instead.
    mkdir -p /tmp/bbbin
    ln -sf /repo/backend/circuits/node_modules/@aztec/bb.js/build/amd64-linux/bb /tmp/bbbin/bb
    export PATH=/tmp/bbbin:$PATH
    bb --version
    if [ ! -f /swap/bb.swap ] || [ "$(stat -c%s /swap/bb.swap)" -lt "$(( '"${BB_SWAP_GB}"' * 1024 * 1024 * 1024 ))" ]; then
      echo "allocating '"${BB_SWAP_GB}"' GiB swapfile (once; it persists in the volume)"
      rm -f /swap/bb.swap
      fallocate -l '"${BB_SWAP_GB}"'G /swap/bb.swap
      chmod 600 /swap/bb.swap
      mkswap /swap/bb.swap >/dev/null
    fi
    swapon /swap/bb.swap 2>/dev/null || true
    echo "memory now:"; free -g | head -3
    ./codegen-passport-verifiers.sh
  '

echo
echo "NEXT, on the host:"
echo "  python3 <scratch>/validate_passport_verifiers.py   # structural checks over the whole set"
echo "  cd ../contracts && forge build --sizes && forge test"
