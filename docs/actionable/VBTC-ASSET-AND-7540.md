# `VBtc.asset()` and EIP-7540: the BTC band is asynchronous, and today's face denies it

Owner-directed 2026-08-16 (pointer: <https://eips.ethereum.org/EIPS/eip-7540>). **Nothing below is
implemented.** This settles the follow-on CLAUDE.md already books — *"today `VBtc.asset()` returns
WBTC as a pricing handle … that accessor's meaning has to be revisited; do not carry it across
unexamined"* — and it is a prerequisite for the band-manager merge, because the merge has to decide
what a single band manager's 4626 face means on the BTC side.

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

- The ETH band is genuinely synchronous (WETH exists, is held, is redeemable). The BTC band is not.
  **A single band manager therefore cannot expose one synchronous 4626 face for both instances** —
  this is a REAL asymmetry in CLAUDE.md's sense, not drift to be deduped away.
- The merge should put the *accounting* in one implementation and let the **face** differ: 4626 for
  ETH, 7540 for BTC. That keeps one band manager without forcing the BTC side to lie.
- ⚠️ Do not "fix" this by making the ETH side asynchronous for symmetry. Symmetry is not the goal;
  not lying is.

## Ordered next steps

1. Settle the Morpho/Euler liquidator-exit question — it selects A/B/C above and nothing else should
   be built first.
2. Make `convertToAssets`/`convertToShares` stop promising synchronous availability (7540's
   `preview*`-reverts rule), keeping the 1:1 ratio where a ratio is genuinely wanted.
3. Only then decide `asset()`.

⚠️ **Cross-repo:** `../ibiza` pins SPV as a submodule and depends on four Vogue/Basket signatures
staying permissionless and stable. Confirm none of them is on the vBTC face before changing it.
