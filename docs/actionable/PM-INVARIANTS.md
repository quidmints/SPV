# The three PoolManager invariants — a verification gate for ALL post-refactor work

V4 and its lock/unlock are **gone from this repo** (zero imports, zero remappings, no submodule).
The lock was never only plumbing: it enforced three invariants for free. With an EXTERNAL router
executing swaps, each becomes ours, and **each fails SILENTLY if unenforced.**

Not advice. A gate: every post-refactor change touching a value path is checked against these three.

---

## 1. SETTLEMENT / CONSERVATION — verify by MEASURED DELTA, never a returned number

`unlock` refused to return while any currency delta was unsettled — you could not leave the
PoolManager owing or owed. That was a conservation check on every swap, automatically. An external
router gives no such guarantee: **it returns a number.**

**CHECK:** does the assertion read a balance the failing code did not produce? Snapshot before,
subtract after, compare against the floor.

**PRECEDENT IN-TREE — all three found by measuring receipts, and all three passed their build:**
- **sUSDE** — `maxWithdraw` non-zero while `withdraw` reverts (§V-R10).
- **refill** — 20 ETH in, ZERO back, across every stable AND QU!D.
- **the first GHO test** — passed on OTHER stables' deliveries while asserting nothing about the
  spoke. It would have passed for the exact defect it existed to catch.

## 2. DELTA SIGN — asserted at the call site now, not derived from the venue

`modifyLiquidity` RETURNED signed deltas, so the band read direction FROM the venue and the sign
could not disagree with what moved. `Core` owns this now: `struct Delta { int256 usd; int256 vol; }`
and `modLP(int256, int256)`, where **the caller carries the sign**.

⇒ The sign is now ASSERTED at the call site rather than DERIVED from the venue. That is a new place a
bug enters silently — and it already has: §E231 found `modLP` hardcoding both legs negative, so every
BURN was accounted as an ADD and a withdrawal GREW `POOLED`.

**CHECK:** at least once per path, assert the sign against a MEASURED balance change.

**PRECEDENT:** `RestoreProfitability.t.sol` had EVERY direction comment backwards — a
stable→volatile BUY *drains* the band. Reasoning about direction is how that happened; measuring is
what caught it.

## 3. REENTRANCY — the lock is gone; a router call is arbitrary code

The V4 lock made this structural for the duration of a swap. A router call executes untrusted code
**with our approval live**.

**CHECK:** `nonReentrant` on every path reaching the router; approval exact-amount AND zeroed after;
router address pinned; and confirm the existing guards cover a callback re-entering through a
DIFFERENT entrypoint than the one that called out.

⚠️ `LevManager`'s `nonReentrant` was written when every swap hit a pool that could not call back.
That assumption is now false — re-derive the guard rather than inheriting it.

### MEASURED against current code, 2026-08-17 — and it found one real gap

| requirement | state |
|---|---|
| router address pinned | ✅ `V3_SWAP_ROUTER` is a `constant` in `Interfaces.sol` |
| approval exact-amount | ✅ `forceApprove(router, amountIn)`, not `type(uint).max` |
| `nonReentrant` on router paths | ✅ `Aux.sorSelfFunded` / `sorSelfFundedReverse` are `external nonReentrant`; `executePath` is self-gated and only reached from inside an already-guarded call |
| **approval zeroed after** | 🔴 **WAS NOT** — fixed in this commit |

**THE GAP:** `SOR._v3Route` approves `amountIn`, tries four fee-tier paths, and on the
all-paths-fail branch `return 0` **with the approval still standing**. On success `exactInput`
consumes exactly `amountIn` so the allowance self-zeroes — the failure path was the hole, which is
why it survives casual reading. Its sibling `SwapLib.curveSellWeeth` already zeroes in its `catch`;
the two are now consistent.

Severity is bounded (the router is pinned and audited, so this is not an open theft vector) but it is
exactly the class the V4 lock used to make unconstructible, and it is the first thing this gate was
pointed at.

---

⇒ **THE VENUE WAS ALSO THE REFEREE.** Removing it removed the refereeing, and nothing about
`forge build` passing tells you these three still hold. **Every one of the precedents listed above
passed its build.** A green suite proves the code runs — not that the invariants an external
contract used to enforce are still enforced.
