//! Enclave-to-enclave seed migration authorization.
//!
//! SGX seals are MRENCLAVE-bound: a NEW enclave build can't unseal the OLD
//! enclave's seed. To upgrade without orphaning the hop's channel key, the OLD
//! (running) enclave transfers the seed to the NEW enclave over the attested
//! provisioning channel ([`crate::seed::provision_seed`] on the receiving side).
//!
//! THE THREAT: the host is untrusted (that is why SGX is here). Migration is
//! triggered by config the host controls, so a malicious host could point the
//! old enclave at an ATTACKER enclave (genuine SGX, attacker MRENCLAVE) and make
//! it export the seed — defeating SGX entirely. The defense: the export target
//! must be authorized by something the host CANNOT forge.
//!
//! THE CONTROL: a [`MigrationAuth`] (target MRENCLAVE + deploy env + network)
//! authorized by the foundation's **operator MULTISIG — a plain k-of-n, NOT a
//! Gnosis Safe** (owner, standing: *"we are not using a Safe anymore, just a
//! simple msig"*) — an n-of-m of the operators' own EVM wallets. A migration
//! needs ≥[`MIGRATION_THRESHOLD`] distinct OWNER signatures over the EIP-712
//! [`MigrationAuth`]; the OLD enclave verifies them with `ecrecover` against
//! the configured owner set before
//! exporting. So NO single key (or single compromised custodian, or the host)
//! can redirect the export, AND losing one key does not brick upgrades. This is
//! NOT governance/a DAO — it is narrow operator key custody for one operation.
//!
//! ⛔ **NO SAFE. A PLAIN k-of-n msig, and that is the OWNER'S STANDING DECISION** ("we are not using
//! a Safe anymore, just a simple msig"). The block here used to be headed "WHY A SAFE" and argued
//! for Safe{Wallet} as the signing UI. **The MECHANISM never depended on one and still does not:**
//! [`verify_migration_auth`] takes an owner list and a threshold and checks k-of-n EIP-712
//! signatures. Nothing calls a Safe contract; nothing reads Safe storage.
//!
//! WHY AN ADDRESS-PINNED OWNER SET (not the old baked `ed25519 OPERATOR_PUBKEYS`):
//!   * operators sign EIP-712 with their own wallets — no bespoke keygen;
//!   * the owner set lives in SEALED CONFIG, not in MRENCLAVE, so rotating a member does NOT change
//!     the measurement (the old scheme baked pubkeys in, so rotation changed MRENCLAVE);
//!   * one primitive: the operator msig and the family msig verify IDENTICALLY.
//!
//! OWNER-SET SOURCE — [`OPERATOR_OWNERS`], a sealed-config snapshot. Self-contained, no RPC trust.
//! ⛔ **THE OLD "TARGET (A)" IS WITHDRAWN, NOT DEFERRED:** it proposed reading the LIVE owner set via
//! an EVM STATE PROOF OF A SAFE, which requires a Safe's storage layout — the thing that is ruled
//! out. It was never built (no `eth_getProof`, no storage-proof code in this file), so nothing is
//! lost by withdrawing it. **Do not re-open it as "the target" without re-deriving it for a msig**;
//! a plain msig exposes no owner-set storage to prove against, so live rotation would need a
//! different mechanism entirely, not a swapped source.

use std::collections::HashSet;

use crate::abi::{address_word, word_u64};
use alloy_primitives::{Address, address, keccak256};
use anyhow::{Context, bail, ensure};
use quid_common::{env::DeployEnv, ln::network::Network};
use quid_enclave::enclave::Measurement;
use secp256k1::{
    Message, Secp256k1, SecretKey,
    ecdsa::{RecoverableSignature, RecoveryId},
};
use serde::{Deserialize, Serialize};

/// The foundation's operator Gnosis **Safe** address — the EIP-712
/// `verifyingContract` a [`MigrationAuth`] is bound to (so an auth can't be
/// replayed against a different Safe), and the anchor for the target (A)
/// state-proof owner-set verification.
///
/// The EIP-712 domain's `verifyingContract` — it SCOPES the signature domain so an operator
/// signature for this deployment cannot be replayed against another. ⚠️ **It is NOT a Safe and
/// nothing calls it**; the name is historical (see the module header: no Safe).
/// PLACEHOLDER (dev). Replace with the real operator msig address before mainnet, like
/// [`Measurement::PROD_SIGNER`] — the boot guard below refuses to run until you do.
pub const OPERATOR_SAFE: Address = address!("000000000000000000000000000000000000dEaD");

/// The EVM chain the operator Safe lives on (EIP-712 domain `chainId`).
/// PLACEHOLDER (dev) — set to the real chain id alongside [`OPERATOR_SAFE`].
pub const OPERATOR_SAFE_CHAIN_ID: u64 = 1;

/// The `BTCChannels` protocol contract the enclave/daemon reads (agreement-gated) and
/// writes (fee / freshness / migration-nonce / swap markers) against. Pinned as a
/// COMPILE-TIME const so it is covered by MRENCLAVE: the untrusted host supplies
/// `btc_channels` via config, and without this pin an in-enclave key would sign against —
/// and every agreement read would trust — a host-chosen LOOK-ALIKE contract on a
/// host-chosen chain (where the host runs all the "agreeing" endpoints). Binding the
/// address + chain id is the config half of moving the EVM path into the enclave; sealing
/// the signing key is the other half. PLACEHOLDER (dev) — replace with the real deployed
/// BTCChannels before mainnet, exactly like [`OPERATOR_SAFE`].
pub const BTC_CHANNELS: Address = address!("000000000000000000000000000000000000dEaD");

/// The EVM chain id `BTCChannels` is deployed on. PLACEHOLDER (dev) — set alongside
/// [`BTC_CHANNELS`]; pinning it stops the host redirecting reads/writes to a fork/testnet.
pub const PROTOCOL_CHAIN_ID: u64 = 1;

/// Sealed-config snapshot of the operator Safe's owners — the trust anchors a
/// [`MigrationAuth`] is verified against (interim source; see module docs).
///
/// PLACEHOLDERS: the well-known addresses of secp256k1 secret keys 1, 2, 3
/// (dev/CI only — see [`operator_address`] / `quid-migrate-auth`). Replace with
/// the real Safe owners before mainnet; prod secrets never enter the repo.
pub const OPERATOR_OWNERS: [Address; 3] = [
    address!("7E5F4552091A69125d5DfCb7b8C2659029395Bdf"), // sk = 0x01..01
    address!("2B5AD5c4795c026514f8317c7a215E218DcCD6cF"), // sk = 0x02..02
    address!("6813Eb9362372EEF6200f3b1dbC3f819671cBA69"), // sk = 0x03..03
];

/// Number of distinct Safe-owner signatures required to authorize a migration.
pub const MIGRATION_THRESHOLD: usize = 2;

/// Fail CLOSED before a staging/prod enclave boots with the DEV migration trust
/// anchors still compiled in. [`OPERATOR_SAFE`] / [`OPERATOR_OWNERS`] ship as the
/// well-known addresses of secp256k1 secret keys 1/2/3 — anyone could forge a
/// 2-of-3 [`MigrationAuth`] and redirect the seed export (total enclave defeat).
/// Prod MUST replace these (from an offline/HSM source, never in the repo); until
/// it does, refuse to run rather than run insecurely. Dev/regtest is unaffected.
pub fn guard_prod_trust_anchors(deploy_env: DeployEnv) -> anyhow::Result<()> {
    if !deploy_env.is_staging_or_prod() {
        return Ok(());
    }
    ensure!(
        OPERATOR_SAFE != address!("000000000000000000000000000000000000dEaD"),
        "OPERATOR_SAFE (the EIP-712 verifyingContract) is still the dev placeholder (0x…dEaD) — refuse to boot in {}",
        deploy_env.as_str()
    );
    // The dev owner set == the addresses of secp256k1 secret keys 1/2/3 (public).
    const DEV_OWNERS: [Address; 3] = [
        address!("7E5F4552091A69125d5DfCb7b8C2659029395Bdf"),
        address!("2B5AD5c4795c026514f8317c7a215E218DcCD6cF"),
        address!("6813Eb9362372EEF6200f3b1dbC3f819671cBA69"),
    ];
    ensure!(
        OPERATOR_OWNERS != DEV_OWNERS,
        "OPERATOR_OWNERS are still the well-known dev keys 1/2/3 — refuse to boot in {}",
        deploy_env.as_str()
    );
    // The production enclave signer (MRSIGNER) must be the real offline/HSM key, not
    // the committed placeholder (which has no private key — clients pinning it could
    // never verify a genuine quote). Fail fast with a clear reason rather than a
    // confusing downstream attestation failure.
    ensure!(
        Measurement::PROD_SIGNER != Measurement::PROD_SIGNER_PLACEHOLDER,
        "PROD_SIGNER is still the placeholder MRSIGNER — build with the real prod signer \
         before running in {}",
        deploy_env.as_str()
    );
    Ok(())
}

/// Fail CLOSED in staging/prod unless the daemon's EVM target matches the MRENCLAVE-pinned
/// [`BTC_CHANNELS`] + [`PROTOCOL_CHAIN_ID`]. The untrusted host supplies `btc_channels` /
/// `chain_id` via config; without this pin an in-enclave key would sign against — and every
/// agreement read would trust — a host-chosen look-alike contract on a host-chosen chain
/// (the host runs all the "agreeing" endpoints, so quorum alone can't catch it). This is
/// the config-binding half of moving the EVM path into the enclave; it fails closed while
/// [`BTC_CHANNELS`] is still the dev placeholder, exactly like [`guard_prod_trust_anchors`].
/// Dev/regtest (host trusted, self-host) is exempt.
pub fn guard_prod_evm_target(
    deploy_env: DeployEnv,
    cfg_btc_channels: Address,
    cfg_chain_id: u64,
) -> anyhow::Result<()> {
    if !deploy_env.is_staging_or_prod() {
        return Ok(());
    }
    ensure!(
        BTC_CHANNELS != address!("000000000000000000000000000000000000dEaD"),
        "BTC_CHANNELS is still the dev placeholder (0x…dEaD) — pin the real deployed \
         BTCChannels (MRENCLAVE-bound) before running in {}",
        deploy_env.as_str()
    );
    ensure!(
        cfg_btc_channels == BTC_CHANNELS,
        "configured btc_channels ({cfg_btc_channels}) != MRENCLAVE-pinned BTC_CHANNELS \
         ({BTC_CHANNELS}) — refusing to boot (host may be redirecting the protocol to a \
         look-alike contract)"
    );
    ensure!(
        cfg_chain_id == PROTOCOL_CHAIN_ID,
        "configured chain_id ({cfg_chain_id}) != MRENCLAVE-pinned PROTOCOL_CHAIN_ID \
         ({PROTOCOL_CHAIN_ID}) — refusing to boot (host may be redirecting to a fork/testnet)"
    );
    Ok(())
}

/// An operator-signed authorization that `measurement` is the successor enclave
/// the old enclave may migrate its sealed seed into. Bound to a deploy env +
/// network so it can't be replayed across environments.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MigrationAuth {
    /// The authorized successor enclave measurement (MRENCLAVE).
    pub measurement: Measurement,
    /// The deploy env this authorization is valid for.
    pub deploy_env: DeployEnv,
    /// The network this authorization is valid for.
    pub network: Network,
    /// ANTI-REPLAY (audit HIGH): a unique per-authorization nonce the operators include
    /// when signing. The migrating enclave CONSUMES it on-chain
    /// (`BTCChannels.markMigrationNonceUsed`) before exporting the seed, so a captured
    /// bundle can be used AT MOST ONCE — it no longer re-authorizes export forever.
    pub nonce: [u8; 32],
}

impl MigrationAuth {
    /// The EIP-712 typed-data digest the Safe owners sign (and the enclave
    /// `ecrecover`s against). `digest = keccak256(0x1901 ‖ domainSeparator ‖
    /// hashStruct(MigrationAuth))`, with the domain bound to [`OPERATOR_SAFE`] +
    /// [`OPERATOR_SAFE_CHAIN_ID`].
    pub fn eip712_digest(&self) -> [u8; 32] {
        // domainSeparator = keccak256(abi.encode(domainTypeHash, name, version,
        //                              chainId, verifyingContract))
        let domain_type_hash = keccak256(
            b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
        );
        let name_hash = keccak256(b"QUID Migration");
        let version_hash = keccak256(b"1");
        let mut dom = Vec::with_capacity(32 * 5);
        dom.extend_from_slice(domain_type_hash.as_slice());
        dom.extend_from_slice(name_hash.as_slice());
        dom.extend_from_slice(version_hash.as_slice());
        dom.extend_from_slice(&word_u64(OPERATOR_SAFE_CHAIN_ID));
        dom.extend_from_slice(&address_word(OPERATOR_SAFE));
        let domain_separator = keccak256(&dom);

        // hashStruct = keccak256(abi.encode(typeHash, measurement,
        //                         keccak256(deployEnv), keccak256(network)))
        let type_hash = keccak256(
            b"MigrationAuth(bytes32 measurement,string deployEnv,string network,bytes32 nonce)",
        );
        let deploy_env_hash = keccak256(self.deploy_env.to_string().as_bytes());
        let network_hash = keccak256(self.network.to_string().as_bytes());
        let mut st = Vec::with_capacity(32 * 5);
        st.extend_from_slice(type_hash.as_slice());
        st.extend_from_slice(self.measurement.as_bytes());
        st.extend_from_slice(deploy_env_hash.as_slice());
        st.extend_from_slice(network_hash.as_slice());
        st.extend_from_slice(&self.nonce);
        let struct_hash = keccak256(&st);

        let mut buf = Vec::with_capacity(2 + 64);
        buf.push(0x19);
        buf.push(0x01);
        buf.extend_from_slice(domain_separator.as_slice());
        buf.extend_from_slice(struct_hash.as_slice());
        keccak256(&buf).0
    }
}

/// The bundle the host carries to the OLD enclave: the [`MigrationAuth`] plus the
/// collected Safe-owner signatures over its EIP-712 digest. The host cannot
/// tamper the auth — the sigs commit to the exact digest, so any edit makes them
/// recover to non-owner addresses and the bundle is rejected.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MigrationAuthBundle {
    pub auth: MigrationAuth,
    /// Each entry is a 65-byte EVM signature `r ‖ s ‖ v` (v ∈ {27, 28}).
    pub signatures: Vec<Vec<u8>>,
}

/// The EVM address controlled by a secp256k1 secret key — i.e. the operator
/// (Safe-owner) address to register. `addr = keccak256(uncompressed_pubkey[1..])[12..]`.
/// (Tooling: print the owner address to add to the Safe.)
pub fn operator_address(secret: &[u8; 32]) -> anyhow::Result<Address> {
    let secp = Secp256k1::new();
    let sk = SecretKey::from_slice(secret).context("invalid operator secret key")?;
    let pk = sk.public_key(&secp);
    Ok(crate::evm_codec::evm_address_of(&pk))
}

/// Produce ONE operator (Safe-owner) signature over a [`MigrationAuth`].
///
/// In production operators sign the EIP-712 digest in their wallet / the Safe UI;
/// this helper is for dev/CI and the `quid-migrate-auth` tool. Returns the 65-byte
/// `r ‖ s ‖ v` signature; combine ≥`MIGRATION_THRESHOLD` of them with
/// [`combine_migration_auths`].
pub fn sign_migration_auth(secret: &[u8; 32], auth: &MigrationAuth) -> anyhow::Result<Vec<u8>> {
    let secp = Secp256k1::new();
    let sk = SecretKey::from_slice(secret).context("invalid operator secret key")?;
    let msg = Message::from_digest(auth.eip712_digest());
    let rsig = secp.sign_ecdsa_recoverable(&msg, &sk);
    let (recid, compact) = rsig.serialize_compact();
    let mut out = vec![0u8; 65];
    out[..64].copy_from_slice(&compact);
    out[64] = recid.to_i32() as u8 + 27; // EVM v ∈ {27, 28}
    Ok(out)
}

/// Join the [`MigrationAuth`] + the collected owner signatures into the bundle
/// the enclave verifies.
pub fn combine_migration_auths(
    auth: MigrationAuth,
    signatures: Vec<Vec<u8>>,
) -> anyhow::Result<Vec<u8>> {
    serde_json::to_vec(&MigrationAuthBundle { auth, signatures })
        .context("serialize migration auth bundle")
}

/// Recover the EVM signer of a 65-byte `r ‖ s ‖ v` signature over `digest`
/// (mirrors OZ `ECDSA.recover`: v ∈ {27, 28}).
fn recover_signer(digest: &[u8; 32], sig: &[u8]) -> anyhow::Result<Address> {
    ensure!(sig.len() == 65, "operator signature must be 65 bytes, got {}", sig.len());
    let parity = match sig[64] {
        27 => 0,
        28 => 1,
        v => bail!("operator sig recovery id v={v} not in {{27,28}}"),
    };
    let recid = RecoveryId::from_i32(parity).context("recovery id")?;
    let rsig = RecoverableSignature::from_compact(&sig[..64], recid)
        .context("malformed operator signature")?;
    let secp = Secp256k1::new();
    let pk = secp
        .recover_ecdsa(&Message::from_digest(*digest), &rsig)
        .context("ecrecover failed")?;
    Ok(crate::evm_codec::evm_address_of(&pk))
}
/// The threshold check BOTH operator-authorized powers run — seed export and wallet drain.
///
/// 🔑 **ONE COPY ON PURPOSE.** The two powers legitimately differ in their PAYLOAD (a successor
/// measurement vs a destination address), so they have different digests. They do **not** differ
/// in how a quorum is established, and the first version of the sweep path duplicated this loop.
/// Two copies of one security check is exactly the drift §E178 was booked for: a fix applied to
/// one and not the other is invisible until it matters.
///
/// What it enforces: every signature recovers to an address in `owners`, DISTINCT owners only
/// (a single compromised key must not reach any threshold by signing repeatedly), and at least
/// `threshold` of them. `what` names the power in the error, so a failure says which one.
fn verify_threshold_signatures(
    digest: &[u8; 32],
    signatures: &[Vec<u8>],
    owners: &[Address],
    threshold: usize,
    what: &str,
) -> anyhow::Result<()> {
    let mut signers: HashSet<Address> = HashSet::new();
    for sig in signatures {
        let addr = recover_signer(digest, sig).context("invalid operator signature")?;
        ensure!(owners.contains(&addr), "signature from non-owner address {addr}");
        signers.insert(addr); // distinct owners only
    }
    ensure!(
        signers.len() >= threshold,
        "{what} needs {threshold} distinct operator signatures, got {}",
        signers.len(),
    );
    Ok(())
}


/// Verify a migration authorization bundle: ≥`threshold` DISTINCT Safe-owner
/// (`owners`) signatures over the SAME EIP-712 [`MigrationAuth`], bound to the
/// expected `deploy_env` + `network`. Returns the authorized target measurement.
/// The OLD enclave calls this before exporting its seed, so a host that controls
/// the migration config still cannot redirect the export.
pub fn verify_migration_auth(
    bundle: &[u8],
    owners: &[Address],
    threshold: usize,
    deploy_env: DeployEnv,
    network: Network,
) -> anyhow::Result<(Measurement, [u8; 32])> {
    let bundle: MigrationAuthBundle =
        serde_json::from_slice(bundle).context("deserialize migration auth bundle")?;

    // Bind to the running environment (also enforced cryptographically — these
    // fields are in the EIP-712 digest, so a tampered value fails recovery — but
    // checking here gives a clear error).
    ensure!(
        bundle.auth.deploy_env == deploy_env,
        "migration auth deploy_env ({}) != expected ({deploy_env})",
        bundle.auth.deploy_env,
    );
    ensure!(
        bundle.auth.network == network,
        "migration auth network ({}) != expected ({network})",
        bundle.auth.network,
    );

    verify_threshold_signatures(
        &bundle.auth.eip712_digest(), &bundle.signatures, owners, threshold, "migration",
    )?;
    // Return the authorized measurement AND the anti-replay nonce; the caller MUST consume
    // the nonce on-chain (markMigrationNonceUsed) before exporting the seed, so a replayed
    // bundle is rejected (the nonce is already used).
    Ok((bundle.auth.measurement, bundle.auth.nonce))
}


// ═══════════════════════════ SWEEP AUTHORIZATION (§W1) ═══════════════════════════
//
// `OnchainWallet::create_sweep_tx` drains the hop's entire on-chain balance to one
// caller-supplied address. It existed for a long time with NO trigger, and its `dead_code`
// warning was twice mistaken for litter and deleted. The reason it was never simply wired to an
// endpoint is that **"send the entire balance to address X" is the same severity as a seed
// export** — so it gets the same control, mirrored here rather than reinvented.
//
// 🔑 **THE ONE THING THAT MUST NOT BE SHARED IS THE DOMAIN.** `SweepAuth` uses its own EIP-712
// domain name (`QUID Sweep`) and its own type string, so a captured `MigrationAuth` signature can
// never be replayed as a sweep authorization, nor the reverse. Everything else — the operator
// Safe, the owner set, `recover_signer`, the threshold discipline — is deliberately the SAME
// machinery, because two divergent copies of an authorization path is how one of them rots.

/// Distinct operator signatures required to authorize a full wallet drain.
///
/// Equal to [`MIGRATION_THRESHOLD`] today and deliberately a SEPARATE constant: the two powers
/// are different (a sweep moves coins, a migration moves the seed), so raising one must not
/// silently raise the other.
pub const SWEEP_THRESHOLD: usize = 2;

/// An operator-signed authorization to drain the hop's on-chain wallet to `destination`.
///
/// Bound to a deploy env + network so it cannot be replayed across environments, and to a
/// `nonce` so a captured bundle authorizes **at most one** drain.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SweepAuth {
    /// The Bitcoin address the entire balance is swept to, as the string the operators SAW and
    /// signed. Kept as text on purpose: the signers approved a human-readable address, and
    /// re-encoding it into bytes here would let a parsing difference change what they approved.
    pub destination: String,
    /// The deploy env this authorization is valid for.
    pub deploy_env: DeployEnv,
    /// The network this authorization is valid for.
    pub network: Network,
    /// ANTI-REPLAY: consumed on-chain (the same one-shot nonce registry a migration uses)
    /// BEFORE the sweep broadcasts, so a captured bundle cannot drain the wallet twice.
    pub nonce: [u8; 32],
}

impl SweepAuth {
    /// `digest = keccak256(0x1901 ‖ domainSeparator ‖ hashStruct(SweepAuth))`.
    ///
    /// ⚠️ The domain name is **`QUID Sweep`**, not `QUID Migration`. That single difference is
    /// what makes the two authorization types non-interchangeable; a test below asserts the
    /// digests differ for otherwise-identical fields.
    pub fn eip712_digest(&self) -> [u8; 32] {
        let domain_type_hash = keccak256(
            b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
        );
        let name_hash = keccak256(b"QUID Sweep");
        let version_hash = keccak256(b"1");
        let mut dom = Vec::with_capacity(32 * 5);
        dom.extend_from_slice(domain_type_hash.as_slice());
        dom.extend_from_slice(name_hash.as_slice());
        dom.extend_from_slice(version_hash.as_slice());
        dom.extend_from_slice(&word_u64(OPERATOR_SAFE_CHAIN_ID));
        dom.extend_from_slice(&address_word(OPERATOR_SAFE));
        let domain_separator = keccak256(&dom);

        let type_hash = keccak256(
            b"SweepAuth(string destination,string deployEnv,string network,bytes32 nonce)",
        );
        let dest_hash = keccak256(self.destination.as_bytes());
        let deploy_env_hash = keccak256(self.deploy_env.to_string().as_bytes());
        let network_hash = keccak256(self.network.to_string().as_bytes());
        let mut st = Vec::with_capacity(32 * 5);
        st.extend_from_slice(type_hash.as_slice());
        st.extend_from_slice(dest_hash.as_slice());
        st.extend_from_slice(deploy_env_hash.as_slice());
        st.extend_from_slice(network_hash.as_slice());
        st.extend_from_slice(&self.nonce);
        let struct_hash = keccak256(&st);

        let mut buf = Vec::with_capacity(2 + 64);
        buf.push(0x19);
        buf.push(0x01);
        buf.extend_from_slice(domain_separator.as_slice());
        buf.extend_from_slice(struct_hash.as_slice());
        keccak256(&buf).0
    }
}

/// The bundle carried to the enclave: the [`SweepAuth`] plus the owner signatures over its
/// digest. The host cannot tamper the auth — the signatures commit to the exact digest.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SweepAuthBundle {
    pub auth: SweepAuth,
    /// Each entry is a 65-byte EVM signature `r ‖ s ‖ v` (v ∈ {27, 28}).
    pub signatures: Vec<Vec<u8>>,
}

/// Produce ONE operator signature over a [`SweepAuth`] (dev/CI + the signing tool; in production
/// operators sign the digest in their own wallet).
pub fn sign_sweep_auth(secret: &[u8; 32], auth: &SweepAuth) -> anyhow::Result<Vec<u8>> {
    let secp = Secp256k1::new();
    let sk = SecretKey::from_slice(secret).context("invalid operator secret key")?;
    let msg = Message::from_digest(auth.eip712_digest());
    let rsig = secp.sign_ecdsa_recoverable(&msg, &sk);
    let (recid, compact) = rsig.serialize_compact();
    let mut out = vec![0u8; 65];
    out[..64].copy_from_slice(&compact);
    out[64] = recid.to_i32() as u8 + 27;
    Ok(out)
}

/// Join a [`SweepAuth`] + collected owner signatures into the bundle the enclave verifies.
pub fn combine_sweep_auths(
    auth: SweepAuth,
    signatures: Vec<Vec<u8>>,
) -> anyhow::Result<Vec<u8>> {
    serde_json::to_vec(&SweepAuthBundle { auth, signatures })
        .context("serialize sweep auth bundle")
}

/// Verify a sweep bundle and return the authorized `(destination, nonce)`.
///
/// ⚠️ **THE CALLER MUST CONSUME THE NONCE ON-CHAIN BEFORE BROADCASTING THE SWEEP** — exactly as
/// the migration path consumes its nonce before exporting the seed. Verification alone does not
/// spend the authorization, so without that step a captured bundle drains the wallet repeatedly.
pub fn verify_sweep_auth(
    bundle: &[u8],
    owners: &[Address],
    threshold: usize,
    deploy_env: DeployEnv,
    network: Network,
) -> anyhow::Result<(String, [u8; 32])> {
    let bundle: SweepAuthBundle =
        serde_json::from_slice(bundle).context("deserialize sweep auth bundle")?;

    ensure!(
        bundle.auth.deploy_env == deploy_env,
        "sweep auth deploy_env ({}) != expected ({deploy_env})",
        bundle.auth.deploy_env,
    );
    ensure!(
        bundle.auth.network == network,
        "sweep auth network ({}) != expected ({network})",
        bundle.auth.network,
    );
    ensure!(!bundle.auth.destination.is_empty(), "sweep auth destination is empty");

    verify_threshold_signatures(
        &bundle.auth.eip712_digest(), &bundle.signatures, owners, threshold, "sweep",
    )?;
    Ok((bundle.auth.destination, bundle.auth.nonce))
}

#[cfg(test)]
mod test {
    use super::*;

    /// Dev operator secret keys 1, 2, 3 (match [`OPERATOR_OWNERS`]).
    fn secret(i: u8) -> [u8; 32] {
        let mut s = [0u8; 32];
        s[31] = i;
        s
    }

    #[test]
    fn operator_owners_const_matches_dev_secrets() {
        // The committed OPERATOR_OWNERS snapshot must be the addresses of the dev
        // secrets 1,2,3 — else every other test (and prod config) would be wrong.
        for i in 0..3 {
            assert_eq!(operator_address(&secret(i as u8 + 1)).unwrap(), OPERATOR_OWNERS[i]);
        }
    }

    #[test]
    fn prod_guard_fails_closed_on_dev_anchors() {
        // Dev/staging-regtest tolerated; staging + prod must refuse while the
        // committed anchors are still the well-known dev keys (they are, per
        // `operator_owners_const_matches_dev_secrets`).
        assert!(guard_prod_trust_anchors(DeployEnv::Dev).is_ok());
        let staging = guard_prod_trust_anchors(DeployEnv::Staging);
        let prod = guard_prod_trust_anchors(DeployEnv::Prod);
        assert!(staging.is_err(), "staging must fail closed on dev anchors");
        assert!(prod.is_err(), "prod must fail closed on dev anchors");
        // The message names WHY (so an operator knows to replace the anchors).
        let msg = format!("{}", prod.unwrap_err());
        assert!(msg.contains("dev") || msg.contains("placeholder"), "explains the refusal: {msg}");
        // Pre-mainnet, the prod signer is still the placeholder — so that guard arm
        // is genuinely live (it will fire once the anchors above are replaced).
        assert_eq!(
            Measurement::PROD_SIGNER, Measurement::PROD_SIGNER_PLACEHOLDER,
            "PROD_SIGNER still placeholder pre-mainnet — guard arm is live"
        );
    }

    #[test]
    fn prod_evm_target_guard_fails_closed_on_placeholder() {
        use alloy_primitives::address;
        let real = address!("00000000000000000000000000000000cafeBABE");
        // Dev is exempt (host trusted) regardless of what's configured.
        assert!(guard_prod_evm_target(DeployEnv::Dev, real, 8453).is_ok());
        // Staging/prod fail closed while BTC_CHANNELS is still the dev placeholder — even
        // if the host's config happens to match the placeholder.
        assert!(guard_prod_evm_target(DeployEnv::Staging, BTC_CHANNELS, PROTOCOL_CHAIN_ID).is_err());
        let prod = guard_prod_evm_target(DeployEnv::Prod, real, 8453);
        assert!(prod.is_err(), "prod must fail closed while BTC_CHANNELS is the placeholder");
        let msg = format!("{}", prod.unwrap_err());
        assert!(msg.contains("placeholder") || msg.contains("dEaD"), "explains the refusal: {msg}");
        // Pre-mainnet BTC_CHANNELS is the placeholder — the guard arm is genuinely live
        // (it fires until the real deployed address is pinned in).
        assert_eq!(
            BTC_CHANNELS, address!("000000000000000000000000000000000000dEaD"),
            "BTC_CHANNELS still placeholder pre-mainnet — guard arm is live"
        );
    }

    fn auth() -> MigrationAuth {
        MigrationAuth {
            measurement: Measurement::new([7u8; 32]),
            deploy_env: DeployEnv::Dev,
            network: Network::Regtest,
            nonce: [0x11u8; 32],
        }
    }

    #[test]
    fn two_of_three_authorizes() {
        let a = auth();
        let s1 = sign_migration_auth(&secret(1), &a).unwrap();
        let s3 = sign_migration_auth(&secret(3), &a).unwrap();
        let bundle = combine_migration_auths(a.clone(), vec![s1, s3]).unwrap();
        let (measurement, nonce) = verify_migration_auth(
            &bundle, &OPERATOR_OWNERS, 2, DeployEnv::Dev, Network::Regtest,
        )
        .unwrap();
        assert_eq!(measurement, a.measurement);
        assert_eq!(nonce, a.nonce, "verify returns the nonce for on-chain consumption");
    }

    #[test]
    fn one_signature_is_not_enough() {
        let a = auth();
        let s1 = sign_migration_auth(&secret(1), &a).unwrap();
        let bundle = combine_migration_auths(a, vec![s1]).unwrap();
        verify_migration_auth(&bundle, &OPERATOR_OWNERS, 2, DeployEnv::Dev, Network::Regtest)
            .unwrap_err();
    }

    #[test]
    fn same_owner_twice_is_one_signer() {
        let a = auth();
        // Two sigs from the SAME owner must NOT count as 2-of-3.
        let s1 = sign_migration_auth(&secret(1), &a).unwrap();
        let s1b = sign_migration_auth(&secret(1), &a).unwrap();
        let bundle = combine_migration_auths(a, vec![s1, s1b]).unwrap();
        verify_migration_auth(&bundle, &OPERATOR_OWNERS, 2, DeployEnv::Dev, Network::Regtest)
            .unwrap_err();
    }

    #[test]
    fn non_owner_rejected() {
        let a = auth();
        let s1 = sign_migration_auth(&secret(1), &a).unwrap();
        let attacker = sign_migration_auth(&secret(99), &a).unwrap(); // not in the Safe
        let bundle = combine_migration_auths(a, vec![s1, attacker]).unwrap();
        verify_migration_auth(&bundle, &OPERATOR_OWNERS, 2, DeployEnv::Dev, Network::Regtest)
            .unwrap_err();
    }

    #[test]
    fn tampered_target_rejected() {
        // Owners signed measurement [7;32]; host swaps it for an attacker MRENCLAVE.
        let signed = auth();
        let s1 = sign_migration_auth(&secret(1), &signed).unwrap();
        let s2 = sign_migration_auth(&secret(2), &signed).unwrap();
        let tampered = MigrationAuth {
            measurement: Measurement::new([0x66u8; 32]),
            deploy_env: DeployEnv::Dev,
            network: Network::Regtest,
            nonce: [0x11u8; 32],
        };
        let bundle = combine_migration_auths(tampered, vec![s1, s2]).unwrap();
        // Sigs were over the original digest → recover to non-owner addrs → reject.
        verify_migration_auth(&bundle, &OPERATOR_OWNERS, 2, DeployEnv::Dev, Network::Regtest)
            .unwrap_err();
    }

    #[test]
    fn tampered_nonce_rejected() {
        // The nonce is in the EIP-712 digest (audit HIGH anti-replay), so a host that swaps
        // it (e.g. to re-use a fresh nonce with old sigs) makes recovery yield non-owner
        // addrs → reject. Prevents forging the anti-replay nonce onto a signed bundle.
        let signed = auth();
        let s1 = sign_migration_auth(&secret(1), &signed).unwrap();
        let s2 = sign_migration_auth(&secret(2), &signed).unwrap();
        let tampered = MigrationAuth { nonce: [0x99u8; 32], ..signed };
        let bundle = combine_migration_auths(tampered, vec![s1, s2]).unwrap();
        verify_migration_auth(&bundle, &OPERATOR_OWNERS, 2, DeployEnv::Dev, Network::Regtest)
            .unwrap_err();
    }

    #[test]
    fn env_mismatch_rejected() {
        let a = auth();
        let s1 = sign_migration_auth(&secret(1), &a).unwrap();
        let s2 = sign_migration_auth(&secret(2), &a).unwrap();
        let bundle = combine_migration_auths(a, vec![s1, s2]).unwrap();
        // Verified against a different network than signed.
        verify_migration_auth(&bundle, &OPERATOR_OWNERS, 2, DeployEnv::Dev, Network::Testnet3)
            .unwrap_err();
    }
    // ─────────────────────────── SWEEP AUTH (§W1) ───────────────────────────

    fn sweep_auth() -> SweepAuth {
        SweepAuth {
            destination: "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080".to_string(),
            deploy_env: DeployEnv::Dev,
            network: Network::Regtest,
            nonce: [0x5Au8; 32],
        }
    }

    #[test]
    fn sweep_threshold_of_distinct_owners_verifies() {
        let a = sweep_auth();
        let s1 = sign_sweep_auth(&secret(1), &a).unwrap();
        let s2 = sign_sweep_auth(&secret(2), &a).unwrap();
        let bundle = combine_sweep_auths(a.clone(), vec![s1, s2]).unwrap();
        let (dest, nonce) =
            verify_sweep_auth(&bundle, &OPERATOR_OWNERS, SWEEP_THRESHOLD, DeployEnv::Dev, Network::Regtest)
                .unwrap();
        assert_eq!(dest, a.destination);
        assert_eq!(nonce, a.nonce, "the nonce comes back so the caller can consume it on-chain");
    }

    #[test]
    fn sweep_one_signature_is_below_threshold() {
        let a = sweep_auth();
        let s1 = sign_sweep_auth(&secret(1), &a).unwrap();
        let bundle = combine_sweep_auths(a, vec![s1]).unwrap();
        verify_sweep_auth(&bundle, &OPERATOR_OWNERS, SWEEP_THRESHOLD, DeployEnv::Dev, Network::Regtest)
            .unwrap_err();
    }

    /// The same owner twice is ONE signer. Without the distinct-signer set, a single compromised
    /// operator key would reach any threshold by signing repeatedly.
    #[test]
    fn sweep_duplicate_owner_does_not_reach_threshold() {
        let a = sweep_auth();
        let s1 = sign_sweep_auth(&secret(1), &a).unwrap();
        let s1_again = sign_sweep_auth(&secret(1), &a).unwrap();
        let bundle = combine_sweep_auths(a, vec![s1, s1_again]).unwrap();
        verify_sweep_auth(&bundle, &OPERATOR_OWNERS, SWEEP_THRESHOLD, DeployEnv::Dev, Network::Regtest)
            .unwrap_err();
    }

    /// 🔑 THE PROPERTY THE SEPARATE EIP-712 DOMAIN EXISTS FOR: an authorization to migrate the
    /// SEED must not also authorize draining the WALLET. Same nonce, same env, same network — and
    /// the digests must still differ, or operator signatures would be interchangeable between two
    /// powers of very different shape.
    #[test]
    fn a_migration_signature_cannot_authorize_a_sweep() {
        let m = MigrationAuth {
            measurement: Measurement::new([0xAB; 32]),
            deploy_env: DeployEnv::Dev,
            network: Network::Regtest,
            nonce: [0x5Au8; 32],
        };
        let s = sweep_auth(); // same nonce/env/network
        assert_ne!(m.eip712_digest(), s.eip712_digest(), "domains must not collide");

        // And concretely: migration signatures do not verify as a sweep bundle.
        let m1 = sign_migration_auth(&secret(1), &m).unwrap();
        let m2 = sign_migration_auth(&secret(2), &m).unwrap();
        let bundle = combine_sweep_auths(s, vec![m1, m2]).unwrap();
        verify_sweep_auth(&bundle, &OPERATOR_OWNERS, SWEEP_THRESHOLD, DeployEnv::Dev, Network::Regtest)
            .unwrap_err();
    }

    /// A tampered destination invalidates the signatures — the address the operators approved is
    /// inside the digest, so the host cannot redirect the drain after they signed.
    #[test]
    fn sweep_destination_cannot_be_swapped_after_signing() {
        let a = sweep_auth();
        let s1 = sign_sweep_auth(&secret(1), &a).unwrap();
        let s2 = sign_sweep_auth(&secret(2), &a).unwrap();
        let redirected = SweepAuth { destination: "bcrt1qattacker".to_string(), ..a };
        let bundle = combine_sweep_auths(redirected, vec![s1, s2]).unwrap();
        verify_sweep_auth(&bundle, &OPERATOR_OWNERS, SWEEP_THRESHOLD, DeployEnv::Dev, Network::Regtest)
            .unwrap_err();
    }

    #[test]
    fn sweep_env_mismatch_rejected() {
        let a = sweep_auth();
        let s1 = sign_sweep_auth(&secret(1), &a).unwrap();
        let s2 = sign_sweep_auth(&secret(2), &a).unwrap();
        let bundle = combine_sweep_auths(a, vec![s1, s2]).unwrap();
        verify_sweep_auth(&bundle, &OPERATOR_OWNERS, SWEEP_THRESHOLD, DeployEnv::Dev, Network::Testnet3)
            .unwrap_err();
    }
}
