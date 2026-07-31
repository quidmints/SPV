# Alliance application: answers

Written 2026-08-01. Every technical claim below was checked against the code in `quidmints/SPV`
and `quidmints/ibiza` before it went in. File and line references are given where a reader might
want to verify one.

---

## What is the problem you're solving?

We had a baby, and part of what that child inherits is already decided. The federally seeded account
opened at birth is locked into a US equity index, denominated in dollars, untouchable until they turn
eighteen. It's a good thing to have. It is also a concentrated bet on one country's equity market
that nobody in the family gets a say in for eighteen years.

The question I set out to answer was where the rest of a child's nest egg should sit so that it isn't
correlated to that, without handing it to a custodian and without the family having to become
traders. Every option available was bad in a specific, fixable way.

Hold BTC and ETH and earn nothing on them. Provide liquidity instead and pay impermanent loss, which
is what an AMM charges you for holding the wrong composition at every price: the position sells
whatever is rising and buys whatever is falling, so its value tracks √p while holding tracks p, and
by no-arbitrage the fees cover that gap and little else. Put the dollar half in one stablecoin and
you have made an issuer bet nobody can price, since a peg sits at 1.00 with overwhelming probability
until it jumps to a different regime, and the hazard is reflexive enough that the price of insuring
it feeds the probability of the event.

QU!D is what we built instead, and it does four things for that account. A depositor brings ETH or
BTC on its own and keeps their exposure to it, because the protocol funds the dollar side of the
position out of its own scheduled future yield rather than asking anyone to sell half their stack.
The impermanent loss the band creates on the way up is cancelled by an opt-in overlay borrowed on an
external, per-position isolated market, so the holder ends up with more of the asset than they started
with. Dollar yield comes from an eleven-name basket, because breadth is the only depeg protection
anyone can honestly sell. And the entry decision is informed by a regime read rather than a guess: a
Kalman bank estimating volatility, factor exposure and mean-reversion, feeding a classifier that
characterises the current market state without pretending to forecast price.

All of it lives on one dashboard, which matters more than it sounds. A family and its wealth manager
can look at the same position, the same exposure, and the same risk, and argue about it from shared
numbers. That is a family-office capability, and the families who most need it are the ones without
a family office.

The identity and privacy work in the second repository extends the same idea to the largest asset a
household actually owns. A homeowner proves control of their title and their income eligibility
without disclosing either, and borrows against it into an address that cannot be linked back to them.
Refinancing becomes something you do against a proof rather than against a relationship with a
licensed intermediary who can decline.

Two structural problems fall out of solving ours. Routing a Lightning payment means locking BTC into
a 2-of-2 channel that earns zero, which is why inbound liquidity has been chronically scarce for a
decade. Bootstrapping an ETH/USD position has always required someone to sell half their crypto to
fund the dollar leg. Both of those go away for everyone else the same way they went away for us.

---

## How did you learn about the problem?

Most recently, from becoming responsible for someone else's eighteen-year time horizon. Sitting down
with our wealth manager to work out where a child's money should go surfaced the gap immediately.
The dollar side of a family balance sheet has a hundred years of instruments built for it, and the
crypto side has spot custody and a shrug. Everything in this application is downstream of trying to
give that conversation something to point at.

Before that, I lost money the ordinary way. Three times long on NEAR between 15 and 23, about $350k of
collateral carrying 50,000 units, liquidated near 7. The equity went to zero. Nothing about that
trade was sophisticated, and the lesson wasn't about NEAR. It was that a static leverage ratio pays
for itself on the way down, which is exactly why our overlay unwinds to zero debt below entry
instead of holding a pinned 2×.

The protocol economics came earlier. In 2019 I worked on Bancor's frontend-incentivisation
governance, an affiliate-fee system that was the first working practice of what Uniswap and Liquity
later called sufficient decentralisation. My mentor Eyal raised the basket-of-stablecoins idea before
mStable was announced, and it sat unbuilt until Liquity's issue #6 gave it a setting. At Manifold
Finance I learned what MEV does to a passive quote, which is why our pool prices off an internal TWAP
cross-checked against Chainlink and never exposes a stale price for arbitrageurs to correct.

The Bitcoin half came out of a project that failed. lbtc.io shut down in 2019. The iOS app planned
then was called Ibiza, and it's where I met Craig Sellars and Brock Pierce at the beginning of
pre-seed. What killed it was custodial wrapping. I have been building the version without a
custodian since.

---

## Who has this problem, and how do they deal with it today?

**Families building a nest egg alongside a wealth manager.** They hold some crypto and a lot of
dollars, and the two halves live in different places with no shared view. The manager is comfortable
with the equity and the bonds and treats the crypto as an unmanaged line item, because nothing exists
that gives them a position they can supervise. What they do today is hold spot and hope, or buy an
ETF and pay for the wrapper, or hand a percentage to someone running a strategy they cannot inspect.

**Lightning liquidity providers.** Small operators lock sats into channels and earn routing fees that
don't cover the opportunity cost of the capital. Most of them just accept it, or they stop running a
node.

**Holders who want yield without selling.** They stake and take the base rate, or they LP and eat the
divergence loss, or they use a leveraged-LP product like YieldBasis that converts the holding loss
into a borrow cost plus liquidation risk. Retail gets pointed at dollar-cost-averaging products
(savewithcastle.com) or at copying Michael Saylor, neither of which is an entry strategy.

**Fund managers and treasuries with a depeg-resistance mandate.** They diversify by hand across
sUSDe, sDAI, USDC and whatever else, rebalancing manually, with no instrument that gives them the
whole spread in one position. Cork Finance built depeg swaps for exactly this group and shipped a
model that cannot work, because the risk it underwrites is undiversifiable and un-hedgeable.

**Bitcoin holders who want DeFi.** They wrap. BitGo's WBTC and Coinbase's cbBTC are at least honest
about being IOUs from a regulated counterparty, which is genuinely useful if your mandate requires
one. Lombard routes through Babylon, which exposes the staker to risks from the networks whose
security they're underwriting, and pays them around 2% for it.

---

## What have you built so far?

Everything described here is written, tested and running against forked mainnet state. None of it has
been audited and none of it holds real value yet.

**The reserve and band.** `Core`, `Vogue`, `Aux`, `Basket` and `Vault` run a Uniswap v4 position
whose token side is virtual, so the depositor's real ETH stays in its yield venue while the position
quotes and collects fees. The band is a ±0.2% range around the oracle price that repacks when price
leaves it (`SwapLib.sol:838`). Swaps price off the internal TWAP under an `onlyUs` gate, so there is
no stale quote to pick off.

**Single-sided deposits funded by a bond ladder.** QU!D is an ERC-6909 token with maturity buckets. A
dollar depositor gets their forward yield claim at entry, computed off the basket's weighted average
yield at that moment. During the first twelve months the protocol projects up to a year forward and
mints against yield that hasn't arrived yet, bounded by a hard 600,000 seed cap (`Basket.sol:25`,
enforced at `:291-307`). That forward dollar supply is what lets an ETH or BTC depositor stake their
whole position without selling half of it.

**IL protection, up-side only.** An opt-in overlay borrows a stable against the LP's own collateral on
an external market (Morpho Blue, Euler EVK sub-accounts, Aave V3 and V4 escrows, or a Liquity V2
trove), buys more of the volatile asset, and gives the band a buffer to sell instead of the LP's
principal. Target LTV is `1 − √(entry/now)` (`LevMath.sol:109-125`), which goes to zero at or below
entry. The keeper sizes to realized band concavity, so leverage is `L = 1/α` rather than a pinned 2×.
We wrote no liquidation engine, because the keeper de-levers a full safety margin below the external
venue's own liquidation line and that venue's engine is the never-triggered backstop.

**Native Bitcoin without a custodian.** Each LP's sats sit in a key-path MuSig2 taproot 2-of-2. The
EVM proves the funding UTXO and the close with a Bitcoin merkle proof against a header chain,
validated end to end against a live regtest node. An LP signs one cold EIP-712 delegation and then
runs nothing at all, with no node to host and no watchtower to keep alive. If the operator
disappears, a pre-signed
CLTV-timelocked exit whose raw bytes are already public on-chain becomes broadcastable by anyone,
with no key and no signing (`BTCChannels.sol:256-271`).

**Attestation instead of trust.** Which addresses may act as a hop is gated by an on-chain Intel DCAP
quote, verified by Automata's Trail-of-Bits-audited verifier, proving the hop's EVM key was born
inside a whitelisted enclave measurement. A Safe governs that whitelist and the revocation list and
moves no funds. The value-moving contracts renounce ownership.

**Off-chain.** A Rust workspace (`quid-ln`) running the Lightning hop, the EVM mirror, the swap-in and
swap-out rails, and the leverage keeper, with SGX-enclave tooling.

**The privacy and identity stack (`ibiza`).** A Privacy Pools fork and Rarime's passport circuits
migrated onto one Noir/UltraHonk toolchain, 149 Forge tests green, with a treasury adapter that lets
shielded deposits earn without letting the yield venue's public event stream reconstruct the link
that the ZK proof exists to hide.

**Regression evidence.** `LeverageCrossSubsidyProbe.t.sol` runs a levered LP through open, lever and
venue liquidation on real Morpho with a real weETH/ETH rate and a real Chainlink feed, then checks at
a matched price that a passive LP's redeemable value and the basket's backing are untouched.

---

## How do you know people need this?

Capa.fi pledged future commitment in the form of basket TVL, and their CEO Juandi was our grants
liaison on behalf of Polygon. EtherFi focused our work on getting the most out of their UniV3 pool.
Mach and Khalani have both committed to list the basket as a venue for their intents, which matters
more than it sounds: it means order flow arrives without us building a destination app.

Two teams put non-dilutive money in during 2025, the Uniswap Foundation and Polygon Labs, on top of
friends and family. Two people agreed to hold keys in the deployer Safe: Paul, who I worked with at
Gauntlet after we met through Halborn in 2022, and Artem, who wrote the research paper on using SPV
proofs in DeFi with Distributed Labs and is now at Blockstream.

What we don't have is live TVL. The strongest demand signal we can point at is structural rather than
commercial: Lightning's inbound liquidity has been under-supplied for years for one reason, and it's
the reason we removed.

---

## How will you make money?

Quid Labs is wholly owned by the QuidMint Foundation, so the question is really how the protocol pays
for its own maintenance. Five things earn.

The inventory skew is the largest. When the pool is scarce in ETH or BTC, a swapper pays above the
oracle price for it, and the difference stays in the basket as backing rather than going to a market
maker (`Core.sol:259-285`). That premium steepens with realized variance and is capped at the real
cost a native-BTC desk bears while its capital is locked waiting on six confirmations.

The band collects ordinary v4 trading fees. Redemptions pay an outflow fee bounded between 3 and 30
basis points, shaped so that draining the basket's yield engine costs more than shedding a depegged
name. Our router takes a spread, and because `SorExchange` drops into Liquity V2's zapper as an
`IExchange`, we earn it on both legs of somebody else's leveraged trove. Underneath all of that the
reserve is lent across Morpho, Aave, sDAI and the Liquity Stability Pool, and that earns whether or
not a single person trades.

That last line is the one that matters for durability. The reserve earns with no volume, so there is
no cost floor that a quiet month falls below.

---

## How will you find more customers?

Every integration surface is permissionless, which means nobody has to do a deal with us.
`Vogue.deposit` and `Basket.mint` are plain external functions with no allowlist and no gate, so a
protocol that wants to route idle funds into the reserve declares a local interface and calls it. Our
own privacy stack integrates with us that way on purpose, holding our addresses as immutable
constructor arguments and importing none of our source.

For Lightning providers the wedge is that they run nothing. Signing one delegation and sending BTC
from Binance or Electrum is the whole onboarding, and the exit is enforced by Bitcoin's own timelock
rather than our willingness to serve them. That removes the barrier that has kept small operators out.

For flow, we're a venue inside other people's products. Mach and Khalani route intents to us, the
Liquity zapper calls our router from inside its flash-loan callback, and the ibiza wallet consumes
SPV as a submodule. None of those need us to acquire a user.

For the basket specifically, the buyer is a fund manager with a depeg-resistance mandate who is
currently doing the diversification by hand, and the pitch is a single position that locks up every
constituent at once.

The channel I care most about is the one we're using ourselves. An independent wealth manager
advising a handful of families has no supervisable crypto product to offer them and no appetite for
one they cannot see inside. Give that manager a dashboard showing exposure, regime and realised
yield across every client at once, and they carry us into every household they advise. One manager is
worth more than a hundred individual signups, and the pitch to them is that we take custody of
nothing.

---

## What is the biggest mistake that you've made so far?

I stayed on a dead product because the code was beautiful. The legacy repository is public at
github.com/quidmints/quid, so the size of it is checkable. Most of that repo is a
synthetic-assets perpetuals engine on Solana, roughly 9,750 lines of Rust, wired to Pyth across 935
US equity tickers, 101 FX pairs, and separate venues for UK, German, French, Dutch and Luxembourg
equities, plus metals, commodities, rates and staking derivatives, each asset class carrying its own
leverage ceiling and minimum fee. The internal name for it was the Ostium killer. When we started,
neither Robinhood Chain nor Kraken's xStocks existed. Both arrived while we were building, and both
are a better answer for the person we were building it for. They hold the licences and the
distribution, and a two-person team does not out-execute that.

Misjudging the market is forgivable. What I actually did wrong was keep going for months after the
market had answered, because the implementation was elegant and I had my hands in it, and I let that
substitute for a reason. Nobody was going to trade a synthetic Deutsche Telekom on our venue once
Kraken would sell them the real tokenised one.

The second mistake sits in the same repository. `Court.sol`, `Jury.sol` and `UMA.sol` are about 1,900
lines of Solidity implementing a jury and arbitration layer for a per-stablecoin depeg prediction
market, on top of a Go oracle with evidence verification, deterministic resolution and model
dispatch. The design was dual-encumbered 1:1, with the no-incident side standing up from basket
capital so it would never suffer the usual chicken-and-egg of having no bettors and therefore no
insurers.

It cannot work, for a reason that has nothing to do with the implementation. The no-incident dollars
are the dollars backing QU!D. When an incident resolves and the incident side recovers funds from
them, those dollars leave the basket and are no longer there to redeem QU!D at maturity. The same
dollar cannot both back a redemption and settle a claim. Worse, it fires during a depeg, when the
basket is already impaired, so it drains the backing precisely when the backing is most needed. And
the thing it was meant to add already existed for free: the basket's fair-value redemption is the
depeg absorption, and every holder eats the same proportional haircut. A market payout makes bettors
whole while everyone else absorbs it. Voter latency also outran relevance, which is a separate reason
the jury layer was never going to resolve anything fast enough to matter.

Both of those got cut, and the current scope around depegs involves no prediction market at all. What
survived is the signal layer, which needs no bettors, and diversification across eleven names, which
is the only depeg protection anyone can price.

There is a smaller repeat of the pattern in the current repository. We shipped `arbETH`, which bought
back an exiting LP's shed ETH at TWAP out of the basket's free surplus so the rebalancing loss landed
on the shared buffer. That was the design thesis for about eight months and it carried a full
economic certification behind it. Surplus is what we owe back to everyone, so spending it to make one
LP whole pays whoever moves first at every other claimholder's expense, and it fires hardest when the
buffer is thinnest. Removing it is why the LP now bears their own impermanent loss through the share
price, with the protection moved onto their own external book.

---

## Tell us something about your company that's not going well.

I am in Ukraine, and the war is the largest operational risk this company carries.

The cost of it is mundane and constant. Work stops when the power does and starts again when it comes
back. Anything requiring a physical presence, a bank, or a notarised signature takes weeks here that
it takes hours somewhere else, and getting out to a conference or a diligence meeting is a logistics
problem before it is a calendar problem. Hiring is close to impossible: the people I would want are
already abroad or already serving, and I cannot offer anyone still here the kind of stability a job
is supposed to come with. There is no redundancy in any of this. One person, in one place, holding
the work.

Ingrid splits her time with a worker-owned produce cooperative in Portland, so the second founder is
part-time by agreement rather than by drift.

The product-side version is plainer. No audit, nothing on mainnet, so live TVL is zero. Native BTC
leverage is a harder problem than the ETH side, because Bitcoin has no smart contracts and every
clean path runs back through WBTC, which defeats the custody model the whole thing exists for. I
would rather say out loud that it probably isn't worth doing than pretend the two sides are
symmetric.

The one thing I will claim for the architecture is that it was built by someone who assumed he might
not be reachable. Nothing runs on a server we own. The contracts are not upgradeable and have no
administrator, a depositor's reclaim needs nothing from us, and an LP's Bitcoin exit is a pre-signed
transaction whose raw bytes are already public, which Bitcoin's own timelock releases the moment our
heartbeat stops. Being here is also the reason the notary-registry work in the identity repo is built
against Ukraine's Ministry of Justice open data rather than against a hypothetical.

---

## How will the next LLM model release affect your business?

This codebase exists because of one. Ingrid's Claude subscription is what turned two years of
prototypes into a working system, and the volume of Solidity, Rust, Noir and Go here is not something
two people write by hand. A better model compresses the work we're worst at: reconciling documentation
with code, preparing for audit, and running adversarial passes over our own money paths.

The risk runs the same direction. A cheaper model means a competitor can read our public repositories
and rebuild the design, so whatever defensibility we have has to come from what is
actually deployed and integrated rather than from the source. It also means anyone probing
unaudited contracts for exploits gets better at it on the same schedule, which is an argument for
getting the audit done before the value arrives rather than after.

There's a third effect that cuts in our favour. Adversarial review used to be something you bought
from a firm at a price that gated small teams out. It is becoming something you run continuously. For
a two-person team without an audit budget, that changes more than it changes for a team with one.

---

## How do you use AI in your workflows today?

Concretely, and mostly as an adversary rather than an author.

**Testing by deletion.** We remove a safeguard and confirm the test then fails, instead of trusting a
green result. That caught two tests in the identity stack that had quietly stopped checking anything,
and it's how we found a proof binding to an unconstrained field, stale roots that let revocation be
evaded, and one parcel that could be titled twice.

**Differential verification against the real thing.** Every Noir gadget is cross-checked against the
exact on-chain function it will face. `lean_imt.nr` was checked against `@zk-kit/lean-imt.sol` for 46
randomized tree shapes covering every carry-up parity up to depth 8; `commitment.nr` against
`poseidon-solidity`'s own `PoseidonT2/T3/T4`. Compiling rather than merely writing the gadgets found
two real bugs immediately.

**Simulation to kill our own ideas.** `sims/measure_K.js` measured LVR on real five-minute COVID data
and came back at 1.84 with the manipulation guard on, against the 0.71 our own certification claimed,
so we now treat every K·σ² we publish as a conservative floor. `sims/leveraged_lp.js` showed a 2× LP
liquidating in 5 to 19% of historical ETH windows, which is why leverage lives on the LP's external
book. `sims/over_realize.js` produced a finding we then retracted, because the simulation was charging
a virtual repack as a real trade.

**Wide adversarial research passes.** The compliance work ran 105 sub-agents over 676 tool calls. It
ruled out the vendor we had assumed would be our accountable curator, and it caught us citing MiCA
Article 70 for something that article does not say (it's about custody, not identity). Both were
findings that would have surfaced in a lawyer's office at a much higher price.

**Auditing the documentation against the contracts.** Design notes go stale faster than code does,
and a stale paragraph is a trap for whoever reviews us next. Running that reconciliation as a
scheduled pass, rather than as something we remember to do, is how we keep the written record usable
by an auditor.

---

## Who are your competitors or alternatives, and why will you win?

**YieldBasis** pairs the volatile asset with borrowed crvUSD at a constant 2× to straighten √p into p.
That works, and it costs: half the trading fees go to the rebalancing budget, the borrow drags, a
crvUSD depeg cascades into every LP, and the static ratio pays releverage losses on every down-move.
Our debt sits on an external isolated market so QU!D never takes a socialized gap-tail, and it sizes
to the impermanent loss the flow actually created, unwinding to zero below entry. We are never holding
2× into a crash.

**Lombard and Babylon** pay a Bitcoin staker roughly 2% to underwrite the economic security of
networks whose risks they inherit. Our BTC LPs keep their own key in a 2-of-2 and earn band fees plus
native sats, while the coins keep doing their Lightning job.

**Cork Finance** priced depeg risk as if it were fire insurance. The base rate is unobservable, the
hazard is reflexive, the underwriting collateral is usually the same asset class being insured, and
the underlying gaps from par to 0.80 in minutes so there's no replicating portfolio. HIYA produces a
number; a number is not a price. We bound the risk by breadth across eleven names instead.

**Bunni** put a liquidity distribution function on a v4 hook that reshaped the pool after every trade
to hold the token ratio. Doing the arbitrage yourself removes the discrepancy arbitrageurs exist to
close, so the pool paid the rebalancing cost continuously while giving up the arb volume that
normally compensates LPs for divergence, and the hack lived in that per-trade accounting step. We
repack only when price leaves a ±0.2% band, and we let outside arbitrageurs pay us fees to do the
rebalancing.

**Pendle** splits a yield-bearing asset into PT and YT, prices PT on a time-decaying curve that has to
be re-anchored as expiry approaches, and fragments liquidity across every maturity. Our bond doesn't
split, because the yield accrues to the reserve and shows up in the scheduled redemption. Maturity is
an accounting stamp on one unified basket.

**mStable** is the only basket product in the category, and it routes to Pendle rather than deploying
the stables to Morpho or Aave, with no endogenous yield from trading them against each other or
against ETH and BTC.

What we do differently in every one of those comparisons is subtract. Risk gets bounded by
diversification rather than priced. One band around the current price replaces a continuous
distribution that has to be maintained. Redemption runs on a calendar. The debt lives outside our
balance sheet on a market that already has its own liquidation engine, so a bad position hits its
owner and stops there. Fewer moving parts is the whole safety argument, and it's the reason a
two-person team can hold this surface in its head well enough to audit it.

---

## What's something you believe about your market or approach that a smart, informed person would disagree with?

Below-entry impermanent loss should not be hedged, and hedging it destroys value for a long-biased LP.

Everyone building IL protection builds it symmetric, and a delta-neutral desk would say a hedge that
only works in one direction isn't a hedge at all. We built the symmetric version. Below entry, a short
leg restores delta-1 by selling the over-held asset into the fall, which converts an impermanent loss
into a realized one and forfeits the recovery. Over a round trip down and back up, the LP who did
nothing beats the LP who hedged, by exactly the realized leak, with identical fees. So the short leg
came out on 2026-07-24 and the target LTV now returns zero at or below entry.

The same logic kills soft liquidation. LLAMMA-style engines exist to sell collateral continuously as
price falls so a levered position never hard-liquidates. That caps further loss by crystallizing the
drawdown, and over a down-and-back-up cycle you sold low and re-levered high. Our overlay sheds debt
to zero as price falls, so it is counter-cyclical to liquidation risk and we never wrote an engine.

The related belief, which is more uncomfortable: we cannot win the fee war and shouldn't try. Cutting
the fee tier does not buy clean volume. It makes you the venue that CEX-DEX arbitrageurs correct
first and hardest when the off-chain mid moves, and that flow is the divergence loss. By no-arbitrage
the incremental fees it pays roughly equal the incremental loss it inflicts, so racing the tier down
grows both sides of `fees − IL` without raising the difference. The addressable number is the
uninformed, markout-neutral fee-paying volume, which is a fraction of headline pool volume and
shrinking as solvers internalize the easy flow off-pool. That's why our economics rest on the yield
floor under the whole stack, a bounded in-range slice, and a scarcity premium retained as backing,
none of which require winning flow we can't select.
