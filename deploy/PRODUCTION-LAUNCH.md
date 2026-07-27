# QU!D production launch runbook — the entire scope (Solidity + Rust + SGX)

The single authoritative checklist to take QU!D from source to mainnet. Covers
the EVM (Solidity) contracts, the off-chain Rust services (hop + LP), and the
**SGX-hardware tail** (everything that can only be done/validated on real SGX
hardware, plus every dev→prod key swap). Sub-docs hold command detail; this is
the master sequence.

- Contract deploy commands + env templates: [`deploy/README.md`](./README.md)
- Bitcoin Core anti-eclipse config: [`quid-ln/ops/README.md`](../quid-ln/ops/README.md)
- SGX custody model: implemented — born-in-enclave seed, `EGETKEY` sealing, DCAP/RA-TLS, Safe-authed
  migration and taproot signing all live in `quid-ln/` (see `quid-enclave/`, `quid-tls-attest-server/`,
  `quid-bridge/src/bin/quid-bridge-daemon.rs`). The old design doc was removed as superseded by this file.
  — NOTE: its swap-OUT-"watcher"/`decode_swap_out_requested` (§4/§7) and "Model B"
  framing are **historical**; the LN swap-out rail was removed and the custody key
  is **born-in-enclave (Model A)** per `TAPROOT-CHANNELS-BUILD-SPEC.md` §11.
- Channel/enclave internals (spec): [`docs/actionable/TAPROOT-CHANNELS-BUILD-SPEC.md`](../docs/actionable/TAPROOT-CHANNELS-BUILD-SPEC.md) §11

## Three deployable units
1. **L1 contracts** (one deployment) — Core/Vault/Basket/Vogue/BTCChannels/SPVGateway + feeds.
2. **Hop enclave** (one instance) — `quid-bridge-daemon`, the Lightning↔EVM custody hub, runs **inside SGX**.
3. **LP enclaves** (many) — `quid-lp-daemon`, each self-hosted by an LP (own SGX, or own laptop+watchtower). LPs are their **own** trust root; they do not provision into foundation infra. See [[LP hosting modes]] (`project-quid-lp-hosting-modes`).

The **provisioner/operator of the hop is the foundation deployer** (same entity that deploys the contracts) — a technical operator using CLIs. No browser is ever in a custody or attestation path.

---

## Phase 0 — Prod key material (OFFLINE / HSM, before anything else)

These replace the committed **dev placeholders**. Generate on an air-gapped/HSM box; the secrets NEVER enter the repo (`.gitignore` already blocks `prod-*`).

- [ ] **SGX enclave signing key (MRSIGNER).** `cargo run -p quid-sgxs-sign --bin gen-signer -- prod-sgxs-signer.der` on the offline box. Paste the printed MRSIGNER into `quid-enclave/src/types.rs` `Measurement::PROD_SIGNER` (currently a PLACEHOLDER `ed84f711…12a8`; dev is `26f048b1…41fd`). Keep `prod-sgxs-signer.der` offline.
- [ ] **Provisioning token (operator secret).** Generate a high-entropy token (`openssl rand -hex 32`); set it as `QUID_PROVISION_TOKEN` on any enclave serving provisioning/migration, and pass the same value to the client (`quid-provision --token …`). Gates the receive side against a network attacker racing a seed in; over the attested TLS, so never in the clear.
- [ ] **2-of-3 operator migration keys (NOT a DAO — operator key custody).** Generate THREE operator keys, each on a separate offline/HSM box ideally held by distinct custodians: `quid-migrate-auth --gen-key prod-operator-N.key` (N=1,2,3). Paste the three printed pubkeys into `quid-hop/src/migration.rs` `OPERATOR_PUBKEYS` (currently dev placeholders). Keep the three secrets OFF the host. A migration needs ≥2 of them to sign — so no single key (or the host) can redirect a seed export, and losing one key doesn't brick upgrades.
- [ ] **EVM deployer key** — hardware wallet / HSM (deploys the contracts). The **hop hot key is NOT an operator secret**: it is DERIVED from the enclave's born-in-enclave sealed seed (no `QUID_HOT_KEY` in prod — the env is refused in-enclave). There is no global on-chain `hopNode`; the hop advertises its enclave-derived address (logged at boot) to the LPs it serves — fleet / family / self — who commit to it in their signed `openChannelDigest`. (An off-SGX individual self-host may set `QUID_HOT_KEY` as a convenience.)

---

## Phase 1 — L1 contracts (Solidity)

- [ ] Build WITHOUT via_ir/optimizer crutches (`forge build --sizes`; libs must fit EIP-170 — see [[headStart bisect method]]).
- [ ] Confirm **feed pins**: 10/11 basket stables have a Chainlink USD feed (BOLD has none — proxy-only RLUSD/USDG/AUSD resolve via data.eth ENS); all pinned at deploy ([[quid-stable-feed-coverage]]). Feeds/forwarder should be constructor-immutable ([[quid-cre-feed-trust-surface]]).
- [ ] Deploy: `cp deploy/deploy.env.example deploy/deploy.env` (edit), then `BROADCAST=1 deploy/deploy-l1.sh deploy/deploy.env` (wraps `evm/src/DeployL1_s.sol`). SPVGateway anchored at a Bitcoin checkpoint; BTCChannels `hopNode = HOP_NODE_OPERATOR`.
- [ ] **Record printed addresses** → they feed the hop/LP env (`QUID_BTC_CHANNELS`, `QUID_BTC_VAULT`, `QUID_SPV_GATEWAY`, `QUID_CHAIN_ID`, `QUID_RPC_URL`).

---

## Phase 2 — Build + sign the SGX enclave (Rust)

> The `quid-bridge` crate carries `[package.metadata.fortanix-sgx]` (heap 2 GiB / stack 8 MiB / threads 6 — **TUNE on hardware**); its two bins ARE the enclave.

- [ ] Add the SGX target on **nightly** — the enclave needs `feature(sgx_platform)`, so the pinned stable 1.90 (`rust-toolchain.toml`) is HOST-only: `rustup toolchain install nightly && rustup +nightly target add x86_64-fortanix-unknown-sgx`.
- [ ] **Build the enclave** — VERIFIED green 2026-07-11 (SPV `0b1c19c`): `cargo +nightly build --target x86_64-fortanix-unknown-sgx -p quid-bridge --release`. The `quid-bridge` daemons ARE the enclave (`[package.metadata.fortanix-sgx]`); `-p quid-bridge` pulls quid-hop/quid-ln/quid-enclave for SGX transitively. Host-green does NOT prove enclave-green — it's a distinct target. NOTE: the old musig2/secp256k1 no_std doubt was DISPROVEN (crypto compiles clean); the real blockers were the **mio/tokio/hyper-util SGX-fork version drift** (now forward-ported on quidmints `main`, pinned via `[patch]`) and secp256k1-sys's **`__memcpy_chk`** link error (fixed by `-U_FORTIFY_SOURCE` in `.cargo/config.toml [env]`, applied automatically). The HOST side (runner, SDK, tests) builds with plain `cargo build` on stable — no `--target`, no nightly.
- [ ] `elf2sgxs` → `.sgxs`, then **sign with the PROD key** (`quid-run-sgx`'s `run-sgx`/`run-sgx-cargo`; `quid-sgxs-sign` does the SIGSTRUCT). Prod enclaves are NOT `--debug`.
- [ ] **Reproducible build → compute MRENCLAVE**; publish it (so LPs/auditors can independently verify the running enclave). Record the canonical measurement.

---

## Phase 3 — Run the hop enclave + seed genesis

- [ ] `cp deploy/hop.env.example deploy/hop.env` (edit with Phase-1 addresses). **`QUID_SEED` is now OPTIONAL** — absent ⇒ **born-in-enclave** (the seed is generated inside SGX and sealed, never seen by the operator). Set it only for a guarded migration/recovery import.
- [ ] Launch the hop enclave via `run-sgx` (host AESM proxy must be reachable — quote generation needs it). `DEPLOY_ENVIRONMENT=prod` **enforces SGX** (`quid-common/src/env.rs` `validate_sgx` — prod can't run off-SGX).
- [ ] First boot: enclave performs **born-in-enclave** genesis (`quid-hop::seed::load_or_provision`), seals the seed (real `EGETKEY`, MRENCLAVE+machine-bound), derives the funding key + shachain root. Only the **public** funding key crosses the boundary, bound into the attestation quote.
- [ ] (Optional guarded import instead of born-in-enclave) operator runs `quid-provision --addr <hop> --measurement <MRENCLAVE> --seed <hex> --network mainnet` (verifies the enclave's DCAP quote natively, then imports over attested TLS). Or set `QUID_PROVISION_LISTEN` on the hop and provision before boot.

---

## Phase 4 — LP onboarding

- [ ] LPs self-host `quid-lp-daemon`: **own SGX** (build for the SGX target, born-in-enclave) OR **own laptop** (plain build, local `QUID_SEED`, mock seal — their risk; needs a watchtower). Same binary, dual-compiled. No cross-attestation needed.
- [ ] LP runs the `lpAuth` responder (signs each on-chain open the hop drives; the LP EVM key only ever signs the off-chain `lpAuth` digest, never sends txs — hop pays gas). Channel funding = BTC to the P2TR 2-of-2 `0x5120‖Q` (both funding pubkeys enclave-born).

---

## Phase 5 — Durability, watchtower, chain-source hardening (MANDATORY)

- [ ] **NEVER ship a single-enclave-no-backup custody key.** A 2-of-2 cannot be moved by one party, and the seal is MRENCLAVE+machine-bound, so an enclave/hardware loss with no backup LOCKS funds forever (spec §11 gotcha — applies to BOTH the hop's key and each LP's key). Therefore:
  - [ ] **Cold floor:** one-time, attested, LP-/operator-initiated backup of *their own* seed (shown once, never persisted unsealed; reuse `sealed_seed.rs`).
  - [ ] **Hot standby:** attested enclave→enclave **replication** to ≥1 standby (same MRENCLAVE) so a single hardware loss doesn't strand funds.
- [ ] **LP availability is a HARD requirement** (separate from the SGX-vs-plain key choice): a swap-serving LP must be **always-on** — its key co-signs swap-out splices in real time. The hop routes swap-outs only through *connected* LPs (`select_delivery_channel` filters on LDK `list_usable_channels()`), so an offline LP is skipped (no global DoS) but serves nothing while down. Run LPs on always-on hardware, not sleeping laptops.
- [ ] **Watchtower** (keyless, hostable public good) for any node that can go offline — defends against revoked-state broadcast while a node is down ([[project-quid-ln-attack-surface]]).
- [ ] **Bitcoin Core anti-eclipse**: supply `asmap.dat` + real `addnode=` peers per [`quid-ln/ops/README.md`](../quid-ln/ops/README.md) (bitcoind fails-closed without asmap).

---

## SGX HARDWARE TAIL — only doable / verifiable on real SGX (the deployment gate)

Everything above this line is verified off-SGX (mock seal + dummy quote). The
following **cannot be closed by any code change here** — they require real SGX
hardware + the offline prod keys. This is the M11 deployment gate.

1. [x] **Enclave-target COMPILES + LINKS** (2026-07-11, SPV `0b1c19c`) — `cargo +nightly build --target x86_64-fortanix-unknown-sgx -p quid-bridge` produces all 4 daemon bins. **[ ] Still hardware-only:** confirm the enclave EXECUTES on real SGX (musig2/secp256k1 run in-enclave; sealing/attestation against genuine hardware). Compile-green does not prove run-green.
2. [ ] **Real `EGETKEY` sealing** works (off-SGX uses a mock keyrequest with "no security").
3. [ ] **Real DCAP quote generation** (AESM round-trip via the `run-sgx` AESM proxy) — off-SGX emits only a dummy quote.
4. [ ] **Confidential-VM backends (SEV-SNP / TDX) hardware tail.** The multi-TEE support (backend detect + role policy + `configfs-tsm` attestation + SEV `SNP_GET_DERIVED_KEY` seal) is verified off-hardware (documented ABIs + compile-time struct/ioctl assertions + fixture-tested parsers + fail-closed device reads). On the FIRST real SEV-SNP deployment confirm: (a) the seal round-trips + is **MEASUREMENT-bound** (a different enclave build cannot unseal); (b) `configfs-tsm` returns a report the relying party verifies against the AMD cert chain. TDX seal (vTPM) + Nitro (NSM attest + KMS seal) are NOT yet wired — those backends stay `custody_ready=false` (individual self-host only) until they are, so nothing runs with insecure CVM custody meanwhile.
4. [ ] **`run-sgx` enclave launch** + AESM proxy on the production box.
5. [ ] **Reproducible MRENCLAVE** computed, published, and verified to match the running enclave.
6. [ ] **PROD SGX signing key** generated offline, `Measurement::PROD_SIGNER` updated to its MRSIGNER, enclave signed with it (replace the dev/placeholder).
7. [ ] **Operator provisioning token** set (`QUID_PROVISION_TOKEN`) + endpoint bound to an operator-private address, AND the **three 2-of-3 operator migration keys** generated off-host with `OPERATOR_PUBKEYS` replaced (dev placeholders → prod). No governance/DAO — distributed operator key custody; ≥2 of 3 needed to authorize a seed export, host-unforgeable.
8. [ ] **Born-in-enclave genesis** exercised on real hardware (seed never leaves the enclave).
9. [ ] **Cold backup + hot replication** validated on hardware (durability — see Phase 5; MANDATORY before custody).
10. [ ] **`DEPLOY_ENVIRONMENT=prod` enforces SGX** end-to-end (`validate_sgx`).
11. [ ] **SGX TCB-recovery procedure rehearsed** — when Intel revokes a TCB level (forced, on a schedule), rebuild on the patched TCB (new MRENCLAVE) and **migrate the key** via the enclave-to-enclave path (Phase 6). Old attestations stop being trusted; the old enclave can still run+unseal to hand off.
12. [ ] **Validating-signer policy** gates every taproot op (open/commitment/HTLC/splice/close/justice) in-enclave (`ValidatingChannelSigner`, e73d04a).
13. [x] **Sealed-state rollback — ACCEPTED bounded residual (decision 2026-06-24).** SGX sealing gives the channel-monitor blob confidentiality+integrity but NOT freshness, and the host owns the disk, so a malicious host can restore an OLD encrypted monitor (resetting the anti-revoked baseline on restart). NOT the same as the 2-of-3-protected seed-export risk, but strictly SMALLER: it canNOT steal the seed (needs 2-of-3 off-host keys), canNOT fool on-chain/EVM state (`swap_out_resolved` reads the chain; Bitcoin/EVM can't be rolled back), and the host alone can't profit (a rolled-back commitment is *revoked* → the counterparty's justice punishes the broadcaster). Worst case = griefing / forced-justice needing host+LP collusion, hurting the hop's own balance; honest LPs still recover via force-close. It is also the same persister-trust assumption every LN node makes. Safe on operator-controlled hardware. OPTIONAL hardening for rented/cloud infra: an external freshness anchor (on-chain-anchored monitor version / attested freshness service / monotonic counter).

---

## Phase 6 — Upgrades (enclave-to-enclave migration, recovery #1)

Every code change OR Intel TCB recovery changes MRENCLAVE, so the new enclave
cannot unseal the old seed. To upgrade WITHOUT mass channel force-closure:

- [ ] Deploy the new enclave (new MRENCLAVE); it boots and serves its attested `/provision` endpoint on an operator-private address with `QUID_PROVISION_LISTEN` + `QUID_PROVISION_TOKEN` set.
- [ ] **≥2 of the 3 operators** sign the new MRENCLAVE, off-host: each runs `quid-migrate-auth --sign --key prod-operator-N.key --measurement <new-MRENCLAVE> --network mainnet --out authN.bin`; then `quid-migrate-auth --combine bundle.bin auth1.bin auth2.bin`. The bundle is host-UNFORGEABLE (the host has none of the 3 secrets).
- [ ] Run the **old** enclave with `QUID_MIGRATE_TO=<new-addr>` + `QUID_MIGRATE_AUTH=bundle.bin` + `QUID_PROVISION_TOKEN=<same token>`. The old enclave verifies the 2-of-3 bundle against the baked-in `OPERATOR_PUBKEYS` (the host can't redirect the export), then verifies the new enclave's attestation == the authorized MRENCLAVE during the TLS handshake, then transfers the seed; the new enclave seals it. The old enclave only needs to **run** (not have valid fresh attestation), so this works under TCB recovery.
- [ ] Switch traffic to the new enclave; retire the old one. (The operator supplies the target MRENCLAVE — there is no governance signature; pair with network isolation + the token so a network attacker can't race a seed in. Worst case of a wrong target is a DoS, never theft.)

Recovery on **unplanned** loss (dead enclave, migration impossible): the LP always recovers their own balance via **force-close** (standard LN — the LP holds the complete aggregated key-path commitment sig, stored at every `commitment_signed` and replayed unilaterally; verified, M9). Only the dead party's OWN balance is lost — symmetric to standard Lightning.

---

## Pre-mainnet gates (don't launch until)
- [ ] All of the SGX HARDWARE TAIL checked.
- [ ] Both prod keys (signer MRSIGNER + governance) replace the dev/placeholder values.
- [ ] Cold backup + hot replication live for the hop key (and documented for LPs).
- [ ] `docs/actionable/AUDIT-TODO.md` sensitive areas 🟢.
- [ ] Watchtower + Bitcoin anti-eclipse config live.
