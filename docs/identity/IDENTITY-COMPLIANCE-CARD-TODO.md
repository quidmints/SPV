# Identity-level sanctions exclusion — scoping TODO

Separate workstream from `backend/circuits/PP-NOIR-FUSION.md` (the base Noir/Honk circuit
migration). This tracks: (1) extending PP's address-level ASP screening to real-world
identity-level screening via rarime, gating our own fleet's spend under the payee-of-record model
(see `COMPLIANCE-THESIS.md` — superseded the earlier "anonymized card sign-up" framing: we are the
KYC'd party via our own prepaid-card fleet, not a card issuer being asked to accept a novel
credential from our customers), and (2) the liquidity design needed if the fleet draws dynamically
on an SPV/QUID balance without breaking PP's anonymity guarantees. Not started; this is the
open-questions-first scope.

## 1. What's confirmed (2026-07-01/02 recon)

- **PP's ASP is address/heuristic-level, not identity-level.** The ASP tree leaf is a per-deposit
  pseudorandom `label` (`keccak256(SCOPE, nonce) % FIELD`), not even a raw address. The actual
  screening (which labels get included) is 0xbow's off-chain, proprietary chain-analysis process.
  Zero real-world identity data anywhere in that pipeline today.
- **rarime's circuits have no matching capability today.** No name-hashing exists (name/name_residual
  are raw byte-packed fields folded into the whole-DG1 commitment, never a standalone lookup key); no
  equality/non-membership predicate against an external list exists; the only "fixed-set membership"
  precedent (`citizenship_check`, `query.nr:82-335`) is a linear scan over a ~240-entry country-code
  array *hardcoded at compile time* — structurally nothing like checking against a large, frequently
  updated external list via a tree. This is net-new circuit work, not a wiring task.
- **The reusable piece exists at the Solidity layer, not the circuit layer.** `@solarity/solidity-lib`'s
  `SparseMerkleTree.getProof` already returns real exclusion data (existence/auxExistence/auxKey/
  auxValue). The Noir circuit side (`noir_dl_lib/src/smt.nr`'s `smt_verifier`) has no exclusion path —
  see `PP-NOIR-FUSION.md`'s tracked-gap section. Porting it is tractable (working reference spec to
  translate, same shape as the LeanIMT/commitment ports already done) but not yet started.
- **The hard part isn't cryptography, it's the trust/governance model.** A ZK non-membership proof only
  proves "not present in exactly this canonicalized list as currently published" — it says nothing about
  whether the list itself is complete, current, or correctly matched. Real-world name/DOB/passport
  matching against something like OFAC's SDN list is a fuzzy-matching problem with genuine false-
  positive/negative rates in production KYC systems; match quality is entirely bounded by whoever
  curates and normalizes the list, not something the circuit can improve. This is a legal/liability
  question before it's an engineering one — wrongly clearing someone or wrongly excluding a legitimate
  user are both real, consequential failure modes.

## 2. Blend — investigated and RULED OUT (corrected 2026-07-09)

Blend (@blend_money) was proposed as the accountable off-chain curator. A full adversarially-verified
research pass (105 sub-agents, 676 tool calls, full findings below) found this does not work: Blend is
an **unlicensed** non-custodial DeFi yield-routing protocol (Delaware shell, Panama arbitration) that
performs **standard identity-based OFAC screening — the vendor receives raw user identity directly**,
the exact opposite of the non-disclosure model this design requires. Zero mention of ZK proofs, Merkle
trees, or cryptographic commitments anywhere in their product. **Ruled out, not a candidate.** No
comparable vendor was found either — see `COMPLIANCE-THESIS.md` for the full corrected picture.

## 3. Regulatory path — CORRECTED: this is not an EU-primary question

An earlier version of this doc anchored to EU eIDAS2/EUDI as "the regulatory path that makes this
plausible," including a claim that MiCA Article 70 supports ZK-based identity verification. **Both were
wrong**, discovered via the same research pass:

- **MiCA Article 70 is entitled "Safekeeping of clients' crypto-assets and funds"** — it is entirely
  about custody/segregation, and has nothing to do with identity verification. The earlier claim was a
  factual misattribution to the wrong article, sourced from an industry blog, not the regulation text.
  Retracted.
- **The operating entity is Cayman/BVI, not EU** (QU!D LTD, BVI; Quid Labs, Cayman IBC; QuidMint
  Foundation parent — see `docs/legal.md` in the `old` reference folder). EU eIDAS2's wallet-acceptance
  mandate binds EU-regulated payment institutions; it does not apply to this entity as the primary
  framework. eIDAS2/QEAAs remain a plausible **future** expansion path if the product later serves EU
  users directly, but chasing it now was the wrong prioritization.
- **The actually relevant frameworks**: OFAC's extraterritorial reach (attaches to USD/card-rail
  contact essentially regardless of incorporation jurisdiction) and Cayman (CIMA)/BVI (FSC) AML
  regimes. See `COMPLIANCE-THESIS.md` for the full reasoning and the open-questions list for counsel.
- One genuinely useful finding survives the correction: **OFAC's SDN list is a public US government
  publication** — it does not need a private vendor to curate or attest it. This reframes the whole
  "who is the accountable curator" question; see the compliance thesis document.
- `Eudi.ts` completion is **deprioritized**, not cancelled — it remains a real gap (conceptual shim, not
  built-to-spec) but is no longer on the critical path for this specific workstream given the entity
  correction above.

Full research findings (all four original research questions, confidence levels, sources) are preserved
in the session record; the corrected synthesis is `COMPLIANCE-THESIS.md`, which supersedes this
section's earlier framing as the canonical document for anything shown to counsel.

## 4. A real tension worth stating plainly: pooling vs. "isolated ledger" compliance best practice

From the shared compliance-infrastructure context (fintech/card-issuance industry norms): the argued
best practice for an "earn"/custody product is an **isolated per-user ledger, never commingled** —
"show me the ledger entry for user X's balance" should never require reconstructing it from pool
accounting, because commingled funds create fiduciary exposure and insolvency complexity that fails
institutional/regulatory diligence.

**PP's core privacy mechanism is the opposite of this by design** — there is no anonymity set without
commingled/pooled funds; that's not an implementation detail, it's the entire mechanism. This is a real,
unavoidable tension between "maximize privacy" and "match the isolated-ledger pattern that fintech
compliance diligence rewards," not something a buffer/backstop design resolves. Worth deciding
explicitly, going in, which side of this tradeoff the product accepts, and being honest with any
compliance partner (Blend or otherwise) about it rather than discovering it during diligence.

## 5. Card-drawing liquidity design — decoupling requirements

If a card dynamically draws on an SPV/QUID balance, the design must avoid exact-amount,
precisely-timed correlation between a PP withdrawal/spend and any SPV-side event (this is the same
constraint as the general SPV↔PP treasury integration — see `PP-SPV-BUFFER-DESIGN.md` for the full
spec). Summary: the card must be funded from PP's own pre-funded buffer, never a synchronous SPV draw
per spend; PP's own backstop (an independent Aave/Morpho credit line, not any SPV-coupled mechanism)
absorbs buffer-exhaustion tail risk; card top-ups are batched/scheduled/jittered like any other buffer
refill.

## 6. Scope verdict (corrected 2026-07-09) — see `COMPLIANCE-THESIS.md` for the canonical version

This is not a side workstream — it is the load-bearing question for the whole wallet's product purpose
(a wallet whose funds cannot be spent is a protocol demo, not a product). The engineering pieces that
do NOT depend on it (Noir/Honk migration, PP↔rarime enclave-rooted note fusion, the treasury buffer
design) are separately valuable and already progressing. Under the fleet/payee-of-record model
(`COMPLIANCE-THESIS.md`), spending itself no longer needs this feature to be usable at all — we settle
with customers directly and fulfill purchases via our own fleet. The identity-level sanctions-exclusion
circuit now gates *our own fleet's* spend (a real but narrower question), not customer-facing card
issuance. It is genuinely blocked, not on engineering, but on:
1. Cayman (CIMA) / BVI (FSC) AML counsel and US OFAC/sanctions counsel input (see `COMPLIANCE-THESIS.md`
   §"Open questions") — not EU counsel, corrected above.
2. Whether operating a payee-of-record/biller-of-record fleet model itself triggers money-transmitter
   or payment-institution licensing (see `COMPLIANCE-THESIS.md` open question 4 — the highest-leverage
   one under the corrected model).
3. The pooling/anonymity-vs-isolated-ledger tension (§4) — `COMPLIANCE-THESIS.md` gives the substantive
   answer (non-custodial pooling ≠ custodial commingling), but it should still be surfaced explicitly to
   counsel, not asserted unilaterally.

**Recommendation:** `COMPLIANCE-THESIS.md` is ready to take to counsel. Circuit/contract code for the
sanctions-exclusion path specifically should wait on that input. The buffer/backstop liquidity design
(§5) has no such blocker and can proceed independently — see `PP-SPV-BUFFER-DESIGN.md`.
