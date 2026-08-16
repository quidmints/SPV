# Puppeteer E2E Permutation Matrix (#18)

Exhaustive front-end fuzz over **every integrated SPA path × happy + sad**, driven by the puppeteer MCP
tools against the anvil mainnet-fork. Goal: no permutation left unexercised before slither/echidna (final gate).

**Do NOT run until the other thread's contracts land.** This is the pre-scoped plan; execution waits.

---

## 🔴 STALE AS A PLAN — IT TARGETS A SURFACE THAT IS BEING DELETED (2026-08-16)

Asked directly whether this is ready to drive the React Native app. **It is not, and it is not a
readiness gap — it is a category error.** Recorded here rather than discovered by someone running it.

* **Puppeteer drives Chromium over the DevTools protocol. React Native has no DOM.** Every
  assertion below — *button disabled/enabled*, *toast/error text*, *deep-link `?tab=`* — is a DOM
  assertion with no counterpart in RN.
* **It navigates `/app`, which is the route being removed.** Owner, 2026-08-16: identity-wallet
  becomes the entire swap and LP app; the SPA keeps only a download link and the video. So this
  matrix exhaustively covers the one surface that will not exist.
* **"Puppeteer cancels the wallet shim"** assumes an injected browser wallet. The app has an
  in-app key, Phantom, or (proposed) a Ledger — none of them a browser shim.
* **It forks MAINNET and has no Bitcoin side at all.** The cross-chain interaction that actually
  needs exercising (deposit on regtest → credit on the EVM) is not in scope anywhere here.

⇒ **WHAT SURVIVES IS THE MATRIX ITSELF, WHICH IS THE VALUABLE PART.** The permutation list —
every tab × happy/sad, the amount edges (`0`, empty, negative, `>` balance, 1 wei, max, scientific
notation), the cross-cutting no-wallet / wrong-network / rejected-tx cases — is driver-agnostic and
was expensive to enumerate. **Keep it; replace the driver.**

⇒ **REPLACEMENT DRIVER: Maestro or Detox** (Expo supports both; Maestro is the lighter fit for a
device on a desk). ⚠️ Not evaluated yet — the choice is unmade, and neither is in the tree.

⇒ **AND THE HARNESS THE OWNER ASKED FOR IS A DIFFERENT ONE:** a phone driving anvil **and** a
Bitcoin regtest together, so a deposit on one chain is seen to credit on the other. Pieces that
already exist: `deploy/deploy-l1.sh`, `spa/e2e-faucet.sh`, `evm/script/DriverE2E.s.sol`,
`quid-ln/ops/bitcoin.conf`, and Bitcoin Core 30.2 baked into `quid-ln/Dockerfile` (same version
`regtest/env.sh` uses, deliberately). **Missing: the RN driver, and anything that runs the two
chains in one scenario.** No test in the tree today spans both.

## Harness (once, per run)
1. `anvil --fork-url $MAINNET --auto-impersonate` (mainnet fork).
2. `BROADCAST=1 RPC_URL=http://127.0.0.1:8545 PRIVATE_KEY=<anvil[0]> deploy/deploy-l1.sh` — now self-grants ANGEL
   on anvil (`b22e38b`), so the full ANGEL-committed stack deploys + finalizes (Aux/Basket renounced, ANGEL burned).
3. `spa/e2e-faucet.sh` — fund the SPA wallet (anvil acct[0] `0xf39F…2266`) with ETH + every basket stable + WBTC.
4. `spa` env → deployed addresses (env-overridable, #17); `npm run dev`; puppeteer_navigate `/app`.
5. Assert on: on-chain state (`cast call`), toast/error text, button disabled/enabled, balance deltas, tab state.

Each case: **precondition → action → assert (happy)** and its **failure twin → assert revert/guard**.

---

## 0. Cross-cutting (apply to every tab)
- **No wallet**: action buttons gated/disabled; connect prompt. Read-only tabs (info) still render.
- **Wrong network**: network-switch prompt; no tx sent.
- **Tx rejected** (puppeteer cancels the wallet shim): graceful error toast, no state change.
- **Deep-link** `/app?tab={mint,deposit,withdraw,swap,redeem,channel}` selects the tab.
- **Amount edge**: `0`, empty, negative, `>` balance, dust (1 wei), max (full balance), scientific notation.
- **Allowance**: unapproved → approve step appears; exact-allowance; infinite-allowance; re-approve.
- **Loading/stale**: stats spinner; RPC error → retry; balances refresh post-tx.

## 1. MINT (stables → QUID)

> **Settled, do NOT re-raise:** there is NO vote gate (the whole vote subsystem was deleted by #12 —
> `voteBtcShare`/`NotVoted`/`_resyncVotes` return nothing in `evm/src`), and **USDT0 is not a basket
> stable**. Both were re-verified against the code on 2026-07-27.

**CORRECTED 2026-07-26 — this section had TWO stale premises; both verified against HEAD before edit.**


## 2. REDEEM (QUID → stables)
Mature-only; per-QD `min(par, solvent-share)` cap; stables-only (band-unwind frees committed USD).
| # | Path | Happy | Sad twin |
|---|------|-------|----------|
|2.1| Redeem to chosen stable | QUID burned, stable received at `min(par,share)` | redeem > QUID balance; redeem 0 |
|2.2| Redeem immature QUID | only mature portion redeemable | redeem when all immature → 0/blocked |
|2.3| Redeem under depeg/haircut | value quoted down (solvent < par) | redeem when solvent share < requested |
|2.4| Redeem full balance | drains to 0 cleanly, no stuck QD (#51) | redeem leaving dust below min |
|2.5| Redeem routing (multi-stable) | splits across held stables | one stable illiquid → routes around |

## 3. SWAP
### 3a. Stable↔stable (`auxSwap`)
|3a.1| Each direction pair | minOut honored, fee applied | minOut too high → revert |
|3a.2| Partial-fill refund (#105) | consumed-signal, unfilled refunded | refund unit/cap correctness |
### 3b. Swap-OUT to BTC (`requestSwapOutOnchain`, rail A Lightning / B on-chain splice)
|3b.1| USD→BTC deliver | sats delivered, LP paid once | minSats too high; no BTC liquidity |
|3b.2| Partial fill | SOR-difference refund + warning (#110) | wrong scriptPubKey; below-min sats |
### 3c. Swap-IN from BTC (hop-driven; on-chain settle via `BTCChannels.settleSwapIn` → `Vault.creditSwapIn`)
<!-- API NAME CORRECTED 2026-07-27: `requestOnchainSwapIn` does NOT exist (0 hits in evm/src). The
     swap-IN is hop-initiated and settles on-chain through settleSwapIn/creditSwapIn. -->
|3c.1| BTC→QUID | poll → credited; CLTV refund path | hop API off (`hopApiConfigured`=false) → gated |
|3c.2| Underpay / timeout | refund via CLTV; no partial credit unless signalled | replay / double-spend rejected |

## 4. DEPOSIT (LP — ETH venues via `Vogue.deposit(amt, recip, venue)`)
Venues: Galaxy(0), ether.fi, Aave-v4, Rover, Euler, Split (per-LP hard-wall, #37/ETH-multivenue).
|4.1| Deposit per venue | LP share ↑ at chosen venue, net-equity accounting | venue maxWithdraw=0 mock (Galaxy) handled |
|4.2| Split ETH/WETH (`splitEthForDeposit`) | raw ETH wrapped + WETH combined | mismatch raw/weth amounts |
|4.3| Allocation slider + comfort knob | maps to venue + magnitude | slider 0 (passive LP) = pure in-range |
|4.4| Deposit 0 / > balance | — | reverts / disabled |

## 5. WITHDRAW (LP — `Vogue.withdraw`, instant vs queued)
|5.1| Withdraw (instant) | `setWithdrawInstant(true)` → immediate | withdraw > deposited |
|5.2| Withdraw (queued) | ether.fi redeem buffer / queue fallback (#38) | venue illiquid → queue, not revert |
|5.3| Partial / full | share math correct, IL realized on repack | withdraw 0 |
|5.4| Withdraw under leverage | net-equity-direct, de-lever if needed | withdraw needs BOLD availability (Liquity) |

## 6. CHANNEL (BTC LP via hop — `submitOpenChannel`→poll→`openChannel`)
|6.1| Open channel happy | funding confirms → SPV proof + `lpAuth` (ecrecover) → QUID minted | hop API off → gated |
|6.2| lpAuth binding | LP signs `openChannelDigest`; hop relays | wrong lpAuth → credited-owner mismatch reject |
|6.3| SPV proof | valid merkle proof accepted | invalid/replayed proof rejected (#22 holes) |
|6.4| autoManagedBTC | opts the LP position into keeper mgmt | — |

## 7. LEVERAGE (`LeverageCard` + `LeverageActionPanel` + `PnLPanel` + `ComfortPanel`)
ETH (weETH: Morpho/Euler/Aave-v4/Liquity) + BTC (vBTC native / WBTC-fallback AaveV3). Target ≤ `TARGET_LTV_CAP=7500`.
|7.1| Open lev per venue/collateral | position opens at 0 debt; net-equity synced to band | cap > 7500 → `BadTarget`; below `MIN_OPEN` |
|7.2| Target 2× (IL-hedge) | keeper holds `ilTargetLtvBps` (sold-fraction ramp) | — |
|7.3| Target >2× (directional) | SPA labels directional (`levL>2.001`, isolated-risk warning); on-chain the keeper still targets the IL ramp clamped at cap — the hold-and-ride branch is [pending] | liquidation guard de-levers near LLTV |
|7.4| Close / unwind | returns ≥ HODL − costs across a move (#82); flash-close BOLD | close with residual debt; over-collat reserve |
|7.5| WBTC-mode fold/de-lever | `rebalanceWbtc` fold-up + Morpho-flash de-lever (#90) | rebalanceWbtc on native venue → `BadTarget` |
|7.6| protectFromQuid | near-liq → redeem opted-in QUID → repay own debt | not near-liq → no-op |
|7.7| Stress test / P&L | ComfortPanel stress bake-in; PnLPanel live | extreme move → bounds shown |

## 8. INFO / DASHBOARD (read-only)
|8.1| Regime brain, net-flow (`fetchNetFlow`), BTC inventory (`fetchBtcInventory`) render | no-wallet render OK |
|8.2| Stats reconcile with on-chain (`cast call` cross-check) | RPC error → retry, no crash |

---

## Coverage ledger (fill during execution)
- [ ] §0 cross-cutting (7) · §1 mint (5) · §2 redeem (5) · §3 swap (6) · §4 deposit (4)
- [ ] §5 withdraw (4) · §6 channel (4) · §7 leverage (7) · §8 dashboard (2)
- Every row has BOTH its happy assertion AND its sad twin exercised. Log any permutation intentionally skipped.

**Next after 100% green:** slither (static) + echidna (property fuzz) on the contracts — the final gate.
