//! Hop peer manager — a concrete mirror of quid `node/src/peer_manager.rs`
//! (`NodePeerManager`). Wraps the LDK `PeerManager` and impls quid-ln's
//! `PeerManagerTrait` so quid-ln's p2p connection / process-events helpers
//! (`spawn_inbound` / `spawn_process_events_task`) can drive it.

use std::{
    ops::Deref,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use lightning::ln::{
    msgs::SocketAddress,
    peer_handler::{IgnoringMessageHandler, MessageHandler, PeerHandleError},
};

use quid_common::{api::user::NodePk, ln::addr::LxSocketAddress};
use quid_crypto::rng::{Crng, RngExt};
use quid_ln::{
    keys_manager::QuidKeysManager,
    logger::TracingLogger,
    p2p::{spawn_process_events_task, ConnectionTx, PeerManagerTrait},
};
use quid_async_util::{notify, notify_once::NotifyOnce, task::LxTask};
use zeroize::Zeroizing;

use crate::node::{
    HopChainMonitor, HopChannelManager, HopOnionMessenger, HopPeerManagerType,
};

#[derive(Clone)]
pub struct HopPeerManager(Arc<Inner>);

struct Inner {
    peer_manager: HopPeerManagerType,
    process_events_tx: notify::Sender,
}

impl Deref for HopPeerManager {
    type Target = HopPeerManagerType;
    fn deref(&self) -> &Self::Target {
        &self.0.peer_manager
    }
}

impl HopPeerManager {
    pub fn init(
        mut rng: &mut dyn Crng,
        keys_manager: Arc<QuidKeysManager>,
        channel_manager: Arc<HopChannelManager>,
        onion_messenger: Arc<HopOnionMessenger>,
        chain_monitor: Arc<HopChainMonitor>,
        logger: TracingLogger,
        shutdown: NotifyOnce,
    ) -> (Self, LxTask<()>) {
        let lightning_msg_handler = MessageHandler {
            chan_handler: channel_manager,
            // Single-channel hop: no gossip; route via the LP. (Like quid user
            // nodes, which ignore routing-message gossip with the LSP.)
            route_handler: IgnoringMessageHandler {},
            onion_message_handler: onion_messenger,
            // No custom LN messages: the retired lpAuth transport was the only
            // consumer; open/splice/deliver are now on-chain / fleet-initiated.
            custom_message_handler: IgnoringMessageHandler {},
            send_only_message_handler: chain_monitor,
        };

        let current_time: u32 = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("System time is before Unix epoch")
            .as_secs()
            .try_into()
            .expect("It's the year 2038 and you own nothing");

        // Zeroize the ephemeral key material on drop (mirrors quid).
        let ephemeral_bytes = Zeroizing::new(rng.gen_bytes());
        let peer_manager: HopPeerManagerType = HopPeerManagerType::new(
            lightning_msg_handler,
            current_time,
            &ephemeral_bytes,
            logger,
            keys_manager,
        );

        let (process_events_tx, process_events_rx) = notify::channel();
        let me = Self(Arc::new(Inner {
            peer_manager,
            process_events_tx,
        }));

        let process_events_task =
            spawn_process_events_task(me.clone(), process_events_rx, shutdown);

        (me, process_events_task)
    }
}

// quid-ln `PeerManagerTrait` boilerplate (delegates to the inner LDK PeerManager).
impl PeerManagerTrait for HopPeerManager {
    fn is_connected(&self, node_pk: &NodePk) -> bool {
        self.0.peer_manager.peer_by_node_id(&node_pk.0).is_some()
    }

    fn notify_process_events_task(&self) {
        self.0.process_events_tx.send();
    }

    fn new_outbound_connection(
        &self,
        node_pk: &NodePk,
        conn_tx: ConnectionTx,
        addr: Option<LxSocketAddress>,
    ) -> Result<Vec<u8>, PeerHandleError> {
        self.0.peer_manager.new_outbound_connection(
            node_pk.0,
            conn_tx,
            addr.map(SocketAddress::from),
        )
    }

    fn new_inbound_connection(
        &self,
        conn_tx: ConnectionTx,
        addr: Option<LxSocketAddress>,
    ) -> Result<(), PeerHandleError> {
        self.0
            .peer_manager
            .new_inbound_connection(conn_tx, addr.map(SocketAddress::from))
    }

    fn socket_disconnected(&self, conn_tx: &ConnectionTx) {
        self.0.peer_manager.socket_disconnected(conn_tx)
    }

    fn read_event(
        &self,
        conn_tx: &mut ConnectionTx,
        data: &[u8],
    ) -> Result<(), PeerHandleError> {
        self.0.peer_manager.read_event(conn_tx, data)
    }

    fn process_events(&self) {
        self.0.peer_manager.process_events()
    }

    fn write_buffer_space_avail(
        &self,
        conn_tx: &mut ConnectionTx,
    ) -> Result<(), PeerHandleError> {
        self.0.peer_manager.write_buffer_space_avail(conn_tx)
    }
}
