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
  `Vault.deliverableETH()` (not `vogueETH()`) + `CORE.POOLED_USD_ETH/BTC`
  before sizing. If requested size > instant-deliverable, warn: "reduce size
  or expect a partial/revert".
- **ETH-side health banner** when ether.fi dominates the ETH backing: show
  instant ETH depth ≈ idle WETH + Galaxy `maxWithdraw` + AAVE + Rover WETH
  leg + (weETH × pool-health). When the weETH/WETH v3 pool can't pay fair
  (the Rover's fair-gate refuses, `sourceWethBody` returns 0), ETH fills
  degrade to the smaller instant set — surface it, don't let users discover
  it via reverts.

## 2. ETH LP — per-deposit venue + the exit ladder

- Venue rides the call now: `deposit(assets, receiver, venue)` /
  `mint(shares, receiver, venue)` / `outOfRange(..., venue)`;
  0 = 50/50 Galaxy+AAVE (default), 1 = ether.fi (weETH), 2 = AAVE-v4,
  3 = all-Galaxy, 4 = ether.fi Rover. **No setter tx exists anymore.**
- Tooltips: venue 1/4 exit via the offramp ladder (v3 pool → Rover →
  0.3% instant → wait-NFT). Venue 4 = same wall as venue 1 plus the
  protocol-owned weETH/WETH LP overlay (fee capture; fair-gated).
- `setWithdrawInstant(bool)` toggle for ether.fi-slice exits: false (default)
  = free wait-NFT on a drained pool; true = accept ~0.3% instant. Show the
  REAL instant capacity: `EtherFiRedemptionManager.totalRedeemableAmount(
  0xEeee…EEeE)` — it is frequently **zero** on mainnet (low-watermark vs
  free pool ETH), in which case "instant" silently degrades to the wait-NFT.
- **Wait-NFT tracking**: LP exits AND redemption shortfalls can mint an
  ether.fi `WithdrawRequestNFT` (0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c)
  to the user. The frontend must list these (claimable-after-finalization)
  or users won't know they hold value.

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

- openChannel flow: fund the 2-of-2 (hop-negotiated), sign `lpAuth`
  (`openChannelDigest`), hop relays. Show channel status from
  `BTCChannels.channels(channelId)` + `ChannelOpened/Closed` events.
- Exit: cooperative close vs `recordForceClose` (permissionless — works even
  if the hop is dead; CSV/CLTV timing on the Bitcoin side).
- Show `Vault.btcFeesOwedSats(lp)` ("BTC-leg fees, paid by the hop to your
  channel key after close — as a separate Bitcoin tx, not inside the close").
- swap-out: `requestSwapOutOnchain(... swapperScript, swapId)` — the **on-chain**
  rail (the LN swap-out rail was removed; the hop splice-out pays the swapper's
  Bitcoin address). Show pending obligation + reversal state.

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
