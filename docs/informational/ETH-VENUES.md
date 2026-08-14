# ETH yield venue

Every ETH deposit becomes **weETH**, earning the full ether.fi staking rate.

There is no venue choice. `Vogue.deposit(assets, receiver)` takes no venue argument, and
`VogueLib._supplyEtherFi` is the single destination — no dispatch, no default sink, no per-address
setting. A placement of 0 reverts `VenueUnavailable` rather than silently redirecting.

## Exit

Withdrawals run the ladder in `VaultLib.withdrawETH`; the ether.fi slice offramps through
`VaultLib.offrampBody` — the Curve weETH/WETH pool, else a multi-day no-fee withdrawal NFT minted to
the withdrawer.

Exits are **not** walled per depositor: the ETH leg is served from the aggregate ETH position
(`vogueETH`), and an illiquid slice is DEFERRED rather than charged to the exiting LP
(`deliverableETH`).

## Source of truth

`imports/VogueLib.sol` (`_supplyEtherFi`), `imports/VaultLib.sol` (`vogueETH`, `deliverableETH`,
`withdrawETH`, `offrampBody`).
