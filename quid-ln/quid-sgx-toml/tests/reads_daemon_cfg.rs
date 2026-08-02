//! Round-trip: the parser reads the daemon crate's enclave entrypoint config.
#[test]
fn reads_quid_bridge_fortanix_sgx_config() {
    let manifest =
        concat!(env!("CARGO_MANIFEST_DIR"), "/../quid-bridge/Cargo.toml");
    let cfg = quid_sgx_toml::read_fortanix_sgx_config(std::path::Path::new(
        manifest,
    ))
    .expect("read fortanix-sgx config from quid-bridge");
    assert!(cfg.debug, "debug should be true");
    // Tracks `quid-bridge/Cargo.toml` (`heap-size = 0x8000_0000  # 2 GiB (TUNE on hardware)`).
    // This asserted 0x4000_0000 (1 GiB) and had NEVER matched the shipped config — the mismatch
    // only surfaced 2026-08-02, the first time this workspace's tests ever ran (quid-cvm is
    // Linux-only, so nothing here had executed on a Mac). The PARSER is fine: the other four
    // assertions pass, so `read_fortanix_sgx_config` reads the manifest correctly. What was stale
    // was this duplicated constant.
    // ⚠️ The config comment says "TUNE on hardware", so this WILL move again. When it does, change
    // it here too — or better, stop duplicating a tunable product value inside a parser test.
    assert_eq!(cfg.heap_size, 0x8000_0000, "heap-size");
    assert_eq!(cfg.stack_size, 0x0080_0000, "stack-size");
    // 6, not 4: `quid-bridge/Cargo.toml` sizes TCS slots for "node + esplora sync + reconnect +
    // rebalancer / bridge" — the `reconnect` task being the persistent hop reconnector (§A.5g).
    // Same story as heap-size: the config moved, this duplicated constant did not.
    assert_eq!(cfg.threads, 6, "threads");
    assert_eq!(cfg.ssaframesize, 1, "ssaframesize");
}
