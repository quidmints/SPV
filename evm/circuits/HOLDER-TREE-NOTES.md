# Holder-tree compatibility notes — fork of `rarimo/passport-zk-circuits-noir`

Our fork of the **Noir** circuits the wallet's on-device prover runs (`query_identity`,
`register_identity*`). MIT. See `app/identity-wallet` (SDK) + `app/contracts/holder` (contracts).

## Headline: the query circuit needs NO source change for one-key-multiple-documents

`query_identity` → `noir_dl::query::query_identity` → `identity_state_verifier` proves SMT
membership of:

```
position = Poseidon(pk_passport_hash, sk_identity_hash)        // sk_identity_hash = profileKey
value    = Poseidon3(dg_commit, identity_counter, timestamp)
smt_verifier(root, value, position, siblings) == 1
```

That is **byte-for-byte identical** to what our `HolderStateKeeper._bindDocument` writes on-chain:

```
index = Poseidon2(documentKey, holderRoot)      // holderRoot = profileKey, documentKey = passportKey
value = Poseidon3(dgCommit, seq, timestamp)      // seq ↔ identity_counter
```

This match was deliberate (the holder tree reuses upstream's leaf index/value shape), and it makes
the circuit compatible **as-is** across every multi-document case:

| Case | Why the existing circuit already handles it |
|---|---|
| **Multi-citizenship** (many passports, one key) | Each document is a separate SMT leaf under the *same* `profileKey`. The prover picks which leaf/document to present; `position` differs per `pk_passport_hash`. No change. |
| **Revoked / superseded** | `HolderStateKeeper` overwrites the leaf value to `Poseidon1(REVOKED)` / `Poseidon1(SUPERSEDED)`. The circuit reconstructs `value = Poseidon3(dgCommit, seq, timestamp)` and asserts membership with *that*; a marker value ≠ the reconstructed value → `smt_verifier` returns 0 → **proof fails automatically**. Revocation is enforced by value-mismatch, not a status flag. |
| **Renewed** | The new leaf is a normal current leaf (`seq+1`); present it. The old leaf is superseded → auto-rejected as above. Identity continuity holds (same `profileKey`). |
| **Expired** | Already supported — `expiration_date_lowerbound/upperbound` + `current_date` + the date comparators in `noir_dl_lib/src/query.nr`. |
| **No current document** | All leaves revoked/superseded/expired → holder simply can't produce a valid proof (correct). |

## So fork #2 is "fork to control/self-host", not "fork to modify"
- **No `.nr` source change is required** for one-key-multiple-documents.
- We still fork the repo to: (a) hold a controlled/audited copy, (b) optionally **self-host the
  circuit bytecode + UltraPlonk trusted setup** so the wallet doesn't depend on rarime's CDN, and
  (c) lock byte-for-byte that the circuit's index/value match `HolderStateKeeper`.

## The only remaining wiring is SDK-side (not circuit, not new crypto)
`generateQueryProof` must feed `identity_counter` = our `DocumentBond.seq` and `timestamp` = the
leaf's issue timestamp, read from **our** `HolderStateKeeper.getDocument(documentKey)` (not upstream
`getPassportInfo`). That's an SDK contract-binding change, already flagged in
`identity-wallet/src/identity/IdentityVault.ts`.

## Out of scope (would need circuit changes — not part of multi-document)
Epoch roots (accept proof vs any recent root), scoped per-RP pseudonyms, BBS — all dropped with
the EUDI thread.
```
