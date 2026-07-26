# BTC-LP custody — the SGX signing daemon (how a sleeping LP safely co-signs swap-outs)

> ⚠️ **PARTIALLY SUPERSEDED (2026-06-24) — for LAUNCH STEPS use [`../../deploy/PRODUCTION-LAUNCH.md`](../../deploy/PRODUCTION-LAUNCH.md).** The custody key is **born-in-enclave (Model A)**; Model-B "key over the wire" is NOT used for the custody key (it remains only the optional guarded import/migration path). The §4/§7 "swap-OUT watcher" + `decode_swap_out_requested` / `SwapOutRequested` references are **historical** — that LN swap-out rail was removed (the on-chain rail settles swap-out proceeds directly). The SGX substrate (§2–§3, §5) and the no-steal/force-close guarantees remain accurate.

> ⚠️ **TAPROOT UPDATE (2026-06-22) — this doc (dated 2026-06-05, oldest) predates the taproot build; key mechanics changed:** (1) funding is no longer a **script 2-of-2** — it's a **MuSig2 key-path aggregate (BIP327)**; "the LP's half of the signature" is now a MuSig2 **partial**, the witness is one 64-byte Schnorr sig, and signing is interactive 2-round MuSig2. (2) "always broadcast the latest commitment / justice sweeps the channel" was BROKEN/P2WSH-only for taproot until **M9a** (force-close sig) + **M9e** (tapscript sweeps). (3) **Key-release/MSKR + the shachain root:** the shachain root now seeds BOTH revocation AND the MuSig2 nonces, so it is **doubly secret-critical** — if it leaks, the funding key is recoverable (M9f-0 algebra); it must be MSKR-released to the attested measurement ONLY and never logged/persisted unsealed. Deterministic (RNG-free) nonces are SGX-friendly by design. (4) The taproot signer's **enclave-target build (`x86_64-fortanix-unknown-sgx`) COMPILES + LINKS as of 2026-07-11 (SPV `0b1c19c`)** — build cmd `cargo +nightly build --target x86_64-fortanix-unknown-sgx -p quid-bridge` (the quid-bridge daemons ARE the enclave). The residual M11 gate is on-hardware EXECUTION, not the build.** See `TAPROOT-CHANNELS-BUILD-SPEC.md` §11.

This is the custody model for the BTC side: how an LP's channel can release BTC to
a swapper **while the LP is asleep**, with a signing key the hosting operator can
**never** extract and a daemon that signs **only** legitimate, non-spoofed releases.
It is the trust model behind the swap-OUT *watcher daemon* (the still-unbuilt
service glue in [`AUDIT-TODO.md`](AUDIT-TODO.md) §10 / the hop-crate `evm_final` +
`decode_swap_out_requested` primitives).

---

## 1. The problem

A swap-OUT (USD→BTC) delivers native BTC to a swapper over Lightning, paid out of
some LP's channel. The channel is **2-of-2** (LP key + hop key) — neither party
alone can move funds. So a swap-out release needs the **LP's signature**, in
real time, whenever a swapper shows up — *including at 3am while the LP sleeps*.

That forces an **always-on signer holding the LP's key**, which creates the
tension:

- It must be **live 24/7** (swappers don't wait for the LP to wake).
- It must sign **only** a release that is *provably* a legitimate swap-out — never
  a spoof, a replay, or an over-large drain.
- The key it signs with must be **impenetrable**: the machine running it is, in
  general, rented/shared infrastructure the LP doesn't physically control. A plain
  always-on server with the key in memory is a honeypot — the host operator (or
  anyone who breaches the box) can lift the key and drain the channel.

"Run your own always-on signer at home" solves the key-custody problem (you trust
yourself) but imposes an uptime/ops burden most LPs won't accept. The SGX model
gives the **low-ops, trust-minimised** alternative.

---

## 2. Can you run a key-signing daemon on untrusted hosting? Yes — that's what SGX is for.

Intel **SGX** (and equivalently AMD SEV-SNP / confidential VMs) runs code in an
**enclave**: a CPU-protected memory region that the OS, the hypervisor, and the
**host operator cannot read or modify** — it's hardware-enforced (the memory is
encrypted by the CPU; even physical RAM access yields ciphertext). So you *can*
upload the daemon to a rented box and run it there: the box executes it but can
never see inside it. Two cryptographic primitives make this trustworthy:

- **Remote attestation.** The enclave emits a *quote* — a report of its code
  measurement (`MRENCLAVE`, a hash of the exact loaded code+data) signed by the
  CPU's attestation key (rooted in Intel / a DCAP PCK cert chain). A remote
  verifier checks the quote and learns: *"a genuine SGX enclave running exactly
  this audited code is running on genuine hardware."* The LP therefore trusts the
  **code** (which is open and audited), **not the operator**.
- **Sealing.** The enclave can encrypt data with a *sealing key* the CPU derives
  from its fused secret + the enclave's `MRENCLAVE`. Sealed blobs can be unsealed
  **only by the same enclave on the same CPU**. The host stores the ciphertext on
  disk so the key survives restarts — but the host can never decrypt it.

---

## 3. The procedure — how the key gets into the enclave without the operator seeing it

There are two provisioning models. The question "do you upload the code and it
pulls the key over the wire on first run?" describes Model B; the simplest and our
default is Model A.

### Model A — generate-inside + seal (the key NEVER crosses the wire)
1. Build the enclave binary **reproducibly**; publish + audit the source so its
   `MRENCLAVE` is a known, expected value.
2. Upload the (public) binary to the untrusted host; the host launches the enclave.
3. **First boot:** the enclave generates the signing keypair *inside itself* using
   the SGX hardware RNG. The **private key never exists outside enclave memory.**
4. The enclave **seals** the private key to disk (bound to `MRENCLAVE` + this CPU).
   The host now holds only ciphertext.
5. The enclave **attests** — emits a quote binding `MRENCLAVE` to its **public**
   key. The LP (or an automated verifier) checks the quote against the expected
   audited `MRENCLAVE` *before* that public key is used as the LP's leg of the
   2-of-2 funding.
6. On every restart the enclave unseals its key (only it can) and resumes signing.

Nothing secret ever leaves the enclave. The operator never sees the key; the LP
trusts the attested code.

### Model B — provision over an attestation-gated channel (the "key over the wire on first run")
Used when the LP wants to **generate/back up the seed themselves** (off the host)
and inject it — for portability or recovery across hosts/enclaves.
1. Build + audit + publish `MRENCLAVE`; deploy to the host.
2. **First boot:** the enclave generates an *ephemeral* keypair and attests,
   producing a quote that includes its ephemeral **public** key.
3. A provisioning service — or the LP's own client — **verifies the quote**
   (genuine enclave **and** the expected `MRENCLAVE`). **Only on success** does it
   encrypt the seed *to that attested ephemeral public key* and send it over the
   wire.
4. The ciphertext can be decrypted **only inside the attested enclave** (the
   ephemeral private key never left it). The host sees only ciphertext in transit;
   a wrong/malicious enclave or a tampered binary attests to a *different*
   `MRENCLAVE`, so the verifier refuses and the seed is never released. The enclave
   then seals the seed for restarts.

So yes — in Model B the seed does travel the network once, **encrypted to a
remotely-attested enclave**, gated on the code measurement matching the audited
build. The wire never carries plaintext, and only the correct code on a genuine
enclave can ever decrypt it.

**What we vendored (lexe model):** each LP's key lives in its **own** per-LP
sealed+attested enclave (isolated from every other LP — not one shared key store).
The LP trusts the published, attested enclave code rather than the operator; the
operator runs the infra but is cryptographically unable to read the key or forge a
signature. (We do **not** modify the vendored lexe enclave code — see the rename
rule; we integrate around it.)

---

## 4. The anti-spoof signing gate (why an autonomous signer is still safe)

An always-on signer that signs *anything* is useless — it would sign a thief's
drain. The enclave daemon signs **only** a release it can **prove** is a legitimate
swap-out, and it enforces those checks *inside* the enclave (the host can't bypass
them):

1. A swap-out exists on the EVM: `BTCChannels.SwapOutRequested(swapper, sats,
   paymentHash)` — the swapper has already committed USD on-curve (`creditSwapOut`,
   which grew backing and recorded the delivery obligation).
2. It is **final**: the request's block is buried ≥ N confirmations
   (`swap::evm_final`) — a reorg can't unwind the swapper's USD *after* the
   irreversible BTC release. (The burn-finality gate.)
3. The release **amount matches** the obligation (`sats`), to the swapper's invoice
   `paymentHash` — no over-release, no redirection.

Only then does the enclave produce the LP's half of the 2-of-2 signature. A spoofed
request (no on-chain commitment), a replay (`swapOutUsed` deduped on-chain), or an
over-large amount fails these checks and is **never signed** — even with the LP
asleep and the host hostile.

This is exactly the **swap-OUT watcher daemon**: subscribe to `SwapOutRequested`
logs → apply `evm_final` → validate amount/hash → sign the release inside the
enclave. The pure primitives (`decode_swap_out_requested`, `evm_final`) are built +
unit-tested in the hop crate; the enclave-hosted subscription/signing loop is the
remaining service glue.

---

## 5. The no-steal guarantee (defence in depth beyond the enclave)

Even if the enclave assumption were wrong, the LP cannot be robbed:

- **2-of-2:** the hop key alone can't move funds, and the LP-enclave key alone
  can't either. Both must sign — so the enclave's anti-spoof gate AND the hop's
  independent checks must both pass.
- **Unilateral force-close exit:** the LP's enclave can *always* broadcast the
  latest commitment transaction and recover its BTC on Bitcoin, with no
  cooperation from the operator. A malicious or vanished operator cannot steal —
  worst case the LP force-closes and exits to chain.
- **Justice / watchtower:** if the hop ever broadcasts a *revoked* (old) state,
  LDK's justice transaction sweeps the entire channel to the victim — Bitcoin-
  native, optionally watched by a watchtower so it fires even while the LP is
  offline.

"Pooled hop custody" therefore means **liquidity/routing coordination** (the hop
nets flow across many channels), **not** key-pooling. Keys stay per-LP, sealed,
and 2-of-2.

---

## 6. LP options

- **(a) Self-run signer** — the LP runs its own always-on node. Max
  decentralisation, full ops burden (uptime, key hygiene).
- **(b) Per-LP sealed+attested enclave on shared infra** (the vendored lexe model)
  — low ops burden, trust-minimised: the LP trusts the audited code via remote
  attestation, the operator can't touch the key, and the force-close exit + the
  watchtower are the backstops. This is why we vendored lexe.

---

## 7. Status — what lexe already gives us vs. what we add

The SGX substrate in §3–§5 is **almost entirely already implemented by the
vendored lexe code** — we are NOT writing SGX plumbing. Concretely, already built
(do not modify — vendored):

| Capability | Where (vendored) |
|---|---|
| Sealing / unsealing (real `EGETKEY` on SGX, AES-GCM; mock key off-SGX for dev) | `quid-enclave/src/platform.rs` `seal`/`unseal` |
| Sealed `RootSeed` (network-bound) + restore-on-boot | `quid-api-core/src/types/sealed_seed.rs` (`seal_from_root_seed` / `unseal_and_validate`) |
| Attestation quote (`EREPORT`), MRENCLAVE/MRSIGNER/MachineId, `compute_from_sgxs` | `quid-enclave/src/platform.rs`, `enclave.rs` |
| Quote-in-x509 attestation cert (gramine-compatible) | `quid-tls/src/attest_client/cert.rs` (`SgxAttestationExtension`) |
| Attested-TLS verifier + **MRENCLAVE `EnclavePolicy`** (trust the code, not the operator) | `quid-tls/src/attest_client/verifier.rs` (`AttestationCertVerifier`) |
| **Model-B provisioning** (client injects the seed over attested TLS; enclave seals it) | `quid-common/src/api/provision.rs` (`NodeProvisionRequest`) |
| The node `keys_manager` that signs inside the enclave | `quid-ln` / `quid-hop` (`LexeKeysManager`) |

So lexe already does the "key over the wire on first run" flow (Model B) end to
end — attested TLS + MRENCLAVE policy + seal — plus the restart sealing. We trust
the measured code, not the operator, today.

- **What's OURS to build (the application layer):** the QU!D swap-OUT **watcher
  loop + anti-spoof gate** running *inside* that lexe enclave — subscribe to
  `SwapOutRequested` → `evm_final` (N-conf finality) → validate amount/hash →
  produce the LP's 2-of-2 signature. The primitives (`evm_final`,
  `decode_swap_out_requested`, `pay_swap_out`, the on-chain `creditSwapOut` /
  `SwapOutRequested` / `swapOutUsed`) are unit/e2e-tested; the enclave-hosted loop
  that drives them is the remaining service glue. Lexe gives a trust-minimised
  node that holds a sealed key and signs — it does NOT know what a "swap-out" is;
  that decision logic is ours.
