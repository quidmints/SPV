# ETH yield venue

Every ETH deposit becomes **weETH**, earning the full ether.fi staking rate.

There is no venue choice. `Quid.deposit(assets, receiver)` takes no venue argument, and
`QuidLib._supplyEtherFi` is the single destination — no dispatch, no default sink, no per-address
setting. A placement of 0 reverts `VenueUnavailable` rather than silently redirecting.

## Exit

Withdrawals run the ladder in `QuidLib.withdrawETH`; the ether.fi slice offramps through
`QuidLib.offrampBody` — the Curve weETH/WETH pool, else a multi-day no-fee withdrawal NFT minted to
the withdrawer.

Exits are **not** walled per depositor: the ETH leg is served from the aggregate ETH position
(`vogueETH`), and an illiquid slice is DEFERRED rather than charged to the exiting LP
(`deliverableETH`).

## Source of truth

`imports/QuidLib.sol` (`_supplyEtherFi`), `imports/QuidLib.sol` (`vogueETH`, `deliverableETH`,
`withdrawETH`, `offrampBody`).
