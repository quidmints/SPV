// TODO(max): All of these modules should be moved to `quid_api[_core]`.

use serde::{Deserialize, Serialize};

/// Authentication and User Signup.
// TODO(max): `error` depends on `auth`
pub mod auth;
/// Revocable clients.
pub mod revocable_clients;
/// `TestEvent`.
pub mod test_event;
/// User ID-like types: `User`, `UserPk`, `NodePk`, `Scid`
pub mod user;

/// A randomly generated id for each mega node.
pub type MegaId = u16;

#[derive(Copy, Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MegaIdStruct {
    pub mega_id: MegaId,
}
