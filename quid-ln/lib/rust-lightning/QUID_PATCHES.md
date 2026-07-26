# Vendored `rust-lightning` (LDK) — QU!D fork-of-a-fork

This directory is a **vendored copy** of the lexe LDK fork, pinned to:

    https://github.com/lexe-app/rust-lightning   branch lexe-v0.2.2-2026_04_28   (commit 027c6a1)

It is vendored (rather than referenced by git) so QU!D can carry a small,
explicit local patch. The workspace `[patch.crates-io]` in `quid-ln/Cargo.toml`
points the `lightning*` crates at this path instead of the git source.

Treat everything here as upstream/read-only **except** changes tagged
`QU!D PATCH` (grep `QU!D PATCH`). Re-vendoring (to bump the lexe branch) means
re-copying the checkout and re-applying these patches.

## QU!D patches

### 1. `ChannelMonitor::funding_pubkeys()` — `lightning/src/chain/channelmonitor.rs`

Adds a public accessor returning the channel's two 2-of-2 funding pubkeys
`(holder, counterparty)`.

**Why:** `BTCChannels.openChannel` requires `OpenParams.{lpPubkey,hopPubkey}`
(the sorted 2-of-2 funding keys) at OPEN time. The funding output is a P2WSH
that hides the keys until the output is spent (channel close), so they can't be
read from chain at open. Upstream LDK exposes funding keys only through
`#[cfg(test/_test_utils)]` accessors (`do_mut_signer_call`,
`unsafe_get_latest_holder_commitment_txn`); nothing public maps a channel to its
funding pubkeys or `channel_keys_id`.

**Safety:** the funding pubkeys are PUBLIC, non-secret data (they appear in the
funding redeem script and are revealed on-chain at every close). Exposing a read
accessor leaks no key material. The Solidity side remains correct-by-construction
regardless: `ChannelLib.openChannelBody` independently rebuilds
`P2WSH(redeem(lp,hop))` and requires it to equal the on-chain funding output, so
a wrong/forged pubkey pair simply fails the contract check.

### 2. `ChannelContext::counterparty_shutdown_scriptpubkey()` + `ChannelDetails.counterparty_shutdown_scriptpubkey` — `lightning/src/ln/channel.rs`, `lightning/src/ln/channel_state.rs`

Adds a public getter on `ChannelContext` and a corresponding `Option<ScriptBuf>`
field on `ChannelDetails` (populated in `from_channel`, TLV id 49, optional) that
surface the counterparty's committed upfront shutdown script.

**Why:** `BTCChannels.recordClose` reads the LP's final balance from the
cooperative-close tx by summing outputs paying `P2WPKH(btcRecipientOf)`
(`_lpFinalBalance`). For that attribution to be correct, the LP's coop-close
payout must land on the script the EVM expects. The hop drives the hop-gated
`openChannel`, so it can refuse to register a channel whose LP payout script
won't conform — but only if it can READ the committed payout script. Upstream
LDK keeps `counterparty_shutdown_scriptpubkey` private to `ChannelContext`; no
public path (including `ChannelDetails`) exposes it.

**Safety:** the shutdown script is PUBLIC, non-secret data exchanged in
`open_channel`/`accept_channel` and revealed on-chain at every cooperative close.
Exposing a read accessor leaks no key material. It's purely additive (a new
optional field at an unused TLV id), so serialization stays backward-compatible.

Consumed by `quid-bridge::channel_driver::drive_open` (via
`quid-hop::node::channel_counterparty_shutdown_script`): the hop reads the LP's
committed P2WPKH shutdown script, derives its `HASH160`, and passes it to
`BTCChannels.openChannel`, which records it as `btcRecipientOf[lpEth]` — so the
LP's cooperative-close balance is attributed to exactly the output LDK pays it
to. Paired with `commit_upfront_shutdown_pubkey = true` (quid-hop node config),
which makes the script available at open and enforced unchanged at close.

### 3. `ChannelMonitor::original_funding_txo()` — `lightning/src/chain/channelmonitor.rs`

Adds a public accessor returning the channel's ORIGINAL (first-negotiated) funding
outpoint, which is STABLE across splices — unlike `get_funding_txo()`, which the
upstream docs say "will change for every splice that has reached its intended
confirmation depth."

**Why:** `BTCChannels` keys a channel's id on its ORIGINAL funding outpoint and
keeps that id across a SPLICE (which only rotates the live funding UTXO). The
bridge's channel reconciler iterates LDK monitors and recomputes each channel's
on-chain `channelId` to mirror open/close/splice. If it derived the id from
`get_funding_txo()` (the rotated, post-splice outpoint) it would mis-key every
spliced channel: it would read "not opened" and drive a PHANTOM second
`openChannel` (a double-count of the LP's BTC), and would never recognise the
channel's close. Upstream LDK keeps `first_negotiated_funding_txo` private with no
public accessor.

**Safety:** the funding outpoint is PUBLIC, non-secret data (it's an on-chain
txid:vout, visible whenever the funding tx confirms). Read-only; leaks no key
material; purely additive. Consumed by
`quid-bridge::channel_driver::run_channel_reconciler` to compute the stable on-chain
`channelId` (and to detect a splice the EVM mirror hasn't caught up to:
`ldk_value > on-chain amountSats` ⇒ re-drive `spliceChannel`).
