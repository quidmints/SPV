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

✅ **RESOLVED 2026-08-28 — `NotaryActionHonkVerifier` NEEDS NO RESTRICTION, AND THE REASON IT WAS
FLAGGED WAS A BAD INFERENCE.** Measured from a green build: `NotaryActionHonkVerifier` **18,019
bytes (6,557 to spare)**, against `WithdrawalHonkVerifier` 17,130 · `EscrowEnvelopeHonkVerifier`
17,129 · `TitleHolderHonkVerifier` 17,066 · `RagequitHonkVerifier` 17,065 — the last four pinned to
`optimizer_runs = 1`, this one not. It IS the largest, by ~900 bytes, not by the ~7,000 that would
put it at risk.
⚠️ **IT WAS SUSPECTED ONLY BECAUSE ITS SOURCE IS 2,518 LINES, THE SAME AS THREE PINNED ONES — and
that says nothing.** Runtime size tracks PUBLIC INPUT COUNT, which is why the `EscrowEnvelope`
restriction comment names its 8 inputs rather than its length. Source-line parity is not evidence
about bytecode; measure first.

## Regenerating

The codegen scripts write straight into this tree — `noir/codegen-light-verifiers.sh` and
`noir/codegen-passport-verifiers.sh` both resolve their output relative to `$NOIR_DIR`. They were
repointed here when the identity stack folded into `evm/src`; if you move this directory again,
those `OUT_DIR`/`DEST` assignments move with it, or the next regeneration writes into a path that
does not exist and creates it silently.
