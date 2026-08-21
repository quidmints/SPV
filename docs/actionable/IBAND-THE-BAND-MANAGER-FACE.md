# `IBand`: the interface that lets `Core` stop knowing which asset it is

Designed 2026-08-16, owner-directed ("finish the refactor, do the design work"). **Declared in
`src/imports/Interfaces.sol`; NOT yet implemented or wired.** This is the last structural step
before `isBTC` can reach zero on the money path, and the precondition for one band manager with two
instances.

## The measurement that forces this shape

After the instance split, `Core`'s remaining `IS_BTC` branches are **not** a mixture of concerns.
Every one of them is `Core` reaching into ONE OF TWO BAND MANAGERS for the same fact and having to
know which:

| `Core` site | today | what it actually wants |
|---|---|---|
| `:395` skew premium | `ISkewSink(IS_BTC ? BTCVAULT : VOGUE)` | credit the band |
| `:157` lev debt | `BTCVAULT.LEV_MANAGER_BTC()` vs `ILevHost(VOGUE.EV()).LEV_MANAGER()` | the band's lev manager |
| `:313` lev gross | `totalGrossCollateralBtc()` vs `totalGrossCollateralEth()` | gross collateral, native units |
| `:840` shortfall base | `totalSharesBTC() + totalBufferBTC()` vs `totalShares()` | the share base to compare |
| `:860` inventory | `POOLED + AUX.vogueBTC()` vs `AUX.vogueETH()` | REAL inventory |
| `:876` remediation | `AUX.btcShortfall(...)` vs nothing | what to do about a shortfall |
| `:1013` payout | `!IS_BTC && VOGUE.takeETH(...)` | pay the volatile leg |

**`ISkewSink` already proved the shape works.** Both managers expose `creditSkewPremium`, and
`Vault.sol:322` records why: *"SAME NAME as `Vogue.creditSkewPremium` so Core dispatches by ADDRESS
through one interface and one call site — two branch-local calls cost 180 bytes of Core's EIP-170."*
`IBand` is that argument applied to the remaining six.

## The interface

```
interface IBand {
    function creditSkewPremium(uint premium6) external;
    function levManager()        external view returns (address);
    function levGrossNative()    external view returns (uint);
    function sharesForShortfall()external view returns (uint);
    function realInventory()     external view returns (uint);
    function onShortfall(address sender, uint shortfall) external;
    function deliverVolatile(uint amount, address who)   external;
}
```

| member | `Vogue` (ETH) | `Vault` (BTC) |
|---|---|---|
| `creditSkewPremium` | exists | exists |
| `levManager` | `ILevHost(EV()).LEV_MANAGER()` | `LEV_MANAGER_BTC` |
| `levGrossNative` | `totalGrossCollateralEth()` | `totalGrossCollateralBtc()` |
| `sharesForShortfall` | `totalShares()` (net) | `totalSharesBTC() + totalBufferBTC()` |
| `realInventory` | `AUX.vogueETH()` | `CORE.POOLED() + AUX.vogueBTC()` |
| `onShortfall` | **no-op** | `AUX.btcShortfall(sender, shortfall)` |
| `deliverVolatile` | `takeETH(amount, who)` | **no-op** |

## ⚠️ The two no-ops are the design, not laziness

Deleting a branch is only right if the asymmetry it encoded is fake. **These two are real**, and
making them explicit members is what stops a future reader "simplifying" them away:

- **`deliverVolatile` is a no-op on BTC.** ETH pays out real ether on-chain; BTC settles by
  Lightning cooperative close, so there is nothing to send from the contract. One of the four
  known-REAL ETH/BTC asymmetries (CLAUDE.md).
- **`onShortfall` is a no-op on ETH, deliberately.** BTC routes to the hop — real-BTC delivery
  consuming no basket stables. ETH does nothing **on purpose**: a surplus-funded refill would buy
  ETH to cover a usually-IMPERMANENT shortfall and realise that IL onto shared backing, compensating
  the flow at every LP's expense. Real ETH demand is met at withdrawal, where `convertToAssets` pays
  each LP pro-rata and the IL is socialised through the share price. `Core.sol:865-875` already
  argues this at length; the interface just gives that argument a home.

⇒ **The bands differ, and `IBand` is where the difference belongs** — in the contract that owns the
settlement, not in a boolean the caller must carry.

## Wiring

`Core` needs one `BAND` handle instead of `VOGUE`/`BTCVAULT` + a flag:
- ETH: set in `setup()` (Vogue exists by then).
- BTC: set in `setBtcVault()` — `Vault` is deployed AFTER `Core` (it takes Core's address at
  construction), which is exactly why that setter already exists.

That leaves `IS_BTC` used only at wiring time (and for `VOL_DECIMALS`/`ASSET`), and **zero** on the
money path.

## Why it is not implemented in the same change

~150 lines across three contracts on the money path, landing on top of a batch that has not yet
reported a suite result. Rule 10: one money-path change per run, or a regression cannot be
attributed. Sequence: get the current batch green, then land `IBand` as its own unit with its own
run.

## What it unlocks

`Vogue` 21,339 + `Core` 13,587 = 34,926 > 24,576, so the managers still cannot merge into one
contract directly — the route runs through the library layer (`VogueLib` 15,340 ∥ `BtcVaultLib`
16,369, the ETH/BTC pair of one logic). **But `IBand` is the step that makes the merge expressible
at all**: once `Core` talks to a band through one face, "one implementation, two instances" is a
refactor of the two managers alone, with no consumer changes.
