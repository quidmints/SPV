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

## 10a. The reframe: the stack issues a BILL, not a loan

Everything above hunts for lending products and every one of them dies on licensing. The framing was
wrong. **The unique primitive here is a dated, fully-backed, discountable claim on a known future
date.** ERC-6909 maturity buckets plus `calcMintYield` produce exactly that: deposit $1,850, receive
QUI with $2,000 face maturing in twelve months, the forward yield priced in at entry. That is a
bankers' acceptance, and the discount market ran on that instrument for three centuries. Pendle splits
yield into two tradable tokens; nobody else in crypto issues a single instrument that matures at face
on a calendar.

A bill is worthless to someone who needs cash. It is worth **more than cash** to a counterparty who
only needs the money on a known future date. That describes a large, unglamorous category: money you
must post now and get back later.

### The security-deposit product

**Market:** US residential security deposits total roughly **$40 billion** sitting idle. An industry
already attacks it — Rhino, Jetty, The Guarantors, SureDeposit, LeaseLock — mostly via surety bonds
that landlords already accept, so no behaviour change is needed at the point of sale.

**The incumbent's weakness is that the fee is non-refundable.** Jetty charges 17.5% of the deposit
amount, others 20–50%, and the tenant never sees it again. A renter facing a $2,000 deposit pays ~$350
and owns nothing.

**The QU!D version dominates on both sides.** The tenant posts QUI maturing to $2,000 at lease end,
pledged to the bond provider, who issues the same bond the landlord already accepts. Absent a claim the
tenant receives $2,000. They end with **more than they started**, against paying $350 for nothing. The
bond provider holds collateral maturing to exactly its exposure, so its loss rate collapses and it can
price under Jetty while earning more. The landlord never touches crypto.

**The hop is the surety company** — licensed, already holding the property-manager relationship, doing
the KYC. QU!D supplies the instrument that removes their credit risk. Same distributor logic as the
mortgage, applied where the regulated party has an obvious reason to say yes.

**Same shape, other markets:** utility deposits for no-credit-file customers, commercial lease
deposits, contractor performance and bid bonds, escrow and earnest money, customs bonds. Each is cash
posted now against a known return date, each has an existing licensed intermediary to hop through.

**Why this is the right answer for LPs specifically.** LP revenue is venue yield, v4 fees, and the
retained scarcity premium, all of which scale with deposits and swap flow. Lending does nothing for an
LP directly. The chain that matters is demand for QUI from people who are **not** crypto natives. A
renter posting a deposit is not chasing yield and will not leave for fifty basis points, which makes it
the most durable deposit base available.

**It needs NO notary, NO title, NO lien and NO registry.** That absence is why it is more deliverable
than everything property-based in this document.

### Attacks on this idea

- **Admitted assets.** State insurance regulators set what a surety may hold as collateral, and a claim
  on a crypto stablecoin basket is almost certainly not on the list. Workaround is a third-party trust
  holding collateral with the surety taking a pledge or letter of credit, which adds a party and a
  cost. **This decides whether the product exists. Counsel question.**
- **QUI is not par-safe.** `docs/legal` is explicit that redemption is capped at par and can fall below
  it for three separate reasons (constituent depeg, genuine vault underperformance, deliverability-only
  illiquidity). Collateral needs a haircut, so the tenant posts more than $1,850 and the economics
  thin. **Model this honestly before pitching it.**
- **Pledge perfection.** In some civil-law jurisdictions perfecting a pledge over a claim against third
  parties needs notarisation and registration in a pledge register. That is a DIFFERENT notary function
  from `TitleLedger`'s property-title one. In the US a pledge of an investment property is perfected by
  control under the UCC, with no notary.
- **Nothing ships without mainnet and an audit.** True of every idea here and the actual gating item.

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
