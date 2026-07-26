# QU!D Indexer

A small, self-hosted blockchain indexer for the QU!D protocol. It indexes the
events needed to reconstruct **net protocol flow** (mint/redeem/swap in & out)
from Ethereum mainnet into a local SQLite DB, and serves a tiny HTTP API the
QU!D Next.js dashboard queries.

It is a drop-in replacement for the SPA's current client-side `eth_getLogs`
reconstruction in `spa/src/lib/flow.ts`: the `GET /flow` response is
**shape-compatible** with that file's `NetFlow` interface, so the SPA swaps its
data source with a near-trivial change (fetch the indexer's `/flow`, fall back
to the in-browser `getLogs` path when the indexer URL isn't configured).

## What it indexes

Mirrors `flow.ts` exactly (the protocol emits no domain flow events by design;
flow is **reconstructed** from ERC20 transfers + channel events):

- **ERC20 `Transfer(from,to,value)`** on each stable + WETH, where `from` OR
  `to` is in the protocol set `{basket, aux, vogue}`:
  - into the set = **inflow** (mint / swap-in / LP-in)
  - out of the set = **outflow** (redeem / swap-out / LP-out)
- **BTCChannels** `ChannelOpened` (BTC **in**, in sats) / `ChannelClosed`
  (BTC **out**, in sats).

Stables are valued **at par ≈ $1** (USD = token units, normalized by decimals),
exactly as `flow.ts` does. ETH is the WETH leg in token units. BTC is signed
sats (opened − closed).

## API

### `GET /flow?windowHours=24`

Returns `NetFlow` JSON (shape matches `flow.ts`):

```jsonc
{
  "stables": [
    { "symbol": "USDC", "netUsd": 0, "inUsd": 0, "outUsd": 0 }
    // … one per configured stable (BOLD last)
  ],
  "stablesNetUsd": 0,   // sum of per-stable netUsd
  "ethNet": 0,          // signed ETH (WETH token units), in − out
  "btcNetSats": 0,      // signed sats, opened − closed
  "fromBlock": 0,       // first block included in the window
  "toBlock": 0,         // last finalized block (the cursor)
  "partial": false      // true if backfill doesn't yet cover the full window
}
```

`windowHours` defaults to `24`. The window is resolved to a block range using
the block timestamps stored at index time; the upper bound is the **finalized
cursor** (`head − CONFIRMATIONS`).

### `GET /health`

```jsonc
{ "ok": true, "lastBlock": 0, "headBlock": 0, "behind": 0 }
```

`lastBlock` is the finalized cursor; `behind = headBlock − lastBlock`.

CORS is permissive (`access-control-allow-origin: *`) so the browser SPA can
fetch cross-origin.

## Configure (env vars)

| Var | Default | Notes |
| --- | --- | --- |
| `RPC_URL` | `http://127.0.0.1:8545` | Ethereum JSON-RPC endpoint |
| `QUID_BASKET` | `0x0…0` | **Set post-deploy** — QU!D token / mint |
| `QUID_AUX` | `0x0…0` | **Set post-deploy** — swap / redeem |
| `QUID_VOGUE` | `0x0…0` | **Set post-deploy** — V4 LP manager |
| `QUID_BTC_CHANNELS` | `0x0…0` | **Set post-deploy** — channel registry |
| `QUID_WETH` | canonical mainnet WETH | override only if needed |
| `QUID_STABLE_<SYM>` | mainnet address | per-stable address override (rare) |
| `START_BLOCK` | `0` | **Set to the protocol deploy block** |
| `CONFIRMATIONS` | `12` | reorg-safety depth (see below) |
| `CHUNK_SIZE` | `2000` | `getLogs` block-range chunk |
| `POLL_MS` | `12000` | live poll interval |
| `PORT` | `4000` | API port |
| `DB_PATH` | `./quid-index.db` | SQLite file |

> **Contract addresses must be filled in post-deploy.** They default to the same
> zero-address placeholders as `spa/src/lib/chains.ts`. With all three of
> `{basket,aux,vogue}` unset the indexer runs but records zero stable/ETH flow
> (no protocol address to attribute transfers to); with `QUID_BTC_CHANNELS`
> unset, BTC sats flow is zero. The indexer logs a warning for each.
> Also set `START_BLOCK` to the deploy block — backfilling from genesis is
> impractical on a full node.

## Run

```sh
npm install          # builds the better-sqlite3 native addon
npm run build        # tsc → dist/
npm start            # backfill, then live-poll + serve the API
# or:
npm run backfill     # backfill to head−CONFIRMATIONS and exit (no serve)
```

Example with real config:

```sh
RPC_URL=https://your-rpc \
QUID_BASKET=0x… QUID_AUX=0x… QUID_VOGUE=0x… QUID_BTC_CHANNELS=0x… \
START_BLOCK=21000000 \
npm start
```

## Reorg / confirmations model

The durable **cursor** only ever advances to `head − CONFIRMATIONS`, so a chain
reorg shallower than `CONFIRMATIONS` can never have moved a block we've already
treated as final. Each poll re-scans the newly-finalized tail **from the
cursor** and upserts on `UNIQUE(tx_hash, log_index)`:

- a reorg that **replaces** a log re-INSERTs the same `(tx,log)` key with a new
  `block_hash` and **overwrites** the stale row in place (no duplicate, no
  double-count);
- a log that **vanishes** in a reorg is harmless because the cursor never
  advanced past it — it simply doesn't reappear on the canonical chain.

`block_hash` is stored so a re-scan's overwrite is observable. RPC calls are
chunked into `CHUNK_SIZE` ranges and retried with exponential backoff; a
transient RPC failure backs off and retries next tick rather than crashing the
loop.

## Architecture

- `src/config.ts` — env config + defaults; mirrors `chains.ts` addresses.
- `src/db.ts` — SQLite schema (`events`, `cursor`) + prepared queries.
- `src/indexer.ts` — backfill + reorg-safe live poll.
- `src/api.ts` — `node:http` server; `NetFlow` aggregation + `/flow`, `/health`.
- `src/main.ts` — wires config → db → indexer + api.

## Note on the `ChannelOpened` event

The deployed `BTCChannels` contract names the sats argument `sats` /
`satsReturned`, while `flow.ts`/`abi.ts` describe it as `totalSats`. The
**canonical type signature** is identical, so this indexer keys on the topic
hash and decodes the sats by ABI position (first non-indexed word), which is
robust to the argument name. The sats value used for BTC flow is therefore
correct regardless of the name discrepancy.
