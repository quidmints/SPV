# Alliance application

Claims verified against `quidmints/SPV` and `quidmints/ibiza`. Full version with mechanism detail and
file references: `ALLIANCE-APPLICATION-LONG.md`. The sibling application in `ibiza` describes the
no-underwriter configuration of the same stack, for jurisdictions without functioning licensed
origination; this one describes the distributor configuration.

---

## What is the problem you're solving?

We had a baby. The account the federal government seeds at birth is locked into a US stock index until
they turn eighteen. Good to have, and a single bet on one country's equity market that nobody in the
family votes on for eighteen years. The rest of a child's nest egg should not correlate to that,
should not sit with a custodian, and should be something my wife and I can look at alongside our
wealth manager rather than a line item he politely ignores.

Every alternative was bad in a fixable way. Bitcoin and Ethereum held outright earn nothing. Put them
in a trading pool and it sells whatever is rising and buys whatever is falling, so a rally leaves you
holding less Bitcoin and a decline leaves you holding more of it at worse prices. That gap is
impermanent loss, and the fees roughly cover it and no more. The pool keeps its shelves stocked by
letting arbitrageurs trade against its stale price, restocking itself out of the people who supplied
it. Put the dollar half in one stablecoin and you own an issuer bet nobody can price.

So: deposit one asset, keep it, leave in it. We fund the dollar side of your position by issuing a
dated claim against yield we have not earned yet, then earn that yield from the liquidity the claim
created. Every credit system in history runs that drivetrain, from a village bank to a central bank,
creating present claims against future value and using the liquidity to produce the value. Ours
shortens the loop to nothing, because the claim funds the exact position that generates the yield
redeeming it. And because what gets subordinated is a date rather than a person, there is no waterfall
of senior and junior claimants to carry forever.

The loss the pool creates on the way up is cancelled by an optional overlay that borrows against your
own collateral on an outside market and gives the pool extra Ethereum to sell instead of your
principal. It unwinds to zero debt below your entry price, so we never carry leverage into a crash.
Dollar yield comes from eleven stablecoins, since holding the basket is the only insurance against a
break that anyone can actually sell, and one twelve-month lock with us relieves redemption pressure on
all eleven at once, which no single issuer can offer. The dated liability curve is the other half of
that: we know what we owe in March and in April and out to the end of the year, so this is an
insurer's duration-matched book expressed as a token rather than a stablecoin with an unpredictable
redemption queue. A depositor gets to know the dollar side is solvent regardless of what the volatile
side is doing, which is the property that makes the whole thing supervisable. Entries are informed rather than guessed: a bank of Kalman filters
estimates present volatility, factor exposure and mean reversion, feeding a classifier that labels the
market as range-bound, two-way volatile, or trending. It characterises the current state and forecasts
nothing, which is the honest version of what a strategy layer can do.

Then the house, which is why the second repository is not a side project. The mortgage chain splits
five ways and four of them need a licence: origination, underwriting, servicing, registering the lien.
The fifth is the capital, and that is the one we have. So a licensed originator finds the borrower,
values the property, sets the terms and creates the lien, and the reserve funds the loan and holds the
paper. Distributing rather than lending also moves the problems cryptography cannot solve, valuation
above all, onto a party already paid and already liable for solving them. Refinancing is the entry,
since the collateral and the payment history exist already and the borrower is there for the rate.

The point of it is duration. Every asset in the reserve today is overnight and crypto-native, so it
reprices daily and goes quiet in the same week everything else does, while the liabilities are dated
out twelve months. That is an insurer's book funded with money-market assets. A mortgage is what
matches it, and the term premium is the payment for supplying exactly what the book is short of. It
is also the only line here uncorrelated with the rest.

The privacy layer does something narrower than people assume, and none of it hides anything from the
lender, who has to know his borrower. It is about the asset reaching investors without the file
following it. An ordinary securitisation ships loan-level data to investors in enough detail that
re-identification is routine. In ours the originator keeps the dossier, and what reaches the reserve
is a proof of genuine title, first position, and ratio within limits. The same mechanism keeps a
household's position off a public ledger, and lets anyone confirm a parcel is not already pledged
without a shared database of who owns what.

Default is where a structure like this usually falls apart, so the three roles are held separately.
The reserve is the economic owner and takes the loss. A named legal person is the record lienholder,
since a registry records a charge in favour of someone who exists and a contract is not a person. The
originator is retained as servicer and forecloses as our agent, which is how every whole-loan sale
already works. Refinancing helps here: discharging the old lien and recording a new one names the
right beneficiary at origination, and faulty assignment afterwards is what the post-2008 foreclosure
litigation was actually about. The paper carries reps and warranties with a repurchase obligation, so
a loan that defaults early or was misrepresented on title or valuation goes back to the originator at
par before anybody forecloses anything. What we give up is mechanical enforcement, and the residual is
servicer risk, held down by a backup servicer named in advance and an irrevocable power of attorney
signed at the start.

---

## How did you learn about the problem?

By becoming responsible for someone else's eighteen-year horizon. An hour with our wealth manager
exposed it. The dollar side of a family balance sheet has a century of instruments, and the crypto
side has spot custody and a shrug.

Before that, expensively. Three times long on NEAR between 15 and 23, $350,000 of collateral carrying
50,000 units, liquidated near 7, equity to zero. A leverage ratio that stays fixed as price falls pays
for itself repeatedly, which is why ours sheds debt on the way down.

Earlier still from work: Bancor's frontend incentivisation governance in 2019, my mentor Eyal's basket
idea that sat unbuilt until Liquity's issue #6 gave it a setting, and Manifold Finance, where I
learned what extractive trading does to a passive quote. lbtc.io shut down in 2019 because it was
custodial, and I have been building the version without a custodian since.

---

## Who has this problem, and how do they deal with it today?

Families building wealth with an advisor who is fluent in half their balance sheet and treats the
other half as unmanaged, because nothing exists he can supervise or report on. Fund managers with a
depeg mandate, diversifying across six stablecoins by hand. Holders who stake for the base rate,
provide liquidity and eat the losses above, or use a leveraged product that swaps the holding loss for
liquidation risk. Lightning operators whose locked coins earn zero, which is why most quit and why the
network has been short of liquidity for a decade. And Bitcoin holders who want anything from DeFi, so
they wrap and trust a company's receipt, or route through Lombard for around two percent and inherit
other networks' risks.

---

## What have you built so far?

All of it runs against forked mainnet state. None is audited or holds value yet.

A Uniswap v4 position whose token side is virtual, so your Ethereum stays in its lending venue earning
yield while the position quotes and collects fees. You get paid twice on the same coins. The bond
ladder funding single-sided deposits, capped at 600,000, with a bootstrap window closing after twelve
months. The up-side loss protection, sized from how far price moved since entry, running on Morpho,
Euler, Aave or Liquity, one isolated position per depositor. We wrote no liquidation engine, because
ours sheds debt in the direction the danger comes from, and a test runs a leveraged position through a
real liquidation to prove a passive depositor is untouched.

On Bitcoin, each depositor's coins sit in a two-signature account with one key theirs, verified by our
contracts using the same lightweight proof a phone wallet uses, validated end to end against a live
test node. The depositor signs one cold message and then runs nothing at all. That message locks the
single address every payout must reach, so even a fully compromised operator can only send their money
to them. If we vanish, a pre-signed transaction whose bytes are already public becomes broadcastable
by anyone, released by Bitcoin's own timelock. Which machines may run our infrastructure is gated by
an on-chain proof they execute an exact published build inside a secure enclave.

The second repository merges two open-source systems onto one proving system, with a single device
seed deriving both the identity key and the spending keys. Privacy Pools breaks the link between a
deposit and the withdrawal spending it, screening money by chain-analysis guesswork. Rarime proves a
passport genuine while revealing nothing about its holder. Merged, a withdrawal proves the honest
thing, that a real and unsanctioned person is withdrawing, and the title ledger on top records a
pledge without publishing whose it is. Shielded deposits also earn, funded on a batched
schedule so the yield venue's public logs cannot rebuild the link the cryptography hides. That
passport stack ran anonymous protest votes inside Iran on the 2024 election.

One dashboard reads all of it, which is the piece a wealth manager needs and the piece nobody in this
industry builds.

---

## How do you know people need this?

Capa.fi pledged reserve deposits, and their chief executive was our grants liaison for Polygon.
EtherFi steered our work toward their liquidity pool. Mach and Khalani committed to list our basket as
a venue for their order flow, so volume arrives without a consumer app. The Uniswap Foundation and
Polygon Labs funded us non-dilutively in 2025. Paul from Gauntlet and Artem, who wrote the research on
Bitcoin proofs in DeFi and is now at Blockstream, agreed to hold keys in the deployment multisig
without having to.

We have no live deposits. The honest evidence is structural. Lightning's liquidity shortage has one
cause, and yield-bearing channel capital is the primitive nobody supplied, so every coin we attract
deepens routing for people who will never hear of us. Wealth managers have no supervisable crypto
product, which is an absence rather than a preference. And Thorchain's collapse stranded the one
constituency that had chosen non-custodial cross-chain Bitcoin on purpose, who now have to pick
between a custodial receipt and nothing.

---

## How will you make money?

Quid Labs is wholly owned by the QuidMint Foundation, so the question is how the protocol funds
itself.

The largest line answers the arbitrage problem above. We hold no stale price, so there is no free
correction to take. A pool still needs restocking, so we charge for scarcity openly: when the pool is
low on Bitcoin, buyers pay above market and that premium stays in the reserve for depositors. It
steepens with volatility, capped at what a market maker really pays to sit on capital awaiting
confirmations. We buy the service Uniswap gets free from arbitrageurs, at a stated price.

The position collects trading fees. Redemptions pay three to thirty basis points, shaped so the cheap
exit leaves the reserve healthier. Our router earns a spread and already sits inside Liquity's
leverage tooling, taking it on both legs of somebody else's trade. The reserve is lent across Morpho,
Aave, sDAI and Liquity, which earns whether or not anyone trades, so a quiet month has no floor to
fall through. Mortgage paper is the line that comes after, and the reason to want it is that it pays
a term premium for lengthening assets we currently hold overnight against liabilities dated a year
out.

---

## How will you find more customers?

Advisors first. An independent wealth manager with a few dozen families has nothing supervisable to
offer them. Give him one dashboard showing exposure, market regime and realised yield across every
client, on positions verifiable on a public ledger where we custody nothing, and he carries us into
every household he advises.

Then protocols, without a deal: our deposit and mint functions are public and ungated, so an
integrator declares a local interface and ships against us without ever having a conversation. Then
order flow rather than users, through Mach, Khalani and Liquity's tooling. Then Lightning operators,
where the pitch is that they stop working, since one signature is the whole onboarding and Bitcoin
enforces the exit rather than our goodwill. And the stablecoin issuers, who benefit from every
twelve-month lock we sell.

---

## What is the biggest mistake that you've made so far?

I stayed on a dead product because the code was beautiful. The old repository is public at
github.com/quidmints/quid.

Most of it trades synthetic real-world assets: 9,750 lines of Rust wired to a price oracle across 935
US stock tickers, 101 currency pairs, five European equity venues, metals, commodities and rates. We
called it the Ostium killer. Neither Robinhood's chain nor Kraken's xStocks existed when we started.
Both arrived while we were building, and both are a better answer for the same customer, because they
hold the licences and the distribution.

Misjudging a market is forgivable. What I did wrong was keep going for months after the market had
answered, because the implementation was elegant and my hands were in it, and I let that stand in for
a reason.

The second mistake sits in the same repository and was wrong on the merits. A jury system for a
prediction market on stablecoins breaking, with the no-break side funded from the reserve's own
capital. Those are the dollars that redeem depositors at maturity, so a payout removes them, and the
same dollar cannot both back a redemption and settle a claim. It also fires during a crisis, when the
reserve is already impaired. The protection it promised existed for free, since a break is absorbed
proportionally by everyone holding a claim. Depeg protection today is diversification and nothing
else.

---

## Tell us something about your company that's not going well.

I am in Ukraine, and the war is the largest operational risk this company carries.

The cost is mundane and relentless. Work stops when the power does. Anything needing a bank, a notary
or a physical presence takes weeks here that it takes hours elsewhere. Hiring is close to impossible,
because the people I would want are already abroad or already serving, and I cannot offer anyone still
here the stability a job is supposed to come with. There is no redundancy in any of it. One person, in
one place, holding the work. Ingrid splits her time with a produce cooperative in Portland, so the
second founder is part-time by agreement.

Plainer: no audit, nothing on mainnet, zero live deposits. Native Bitcoin leverage is harder than the
Ethereum side and every clean path runs back through a custodial wrapper, so I would rather say out
loud that it probably isn't worth doing.

What I will claim is that this was built by someone who assumed he might not be reachable. Nothing
runs on a server we own, the contracts cannot be upgraded and have no administrator, and a depositor's
exit needs nothing from us.

---

## How will the next LLM model release affect your business?

This codebase exists because of one. Ingrid's Claude subscription turned two years of prototypes into
a working system, and this volume of Solidity, Rust, Noir and Go is not something two people write by
hand in a country with rolling blackouts. Better models compress what we are worst at, which is audit
preparation and adversarial review of our own money paths. The same improvement lets someone read our
public repositories and rebuild the design, so defensibility has to come from what is deployed and
integrated, and anyone probing unaudited contracts improves on that schedule too. The underrated
effect is that continuous adversarial review used to be sold by firms at a price that excluded teams
our size.

---

## How do you use AI in your workflows today?

As an adversary more than an author.

We test by deleting the safeguard and confirming the test then fails, rather than trusting a green
result. That caught two identity tests which had silently stopped checking anything and a bug letting
one property be titled twice.

We simulate to kill our own ideas. Measuring our trading losses on real crash data came back nearly
three times worse than our own published study, so we treat those figures as conservative floors.
Another run showed a fixed two-times position liquidating in five to nineteen percent of historical
Ethereum windows, which is why leverage sits on the depositor's outside book rather than ours.

The compliance research ran 105 sub-agents across 676 tool calls, ruled out the vendor we had assumed
was our partner, and caught us citing a regulation for something it does not say.

---

## Who are your competitors, and why will you win?

**YieldBasis** solves the same problem and overpays. Half the trading fees maintain a fixed two-times
ratio, the borrowing drags, a break in the stablecoin they borrow cascades into every depositor, and
the fixed ratio forces re-levering on every decline, which is selling low and buying back higher on
repeat. Ours borrows on an outside market isolated per depositor, sizes to the loss actually incurred,
and unwinds below entry.

**Lombard and Babylon** pay a Bitcoin holder around two percent to underwrite the security of other
networks whose failures they then inherit. We integrate the most decentralised Bitcoin layer two
instead, leave the key in the depositor's own hands, and target roughly twenty percent. Nothing is
live, so treat that as a design figure rather than a measurement.

**Cork Finance** priced insurance on a risk that has no price. The base rate is unobservable, since
each stablecoin is structurally unique with almost no event history. The hazard is reflexive, because
the rising price of protection is itself the run signal. And the risk is perfectly correlated in the
only state that pays, so the underwriter is wiped out when several break together, usually holding
collateral in the same asset class being insured.

**Bunni** reshaped pool liquidity after every trade. Doing that correction themselves removed the
discrepancy arbitrageurs exist to close, so they forwent the arbitrage fees that pay liquidity
providers while still bearing the rebalancing cost, and the hack that killed them lived in that same
per-trade accounting. We re-centre only when price leaves a narrow band, and let outsiders pay us to
rebalance.

**Pendle** splits a yield asset into two tokens on a decaying curve needing re-parameterisation, with
liquidity fragmented per expiry; ours doesn't split, because the yield accrues to the reserve and
appears in the scheduled redemption. **mStable** routes to Pendle rather than lending the stablecoins
out, and earns nothing from trading them against each other. **Perena** swaps between stablecoins and
stops there, where ours are swappable against Ethereum and Bitcoin. **Panoptic** reaches single-sided
provision through options machinery, where the bond ladder gets there by funding the dollar leg out of
scheduled yield. **WBTC and cbBTC** are honest custodial receipts, correct for a mandate requiring a
regulated counterparty.

Across all of them we subtract. Bound risk by breadth instead of pricing it. One band instead of a
maintained distribution. Redemption on a calendar. Debt on somebody else's market, which already runs
its own liquidation machinery. Fewer moving parts is the safety argument, and it is why two people can
hold this system in their heads well enough to audit it honestly.

---

## What's something a smart, informed person would disagree with?

**Losses below your entry should not be hedged, and hedging them destroys value.**

Everyone builds this protection symmetric, and any derivatives desk would say a one-directional hedge
is not a hedge. We built the symmetric version, ran it, and threw it away. Below your entry the pool
has bought too much of the falling asset, and correcting that means selling the excess into the
decline, which turns a paper loss into a realised one and forfeits the recovery. Across a full round
trip, the holder who did nothing beats the holder who hedged, by exactly what got realised, on
identical fees. The same reasoning condemns the soft-liquidation machinery Curve's stablecoin is built
on, which avoids a hard liquidation by crystallising the drawdown instead.

**The related belief: we cannot win the fee war and should not try.** Cutting your fee does not buy
clean volume. It makes you the venue arbitrageurs correct first when the outside market moves, and
that flow is exactly the loss your liquidity providers bear. The fees it pays roughly equal the losses
it inflicts, so racing the fee down grows both sides and never the difference. Anyone benchmarking us
on headline volume will conclude we are losing on a metric that stopped meaning anything once solvers
began matching the easy flow away from pools.
