# Alliance application

Claims verified against `quidmints/SPV` and `quidmints/ibiza`. Mechanism detail and file references
are in `ALLIANCE-APPLICATION-LONG.md`.

---

## What is the problem you're solving?

We had a baby. The account the federal government seeds at birth is locked into a US stock index
until they turn eighteen. Good to have, and a single bet on one country's equity market that nobody
in the family votes on for eighteen years. The rest of a child's nest egg should not correlate to
that, should not sit with a custodian, and should be something my wife and I can look at alongside
our wealth manager rather than a line item he politely ignores.

Every alternative was bad in a fixable way. Bitcoin and Ethereum held outright earn nothing. Put them
in a trading pool and the pool sells whatever is rising and buys whatever is falling, so a rally
leaves you holding less Bitcoin and a decline leaves you holding more of it at worse prices. That gap
is impermanent loss, and the fees you collect roughly cover it and no more. The pool keeps its shelves
stocked by letting arbitrageurs trade against its stale price, which means it restocks itself out of
the people who supplied it. Put the dollar half in one stablecoin and you own an issuer bet nobody can
price.

So: deposit one asset, keep it, leave in it. We fund the dollar side of your position by issuing a
dated claim against yield we have not earned yet, then earn that yield from the liquidity the claim
created. Future yield is the junior tranche, so we subordinate a date instead of a person and carry
no waterfall. The loss the pool creates on the way up is cancelled by an optional overlay that borrows
against your own collateral on an outside market and hands the pool extra Ethereum to sell instead of
your principal. It unwinds to zero debt below your entry price, so we never carry leverage into a
crash. Dollar yield comes from eleven stablecoins, because breadth is the only depeg protection
anyone can honestly sell, and a twelve-month lock with us relieves redemption pressure on all eleven
at once, which no single issuer can offer.

Our second repository does the same for the largest asset most households own. Prove you control an
unencumbered title without disclosing who you are or which property, then borrow against that proof
into an address nobody can trace back to you.

---

## How did you learn about the problem?

By becoming responsible for someone else's eighteen-year horizon. An hour with our wealth manager
exposed it: the dollar side of a family balance sheet has a century of instruments, and the crypto
side has spot custody and a shrug.

Before that, expensively. Three times long on NEAR between 15 and 23, $350,000 of collateral carrying
50,000 units, liquidated near 7, equity to zero. A leverage ratio that stays fixed as price falls pays
for itself repeatedly, which is why ours sheds debt on the way down.

The rest came from work. Bancor's frontend incentivisation governance in 2019, the first practice of
what Uniswap and Liquity later called sufficient decentralisation. My mentor Eyal's basket idea, which
sat unbuilt until Liquity's issue #6 gave it a setting. Manifold Finance, where I learned what
extractive trading does to a passive quote. lbtc.io shut down in 2019 because it was custodial, and I
have been building the version without a custodian since.

---

## Who has this problem, and how do they deal with it today?

Families building wealth with an advisor who is fluent in half their balance sheet and treats the
other half as unmanaged, because nothing exists he can supervise or report on. Fund managers with a
depeg mandate, diversifying across six stablecoins by hand. Holders who stake for the base rate,
provide liquidity and eat the losses above, or use a leveraged product that swaps the holding loss for
liquidation risk. Lightning operators whose locked coins earn zero, which is why most of them quit and
why the network has been short of liquidity for a decade. And Bitcoin holders who want anything from
DeFi, who wrap and trust a company's receipt, or route through Lombard for around two percent and
inherit other networks' risks.

---

## What have you built so far?

All of it runs against forked mainnet state. None of it is audited or holds value yet.

A Uniswap v4 position whose token side is virtual, so your Ethereum stays in its lending venue earning
yield while the position quotes prices and collects fees. You get paid twice on the same coins. The
bond ladder funding single-sided deposits, capped at 600,000 with a bootstrap window closing after
twelve months. The up-side loss protection, sized from how far price moved since entry, running on
Morpho, Euler, Aave or Liquity, one isolated position per depositor. We wrote no liquidation engine,
because ours sheds debt in the direction the danger comes from, and a test runs a leveraged position
through a real liquidation to prove a passive depositor is untouched.

On Bitcoin, each depositor's coins sit in a two-signature account with one key theirs, verified by our
contracts using the same lightweight proof a phone wallet uses, validated end to end against a live
test node. The depositor signs one cold message and then runs nothing, with no node to host and no
uptime to keep. That message locks the single address every payout must reach, so even a fully
compromised operator can only send their money to them. If we vanish, a pre-signed transaction whose
bytes are already public becomes broadcastable by anyone, released by Bitcoin's own timelock. Which
machines may run our infrastructure is gated by an on-chain proof they execute an exact published
build inside a secure enclave, with a multisig governing that list and touching no money.

The second repository merges Privacy Pools with Rarime's passport proofs onto one proving system, 149
tests green. Shielded deposits earn, funded on a batched schedule so the yield venue's public logs
cannot reconstruct the link the cryptography hides. The passport stack we fork ran anonymous protest
votes inside Iran on the 2024 election.

---

## How do you know people need this?

Capa.fi pledged reserve deposits, and their chief executive was our grants liaison for Polygon.
EtherFi steered our work toward their liquidity pool. Mach and Khalani committed to list our basket as
a venue for their order flow, so volume arrives without a consumer app. The Uniswap Foundation and
Polygon Labs both funded us non-dilutively in 2025. Paul from Gauntlet and Artem, who wrote the
research on Bitcoin proofs in DeFi and is now at Blockstream, agreed to hold keys in the deployment
multisig without having to.

We have no live deposits. The honest evidence is structural: Lightning's liquidity shortage has one
cause and we removed it, and wealth managers have no supervisable crypto product, which is an absence
rather than a preference.

---

## How will you make money?

Quid Labs is wholly owned by the QuidMint Foundation, so the question is how the protocol funds
itself.

The largest line answers the arbitrage problem above. We hold no stale price, so there is no free
correction to take. A pool still needs restocking, so we charge for scarcity openly: when the pool is
low on Bitcoin, buyers pay above market and that premium stays in the reserve for depositors. It
steepens with volatility and is capped at what a market maker really pays to sit on capital awaiting
confirmations. We buy the service Uniswap gets for free from arbitrageurs, at a stated price, from
willing counterparties.

The position collects trading fees. Redemptions pay three to thirty basis points, shaped so the cheap
exit is the one leaving the reserve healthier. Our router earns a spread and already sits inside
Liquity's leverage tooling, taking it on both legs of somebody else's trade in their own product. And
the reserve is lent across Morpho, Aave, sDAI and Liquity, which earns whether or not anyone trades.
A quiet month has no floor to fall through.

---

## How will you find more customers?

Advisors first. An independent wealth manager with a few dozen families has nothing supervisable to
offer them. Give him one dashboard showing exposure, market regime and realised yield across every
client, on positions verifiable on a public ledger where we custody nothing, and he carries us into
every household he advises.

Then protocols, without a deal. Our deposit and mint functions are public and ungated, so an
integrator declares a local interface and ships against us without ever having a conversation. Our own
privacy stack does exactly that.

Then order flow rather than users, through Mach, Khalani and Liquity's tooling. Then Lightning
operators, where the pitch is that they stop working: one signature and a transfer is the whole
onboarding, and Bitcoin enforces the exit rather than our goodwill. And the stablecoin issuers, who
benefit from every twelve-month lock we sell.

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

The second mistake sits in the same repository and was wrong on the merits. Roughly 1,900 lines
implementing a jury system for a prediction market on stablecoins breaking, with the no-break side
funded from the reserve's own capital. Those are the dollars that redeem depositors at maturity, so a
payout removes them and the same dollar cannot both back a redemption and settle a claim. It also
fires during a crisis, when the reserve is already impaired. The protection it promised existed for
free, since a break is absorbed proportionally by everyone holding a claim. Both are gone, and depeg
protection today is diversification and nothing else.

---

## Tell us something about your company that's not going well.

I am in Ukraine, and the war is the largest operational risk this company carries.

The cost is mundane and relentless. Work stops when the power does. Anything needing a bank, a notary
or a physical presence takes weeks here that it takes hours elsewhere, and getting out to a meeting is
a logistics problem before it is a calendar problem. Hiring is close to impossible, because the people
I would want are already abroad or already serving, and I cannot offer anyone still here the stability
a job is supposed to come with. There is no redundancy in any of it. One person, in one place, holding
the work. Ingrid splits her time with a produce cooperative in Portland, so the second founder is
part-time by agreement.

Plainer: no audit, nothing on mainnet, zero live deposits. Native Bitcoin leverage is harder than the
Ethereum side and every clean path runs back through a custodial wrapper, so I would rather say out
loud that it probably isn't worth doing.

What I will claim is that the architecture was built by someone who assumed he might not be reachable.
Nothing runs on a server we own, the contracts cannot be upgraded and have no administrator, and a
depositor's exit needs nothing from us.

---

## How will the next LLM model release affect your business?

This codebase exists because of one. Ingrid's Claude subscription turned two years of prototypes into
a working system, and this volume of Solidity, Rust, Noir and Go is not something two people write by
hand in a country with rolling blackouts.

Better models compress what we are worst at, which is audit preparation and adversarial review of our
own money paths. The same improvement lets someone read our public repositories and rebuild the
design, so defensibility has to come from what is deployed and integrated. Anyone probing unaudited
contracts improves on that schedule too, which argues for finishing the audit before the money
arrives. The underrated effect is that continuous adversarial review used to be sold by firms at a
price that excluded teams our size.

---

## How do you use AI in your workflows today?

As an adversary more than an author.

We test by deleting the safeguard and confirming the test then fails, rather than trusting a green
result. That caught two identity tests that had silently stopped checking anything, a proof binding to
an unconstrained value, and a bug letting one property be titled twice.

We verify every cryptographic component against the exact on-chain function it will face, across 46
randomised structural cases. Compiling the gadgets rather than writing them found two real bugs
immediately.

We simulate to kill our own ideas. Measuring our trading losses on real crash data came back nearly
three times worse than our own published study, so we treat those figures as conservative floors.
Another run showed a fixed two-times position liquidating in five to nineteen percent of historical
Ethereum windows, which is why leverage sits on the depositor's outside book. A third produced a
finding we retracted, because the simulation charged a bookkeeping entry as a real trade.

The compliance research ran 105 sub-agents across 676 tool calls, ruled out the vendor we assumed was
our partner, and caught us citing a regulation for something it does not say.

---

## Who are your competitors, and why will you win?

**YieldBasis** solves the same problem and overpays. Half the trading fees maintain a fixed two-times
ratio, the borrowing drags, a break in the stablecoin they borrow cascades into every depositor, and
the fixed ratio forces re-levering on every decline, which is selling low and buying back higher on
repeat. Ours borrows on an outside market isolated per depositor, sizes to the loss actually incurred,
and unwinds below entry.

**Cork Finance** priced insurance on a risk that has no price. The base rate is unobservable, since
each stablecoin is structurally unique with almost no event history. The hazard is reflexive, because
the rising price of protection is itself the run signal. And the risk is perfectly correlated in the
only state that pays, so the underwriter collects small premiums in calm markets and is wiped out when
several break together, usually holding collateral in the same asset class being insured. Their model
produced a number. Two speculative crowds agreeing momentarily is not a price.

**Bunni** reshaped pool liquidity after every trade. Doing the correction themselves removed the
discrepancy arbitrageurs exist to close, so they forwent the arbitrage fees that pay liquidity
providers while still bearing the rebalancing cost, and the hack that killed them lived in that same
per-trade accounting. We re-centre only when price leaves a narrow band, and let outsiders pay us to
rebalance.

**Pendle** splits a yield asset into two tokens on a decaying curve needing re-parameterisation, with
liquidity fragmented per expiry. Ours doesn't split, because the yield accrues to the reserve and
appears in the scheduled redemption. **mStable** routes to Pendle rather than lending the stablecoins
out. **WBTC and cbBTC** are honest custodial receipts, correct for a mandate requiring a regulated
counterparty.

Across all of them we subtract. Bound risk by breadth instead of pricing it. One band instead of a
maintained distribution. Redemption on a calendar. Debt on somebody else's market, which already runs
its own liquidation machinery. Fewer moving parts is the safety argument, and it is why two people can
hold this system in their heads well enough to audit it honestly.

---

## What's something a smart, informed person would disagree with?

**Losses below your entry should not be hedged, and hedging them destroys value.**

Everyone builds this protection symmetric, and any derivatives desk would say a one-directional hedge
is not a hedge. We built the symmetric version. Below entry the pool has bought too much of the
falling asset, and correcting that means selling the excess into the decline, which turns a paper loss
into a realised one and forfeits the recovery. Across a full round trip, the person who did nothing
beats the person who hedged by exactly what got realised, on identical fees. We deleted the down-side
leg in July.

The same logic kills the soft-liquidation machinery Curve's stablecoin is built on. Those engines sell
collateral continuously as price falls to avoid a hard liquidation, capping further loss by
crystallising the drawdown, so across a decline and recovery you sold low and re-bought high.

**The related belief: we cannot win the fee war and should not try.** Cutting your fee does not buy
clean volume. It makes you the venue arbitrageurs correct first when the outside market moves, and
that flow is exactly the loss your liquidity providers bear. The fees it pays roughly equal the losses
it inflicts, so racing the fee down grows both sides and never the difference. Anyone benchmarking us
on headline volume will conclude we are losing on a metric that stopped meaning anything once solvers
began matching the easy flow away from pools.
