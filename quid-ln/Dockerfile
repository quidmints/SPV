# quid-ln Linux toolchain — the ONLY way this workspace builds.
#
# `quid-cvm` is Linux-only and TRANSITIVE, so `cargo` cannot build quid-ln on macOS at all.
# This image is what makes the Rust suite (and `testCrossChain_FullE2E`) runnable from a Mac.
#
#   build:  docker build -t quid-ln:dev quid-ln
#   test:   docker run --rm --sysctl net.ipv6.conf.all.disable_ipv6=0 \
#             -v "$PWD/quid-ln":/w -w /w quid-ln:dev
#
# ⚠️ `--sysctl net.ipv6.conf.all.disable_ipv6=0` is REQUIRED and cannot be baked in — sysctls are a
#    RUNTIME flag. Six `p2p` tests bind `[::1]:0` and fail `AddrNotAvailable` without it. That is the
#    container, not the code: re-running those six WITH the flag passes 6/6. Verified 2026-08-02.
#
# ⚠️ MEMORY. Docker Desktop's VM defaults near 2 GB (`docker info` MemTotal). That is a VM
#    allocation, NOT host free RAM, so closing host apps does nothing — raise it in
#    Settings → Resources → Memory. Below ~4 GB, `rustc` is OOM-killed with NO diagnostic (just
#    "process didn't exit successfully"), which reads exactly like a compile error and is not one.
#    The ENV defaults below keep a 2 GB VM working; delete them once the VM has 6-8 GB.

FROM rust:1.90

# Pinned to `quid-ln/rust-toolchain.toml` (channel 1.90.0). If that file moves, move this too —
# a mismatch makes the image silently re-download a second toolchain on every run.

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config libssl-dev clang cmake \
        curl ca-certificates jq python3 \
    && rm -rf /var/lib/apt/lists/*

# ── Bitcoin Core, pinned + checksum-verified ────────────────────────────────────────────────────
# Same version as `regtest/env.sh` (BITCOIN_VERSION=30.2) so the Docker and host harnesses agree;
# a split here would mean consensus behaviour differing between them, which is the kind of thing
# that costs a day to notice. `electrsd` CAN download bitcoind itself, but baking it in makes runs
# hermetic and offline-capable, and `BITCOIND_EXE` is exactly what `harness.rs:33` looks for first.
ARG BITCOIN_VERSION=30.2
RUN set -eux; \
    cd /tmp; \
    tar="bitcoin-${BITCOIN_VERSION}-x86_64-linux-gnu.tar.gz"; \
    base="https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}"; \
    curl -fsSLO "$base/$tar"; \
    curl -fsSLO "$base/SHA256SUMS"; \
    grep " $tar\$" SHA256SUMS | sha256sum -c -; \
    tar -xzf "$tar" -C /opt; \
    ln -s "/opt/bitcoin-${BITCOIN_VERSION}/bin/bitcoind" /usr/local/bin/bitcoind; \
    ln -s "/opt/bitcoin-${BITCOIN_VERSION}/bin/bitcoin-cli" /usr/local/bin/bitcoin-cli; \
    rm -f "$tar" SHA256SUMS

ENV BITCOIND_EXE=/usr/local/bin/bitcoind
# ELECTRS_EXE is deliberately NOT set: `electrsd`'s `electrs_<ver>` download feature is already
# enabled in quid-hop/Cargo.toml, and it pins the electrs build it expects. Baking a different one
# in would override that pin via `harness.rs:37` and silently test against the wrong indexer.

# ── Memory-safe defaults for a ~2 GB Docker VM (see the MEMORY note above) ──────────────────────
ENV CARGO_BUILD_JOBS=1 \
    RUSTFLAGS="-C debuginfo=0 -C codegen-units=1" \
    CARGO_TERM_COLOR=never

WORKDIR /w
CMD ["cargo", "test", "--workspace", "-j", "1"]
