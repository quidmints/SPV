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
    assert_eq!(cfg.heap_size, 0x4000_0000, "heap-size");
    assert_eq!(cfg.stack_size, 0x0080_0000, "stack-size");
    assert_eq!(cfg.threads, 4, "threads");
    assert_eq!(cfg.ssaframesize, 1, "ssaframesize");
}
