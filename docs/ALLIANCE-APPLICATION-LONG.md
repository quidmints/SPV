# Alliance application: answers

Written 2026-08-01. Every technical claim was checked against the code in `quidmints/SPV` and
`quidmints/ibiza` before it went in, and file references are given where a reader might want to
verify one. Written to be legible to someone who does not work in crypto.

---

## What is the problem you're solving?

We had a baby, and a piece of what that child inherits was decided for us. The account the federal
government seeds at birth is invested in a US stock index fund and locked until they turn eighteen.
It's a good thing to have. It is also a single bet on one country's equity market, in one currency,
that nobody in the family gets a say in for eighteen years.

So the real question was where the rest of a child's nest egg should sit. It should not be correlated
to that account. It should not sit with a custodian who can lose it. And it should be something my
wife and I can look at alongside our wealth manager and argue about from shared numbers, rather than
a line item he politely ignores because he can't see inside it.

Every option available to us was bad in a specific way, and each of those ways turns out to be
fixable.

**Holding Bitcoin and Ethereum earns nothing.** They sit there. If you want them to earn, the usual
move is to become a liquidity provider, which means putting them into an automated market maker: a
pool of two assets that quotes prices by formula instead of by order book, and pays you a cut of the
trading fees. The catch is what the pool does with your money while you're in it. It sells whatever
is rising and buys whatever is falling. In a rally you end up holding less Bitcoin and more dollars,
having sold the Bitcoin too cheaply the whole way up. In a decline you end up holding more Bitcoin at
progressively worse prices, which people in this industry cheerfully describe as buying the dip and
which is, in a sustained downtrend, just losing. The gap between what you'd have had by doing nothing
and what you actually have is called impermanent loss, and it is neither small nor impermanent once
you've exited. There's a well-known result that the fees you collect roughly cover it and no more,
which means the average liquidity provider would have been better off sitting still.

Worse, the mechanism that keeps a pool stocked is the mechanism that costs you. A pool's price is
always slightly stale relative to the real market. Professional arbitrageurs trade against that
staleness, correcting the pool and pocketing the difference. That correction is how the pool keeps a
sensible mix of both assets on the shelf, and the money for it comes out of the liquidity providers.
The industry's name for this is loss-versus-rebalancing. In plain terms: the pool stays stocked by
letting informed traders pick off the people who supplied it.

**Putting the dollar half in one stablecoin is a bet nobody can price.** A stablecoin sits at exactly
one dollar with overwhelming probability, right up until it doesn't, at which point it moves to a
different regime in minutes. There is almost no data in the middle. The risk is also reflexive, in
that the price of insuring against a break feeds the probability of the break. And these events
cluster, so the one moment your protection pays out is the moment everything else you own is also
breaking. That combination means there is no honest premium to quote for it, which we'll come back to
when the competition comes up.

**Bitcoin locked into Lightning earns nothing either.** Lightning is Bitcoin's payments layer, and to
route a payment through it you have to lock coins into a joint account with your counterparty. That
capital earns zero for as long as it sits there. This is the whole reason Lightning has been short of
liquidity for a decade: providing it is a cost centre, so there isn't enough, so routing is shallow,
so the network underdelivers.

### What we built instead

**You deposit one asset and you keep it.** Bring Ethereum on its own, or Bitcoin on its own. You
don't sell half of it to fund the other side of a trading position, which is what every other venue
requires. When you leave, you leave in the asset you brought, plus what it earned. The claim you hold
while you're in is a standard yield-bearing vault share, the same interface any wallet or accounting
tool already knows how to read, so your wealth manager's software can price it without a bespoke
integration.

**The protocol funds the dollar side out of its own future.** This is the part that makes single-sided
deposits possible, and it's worth explaining slowly because it's the heart of the design.

A trading position needs both assets. Normally that means you sell half your Bitcoin to buy the
dollars. We don't ask for that. Instead the protocol issues a dollar claim against yield it has not
earned yet, uses that to fund the dollar side of your position, and then earns the yield that redeems
the claim from the trading and lending the position enables.

Think about how a diesel engine starts. It needs no spark. Compression alone ignites it, so the engine
is self-sufficient once it's turning. The only genuinely hard part is turning it over the first time,
and with a dead battery you don't need a jump pack: you roll the car in gear and let its own momentum
crank the engine until compression catches. The energy comes from inside the system.

Most crypto projects cold-start with a jump pack. They print a governance token and pay people to
show up, which works until the subsidy stops. We crank the engine with its own forthcoming output.
Early depositors get paid out of the protocol's own projected yield, monetised up front, and the
liquidity that creates generates the yield that was promised. There's a hard ceiling on how far we can
crank, 600,000 units, written into the contract (`Basket.sol:25`). After the first twelve months the
projection horizon collapses from a year to a month, because by then we have real observed yield and
no longer need to guess.

The instrument this works through is a bond ladder. One token contract holds many dated series, each
maturing on its own month, so at any moment we know our entire forward dollar liability curve: what
we owe in March, in April, and so on. That is what an insurer's duration-matched book looks like,
expressed as a token. It's also why we don't need the capital structure everyone else builds.

The conventional way to make a claim safe is to subordinate somebody. You create a senior tranche and
a junior tranche, and the junior eats losses first. Then you carry that waterfall forever, with a
separate valuation for each layer. We subordinate time instead of a person. Future yield is the junior
tranche. There is one elastic supply, no waterfall, and no per-tranche accounting, because the thing
being subordinated is a date rather than a claimant.

**The impermanent loss on the way up is cancelled.** Here is the mechanism in one image. The problem
in a rally is that the pool sold your Ethereum too cheaply. So we give the pool something else to
sell. An optional overlay borrows dollars against your own collateral, on an outside lending market,
buys extra Ethereum with them, and hands that extra to the pool as the inventory it sells during the
rally. Your principal is left alone. The buffer is sized exactly to the loss the pool has actually
created, which is a number we can compute from how far price has moved since you entered.

Two things about that are worth a non-specialist's attention. The borrowing happens on somebody else's
lending market, one position per depositor, walled off from everyone else. If a position goes wrong it
hits that one depositor and stops. Nothing about it touches the shared reserve, and we have a test on
real Morpho with a real price feed that runs a leveraged position through a full liquidation and then
checks that a passive depositor's redeemable value and the reserve's backing are untouched
(`test/LeverageCrossSubsidyProbe.t.sol`).

And the overlay unwinds to zero debt when price falls back below where you started. We are never
carrying borrowed money into a crash. Most of the reason people get destroyed in this industry is
holding leverage through a decline, and our design refuses to.

**The dollar yield comes from breadth.** Eleven stablecoins, spread across lending venues, rather than
one issuer's promise. Since the risk of any single one breaking cannot be priced, the only honest
protection is to never be concentrated in one. There is a second-order effect here that surprised us.
When a depositor locks dollars with us for twelve months, they are simultaneously removing redemption
pressure from every stablecoin in the basket, in proportion to its weight. No individual issuer can
offer that, because no individual issuer holds the others. A longer lock relieves more pressure, which
is why our yield schedule pays more for duration: the extra yield is the market-clearing price for the
stability the lock provides. Each issuer needs to hold less cash on hand against redemptions, so each
can deploy more toward earning, which flows back through the basket's average to our depositors, who
then have more reason to lock for longer.

**Entries are informed rather than guessed.** A dashboard reads the current market state using a bank
of Kalman filters, which is the standard tool for estimating a quantity that drifts, tracking realised
volatility, the position's exposure to Bitcoin versus Ethereum, and how strongly prices are
mean-reverting right now. That feeds a classifier that labels the present regime as range-bound,
two-way volatile, or trending. It characterises the current state and makes no forecast, which is
stated plainly in the code so nobody mistakes it for a crystal ball.

**The instrument this produces is the deliverable.** The maturity buckets mean a depositor pays $1,850
and holds a claim with $2,000 of face maturing in twelve months, forward yield priced in at entry. A
claim bought at a discount that matures on a calendar, which nothing else in crypto issues, and which
Pendle needs two tokens and a re-parameterised decaying curve to approximate.

Be precise about what it is not. A bill of exchange pays an **unconditional fixed sum**, and QUI's
redemption is capped at par and can fall below it, so it is a defined-maturity fund share rather than a
bill. That distinction matters beyond pedantry: the floating downside is what keeps QUI outside the
payment-stablecoin definition in our own securities analysis, so describing it as a fixed-sum
obligation would undercut the argument it depends on.

The instrument is worthless to someone who needs cash today and valuable to a counterparty who only
needs the money on a date they already know. **US residential security deposits alone are around forty
billion dollars sitting idle**, and an industry already sells alternatives that landlords accept, so
nothing changes at the point of sale. Their weakness is that the renter's fee never returns: Jetty
takes 17.5% of the deposit amount and the tenant owns nothing afterwards.

**Partial collateral, not full.** A renter who could post $1,850 could post the $2,000 deposit outright,
so a fully collateralised bond serves a customer who does not need it. What works is posting a smaller
maturing claim so the surety writes the bond at a premium well under 17.5%, partly secured and partly
underwritten. And the buyer is a surety that **declines** thin-file applicants today, because collateral
lets them approve a segment they currently reject. Removing risk from a surety who already approves
someone removes their margin, since a surety bond is a credit product with a right of indemnity and the
premium is payment for pricing that risk.

The same shape covers escrow against a set closing, bid bonds, and utility deposits returned after a
year of payment history, all of which have genuinely certain release dates. Security deposits are the
weakest of the group, because early termination breaks the date match.

Two things decide whether any of it exists, and both are counsel questions: whether a surety can hold
the claim under state admitted-asset rules or needs it in a third-party trust, and what haircut the
capped-at-par redemption requires. A third is distribution, since Rhino and Jetty sell to property
managers rather than renters, so a surety partnership still leaves that gate shut.
`docs/informational/CREDIT-STRATEGY-FINDINGS.md` carries the corrections and the full open list.

**And the largest household asset is the direction after that.** Our second repository handles
property, and we distribute rather than lend. The mortgage chain splits five ways, and four of them need a
licence: origination, underwriting, servicing, registering the lien. The fifth is the capital, which
is the one we have. So a licensed originator finds the borrower, values the property, sets the terms
and creates the lien, and the reserve funds the loan and holds the paper. Distributing rather than
lending also moves the problems cryptography cannot solve, valuation above all, onto a party already
paid and already liable for solving them. Refinancing is the entry, since the collateral and the
payment history exist already and the borrower is there for the rate.

The point of it is duration. Every asset in the reserve today is overnight and crypto-native, so it
reprices daily and goes quiet in the same week everything else does, while the liabilities are dated
out twelve months. That is an insurer's book funded with money-market assets, and a mortgage is what
matches it. The term premium is the payment for supplying exactly what the book is short of, and it
is the only line here uncorrelated with the rest.

The privacy layer does something narrower than people assume, and none of it hides anything from the
lender, who has to know his borrower. It is about the asset reaching investors without the file
following it. An ordinary securitisation ships loan-level data to investors in enough detail that
re-identification is routine. In ours the originator keeps the dossier, and what reaches the reserve
is a proof of genuine title, first position, and ratio within limits. The same mechanism keeps a
household's position off a public ledger, and lets anyone confirm a parcel is not already pledged
without a shared database of who owns what.

**Who forecloses, since the reserve is now the party owed.** The originator does, and not because it
still owns the debt. Servicing is a right separate from ownership, and it is how every whole-loan sale
already works: Fannie and Freddie own trillions in notes and have never foreclosed on anything, while
the servicer does it in the owner's name under a servicing agreement. Three roles, deliberately
separated.

The **economic owner** is the reserve, taking the cash flows and bearing the credit loss. The **record
lienholder** is a named legal person, because a registry records a charge in favour of someone who
exists and a smart contract is not a person: either the originator holds the lien as nominee for the
noteholder, which is precisely MERS's function in the US, or an SPV is the record holder and the
reserve holds a beneficial interest. The **servicer** collects and, on default, enforces, which is how
the originator keeps earning after selling the paper.

Refinancing makes this cleaner rather than harder. A refi discharges the old lien and records a new
one in first position, which is a fresh notarised act, so the correct beneficiary is named at
origination. Chain of title breaks down in *assignment*, not in origination, and the entire post-2008
foreclosure mess (robo-signing, "show me the note," Ibanez in Massachusetts) was securitisation trusts
trying to enforce liens they could not prove had been properly assigned to them.

The privacy design is consistent with this. On default the reserve cannot identify who to sue, having
never received the file, and it does not need to: the servicer holds the dossier and the standing.
What the contract does is hold the beneficial interest, receive payments, and mark a loan delinquent
against a schedule it already knows, which is the event that instructs the servicer. Enforcement
happens in a courthouse.

**What this gives up, stated rather than buried.** The no-underwriter design had mechanical
liquidation and nobody able to refuse. This one has a human enforcement path with human failure modes,
and the sharpest is servicer risk: a servicer who is captured, insolvent or simply unwilling stalls
recovery on paper we cannot enforce ourselves. That risk is priced into every RMBS deal, and the two
standard mitigations both belong in the agreement, a backup servicer designated in advance and the
irrevocable power of attorney (*Vekālat-nāmeh-ye Belā-'Azl*) signed at the start, which lets a
substitute act without the borrower's cooperation.

More important than the foreclosure mechanics: the reserve should mostly not be holding defaulted
loans at all. Whole-loan purchase agreements carry reps and warranties with a repurchase obligation,
so a loan that defaults early, or where a representation about title or valuation proves false, goes
back to the originator at par. That keeps their skin in the game on exactly the inputs cryptography
cannot verify, and it means most bad loans leave the reserve before anyone forecloses anything.

**The originator keeps a retention slice, and this is structural rather than cosmetic.** In May 2026 a
California court granted summary judgment for OppFi against the state regulator, holding that at
origination the entity which funds, controls underwriting and bears risk is the true lender. All three
elements. A bank acting as a riskless conduit is therefore not the lender, and the licensing obligation
lands back on whoever funds and bears the risk, which would be us. EU securitisation rules already
impose a five percent retention obligation on originators for the same reason, so a retained tranche
satisfies both at once. A riskless pass-through is the exact fact pattern these tests were written to
catch.

**And the sequence matters more than the destination.** Near-term duration comes from buying rated
paper, which is securities investing and requires no lending licence in any jurisdiction. Whole-loan
purchase is the step after, gated on counsel rather than on engineering, because in several US states
even purchasing consumer paper requires a licence and the purchaser inherits assignee liability.
Origination is a multi-year regulated business that buys nothing a partnership does not already provide
at the volumes in question. `docs/informational/CREDIT-STRATEGY-FINDINGS.md` is the research record:
what was checked, what was wrong, and seven open questions, the sharpest being whether CRD VI's
non-bank carve-out survives its ban on third-country lending into the EU from January 2027.

### Why this is worth funding rather than just building for ourselves

The thing we needed was a family-office capability: consolidated view, real diversification, credit
against illiquid assets, professional supervision. Families with a hundred million dollars have that.
Families with a normal amount of money have a spreadsheet and a wealth manager who cannot see half
of it.

Solving it for one family solved two structural problems for everyone else. Bitcoin locked in
Lightning stops being dead capital, which moves the supply curve for the whole network. And
bootstrapping a two-sided trading position no longer requires anybody to sell half their holdings.

---

## How did you learn about the problem?

Most recently, by becoming responsible for someone else's eighteen-year time horizon. Sitting down
with our wealth manager to plan a child's account made the gap obvious within an hour. The dollar side
of a family balance sheet has a century of instruments built for it, and the crypto side has spot
custody and a shrug. Everything in this application came out of trying to give that conversation
something concrete to point at.

Before that, I learned it the expensive way. Three times long on NEAR between 15 and 23, roughly
$350,000 of collateral carrying 50,000 units, liquidated near 7. The equity went to zero. Nothing
about the trade was sophisticated, and the lesson had nothing to do with NEAR. A leverage ratio that
stays fixed as price falls pays for itself on the way down, over and over. That is exactly why our
overlay sheds debt to zero below your entry price rather than holding a constant multiple, and why we
wrote no liquidation machinery of our own.

The protocol economics came from work. In 2019 I built Bancor's frontend incentivisation governance,
an affiliate-fee system that turned out to be the first working practice of what Uniswap and Liquity
later called sufficient decentralisation. My mentor Eyal raised the basket-of-stablecoins idea before
mStable was announced, and it sat unbuilt until Liquity's issue #6 gave it a setting. At Manifold
Finance I learned what extractive trading does to a passive quote, which is the direct reason our pool
prices off a time-weighted average cross-checked against an independent feed, and never publishes a
stale price for anyone to trade against.

The Bitcoin half came from a failure. lbtc.io shut down in 2019. The iOS app planned then was called
Ibiza, which is where I met Craig Sellars and Brock Pierce at the start of pre-seed. What killed it was
custodial wrapping: the model where you hand your Bitcoin to a company, they give you a receipt token,
and the whole thing rests on that company staying solvent and honest. I have been building the version
without a custodian ever since, and the current design is the first one where the depositor genuinely
never gives up their key.

---

## Who has this problem, and how do they deal with it today?

**Families building wealth alongside an advisor.** They hold some crypto and considerably more in
dollars and equities, and the two halves live in different worlds. The advisor is fluent in one and
treats the other as an unmanaged line item, because nothing exists that gives them a position they can
supervise, price, or report. What these families do today is hold spot and hope, buy an ETF and pay
for the wrapper while giving up any yield, or hand a percentage to a fund running a strategy they
cannot inspect. The number of households in this position is the entire premise of the wealth
management industry's current crypto anxiety.

**Fund managers with a mandate to resist depegs.** Anyone running a treasury or a fund has risk
mandates, and holding stablecoins concentrated in one issuer breaks most of them. They diversify by
hand across half a dozen names, rebalancing manually, with no single instrument that gives them the
whole spread. Cork Finance built a product aimed exactly at this group, selling insurance against a
stablecoin breaking, and we'll explain in the competition section why that cannot work.

**Holders who want yield without selling.** They stake and take the base rate, or they provide
liquidity and eat the losses described above, or they use a leveraged product like YieldBasis that
converts the holding loss into a borrowing cost and a liquidation risk. Retail gets pointed at
dollar-cost-averaging apps or at copying Michael Saylor, and neither of those is a strategy.

**Lightning liquidity providers.** Small operators lock coins into channels and earn routing fees that
don't cover the opportunity cost. Most accept it as a public service, or they stop running a node. The
network's chronic shortage of inbound liquidity is the aggregate of thousands of people making that
calculation.

**Bitcoin holders who want anything at all from DeFi.** They wrap. BitGo's WBTC and Coinbase's cbBTC
are honest about what they are, a receipt from a regulated counterparty, and they're genuinely useful
if your mandate requires a regulated counterparty. Lombard routes through Babylon, which pays a
Bitcoin holder around two percent to underwrite the security of other networks whose failures they
then inherit. Every one of these asks a Bitcoin holder to trust something new. Our design asks them to
trust what they already trust, which is Bitcoin's own scripting rules and their own key, and connects
that to everything else.

---

## What have you built so far?

Everything described here is written and tested against forked mainnet state, and runs. None of it has
been audited and none of it holds real value yet.

**The reserve and the trading position.** A Uniswap v4 position whose token side is virtual, meaning
the depositor's actual Ethereum stays in its lending venue earning yield while the position quotes
prices and collects trading fees. You get paid twice on the same coins. The quoted range is a tight
band around the oracle price and re-centres when price leaves it (`SwapLib.sol:838`), rather than
being reshaped on every single trade, which matters for reasons we cover under Bunni below.

**Single-sided deposits funded by a dated bond ladder.** The mechanism described in the first answer.
Maturity buckets, a hard 600,000 seed cap, a twelve-month bootstrap window after which the projection
horizon collapses to a month.

**Impermanent-loss protection, on the up side only.** The buffer mechanism described above. Target
borrowing is computed directly from how far price has moved since entry and returns zero at or below
that entry (`LevMath.sol:109-125`). The keeper sizes leverage to how concave the position has actually
become from real trading flow, so in a quiet market it borrows nothing.

**No liquidation engine, deliberately.** Competing designs need one because they hold a fixed leverage
ratio that can breach. Ours sheds debt as price falls, so it de-risks in the same direction the danger
comes from. The keeper de-levers a full safety margin below the outside venue's own liquidation line,
which makes that venue's engine a backstop that never fires, and if it ever did fire it would hit one
depositor in isolation.

**Native Bitcoin with no custodian.** Each depositor's coins sit in a joint account on Bitcoin
requiring two signatures, one of which is theirs. Our contracts verify that the account was funded, and
later that it was closed, using the same lightweight proof a phone wallet uses to check that a payment
happened. That has been validated end to end against a live Bitcoin test node, so the bridge runs
rather than existing as a diagram.

**And the depositor runs nothing.** This is the part that makes it usable by a family rather than by an
engineer. Historically, providing Lightning liquidity meant running a node, keeping it online, and
running a watchtower to catch your counterparty cheating. Our depositor signs one message from their
normal wallet, cold, which someone else pays the gas to submit, and then sends Bitcoin from wherever
they hold it. There is no software for them to host and nothing to keep online. The message names who
may operate their channel and, critically, the
one Bitcoin address every payout must go to, and that address is locked from that moment on, so even a
completely compromised operator can only move the depositor's money to the depositor.

**A dead man's switch, so the exit doesn't depend on us.** The operator continuously pre-signs a
transaction that pays the depositor their full balance, time-locked to a near-future date, and
publishes the raw bytes on-chain. While we're alive we keep pushing that date forward, so it can never
be broadcast prematurely. If we stop, the date arrives and anybody at all can broadcast the already
published transaction, holding no key and asking nobody. Bitcoin's own timelock does the enforcement
(`BTCChannels.sol:256-271`).

**Hardware attestation instead of a promise.** Which machines may operate as our Bitcoin infrastructure
is gated by a cryptographic proof, verified on-chain by an audited third-party verifier, that the
machine is running an exact published build inside a secure enclave. The signing key is born inside
that enclave and sealed to that specific build, so modified code cannot reach it. A multisig governs
only the list of approved builds and moves no money. Every other contract that touches money has had
its ownership renounced.

**Many channels rather than one pool.** We could have held everyone's Bitcoin in one big account,
which would save us some bookkeeping. It would also mean somebody custodies everyone's coins, either a
trusted party or a committee, and it caps total liquidity at one account's size. We pay a small
accounting cost for per-depositor segregation and get self-custody, no single catastrophic target, and
horizontal scaling where every new depositor brings their own capacity.

**The off-chain half.** A Rust codebase running the Lightning node, the mirror that reflects every
Bitcoin movement onto the contracts, the swap rails in both directions, and the keeper that manages
leveraged positions.

**Privacy and identity.** A separate repository merging two open-source systems onto one proving
system: Privacy Pools, which lets you deposit and later withdraw without the two being linkable, and
Rarime, which proves a passport is genuine while revealing nothing about its holder. Each had a gap.
The first screens money using guilt-by-association heuristics; the second proves personhood but never
touches money. Merged, a withdrawal proves the honest thing, that a real and unsanctioned person is
withdrawing. 149 tests green. The passport stack we fork was used inside Iran by civil-society
organisations to run anonymous protest votes on the 2024 election, so the hard part has field
evidence behind it.

**And a treasury adapter with a subtle property.** Shielded deposits sitting idle earn nothing, which
means privacy costs the user their return. Ours earn. The non-obvious part is that if the privacy pool
moved money into the yield venue synchronously with each user's deposit, the yield venue's public
event log would reconstruct exactly the link the cryptography exists to hide. So the funding is
batched, rate-limited, and deliberately unsynchronised with any individual's action.

---

## How do you know people need this?

Capa.fi pledged future commitment in the form of reserve deposits, and their chief executive Juandi
was our grants liaison on behalf of Polygon. EtherFi steered our work toward getting the most out of
their liquidity pool. Mach and Khalani have both committed to list our basket as a venue for their
order flow, which matters more than it sounds: it means trading volume arrives without us building a
consumer app to attract it.

Two organisations put non-dilutive money in during 2025, the Uniswap Foundation and Polygon Labs, on
top of friends and family. Two people who did not have to agreed to hold keys in the deployment
multisig: Paul, who I worked with at Gauntlet after meeting through Halborn in 2022, and Artem, who
wrote the research paper on using Bitcoin proofs in DeFi with Distributed Labs and is now at
Blockstream. People who audit systems for a living do not attach their names to designs they think are
unsound.

What we do not have is live deposits. The honest demand evidence is structural. Lightning's liquidity
shortage has one cause, and it's the cause we removed. Wealth managers currently have no supervisable
crypto product to offer, and that is not a preference, it's an absence.

---

## How will you make money?

Quid Labs is wholly owned by the QuidMint Foundation, so the real question is how the protocol funds
its own maintenance without depending on anyone's continued goodwill. Five things earn.

The largest is a pricing mechanism, and it's the direct answer to the picked-off-by-arbitrageurs
problem from the first question. We refuse to hold a stale price, so there's no free correction for
anyone to take. But a pool still needs its shelves restocked. So we charge for scarcity instead: when
the pool is running low on Bitcoin, anyone buying Bitcoin from it pays above the market price, and
that premium stays in the reserve as backing for depositors (`Core.sol:259-285`). The premium steepens
when volatility rises, and it's capped at the genuine cost a professional market maker bears while
their capital is tied up waiting for Bitcoin confirmations. We are buying the same restocking service
Uniswap gets, from willing counterparties at a stated price, rather than extracting it from the people
who supplied the liquidity.

The trading position collects ordinary fees. Redemptions pay an outflow fee between three and thirty
basis points, shaped so that pulling out the collateral generating the most yield costs more than
shedding a name that has already broken, which means the cheap exit is the one that leaves the reserve
healthier. Our router takes a spread, and because it drops directly into Liquity's leverage tooling as
a compatible exchange, we earn that spread on both legs of somebody else's trade inside their own
product. Underneath all of it the reserve is lent across Morpho, Aave, sDAI and Liquity's stability
pool, which earns whether or not a single person trades.

That last line is what makes this durable. There is no floor a quiet month falls below, which is why
we do not plan to depend on repeated grants.

---

## How will you find more customers?

**Through advisors, which is the channel I care most about.** An independent wealth manager advising a
few dozen families has no supervisable crypto product and no appetite for one they can't see inside.
Give that person a dashboard showing exposure, current market regime, and realised yield across every
client at once, on a position where we custody nothing and they can verify the holdings on a public
ledger, and they carry us into every household they advise. One advisor is worth more than a hundred
individual signups, and the conversation with them is about supervision rather than about crypto.

**Through other protocols, without needing a deal.** Every integration surface we have is
permissionless. Our deposit and mint functions are plain public functions with no allowlist and no
gate, so a protocol wanting to route idle funds into the reserve declares a local interface and calls
it. Our own privacy stack integrates with us exactly that way, holding our addresses as fixed
constructor arguments and importing none of our source code, which means an integrator can ship
against us without ever having a conversation.

**Through order flow rather than users.** Mach and Khalani route to us. Liquity's leverage tool calls
our router from inside its own transaction. Our identity wallet consumes the reserve as a dependency.
In each case somebody else's product brings the volume.

**Through Lightning operators, where the pitch is that they stop working.** Signing one message and
sending Bitcoin from an exchange or a wallet is the entire onboarding. The exit is enforced by
Bitcoin's timelock rather than by our willingness to serve them. That removes the barrier that has
kept small operators out of channel liquidity provision entirely.

**And through the stablecoin issuers themselves, whose interests we happen to serve.** A twelve-month
lock with us reduces redemption pressure on every constituent at once. That is a benefit an issuer
cannot manufacture alone and has every reason to promote.

---

## What is the biggest mistake that you've made so far?

I stayed on a dead product because the code was beautiful. The old repository is public at
github.com/quidmints/quid, so the scale of it can be checked.

Most of that repository is an engine for trading synthetic versions of real-world assets: roughly
9,750 lines of Rust wired to a price oracle across 935 US stock tickers, 101 currency pairs, separate
venues for UK, German, French, Dutch and Luxembourg equities, and then metals, commodities, interest
rates and staking derivatives, each asset class carrying its own leverage ceiling and minimum fee. The
internal name for it was the Ostium killer. When we started, neither Robinhood's chain nor Kraken's
xStocks existed. Both arrived while we were building, and both are a better answer for the person we
were building it for, because they hold the licences and the distribution, and a two-person team does
not out-execute that.

Misjudging a market is forgivable. What I actually did wrong was keep going for months after the
market had answered, because the implementation was elegant and my hands were in it, and I let that
stand in for a reason. Nobody was going to trade a synthetic Deutsche Telekom on our venue once Kraken
would sell them the real tokenised one.

The second mistake sits in the same repository, and it's the more interesting failure because it was
wrong on the merits rather than on timing. About 1,900 lines of Solidity implement a jury and
arbitration system for a prediction market on stablecoins breaking their peg, sitting on a Go service
handling evidence verification and deterministic resolution. The idea was insurance: people who think
a stablecoin will break take one side, people who think it won't take the other, and the payout makes
the insured whole. The chicken-and-egg problem with such a market is that nobody wants to be the
insurer, so we solved that by standing the no-break side up from the reserve's own capital.

Which is precisely why it cannot work. The reserve's dollars are the dollars that redeem our
depositors at maturity. When a break resolves and the payout comes out of them, those dollars leave
and are no longer available to redeem anyone. The same dollar cannot both back a redemption and settle
a claim. And it fires during a crisis, when the reserve is already impaired, so it drains the backing
at exactly the moment the backing matters most. The thing it was meant to provide already existed for
free: when a stablecoin in our basket breaks, everyone holding a claim takes the same proportional
reduction, which is the fairest possible outcome. A market payout makes the gamblers whole while
everyone else absorbs it.

Both are gone. Depeg protection in the current design is diversification across eleven names and
nothing else.

There is a smaller repeat of the pattern in the current repository, and it's worth admitting because
it shows the failure mode is mine rather than situational. We shipped a mechanism that bought back a
departing depositor's shortfall out of the reserve's spare capital, so the trading loss landed on the
shared cushion rather than on the person leaving. That was the design thesis for about eight months
and carried a full economic study behind it. Spare capital is what we owe back to everyone, so
spending it to make one person whole pays whoever moves first at every other claimholder's expense,
and it fires hardest when the cushion is thinnest. Removing it is why a depositor now bears their own
trading loss through the share price, with the protection moved onto their own isolated position.

---

## Tell us something about your company that's not going well.

I am in Ukraine, and the war is the largest operational risk this company carries.

The cost of it is mundane and relentless. Work stops when the power does and resumes when it returns.
Anything needing a physical presence, a bank, or a notarised signature takes weeks here that it takes
hours elsewhere, and getting out to a conference or a diligence meeting is a logistics problem before
it is a calendar problem. Hiring is close to impossible, because the people I would want are already
abroad or already serving, and I cannot offer anyone still here the stability a job is supposed to
come with. There is no redundancy in any of it. One person, in one place, holding the work.

Ingrid splits her time with a worker-owned produce cooperative in Portland, so the second founder is
part-time by agreement rather than by drift.

The product-side version is plainer. No audit, nothing on mainnet, so live deposits are zero. Native
Bitcoin leverage is a materially harder problem than the Ethereum side, because Bitcoin has no smart
contracts and every clean path runs back through a custodial wrapper, which defeats the model the
whole system exists for. I would rather say out loud that it probably isn't worth doing than pretend
the two sides are symmetric.

The one thing I will claim for the architecture is that it was built by someone who assumed he might
not be reachable. Nothing runs on a server we own. The contracts cannot be upgraded and have no
administrator, a depositor's reclaim needs nothing from us, and a Bitcoin depositor's exit is a
pre-signed transaction whose bytes are already public, which Bitcoin's own timelock releases the
moment our heartbeat stops. Being here is also why the notary-registry work in the identity
repository is built against Ukraine's Ministry of Justice open data rather than against a
hypothetical.

---

## How will the next LLM model release affect your business?

This codebase exists because of one. Ingrid's Claude subscription is what turned two years of
prototypes into a working system, and the volume of Solidity, Rust, Noir and Go here is not something
two people write by hand in a country with rolling blackouts.

A better model compresses the work we are worst at, which is reconciling documentation against code,
preparing for audit, and running adversarial passes over our own money paths. The risk runs in the
same direction. A cheaper model means someone can read our public repositories and rebuild the design,
so whatever defensibility we have has to come from what is deployed and integrated rather than from
the source being clever. It also means anyone probing unaudited contracts for exploits improves on the
same schedule, which is an argument for finishing the audit before the money arrives.

There is a third effect that cuts in our favour and gets underrated. Adversarial review used to be
something you bought from a firm at a price that gated small teams out entirely. It is becoming
something you run continuously. For two people without an audit budget, that changes more than it
changes for a team with one.

---

## How do you use AI in your workflows today?

Concretely, and mostly as an adversary rather than as an author.

**We test by deleting the safeguard.** Rather than trusting a green test result, we remove the
protection the test is supposed to be checking and confirm the test then fails. That caught two tests
in the identity stack that had quietly stopped checking anything at all, and it is how we found a
proof that was binding to an unconstrained value, stale records that let a revoked credential stay
valid, and a bug that let one property be titled twice.

**We verify every cryptographic component against the real thing it will face.** Each proof gadget is
checked against the exact on-chain function it will be compared to in production, across 46 randomised
tree shapes covering every structural edge case. Compiling the gadgets rather than merely writing them
found two real bugs immediately.

**We simulate in order to kill our own ideas.** One simulation measured our trading losses on real
five-minute data through the March 2020 crash and came back nearly three times worse than our own
published study claimed, so we now treat every such figure we publish as a conservative floor rather
than a measurement. Another showed that a fixed two-times leveraged position would have been
liquidated in five to nineteen percent of all historical Ethereum windows, which is the direct reason
leverage lives on the depositor's own outside position and never on our balance sheet. A third
produced a finding we then had to retract, because the simulation was charging a bookkeeping operation
as though it were a real trade.

**We run wide adversarial research passes.** The compliance work ran 105 sub-agents across 676 tool
calls. It ruled out the vendor we had assumed would be our accountable partner, and it caught us
citing a regulation for something that regulation does not say. Both would have surfaced in a lawyer's
office at considerably higher cost.

**And we reconcile documentation against code on a schedule.** Design notes go stale faster than code
does, and a stale paragraph is a trap for whoever reviews us next.

---

## Who are your competitors or alternatives, and why will you win?

**YieldBasis** solves the same problem we do and pays too much for it. It borrows a stablecoin against
your Bitcoin and holds a constant two-times position, which mathematically straightens the losing
curve. That works. The costs are that half your trading fees go to maintaining the ratio, the borrowing
drags continuously, a break in the stablecoin they borrow cascades into every depositor at once, and
the fixed ratio forces them to re-lever on every decline, which means selling low and buying back
higher over and over. Our borrowing sits on an outside market in a position isolated to one depositor,
so we never inherit a socialised shortfall. It is sized to the loss actually incurred rather than
pinned at a constant, and it unwinds to nothing below your entry. We are never holding two-times
leverage into a crash.

**Lombard and Babylon** pay a Bitcoin holder roughly two percent to underwrite the security of other
networks whose risks they then carry. Our Bitcoin depositors keep their own key in a joint account
that neither we nor anyone else can spend unilaterally, earn trading fees, and their coins keep doing
their Lightning job while they do it.

**Cork Finance** priced insurance on a risk that has no price. Actuarial pricing needs three things
and a currency peg breaks all of them. The base rate is unobservable, because the event has almost no
history and each stablecoin is structurally unique. The hazard is reflexive, because the rising price
of the insurance is itself a signal that triggers the run. And the risk is perfectly correlated in the
only state that pays out, so the underwriter collects small premiums in calm markets and is wiped out
when several break together, usually while holding collateral in the same asset class being insured.
There is also no way to hedge through the gap, since the price moves from par to eighty cents in
minutes. Their model produced a number. A number that two speculative crowds momentarily agree on is
not a price. We bound the risk by breadth instead, which is unglamorous and works.

**Bunni** is the cautionary tale and it's worth understanding precisely. They built a system that
reshaped the pool's liquidity after every single trade to maintain the right token ratio. By doing
that correction themselves, they eliminated the price discrepancy that arbitrageurs exist to close.
No discrepancy means no arbitrage means no arbitrage fees, and arbitrage is a large share of the
volume that normally compensates liquidity providers. So the pool paid the rebalancing cost
continuously while forgoing the revenue that pays for it, and the hack that killed them lived in that
same per-trade accounting step. We re-centre only when price leaves a narrow band, and we let outside
arbitrageurs pay us fees to do the rebalancing rather than doing it ourselves for free.

**Pendle** is the closest thing to our bond and carries more machinery. They split a yield-bearing
asset into two tokens, one for the principal and one for the yield, then price the principal on a
time-decaying curve that has to be re-parameterised as maturity approaches, with liquidity split
across every expiry. Ours doesn't split, because the yield accrues to the reserve and shows up in the
scheduled redemption. There is no secondary curve to maintain and nobody to sell the yield strip to,
so the bond funds itself.

**mStable** is the only genuine basket competitor. It routes to Pendle rather than deploying the
stablecoins into lending, and it earns nothing from trading them against each other or against
Bitcoin and Ethereum. It is a good interface on somebody else's strategy.

**WBTC and cbBTC** are receipts from regulated custodians, which is exactly right for a fund whose
mandate requires a regulated counterparty. They are honest about what they are, and they are the
backwards answer to what bridging Bitcoin and Ethereum should mean.

What we do differently across all of those is subtract. Rather than trying to price a risk nobody can
price, we bound it by holding eleven things instead of one. A single band around the current price
does the work that a continuously maintained distribution does elsewhere, and it only moves when price
leaves it. Redemption runs on a calendar that was set when the claim was written. Our debt sits on
somebody else's market, isolated per depositor, on a venue that already operates its own liquidation
machinery and has been doing so for years. Fewer moving parts is the entire safety argument, and it is
also why two people can hold this system in their heads well enough to audit it honestly.

I'd add one thing about how we relate to these. Bancor sued Uniswap last year. We are building to be a
venue inside other people's products rather than a destination that has to beat them, which is why
every integration surface is permissionless and why our router already sits inside Liquity's tooling.
Ethereum works because the pieces compose. That is worth more to us than winning an argument.

---

## What's something you believe that a smart, informed person would disagree with?

**Losses below your entry price should not be hedged, and hedging them destroys value.**

Everyone building this kind of protection builds it symmetric, and any derivatives desk would tell you
that a hedge working in one direction is not a hedge. We built the symmetric version. Here is what
happens with it.

Below your entry, the pool has bought too much of the falling asset. A symmetric hedge corrects that
by selling the excess into the decline, which restores your target exposure and, in doing so, converts
a paper loss into a realised one. If price then recovers, you have permanently forfeited the recovery,
because you sold at the bottom to a hedge that was doing its job. Over a full round trip down and back
up, the person who did nothing beats the person who hedged, by exactly the amount that got realised,
with identical fees along the way. So we deleted the down-side leg on 2026-07-24, and the borrowing
target now returns zero at or below entry.

The same logic kills the soft-liquidation machinery that Curve's stablecoin and its descendants are
built on. Those engines sell your collateral continuously as price falls so that you never face a hard
liquidation. That caps further loss by crystallising the drawdown, and across a decline and recovery
you sold low and re-bought high. Our position sheds debt as price falls, which means it de-risks in
the direction the danger comes from, and we never wrote an engine.

**The related belief, which is more uncomfortable: we cannot win the fee war and should not try.**

The instinct in this industry is that the cheapest venue wins the volume. Cutting your fee does not
buy clean volume. It makes you the venue that professional arbitrageurs correct first and hardest when
the outside market moves, and that flow is precisely the loss your liquidity providers bear. The fees
that flow pays roughly equal the losses it inflicts, so racing the fee down grows both sides of the
equation and never the difference. The addressable number was never headline volume. It is the
uninformed, fee-paying volume, which is a fraction of the total and shrinking as intent solvers match
the easy flow away from pools entirely.

So our economics rest on things that do not require winning flow we were never able to select. Yield
accrues on the entire deposit rather than on the slice that happens to be quoting. The exposure that
can lose is capped by design. The scarcity premium is charged openly and kept for depositors instead
of being surrendered to whoever is fastest. Anyone benchmarking us against a competitor's headline
volume will conclude we are losing on the metric that stopped meaning anything once solvers started
matching the easy flow away from pools.
