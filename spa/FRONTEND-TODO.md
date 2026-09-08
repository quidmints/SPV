# FRONTEND-TODO — UX obligations the contracts assume the frontend enforces

> Living list. The contracts make hard guarantees (no permanent bag, minOut
> protection, deferral instruments) but several of them are only *reachable*
> if the frontend quotes/sets the right parameters and surfaces the right
> state. Each item below names the on-chain source of truth to read.

## 1. SWAPS — swappers never wait; protect them with minOut (NEVER 0)

Swaps are atomic: full fill, partial fill, or revert — there is **no waiting
instrument for swappers** (wait-NFTs are LP/redeemer-only, by design). The
swapper's protection is their own `minOut`:

- **ALWAYS set a real `minOut`** on `Aux.swap/swapTo` (e.g. quote × slippage
  tolerance). With `minOut = 0` a mid-tx liquidity drain (e.g. the weETH/WETH
  univ3 pool emptying while the ETH side is weETH-heavy) pays a partial fill
  and the swapper eats the difference. With a real minOut the whole swap
  reverts and the swapper keeps their USD. Strand-3 only guards the
  `max == 0` case — partial fills are the frontend's job.
- **Quote against DELIVERABLE depth, not solvency**: read
  `Quid.deliverableETH()` (`evm/src/Quid.sol:237`; `Aux.deliverableETH()`,
  `Aux.sol:1039`, is a thin forwarder to the same number) and `POOLED_USD()`
  before sizing. If requested size > instant-deliverable, warn: "reduce size
  or expect a partial/revert".
  ⛔ **`Vault.deliverableETH()` DOES NOT EXIST** — `deliverableETH` is on
  `Quid` and `Aux`. Neither does `vogueETH()`.
  ⛔ **NOR DO `POOLED_USD_ETH` / `POOLED_USD_BTC`.** There is exactly ONE
  `POOLED_USD()` per `Core` instance (`Core.sol:68`) and there are TWO
  instances (`DeployLib.sol:139-140`) — pick the range by ADDRESS
  (`chains.ts` `rangeCore` for ETH, `rangeCoreBtc` for BTC), never by a name
  suffix. The suffixed names are exactly what took the SPA down before.
- **ETH-side health banner** when ether.fi dominates the ETH backing: show
  instant ETH depth ≈ idle WETH + (weETH × what the Curve weETH/WETH-ng pool
  can pay). `QuidLib.deliverableETH` (`:618`) bounds the weETH slice at 90% of
  that pool's WETH balance, so the surplus DEFERS rather than being counted;
  the exit ladder below it is idle WETH → the Curve sale (floored 25 bps under
  oracle) → the ether.fi wait-NFT. Surface the degradation, don't let users
  discover it via reverts.
  ⛔ There is no Rover, no Galaxy `maxWithdraw` rung and no weETH/WETH **v3**
  pool in the ETH ladder — those names have no symbol in `evm/src`.

## 2. ETH LP — one destination, and the exit ladder

⛔ **THERE IS NO VENUE AXIS. DO NOT BUILD A VENUE PICKER, AND DO NOT ENCODE ONE.**
`Quid.deposit(uint assets, address receiver)` (`evm/src/Quid.sol:1789`) and
`Quid.mint(uint shares, address receiver)` (`:1803`) take **two arguments**.
There is no third `venue` argument, no `VENUE_*` constant anywhere in `evm/src`,
and no `setEthVenue`/`setWithdrawInstant` setter. Every ETH deposit's WETH goes
to ONE destination — ether.fi weETH via `QuidLib._supplyEtherFi`
(`imports/QuidLib.sol:109-113`) — and a placement of zero reverts
`VenueUnavailable`. `spec.md §4.1` states it: "no venue choice, no deposit code,
no dispatch and no fallback".
⛔ **`outOfRange(...)` DOES NOT EXIST EITHER.** The on-chain out-of-range book was
deleted (§OOR-BOOK-DELETED). Its successor is a signed EIP-712 intent,
`Quid.fillIntent` (`evm/src/Quid.sol:1246`), which costs nothing on chain until
it fills — a wallet SIGNING flow, not a transaction. **Do not add a `fillIntent`
encoder until that signing flow exists**; an encoder with no caller is the
§E154-client-ghosts shape, and `tools/check-client-abis.py` reads
`spa/src/lib/abi.ts` for exactly this.
- What IS still true, and is the whole of the ETH-LP UX obligation: show the
  **exit ladder** and where it degrades. `QuidLib.withdrawETH` (`:682`) serves
  idle WETH first, then opportunistically sells weETH on the Curve
  weETH/WETH-ng pool, then falls to the ether.fi wait-NFT rung for the
  remainder. A partial fill is not an error — it is the deferral working.
- **Wait-NFT tracking**: LP exits AND redemption shortfalls can leave the user
  holding an ether.fi withdraw request (`IEtherFiLiquidityPool.requestWithdraw`,
  `QuidLib.sol:791`). The frontend must list these
  (claimable-after-finalization) or users won't know they hold value.

## 3. REDEEM — matured vs forward, clamp, deferral

- Clamp the redeem slider to `AUX.redeemableAmount()` (on-chain clips too;
  a stale read just leaves QD in the wallet).
- `QUID.balanceOf(user)` AGGREGATES forward-credited months; only the
  matured slice can redeem/transfer (else `InsufficientUnlocked`). Show
  "matured / forward" split (per-month `balanceOf(user, month)`).
- Explain the deferral model: an unserved redemption slice stays as QD
  (redeemable when liquidity returns) or arrives as a wait-NFT — it is a
  claim, never a loss.

## 4. BTC LP — parity screens (sync to latest contracts)

- openChannel flow: **the LP signs nothing on the EVM.** `openChannel` is
  hop-gated (`BTCChannels.sol:942`), `lpEth` is DERIVED from `p.lpPubkey`
  rather than supplied, and the LP's consent arrives as a BIP-340 *Bitcoin*
  signature over `btcRecipientPoPDigest(lpEth)` (`:936-946`, `spec.md §4.2`).
  The frontend's job is the payout key and the status read, not a digest
  signature. Show channel status from `BTCChannels.channels(channelId)`
  (`:206`) + `ChannelOpened/Closed` events.
- Exit: cooperative close vs `recordForceClosePermissionless`
  (`BTCChannels.sol:1949` — permissionless, works even if the hop is dead;
  CSV/CLTV timing on the Bitcoin side). ⛔ The name is
  `recordForceClosePermissionless`; there is no `recordForceClose` and no
  `forceCloseByLP`.
- Show the LP's BTC-leg fee accrual from `Vault.autoManaged(lp)` — the
  `fees_tok` field of `Types.Deposit` is the token-side (sats) fee leg on the
  BTC range manager (`Shares.sol:136`). ⛔ There is no
  `Vault.btcFeesOwedSats(lp)`; that name survives only as a stale comment in
  `Quid.sol:329`.
- swap-out: `requestSwapOutOnchain(address token, uint usdAmount, uint minSats,
  bytes32 swapId)` (`BTCChannels.sol:2251`) — the **on-chain** rail (the LN
  swap-out rail was removed; the hop splice-out pays the swapper's Bitcoin
  address, taken from `btcRecipientOf`, not from a `swapperScript` argument).
  Show pending obligation + reversal state.
  ⚠️ **Gate the button on `Aux`/`BTCChannels.btcRecipientOf(user) != 0`.** With
  no registered payout key the call reverts `NotPubkeyHash` before any USD
  moves (`BTCChannels.sol:2265`), so the user must `setBtcRecipient` (`:2443`)
  first. Surface that as a prerequisite step, not as a failed transaction.

<!-- §5 "Existing stubs to finish" (venue param, swap minOut, BTC-channel
hopPubkey/lpAuth/close-tracking) PURGED 2026-06-24 — those screens are wired
(Mint/Redeem/Swap/ETH-LP/self-LP/BTC-channel) with the on-chain sources in
src/lib/{abi,hop,btcaddress}.ts. §1–§4 above remain STANDING UX obligations
(e.g. "always set minOut"), not one-time tasks. -->

## 5. Node hosting (key / LN-node side) — LP self-host guidance

These are the frontend obligations for the SGX/key/LN-node model (NOT a custody
or attestation path in the browser — the browser does NO DCAP verification and
NO seed provisioning; that's the operator's CLI). See `project-quid-lp-hosting-modes`.

  TWO ORTHOGONAL axes — do not conflate them in the UI:
- **Availability (HARD requirement to serve swaps).** A swap-serving LP MUST be
  **always-on** — its key must co-sign swap-out splices in real time (even at 3am).
  A sleeping node serves NO swaps and earns NO fees while down (the hop routes
  swap-outs around offline LPs to online ones — an offline LP is skipped, not a
  global blocker). Surface this as a requirement, not an option: "run on
  always-on hardware (home server / VPS), not a laptop that sleeps."
- **Watchtower for any node that can go offline.** Even a normally-always-on node
  needs a watchtower (keyless, hostable) so a counterparty can't broadcast a
  revoked state while it's briefly down. Surface prominently.
- **Key protection (independent choice).** LPs self-host their own `quid-lp-daemon`
  and are their own trust root. Two options, pointers not a wizard:
  - **Own SGX enclave** — build for `x86_64-fortanix-unknown-sgx`; born-in-enclave,
    sealed to their machine. Lowest trust assumptions.
  - **Plain** — local key, no hardware protection (their risk).
  Either way the availability + watchtower requirements above still apply.
- **Do NOT build:** in-browser attestation/DCAP verification, a WASM verifier, or
  any in-browser seed/provisioning UI — explicitly out of scope (the provisioner
  is the operator/deployer via CLI).
