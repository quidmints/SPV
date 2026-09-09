# spec.md — the protocol

The deployed system as the code defines it. Every claim carries a `file:line` into `evm/`. Where this
file and the contracts disagree, the contracts win.

The authority for what is deployed is `DeployLib.deployQuidStack` (`evm/script/DeployLib.sol:120`),
called once from `evm/script/DeployL1_s.sol:300-326`.

⚠️ **A naming trap in the deploy script, stated up front because it changes what its lines mean.**
`DeployL1_s.sol:192-193` declares `Vault public ETH;` and `Vault public BTC;` and then sets
`BTC = ETH` (`:324`), both pointing at the **`Vault`** (`:323`, `a.vault = address(BTC)` at
`DeployLib.sol:242`). The handle named `ETH` is *not* the ETH range manager — `Quid` is — and its
comment ("merged Vault — ETH-venue face") predates §ETHVENUE-FOLD, which moved the ETH venue into
`Quid`. Consequently `Ownable(address(ETH)).renounceOwnership()` at `:571` renounces the **Vault**.

---

## 1. The deployed contracts

### 1.1 `Quid` — the ETH range manager, and the ETH yield venue

`evm/src/Quid.sol:38`. Constructed first (`DeployLib.sol:121`), wired by `Quid.setup(quid, aux, core)`
(`Quid.sol:456`), which renounces its own ownership in the same call (`Quid.sol:461`).

Two things at one address. As **range manager** it holds the ETH LP book: per-LP state lives in the
shared base `Shares` (`evm/src/Shares.sol:67`), where `balanceOf(user)` *is*
`autoManaged[user].pooled` — the balance is the position, which is why the ERC-20 face is hand-rolled
rather than inherited. Its token face is `vETH` (`Quid.sol:1627`) and `asset()` returns WETH
(`Quid.sol:1630`). As **yield venue** it holds ether.fi `weETH` directly (`Quid.sol:109`, `:190`);
there is no separate ETH-venue contract and `Aux` is pointed at `Quid` for that role
(`DeployLib.sol:234`).

### 1.2 `Core` ×2 — the range engine, one instance per asset

`evm/src/Core.sol:42`. **The same bytecode deployed twice** (`DeployLib.sol:139-140`):

```solidity
core         = new Core(cfg.weth, SwapLib.ethRisk());
Core btcCore = new Core(cfg.wbtc, SwapLib.btcRisk());
```

There is no `isBTC` flag. Each instance is told its asset and risk profile directly and exposes
exactly one `POOLED` and one `POOLED_USD` (`Core.sol:68,71`). Neither can see the other's dollars.
The only shared bound is the sum: each pushes its equity to `Aux`, and every in-range USD add
requires `committedUsd18() <= haircutTvl`.

Both are configured by `Core.setup` (`Core.sol:818`). The ETH instance's range manager is `Quid`; the
BTC instance is set up with a zero range and receives its manager later through `setBtcVault`
(`Core.sol:717`).

**No observation source is pinned on either instance** (`DeployLib.sol:143`, `Core.sol:1515`). The
consequence is stated rather than left to be found: the observation ring is never written,
`ringVariance` returns 0, and unmeasured variance is priced at the ceiling. Prices come from the
pinned Chainlink anchors (`Aux.getTWAPforAsset`, `Aux.sol:746`).

### 1.3 `Aux` — settlement adapter and joint accountant

`evm/src/Aux.sol:37`. Constructed with both range addresses, both `Core` addresses and the
`stables[]` / `vaults[]` arrays (`DeployLib.sol:163-170`), so its denominator is complete from birth.
It owns the fourteen basket stablecoins and their positionally-paired venues; the swap entrypoints
`swap`/`swapTo` (`Aux.sol:873,886`); basket deposit (`:1288`) and redemption (`:1043,1054`);
`committedTotal()` (`:1227`) and the backing checks that read it (`:1238,1260`); permissionless vault
health `pokeVaultHealth` (`:487`); and the one-shot deploy wiring `configure` (`:669`) / `wire`
(`:687`).

### 1.4 `Basket` — the QU!D token

`evm/src/Basket.sol:20`. Three faces on one contract: **ERC-20** `"QU!D"`/`"QUI"` (`:149`) for the
matured, 1:1-backed pool; **ERC-6909** dated monthly tranches keyed by `currentMonth()` (`:260`) for
immature months; and a **LayerZero V2 OApp** to Solana, `SOLANA_EID = 30168` (`:41`), sent by
`bridgeToSolana` (`:177`) and received by `_lzReceive` (`:214`). The endpoint is taken at
construction because an OApp's endpoint is immutable — there is no setter to get wrong later.

Protocol-internal minting is restricted by `Basket.auth()` to three addresses: `AUX`, `RANGE`
(`Quid`) and `BTC_VAULT` (`Vault`) — `Basket.sol:81-90`. The constructor requires the deployer to
have approved `Aux` for the Foundation ANGEL NFT, tokenId 16508 (`Basket.sol:74`), so it cannot be
born without the seed commitment in place.

### 1.5 `Vault` — the BTC range manager

`evm/src/Vault.sol:70`, constructed on the **BTC** `Core` (`DeployLib.sol:230`). It carries the BTC
side of the same `Shares` state `Quid` carries for ETH, and deploys `VBtc` in its constructor
(`Vault.sol:179`).

It has **no user-facing deposit**. Its position entrypoints are `onlyBTCChannels`: `requestDeposit`
(`:449`), `requestRedeem` (`:541`), `resize` (`:553`). Permissionless upkeep is `syncLev` (`:478`),
`collectFees` (`:615`), `compound` (`:648`).

### 1.6 `VBtc` — the 8-decimal BTC position token

`evm/src/VBtc.sol:54`. `decimals = 8` because vBTC *is* sats. `VAULT` is immutable and is the only
address that may mint or burn (`:64,88`); `mintTo` is declared at `:131` and has exactly one call
site, `Vault.sol:280`, inside `exposeBtcToLev` — so the entire vBTC supply is the levered slice.
`asset()` returns WBTC (`:95`) as a **pricing handle only**; the 4626 face is a pure identity
(`convertToAssets(x) == x`, `:96-97`), because the shares *are* the underlying unit.

### 1.7 `SPVGateway` — the Bitcoin header chain

`evm/src/spv/SPVGateway.sol`. Initialised from a checkpoint header, height and cumulative work plus
the headers that follow it — the followers both catch the gateway up and prove the checkpoint
canonical, so an orphaned checkpoint reverts the deploy rather than bricking silently later
(`DeployL1_s.sol:314-322`). Header submission is permissionless: `addBlockHeader` and
`addBlockHeaderBatch` have no caller gate. `checkTxInclusion` is the merkle-inclusion check every
Bitcoin-facing path in `BTCChannels` routes through, and it reads `blocksHeightToBlockHash` so an
orphaned chain cannot vouch for a transaction.

### 1.8 `BTCChannels` — the per-LP Lightning channel registry

`evm/src/BTCChannels.sol:112`. Lifecycle: `openChannel` (`:926`), `splice` (`:1138`),
`registerChannelClaim` (`:1076`), `recordClose` (`:1788`), `recordForceClosePermissionless` (`:1949`),
`emitDeadManExit` (`:1431`) / `recordDeadManExit` (`:1891`). Swap rails: `settleSwapInProven` (`:2076`),
`requestSwapOutOnchain` (`:2232`), `deliverSwapOutOnchain` (`:2302`), `reverseSwapOut` (`:2141`),
`refundExpiredSwapOut` (`:2184`). An LP pins its BTC payout key with `setBtcRecipient` (`:2443`).

The exit ladder is bounded at both ends: `if (exits.length < 2) revert LadderTooShallow();` and
`if (exits.length > MAX_LADDER_RUNGS) revert LadderTooDeep();` (`:1489`, `:1492`,
`MAX_LADDER_RUNGS = 16` at `:513`), both checked **before** the verify loop at `:1499`.

Measured 21,241 deployed bytes against the EIP-170 limit of 24,576.

### 1.9 The leverage overlay

Deployed by the same script, opt-in behind `DEPLOY_LEV=1` (`DeployL1_s.sol:506`) and skipped entirely
when unset.

- `LevManager` over weETH collateral, three allowlisted venues pinned once and frozen: Morpho
  weETH/RLUSD 86% (`DeployL1_s.sol:664`), Morpho weETH/PYUSD 86% (`:668`), and an Aave V3 venue with
  weETH collateral and USDT debt (`:686`). Both weETH/USDC markets and the weETH/WETH venue are
  **absent, not demoted** — the file records the measurement: weETH/USDC held $0.17M idle across 100
  of 100 weeks, against $9.66M (RLUSD) and $4.32M (PYUSD).
- `BtcLevManager` over vBTC collateral with **one** venue: an Aave V3 escrow, WBTC collateral, a
  deploy-chosen stable debt asset defaulting to USDC (`DeployL1_s.sol:559-567`).
- There is **no Morpho market whose collateral token is vBTC**, by standing owner ruling: collateral
  and acquisition target would be the same asset, so a drawdown margin-calls the very thing the
  borrow bought (`DeployL1_s.sol:525-533`).

Leverage is bounded by **one protocol-wide constant**, `LevBase.TARGET_LTV_CAP_BPS = 7500`
(`evm/src/imports/LevBase.sol:51`). There is no per-depositor target setter.

⚠️ The cap is quoted **debt-over-equity** while a venue LLTV is **debt-over-collateral**, so the two
are only comparable after `c/(1+c)`: 7500 in cap terms is 4285 in venue terms, and the headroom under
Morpho's 86% LLTV is `8600 − 4285 = 4315` bps (`LevBase.sol:122-123`).

---

## 2. The trust model

There are no roles, no governance, no timelock and no upgrade path. Authority is expressed as
explicit address-set comparisons, enumerated here in full.

| contract | gate | who |
|---|---|---|
| `Aux` | `onlyOwner` — `configure` (`:669`), `wire` (`:687`), `evacuate` (`:517`), `finalize` (`:702`) | the deployer, until `finalize()` |
| `Basket` | `Ownable`; `auth()` (`:81`) for protocol-internal mints | deployer until renounce; `auth` is the fixed set {`AUX`, `RANGE`, `BTC_VAULT`} |
| `Quid` | `onlyOwner` on `setup` only (`:456`); `_onlyPinner` = `msg.sender == DEPLOYER` (`:126`) | deployer, then `immutable DEPLOYER` |
| `Core` | `msg.sender == DEPLOYER` on `setup` (`:818`), `setBtcVault` (`:717`), `setObservationSource` (`:1634`) | `immutable DEPLOYER` (`:785`) |
| `Vault` | `Ownable` (`:70,176`) — `setup` (`:195`), `setLevManager` (`:227`); plus `onlyUs` (`:139`) / `onlyBTCChannels` (`:161`) | the deploy script |
| `BTCChannels` | `_onlyHop()`: `msg.sender == MAIN_HOP \|\| msg.sender == FALLBACK_HOP` (`:834`) | two immutables (`:805-806`), assigned once in the constructor |
| `VBtc` | `onlyVault` (`:88`) | `immutable VAULT` (`:64`) |
| `SPVGateway` | none on header submission | anyone |

`BTCChannels` has **no owner at all** — it is not `Ownable` and declares no owner slot; `owner`,
`transferOwnership` and `renounceOwnership` are absent from its ABI. Its hop authority is the two
immutable addresses and nothing else: no setter, no registry, no multisig. Either hop may act on any
channel. `_onlyHop()` has exactly **eight** call sites: `openChannel` (`:942`), `splice` (`:1146`),
`emitDeadManExit` (`:1431`), `commitFreshness` (`:1618`), `markMigrationNonceUsed` (`:1651`),
`settleSwapInProven` (`:2076`), `reverseSwapOut` (`:2141`), `deliverSwapOutOnchain` (`:2302`).

There is **no attestation gate on any hop money path**; the MRENCLAVE whitelist gates nothing here
(`BTCChannels.sol:105`). The LP signs nothing on the EVM: consent arrives with the open as a BIP-340
*Bitcoin* signature over `btcRecipientPoPDigest(lpEth)`, and `lpEth` is **derived** from `p.lpPubkey`
rather than supplied, because Bitcoin and the EVM share secp256k1 (`BTCChannels.sol:936-946`).

### 2.1 What `finalize()` leaves behind

`Aux.finalize()` (`Aux.sol:702`, called at `DeployL1_s.sol:367`) asserts every cross-contract linkage
equals `Aux`'s owner-set view — catching a front-runner's malicious-but-non-zero pin in an ungated
setter — **before** anything is burned, so a mis-wired deploy reverts all-or-nothing. It then burns
the committed ANGEL NFT and calls `renounceOwnership()`. It is one-shot. `Basket`'s owner is
renounced on the next line (`:368`); `Quid` renounced itself inside `setup`.

**Three levers survive that ceremony. They are stated here rather than left to be found.**

1. **`Core.setObservationSource`** (`Core.sol:1634`), gated on `immutable DEPLOYER`. It has zero
   non-test callers and no deploy script calls it, so it is deliberately left **UNSET** on both
   instances — the slot is still open post-finalize.
2. **`Quid.setLevManager`**, gated on `immutable DEPLOYER` through `_onlyPinner` (`Quid.sol:126`).
   A one-shot pin, exercised only when `DEPLOY_LEV=1`.
3. **`Vault`'s ownership.** `Vault` is `Ownable` and the renounce (`DeployL1_s.sol:571`) sits
   **inside** `_deployLeverageOverlay`, after its `DEPLOY_LEV` early return at `:506`. ⇒ **`Vault` is
   renounced if and only if `DEPLOY_LEV=1`. On a deploy without the leverage overlay the deploy
   script remains `Vault`'s owner**, and `Vault.setLevManager` is its remaining owner-gated function.

### 2.2 What is deliberately permissionless

Recording a channel close: the splice-versus-close discriminator is cryptographic, so the gate does
not need to trust *who* calls, and a channel can be retired once Bitcoin confirms without depending
on hop or LP liveness — `recordClose` (`:1799`), `recordForceClosePermissionless` (`:1949`),
`recordDeadManExit` (`:1891`). Also `registerChannelClaim` (`:1076`), `refundExpiredSwapOut`
(`:2184`), `Aux.pokeVaultHealth` (`:487`), `Vault.syncLev` (`:478`), and header submission.

There are no solvers. There is no refill keeper. A keeper exists for the leverage overlay only.

---

## 3. The asset model

**QU!D** (`Basket`) is the dollar claim. Its matured supply is a fungible ERC-20 backed 1:1 by the
basket; its immature supply is a set of ERC-6909 tranches dated to future months. `trancheTotal()` is
the outstanding senior seed tranche, excluded from redeemable TVL.

**The basket** is fourteen stablecoins, each paired positionally with a yield venue
(`DeployL1_s.sol:217-227`, `:236-253`). Fourteen is the layout maximum, not a round number: the
accounting array is a `uint[15]` where slot 0 is the yield-weighted sum, slots 1..13 are per-token
deposits and slot 14 is the raw TVL total that `BasketLib.computeMetrics` divides by. A fifteenth stable
would silently overwrite that total, which is why the deploy asserts
`require(STABLECOINS.length == 14, ...)` at `DeployL1_s.sol:262`. The two arrays are positionally
paired and **nothing else enforces it** (`:253`). BOLD must stay last — `Aux` pins
`stables[length-1]` as the Liquity-Stability-Pool-routed stable. GHO and USDG carry `address(0)`
venues on purpose; they route through Aave.

**vETH** (`Quid`) is the ETH LP's position: `asset()` is WETH, but the backing held is weETH, and
`rangeETH()` values weETH in ETH plus idle WETH plus the levered leg (`Quid.sol:213`).

**vBTC** (`VBtc`) is the BTC LP's position — 8-decimal, minted and burned only by `Vault`. It *is*
sats.

**The two `Core` instances** hold the range state: one per asset, independent USD accounting, bound
only in the sum through `Aux.committedTotal()`.

**The range** is a band on an absolute price, not a tick range:

```solidity
lower = price * (10000 - delta) / 10000;
upper = price * (10000 + delta) / 10000;
```

`SwapLib.updateBounds` (`evm/src/imports/SwapLib.sol:2815-2819`), called with `RANGE_DELTA = 200`
(`:870`) at `:2921` and `:2965` — a ±2% band. No bounds are stored as configuration; they are
recomputed at each repack. Because the band is always built this way, the ratio `lo/up` is pinned at
`(1−δ)/(1+δ)` however far spot drifts, and `QuidLib.kLvrAt` clamps spot into the band — so the LVR
coefficient K is confined to `[12.56e18, 12.62e18]` for the live geometry.

---

## 4. The five flows

### 4.1 ETH deposit

`Quid.deposit(uint assets, address receiver)` — two arguments, `payable` (`Quid.sol:1784`). It routes
through `_deposit4626` → `_depositImpl`, so the full machinery runs (backing check, rebalance,
`addLiq`). Native ETH sent as `msg.value` is wrapped; any remaining `assets` is pulled as WETH up to
the caller's allowance and balance (`imports/QuidLib.sol:97-107`). Then the entire WETH balance goes
to **one destination**: ether.fi weETH via `_supplyEtherFi` (`QuidLib.sol:109-113`). There is no venue
choice, no deposit code, no dispatch and no fallback — a placement of zero reverts `VenueUnavailable`
(`QuidLib.sol:113`). The weETH is held by `Quid` itself; the depositor's shares are the delta in
`autoManaged[receiver].pooled`, and the ETH `Core` pairs the deposit as range depth.

### 4.2 BTC deposit

A BTC LP does not call the protocol. The hop — one of the two immutable addresses — submits
`openChannel(p, rawFundingTx, fundingMerkleProof, auth, exits)` (`BTCChannels.sol:926-946`). The call
SPV-proves the funding transaction through `SPVGateway` and byte-matches the taproot output against
`0x5120 ‖ Q`, where `Q` is proven equal to `TapTweak(KeyAgg(lpPubkey, hopPubkey))` on-chain; `lpEth`
is derived from `p.lpPubkey`, and `btcRecipient` is pinned at open as the sole payout, so no hop can
redirect funds. `BTCChannels` then calls `Vault.requestDeposit(lpEth, sats)` (`:1042`), which pairs
the sats as range depth on the BTC `Core` and credits the LP's shares. If that leg reverts — an
unhealthy basket — the custody record still stands, the amount is written to `pendingClaimSats` with
a `ChannelClaimDeferred` event, and anyone may credit it later via `registerChannelClaim` (`:1076`).
A splice that grows the channel takes the same path for the growth.

### 4.3 Swap

`Aux.swap(token, asset, forVolatile, amount, minOut, loadBalance)` (`Aux.sol:873`) forwards to
`swapTo(..., recipient, ...)` (`:886`), which holds the reentrancy lock and delegatecalls
`SwapLib.swapToBody` in `Aux`'s own context. `token` is the input stable, QU!D, or zero when paying
volatile; `asset` is WETH or WBTC; `forVolatile` picks the direction. `Aux` dispatches to the `Core`
instance that owns that asset. Price comes from the pinned Chainlink anchor cross-checked in
`getTWAPforAsset` (`:746`), and the band is recomputed by `updateBounds`. Fills settle **at oracle
against inventory** — one price, no traversal, no discovery (`Core.sol:1423-1428`) — which is why a
swap does not move `poolStats()`. The dynamic axis is `riskFactor`, per-stable depeg severity read
live from that stable's pinned feed (`Aux.sol:231,240`). ⚠️ There is no outflow fee on this path at
all — see §4.4. Every in-range USD add is gated by `committedUsd18() <= haircutTvl`, which is what
keeps the two ranges jointly bounded. The recipient can be set explicitly so a holder blacklisted by
a stable issuer can take proceeds at a fresh address (`Aux.sol:880-885`).

### 4.4 QU!D mint and redemption

Minting is `Basket.mint(pledge, amount, token, when)` (`Basket.sol:283`). The user's stable is taken
through `Aux.deposit` (`Aux.sol:1288`) and supplied to that token's paired venue; QU!D is issued dated
to `currentMonth() + 1` or later, so new issuance lands in an ERC-6909 tranche and matures into the
fungible pool. Protocol-internal mints — LP fee credit and swap-in/swap-out reissuance — go through
the same function under `auth()`, bounded by a supply cap that is the structural defence against a
compromised hop signer: even with valid signatures a protocol mint can only use headroom that prior
burns or backing growth opened (`Basket.sol:287-300`).

Redemption is `Aux.redeem(amount)` / `redeemTo(amount, recipient)` (`:1043,1054`). You can only ever
burn your own QU!D — the turn burns `msg.sender`'s mature batches (`Basket.turn`, `:264`) — and the
recipient overload only retargets the payout. Redemption is always pro-rata across the basket. The
only live charge on redemption is the **depeg haircut**, read per stable from its pinned Chainlink
feed (`getDepegSeverityBps` → `liveDepegBps`, inside `redeemAsBody`). It is uncapped by design.
⛔ **THERE IS NO OUTFLOW FEE, AND AS OF 2026-09-09 THERE IS NO CODE FOR ONE EITHER.** `FeeLib.calcFeeL1`
was declared and never called — every reference in `evm/src` and `evm/script` was a comment, and the only
executable callers were a unit test — so it was **deleted**, together with `BASE = 3` and `MAX_FEE = 30`,
which nothing outside its body read. `grep calcFeeL1 evm/src evm/script` now returns nothing.
📌 **THIS CORRECTS AN EARLIER VERSION OF THIS FILE, WRITTEN 2026-09-08**, which stated the redemption
fee as "`BASE = 3` bps → `MAX_FEE = 30` bps plus an uncapped depeg haircut". The constants existed; the
charge did not. A declared constant with a plausible name is not evidence of a live fee, and this is
an outward-facing claim about what users pay. **Whether a drain tax SHOULD exist is open** — it is a
product question, not a coding one, and it is booked as `SPRINT.md` §C2b.

### 4.5 Channel close

Permissionless, once Bitcoin confirms. `recordClose(channelId, p, rawCloseTx, closeBlockHash,
merkleProof, txIndex)` (`BTCChannels.sol:1788`) requires the channel open, then runs two
discriminators. `_requireNotSplice` (`:1726`) separates a close from a splice cryptographically — a
splice leaves a continuing 2-of-2 output that `BitcoinTx` can reconstruct, a close does not — which is
what stops a third party replaying a confirmed splice to force-retire a live channel.
`_verifyTxSpendsChannel` (`:627`) proves inclusion through `SPVGateway.checkTxInclusion` and that the
transaction spends the channel's outpoint.

A cooperative close (locktime 0) pays the LP `_lpFinalBalance` — the sum of outputs paying the LP's
committed key-path P2TR, pinned at open (`:734`, `:768`) — under a stale-close guard scoped so the LP
itself can always close (`:1841`). A non-cooperative close must additionally pass
`BitcoinTx.isCommitmentTx` and settles at the channel's funded amount, realising no swap proceeds.
`_finalizeClose` (`:686`) marks the channel closed, frees the LP to open a fresh one, decrements
`totalSatsLocked`, clamps a payout that exceeds what the channel held (emitting `PayoutExceededChannel`
rather than silently truncating), and — if the claim had actually been credited — calls
`Vault.requestRedeem(lpEth, lpPayoutSats)` (`:717`) to retire the LP's range position and settle its
USD leg. The LP's bitcoin is recovered by the close transaction itself, off this path.
`recordDeadManExit` (`:1891`) is the same shape keyed on a recorded `deadManDeadline`, and is
permissionless so an absent LP or a dead hop cannot strand the position.

---

## Not covered here

The live mainnet addresses (`evm/deployments/l1.json` is stale — it carries dead keys and lacks
`range` and `btcCore`); the Solana program surface (`svm/`); the identity/passport stack
(`evm/src/identity/`, `evm/noir/`, `evm/don/`), which is deferred scope with its own TODO and is not
part of the deployed protocol.
