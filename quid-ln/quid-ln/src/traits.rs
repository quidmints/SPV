use std::ops::Deref;

use quid_api::vfs::Vfs;
use quid_common::api::user::NodePk;
use lightning::{
    chain::chainmonitor::Persist,
    ln::msgs::RoutingMessageHandler,
    ln::peer_handler::{CustomMessageHandler, IgnoringMessageHandler},
};

use crate::{
    alias::{
        ChainMonitorType, ChannelManagerType, PeerManagerType,
        SignerType,
    },
    event::EventHandlerMethods,
    persister::PersisterMethods,
};

/// A 'trait alias' defining all the requirements of a Quid persister.
pub trait QuidPersister:
    Clone
    + Send
    + Sync
    + 'static
    + Deref<
        Target: PersisterMethods + Vfs + Persist<SignerType> + Send + Sync,
    >
{
}

impl<PS> QuidPersister for PS where
    PS: Clone
        + Send
        + Sync
        + 'static
        + Deref<
            Target: PersisterMethods
                        + Vfs
                        + Persist<SignerType>
                        + Send
                        + Sync,
        >
{
}

/// A 'trait alias' defining all the requirements of a Quid channel manager.
pub trait QuidChannelManager<PS: QuidPersister>:
    Clone + Send + Sync + 'static + Deref<Target = ChannelManagerType<PS>>
{
}

impl<CM, PS> QuidChannelManager<PS> for CM
where
    CM: Clone
        + Send
        + Sync
        + 'static
        + Deref<Target = ChannelManagerType<PS>>,
    PS: QuidPersister,
{
}

/// A 'trait alias' defining all the requirements of a Quid chain monitor.
pub trait QuidChainMonitor<PS: QuidPersister>:
    Send + Sync + 'static + Deref<Target = ChainMonitorType<PS>>
{
}

impl<CM, PS> QuidChainMonitor<PS> for CM
where
    CM: Send + Sync + 'static + Deref<Target = ChainMonitorType<PS>>,
    PS: QuidPersister,
{
}

/// A 'trait alias' defining all the requirements of a Quid peer manager. `CMH`
/// is the custom-message handler; it defaults to `IgnoringMessageHandler` so
/// existing 3-arg bounds are unchanged, but the hop overrides it to carry its
/// lpAuth custom messages.
pub trait QuidPeerManager<CM, PS, RMH, CMH = IgnoringMessageHandler>:
    Clone + Send + Sync + 'static + Deref<Target = PeerManagerType<CM, RMH, PS, CMH>>
where
    CM: QuidChannelManager<PS>,
    PS: QuidPersister,
    // TODO(max): Tried to create a `QuidRoutingMessageHandler` alias for these
    // bounds so the don't propagate everywhere, but couldn't get it to work.
    RMH: Deref,
    RMH::Target: RoutingMessageHandler,
    CMH: Deref,
    CMH::Target: CustomMessageHandler,
{
    /// Returns `true` if we're connected to a peer with `node_pk`.
    fn is_connected(&self, node_pk: &NodePk) -> bool {
        // TODO(max): This LDK fn is O(n) in the # of peers...
        self.peer_by_node_id(&node_pk.0).is_some()
    }
}

impl<PM, CM, PS, RMH, CMH> QuidPeerManager<CM, PS, RMH, CMH> for PM
where
    PM: Clone
        + Send
        + Sync
        + 'static
        + Deref<Target = PeerManagerType<CM, RMH, PS, CMH>>,
    CM: QuidChannelManager<PS>,
    PS: QuidPersister,
    RMH: Deref,
    RMH::Target: RoutingMessageHandler,
    CMH: Deref,
    CMH::Target: CustomMessageHandler,
{
}

/// A 'trait alias' defining all the requirements of a Quid event handler.
pub trait QuidEventHandler:
    EventHandlerMethods + Clone + Send + Sync + 'static
{
}

impl<T: EventHandlerMethods + Clone + Send + Sync + 'static>
    QuidEventHandler for T
{
}
