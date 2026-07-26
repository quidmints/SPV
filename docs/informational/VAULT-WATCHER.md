# Vault-health handling — on-chain, permissionless, binary

The depeg watcher answers "is this *token* worth less than $1?" Vault health answers
a harder, **different** question: "can this *vault* still RETURN our stablecoins?"
The two must not be conflated.

Vault health is **100% on-chain** (the old off-chain CRE `onReport`/`setVaultWatcher`
forwarder and the graded `haircutBps` lever were removed — the CRE key was a trust
surface, and `haircutBps` an owner-only lever that was always 0 in production once
ownership renounced). What remains is deliberately **binary + trustless**.

## The mechanism (all in `Aux` / `BasketLib`, built + tested)

- **`Aux.pokeVaultHealth(vault)` — permissionless.** Reads only ERC4626 ground
  truth (`convertToAssets(balanceOf)` vs `maxWithdraw`, `BasketLib.pokeVaultHealthBody`).
  When a vault is verifiably illiquid (`liq < 50%`) it triggers the protective
  **block + dwell→evacuate**. It can only *tighten* (never unblock a vault it didn't
  itself flag, never re-quote value); the unfakeable read + a 30-min cross-poke
  `EVAC_DWELL` make a grief call impossible. Anyone can call it, so a captured key
  can't withhold the rescue.
- **`VaultHealth` is binary** (`{ bool blocked; uint40 flaggedAt; }`, no haircut):
  - `blocked` → `_supply` stops routing NEW deposits here; the vault is **valued at
    `maxWithdraw`** in `vogueETH`/`get_deposits` (deliverable value, not par).
  - `flaggedAt` → the `EVAC_DWELL` clock; auto-cleared on recovery.
- **`evacuate` (`onlyOwner`, un-dwelled) / the dwell-gated poke path** → block +
  `redeem` our shares + `spreadEquallyBody` across the stable's other unblocked
  vaults (maximal diversification of the recovery). Best-effort: a frozen `redeem`
  reverts inside try/catch → the vault stays blocked, loss socialized.

There is **no re-quote/haircut lever**: a blocked vault is simply valued at what it
can actually deliver (`maxWithdraw`), and `get_deposits`' per-vault try/catch already
values a reverting/gas-bombing vault at 0 without bricking the basket.

## The crux: illiquidity ≠ insolvency (why binary is right)

This is where a naïve, value-moving watcher becomes useless or actively harmful —
which is exactly why the graded haircut was dropped in favor of "block + value at
`maxWithdraw`."

- **Insolvency (realized loss / bad debt).** A Morpho Blue market the vault lent
  into took bad debt; the vault writes it down → `convertToAssets` DROPS. The
  protocol's backing **already falls automatically** because `BasketLib` reads
  `convertToAssets`. A separate haircut would **DOUBLE-COUNT**. The right action is
  BLOCK (stop feeding a losing vault) + EVACUATE — no re-quote.

- **Illiquidity (assets whole, just locked).** Utilization ~100%, so `maxWithdraw`
  is small, but every dollar is still there and recoverable later — exactly the
  protocol's thesis (*the dollars are present, unfelt but present*). The right
  action is EVACUATE the withdrawable part + BLOCK + value at `maxWithdraw`; the
  locked remainder is not a loss and must **not** be haircut.

- **Unrealized impairment (reported OVERSTATES recoverable).** Bad debt sits in a
  market the vault hasn't written down yet, so `convertToAssets` is stale-high. This
  is the ONLY case a re-quote would ever be warranted — but **`Recoverable` cannot
  be derived from on-chain totals** (`totalAssets`/`convertToAssets` are the vault's
  self-report; on un-written-down bad debt they read stale-HIGH — the very thing you
  need to detect; a large `totalAssets` can be other equally-stuck depositors or
  value inflated by unrealized bad debt). Real solvency lives in per-market
  collateral health, oracle liveness, and bad debt that only crystallizes on
  liquidation — none of which a single on-chain scalar exposes. So the on-chain
  watcher deliberately does **not** guess at impairment; it runs **liquidity-only**
  (illiquidity → evacuate; never a re-quote on a guess) and lets `convertToAssets`
  book realized losses as they land.

**Conservatism / no flapping:** a blocked vault re-admits only once it is liquid
again (the auto-unblock in the poke path); a transient blip can't move status
without the on-chain read actually clearing.

**Why this isn't useless:** it never reacts to normal Morpho behavior (high
utilization, ordinary yield) with a phantom backing cut; it separates "can't
withdraw now" (evacuate + value at `maxWithdraw`) from "lost money" (already in
`convertToAssets`); and it never phantom-reduces backing on a guess.
