# Where the contract still takes the hop's WORD — the complete class

**Owner, 2026-08-16: *"prove the thing dont take the hops word, get rid of all dependecneis of
this anature."*** This file is the enumeration behind that directive. It lives here rather than in
`QUEUE.md` because that file had another thread's uncommitted edits in it when this was written,
and staging it would have swept their work into this commit (rule 14). **Fold these rows into
`QUEUE.md` when it is quiet, then delete this file.**

## The distinction the audit turns on

🔑 **PROVING SATS MOVED IS NOT PROVING WHO GETS CREDITED, and only the first half is built.**

* **Proof of FACT** — did Bitcoin move? ✅ Covered. `settleSwapInProven` takes a tx + SPV
  inclusion proof; `parkProvenSats` establishes `provenSatsAvailable` that
  `settleSwapInBuffered` spends against.
* **Proof of ATTRIBUTION** — whose sats were they, and who receives the USD? 🔴 **Not covered
  anywhere.** The hop asserts it, on every credit path, including the proven one.

⇒ A compromised hop can settle a **real, fully proven** swap-in **to itself**. The pool is
unharmed — it got the sats — and **the seller is robbed.** The proof gate does not see this,
because it was never the question the proof answers.

## The ten hop-gated entrypoints, classified

`_onlyHop()` guards ten (`BTCChannels.sol` :884 :988 :1130 :1166 :1291 :1425 :1457 :1774 :1822
:1968). Being hop-gated is not the defect — the hop legitimately relays. The defect is a
**parameter that routes value and is asserted rather than proved.**

| entrypoint | value-routing input | status |
|---|---|---|
| `settleSwapInProven` :1774 | `seller`, `token`, `minDeliveredUsd` | 🔴 **hop's word** (§T2) |
| `settleSwapInBuffered` :1166 | same | 🔴 **hop's word** (§T2) |
| `commitFreshness` :1425 | the freshness outpoint is hop-controlled | 🔴 **one tx revokes every emitted exit** (§T3) |
| *(the BOLT11 rail)* | credits through the unproven `settleSwapIn` | 🔴 **no Bitcoin proof at all** (§E166-2 / §T1) |
| `openChannel` :884 | LP consent | ✅ `LpConsent` — relayed, not manufactured |
| `deliverSwapOutOnchain` :1968 | payout script | ✅ §E184 — cannot pay anywhere but `btcRecipientOf` |
| `reverseSwapOut` :1822 | recipient / size / denomination | ✅ M1#3 |
| `emitDeadManExit` :1291 | the armed shape | ✅ §E165-b — cannot arm a worthless exit |
| `parkProvenSats` :1130 | sats | ✅ proven |
| `splice` :988, `markMigrationNonceUsed` :1457 | — | ⚪ not a credit path; re-check under §T3 |

## The three that remain, and they are ONE change

1. **§T2 — seller-signed EIP-712 intent.** The seller signs `(seller, token, minUsd,
   paymentHash)` off-chain; the contract `ecrecover`s and reads all three from there, so the hop
   supplies only the hash. **Costs no extra transaction** — consent rides WITH the action, the
   same pattern as `OpenAuth.lpSig`.
2. **§T3 — freshness outpoint becomes a 2-of-2 (hop + LP).** Invalidation then needs the LP's
   signature, which is free: invalidation only ever happens when a fresher exit is agreed and the
   LP is signing that anyway.
3. **§E166-2 — the BOLT11 rail anchored to an on-chain splice proof**, so every credit path ends
   in a Bitcoin proof. ⚠️ **Only then does `settleSwapIn` delete** (§T1-BLOCKED) — and its OTHER
   role, the swap-out failure reversal at `:1814` where nothing arrives and nothing is provable,
   is legitimate and **must survive under its own name.**

🔴 **ALL THREE CHANGE `BTCChannels` SIGNATURES, SO PER §ORDER-M1 THEY MUST LAND TOGETHER.** Each
signature change costs Rust encoders + the ABI checker + every test call site (M1#1 cost 13 sites,
§T1-d 8 positional destructurings, §T9 would have cost 17). Landing them one at a time pays that
three times and leaves two half-states in between.

⚠️ **AND THE ORDER IS NOT FREE: §T3 is Phase 3 in `§PHASE-ORDER` because it changes WHAT AN EXIT
COMMITS TO** (`Prevouts::All` binds the freshness UTXO). Batching the signatures does not let it
jump the queue — the batch lands at §T3's slot, not §T2's.

## What is NOT in scope, said plainly

**Service.** A hop can always stop settling, stop emitting, stop routing. That is bounded, never
prevented, and the bound is ladder depth. Removing the hop's WORD does not remove its ability to
do NOTHING, and no signature change will.
