# QU!D — protocol specification

**One document. What the protocol is, what each contract does, and what is still open.**

---

## 0. How to read this

This file replaces a 2,206-line *dashboard* specification that described a Kalman/HMM signal
surface over a Uniswap-v4-primary protocol with stored range bounds and a surplus-funded IL
make-whole. None of those four things is true of the tree any more: v4 was cut (§V4-CUT), range
bounds are absolute prices with no ticks, `arbETH` was removed, and the estimation stack is a
client-side convenience rather than a protocol component. The old file is gone rather than
annotated, because a document that is wrong about the architecture cannot be repaired by a banner.

**Precedence, highest first.** The contracts in `evm/src` are canonical. `CLAUDE.md` is canonical
for how to work in the tree and for environment facts. `docs/actionable/QUEUE.md` is canonical for
status. This file is canonical for *what the protocol is*, and every claim in it was read from
source. `docs/informational/` is prose that has drifted from the code in about ten places and must
never be quoted without checking; §A below is the standing ledger of those drifts.

**Section numbers are load-bearing in one place.** Three live Solidity comments cite `spec.md §3.8`
as the authority for the fees-versus-LVR test — `imports/QuidLib.sol:213`, `imports/QuidLib.sol:247`
and `Core.sol:259`. §3.8 below answers exactly that question and must keep its number. If you
renumber section 3, fix those three comments in the same commit.

---

## 1. The instrument

### 1.1 What QD is

A dollar claim bought at a discount that matures on a calendar month. Pay less now, hold face value
maturing later, with the forward yield priced in at mint.

`Basket` is one contract holding many dated series: an ERC-6909 where the token id **is the maturity
month**, wearing an ERC-20 face for the aggregate. `mint(pledge, amount, token, when)` fixes the
maturity at mint time (`Basket.sol:280`); `currentMonth()` advances; only matured vintages can burn,
and there is no allowlist or privileged address that can burn an immature one.

The normalised amount minted is the deposit plus an accrual term scaled by the chosen maturity and
by either the fixed seed-tranche rate during bootstrap or the live observed average of the
constituent vaults' yields afterwards. **One dollar deposited was never one QD minted.** The accrual
is the discount, priced at entry.

### 1.2 What QD is not

It is **not** a bill of exchange, a bankers' acceptance, or any fixed-sum obligation, and the
distinction is not pedantry. A bill is an *unconditional* order to pay a fixed sum, and
unconditionality is what makes a bill discountable and acceptable as collateral. QD redeems at
`min(solvent / matureSupply, par)`: capped at par, and able to fall below it for three separate
reasons.

- **A constituent stablecoin depegs.** A per-stable native-value haircut, read live from that
  stable's pinned Chainlink feed.
- **A constituent vault loses money independent of any depeg.** Backing reads `convertToAssets`, so
  a realised write-down lands automatically.
- **Illiquidity, which is not insolvency.** Funds solvent at par but not currently withdrawable are
  haircut on *deliverability* and the unserved balance is retained as a live deferred claim, paid
  once liquid. This defers value rather than destroying it.

**The floating downside is deliberate and load-bearing.** It is what separates QD from a
par-redeemable payment stablecoin, whose regulatory definition turns on fixed-value convertibility.
The accurate external description is a defined-maturity fund share that matures on a date and
returns net asset value. **Never describe QD externally as a bill, an acceptance, or a fixed-sum
obligation.**

### 1.3 The forward liability curve

Because every unit carries its maturity month as its token id, the protocol knows its **entire
forward dollar liability curve** at any moment: what is owed in March, in April, out to the end of
the year. That is a duration-matched book expressed as a token, not a stablecoin with an
unpredictable redemption queue. Reserves mature *into* the schedule; the "dollars on hand" property
is asset–liability matching rather than a promise.

It is also what lets the volatile side be single-sided. An ETH/USD or BTC/USD range needs a dollar
leg. Nobody has to sell half their ETH to fund it, because the maturity ladder *is* the predictable
forward dollar stream and that stream collateralises the dollar side.

### 1.4 The cap, and the cold start

Issuance against not-yet-earned yield is bounded by a hard constant: `CAP = 600_000 * 1e18`
(`Basket.sol:48`). The bootstrap projects up to a full year forward with the 1:1 supply cap skipped
while `currentMonth() < 12`; after that the horizon collapses to about a month, because observed
yield exists and there is nothing left to guess. The far projection is a one-time ignition cost
gated on a month counter, not a standing policy.

Protocol-internal mints (fee and swap-out legs, `auth(msg.sender)` in `Basket.mint`) are separately
gated after month 12 on live headroom — par backing minus the depeg haircut minus the
deliverability haircut, against `totalSupply()`. Anything over headroom is **deferred to a later
maturity rather than shrunk away**, so a fee claim is preserved without becoming redeemable against
dollars that are not there.

**Minting QU!D is a last resort** (standing rule 8b). A mint creates a liability against the basket;
paying with value that already exists never does. Before adding a mint site, show the non-minting
route is grotesque rather than merely inconvenient.

---

## 2. Architecture

### 2.1 Topology

| contract | role |
|---|---|
| `Basket.sol` | QD itself — ERC-6909 by maturity, ERC-20 face, LayerZero `OApp` to Solana (`SOLANA_EID = 30168`) |
| `Aux.sol` | the dollar basket — stable custody across venues, swaps, redemption, vault health |
| `Core.sol` | the range engine — oracle ring, pooled counters, skew premium registers. One instance per asset |
| `Quid.sol` | the **ETH** range manager, and the ERC-4626 the depositor holds |
| `Vault.sol` | the **BTC** range manager. BTC-only since the `EthVenue` extraction |
| `Shares.sol` | the range state both managers inherit — `lpShares`, `autoManaged`, `feesPerShare`, `levPooled`, `totalBuffer` |
| `VBtc.sol` | the synthetic sats-denominated underlying the BTC range's `asset()` points at |
| `BTCChannels.sol` | Lightning channel custody, SPV-proven open / splice / close, swap settlement |
| `spv/SPVGateway.sol` | the Bitcoin header chain the proofs are checked against |
| `LevManager.sol` / `BtcLevManager.sol` | the opt-in IL overlay, per asset |

Delegatecalled bodies live in `imports/` — `SwapLib`, `QuidLib`, `BtcLib`, `BasketLib`, `LevMath`,
`BitcoinTx`, `ChannelLib`, `FeeLib`, `OracleLib`, `RangeLib`, `LevBase`, `LevVenueBase`. Their
external surface is large because a delegatecalled library function must be `external` or `public`;
that is a linking constraint, not deliberate API.

Six libraries were **folded into other files rather than deleted**, and this is the most dangerous
class of stale reference in the tree: the code is live and a grep for the old name returns only a
comment. `ExitLib` and `MuSig2Agg` are in `BitcoinTx`; `ExternalTwap` is in `OracleLib`;
`FixedRateFill` and `ShareMath` are in `SwapLib`; `SortedSetLib` survives as a symbol in `imports/`.
`SOR.sol` is a genuine tombstone — routing was deleted outright.

### 2.2 One engine, two instances

`isBTC` is polymorphism done by hand and it is the codebase's biggest single source of bulk. `Core`
is the one place that got it right: it parameterises the distinction with a bool and is instantiated
twice — `new Core(cfg.weth, …)` and `new Core(cfg.wbtc, …)` (`DeployLib.sol:136-137`). Everything
above `Core` forked into per-asset copies instead.

**The consequence for reading the code: the discriminator moved from the name to the address.**
`lpShares` on the BTC instance *is* what `lpSharesBTC` used to name. A zero-hit grep for a
`*BTC`-suffixed member is evidence of a rename, never of a removal.

Some asymmetries are real and must survive any consolidation: the gross-versus-net pooled comparison,
8-versus-18 decimals with vBTC's identity conversions, vBTC having no bearer redemption, and
Lightning cooperative close versus on-chain WETH settlement. `VBtc` in particular must survive —
not for any privacy reason (that justification is dead) but because the BTC range has **no ERC-20
underlying unless it mints one**: the real underlying is LN-custodied native BTC, and WBTC is only a
pricing handle that is never held.

### 2.3 Ownership posture

Ownership is **renounced after `setup`**. Basket composition, the stable set and the tranche rules
are fixed at deploy; there is no on-chain curation or governance surface to re-weight, add or remove
a stable. Any change is a fresh deploy. Cross-contract pins are pin-once and reject re-wiring.

`onlyUs` gates `Core` internals to the wrappers. It does **not** make the protocol closed — swap, LP
deposit and redemption entrypoints are ordinary permissionless functions, which is precisely why an
external integrator can call them without admission.

### 2.4 Decimal bases

Three bases coexist: **6** for USD stables, **8** for sats and WBTC, **18** for ETH, QU!D and
internal USD. The WBTC price carries a ×1e10 lift (`usd·1e28`) which closes the 8↔18 gap, so a flat
`/1e30` scale is correct for *both* assets and adding a second ×1e10 "to fix BTC" double-counts it.
Never infer a stable's decimals from its slot index — read `IERC20(stable).decimals()`.

### 2.5 Size discipline

solc 0.8.30, optimizer on, 200 runs, **`via_ir = false` deliberately**: stack-too-deep is solved by
moving locals into struct fields, not by turning on the IR pipeline. EIP-170 binds. `forge build
--sizes` does not report every contract that matters; use `python3 tools/check-contract-sizes.py`,
which reads `deployedBytecode.object` directly.

**A margin is a reading with a timestamp, not a fact about the repo — and so is which contract
binds.** That answer has been wrong three times in one day. Re-run the script; do not quote a number
from any document, this one included.

---

## 3. The two volatile legs

### 3.1 The ETH range

The depositor brings ETH alone and holds a standard ERC-4626 share. `Quid` **is** that 4626 — there
is no wrapper. Its ERC-20 face is a **projection of range state** rather than a ledger:
`totalSupply()` returns `lpShares`, `balanceOf(u)` returns `autoManaged[u].pooled`, and `transfer`
moves shares. There is no balances mapping, because the range's own accounting is the balance.

`deposit(assets, receiver)` pulls from `msg.sender` and credits `receiver`, so a third party may
fund a position for an address that never held the asset — the hook §4 depends on. `withdraw` and
`redeem` require `owner == msg.sender` and revert `AllowanceFlow` otherwise, because the withdraw
path reads `autoManaged[msg.sender]`; a front-end acting for someone else must first transfer the
shares.

The underlying range is two-sided, ETH plus protocol-owned synthetic dollars, but **the dollar leg
was never the depositor's**, so the share redeems to one asset. `convertToAssets(shares)` is a
pro-rata slice of the ETH-side backing and fees accrue by appreciating that single-asset share
price. That is what makes it a clean 4626 rather than an LP-token-of-two-tokens no accounting system
can price.

Two guards on the position:

- **The JIT lock.** `_depositImpl` stamps `lastDepositBlock[pledge]` and `_withdraw` refuses a
  same-block exit, closing the one composition the audit found open on the 4626 path —
  `deposit → swap → withdraw` atomically sniping a swap fee. Keyed on the *receiver*, so a
  throwaway-receiver bypass is stamped too.
- **The recipient pin.** `pinRecipient(to)` restricts the only address an LP's withdrawals may pay.
  The first pin applies immediately (unrestricted → restricted cannot make an LP worse off); every
  subsequent re-point waits `RECIPIENT_TIMELOCK = 3 days`. **The delay is the whole mechanism** — a
  pin the LP key can set, the LP key can also unset, so a stolen key may request a change but cannot
  act inside the window. Zero means unpinned, so it is additive.

**Range geometry: there are no ticks.** `evm/src` holds ~185 case-insensitive `tick` matches and
every one is a comment recording the removal. Bounds are absolute prices (`loPrice`/`upPrice`), the
fill settles at the oracle, and out-of-range orders carry absolute `lower`/`upper`. The width is
`RANGE_DELTA = 20` (`imports/SwapLib.sol:824`) — **±0.2%**, an order of magnitude tighter than the
±2% every figure in `docs/informational/` is keyed to.

### 3.2 The ETH yield venue

**There is one destination and no choice.** `Quid.deposit` takes no venue argument, and
`QuidLib._supplyEtherFi` is the single sink: *"ONE DESTINATION: every ETH deposit becomes weETH. No
venue choice, no default, no dispatch"* (`imports/QuidLib.sol:140`). A placement of zero reverts
`VenueUnavailable` rather than silently redirecting, because no venue can be assumed always-live and
a fallback would place capital the depositor never chose.

> ⚠️ `docs/FAQ.md` still lists six deposit venue codes (0, 2, 3, 4, 5, 6) and says the allocation
> discretion belongs to the depositor. **That is stale.** `docs/informational/ETH-VENUES.md` is the
> one that matches the code.

Exit runs the ladder in `QuidLib.withdrawETH`; the weETH slice offramps via `QuidLib.offrampBody` —
the Curve weETH/WETH pool, else a multi-day no-fee ether.fi withdrawal NFT minted to the withdrawer.
**The guarantee of redeemability is the un-pullable queue**, not any pool position: third-party WETH
in a pool converts or arbs away exactly when stressed, so the floor has to be the thing nobody can
pull. The conversion cost is borne by the exiting LP and never socialised.

Exits are not walled per depositor — the ETH leg is served from the aggregate position, and an
illiquid slice is **deferred** rather than charged to whoever is leaving.

### 3.3 The BTC range — Lightning custody without a bridge

Each LP locks native BTC in a **2-of-2 key-path simple-taproot channel (BOLT #995)** with the
protocol's hop node, holding one of the two MuSig2 shares itself. The hop can never spend alone. If
the hop vanishes the LP unilaterally force-closes the LDK channel and recovers its balance after the
`to_self_delay` CSV. There is no funding-script CLTV refund branch, because a key-path taproot output
has no leaf. **Hop failure loses the LP nothing.**

The channel is a *standard* LDK/BOLT channel. Commitment state, revocation, HTLC resolution and
penalty enforcement live entirely on Bitcoin; the EVM does not anchor commitments and does not
adjudicate fraud. Its only job is to bridge the channel to the range position, and it does that with
Bitcoin merkle proofs against `SPVGateway`'s header chain:

- **`openChannel`** proves the key-path P2TR funding UTXO `0x5120 || Q` exists at `amountSats`, then
  credits the LP's BTC position. The funding output is byte-matched against the committed `Q` and
  the value against the proven transaction, so a position cannot be fabricated.
- **`splice`** proves the funding UTXO was spent into a new 2-of-2, grow or shrink, and re-anchors
  the live outpoint. Capacity changes by splice; there is one channel per `lpEth`.
- **`recordClose`** proves the funding UTXO was spent and retires the position, paying accrued
  USD-leg claims and delivered proceeds. The remaining channel BTC is recovered natively by the
  close transaction itself.

`lpEth` is **derived on-chain** from `lpPubkey` via `ChannelLib.lpEthOf` — Bitcoin and the EVM share
secp256k1, so the channel key already determines the LP's EVM address. An `lpEth` supplied alongside
a signature was a second source of truth for an address the chain can compute, and deleting it
closed an attribution hole. **The LP signs nothing on the EVM side.** What it does supply is
`btc_recipient_pop`, a BIP-340 Schnorr proof-of-possession over `btcRecipientPoPDigest(lpEth)` — a
Bitcoin signature.

`btcRecipientOf` is **one** source of truth for both cooperative-close attribution and the splice
path. A withdrawal routed to any other script would let `_lpFinalBalance` read zero, inflate
`delivered`, and over-claim the shared swap-out proceeds pool. That is cross-LP theft, and it is why
an arbitrary-address `redeemVBtc(sats, p2trScript)` must not be built on the strength of `VBtc.sol`'s
own header, which argues for it.

P&L is **per channel, not pooled**: `delivered = funded − finalBalance`, paid its share of realised
swap proceeds. The BTC-leg fees accrue in native sats and settle at close; the USD leg mints as QD.

**What this does for Lightning.** Routing liquidity has always been a cost centre — locked BTC earns
nothing, so there is too little of it, so routing is shallow. Here the same self-custodied,
L1-enforced channel BTC simultaneously backs a yield-earning position, with no custodial wrapper, no
Lightning fork, and nothing added to Lightning's security surface. The externality is positive for
the whole network, not only for our LPs.

### 3.4 The dollar basket

**Fourteen stables**, and that is the layout maximum rather than a round number. `BasketLib` fixes a
`uint[15]` contract: slot 0 is the yield-weighted sum across all sources, slots 1..N are the
per-token deposits, and **slot 14 is the raw TVL total**. Fourteen stables fills 1..13 exactly. A
fifteenth would write slot 14 and silently overwrite the total `FeeLib.calcFeeL1` divides by. Do not
add one without widening the arrays first.

BOLD must stay **last**: `Aux` pins `stables[length-1]` as the Liquity-SP-routed stable. The set, in
order: USDC, USDT, PYUSD, GHO, RLUSD, USDG, DAI, USDS, USDe, AUSD, cUSD, crvUSD, frxUSD, BOLD.
Venues are Morpho 4626 vaults for most, Aave v4 natively for GHO and USDG (their slots are
`address(0)` on purpose and `setVault` rejects re-wiring either), native 4626 wrappers for sDAI,
sUSDe, stcUSD, scrvUSD, sfrxUSD, and the Liquity Stability Pool for BOLD.

**Breadth is the insurance, not a bet on any one issuer.** A peg is unpriceable in the actuarial
sense: the base rate is unobservable (mass at par, then a regime jump, each incident *sui generis*),
the hazard is reflexive (the price of protection feeds the probability of the event), and the risks
are perfectly correlated in the only state that pays. If you cannot price the tail of a single peg,
the robust move is to never take a concentrated bet on one — bound the risk by breadth instead of
pricing it.

There is a second-order effect worth stating because no issuer can offer it: a depositor locking
dollars for twelve months removes redemption pressure from *every* stable in the basket in
proportion to its weight. Longer locks relieve more, which is why the yield schedule pays for
duration.

### 3.5 The oracle ring and the skew

Swaps execute at `getTWAPforAsset` — an internal ring cross-checked against Chainlink — reused as
the range price. `USD18 per 1e18 raw`, with WBTC carrying the ×1e10 lift.

A constant-product AMM keeps its inventory stocked by letting arbitrageurs trade against its own
stale price. That is LVR, and it means the shelves stay stocked **by picking off the people who
stocked them**. Oracle pricing refuses that: no stale price, no LVR to harvest. But refusing it has
a cost — inventory no longer refills itself for free, so rebalancing must be *bought* rather than
extracted.

The purchase price is the skew: the **Avellaneda–Stoikov reservation shift**, paid by the trader who
created the exposure and retained for the LPs who bear it.

```
skew = Γ · σ² · q            Γ = GAMMA_WAD = 3e16   (γ·(T−t) folded into one coefficient)
                             σ² = annualized realized variance from the ring
                             q  = (target − inventory) / target, the A–S scarcity
```

Both σ² and q enter **linearly** — there is no scarcity² and no separate vol-steepening term; the
earlier convex curve was replaced (`imports/SwapLib.sol:1014-1022`, `:1333`). The horizon `T−t` is
already carried by the `FLOW_DECAY` EWMA on flow and scarcity. A flush guard (`inv ≥ target ⇒ 0`)
and a `MAX_WELL_SKEW` cap bound it.

**The refill trigger is the skew's own predicate**, character for character — the thing we charge
for and the thing we fix cannot drift apart, because a separate threshold would be two definitions
of one condition and the one that drifts is always the one nobody tests.

There is no swap-in bonus. `payRefillBonus` was removed on 2026-07-22 and the code says *"paying a
swapper a bonus is exactly what the removal was meant to stop… Do NOT rebuild it."* The JIT
counterparty is real, but it is compensated by the retained premium staying with LPs as backing.

`swapFeePpm()` charges nothing; it is a disclosure accessor. The skew **is** the fee.

### 3.6 The IL overlay

Opt-in, per LP, up-side only, isolated on an external lending market.

The mechanism in one line: **the range sells the buffer, not the principal.** When ETH rises the
range's loss is that it sold ETH too cheaply. The overlay borrows a stable against the LP's own
collateral, buys ETH, and hands the range that extra inventory to sell instead of the principal.

The target is `1 − √(entry/now)` — the fraction of ETH the range has actually sold since entry — and
it returns **zero at or below entry** (`imports/LevMath.sol:109-125`). Where the range reports a real
measured sold fraction, that is used in preference to the formula. A position **opens at zero
leverage** and levers up only as the range sells.

**Why up-side only.** Below entry the range over-holds the falling asset. A short leg corrects that
by selling into the decline, which realises the loss and forfeits the recovery — so for a long-biased
holder, doing nothing strictly dominates any round trip: same fees, minus the realised leak. The
below-entry leg was built and deleted on 2026-07-24. De-levering and shorting are also not the same
thing: de-levering into a fall crystallises the drawdown and leaves you de-risked rather than whole,
which is the LLAMMA cost. Below entry we hold.

**Why there is no liquidation engine.** The leverage is counter-cyclical to liquidation risk. Below
entry the target is zero, so the keeper de-levers to zero debt and there is nothing to liquidate.
Above entry the collateral has appreciated, so LTV is healthy. The residual — a gap crash while
levered above entry — is backstopped by the venue's own isolated liquidation, which hits one
depositor and stops. There is a fork test that runs a levered position through a full liquidation on
real Morpho with a real feed and then checks a passive depositor's redeemable value and the
reserve's backing are untouched (`test/LeverageCrossSubsidyProbe.t.sol`).

**The rebalance band is derived, not chosen.** `h³ = g / (C·K)` — the classic no-trade region under
a fixed transaction cost, where `g` is the gas cost of one rebalance read from `block.basefee`, `C`
is the position collateral, and `K` is the concentrated-liquidity LVR coefficient
`1/(4(2 − √(P/Pb) − √(Pa/P)))` read from range geometry. **σ cancels**: higher volatility crosses the
band sooner *and* makes the error costlier, and for this cost structure the two exactly offset. So
the band needs no volatility estimate and cannot be moved by anyone who can move one. A $100k
position at 3 gwei bands at ~62 bps; a $1k position at ~288 bps. It returns 0 — rebalance always —
when any input is unmeasured, which is the fail-open direction on purpose, because here the failure
that costs money is *not hedging*.

> 🔴 **`setTargetLtv` no longer exists** (§E358, `imports/LevBase.sol:404`). IL-protect is a
> protocol-wide liability on behalf of all LPs, so no LP carries a debt-to-collateral ratio of its
> own to set. There is one cap, `TARGET_LTV_CAP_BPS = 7500` bps ≈ 4× (`imports/LevBase.sol:46`).
> `docs/FAQ.md`'s "the depositor sets their own direction" answer, and `LevManager.sol:280`'s
> orphaned docblock, both describe a function that was deleted.

`openLev(venue, collWeeth)` is the LP's; `rebalance` and `cascadeDelever` are permissionless and only
move toward the target. Borrow venues are Morpho for ETH and Aave v3 for the WBTC leg. Isolation is
Morpho-native: `onBehalf = lp` puts each position under the LP's own address, so a liquidation
follows the call arguments rather than the contract making them.

**When to decline it.** The overlay is a view, not a default. An unlevered depositor's loss depends
on *where price ends*; the overlay's cost depends on *how it got there*, because it borrows and buys
as price rises and sells and repays as it falls, paying spread on both legs plus interest every
cycle. Path length, not destination. So: choppy round-tripping markets (the most common regime for
these assets), rise-then-fall (the worst case — bought high with borrowed money, sold low), thin
volume (no fees to amplify, so it is pure carry against a loss that is impermanent anyway), and a
long horizon with no forced exit (the loss is impermanent *for you* in the strict sense). It is also
not downside protection. Where it wins: sustained directional moves, high volume where fee capture
on doubled depth dominates carry, and any depositor whose exit timing is not their own choice.

**The open tension, stated because it is one.** To give LPs a linear claim, rebalancing loss is
transferred to shared surplus. A levered LP puts a larger in-range position to work, generates
amplified LVR, and that amplified loss lands on the *same* shared surplus — so it consumes more of
the common buffer than its share. In a per-position AMM each LP eats its own IL and leverage is not
an externality; the linear-claim design makes it one. Calm: net beneficial. Stress: net harmful.
This is the strongest internal argument for keeping the overlay opt-in and bounded, and it is the
axis to measure before loosening either.

### 3.7 Redemption and the outflow fee

Redemption is **stables-only and pro-rata**. When free stables cannot cover it, `redeemAsBody`
unwinds the range to free QU!D's own committed dollars (`Quid.unwindForRedeem`) — no volatile leg is
sold, no LP's ETH is touched. `redeemTo` retargets the payout without changing whose QD burns, so a
holder blacklisted by a stable issuer can take proceeds at a fresh address instead of being stranded.

`redeemableAmount()` is the capacity quote front-ends should clamp against; `redeem` also clips
internally, so a stale read leaves QD in the wallet rather than reverting. **It is not `view`** —
calling it without a refresh reports a collapse to zero that is indistinguishable from a real defect.

The fee is **two terms**, not three.

1. **The drain tax, `FeeLib.calcFeeL1`.** Draining a stable whose yield factor sits above the
   basket's weighted-average baseline lowers the basket's average yield, so it is taxed
   `(mine − baseline)`. At or below baseline it is `BASE = 3` bps. A depegged stable is already
   yield-discounted upstream, so it also lands at `BASE` — cheap to shed bad collateral, expensive
   to drain the yield engine. `FeeLib.scaledFeeL1` scales the above-`BASE` excess by the drained
   fraction, so a small cherry-pick is ≈ `BASE` and draining a whole stable is the full charge.
   Capped at `MAX_FEE = 30` bps.
2. **The depeg haircut, `FeeLib.riskFactor`.** A multiplicative haircut so a redeemer cannot pull a
   dollar-booked, ninety-five-cent stable at par. **A separate, uncapped axis** — a fee is not a
   loss.

Allocation is concentration-proportional: a redemption spreads across stables in the proportions
they are actually held, so a default exit cannot covertly concentrate the basket into one name. Each
slot is `try/catch`'d so one halted venue does not brick the redemption. `checkBacking()` closes
every branch.

> 🔴 The `baseRate` third term is **gone**. There is no Liquity-style decaying directional
> redemption toll: `_br`, `_touchBaseRate`, `BR_DECAY` and `BR_MAX_MIN` were removed from `Aux` and
> `FeeLib`, with the reason recorded at `Core.sol:200` — QU!D has no peg-arb loop, so the toll had
> nothing to price. The off-chain CRE severity feed is gone too; the pinned per-stable Chainlink
> feeds *are* the signal. Anywhere `docs/informational/FEES-OUTFLOWS-TWAP.md` says "+ baseRate" or
> "worse of CRE and a live feed", read it as absent.

The time-aware machinery the stable side reuses is a **time-weighted average yield** —
`yieldAccum += yield · elapsed`, exactly as a TWAP accumulates price — which smooths a one-block
yield wick the way a 30-minute price TWAP ignores a spot wick. That same `avgYield` sets the bond
coupon, and the per-stable arrays it is built from are the inputs the fee reads, so **no vault is
re-read on the fee path**.

### 3.8 LP economics — did realized fees cover the IL we bore?

> **This section's number is cited from `imports/QuidLib.sol:213`, `imports/QuidLib.sol:247` and
> `Core.sol:259`. Keep it.**

An in-range AMM position is **short gamma with a fee coupon**: it continuously sells what is rising
and buys what is falling, so its payoff is concave against a linear hold, and it is economically
selling optionality to traders with fees as the premium. By no-arbitrage, in an efficient market
**fees ≈ IL on average**. LPs profit only where fees *structurally* exceed realised IL, which
competition erodes. There is no passive escape and there is no parameterisation that escapes it:
delta-hedging a short-gamma position is always buy-high-sell-low, because that is what negative
gamma means.

Since gamma cannot be hedged for free, and `fees ≈ IL`, the only leverage-free moves are three:
**(a)** earn yield on the capital a normal LP forgoes, raising the floor; **(b)** minimise the
capital actually exposed to short gamma, shrinking the footprint; **(c)** get paid above fair for
the gamma. QU!D does (a) and (b) structurally, and declines (c).

**(a) is structural because the position is virtual.** The V4-style book is mock ETH and mock
dollars, so the depositor's real ETH never sits idle in a pool — it stays at the yield venue earning
while the virtual position earns the retained premium. **The reserve baseline is earned whether the
dollar leg is ranged or sits idle**, which is exactly why it is *not* marginal compensation for IL
and must not size the range (`Core.sol:259`).

**(b) is the θ budget, and it is derived rather than chosen.** θ is Merton's `μ/(K·σ²)` — the optimal
fraction of capital to commit to a risky bet — and the bet being sized is IL-bearing in-range depth:

```
θ = rangeFeeYield / (K · σ²)

rangeFeeYield = premiumEwmaUsd · PREMIUM_ANNUALIZE / POOLED_USD
K             = kLvrWad(core, loPrice, upPrice) = 1/(4(2 − √(P/Pb) − √(Pa/P)))
σ²            = realizedVarianceWad, annualized, from Core's oracle ring
```

The numerator is the **realised** retained scarcity premium, decayed over ~48h and annualised by
`PREMIUM_ANNUALIZE = 127` (an EWMA with half-life H has mean lifetime H/ln2; 48/ln2 ≈ 69.25h, and
8760/69.25 ≈ 126.5, rounded up). It is measured against the range's **own** in-range dollars — the
capital that actually bore the IL — which is what makes it a yield on the bet rather than on the
whole reserve. The denominator is **potential** LVR. The two are independent: the numerator moves
with whether flow arrived, the denominator with how much IL we were exposed to.

**That independence is the whole point, and it is fragile.** Deriving the numerator instead as
`skewWad × flowEwmaUsd / pooled` looks strictly better — zero new storage, no hot-path write — and
is wrong, because `skewWad` already contains σ², so σ² would **cancel** and θ would collapse into a
vol-independent function of scarcity and flow, measuring nothing. That cancellation is the
Avellaneda–Stoikov property (fees are priced to scale with vol) and it would silently gut θ's
purpose.

**So `derivedThetaWad < 1e18` is the protocol's own rationality test failing: realised fees did not
cover the IL we bore.** Above 1e18 it reports how far above the no-throttle threshold the range is.

θ **fails open** at `1e18` on any unmeasured input — cold ring, zero premium, zero K. Failing closed
would deadlock a fresh range forever: no depth ⇒ no fees ⇒ no premium ⇒ no depth. That is safe only
because `SwapLib.clampByBacking` applies the physical `backing − pooled` headroom independently, so
every path stays bounded at real backing even when θ does not bind.

**Why the θ clamp is not a liquidity policy.** θ ≤ `yield/(K·σ² − f)` was originally a *solvency*
inequality under the previous design, where the basket's surplus absorbed the LP's IL through
`arbETH`; bounding the exposed slice bounded how much shared surplus could be drained. That design
is overruled — `arbETH` is removed and the LP bears its own IL through the share price. Thinning the
range in a volatility spike, when swap demand and fee opportunity peak, is the fair-weather-liquidity
failure that makes AMMs unreliable exactly when they matter. Treat θ as what it now is: a sizing
input, not a promise about depth.

**Where the numbers in `docs/informational/` fit.** The K measurements (COVID 5m data: 2.74 guard-off,
1.84 guard-on), the crash-day result (2020-03-12, ETH −52% intraday, −2.32% of position value across
41 repacks) and the solvency table are all keyed to a **±2% range**. The deployed range is ±0.2%.
Treat them as historical LVR data, not as a live safety argument.

### 3.9 Vault health, and why the response is multi-vault

The depeg watcher asks "is this *token* worth less than a dollar?" Vault health asks a different and
harder question: "can this *vault* still return our stablecoins?" Conflating them is the error the
design exists to avoid.

Vault health is **100% on-chain, permissionless and binary**. `Aux.pokeVaultHealth(vault)` reads only
ERC-4626 ground truth — `convertToAssets(balanceOf)` against `maxWithdraw`. Below 50% liquidity it
triggers block plus dwell-then-evacuate. It can only *tighten*: it can never unblock a vault it did
not itself flag and never re-quotes value. The unfakeable read plus a 30-minute cross-poke
`EVAC_DWELL` makes a grief call impossible, and because anyone can call it, a captured key cannot
withhold the rescue.

`VaultHealth` is `{ bool blocked; uint40 flaggedAt; }` — **no haircut lever**. A blocked vault stops
receiving new deposits and is **valued at `maxWithdraw`**: what it can actually deliver.

**Why binary is right.** *Insolvency* — a realised write-down — already lands automatically, because
backing reads `convertToAssets`; a separate haircut would double-count. *Illiquidity* — assets whole,
just locked — is not a loss and must not be haircut; evacuate the withdrawable part, block, value at
`maxWithdraw`, and leave the rest as a present-but-locked claim. *Unrealised impairment* is the only
case a re-quote would be warranted, and it **cannot be derived from on-chain totals**:
`totalAssets`/`convertToAssets` are the vault's self-report and read stale-*high* on un-written-down
bad debt, which is the very thing you would need to detect. So the watcher runs liquidity-only and
never guesses at impairment.

**Detection is worthless without somewhere to go, and that is what multi-vault provides.** On an
incident the protocol evacuates the deteriorating vault and spreads the recovery equally across the
healthy ones — maximal diversification of what comes back — best-effort, with a frozen `redeem`
reverting inside `try/catch` so the vault stays blocked and the loss is socialised rather than
bricking the basket. A single-vault protocol can only detect a problem and then suffer it.

---

## 4. The privacy layer

### 4.1 The change, stated plainly

The Privacy Pool contracts move **from `ibiza` into this repository**, and every deposit is routed
through them.

This reverses a standing decision. `ibiza/PP-SPV-BUFFER-DESIGN.md` §1 asserts an optics requirement —
*"SPV's repo must contain zero references to PP"* — and enforces it structurally by hand-declaring
`ISpvVogue`/`ISpvBasket` on the PP side. The glue was then deleted outright on 2026-08-24
(`ibiza@8fa5e9e`: *"no longer relevant, bad glue; redo the SPV integration later when SPV progress is
ready"*). **That document is superseded by this section and should be retired rather than edited.**

Two reasons the direction is now the other way:

- **Rule 2.** A hand-copied interface living in two repositories is the same declaration twice, which
  is what standing rule 2 forbids inside one — and it is the mechanism behind the cross-repo
  fragility that *"SPV depends on exactly four Quid/Basket signatures staying permissionless and
  stable."* Merging replaces a hand-copy with a real import and the drift risk deletes itself.
- **The repo boundary is the process boundary, and the host is here.** SPV owns every long-running
  process in the system. The batch aggregator has to run somewhere, and this is the repo with a host.

### 4.2 Cold start is the actual argument

A privacy pool is worthless to its first user. If mixing is opt-in, the first person who wants it
arrives to an empty anonymity set and correctly declines, and so does everyone after them. **Routing
the protocol's own TVL through the pool is what gives the first real user someone to mix with.**

But be precise about what the anonymity set is made of, because it decides whether this works at all:
**the set is notes, not dollars.** Routing fifty million dollars through the pool as twelve LP
deposits gives an anonymity set of twelve. The bootstrap only works if the forced flow produces
*many, similarly-sized* notes. That is a parameter choice — minimum denomination and split policy —
and it must be made deliberately rather than inherited from a default. The wallet's current default
(`Uniform` mode over 10 / 1 / 0.1 ETH) turns 9.9 ETH into **99 notes**, each with its own proof and
its own withdrawal, which is a very different gas and UX profile from one `Quid.deposit` call.

### 4.3 What the pool proves

**Not fund provenance.** Nothing about origin is proven or disclosed. The property is *provable
dissociation*, which is deliberately weaker: it lets an honest holder distance themselves from
tainted deposits without ever identifying their own.

The predicate a withdrawal actually carries, in `PrivacyPool.withdraw` and re-checked per withdrawal
in `withdrawBatch`:

1. **The state root is known** — a 64-entry circular history over a LeanIMT commitment tree.
2. **The identity is registered and unrevoked** — one inclusion proof of the withdrawer's escrow
   commitment carrying the clean status (`0`) in `IdentityRegistry`. Encoding status in the *value*
   rather than splitting inclusion and revocation across two trees removed 43% of the withdrawal
   circuit (43,772 → 24,812 ACIR opcodes) and removed `sk_identity` from the withdrawal entirely:
   identity is proven once, at escrow.
3. **The subject is not blacklisted** — a non-membership proof against the root pulled from
   `RegistrySourceAnchor`, never set on the pool.

Three consequences that are easy to get wrong and are worth carrying across:

- **Root expiry is mandatory here.** An inclusion-only tree is safe to prove against forever, because
  an old root has *fewer* members and can only under-approve. This tree also carries revocations, so
  an old root has fewer of *those* — honouring one indefinitely would let a revoked identity prove
  the clean state forever. `isValidRoot` bounds acceptance by `MAX_ROOT_AGE` while always keeping the
  latest root valid, so controller inaction can never block a withdrawal.
- **The blacklist root is pulled, not set, and the reverts are load-bearing.** It used to be a
  storage field written under `onlyEntrypoint`; one address choosing the value is a pause lever in
  everything but name, on a contract whose central claim is that no such lever exists. It now comes
  from an append-only, unowned anchor. `_activeBlacklistRoot()` reverts on an absent or unactivated
  snapshot and **must not be caught**: for an exclusion predicate, an empty set proves non-membership
  for everyone, so swallowing the revert would admit everyone.
- **Batching amortises the proof check, never the policy checks.** The aggregation verifier takes one
  public input, so `s[3]`, `s[5]` and `s[7]` are whatever the prover folded in and every one must be
  re-anchored to pool state in the settlement loop. A wider proof without those checks would be worse
  than the open gap, because the gap was written down and an unchecked signal looks like coverage.
  `PUB_LEN` is **8** in both `BatchVerifierLib` and `BatchCommitmentLib`, and `s[7]` is the blacklist
  root — the "still 7" claim in `docs/actionable/SPRINT.md` is stale.

`PrivacyPool.withdraw` is untouched by batching: a user censored by every batcher still self-submits
at full gas, so batcher refusal costs money, never access.

### 4.4 Forcing TVL through the pool — the design, and its costs

**The note commits to a share count, not to an asset amount.**

`PrivacyPoolComplex`'s `ASSET` is the range manager's ERC-4626 share. `Entrypoint.deposit` pulls the
depositor's ETH, opens the position via `Quid.deposit(assets, receiver)` with the pool as receiver,
and inserts a commitment over the resulting share count. The pool holds one aggregate position;
per-note ownership is internal to it.

This is the only variant in which **yield accrues inside the anonymity set**. A share count is static
while the share price appreciates, so a note minted today and a note minted next year are the same
size in the field, uniform denominations stay uniform forever, and the depositor's yield arrives
through `convertToAssets` without the note ever being touched. It needs no change to
`PoseidonT4([value, label, precommitment])` — a share count is as good a field element as wei — and
no change to the withdrawal circuit's value semantics.

The hook it depends on already exists: `Quid.deposit` pulls from `msg.sender` and credits `receiver`,
so the pool can fund a position for an address that never held the asset.

**Four costs, named rather than discovered later.**

1. **The pool becomes one LP.** Every note-holder's economics are the aggregate position's. There is
   no per-note venue choice (there is no venue choice at all, §3.2) and no per-note overlay — the
   IL overlay is `openLev` on an address, and the address is the pool. Either the pool takes the
   overlay for everyone or for nobody. *Recommend: nobody, initially.* The overlay is a view (§3.6)
   and a pool cannot hold a view on its members' behalf.
2. **The JIT lock becomes a shared surface.** `lastDepositBlock` is keyed on the receiver, and the
   receiver is now always the pool, so **any** deposit blocks **every** withdrawal in that block. The
   existing grief analysis ("dust-depositing to a victim delays them one block, self-defeating")
   assumed a per-LP key and does not survive this change. It needs re-deriving before launch.
3. **Liquidity.** TVL swept into ranges and ether.fi is not sitting in the pool. Withdrawals need a
   buffer, and the buffer needs sweeps and reclaims that are keeper-gated, rate-limited and
   size-capped — because timing is the sensitive parameter here, and a sweep sized to exactly match
   one user's deposit reconstructs the link the ZK design exists to hide. The residual is real and
   bounded rather than eliminated: if demand outpaces both the buffer and the reclaim cadence, the
   pool is forced into a synchronous reclaim, which is the correlatable event. Buffer size, cadence
   and backstop capacity are a genuine three-way trade between capital efficiency, privacy and
   liquidity risk. The prior implementation of exactly this shape is recoverable at
   `ibiza@8fa5e9e^:backend/contracts/contracts/pool/spv/SpvTreasuryAdapter.sol`, 19 tests, and is the
   right starting point rather than a fresh design.
4. **Every LP exit inherits the identity and blacklist liveness dependency.** A withdrawal reverts if
   the anchor has no active snapshot, and today `RegistrySourceAnchor` has no wired on-chain write
   path for the ICAO workflow. **Forcing all TVL through the pool means the protocol cannot pay
   anyone until that is wired.** This is the single hardest launch dependency the change creates and
   it is not a contract-side fix.

**The ownership posture also has to be reconciled.** `Entrypoint` is UUPS-upgradeable behind
`_OWNER_ROLE`; §2.3 says ownership is renounced and pins are one-shot. Putting an upgradeable,
owner-controlled contract on the money path is a posture change, and it must be an explicit decision
recorded here rather than something absorbed by a file move.

### 4.5 The move itself

What moves: `pool/{PrivacyPool,Entrypoint,State}.sol`, both implementations, `lib/{Constants,ProofLib,
BatchVerifierLib,BatchCommitmentLib,DeployLib}.sol`, the pool interfaces, and the five Honk verifiers.
What stays behind a narrow interface: `IIdentityRegistry` and `IBlacklistAnchor` are one function
each on purpose, so the identity stack can deploy separately without widening the money path.

Four build blockers, measured, all of which must be cleared **before any file moves**:

| blocker | detail |
|---|---|
| **solc pin** | 16 pool files carry `pragma solidity 0.8.28;` — an exact pin, not a caret. This tree is `solc_version = "0.8.30"`. Loosen to `^0.8.28`. |
| **verifier size** | The Honk verifiers are ~24.5 KB against EIP-170's 24,576 at `optimizer_runs = 200`. ibiza survives on per-path `compilation_restrictions` with `optimizer_runs = 1` (measured there: 24,534 → 23,527 bytes for +0.6% gas on a ~2.76M-gas verify). `evm/foundry.toml` has no such block. |
| **remappings** | This tree maps `@openzeppelin/contracts-upgradeable/` to **plain OZ**, which has no `AccessControlUpgradeable` or `UUPSUpgradeable`. New dependencies: the real upgradeable lib, `poseidon-solidity`, `lean-imt`, `evidence-registry`. ibiza's bare `interfaces/` prefix collides with `src/spv/interfaces/` and must be scoped. |
| **build order** | Reconcile both `remappings.txt` and prove `forge build` green on the union first. Moving files first lands a repo that does not compile — ibiza's own recorded warning about this exact merge, and it is correct. |

---

## 5. Clients

### 5.1 The web surface is a landing page and nothing else

`spa/` reduces to marketing. The application moves to the phone (§5.2).

The current landing page is a **clone of `savewithcastle.com`** — its own source comment says so —
and it ships that company's logo, its investor logos, and **photographs of two named real people**
under `public/castle/images/team/`. It also asserts *"Banking services are provided through Quid Labs
partner banks."* All of that comes out: the third-party marks and photographs entirely, and the
banking claim unless it is true.

**The web/app split.** The discriminator is not BTC versus ETH — it is **what touches the channel
key**. Browsing, quoting, positions, swap-in and swap-out *requests*, and redemption views belong on
the web for both assets. Only four things need the app, because only they sign with the LP funding
half: the exits ladder (MuSig2, BIP-327), the payout-key proof-of-possession (BIP-340), the rekey
consent, and the liveness heartbeats. The web page must **refuse** the LP-side actions until the app
has produced the artefact they depend on, rather than letting them start and fail late — and the
on-chain state is already the source of truth for whether it has (`btcRecipientOf[lpEth] != 0` and
the armed-ladder state are both readable, so the gate needs no backend).

⚠️ **A swapper is not an LP.** Swap users never hold a funding half, so nothing about them should be
gated behind the app; gating them is a self-inflicted funnel loss.

### 5.2 One mobile app

The rarimo fork (`ibiza/frontend/identity-wallet`) and the Solana app (`seeker-main`) become one
React Native application carrying identity, the privacy pool, the EVM protocol surface, and the SVM
surface.

What each brings: the rarimo fork has `identity/` (one holder key, many documents — multi-citizenship
plus renewal and revocation), `pp/` (note derivation, discovery, withdrawal witness assembly, relay,
with tests), `passport/`, the forked rarime SDK, and a native Noir prover autolinked from a sibling
module. Its UI is a 78-line read-only shell. `seeker-main` has the Solana Mobile Wallet Adapter, the
Anchor client, and the ticker surface — and an app shell that actually renders.

Three things to fix in the merge rather than carry:

- **The chain layer is stale, not current.** `identity-wallet/src/chain/` is a port of the SPA's
  `lib/` taken *before* the `Vogue`→`Quid` rename and the `isBTC`→two-instances split. It still
  declares `POOLED_ETH`/`POOLED_BTC`/`POOLED_USD_ETH`/`POOLED_USD_BTC` as four selectors,
  `observe(uint32[], bool isBTC)`, `vogueETH`, `autoManagedBTC`, `lpSharesBTC` and a 5-argument
  `swap`. Re-port from `spa/src/lib/`, which is closer but **is not clean either**, so port from it
  with the checks below rather than by copying.
  ⚠️ **`tools/check-client-abis.py` reporting "67 signatures, 0 drifted" does NOT mean the client
  works, and this was measured rather than argued.** The checker reads `spa/src/lib/abi.ts` and
  nothing else. It cannot see a second declaration of the same call elsewhere in the client, it does
  not parse TSX, and it does not read `evm/deployments/l1.json`. With `spa/node_modules` present,
  `npx tsc --noEmit` found three things it had passed over: a JSX comment placed in an expression
  position so the leverage panel did not compile at all; a LOCAL `outOfRange` encoder in
  `(app)/app/page.tsx` still taking the `venue` fifth argument that `abi.ts:166` had already recorded
  as never having existed; and `chains.ts` reading `l1.range` from a deploy record whose key is still
  `vogue`, so the ETH range manager silently resolves to the zero address.
  ⇒ **`CLAUDE.md`'s "in this tree `tsc` cannot run at all: `spa/` has NO `node_modules`" is stale**,
  and that staleness is why the ABI checker was described as the only client-side gate available. Run
  both, and let both gate the commit.
- **`seeker-main/utils/deriveEthKey.ts` is broken.** It derives what it calls an Ethereum address
  using **NIST P-256** and hashes with **sha256**. Ethereum is secp256k1 and keccak256, so no
  signature from that key will ever recover to that address.
- **Version skew.** Expo 54 versus 57, React 19.0 versus 19.2. Pick one shell and one Expo version
  before porting anything.

The MuSig2 route is settled: `@scure/btc-signer` (`musig2.js` is a named export, v2.3.0 verified) —
`@noble/curves` does not ship MuSig2. **Use `deterministicSign`, not `nonceGen` + `Session`.** BIP-327's
deterministic mode derives the nonce from the secret, the message and the aggregated other-nonce, so
there is no secnonce to persist, leak or replay. This matters because the Rust `musig2` crate's
guarantee — `FirstRound`/`SecondRound` consume `self`, making reuse a type error — **does not cross
the language boundary**; in TypeScript, signing twice under one secnonce is an ordinary call that
type-checks, and two partials under one secnonce leak the LP's key while every on-chain byte still
looks correct. This tree has shipped that bug once already. `deterministicSign` requires every other
signer's nonce first, so it is available only to whoever signs last; in our 2-of-2 the hop presents
its nonce and the LP signs second, which is exactly that position. **Confirm the hop cannot be made
to sign second**, or the LP is forced back into stateful `nonceGen`.

**Do not adopt ERC-7947 for `lpEth`.** It reopens the attribution hole §3.3 closed, it is a trusted
off-chain attester accepting a proof, and it is redundant — `lpEth` *is* the channel key's address,
so an LP proves control of its own identity by signature with no third party. Recovery of a *lost*
key is a separate question and is not answered by that verdict.

---

## 6. Off-chain

Strategy logic lives in a keeper-style agent; the contracts hold consensus-critical state. The agent
holds no persistent delegate authority.

`quid-ln/` ships six long-running binaries — the bridge daemon, the LP daemon, the watchtower,
provisioning, auth migration and exit recovery — plus the leverage keepers, which are one more spawn
in the bridge's `JoinSet` rather than a new service. The hop node is the protocol's Lightning↔EVM
node, one instance; LPs run their own.

The daemons build for `x86_64-fortanix-unknown-sgx` and **are** the enclave. Off that target the
sealing path is `MockKeyRequest`, whose own docstring is the finding: *"It just samples a fresh key
for every sealing operation and stores the key adjacent to the ciphertext. NOTE: this does not
provide any security whatsoever."* ⇒ **In a container, "sealed" state is plaintext to anyone who can
read the volume.** A container buys host access control, not attestation and not sealing. That is a
coherent posture; it is simply not the enclave's, and it must be stated wherever the enclave's
guarantee is currently claimed.

The Rust workspace does not build on macOS at all (`quid-cvm` is Linux-only and transitive). Use the
image. `quid-ln/Dockerfile` is a **build** image, not a deployment artifact — it ends
`CMD ["cargo", "test", "--workspace"]` and has no release profile, no daemon entrypoint and no volume
contract for the channel-monitor data directory. The runtime image does not exist yet.

**The estimation stack is a client convenience, not a protocol component.** `spa/src/lib/kalman.ts`,
`quant.ts` and `regime.ts` characterise the present state — realised volatility, cross-asset beta,
mean-reversion strength, a regime label — and **forecast nothing**. No sequence model is trained on
price history, because a sequence model on price-only data for a liquid asset reproduces
`close_{t+1} ≈ close_t` with a one-period lag and that lag is not alpha. Nothing on-chain consumes
any of it. The one estimation quantity that *is* consensus-critical is σ², and it comes from `Core`'s
own oracle ring, never from a client.

---

## 7. Tried and rejected

Recorded so they are not re-litigated.

- **The surplus-funded make-whole (`arbETH`/`arbBody`/`refillETH`).** Surplus is `TVL − committed` —
  the shared safety margin, what we owe back — not a payout reserve. Spending it to make one exiting
  LP whole compensates that flow at every other claimholder's expense, which is the first-out-at-
  others'-expense pattern the redemption path already refuses. The replacement is R1: the LP bears
  its own IL through the share price.
- **The below-entry short leg.** Realises the down-side loss and forfeits the recovery. §3.6.
- **`setTargetLtv` and the per-LP cap.** §3.6.
- **The boundary-order "ratchet".** Tested across GBM, OU, real-data variance-ratio, real-data
  breakeven and the BTC delivery model: spread capture ≈ 0 in every one. Removed as inert machinery.
  A passive LP cannot escape adverse selection with limit orders either — they suffer the same
  selection.
- **A V4 dynamic-fee hook.** Flow cannot be classified cleanly at quote time and the depth-versus-fee
  trade makes it more liability than edge. Viability does not rest on it.
- **Regime-adaptive repack width.** Legitimate and leverage-free, but net-new machinery (a vol
  estimator, an adaptive-width path, the test surface) for marginal IL saved over the fixed range.
  Documented in case the calculus changes at scale.
- **Depeg prediction markets as insurance.** The no-incident side would be the same dollars backing
  QD, so a payout double-spends the backing; it is pro-cyclical, firing exactly when the basket is
  already impaired; and it un-socialises a loss that pro-rata redemption already socialises fairly.
  The only non-broken variant needs *external, segregated* reinsurance capital flowing **into** the
  basket, which is a different product.
- **YieldBasis-style leverage on the volatile leg.** It converts √p to p with a maintained 2× and
  pays for it with borrow fees plus half the trading fees — which is what no-arbitrage forces, since
  hedging the curvature costs about the IL itself. It buys a flow cost in place of a holding loss and
  bolts on liquidation risk, borrow drag and crvUSD reflexivity. We decline all of it.
- **`vBTC` through the privacy pool.** Nobody ever holds vBTC — it is an internal accounting token
  inside the leverage machinery, not a wrapper anyone can custody — so there is no holder population
  to build an anonymity set from.
- **A "cheapest venue wins the flow" pitch.** False, and it contradicts `fees ≈ IL`. Cutting the fee
  makes you the venue CEX–DEX arbitrageurs correct first and hardest; racing the tier down grows both
  sides of `fees − IL` without raising the difference. The honest addressable number is uninformed,
  markout-neutral fee-paying volume, not headline through-volume.
- **Mortgage origination and underwriting.** Four of the five roles need a licence. The fifth is
  capital, which is the one we have — so if property credit ever happens it is as a distributor:
  a licensed originator finds the borrower, values the property, sets terms and creates the lien;
  the reserve funds the loan and holds the paper; the originator services it.

---

## 8. Open

1. **The PP note format.** §4.4 records the share-count decision and its four costs. Cost 2 (the JIT
   lock becoming a shared surface) needs a fresh grief analysis before launch; cost 4 (the anchor
   liveness dependency on every exit) is a launch blocker owned outside this repo.
2. **The `Entrypoint` upgradeability posture** against §2.3's renounce-and-pin discipline.
3. **Denomination and split policy** — the parameter that decides whether §4.2's anonymity set is
   real.
4. **The batch fill policy.** The aggregator proof machinery is built (`build-recursion-tree.py`,
   `TreeRoot{8,16,32}HonkVerifier`, `BatchCommitmentLib`, `PrivacyPool.withdrawBatch`). What is
   unbuilt is the operational wrapper: which pending withdrawals to collect, when to fire, invoking
   the tree build, submitting the root. **Do not re-derive or re-implement the aggregation itself.**
5. **The `exits` ladder on the phone** — the last piece of the LP signer, blocked on BIP-327 and on
   confirming the hop always signs first.
6. **The runtime container image**, and the volume contract for the channel-monitor data directory.
7. **A usable archive RPC.** Both ankr keys in `evm/.env` are dead at the provider. Pinned fork runs
   currently work only by pinning `FORK_BLOCK` to a recent block on the keyless public node, which
   makes the run deterministic and disk-cacheable but not archival.
8. **The `LevManager` byte margin**, which has been the binding contract at last measurement. Re-run
   `tools/check-contract-sizes.py` rather than trusting any figure written down anywhere.
9. **Two pre-existing client defects, both in the `/app` half that §5.2 replaces**, surfaced the
   first time `tsc` was run in `spa/`. Neither is fixed here, because each needs its own change:
   `computeChannelDigest` is called twice in `(app)/app/page.tsx` and defined nowhere, so the
   openChannel flow cannot run; and `evm/deployments/l1.json` still keys the ETH range manager as
   `vogue` while `chains.ts` reads `l1.range`, so `CONTRACTS.range` resolves to the zero address.
   The second is the `Vogue`→`Quid` rename never reaching the deploy record, and the fix belongs in
   `DeployL1_s`'s JSON writer plus a redeploy — the file's own comment forbids hand-editing it,
   because CREATE addresses are a function of deployer and nonce and an invented one silently
   answers nothing.

---

## A. Corrections ledger

Claims in circulation that the code contradicts. Check here before quoting `docs/informational/` or
`docs/FAQ.md`.

| claim | status | evidence |
|---|---|---|
| "the range is ~2%", "`_updateTicks(sqrtPriceX96, 200)`" | 🔴 wrong on both counts | `RANGE_DELTA = 20` ⇒ ±0.2%, `imports/SwapLib.sol:824`; no such call exists, and there are no ticks |
| "the depositor chooses an ETH venue (codes 0/2/3/4/5/6)" | 🔴 stale (`docs/FAQ.md`) | one destination, weETH, no dispatch — `imports/QuidLib.sol:140-145` |
| "`setTargetLtv(capBps)` lets the depositor set direction" | 🔴 deleted | §E358, `imports/LevBase.sol:404`; one protocol-wide `TARGET_LTV_CAP_BPS = 7500` |
| "eleven stablecoins" | 🔴 stale | **fourteen**, and that is the `uint[15]` layout maximum — `script/DeployL1_s.sol:239-254` |
| "the outflow fee has three terms including `baseRate`" | 🔴 removed | `_br`, `_touchBaseRate`, `BR_DECAY`, `BR_MAX_MIN` gone; reason at `Core.sol:168` |
| "depeg severity is the worse of the CRE report and a live feed" | 🔴 CRE removed | pinned per-stable Chainlink feeds are the signal |
| "the swap-in bonus compensates a JIT actor" | 🔴 instrument removed | `payRefillBonus` deleted 2026-07-22; the retained premium is the compensation |
| "`skewWad = Γ·σ²·q/(1−q)^ρ`" | 🟠 stale comment at `imports/QuidLib.sol:205` | the curve is **linear**, `Γ·σ²·q` — `imports/SwapLib.sol:1014-1022`, `:1333`. The σ²-cancellation argument survives unchanged |
| "the basket's surplus absorbs the LP's IL (θ-bounded)" | 🔴 overruled | R1 — the LP bears its own IL via the share price; `arbETH` removed |
| "range bounds are stored" | 🔴 no longer true | `deltaBps`/`pLower`/`pUpper` deleted; composition is width-independent |
| "`BatchVerifierLib.PUB_LEN` is still 7, so the batch path bypasses the predicate" | 🔴 stale (`SPRINT.md`) | `PUB_LEN = 8` in both batch libraries; `s[7]` is the blacklist root and is re-anchored per withdrawal |
| "SPV must contain zero references to PP" | 🔴 superseded | §4.1 |
| "solvers quote the exact number a swap executes at" | ✅ fixed 2026-08-16 | was the instantaneous rate against a settlement charging the integral — a 90%-of-range drain filled 4.12× worse than quoted. `wellSkew(asset, drainUsd6)` added |
| K = 0.71 guard-on, θ ≈ 0.25–0.40, the 2020-03-12 crash figure | 🟠 off-basis | all keyed to ±2%; historical LVR data, not a live safety argument |

---

## B. Glossary

**basket** — the diversified stablecoin reserve in `Aux` backing QD.
**deliverability** — what a venue can pay *now* (`maxWithdraw`), as distinct from what it is worth
(`convertToAssets`). Illiquidity defers value; insolvency destroys it.
**drain tax** — the yield-versus-baseline term of the redemption fee.
**haircut** — the depeg reduction, a separate uncapped axis from the fee.
**hop** — the protocol's Lightning node, counterparty to every LP channel.
**K** — the concentrated-liquidity LVR coefficient, `1/(4(2 − √(P/Pb) − √(Pa/P)))`. Pure geometry.
**LVR** — loss versus rebalancing; the continuous-time variance tax an in-range LP pays informed flow.
**overlay** — the opt-in, up-side-only IL hedge (§3.6).
**pooled / vogue counters** — `POOLED_*` are **gross** and include the levered buffer; the `vogue*`
views are **net** and exclude it, because an asset matched by an equal debt contributes zero equity.
**q** — Avellaneda–Stoikov scarcity, `(target − inventory)/target`.
**repack / reseat** — re-centring the range on the current price. Moves no value by swapping and is
skipped when spot deviates from TWAP, so IL is never crystallised into a manipulated print.
**skew** — the reservation premium charged for inventory risk. The skew *is* the fee.
**θ** — the derived in-range depth budget, `rangeFeeYield / (K·σ²)`. Fails open at 1e18.
**vBTC** — the synthetic sats-denominated underlying the BTC range's `asset()` points at. Nobody
holds it.
