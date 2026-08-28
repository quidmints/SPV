# PP↔SPV treasury integration: reverse coupling + anonymity-preserving buffer design

Status: implemented and tested (`SpvTreasuryAdapter` + interfaces, `backend/contracts/contracts/pool/spv/`,
19/19 Forge tests green). This doc is the rationale; the contracts are the spec.

> **Staleness note (2026-07-26).** The repo-wide test count this header used to quote (49/49) is long
> out of date — it is **149/149** as of today; don't treat a number in this file as current, check
> `forge test`. More substantively, §5's "Open" list below is **partly stale**: the Aave `ICreditLine`
> implementation described there as unstarted has since been built (`AaveCreditLine.sol`, 18 tests).
> `TODO.md` §2.10 is the live tracker for this integration; this document is the design rationale and
> should be read as such, not as a status board.

## 1. Why reverse coupling (PP pins SPV, never the reverse)

PP and SPV are separate repos (PP = rarime + Privacy Pools + Noir/Honk migration; SPV = enclave +
Lightning + core AMM/LP Solidity). Optics requirement: SPV's repo must contain zero references to PP.
This is structurally enforced, not just a convention: PP's repo never imports SPV's source; it declares
minimal local interface stubs (`ISpvVogue`, `ISpvBasket` in `contracts/pool/spv/ISpvVenue.sol`) matching
SPV's real, confirmed function signatures, and holds SPV's deployed addresses as **immutable**
constructor arguments in its own contracts. Same pattern any protocol uses to integrate with an external
deployed contract it doesn't own (e.g. declaring `IUniswapV2Router02` locally rather than vendoring
Uniswap's source).

**Confirmed, not assumed:** `Vogue.deposit(uint,address[,uint8])` / `withdraw(uint,address,address)` and
`Basket.mint(address,uint,address,uint)` are plain `external`/`external payable` functions with no
`onlyUs` gate and no allowlist — standard permissionless entry points. This means PP needs **zero
admission** on SPV's side at all (not `onlyUs`, not a governance allowlist) — it calls the same public
interface any ordinary integrator would. SPV's own `onlyUs` tier (the pin-once, immutable-or-burned-owner
pattern used by Vogue/Aux/Core/Vault/Basket/Rover, gating pooled-fund and mint/burn operations like
`addLiq`/`drawPooledUsdBtc`) is explicitly NOT something PP should ever be part of, in either direction —
that tier has no off-switch by design, and PP is an actively-changing fork that needs one.

## 2. Why the deposit/withdraw legs must be decoupled from individual user actions

Vogue's own `Deposited`/`Withdrawn` events are public and cleartext — no privacy properties of their
own. PP's privacy model does NOT hide deposit/withdrawal amounts or addresses (those are already public
in PP's own `Deposited`/`Withdrawn` events); it hides only the LINK between a specific deposit and the
withdrawal that later spends it (via the ZK proof over the LeanIMT).

If PP forwarded funds into Vogue synchronously and 1:1 with individual user actions ("user deposits X →
PP immediately deposits X into Vogue"; "user withdraws Y → PP immediately pulls Y from Vogue"), Vogue's
event stream becomes a side-channel that reconstructs exactly the link PP's ZK design exists to hide —
an outside observer correlates PP's own public events against Vogue's public events by matching
amount + timing.

**The fix is not "hide the Vogue events" (impossible, they're not private) — it's decoupling:**
1. User-facing withdrawals draw from PP's own pre-funded buffer, never directly from Vogue in real time.
2. Sweeps (idle → Vogue) and reclaims (Vogue → buffer) are keeper-gated, rate-limited, and size-capped —
   never synchronous with, or sized to exactly match, any single user's deposit/withdrawal.
3. No per-user earmarking inside the Vogue position — it's a single, fungible, aggregate position from
   PP's internal accounting perspective. (Tagging "this slice backs commitment X" would leak via PP's own
   bookkeeping even if it never touches Vogue's on-chain state.)

This does NOT make PP's aggregate TVL more observable than it already is (that's inherent and already
public) — it prevents the NEW discrete push-notification stream Vogue's events would otherwise add.

## 3. Why sweep/reclaim are keeper-gated, not permissionless

SPV's own de-lever functions (`LevManager.rebalance`/`closeLev`) are deliberately permissionless —
that's correct there because timing doesn't leak anything (de-levering a specific LP's position is
inherently tied to that LP anyway). Here, timing IS the sensitive parameter: if sweep/reclaim were
callable by anyone, an adversary could deliberately trigger one at a moment chosen to create a
correlation opportunity. `SpvTreasuryAdapter` restricts both to a single, owner-rotatable `keeper`
address, with the actual jitter/discretion (choosing amounts and timing within the contract-enforced
rate-limit and size-cap) left to that keeper's off-chain judgment — the contract enforces the safety
invariants, not the unpredictability itself.

## 4. Why the backstop is NOT SPV's `_deleverFlash`, and doesn't need tight coupling to be useful

Investigated directly (not assumed): `LevManager._deleverFlash` is an **atomic same-transaction** Morpho
Blue flash loan — borrow and repay within one call frame, no persisted debt, reverts if it can't close
out. That's architecturally the wrong shape for "draw instantly during a buffer shortfall, repay later
whenever the next scheduled reclaim lands" — no amount of coupling tightness would make an atomic
primitive support cross-transaction settlement.

The actual right primitive is simpler and doesn't require any SPV coupling at all: a standard
**collateralized credit line** (`ICreditLine` — `borrow`/`repay`/`debtOf`), which PP opens independently
with its own posted collateral on an external money market (Aave/Morpho/Euler — the same class of venue
SPV itself trusts, borrowing the pattern, not the code or the deployment). `SpvTreasuryAdapter.
drawBackstop`/`repayBackstop` are written against this abstraction; wiring it to a real Aave/Morpho pool
is separate, unstarted work (see `ICreditLine.sol`'s STATUS note) that can land later without touching
the sweep/reclaim logic already built.

**Residual tail risk, stated plainly:** if withdrawal demand outpaces both the buffer and the scheduled
reclaim cadence AND the backstop is undersized/unwired, PP would be forced into an urgent, synchronous
Vogue reclaim — exactly the correlatable event this design exists to avoid. Buffer size, sweep/reclaim
cadence, and backstop capacity are a genuine three-way trade-off (capital efficiency vs. privacy vs.
liquidity risk), not something eliminated by this design — only bounded by it. Sizing these parameters
against realistic withdrawal-demand distributions is explicitly open, ongoing work, not a one-time
constant.

## 5. What's built vs. open

**Built and tested (`contracts/pool/spv/`):**
- `ISpvVenue.sol` — local interface stubs for Vogue/Basket (no SPV source import).
- `ICreditLine.sol` — backstop abstraction (interface only, not wired to a real venue yet).
- `SpvTreasuryAdapter.sol` — immutable SPV address wiring, funding/release, keeper-gated rate-limited
  size-capped sweep/reclaim, backstop draw/repay with debt tracking, pause, owner governance.
- `test/pool/SpvTreasuryAdapter.t.sol` — 19 tests, all invariants above covered (including a real bug
  the tests caught: the min-interval check originally blocked the very first-ever sweep/reclaim because
  `lastSweepAt`/`lastReclaimAt` default to 0 — fixed to treat 0 as "never happened," not "just happened
  at time 0").

**Open:**
- ~~Real Aave/Morpho/Euler `ICreditLine` implementation (currently interface-only).~~ **DONE** —
  `AaveCreditLine.sol` implements `ICreditLine` against Aave V3's real `IPool`, 18 tests passing.
  Pool/WETH addresses are constructor params because the target chain is still undecided (SPV has
  not picked one). See TODO.md §2.10.
- `Basket.mint` integration for idle stablecoins (interface declared, not wired into the adapter yet —
  `Basket.mint`'s collateral/token-whitelist requirements need checking before relying on it, per the
  earlier open item).
- Concrete parameter sizing (buffer floor, `minSweepInterval`/`minReclaimInterval`, `maxSweepBps`,
  backstop capacity) against realistic withdrawal-demand modeling — currently placeholder defaults
  (1 hour intervals, 50% max sweep fraction).
- PP-side governance process for periodically funding/releasing the adapter from `Entrypoint`'s own
  balance (the adapter is a satellite; nothing in PP's core `PrivacyPool`/`Entrypoint` currently calls it
  — that wiring, and who/what triggers it, is unstarted).
