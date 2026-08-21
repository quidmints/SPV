# `VBtc.asset()` and EIP-7540: BOTH bands are asynchronous, and both faces deny it

Owner-directed 2026-08-16 (pointer: <https://eips.ethereum.org/EIPS/eip-7540>). **Nothing below is
implemented.** This settles the follow-on CLAUDE.md already books — *"today `VBtc.asset()` returns
WBTC as a pricing handle … that accessor's meaning has to be revisited; do not carry it across
unexamined"* — and it is a prerequisite for the band-manager merge, because the merge has to decide
what a single band manager's face means. ⚠️ The answer changed once the owner pointed out the
de-lever: it is 7540 for BOTH instances, not 4626-for-ETH plus 7540-for-BTC. See the corrected
section at the end -- the earlier reading of this document is wrong on that point.

## The defect, stated precisely

`evm/src/VBtc.sol`:

| line | code | what it claims |
|---|---|---|
| `:82` | `asset() => WBTC` | the underlying is WBTC |
| `:83` | `convertToAssets(shares) => shares` | shares convert 1:1, **now** |
| `:84` | `convertToShares(assets) => assets` | and back again, **now** |

**Both claims are false, in different ways.**

1. **`asset()` names a token the band never holds.** WBTC is a *pricing handle* — the venue prices
   vBTC against it via `getTWAPforAsset`. The real underlying is LN-custodied native BTC, which has
   no EVM token. ERC-4626 defines `asset()` as the thing `deposit` takes and `redeem` pays. Nothing
   here deposits or pays WBTC.

2. **The identity conversion is a synchronous promise the protocol cannot keep.** vBTC *is* sats, so
   the ratio is right — but `convertToAssets` asserts the conversion is available on call. Redeeming
   sats requires a **Lightning cooperative close or a splice**, which needs L1 confirmations. The
   number is correct and the availability is not, which is the harder half to notice: an integrator
   reads a non-reverting 1:1 preview and sizes a position against liquidity that takes blocks to
   exist.

⇒ The problem is not the ratio. It is that a **synchronous** interface is describing an
**asynchronous** settlement.

## Why 7540 is the right shape

EIP-7540 extends 4626 with a request/claim lifecycle: `requestDeposit` / `requestRedeem` put an
amount into a **pending** state, which later becomes **claimable**, and only then is it claimed.
That is precisely the BTC settlement shape — request, wait for confirmations, settle — rather than a
latency we currently hide behind a pure function.

The load-bearing clause for us: **7540 requires `preview*` to REVERT for asynchronous flows.** That
is the correction, expressed as a rule rather than a comment. It replaces a false promise with an
explicit lifecycle, and an integrator that assumed instant redemption fails loudly at the call
instead of quietly at settlement — the discriminator standing rule 3 asks for.

⚠️ **7540 does NOT remove the ERC-20 `asset()` requirement.** It still expects an asset address, so
adopting it does not by itself fix defect (1). The two must be settled together, and (1) is the one
with a real decision in it:

| option | `asset()` | cost |
|---|---|---|
| **A — keep WBTC as the handle** | WBTC | the accessor keeps lying; every integrator must know it is nominal |
| **B — `asset()` returns vBTC itself** | vBTC | honest under "the band has no underlying unless it mints one" (CLAUDE.md's resolved reason for vBTC surviving), but `asset() == address(this)` is degenerate and some integrators reject it |
| **C — a minimal sats-denominated ERC-20 as the true underlying** | that token | most honest, most bytecode, and creates a second supply to reconcile |

**Not chosen here.** The measurement that should decide it is the one CLAUDE.md already names as the
surviving blocker: *an open Morpho/Euler market where a liquidator who seizes vBTC has no way to
exit*. Whichever option makes that liquidator's exit expressible is the right one — the answer is
downstream of a real user, not of interface aesthetics.

## Consequences for the band-manager merge

🔴 **CORRECTED 2026-08-16 (owner). BOTH BANDS ARE ASYNCHRONOUS, and the earlier version of this
section was wrong.** It claimed "the ETH band is genuinely synchronous (WETH exists, is held, is
redeemable)" and warned against making ETH async "for symmetry". The counter-example is not
Lightning at all — it is the **de-lever**:

- A redemption can require unwinding a levered position, and that unwind depends on **venue
  UTILISATION**. When the venue is drawn down, the withdraw leg cannot complete in the same
  transaction.
- The flash-repay-first path (`extractLev`) is bounded by `deliverableDollars` and by the liquidation
  threshold, so a single flash loan **is not guaranteed to execute the whole way**. What remains is
  a claim to be settled later.

⇒ ETH inherits the same request → pending → claimable shape as BTC, for a completely different
reason: BTC because settlement is a Lightning cooperative close, ETH because de-levering is
utilisation-bounded. **The asynchronicity is a property of the PROTOCOL, not of the BTC leg.**

- So a single band manager CAN expose one face for both instances, and that face is **7540, not
  4626** — which makes the merge simpler than the earlier note claimed, not harder.
- The `preview*`-must-revert rule then applies on BOTH sides. Today the ETH side is the more
  misleading of the two: it advertises a synchronous redemption that a drawn-down venue cannot
  honour, and unlike vBTC nobody reads a warning header before integrating against it.
- ⚠️ The earlier warning is INVERTED: the risk is not "making ETH async for symmetry", it is leaving
  ETH synchronous because it superficially looks like it can be.

## Ordered next steps

1. Settle the Morpho/Euler liquidator-exit question — it selects A/B/C above and nothing else should
   be built first.
2. Make `convertToAssets`/`convertToShares` stop promising synchronous availability (7540's
   `preview*`-reverts rule), keeping the 1:1 ratio where a ratio is genuinely wanted.
3. Only then decide `asset()`.

⚠️ **Cross-repo:** `../ibiza` pins SPV as a submodule and depends on four Quid/Basket signatures
staying permissionless and stable. Confirm none of them is on the vBTC face before changing it.
