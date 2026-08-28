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
by a SINGLE leaf hash (`BitcoinTx.sol:191` — `taggedHash("TapTweak", internalX ‖ leafHash)`), and
that leaf is the spendable CLTV refund path. Taproot permits a TREE, so add a second, deliberately
unspendable leaf that commits to the terms:

🔴 **SUPERSEDED — ONE LEAF, NOT TWO (2026-08-16). The owner asked "why is there a tapBranch?" and
the answer is that there should not be.** The original text specified a second, unspendable
`OP_RETURN` leaf combined by a merkle branch. It works and it is more machinery than the job
needs. **The terms go INSIDE the refund leaf that already exists**, as a push that is executed and
immediately dropped:

```
depositLeaf = <sha256(abi.encode(seller, token, minDeliveredUsd))> OP_DROP
              <cltvHeight> OP_CLTV OP_DROP <userRefund> OP_CHECKSIG
q           = internalKey + taggedHash("TapTweak", internalX ‖ tapLeafHash(depositLeaf))·G
```

⇒ **WHAT THIS DELETES FROM THE BATCH:** no `tapBranch` on the derivation path, **no 32-byte
sibling in the control block of every refund spend**, and no new primitive to keep in step across
Solidity, Rust and TypeScript. `taprootOutputKeyWithLeaf` is called EXACTLY as it is today — the
Solidity change becomes a leaf BUILDER, not a tree. Cost: 34 bytes of witness on the refund path
only, which is the rare path.
⇒ Spendability is untouched: the leaf still ends with the existing refund script byte for byte
(pinned by a test in `identity-wallet/src/chain/taproot.test.ts`).
📌 `MuSig2Agg.tapBranch` stays — it is correct and cross-checked against `rust-bitcoin` — but
**nothing in the deposit path calls it**, so a second leaf later must be a deliberate decision
rather than a drift. ✅ Reference implementation and 11 tests: ibiza `53d03b4`.

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

⚠️ **CONSEQUENCES UNDER THE ONE-LEAF DESIGN — the first of the original three is GONE:**
1. ~~The refund spend needs a bigger control block.~~ **No longer true.** One leaf means the
   control block is unchanged, and `user_refund_script_path_verifies_and_control_block_belongs_to_the_leaf`
   keeps its shape. This was the main cost of the two-leaf version and it is simply removed.
2. **EVERY DEPOSIT ADDRESS STILL CHANGES.** The leaf script grows a 34-byte prefix, so the leaf
   hash — and therefore the address — moves. The Rust side (`swap_in_onchain.rs:deposit_spend_info`,
   `refund_leaf`) must build the identical script or the address the hop quotes and the address the
   contract recomputes diverge and **every swap-in fails.** Land both sides together and test
   against a real regtest deposit, not a unit fixture. ▶️ The seam to use is
   `quid-bridge/tests/hop_bridge_e2e.rs` with its `EvmClient` pointed at anvil instead of stubbed.
3. **`minDeliveredUsd` is a QUOTE, so committing to it fixes the price at quote time.** Probably
   correct — it is what the seller agreed — but it removes any re-quote of a stale deposit, leaving
   `expiresAt` as the only escape. A product decision wearing a cryptographic hat; confirm before
   building.
4. **THE ENFORCEMENT POINT IS THE CLIENT, NOT THE CHAIN.** Because `seller` is committed rather
   than derived, nothing on-chain rejects a substituted one — **the payer's wallet refusing to pay
   an address it did not compute is what binds the hop.** That check is booked as constraint 4 on
   ibiza's QR item. ⚠️ A screen that renders the hop's address provides NO protection while looking
   exactly like one that does.

## ▶️ Still owed, and not booked anywhere else

* **A shared leaf fixture across all three implementations.** `tapBranch` is agreed by four
  (Solidity, python, rust-bitcoin, TS); a full `depositLeaf` is agreed by **one**. Pin one script
  in all three suites before an address is trusted end to end.
* **`@scure/btc-signer` in the wallet** for TapTweak + bech32m — the QR verifier stops at the leaf
  hash without it.
* **Rust-side BIP-340 parity** (`RootSeed::derive_eth_wallet_key`). ⏬ **Downgraded from blocking
  to optional**: it mattered only while `seller` was DERIVED from the refund key. Under the
  committed-terms design the two keys need no relationship, which is what makes the batch work for
  Ledger and Phantom. Keep the rule for wallets that DO use one key; it is no longer a prerequisite.
* 🔴 **THE CRE / ASP-versus-DON QUESTION IS UNFINISHED AND IS BOOKED NOWHERE ELSE.** Discussed
  twice this session and never concluded. What IS settled: the mechanism's POLARITY fixes the
  failure direction independent of how the set is populated (exclusion fails open, inclusion fails
  closed), **one inclusion term poisons a whole conjunction**, and fuzzy multi-document identity
  cannot be an exclusion predicate because exclusion proofs need a canonical key. What is NOT
  settled: **whether a DON can carry seed-set publication without becoming the authority the
  exclusion design removed, and how anyone verifies a DON is actually decentralised.** ⚠️ This is a
  design conversation, not a build, and it gates ibiza's `2.18gz-unify` and `court.sol`.

## 🔴 §HOP-RCE — WHAT SURVIVES ARBITRARY CODE EXECUTION *INSIDE* THE DAEMON (2026-08-28)

Owner's threat model, and it is the right one: *"if the daemon is hacked and arbitrary source code
can be injected into its process, none of these existing operations [may] end maliciously."*

⚠️ **ATTESTATION DOES NOT ANSWER THIS AND MUST NOT BE CITED AS IF IT DID.** `MRENCLAVE` is measured
at LOAD. A memory-safety bug exploited at runtime leaves it unchanged, so the compromised process
still produces VALID attestations and still holds the sealed keys. Every bound below therefore has
to be an on-chain or protocol-level one; "the enclave is attested" is not a bound.

⭐ **THE ONE CONSTRUCTION IN THIS TREE THAT SURVIVES IT IS `QUID_SWEEP_AUTH`** — the destination
lives in an operator-signed bundle verified against `OPERATOR_OWNERS`, keys the daemon does not
hold: *"the host can choose WHETHER to sweep, never WHERE."* **That is the shape the two DoS/guard
findings below want.**

### Dismissed with evidence — do not re-book these

| surface | why it is NOT an exposure |
|---|---|
| **All 10 keeper selectors** (`rebalance`, `rebalanceMany`, `cascadeDelever`, `protectFromQuid`, `compound`, `syncLev`, `leverBorrow`, `deleverWithdraw`, `repay`, `rebalanceWbtc`) | **Every one is `external nonReentrant` with NO caller gate — permissionless by design (§84).** The hot key confers ZERO privilege; a compromised daemon can do exactly what any address can already do. `minOut` is FLOORED against the TWAP inside the contract (`LevMath.sol:314`, `:323` *"the oracle floor always wins"*), so a caller can only make it STRICTER; `dex` is a path with the router pinned to `ONEINCH_ROUTER`; and `debtDelta(..., _bandFor(lp, e0))` returns 0 inside the no-trade band, so repeated calls cannot grind. **Residual ≤ `SELL_SLIP_BPS` (1%) per GENUINE rebalance via route choice — a permissionless-function property, not a compromise one.** |
| **`addBlockHeaderBatch`** | **Fully permissionless** (`SPVGateway.sol:133`, no caller gate) and every header is checked against PoW target, epoch retarget, median-past-time and cumulative work. A compromised hop can only submit headers that satisfy Bitcoin consensus. **It is in the signer allowlist because the daemon SENDS it, not because it is gated.** |
| **`openChannel` claim path** | §LAZY-OPEN converted this from "a hop that declines strands the LP" into "custody is booked as `pendingClaimSats`, and **anyone** may credit it" (`BTCChannels.sol:1018` try/catch, `:588` permissionless `registerChannelClaim`). Refusal is now DELAY, not loss. |
| **LP channel funding half** | 2-of-2 MuSig2, and `QUID_FLEET_COHOSTS_VAULT` defaults **false**. ⚠️ **BUT SEE THE CRITICAL ROW BELOW — this is safe only while that stays false.** |

### 🔴 CRITICAL — one boolean decides whether the 2-of-2 is real

`QUID_FLEET_COHOSTS_VAULT=true` makes the fleet hold BOTH halves of every channel, and `vault.rs`
says so outright: *"one custodian, one secret … the 2-of-2 is NOMINAL in this deployment."* Then:
*"A compromised enclave could spend every channel's funding output, and no contract change reaches
that — the Bitcoin UTXO does not care what Solidity believes."*
⇒ **This is the highest-severity item in the audit and it is a DEPLOYMENT SETTING, not code.**
▶️ **Fix: assert it at boot against the attestation policy** so a co-hosting fleet cannot present
itself as a split-custody one. Default-false is necessary and not sufficient — rule 3's inverse
applies exactly: violating this is SILENT.

### 🔴 §HOP-RCE-1 — `emitDeadManExit` has NO FRESHNESS BINDING, so LP protections are hop-erasable

`_armDeadManExit` verifies structure, BIP-341 sighash and BIP-340 signature against `Q`, and
`if (paid < exit.checkpointSats) revert ExitUnderpaysCheckpoint()`. **What it does NOT check is that
the arming is CURRENT.** Any previously-signed arming for the same funding outpoint re-verifies
forever, and the refresh path then does two destructive writes:
1. `checkpointOf[channelId] = exit.checkpointSats` — **UNCONDITIONAL, so it ratchets DOWN.** The
   stale-close guard rejects a cooperative close paying less than the attested balance, so lowering
   it re-permits closes that guard exists to reject.
2. `paidOutSinceCheckpoint[channelId] = 0` — erases the record of payouts since the checkpoint.
⛔ **THE ASYMMETRY IS DELIBERATE AND ITS JUSTIFICATION ASSUMES AN HONEST HOP.** `_armLadder` takes
the MAX (`uint hi`) for precisely this reason, and the refresh path's comment says *"That is why the
ladder takes a max and this does not — they mean different things by 'attested'."* True under an
honest hop; false under this threat model.
✅ **Bounded by `exitArmedOnOutpoint[_currentOutpointKey(channelId)][deadline]`** — replay is confined
to the CURRENT funding scope, so a splice/rotation invalidates old armings.
▶️ **Fix: `require(exit.checkpointSats >= checkpointOf[channelId])` on the refresh path** — the same
rule the ladder already enforces. ⚠️ Verify against the stated motivation first (*"the balance may
have DROPPED"*): if a legitimate decrease exists, it needs LP participation, not hop discretion.

### 🔴 §HOP-RCE-2 — `commitFreshness` is a ratchet with NO CEILING and NO RESET

`commitFreshness(channelId, seq)` (`_onlyHop`) and `commitManagerFreshness(seq)` (self-scoped by
`msg.sender`, correctly) are strictly monotonic and unbounded above. A compromised hop writes
`seq = type(uint64).max`. On reboot the enclave *"reads `freshnessSeq[channelId]` and refuses a
locally-loaded monitor whose `update_id` is behind"* — which is now every monitor that will ever
exist. **The channel becomes permanently unloadable, on-chain, irreversibly.**
⛔ **AND IT IS NOT SELF-LIMITING: it poisons the SUCCESSOR enclave too.** Migration carries the seed,
not a way to lower the counter, so a compromise that lasts one transaction disables the channel for
every future enclave. Funds are not stolen; the channel is bricked and only the ladder/force-close
path remains.
▶️ **Fix: bound the jump (`seq <= freshnessSeq[id] + MAX_FRESHNESS_JUMP`)**, or an operator-signed
reset in the `QUID_SWEEP_AUTH` shape. The first is smaller and keeps monotonicity intact.

### 🟠 §HOP-RCE-3 — `settleSwapInBuffered`: value IS divertible, bounded by in-flight proven sats

The anti-conjuring design HOLDS and should not be re-litigated: `provenSatsAvailable[msg.sender]`
can only be raised by an SPV-proven splice, `consumed > avail` reverts, and `paymentHash` gives
idempotency. *"It can no longer conjure the SATS."*
🔴 **But the hop NAMES THE SELLER, and nothing binds `seller` to the party that paid the HTLC.** A
compromised hop names ITSELF and takes the USD for sats a swapper really sent. **The pool stays
solvent — sats in, USD out — so no invariant fires; the SWAPPER is the victim**, which is why no
protocol-level check catches it.
✅ **Bounded by proven-but-uncredited inventory, NOT by pool size.** The exposure is in-flight
swap-in volume, and it is capped by how much the hop has proven and not yet credited.
▶️ **Fix requires binding the credit to the LN preimage/route rather than to a hop-supplied address**
— a real design change, not a guard. Book it before assuming the bound is acceptable.

⚠️ **NOT AUDITED, and named so it is not mistaken for cleared:** the ibiza WITHDRAWAL AGGREGATOR —
its signing chokepoint has not been located, and whether it passes through `EvmTxPolicy` at all is
unestablished. Also unexamined: `splice`, `recordClose`, `recordForceClosePermissionless`,
`deliverSwapOutOnchain`, `reverseSwapOut`, `settleSwapInProven`, `markMigrationNonceUsed`.
