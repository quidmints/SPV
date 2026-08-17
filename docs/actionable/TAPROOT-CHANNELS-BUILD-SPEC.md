# QU!D Simple Taproot Channels — Build Spec (verbatim-grounded)

> Single source of truth for the key-path-MuSig2 taproot-channel build. Every
> rule here is grounded in a PRIMARY spec (cited). Implement against THIS, not
> memory. Authoritative sources consulted verbatim:
> - **BIP327** (MuSig2): https://github.com/bitcoin/bips/blob/master/bip-0327.mediawiki
> - **BIP340** (Schnorr) / **BIP341** (Taproot): bitcoin/bips
> - **BOLT simple-taproot-channels** (lightning/bolts PR #995, merged 2026-05-04):
>   `bolt-simple-taproot.md` (feature bits 80/81). Extension BOLT — base BOLT #2/#3
>   inherited, overridden only where it says so.
> - Cross-check: Optech simple-taproot-channels topic; LND #7904/#9982/#9985.

---

## ⚠️ STATUS AS MEASURED 2026-08-17 — READ THIS BEFORE ANY MILESTONE BODY BELOW

**Every per-milestone status in §7 and §9 is written in the present tense and MOST OF IT IS NOW
FALSE.** The bodies were authored 2026-06-21/22; the work landed over the following weeks and nobody
came back to re-mark them. They still read as live gaps, including three marked 🔴 CRITICAL. Their
DESIGNS remain the reference — the value is in the design text, not the status.
⇒ Measured today by grepping structure (not by trusting a marker), plus one full suite run:

| claim in the body below | measured state 2026-08-17 | evidence |
|---|---|---|
| **M9f-0** 🔴🔴 "coop-close nonce reuse leaks the funding private key … CONFIRMED, not to verify" | ✅ **FIXED** — the closing nonce is per-ROUND | `lightning::sign::closing_nonce_height(round)` + `CLOSING_NONCE_BASE` (`sign/mod.rs:2525-2536`), mirrored in `quid_ln::validating_signer:1717-1726`; used at `channel.rs:6553/11304/11359`; a test asserts round-0 vs round-1 pubnonces DIFFER (`validating_signer.rs:2929-3037`) |
| **M9a** "the real aggregated key-path sig … is DISCARDED, so a holder can never broadcast its own commitment" | ✅ **stored + persisted** | `HolderCommitmentTransaction.taproot_key_path_sig: Option<schnorr::Signature>` + `with_taproot_key_path_sig` (`chan_utils.rs:2211/2327`), serialized as TLV 8 (`:2243`) — so it survives a reboot, which is the whole point |
| **M9b** 🔴 "the taproot tx-builder emits no HTLC outputs/sigs" | ✅ **built** | `taproot_htlc_leaves` / `get_taproot_htlc_spk` / `taproot_htlc_leaf_sighash` / `build_taproot_htlc_input_witness` / `with_taproot_htlc_sigs`; `channel.rs:5374` handles `msg.htlc_partial_signatures` |
| **M9c** "`sign_splice_shared_input` … `Taproot(_) => todo!()`" | ✅ **implemented + tested** | `ValidatingChannelSigner::partially_sign_splice_shared_input` (`:1652`) with a round-trip test (`:3343-3428`) |
| **M9d** "`ChannelReestablish` has NO nonce field" | ✅ **wired** | `msgs.rs:1036/1043` — `next_local_nonce` **and** `next_local_nonces: Vec<(Txid, PubNonce)>` for spliced channels |
| **M9e-4** 🔴 "the anchor zero-fee holder-HTLC claim signs ECDSA/P2WSH" | ✅ **taproot-aware** | `events/bump_transaction/mod.rs:100-163, 1027-1036` — `get_taproot_anchor_spk`, `taproot_tx_input_witness`, taproot-specific HTLC satisfaction weights |
| **M9g** 🟠 "QU!D's taproot channels carry NO anchor outputs" | ✅ **anchors negotiated** | `get_initial_channel_type` (`channel.rs:15466-15478`) layers `set_anchors_zero_fee_htlc_tx_required()` into the taproot branch |
| **M6** "REMAINING — BLOCKED on a signer-variant change; nothing ever builds `::Taproot`" | ✅ **unblocked** | `channel.rs:3570/3982` — `let holder_signer = if channel_type.supports_simple_taproot()` |
| **M9-final #1** "zero `todo!()`" | ✅ **zero real ones** | `grep -rn "todo!(" quid-ln --include=*.rs` = **7 hits, all inside comments/doc-prose**; the vendored `lightning` tree has **one**, and it is a comment |

**Suite, run today in the pinned Docker image** (`cargo test --workspace`, the only way it builds —
`quid-cvm` is Linux-only): **712 passed / 0 failed / 43 ignored, 66 suites**, exit 0. Was recorded as
624 on 2026-08-07.
⚠️ **The 43 ignored were enumerated, not waved past** — they are doc-examples, snapshot *dumpers*
(`dump_*`/`take_*_snapshot`) and one live-network test (`transport::tests::live_l1_chain_id_and_block_number`).
**None is a taproot or channel-lifecycle test**, so the green run is not hiding the M9 coverage. That
check matters because §9's own meta-rule is that a passing interactive test proves nothing about the
offline/adversarial branches.

### ⇒ WHAT IS ACTUALLY LEFT (the honest remainder)

1. **§9 M9f — the four VERIFY bullets.** One is now answered; see the note added to M9f itself.
2. **M9-final #2 — "Bucket 2" dead-P2WSH removal (QU!D side). Not done; the READ-ONLY AUDIT IT ASKS
   FOR IS NOW DONE for the main symbol, and the answer is "test-only".** `quid-hop/src/funding.rs:37`
   defines `p2wsh_script_pubkey`; its only two callers (`funding.rs:139`, `evm_codec.rs:1484`) are
   **both inside `#[cfg(test)]` modules**, and what they assert is the *P2WSH shape itself* — the
   pre-taproot format QU!D no longer negotiates. Same for `channel_redeem_script` (the 71-byte 2-of-2).
   ⚠️ **Reachability is not the whole test — `create_sweep_tx` was deleted twice on exactly this
   evidence and restored twice** (`CLAUDE.md`: `git log -S` the symbol before deleting it). So this is
   reported as MEASURED, not as authorisation: a symbol whose only callers are tests asserting a
   retired wire format is a genuine removal candidate, but the decision belongs with whoever owns the
   e2e fixtures, and the spec's PROCEDURE ("do not yank `e2e_ffi` out from under a still-used test")
   is the constraint.
3. **§10 FINAL AUDIT — the COVERAGE largely exists; what has no recorded output is the audit as a
   PROCESS.**
   ⚠️ **I first wrote "not started" here, and that was an absence claim from the doc's silence — the
   move `CLAUDE.md` forbids ("never assert absence from a search"). Corrected by enumerating the
   tests.** There are **40 taproot test functions** across the vendored `lightning` tree and
   `quid-ln`, and they land squarely on §10's areas rather than on the happy path:
   `taproot_splice_shared_input_signatures_verify` (area 7),
   `taproot_closing_and_splice_nonce_heights_disjoint_and_distinct` +
   `taproot_splice_nonce_distinct_per_prev_funding_txid` + `taproot_ctx_rejects_closing_round_regression`
   (area 11, no-nonce-reuse), `taproot_resolution_htlc_sighash` / `taproot_sweep_keyspend_sighash` /
   `taproot_sweep_leaf_sighash` / `taproot_to_remote_spend_info` / `taproot_to_local_spend_info`
   (areas 4–6, on-chain resolution), `taproot_ctx_rejects_counterparty_funding_key_swap` +
   `taproot_ctx_rejects_funding_value_change` (adversarial context substitution),
   `taproot_builder_commitment_and_close_signatures_verify` (areas 1–3).
   ⇒ **What is genuinely missing is §10's METHOD, not its subject matter:** the fan-out of independent
   readers per area, each finding adversarially verified, with a completeness critic asking which
   modality is unexercised — and a written record of the result. That is worth doing, and it is
   cheaper than the doc implies, because the per-area tests it would look for mostly already exist.
   ⚠️ **Do NOT read the list above as area-by-area sign-off.** These are *signer- and
   builder-level* tests; §10 asks for the **monitor-detection → package → broadcast** path and
   two-node/offline branches (its own meta-rule: "a passing interactive test proves nothing about
   these"). Mapping the 40 onto the 12 areas and naming the empty cells IS the audit's first step.
4. **§11 M11 — SGX BUILD done (2026-07-11), in-enclave EXECUTION still unproven on real hardware.**
   Unchanged and correctly last.
5. **Outside this spec:** the EVM-side rotation/ladder gap — two of five outpoint-rotation sites still
   arm nothing (`BTC-CUSTODY-OPEN.md` §3, §E233-ladder).

---

## 0. Dependency foundation (DECIDED: stay on bitcoin 0.32 + conduition musig2 — path of least resistance)
- **STAY on `bitcoin 0.32` / `secp256k1 0.29`** — the whole workspace (LDK fork +
  the BDK/esplora/miniscript wallet stack the hop/bridge uses) is already here and
  compiles green. **No migration.**
- **MuSig2 = conduition `musig2 0.1.2`** (`[target.'cfg(taproot)'.deps]` of the
  `lightning` crate, replacing the dead arik-so dep). Its **0.1.x line rides
  `secp256k1 ^0.29`** = our exact version ⇒ native types end-to-end, **NO shim, NO
  version conflict, NO ecosystem fork.** `features=["secp256k1"]` → EC math on
  libsecp256k1; protocol logic is BIP327-vector-conforming + differentially fuzzed
  vs the BIP327 reference. Pin exactly + review its ~6 protocol files (unaudited — the
  one accepted residual). NOT 0.4.x (that's the secp256k1-0.31 line → would reintroduce
  a version bump).
- **Why not the "authoritative" libsecp256k1 musig (rust-secp256k1 0.32):** it requires
  `bitcoin 0.33`, which is **permanently beta** (maintainers will never ship 0.33.0;
  next is 0.34-beta) and would force forking the entire BDK/miniscript/esplora stack to
  0.33 (miniscript 13.1.0, latest, is still `bitcoin ^0.32.6`). Verified: 0.33 has **no
  non-musig benefit** we'd lose (only a `MAX_MONEY` Amount check we already clamp + a
  PSBT serde break = a cost). Nothing to gain → don't migrate. Revisit native musig only
  if the whole stack later moves to the 0.34 line for other reasons.

## 1. MuSig2 (BIP327) — load-bearing rules (conduition `musig2 0.1.2` API)
- **KeySort BEFORE KeyAgg.** Sort the 33-byte compressed keys lexicographically (BIP327
  `KeySort`); the BOLT mandates `KeyAgg(KeySort(pk1,pk2))`. Pass the sorted keys to
  `KeyAggContext::new([..])`. **The Rust signer, the counterparty, AND the EVM contract
  MUST use the identical sort** or `Q` mismatches → unspendable funding.
- **Taproot tweak (key-path-only / BIP86):** `KeyAggContext::new(sorted)
  .with_unspendable_taproot_tweak()` — this applies the x-only tweak `t =
  H_TapTweak(agg_xonly)` with an EMPTY merkle root (no script path), exactly BIP341
  §158. (`with_taproot_tweak(merkle_root)` exists for script-path; we don't use it.) The
  tweaked output key is `ctx.aggregated_pubkey()`. Tweak the context BEFORE signing
  (the partial-sig aggregation folds the tweak). Both signers independently recompute
  `Q` via `with_unspendable_taproot_tweak()` before signing (anti-hidden-leaf, BIP341 §158).
- **NONCES — deterministic per-commitment (BOLT), NOT random.** `musig2_shachain_root
  = hmac(msg, sha256(shachain_root))`, secret nonce derived per **commitment height**
  (mirrors revocation-secret derivation). This is the authoritative LN scheme and is
  **crash-safe** (re-derivable for a fixed height/message → no reuse-with-different-
  message on restart; nothing secret to persist). It SUPERSEDES the earlier "randomize
  the nonces" instruction — randomization would deviate from the interop spec AND
  reintroduce the persist/reload reuse hazard. The `next_local_nonces` map keyed by
  **funding TXID** (in `revoke_and_ack`/`channel_reestablish`) is a SEPARATE concern
  (multi-channel/splice transport), not the per-commitment uniqueness mechanism — do
  not conflate. Nonces are "100% ephemeral, forgotten even after a dropped connection";
  re-sent fresh on reconnect.
- **Round flow (conduition `FirstRound`/`SecondRound`):** R1 each party builds a
  `FirstRound` (holds the `SecNonce`; from the shachain-derived nonce seed, §above) →
  exchange `PubNonce` → `first_round.receive_nonce(..)`; the `AggNonce` is formed inside.
  R2 `first_round.finalize(seckey, message) -> SecondRound` → `second_round.our_signature()`
  is our `PartialSignature` → exchange → `second_round.receive_signature(idx, partial)`
  (**verifies each partial — REQUIRED, it errors on a bad one**) → `second_round.finalize()
  -> secp256k1::schnorr::Signature` (the aggregated key-path sig). (Lower-level
  `sign_partial`/`aggregate_partial_signatures` exist if we drive rounds manually.)
- **Cache the `KeyAggContext` per channel** (integrity-protected). Fresh round/nonce per
  signature; `SecNonce` single-use, dropped, never persisted (re-derivable from shachain).

## 2. Taproot funding (BIP340/341 + BOLT)
- Output script: **`0x51 0x20 || Q`** (34 bytes). `Q = lift_x(agg) + int(H_TapTweak(bytes(agg)))·G`,
  empty merkle root. (BOLT: `funding_key = KeyAgg(KeySort(p1,p2)) + tagged_hash("TapTweak",combined)·G`.)
- Tagged hash: `SHA256(SHA256(tag)||SHA256(tag)||x)`, tag `"TapTweak"`.
- Key-path sighash (coop close / commitment): `hash_TapSighash(0x00 || SigMsg(0x00,0))`,
  `spend_type=0`, SIGHASH_DEFAULT (64-byte sigs). Signer feeds funding amount +
  the 34-byte scriptPubKey (committed via `sha_amounts`/`sha_scriptpubkeys`).
- Parity handled by libsecp256k1's cache tweak path — **never hand-roll the point math.**
- **EVM:** build `0x5120 || Q` and byte-match the SPV-proven funding output. NO on-chain
  EC. Sufficient + correct (consensus does spend-time verification; trust = lpAuth
  consent to Q + off-chain MuSig2 keygen guarantees the 2-of-2).

## 3. Commitment tx format (BOLT, M4)
- Internal key for to_local/to_remote = **NUMS** `02dca094751109d0bd055d03565874e8276dd53e926b44e3bd1bb6bf4bc130a279` (script path always taken).
- **to_local** tapleaves: `to_delay`: `<local_delayed> OP_CHECKSIGVERIFY <to_self_delay> OP_CSV`;
  `revoke`: `<local_delayed> OP_DROP <revocation> OP_CHECKSIG` (LND optimized to CHECKSIGVERIFY).
- **to_remote**: single leaf `<remote> OP_CHECKSIGVERIFY 1 OP_CSV` (1-block CSV).
- **anchors**: internal key = remote/local_delayed; leaf `OP_16 OP_CSV`.
- **HTLC**: internal key = `revocation_pubkey`; timeout/success leaves; 2nd-level txs reuse
  to_local structure. **HTLC sigs = plain BIP340 Schnorr** (only funding spends are MuSig2).
- **HTLCs NOT mandatory for a minimal channel** (no-HTLC config is spec-blessed) → first
  channel milestone = open/coop-close/force-close, NO HTLC tapscripts. QU!D needs HTLCs
  later (swap-in = inbound HTLC claim; swap-out = outbound BOLT11 pay) — separate milestone.

## 4. Message / nonce flow (BOLT). Field NAMES + sizes authoritative; TLV type NUMBERS confirm against source.
| msg | field | size/role |
|---|---|---|
| open_channel / accept_channel | `next_local_nonce` | 66B verification nonce |
| funding_created / funding_signed | `partial_signature_with_nonce` | 98B (32B sig + 66B nonce) |
| channel_ready | `next_local_nonce` | 66B fresh verification nonce |
| commitment_signed | `partial_signature_with_nonce` | 98B |
| revoke_and_ack | `next_local_nonces` (map by funding TXID) | 66B each |
| channel_reestablish | `next_local_nonces` (map by funding TXID) | resync |
| shutdown | `shutdown_nonce` | 66B closer init |
| closing_complete | `partial_sig_with_nonce` | 98B closer partial+JIT nonce |
| closing_sig | `partial_sig` (32B) + `next_closee_nonce` (66B) | closee + next RBF round |

## 5. Cooperative close + force-close
- **Coop close:** MuSig2 key-path + RBF. `shutdown`(shutdown_nonce) → `closing_complete`
  (partial_sig_with_nonce) → `closing_sig`(partial_sig + next_closee_nonce). JIT nonces;
  only the current closee nonce held in memory. Single 64-byte Schnorr = smallest close.
- **Force-close = commitment broadcast** (verification nonce → final sig). Balance-respecting.
  **This is the BTC non-custodial backstop (Option C) — CONFIRMED by the spec; there is
  NO funding-level CLTV refund leaf** (key-path-only funding has no script path for one).
  EVM `recordClose` unchanged for taproot: outpoint match + locktime discriminator
  (force-close = nonzero locktime → delivered=0; coop = locktime 0 → reads LP payout).

## 6. QU!D-specific change sites
- `quid-hop/src/funding.rs`: `channel_redeem_script`→P2TR (KeySort+KeyAgg+tweak); `p2wsh_script_pubkey`→`p2tr` (`0x5120||Q`). Stay byte-identical to the EVM mirror.
- `quid-hop/src/evm_codec.rs`: `funding_pubkeys_from_witness` (71-byte 2-of-2 parse) BREAKS — a key-path close has an empty witnessScript. Recover funding keys from the **stored open-time Q / OpenParams** instead.
- `quid-hop/src/node.rs`: `funded_output`, `channel_funding_pubkeys` (x-only 32B), `initiate_splice_out` LP payout (P2WPKH ok, or P2TR).
- `quid-ln/src/validating_signer.rs`: impl **`TaprootChannelSigner`** alongside `EcdsaChannelSigner`. REUSE `PolicyState` (anti-revoked-reuse, index-based, scheme-agnostic) + `check_closing_payout_script` (recompute committed script for taproot). 8 methods wire `secp256k1::musig`.
- EVM `ChannelLib.sol`/`BTCChannels.sol`: commit-`Q` adapter — build `0x5120||Q`, relax 33→32-byte key checks, OpenParams carry `Q` (32B), channelId/`ChannelOpened` event shape. **Pre-mainnet ⇒ taproot-only (no dual P2WSH/P2TR support needed).**

## 7. Milestones (TDD; each green before next; report green/remaining)
- **M0** ~~bitcoin-0.33 port~~ → DROPPED. Stay on bitcoin 0.32 (already green); wire conduition `musig2 0.1.2` (`features=["secp256k1"]`) into the `lightning` cfg(taproot) deps + `quid-ln`. *(dep swap done; verify `cargo build -p lightning` still green.)*
- **M1** MuSig2 keyagg + P2TR funding script via `KeyAggContext::new(KeySort(..)).with_unspendable_taproot_tweak()` — `funding.rs` byte test + EVM `ChannelLib` mirror.
- **M2** (A) FOLD taproot into the DEFAULT build — move musig2 to `[dependencies]`, remove all `#[cfg(taproot)]` gating (resolve each cfg(taproot)/cfg(not(taproot)) pair → keep taproot, drop fallback; no conflicts); plain `cargo build` + existing tests stay green. (B) `TaprootChannelSigner` (8 methods, conduition musig, shachain nonces, reuse policy) + the 2-party key-path roundtrip + nonce-determinism unit tests.
- **M3** taproot feature bit (80/81) + `get_initial_channel_type` negotiation.
- **M4** commitment/closing tx format (NUMS + tapscripts) — NO-HTLC first.
- **M5** nonce-exchange handler state machine (open/funding/commitment/revoke/close).
  *Signer layer DONE + proven:* the 3 MuSig2 `TaprootChannelSigner` bodies
  (`partially_sign_counterparty_commitment` / `finalize_holder_commitment` /
  `partially_sign_closing_transaction`) are implemented; the deterministic
  per-height JIT nonce, the per-signer round helpers
  (`taproot_signer::our_key_path_partial` / `aggregate_key_path_partials` /
  `local_pubnonce`), and the late-bound `TaprootSignerContext` seam
  (`provide_taproot_context`) are wired; a functional test
  (`taproot_open_commitment_and_coop_close_signatures_verify`) drives the full
  open→commitment→coop-close MuSig2 flow and asserts every aggregate key-path
  Schnorr sig verifies vs the tweaked `Q`. **PREREQUISITE for the ChannelManager
  wire-integration moved to M6** (the channel.rs `_ => todo!()` send-arms STAY —
  they cannot produce a correct sig yet because (a) LDK's commitment/funding/close
  tx *builder* is still P2WSH — never branches on `supports_simple_taproot()` — so
  a taproot sig would cover the wrong tx, and (b) the nonce *plumbing* is absent:
  `open_channel`/`CommonOpenChannelFields` has no `next_local_nonce` field/TLV, no
  handler reads/stores incoming nonces, and `ChannelContext` has no nonce storage.
  Both are tx-builder/handler concerns, not signer-state-machine concerns).
  Also DONE: lib-test compile fix (missing `counterparty_shutdown_scriptpubkey`).
- **M6** QU!D wiring (funding/evm_codec/node) + EVM commit-`Q` adapter + LDK↔BDK
  byte seam **+ make LDK's commitment/funding/close tx builder taproot-aware
  (NUMS-tapscript outputs + `0x5120||Q` funding SPK + `taproot_funding_keyspend_
  sighash`) + add the `open_channel` `next_local_nonce` TLV + `ChannelContext`
  nonce storage + the ChannelManager handler nonce exchange that drives the M5
  signer bodies, then fill the channel.rs `_ => todo!()` send-arms**.
  *Progress (this pass):*
  * **DONE — taproot tx-builder:** `insert_non_htlc_outputs` branches on
    `channel_type.supports_simple_taproot()` → `to_local`/`to_remote`/anchor
    outputs use the M4 NUMS-tapscript SPK builders; `secp_ctx` threaded through
    `build_outputs_and_htlcs`/`rebuild_transaction`/`verify`. Funding output is
    P2TR via new `chan_utils::channel_taproot_script_pubkey` /
    `taproot_funding_aggregate_xonly` (KeySort+KeyAgg+unspendable-tweak → `0x5120||Q`,
    mirrors `quid_ln::taproot_signer` w/o a quid-ln dep) + `FundingScope::get_funding_spk()`
    wired at the 4 funding-SPK sites. Non-taproot path byte-identical.
  * **DONE — nonce TLV/storage:** `next_local_nonce` (TLV type 4) added to
    `CommonOpenChannelFields` + serialized in `open_channel`/`open_channel2`
    write/read (the accept/funding/commitment/RAA nonce fields were already
    scaffolded in M5). `ChannelContext` gains `cur_counterparty_taproot_nonce` +
    `cur_counterparty_closing_nonce`. `ChannelSignerType::as_taproot()` accessor added.
  * **DONE — TDD proof:** `quid-ln` test
    `taproot_builder_commitment_and_close_signatures_verify` drives the REAL LDK
    taproot tx-builder + the proven M5 signer end-to-end: asserts P2TR commitment
    outputs + `0x5120||Q` funding SPK and that LP+hop key-path partials over the
    BIP341 sighash of the taproot-format commitment/close txs aggregate to a
    BIP340 sig verifying vs `Q`. (M5's test used a P2WSH channel type → the M6
    builder branch previously had no verifying-sig coverage.)
  * **REMAINING — handler exchange + send-arms + LDK two-node functional test:**
    BLOCKED on a signer-variant change. All `ChannelContext` constructors hardwire
    `ChannelSignerType::Ecdsa(_)`; nothing ever builds `::Taproot`, and
    `derive_channel_signer` returns only an `EcdsaSigner`. The 11 `_ => todo!()`
    send-arms match the never-constructed `Taproot` variant (dead), and
    `InMemorySigner`'s `TaprootChannelSigner` bodies in `sign/mod.rs` are still
    `todo!()` (only `quid_ln::ValidatingChannelSigner` has real bodies). To reach
    a green two-node ChannelManager functional test: (a) derive/store the `Taproot`
    signer variant for `supports_simple_taproot()` channels (a `SignerProvider`-level
    change), (b) implement `InMemorySigner`'s taproot bodies + a `provide_taproot_context`
    seam for the test harness, then (c) wire the handler nonce exchange
    (generate holder `next_local_nonce`, store the peer's, call
    `provide_taproot_context`, fill the send-arms with key-path partials). HTLC
    arms stay `todo!("M6-HTLC")`.
- **M7** final cleanup: **zero `todo!()`** anywhere (the cfg-flag removal already happened in M2); full default build + all suites green.
- **M8** e2e: `quid-hop/tests/e2e.rs` (regtest) + `quid-bridge/tests/driver_e2e.rs` (anvil+bitcoind) green.
- *(later)* taproot HTLCs for swap-in/out.

## 8. Efficiency (spec-grounded)
- Prefer coop close (single 64-byte key-path Schnorr; smallest, private).
- Deterministic shachain nonces ⇒ no persistent nonce DB (re-derivable); JIT signing nonces; only current verification nonce in memory.
- RBF coop close for cheap fee-bumps (fresh closer nonce per round; no session re-derive).
- Cache `KeyAggCache` per channel.
- No-HTLC minimal channel first.

## 9. M9 — "production-capable taproot channel" (the real remaining work)
> **Why this section exists.** M0–M8 built + live-verified the *happy interactive path*: open → commitment → coop-close with both parties online. A spec audit (2026-06-21) + a live swap-e2e run proved that QU!D's design needs four more things the earlier milestones mis-scoped as "optional / later / separate" — three are load-bearing, and the green two-node test MASKED all of them (it never goes offline, never resizes, never reconnects, never sends an HTLC). **Meta-rule for M9: every sub-milestone's test MUST exercise the non-happy path it covers (offline broadcast, in-flight HTLC, resize, reconnect) — a passing interactive test proves nothing about these.**
>
> Ranked by severity for QU!D. Implement order: M9a → M9b → M9c → M9d.

### M9a — Force-close: store the aggregated key-path funding sig 🔴 (safety / non-custodial backstop)
**The bug (silent — not even a `todo!()`):** `channel.rs:~3211` builds `HolderCommitmentTransaction::new(..., taproot_unused_ecdsa_sig(), ...)` — a DUMMY funding sig — and the real aggregated key-path Schnorr sig computed at `verify_taproot_keyspend_partials` (3225/5094/10834) is used only to validate the peer's partial, then DISCARDED. So a holder can never broadcast its own commitment.
**Why it can't be deferred & why it's special:** MuSig2 funding signing is INTERACTIVE (2 rounds, both online). Force-close happens when the counterparty is OFFLINE. Therefore the holder-commitment funding signature MUST be produced+persisted *during* `commitment_signed` (when both partials + the deterministic nonces are in hand) so it can be broadcast unilaterally later. This is the BTC non-custodial backstop (§5, Option C); without it the penalty/CSV/anchor safety analysis and the EVM `recordClose` non-zero-locktime branch (`BTCChannels.sol:64`) are dead. Live-confirmed gating: a force-close today has no valid funding witness.
**Design (localized):**
- At `commitment_signed` *receive* for the holder commitment (the 3225/5094 sites): the counterparty's `partial_signature_with_nonce` is THEIR partial over OUR new holder commitment. We hold our own partial (secnonce deterministic at this height) + their pubnonce. We already aggregate to verify — **store the resulting `schnorr::Signature` instead of discarding it.**
- `HolderCommitmentTransaction` carries a taproot key-path funding sig (`schnorr::Signature`) replacing the ECDSA `counterparty_sig` + complete-at-broadcast model. The broadcast/witness builder emits the **key-path witness = one 64-byte SIGHASH_DEFAULT sig** (not a 2-of-2 script witness).
- **`ChannelMonitor` persistence:** the stored key-path sig MUST be serialized — force-close can fire after a reboot. (Restart-durable; mirrors the LDK->onchain cid-map follow-up already noted in memory.)
- **Revoke-and-ack interaction (the subtle part, get it right):** each new `commitment_signed` we receive gives us the sig over our NEW holder commitment; it SUPERSEDES the prior holder commitment+sig. We `revoke_and_ack` the *counterparty's* old state, not ours; our stored holder sig is simply replaced per height. Store exactly the latest holder commitment + its aggregated key-path sig; never broadcast a superseded one. (No new MuSig2 round at revoke time — the sig was formed at commitment_signed.)
**Test (MUST go offline):** open → exchange ≥1 commitment → drop the counterparty → holder broadcasts its latest commitment → assert the funding input witness is one 64-byte key-path sig verifying vs `Q` AND bitcoind accepts the tx. Then EVM `recordClose` with non-zero locktime → STATUS_CLOSED.

### M9b — Taproot HTLCs 🔴 (core function: swaps)
**Live-confirmed gap:** P2TR channel opens, then `commitment_signed` fails `"Got wrong number of HTLC signatures (0)"` — the taproot tx-builder emits no HTLC outputs/sigs. The custody channel is the hop's ONLY channel and carries EVERY swap HTLC (swap-in = inbound claim, swap-out = outbound BOLT11), so this is the channel's whole purpose.
**Design (per §3):**
- **Tx-builder:** insert HTLC outputs for taproot (internal key = `revocation_pubkey`; offered + received tapscript trees with timeout/success leaves; 2nd-level HTLC txs reuse the `to_local` tapscript structure). Currently only `to_local`/`to_remote`/anchors are built for taproot.
- **HTLC sigs = plain BIP340 Schnorr, NOT MuSig2** (only the funding spend is MuSig2). Add the taproot HTLC-signing methods to `TaprootChannelSigner` (holder + counterparty HTLC txs) producing `schnorr::Signature`; `commitment_signed` carries the HTLC-sig vec.
- **Resolution:** timeout (CLTV) and success (preimage) tapleaf spends; the 483-HTLC/side cap + anti-jamming config already in `build_user_config` apply.
- `ValidatingChannelSigner` policy extends to HTLC sigs (`PolicyState` is scheme-agnostic).
**Test:** the live swap-in e2e (`e2e_ffi` default / `testCrossChain_FullE2E`) goes GREEN end-to-end (open → inbound HTLC → claim with preimage → `settleSwapIn`), plus swap-out (outbound HTLC → BOLT11 pay → `settleSwapOut`).

### M9c — Splice signing 🟠 (capacity / withdrawal / rebalance)
**Gap (`todo!()`):** `channel.rs:9317` (`sign_splice_shared_input`), `12399` + `12504` (funding-pubkey rotation) are `ChannelSignerType::Taproot(_) => todo!()`. Splice is QU!D's ONLY capacity mechanism (one channel/LP; grow/shrink/rebalance/withdraw all via splice — `recordClose` already branches on it).
**Design:**
- `sign_splice_shared_input` for taproot: the splice tx spends the OLD funding output (2-of-2 MuSig2 key-path). Both parties are online during splice negotiation → interactive MuSig2 over the splice input, identical machinery to coop-close. Produce the aggregate key-path sig.
- Funding-pubkey rotation (BOLT #995): the funding key rotates using `prev_funding_txid` as a tweak. For MuSig2, derive each party's rotated individual funding key, re-`KeyAgg`+unspendable-tweak → `Q'`; the new funding output is `0x5120||Q'`. The EVM splice adapter must accept `Q'` (same byte-match path as open).
**Test:** taproot splice-in (grow) + splice-out (shrink) e2e on real bitcoind+anvil, reconciled through `recordClose`/the resize entrypoint.

### M9d — Reconnect nonce resync 🟡 (long-lived channel liveness)
**Gap:** the `ChannelReestablish` message struct has NO nonce field; `get_channel_reestablish` populates none. Spec §1/§4: nonces are forgotten on disconnect and re-sent fresh on reconnect via `channel_reestablish` `next_local_nonces`. Always-on hop/LP daemons reconnect; without resync the next `commitment_signed` has no counterparty pubnonce.
**Design:** add `next_local_nonce` (single channel) / `next_local_nonces` (map by funding txid, for spliced channels) to `ChannelReestablish` (TLV) + serialization; `get_channel_reestablish` populates our fresh holder verification nonce (deterministic at the next commitment height); the receive handler stores the peer's (mirrors the `channel_ready` path). (Deterministic nonces let each side re-derive its own; the transport to re-exchange pubnonces is what's missing.)
**Test:** open → disconnect mid-channel → reconnect via `channel_reestablish` → a subsequent `commitment_signed` round succeeds.

### M9e — Taproot ON-CHAIN RESOLUTION 🔴 (safety: penalty / HTLC claims / sweep) — found 2026-06-21
**The gap (silent P2WSH assumption, same class as M9a — NOT a `todo!()`):** `chain/package.rs` builds EVERY on-chain claim witness as ECDSA + `witnessScript` (e.g. `:908–943`: `RevokedOutput` → `get_revokeable_redeemscript` + `sign_justice_revoked_output`; `RevokedHTLCOutput` → `get_htlc_redeemscript` + `sign_justice_revoked_htlc`; serialize_der + `EcdsaSighashType::All` + `witness_script` push), with NO taproot branch (only the funding spend at `:671–676` is taproot). M9a broadcasts the commitment; NOTHING spends its OUTPUTS for taproot.
**Why it can't be deferred:** once a taproot commitment is on-chain, a P2WSH witness is invalid for its tapscript outputs, so for a taproot channel today:
- 🔴 a counterparty who broadcasts a REVOKED state can't be punished → theft;
- 🔴 in-flight swap HTLCs can't be claimed on-chain (preimage/timeout) → swap atomicity breaks in the exact failure case it exists for;
- 🔴 the broadcaster can't sweep its own `to_local` balance after the CSV delay.
**Design:** make every `PackageSolvingData` witness builder taproot-aware — emit `[schnorr_sig, tapleaf_script, control_block]` (BIP341 script-path), using the M4 NUMS-tapscript builders for `to_local` (to_delay + revoke leaves), HTLC (offered/received timeout/success leaves), and the anchor leaf. Add the taproot signer methods producing BIP340 Schnorr: `sign_justice_revoked_output`, `sign_justice_revoked_htlc`, counterparty/holder HTLC sweep sigs, delayed-output sweep, anchor CPFP. Covers: `RevokedOutput`, `RevokedHTLCOutput`, `CounterpartyOffered/ReceivedHTLCOutput`, `HolderHTLCOutput`, the delayed `to_local` sweep, and anchors.
**Test (MUST exercise the on-chain branch):** (a) JUSTICE — counterparty broadcasts a revoked taproot commitment → we sweep all outputs via the revoke tapleaf; bitcoind accepts. (b) HTLC ON-CHAIN — force-close with an in-flight HTLC → claim it via preimage (success leaf) AND via timeout (CLTV); bitcoind accepts. (c) DELAYED SWEEP — broadcaster claims `to_local` after CSV via the to_delay tapleaf.
**M9e-2 — REOPENED (found 2026-06-22 during M9d): the `to_remote` `StaticPaymentOutput` on-chain sweep is still P2WSH-only for taproot.** M9e (done) covered to_local/HTLC/justice/anchor, but NOT the counterparty-broadcast `to_remote` claim: `get_countersigner_payment_script` + `InMemorySigner::sign_counterparty_payment_input` build a P2WSH/P2WPKH witness, and the monitor matches the `to_remote` SPK as P2WSH, while a taproot commitment emits `get_taproot_to_remote_spk` (1-CSV tapleaf, §3). **Why it matters for non-custody:** when the HOP force-closes (broadcasts ITS commitment), the LP's balance is the `to_remote` output on the hop's tx — a P2WSH-only sweep witness ⇒ the LP CANNOT claim its own balance ⇒ recovery hole (this is the LP-side mirror of M9a; RECOVERY-REVIEW gate #5 / LP non-custody depends on it). FIX: taproot-aware `to_remote` sweep — `get_taproot_to_remote_spk` script-path witness (`[schnorr_sig, 1-CSV tapleaf, control_block]`) via a taproot `sign_counterparty_payment_input`/SpendableOutput path; needs `all_prevouts` plumbed through the SpendableOutput-spend API (BIP341 taproot sighash commits to all prevouts). TEST: hop broadcasts its commitment → LP sweeps its `to_remote` after the 1-block CSV; bitcoind accepts. **[DONE fc88e04.]**

**M9e-3 — 🔴 SEVERE, REOPENED (found 2026-06-22 by the §10 audit cluster A): the ChannelMonitor's on-chain output DETECTION is still P2WSH-only for taproot.** M9e/M9e-2 fixed the SIGNERS + witness BUILDERS + `to_remote` detection, but MISSED the DETECTION sites for `to_local`-justice, the holder's own `to_local` sweep, and holder-HTLC claims — so the monitor never builds the claim package for those classes and the (working) witness builder is never reached. M9e's tests proved witness *production* in isolation, never the end-to-end monitor-detection→package→broadcast path. Sites (all `chain/channelmonitor.rs`, same fix shape = add `supports_simple_taproot()` branches mirroring the M9e-2 `to_remote` detection; the signer `_taproot` methods + package.rs finalize arms are ALREADY complete = detection-only plumbing):
- 🔴 **Justice on revoked `to_local`** (`:4750` `check_spend_counterparty_transaction` matches `revokeable_redeemscript.to_p2wsh()`; taproot `to_local` = `get_taproot_to_local_spk` P2TR ⇒ never matches ⇒ no `RevokedOutput` package). A counterparty broadcasts a revoked state and STEALS the `to_local` (PROVEN: 0 justice txn broadcast).
- 🔴 **Holder's own `to_local` sweep** (`:5102` `get_broadcasted_holder_claims` stores `redeem_script.to_p2wsh()`, matched at `:6383` against the P2TR `to_local` ⇒ no `DelayedPaymentOutput` SpendableOutput). Hop CAN'T recover its own balance after force-close. (Unlike M9e-2's `to_remote`, there is NO deser self-heal here — fix must add one.)
- 🔴 **Holder in-flight HTLC claims** (`:5060` `get_broadcasted_holder_htlc_descriptors` zips the EMPTY ECDSA `counterparty_htlc_sigs` instead of `taproot_counterparty_htlc_sigs`; debug-panic or release-zero descriptors). Hop CAN'T claim a swap HTLC on-chain ⇒ swap↔force-close loss (seller's BTC times out after `settleSwapIn` already delivered USD).
- 🟠 **Revoked 2nd-level HTLC-tx justice** (`:5033` `check_spend_counterparty_htlc` gates on P2WSH `witness.len()==5`).
- Also relax the TEST-ONLY assertion at `:6066` (`spends_watched_output` asserts every watched-P2TR spend is a len-1 key-path spend) to allow taproot SCRIPT-path sweeps. TEST (MUST drive the real monitor block-confirmation path, not just the signer): counterparty broadcasts a revoked taproot commitment → monitor broadcasts a justice tx sweeping `to_local`+HTLC; hop force-closes → gets `SpendableOutputs` for its `to_local` + builds its holder-HTLC claims. **[DONE b4c9f0d/34d681e.]**

**M9e-4 — 🔴 QU!D-critical, found 2026-06-22 by §10 audit cluster D (#4): the ANCHOR zero-fee holder-HTLC on-chain claim signs ECDSA/P2WSH, not taproot.** M9e/M9e-3 built the holder-HTLC claim via the package.rs MALLEABLE (self-funded) path — but for `anchors_zero_fee_htlc_tx` channels the holder-HTLC claim is ZERO-FEE, so it routes through the EXTERNAL-funding CPFP **bump handler** (`events/bump_transaction/mod.rs:1197`), which signs the HTLC input via the ECDSA `sign_holder_htlc_transaction` (`sign/mod.rs:1968`, no taproot branch) + `chan_utils build_htlc_input_witness` (P2WSH, no taproot branch) → INVALID witness over the taproot HTLC tapscript output → validating signer panics `IncorrectSignature`. **Simple-taproot channels are ALWAYS anchor channels (M9g), so this is the force-close on-chain-claim path for EVERY in-flight swap HTLC** — a swap that's mid-flight when the channel force-closes can't be claimed ⇒ BTC loss (the M9e-2 `to_remote`/M9a-class hole, but on the HTLC claim). FIX (3 coordinated sites on the production claim path): route the bump handler's HTLC signing through `sign_holder_htlc_transaction_taproot` + `build_taproot_htlc_input_witness` (mirror `package.rs:563-588`), surfacing the counterparty Schnorr sig + tapleaf/spend_info into the bump handler (today only the ECDSA `HTLCDescriptor` reaches it — extend it with the taproot data). TEST: anchor simple-taproot channel, force-close with an in-flight HTLC → the bump/claim produces a valid taproot script-path witness that verifies + bitcoind accepts. (Cluster D added a passing regression-guard asserting the broken path is reached; the real fix + a positive test are M9e-4.)

### M9f-0 — 🔴🔴 CONFIRMED CRITICAL (2026-06-21): coop-close nonce reuse leaks the funding private key
**Confirmed, not "to verify."** `sign/taproot_signer.rs::local_pubnonce`/`our_key_path_partial` derive the secret nonce via `derive_secnonce_seed(shachain_root, height)` with EMPTY `SecNonceSpices` — the message/sighash is NOT folded into the nonce (it enters only the 2nd round `finalize(seckey, message)`). The closing path pins `height = CLOSING_NONCE_HEIGHT = u64::MAX` (sign/mod.rs:1970) at all sites (channel.rs:6445/10915/10950). ⇒ EVERY closing partial sig reuses the SAME nonce `k`. `closing_signed` is a multi-round FEE negotiation: each round signs a different close tx (different fee ⇒ different message `m`), and our partials are SENT to the counterparty. Two partials with the same `k` over `m1≠m2` ⇒ `x = (s1−s2)/(H(R,Q,m1)−H(R,Q,m2))` = our funding privkey ⇒ counterparty controls the 2-of-2 ⇒ DRAINS the channel. Commitment-path nonces are fine (per-state height varies); the bug is the fixed CLOSING_NONCE_HEIGHT. Violates the spec's OWN §5/§8 "fresh closer nonce per round". M8/M9b e2e missed it (single-round closes ⇒ one `m`). **FIX (mandatory, top of M9 queue):** the closing nonce must be FRESH per round. NOTE you CANNOT message-bind it (MuSig2 exchanges the nonce in round 1 BEFORE the message/fee is known in round 2; the nonce is advertised via `shutdown_nonce`/`next_closee_nonce` before the close tx is final). Correct fix = a distinct, re-derivable nonce per closing round via a monotonic per-round index used as the derivation `height` (e.g. `CLOSING_NONCE_BASE − round`), advertised each round through `shutdown_nonce` (round 0) + `next_closee_nonce` (subsequent rounds) per §4/§5, so no two distinct close txs ever share a nonce. Crash-safe because the round index is deterministic/re-derivable. Audit ALL fixed-height nonce uses for the same flaw (any path that can sign >1 distinct tx at a fixed height).

### M9f — remaining edge cases to VERIFY (not yet confirmed; resolve during/before the final audit)
- ✅ **EVM `recordClose` with HTLC outputs present — CHECKED 2026-08-17, AND THE PREMISE DOES NOT
  APPLY.** The concern was that "the delivered/payout split assumes `funded − lpPayout`" so HTLC
  value could be mis-attributed. It cannot, because **the force branch never reads a per-output
  value at all**: `recordClose` sets `lpPayoutSats = channels[channelId].amountSats` on
  `!coop`, i.e. the full funded total, so `delivered = funded − lpPayout = 0` identically
  (`BTCChannels.sol:1712`, and the header at `:101-104` states this as the design — "a solvency
  reconciliation of a unilateral close"). Only the COOP branch reads outputs
  (`_lpFinalBalance`), and a cooperative close cannot carry HTLC outputs — BOLT `shutdown` blocks
  new HTLCs and the close waits for the in-flight ones to resolve. `_finalizeClose` then clamps the
  payout to `lpEntitled = totalSats − poolOwnedSats[channelId]` and emits `PoolSatsLeftWithLp` on
  any excess rather than absorbing it silently.
  ✅ **AND THE NARROWER SUCCESSOR IS ALSO CLOSED — CHECKED, not booked.** The worry was that the
  clamp reads `poolOwnedSats` (BOOKED inventory) while an in-flight LN swap-in might be unbooked.
  **It cannot be, because the LN rail cannot increase channel sats at all.**
  `settleSwapInBuffered` (`:1343`) does not add sats — it **draws down**
  `provenSatsAvailable[hop]`, inventory that `parkProvenSats` (`:1317-1320`) credited to BOTH
  `poolOwnedSats[channelId]` and `provenSatsAvailable[hop]` **in the same transaction as the
  SPV-proven splice that brought the sats in**. The entrypoint that could once conjure sats without
  a splice was the phantom `settleSwapIn`, and it is deleted. So there is no state in which LN-side
  value sits in the channel unbooked; the sequence is always *splice in (booked) → later sell out of
  that inventory*.
  🔑 **The two ledgers differ in MEANING, not in accuracy, and that is the thing to not misread:**
  a swap-in decrements `provenSatsAvailable` (those sats can no longer be sold again) and correctly
  leaves `poolOwnedSats` alone (the sats never left the channel — the pool paid USD and kept them).
  `_releasePoolSats` is what decrements the latter, when pool sats actually leave. ⇒ The close-side
  clamp `lpEntitled = totalSats − poolOwnedSats` is complete.
- **On-chain-preimage → bridge settlement:** if a swap HTLC resolves on-chain (success spend reveals the preimage) instead of off-chain, the bridge/EVM must detect + settle without double-counting (interacts with `settleSwapIn/Out` + `swapInUsed/swapOutUsed`).
- **Restart durability:** the signer's shachain root + per-height nonce derivation + the LDK→on-chain cid map must survive a node reboot (a force-close can fire post-reboot).
- **Weight/dust constants P2WSH-derived (LOW sev, exactness):** chan_utils HTLC tx weights (703/663) + `COMMITMENT_TX_WEIGHT_PER_HTLC=172` + base weight key only on `anchors_zero_fee_htlc_tx`, not taproot; a taproot key-path funding witness (64B) is lighter than P2WSH 2-of-2 (~220B). NOT a safety vuln — both parties use identical constants (no trim/commitment mismatch), QU!D runs anchors-zero-fee-htlc (fees≈0, CPFP-bumped), and the error is overestimate (overpay-safe). Tighten to taproot-exact weights for correctness; verify no dust-boundary trim disagreement.

### M9g — Taproot ANCHORS 🟠 (force-close fee-safety; 🔴 with in-flight HTLCs) — found 2026-06-21
**The gap (silent type-downgrade):** `get_initial_channel_type` (channel.rs:14930–14945) returns EARLY for the taproot branch with `only_static_remote_key + option_simple_taproot` (+optional scid_privacy) and NEVER sets anchors — the `set_anchors_zero_fee_htlc_tx_required()` logic (:14964) is in the non-taproot fallthrough it skips. So even though `build_user_config` sets `negotiate_anchors_zero_fee_htlc_tx = true` (node.rs:721) and a test asserts it (node.rs:1182), QU!D's taproot channels carry NO anchor outputs (the commitment builder at chan_utils.rs:~2745 correctly emits none, matching the negotiated type). M6c chose this to avoid the 2×330-sat fee-reservation complexity.
**Why it matters:** without anchor outputs a force-closed taproot commitment can't be CPFP-fee-bumped, and the pre-signed commitment can't be RBF'd → a force-close at a stale low feerate is STUCK at the pre-signed rate. With in-flight swap HTLCs that risks missing the HTLC CLTV deadline → loss. QU!D's documented force-close safety (anchors+CPFP+CSV, see the LN-attack-surface analysis) is ABSENT for taproot. Also: config/test claim anchors while the channel has none (false confidence), and it deviates from BOLT #995 (simple-taproot channels ARE anchor channels).
**Design:** make the taproot negotiated type include `option_anchors_zero_fee_htlc_tx` (taproot branch of `get_initial_channel_type` + acceptor type-check); emit the two taproot anchor outputs (`get_taproot_anchor_spk`, already wired) on the simple-taproot commitment; reserve their value in the fee/balance model (`tx_builder::subtract_addl_outputs` / `commit_tx_fee_sat`, currently keyed off `supports_anchors_zero_fee_htlc_tx()`); add the package.rs anchor CPFP spend arm (M9e wired `taproot_anchor_spend_info`). Resolve the config↔type contradiction so the negotiated type matches what's advertised.
**Test:** open a taproot channel → assert the negotiated type includes anchors AND the commitment has 2 anchor outputs → force-close → CPFP-bump via a taproot anchor spend (bitcoind accepts the package).

### M9-final (cleanup — runs AFTER the correctness milestones M9c/M9d/M9f, BEFORE the §10 audit)
1. **Zero `todo!()`** for taproot anywhere except the genuine non-gap **announcement** (`channel.rs:12054/12086`) — QU!D's hop is a private unannounced leaf (force-closes inbound opens), so channel announcement is intentionally never implemented; leave a comment, not a `todo!()` that implies unfinished work.
2. **Dead-P2WSH removal (QU!D-side only — "Bucket 2"):** QU!D is taproot-only pre-mainnet (§6), and the EVM already dropped P2WSH, so the QU!D-specific 2-of-2/P2WSH glue in `quid-hop`/`quid-bridge` is dead for production — candidates: `funding_pubkeys_from_witness` (2-of-2 witnessScript parse), any P2WSH funding-script builders, the `e2e_ffi` P2WSH fixture mode. PROCEDURE: first a read-only dead-code audit (no callers / only reachable from non-taproot paths) to quantify exactly what's removable; remove only the truly-unreferenced, and do NOT yank the `e2e_ffi` harness out from under a still-used test. NOT client-side-needed (this is LN node-internal channel machinery, never SPA-facing). **KEEP "Bucket 1" — the vendored LDK fork's generic ECDSA/P2WSH machinery** (`ChannelSignerType::Ecdsa`, `get_*_redeemscript`, the P2WSH commitment/witness path): QU!D never negotiates non-taproot channels so it's dead at runtime, but it's upstream library generality, intertwined with everything, and exercised by the in-tree ECDSA tests — removing it = massive risky fork divergence for zero benefit. (Decided 2026-06-21: hold the whole pass for final, then proceed.)

## 10. FINAL AUDIT (run when the M9 build agenda is code-complete — rust + solidity)
> We have found gaps in sequence (HTLCs → force-close → splice → reconnect → on-chain resolution). The spec modeled the cooperative happy path, so adversarial/offline/on-chain branches are where gaps hide. Do NOT trust the milestone list as proof of completeness — walk the lifecycle adversarially. The audit is itself adversarial + multi-perspective (separate readers per area; verify each "done" against a test that exercises the NON-happy branch).
**Lifecycle coverage matrix — every cell needs a taproot test that exercises the real branch:**
1. OPEN: funding `0x5120||Q`; nonce exchange; channel_type negotiation; abort/timeout mid-open.
2. NORMAL OPS: add/settle/fail HTLC; dust HTLC (no output, exposure cap); max-HTLC (483/side) cap; fee-update; concurrent updates.
3. COOP CLOSE: single round; RBF rounds (FRESH nonce each — security); both shutdown-script variants.
4. FORCE CLOSE (us): broadcast latest holder commitment (stored key-path sig); sweep to_local after CSV; claim our in-flight HTLCs (2nd-level).
5. FORCE CLOSE (them, current): claim our to_remote (1-CSV); claim HTLCs owed us.
6. REVOKED broadcast (them): justice/penalty sweep of ALL outputs via revoke tapleaves.
7. SPLICE: grow + shrink; funding-key rotation → Q'; HTLCs in flight across splice; nonce map by funding-txid.
8. RECONNECT: mid-channel; mid-signing (after commitment_signed, before RAA); nonce resync; splice + reconnect.
9. RESTART: re-derive nonces; persisted holder/justice sigs; cid map; force-close post-reboot.
10. EVM RECONCILIATION: recordClose coop (locktime 0, LP payout) + force (nonzero, retire) + with-HTLC-value; Q & Q'(splice) byte-match; on-chain-preimage → settleSwapIn/Out without double-count; foreign-output ban.
11. CRYPTO/SECURITY: no nonce reuse anywhere (per-height + per-RBF-round); partial-sig verify-before-aggregate at every site; KeySort identical across Rust signer + counterparty + EVM; single secp256k1 0.29.
12. PROCESS: zero stray `todo!()` (except announcement); off-limits other-thread files untouched; forge build under project config (no via_ir); full suites green (lightning, quid-ln, quid-hop, quid-bridge, forge) + live regtest e2e.
**Method:** fan out independent readers per area (1–12), each producing findings; adversarially verify each finding (is it real? does a test prove it?); a completeness critic asks "what modality/branch is unexercised?". Anything found = a new M9x item, built + tested, before sign-off.

## 11. M11 — SGX enclave + key provisioning (BORN-IN-ENCLAVE, not MSKR-delivery) — THE FINAL MILESTONE (do LAST)
> Key model DECIDED 2026-06-22: keys are **born in the enclave** (Model A), NOT delivered to it (MSKR/Model-B is rejected for the custody key — born-in-enclave deletes the whole key-delivery attack surface). The recovery/availability story is the layered model below (cold LP-seed floor + hot attested replication), NOT a key handoff. See the KEY PROVISIONING bullet.
> **Sequencing (user direction 2026-06-21): M11 runs LAST — finish ALL protocol work first (M9c-finish, M9d, M9f, M9-final) AND the §10 audit, THEN do M11.** Prod/staging MUST run inside the SGX enclave (`quid-common/src/env.rs:82` — "Staging and prod can only run in SGX!"); the node (incl. the `lightning` crate, now carrying conduition `musig2`) compiles to `x86_64-fortanix-unknown-sgx` via Fortanix EDP (`quid-enclave`, `sgx-isa`, attestation `Measurement`). The taproot signer is `ValidatingChannelSigner` — the in-enclave least-privilege POLICY layer (memory e73d04a / [[project-quid-sgx-signer-scoping]]). **The enclave target now COMPILES + LINKS (2026-07-11, SPV `0b1c19c`): `cargo +nightly build --target x86_64-fortanix-unknown-sgx -p quid-bridge`** (the quid-bridge daemons ARE the enclave). The residual is on-hardware EXECUTION, not the build.
- **M11 (deployment-blocking): SGX-target BUILD DONE (2026-07-11), in-enclave EXECUTION still pending real hardware.** The taproot deps COMPILE + LINK for `x86_64-fortanix-unknown-sgx` — conduition `musig2 0.1.2` (`default-features=false, features=["secp256k1"]`, `std_rng` NOT enabled) + `secp256k1 0.29` compile clean no_std+alloc (never the blocker; the drift was mio/tokio/hyper-util). Still to prove on genuine SGX: in-enclave EXECUTION. The deterministic shachain nonce (RNG-FREE) is SGX-friendly *by design* — RNG inside an enclave is constrained; this is a second reason (beyond crash-safety) the spec mandates deterministic nonces over randomized. Add an SGX-target check to the build matrix; host-target green does NOT prove enclave build.
- **KEY PROVISIONING — CONFIRMED MODEL (2026-06-22): born-in-enclave + cold seed floor + hot replication (do NOT deliver a key TO the enclave).** Three layers, deliberately combined so confidentiality is maxed AND the §2.1 custody-theorem invariant holds:
  1. **Born-in-enclave genesis (Model A, HOP-CUSTODY-SGX §3):** the enclave generates its `RootSeed` *inside* SGX; the funding key + the shachain root derive from it. NO plaintext key/seed ever exists outside the enclave at genesis — this DELETES the entire "secure key delivery" attack surface (browser/clipboard/host-OS/hypervisor). What crosses the boundary is ONLY the **public** funding key, **bound into the attestation quote** (pubkey == `REPORTDATA` / RA-TLS) so a malicious host can't substitute its own. "Fund the channel" = send BTC to the on-chain **P2TR 2-of-2 funding output `0x5120‖Q`**, `Q = KeyAgg(KeySort(LP_funding_pubkey, hop_funding_pubkey)) + taproot tweak` — both halves enclave-born (LP key in the per-LP enclave, hop key in the hop enclave), each exports its attested pubkey, KeyAgg → the address. (NOT a BOLT11 invoice — those are the swap payments that later ride the channel.)
  2. **Cold catastrophe floor — ONE-TIME, attested, LP-initiated backup of the LP's OWN seed** (the §2.1 invariant: "non-custodial ⟺ the user independently holds a recovery secret"). This is the OPPOSITE direction from delivery (the LP optionally *extracts* their own recovery seed once, over the attested/wallet-verified SPA channel, shown once, NEVER persisted unsealed) — a tiny surface vs handing a key in. Reuse lexe `sealed_seed.rs` (sealed `RootSeed` + restore-on-boot).
  3. **Hot availability — attested enclave→enclave replication** (RA-TLS, same MRENCLAVE) to ≥1 standby so a single hardware loss doesn't strand funds; also answers "the fleet needs the same key."
  **GOTCHA (must hold in scope): the channel close-paths do NOT rescue a LOST key.** Both the cooperative close AND the Option-C force-close are spends of the 2-of-2 → both require our funding key; if the key is purely in-enclave and the hardware dies with no backup/replica, neither close can be signed → funds LOCKED in the 2-of-2 forever (a 2-of-2 can't be moved by one party). So close-paths cover COUNTERPARTY-unavailability (hop vanishes → force-close with OUR key), NOT OUR-key-loss. ⇒ layers 2+3 are MANDATORY for a custody key; **NEVER ship a single-enclave-no-backup custody key.** This applies to BOTH halves — the HOP's enclave key has the identical durability requirement (its loss locks the hop's side of every channel).
  **Shachain-root criticality (AMPLIFIED by taproot):** the shachain root now seeds BOTH revocation secrets AND the deterministic MuSig2 nonces (`nonce_seed = HMAC(shachain_root, height)`); a leak lets an attacker derive the nonces → with the public partial sigs recover the funding key (the M9f-0 algebra). It must NEVER leave the enclave (except the layer-2 LP-initiated attested backup of the LP's own seed), never be logged/persisted unsealed.
- **Enclave boundary for the `TaprootSignerContext` seam:** the seam feeds the in-enclave signer the counterparty funding pubkey + amount + per-round nonce (data the `TaprootChannelSigner` trait surface lacks). Verify it crosses host→enclave WITHOUT exporting any enclave secret, and that the validating-signer least-privilege policy still gates what the enclave will sign for every taproot op (open/commitment/HTLC/splice/close/justice). Same scrutiny for the new M9c splice + M9e on-chain-resolution signer methods.
- **Reuse lexe MAXIMALLY (build strategy for M11):** pull the enclave/attestation/sealing parts we need from `/projects/lexe` (`lexe-enclave`, `lexe-tls-attest-server`, sealing/quote machinery) **as-is** where they fit, and modify only the parts our design needs — all inside the SPV workspace. `/projects/lexe` is the **read-only copy-from source — never edited**; every `lexe-*` crate/dir/identifier becomes `quid-*` on copy-in (per the rename rule). The deltas WE add for taproot: confirm conduition `musig2`/`secp256k1` build for the enclave target, seal the shachain root (now doubly-critical), and wire the `TaprootSignerContext` seam inside the enclave boundary. Don't re-implement what lexe already provides (attested-mTLS, DCAP quote verification, MRENCLAVE sealing) — integrate around it.
- Sequencing: **M11 is the LAST milestone** — everything else (M9c-finish, M9d, M9f verifies, M9-final cleanup, §10 audit) ships first; M11 is the deployment gate (audit-matrix area 13) run at the very end.
