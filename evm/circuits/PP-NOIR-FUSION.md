# #2 — Noir/Honk unification of rarime + Privacy Pools (the coherent fusion)

**Decision (locked):** full **UltraHonk** migration of the *whole* stack — rarime identity circuits **and** PP
circuits on one **Noir 1.0 + Barretenberg (Honk)** toolchain. Complexity is accepted; the goal is the most
*correct and coherent* fusion, not the minimal port.

## Why Honk + one toolchain
- One **prover** binary, one **SRS**, one **verifier-codegen** pipeline on device — the real single-prover win.
- Faster client-side proving (Honk) — the on-device UX bottleneck.
- Future-proof (UltraPlonk/`BaseUltraVerifier` is the dying path); do the re-audit once, on the modern backend.

## The unified hash: circomlib-Poseidon (NOT Poseidon2)
The most *correct* choice, because it is the **audited, already-present** one:
- rarime's identity circuits already hash with circomlib-Poseidon and verify on-chain against
  `poseidon-solidity`; keeping it means **no hash change inside the complex, audited identity circuits**.
- The wallet (`src/pp/notes.ts`, `discovery.ts`) already uses `@iden3/js-crypto` (circomlib).
- On-chain we already vendored `poseidon-solidity` + `@zk-kit/lean-imt.sol` (circomlib).
- → **one hash across circuit + wallet + contracts, all audited/proven.** Poseidon2 would either fork the
  stack into two hashes (incoherent) or move rarime onto the **unaudited** `poseidon2-evm` (less correct).
- **Poseidon2 stays a deferred, uniform efficiency swap** — `noir-lang/poseidon` exposes both, so it's a
  one-line change everywhere *after* the coherent stack is proven and *if* proving time demands it.

> Determining unknown to confirm: whether our forked identity stack must interoperate with the **live
> Rarimo protocol** (passport/CSCA registrations, global identity SMT). If yes, circomlib is *forced* for
> rarime (reinforcing the above). If we are fully self-contained on our own `HolderStateKeeper`, Poseidon2-
> everywhere becomes *possible* — but still the less-audited option, so circomlib remains the recommendation.

## Coherent-fusion architecture (what "makes the most sense")
- **One circuits workspace** — rarime circuits (migrated to Noir 1.0) + `pp/` lib (this dir), both importing
  `noir-lang/poseidon` and a shared Merkle module (rarime SMT gadget + PP `lean_imt`), all over one hash.
- **One verifier interface on-chain** — PP drops its Groth16 `IVerifier`/`verifyProof(pA,pB,pC,[8])` and
  adopts rarime's **`INoirVerifier.verify(bytes proof, bytes32[] publicInputs)`**. Both stacks call the same
  Honk verifier ABI. This is the tangible contract-level fusion.
- **One on-chain Poseidon** (`poseidon-solidity`) serves both rarime's SMT and PP's LeanIMT.
- **One evidence registry (ERC-7812)** anchors both identity state roots and PP ASP roots (finishes idea C;
  #3 already anchors the ASP side) — extended (2026-07-24) to a third category: periodically-refreshed
  external authoritative-source lists (e.g. a government notary registry), via the SAME registry
  through a new `RegistrySourceAnchor` contract, keyed by `registryId` so more sources can be added
  without redeploying. See "External authoritative-source anchoring (CRE)" below.
- **Recursion available** (rarime ships `recursion.nr`) — Honk composes proofs, so identity+PP flows can be
  aggregated into one on-chain verify later if desired.

## Reuse map (lean on these; build almost nothing)
| Layer | Reuse (exists) | New |
|---|---|---|
| Circuit hash | `noir-lang/poseidon` (Poseidon1, circomlib) | — |
| Wallet hash | `@iden3/js-crypto` (already a dep) | — |
| On-chain hash + tree | `poseidon-solidity` + vendored `@zk-kit/lean-imt.sol` | — |
| LeanIMT circuit gadget | (no Noir lib) — PP `merkleTree.circom` is the spec | `pp/src/lean_imt.nr` ✅ ported |
| Commitment gadget | PP `commitment.circom` is the spec | `pp/src/commitment.nr` ✅ ported |
| Comparators / range / bits | Noir stdlib | — |
| Verifier (Honk) | `bb` codegen | — |
| Withdraw/ragequit logic | PP `withdraw.circom` is the spec | translate (Phase 2) |
| Passport primitives (rarime) | `zkpassport/noir-ecdsa`, `noir_rsa` | — |

## External authoritative-source anchoring (CRE) — 2026-07-24

Turns a bulk-export government data source (concretely: Ukraine's Ministry of Justice notary
registry, `ern.minjust.gov.ua` / `data.gov.ua` open data) into a periodically-refreshed,
Merkle-committed, on-chain-verifiable fact — "the concept is sound (a public, authoritative
government source, same pattern as the OFAC list)": a snapshot, not a live query endpoint,
because that's what the source actually is (an XML/zip bulk export, not a real-time lookup API).

- **`backend/contracts/contracts/registry/RegistrySourceAnchor.sol`** (new) — anchors a
  `registryId`-keyed root into the SAME `IEvidenceRegistry` rarime/PP already use, mirroring
  the `updateRoot`/`latestActiveRoot` pattern `Entrypoint` used AT THE TIME deliberately (1-hour
  activation delay against front-run/equivocation, write-once-per-index). Note that `Entrypoint`
  itself has since abandoned that pattern for an on-chain append-only tree with no activation delay
  (TODO.md sec. 2A Phase 1b); `RegistrySourceAnchor` legitimately keeps it, because it anchors a
  genuinely external snapshot it cannot recompute, which is the case the delay was designed for.
  `onReport(bytes,bytes)` decodes a CRE
  report payload and dispatches to `publishSnapshot` — gated by `REGISTRY_POSTMAN`
  (`AccessControl`), not yet wired to Chainlink's actual `KeystoneForwarder`/`IReceiver` trust
  model (flagged explicitly in the contract's own doc comment — confirm the exact Forwarder
  interface against current CRE docs before granting it the role in production).
- **`backend/cre/notary_registry/main.go`** (new) — a cron-triggered (`cron.Trigger`, daily
  default) Chainlink CRE WASM workflow, structurally reusing `old/keeper/my-workflow/main.go`'s
  proven pattern: `http.SendRequest` + `cre.ConsensusIdenticalAggregation` (every DON node fetches
  the bulk export independently and must agree byte-for-byte — no single operator can substitute a
  tampered snapshot) → `runtime.GenerateReport` → `evmClient.WriteReport`. Parses the export
  (handles both raw `.xml` and `.zip`-wrapped), builds a keccak/OpenZeppelin-`MerkleProof`-
  compatible sorted-pair Merkle tree over ACTIVE-status entries only, writes the root.
  - **keccak, not Poseidon, deliberately**: this tree isn't consumed by a ZK circuit yet — the
    notary-CREDENTIAL binding circuit (proving "I am the specific person behind this registry
    entry," as opposed to merely "I am *an* ASP-cleared identity" — see the identity-based ASP
    entry above) is separate, explicitly deferred future work. A future ZK-consuming version of
    this tree would need Poseidon+LeanIMT at that point, mirroring `pp/src/identity_asp.nr` — not
    now.
  - **Real, remaining operator TODOs (written directly into `main.go`'s header, not hidden):** (1)
    the exact bulk-export URL is left blank, not guessed, pending confirmation against the live
    `data.gov.ua` catalog entry; (2) `NotaryRecordXML`'s field tags are a placeholder schema
    pending a real downloaded sample. These need real-world data this session doesn't have access
    to; everything else is implemented.
  - **2026-07-24: dropped IPFS entirely, not just left unwired.** The leaf set is no longer routed
    through an external pinning service at all — `RegistrySourceAnchor.publishSnapshot` now takes
    the full `bytes32[]` leaf array as calldata and **computes the root on-chain itself**
    (`_computeRoot`, keccak/sorted-pair), emitting the leaves via `SnapshotLeaves`. This closes a
    real soundness gap the CID-based design had (a postman could previously anchor ANY root with
    no way to check it corresponded to real data) and removes the external-dependency question
    entirely — data availability is the transaction's own calldata/event log, permanently
    replayable by any full node. `backend/cre/notary_registry/main.go` submits `leaves` directly
    (no `sourceCID` parameter exists anymore). The identity ASP tree (Poseidon-hashed, unlike the
    notary registry's keccak tree) gets the same treatment via a separate, purpose-built
    `IdentityAspLeafRegistry` (permissionless, no on-chain root recomputation — Poseidon
    recomputation for a large leaf set is real avoidable gas cost, and `Entrypoint.updateRoot`
    already trusts the same off-chain root computation unconditionally, unchanged).
  - **2026-07-24: `RegistrySourceAnchor`/`TitleLedger` converted to UUPS-upgradeable-behind-proxy**
    (`initialize()` instead of constructor-set immutables), matching this codebase's own
    convention for record-holding registry contracts (Entrypoint/StateKeeper/RegistrationSimple) —
    an inconsistency caught by comparing against MetaLeX's real `cybercorps-contracts` repo, which
    uses the same UUPS+upgradeable pattern throughout. `IdentityAspLeafRegistry` is the deliberate
    exception (see its own header comment): it has no access control and makes no trust claim, so
    adding an upgrade owner would introduce a trust surface that contradicts its whole point.
  - Not built/simulated/deployed this session (same standing constraint as the Noir work: no
    toolchain runs without asking first).

## Dependency freshness pass (2026-07-25)

Checked every dependency ecosystem in this fusion against real upstream registries (not assumed
current). Safe, verified bumps applied directly; anything requiring a build to confirm compatibility
is flagged, not silently bumped. Full breakdown in the session log; summary:

- **Noir packages**: `poseidon` v0.1.0→v0.3.0 (9 releases behind; checked `poseidon/bn254.nr`
  directly at v0.3.0 - `hash_1`..`hash_16` unchanged at the same `poseidon::poseidon::bn254` path),
  `noir_sort` v0.2.0→v0.4.0 (checked `sort_advanced`, the only function this tree uses, still
  exists), `noir-ripemd160` v0.0.2→v0.0.4 (its own changelog: "update noir version"). **`nargo`
  itself is NOT bumped** - still pinned at 1.0.0-beta.1 in spirit, latest is 1.0.0-beta.25 (24
  releases behind, confirmed breaking stdlib removals in between - none used in this tree, checked
  via grep). Bumping nargo re-verifies the whole ~16k-line `noir_dl_lib`, tracked under
  P0-remaining, not done as a quick pin edit.
- **CRE Go module**: `go-ethereum` v1.16.4→v1.17.4, `cre-sdk-go` core v1.0.0→v1.15.0, `http`/`cron`
  capabilities v1.0.0-beta.0→v1.4.0 (**both have exited beta** since `main.go` was written against
  `old/keeper`'s reference code - a real compatibility risk, not a safe assumption; only
  `go build`/`go mod tidy` can confirm `main.go` still compiles against these).
- **npm (wallet)**: `@iden3/js-crypto` re-checked, still correctly pinned at exact `1.3.2` (1.3.3's
  peer requirement on `@noble/hashes@2.2.0` still conflicts with `@noble/curves`'s `1.8.0` - the
  conflict is still real, not stale). **Expo is 3 major versions behind (54.0.36 → latest 57.0.8)**,
  dragging React Native (0.81→0.86) with it - flagged as its own dedicated upgrade, not attempted
  here (too large/regression-risky to bundle into a dependency-freshness pass). `@noble/curves`/
  `@noble/hashes` (1.x→2.x), `@peculiar/x509` (1.x→2.x), and `mrz` (4.x→5.x) all have major-version
  gaps too - security/parsing-critical libraries, flagged for individual changelog review rather
  than blind bumps.
- **Foundry `lib/`**: `poseidon-solidity` already current (0.0.5). `@openzeppelin/contracts`
  5.2.0→5.6.1, `@openzeppelin/contracts-upgradeable` 5.2.0→5.6.1, `@solarity/solidity-lib`
  3.1.0→3.3.3 all behind. These are vendored as plain directories, not git submodules (`ibiza`
  itself isn't a git repo, confirmed no `.gitmodules`) - bumping means replacing vendored source
  trees wholesale, which needs a real `forge build` to verify nothing broke. Flagged, not done.
- **`@rarimo/rarime-rn-sdk`**: forked to `github.com/quidmints/rarime-rn-sdk` (vendored baseline
  pushed, `ibiza`'s package.json now references the fork via `github:quidmints/rarime-rn-sdk#main`
  instead of the upstream npm package) - the prerequisite for adding Honk-proving support without
  editing an unforked third-party dependency in place. The actual Honk-proving native code
  (Kotlin/Swift) is not written yet - separate next step.

> **CLI RENAME NOTE (2026-07-26) — every P0 finding below still holds; only command spellings
> changed.** `bb 0.82.2` moved the commands this section names (`prove_ultra_keccak_honk`,
> `write_vk_ultra_keccak_honk`, `contract_ultra_honk`) under `bb OLD_API`. Current spellings are
> `bb prove --scheme ultra_honk --oracle_hash keccak`, `bb write_vk --scheme ultra_honk
> --oracle_hash keccak`, and `bb write_solidity_verifier --scheme ultra_honk`. **Finding 5 below —
> that the keccak transcript is MANDATORY for standalone on-chain verification — is unchanged, and
> was re-confirmed against two REAL circuits** (not just P0's trivial one) on 2026-07-26. Do not
> read the rename as the finding being stale.
>
> **Correction:** P0's claim that this machine's CPU cannot run native `bb` is machine-specific, not
> a project fact. `bb` SIGILLs without AVX2/BMI2 (the i3-U330 P0 ran on) and runs fine on a CPU that
> has them — verified on an i9-9880H. `backend/circuits/codegen-verifiers.sh` is the re-runnable
> capture of this whole pipeline; prefer it over following the prose below by hand. See TODO.md
> §2.3 and §1's AVX2 correction.

## P0 — CONFIRMED GO (toolchain spike, run on this dev machine 2026-07-01)

**Toolchain installed:**
- `nargo 1.0.0-beta.1` via `noirup --version 1.0.0-beta.1` — matches rarime's pinned README version exactly.
- `bb.js@0.82.2` (WASM, npm) — **not native `bb`**. This machine's CPU (Intel Core i3-U330, SSE4.2 only, no
  AVX2/BMI2) segfaults the native `bb` binary (`Illegal instruction`). Correct call for THIS
  dev-machine spike (proves the toolchain end-to-end without needing AVX2). **The "so bb.js WASM
  is the correct backend for mobile production too" conclusion below was WRONG — corrected
  2026-07-24 (see P4's Status entry).** It conflated this machine's local x86/AVX2 gap with React
  Native's JS-engine capability; Hermes has no WebAssembly support at all (checked, not assumed),
  and bb.js is browser-first infrastructure (156MB, web-worker/IndexedDB-based) regardless of
  engine. Mobile production proving should extend rarime's existing NATIVE proving bridge
  instead, matching both rarime's own precedent and zkPassport's (`noir_rs`) — not adopt WASM.
  ~~so `bb.js` WASM is actually the *correct* target anyway, not a workaround. `noir-lang/awesome-noir`-adjacent
  tooling and the wallet's own prover will use the WASM/portable backend in production, same as this spike.~~
- **Correction to the original plan:** do **not** match rarime's pinned `bb 0.66.0`. `bbup`'s own installer
  warns of a **critical UltraHonk soundness vulnerability in bb < 0.82.0** ("any Solidity verifier contracts
  must be regenerated using a patched version"). `bbup` auto-resolved `0.82.2` as compatible with
  `nargo 1.0.0-beta.1` — use that resolution method (`bbup` with no args, reading installed `nargo`), not a
  hardcoded version, whenever this is repeated.

**End-to-end loop closed (all empirically verified, not assumed):**
1. `nargo compile` — trivial circuit compiles clean under `1.0.0-beta.1`.
2. `nargo execute` — witness generation works.
3. `bb.js prove_and_verify_ultra_honk` — proof generated + verified via WASM, ~6s, exit 0.
4. `bb.js contract_ultra_honk` — generates a Solidity `HonkVerifier` whose interface is
   **`verify(bytes calldata _proof, bytes32[] calldata _publicInputs) external view returns (bool)`** —
   confirmed **identical in shape** to rarime's existing `INoirVerifier.sol`. The P3 interface-unification
   step is trivial, not an adapter.
5. **Load-bearing correction found by testing, not assumption:** the plain `_ultra_honk` prove/vk commands
   (Poseidon2/native-transcript, meant for in-circuit **recursive** verification) do **NOT** verify against
   `contract_ultra_honk`'s generated Solidity — deploying and calling `verify()` reverted `SumcheckFailed()`.
   Standalone on-chain (EVM) verification requires the **keccak-transcript variants**:
   `prove_ultra_keccak_honk` + `write_vk_ultra_keccak_honk`, paired with `contract_ultra_honk`. With that
   pairing, a real Forge test **deploys the generated verifier and calls `verify()` with a real WASM-produced
   proof → returns `true`**; a tampered public input correctly reverts.
   → **This promotes the old P6 "keccak-Honk verifier variant" from a deferred efficiency tweak to a P3
   functional requirement.** Always use the `_keccak_honk` prove/vk/verify commands when the target is a
   standalone Solidity verifier (i.e. every PP/rarime on-chain verifier in this fusion).
6. **Measured gas** (Forge `--gas-report`, trivial 1-public-input circuit): `verify()` alone ≈ **1,982,980
   gas**; deployment ≈ 6.56M gas / 30,216 bytes. This is real and non-trivial — materially higher than a
   Groth16 verify (~200–250k gas). Confirms the P3 "gas jumps materially" caveat with a real number instead
   of a guess; real circuits (bigger public-input counts) will cost more. This is a genuine trade the fusion
   makes for one-prover coherence — worth remembering when judging whether the union is worth it per-circuit.

**Scratch artifacts** (not committed — regenerate via the commands above; `/tmp` scratchpad is ephemeral):
Nargo project + witness, `bb.js` proof/vk (both transcript variants), generated `HonkVerifier.sol`
(non-keccak, fails on-chain — kept as a negative example) and `VerifierKeccak.sol` (the correct one), and a
Forge test proving both the positive and negative (wrong-input) case.

## P1 — gadget differential tests: CONFIRMED (2026-07-01)

Both `pp/` gadgets now compile under `nargo 1.0.0-beta.1` and pass real `nargo test` differential
tests against the exact on-chain functions PP will call:

- **`pp/src/lean_imt.nr`** — `lean_imt_inclusion` matches `@zk-kit/lean-imt.sol` (`LeanIMT.insert` +
  `.root()`) exactly, for a real 3-leaf tree, cross-checked via a Forge test using the vendored
  `PoseidonT3`/`LeanIMT.sol`. `nargo test`: **pass**.
- **`pp/src/commitment.nr`** — `commitment_hasher` matches `poseidon-solidity`'s `PoseidonT2/T3/T4` —
  the same functions `PrivacyPool.sol` itself calls for commitments/nullifiers. `nargo test`: **pass**.
- Two real bugs were caught by actually compiling (not just writing) the gadgets, both fixed:
  non-ASCII (em-dash) characters in comments are rejected by this Noir parser; and the import path
  for `noir-lang/poseidon` v0.1.0 is `poseidon::poseidon::bn254`, not `poseidon::bn254` (package
  `poseidon` re-exports `pub mod poseidon;`, which contains the `bn254` submodule).
- The library's own source confirms the design doc's central claim independently: `bn254.nr` states
  "Consistent with Circom's implementation" — not just asserted, now primary-sourced.

**Remaining for P1:** these are single hand-derived vectors, not fuzzed/randomized ones. Before
trusting `lean_imt_inclusion` for real value, add randomized (leaf, index, siblings, depth) vectors —
particularly the LeanIMT carry-up edge case (odd leaf counts at multiple levels) — cross-checked the
same way.

## Tracked gap: no exclusion (non-membership) path in the Noir SMT gadget

**The Noir circuit side has no exclusion path at all — `smt_verifier` in `smt.nr` only proves
membership.** (`noir_dl_lib/src/smt.nr:65-91`: takes `(root, leaf, key, siblings)` and always assumes
the claimed `leaf` value sits at `key`'s position; no aux-leaf params, no branch for an empty subtree
or a different key found on the path.) The on-chain Solidity side (`@solarity/solidity-lib`'s
`SparseMerkleTree.getProof`, vendored at `lib/solidity-lib/`) already returns full exclusion data
(`existence`/`auxExistence`/`auxKey`/`auxValue`) — so there's a working reference spec to port from,
same shape as the `pp/` gadget ports above, when this becomes needed.

**Does anything need it today? No — confirmed, not just assumed.** `HolderStateKeeper`'s
revocation/renewal never needed true exclusion: the document key stays a tree member forever, only
its value changes to a `Poseidon1(REVOKED)`/`Poseidon1(SUPERSEDED)` sentinel, so a query circuit that
reconstructs the claimed-current value (`Poseidon3(dgCommit, seq, timestamp)`) and does a plain
*membership-with-value* check against the current root will correctly reject a stale claim — no
exclusion proof required. This is proven directly (not just asserted) by
`test_leaf_value_matches_circuit_reconstruction` in `test/holder/HolderStateKeeper.t.sol`. (An earlier
version of `HolderStateKeeper.sol`'s NatSpec incorrectly called this "exclusion (non-membership)
proofs" — fixed to describe the real membership-with-value mechanism, 2026-07-02.)

**A real, separate, currently-unaddressed gap:** even with the Solidity-side property proven, nothing
today makes the *circuit* actually consume it. The forked `query_identity` circuit's only tree check
(`identity_state_verifier`, `query.nr:56-80`) still proves membership against the upstream
`id_state_root`/passport-commitment convention — it has not yet been rewired to reconstruct and check
against `HolderStateKeeper`'s value convention (`dgCommit`/`seq`/`timestamp`) at all. Until that wiring
happens, a revoked/superseded document's query proof isn't actually rejected end-to-end — the
cryptographic property holds on-chain, but nothing calls it. **Add to P2 (or a new P1.5): wire
`query_identity` to the holder-tree leaf convention**, as part of the circuit migration, not a
follow-on.

**When exclusion (true non-membership) WOULD be needed:** a real external-list check — e.g. "this
identity is not on a sanctions list" — is structurally a non-membership proof (the identity was never
added, not "added then revoked"). That's the one scenario that would actually require porting the
`smt_verifier` exclusion path above. See the separate identity-compliance/card-issuance TODO doc for
that workstream; it is NOT assumed to be in scope for the base Noir migration.

## Phased plan (remaining)
- **P0-remaining: rarime migration.** Migrate rarime circuits to Noir 1.0 syntax (mixed old/new generics
  found — `noir_dl_lib/src/big_curve/*` uses pre-`<let N: u32>` generics in places); bump `noir_sort`/
  `ripemd160` dependency tags to 1.0-compatible releases; regenerate verifiers with the **keccak-Honk**
  commands confirmed above; confirm identity register/query **still prove + verify on-chain**. ~16k lines of
  `.nr` source total (mostly `noir_dl_lib`'s signature-verification/bignum code) — this is the bulk of the
  remaining P0 work and the part not yet spiked.
- **P1-remaining:** randomized/fuzzed differential vectors (see above).
- **P2 PP circuit port — RESCOPED (2026-07-24): identity-based ASP, not a faithful address-based
  port.** Upstream's ASP membership is keyed by `label` (a value pinned per DEPOSIT), so clearance
  is a property of one deposit event, not the depositor — no way to reuse an identity's clearance
  across notes, or as a standalone fact ("this identity passed screening") usable outside the pool.
  Rescoped to key ASP membership by IDENTITY instead, using the same `holderRoot`
  (`Poseidon(pubkey(sk_identity))`) rarime's `HolderStateKeeper` already anchors — one identity
  commitment, three consumers (holder tree, ASP tree, wallet), not three drifting definitions.
  **Written this session** (not yet nargo-compiled — standing constraint, run `nargo test` to
  confirm before trusting):
  - `pp/src/identity_asp.nr` — `identity_asp_membership(sk_identity, asp_root, leaf_index,
    siblings, actual_depth) -> holder_root`. Reuses `noir_dl_lib::not_passports_zk_circuits::
    extract_pk_identity_hash` (rarime's own `Poseidon(pubkey(sk_identity))`, already used by
    `register_identity`) rather than reimplementing the EC scalar-mult + hash. `sk_identity` stays
    a PRIVATE witness — membership never reveals which ASP member is withdrawing, same anonymity
    shape as upstream's per-label scheme. Test vector cross-checked empirically against
    `@iden3/js-crypto` (the wallet's own `RarimeUtils.getProfileKey` primitives), not assumed.
  - `withdraw_identity/` (new package) — the actual withdraw circuit: existing-note state-tree
    membership + value conservation + change-note commitment (via `pp::commitment`,
    `pp::lean_imt`, unchanged) plus `pp::identity_asp` for the ASP check. Public I/O pinned to
    `ProofLib.WithdrawProof.pubSignals`'s existing 8-slot layout. **CORRECTED 2026-07-26:** this
    bullet used to claim "**`Entrypoint.sol`/`PrivacyPool.sol` need NO changes**". That was true of
    the identity re-keying itself, and is now false of the contracts — both changed substantially
    in TODO.md sec. 2A Phase 1b. `Entrypoint` maintains the ASP tree on-chain and append-only via
    `admitIdentity`; `updateRoot`/`latestActiveRoot`/`rootByIndex`/`associationSets` were REMOVED;
    and `PrivacyPool.validWithdrawal` now gates on `isKnownAspRoot` (any historical root) instead
    of equality with the single latest active one. The circuit's 8-slot public I/O is genuinely
    unchanged by all of that — only the contract side moved.
  - `frontend/identity-wallet/src/postman/identityAsp.ts` — the off-chain half: `IdentityAspTree`
    (TS mirror of `lean_imt.nr`'s construction rule, same Poseidon) builds the tree from cleared
    `holderRoot`s and produces circuit-ready inclusion paths. **CORRECTED 2026-07-26:**
    `publishIdentityAspRoot` is gone with `updateRoot`; the module now exposes `admitIdentity`
    (one tx per identity, decoding the real `IdentityAdmitted` event) and `loadIdentityAspTree`
    (replays those events to rebuild the local mirror, since the contract stores only the root).
  - **Explicitly deferred, not built this session:** the notary-credential BINDING layer (proving
    "I am the specific person listed in an external registry entry," as opposed to "I am *an*
    ASP-cleared identity") — see the CRE notary-registry mechanism below, which anchors the raw
    registry as a verifiable source but does not yet bind individual registry entries to specific
    `holderRoot`s. That binding is a separate follow-on.
- **P3 On-chain verifier unification.** Replace PP Groth16 verifiers with Honk (**keccak-transcript
  variant, confirmed required above**); swap `IVerifier`→`INoirVerifier` (confirmed drop-in shape);
  rewire `PrivacyPool`/`ProofLib` to `verify(bytes,bytes32[])`. Budget real gas per the measurement above.
- **P4 Wallet prover unification — CORRECTED 2026-07-24 (see the Status section's P4 entry for the
  full finding).** The original framing here ("one bb.js-WASM Honk prover serves identity + PP...
  also the right backend for mobile") was wrong: it conflated this dev machine's local x86/AVX2
  gap with React Native's JS-engine capability. Hermes has no WebAssembly support at all (checked,
  not assumed), and bb.js is browser-first infrastructure regardless. The real mobile path is
  extending rarime's existing NATIVE proving bridge (`RnNoirModule.ts` → `@rarimo/rarime-rn-sdk`'s
  Swift/Kotlin, currently `provePlonk`-only) with a Honk-proving entry point — matching both
  rarime's own precedent and the wider Noir-mobile ecosystem's (zkPassport's `noir_rs`). That's
  native-code work in a different package, not built this session. Witness gen from discovered
  notes (`src/pp/discovery.ts`) + reconstructed LeanIMT paths is still the right TS-side plan
  regardless of which prover backend ends up calling it.
- **P5 Re-audit + differential equivalence.** Audit migrated rarime + new PP; assert old-Groth16-PP and
  new-Honk-PP agree on accept/reject; deposit→withdraw e2e.
- **P6 (deferred efficiency).** Poseidon2 uniform swap · recursion/aggregation · tree-depth tuning ·
  public-input packing.

## Status
- ✅ **P0 (spike): CONFIRMED GO.** Toolchain installed + working end-to-end incl. real on-chain verify.
- ✅ **P1 (gadgets): core differential tests CONFIRMED; P1-remaining (fuzzed vectors) WRITTEN,
  not yet run.** `pp/src/commitment.nr`, `pp/src/lean_imt.nr` compile and match on-chain Solidity
  vectors exactly (`nargo test`, 2/2 pass, 2026-07-01). 2026-07-24: added 46 randomized differential
  vectors to `lean_imt.nr` (10 tree sizes 1–37, every parity/carry-up combination up to
  `MAX_DEPTH=8`, including multi-level carries — the specific gap this line used to flag), built
  and proven in Node against real Poseidon output, not yet `nargo test`-confirmed.
- ⏳ **P0-remaining (rarime migration)** is the next substantial dev-machine task — the bulk of the
  work, not yet started.
- ✅ **P3 (Groth16→Honk swap for withdrawals): DONE at the contract level.** `ProofLib.WithdrawProof`
  now carries a Honk `bytes proof` (no more `pA`/`pB`/`pC`); `State.WITHDRAWAL_VERIFIER` is
  `INoirVerifier`; `PrivacyPool.withdraw()` calls `.verify(proof, publicInputsBytes32())`.
  `RAGEQUIT_VERIFIER` was ALSO ported (see `RagequitHonkVerifier.t.sol`); both are `INoirVerifier`
  today, so no Groth16 remains in the pool. Test suite
  (`PrivacyPoolSimple.t.sol`) updated to match. Still missing: the actual generated Honk verifier
  contract for `withdraw_identity` (needs `nargo compile` + `bb` codegen — a build step, not
  hand-writable) and the wallet-side prover integration (P4, below).
- 🔶 **P2 (identity-based ASP): written, NOT yet `nargo`-tested.** `pp/src/identity_asp.nr` +
  `withdraw_identity/` + the wallet's `postman/identityAsp.ts` exist and are internally
  cross-checked (the identity-commitment test vector against real `@iden3/js-crypto` output), but
  have not been compiled/run — same standing constraint as P0-remaining. `postman/identityAsp.ts`'s
  tree construction now uses the official `@zk-kit/lean-imt` package (2026-07-24: caught and fixed
  a hand-rolled reimplementation of the exact same algorithm — see git history/session log).
- 🔶 **P4 (wallet prover integration for PP circuits): the native proving capability now EXISTS
  and is wired (2026-07-25) — the wallet-side calling code (witness assembly, tree
  reconstruction, calldata submission) still doesn't.** Android side: confirmed directly in the
  vendored `noir.aar`'s compiled bytecode (not assumed) that `Circuit.prove(..., proofType:
  String, ...)` already accepts `"honk"` — the literal string sits in `Circuit.class`'s constant
  pool next to `"prove"`/`"proofType"`/`"recursive"`. Added `RnNoirModule.kt`'s `proveHonk`
  AsyncFunction (calls the exact same already-committed binary `provePlonk` uses, just a
  different `proofType`) + the matching TS bridge (`NoirModule.ts`, `RnNoirModule.ts`'s
  `NoirCircuitParams.proveHonk`) in the `quidmints/rarime-rn-sdk` fork, pushed. iOS (Swoir) side
  not checked this session — no Xcode/Mac available to inspect the equivalent Swift binding.
  Still missing, and still real work: the wallet-side code that builds a `withdraw_identity`
  witness from a discovered note + reconstructed state/identity-ASP tree paths and calls this new
  `proveHonk` — genuinely not started.

  (Earlier framing this doc corrected on 2026-07-24, kept for the record below.)

  The earlier "one bb.js-WASM Honk prover serves identity + PP" framing (this doc, P0 log) was
  **wrong for the mobile target, not just incomplete** — it conflated two unrelated things: this
  dev machine's x86 CPU lacking AVX2 (a real but LOCAL-TESTING-ONLY limitation) with React
  Native's JS-engine capability. Checked properly this session:
  - Hermes (RN's default/only well-supported engine as of RN 0.81 + New Architecture) has never
    supported the WebAssembly JS API (open Hermes issue since 2020, no roadmap) — confirmed, not
    assumed.
  - `@aztec/bb.js` itself is the wrong tool for mobile regardless of engine: 156MB unpacked, built
    browser-first (`comlink` web workers, `idb-keyval`/IndexedDB caching — browser-only APIs).
  - Nobody actually does on-device Noir proving this way. zkPassport (a real, shipped Noir-based
    mobile passport app) uses `noir_rs` — a Rust crate cross-compiled to native iOS/Android
    bindings. rarime's own SDK, already a dependency of this wallet, does the exact same thing:
    `RnNoirModule.ts` calls `NoirModule.provePlonk(...)`, backed by NATIVE Swift/Kotlin code
    (`@rarimo/rarime-rn-sdk`'s `android/libs/noir.aar` + iOS `Swoir*`/`Swoirenberg*`), not WASM.

  **Corrected plan:** PP circuit proving on mobile should extend that SAME native binding
  (`provePlonk` → also a Honk-proving entry point), not add a JS-side WASM prover. That's real,
  concrete work, but it's native Swift/Kotlin/C++ work inside `@rarimo/rarime-rn-sdk` — a
  different package than this repo, using toolchains (Xcode/Android NDK) not available in this
  session. Nothing was built for this (correctly, per direction — building a WASM bridge would
  have been building the wrong thing).
- ✅ **External registry anchoring (CRE): written, NOT yet built/simulated/deployed, but no known
  functional gaps remain.** `RegistrySourceAnchor.sol` + `IdentityAspLeafRegistry.sol` +
  `backend/cre/notary_registry/main.go` exist; IPFS dependency removed entirely (2026-07-24, see
  above); both anchor contracts converted to UUPS-upgradeable, matching this codebase's
  convention. Remaining items are real-world data inputs (export URL, XML schema) this session
  doesn't have access to, not implementation gaps. Independent of the P0–P5 phased plan.
