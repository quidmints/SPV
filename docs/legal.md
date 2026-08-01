# Legal and regulatory analysis

**Status 2026-08-01.** This file consolidates the securities analysis (GENIUS Act, Howey, Section 17,
PACE) with the regulatory findings from the 2026-08-01 credit-strategy research pass. It supersedes
`docs/informational/CURATOR-DISCRETION-AND-THE-PEIRCE-QUESTION.md`, which held the Peirce commentary
while this file had no home in either repository. Nothing here is a legal opinion. It is the technical
and factual case a lawyer needs in order to form one.

Companion documents: `docs/informational/CREDIT-STRATEGY-FINDINGS.md` (commercial strategy and the
research trail), `ibiza/COMPLIANCE-THESIS.md` (the wallet's compliance-by-construction argument).

---

## Part I — Entity and framing

QU!D LTD is a BVI entity owned by Quid Labs, a Cayman IBC whose parent is the QuidMint Foundation.
The entities were founded on the cusp of the Terra crash, with first-hand experience of collateral
damage: under FASB ASC 958 nonprofit accounting principles, accumulated deficit exists on the balance
sheet as a documented liability against future operations.

Bebop.xyz chose a name representing intent-based hops, after bebop jazz replaced the big band's
arranged harmony with improvisation over complex chord changes at high tempo. Every stablecoin in the
basket is in a *quid pro quo*: mutual redemption pressure relief, peg stability. The Signal Foundation
started on a promissory note; on similar terms, MetaWeb Capital backed a meta-stable.

---

## Part II — GENIUS Act

The GENIUS Act was passed to address a specific and documented failure mode in stablecoin
infrastructure: issuers holding reserve assets external to the stablecoin itself that could fail to
maintain 1:1 backing under stress.

The question is not whether QU!D qualifies as a permitted issuer under the Act, or even whether any
other design could be better qualified.

### Redemption mechanics — corrected 2026-07

The basket composition at redemption of 1 ERC20 (QD) varies with live market conditions, and the
dollar value is **not invariant either**. Verified directly against `evm/src/imports/BasketLib.sol`
(`_redeemQuote` / `_settleRedeem` / `computeMetrics` / `_illiquidLoss`), modifying nothing:

`perShare = min(solvent * WAD / matureSupply, WAD)`. Redemption value is capped at par (never above
$1 — surplus above par is LP equity, consistent with the tranche mechanism below) but can fall below
par for **three distinct, code-documented reasons**, not one:

1. **A constituent stablecoin depegging** (`depegLoss`, a per-stable native-value haircut).
2. **A constituent vault genuinely losing money, independent of any depeg.** `computeMetrics`'s own
   inline comment states this explicitly ("yieldWeighted < raw: ... depeg-discounted contribution
   dragged yieldWeighted below raw, OR a vault is genuinely losing money"). Ordinary strategy or
   lending-market underperformance is its own separate solvency-reducing path — a general
   realized-vs-assumed shortfall, not limited to any one venue or cause. The seed tranche's own fixed
   *projected* 100% APR bootstrap rate (per `calcMintYield`'s `isSeed` branch) is one liability this
   same shortfall can be measured against, the way an insurer's claims can exceed a too-optimistic
   premium projection. Not a separate mechanism, just this one applied to that specific claim.
3. **Illiquidity, as distinct from insolvency** (`_illiquidLoss`, a *separate* deliverability haircut).
   Funds can be fully solvent at par yet not currently withdrawable, e.g. a frozen or
   utilization-capped Morpho/Euler market. This defers rather than destroys value — the unserved
   balance is retained as a live deferred claim, paid once liquid, not paid out at a stale price.

This was previously pegged 1:1 at redemption; it no longer is, and not for a single narrow reason. **The
correction cuts in QU!D's favor, not against it** — see the Section 4(a)(11) discussion below.

### What the basket is

The basket generates no endogenous yield, only exogenously through Uniswap, AAVE, Morpho, and the
stablecoin vaults. It is closer to an ETF or money market fund share, aggregating existing monetary
instruments issued by third parties into a redeemable unit. The pass-through yield originates from the
reserve income of each constituent issuer: FRAX's monetary premium, DAI's DSR, sUSDe's funding basis.

This aligns with the CFTC's historical treatment of basket instruments backed by physical commodities,
and with recent SEC staff guidance distinguishing utility from investment characteristics.

Section 3(a)(1)(A) of the ICA defines an investment company as any issuer primarily engaged in the
business of investing in securities. Whether basket-constituent stablecoins are "securities" for ICA
purposes is itself unresolved — the GENIUS Act explicitly excludes compliant payment stablecoins from
the definitions of "security" under the Securities Act of 1933 and the Securities Exchange Act of 1934.
If the underlying constituents are not securities, the ICA's primary classification trigger does not
apply.

Depositors commit capital today and receive a claim on future value, sized at entry, contingent on the
basket's performance over the maturity period. DCF secondary market pricing insinuates a warrant-like
resemblance: a locked claim trading at a discount to face value as maturity approaches.

### Proportionality — Section 4(a)(1)(A)

Section 4(a)(1)(A) requires that capital requirements *"may not exceed what is sufficient to ensure the
permitted payment stablecoin issuer's ongoing operations,"* and liquidity standards *"may not exceed
what is sufficient to ensure the ability of the issuer to meet the financial obligations of the issuer,
including redemptions."*

These proportionality constraints are written into the statute because the regulation targets a gap
which does not exist for QU!D. QU!D addresses the regulatory concern more completely than the Act's own
requirements do, which makes the Act's compliance apparatus proportionally lighter for QU!D rather than
inapplicable.

Hayek's argument in *The Use of Knowledge in Society* (1945) is that no central authority, including a
regulator or an auditor, can replicate what a price mechanism does: aggregate dispersed private
information held by millions of individual actors who each know something the others don't.

A PCAOB-reviewed monthly attestation is a central authority making a backward-looking determination.
It tells a regulator what the reserve composition was at a point in time. It cannot tell a regulator in
real time whether that composition is adequate given current market conditions.

> **⚠️ SUPERSEDED (2026, and again on 2026-08-01).** The paragraphs that followed argued a depeg
> prediction market would operationalise reserve sufficiency continuously, aggregating dispersed private
> information rather than relying on a single auditor. **The prediction market was removed from the
> design and the argument should not be revived.** The mechanism failed on its own merits: the
> no-incident side was funded from basket capital, which is the same capital that redeems QD at
> maturity, so an incident payout double-spends the backing and does so during the crisis that already
> impaired it. The protection it promised existed for free, since a break is absorbed proportionally by
> every claimholder. See `CREDIT-STRATEGY-FINDINGS.md` and the biggest-mistake section of
> `ALLIANCE-APPLICATION.md`. **The Hayekian point above survives as an argument about the limits of
> periodic attestation; it no longer has a mechanism attached.** Depeg protection today is
> diversification across eleven constituents and nothing else.

### The tranche

Section 4(a)(1)(A) sets a ceiling on what regulators can require of issuers. It is a constraint on
regulatory overreach, not a definition of what capital reserves are for in general.

The tranche is not a capital reserve in the regulatory sense at all. It is a cost-recovery mechanism
for a documented accounting loss. Collateral damage absorbed in the course of research and development
is projected to be fully amortised (breakeven) as part of "fair launch".

From the basket's perspective the tranche represents a senior liability to seed funders, structurally
subordinating regular depositor claims below it at the accounting level while preserving regular
depositors' dollar-equivalent redemption guarantee intact, because the 1:1 peg is fully maintained on
their portion (excluding the tranche).

From the moment QuidMint's accumulated deficit is fully amortised, preferential treatment in the mint
function of `Basket.sol` ceases to exist. It is not fee income, not yield extraction, and not profit
distribution. It is a restoration of the entity's net asset position to zero, which is the definitional
objective of nonprofit accounting. No profit is generated until the accumulated deficit is fully
recovered, and the tranche is sized to achieve exactly that recovery and no more.

The tranche is an issuance spread — the difference between the dollar deposited and the QD issued —
standard in any instrument with a spread between issue price and face value.

The liability column of the tranche in `Basket.sol` is not simply a quantity of deposited stablecoin
value set aside. It is QD minted on underbacked terms: seed funders receive QD with the multiplier (up
to 2x) without that QD being fully backed by an equivalent dollar value in the basket at the time of
minting. The QD exists as a liability before the backing exists for it. `Aux.sol`'s asset column of the
tranche is what capitalises that underbacked liability and makes it whole over time. The two legs
existing simultaneously is what allows the mechanism to work.

The breakeven structure also does something Howey analysis alone cannot: it removes QU!D from the
category of entities with a profit motive with respect to the basket's output.

---

## Part III — Section 4(a)(11), the yield prohibition

> *"No permitted payment stablecoin issuer or foreign payment stablecoin issuer shall pay the holder of
> any payment stablecoin any form of interest or yield (whether in cash, tokens, or other
> consideration) solely in connection with the holding, use, or retention of such payment stablecoin."*

The prohibition exists for a specific policy reason articulated in the CSBS implementation comment
letter: to "disincentivize the holding of large uninsured stablecoin balances, which could trigger
deposit flight out of the banking system." The concern is issuers using their own reserve income —
Treasuries yield, repo income, bank interest — to pay depositors returns that make stablecoins function
as uninsured deposit substitutes.

The basket holds yield-bearing instruments generating income under the independent governance of those
instruments' respective protocols. QU!D holds these instruments without discretion over their rates,
and without risking QU!D's own CAP to produce them.

Upon minting QD in exchange for their dollars, depositors accept a binding surrender of redemption
optionality for a defined term — precisely the material economic risk the CSBS letter identifies as the
permissibility threshold: *"any payment should require a holder to engage in effort or accept risks
beyond the ordinary course of holding, using, or retaining a payment stablecoin."*

The depositor accepts illiquidity, basket composition risk over the lock period, and secondary market
exit at DCF valuation as their only path to early liquidity, alongside productive deployment as
collateral.

**Corrected 2026-07** (see the redemption mechanics above): the depositor's risk is not merely
illiquidity and composition risk over the lock period. Mature redemption itself is capped-at-par with
an uninsured downside below par under basket stress, from any of three distinct causes. This is a real,
additional material risk beyond ordinary stablecoin holding, and it **strengthens rather than weakens**
the argument: it is precisely the kind of NAV-variability a genuine fund or ETF share carries and a
par-redeemable payment stablecoin structurally cannot. A payment stablecoin's core regulatory definition
turns on fixed-value convertibility; a structure whose redemption value can legitimately fall below par
under stress is further from that definition, not closer to it.

> **⚠️ CONSTRAINT ADDED 2026-08-01, external-communications discipline.** Because the floating downside
> is load-bearing here, **QD must never be described externally as a bill of exchange, a bankers'
> acceptance, or any fixed-sum obligation.** A bill pays an unconditional fixed sum on a determinable
> date; QD does neither. Describing it as one would concede the fixed-value convertibility this section
> spends its length denying. The accurate external analogue is a **defined-maturity fund share** (an
> iBonds-style instrument that matures on a date and returns NAV). A draft of
> `ALLIANCE-APPLICATION.md` used the bill framing on 2026-08-01 and was corrected the same day.

The virtual upfront normalized allocation in `Basket.sol`'s `mint()` compounds the distinction. What
depositors receive at entry is not a current cash payment of interest. It is an accrued entitlement, a
forward-looking claim on future basket yield, computed at entry and redeemable at the chosen maturity.

Verified 2026-07 against `BasketLib.calcMintYield`, modifying nothing: `normalized` at mint equals the
deposited amount plus an accrual term scaled by the depositor's chosen maturity and either a fixed
seed-tranche rate (100% APR projection, while `isSeed` — the bootstrap-incentive constant, not observed
yield) or `avgYield` (the live observed average of constituent-vault yields, once the seed tranche is
filled). One dollar deposited was never literally one QD minted; the accrual is priced in at entry,
exactly as the "accrued entitlement" language argues. This mint-side finding is *consistent* with, not
a correction to, the existing text.

The CSBS letter distinguishes "irregular or unpredictable payments" from structured accrual
entitlements tied to maturity choices. A depositor who selects a longer maturity accepts lock-up risk
in exchange for a larger claim on future yield. This is option-like compensation for a commitment
decision, in the category of allocation rights rather than issuer payments.

Arguments around "solely" are belt-and-suspenders on the yield question. Section 17 is the reason that
question may never need to be litigated at all.

---

## Part IV — Section 17 and the Howey sequence

Section 17 is not a substitute for the Howey analysis. It is a statutory roof built on top of a
successful Howey prong 3 defense. The sequence matters because the payment stablecoin definition itself
contains a circular constraint: a digital asset that is a security cannot qualify. Section 17 therefore
never underwrites an attached RWA. **Howey must be resolved first.**

**Prong 1 — Investment of money.** Satisfied. Depositors exchange stablecoins for QD. This cannot be
argued away.

**Prong 2 — Common enterprise.** Likely satisfied under horizontal commonality. All QD holders share
the same basket composition and performance pro-rata. This is pooling. The correct strategy is not to
contest this prong but to win decisively on prong 3. By 2024 the SEC and Southern District had
effectively collapsed prongs 2 and 3 into a single inquiry — whether profits depend on the promoter's
efforts — making prong 3 the operative question in any enforcement context.

**Prong 3 — Expectation of profits from the efforts of others.** This is where QD's architecture
provides its strongest defense, and where the breakeven structure does something no Howey argument
alone can accomplish. The precise legal question is whose *ongoing managerial efforts* are the
undeniably significant ones — those essential to the failure or success of the enterprise.

### The Peirce question — curator discretion (inserted 2026-08-01)

> **Sourcing caveat, load-bearing.** The Peirce statement (SEC newsroom, 22 July 2026, on crypto vaults
> and lending strategies) postdates the training data of the model that drafted this commentary.
> Everything below works from a second-hand characterisation: that the SEC is examining the economic
> function of vaults and curators; that a curator deciding how other people's assets are deployed may
> be acting as a fund manager or investment adviser even when everything happens through smart
> contracts; that custodial versus non-custodial is not the axis of concern; and that what matters is
> whether a strategy is credibly rules-based or whether users are relying on the judgment of an
> identifiable manager. **Read the statement before relying on any of this.**

The Peirce statement is the best thing that could have happened to this section, because it replaces a
subjective prong-three argument with an objective question about code, and QU!D can answer that one.

If the operative test is whether a strategy is credibly rules-based or whether depositors rely on the
continuing judgment of an identifiable manager, the question becomes: after launch, what function can
any person call that changes where depositor assets are deployed? The answer is none, and it is
enforced rather than promised.

`Aux.finalize()` calls `renounceOwnership()`. Every discretionary lever in the reserve sits behind
`onlyOwner`, so all of them die at that call: `evacuate`, `setVault`, `setStableFeed`, `setAssetFeed`,
`setEthVenue`, `setBTCChannels`, `setQuid`. `Vogue.setup()` renounces the same way. The basket's
constituent set is fixed at deployment and cannot be added to. The leverage venue allowlist is pin-once
then frozen behind a `venuesFrozen` flag, described in the source itself as matching the
renounce-everything posture. The contracts are not upgradeable and have no administrator, so changing
allocation logic would require a new deployment and a voluntary migration by depositors.

**This is the distinction against a curated vault.** A Morpho or Euler curator holds *continuing*
discretion: they can reallocate tomorrow, into markets nobody has seen yet, and depositors rely on that
judgment prospectively. QU!D's allocation decision was exercised once, at deployment, and is now
unreachable by anyone including the deployer. The Howey argument already turns on *ongoing* managerial
effort, and the Peirce framing converges on the same axis from the adviser side rather than the
security side.

**Two design decisions were made specifically to remove discretion, and they read as evidence of
intent.** `pokeVaultHealth` is permissionless and reads only ERC-4626 ground truth, comparing
`convertToAssets` against `maxWithdraw`. It can tighten and never loosen and it cannot re-quote anyone's
value. It replaced a graded `haircutBps` lever that was removed *because* it was owner-only. A system
that deletes its own discretionary levers before anyone asks is making the rules-based case in the
strongest available form. Separately, the yield venue is chosen per deposit by the depositor and there
is no setter, so what allocation discretion exists belongs to the depositor.

**A further argument runs from the entity rather than the code.** The Investment Advisers Act definition
at §202(a)(11) requires acting as an adviser **for compensation**. A memberless Cayman foundation whose
only extraction is a tranche sized to recover a documented accumulated deficit under ASC 958, and which
terminates at breakeven, has a weak compensation element. Code facts and entity facts point the same
way, which neither does alone.

**What survives, and should be disclosed rather than discovered.** `Vault` retains three owner setters
(`setRover`, `setLevManager`, `setLevManagerBTC`) and no renounce was found on that contract. If the
intent is the renounce-everything posture the rest of the system takes, **this is the gap to close
before launch.** The multisig over the enclave measurement whitelist governs which code may operate the
Bitcoin hop and moves no funds, a governance surface and not an investment-discretion one. The
off-chain keeper managing leveraged positions is protocol-operated, and its defence is that it executes
a closed-form target, `1 − √(entry/now)`, on opt-in positions isolated to the depositor's own external
account, so it selects nothing.

**Summary for counsel:** composition and allocation logic are frozen at deployment, the surviving
automated paths are permissionless and read objective on-chain state, and the discretion that remains
is over infrastructure rather than over where depositor money goes. Closing the `Vault` setters would
make that claim complete.

#### Verification trail (read from source 2026-08-01, not recalled)

| claim | location |
|---|---|
| Aux renounces at finalize | `evm/src/Aux.sol:598-604` |
| Vogue renounces at setup | `evm/src/Vogue.sol:309-313` |
| evacuate / setVault / setStableFeed / setAssetFeed are onlyOwner | `evm/src/Aux.sol:487`, `:497`, `:167`, `:191` |
| basket constituents fixed at deploy, no permissionless binder | `evm/src/Aux.sol:177` |
| lev venue allowlist pin-once then frozen | `evm/src/LevManager.sol:146`, `:208-210` |
| pokeVaultHealth permissionless, ERC-4626 ground truth only | `docs/informational/VAULT-WATCHER.md` |
| graded haircutBps removed because owner-only | `docs/informational/VAULT-WATCHER.md` |
| depositor picks venue, no setter | `evm/src/Vogue.sol:1277-1281` |
| Safe governs MRENCLAVE whitelist only, moves no funds | `evm/src/AttestedHopRegistry.sol:47-53` |
| **Vault setters with no renounce found** | `evm/src/Vault.sol:355`, `:362`, `:372` |
| IL target closed-form, zero at or below entry | `evm/src/imports/LevMath.sol:109-125` |

### Completing the sequence

QU!D's efforts are limited to two moments: deployment of the contract, and initial LP attraction
through the seed funder mechanism. After those two acts, QU!D makes no ongoing managerial decisions
that steer profitability, especially not in any way materially more significant than the governance
decisions of the constituent protocols within the basket.

The Ninth Circuit's 2025 decision in *SEC v. Barry* confirmed that the operative test is whether the
manager's *ongoing* efforts steer the project toward profitability. Deployment and initial
bootstrapping are ongoing efforts until they are fulfilled.

The enterprise cannot be steered toward profitability by any managerial decision because no managerial
decision can accelerate or expand the recovery beyond what the tranche mechanism represents. A promoter
whose enterprise produces no profit until a specific, documented, terminating threshold is crossed, and
whose distribution mechanism is enforced by contract rather than discretion, is not the kind of
promoter Howey's prong 3 was designed for. During the seed funder phase QU!D's enterprise produces no
profits. After breakeven the tranche mechanism terminates and QU!D has no further extraction mechanism
at all.

The secondary market severs the remaining thread. *SEC v. Ripple Labs* distinguished institutional
sales, where buyers specifically relied on the issuer's efforts, from programmatic secondary market
sales where anonymous buyers cannot know whose efforts produce returns and therefore cannot form the
expectation prong 3 requires. QD's DCF-priced secondary market is analogous: secondary buyers acquire a
discount instrument whose value is determined by basket mechanics and time-to-maturity, not by any
QU!D managerial decision made after deployment.

**The sequential conclusion.** QD fails Howey prong 3 because returns are generated by the independent
managerial efforts of the constituent protocols. By non-security status, QD qualifies as a payment
stablecoin. Section 17 then converts that qualification into a statutory guarantee across six federal
statutes simultaneously: the Securities Act of 1933, the Securities Exchange Act of 1934, the
Investment Advisers Act of 1940, the Investment Company Act of 1940, the Securities Investor Protection
Act of 1970, and the Commodity Exchange Act. Section 17 also clarifies that permitted payment
stablecoin issuers are not investment companies, removing ICA exposure without requiring reliance on
Section 3(c)(1) or 3(c)(7) exemptions.

The structural arguments are not merely regulatory positioning. They are the conditions under which
this sequential logic holds at every step. **Lose the Howey prong 3 defense and Section 17 never
attaches. Lose the payment stablecoin classification and the full securities analysis is inherited
simultaneously.**

SEC Chair Atkins stated publicly in July 2025 that only a limited number of crypto assets should be
treated as securities under federal law, and the agency has dismissed many pending cases inconsistent
with current policy. The Howey analysis should nevertheless be documented now precisely because
enforcement environments shift — QD's architecture holds under the most demanding version of that
analysis regardless of who is enforcing it.

---

## Part V — PACE Act

Independently verified against the bill text, which remains a recently-introduced House bill, not law.
Treat this section as a reasoned application for counsel to test, at the same evidentiary level as
everything else here.

PACE (Payments Access and Consumer Efficiency Act, introduced 2026-04-21, Reps. Kim/Liccardo) creates a
federal "Registered Covered Provider" category: qualified nonbank payment firms register with the OCC
and connect directly to Fed rails (FedNow, FedACH, Fedwire) via a dedicated payments reserve account,
bypassing the sponsor-bank intermediary layer GENIUS-compliant issuers otherwise depend on.

**QD is very likely not a PACE-relevant registrant.** The Registered Covered Provider category is built
for GENIUS-style payment stablecoin issuers and payment firms moving fiat at scale under a fixed-value
redemption model — precisely the category the Howey/Section 17 analysis above, strengthened by the
redemption correction (capped-at-par, floating downside, not invariant), argues QD is *not*. Forcing a
PACE-registrant characterization onto QD would cut against the fund/ETF-share positioning the rest of
this document builds. **PACE is not the basket's regulatory home and should not be pursued as one.**

Second-order relevance: the basket's constituent issuers (FRAX, DAI's protocol, sUSDe/Ethena) are more
plausibly PACE registrants in their own right. If they gain direct Fed rail access their own settlement
and redemption improves, which passes through to the basket's yield and liquidity exactly as the
pass-through framing describes — a benefit to QD holders requiring no action or registration by QU!D.

---

## Part VI — Lending, licensing and cross-border (added 2026-08-01)

Full commercial reasoning and sources in `docs/informational/CREDIT-STRATEGY-FINDINGS.md`. The legal
conclusions:

**Licensing follows the borrower, not the lender.** Offshore incorporation exempts nothing. A
foundation-owned IBC needs the same state licence a shareholder-owned one does, and true lender
doctrine has killed most attempts to route around it.

**A riskless intermediary does not work.** In May 2026 a California court held in the OppFi matter that
at origination the entity which **funds, controls underwriting, and bears risk** is the true lender.
Conjunctive. A bank acting as a riskless conduit is therefore not the lender and the licensing
obligation lands on whoever funds and bears risk. The fix is genuine retention, which EU securitisation
rules already require at 5% for the same reason. **The "hop" pattern that is correct in `BTCChannels`
inverts here: in Lightning risklessness is the safety property, in regulated finance it is the defect.**

**CRD VI closes cross-border lending into the EU from a third country.** Article 21c bans third-country
undertakings from providing core banking services, expressly including lending (consumer and
corporate), into the EU without a licensed branch. Transposition 10 January 2026; **grandfathering cut
off 11 July 2026, already passed**; prohibition effective 11 January 2027. Exemptions (interbank,
intragroup, reverse solicitation, MiFID-ancillary) are narrow and reverse solicitation cannot support a
business model. **OPEN:** whether the non-bank carve-out exempts a pure lender that takes no deposits,
since the EU credit-institution definition requires deposit-taking *and* lending, and whether national
transposition preserves that.

**Directive 2021/2167** creates a passportable regime for non-banks acquiring bank-originated credit,
but its confirmed scope is **non-performing** loans. **OPEN:** whether it reaches performing mortgage
loans.

**Foreign-currency consumer lending is regulated scar tissue.** After the CHF mortgage crisis (Poland
~550k loans, €30bn, 7.7% of GDP; Hungary two-thirds of household debt, ~28% of GDP), the Mortgage
Credit Directive permits FX consumer loans only with a conversion right or equivalent protection.

**Payee-of-record purchase scope.** The line is narrowness: buying a specific good and delivering it
with pre-funded customer money resembles a merchant or agent of the payee; general spending power
resembles money transmission plus prepaid access. Any crypto-to-fiat conversion is money transmission
on its own. Already `ibiza/COMPLIANCE-THESIS.md` open question 4.

**Surety collateral.** State insurance regulators define admitted assets, and a crypto basket claim is
almost certainly not among them. **OPEN:** whether a third-party trust with the surety taking a pledge
or letter of credit resolves it.

**Entity and residency — correction.** An earlier warning that a US-resident founder triggers CFC and
GILTI was overstated. A Cayman foundation company constituted with **no members** has no US shareholder
to attribute ownership to, so Subpart F does not engage, and corporate default classification keeps
§679 grantor trust rules out. **The exposure that survives is management and control**, independent of
ownership: a US-resident director deciding from US soil raises effectively-connected-income questions,
and compensation is personal income wherever the entity sits. **PREREQUISITE, UNRESOLVED: is QuidMint
Foundation actually memberless, or does it have members with economic rights?** The entire analysis in
this paragraph and the Advisers Act argument in Part IV both turn on it.

---

## Open questions, consolidated

**Blocking, and not resolvable by engineering or by more research:**

1. **Is QuidMint Foundation memberless?** Prerequisite for both the tax analysis and the Advisers Act
   "for compensation" argument.
2. **Does CRD VI's non-bank carve-out exempt a pure lender?** Counsel. Five months to the prohibition.
3. **Can a surety hold a QD claim under admitted-asset rules, or does it need a third-party trust?**
   Counsel. Decides whether the deposit-collateral product exists.
4. **Does payee-of-record fulfilment trigger money transmission?** Counsel. `COMPLIANCE-THESIS.md` Q4.
5. **CIMA / BVI FSC requirements for a prepaid-card fleet operator, and OFAC's direct extraterritorial
   reach.** `COMPLIANCE-THESIS.md` Q1, Q2.
6. **Who bears liability for fuzzy name-matching errors in the sanctions-exclusion layer?**
   `COMPLIANCE-THESIS.md` Q3.

**Answerable from documents, not yet answered:**

7. Does Directive 2021/2167 reach performing loans, or stop at NPLs?
8. Read the actual Peirce statement of 22 July 2026 and confirm the characterisation in Part IV.
9. Is the Ukrainian витяг КЕП-signed, and is the signature verifiable off a published chain?
10. Does perfecting a pledge over a QD claim require notarisation and pledge-register entry in target
    jurisdictions? (US: no, UCC control. Civil-law: per country.)

**Action items inside our control:**

11. **Close the three `Vault` owner setters, or record why they must survive launch.** This is the one
    open item that materially weakens the Part IV argument and it is fixable by us.
12. Model the collateral haircut the capped-at-par redemption requires, against the incumbent's 17.5%.
13. Place this file wherever the canonical legal document should live, and delete
    `docs/informational/CURATOR-DISCRETION-AND-THE-PEIRCE-QUESTION.md`, which this supersedes.
