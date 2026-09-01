# CHAIN-COUPLING — every EVM-specific assumption in the Lightning daemon/bridge

**Purpose.** A later sprint (after the EVM scope is complete) makes `quid-ln` — the daemon, bridge and
hop — settle against **SVM** as well as the EVM. This file is the inventory that sprint starts from:
every place the Lightning stack assumes an *Ethereum* settlement layer rather than *a* settlement
layer. It is a **coupling map, not a plan** — no abstraction is proposed here, because choosing one
before the list is complete is how the wrong seam gets cut.

⛔ **DO NOT START THE PORT FROM THIS FILE ALONE.** Written 2026-09-01 during the Bitcoin sprint, from
the couplings that surfaced while working. **It is not yet exhaustive** — the sweep that closes it is
named at the end. Rows are things measured in-tree, not recalled.

⚠️ **THE POINT IS NOT "REPLACE `alloy` WITH A SOLANA SDK".** Most of these rows are not about types or
RPC. They are about **semantics the protocol's safety arguments rest on** — what an address IS, what
"the chain says" MEANS, what is atomic, and when a record becomes visible. Swapping the client library
is the easy half and is not where a port goes wrong.

---

## 1. IDENTITY — an LP *is* an EVM address, derived from the key that funds the channel

| where | what it assumes |
|---|---|
| `evm_codec.rs` `lp_eth_of` / `ChannelLib.lpEthOf` | `lpEth` is **derived** from `p.lpPubkey` — Bitcoin and the EVM share **secp256k1**, so a channel key already states its EVM account. `openChannel` takes no address at all |
| `BTCChannels.btcRecipientOf[lpEth]` | the payout script is keyed on that derived address, and `_lpPayoutScript(lpEth)` derives the BTC destination FROM it |
| `_onlyHop()` | authority is a two-address constant (`MAIN_HOP`/`FALLBACK_HOP`), both EVM addresses |

🔴 **THIS IS THE DEEPEST COUPLING IN THE STACK AND IT IS NOT A TYPE.** Solana accounts are
**ed25519**, so *"the LP's Bitcoin funding key already names its settlement account"* has **no SVM
analogue**. Every property built on it has to be re-derived, not re-typed:
* §E183 deleted the LP's EVM signature *because* the address is derivable — that argument does not
  survive a chain where it is not.
* §HANDOFF-2026-08-15 forbids a rotatable `lpEth` because *"`_lpPayoutScript(channels[channelId].lpEth)`
  derives the BTC payout script FROM `lpEth`"* — reopening it is *"the attribution hole under a new
  name"*. An SVM account model must satisfy that same constraint or the hole reopens by construction.
⇒ **Decide the SVM identity model FIRST. Everything below inherits it.**

## 2. TRUTH — "what the chain says" is read as *EVM storage words at fixed offsets*

`channel_truth.rs` is the signer's on-chain comparand (§E177, and §T9 wires it):
```rust
const W_AMOUNT_SATS: usize = 0;
const W_KEYS_HASH:   usize = 5;
fn word(bytes: &[u8], i: usize) -> …      // 32-byte word slicing of a raw storage read
```
It assumes **fixed 32-byte words**, a **struct laid out in slot order**, and that a mapping entry that
was never written **reads as all-zero** — which is load-bearing: *"`keysHash == 0` IS the 'no record'
test"*, because an unwritten entry is indistinguishable from zeros.

🔴 **SVM HAS NO SLOT MODEL.** Accounts are byte buffers with program-defined layouts, and a
non-existent account is an **error**, not zeros. So both the READ and the *absence* test need
rebuilding, and the absence test is the subtle one: §E177 relies on absence being **cheap and
unambiguous** to distinguish *not yet recorded* from *contradicted*.
⚠️ Solidity slot order is also the fragile half on our own side — CLAUDE.md already warns that
reordering `Core`'s state breaks a harness reading raw slots.

## 3. ATOMICITY AND VISIBILITY — the one-way window is an EVM timing assumption

§T9's design (`§T9-IS-WIRING-E177`) rests on: *the EVM mirrors a splice only AFTER it confirms*, so a
signer context is legitimately **ahead** of the chain for a bounded window. That window's width is a
property of **how the bridge relays**, not of the EVM — but the *shape* of the fix (accept the current
scope or the one it replaces) assumes a single, totally-ordered settlement chain with monotonic
finality.
⚠️ **Re-derive it for SVM rather than porting it.** Solana's confirmed/finalized distinction and its
fork behaviour change what "already seen" means, and `truth_recorded` is a **one-way latch** whose
safety depends on never observing a record that later disappears.

## 4. AUTH BUNDLES — EIP-712 typed data, verified with `ecrecover`

| bundle | site |
|---|---|
| `MigrationAuth` (enclave upgrade, k-of-n) | `migration.rs` — *plain k-of-n msig, **NOT** a Gnosis Safe* |
| `SweepAuth` (operator-triggered sweep) | `sweep.rs` / `quid-bridge-daemon` |
| `OpenAuth.btcRecipientPoP` | ⚠️ **NOT EIP-712 — a BIP-340 Bitcoin signature** over `sha256(abi.encode(chainid, address(this), lpEth, bindHash))` |

🔴 **`btcRecipientPoPDigest` IS THE INTERESTING ONE AND IT IS A HYBRID.** The signature is *Bitcoin's*,
but its message commits to **EVM chain id** and **EVM contract address** — that binding is what stops
a PoP being replayed onto another chain or another deployment. **An SVM deployment needs an equivalent
domain separator, or the same PoP is valid on both chains at once.**
⚠️ `MIGRATION_THRESHOLD` k-of-n over **secp256k1 EOAs** also has no direct SVM analogue; Solana msig is
program-mediated and ed25519.

## 5. TRANSACTION MECHANICS — the shallow layer, listed for completeness

`client.rs`, `relayer.rs`, `evm.rs`, `signer.rs`, `abi.rs`, `hexutil.rs`: JSON-RPC, gas estimation,
nonces, selectors, `Address`/`U256`, hex encoding, and `read_gateway_height`'s **block-height**
confirmation counting. `boot.rs` derives the hot key as `evm_signing_key(&root_seed, "QUID_HOT_KEY")`.
✅ **This is the half a client-library swap actually addresses.** It is real work and it is not where
the risk is.

## 6. SETTLEMENT SEMANTICS THE BRIDGE ENCODES

`channel_driver.rs`, `swap_out_onchain.rs`, `swap_in.rs`, `vault.rs`: the **order** of settle-then-claim
(*"deliver the USD on-chain via `settleSwapIn` BEFORE taking the seller's BTC"*), reversibility of a
pending swap-out, and the reconciler's retry-until-mirrored loop. These encode **what a settlement
failure costs and who is exposed meanwhile** — chain-agnostic in intent, chain-specific in every
timing constant.

---

## What is NOT coupled, and is worth stating so the port does not touch it

✅ **Everything Bitcoin-side is already chain-agnostic** and must stay that way: the 2-of-2 MuSig2
custody, the pre-signed `ExitArming` ladder (§E188's *"funds = no key"*), `to_remote` derivation,
splice negotiation, the freshness/anti-rollback counters as a CONCEPT (their ANCHOR is coupled — §2),
and every LDK patch in `QUID_PATCHES.md`.
⇒ **A correct port changes where the anchor lives and what an account is. It must not touch how BTC
moves**, which is where the funds actually are.

## The sweep that closes this file

Not yet run — do it at the start of that sprint, not now:
1. `grep -rl "alloy_primitives" quid-ln/` — currently **20 files**. Classify each as §5 (mechanics,
   swap the library) or §1–§4 (semantics, re-derive).
2. Enumerate every `evm_codec.rs` entrypoint encoder against `evm/src` — `check-client-abis.py`
   already gates this pair and would gate the SVM pair too.
3. List every constant that is a **chain timing assumption** (confirmations, poll intervals, the CLTV
   headroom) — those are the ones that look portable and are not.

📌 **Rule for whoever runs it:** a row belongs here if a *correct* SVM implementation would have to
make a DIFFERENT decision — not merely call a different function.
