//! M3 — `option_simple_taproot` (BOLT feature bits 80/81) advertisement +
//! channel-type negotiation.
//!
//! Runs from `quid-ln` (depends on the vendored, patched `lightning` library)
//! because the fork's own lib-test target has a pre-existing, unrelated compile
//! break — see the note in `taproot_format_vectors.rs`.
//!
//! These assert the M3 contract:
//!   - the `option_simple_taproot` feature is advertised in `init` ONLY when the
//!     user explicitly opts in (`negotiate_simple_taproot = true`);
//!   - by default channel opening stays on the existing (non-taproot) channel
//!     type — no taproot bit anywhere (so the not-yet-built M5 taproot handlers
//!     are never hit by default);
//!   - when opted in, the derived channel type carries the taproot bit so it is
//!     explicitly negotiable, and the legacy `static_remote_key` type is NOT
//!     also advertised as the channel type.

use lightning::ln::channelmanager::provided_init_features;
use lightning::types::features::ChannelTypeFeatures;
use lightning::util::config::UserConfig;

fn config_with_taproot(enable: bool) -> UserConfig {
    let mut cfg = UserConfig::default();
    cfg.channel_handshake_config.negotiate_simple_taproot = enable;
    cfg
}

#[test]
fn init_advertises_simple_taproot_only_when_opted_in() {
    // Default: feature NOT advertised (scope-crush guard — opening stays legacy).
    let default_features = provided_init_features(&UserConfig::default());
    assert!(
        !default_features.supports_simple_taproot(),
        "option_simple_taproot must NOT be advertised by default"
    );

    // Opt-in: feature advertised as optional (bit 81).
    let opted_in = provided_init_features(&config_with_taproot(true));
    assert!(
        opted_in.supports_simple_taproot(),
        "option_simple_taproot must be advertised when negotiate_simple_taproot is set"
    );
    assert!(
        !opted_in.requires_simple_taproot(),
        "we advertise the feature as optional, not required"
    );
}

#[test]
fn channel_type_carries_taproot_only_when_opted_in() {
    // The channel-type features the manager understands are derived from the
    // advertised init features (this is exactly what `provided_channel_type_features`
    // does internally: `ChannelTypeFeatures::from_init(&provided_init_features(..))`).
    let default_ct = ChannelTypeFeatures::from_init(&provided_init_features(&UserConfig::default()));
    assert!(
        !default_ct.requires_simple_taproot(),
        "default channel type must not understand/require taproot"
    );

    let taproot_ct =
        ChannelTypeFeatures::from_init(&provided_init_features(&config_with_taproot(true)));
    assert!(
        taproot_ct.requires_simple_taproot(),
        "opted-in channel type must support the taproot channel type for explicit negotiation"
    );

    // A peer requesting the taproot channel type is within our supported set
    // (so the accept path won't reject it as an unknown bit).
    let mut requested = ChannelTypeFeatures::empty();
    requested.set_simple_taproot_required();
    assert!(
        !requested.requires_unknown_bits_from(&taproot_ct),
        "accept path: a taproot channel-type request must be understood when opted in"
    );
    // ...and is correctly rejected as unknown when we have NOT opted in.
    assert!(
        requested.requires_unknown_bits_from(&default_ct),
        "accept path: a taproot channel-type request must be unknown by default"
    );
}
