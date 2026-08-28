# Holder-tree fork of `rarimo/passport-contracts`

This is our fork of [`rarimo/passport-contracts`](https://github.com/rarimo/passport-contracts)
(Hardhat, MIT), vendored into the app workspace so it's self-contained. See `SCOPE.md` §7.8.

## What we changed (and why)

Upstream `StateKeeper.addBond` enforces a **strict identity↔passport bijection**
(`require(_identityInfo.activePassport == 0)`) — one holder key binds at most one document.
That's the "1 key = 1 document" limitation. rarime supports identity *rotation* for one
passport (`reissueBondIdentity`) but never one-holder-many-documents or renewal-with-continuity.

Our fork adds a **holder-rooted credential tree** in `contracts/holder/`:

| File | Role |
|---|---|
| `holder/HolderStateKeeper.sol` | `is StateKeeper`. Reuses cert/owner/registration/signature machinery. **Disables the 1:1 `addBond`**. Adds the document model: `addDocument` (many docs per holder root), `renewDocument` (supersede old + bind new under same root), `revokeDocument`, views `getDocument` / `getHolderDocuments` / `getActiveDocumentCount`. |
| `holder/HolderRegistration.sol` | `is RegistrationSimple`. Reuses the signer set + Noir proof verification, writes to the document model via `registerDocumentViaNoir` / `renewDocumentViaNoir` / `revokeDocumentViaSigner`. |

**The SMT (`state/PoseidonSMT.sol`) is unchanged** — solarity's `SparseMerkleTree` already
does add/update/remove + inclusion AND exclusion (non-membership) proofs, which is all
renewal/revocation needs. The fix was the *binding semantics* in StateKeeper, not the tree
primitive.

**Renewal continuity / the link proof:** the holder root is the durable identity; all
continuity (scoped pseudonyms, nullifiers, card-state) binds to it, not the document. Renewal
preserves the root. The link is cryptographic — both the old and the renewed document carry a
Noir proof binding their DG1 to the *same* `holderRoot` (the identity key lives inside the DG1
commitment), so a renewal can only attach a document the holder can prove control of.

Everything else in the repo is upstream, kept as reference.

## Build & test — Foundry (Hardhat ripped out)
This is now a **Foundry** project (matches `SPV/evm`). Solidity deps are remapped to
`node_modules` (`remappings.txt`); `forge-std` is vendored in `lib/`. solc 0.8.28, optimizer/200,
evm `london`.
```
cd contracts
forge build
forge test --match-path "test/holder/*" -vv     # 12 passing
```
The holder suite (`test/holder/HolderStateKeeper.t.sol`) covers multi-citizenship, renewal
continuity, revocation, non-membership, and an **executable circuit-compat check**: the SMT leaf
value equals `Poseidon3(dgCommit, seq, timestamp)` — exactly what `query_identity` reconstructs —
and a revoked leaf becomes the `Poseidon1(REVOKED)` marker (so the circuit auto-rejects it).

## Circuits — compatible as-is (no change)
`app/circuits/` (forked `passport-zk-circuits-noir`). `query_identity` proves SMT membership of
the same index/value the holder tree writes, so revoked/superseded/multi-citizenship all work
unchanged. See `app/circuits/HOLDER-TREE-NOTES.md` (and the executable proof above).
