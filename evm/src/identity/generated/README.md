# `src/identity/generated/` — machine-written Solidity, committed on purpose

**109 files. Nothing here is hand-edited, and every one of them deploys its own bytecode.**

They are quarantined under one root so the authored surface is legible: `src/identity` is 184
`.sol` files, and **75** of them are written by a person. Reading that tree without this split
makes the identity stack look four times the size it is.

| directory | what wrote it | count |
|---|---|---|
| `passport/noir/` | `noir/codegen-passport-verifiers.sh` (UltraPlonk, TD1, five hashes) | 88 |
| `passport/verifiers/` | `noir/codegen-light-verifiers.sh` (UltraHonk, TD1, SHA-256) | 11 |
| `pool/verifiers/` | Barretenberg — withdrawal, ragequit, recursion-tree roots | 5 |
| `sdk/verifier/` | Barretenberg — TD1/TD3 query-proof verifiers | 2 |
| `title/` | Barretenberg — notary action, title holder | 2 |
| `registry/verifiers/` | Barretenberg — escrow envelope | 1 |

## Why they are committed rather than generated at build time

Regenerating needs Docker, the Noir toolchain and `bb` — `noir/build-passport-verifiers-docker.sh`
exists precisely because none of that is assumable on a developer or CI machine. Gitignoring them
would make `forge build` depend on a toolchain most checkouts do not have, and would make the
deployed bytecode non-reproducible from the repo alone. **A verifier is a proving key rendered as
Solidity: the artifact IS the security property, so it belongs in the history where it can be
diffed.**

## Three things that will bite whoever touches this

🔴 **THE OPTIMIZER RESTRICTIONS IN `evm/foundry.toml` ARE MATCHED BY PATH, AND THE FAILURE IS AT
DEPLOY TIME.** Five entries pin verifiers to `optimizer_runs = 1`. `EscrowEnvelopeHonkVerifier` is
**25,503 bytes at the default 200 runs — 927 OVER EIP-170** and undeployable. It compiles clean
either way, so nothing in a green build tells you. `tools/check-contract-sizes.py` is the only gate.
⇒ **Move a file in here and you must move its `paths =` entry in the same commit.**

⚠️ **THE `TreeRoot*` ENTRY IS A GLOB, AND THAT IS DELIBERATE.** Honk's verifier is a fixed
algorithm, so a deeper recursion tree grows the *circuit*, not the contract — a new batch depth
needs a new file but no new reasoning.

🔴 **UNRESOLVED — `NotaryActionHonkVerifier` HAS NO RESTRICTION AND IS THE SAME SIZE AS THREE THAT
DO.** Measured: `title/NotaryActionHonkVerifier.sol`, `title/TitleHolderHonkVerifier.sol`,
`registry/verifiers/EscrowEnvelopeHonkVerifier.sol` and `pool/verifiers/WithdrawalHonkVerifier.sol`
are **2,518 lines each**, and the last three are all pinned to `optimizer_runs = 1` while the first
is not. That is exactly the shape the note above predicts: same fixed algorithm, same source size.
⚠️ **Source size is NOT the deciding factor, so this is a question and not yet a defect** — runtime
size scales with the PUBLIC INPUT COUNT (the `EscrowEnvelope` entry says so: *"8 public inputs, the
most of any circuit here, and each one costs runtime code"*), so a verifier with fewer inputs can
sit under the limit unrestricted. ▶️ **Settle it with `tools/check-contract-sizes.py` after a
successful build** — if `NotaryActionHonkVerifier` is near or over 24,576, it needs a `paths =`
entry. It was carried across from ibiza's `foundry.toml` exactly as it stood; the omission predates
this repo and was not introduced by the fold.

⛔ **COMPILING THESE IN PARALLEL OOMS A SMALL MACHINE.** Several are ~100 KB of source. On a 3 GB
box `forge build` dies with `solc exited with signal: 9 (SIGKILL)`, which reads exactly like a code
error and is not one. Use `forge build --threads 1`.

## Regenerating

The codegen scripts write straight into this tree — `noir/codegen-light-verifiers.sh` and
`noir/codegen-passport-verifiers.sh` both resolve their output relative to `$NOIR_DIR`. They were
repointed here when the identity stack folded into `evm/src`; if you move this directory again,
those `OUT_DIR`/`DEST` assignments move with it, or the next regeneration writes into a path that
does not exist and creates it silently.
