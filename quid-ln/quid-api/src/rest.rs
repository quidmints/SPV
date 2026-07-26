use std::time::Duration;

// Apparently it takes >15s to open a channel with an external peer.
pub const API_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
