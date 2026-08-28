# Compliance-by-construction: the product thesis for the QU!D wallet

**Purpose of this document.** This is the argument to be tested with Cayman/BVI corporate counsel and
US OFAC/sanctions counsel before further product work is justified. Under the fleet/payee-of-record
model (below), we are not asking any external card issuer to accept a novel KYC substitute — we
operate our own prepaid-card fleet and merchant relationships as the KYC'd party, so the primary
audience for this document is our own compliance counsel, not a third party's diligence team. It
states one claim precisely, shows the concrete mechanism behind each part of it, and separates what is
built-and-verified from what is designed but unbuilt from what is genuinely open. Nothing here should
be read as a legal opinion — it is the technical case a lawyer needs in order to form one.

## The claim

A wallet is only as useful as the money inside it is spendable. Spendability in the real world runs
through a card, and a card runs through an issuer's compliance diligence. So the actual product being
built is not "a private wallet" — it is a wallet that can make a credible, examinable case that it is
**more** compliant than a conventional custodial neobank, while still delivering genuine self-custody
and transaction-level privacy: no party — not us, not an issuer, not an observer of the chain — can
link a specific withdrawal to the deposit that funded it, and no party ever custodies user funds or
retains user identity data.

Concretely: **every spend carries a cryptographic proof that the spending identity is not sanctioned
and that the funds being spent trace to screened-clean provenance — verified fresh, at the moment of
the transaction, not once at onboarding and then trusted indefinitely.** That is a strictly stronger
compliance posture than the batch/periodic KYC model most neobanks run, not a weaker one traded off
against privacy.

## Why this is the actual differentiator, not just a nice property

The recurring failure pattern behind neobank/card-program collapses (Wirecard, FTX, Binance losing
card-network relationships, KAST's December 2025 custodial-terms controversy) is one of two things:
(a) custodial commingling that creates counterparty and insolvency exposure users don't see until it's
too late, or (b) KYC/AML that is real at onboarding and stale by the time it matters — a snapshot, not
a continuous property.

This architecture is built to avoid both, by construction rather than by policy:

- **Not custodial, even though funds are pooled.** PP's privacy mechanism requires pooling — there is
  no anonymity set without commingled funds, that's the mechanism, not a bug. But pooling here is not
  the same failure mode as custodial commingling: nobody but the holder of a given note's secrets can
  ever authorize its withdrawal. Pooling affects who can observe a link between deposit and withdrawal;
  it does not create a third party with the power to move, freeze, or lose user funds. This is the
  honest answer to the "isolated ledger vs. pooled vault" tension the fintech-compliance literature
  raises — it's a different axis (custody) from the one pooling touches (observability).
- **Continuous, not periodic, compliance re-verification.** Every transaction re-proves the compliance
  property cryptographically, rather than relying on a KYC check performed once and never re-checked in
  real time. This is precisely the gap the industry's own commentary identifies as the actual cause of
  enforcement failures (Starling Bank's £29M fine for zero individual sanctions alerts over six months
  is the canonical example of what batch screening misses).

## The spending mechanism: we are the payee of record, not the customer

This is the answer to "how does money actually leave the wallet and become a flight, a stay, a
purchase" — and it resolves the large-purchase question from earlier drafts of this thesis directly,
rather than deferring it to a future tier.

**Scope correction:** the primary use case is fleets — we operate our own fleet of prepaid card
instruments as a business — not individual family/retail card issuance to end customers, though the
underlying architecture supports that later without change. This removes the hardest part of the
original problem: **we never issue, recycle, or manage a KYC'd payment instrument in a customer's
name, because customers never hold one.**

**The mechanism:**
1. We are the **payee of record** for every customer request. A customer's PP-private funds settle
   with *us*, cryptographically — never with a merchant, never with a KYC'd rail directly.
2. We fulfill the request — a flight, an Airbnb stay, any real-world purchase — **ourselves, as the
   business**, using our own fleet of prepaid card instruments stacked together to cover the amount,
   and/or direct business accounts with merchants (an airline, Airbnb) where *we* are the KYC'd,
   billed party of record. For merchants without a clean resale API (Airbnb notably has none), this
   means scraping listings/pricing to know what to buy, then booking and paying directly through our
   own account, and separately invoicing the customer for the service.
3. The customer never touches, and is never the named holder of, a KYC'd payment instrument or a
   KYC'd merchant relationship. What the customer holds is an internal, wallet-tracked claim, settled
   against our real purchase.

**This is structurally identical to a pattern already built and running in the SPV codebase**, not a
novel invention: `Vault.sol`'s `vBTC` is a synthetic, sats-denominated token minted only against
cryptographically *attested* real BTC (proven via `BTCChannels`/enclave/`lpAuth`) — its ERC-4626
valuation face uses WBTC purely as a pricing/interface reference; real WBTC is never custodied or
touched. The real, attested position sits on SPV's side; what circulates for the LP is an internal
synthetic claim reconciled against it. The travel-purchase mechanism above plays the identical role:
the real, KYC'd position (the airline ticket, the Airbnb booking, the prepaid-card stack that funded
it) sits with us; what the customer holds and spends is the internal claim, compensated against it —
never a pass-through to the KYC'd merchant relationship.

**Why this dissolves the earlier "what about large purchases" open question**, rather than just
narrowing it: there is no tier at which a customer needs to step up to their own disclosed KYC,
because a customer's payment instrument is never the thing touching the merchant. The three-tier
model in an earlier draft of this document (no-KYC prepaid / mid-tier exclusion-proof / opt-in
disclosed KYC for large purchases) is superseded by this — the identity-level sanctions-exclusion
layer still matters (see below), but it gates *our* fleet's spend and *our* relationship with the
customer, not a graduated customer-facing KYC ladder.

## The three-layer mechanism

| Layer | What it proves | Status |
|---|---|---|
| **rarime** | The transacting identity holds a valid, unrevoked government-issued document, and satisfies arbitrary disclosed/undisclosed predicates over it (age, nationality, validity window) — without revealing the underlying identity to any counterparty. | Circuits compile clean under the pinned toolchain (nargo 1.0.0-beta.13 + bb 1.2.0); full proving with real passport data not yet exercised (see Open Items). |
| **PP (Privacy Pools fork)** | The spent funds trace to a deposit that passed the Association Set Provider's screening (today: address-level chain-analysis heuristics, 0xbow's existing, live mechanism) — without revealing which deposit. | Live mechanism, forked and folded into this stack, compiling and testing green (49/49 Forge tests as of this session). |
| **Identity-level sanctions exclusion (new, unbuilt)** | The transacting *identity* — not just the deposit address — is not on a sanctions list, proven as a zero-knowledge non-membership proof against a Merkle-committed list, entirely client-side. | Designed, not built. This is the layer that closes the gap between "address wasn't flagged" (existing) and "person isn't sanctioned" (new). See below. |

### The sanctions-exclusion layer, specifically

The mechanism does not require a compliance vendor to ever receive a user's identity. **OFAC's SDN
list is a public US government publication** — it does not need a private intermediary to curate or
attest it. The design: commit the published list to a Merkle tree, publish the root, and each user's
device (running the rarime circuit) proves non-membership of their own normalized identity hash
locally — no query, no identity disclosure, to us or anyone, ever. This is the same pattern PP's own
ASP already uses (0xbow publishes a root; users prove membership against it without anyone learning
who deposited).

The cryptographic primitive this needs (an SMT non-membership/exclusion proof in Noir) does not exist
yet in the forked circuit stack — `smt_verifier` in `noir_dl_lib/src/smt.nr` only proves membership
today. The on-chain Solidity reference implementation this would port from already exists and works
(`@solarity/solidity-lib`'s `SparseMerkleTree.getProof`, vendored and in use in this stack today).
Porting it is scoped and tractable; it has not been started, deliberately, until the questions below
are answered — building the crypto for a list nobody can legally publish or attest is wasted work.

## Entity and regulatory context (grounding this correctly, not aspirationally)

The operating entity is **QU!D LTD (BVI)**, owned by **Quid Labs (Cayman IBC)**, under the **QuidMint
Foundation**. This is not an EU entity, and an earlier draft of this compliance thesis incorrectly
anchored to EU eIDAS2/MiCA as the primary applicable framework — that was wrong and has been corrected
here. `docs/legal.md` (a separate, adjacent workstream) documents an extensive US federal securities
analysis (Howey, the GENIUS Act, Section 17, SEC precedent) for the token/basket side of this
ecosystem — that analysis is not this document's subject, but it confirms where the real regulatory
exposure and existing legal investment actually sit: US federal law and Cayman/BVI corporate/AML
regulation, not EU digital-identity law.

The practically relevant frameworks for the sanctions-exclusion question are therefore:
- **OFAC's extraterritorial reach** — sanctions screening obligations attach to USD/US-financial-system
  contact (which any Visa/Mastercard-rail card product realistically has) essentially regardless of
  where the issuing entity is incorporated. This is very likely the actual hard requirement, not an EU
  wallet-acceptance mandate.
- **Cayman (CIMA) / BVI (FSC) AML regimes** — both FATF-aligned, both requiring sanctions screening,
  generally lighter-touch than direct EU or US retail regulation but not zero.
- EU eIDAS2/QEAAs may be a credible **future expansion path** if/when this product serves EU users
  directly, but it is not the primary path for this entity today, and no precedent was found (see
  research below) for a QEAA structured the way this design would need regardless.

## What was checked and ruled out (2026-07, full findings in `IDENTITY-COMPLIANCE-CARD-TODO.md`)

A thorough, adversarially-verified research pass (105 sub-agents, 676 tool calls) found:
- **Blend (@blend_money)** is not a fit — an unlicensed, non-custodial DeFi yield-routing protocol that
  performs standard identity-based OFAC screening (the vendor receives raw identity data), the opposite
  of the non-disclosure model this design requires. Ruled out, not a candidate.
- **No vendor found anywhere**, including the closest real analogue (Holonym/Human ID), offers a
  "publish a committed list, verify client-side, never receive identity" product today. This appears to
  be genuinely novel, not merely hard to find.
- **MiCA Article 70** is about custody/safekeeping of client assets, not identity verification — an
  earlier claim citing it as supporting ZK-based KYC was a factual misattribution, now corrected.
- **eIDAS2 QEAAs** are a real mechanism (a certified Qualified Trust Service Provider can issue
  attestations of arbitrary facts) but no precedent was found for one structured around a committed
  list rather than a per-person claim, and — per the entity-context correction above — this is not the
  primary applicable framework for a Cayman/BVI entity in any case.
- **No real, currently-operating card issuer** was confirmed to accept a ZK/selective-disclosure
  credential in place of direct KYC today. This is an absence-of-evidence finding (low confidence in
  either direction), not a confirmed non-existence — and it is now **moot** under the fleet/payee-of-
  record model above: we no longer need any card issuer to accept a novel KYC substitute for our
  customers at all.

## Open questions — for counsel, not resolved here

Superseded by the fleet/payee-of-record model above: question 1 in an earlier draft asked whether a
*card issuer's* diligence would accept self-published sanctions screening. Under the fleet model, we
are not asking a card issuer to accept a novel KYC substitute for our customers at all — we operate
our own prepaid-card fleet and our own merchant relationships as the KYC'd party. The open questions
now concern *our own* compliance posture as an operator, not a third party's acceptance of ours:

1. What do **CIMA (Cayman) and the BVI FSC** actually require of an entity operating a fleet of prepaid
   card instruments and acting as payee-of-record/biller-of-record for customers, concretely — and does
   self-published OFAC-list screening (for our own fleet's spend) satisfy it?
2. Does **OFAC's own extraterritorial reach** attach directly to this entity given its
   card-network/USD-rail contact through the fleet, independent of Cayman/BVI's own requirements — and
   if so, what does direct OFAC compliance require beyond sanctions-list screening (e.g.,
   blocked-transaction reporting)?
3. Who bears liability for **fuzzy name-matching errors** in the identity-level exclusion layer (false
   positive: wrongly excluding a legitimate user; false negative: wrongly clearing a sanctioned one) —
   this still matters for gating the fleet's own spend, even though no external card issuer needs to
   accept it.
4. Does acting as biller-of-record / payee-of-record for customer-directed purchases (travel, etc.),
   funded by a stacked fleet of prepaid instruments, itself trigger money-transmitter or payment-
   institution licensing requirements in Cayman/BVI or in the jurisdictions where merchants (airlines,
   Airbnb) are billed? This is the single highest-leverage question for counsel given the model above.
5. Is there a **real, currently-operating** precedent for this specific fleet/payee-of-record structure
   we simply haven't found yet — worth one more targeted pass specifically with Cayman/BVI-savvy
   compliance counsel, who may know of arrangements not visible from public research.

## What's built vs. designed vs. open (the honest ledger)

**Built and verified this session:**
- rarime identity circuits compile clean under the target Noir 1.0/Honk toolchain (compile-verified;
  full real-data proving not yet exercised).
- PP forked, folded, and unified onto the same toolchain; ASP anchoring in an ERC-7812 evidence
  registry (address-level screening, live mechanism) — 49/49 Forge tests passing.
- Enclave-rooted note derivation: one device seed derives both `sk_identity` and PP note master keys —
  the actual technical fusion between rarime and PP, independent of the compliance question.
- `SpvTreasuryAdapter`: privacy-preserving idle-fund yield routing (buffer/sweep/reclaim/backstop),
  19/19 tests passing, not yet wired into PP's core contracts.

**Designed, not built:**
- The Noir SMT non-membership/exclusion gadget (needed for identity-level sanctions exclusion) — scoped,
  reference spec exists on-chain, port not started.
- The self-published OFAC-list Merkle commitment and publication process.

**Genuinely open, blocking further build on this specific feature:**
- Every item in "Open questions" above. None of them are resolvable by more engineering or more web
  research — they need Cayman/BVI and US OFAC counsel.
