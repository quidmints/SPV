//! Type aliases which prevent most LDK generics from infecting Quid APIs.

use std::sync::Arc;

use lightning::{
    chain::{chainmonitor::ChainMonitor, channelmonitor::ChannelMonitor},
    ln::{
        channelmanager::ChannelManager,
        peer_handler::{IgnoringMessageHandler, PeerManager},
    },
    onion_message::messenger::OnionMessenger,
    routing::{
        gossip::NetworkGraph, scoring::ProbabilisticScorer, utxo::UtxoLookup,
    },
};
use lightning_transaction_sync::EsploraSyncClient;

use crate::{
    esplora::FeeEstimates, keys_manager::QuidKeysManager,
    logger::TracingLogger, message_router::QuidMessageRouter,
    p2p::ConnectionTx, route::QuidRouter, tx_broadcaster::TxBroadcaster,
    validating_signer::ValidatingChannelSigner,
};

// --- Partial aliases --- //
// - All are prefixed with "Quid" and contain at least one more generic.
// - The last generic is filled by an alias in the consuming crate.
// - Lexicographically sorted.

pub type ChainMonitorType<PERSISTER> = ChainMonitor<
    SignerType,
    Arc<EsploraSyncClientType>,
    BroadcasterType,
    Arc<FeeEstimatorType>,
    TracingLogger,
    PERSISTER,
    Arc<QuidKeysManager>,
>;

pub type ChannelManagerType<PERSISTER> = ChannelManager<
    Arc<ChainMonitorType<PERSISTER>>,
    BroadcasterType,
    Arc<QuidKeysManager>,
    Arc<QuidKeysManager>,
    Arc<QuidKeysManager>,
    Arc<FeeEstimatorType>,
    Arc<RouterType>,
    Arc<MessageRouterType>,
    TracingLogger,
>;

pub type OnionMessengerType<CHANNEL_MANAGER> = OnionMessenger<
    Arc<QuidKeysManager>,
    Arc<QuidKeysManager>,
    TracingLogger,
    CHANNEL_MANAGER,
    Arc<MessageRouterType>,
    // OffersMessageHandler
    CHANNEL_MANAGER,
    // AsyncPaymentsMessageHandler
    IgnoringMessageHandler,
    // DNSResolverMessageHandler
    // TODO(phlip9): impl for BIP 353?
    IgnoringMessageHandler,
    // CustomOnionMessageHandler
    IgnoringMessageHandler,
>;

pub type PeerManagerType<
    CHANNEL_MANAGER,
    RMH,
    PERSISTER,
    // CustomMessageHandler — defaults to IgnoringMessageHandler so existing
    // 3-arg users (and the QuidPeerManager trait bounds) are unaffected; the hop
    // overrides it to carry its lpAuth custom messages.
    CMH = IgnoringMessageHandler,
> = PeerManager<
    ConnectionTx,
    CHANNEL_MANAGER,
    // RoutingMessageHandler
    RMH,
    // OnionMessageHandler
    Arc<OnionMessengerType<CHANNEL_MANAGER>>,
    TracingLogger,
    // CustomMessageHandler
    CMH,
    Arc<QuidKeysManager>,
    // SendOnlyMessageHandler
    Arc<ChainMonitorType<PERSISTER>>,
>;

// --- Full type aliases --- //
// - Fully concrete.
// - Lexicographically sorted.

pub type BroadcasterType = TxBroadcaster;

pub type ChannelMonitorType = ChannelMonitor<SignerType>;

pub type EsploraSyncClientType = EsploraSyncClient<TracingLogger>;

pub type FeeEstimatorType = FeeEstimates;

pub type MessageRouterType = QuidMessageRouter;

pub type NetworkGraphType = NetworkGraph<TracingLogger>;

pub type ProbabilisticScorerType =
    ProbabilisticScorer<Arc<NetworkGraphType>, TracingLogger>;

pub type RouterType = QuidRouter;

/// The node's production channel signer: the self-host validating signer that
/// wraps an in-process `InMemorySigner` with QU!D's two defense-in-depth policy
/// checks (anti-revoked-reuse + closing-payout-script lock). See
/// [`crate::validating_signer`].
pub type SignerType = ValidatingChannelSigner;

// TODO(max): Revisit - why are we using dynamic dispatch here?
pub type UtxoLookupType = dyn UtxoLookup + Send + Sync;
