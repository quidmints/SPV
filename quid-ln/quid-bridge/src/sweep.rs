//! (§W1) THE AUTHORIZED TRIGGER FOR A FULL WALLET DRAIN.
//!
//! `OnchainWallet::create_sweep_tx` builds a transaction that sends the hop's ENTIRE on-chain
//! balance to one address. It sat with no caller long enough to be mistaken for dead code and
//! deleted twice. It was never missing a caller by accident — it was missing the *control* that
//! a caller would have to go through, because **"send the entire balance to address X" is the
//! same severity as a seed export**.
//!
//! So this is that control, and it is deliberately the SAME shape as the seed export's:
//! an EIP-712 [`SweepAuth`] signed by ≥ [`SWEEP_THRESHOLD`] distinct owners of the operator
//! Safe, verified in-enclave by `ecrecover`, with an anti-replay nonce consumed **on-chain
//! before** anything is broadcast.
//!
//! ## The order is the security property
//!
//! 1. **VERIFY** the bundle — threshold, distinct owners, env/network binding.
//! 2. **PARSE + NETWORK-CHECK** the destination the operators signed.
//! 3. **CONSUME the nonce on-chain**, and only on success:
//! 4. **BUILD + BROADCAST** the drain.
//!
//! ⚠️ **Step 3 must precede step 4 and it is not a formality.** Verification alone does not
//! spend an authorization: a host that captured a valid bundle could otherwise replay it and
//! drain every future balance the wallet ever holds. Consuming first means a replay hits an
//! already-used nonce and reverts *before* any coins move — the same reason the migration path
//! consumes before exporting the seed.
//!
//! ⚠️ **And a failed consume must ABORT, not warn.** If the nonce cannot be confirmed consumed,
//! the correct outcome is no sweep at all: an un-swept wallet is recoverable (the operators can
//! re-authorize), whereas a swept-but-unconsumed authorization is a standing drain permit.

use anyhow::Context;
use bitcoin::{Address, Network, Transaction};
use tracing::{info, warn};

use quid_common::{
    env::DeployEnv,
    ln::{amount::Amount, network::Network as LnNetwork, priority::ConfirmationPriority},
};
use quid_hop::migration::{verify_sweep_auth, SWEEP_THRESHOLD};

use crate::provision_api::MigrationNonceConsumer;

/// What a completed sweep reports back: the broadcast drain and the fee it paid.
#[derive(Clone, Debug)]
pub struct SweepOutcome {
    pub tx: Transaction,
    pub fee: Amount,
    /// The address the operators authorized, after the network check.
    pub destination: Address,
}

/// Verify an operator-signed sweep bundle, consume its nonce on-chain, then drain the wallet.
///
/// `owners` is the sealed-config snapshot of the operator Safe's owner set — the SAME anchor the
/// migration path uses, so a rotation of the Safe changes both powers together rather than
/// leaving one on a stale list.
///
/// ⚠️ `network` is checked against the parsed address, not merely against the auth's own field.
/// The operators sign a STRING; a string that is a valid address on another network would
/// otherwise be accepted here and the coins sent somewhere unspendable — the auth's `network`
/// field proves what they *intended*, `require_network` proves what the text actually *is*.
#[allow(clippy::too_many_arguments)]
pub async fn execute_sweep<C: MigrationNonceConsumer, W: BuildSweep, B: BroadcastTx>(
    bundle: &[u8],
    owners: &[alloy_primitives::Address],
    deploy_env: DeployEnv,
    ln_network: LnNetwork,
    btc_network: Network,
    consumer: &C,
    wallet: &W,
    priority: ConfirmationPriority,
    broadcaster: &B,
) -> anyhow::Result<SweepOutcome> {
    // 1. AUTHORIZATION.
    let (destination, nonce) =
        verify_sweep_auth(bundle, owners, SWEEP_THRESHOLD, deploy_env, ln_network)
            .context("sweep authorization rejected")?;

    // 2. The destination, as text the operators approved → an address valid on THIS network.
    let dest: Address = destination
        .parse::<Address<bitcoin::address::NetworkUnchecked>>()
        .with_context(|| format!("sweep destination {destination} is not a Bitcoin address"))?
        .require_network(btc_network)
        .with_context(|| format!("sweep destination {destination} is not a {btc_network} address"))?;

    // 3. SPEND THE AUTHORIZATION BEFORE MOVING ANY COINS. A failure here is terminal for this
    //    attempt on purpose — see the module header.
    consumer
        .consume(nonce)
        .context("sweep nonce not consumed on-chain — refusing to broadcast the drain")?;
    info!(destination = %dest, "sweep: authorization consumed, draining wallet");

    // 4. BUILD + BROADCAST.
    let (tx, fee) = wallet
        .build_sweep(&dest, priority)
        .context("build sweep tx (a dust balance cannot cover its own fee)")?;
    broadcaster
        .broadcast(&tx)
        .await
        .context("broadcast sweep tx")?;
    warn!(txid = %tx.compute_txid(), %fee, destination = %dest, "sweep: wallet drained");
    Ok(SweepOutcome { tx, fee, destination: dest })
}

/// Building the drain, behind a trait for ONE reason: so the step ORDER above is testable.
///
/// ⚠️ The first version of this module took `&OnchainWallet` directly, and its ordering test
/// could not call [`execute_sweep`] at all — it re-ran the first two steps inline and asserted on
/// those. That test would have passed against an executor that swept BEFORE consuming, i.e.
/// against the exact bug it was named for. Injecting the builder makes the real function
/// observable: the test now asserts the wallet was never even asked to build.
pub trait BuildSweep {
    fn build_sweep(
        &self,
        dest: &Address,
        priority: ConfirmationPriority,
    ) -> anyhow::Result<(Transaction, Amount)>;
}

impl BuildSweep for quid_ln::wallet::OnchainWallet {
    fn build_sweep(
        &self,
        dest: &Address,
        priority: ConfirmationPriority,
    ) -> anyhow::Result<(Transaction, Amount)> {
        self.create_sweep_tx(dest, priority)
    }
}

/// Broadcasting, behind a trait for the same reason.
#[allow(async_fn_in_trait)]
pub trait BroadcastTx {
    async fn broadcast(&self, tx: &Transaction) -> anyhow::Result<()>;
}

impl BroadcastTx for quid_ln::esplora::Esplora {
    async fn broadcast(&self, tx: &Transaction) -> anyhow::Result<()> {
        self.client().broadcast(tx).await.context("esplora broadcast")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use quid_hop::migration::{combine_sweep_auths, sign_sweep_auth, SweepAuth, OPERATOR_OWNERS};
    use std::cell::Cell;

    fn secret(i: u8) -> [u8; 32] {
        let mut s = [0u8; 32];
        s[31] = i;
        s
    }

    fn a_bundle(dest: &str) -> Vec<u8> {
        let auth = SweepAuth {
            destination: dest.to_string(),
            deploy_env: DeployEnv::Dev,
            network: LnNetwork::Regtest,
            nonce: [0x5Au8; 32],
        };
        let s1 = sign_sweep_auth(&secret(1), &auth).unwrap();
        let s2 = sign_sweep_auth(&secret(2), &auth).unwrap();
        combine_sweep_auths(auth, vec![s1, s2]).unwrap()
    }

    struct FailingConsumer;
    impl MigrationNonceConsumer for FailingConsumer {
        fn consume(&self, _nonce: [u8; 32]) -> anyhow::Result<()> {
            anyhow::bail!("chain unreachable")
        }
    }

    struct CountingBroadcaster {
        calls: Cell<u32>,
    }
    // The executor is single-threaded in these tests; `Cell` needs this to satisfy the bound.
    unsafe impl Sync for CountingBroadcaster {}
    impl BroadcastTx for CountingBroadcaster {
        async fn broadcast(&self, _tx: &Transaction) -> anyhow::Result<()> {
            self.calls.set(self.calls.get() + 1);
            Ok(())
        }
    }

    struct CountingBuilder {
        calls: Cell<u32>,
    }
    unsafe impl Sync for CountingBuilder {}
    impl BuildSweep for CountingBuilder {
        fn build_sweep(
            &self,
            _dest: &Address,
            _priority: ConfirmationPriority,
        ) -> anyhow::Result<(Transaction, Amount)> {
            self.calls.set(self.calls.get() + 1);
            anyhow::bail!("the test never needs a real drain — reaching here is the failure")
        }
    }

    /// 🔑 THE ORDERING PROPERTY, ASSERTED ON THE REAL FUNCTION: a nonce that cannot be consumed
    /// means the wallet is never asked to build a drain, and nothing is broadcast.
    ///
    /// Measured on the builder's and broadcaster's own call counts, NOT on the returned error —
    /// an executor that swept and only then failed to consume would also return `Err`, so the
    /// error alone cannot tell the two apart. That is precisely the bug this exists to catch.
    #[tokio::test]
    async fn a_failed_nonce_consume_never_reaches_the_wallet() {
        let builder = CountingBuilder { calls: Cell::new(0) };
        let broadcaster = CountingBroadcaster { calls: Cell::new(0) };
        let bundle = a_bundle("bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080");

        let out = execute_sweep(
            &bundle,
            &OPERATOR_OWNERS,
            DeployEnv::Dev,
            LnNetwork::Regtest,
            Network::Regtest,
            &FailingConsumer,
            &builder,
            ConfirmationPriority::Normal,
            &broadcaster,
        )
        .await;

        assert!(out.is_err(), "an unconsumable authorization must abort the sweep");
        assert_eq!(builder.calls.get(), 0, "the wallet must not be asked to build an unspent drain");
        assert_eq!(broadcaster.calls.get(), 0, "nothing may be broadcast");
    }

    /// The whole path succeeds when the authorization is good: consume, build, broadcast — once
    /// each, in that order.
    #[tokio::test]
    async fn a_valid_authorization_consumes_then_broadcasts() {
        struct OkConsumer {
            consumed: Cell<u32>,
        }
        unsafe impl Sync for OkConsumer {}
        impl MigrationNonceConsumer for OkConsumer {
            fn consume(&self, _nonce: [u8; 32]) -> anyhow::Result<()> {
                self.consumed.set(self.consumed.get() + 1);
                Ok(())
            }
        }
        struct RealishBuilder;
        impl BuildSweep for RealishBuilder {
            fn build_sweep(
                &self,
                _dest: &Address,
                _priority: ConfirmationPriority,
            ) -> anyhow::Result<(Transaction, Amount)> {
                Ok((
                    Transaction {
                        version: bitcoin::transaction::Version::TWO,
                        lock_time: bitcoin::absolute::LockTime::ZERO,
                        input: vec![],
                        output: vec![],
                    },
                    Amount::from_sats_u32(250),
                ))
            }
        }

        let consumer = OkConsumer { consumed: Cell::new(0) };
        let broadcaster = CountingBroadcaster { calls: Cell::new(0) };
        let bundle = a_bundle("bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080");

        let out = execute_sweep(
            &bundle,
            &OPERATOR_OWNERS,
            DeployEnv::Dev,
            LnNetwork::Regtest,
            Network::Regtest,
            &consumer,
            &RealishBuilder,
            ConfirmationPriority::Normal,
            &broadcaster,
        )
        .await
        .expect("a threshold-signed, network-correct sweep must execute");

        assert_eq!(consumer.consumed.get(), 1, "the nonce is spent exactly once");
        assert_eq!(broadcaster.calls.get(), 1, "the drain is broadcast exactly once");
        assert_eq!(out.destination.to_string(), "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080");
    }

    /// A destination valid on ANOTHER network is refused BEFORE the nonce is spent — an
    /// authorization wasted on an unusable address would be worse than the refusal.
    #[tokio::test]
    async fn a_mainnet_destination_is_refused_on_regtest() {
        struct SpyConsumer {
            consumed: Cell<u32>,
        }
        unsafe impl Sync for SpyConsumer {}
        impl MigrationNonceConsumer for SpyConsumer {
            fn consume(&self, _nonce: [u8; 32]) -> anyhow::Result<()> {
                self.consumed.set(self.consumed.get() + 1);
                Ok(())
            }
        }
        let consumer = SpyConsumer { consumed: Cell::new(0) };
        let builder = CountingBuilder { calls: Cell::new(0) };
        let broadcaster = CountingBroadcaster { calls: Cell::new(0) };
        let bundle = a_bundle("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"); // mainnet bech32

        let out = execute_sweep(
            &bundle,
            &OPERATOR_OWNERS,
            DeployEnv::Dev,
            LnNetwork::Regtest,
            Network::Regtest,
            &consumer,
            &builder,
            ConfirmationPriority::Normal,
            &broadcaster,
        )
        .await;

        assert!(out.is_err(), "a mainnet address must not be swept to on regtest");
        assert_eq!(consumer.consumed.get(), 0, "and the authorization must NOT be spent");
        assert_eq!(broadcaster.calls.get(), 0);
    }
}
