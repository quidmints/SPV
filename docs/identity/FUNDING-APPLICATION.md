# Funding Application — Private Property & Identity Infrastructure

> All software described here is written and ships with this application. Claims are deliberately
> conservative: what is built is described as built, what is not is described as not.

**Source code** (both repositories ship with this application):
- Identity, privacy pool and title layer — <https://github.com/quidmints/ibiza>
- Treasury and reserve protocol — <https://github.com/quidmints/SPV>

**Prior deployment of the identity base, in Iran:** Rarime's Freedom Tool — the passport
zero-knowledge stack this work renovates — was used by Iranian civil-society organisations
(IranUnchained, TCT e.V.) to run anonymous protest votes on the 2024 presidential election,
verifying eligibility from biometric passports scanned locally, with nothing transmitted to a server.
<https://alexablockchain.com/iranian-voting-app-to-protest-presidential-election/>

**Scope of the lending design.** Section 2's central choice, that the protocol funds loans and nobody
underwrites them, is specific to jurisdictions where licensed origination is unavailable, captured, or
itself a vector for refusal. That is the case this application addresses, and the anti-refusal property
in section 1 is the whole reason for the choice. The same identity, title and reserve stack also runs a
second configuration wherever licensed origination functions normally: a licensed originator finds the
borrower, values the property, sets the terms and registers the lien, and the reserve funds and holds
the resulting paper. That configuration gives up the anti-refusal property and is not what is proposed
here. Its privacy layer serves a different end, keeping the borrower's file with the originator rather
than shipping it to whoever holds the paper, and the originator must retain a genuine risk slice rather
than act as a conduit, since a lender that bears no risk is not the lender for licensing purposes.
Recorded so the two are not read as contradicting each other. Research record, including why the
closed-title-register premise does not hold in Ukraine, the US or England, and why notaries gate
writing rather than reading: `SPV/docs/FAQ.md` Part 4.

---

## 1. Short description of the proposed project *(297/300 words)*

All of the software is built. It lets a person prove who they are, and prove they own a piece of
land, without disclosing either to the public.

This is not hypothetical here: the passport zero-knowledge stack we renovate was already used inside
Iran for anonymous voting. The passport is read by the phone's NFC chip, checked on the device,
nothing sent to a server.

We joined two open-source systems. Privacy Pools (0xbow) lets someone deposit and later withdraw
without the two being linkable; Rarime proves a passport genuine while revealing nothing about its
holder. Each had a gap: Privacy Pools screens *money*, using chain-analysis guesswork that taints
funds by association; Rarime proves *personhood* but touches no money. Merged, a withdrawal proves
the honest thing — a real, non-sanctioned person is withdrawing.

Three things the merge makes possible that did not exist:

**Shielded money that earns.** Privacy Pools holds deposits idle. Ours sit in a reserve that earns
yield while shielded, so privacy stops costing the user their return.

**Bitcoin without a custodian.** Production BTC bridges ask you to trust an operator or committee
holding the coins. Ours does not: the depositor keeps one of two keys, the protocol cannot move funds
alone, and if the protocol disappears the depositor closes the channel and recovers their bitcoin
unilaterally.

**Land ownership as a private, verifiable fact** — provable to a lender or a court, invisible to
everyone else, and impossible to register twice over the same parcel.

The purpose is narrow and worth stating plainly: to strip a licensed intermediary's cost out of
mortgage credit, and to make refusal impossible. Nobody can be denied on grounds of faith, politics,
sex or ethnicity, because there is no one in the system with the power to refuse.

---

## 2. Implementation: approach, activities, and milestones *(997/1000 words)*

**Every part of the software is written and ships with this application**, proving and verifying
on-chain today. It has not had an audit, a real document, or value at stake — the three gaps the
milestones close, in order.

**What ships:** the zero-knowledge circuits for registration, withdrawal, escrow and emergency exit;
the identity registry, shielded pool and title ledger; the reserve that earns on shielded deposits;
the payment-channel bridge holding bitcoin without a custodian; and a wallet deriving every key from
one phrase in the phone's secure enclave.

One engineering decision underpins the rest: the two systems we merged proved things incompatibly,
so we rebuilt both onto one proving system — one toolchain to keep current, one surface to audit.

Both repositories are public, so the claim is checkable: clone either, run the suites, regenerate
every fixture from committed scripts. Each generated verifier is exercised on-chain against a real
proof, so one that stopped verifying would fail.

### Milestone 1 — Audit

Nothing reaches a real user before independent review, by descending risk. **The circuits**, where a
flaw is silent and total: one wrong constraint mints value or bypasses identity while tests still
pass. **The identity registry**, whose guarantees are the product: it can refuse
nobody, exclusion demands an act citing a rule, and a stale record expires so revocation cannot be
outrun while the newest never expires, so inaction blocks nobody. **The enrolment gate** feeding it
(section 5). **The money** — deposit and withdrawal accounting, double-spend prevention, redemption.
And **key handling**, where a weakness loses funds however good the circuits are. We will also
commission a review of who can do what to whom, where such systems fail more often than in
arithmetic.

### Milestone 2 — Deploy

Both repositories to mainnet. **The gating item is not the contracts but the phone:** the identity
libraries run only on a device, and passport NFC reading is the one piece still to write — a contract
nobody can reach is not deployed. This milestone finishes it and confirms a proof made on real hardware
verifies on-chain.

### Milestone 3 — Proving it works in practice

A small consenting group, real documents, value starting near zero and rising as it holds: scan,
register, deposit, withdraw to a fresh address, and confirm nobody holding the whole chain can
connect the two. Timings come from mid-range phones.

**This is field work** — engaging notaries, retaining counsel, recruiting through partners users
already trust — done in-country, where most of this funding goes. It needs documents from several
states, since chip behaviour differs beyond the standard.

### Milestone 4 — Title and lending

The title ledger exists; the bridge to the land registry does not. Iran's Deeds and Properties
Organisation (*Sazman-e Sabt*, سازمان ثبت) grants three levels of access, each doing a job the others
cannot — and that division decides where each check runs:

- **The owner**, via *Sabt-e Man* (my.ssaa.ir), sees every parcel and charge against their ID
  (*kod-e melli*, کد ملی) — the only way to *discover* an undisclosed charge.
- **Anyone** can confirm a named deed (*Tasdiq-e Asalat*, تصدیق اصالت) from its 18-digit identifier
  and the owner's ID.
- **A licensed notary** (*Sardaftar*, سردفتر), via ssar.ir alone, registers a mortgage or executes a
  transfer.

Only a licensed notary can register a *consensual* mortgage: a private agreement is not void, but
the Land Registration Act makes it inadmissible before courts and registries, so it cannot be
foreclosed. Whether a notary is licensed is public fact about a public register, which we index
through a decentralised oracle network where every node returns byte-identical data.

A *deed* cannot be checked that way, because the query names the owner. Run by a lender it exposes
every applicant; run by the owner it discloses nothing — they supply details a government already
holds. So the owner runs it on their own device and submits a proof: what reaches the chain is that
a genuine deed exists, bound to identifiers naming neither party nor parcel.

**Notaries can be punished for serving a system like this.** Today the acting notary is named
on-chain: an address in the title entry, and an indexed event topic. Anonymising them — set
membership without naming a member — is designed, not built.

**We fund loans; nobody underwrites them — the central choice.** Underwriting means judging a
person, and whoever holds that judgment can refuse: on faith, politics, sex, name. A promise never
to use it is worth only the promiser's freedom from pressure, so the power sits nowhere. The
protocol lends against collateral checked mechanically — genuine title, unencumbered parcel, ratio
within limits — which cannot be aimed at anyone. **The reserve lends, the borrower repays it** on a
schedule the contract holds, a notary creates the lien, and the borrower's equity is first loss.

**Two more reasons not to take that role.** Underwriting needs a licence, so doing it ourselves
would put the system on permission that can be withdrawn — and an underwriter holds the borrower's
file, which we would rather never hold: uncollected data cannot be compelled.

A cheaper rate follows, though less than disintermediation usually promises; section 7 sets out
which parts of a bank's rate we remove and which we do not.

Lending also needs what cryptography cannot supply: an **independent valuation** — the borrower
provides the figure and gains by inflating it. The tractable form is attesting a licensed valuer, as
we attest notaries, or reading auction results.

Foreclosure uses existing institutions — judicial enforcement (*Ejra-ye Ahkam*, اجرای احکام) and
auction (*Mozāyedeh*, مزایده) — with irrevocable assignment
(*Vekālat-nāmeh-ye Belā-'Azl*, وکالت‌نامه بلاعزل) signed at the start, a form courts accept.
**If valuation cannot be made independent we ship identity and title without lending.**

**Delivered:** an audit report and fixes; live contracts and a wallet reading a real passport;
evidence a person can register, transact and leave unconnected; a title from a proven-licensed
notary, property undisclosed.


---

## 3. Technical feasibility *(298/300 words)*

**Technologies.** Noir/UltraHonk circuits; Solidity verification; React Native over the platform
secure enclave. Identity follows ICAO 9303, so the trust root can be the issuing state's signature
rather than anything we control — today a key of ours attests it, which milestone 1 moves on-chain.

**Capacity.** The system is built and tested — the strongest evidence we can build it. We found and
fixed subtle defects on the way: a proof binding to an unconstrained field, stale roots letting
revocation be evaded, one parcel titleable twice. Finding our own errors matters more than claiming
correctness. **The identity base is field-proven here:** the stack we fork ran anonymous Iranian
protest voting (link above), so scanning by users at risk is demonstrated.

**Dependencies.** The proving toolchain and document standard, both stable and open; registry
portals we do not control.

**Risks and mitigation.** *Lending's dependencies do not resolve* — valuation, an entity able to
hold a lien, a state-visible encumbrance; mitigated by scoping identity and title to stand alone,
since provable private ownership is useful without anyone lending on it. *Portal changes break
the scrapers* — versioned workflows with a timelock, so updates are visible before taking effect.
*Registry access withdrawn* — local integration sits behind an interface, so a jurisdiction is
configuration, not a fork.

**One bound we state rather than hide.** Both trust roots are the state's own: the property
registers, and the signing keys that make a document genuine. Strong against private fraud — a
bribed notary, a forged deed — and worthless against a state fabricating credentials. **That
signing-key list is the one input we must get right and cannot prove right from inside:** a proof
shows only that a document was signed by a key on the list it was handed. It comes from the
official directory, pinned on-chain.


---

## 4. Scalability *(298/300 words)*

**Cryptographic scaling is already done and measured.** The withdrawal proof was reduced from 43,772
to 24,812 constraints — a 43% cut — by merging two identity structures into one and moving the
identity check off the frequently-used path onto a one-time registration step. Costs that recur per
user, per transaction, are the ones we optimise; one-time costs we accept.

**On-chain state scales sublinearly.** Membership lives in a sparse Merkle tree; adding a user costs
a proof of depth proportional to the logarithm of the population, not its size. The registry is sized
for roughly four billion identities, which is not the binding constraint.

**The binding constraint is client proving time**, since proofs are generated on the user's phone. It
is bounded by circuit size, which is why we measure every change in constraints rather than
estimating. This also scales with hardware improving over time, in our favour.

**Jurisdictional scaling is the real question.** Identity, title and mortgage logic are the same
everywhere. What is local is narrow — the registry endpoints, the deed format, the enforcement
institutions — and sits behind interfaces, so a second country is configuration plus legal review
rather than a second codebase. Notaries scale the same way: proving membership of the licensed set
costs the same whether that set holds ten or ten thousand.

**Every user brings their own capacity.** Proofs are made on the person's phone and checked by the
chain, so there is no shared component that saturates: a thousandth user costs the same as the first.
The reserve grows by adding deposits, needing no protocol change and nobody's permission, and its
assets are diversified so capacity is not gated on the depth of any single one. What limits lending
volume is the supply of independently valued properties, not anything technical.


---

## 5. Resilience to censorship *(300/300 words)*

**What can be blocked** is network access to the chain, the registries the property layer reads,
and one approval step we have not removed: enrolling a passport needs a signature from a key we
hold, attesting the issuing state's certificate chain off-chain. That key could be ordered to
refuse one person, invisibly. Milestone 1 verifies the chain inside the proof instead, turning
refusal into an all-or-nothing act everybody can see.

**After that step there is no gatekeeper.** No server to seize, no operator to coerce. Exclusion
**fails open** — someone pressured into inaction blocks nobody, because the newest state stays valid
indefinitely. Most systems get this backwards; here doing nothing is safe. Nor can anyone be dropped
quietly: exclusion demands an act citing a reason, recorded permanently.

Chain access runs over ordinary HTTPS to any endpoint the user supplies, hard to tell from other
web traffic.

**App-store delisting is among the weakest levers against us.** Sanctions already keep Google Play
largely unavailable to Iranian users, so that market runs on local stores and direct installation —
sideloading is the norm, not a habit we must teach. React Native was chosen for that: it compiles to
a standard Android package installable from a file, passed between phones or over a messaging app,
with no store, no account, no record of who downloaded it. A store can be delisted; a file cannot.
iOS lacks this, so Android leads.

**Blocking the registries degrades rather than stops the system.** Identity and the shielded pool
read no state endpoint — only the passport chip and the chain — so cutting it costs property
functions alone.

**What we cannot engineer away** is coercion: a seized phone whose holder is made to unlock it.
Biometric gating and no identity in the clear limit that without solving it.

---

## 6. User security measures *(284/300 words)*

**Nothing identifying is published.** An obvious design would store a fingerprint of a street
address; anyone could fingerprint public records and find the match. Those values are disguised
against search.

**One secret, in hardware.** A single phrase sits in the phone's secure storage behind biometric
unlock and every other key derives from it — spending keys derived, never stored. If hardware
backing cannot be confirmed, the wallet refuses to store it.

**The gap we disclose rather than let an auditor find: there is no recovery.** The phrase is
generated on the device, never shown, kept out of cloud backup — a lost phone is a lost identity and
lost funds. Milestone 2 adds recovery putting no key on anyone's server.

**A guaranteed way out.** Whoever deposited can always reclaim directly from the contract with the
key on their own phone — no approval, no operator, nothing but the chain. The cost is that it
publicly links the deposit to whoever reclaims it, a trade nobody makes for them.

**Assumptions stated, not hidden.** The check proves someone holds a genuine document, not that
they are trustworthy — and a person may hold several, limiting what excluding one achieves.

**Joining is now unobservable.** Registration used to publish a person's identity beside their pool
account, so it was visible someone had joined. The proof now shows the document is registered
without naming it; the one published value is shared by everyone.

**Verification over assertion.** We test by deleting a safeguard and confirming the test then
fails rather than trusting a green result — which caught real defects, including two tests that had
quietly stopped checking anything.

**Audit first.** No real value at stake until independent review is complete and its findings
fixed.


---

## 7. Keeping costs low *(299/300 words)*

**No infrastructure to run.** No backend, no database, no server holding user data — removing the
largest recurring cost and the largest liability together. Ethereum provides availability; the phone
does the rest.

**Optimise what recurs, accept what does not.** Every change is measured, and we reject those adding
cost to the frequent path however elegant: withdrawal is 43% cheaper than it was, and one redesign
was cancelled on measurement at 12% more expensive for a cosmetic gain. Registration cost we
accept — paid once per person, not per transaction.

**Transaction fees are the user's cost, so they are our problem.** Verification cost is fixed by
proof size, constant here however complex the computation behind it.

**Build on maintained open source.** We wrote no proving system, data structure or passport parser.
Where we briefly wrote one, we deleted it and asked the chain instead — less to maintain, and
impossible to drift out of agreement.

**One mechanism, two uses.** Blocking a sanctioned person and stopping a property being mortgaged
twice both reduce to publishing disguised identifiers anyone can check without learning what they
mean. Built once, used for both — half the code, one auditable thing, one fewer contract.

**The largest cost a borrower bears is the rate, and we cut less of it than disintermediation
implies.** Banks fund on insured deposits, the cheapest money there is. What genuinely goes is
branch overhead, the charter's capital charge and the premium a licensed few command. Iran's 30% is
mostly currency — negative in real terms against 40% inflation — so hard-currency credit is cheaper
in name only unless the borrower earns it.

**Grant funds go to audit, field work, devices and legal review** — what money alone unlocks. Field work dominates after audit: notaries, counsel per jurisdiction and cohort recruitment
are people-time in-country, not engineering.


---

## 8. Maintenance beyond the funding cycle *(294/300 words)*

**Nothing to keep running.** With no servers there is no cost floor: if funding stops, the deployed
contracts continue and users keep control of their money. Even if the project is abandoned outright,
nobody is stranded — the direct reclaim in section 6 needs no one but the user.

**Documented to be handed over.** The codebase records not only what it does but why — decisions that
were reversed and the measurement that reversed them, safeguards that exist because a specific
failure was found. Someone who never met us can follow the reasoning. This is already the working
practice, not a plan.

**Open source, on maintained dependencies.** The proving toolchain and identity libraries are
actively developed by others; our contribution is the layer joining them, and defects we find there
we have already contributed back.

**How it pays for itself.** The reserve earns a return whether or not a single mortgage is ever
written, and that — not lending — is what funds maintenance. We do not plan to depend on repeated
grants: this funding is for what cannot be self-funded, principally the audit.

**What actually recurs is narrow.** One thing genuinely needs attention over time: a government
portal changing its format, breaking the reader that indexes it. Everything jurisdiction-specific is
isolated behind one interface, so that repair is self-contained, local, and touches no cryptography —
a developer in-country can do it without us and without any key we hold.

**What happens if we stop.** The contracts are not upgradeable and have no administrator, so they
keep running with nobody at the controls; deposits, withdrawals and existing titles are unaffected by
our absence. The worst case is not loss but staleness — a stale reader blocks new titles while
leaving every existing balance and title reachable.

