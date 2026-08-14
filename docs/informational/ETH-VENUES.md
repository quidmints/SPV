# ETH yield venues

The ETH backing the QU!D ETH-LP is parked in an external yield venue chosen per deposit by the
depositor — the venue rides the deposit call, there is no setter.

## The venues

| id | what |
|----|------|
| 0 | `SPLIT` — spreads across the venues below |
| 2 | `AAVE` — Aave-v4 spoke supply |
| 4 | `ETHERFI` — direct weETH, earning the full ether.fi staking rate |

There is no id 1 or 3, and no default sink: a chosen venue that places 0 reverts `VenueUnavailable`
rather than silently redirecting, because no venue can be assumed always-live.

## Exit

Withdrawals run the ladder in `VaultLib.withdrawETH`; the ether.fi slice offramps through
`VaultLib.offrampBody` — the Curve weETH/WETH pool, else a multi-day no-fee withdrawal NFT minted to
the withdrawer.

Exits are **not** hard-walled per venue: the ETH leg is served from the aggregate ETH position
(`vogueETH`), and an illiquid slice is DEFERRED rather than charged to the exiting LP
(`deliverableETH`).

## Source of truth

`Vogue.sol` (venue codes), `imports/VogueLib.sol` (`_supplyEtherFi`), `imports/VaultLib.sol`
(`vogueETH`, `deliverableETH`, `withdrawETH`, `offrampBody`).
