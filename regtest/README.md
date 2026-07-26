# QU!D regtest harness

A self-contained, reproducible Bitcoin **regtest** node + the scripts that drive
the BTC-channel SPV end-to-end test. No sudo, no system install, **no blockchain
download** — everything lives under this folder and is gitignored.

```bash
cd SPV/regtest
./setup.sh         # one-time: download + checksum-verify bitcoin-core 28.1 → .bitcoin-core/
./start.sh         # boot regtest, create the "quid" wallet, mine 101 blocks (instant)
./gen-fixture.sh   # fund a real channel, confirm it, write the openChannel SPV fixture
(cd ../evm && forge test --match-path test/btc/OpenChannelE2E.t.sol -vv)   # real proof → real verifier
./stop.sh          # stop  (./stop.sh --wipe to also delete the chain data)
./cli.sh getblockcount   # ad-hoc bitcoin-cli (bound to this node + wallet)
```

Requirements: `bash`, `curl`, `python3`, `tar`, `sha256sum` (all standard), plus
`foundry` for the Solidity side. ~40MB download, a few hundred MB of RAM at most.

## Why regtest, not signet

For testing our SPV bridge + Lightning channel funding, **regtest is the right
choice — and it's the kindest to a low-spec machine**:

| | regtest | signet |
|---|---|---|
| chain download | **none** (local genesis) | syncs a real public chain |
| block production | **on demand, instant** (`generatetoaddress`) | ~10 min cadence, miner-controlled |
| control | full — exact confirmations, timestamps, reorgs | none — you take what the network gives |
| resolution for our tests | **maximum** (deterministic, every block ours) | coarse, non-deterministic |
| real PoW / difficulty | no (trivial target) | yes |

We need **maximum resolution with zero download**, which is exactly regtest:
mine blocks one at a time, place the funding tx at a known height, mine the exact
6 confirmations `openChannel` requires, all in milliseconds. Our `SPVGateway` is
regtest-compatible (constant `0x207fffff` target below the 2016 retarget,
`hash ≤ target` trivially satisfied, MTP monotone), so a regtest funding tx +
merkle proof flows through the **real** on-chain verifier unchanged.

The one thing regtest can't exercise — **real PoW difficulty / retargeting** — is
covered separately by the embedded **real signet fixtures** in
`evm/test/SPVGateway.t.sol`. So the split is deliberate:
- **regtest (here):** the live, on-demand funding → proof → `openChannel` e2e.
- **signet fixtures:** the PoW/header-chain cryptography.

Together: full coverage, no chain to download.

## What the e2e proves

`gen-fixture.sh` → `gen_open_channel_fixture.py` builds the protocol's SIMPLE-TAPROOT
(BOLT #995) **key-path P2TR** funding output `0x5120||Q` — byte-for-byte what
`BitcoinTx.buildTaprootScriptPubKey` emits and `ChannelLib.locateChannelOutput`
matches. Key-path taproot reveals no script on-chain, so there is nothing to
reconstruct and the contract does NO EC math: `Q` is lpAuth-committed (signed into
the OpenParams digest) and byte-matched. (This replaced the old P2WSH 2-of-2 +
`buildChannelRedeemScript`, which no longer exist in the contracts.) It funds +
confirms that output, and
shapes the witness-stripped legacy tx (so `double-sha256 == txid`), the merkle
branch (self-checked to fold to the block's real merkleroot), and the header
chain. `OpenChannelE2E.t.sol` then runs that real data through the **actual**
`SPVGateway` (init genesis → `addBlockHeaderBatch` → `checkTxInclusion`) and
`BTCChannels.openChannel` — channel written to the LP signer, `registerBtcLp`
credited. A committed fixture ships in the repo, so the Foundry test runs without
regtest; this harness **regenerates** it.

## Lightning layer — two real LND nodes + a real HTLC swap

```bash
./setup-ln.sh      # one-time: download LND (lnd + lncli) → .lnd-dist/
./start-ln.sh      # start alice (LP/seller) + bob (hop), open an alice→bob channel
./swap.sh 50000    # alice pays bob 50k sats over a REAL HTLC; capture the preimage
./stop-ln.sh       # stop both nodes  (--wipe to delete node data)
```

`swap.sh` writes `evm/test/btc/swapin_fixture.json` — `{ sats, paymentHash,
preimage }` from a genuine Lightning payment (`sha256(preimage) == paymentHash`).

### Driven automatically by `forge` (vm.ffi)

`evm/test/btc/.. testSwapIn_RealLightningHTLC` (in `Alles.t.sol`) orchestrates the
**whole thing from a single `forge test`**: `swapin-e2e.sh` (via `vm.ffi`) brings
up regtest + both LND nodes + the channel and performs the HTLC swap, then the
test:
1. proves ON-CHAIN that the settled `paymentHash == sha256(real LN preimage)`,
2. drives the REAL `BTCChannels.settleSwapIn` with that hash → mints QD to the
   seller against drawn `POOLED_USD_BTC`,
3. asserts a replay of the same real hash reverts (`SwapInReplay`).

It **skips cleanly** (suite stays green) if the harness binaries aren't installed
— so run `./setup.sh && ./setup-ln.sh` once, then `forge test` does the rest.

```bash
(cd ../evm && forge test --match-test testSwapIn_RealLightningHTLC -vv)
```

### The hop daemon (both directions) — runnable

`hop-daemon.sh` is the thin LN↔EVM bridge that runs against a local EVM:

```bash
./start-evm.sh         # anvil + deploy the demo stack (MockHopAux + real BTCChannels)
./swap.sh 50000        # swap-IN : alice pays bob a real HTLC (memo = seller EVM addr)
./swapout.sh 20000     # swap-OUT: alice makes an invoice; the EVM obligates the hop
./hop-daemon.sh once   # the daemon settles BOTH:
                       #   swap-IN  → BTCChannels.settleSwapIn(seller, sats, hash)
                       #   swap-OUT → bob pays the swapper's invoice (EVM→LN)
./stop-evm.sh
```

- **swap-IN (BTC→USD):** the seller pays the hop over Lightning; the daemon sees
  the settled invoice (memo carries the seller's EVM address) and calls
  `settleSwapIn` — dedup'd on the HTLC hash both off-chain and on-chain
  (`swapInUsed`).
- **swap-OUT (USD→BTC):** the EVM obligates BTC delivery (here `MockHopAux`
  records it; in production the V4 BTC pool emits it); the daemon pays the
  swapper's invoice (`bob → alice`) and marks it settled. Per-channel close P&L
  reconciles it on the EVM (covered by the fork tests).

Verified live: swap-in → `swapInUsed=true`, credit recorded for the memo seller;
swap-out → the swapper's invoice `SETTLED` and the obligation marked paid.

`./hop-daemon.sh` (no arg) runs the same logic as a watch loop — that loop is the
production hop service. (For a self-custodial LDK build instead of LND, it would
watch its own LDK node and call the same `settleSwapIn`; the bridge logic is
identical.)
