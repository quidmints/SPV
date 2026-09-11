# SPV

QU!D is a dated, fully-backed dollar claim issued against a diversified basket of fourteen
stablecoins. Against that basket the protocol runs two independent concentrated-liquidity ranges —
one on ETH, one on native Bitcoin — whose LPs provide single-sided volatile inventory and earn the
swap flow between the basket and that inventory.

There is no AMM dependency. The range is a bps band computed on an absolute price
(`SwapLib.updateBounds`, `evm/src/imports/SwapLib.sol:2815-2819`), currently ±2%
(`RANGE_DELTA = 200`, `evm/src/imports/SwapLib.sol:870`). No Uniswap v4, no `PoolManager`, no
`PoolKey`, no ticks, and no reference pool is read by any deployed contract.

Bitcoin liquidity is real Lightning custody. An LP's channel funding transaction is SPV-proven on
the EVM and its taproot output is byte-matched against a 2-of-2 aggregate key the contract
reconstructs on-chain — the contract does secp256k1 elliptic-curve arithmetic and proves
`Q == TapTweak(KeyAgg(lpPubkey, hopPubkey))` at open and at every splice
(`evm/src/imports/BitcoinTx.sol:453,474,530-547`).

**The protocol specification is [`spec.md`](./spec.md).**

## Repository layout

| path | what it holds |
|---|---|
| `evm/` | The Solidity. `src/` is the protocol; `script/DeployL1_s.sol` + `script/DeployLib.sol` are the one canonical deploy; `test/` is the Foundry suite; `lib/` the submodules. |
| `quid-ln/` | The Rust workspace: the LN node, `quid-bridge`, `quid-hop`, and the SGX/enclave crates. our LDK fork is the EXTERNAL repo `quidmints/rust-lightning` (see below). |
| `svm/` | The Anchor workspace — one program, `svm/programs/quid`, plus TypeScript tests. |
| `spa/` | Next.js — the landing page and the browser depositor surface. |
| `app/` | The Expo / React Native wallet. |
| `indexer/` | A small self-hosted indexer for protocol events. |
| `regtest/` | A reproducible Bitcoin regtest node and the shell drivers for the end-to-end channel, swap-in and swap-out flows. |
| `deploy/` | Provisioning: `deploy-l1.sh`, `run-hop.sh`, the `*.env.example` templates, and `PRODUCTION-LAUNCH.md`. |
| `sims/`, `analysis/` | Economic simulation (JS) and the price-data/IL series behind the economic numbers. |
| `tools/` | Repository gates and analysis helpers. |
| `docs/` | See "Where the documentation lives". |

`evm/src/identity/` is a vendored Rarimo passport-contracts tree with its own upstream README and
LICENSE. It is **not** part of the deployed protocol stack and has a separate deploy script,
`evm/script/DeployPassportVerifiers.s.sol`.

### The LDK fork

🔴 **The LDK fork is `https://github.com/quidmints/rust-lightning` (branch `main`), consumed via `[patch.crates-io]` — `Cargo.lock` pins the commit.** It is NOT vendored: `quid-ln/lib/rust-lightning/` was a 435-file / 13 MB copy that **nothing compiled**, deleted 2026-09-11 because it was the first hit for every grep while having no effect on any build. Our patches to it are documented in `quid-ln/LDK-FORK-PATCHES.md`; the code they describe must be verified against the locked commit in the fork, never against this tree.
(branch `lexe-v0.2.2-2026_04_28`), vendored in-tree and consumed through `[patch.crates-io]` in
`quid-ln/Cargo.toml`. **It is a fork, not a patched dependency: `+7,115 / −565` lines across 33
files plus a new 548-line `lightning/src/sign/taproot_signer.rs`.** Simple-taproot channels and
MuSig2 splice signing are ours — `negotiate_simple_taproot`, `supports_simple_taproot`,
`partially_sign_splice_shared_input`, `channel_taproot_script_pubkey` and `splice_nonce_height` all
have **zero** occurrences upstream. `QUID_PATCHES.md` in that directory carries the measurement and
the per-area breakdown; do not rely on grepping the `QU!D PATCH` marker, which tags fewer than 1% of
the changed lines.

## Building and testing

### EVM (Foundry)

```
cd evm
forge build
forge test
```

- `solc 0.8.30`, `evm_version = "cancun"`, `via_ir = false`. The last is a hard constraint, not a
  tuning knob — stack-too-deep is solved by struct fields and separate frames, not by the IR
  pipeline.
- Remappings live in `evm/remappings.txt` and **only** there; `foundry.toml` deliberately declares
  none, because forge merges the two lists and they had diverged.
- Tests fork mainnet. The RPC URL comes from `evm/.env` (gitignored) via the native `ETH_RPC_URL`
  variable — there is deliberately no `eth_rpc_url` key in `foundry.toml`, because Foundry does not
  expand `${VAR}` there.
- Foundry caches fork state **per block number**, so unpinned runs share nothing. Use
  `tools/forge-test.sh [forge test args]`, which pins the current head and reuses that pin.
- Throttling flags are CLI-only and require `--rpc-url`:
  `--compute-units-per-second 100 --fork-retries 10 --fork-retry-backoff 1000`.
- **Run one build at a time.** A second concurrent `forge build` exhausts memory on a normal box. A
  build that dies with exit 137 is usually the *linter* being OOM-killed after a successful compile
  — check the artifact, or pass `--no-lint`.

### Rust

```
cd quid-ln
cargo test -p <crate>
```

The toolchain is pinned to `1.90.0` (`quid-ln/rust-toolchain.toml`). `cargo check` never builds test
targets, so it cannot see a broken test; use `cargo test -p <crate>`, or at minimum
`cargo check -p <crate> --all-targets`. `quid-ln/Dockerfile` is the reproducible build environment.

### Solana

```
cd svm && anchor build
```

Then the TypeScript tests under `svm/tests/`.

### Gates

- `tools/check-contract-sizes.py` — EIP-170. Needed because `forge build --sizes` omits any contract
  with unresolved `linkReferences`, which is most of the libraries.
- `tools/check-client-abis.py` — client encodings against the deployed ABIs.
- `tools/check-doc-symbols.py` — run after any rename.
- `tools/check-dead-internals.py` — internal functions with no callers.

## Where the documentation lives

Precedence, highest first: **the contracts in `evm/src` are canonical for behaviour.** `CLAUDE.md` is
canonical for how to work in this tree and for environment facts. `docs/actionable/SPRINT.md` is
canonical for status.

| question | go to |
|---|---|
| What is the protocol? | `spec.md` |
| How do I work in this tree? What is the build environment? | `CLAUDE.md` |
| What is the status of X? What order should work be done in? | `docs/actionable/SPRINT.md` |
| What is still open? | `docs/actionable/TODO.md` |
| What crosses a chain boundary? | `docs/actionable/CHAIN-COUPLING.md` |
| How do I deploy, or run the hop and LP daemons? | `deploy/PRODUCTION-LAUNCH.md`, `deploy/README.md` |
| What must the front end enforce? | `spa/FRONTEND-TODO.md` |

🪦 **THERE IS NO PROSE DESCRIPTION OF THIS SYSTEM RIGHT NOW, AND THAT IS DELIBERATE** (owner,
2026-09-11: *"we have to rewrite the docs anyway so remove them entirely"*). `docs/informational/`
(nine files) and `docs/FAQ.md` (2,746 lines) are deleted, along with `docs/identity/` (17,800 lines,
deferred scope).

**Why deletion rather than repair:** every one of them described a design the tree no longer has.
The FAQ still explained the Avellaneda–Stoikov scarcity kernel — `Γ·σ²·q̄`, the variance registers,
the confirmation-cost base — with confident `file:line` citations, and mentioned the **flat 420 ppm
that actually replaced it ZERO times.** Three of the nine informational files carried their own
*OVERRULED* banners. A confident wrong description is worse than none: a reader who finds nothing
goes and measures, and a reader who finds a stale paragraph stops.

⇒ **`docs/actionable/` is what survives, and it is WORK, not description** — `SPRINT.md` is the
queue, `TARGET-DESIGN.md` is the model and is the authority on intent. Anything outward-facing gets
written once the implementation is finalized, against the code that exists then.
⛔ **Do not reconstruct a description from git history.** The deleted files are recoverable
(`git show <sha>:docs/FAQ.md`) and every one of them is wrong.
