# ETH yield venues — depositor-chosen, per-LP hard-walled

The ETH that backs the QU!D ETH-LP is parked in an external yield venue **chosen per deposit by the
depositor** (no setter — the venue rides the deposit call) and **hard-walled per-LP**: your exit is
served from *your* venue, so one venue's incident can't drain another LP. (Consolidates the old
`ETHERFI.md` + `ETH-MULTI-VENUE.md`, both stale on the venue set.)

## The venues (verified 2026-08-01 against `Vogue.sol:1277-1281` and `imports/VaultLib.sol:115-117`)

> ⚠️ The earlier six-row table on this page was stale in two ways: it listed a `VENUE_ETHERFI` at
> id 1, and it omitted Gauntlet. There is deliberately **no id 1** — ether.fi always routes through
> Rover.

| id | what |
|----|------|
| 0 | `SPLIT` — **DEFAULT**, spreads across the curators, diversifying curator risk |
| 2 | `AAVE` — Aave-v4 spoke supply |
| 3 | `GALAXY` — Morpho V2 curator 4626; also the self-managed fallthrough |
| 4 | `ROVER` — ether.fi via the **protocol-owned** weETH/WETH v3 LP (fair-anchor, no cap/window) |
| 5 | `EULER` — a 2nd WETH 4626 curator, **fungible with Galaxy** |
| 6 | `GAUNTLET` — a 3rd WETH 4626 curator, fungible with the other two |

The 4626 curator set backing `vogueETH` is `[galaxy, euler, gauntlet]` plus weETH
(`VaultLib._venues`), and the constructor enforces the three being pairwise distinct
("vault:dupVenue") because aliasing two of them double-counts backing.

## Custody: `Vault`, via a pinned `ethVenue` handle
The WETH-side custody (Galaxy/Euler 4626 shares, Aave WETH, weETH) and its ops (`supplyETH`/
`withdrawETH`, `supplyEtherFi`/`supplyAaveEth`/`supplyEulerEth`/`supplyEtherFiToRover`,
`offrampEtherFi`, `vogueOp`/`vogueETH`) were **regrouped out of `Aux` into the `EthVenue`
contract** — `Aux` keeps a pinned handle (`Aux.ethVenue`) + thin forwarders. So "Aux holds the ETH"
in older notes is wrong; `EthVenue` does.

## ether.fi — yield in, exit through, never own
ether.fi (weETH) is a *yield route*, never a held position. Exit uses an **offramp ladder**:
instant-redeem rungs first (`testEthVenue_EtherFi_InstantRedeem_Rung3`), falling back to a
**withdraw-NFT** when instant liquidity is short (`…_WaitNFT`), and the Rover path offramps through
the protocol's own weETH/WETH LP. The redemption manager only emits native ETH / stETH.

## Curator-risk handling
Galaxy and Euler are both Morpho-style WETH 4626s and **fungible** (`vogueETH`/`deliverableETH`
count both; the withdraw ladder pulls from both; per-vault health/evacuate treats both as
ETH-venue vaults). A paused/down curator **reroutes** (`testGalaxyFallback_RevertReroutes`), and a
zero-shares supply reverts rather than stranding. Per-vault health is policed on-chain via
`pokeVaultHealth` (block + dwell-evacuate; see [[VAULT-WATCHER]]).
