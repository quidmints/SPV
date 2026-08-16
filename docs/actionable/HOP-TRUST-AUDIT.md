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

## 🔴 STOP — READ THIS BEFORE BUILDING §T2's EIP-712 INTENT. THE ATTRIBUTION MAY ALREADY BE PROVEN.

Found while opening `settleSwapInProven` to implement the intent (2026-08-16). **The deposit
address already commits to the payer's key, and the contract already verifies that binding — the
proof is being computed and then thrown away.**

* `ExitLib.swapInDepositKey(internalKey, userRefund, cltvHeight)` builds the taproot output key by
  tweaking `internalKey` with the tapleaf hash of `<cltvHeight> OP_CLTV OP_DROP <userRefund>
  OP_CHECKSIG` (`:163-182`).
* `verifySwapInDeposit` **RECOMPUTES `q` from `userRefund`** and requires the deposit to have paid
  that exact script (`:149-158`) — otherwise `DepositNotPaid`.
* The Rust side agrees and is tested for it: *"deposit_key_is_deterministic_and_index_scoped"*,
  *"distinct_cltv_or_user_yields_a_distinct_deposit_address"*, *"refund_leaf_encodes_cltv_and_user_key"*.

⇒ **WHO PAID IS ALREADY A PROVEN FACT**, bound into the address the sats landed at. What is
missing is only the mapping from `proof.userRefund` (a BIP-340 x-only secp256k1 key) to `seller`
(an EVM address). **Both are secp256k1** — x-only fixes y as even, so the full point is
determined and the address is `keccak(pubkey)[12:]`, computable on-chain in a repo that already
pays for on-chain EC (`MuSig2Agg`, §E129/§E142).

⇒ **IF THAT HOLDS, §T2 IS NOT AN ADDITION — IT IS A DELETION.** `seller` stops being a parameter
and becomes `addressFromXOnly(proof.userRefund)`. No EIP-712 domain, no seller signature, no extra
round trip, and one fewer hop-supplied field instead of several more. **That is standing rule 17:
a root fix makes the previous fix deletable, and the EIP-712 intent would be the clamp.**

### 🔴 CHECKED, AND IT REFUTES THE STRONG FORM ABOVE. Read this before acting on it.

I named the falsifying check and ran it before building on the conclusion. **`user_refund` is
supplied by the CLIENT, in the same request as `seller`, and nothing binds the two.**

`quid-bridge/src/swap_in_api.rs:13` documents the `/swap-in-onchain` body as
`{ …, "user_refund_pubkey": "<32-byte x-only hex>" }`; `:129` is the field, `:243-246` parses it,
`:263` passes it straight into `deposit_for(&secp, &oc.master, user_refund, cltv, network)`. The
Rust helper takes it as a parameter (`swap_in_onchain.rs:314-323`) — it derives nothing.

⇒ **SO "THE ATTRIBUTION IS ALREADY PROVEN" IS TOO STRONG AND IS RETRACTED.** What the deposit
address proves is that the sats paid a script committing to *a user-supplied refund key*. It does
NOT tie that key to the `seller` EVM address the hop names — they are two independent fields of
one request, and `seller = addressFromXOnly(userRefund)` today would credit the EVM address of a
Bitcoin key nobody claims to control.

✅ **THE LEVER SURVIVES, BUT IT IS A CLIENT CHANGE, NOT A CONTRACT-ONLY ONE.** The two keys are
independent *by convention*, not by construction. If the wallet derives BOTH from ONE secp256k1
private key — x-only for the refund leaf, `keccak(pubkey)[12:]` for the EVM address — then the
deposit address commits to the seller by construction, and `seller` deletes from the signature
exactly as described. That is the secp256k1 coincidence this repo already pays for, used at the
place where it actually removes a trust assumption.

🔴 **AND THE CUSTODY DECISION DECIDES WHETHER IT IS AVAILABLE AT ALL** — which is why this
connects to ibiza's wallet work rather than being purely an SPV question:
* **In-app key** (identity-wallet holds its own secp256k1): one key can serve both. **§T2 becomes
  a deletion.**
* **External wallet** (Phantom holds the EVM key): the app cannot extract that private key to
  build a BIP-340 refund leaf from it, so the BTC refund key MUST be separate — and for those
  sessions there is nothing to derive. **§T2 stays a signed intent.**
⇒ **Both are needed unless external wallets are ruled out of the swap-in path.** Decide that
first; it is the difference between deleting a parameter and adding an EIP-712 domain.

### ✅ DECIDED (owner, 2026-08-16): EXTERNAL WALLETS ARE RULED OUT OF THE SWAP-IN PATH.

⇒ **§T2 IS A DELETION.** `seller` comes off `settleSwapInProven` / `settleSwapInBuffered` and is
derived on-chain from `proof.userRefund`. No EIP-712 domain, no seller signature, no extra round
trip, one fewer hop-asserted field. The signed intent is **not** built.

⚠️ **This costs less than it sounds, and the QR work is why.** A BTC-funded entry needs no EVM
transaction from the user at all, so a Phantom user is not shut out of the product — they are
shut out of *this rail's* attribution, and the rail they use instead is the one that already
required no signature from them. Phantom remains supported for redeem / withdraw / leverage,
where `signerKind()` and the honest badge still apply.

🔴 **THE ONE DETAIL THAT WILL BREAK THIS SILENTLY: BIP-340 Y-PARITY.** An x-only key is the
x-coordinate ONLY; BIP-340 resolves the ambiguity by defining the key as the point with **even
y**. An EVM address is `keccak(x ‖ y)[12:]` over the *full* point. **Half of all private keys
produce an odd-y pubkey**, and for those the even-y point is the NEGATION — a different `y`, a
different keccak, and therefore **a different EVM address**.

⇒ **The wallet must define its EVM address as the address of the NORMALISED (even-y) point**, and
sign EVM transactions with `d' = n − d` whenever the raw key is odd-y — the same normalisation
BIP-340 already requires for signing the refund leaf. Get this wrong and it fails for
**exactly half of users**, as credits routed to an address they do not control, with the contract,
the proof and the deposit all correct. There is no on-chain check that can catch it: the derived
address is perfectly well-formed either way.
📌 Rust already has the EVM half (`RootSeed::derive_eth_wallet_key`); the wallet needs the
matching derivation on the TS side, and both must agree on the parity rule or the same seed
yields two different addresses on the two sides.

### ✅ AND THE REST OF IT TOO (owner, 2026-08-16): NOT TAKING THE HOP'S WORD FOR *ANYTHING*.

`token` and `minDeliveredUsd` close by the SAME mechanism, with no signature and no extra
transaction: **put them in the deposit address.** The address is already a commitment — it just
commits to too little.

🔑 **THE DEPOSIT ADDRESS BECOMES THE CONTRACT.** Today `swapInDepositKey` tweaks the internal key
by a SINGLE leaf hash (`MuSig2Agg.sol:191` — `taggedHash("TapTweak", internalX ‖ leafHash)`), and
that leaf is the spendable CLTV refund path. Taproot permits a TREE, so add a second, deliberately
unspendable leaf that commits to the terms:

```
termsLeaf   = OP_RETURN <sha256(abi.encode(seller, token, minDeliveredUsd))>  // never spent
merkleRoot  = TapBranch(sort(tapLeafHash(refundLeaf), tapLeafHash(termsLeaf)))
q           = internalKey + taggedHash("TapTweak", internalX ‖ merkleRoot)·G
```

### 🔴 `seller` GOES IN THE LEAF TOO — AND THAT MAKES THE PARITY RULE OPTIONAL, NOT A PREREQUISITE

Raised by the owner asking whether an LP might link a **Ledger** rather than hold a key in the
app. That question breaks the derivation approach, and in breaking it produces a better design.

⚠️ **A HARDWARE WALLET SEPARATES THE TWO KEYS BY CONSTRUCTION.** Ledger signs Bitcoin and Ethereum
through *different device apps on different BIP-32 paths* (`m/86'/…` taproot vs `m/44'/60'/…`), and
will not sign an EVM payload with a Bitcoin-path key or vice versa. ⚠️ **UNVERIFIED — the linked
DMK page 404s; check against the live docs before relying on it.** But the shape is the same for
Phantom, which holds the EVM key and will not surrender it. ⇒ **For any external signer, "one key,
two identities" is unavailable, and `seller = addressFromXOnly(userRefund)` cannot be computed.**

✅ **PUTTING `seller` IN THE TERMS LEAF COVERS EVERY CUSTODY MODEL AT ONCE.** The payer's own wallet
computes the expected deposit address from the terms it agreed and **refuses to pay if the hop's
quoted address differs** — so the hop cannot substitute a `seller` without the money never
arriving. That binds under in-app keys, Phantom, Ledger, or anything else, and needs no
relationship between the BTC and EVM keys.

⇒ **REVISION TO THE PUBLISHED ORDER: the BIP-340 parity rule is NOT a prerequisite for §T2.** It
already landed (ibiza `bad8176`, 7 tests) and remains correct and useful — one key, two identities,
with the negation trap closed — but §T2 no longer waits on it, and **the batch is now custody-
agnostic**, which is a much better property than a batch that only works for one wallet type.

⚠️ **THE ONE THING THE TWO APPROACHES DO NOT SHARE, and it must be stated:** derivation is enforced
**on-chain**; the leaf commitment is enforced by **the payer checking the address before sending**.
Both bind the hop, but the second assumes the client computes the address independently rather than
displaying whatever the hop returns. **That check is now load-bearing and belongs in the QR
screen** — `requestOnchainSwapIn`'s response must be VERIFIED, never merely rendered.

The contract then recomputes `q` from the terms the hop CLAIMS. **Lie about either field and the
recomputed address is not the one the sats went to — `DepositNotPaid`, on the existing check.** No
new trust, no new round trip, and no new failure mode: the hop's assertion is verified against a
fact the payer fixed when they chose where to send money.

⇒ **With this plus the `seller` derivation above, `settleSwapInProven` takes NOTHING on the hop's
word.** Every value-routing input is either proven by the deposit or derived from it.

📌 **What is actually missing is ~5 lines.** `tapLeafHash` exists (`:169`) and the single-leaf
tweak exists (`:191`); there is **no `tapBranch`**. BIP-341's is a tagged hash over the two child
hashes in lexicographic order — that is the entire addition on the Solidity side.

⚠️ **THREE CONSEQUENCES, none of them optional:**
1. **The refund spend needs a bigger control block.** A 2-leaf tree means the refund path must
   carry the sibling (`tapLeafHash(termsLeaf)`, 32 bytes) to prove membership. Cheap, but it
   changes the witness, and `user_refund_script_path_verifies_and_control_block_belongs_to_the_leaf`
   pins the current shape.
2. **EVERY DEPOSIT ADDRESS CHANGES.** This is a breaking change to the rail: the Rust side
   (`swap_in_onchain.rs:deposit_spend_info`) must build the identical tree, or the address the hop
   quotes and the address the contract recomputes diverge and **every swap-in fails**. Land both
   sides together and test against a real regtest deposit, not a unit fixture.
3. **`minDeliveredUsd` is a QUOTE, so committing to it fixes the price at quote time.** That is
   probably correct — it is what the seller agreed to — but it removes any ability to re-quote a
   stale deposit, and the existing `expiresAt` becomes the only escape. Confirm that is intended
   before building; it is a product decision wearing a cryptographic hat.

📌 `token` and `minDeliveredUsd` are NOT covered by this and remain the hop's word regardless —
the deposit address commits to the PAYER, not to what they were promised. A signed intent may
still be needed for those two, which would make it a much smaller change than the queue describes.

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
