# quid-hop fuzz targets

Coverage-guided (libFuzzer) fuzzing for quid-hop's UNTRUSTED-input parsers. This
is the deeper companion to the in-tree `proptest` cases (run by `cargo test -p
quid-hop`); use it for long, mutation-driven panic hunting.

Targets:
- `lp_auth` — `read_lp_auth` (lpAuth custom-message decoder, fed by untrusted LN peers)

## Run

One-time: `cargo install cargo-fuzz` (needs a nightly toolchain).

```bash
cd quid-hop/fuzz
cargo +nightly fuzz run lp_auth
```

This crate is a DETACHED workspace (its own `[workspace]` in Cargo.toml) so it is
not part of `cargo build` / `cargo test` and does not require a sanitizer
toolchain for the normal build. A crash reproducer is written under
`fuzz/artifacts/<target>/`; re-run it with
`cargo +nightly fuzz run <target> fuzz/artifacts/<target>/<crash-file>`.
