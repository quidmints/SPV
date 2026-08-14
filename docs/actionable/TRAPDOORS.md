# TRAPDOORS — every place the protocol KNOWINGLY trusts something

Audit input, requested 2026-08-12: *"enumerate all the knowing trapdoors we have that were
existing before the #1 and #2 fix and the secp256k1 landing."*

A **trapdoor** here means a capability or an accepted-without-proof input that could move or
mis-account funds if the trusted party misbehaves. Bugs are not trapdoors; these are the
places the design *chose* to trust, plus the privileged powers that exist by construction.

⚠️ **EVERY ROW IS VERIFIED IN THE CODE, NOT READ FROM A QUEUE MARKER.** On 2026-08-12 four
🔴 rows (§E107, §E130, §E142, §E115) turned out to be fixed already, and one enumeration row
was stale *because a third path had been added since it was written*. Re-verify before
acting; the cost is one grep.

`#1` = the phantom swap-in. `#2` = a compromised running enclave image.

---

## T1 ✅ CLOSED — `settleSwapIn` IS DELETED; every credit is now bounded by proof

`BTCChannels.sol:1553`. **This is `#1`, and it is NOT closed — it is NARROWED.**
`settleSwapInProven` (`:1522`) was added and derives the deposit address on-chain from the
pinned `BTC_DEPOSIT_KEY`, so a credit can be *proven*. **But the old unproven entrypoint
still exists beside it and is still callable by the hop.** A compromised hop credits sats
that never arrived and drains `POOLED_USD_BTC` to its liquidity limit.

⚠️ **WORSE IN KIND than a hop stealing its own channels' BTC** — the loss reaches QU!D
holders and other LPs who never opted into enclave trust.

✅ **(E166-2) THE GATE IS NOW OPEN: the LN rail HAS a provable form.** `settleSwapInSpliced`
credits a seller ONLY against sats an SPV-verified grow-splice proves entered custody — and
`sats` is deliberately NOT a parameter, it is `grewBy`, so the hop cannot assert it. A
Lightning HTLC produces no transaction to prove, but the sats become provable the moment the
hop splices them into a channel. Conservation holds: the spliced sats become LP backing while
the seller is paid USD.

▶️ **WHAT REMAINS IS THE DELETION ITSELF.** Its OTHER role already survives under its own
name: `reverseSwapOut` refunds USD the swapper already paid, where nothing arrives and
nothing is provable — and the daemon now calls it (T1-b).

⚠️ **THE CALLER COUNT IN THIS ROW WAS WRONG — THERE ARE THREE, NOT TWO** (verified 2026-08-13
by enumerating, which is the only way this row was ever going to be right):

| caller | destiny | state |
|---|---|---|
| `swap_out_onchain.rs` reversal | `reverseSwapOut` | ✅ done (T1-b) |
| `swap_in_onchain.rs` on-chain deposit rail | `settleSwapInProven` | ✅ done (T1-c) |
| `swap_in.rs` LN rail | `settleSwapInBuffered` | ✅ done (M1#1) |

⇒ **TWO OF THE THREE ARE OFF THE PHANTOM, AND `EvmClient` IS NOW THE LN RAIL'S TRAIT ALONE**
(verified by enumeration: `swap_in.rs` is its only remaining production consumer). The
on-chain rail now hands the contract a transaction and an SPV proof, and the contract derives
the sats and dedups on the **txid** it computes itself.

✅ **AND THE LN RAIL IS DONE TOO (M1#1, 2026-08-14) — the ordering conflict dissolved rather
than being traded away.** Provability wants the sats in custody BEFORE the credit; atomicity
wants the credit BEFORE taking the seller's sats. **Sats are fungible, so they need not be the
SAME sats:** `parkProvenSats` proves the hop's own BTC into custody AHEAD of demand, and
`settleSwapInBuffered` draws that balance down. Every credit is therefore debited against sats
already proven, while the seller still settles instantly and is never exposed.

🔑 **WHAT THE HOP CAN NO LONGER DO:** conjure sats. `provenSatsAvailable` bounds it, and only an
SPV-proven grow-splice raises that balance. ⚠️ **The bound is on `consumed`, not the request** —
asking for more than you proved is harmless when the pool converts less; the guard fires only
when the pool WOULD convert past the balance.

⚠️ **THE `paymentHash` SURVIVES BUT ITS JOB CHANGED, AND CONFLATING THE TWO IS WHAT MADE THE OLD
ENTRYPOINT A TRAPDOOR.** It is now IDEMPOTENCY ONLY — one credit per HTLC across daemon retries
and restarts, protecting the hop's own balance and the seller from a double payment. It is **not**
what bounds the credit; a value the hop invents never could be. Dropping it entirely was tried and
reverted: the bridge gates restart-safety on `swapInUsed`, so without it a retried submission
credits twice.

▶️ **STILL THE HOP'S WORD (T2), UNCHANGED:** the seller, the token and the USD floor.

## T2 🔴 OPEN — `seller`, `token`, `minDeliveredUsd` are hop assertions

`BTCChannels.sol:1519`, and the code says so: *"STILL TRUSTED, AND NAMED SO IT IS NOT
MISTAKEN FOR PROVEN."* Even on the **proven** path, only *the sats exist and landed at an
address only this protocol controls* is proven. **Who** gets credited, in **which** token,
and the **USD floor** remain the hop's word.

## T3 🔴 OPEN — the shared freshness UTXO is a one-transaction revocation of EVERY escape

One fleet-controlled outpoint is bound into every emitted dead-man exit (BIP-341
`Prevouts::All` commits to all prevouts), so **spending that one UTXO invalidates every
LP's pre-signed exit at once**. That is the intended invalidation mechanism *and* a single
point of revocation for the whole system's escape hatch. Per-channel freshness fee cost is
**unmeasured** (§E166 item 5).

🔴 **AND IT ALMOST GAINED A SECOND TRIGGER (2026-08-13, found by the owner asking what a sweep
is FOR).** `OnchainWallet::create_sweep_tx` calls `build_tx()` directly rather than through the
shared builder, so it did **not** inherit the `unspendable` reservation — despite that helper's
comment promising *"every builder path — including any added later — inherits it"*. A
`drain_wallet()` would therefore have spent the freshness UTXO, and **one authorized sweep would
have silently invalidated every LP's pre-signed exit.** Fixed by applying the exclusion in the
sweep, with a test asserting on the built tx's INPUTS — and mutation-tested: removing the
exclusion makes it fail. ⚠️ The pre-existing test that should have caught it is named
`reserved_outpoint_is_unspendable_by_ordinary_building` — **"ordinary" is exactly the word that
let a drain through.**

## T4 🟡 NARROWED — the fleet held BOTH funding halves

Was `#2`'s core: `deadman_exit.rs` armed the hop signer *and* the vault signer in one
process. **Closed structurally by §E175-a** — the heartbeat's vault is `Option`, and
reverting it does not fail a test, it **fails to compile**. ⚠️ Residual: this is a property
of the *deployment* (the fleet must not hold a vault seed), not of the code alone.

## M1 🎯 THE ACTUAL SECURITY MODEL — every place a MALICIOUS HOP can still take value

Owner, 2026-08-13: *"there should be no attestation gates of any kind anywhere because it's
something a compromised enclave/daemon could replace with malicious code. **there should be no
malicious code attacks possible**."*

⇒ **The invariant is: NO PATH MAY DEPEND ON THE HOP BEING HONEST.** An attestation gate asserts
an address runs approved *code*, which is only as strong as whoever controls the whitelist —
and buys nothing against any of the attacks below, **every one of which is available to a hop
running perfectly attested code**. That is why §E185's unwiring was the right direction and why
T5 is struck: hardening a gate that should not exist is motion, not progress.

**The list, in severity order. This is what "complete the security model" means:**

| # | a malicious hop can… | why | fix |
|---|---|---|---|
| 1 | **conjure USD from nothing** — credit sats that never arrived, draining `POOLED_USD_BTC` | `settleSwapIn` takes the hop's WORD; the loss reaches QU!D holders who never opted into any enclave trust | §T1-e-r pre-proven buffer, then DELETE the entrypoint |
| 2 | **spend any LP's funding UTXO alone** | the fleet process holds BOTH halves of the 2-of-2 (§E175-b: `daemon.rs:235` passes `Some(vault)` unconditionally) | the LP holds its own half — LP-hosted vault or the app |
| 3 | **misdirect a proven credit** — choose the payee, the token and the USD floor | T2: only *the sats exist and landed* is proven | pin what can be pinned (§T1-d: the record has room for `token`) |
| 4 | **revoke every LP's escape in one transaction** | T3: the shared freshness UTXO is bound into every emitted exit | per-channel freshness (fee cost unmeasured) |
| 5 | **void every LP's escape by splicing** | a splice rotates the funding outpoint, so every armed rung is unbroadcastable, and NOTHING re-arms — see the reopened **T9** | make re-arming atomic with the splice |

⚠️ **Note what is NOT on this list: anything an attestation gate would have stopped.** That is
the whole argument.

## T5 ✅ GONE — the attestation registry is DELETED, not merely unwired

**Was:** *enclave image rotation has no TTL and no timelock*. Both were true of
`AttestedHopRegistry`, and I implemented them before the owner's direction made the work
misdirected. **The contract and its test file are now deleted outright (2026-08-14).**

⇒ **There is no attestation gate anywhere in this protocol.** §E185 removed every call site;
this removes the thing they called. Nothing referenced it but comments, and those are corrected.

🔑 **WHY, in the owner's terms:** *"there should be no attestation gates of any kind anywhere
because it's something a compromised enclave/daemon could replace with malicious code. there
should be no malicious code attacks possible."* An attestation gate asserts an address runs
approved CODE — only as strong as whoever controls the whitelist, and worthless against every
attack in §M1, each of which is available to a hop running perfectly attested code.

⚠️ **TWO THINGS THE DELETION DOES NOT DO, said plainly:** it does not remove the enclave from
the deployment (seeds are still sealed, `MigrationAuth` still governs export — that is T10), and
it does not by itself make any path trustless. **The invariant is §M1's — no path may depend on
the hop being honest — and it is met by proof, custody and pre-signed escapes, never by a gate.**

⚠️ **Kept from the reverted TTL/timelock attempt, because it was nearly shipped as settled:** the
grant-delayed / revoke-instant asymmetry is NOT free. Instant revocation is a global, no-notice
halt that also disables `emitDeadManExit`. That was an argument for having no such gate — which
is now the state.

## T6 🟡 BY DESIGN — pin-once deployer powers

`Core.setBtcVault` (`Core.sol:577`) is `DEPLOYER`-gated **and** pin-once
(`BtcVaultPinned`). Same shape elsewhere. Not a standing power — a one-way wiring step — but
it is a trapdoor **until pinned**, and nothing forces pinning before use.

## T7 ✅ CLOSED — `openChannel` had no hop gate

`_onlyHop()` guarded seven entrypoints and `openChannel` was **not** one of them; its only
hop-side gate was `_requireAttested`, a **no-op** while the registry was unpinned. Closed by
§E185. **A no-op reads like a check, which is why it survived.**

## T8 ✅ CLOSED — `btcRecipientOf` proved on-curve, never controlled

An LP (§E138) or a swapper (§E184) could pin a valid-but-not-theirs x-only key; ~half of
arbitrary 32-byte values are valid points, so ~half of typos land funds on a key someone
else may hold. Closed by proof-of-possession, and for swap-out by **deriving** the
destination from the registered key rather than accepting one.

## T9 🔴 REOPENED — a SPLICE silently voids the whole exit ladder (M1#5)

Arming is a construction-time invariant **at open only** (§E156/§E165): `openChannel` verifies a
pre-signed ladder, so a channel cannot be CREATED without a recovery path.

🔴 **BUT A SPLICE DESTROYS IT, AND NOTHING RE-ARMS (verified 2026-08-14).** `_armDeadManExit`
checks every rung against `channels[cid].fundingTxId` / `fundingVout` / `amountSats`; a splice
rotates all three. Every rung armed at open therefore spends a **spent outpoint** and attests a
stale amount — it is not merely short, it is **unbroadcastable**. And `_armLadder` has exactly one
caller: `openChannel` (`:882`). Four entrypoints rotate the outpoint — `splice`,
`settleSwapInSpliced`, `parkProvenSats`, `deliverSwapOutOnchain` — and **none of them re-arm.**

⚠️ **THE HEARTBEAT NORMALLY HIDES THIS**, which is why it survived: `emitDeadManExit` re-arms
against the current outpoint every tick, so an honest fleet leaves only a one-tick window. **But
the hop chooses when to splice.** A malicious hop splices and stops emitting, and the LP has no
escape at all — attacker-controlled, which is exactly the M1 criterion (*no path may depend on the
hop being honest*).

⏸️ **THE FOUR-ENTRYPOINT VERSION IS NOT WRONG — IT IS SECOND. SETTLED 2026-08-14** after the
owner twice refused to let *"probably the wrong shape"* stand as an answer.

**The two mechanisms cover DIFFERENT failure cases, so neither replaces the other:**

| mechanism | protects | how |
|---|---|---|
| **LP-side refusal** — don't co-sign a splice without a fresh exit | a **LIVE** LP | it holds the bytes and broadcasts them itself; a hop cannot splice without handing them over |
| **on-chain arming** at the splice | an LP that is **GONE** | it is the only thing that makes the bytes PUBLIC (`DeadManExitEmitted`), which is what lets ANYONE broadcast — the dead-man premise |

⇒ **The residual after LP-side refusal alone is narrow but real: the LP is dead AND the hop never
emitted after the splice.** Nothing forces the emission today — the heartbeat does it by habit,
and habit is exactly what a malicious hop drops. Making arming atomic with the splice is the only
way to force it, which is why the recipe below stays.

⚠️ **AND IT CANNOT BE CIRCULAR, WHICH WAS THE OTHER WORRY:** the splice tx is negotiated, so its
txid is known once both parties sign; the exit for the post-splice state can therefore be signed
BEFORE the splice is broadcast, and submitted with it.

🔑 **THE FACT THAT DECIDES IT: A SPLICE SPENDS THE 2-of-2 FUNDING UTXO.** `WrongPrevOutpoint`
says so — *"tx doesn't spend this channel's funding UTXO"* — and `SpliceKeyNotTwoOfTwo` requires
the new output to be `KeyAgg(lpPubkey, hopPubkey)`. **A splice therefore CANNOT HAPPEN without
the LP's own signature.** The LP is already in the loop for every rotation.

⇒ **The property belongs in the LP's validating signer, not in the contract: refuse to co-sign a
splice until a valid signed exit for the POST-splice state is in hand.** That is enforced exactly
where the LP's interest lives, costs no ABI change, no Rust encoder change and none of the 17
test sites — and it is what `validating_signer.rs` exists for. A malicious hop then cannot splice
at all without handing over the replacement escape first.

⚠️ **AND IT ONLY MATTERS AFTER M1#2.** Today the fleet holds BOTH halves (`daemon.rs:235`), so it
can spend the funding output outright and the ladder is moot regardless of how it is armed. **The
on-chain arming cannot fix a hole that exists because one party holds both keys.** ⇒ **M1#2 is the
keystone, and T9's real fix is downstream of it** — which also means the four-entrypoint change
would have been built, tested and shipped while still not closing the attack it names.

📋 **WHAT THE CHAIN STILL UNIQUELY PROVIDES, and the only part worth keeping on-chain:** PUBLIC
availability of the exit bytes (`DeadManExitEmitted`), so a third party can broadcast for an LP
that is itself gone. LP-side refusal covers the LP-is-alive case completely (it holds the bytes
and can broadcast); the public emission is the backstop for the case where the LP is dead too,
which is the same case the dead-man design already targets. That is a far smaller requirement
than "every splice entrypoint takes a ladder".

✅ **The heavier version IS built and measured** — see the recipe below — so if defence-in-depth
is wanted later it is a paste, not a design. But it should not be the first move.

## T10 🔴 OPEN — `MigrationAuth`: a 2-of-3 Safe can export the enclave seed

**This document existed for a day without its most powerful row, and it was found by the owner
asking why an answer was about LPs when the question was about migration authority.** Zero
matches for "migration" in this file before 2026-08-13.

`migration.rs` — the foundation's **operator Gnosis Safe** (n-of-m, EIP-712 `MigrationAuth`,
verified in-enclave by `ecrecover` against a sealed snapshot of the Safe's owner set) authorises
a successor enclave, and the old enclave **exports its seed to it**. The code says the
consequence outright: forging a 2-of-3 lets you *"redirect the seed export (total enclave
defeat)"*.

⇒ **Whoever holds that quorum holds the hop's seed, and therefore the hop half of every
channel.** And because the fleet's vault seed is an HKDF sibling of the hop's (§E175-b, and
deliberately so), that same quorum today holds **both** halves of every 2-of-2.

⚠️ **THIS IS NOT FIXED BY PER-LP CUSTODY — AND IT IS EXACTLY WHAT PER-LP CUSTODY BOUNDS.** Who
holds the LP half is a different question with a different answer (the LP). The relationship is
one of *blast radius*: with the halves as they are, a Safe compromise can spend **every LP's
funding UTXO**; with the LP holding its own half, the same compromise yields the hop side only
and **cannot spend an LP's UTXO alone**. Neither fact substitutes for the other.

🔴 Residual, separate from the above: `OPERATOR_SAFE`/`OPERATOR_OWNERS` still ship as the
well-known addresses of **secp256k1 secret keys 1/2/3**. `guard_prod_trust_anchors` refuses to
boot staging/prod with them, which is the right shape — but the real values *"MUST replace these
before mainnet"* and have not. There is also **no timelock** on a migration, same gap as T5.

## T11 🟡 BY DESIGN — an LP holding a real half can GRIEF, and that is the trade

Enumerated because introducing per-LP custody **creates** this: today the LP holds no key, so it
cannot misbehave at all. With one half of the 2-of-2 an LP **cannot steal** — spending the
funding UTXO needs both halves, splice outputs are bound to the new funding output or
`btcRecipientOf` (`ForeignSpliceOutput`, the cross-LP-theft guard), and swap-out proceeds are
pinned to recorded state. What it **can** do:

1. **Refuse to co-sign** — no splices, no cooperative close, no new ladder rungs. Its own channel
   freezes and cannot source swap-out BTC; the protocol degrades to `reverseSwapOut` refunding
   the swapper, so this is **capacity loss, not a loss of funds**. §E187's answer is ladder depth.
2. **Broadcast a REVOKED commitment** — the classic LN theft attempt, defended by LDK's justice
   path **only while the hop is online within the CSV window**. ✅ **CHECKED, not assumed
   (2026-08-13):** `node.rs` wires a real `ChainMonitor` built over a live `TxBroadcaster`
   (`:784`, `:774`) plus an LDK resync path (`ldk_resync_tx`), so the penalty machinery is
   present and standard. **What is NOT verified is the liveness assumption it rests on** — that
   the hop is online and chain-synced inside the CSV window — which is the part per-LP custody
   makes newly load-bearing.

⚠️ **AND THE OBVIOUS PLACE TO LOOK FOR THAT DEFENCE IS THE WRONG ONE:** `quid-watchtower` is a
**dead-man-exit** watchtower — *"KEYLESS… broadcasts the already-public signed bytes"*. It does
**not** watch for revoked commitments and cannot produce a justice transaction. A name that reads
like LN penalty coverage while providing none is the §E185 no-op shape again. ▶️ Before per-LP
custody ships, settle who runs penalty coverage and with what liveness assumption.

⇒ **The trade is fleet-can-STEAL → LP-can-GRIEF, and it is a good one** — griefing is bounded and
recoverable, theft is neither — but it must be booked, not discovered.

---

## The secp256k1 items — 6, verified, not 7

Enumerated in §E138's row and checked against `evm/src` (§E183):
`_proveFundingKeys` + splice KeyAgg · exit-tx Schnorr · §E130/§E131 curve validity ·
§E138 PoP · §E159 swap-in deposit derivation · delete-delegation.

**Every EC consumer in `evm/src` maps to one of those six** — `:1062`, `:1119`, `:1165`,
`:1290`, `:1669`, `:1847`, `:1857`, `ExitLib:123`, `ExitLib:166`. **There is no seventh
USE.** §E131 (swapper script) is part of item 4, which bundles E130+E131.

⚠️ **Item 1 (delete delegation) IS NOT DONE** — `BTCChannels.sol:818` still verifies
`auth.lpSig`. §E157 deleted the delegation *transaction*, not the LP's signature.
