# QU!D — the whole thing, as questions

**Status 2026-08-01.** One document. It replaces `ALLIANCE-APPLICATION.md`,
`ALLIANCE-APPLICATION-LONG.md`, `legal.md`, `informational/CREDIT-STRATEGY-FINDINGS.md` and
`informational/GO-TO-MARKET-AND-READINESS.md`, which are deleted. Code documentation in
`docs/informational/` (IL, fees, venues, vault health) stays where it is and is referenced from here.

Every technical claim was read from source in `quidmints/SPV` and `quidmints/ibiza` before it went in.
Every external claim carries a source. Anything marked **OPEN** is genuinely unresolved and most of it
needs counsel rather than engineering.

**Part 1 is the fundraising application and is extractable on its own.** Parts 2 onward are the
reference behind it.

---

# Part 1 — The application

## What is the problem you're solving?

We had a baby. The account the federal government seeds at birth is invested in a US stock index fund
and locked until they turn eighteen. Good to have, and a single bet on one country's equity market, in
one currency, that nobody in the family gets a say in for eighteen years.

So the question was where the rest of a child's nest egg should sit. It should not correlate to that.
It should not sit with a custodian who can lose it. And it should be something my wife and I can look
at alongside our wealth manager rather than a line item he politely ignores because he cannot see
inside it.

Every option was bad in a specific, fixable way.

**Holding Bitcoin and Ethereum earns nothing.** They sit there. If you want them to earn, the usual
move is to put them in an automated market maker: a pool of two assets that quotes prices by formula
instead of by order book and pays you a cut of the trading fees. The catch is what the pool does with
your money while you are in it. It sells whatever is rising and buys whatever is falling. In a rally
you end up holding less Bitcoin and more dollars, having sold the Bitcoin too cheaply the whole way up.
In a decline you end up holding more Bitcoin at progressively worse prices, which the industry
cheerfully calls buying the dip and which is, in a sustained downtrend, just losing. The gap between
what you would have had by doing nothing and what you actually have is impermanent loss, and it is
neither small nor impermanent once you have exited. There is a well-known result that the fees you
collect roughly cover it and no more, so the average liquidity provider would have been better off
sitting still.

Worse, the mechanism that keeps a pool stocked is the mechanism that costs you. A pool's price is
always slightly stale relative to the real market. Professional arbitrageurs trade against that
staleness, correcting the pool and pocketing the difference, and that correction is how the shelves
stay stocked. The money for it comes out of the liquidity providers. **In plain terms: the pool stays
stocked by letting informed traders pick off the people who supplied it.**

**Putting the dollar half in one stablecoin is a bet nobody can price.** A stablecoin sits at exactly
one dollar with overwhelming probability, right up until it does not, at which point it moves to a
different regime in minutes. There is almost no data in the middle. The risk is also reflexive: the
price of insuring against a break feeds the probability of the break. And these events cluster, so the
one moment your protection pays out is the moment everything else you own is also breaking.

**Bitcoin locked into Lightning earns nothing either.** Lightning is Bitcoin's payments layer, and
routing a payment through it means locking coins into a joint account with your counterparty where they
earn zero. This is the whole reason Lightning has been short of liquidity for a decade: providing it is
a cost centre, so there is not enough, so routing is shallow, so the network underdelivers its own
promise.

### What we built instead

**You deposit one asset and you keep it.** Bring Ethereum on its own, or Bitcoin on its own. You do not
sell half of it to fund the other side of a trading position, which is what every other venue requires.
When you leave, you leave in the asset you brought plus what it earned. The claim you hold while you
are in is a standard yield-bearing vault share, the same interface any wallet or accounting tool
already reads, so an adviser's software can price it without a bespoke integration.

**The protocol funds the dollar side out of its own future.** A trading position needs both assets.
Normally that means selling half your Bitcoin to buy the dollars. We do not ask for that. The protocol
issues a dollar claim against yield it has not earned yet, uses it to fund the dollar side of your
position, and then earns the yield that redeems the claim from the trading and lending the position
enables.

Think about how a diesel engine starts. It needs no spark; compression alone ignites it, so the engine
is self-sufficient once turning. The only hard part is turning it over the first time, and with a dead
battery you do not need a jump pack. You roll the car in gear and let its own momentum crank the engine
until compression catches. The energy comes from inside the system.

Most crypto projects cold-start with a jump pack: print a governance token and pay people to show up,
which works until the subsidy stops. We crank with our own forthcoming output. Early depositors are
paid out of the protocol's own projected yield, and the liquidity that creates generates the yield that
was promised. There is a hard ceiling on how far we can crank, 600,000 units, written into the contract
(`Basket.sol:25`). After twelve months the projection horizon collapses from a year to a month, because
by then there is observed yield and no need to guess.

**Every credit system in history runs that drivetrain**, from a village bank to a central bank: create
present claims against future value, and use the present liquidity to produce the value that redeems
them. The differences are how loose the loop is. A bank lends against a borrower's project it does not
control. A bond funds an operation that may or may not generate the coupon. Seigniorage is created
against an entire economy's future productivity, the loosest loop of all. **Ours shortens it to
nothing, because the claim funds the exact position that generates the yield redeeming it**, and the
collateral is productive while it does so.

The instrument is a bond ladder. One token contract holds many dated series, each maturing in its own
month, so at any moment we know the entire forward dollar liability curve: what we owe in March, in
April, out to the end of the year. That is what an insurer's duration-matched book looks like,
expressed as a token, rather than a stablecoin with an unpredictable redemption queue.

And it is why we need none of the capital structure everyone else builds. The conventional way to make
a claim safe is to subordinate somebody: a senior tranche and a junior tranche, the junior eating
losses first, and that waterfall carried forever with a separate valuation per layer. **We subordinate
time instead of a person.** Future yield is the junior tranche. One elastic supply, no waterfall, no
per-tranche accounting, because the thing subordinated is a date rather than a claimant.

**The impermanent loss on the way up is cancelled.** The problem in a rally is that the pool sold your
Ethereum too cheaply, so we give the pool something else to sell. An optional overlay borrows dollars
against your own collateral on an outside lending market, buys extra Ethereum, and hands that to the
pool as the inventory it sells during the rally. **The band sells the buffer, not the principal.** The
buffer is sized exactly to the loss the pool has actually created, computable from how far price has
moved since you entered.

Two things deserve a non-specialist's attention. The borrowing happens on somebody else's lending
market, one position per depositor, walled off from everyone else, so a position that goes wrong hits
that depositor and stops. We have a test on real Morpho with a real price feed that runs a leveraged
position through a full liquidation and then checks a passive depositor's redeemable value and the
reserve's backing are untouched (`test/LeverageCrossSubsidyProbe.t.sol`). And the overlay unwinds to
zero debt when price falls back below where you started, so we are never carrying leverage into a
crash.

**The dollar yield comes from breadth.** Eleven stablecoins across lending venues rather than one
issuer's promise, because holding the basket is the only insurance against a break that anyone can
honestly sell. There is a second-order effect that surprised us: when a depositor locks dollars for
twelve months they simultaneously remove redemption pressure from every stablecoin in the basket, in
proportion to its weight. No individual issuer can offer that, because no issuer holds the others. A
longer lock relieves more pressure, which is why the yield schedule pays more for duration. Each issuer
then needs less cash on hand against redemptions and can deploy more toward earning, which flows back
through the basket's average to our depositors, who have more reason to lock for longer.

**Entries are informed rather than guessed.** A bank of Kalman filters, the standard tool for
estimating a quantity that drifts, tracks realised volatility, the position's exposure to Bitcoin
versus Ethereum, and how strongly prices are mean-reverting right now. That feeds a classifier labelling
the present regime as range-bound, two-way volatile, or trending. It characterises the current state
and forecasts nothing, which is stated plainly in the code so nobody mistakes it for a crystal ball.

**A depositor gets to know the dollar side is solvent regardless of what the volatile side is doing.**
Determinate design means perfect information, and that property is what makes the position supervisable
by somebody's adviser.

**And the instrument that comes out of it is something nothing else in crypto issues.** Pay $1,850,
hold a claim with $2,000 of face maturing in twelve months, forward yield priced in at entry. Pendle
needs two tokens and a re-parameterised decaying curve to approximate it. That claim is worthless to
anyone who needs cash today and valuable to a counterparty who only needs the money on a date they
already know, which turns out to be a large and dull category. **US residential security deposits alone
are around forty billion dollars sitting idle.** Part 5 is the product built on that.

**The largest household asset is the direction after that.** Our second repository lets a homeowner
prove they control an unencumbered title without disclosing who they are or which property. We do not
originate or underwrite, because four of the five roles in a mortgage need a licence and the fifth,
capital, is the one we have.

### Why this is worth funding rather than just building for ourselves

The thing we needed was a family-office capability: consolidated view, real diversification, credit
against illiquid assets, professional supervision. Families with a hundred million dollars have it.
Families with a normal amount of money have a spreadsheet and an adviser who cannot see half of it.

Solving it once solved two structural problems for everyone else. Bitcoin locked in Lightning stops
being dead capital, which moves the supply curve for the whole network and deepens routing for people
who will never hear of us. And bootstrapping a two-sided trading position no longer requires anybody to
sell half their holdings.

## How did you learn about the problem?

By becoming responsible for someone else's eighteen-year horizon. An hour with our wealth manager
exposed it: the dollar side of a family balance sheet has a century of instruments built for it, and
the crypto side has spot custody and a shrug.

Before that, expensively. Three times long on NEAR between 15 and 23, roughly $350,000 of collateral
carrying 50,000 units, liquidated near 7, equity to zero. Nothing about the trade was sophisticated and
the lesson had nothing to do with NEAR. A leverage ratio that stays fixed as price falls pays for
itself over and over, which is exactly why our overlay sheds debt on the way down and why we wrote no
liquidation machinery of our own.

The protocol economics came from work. In 2019 I built Bancor's frontend incentivisation governance, an
affiliate-fee system that turned out to be the first working practice of what Uniswap and Liquity later
called sufficient decentralisation. My mentor Eyal raised the basket-of-stablecoins idea before mStable
was announced, and it sat unbuilt until Liquity's issue #6 gave it a setting. At Manifold Finance I
learned what extractive trading does to a passive quote, which is the direct reason our pool prices off
a time-weighted average cross-checked against an independent feed and never publishes a stale price for
anyone to trade against.

The Bitcoin half came from a failure. lbtc.io shut down in 2019. The iOS app planned then was called
Ibiza, which is where I met Craig Sellars and Brock Pierce at the start of pre-seed. What killed it was
custodial wrapping: hand your Bitcoin to a company, take a receipt token, and the whole thing rests on
that company staying solvent and honest. I have been building the version without a custodian ever
since, and this is the first design where the depositor never gives up their key.

## Who has this problem, and how do they deal with it today?

**Families building wealth with an adviser.** The adviser is fluent in one half of the balance sheet
and treats the other as unmanaged, because nothing exists he can supervise, price, or report on. They
hold spot and hope, or buy an ETF and pay for the wrapper while giving up the yield.

**Fund managers with a depeg mandate.** Diversifying across six stablecoins by hand, with no single
instrument giving them the whole spread. Cork Finance built a product aimed exactly here and Part 3
explains why it cannot work.

**Holders who want yield without selling.** They stake for the base rate, provide liquidity and eat the
losses above, or use a leveraged product that swaps the holding loss for liquidation risk.

**Lightning liquidity providers.** Locked coins earn zero, so most small operators quit, and the
network's decade-long shortage is that calculation aggregated.

**Bitcoin holders who want anything from DeFi.** They wrap and trust a company's receipt, or route
through Lombard for around two percent and inherit other networks' risks. Every one of those asks a
Bitcoin holder to trust something new. Our design asks them to trust what they already trust, which is
Bitcoin's own rules and their own key, and connects that to everything else.

## What have you built so far?

All of it runs against forked mainnet state. None is audited or holds value yet.

A Uniswap v4 position whose token side is virtual, so your Ethereum stays in its lending venue earning
yield while the position quotes prices and collects fees. **You get paid twice on the same coins.** The
bond ladder funding single-sided deposits, capped at 600,000, with a bootstrap window closing after
twelve months. The up-side loss protection, sized from how far price moved since entry, running on
Morpho, Euler, Aave or Liquity, one isolated position per depositor. We wrote no liquidation engine,
because ours sheds debt in the direction the danger comes from, and a test runs a leveraged position
through a real liquidation to prove a passive depositor is untouched.

On Bitcoin, each depositor's coins sit in a two-signature account with one key theirs, verified by our
contracts using the same lightweight proof a phone wallet uses, validated end to end against a live
test node. **The depositor signs one cold message and then runs nothing at all**, with no software to
host and nothing to keep online. That message locks the single address every payout must reach, so even
a fully compromised operator can only send their money to them. If we vanish, a pre-signed transaction
whose bytes are already public becomes broadcastable by anyone, released by Bitcoin's own timelock.
Which machines may run our infrastructure is gated by an on-chain proof that they execute an exact
published build inside a secure enclave.

The second repository merges two open-source systems onto one proving system, with a single device seed
deriving both the identity key and the spending keys. Privacy Pools breaks the link between a deposit
and the withdrawal spending it, screening money by chain-analysis guesswork. Rarime proves a passport
genuine while revealing nothing about its holder. Merged, a withdrawal proves the honest thing: that a
real and unsanctioned person is withdrawing. The title ledger on top records a pledge without
publishing whose it is. Shielded deposits also earn, funded on a batched schedule so the yield venue's
public logs cannot rebuild the link the cryptography hides. That passport stack ran anonymous protest
votes inside Iran on the 2024 election.

One dashboard reads all of it, which is the piece a wealth manager needs and the piece nobody in this
industry builds.

## How do you know people need this?

Capa.fi pledged reserve deposits, and their chief executive was our grants liaison for Polygon. EtherFi
steered our work toward their liquidity pool. Mach and Khalani committed to list our basket as a venue
for their order flow, so volume arrives without a consumer app. The Uniswap Foundation and Polygon Labs
funded us non-dilutively in 2025. Paul from Gauntlet and Artem, who wrote the research on Bitcoin
proofs in DeFi and is now at Blockstream, agreed to hold keys in the deployment multisig without having
to. People who audit systems for a living do not attach their names to designs they think are unsound.

We have no live deposits. The honest evidence is structural. Lightning's liquidity shortage has one
cause and we removed it. Wealth managers have no supervisable crypto product, which is an absence
rather than a preference. And Thorchain's collapse stranded the constituency that chose non-custodial
cross-chain Bitcoin deliberately, who now choose between a custodial receipt and nothing.

## How will you make money?

Quid Labs is wholly owned by the QuidMint Foundation, so the question is how the protocol funds itself.

The largest line answers the arbitrage problem above. We hold no stale price, so there is no free
correction to take. A pool still needs restocking, so we charge for scarcity openly: when the pool is
low on Bitcoin, buyers pay above market and that premium stays in the reserve for depositors. It
steepens with volatility and is capped at what a market maker really pays to sit on capital awaiting
confirmations. **We buy the service Uniswap gets free from arbitrageurs, at a stated price, from
willing counterparties.**

The position collects trading fees. Redemptions pay three to thirty basis points, shaped so the cheap
exit is the one leaving the reserve healthier. Our router earns a spread and already sits inside
Liquity's leverage tooling, taking it on both legs of somebody else's trade. The reserve is lent across
Morpho, Aave, sDAI and Liquity, which earns whether or not anyone trades, so a quiet month has no floor
to fall through. The deposit-collateral product in Part 5 adds a fee shared with the surety, and it is
worth more than its margin because it brings deposits from people who are not chasing yield.

## How will you find more customers?

**Advisers first, and a specific kind.** Not a mainstream registered adviser, who cannot recommend an
unaudited protocol without breaching a fiduciary duty. A family office holding crypto for households
already asking what to do with it, or a firm built specifically to advise on digital assets, both of
which carry a fraction of the compliance surface and are hunting for products rather than waiting to be
sold to.

The wall that kept advisers out of this asset class is custody: an adviser who takes custody of client
crypto needs a qualified custodian. Our structure never raises the question, because the client holds
their own keys and the adviser gets read access to a position anyone can verify on a public ledger. And
the hook is not the dashboard. **Advisers bill on assets under management, and a client's self-custodied
ETH is invisible to their reporting stack, so it sits outside the fee base.** Make it visible and
reportable and they can bring it under management and charge on it. We are not selling them software,
we are expanding what they can bill.

Then protocols, without a deal: our deposit and mint functions are public and ungated, so an integrator
declares a local interface and ships against us without ever having a conversation. Then order flow
rather than users, through Mach, Khalani and Liquity's tooling, none of which needs us to acquire
anybody. Then surety companies, specifically the ones who decline thin-file renters today, because
partial collateral lets them approve a segment they currently reject. Then Lightning operators, where
the pitch is that they stop working, since one signature is the whole onboarding and Bitcoin enforces
the exit rather than our goodwill. And the stablecoin issuers, who benefit from every twelve-month lock
we sell.

## What is the biggest mistake that you've made so far?

I stayed on a dead product because the code was beautiful. The old repository is public at
github.com/quidmints/quid.

Most of it trades synthetic real-world assets: 9,750 lines of Rust wired to a price oracle across 935
US stock tickers, 101 currency pairs, five European equity venues, metals, commodities and rates. We
called it the Ostium killer. Neither Robinhood's chain nor Kraken's xStocks existed when we started.
Both arrived while we were building, and both are a better answer for the same customer, because they
hold the licences and the distribution.

Misjudging a market is forgivable. What I did wrong was keep going for months after the market had
answered, because the implementation was elegant and my hands were in it, and I let that stand in for a
reason.

The second mistake sits in the same repository and was wrong on the merits. A jury system for a
prediction market on stablecoins breaking, with the no-break side funded from the reserve's own
capital. Those are the dollars that redeem depositors at maturity, so a payout removes them, and the
same dollar cannot both back a redemption and settle a claim. It also fires during a crisis, when the
reserve is already impaired. The protection it promised existed for free, since a break is absorbed
proportionally by everyone holding a claim. Depeg protection today is diversification and nothing else.

Part 4 is the full list, including three more from the current repository, because the pattern matters
more than any single instance.

## Tell us something about your company that's not going well.

I am in Ukraine, and the war is the largest operational risk this company carries.

The cost is mundane and relentless. Work stops when the power does. Anything needing a bank, a notary
or a physical presence takes weeks here that it takes hours elsewhere. Hiring is close to impossible,
because the people I would want are already abroad or already serving, and I cannot offer anyone still
here the stability a job is supposed to come with. There is no redundancy in any of it. One person, in
one place, holding the work. Ingrid splits her time with a produce cooperative in Portland, so the
second founder is part-time by agreement.

Plainer: no audit, nothing on mainnet, zero live deposits. Native Bitcoin leverage is harder than the
Ethereum side and every clean path runs back through a custodial wrapper, so I would rather say out loud
that it probably is not worth doing.

What I will claim is that this was built by someone who assumed he might not be reachable. Nothing runs
on a server we own, the contracts cannot be upgraded and have no administrator, and a depositor's exit
needs nothing from us. Being here is also why the notary-registry work is built against Ukraine's
Ministry of Justice open data rather than against a hypothetical.

Part 7 is a fuller and less flattering readiness assessment, written so nobody has to discover it in a
diligence meeting.

## How will the next LLM model release affect your business?

This codebase exists because of one. Ingrid's Claude subscription turned two years of prototypes into a
working system, and this volume of Solidity, Rust, Noir and Go is not something two people write by
hand in a country with rolling blackouts. Better models compress what we are worst at, which is audit
preparation and adversarial review of our own money paths. The same improvement lets someone read our
public repositories and rebuild the design, so defensibility has to come from what is deployed and
integrated, and anyone probing unaudited contracts improves on that schedule too. The underrated effect
is that continuous adversarial review used to be sold by firms at a price that excluded teams our size.

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

And we reconcile documentation against code on a schedule, because design notes go stale faster than
code does and a stale paragraph is a trap for whoever reviews us next. The retraction banners across
`docs/informational/` are the output of that practice.

## Who are your competitors, and why will you win?

Part 3 has the full treatment. In short:

**YieldBasis** solves the same problem and overpays: half the trading fees maintain a fixed two-times
ratio, the borrowing drags, a break in the stablecoin they borrow cascades into every depositor, and
the fixed ratio forces re-levering on every decline, which is selling low and buying back higher on
repeat. Ours borrows on an outside market isolated per depositor, sizes to the loss actually incurred,
and unwinds below entry.

**Lombard and Babylon** pay a Bitcoin holder around two percent to underwrite the security of other
networks whose failures they then inherit. We integrate the most decentralised Bitcoin layer two
instead, leave the key in the depositor's own hands, and target roughly twenty percent. Nothing is
live, so treat that as a design figure rather than a measurement.

**Cork Finance** priced insurance on a risk that has no price. **Bunni** reshaped pool liquidity after
every trade, which removed the discrepancy arbitrageurs exist to close and starved their own liquidity
providers of the fees that pay for divergence, and the hack that killed them lived in that same
per-trade accounting. **Pendle** splits a yield asset into two tokens on a decaying curve needing
re-parameterisation, with liquidity fragmented per expiry. **mStable** routes to Pendle rather than
lending the stablecoins out. **Perena** swaps between stablecoins and stops there. **Panoptic** reaches
single-sided provision through options machinery. **WBTC and cbBTC** are honest custodial receipts,
correct for a mandate requiring a regulated counterparty.

Across all of them we subtract. Rather than trying to price a risk nobody can price, we bound it by
holding eleven things instead of one. A single band around the current price does the work a
continuously maintained distribution does elsewhere, and it only moves when price leaves it. Redemption
runs on a calendar set when the claim was written. Our debt sits on somebody else's market, isolated
per depositor, on a venue that already operates its own liquidation machinery. Fewer moving parts is
the entire safety argument, and it is why two people can hold this system in their heads well enough to
audit it honestly.

One note on how we relate to these. Bancor sued Uniswap last year. We build to be a venue inside other
people's products rather than a destination that has to beat them, which is why every integration
surface is permissionless and why our router already sits inside Liquity's tooling. Ethereum works
because the pieces compose, and that is worth more to us than winning an argument.

## What's something a smart, informed person would disagree with?

**Losses below your entry should not be hedged, and hedging them destroys value.**

Everyone builds this protection symmetric, and any derivatives desk would say a one-directional hedge
is not a hedge. We built the symmetric version, ran it, and threw it away. Below your entry the pool
has bought too much of the falling asset, and correcting that means selling the excess into the
decline, which turns a paper loss into a realised one and forfeits the recovery. Across a full round
trip the holder who did nothing beats the holder who hedged, by exactly what got realised, on identical
fees. The same reasoning condemns the soft-liquidation machinery Curve's stablecoin is built on, which
avoids a hard liquidation by crystallising the drawdown instead.

**The related belief: we cannot win the fee war and should not try.** Cutting your fee does not buy
clean volume. It makes you the venue arbitrageurs correct first when the outside market moves, and that
flow is exactly the loss your liquidity providers bear. The fees it pays roughly equal the losses it
inflicts, so racing the fee down grows both sides and never the difference. Anyone benchmarking us on
headline volume will conclude we are losing on a metric that stopped meaning anything once solvers
began matching the easy flow away from pools.

---

# Part 2 — How it actually works

## What happens to my Ethereum when I deposit it?

It goes to a lending venue you choose at deposit time and stays there earning. The Uniswap v4 position
that quotes prices and collects trading fees uses **virtual** tokens, so your real ETH never has to sit
idle in a pool. You are paid twice on the same coins: venue yield on the whole stack, and trading fees
on the slice that is quoting.

The venue rides the deposit call and there is no setter, so the allocation discretion that exists
belongs to you rather than to us. Deposit codes are 0 (split across curators), 2 (Aave v4), 3 (Galaxy),
4 (ether.fi via our own weETH/WETH position), 5 (Euler), 6 (Gauntlet). There is deliberately no code 1;
ether.fi always routes through Rover. See `docs/informational/ETH-VENUES.md`.

## What is vETH exactly? Is it a wrapper around two assets?

No, and the distinction matters for anyone integrating it. The underlying band is two-sided, ETH plus
synthetic dollars, but **the synthetic dollar leg is protocol-owned and was never yours.** So the share
redeems to one asset: ETH, plus the fees that share earned. `convertToAssets(shares)` is your pro-rata
slice of the ETH-side backing, and fees accrue by appreciating that single-asset share price.

It feels dual because the position trades both sides. The redemption surface is single-asset, which is
what makes it a clean ERC-4626 rather than an LP-token-of-two-tokens that no accounting system knows
how to price.

## How is the impermanent loss actually cancelled?

The rule is that **the band sells the buffer, not the principal.** When ETH rises, the band's loss is
that it sold ETH too cheaply. The overlay borrows a stable against your own collateral, buys ETH with
it, and supplies exactly enough extra ETH for the band to sell instead of yours.

The keeper sizes that buffer to the loss actually incurred, `1 − √(entry/now)`, which is the fraction of
ETH the band has sold since you entered. The target returns zero at or below entry
(`imports/LevMath.sol:109-125`). Where the band reports its real measured sold fraction, that number is
used in preference to the formula.

There is an elegance worth noting: **"the band sells the buffer" and "unwind the borrow for a swap" are
the same operation.** A buy-ETH swap makes the band sell ETH, which sells the buffer, which de-levers
the slice and repays debt. The tap mechanism and the buffer-sale mechanism are one thing, not two bolted
together.

## Why up-side only? Isn't a one-directional hedge not a hedge?

That is exactly what a derivatives desk would say, and we built the symmetric version before deleting
it. Below entry the band over-holds the falling asset. A short leg corrects that by selling the excess
into the decline, which realises the loss and forfeits the recovery. Down-side impermanent loss is
genuinely impermanent and heals on its own, so for a long-biased holder, doing nothing strictly
dominates any round trip: same fees, minus the realised leak. The up-side overlay bets **with** the
holder's thesis; a down-side short bets against it.

**De-levering and shorting are not the same thing and protect in opposite ways.** De-levering as price
falls sells collateral to shrink exposure, driving delta toward zero. That caps further loss and
crystallises the drawdown, so over a down-and-back-up cycle you sold low and re-levered high, which is
the LLAMMA cost. You are de-risked, not made whole. A true short gains as price falls and preserves
value through it. We do neither below entry: we hold.

## Why is there no liquidation engine?

Because our leverage is counter-cyclical to liquidation risk. Below entry the target is zero, so the
keeper de-levers to zero debt and there is nothing to liquidate. Above entry the collateral has
appreciated, so the loan-to-value ratio is healthy. The only residual is a gap crash while still
levered above entry, and that is backstopped by the external venue's own isolated liquidation, which
hits one depositor and stops.

Soft-liquidation engines exist to convert collateral to stable continuously as price falls so a levered
position never hard-liquidates. Our design makes that structurally unnecessary. Simpler and safer than
both a static-leverage design that pays re-levering losses on every down-move and a stablecoin that
needs LLAMMA to survive.

## What is the "full-2× buffer" and why do ETH and BTC differ?

A two-times levered position puts in equity E, borrows E, and holds a 2E band position. That 2E sits in
one pooled-dollar slice as equity E plus a debt-funded buffer E. **The buffer's dollar value equals the
depositor's own debt exactly**, so the pure equity claim is in-range dollars minus leverage debt, read
live from the pinned manager (`Core.sol:93-99`).

Same concept both assets: the `POOLED_*` counters are **gross** and include the buffer; the `vogue*`
views are **net** and exclude it. The buffer is excluded from the net view because it is debt-offset —
an asset E matched by an equal debt E contributes zero equity, and counting it would treat borrowed
coins as backing, inflate solvency and over-issue QD.

The plumbing differs. On ETH, `vogueETH` excludes the pooled slice entirely, so the shortfall path must
add gross collateral back to make a gross-versus-gross comparison balance. On BTC, `syncLevBTC` pairs
net equity into `POOLED_BTC` in lockstep with the levered slice, so BTC's gross is already inside and
adding a gross term would double-count. **A naive collapse of the two would break one side's shortfall
maths**, which is why the asymmetry is deliberate rather than an oversight.

## Why is ETH's collateral treated differently from BTC's?

ETH's gross collateral (weETH, WETH) is on-chain deliverable, so "gross is the backing, debt netted as a
liability" is the direct representation: what you count is literally redeemable.

BTC's gross is channel BTC, which is **not deliverable** because it is cross-chain. You cannot redeem QD
against sats sitting in a Lightning channel. So BTC is forced into net-equity for solvency, plus a
separate buffer for capacity.

> **Precision note, corrected 2026-08-01 against the source.** An earlier draft said `deliverableETH`
> "subtracts the full gross so redemptions never touch the levered slice." It subtracts the levered **net
> equity**, not the gross. The source also insists the name be read narrowly: it is **not** a promptness
> guarantee and not a view-twin of the withdraw ladder, and it counts the Aave leg, weETH at the vault,
> raw eETH and the offramp position at full face even though none is instantly convertible. That
> over-statement is tolerable rather than a bug, because its only two consumers tolerate it: the band
> uses it solely to cap how much of a withdrawal is sourced from the in-range burn before the venue
> ladder takes the remainder, with the shortfall derived from what was actually sent so the sourcing
> order self-corrects; and the swap-out de-lever gate is caught downstream by slippage bounds and
> deferral. Do not quote it as a redemption guarantee.

## What is the skew, and why does the pool need one?

It is the answer to "the toxic thing Uniswap does to refill." A constant-product AMM keeps inventory
balanced by letting arbitrageurs trade against its own stale price: the market moves, the pool lags,
arbers realign it and pocket the gap. The pool always has inventory, and its providers pay for that
rebalancing through systematic adverse selection.

We refuse it. Swaps price off an internal time-weighted average cross-checked against an independent
feed, so there is no stale price and no free correction. **But a pool still needs restocking**, so we
buy the same service openly: when the pool is scarce in the volatile asset, a buyer pays above the
oracle price, and that premium is retained as basket backing for depositors
(`Core.sol:259-285`).

This is the reservation-price offset from inventory-risk market making, the Avellaneda–Stoikov idea:
the price of holding the wrong composition. It steepens with realised variance and is capped at the real
drain-edge cost a native-BTC desk bears while its capital is locked awaiting roughly six confirmations.

**One thing that used to exist and does not:** a bonus paid to whoever refilled the pool was removed in
July 2026. Refill is now a self-funding fleet operation, so the premium accrues to depositors instead of
being paid out to a refiller.

## How is the redemption fee calculated?

Two terms, not three. A drain tax that rises when you pull out the stablecoin whose yield is above the
basket's weighted average, scaled convexly by how much of that stablecoin you are draining, bounded
between 3 and 30 basis points. And a separate, uncapped depeg haircut so nobody redeems a
dollar-booked-but-ninety-five-cent-worth stablecoin at par.

The shape means **the cheap exit is the one that leaves the basket healthier**: shedding a depegged or
low-yield name costs the floor, draining the yield engine costs more. A default redemption draws
pro-rata across the basket, so an exit cannot covertly concentrate risk into one collateral.

A third term, a Liquity-style decaying directional toll, was documented and then removed, because QU!D
has no peg-arb loop for it to price. See `docs/informational/FEES-OUTFLOWS-TWAP.md`, which carries the
retraction.

## How does the Bitcoin side work without a custodian?

Each depositor's coins sit in a two-of-two joint account on Bitcoin, key-path taproot, one key theirs.
The funding output is 34 bytes: `0x5120 || Q`, where **Q is the 32-byte x-only MuSig2 aggregate key** of
the two funding keys. Our contract does no elliptic curve arithmetic at all; it byte-matches the
committed Q against an SPV-proven transaction, the same lightweight proof a phone wallet uses to check
a payment happened. Validated end to end against a live regtest node.

Taproot buys a key-path spend carrying a 64-byte Schnorr signature and no witness script, so there is
no script to reconstruct on-chain and no leaf to hide anything in. **The honest limit, stated in the
source:** the contract never proves Q equals the aggregate of the two keys, so two-of-two genuineness
rests on the off-chain key generation plus the hop gate. A malicious hop is the residual, and it was the
residual under the previous script-based design too.

## Why many channels rather than one pooled vault?

Because "one channel" only feels like less work. A single pooled channel would save a counter or two by
letting us use pool fractions instead of per-depositor delivery tracking. It would also mean somebody
custodies everyone's Bitcoin, which is either a trusted custodian, defeating the entire point, or a
threshold federation, which is more work than per-depositor channels plus a single catastrophic failure
target. It caps liquidity at one channel's size and makes rebalancing a coordination problem. And you
would build every hard part anyway: the proofs, the funding and close, the swap routing.

So the trade is not simple versus complex. It is a couple of accounting counters versus a
custody-and-trust problem plus a scaling ceiling. **Multi-channel pays the small price to get per-
depositor self-custody, no single point of failure, and horizontal scaling where every new depositor
brings their own capacity.** Slightly more on-chain work, N proofs instead of one, but they are
independent and parallel and that is literally what buys N independent trustless positions.

This also settles a modelling question: pool-fraction accounting was never actually available to us
without giving up the decentralisation, because it is the single-channel model wearing a disguise.
Per-channel accounting is not the more expensive option, it is the only one honest about where the
Bitcoin lives.

## Isn't per-swap Bitcoin settlement impossibly heavy?

It would be, and that is not the design. **Ethereum is peer-to-pool and non-custodial because WETH
lives inside the contract.** Native Bitcoin cannot live inside an Ethereum contract, so non-custodial
native Bitcoin liquidity is either per-depositor channels (non-custodial but peer-to-peer) or a bonded
federation (peer-to-pool but custodial). That is the cross-chain trilemma rather than a design failure.

The resolution is to decouple the swap from the settlement. The user-facing swap is peer-to-pool,
instant, on Ethereum, against pooled Bitcoin, with providers holding pro-rata shares. Each swap advances
an off-chain channel commitment, which is cheap, both-signed, and needs no Bitcoin transaction. The
on-chain settlement happens periodically, or when somebody actually withdraws real Bitcoin to a Bitcoin
address. **N swaps become one settlement.** That is what a commitment scheme is for: many cheap
off-chain updates netting into rare on-chain settlements, amortised to near-zero per swap.

## What do I give up by letting the fleet run my channel?

Less than you would expect, and the code says so. You sign one cold EIP-712 delegation, relayed
gaslessly by the operator, naming who may operate channels owned by your address and the single Bitcoin
payout address every payout must reach. That address is **locked** from that moment, so a fully
compromised operator can only fund positions credited to you with payouts to you. Bounded, never theft.

The authority you name is either a specific hop, if you self-host or run a family node, or the
Safe-governed registry, in which case any hop it attests can operate for you and a key rotation is one
transaction that every delegating depositor follows without re-signing.

**Two residuals remain, and both are narrow.** Autonomy: if the operator is compelled to deny you
service or shuts down, a self-hoster keeps operating their own channels. But the dead-man exit means
even a fleet depositor still exits non-custodially, because a pre-signed timelocked transaction with
public bytes becomes broadcastable by anyone once our heartbeat stops. So the residual is continuing to
*operate*, not continuing to *exit*. And institutional custody policy: an entity contractually barred
from any third party in its custody path. Both are real and neither is mass-market.

**One practical constraint:** the payout address must be a 32-byte x-only taproot key, because every
payout script is key-path P2TR. A legacy or segwit-v0 exchange withdrawal address will not work.

## Why don't Bitcoin depositors' fees compound like the ETH side?

They could, and it would make them worse off. Three reasons, and the second is the non-obvious one.

It costs real Bitcoin transactions. ETH fee compounding is a free accounting entry because the v4 ETH
pool is virtual and the real ETH already sits at the venue. Bitcoin liquidity lives in a real UTXO, so
folding owed sats into capacity means a splice transaction with a fee, a confirmation wait and a proof.

**It would subject the Bitcoin depositor's fee yield to impermanent loss, which it currently escapes.**
On the ETH side a compounded fee becomes part of the position and bears IL going forward, which is
standard AMM behaviour. On the Bitcoin side the fee is a fixed sats claim paid at close and never
re-invested, so it is IL-shielded. Aligning the two would convert an IL-free fixed claim into
IL-bearing principal. **The asymmetry is a favourable property, not a gap**, and symmetry for its own
sake would downgrade Bitcoin depositors.

And it touches the per-channel close attribution. Splicing fee sats into the funded amount grows the
principal base that feeds delivery denominators, so it cannot be done without corrupting that
accounting.

## Is a Bitcoin liquidity provider just buying the dip all the way down?

A pure in-range Bitcoin position would be, and that is the honest risk. Such a provider ends up holding
more Bitcoin at progressively lower prices, with the loss realised as a real dollar-value hit, offset
only by fees. Bitcoin has no yield stack to cushion it the way restaking cushions ETH. In a sustained
downtrend, in-range Bitcoin provision is structurally a losing position and the fees do not cover a
trending drawdown.

> **⚠️ CORRECTED 2026-08-01 against the source.** An earlier draft of this answer said the protocol
> delta-hedges Bitcoin depositors back to one-times exposure using its own balance sheet, buying back
> the Bitcoin the AMM sheds at a cost of roughly a quarter of variance paid from trading fees. **That
> mechanism was removed as toxic and does not exist.** It is `arbBTC`, the Bitcoin analogue of
> `refillETH`, and `Aux.sol:862-866` records the removal in exactly the terms Part 4 uses: it spent the
> **shared** safety margin to deliver WBTC against a usually-impermanent shortfall, compensating the
> exiting flow at every other claimholder's expense. The draft therefore described as a live feature the
> precise thing this document elsewhere lists as a mistake we made and reversed.

**Three things actually bound that risk, and none of them is a protocol-funded hedge.**

**The theta clamp caps how much is exposed at all.** The paired band depth is limited to a live
fraction of the Bitcoin backing, derived from yield over concentration times variance, so the in-range
slice shrinks automatically exactly when volatility spikes. Most of the deposit sits outside the band
and is never short gamma.

**The IL protection is an opt-in per-depositor overlay, not a balance-sheet operation.** `BtcLevManager`
is the Bitcoin analogue of the ETH one, sharing the same economics through the shared library, with
vBTC-collateral leverage on external isolated venues and the same `1 − √(entry/now)` target that returns
zero at or below entry. A depositor who wants the up-side loss cancelled opts in and it happens on their
own external book. A depositor who does not, holds.

**And shortfall settlement is settlement, not subsidy.** When the pool owes Bitcoin, the only path is a
Lightning hop request: real Bitcoin sent on layer one by the hop daemon, **consuming no basket
stablecoins**. The old WBTC-from-free-backing fallback is gone. With no registered recipient it is a
no-op and the pool composition reconciles fairly at settlement.

So the honest answer to the question is that a Bitcoin depositor is exposed to trend risk on the
*clamped slice only*, can cancel the up-side portion of it on their own book if they choose, and bears
the rest through the share price. Nobody else's capital makes them whole, which is the same principle
the ETH side settled on after `arbETH` was removed.

## Does where I host my node affect anyone else?

No, and this is why "choosy providers" is not a complication. A provider's node only ever holds that
provider's own half of a two-of-two with the hop, and the on-chain custody is correct by construction.
Where you host affects the security of your own key and nothing else. Neither the hop nor any other
provider needs to trust how you host.

## What does the quant dashboard actually do?

It characterises the current market state and forecasts nothing, which is written into the source so
nobody mistakes it.

A bank of Kalman filters, the standard tool for tracking a quantity that drifts, estimates three things:
volatility in log-variance space for positivity and stability, factor exposure between ETH and BTC, and
the mean-reversion coefficient. Production rules from the spec are both implemented: an
innovation-divergence check that flags a filter which has stopped tracking, and a Huber robust gain that
down-weights innovations beyond three standard deviations so fat tails do not throw it.

That feeds a regime classifier labelling the present as range-bound, two-way volatile, or trending. It
is source-agnostic and runs on any log-price series, and it deliberately combines the internal pool ring
with external market feeds, because reading only your own pool is circular: the pool is the thing you
are trying to protect.

## What is the smart order router and what is different about it?

Each path is a chain of v4 hops sharing an entry stablecoin and a source vault, routed through the pool
manager's unlock, with the terminal always native ETH. Two things distinguish it.

At runtime it picks the source with the **highest live basket concentration fee** first, and only falls
back to deploy order if that fails. So routing is a function of basket health rather than a static
preference: the router prefers to spend the stablecoin the basket most wants to shed.

And it accepts caller-funded paths. An external caller can route its own funds through the same real
Uniswap v4 hops without touching basket backing, which is what lets the leverage overlay swap borrowed
dollars without spending the reserve. That is also why `SorExchange` drops into Liquity's leverage
zapper as a compatible exchange, so we earn the spread on both legs of somebody else's trade inside
their own product.

## How do the off-chain strategies and the Lightning keeper fit together?

A Rust workspace runs the bridge: the Lightning hop, the mirror reflecting every Bitcoin movement onto
the contracts, the swap rails in both directions, and the leverage keeper. **The EVM contracts hold the
accounting authority.** Nothing off-chain can mint or move funds without the on-chain checks passing.

The hop is protocol-operated and trusted infrastructure in the sense that it co-signs channel operations
and submits mirrors, but it **cannot steal**: every value path also requires the depositor's signature
and the Bitcoin two-of-two spend. The worst case for a lost or compromised hop key is halt, not theft,
and depositors always self-exit.

The keeper's entire job is to make a liquidation engine unnecessary. It polls each opted-in levered
position and holds its loan-to-value inside a band around the target while never letting it reach the
external venue's liquidation threshold, always a full safety margin below. So the venue's engine is a
never-triggered backstop and we never wrote one. It is event-driven rather than a simple poller, because
an unlevered depositor's withdrawal can force a chained unwind of other levered positions.

The target is `L = 1/α`, where α is the realised band concavity measured from actual flow. Busy flow
drives α toward one half and leverage toward two, cancelling the loss that flow created. Quiet flow
drives leverage toward one, because there is no realised loss to cancel. **Pinning a constant two-times
over-levers in quiet regimes and drains the buffer**, which is the mistake sizing to α avoids.

## What is the multisig for?

One bounded governance surface, and it moves no money.

Which addresses may act as a Bitcoin hop is gated by an on-chain Intel DCAP attestation, verified by
Automata's audited verifier, proving the hop's EVM key was born inside a whitelisted enclave
measurement and is sealed to it, so modified code cannot reach the key. The Safe governs **only** that
measurement whitelist and the revocation list, meaning which *code* may be a hop. Adding a measurement
is a public transaction checkable against a reproducible build.

It exists because the Bitcoin swap pool is global, so a malicious hop would dilute every depositor
rather than harming one. Off-chain per-depositor attestation cannot protect a shared pool; the honesty
of every hop has to be enforced at the contract, for everyone. Every value-moving contract renounces
ownership.

## Why does Lightning matter beyond our own depositors?

Bitcoin's base layer settles a handful of transactions per second, enough to be settlement and not
enough to be money you spend. Lightning is the answer that keeps Bitcoin Bitcoin: payments move
off-chain across two-of-two channels, instantly and nearly free, while every channel is anchored to and
enforced by Bitcoin itself. It inherits base-layer security without paying the throughput tax, and it is
the only scaling path that does not dilute what Bitcoin is.

Its hardest adoption barrier is economic rather than cryptographic. **Routing requires locked capital
that earns nothing**, so inbound liquidity is chronically scarce, so routing is shallow, so the network
underdelivers. Every honest analysis lands here.

Making locked channel Bitcoin simultaneously back a yield-earning position attacks that at the root,
without custodial wrapping, without forking Lightning, and without asking Bitcoin to be anything other
than Bitcoin. If providing channel liquidity pays, the supply curve moves, and deeper liquidity means
better routing for everyone on the network rather than only for our depositors. The externality is
positive and it is the one thing the network has structurally lacked.

---

# Part 3 — Competition, in detail

## YieldBasis

It targets zero impermanent loss on a Bitcoin position by borrowing an equal value of crvUSD against
the deposit and running a constant two-times leveraged position. A two-times leveraged AMM position
moves roughly linearly with the asset instead of concavely, so the holding loss is cancelled while the
position still earns fees.

**The loss is not eliminated, it is paid for.** Maintaining constant leverage as price moves requires
continuous rebalancing, funded from a budget filled by the borrow fees and **half of all trading fees**.
That is the cost, made explicit: the provider keeps roughly half the gross fees and pays the borrow. By
no-arbitrage this is what theory forces, since hedging a concave payoff costs approximately the loss
itself. You can move it from a holding loss to a flow cost; you cannot make it vanish.

What that buys: leverage and debt, so liquidation risk, a borrow-rate drag, and reflexivity on crvUSD
where a depeg or a lending-market stress cascades into every provider. Half the trading fees consumed.
Regime dependence, since it only nets positive when remaining fees plus asset yield exceed borrow plus
rebalancing. And dependence on arbitrageurs and a rebalancing AMM to hold the peg under stress, so
linearity is a maintained property rather than a guaranteed one.

**Our two differences.** Safer: our debt stays external and isolated per depositor, so QD never takes a
socialised gap tail. And more efficient with a safer downside: a static two-times pays re-levering
losses on every down-move, whereas we lever dynamically to the loss actually incurred and de-lever to
zero below entry, so we never hold two-times into a crash.

## Cork Finance

Depeg swaps functioning like credit default swaps, with cover-token holders earning yield if no depeg
occurs and absorbing the loss if it does, priced with a market-implied risk premium. The premise is that
depeg risk can be actuarially priced and underwritten. **It cannot, and not for want of cleverness.**

Actuarial pricing needs three things and a peg breaks all three.

**The base rate is unobservable.** A peg sits at roughly par with overwhelming probability until it
jumps to a different regime. The distribution is bimodal with almost all mass at par and a thin
catastrophic tail, and each peg is sui generis with different collateral, redemption mechanism and
operator, so there is no frequency data to estimate the tail from. You are pricing an event that by
construction almost never appears in the sample.

**The hazard is reflexive rather than exogenous.** Fire and mortality are roughly independent of the
insurance written on them. A depeg is a confidence and coordination failure, so the price of the
insurance feeds back into the probability of the event, and spiking depeg-swap prices are themselves a
run signal. You cannot price a hazard whose probability is a function of its own price; the model and
the market are entangled.

**The risk is perfectly correlated in the only state that pays.** Insurance works because risks are
independent and not every house burns the same day. Depegs cluster: they happen in liquidity crises,
and in a crisis the whole correlated complex breaks at once, as USDC in March 2023 dragged DAI through
its collateral, as UST and LUNA did, as the LST cascade did. The underwriter collects small premiums in
calm and is wiped out exactly when many pegs break together. Worse than undiversifiable: the
underwriting collateral is usually the same asset class being insured, so payout capacity evaporates
precisely when claims arrive.

On top of that there is no replicating portfolio. The underlying gaps discontinuously, par to eighty
cents in minutes, so you cannot delta-hedge through the gap, and there is no deep options surface on the
peg to back out implied probabilities. Without a hedge, fair price is undefined except under a model the
rare event will itself violate.

So in theory you write probability times severity plus load and call it fair. In practice every input is
unobservable, endogenous or undiversifiable. Their model produced a number, and a market-implied
clearing price for a reflexive, correlated, un-hedgeable tail is not an actuarial price. It is the
momentary agreement of two speculative crowds, carrying no guarantee of covering realised loss. **An
elegant implementation of an unpriceable premise.** Practical attempts are moot because the mootness is
structural rather than a tuning problem.

**Which is why diversification is the only feasible alternative, and why we hold a basket.** If you
cannot price or underwrite the tail of any single peg, the robust move is never to take a concentrated
bet on any single peg's survival. You do not insure the risk, you bound it by breadth. **The only way to
be insured against depegs is by holding basket shares.**

## Bunni

A v4 hook that replaced Uniswap's native mechanics with a custom liquidity distribution function
intended to rebalance the pool after every trade to maintain correct token ratios. The bug exploited in
their catastrophic hack lived in that per-trade liquidity-reshaping accounting step.

**And they were depriving arbitrageurs.** By reshaping liquidity after every swap to maintain ratios,
the function was doing the arbitrage itself, mechanically correcting the pool's price toward external
markets inside the hook logic. Doing that removes the price discrepancy arbitrageurs exploit. No
discrepancy means no arbitrage opportunity means no arbitrage fee flow. The pool ate the arbitrage
profit itself through the rebalancing mechanism rather than letting external parties capture it and
return it as fees.

The consequence is that their fee revenue came almost entirely from organic volume. Arbitrage volume,
which is a large share of AMM swap volume and generates the majority of provider fee revenue in volatile
pairs, was structurally eliminated as a fee source. Providers supplied liquidity and got back less than
a vanilla pool with the same TVL would return. The pool also paid the rebalancing cost continuously, in
gas, hook computation and the implicit cost of reshaping against incoming flow, without capturing the
revenue that normally compensates for divergence.

**Our calibration is one symmetric band around the current price**, recomputed and repacked only when
price drifts out of the current range, never after every trade. One static range, event-triggered, no
continuous distribution function. Categorically simpler, and we let external arbitrageurs capture the
discrepancy and pay us fees for the privilege.

## Pendle

It wraps a yield-bearing asset, splits it into a principal token redeeming one-to-one at maturity and
trading at a discount before, and a yield token capturing yield to maturity, then trades them on a
bespoke time-decaying AMM whose rate anchor and scalar must be re-parametrised as expiry approaches,
with liquidity fragmented per maturity.

Our bond is more elegant on four axes. **No token split**, because the yield accrues to the reserve and
is reflected in the scheduled redemption, so one instrument rather than two tokens and two markets.
**No bespoke decaying AMM**, because redemption is on a known schedule at a known relationship to the
reserve, self-funding by duration, so there is no secondary curve to maintain and no keeper
re-parametrisation risk. **No liquidity fragmentation**, because maturity is an accounting stamp on one
unified basket rather than a separate pool per expiry. And **matched yield rather than stripped and
sold**: Pendle monetises yield by selling the strip to a counterparty, whereas ours keeps the yield
inside the reserve servicing the bond, so the bond is self-funding with positive carry and needs nobody
to buy the strip.

## mStable, Perena, Panoptic, and the wrapped-Bitcoin products

**mStable** is the only genuine basket competitor. It works with Pendle exogenously and does not
redeploy the stablecoins to Morpho or Aave. It has no endogenous yield, meaning it does not trade the
stablecoins against each other or against ETH and BTC. Good interface on somebody else's strategy.

**Perena** only swaps between stablecoins. There are eleven in our basket and they are swappable against
ETH and BTC.

**Panoptic** reaches single-sided provision through options machinery. Our bond ladder gets there by
funding the dollar leg out of scheduled yield, which is a simpler mechanism for the same outcome.

**BitGo's WBTC and Coinbase's cbBTC** are useful for depositors whose mandate requires regulated
counterparties, and they are honest about what they are. They are also ultimately backwards to what
bridging Ethereum and Bitcoin should be.

**Lombard** links Babylon as a sort of EigenLayer for Bitcoin, which exposes stakers to risks from the
underlying networks whose economic security is being underwritten, compensating them around two percent.
We integrate the most decentralised Bitcoin layer two, leave the key with the depositor, and target
roughly twenty percent. Nothing is live, so treat that as a design figure.

**Exodus** is the newest and the most direct. They agreed to acquire W3C Corp for $175 million, bringing
in Baanx as a crypto card program manager and Monavate as an issuer processor, giving direct issuing
capability on Visa, Mastercard and Discover. Exodus Pay is self-custodial spending of USDC or Bitcoin at
any Visa merchant or through Apple Pay, with network fees subsidised, rolling out state by state through
April 2026. **That rollout cadence is the money-transmission licensing grind made visible by a public
company with a balance sheet**, and it is the strongest available evidence for how hard the card path
is. Baanx remains available as a program manager, so partnering is a route, entered as the supplier
rather than as a late-following competitor.

## The throughline

Cork and Bunni both died by adding expressive machinery on top of v4: an unpriceable insurance market
and a per-trade liquidity-reshaping function. Pendle carries structural overhead in its two-token split,
decaying AMM and fragmented liquidity.

**Our edge everywhere is subtractive.** Bound risk by diversification instead of pricing it. Calibrate
one current-price band instead of maintaining a continuous distribution. Redeem on a schedule instead of
on a maintained curve. Keep debt external and isolated instead of socialised. **The minimalism is the
safety argument**, and it is also why two people can hold this system in their heads well enough to
audit it honestly.

---

# Part 4 — What we tried and rejected

This section exists because the path matters. A product arrived at on the day it was written is a
hypothesis; a product arrived at after eight rejected alternatives, each killed for a stated reason, is
a conclusion. Everything below was built or seriously scoped and then deleted.

## Synthetic real-world assets (the legacy repository)

An engine for trading synthetic stocks, currencies, metals, commodities and rates on Solana: 9,750 lines
of Rust, price-oracle maps across 935 US tickers, 101 currency pairs, five European equity venues, each
asset class with its own leverage ceiling and minimum fee. Internally, the Ostium killer.

**Killed by the market, and then by me for months after.** Neither Robinhood's chain nor Kraken's
xStocks existed when we started. Both arrived mid-build and both are a better answer for the same
customer, because they hold the licences and the distribution and a two-person team does not out-execute
that. Nobody trades a synthetic Deutsche Telekom on our venue once Kraken sells the real tokenised one.
The failure was not misjudging the market; it was continuing after the market had answered, because the
implementation was elegant and my hands were in it.

## Depeg prediction markets (the legacy repository)

Roughly 1,900 lines implementing a jury and arbitration system over a Go service handling evidence
verification and deterministic resolution, dual-encumbered one-to-one, with the no-incident side stood
up from basket capital to solve the chicken-and-egg of having no bettors and therefore no insurers.

**Killed on the merits.** The no-incident dollars *are* the dollars backing QD. When an incident
resolves and the incident side recovers funds from them, those dollars leave the basket and are no
longer there to redeem at maturity. The same dollar cannot both back a redemption and settle a claim. It
is pro-cyclical, firing during a depeg when the basket is already impaired, draining backing exactly
when it is most needed. And it un-socialises a loss that was already fairly socialised, because the
basket's fair-value redemption **is** the depeg absorption and every holder eats the same proportional
haircut, so a market payout makes bettors whole while everyone else absorbs it. The court and jury
resolution layer also failed on latency, since voter response outruns relevance.

**What survives:** the depeg *signal* layer, which needs no bettors, and diversification. The only
non-broken insurance variant would need external segregated reinsurance capital flowing into the basket
on an incident, which is a different product and not this one.

## The surplus-funded make-whole (current repository)

`arbETH` bought back an exiting depositor's shed ETH at the time-weighted price out of the basket's free
surplus, so the rebalancing loss landed on the shared cushion rather than on the person leaving. It was
the design thesis for about eight months and carried a full economic study: a backtest over 3,215 daily
observations plus five-minute data through the March 2020 crash, a measured concentration constant, and
a solvency table.

**Killed because the study answered the wrong question.** Surplus is total value minus committed, which
is what we owe back to everyone. Spending it to make one exiting depositor whole compensates whoever
moves first at every other claimholder's expense, and it fires hardest during the stress when the
cushion is thinnest. It is the same first-out-at-par pattern the redemption path had already been
hardened against, rebuilt one layer up without noticing. Removed along with `refillETH` and the Bitcoin
equivalent, which was permissionless and griefable besides.

## The boundary-order ratchet (current repository)

Peeling in-range capital into a one-sided order that re-arms on fill. Tested across geometric Brownian
motion, Ornstein-Uhlenbeck, real-data variance ratio, real-data breakeven, and the Bitcoin delivery
model. **Spread capture was approximately zero in every one.** Removed as inert machinery. The only real
lever it exposed, how much asset to put in-range versus hold at the venue, is a deposit-time sizing
choice needing none of the apparatus.

## The below-entry short leg (current repository, July 2026)

Built as the symmetric half of the loss protection, then deleted for the reason in Part 1's contrarian
answer: it realises down-side loss and forfeits the recovery, so holding strictly dominates for a
long-biased depositor over any round trip.

## Mortgage origination and cross-border lending

Scoped seriously, then narrowed to a much later step. The reasoning is worth keeping because it is the
same wall every subsequent idea hit.

**Against a deposit-funded bank you lose on rate and it is not close.** A bank funds a mortgage on
insured deposits at two to four percent; our cost of funds is depositor yield at six to eight. The
genuine edge is against hard money and private credit, where the incumbent raises at ten to fifteen
percent net and lends at eleven to fourteen plus points. That edge is real and unaffected by any of the
research below.

**But the route to it narrowed four times in one day of research.** A licensed originator must retain
genuine risk, because the May 2026 OppFi decision holds that at origination the entity which funds,
controls underwriting and bears risk is the true lender, so a riskless conduit hands the licensing
obligation back to whoever funds it. Colorado and Oregon are opting out of federal rate exportation and
multiple legislatures are codifying true-lender tests. Directive 2021/2167 turns out to be a
non-performing-loan framework rather than a performing-loan passport. And CRD VI bans third-country
undertakings from lending into the EU without a licensed branch from 11 January 2027, with the
grandfathering window having closed on 11 July 2026.

**Origination itself is a company, not a feature.** The individual licence is a formality: twenty hours
of education, one exam, fingerprints, a credit review, roughly two thousand dollars, three to six
months, and worth holding personally because it makes you credible with partners. The company licence
is state by state with no federal option, twenty to fifty thousand dollars each in fees, bonds and
legal, six to twelve months each, minimum net worth and surety bond per state, and control-person
diligence on every ten percent owner. **The blocking requirement is the qualifying individual**: states
demand a designated person with three to five years of documented origination *management* experience,
not substitutable by competence, so you hire before you can file. And the licence is the cheap part
next to TRID disclosure generation, ability-to-repay determinations, HMDA reporting, fair lending, the
originator compensation rule, quality control and examination readiness.

**Verdict:** the licence buys nothing a partnership does not already provide at any volume in sight.
Property credit stays as the direction after there is a balance sheet worth an originator's attention.

## Automobile lending

Better than mortgage on the technology and worse on the fit.

**Valuation is solved**, which removes the one dependency our own funding application names as a kill
condition. A VIN and an odometer reading give Black Book, Kelley Blue Book and Manheim auction prints:
real transaction data on a liquid secondary market, quoted publicly, refreshed weekly. Enforcement
collapses from months to days through self-help repossession under UCC Article 9, deleting most of the
servicer-risk story. Effective duration of two to three years matches the liability ladder better than a
thirty-year mortgage does. And electronic lien and title systems fit the registry-anchoring machinery
better than land registries do, being already electronic, structured and continuously updated. Smaller
tickets diversify a portfolio faster and tell you whether underwriting works in months rather than a
decade.

**Against it:** depreciating collateral, negative equity routinely rolled into new loans so
loan-to-value above one hundred percent is normal, recovery around half, loss frequency far above
mortgage, and endemic fraud through straw purchases, odometer tampering and title washing.

**And the correction that killed it as a "lighter" pilot:** consumer credit is *more* regulated than
commercial property lending, not less. Truth in Lending, Regulation Z, ECOA, FCRA, state usury caps and
direct CFPB authority all attach. **Origination requires a state licence, and in many states so does
merely purchasing retail installment contracts**, with the assignee inheriting Holder Rule liability for
claims against the dealer. Distribution does not clear licensing here the way it does elsewhere.

Verdict: a good pilot for the machinery, wrong as the business, and off-thesis besides. Subprime car
paper is consumer credit underwriting with different staff, different failure modes and a reputational
weight that sits badly beside a product for a child's savings.

## Unsecured lending and a credit card

The proof stack establishes that someone is real and owns things. **It says nothing about willingness to
pay**, which is what a credit score measures and what drives unsecured loss rates. A provably genuine
citizen with a provably owned apartment abroad can simply stop paying, leaving no collateral and a
judgment unenforceable in their jurisdiction. The assets-abroad fact is simultaneously the underwriting
story and the collections nightmare.

A card cannot be issued without a bank, because network membership requires being one or renting a BIN,
which is why every fintech card names an issuing bank on the back. Regulation B requires adverse action
notices with specific reasons, and an underwriting model keyed on foreign assets and citizenship invites
a disparate-impact test on national origin, where expanding access to a rejected group is a good story
and not a legal defence.

**The funding premise was backwards.** A bank funds on deposits at zero to five percent; we fund at
depositor yield. Charge-offs run three to four percent prime and eight to twelve subprime. Recovery on
charged-off unsecured debt is ten to twenty percent, so **collections is the margin rather than
trimmable overhead**, and a minimal collection stack makes the economics worse rather than cheaper.

**What survives is collateralised spending**, where the loss rate goes to near zero because we hold the
claim to the collateral, so ten percent undercuts a twenty-two percent card while being structurally
more profitable. That product is now Exodus's, which is why the recommendation is to supply them rather
than race them.

## The riskless intermediary, and the metaphor that produced it

The idea that a local bank could act as a hop, originating to residents it alone may serve and passing
the loan onward without taking risk, has a name and a specific failure. Under the true lender test, a
bank taking no risk is not the lender.

**The deeper error is that the hop metaphor inverts.** "Hop" has been used consistently for the
Lightning routing node, for intent hops, and for the financial intermediary, and in Lightning the
pattern works precisely **because the hashlock makes a riskless pass-through atomic and trustless**. The
hop cannot steal and cannot be blamed exactly because it holds no position. Risklessness is the safety
property.

In regulated finance the identical structure is what regulators attack: rent-a-charter, true lender,
conduit doctrine. **The risklessness that makes a Lightning hop safe is what makes a financial hop
collapse.** Every workable version requires the intermediary to hold real risk, which is the opposite of
a hop. The mortgage originator retains a slice. The surety keeps underwriting exposure. Reasoning from
the metaphor produces structures that look elegant and are legally void, and the same word is correct in
`BTCChannels` and misleading everywhere else.

## Three assertions corrected during this process

Recorded because the wrong versions were repeated confidently before anyone checked.

**Land registers are not notary-gated where checked.** Ukraine's State Register of Real Property Rights
has been open to any natural or legal person since 1 January 2015, explicitly public and paid, searchable
online after authenticating with your own passport and tax number. US county recorders publish deeds and
liens, name- and parcel-searchable. HM Land Registry sells a title register for a few pounds. Three for
three against the premise. **What survives is that notaries gate writing, not reading**: registering a
consensual mortgage is a constitutive legal act only they can perform, and reading a register is a
lookup.

**A US-resident founder does not automatically trigger CFC and GILTI.** A Cayman foundation company can
be constituted with no members, and Subpart F attribution requires US shareholders holding more than
half by vote or value. With nobody holding either, the machinery does not engage, and corporate default
classification keeps the foreign grantor trust rules out. **The exposure that survives is management and
control**, independent of ownership.

**"No secondary market" was wrong.** Insurers, mortgage REITs and specialty finance are increasingly
prominent whole-loan buyers, and cross-border broking platforms exist. What remains unestablished is
whether anything trades *below* the securitisation threshold, which is the gap the verification stack
would open.

## And one thing the research vindicated

The claim that information barriers are not the bottleneck was **too strong**. The European Commission's
own White Paper on mortgage credit integration names them explicitly: fragmented credit registers,
inconsistent valuation practices, disparate land registry systems, and registers not provided in foreign
languages. Its operative sentence is that mortgage banks have difficulty assessing the information they
receive and therefore do not risk lending on property in another Member State.

That is a verification problem and it is what the identity and title stack solves. **The honest position
is that solving it is necessary and not sufficient**, because licensing, enforcement variance and
currency-risk regulation sit on top and cryptography moves none of them.

---

# Part 5 — The instrument, and what it is for

## What is QD, precisely?

A claim bought at a discount that matures on a calendar. Pay $1,850, hold $2,000 of face maturing in
twelve months, with the forward yield priced in at entry through the mint function. One token contract
holds many dated series.

Verified against the mint path: the normalised amount at mint equals the deposit plus an accrual term
scaled by the chosen maturity and either the fixed seed-tranche rate during bootstrap or the live
observed average of constituent-vault yields afterward. **One dollar deposited was never literally one
QD minted**; the accrual is priced in at entry.

## What is it not?

**Not a bill of exchange or a bankers' acceptance**, and this matters beyond pedantry.

A bill is an **unconditional order to pay a fixed sum** on a determinable date, and unconditionality is
exactly why a bill is discountable and acceptable as collateral. QD fails both tests. Redemption is
`min(solvent / matureSupply, par)`: capped at par, and able to fall below it for three documented
reasons.

**A constituent stablecoin depegging**, a per-stable native-value haircut. **A constituent vault
genuinely losing money independent of any depeg**, which the metrics code names explicitly as its own
separate solvency-reducing path, being an ordinary realised-versus-assumed shortfall rather than
anything venue-specific; the seed tranche's own projected bootstrap rate is one liability that same
shortfall can be measured against, the way an insurer's claims can exceed a too-optimistic premium
projection. And **illiquidity as distinct from insolvency**, a separate deliverability haircut where
funds are solvent at par yet not currently withdrawable, which defers rather than destroys value because
the unserved balance is retained as a live deferred claim and paid once liquid.

**The floating downside is load-bearing and deliberate.** It is what distinguishes QD from a
par-redeemable payment stablecoin, whose regulatory definition turns on fixed-value convertibility, and
it keeps the fund-share framing alive. See Part 6. **QD must therefore never be described externally as
a bill, an acceptance, or any fixed-sum obligation.** The accurate analogue is a defined-maturity fund
share that matures on a date and returns net asset value. A draft of the fundraising application used
the bill framing on 2026-08-01 and was corrected the same day.

## What is the product built on it?

A claim like this is worthless to someone who needs cash today and valuable to a counterparty who only
needs the money on a date they already know. That is a large, dull category: money you must post now and
get back later.

**US residential security deposits total around forty billion dollars sitting idle.** An industry
already attacks it, mostly through surety bonds that landlords already accept, so nothing changes at the
point of sale. **The incumbent's weakness is that the renter's fee never returns**: one provider charges
17.5% of the deposit amount, others 20 to 50%, so a renter facing $2,000 pays roughly $350 and owns
nothing afterwards.

**Partial collateral, not full.** A renter who could post $1,850 could post the $2,000 deposit outright,
so a fully collateralised bond serves a customer who does not need it, since deposit alternatives are a
*liquidity* product rather than a cost-saving one. What works is posting a smaller maturing claim so the
surety writes the bond at a premium well under the incumbent's, partly secured and partly underwritten.

**And the buyer is a surety that DECLINES thin-file applicants.** A surety bond is a three-party credit
product with a right of indemnity against the principal, and the premium compensates for pricing that
risk. Removing the risk from a bond they already write only compresses their margin. Collateral lets
them approve a segment they currently reject, which is revenue they do not have rather than revenue they
would cannibalise.

The same shape covers escrow against a set closing, bid bonds, and utility deposits returned after a
year of payment history, all of which have genuinely certain release dates. **Security deposits are the
weakest of the group**, because early termination through eviction or a break clause breaks the date
match, though most jurisdictions settle at move-out which mostly aligns.

**It needs no notary, no title, no lien and no registry**, and that absence is why it is more deliverable
than everything property-based.

## Why is this best for the liquidity providers specifically?

Provider revenue is venue yield, trading fees, and the retained scarcity premium, all of which scale
with deposits and swap flow. Lending does nothing for a provider directly; it raises the basket's yield,
which sets the bond coupon, which attracts dollar deposits, which fund the provider's dollar leg.

**So the chain that matters is demand for QD from people who are not crypto natives.** A renter posting
a deposit is not chasing yield and will not leave when a competitor offers fifty basis points more. That
is the most durable deposit base available and it is worth more to a provider than any lending margin.

## What decides whether it exists?

**Admitted assets.** State insurance regulators define what a surety may hold as collateral, and a
crypto basket claim is almost certainly not on the list. The workaround is a third-party trust holding
the collateral with the surety taking a pledge or letter of credit, which adds a party and a cost. This
is the first call to make and it is a counsel call.

**The haircut.** Because redemption is capped at par with a floating downside, the collateral needs a
haircut, so the renter posts more and the margin narrows. Model it before pitching, because a bond
underwriter asks in the first ten minutes.

**Liquidity on claim.** The instrument is illiquid until maturity by construction, and a surety needs
collateral it can reach when a claim lands. Early redemption is clamped to what has matured, so an early
draw recovers less than face. Partial collateral plus a maturity set inside the lease term mitigates it.

**Distribution.** The incumbents sell to **property managers**, who choose which alternative to offer
renters. A surety partnership still leaves that gate shut.

**Pledge perfection.** Some civil-law jurisdictions require notarisation and pledge-register entry to
perfect a security interest over a claim, which is a different notary function from the property-title
one. In the US a pledge of an investment property is perfected by control under the UCC, with no notary.

## Where does the payee-of-record model fit?

Our compliance thesis describes a fleet model where a customer's private funds settle with us
cryptographically and we fulfil the purchase ourselves as the KYC'd party using our own prepaid
instruments and merchant accounts. That is structurally identical to a pattern already in the codebase:
synthetic sats minted only against cryptographically attested real Bitcoin, where the real attested
position sits on one side and what circulates is an internal claim reconciled against it.

**The line that decides money-transmitter exposure is narrowness.** Buying a *specific good and
delivering it* with pre-funded customer money resembles a merchant or an agent of the payee. Providing
*general spending power* resembles money transmission plus prepaid access. Any crypto-to-fiat conversion
in the flow is money transmission on its own, with registration and state licences. This is already the
highest-leverage counsel question in the compliance thesis.

## Could we prove income the same way we prove identity?

Not with what is built, and probably not needed.

**The runtime environment covers public authoritative sources completely** — every node fetches the same
bulk export and must agree byte-for-byte, which is the right shape for a notary register or a sanctions
list, and no external vendor is needed for that class.

**It cannot reach income, structurally.** Identical aggregation requires every node to fetch the same
data, and payroll and tax data sit behind per-user authentication, so reaching it would mean handing
every node the user's credentials. There is nothing to agree on when the data is a private authenticated
session.

**Passport proofs work because the issuing state signs the document.** The tax authority does not sign
W-2s, so no equivalent proof exists. The mechanism that would work is zkTLS or web proofs, where a user
authenticates in a real session and a notary attests to what the server said without the verifier
learning credentials. Two caveats: a different cryptographic primitive from anything built, so net-new
work; and a weaker guarantee, since it proves what a server responded in a session the user controls
rather than a state signature over a chip.

**And it is probably unnecessary**, because income verification without disclosure only matters if no
party may hold the file. Under a distributor model a licensed originator verifies income conventionally,
with consent, because that is their job and their liability.

## If we ever do property credit, who forecloses?

The originator does, and not because they still own the debt. **Servicing is a right separate from
ownership**, and it is how every whole-loan sale works: the large agencies own trillions in notes and
have never foreclosed on anything, while the servicer does it in the owner's name under a servicing
agreement.

Three roles, deliberately separated. The **economic owner** is the reserve, taking cash flows and
bearing credit loss. The **record lienholder** is a named legal person, because a registry records a
charge in favour of someone who exists and a smart contract is not a person: either the originator holds
the lien as nominee, which is precisely what the US mortgage registry system does, or a special purpose
vehicle is the record holder and the reserve holds a beneficial interest. The **servicer** collects and
enforces, which is how the originator keeps earning after selling the paper.

**Refinancing makes this cleaner rather than harder.** A refinance discharges the old lien and records a
new one in first position, a fresh notarised act, so the correct beneficiary is named at origination.
Chain of title breaks down in *assignment*, not origination, and the entire post-2008 foreclosure mess
was securitisation trusts trying to enforce liens they could not prove had been properly assigned.

**The privacy design is consistent with this.** On default the reserve cannot identify who to sue,
having never received the file, and does not need to, because the servicer holds the dossier and the
standing. The contract holds the beneficial interest, receives payments, and marks a loan delinquent
against a schedule it already knows, which is the event that instructs the servicer. Enforcement happens
in a courthouse.

**What it gives up, stated rather than buried.** A human enforcement path with human failure modes, the
sharpest being servicer risk: a servicer who is captured, insolvent or unwilling stalls recovery on
paper we cannot enforce ourselves. Two standard mitigations belong in the agreement, a backup servicer
designated in advance and an irrevocable power of attorney signed at the start.

**More important than the foreclosure mechanics:** the reserve should mostly not hold defaulted loans at
all. Whole-loan purchase agreements carry representations and warranties with a repurchase obligation,
so a loan that defaults early or where a representation about title or valuation proves false goes back
to the originator at par. That keeps their capital behind exactly the inputs cryptography cannot verify.

## Why is the privacy layer there at all, if the lender must know the borrower?

It hides nothing from the lender. **It is about the asset reaching investors without the file following
it.** An ordinary securitisation ships loan-level data to investors in enough detail that
re-identification is routine. In ours the originator keeps the dossier and what reaches the reserve is a
proof of genuine title, first position, and ratio within limits.

The same mechanism keeps a household's position off a public ledger, and lets anyone confirm a parcel is
not already pledged without a shared database of who owns what. And there is a finding worth keeping
from the registry research: **in Ukraine the requester must identify themselves and every query is
logged**, so a lender screening applicants builds a state-visible trail of everyone it investigated,
whereas an owner querying their own record discloses nothing new. That argues for owner-side querying
better than the original reasoning did, and it needs no notary.

---

# Part 6 — Legal and regulatory

Nothing here is a legal opinion. It is the technical and factual case a lawyer needs to form one.

## What are the entities?

QU!D LTD is a BVI entity owned by Quid Labs, a Cayman IBC whose parent is the QuidMint Foundation. The
entities were founded on the cusp of the Terra crash, with first-hand experience of collateral damage:
under FASB ASC 958 nonprofit accounting principles, accumulated deficit exists on the balance sheet as a
documented liability against future operations.

Bebop.xyz chose a name representing intent-based hops, after bebop jazz replaced the big band's arranged
harmony with improvisation over complex chord changes at high tempo. Every stablecoin in the basket is
in a *quid pro quo*: mutual redemption pressure relief, peg stability. The Signal Foundation started on a
promissory note; on similar terms, MetaWeb Capital backed a meta-stable.

## Does the GENIUS Act apply?

The Act addresses a specific documented failure mode: issuers holding reserve assets external to the
stablecoin itself that could fail to maintain one-to-one backing under stress. The question is not
whether QU!D qualifies as a permitted issuer, or whether any other design could be better qualified.

The basket generates no endogenous yield, only exogenously through Uniswap, Aave, Morpho and the
stablecoin vaults. It is closer to an ETF or money market fund share, aggregating existing monetary
instruments issued by third parties into a redeemable unit. The pass-through yield originates from each
constituent issuer's own reserve income: a monetary premium here, a savings rate there, a funding basis
elsewhere. This aligns with the CFTC's historical treatment of basket instruments backed by physical
commodities, and with recent SEC staff guidance distinguishing utility from investment characteristics.

Section 3(a)(1)(A) of the Investment Company Act defines an investment company as an issuer primarily
engaged in investing in securities. Whether basket-constituent stablecoins are securities for that
purpose is itself unresolved, because the GENIUS Act explicitly excludes compliant payment stablecoins
from the security definitions under both the 1933 and 1934 Acts. **If the constituents are not
securities, the primary classification trigger does not apply.**

Depositors commit capital today and receive a claim on future value, sized at entry, contingent on the
basket's performance over the maturity period. Discounted-cash-flow secondary pricing insinuates a
warrant-like resemblance: a locked claim trading at a discount to face as maturity approaches.

## What about the proportionality constraint?

Section 4(a)(1)(A) requires that capital requirements *"may not exceed what is sufficient to ensure the
permitted payment stablecoin issuer's ongoing operations,"* and liquidity standards *"may not exceed
what is sufficient to ensure the ability of the issuer to meet the financial obligations of the issuer,
including redemptions."*

These constraints are in the statute because the regulation targets a gap that does not exist for QU!D.
QU!D addresses the regulatory concern more completely than the Act's own requirements do, which makes
the compliance apparatus proportionally lighter rather than inapplicable.

Hayek's argument in *The Use of Knowledge in Society* (1945) is that no central authority, regulator or
auditor included, can replicate what a price mechanism does: aggregate dispersed private information
held by millions of actors who each know something the others do not. A PCAOB-reviewed monthly
attestation is a central authority making a backward-looking determination. It tells a regulator what
the reserve composition was at a point in time. It cannot tell a regulator in real time whether that
composition is adequate given current market conditions.

> **⚠️ SUPERSEDED.** This argument previously continued into a proposal that a depeg prediction market
> would operationalise reserve sufficiency continuously. **That mechanism was removed from the design
> and the argument should not be revived** — see Part 4 for why it fails on its own merits. The Hayekian
> point survives as an argument about the limits of periodic attestation; it no longer has a mechanism
> attached. Depeg protection today is diversification across eleven constituents and nothing else.

## What is the tranche, in regulatory terms?

Section 4(a)(1)(A) sets a ceiling on what regulators can require. It is a constraint on regulatory
overreach, not a definition of what capital reserves are for.

**The tranche is not a capital reserve in the regulatory sense at all.** It is a cost-recovery mechanism
for a documented accounting loss. Collateral damage absorbed in the course of research and development
is projected to be fully amortised as part of fair launch.

From the basket's perspective it represents a senior liability to seed funders, structurally
subordinating regular depositor claims below it at the accounting level while preserving those
depositors' dollar-equivalent redemption guarantee intact, because the peg is fully maintained on their
portion excluding the tranche.

From the moment the accumulated deficit is fully amortised, preferential treatment in the mint function
ceases to exist. It is not fee income, not yield extraction, and not profit distribution. It is a
restoration of the entity's net asset position to zero, which is the definitional objective of nonprofit
accounting. **No profit is generated until the deficit is fully recovered, and the tranche is sized to
achieve exactly that recovery and no more.**

Mechanically it is an issuance spread, the difference between the dollar deposited and the QD issued,
standard in any instrument with a spread between issue price and face value. The liability column is not
simply deposited value set aside: it is QD minted on underbacked terms, with seed funders receiving the
multiplier without that QD being fully backed at the time of minting. **The QD exists as a liability
before the backing exists for it**, and the asset column is what capitalises that underbacked liability
and makes it whole over time. The two legs existing simultaneously is what allows the mechanism to work.

The breakeven structure also does something Howey analysis alone cannot: **it removes QU!D from the
category of entities with a profit motive with respect to the basket's output.**

## Does the yield prohibition at Section 4(a)(11) bite?

> *"No permitted payment stablecoin issuer or foreign payment stablecoin issuer shall pay the holder of
> any payment stablecoin any form of interest or yield (whether in cash, tokens, or other consideration)
> solely in connection with the holding, use, or retention of such payment stablecoin."*

The prohibition exists for a reason the CSBS implementation comment letter articulates: to
"disincentivize the holding of large uninsured stablecoin balances, which could trigger deposit flight
out of the banking system." The concern is issuers using their own reserve income to pay depositors
returns that make stablecoins function as uninsured deposit substitutes.

The basket holds yield-bearing instruments generating income under the independent governance of those
instruments' own protocols. QU!D holds them without discretion over their rates and without risking its
own capital to produce them.

On minting, depositors accept a binding surrender of redemption optionality for a defined term, which is
precisely the material economic risk the CSBS letter identifies as the permissibility threshold: *"any
payment should require a holder to engage in effort or accept risks beyond the ordinary course of
holding, using, or retaining a payment stablecoin."* The depositor accepts illiquidity, basket
composition risk over the lock period, and secondary-market exit at discounted valuation as their only
early liquidity, alongside productive deployment as collateral.

**And the redemption correction strengthens this rather than weakening it.** Mature redemption is
capped-at-par with an uninsured downside below par under basket stress, from any of the three causes in
Part 5. That is a real additional material risk beyond ordinary stablecoin holding. **It is precisely the
kind of net-asset-value variability a genuine fund or ETF share carries and a par-redeemable payment
stablecoin structurally cannot**, because a payment stablecoin's core regulatory definition turns on
fixed-value convertibility. A structure whose redemption value can legitimately fall below par under
stress is further from that definition, not closer to it.

The upfront normalised allocation compounds the distinction. What depositors receive at entry is not a
current cash payment of interest. It is an accrued entitlement, a forward-looking claim on future basket
yield computed at entry and redeemable at the chosen maturity. The CSBS letter distinguishes "irregular
or unpredictable payments" from structured accrual entitlements tied to maturity choices, and a
depositor selecting a longer maturity accepts lock-up risk in exchange for a larger claim. **This is
option-like compensation for a commitment decision, in the category of allocation rights rather than
issuer payments.**

Arguments around "solely" are belt-and-suspenders. Section 17 is the reason the question may never need
litigating at all.

## How does the Howey and Section 17 sequence work?

Section 17 is not a substitute for the Howey analysis. It is a statutory roof built on top of a
successful prong-three defense, and the sequence matters because the payment stablecoin definition
contains a circular constraint: a digital asset that is a security cannot qualify, so Section 17 never
underwrites an attached real-world asset. **Howey must be resolved first.**

**Prong 1, investment of money.** Satisfied. Depositors exchange stablecoins for QD. This cannot be
argued away.

**Prong 2, common enterprise.** Likely satisfied under horizontal commonality, since all holders share
the same basket composition and performance pro-rata. This is pooling. The correct strategy is not to
contest it but to win decisively on prong three. By 2024 the SEC and the Southern District had
effectively collapsed prongs two and three into a single inquiry — whether profits depend on the
promoter's efforts — making prong three operative in any enforcement context.

**Prong 3, expectation of profits from the efforts of others.** The precise legal question is whose
*ongoing managerial efforts* are the undeniably significant ones, those essential to the failure or
success of the enterprise.

## What about the SEC's position on vault curators?

> **Sourcing caveat, load-bearing.** The Peirce statement (SEC newsroom, 22 July 2026, on crypto vaults
> and lending strategies) postdates the training data of the model that drafted this commentary. It works
> from a second-hand characterisation: that the SEC is examining the economic function of vaults and
> curators; that a curator deciding how other people's assets are deployed may be acting as a fund
> manager or investment adviser even when everything happens through smart contracts; that custodial
> versus non-custodial is not the axis of concern; and that what matters is whether a strategy is
> credibly rules-based or whether users rely on the judgment of an identifiable manager. **Read the
> statement before relying on any of this.**

The statement is the best thing that could have happened to this section, because it replaces a
subjective prong-three argument with an objective question about code, and QU!D can answer that one.

If the test is whether a strategy is credibly rules-based or whether depositors rely on the continuing
judgment of an identifiable manager, the question becomes: **after launch, what function can any person
call that changes where depositor assets are deployed?** The answer is none, and it is enforced rather
than promised.

The reserve's setup call renounces ownership. Every discretionary lever sits behind an owner gate, so all
of them die at that call: evacuation, vault assignment, price feed assignment, venue assignment. The band
contract renounces the same way. The basket's constituent set is fixed at deployment and cannot be added
to. The leverage venue allowlist is pin-once then frozen behind a flag the source itself describes as
matching the renounce-everything posture. The contracts are not upgradeable and have no administrator, so
changing allocation logic would require a new deployment and a voluntary migration by depositors.

**This is the distinction against a curated vault.** A Morpho or Euler curator holds *continuing*
discretion: they can reallocate tomorrow, into markets nobody has seen yet, and depositors rely on that
judgment prospectively. QU!D's allocation decision was exercised once, at deployment, and is now
unreachable by anyone including the deployer. The Howey argument already turns on *ongoing* managerial
effort, and this framing converges on the same axis from the adviser side rather than the security side.

**Two design decisions were made specifically to remove discretion, and they read as evidence of
intent.** The vault-health poke is permissionless and reads only ERC-4626 ground truth, comparing
convertible assets against maximum withdrawable. It can tighten and never loosen and it cannot re-quote
anyone's value. It replaced a graded haircut lever that was removed *because* it was owner-only. **A
system that deletes its own discretionary levers before anyone asks is making the rules-based case in the
strongest available form.** Separately, the yield venue is chosen per deposit by the depositor and there
is no setter, so what allocation discretion exists belongs to the depositor.

**A further argument runs from the entity rather than the code.** The Investment Advisers Act definition
at §202(a)(11) requires acting as an adviser **for compensation**. A memberless Cayman foundation whose
only extraction is a tranche sized to recover a documented accumulated deficit under ASC 958, and which
terminates at breakeven, has a weak compensation element. Code facts and entity facts point the same way,
which neither does alone.

**What survives, and should be disclosed rather than discovered.** The vault contract retains three owner
setters for the offramp position and the two leverage managers, and no renounce was found on it. **If the
intent is the renounce-everything posture the rest of the system takes, this is the gap to close before
launch.** The multisig over the enclave measurement whitelist governs which code may operate the Bitcoin
hop and moves no funds, a governance surface and not an investment-discretion one. The off-chain keeper
executes a closed-form target on opt-in positions isolated to the depositor's own external account, so it
selects nothing.

**Summary for counsel:** composition and allocation logic are frozen at deployment, the surviving
automated paths are permissionless and read objective on-chain state, and the discretion that remains is
over infrastructure rather than over where depositor money goes. Closing the vault setters would make
that claim complete.

### Verification trail, read from source 2026-08-01

| claim | location |
|---|---|
| Aux renounces at finalize | `evm/src/Aux.sol:598-604` |
| Vogue renounces at setup | `evm/src/Vogue.sol:309-313` |
| evacuate / setVault / setStableFeed / setAssetFeed are onlyOwner | `evm/src/Aux.sol:487`, `:497`, `:167`, `:191` |
| basket constituents fixed at deploy, no permissionless binder | `evm/src/Aux.sol:177` |
| lev venue allowlist pin-once then frozen | `evm/src/LevManager.sol:146`, `:208-210` |
| pokeVaultHealth permissionless, ERC-4626 ground truth only | `docs/informational/VAULT-WATCHER.md` |
| graded haircut removed because owner-only | `docs/informational/VAULT-WATCHER.md` |
| depositor picks venue, no setter | `evm/src/Vogue.sol:1277-1281` |
| Safe governs measurement whitelist only, moves no funds | `evm/src/AttestedHopRegistry.sol:47-53` |
| **Vault setters with no renounce found** | `evm/src/Vault.sol:355`, `:362`, `:372` |
| IL target closed-form, zero at or below entry | `evm/src/imports/LevMath.sol:109-125` |
| band width ±0.2%, not ±2% | `evm/src/imports/SwapLib.sol:831-838` |
| eleven stablecoins, BOLD last | `evm/test/Alles.t.sol:285-300` |

## How does the sequence conclude?

QU!D's efforts are limited to two moments: deployment, and initial liquidity attraction through the seed
funder mechanism. After those, QU!D makes no ongoing managerial decisions steering profitability,
certainly none materially more significant than the governance decisions of the constituent protocols
inside the basket.

The Ninth Circuit's 2025 decision in *SEC v. Barry* confirmed the operative test is whether the manager's
*ongoing* efforts steer the project toward profitability. Deployment and initial bootstrapping are ongoing
efforts until they are fulfilled.

The enterprise cannot be steered toward profitability by any managerial decision, because no decision can
accelerate or expand the recovery beyond what the tranche represents. **A promoter whose enterprise
produces no profit until a specific, documented, terminating threshold is crossed, and whose distribution
is enforced by contract rather than discretion, is not the kind of promoter prong three was designed
for.** During the seed phase the enterprise produces no profits; after breakeven the mechanism terminates
and there is no further extraction mechanism at all.

The secondary market severs the remaining thread. *SEC v. Ripple Labs* distinguished institutional sales,
where buyers relied specifically on the issuer's efforts, from programmatic secondary sales where
anonymous buyers cannot know whose efforts produce returns and therefore cannot form the expectation
prong three requires. Our discount-priced secondary market is analogous: buyers acquire an instrument
whose value is determined by basket mechanics and time-to-maturity, not by any managerial decision made
after deployment.

**The sequential conclusion.** QD fails prong three because returns are generated by the independent
managerial efforts of the constituent protocols. By non-security status it qualifies as a payment
stablecoin. Section 17 then converts that qualification into a statutory guarantee across six federal
statutes simultaneously: the Securities Act of 1933, the Securities Exchange Act of 1934, the Investment
Advisers Act of 1940, the Investment Company Act of 1940, the Securities Investor Protection Act of 1970,
and the Commodity Exchange Act. Section 17 also clarifies that permitted payment stablecoin issuers are
not investment companies, removing Investment Company Act exposure without relying on the 3(c)(1) or
3(c)(7) exemptions.

The structural arguments are not merely positioning. They are the conditions under which this logic holds
at every step. **Lose the prong-three defense and Section 17 never attaches. Lose the payment stablecoin
classification and the full securities analysis is inherited simultaneously.**

SEC Chair Atkins stated publicly in July 2025 that only a limited number of crypto assets should be
treated as securities under federal law, and the agency has dismissed many pending cases inconsistent
with current policy. The analysis should nevertheless be documented now precisely because enforcement
environments shift. **The architecture holds under the most demanding version of that analysis regardless
of who is enforcing it.**

## Is the PACE Act relevant?

Independently verified against the bill text, which remains a recently-introduced House bill, not law.
Treat this as a reasoned application for counsel to test.

PACE (Payments Access and Consumer Efficiency Act, introduced 2026-04-21, Reps. Kim/Liccardo) creates a
federal Registered Covered Provider category: qualified nonbank payment firms register with the OCC and
connect directly to Federal Reserve rails through a dedicated payments reserve account, bypassing the
sponsor-bank layer GENIUS-compliant issuers otherwise depend on.

**QD is very likely not a PACE-relevant registrant.** The category is built for payment stablecoin
issuers and payment firms moving fiat at scale under a fixed-value redemption model, precisely the
category the analysis above, strengthened by the redemption correction, argues QD is *not*. Forcing that
characterisation onto QD would cut against the fund-share positioning the rest of this section builds.
**PACE is not the basket's regulatory home and should not be pursued as one.**

Second-order relevance is real though: the basket's constituent issuers are more plausibly PACE
registrants in their own right. If they gain direct rail access their own settlement and redemption
improves, which passes through to the basket's yield and liquidity exactly as the pass-through framing
describes, benefiting QD holders with no action or registration by us.

## What did the lending research establish, legally?

**Licensing follows the borrower, not the lender.** Offshore incorporation exempts nothing. A
foundation-owned entity needs the same state licence a shareholder-owned one does, and true lender
doctrine has killed most attempts to route around it.

**A riskless intermediary does not work.** The May 2026 OppFi decision holds that at origination the
entity which **funds, controls underwriting, and bears risk** is the true lender. Conjunctive. The fix is
genuine retention, which EU securitisation rules already require at five percent for the same reason.

**CRD VI closes cross-border lending into the EU from a third country.** Article 21c bans third-country
undertakings from providing core banking services, expressly including lending for both consumer and
corporate borrowers, without a licensed branch. Transposition 10 January 2026; **grandfathering cut off
11 July 2026, already passed**; prohibition effective 11 January 2027. Exemptions are narrow and reverse
solicitation cannot support a business model. **OPEN:** whether the non-bank carve-out exempts a pure
lender that takes no deposits, since the EU credit-institution definition requires deposit-taking *and*
lending.

**Directive 2021/2167** creates a passportable regime for non-banks acquiring bank-originated credit, but
its confirmed scope is **non-performing** loans. **OPEN:** whether it reaches performing loans.

**Foreign-currency consumer lending is regulated scar tissue.** After the Swiss franc mortgage crisis —
Poland roughly 550,000 loans, €30 billion, 7.7% of GDP; Hungary two-thirds of household debt, around 28%
of GDP, over 90% in francs; instalments up 60% in Hungary and 50–100% in Croatia before the franc jumped
20% overnight in January 2015; Hungary force-converting the book in February 2015 — the Mortgage Credit
Directive permits foreign-currency consumer loans only with a conversion right or equivalent protection.

**Adviser custody shapes the distribution channel.** An adviser who takes custody of client crypto
requires a qualified custodian, and that is the principal legal reason advisers have stayed out of this
asset class. Our structure does not raise it, because the client self-custodies and the adviser receives
read access to a position verifiable on a public ledger. Single-family offices are generally exempt from
Advisers Act registration under the family office rule, which is why they are the realistic first channel
rather than a registered adviser. **A fiduciary cannot recommend an unaudited protocol**, so what is
available pre-audit is a letter of intent, not an allocation. **OPEN:** confirm the current custody rule
and any successor safeguarding rule, and the family office exemption, with counsel. Both are recalled
rather than researched.

**Entity and residency.** A Cayman foundation company constituted with **no members** has no US
shareholder to attribute ownership to, so Subpart F does not engage, and corporate default classification
keeps the grantor trust rules out. **The exposure that survives is management and control**, independent
of ownership: a US-resident director deciding from US soil raises effectively-connected-income questions,
and compensation is personal income wherever the entity sits. **PREREQUISITE, UNRESOLVED: is QuidMint
Foundation actually memberless, or does it have members with economic rights?** Both the tax analysis and
the Advisers Act argument turn on it.

---

# Part 7 — Go to market and honest readiness

## Which adviser says yes first?

**Not a mainstream registered investment adviser.** Recommending an unaudited, pre-mainnet protocol to a
retail client is a fiduciary breach. They would also need to amend Form ADV, get compliance sign-off, and
run diligence for which they have no framework. Chasing that firm wastes months.

**A family office**, single- or multi-family, serving households that already hold crypto. Generally
exempt from Advisers Act registration under the family office rule, so a fraction of the compliance
surface, and their clients are already asking what to do with idle ETH and BTC while the office has no
answer beyond "hold it."

**Or a crypto-native adviser**, a firm built specifically for digital assets, which solved the regulatory
posture years ago and is hunting for products rather than waiting to be sold to.

**The constraint that shapes the channel is custody**, and our structure sidesteps it, which is the
opening line rather than a footnote. **The economic hook is not the dashboard**: advisers bill on assets
under management, and a client's self-custodied ETH is invisible to their reporting stack, so it sits
outside the fee base entirely. Make it visible and reportable and they bring it under management and
charge on it. **You are not selling software, you are expanding what they can bill.**

**What is available pre-audit is a letter of intent**, not an allocation: "if this existed and were
audited, we would allocate for these clients." A commercial statement rather than a fiduciary act,
signable today, and precisely what an investor wants to see. Capa.fi's pledge is already this shape.

## Which surety says yes first?

The one that **declines** thin-file applicants today, because partial collateral lets them approve a
segment they reject, which is incremental revenue. Never the one already approving the applicant, since
removing risk from a bond they already write only compresses their margin.

Note the second gate: the incumbents sell to **property managers**, who choose which alternative to offer
renters, so a surety partnership still leaves that gate shut.

**Both conversations can produce paper before a single contract is deployed**, which is the argument for
having them now rather than after the audit.

## Deliverables, ranked by what can actually ship

1. **Intent venue listings** (Mach, Khalani, already committed). No licence, no product, no customer
   acquisition. Brings the swap flow that drives the retained scarcity premium straight to depositors.
   Needs a deployment and nothing else. **Fastest provider revenue in the stack.**
2. **The Liquity zapper.** Built. Earns the router spread on both legs inside someone else's product.
3. **QD as pledged deposit collateral.** Needs one surety partner and a counsel answer on admitted
   assets.
4. **Exodus.** They hold the rails and the state-by-state licences and are missing yield on unspent
   balances, which is exactly what the basket makes. Enter as the supplier.

## Does this document set make an undeniably strong investment case?

**No, and the gap is not traction.**

**What traction would prove:** the audit, mainnet, live deposits, whether providers actually beat simply
staking, whether the scarcity premium earns real money at real volume. All execution.

**What traction cannot prove, because nobody was ever asked.** The product changed four times in one day
of research: mortgage refinancing, auto, unsecured cards, deposit collateral. Every pivot came from
reasoning rather than from a customer. **No surety underwriter has seen the deposit product. No family
office has seen the dashboard.** Traction cannot validate a hypothesis nobody has tested.

**Two counsel gates sit on that product and both are binary.** If admitted-asset rules come back no, the
product does not exist at any level of traction.

**A fact about our own entity is unresolved** and the legal position depends on it.

**The vault contract retains three owner setters** while Part 6 argues nobody can change where depositor
assets go. That contradiction is in the code now, it is an afternoon's work, and it is the cheapest thing
on this list to fix.

**The twenty percent Bitcoin figure has no evidence behind it** and sits in a document reporting zero
live deposits. Traction would prove it; stating it beforehand is a credibility cost meanwhile.

**Ukraine, one founder, no redundancy.** More traction concentrated in one person in a war zone raises
the amount at stake rather than reducing the risk.

**Competitive and regulatory facts that do not move.** Exodus spent $175 million acquiring card
infrastructure and is licensing state by state into the collateralised-spend product. CRD VI closes on 11
January 2027.

**What the documents do establish.** That the technology is real, substantial and checkable in public
repositories, with real-stack regression tests against live protocol state rather than mocks. That this
team finds its own errors and retracts them in writing, which almost nobody does. That the
impermanent-loss work is more rigorous than the field's and the up-side-only conclusion is genuinely
differentiated. That the Bitcoin custody design is novel and verifiable line by line. That the legal
analysis is more thorough than most projects ever produce.

**That is a strong case that these are serious builders. It is not yet a case that a business exists.**

**The shortest path** is not more code and not more documents. One conversation with a surety underwriter
who declines thin-file renters, and one with a family office holding crypto for families asking what to
do with it. Either can produce signed paper before anything is deployed.

---

# Part 8 — Open questions

**Blocking, needing counsel rather than engineering:**

1. **Is QuidMint Foundation memberless?** Prerequisite for both the tax analysis and the Advisers Act
   argument.
2. **Does CRD VI's non-bank carve-out exempt a pure lender?** Five months to the prohibition.
3. **Can a surety hold a QD claim under admitted-asset rules, or does it need a third-party trust?**
   Decides whether the deposit-collateral product exists.
4. **Does payee-of-record fulfilment trigger money transmission?**
5. **CIMA and BVI FSC requirements for a prepaid-card fleet operator, and OFAC's direct extraterritorial
   reach.**
6. **Who bears liability for fuzzy name-matching errors in the sanctions-exclusion layer?**
7. **Confirm the current custody rule, any successor safeguarding rule, and the family office
   exemption.** The whole adviser channel rests on this and it was recalled rather than researched.

**Answerable from documents, not yet answered:**

8. Does Directive 2021/2167 reach performing loans, or stop at non-performing?
9. Read the actual Peirce statement of 22 July 2026 and confirm the characterisation in Part 6.
10. Is the Ukrainian extract signed with a qualified electronic signature, and is it verifiable off a
    published chain?
11. Does perfecting a pledge over a QD claim require notarisation and pledge-register entry in target
    jurisdictions?
12. Does a cross-border whole-loan market exist **below** the securitisation threshold, and if it is
    empty, is it empty for information reasons or legal ones?

**Inside our control:**

13. **Close the three vault owner setters, or record why they survive launch.** The one open item that
    materially weakens Part 6 and the only one we can fix unilaterally.
14. Model the collateral haircut the capped-at-par redemption requires, against the incumbent's 17.5%.
15. Reconcile whether the reserve would hold whole loans or participations, and who the record lienholder
    would be, if property credit is ever pursued.
16. Take a letter of intent to one family office and one crypto-native adviser.
17. Take the partial-collateral proposition to a surety's decline pile, haircut modelled first.

---

## Sources

Registry access: [ICLG Ukraine Real Estate 2026](https://iclg.com/practice-areas/real-estate-laws-and-regulations/ukraine/) ·
[Lexology, register became publicly available](https://www.lexology.com/library/detail.aspx?g=a93a73d1-c7a9-46a1-b2bd-2cd16299312b) ·
[WikiLegalAid, порядок доступу](https://legalaid.wiki/index.php/%D0%9F%D0%BE%D1%80%D1%8F%D0%B4%D0%BE%D0%BA_%D0%B4%D0%BE%D1%81%D1%82%D1%83%D0%BF%D1%83_%D0%B4%D0%BE_%D0%94%D0%B5%D1%80%D0%B6%D0%B0%D0%B2%D0%BD%D0%BE%D0%B3%D0%BE_%D1%80%D0%B5%D1%94%D1%81%D1%82%D1%80%D1%83_%D1%80%D0%B5%D1%87%D0%BE%D0%B2%D0%B8%D1%85_%D0%BF%D1%80%D0%B0%D0%B2_%D0%BD%D0%B0_%D0%BD%D0%B5%D1%80%D1%83%D1%85%D0%BE%D0%BC%D0%B5_%D0%BC%D0%B0%D0%B9%D0%BD%D0%BE)

True lender: [Consumer Finance Monitor on OppFi v DFPI](https://www.consumerfinancemonitor.com/2026/05/29/california-court-issues-final-statement-of-decision-rejecting-dfpi-true-lender-theory-against-oppfi/) ·
[NYLJ](https://www.law.com/newyorklawjournal/2026/06/18/true-lender-doctrine-and-opportunity-financial-llc-v-clothilde-hewlett/) ·
[Stinson, states codifying true lender](https://www.stinson.com/newsroom-publications-states-expand-regulation-of-consumer-lending-codification-of-true-lender-and-opt-out-of-didmcas-interest-exportation)

CRD VI: [A&O Shearman](https://www.aoshearman.com/en/insights/new-licensing-requirements-for-cross-border-lending-into-europe) ·
[Latham](https://www.lw.com/en/insights/crd-vi-implications-of-the-licensed-branch-requirement-on-lending-to-eu-borrowers) ·
[Crowell, the non-bank carve-out](https://www.crowellfintalk.com/2026/06/crd-vi-new-rules-for-cross-border-lending-into-europe-why-the-non-bank-carve-out-matters-but-is-not-the-full-story/) ·
[Ashurst Q&A](https://www.ashurst.com/en/insights/qa-on-the-third-country-branch-introduced-by-crd-vi/)

Credit purchasers: [European Sources Online, Directive 2021/2167](https://www.europeansources.info/record/proposal-for-a-directive-on-credit-servicers-credit-purchasers-and-the-recovery-of-collateral/) ·
[KPMG](https://kpmg.com/hu/en/home/insights/2023/10/the-npl-directive-new-playing-rules-for-credit-purchasers-and-servicers-in-the-eu.html)

FX mortgages: [European Parliament briefing](https://www.europarl.europa.eu/RegData/etudes/BRIE/2021/689361/EPRS_BRI(2021)689361_EN.pdf) ·
[WEF](https://www.weforum.org/stories/2015/10/how-should-european-economies-manage-their-foreign-currency-loans/)

EU barriers: [White Paper on the Integration of EU Mortgage Credit Markets, CELEX 52007DC0807](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:52007DC0807) ·
[Taylor Wessing](https://www.taylorwessing.com/en/insights-and-events/insights/2024/11/lf-cross-border-lending-in-the-eu)

Security deposits: [Second Nature, $40bn](https://www.secondnature.com/blog/security-deposit-alternatives) ·
[Brick Underground, the 17.5% fee](https://www.brickunderground.com/rent/security-deposit-alternatives-nyc) ·
[Buildium, surety bonds as alternatives](https://www.buildium.com/blog/surety-bonds-as-alternatives-to-security-deposits/) ·
[Shelterforce](https://shelterforce.org/2020/12/10/security-deposit-alternatives-the-misleading-marketing-of-renters-choice/)

Exodus: [CoinDesk on the 2026 payments app](https://www.coindesk.com/business/2025/12/09/crypto-wallet-firm-exodus-bets-on-stablecoins-for-real-world-payments-with-2026-app) ·
[Decrypt](https://decrypt.co/363947/exodus-pay-bitcoin-wallet-spending-app) ·
[CoinDesk on the Baanx card](https://www.coindesk.com/business/2025/05/27/bitcoin-wallet-firm-exodus-unveils-crypto-debit-card-with-baanx)

YieldBasis: [docs](https://docs.yieldbasis.com/user/how-it-works) ·
[Mirador](https://www.mirador.finance/p/impermanent-loss-and-how-yieldbasis-b10) ·
[Sentora](https://medium.com/sentora/impermanent-loss-no-more-how-yield-basis-reimagines-curves-crypto-pools-1b50b8aa5c6b)

Iran deployment of the identity base: [AlexaBlockchain on the Freedom Tool](https://alexablockchain.com/iranian-voting-app-to-protest-presidential-election/)
