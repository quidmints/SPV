# QU!D ops — hardened Bitcoin Core (anti-eclipse)

This directory holds the **production** ops artifacts for the node software the
hop/bridge self-hosts. Right now that is the hardened `bitcoin.conf` for the
Bitcoin Core full node that backs the chain source.

> Scope: this is a **mainnet production** artifact. The regtest test harness
> (`quid_hop::harness`) launches its own throwaway bitcoind — that is regtest,
> has no peers, and has no eclipse concern. Do not apply this config there.

## Why this exists: the eclipse threat

QU!D's BTC security ultimately rests on what our Bitcoin node believes is the
best chain. esplora-electrs indexes this node; the LDK node and the SPV header
relayer trust it for headers, merkle proofs, confirmations, and broadcast. So
the residual chain-source risk is a **P2P eclipse attack**:

An attacker who monopolises *all* of the node's peer connections controls the
node's view of the network. They can:

- feed a **stale or withheld tip** (hide new blocks),
- **censor** our funding/close/CPFP transactions (never relay them to miners),
- present a **low-work fork** with forged "confirmations" to make the node (and
  thus the on-chain SPV logic downstream) act on a chain that real miners will
  orphan.

Eclipse is achieved by flooding the node's **address manager (addrman)** so that
when it picks peers it only ever picks the attacker's, and/or by occupying all
inbound + outbound slots. The hardening below attacks each vector.

## The four defenses (mirrored in `bitcoin.conf`)

1. **`asmap=` — ASN bucketing (strongest).** addrman buckets candidate peers so
   no single source can dominate. By default it buckets by /16 IP prefix, which
   a cloud attacker spanning a few /16s can still flood. `asmap` buckets by
   **ASN** instead, so filling buckets requires control of many *distinct
   networks* — orders of magnitude more expensive. This is the most effective
   single measure. **You must supply the file** (see setup below).

2. **Outbound diversity + anchors.** Core makes 8 full-relay + 2
   block-relay-only outbound connections, diversified across network groups.
   The 2 block-relay-only peers are written to `anchors.dat` on shutdown and
   reconnected on restart (**on by default since v0.21**), so a restart can't be
   used to shake the node onto an attacker-seeded peer set. We keep these on and
   raise `maxconnections` for headroom.

3. **Persistent trusted peers via `addnode=` (NOT `connect=`).** Pinning a few
   known-good peers gives a stable honest anchor that addrman flooding can't
   displace. **You must set real peers** (see setup below).
   **Never use `connect=`** — it talks ONLY to the listed peers and disables all
   discovery, which would *cause* a total eclipse if those peers go bad. The
   config has a loud warning to this effect.

4. **Keep discovery ON.** `dns=1` / `dnsseed=1` (defaults) let the node find a
   wide, independent set of peers and heal its peer set. Turning discovery off
   in the name of "hardening" is an eclipse footgun; we set these explicitly so
   nobody disables them.

Plus DoS hygiene: `peerbloomfilters=0` / `peerblockfilters=0` (drop light-client
serving surface), a sane `maxuploadtarget`, and `debug=net` + `logips=1` so an
eclipse-in-progress (sudden peer churn, all-one-ASN inbound) shows up in logs and
monitoring.

## Operator setup — REQUIRED before production

The config will not work safely until you do these two things:

### 1. Supply an `asmap` file

`bitcoin.conf` sets `asmap=asmap.dat` (resolved relative to the **datadir**; an
absolute path is used as-is). bitcoind **refuses to start if the file is
missing** — fail-closed by design.

Get/maintain the map via Bitcoin Core's own tooling:

- The canonical asmap tooling lives in the Bitcoin Core repo under
  `contrib/asmap/` (it builds an `asmap.dat` from a routing table / RIB dump).
- Prebuilt, periodically-updated dumps are published by the community
  (e.g. the `fjahr/asmap-data` repo). Verify provenance before trusting one.

Then place the resulting file at `<datadir>/asmap.dat` (or change the `asmap=`
path). Refresh it periodically (ASNs change); a stale map still helps but a fresh
one helps most.

### 2. Set real `addnode=` peers

In `bitcoin.conf`, uncomment and replace the `addnode=` placeholders with **2–4
real peers you trust** — ideally:

- your organisation's other bitcoind nodes (different ASN/region where possible),
- a partner / known-good operator's node,
- optionally a `.onion` peer for network-path diversity.

Diversity across ASNs/regions matters more than raw count. **Do not** convert
these to `connect=`.

### 3. RPC auth (not eclipse, but don't ship the placeholder)

Generate an `rpcauth` line with Core's `share/rpcauth/rpcauth.py`, put the
resulting `rpcauth=user:salt$hash` in the config, and keep the cleartext
password out of git. RPC is bound to loopback for the co-located electrs.

## Verifying the posture on a running node

```bash
# Peer count + that we have outbound (non-inbound) and block-relay peers:
bitcoin-cli getpeerinfo | jq '[.[] | {addr, inbound, connection_type}]'
bitcoin-cli getnetworkinfo | jq '{connections, connections_in, connections_out}'

# Confirm the asmap was loaded (addrman buckets by ASN). getrawaddrman shows the
# mapped_as field per entry when an asmap is active:
bitcoin-cli getrawaddrman | jq '[.. | .mapped_as? // empty] | length'
```

A healthy node has several outbound peers spread across multiple ASNs, the 2
block-relay-only anchors, and a non-empty addrman with `mapped_as` populated.
