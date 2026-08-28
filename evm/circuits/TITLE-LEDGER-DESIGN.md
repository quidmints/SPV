# Title ledger — privacy-preserving property records, informed by (not copying) MetaLeX CyberCorps

**Written 2026-07-24.** Nothing here has been `nargo`/`forge` compiled or run this session (standing
constraint). Written to the same real-code, not-yet-verified standard as `withdraw_identity/`.

## Why this exists

`NotarialTitle` (the wallet's `DocumentType` for property/vehicle titles) originally rode on rarime's
holder-tree/SMT convention — the same mechanism used for passports: a leaf proves "this document
exists, is current, hasn't been revoked." That's a membership-and-freshness check. It says nothing
about what the title record legally *says* (restriction legends, chain-of-title, governing documents) —
structurally the same gap MetaLeX's `MetaLEX.pdf` (in `projects/`) spends 39 pages dissecting in
ERC-3643/1400/7943: tokens that gate transfers without knowing what they represent.

Read against that document: MetaLeX's CyberCorps solves this by making the on-chain record rich,
self-describing, and non-fungible per entry — but its core thesis is built on *identifiable,
inspectable* ownership (it exists specifically to satisfy DGCL §§219–220's stockholder-list
inspection rights). That's the opposite of what this system needs: the explicit requirement (2026-07-24
direction) is that a title's ownership must **never be traceable** — an owner should be able to prove
they control a title (e.g. to get a loan) without that proof, or the loan disbursement, ever being
linkable back to them, including across their own multiple titles.

**So: take CyberCorps' structural properties that don't touch identity, reject the one that does.**

## What's inherited from CyberCorps

- Rich, self-describing, non-fungible per-entry records (not a fungible balance).
- "The ledger IS the record, not a pointer to an off-chain register."
- Per-entry restriction legends, mutable independently per title.
- Chain-of-title / provenance (`priorTitleId` linking entries).
- "Possession alone never implies a change of registered holder" — CyberCorps enforces this via an
  admin-authorized metadata edit; here it's enforced via a ZK proof instead (same principle, no
  identity-disclosing mechanism required).

## What's deliberately NOT inherited

- Identity in the ledger, in any form — no holder name, no "soulbound but wallet-visible" holder
  field. CyberCorps' inspectability requirement is a legal-compliance goal (SEC/DGCL recognition as a
  security) this system is not attempting; the goal here is a private collateral/attestation
  primitive, not a compliant-security issuance system.

## The mechanism

- **`backend/contracts/contracts/title/TitleLedger.sol`** — public metadata (`legalDescriptionHash`,
  `jurisdiction`, `priorTitleId`, mutable `restrictionLegends`, `encumbered`) with **zero holder
  identity**. Minting/legend/encumbrance changes require a signature from a notary currently active in
  `RegistrySourceAnchor`'s CRE-fed registry (the same mechanism built for the Ukraine notary registry,
  already country-agnostic via `registryId`). Holdership is a single `holderCommitment: bytes32` per
  title, mutated only via a ZK proof (`transferTitle`), and readable for eligibility checks without
  mutation (`verifyHolderProof` — the loan-collateral hook).
- **`backend/circuits/pp/src/title_holder.nr`** + **`backend/circuits/title_holder/`** — proves
  knowledge of `sk_identity` behind a title's commitment. The commitment is
  `Poseidon2(Poseidon(pubkey(sk_identity)), title_id)` — **deliberately not** `pp::identity_asp`'s raw
  `holder_root` (which is fixed per identity and reused across the whole fusion). Reusing the raw value
  here would let anyone compare that one field across every title entry and correlate every title the
  same person holds — the title-specific derivation is what actually makes this unlinkable, not just
  "we didn't put a name in a field."

## The loan flow this is built for

1. Borrower calls `TitleLedger.verifyHolderProof(titleId, proof)` (or a lending contract does, off a
   proof the borrower supplies) — confirms control of the title without revealing who they are.
2. Lender disburses the loan via a **Privacy Pool deposit**, using a precommitment the borrower
   generated locally (`frontend/identity-wallet/src/pp/notes.ts`, already built) — not a direct
   transfer to an address that could be linked to the borrower by timing/counterparty analysis.
3. Borrower later withdraws from Privacy Pool into any address, at any time — fully unlinkable from
   step 1. This is the literal enactment of the 2026-07-24 direction: "self-prove [ownership] against
   notary's attestation... to get a loan to a private address that they PP into a different address."

The lending contract itself (encumbrance placement, repayment, liquidation) is **not built** — out of
scope for this pass. `verifyHolderProof`/`setEncumbered` are the integration points such a contract
would call.

## Open gaps, not silently assumed solved

- **Notary-to-address binding.** `TitleLedger.bindNotaryAddress` is an admin-gated placeholder —
  binding a real-world notary's identity (as attested by the government registry: reg number, name,
  region) to an Ethereum signing key needs an out-of-band process this session doesn't build. The
  most natural fit is reusing rarime's own passport-verification flow (the notary proves their own
  identity via a passport-registered `holder_root`, cross-checked by name/ID against the registry) —
  but that's real, separate work.
- **`nargo`/`forge` verification.** Same as every other circuit/contract written this session —
  written, cross-checked where possible via independent Node computation
  (`title_holder.nr`'s test vector), not yet compiled or run.
- **The Honk verifier for `title_holder`.** Same as `withdraw_identity`'s — generating the actual
  `INoirVerifier`-shaped contract requires the `nargo compile` + `bb` toolchain, a build step, not
  done this session.
