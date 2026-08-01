# Go-to-market and readiness: who says yes first, and what the documents do not yet prove

Written 2026-08-01. Two parts. The first names the two buyers who can commit **before** the audit and
what each of them actually needs to hear. The second is an honest assessment of what the current
document set establishes and what it does not, written so nobody has to discover it in a diligence
meeting.

Companions: `docs/informational/CREDIT-STRATEGY-FINDINGS.md` (the product and research trail),
`docs/legal.md` (regulatory), `docs/ALLIANCE-APPLICATION.md` (the pitch).

---

## Part I — The advisor channel, named precisely

"An independent wealth manager" was too vague and pointed at the wrong firm.

### Not a mainstream RIA, and chasing one wastes months

A registered investment adviser recommending an unaudited, pre-mainnet protocol to a retail client is a
fiduciary breach. They also have to amend Form ADV, obtain their compliance officer's sign-off, and run
diligence for which they have no framework and no precedent. That firm is not the first yes.

### The two firms that are

**A family office, single- or multi-family, serving households that already hold crypto.** Single-family
offices are generally exempt from Advisers Act registration under the family office rule, so the
compliance surface is a fraction of an RIA's. Their clients are already asking what to do with idle ETH
and BTC and the office has no answer beyond "hold it."

**A crypto-native RIA** — a firm built specifically to advise on digital assets, which has already
solved the regulatory posture that stops everyone else, and which is actively hunting for products
rather than waiting to be sold to.

> ⚠️ **Verify before relying on either.** The family office registration exemption and the custody-rule
> analysis below are recalled, not researched, and this session has already been wrong twice on
> confidently-asserted legal facts (see `CREDIT-STRATEGY-FINDINGS.md` §1). Confirm the current state of
> the SEC custody rule and any successor safeguarding rule with counsel before using either in a
> conversation.

### The constraint that shapes the whole channel: custody

An adviser who takes custody of client crypto needs a **qualified custodian**, and that requirement is
the wall that has kept advisers out of this asset class entirely. Nothing else explains the adoption
gap as well.

**QU!D's structure sidesteps it.** The client self-custodies, the adviser receives read access to a
position verifiable on a public ledger, and the adviser therefore never has custody, so the
qualified-custodian question never arises. **This is the opening line of the pitch, not a footnote.**

### The economic hook, which is not the dashboard

The first framing of this channel said the dashboard gives an adviser something supervisable. True and
weak. The sharper version:

**Advisers bill on assets under management, and assets they cannot see or report are not billable.** A
client's self-custodied ETH is invisible to the adviser's reporting stack, so it sits outside the fee
base entirely. Make it visible and reportable and the adviser can bring it under management and charge
on it.

You are not selling software. You are expanding what they can bill.

### What is actually available pre-audit

**A correction to an earlier claim in this thread.** It was asserted that one adviser saying yes would
move the investment case further than the documents. Half wrong: a fiduciary **cannot recommend** an
unaudited protocol, so an actual allocation is gated on the audit like everything else.

What *is* available now is a **letter of intent** — "if this existed and were audited, we would allocate
for these clients." That is a commercial statement rather than a fiduciary act, it can be signed today,
and it is precisely what an investor wants to see. Capa.fi's TVL pledge is already this shape.

## The other pre-audit conversation: the surety underwriter

Detail in `CREDIT-STRATEGY-FINDINGS.md` §10a. The profile in one line: **a surety that currently
DECLINES thin-file applicants**, because partial collateral lets them approve a segment they reject
today, which is incremental revenue rather than the cannibalised kind. Never pitch a surety already
approving the applicant, since removing risk from a bond they already write only compresses their
margin.

Note the second gate: Rhino and Jetty sell to **property managers**, who choose which alternative to
offer renters. A surety partnership still leaves that gate shut.

**Both of these conversations can produce paper before a single contract is deployed.** That is the
argument for having them now rather than after the audit.

---

## Part II — What the documents establish, and what they do not

Asked directly whether the document set makes an undeniably strong investment case requiring only
traction to prove it. **It does not, and the gap is not traction.**

### What traction would prove

The audit, mainnet deployment, live TVL, whether LPs actually beat simply staking, whether the retained
scarcity premium earns real money at real volume. All execution. All provable by doing.

### What traction cannot prove, because nobody was ever asked

**The product changed four times in one day.** Mortgage refi, auto, unsecured card, deposit collateral.
Every pivot came from reasoning rather than from a customer. No surety underwriter has seen the deposit
product. No family office has seen the dashboard. Traction cannot validate a hypothesis nobody has
tested, and the honest reading of a document that arrives at its product on the day it was written is
that the product is a hypothesis.

**Two counsel gates sit on that product and both are binary.** If admitted-asset rules come back no,
the product does not exist at any level of traction (`legal.md` open question 3).

**A fact about our own entity is unresolved** and the legal position depends on it: whether QuidMint
Foundation is memberless (`legal.md` open question 1).

**`Vault` retains three owner setters** while `legal.md` Part IV argues nobody can change where
depositor assets go. That contradiction is in the code now, it is an afternoon's work, and it is the
cheapest thing on this list to fix.

**The ~20% BTC yield figure has no evidence behind it** and sits in a document reporting zero live
deposits. Traction would prove it; stating it beforehand is a credibility cost in the meantime.

**Ukraine, one founder, no redundancy.** More traction concentrated in one person in a war zone raises
the amount at stake rather than reducing the risk.

**Competitive and regulatory facts that do not move.** Exodus spent $175m acquiring card infrastructure
and is licensing state by state into the collateralised-spend product. CRD VI closes cross-border
lending into the EU on 11 January 2027.

### What the documents do establish

That the technology is real, substantial and checkable in public repositories, with real-stack
regression tests against live protocol state rather than mocks. That this team finds its own errors and
retracts them in writing, which almost nobody does — the retraction banners across
`docs/informational/` are evidence of method, not of sloppiness. That the impermanent-loss work is more
rigorous than the field's and the up-side-only conclusion is genuinely differentiated. That the Bitcoin
custody design is novel and verifiable line by line. That the legal analysis is more thorough than most
projects ever produce.

**That is a strong case that these are serious builders. It is not yet a case that a business exists.**

### The shortest path

Not more code and not more documents. One conversation with a surety underwriter who declines thin-file
renters, and one with a family office holding crypto for families who are asking what to do with it.
Either can produce signed paper before anything is deployed, and either would move the investment case
further than the twenty-two thousand words currently sitting in these files.

---

## Booked actions

1. Close the three `Vault` owner setters, or record why they survive launch. (`legal.md` #11)
2. Confirm the Foundation's membership status. (`legal.md` #1)
3. Verify the custody-rule and family-office-exemption analysis in Part I with counsel.
4. Take a letter of intent to one family office and one crypto-native RIA.
5. Take the partial-collateral proposition to a surety's decline pile, with the haircut modelled first.
