# Connecting the Vogue/Aux venue to Khalani's solver backend

**Status:** DESIGN / actionable. Scopes what it takes to make our on-chain venue (Vogue band + Aux
basket router) a liquidity source that Khalani (Arcadia) order flow routes through. No code yet.
Grounded in a read of Khalani's actual SDK — `github.com/tvl-labs/arcadia-sdk-rs` — not marketing pages.

---

## 0. TL;DR — the connect path is "run an Arcadia solver," not "expose a maker endpoint"

Khalani is a **decentralized solver network + cross-chain intent settlement hub** (product name
**Arcadia Intents Protocol**; company **TVL Labs**). It sits *below* the order-flow-auction layer
(1inch Fusion / CoW / UniswapX) and *beside* individual fillers (Bebop) — it is **infrastructure**, not
an app we compete with.

**Critical finding from the SDK:** Khalani has **no first-class "register a maker, we'll call your
contract / poll your RFQ" path.** The only way our liquidity participates is by a **solver** choosing to
source a fill through it. So "connect our venue to Khalani's solver backend" concretely means:

> **We run our own Arcadia solver** (a Rust binary using `arcadia-sdk-rs`) that connects to Khalani's
> **Medusa** hub over WebSocket, subscribes to intents, and — for legs we can price well — submits a
> **Solution** whose fill it sources on-chain via **`Aux.swapTo`** on Ethereum L1, settling through
> Khalani's per-chain **AssetReserves ("spoke")** contract.

Our on-chain venue needs **no changes** — `Aux.swapTo` is already ungated, `minOut`-bounded, and
explicit-recipient. The whole build is the **off-chain solver binary** + the mToken/settlement plumbing.

---

## 1. Khalani / Arcadia backend architecture (as it actually is)

From `tvl-labs/arcadia-sdk-rs` (`crate arcadia-sdk-rs 0.1.0`, edition 2024, `alloy 1.0`, `tokio`,
`jsonrpsee`, `tokio-tungstenite`):

- **Medusa** = the intent-coordination hub (the mempool + matcher). Solvers connect via **WebSocket**
  (`src/client/medusa_ws.rs`, `create_medusa_ws_client(url, signed_add_solver)`) and/or JSON-RPC
  (`src/client/medusa_rpc.rs`). The WS gives a `Receiver<WsBroadcastMessage>` (intents in) and a
  `Sender<WsPayload>` (solutions out).
- **Solver registration:** EIP-712 **`SignedAddSolver`** (`src/types/rpc_payloads.rs`) — sent as
  `WsPayload::AddSolver(...)` on connect. This is the auth/onboarding handshake.
- **mTokens:** intents are denominated in **mTokens** — Arcadia's canonical multi-chain asset
  representation, *not* raw ERC20s. Real tokens become mTokens by depositing into a spoke's
  `AssetReserves`; mTokens become real tokens by withdrawing.
- **Intent model** (`src/types/intents.rs`):
  ```rust
  struct Intent { author, valid_before, valid_after, nonce,
                  src_m_token: Address, src_amount: U256, outcome: Outcome }
  struct Outcome { m_tokens: Vec<Address>, m_amounts: Vec<U256>,
                   outcome_asset_structure: OutcomeAssetStructure,  // any-single | any-combination | all
                   fill_structure: FillStructure }                  // Exact | Minimum | PercentageFilled | Range
  ```
  `fill_structure ∈ {Minimum, PercentageFilled, Range}` ⇒ **partial fills are first-class** — this is the
  collaborative-solving / "refinement" primitive.
- **Solution model** (`src/types/solution.rs`):
  ```rust
  struct Solution { intent_ids: Vec<B256>, intent_outputs: Vec<Intent>, receipt_outputs: Vec<Receipt>,
                    spend_graph: Vec<MoveRecord>, fill_graph: Vec<FillRecord> }
  ```
  A solver expresses *how* it fills via `spend_graph` (asset movements, `qty: U256`) + `fill_graph`
  (which output satisfies which input). Emitting a residual `intent_outputs` entry = **refine**: solve
  the slice you're best at, hand the rest back for other solvers to complete. Submitted as
  `SignedSolution`.
- **Settlement = `AssetReserves` spoke contract, per chain** (`src/client/spoke.rs`):
  - `deposit(token, amount)` (with ERC20 `approve`) — put real tokens in → mint mToken.
  - `withdrawWithPermit(permit, receiver, user_signature, operator_signature)` — release real tokens
    out, co-authorized by the user *and* the Medusa **operator** signature.
  - Cross-chain messaging is Hyperlane (Khalani forks `hyperlane-monorepo-khalani`).

**So the solver's job:** watch Medusa → for a winnable intent, hold or acquire the output mToken → post a
Solution → settle on the spoke. **Our venue is where the solver *acquires the underlying asset*.**

---

## 2. Our on-chain connect surface (verified by direct read + Explore sweep)

The V4 band trades **mock tokens behind `onlyUs`** (`Vogue.sol:218`); no external party can arb the pool
directly. The **only** external door into our liquidity is `Aux.swap*`, which prices a stable/QUID ↔
WETH/WBTC swap against the oracle band, minting/redeeming against the basket:

```solidity
// evm/src/Aux.sol:661 / :674  — ungated public, nonReentrant, minOut-bounded, explicit recipient
function swap  (address token, address asset, bool forVolatile, uint amount, uint minOut) public payable returns (uint);
function swapTo(address token, address asset, bool forVolatile, uint amount, uint minOut, address recipient) public payable returns (uint);
```
- `asset` **must be WETH or WBTC** (`SwapLib.sol:546`); `token` = a registered basket stable, QU!D, or
  `0` when paying volatile. `forVolatile` picks direction.
- **WBTC constraints:** WBTC swap-*in* is disallowed (`BtcInflowsViaChannels`, `SwapLib.sol:548`); WBTC
  swap-*out* to a non-self recipient needs a pre-registered `btcRecipientOf` (`SwapLib.sol:551`). So the
  clean same-chain legs a solver serves first are **stable/QUID ↔ WETH** and **WETH → stable/QUID**.
- Every swap enforces a 0.5% manip band vs TWAP (`BasketLib.sol:475`) and a live backing-solvency check
  (`SwapLib.sol:565`). `minOut` reverts protect us on fast moves ⇒ **zero settlement/latency risk to us**.
- **Pricing views (no true `getAmountOut`):** `Aux.getTWAPforAsset(asset, period)` (`Aux.sol:627`) and
  `Aux.resolvedTwap(asset, period) → (price, stale)` (`Aux.sol:648`), Chainlink-anchored. Our solver
  computes the fill price off these + band + fee + haircut. **Scale caveat:** USD-18 per `1e18` raw;
  WBTC ×`1e10`; sats→usd `/1e18` ([[reference-gettwapforasset-scale]]).
- **Proven adapter template (in the production stack):** `evm/src/SorExchange.sol` wraps `Aux.swap`
  behind Liquity's `IExchange` — `transferFrom` in → `forceApprove(AUX)` → `AUX.swap(...)` →
  `safeTransfer` out. This is the pattern our solver's on-chain execution mirrors (or it just calls
  `swapTo` directly via alloy). `Aux.swap` is published as the canonical seam via `imports/ISwap.sol`.
- **Also open, caller-funded, real-V4 (no basket redemption):** `Aux.sorSelfFunded` /
  `sorSelfFundedReverse` (`Aux.sol:768/:784`) for pure stable↔WETH routing if a fill needs that instead
  of a basket swap.

> Note: `old/evm/src/Solver.sol` (a Bebop-JAM `JamSolver` over an `Aux.flashLoan`) is **reference-only —
> not part of the production stack**, and current SPV `Aux` has no `flashLoan`. Do not port it; see §5.

---

## 3. The structural fit — and the discipline it imposes

- We plug in as a **liquidity source behind our own solver**, quoting a **firm two-sided price**, not as
  an AMM pool a solver simulates/sandwiches (mock-pool + `onlyUs` prevent that anyway —
  [[reference-mock-quid-pool-no-external-lvr]]).
- **TAM discipline:** our edge is **uninformed fee volume**, not "cheapest venue"
  ([[project-quid-orderflow-tam-truth]]). The solver quotes a real spread tracking live cost; it does
  **not** win by being the cheapest crash route ([[reference-quid-procyclical-intermediary-caution]]).
  Arcadia's **partial-fill / refinement** model is exactly the knob for this: fill only the slice our
  band serves at a good price (`fill_structure = Minimum/Range`), refine the rest back to the network.
- **We already speak the pricing shape.** [`BTC-MARKET-MAKING-SPEC.md` §5](./BTC-MARKET-MAKING-SPEC.md)
  commits to a Bebop-shaped firm-quote engine (skew curve, quote-expiry locking the band for the
  delivery window). That **quoting/pricing logic is reused inside our Arcadia solver** — only the
  *transport* differs (Medusa WS + `Solution` instead of Bebop `settle()`).

---

## 4. mTokens — the gating dependency

Intents reference **mTokens** (`src_m_token`, `outcome.m_tokens`), so we can only serve intents whose
legs are assets Arcadia has minted mTokens for.

- **WETH / USDC** almost certainly have Arcadia mTokens today ⇒ serve those legs first (monetize basket
  depth: e.g. an intent "X mUSDC on Base → mWETH on Ethereum" — our solver fills the Ethereum WETH leg
  from the basket via `swapTo(USDC, WETH, forVolatile=true, ...)`).
- **QU!D** (and our specific stables GHO/USDG/BOLD) are **almost certainly not mTokens yet.** For anyone
  to express "I want QU!D" as an Arcadia intent, QU!D must be onboarded as an mToken (coordinate with TVL
  Labs). Until then we are a *liquidity source for the WETH/stable legs*, not a QU!D distribution channel.
- **Decision to surface:** is the goal (a) earn basket fees by filling WETH/stable legs of others'
  intents [no listing needed], or (b) distribute QU!D via Arcadia [needs mToken onboarding + Hyperlane
  route]? (a) is buildable now; (b) is a partnership + listing track. See §7.

---

## 5. Build plan

### Model recommendation
The connect path **is** running an Arcadia solver. There is no lighter "maker registration" tier in the
SDK. Reject the flash-capital model (§6). Two staged builds:

### Phase 0 — a read-only Arcadia solver (observe, don't fill)
1. New Rust crate (fits our keeper stack — `quid-ln`, `lev_keeper`, `rebalancer` are already Rust) that
   depends on `arcadia-sdk-rs` + `alloy`. Connect to **Medusa** via `create_medusa_ws_client`, register
   with a `SignedAddSolver` signed by a dedicated fleet key (reuse our EVM signer infra;
   [[project-quid-lp-automation-selfhost]]).
2. Subscribe to `WsBroadcastMessage` intents; **for each, compute the price we *would* quote** from
   `getTWAPforAsset`/`resolvedTwap` + band + fee/haircut + spread (reuse BTC-MM §5 pricing). **Do not
   submit solutions yet** — log fillable rate, competitiveness, and which legs (WETH/USDC) map to our
   mTokens. Validates flow + economics before touching money.
3. Confirm from live traffic: which mTokens/legs appear, spoke/`AssetReserves` addresses, operator
   signature flow, quote-firmness window vs our manip-guard recenter (`Vogue.sol` `_rebalance`).

### Phase 1 — live solver (fill for real)
4. On a winnable intent, build a `Solution` (`intent_ids`, `spend_graph`, `fill_graph`, residual
   `intent_outputs` for partial fills), acquire the output asset by calling **`Aux.swapTo`** on L1
   (recipient = the solver's settlement address), `deposit` it into the spoke `AssetReserves` to satisfy
   the fill, and submit `SignedSolution`.
5. Settle via `AssetReserves.deposit` / `withdrawWithPermit`; handle the Medusa **operator** co-signature
   on withdrawal. Bound every `swapTo` with `minOut` = our quoted floor ⇒ if the band moved, our leg
   reverts and the solution fails atomically (no unhedged exposure).
6. Inventory model: either **just-in-time** (swap the basket per fill) or **warehouse mToken inventory**
   and rebalance it against the basket periodically. Start JIT (zero warehouse, cleanest custody story);
   graduate to a small warehouse only if latency demands it.

### Cross-chain / native-BTC note
For legs delivering **native BTC**, the solver would drive our swap-out rails (LN / on-chain HTLC —
[[project-quid-swapout-lightning-gap]], BTC-MM §5), not `swapTo`. **Scope Phases 0–1 to EVM WETH/stable
legs**; native-BTC delivery is a later phase gated on the swap-out rails.

---

## 6. Why NOT a flash-capital model

`old/evm/src/Solver.sol` (reference-only, non-prod) lends the basket as flash capital to a JAM solver.
Re-creating that for Arcadia would require re-adding `Aux.flashLoan` (audit-heavy new surface on
committed backing — [[reference-quid-backing-invariant]]) and buys nothing: an Arcadia solver needs our
*price*, not our *capital*. `swapTo` delivers the fill atomically. Only revisit if a concrete Arcadia
flow forces us to pre-fund a multi-hop before the taker's asset arrives — and even then prefer
settle-then-claim ([[project-quid-btc-swapin-atomicity-aave-cap]]).

---

## 7. Open questions to resolve against Khalani before Phase 1

1. **mToken coverage:** exact mToken set + `AssetReserves`/spoke addresses on Ethereum (and which of
   WETH/USDC we can serve day 1). Is QU!D onboardable as an mToken, and at what cost? (§4 decision.)
2. **Solver onboarding:** is Medusa solver registration permissionless (just `SignedAddSolver`) or
   gated/staked? Any bond, allow-listing, or reputation requirement? (Marketing says "permissionless" —
   verify against the live hub.)
3. **Operator trust in settlement:** `withdrawWithPermit` needs an **operator** signature (Medusa). Map
   the exact trust assumption — what can a malicious/faulty operator do to an in-flight solution? (Our
   `minOut` bounds *our* leg, but understand the settlement-side failure modes.)
4. **Quote firmness vs the band:** reconcile Arcadia's expected solution-commit window with our
   manip-guard recenter; mark the RFQ offset as a sanctioned inventory offset (same reconciliation as
   BTC-MM §2a/§6b).
5. **Spread/refinement policy:** the two-sided spread + when to fully-fill vs refine-and-partial-fill —
   live-cost-tracking, TAM-disciplined (§3). Owner decision, akin to [[SOR-SIGNIFICANCE-DESIGN.md]].
6. **Demand side (separate track):** if we *also* want to source cross-chain flow *into* our SPA, that's
   the **Hyperstream API** / **TokenFlight** widget (`POST /v1/quotes` → `/deposit/build` → `/deposit/submit`
   → track) — the taker side, orthogonal to being a solver. Note but don't scope here.

---

## References
- Khalani SDK (external, read 2026-07): `github.com/tvl-labs/arcadia-sdk-rs` — `client/medusa_ws.rs`
  (`create_medusa_ws_client`, `WsPayload`/`WsBroadcastMessage`), `client/medusa_rpc.rs`,
  `client/spoke.rs` (`AssetReserves.deposit` / `withdrawWithPermit`), `types/intents.rs`
  (`Intent`/`Outcome`/`FillStructure`), `types/solution.rs` (`Solution`/`spend_graph`/`fill_graph`),
  `types/rpc_payloads.rs` (`SignedAddSolver`, `SignedSolution`). Demand side: `hyperstream-sdk` (TS),
  `tokenflight-embed-examples`. Cross-chain messaging: `hyperlane-monorepo-khalani`.
- Our code (verified): `evm/src/Aux.sol:661` `swap`, `:674` `swapTo`, `:627` `getTWAPforAsset`, `:648`
  `resolvedTwap`, `:768`/`:784` `sorSelfFunded[Reverse]`, `:730` `auxSwap` (onlyUs, internal);
  `evm/src/imports/SwapLib.sol:546-565` (asset/stable/backing gates), `imports/ISwap.sol` (the seam),
  `imports/BasketLib.sol:475` (manip band); `evm/src/Vogue.sol:218` (`onlyUs`/mock band);
  `evm/src/SorExchange.sol` (proven thin adapter over `Aux.swap`).
- Sibling specs: [`BTC-MARKET-MAKING-SPEC.md`](./BTC-MARKET-MAKING-SPEC.md) §5 (reusable firm-quote
  pricing spine), [`SOR-SIGNIFICANCE-DESIGN.md`](./SOR-SIGNIFICANCE-DESIGN.md).
- Memory: [[project-quid-btc-market-structure]], [[reference-mock-quid-pool-no-external-lvr]],
  [[project-quid-orderflow-tam-truth]], [[reference-quid-procyclical-intermediary-caution]],
  [[reference-gettwapforasset-scale]], [[project-quid-swapout-lightning-gap]],
  [[project-quid-lp-automation-selfhost]], [[feedback-use-proven-code-never-handroll]].
