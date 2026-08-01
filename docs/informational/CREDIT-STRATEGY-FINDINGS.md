# Credit strategy: what was researched, what was wrong, what is still open

Written 2026-08-01. This is the research record behind the lending direction in
`docs/ALLIANCE-APPLICATION.md` and the scoping note in `ibiza/FUNDING-APPLICATION.md`. Every
external claim carries a source. Everything marked OPEN is genuinely unresolved and none of it is
resolvable by more engineering.

> **Three corrections to things asserted earlier in the same session and later checked.** Recorded
> because the wrong versions were repeated confidently before anyone looked.

---

## 1. Land registry access: the closed-register premise does not hold where checked

**Claimed:** in many countries notaries are public but title registers are not, so a notary must be
the oracle for title.

**Checked, three for three against it:**

- **Ukraine.** The State Register of Real Property Rights has been open to any natural or legal
  person since 1 January 2015. Information on registered rights and encumbrances is explicitly
  public and paid. You authenticate on the government e-services portal with your own name, passport
  data and tax number, pay the fee, and search. A notary is one route among several (notary, front
  office, or search it yourself), not a gate. Subject-based search by tax number is available to any
  identified requester under Article 32 of Law 1952-IV.
- **United States.** County recorders publish deeds, mortgages and liens, name- and parcel-searchable,
  online in most populous counties. The title insurance industry exists because the records are
  public and messy.
- **England and Wales.** HM Land Registry sells a title register for a few pounds and names the owner.

**What survives, and it is the distinction that should have been drawn first: notaries gate WRITING,
not READING.** `ibiza/FUNDING-APPLICATION.md` states this correctly for Iran — only a licensed notary
can register a consensual mortgage, and a private agreement is inadmissible before courts and
registries, so it cannot be foreclosed. Registering a charge is a constitutive legal act. Reading a
register is a lookup.

**Consequence for the build.** `TitleLedger` requires a notary signature (from `RegistrySourceAnchor`'s
CRE-fed registry) to mint, to change a legend, and to set an encumbrance. That is correct for the
encumbrance path. For the *read* path it may be unnecessary: Ukrainian state extracts are understood to
carry a qualified electronic signature (КЕП), so the state's own key could be verified directly and the
notary drops out. **OPEN: confirm the витяг is actually КЕП-signed and that the signature is verifiable
off a published certificate chain.** If it is, the owner-runs-it-themselves design works without
recruiting a single notary.

**One finding that helps.** In Ukraine the *requester* must identify themselves and every query is
logged against a real person. So a lender screening applicants builds a state-visible trail of everyone
it investigated. The owner querying their own record discloses nothing new. That is a stronger argument
for owner-side querying than the one in the funding application, and it does not depend on notaries.

## 2. Notary anonymity is on the critical path if notaries stay

`TitleLedger` names the acting notary on-chain today, as an address in the entry and an indexed event
topic. `TITLE-LEDGER-DESIGN.md` records that anonymising them (set membership without naming a member)
is designed and not built. Any design depending on notary willingness needs that gadget, because a
notary enumerable from a public log has a specific reason to decline. The funding application already
notes notaries can be punished for serving a system like this.

## 3. Distribution, and why a riskless hop fails

The model in the application is distribution: a licensed originator finds the borrower, values the
property, sets terms and creates the lien; the reserve funds the loan and holds the paper. The
mortgage chain splits five ways and four need a licence. The fifth is the capital.

**The proposal that a bank act as a riskless hop does not survive.** In May 2026 the Los Angeles
County Superior Court granted summary judgment for OppFi against California's DFPI, holding that at
origination **the entity that funds, controls underwriting, and bears risk is the true lender.**
Conjunctive. A bank taking no risk is therefore not the true lender, and the licensing obligation
lands on whoever funds and bears it.

**The fix is retention, and other regulation already requires it.** EU securitisation rules impose a
5% risk-retention obligation on the originator for exactly this reason. A local bank keeping a genuine
tranche satisfies both retention and the "bears risk" element at once. A riskless hop is the fact
pattern these tests were written to catch.

**Two caveats on leaning on OppFi.** It is a California trial court and its reach elsewhere is
uncertain, since other states and regulators disagree. And the direction of travel is adverse:
Colorado and Oregon are opting out of federal rate exportation, and multiple legislatures are writing
true-lender tests directly into consumer lending licensing statutes.

## 4. CRD VI closes the offshore lending route into the EU, and the grandfathering window has passed

**This is the hardest finding here and it is dated.** Article 21c of CRD VI bans third-country
undertakings from providing core banking services into the EU on a cross-border basis without a
licensed branch. Core banking services expressly include **lending** (consumer credit, commercial
financing, factoring), alongside deposit-taking, guarantees and commitments. It catches **both consumer
and corporate** lending, and "in a Member State" is read broadly to cover dealings with EU clients
regardless of where the service is consumed.

| date | event |
|---|---|
| 2024-06-19 | published |
| 2026-01-10 | Member State transposition deadline |
| **2026-07-11** | **grandfathering cutoff — contracts before this date remain valid** |
| **2027-01-11** | **prohibition takes effect** |

The grandfathering cutoff passed three weeks before this document was written. The prohibition is five
months out.

**Exemptions, none of which is a business model.** Interbank, intragroup, reverse solicitation, and a
MiFID-ancillary overlap of uncertain scope. Reverse solicitation is read restrictively: any repeated
transactions, EU-facing marketing, or proactive outreach disapplies it, and the guidance is explicit
that a sustainable business cannot be built on it. There is also no passport for a third-country
branch, so a branch in one Member State cannot serve the others.

**OPEN, and it is the one thread worth pulling: the non-bank carve-out.** Article 21c bites on
undertakings that would be credit institutions if established in the EU, and the EU definition of
credit institution requires deposit-taking *and* lending. A pure lender that takes no deposits may sit
outside. Commentary flags this as real but "not the full story," and national transposition varies,
with many Member States separately licensing lending activity anyway. **This needs counsel, not more
searching.**

## 5. EU 2021/2167 is an NPL framework, not a performing-loan passport

Directive (EU) 2021/2167 on credit servicers and credit purchasers creates a passportable regime for
non-banks acquiring bank-originated credit and amends both the Consumer Credit Directive and the
Mortgage Credit Directive. Its scope, as far as could be confirmed, is **non-performing** loans. It was
written to build an NPL secondary market and to remove national obstacles to banks assigning bad debts
to credit purchasers.

**OPEN: whether it reaches performing mortgage loans.** That single question decides whether a European
version of the distribution structure is passported or unlicensed. It should be answerable from the
directive text and one national implementation, and it was not answerable from secondary commentary.

## 6. The cross-border rate arbitrage is real, was enormous, and is now regulated

A foreign lender can offer a dramatically better nominal rate, because the difference comes from cost of
funds, which is a currency arbitrage. It was tried at scale:

- Poland: roughly 550,000 Swiss franc mortgages, about €30bn, 7.7% of GDP.
- Hungary: two-thirds of household debt foreign-currency denominated, 7.3 trillion HUF, ~28% of GDP,
  over 90% of it in francs.
- Instalments rose 60% in Hungary and 50–100% in Croatia over three years of franc appreciation, before
  the SNB abandoned its euro cap in January 2015 and the franc jumped ~20% overnight.
- Hungary force-converted the book to forint in February 2015. Poland litigated for a decade.

The Mortgage Credit Directive now permits foreign-currency consumer loans only where the borrower has a
right to convert into their home currency, or another mechanism limits exchange-rate risk. That is scar
tissue written specifically to stop this trade.

`ibiza/FUNDING-APPLICATION.md` §7 already says the operative thing in one line: hard-currency credit is
cheaper in name only unless the borrower earns hard currency. **The segment where this works without
being a scandal is borrowers with hard-currency income and soft-currency property** — remote workers,
diaspora, exporters, crypto holders. Real, and much smaller than the market that took CHF mortgages.

Enforcement subcontractor cost, which was the original hypothesis for why a foreign lender could
compete, is the same for everyone and is a small line. It is not the operative variable.

## 7. The information barrier IS named by the Commission, which cuts in the project's favour

The 2007 White Paper on the Integration of EU Mortgage Credit Markets lists both kinds of barrier, and
the data-side list is not trivial:

- **Credit registers** — fragmented infrastructure; lenders face discrimination accessing cross-border
  credit data.
- **Valuation** — the Commission seeks to "facilitate the use of foreign valuation reports, and promote
  the development and use of reliable valuation standards."
- **Land registry** — disparate systems; the Commission encourages Member States to put registers online
  and promotes the EULIS project for cross-border property information.
- **Language** — registers are not provided in foreign languages, so a Dutch buyer must translate.

And the operative sentence: *mortgage banks have difficulty assessing the value of the information they
receive and so do not risk supporting a loan on property in another Member State.*

That is a verification problem, and it is what the identity and title stack is built to solve. The
earlier claim that the information barrier "is not the bottleneck" was too strong. Both barriers are
real and the Commission names both. **The honest position is that solving the information barrier is
necessary and not sufficient**, because CRD VI and national licensing sit on top of it and cryptography
does not move those.

## 8. The cross-border whole-loan market exists

Non-bank financial institutions — insurers, mortgage REITs, specialty finance — are increasingly
prominent buyers of whole loans, drawn by long-dated cash flows. The UK, Germany and France lead.
Cross-border broking platforms exist (Homevest, founded 2021, 18 bank partners across Europe, offering
both cross-border broking to buyers and an origination solution to banks).

So "no secondary market" was wrong. **OPEN: whether a market exists BELOW the securitisation threshold**
— individual loans in small markets that cannot reach a rating or a pool. The hypothesis is that
capital flows cross-border into European mortgages through rated, pooled instruments issued by large
banks, and that nothing flows underneath that. If that gap is empty for information reasons, the stack
is aimed at something. If it is empty for legal reasons, it stays empty.

## 9. Adjacent assets that were considered and where they landed

**Automobile.** Better than mortgage on the technology and worse on the fit. Valuation is *solved* (VIN
plus odometer against Black Book, KBB, Manheim auction prints), which removes the single unsolved
dependency the funding application names as a kill condition. Enforcement collapses from months to days
via self-help repossession under UCC Article 9. Effective duration of two to three years matches the
liability ladder better than a thirty-year mortgage does. DMV electronic lien and title systems fit
`RegistrySourceAnchor` better than land registries do. Against that: depreciating collateral, negative
equity rolled into new loans routinely, loss severity around 50%, endemic fraud, and consumer credit
regulation heavier than commercial property lending. **Origination and often even purchase of retail
installment contracts require a state sales finance licence, and the assignee inherits FTC Holder Rule
liability.** Verdict: a good pilot for the title-lending machinery, wrong as the business.

**Unsecured / credit card.** The proof stack establishes that someone is real and owns things. It says
nothing about *willingness to pay*, which is what a credit score measures and what drives unsecured loss
rates. A card cannot be issued without a bank: network membership requires being one or renting a BIN.
Regulation B requires adverse action notices with specific reasons, and an underwriting model keyed on
foreign assets and citizenship invites a disparate-impact test on national origin. The funding-cost
premise is backwards: a bank funds on deposits at 0–5%, the reserve funds at depositor yield. Charge-offs
run 3–4% prime and 8–12% subprime, recovery on charged-off unsecured debt is 10–20%, and collections is
the margin rather than trimmable overhead. **The version that survives is collateralised**: spending
power against assets the reserve already holds the claim to, where the loss rate goes to near zero and
you can undercut a 22% card at 10% while being structurally more profitable.

**Which is now occupied.** Exodus agreed to acquire W3C Corp for $175m, bringing in Baanx (crypto card
program manager) and Monavate (issuer processor), giving direct issuing capability on Visa, Mastercard
and Discover. Exodus Pay launched into early 2026: self-custodial, spend USDC or BTC at any Visa
merchant or via Apple Pay, network fees subsidised. **Rollout is state by state** (NE, TX, FL, NY, CA,
national through April 2026), which is the money-transmission licensing grind made visible by a public
company with a balance sheet. Baanx remains available as a program manager, so partnering is a route,
but as a late follower.

## 10. Purchase-scope, if the payee-of-record model is used

The line that decides money-transmitter exposure is **narrowness**. Buying a *specific good and
delivering it* with the customer's pre-funded money looks like a merchant or an agent of the payee.
Providing *general spending power* looks like money transmission plus prepaid access. Any crypto-to-fiat
conversion in the flow is money transmission on its own, with FinCEN registration and state licences.
This is already open question 4 in `ibiza/COMPLIANCE-THESIS.md` and is correctly identified there as the
highest-leverage counsel question.

## 10a. The reframe, and four things wrong with the first version of it

Everything above hunts for lending products and every one dies on licensing. The framing was wrong:
the distinctive primitive here is not a loan but a **dated claim issued at a discount**. ERC-6909
maturity buckets plus `calcMintYield` produce it — pay $1,850, hold a claim with $2,000 of face
maturing in twelve months, forward yield priced in at entry. The minter's advantage is immediate and
real, and Pendle needs two tokens and a decaying curve to approximate it.

> **⚠️ The first draft of this section (2026-08-01, same day) called it a BILL and built a
> full-collateral security-deposit product on top. Both were wrong. Corrected below. The wrong version
> also reached `ALLIANCE-APPLICATION.md` and `-LONG.md` and was removed from them.**

### Correction 1: it is not a bill, and calling it one fights the legal position

A bill of exchange or bankers' acceptance is an **unconditional order to pay a fixed sum** on a
determinable date. Unconditionality is precisely why a bill is discountable and acceptable as
collateral: the holder knows what arrives.

QUI fails both tests. `perShare = min(solvent · WAD / matureSupply, WAD)` is capped at par and can fall
below it for three documented reasons — constituent depeg, genuine constituent-vault underperformance,
and a deliverability-only illiquidity haircut. The sum is not fixed and the promise is not
unconditional.

**And the legal document argues FOR that floating downside on purpose.** It is what distinguishes QUI
from a par-redeemable payment stablecoin and keeps the fund/ETF-share framing alive under the Howey and
Section 17 sequence. Describing QUI as a bill in a fundraising document pulls directly against the
argument the legal document is making. The accurate analogue is a **defined-maturity fund share**,
something like an iBonds ETF that matures on a date and returns NAV. That is honest, and it is also
security-shaped, which is the tension the legal analysis exists to manage. Any external description
must not resolve that tension by accident.

### Correction 2: the deposit-alternative customer cannot post the collateral

Deposit alternatives exist because the renter **does not have** the deposit. Jetty's proposition is
$350 today instead of $2,000 today. It is a **liquidity** product, not a cost-saving one.

The first draft asked the tenant to post ~$1,850 of collateral to secure a $2,000 obligation. Anyone
holding $1,850 can post the $2,000 cash deposit outright, or is close enough that the alternative is
pointless. **The full-collateral product serves a customer who does not need it.** The residual buyer
is someone who could post cash and would rather earn on it, whose entire gain is the yield on $2,000
for a year — call it $150. Nobody completes a crypto onboarding for $150.

**What survives is partial collateral.** Post $500, the surety writes the $2,000 bond at a premium well
under 17.5% because it is partly secured and partly underwritten. Real, and a much smaller claim: the
surety keeps genuine risk and still has to underwrite.

### Correction 3: removing a surety's risk removes their margin

A surety bond is not insurance. It is a **three-party credit product** — principal, obligee, surety —
carrying a right of indemnity against the principal, and the premium compensates for pricing that risk.
Fully collateralise it and the surety becomes a conduit whose margin compresses to a filing fee. Rhino
and Jetty have no reason to want that.

**The buyer is a surety that currently DECLINES thin-file applicants.** Collateral lets them approve a
segment they reject today, which is incremental revenue rather than cannibalised revenue. Pitch the
decline pile, never the approval pile.

### Correction 4: the distribution gate is the property manager, not the surety

Rhino and Jetty sell to **property managers**, who decide which alternative to offer renters.
Partnering with a surety leaves that gate shut. There are two gates, and the first draft counted one.

### What survives, and where the date-match actually holds

The instrument is genuinely distinctive and the minter's upfront advantage is real. The collateral use
case works wherever the **release date is genuinely certain**:

| use case | date-certain? |
|---|---|
| escrow / earnest money against a set closing | **yes** |
| bid bonds (released on award or window close) | **yes** |
| utility deposits (returned after ~12 months of payment history) | mostly |
| security deposits | **weaker** — most jurisdictions settle at move-out, which matches, but early termination (eviction, break clause) breaks it |

Security deposits, the flagship example in the first draft, are the weakest of the four.

**The LP logic is untouched.** LP revenue is venue yield, v4 fees, and the retained scarcity premium,
all scaling with deposits and swap flow. Lending does nothing for an LP directly. What matters is
demand for QUI from people who are **not** crypto natives, because they are not chasing yield and will
not leave for fifty basis points. That is the most durable deposit base available and it is worth more
to an LP than any lending margin.

**It needs no notary, no title, no lien and no registry.** That absence is why it remains more
deliverable than everything property-based here.

### Remaining attacks

- **Admitted assets.** State insurance regulators define what a surety may hold as collateral and a
  crypto basket claim is almost certainly not on the list. Workaround is a third-party trust with the
  surety taking a pledge or letter of credit, adding a party and a cost. **Counsel question, and it
  decides whether any version exists.**
- **Liquidity on claim.** The instrument is illiquid until maturity by construction. A surety needs
  collateral it can reach when a claim lands. Early redemption is clamped to `redeemableAmount()`, so
  an early draw recovers less than face. Partial collateral plus a maturity set inside the lease term
  mitigates it; the secondary market that would solve it properly does not exist.
- **Pledge perfection.** Some civil-law jurisdictions require notarisation and pledge-register entry to
  perfect a security interest over a claim. Different notary function from `TitleLedger`'s. In the US a
  pledge of an investment property is perfected by control under the UCC, no notary.
- **Nothing ships without mainnet and an audit.**

## 10b. The hop metaphor inverts, and this is the deepest error in the whole thread

"Hop" has been used consistently across three layers: the Lightning routing node in `BTCChannels`,
Bebop's intent hops, and the financial intermediary in every lending structure above. The instinct is
that a capable party stands in the middle, forwards, takes a fee, and owns nothing.

**In Lightning that works because the hashlock makes the pass-through atomic and trustless.** The hop
cannot steal and cannot be blamed, precisely because it holds no position. Risklessness is the safety
property.

**In regulated finance the identical structure is what regulators attack.** Rent-a-charter, true lender,
conduit doctrine. The May 2026 OppFi test holds that the party which funds, underwrites and bears risk
is the lender (§3). So the risklessness that makes a Lightning hop safe is exactly what makes a
financial hop unlawful, or rather what collapses it — the licensing obligation simply lands back on
whoever actually bears the risk.

**Every workable version of the financial intermediary requires them to hold real risk**, which is the
opposite of a hop. The mortgage originator retains a slice. The surety keeps underwriting exposure. The
metaphor does not carry across the boundary, and reasoning from it produces structures that look
elegant and are legally void. This is worth stating in the codebase because the same word appears in
`BTCChannels` (where it is correct) and in the credit strategy (where it is not).

## 11. Where this leaves the strategy

The reserve's real, immediate need is **duration**: liabilities are dated out twelve months and every
asset is overnight and crypto-native. Mortgage paper matches that book and pays a term premium for it.
That need is genuine and does not depend on any of the open questions above.

Buying rated paper fixes duration without a lending licence, but it is a **treasury operation, not a
product**: it uses none of the stack and there is nothing to deliver to a customer. Whole-loan purchase
is gated on counsel. Origination is a multi-year, multi-million, full-time regulated business requiring
a hired qualifying individual, and it buys nothing a partnership does not already give you at the
volumes in question.

**The deliverable is §10a**, because it is the one product that uses the instrument only this stack
issues and needs none of the machinery that licensing blocks.

**The PMF question on the title layer is honestly open.** The stack solves a verification problem the
European Commission itself names as a barrier. It does not solve licensing, enforcement variance,
currency-risk regulation, or servicing at distance. And the deposit product, which is the most
deliverable thing here, does not use it. What has clearer demand in the same repository: proof of
personhood and sybil resistance; sanctions screening without disclosure, once the exclusion gadget is
built; and shielded deposits that earn.

**Does any of this validate the notary integration? Narrowly.** Notaries gate WRITING, so requiring a
notary signature to set an encumbrance in `TitleLedger` is correct and unavoidable. Notaries do NOT
gate reading, so requiring one to verify title is probably unnecessary (§1). And the deposit product
needs neither. The notary work pays off on the encumbrance path if property lending is ever pursued,
and not before.

### Deliverables, ranked by what can actually ship

1. **Intent venue listings** (Mach, Khalani — already committed). No licence, no product, no customer
   acquisition. Brings the swap flow that drives the retained scarcity premium straight to LPs. Needs a
   deployment and nothing else. **Fastest LP revenue in the stack.**
2. **The Liquity zapper** (`SorExchange`). Built. Earns the SOR spread on both legs inside someone
   else's product.
3. **QUI as pledged deposit collateral** (§10a). Needs one surety partner and a counsel answer on
   admitted assets.
4. **Exodus.** They hold the rails and the state-by-state licences and are missing yield on unspent
   balances, which is exactly what the basket makes. Enter as the supplier, not the competitor.

**Who says yes first, and what the document set does not yet prove:**
`docs/informational/GO-TO-MARKET-AND-READINESS.md`. Summary — the two conversations that can produce
signed paper *before* the audit are a surety's **decline pile** (partial collateral lets them approve a
segment they reject today) and a **family office** holding crypto (a fraction of an RIA's compliance
surface, and their clients are already asking). The adviser hook is not the dashboard: advisers bill on
AUM and self-custodied ETH is invisible to their reporting stack, so making it reportable expands their
fee base. A fiduciary cannot recommend an unaudited protocol, so what is available now is a letter of
intent rather than an allocation.

## 12. What an origination licence actually costs, if it is ever revisited

Two things, wildly different in difficulty.

**The individual licence is a formality.** Under the SAFE Act you register as a Mortgage Loan
Originator through NMLS: twenty hours of pre-licensing education, one national exam, fingerprints, a
criminal background check, a credit review, eight hours of continuing education a year. Roughly
$1,500–2,000 for the first state, three to six months. Disqualifiers are a felony within seven years,
or ever a felony involving fraud, dishonesty, breach of trust, or money laundering. **Worth holding
personally regardless**, because it makes you credible with the originators you want to partner with.

**The company licence is a different order of problem.** No federal licence exists for a non-bank, so
it is state by state, fifty applications for national coverage. Per state: a minimum net worth between
$25k and $250k, a surety bond from $25k to $500k scaled to volume, audited financials, background
checks on every control person at 10%+, and in some states a physical office. Twenty to fifty thousand
dollars per state in fees, bonds and legal; six to twelve months each.

**The requirement that actually blocks it is the qualifying individual** — states require a designated
person with three to five years of documented mortgage origination *management* experience. Not
substitutable by competence. You would hire before you could file, and that person becomes a
load-bearing dependency for a two-person company.

**The licence is the cheap part.** What follows is TRID disclosure generation, Ability-to-Repay and
Qualified Mortgage determinations, HMDA reporting, ECOA fair lending, the Loan Originator Compensation
rule, a quality-control programme, and CFPB examination readiness. A full-time function with headcount,
unrelated to anything else being built.

**Realistic:** business-purpose lending against investment property in one state, possibly no licence at
all depending on the state, months. Consumer residential in one state, nine to eighteen months and
$50–100k, contingent on hiring the qualifying individual first. Multi-state consumer, years and
millions, a company in its own right.

**Verdict:** the licence buys nothing the partnership does not already provide, at any volume currently
in sight. Revisit when origination margin moves the needle, which is a balance-sheet question.

## 13. Entity and residency: a correction, and the exposure that actually survives

**Correction made in-thread and worth recording.** An earlier warning that a US-resident founder
controlling the Cayman structure triggers CFC and GILTI was **overstated**. A Cayman **foundation
company can be constituted with no members**, which is why crypto projects use the form. Subpart F
attribution requires US shareholders holding more than half by vote or value; with nobody holding
either, there is no US shareholder and the CFC and GILTI machinery does not engage. Foundation
companies are companies, so they default to corporate rather than trust classification for US purposes,
which also keeps the foreign grantor trust rules at §679 out of it.

**The exposure that survives is management and control, and it is independent of ownership.** A
US-resident director making the entity's decisions from US soil raises the question of whether the
entity has a US trade or business generating effectively connected income. Ownerlessness does nothing
for that. Nor does it help if the founder takes compensation, which is personal income wherever the
entity sits. **Cross-border tax counsel, and a narrower conversation than the one first described.**

**PREREQUISITE, unresolved:** is QuidMint Foundation actually memberless, or does it have members with
economic rights? The chain runs QU!D LTD (BVI) → Quid Labs (Cayman IBC) → QuidMint Foundation, and the
whole analysis turns on where it terminates. If it terminates in nobody, the above holds. If there are
members, it does not.

**The foundation buys nothing on lending licences.** Authorisation follows the borrower's jurisdiction
and the activity. A foundation-owned IBC needs the same state licence a shareholder-owned one does.

**Where it does real work is the two arguments that matter.** The Investment Advisers Act definition
requires acting **for compensation**. An entity with no owners, whose only extraction is a tranche
sized to recover a documented accumulated deficit and terminating at breakeven, has a genuinely weak
compensation element. That pairs with the renounced-ownership code facts (see
`docs/legal.md` Part IV). Same for Howey prong three: the breakeven structure
reads as rhetoric from a company with shareholders and as structure from a memberless foundation
running ASC 958 accounting.

## 14. Income verification: CRE cannot reach it, and it is probably unnecessary

**CRE covers public authoritative sources completely** — every DON node fetches the same bulk export
and must agree byte-for-byte. Correct shape for a notary register or an OFAC list, and no external
vendor is needed for that class.

**It cannot reach income, structurally rather than as a gap in the build.** Identical-aggregation
requires every node to fetch **the same** data. Payroll and IRS data sit behind per-user
authentication, so making CRE reach it would mean handing every DON node the user's credentials. There
is nothing for the nodes to agree on when the data is a private authenticated session.

**Passport proofs work because ICAO documents carry the issuing state's signature.** The IRS does not
sign W-2s, so no rarime-shaped proof exists for income. The mechanism that would work is **zkTLS / web
proofs** (Reclaim, zkPass, Opacity): the user authenticates to a payroll provider in a real TLS session
and a notary attests to what the server said without the verifier learning credentials. Two caveats — a
different cryptographic primitive from anything currently built, so net-new work; and a weaker
guarantee, since it proves what a server responded in a session the user controls rather than a state
signature over a chip.

**The more useful observation is that it is probably unnecessary.** Income verification without
disclosure only matters if no party may hold the file. Under the distributor model a licensed
originator verifies income conventionally, with consent, because that is their job and their liability.

---

## Open items, consolidated

1. Is the Ukrainian витяг КЕП-signed, and is the signature verifiable off a published chain?
2. Does the CRD VI **non-bank carve-out** exempt a pure lender that takes no deposits, and does national
   transposition preserve that? (counsel)
3. Does Directive 2021/2167 reach **performing** loans, or stop at NPLs? (directive text plus one
   national implementation)
4. Does a cross-border whole-loan or participation market exist **below the securitisation threshold**,
   and if it is empty, is it empty for information reasons or legal ones?
5. Will a local bank accept a retention slice small enough to leave the economics workable? (a
   conversation, not a search)
6. Does the reserve hold whole loans or participations, and who is the record lienholder — the
   originator as nominee, or an SPV?
7. Purchase-scope: does payee-of-record fulfilment trigger money transmission? (counsel; already
   `COMPLIANCE-THESIS.md` open question 4)
8. **Can a surety accept a QUI claim as collateral under state admitted-asset rules, or must it sit in
   a third-party trust with the surety taking a pledge or letter of credit?** (counsel — this decides
   whether §10a exists)
9. **What haircut does QUI's capped-at-par, floating-downside redemption require as collateral**, and
   do the economics still beat Jetty's 17.5% after it? (model, not research)
10. Does perfecting a pledge over a QUI claim require notarisation and pledge-register entry in the
    target jurisdiction? (US: no, UCC control. Civil-law: check per country.)

## Sources

- Ukraine register access: [ICLG Ukraine Real Estate 2026](https://iclg.com/practice-areas/real-estate-laws-and-regulations/ukraine/) ·
  [Lexology, register became publicly available](https://www.lexology.com/library/detail.aspx?g=a93a73d1-c7a9-46a1-b2bd-2cd16299312b) ·
  [WikiLegalAid, порядок доступу](https://legalaid.wiki/index.php/%D0%9F%D0%BE%D1%80%D1%8F%D0%B4%D0%BE%D0%BA_%D0%B4%D0%BE%D1%81%D1%82%D1%83%D0%BF%D1%83_%D0%B4%D0%BE_%D0%94%D0%B5%D1%80%D0%B6%D0%B0%D0%B2%D0%BD%D0%BE%D0%B3%D0%BE_%D1%80%D0%B5%D1%94%D1%81%D1%82%D1%80%D1%83_%D1%80%D0%B5%D1%87%D0%BE%D0%B2%D0%B8%D1%85_%D0%BF%D1%80%D0%B0%D0%B2_%D0%BD%D0%B0_%D0%BD%D0%B5%D1%80%D1%83%D1%85%D0%BE%D0%BC%D0%B5_%D0%BC%D0%B0%D0%B9%D0%BD%D0%BE)
- True lender: [Consumer Finance Monitor on OppFi v DFPI](https://www.consumerfinancemonitor.com/2026/05/29/california-court-issues-final-statement-of-decision-rejecting-dfpi-true-lender-theory-against-oppfi/) ·
  [NYLJ, True Lender Doctrine and OppFi v Hewlett](https://www.law.com/newyorklawjournal/2026/06/18/true-lender-doctrine-and-opportunity-financial-llc-v-clothilde-hewlett/) ·
  [Stinson, states codifying true lender](https://www.stinson.com/newsroom-publications-states-expand-regulation-of-consumer-lending-codification-of-true-lender-and-opt-out-of-didmcas-interest-exportation)
- CRD VI: [A&O Shearman, new licensing requirements for cross-border lending into Europe](https://www.aoshearman.com/en/insights/new-licensing-requirements-for-cross-border-lending-into-europe) ·
  [Latham, implications of the licensed branch requirement](https://www.lw.com/en/insights/crd-vi-implications-of-the-licensed-branch-requirement-on-lending-to-eu-borrowers) ·
  [Crowell, why the non-bank carve-out matters but is not the full story](https://www.crowellfintalk.com/2026/06/crd-vi-new-rules-for-cross-border-lending-into-europe-why-the-non-bank-carve-out-matters-but-is-not-the-full-story/) ·
  [Ashurst, Q&A on the third-country branch](https://www.ashurst.com/en/insights/qa-on-the-third-country-branch-introduced-by-crd-vi/)
- Credit purchasers: [European Sources Online, Directive 2021/2167](https://www.europeansources.info/record/proposal-for-a-directive-on-credit-servicers-credit-purchasers-and-the-recovery-of-collateral/) ·
  [KPMG, NPL Directive playing rules](https://kpmg.com/hu/en/home/insights/2023/10/the-npl-directive-new-playing-rules-for-credit-purchasers-and-servicers-in-the-eu.html)
- FX mortgages: [European Parliament, unfair terms in Swiss franc loans](https://www.europarl.europa.eu/RegData/etudes/BRIE/2021/689361/EPRS_BRI(2021)689361_EN.pdf) ·
  [WEF, managing foreign currency loans](https://www.weforum.org/stories/2015/10/how-should-european-economies-manage-their-foreign-currency-loans/)
- Barriers: [EU White Paper on the Integration of EU Mortgage Credit Markets, CELEX 52007DC0807](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:52007DC0807) ·
  [Taylor Wessing, cross-border lending in the EU](https://www.taylorwessing.com/en/insights-and-events/insights/2024/11/lf-cross-border-lending-in-the-eu)
- Security deposits: [Residential deposits total $40bn, Second Nature](https://www.secondnature.com/blog/security-deposit-alternatives) ·
  [Jetty's 17.5% fee and the surety model, Brick Underground](https://www.brickunderground.com/rent/security-deposit-alternatives-nyc) ·
  [Surety bonds as deposit alternatives, Buildium](https://www.buildium.com/blog/surety-bonds-as-alternatives-to-security-deposits/) ·
  [The misleading marketing of Renter's Choice, Shelterforce](https://shelterforce.org/2020/12/10/security-deposit-alternatives-the-misleading-marketing-of-renters-choice/)
- Exodus: [CoinDesk on the 2026 payments app](https://www.coindesk.com/business/2025/12/09/crypto-wallet-firm-exodus-bets-on-stablecoins-for-real-world-payments-with-2026-app) ·
  [Decrypt, Exodus Pay](https://decrypt.co/363947/exodus-pay-bitcoin-wallet-spending-app) ·
  [CoinDesk, Exodus and Baanx card](https://www.coindesk.com/business/2025/05/27/bitcoin-wallet-firm-exodus-unveils-crypto-debit-card-with-baanx)
