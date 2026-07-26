//! Reproducible SGX signing-key generator.
//!
//! ```bash
//! cargo run -p quid-sgxs-sign --bin gen-signer -- <out.der>
//! ```
//!
//! Samples a fresh 3072-bit RSA (exp=3) SGX signing key, writes its PKCS#8 DER
//! to `<out.der>`, and prints the resulting MRSIGNER (signer measurement).
//!
//! - Dev key: write to `quid-sgxs-sign/data/dev-sgxs-signer.der` and commit it
//!   (it only signs `--debug` enclaves). Set
//!   `Measurement::DEV_SIGNER` to the printed MRSIGNER.
//! - Prod key: generate on an offline / HSM-backed machine, keep the DER OUT of
//!   the repo, and paste the printed MRSIGNER into `Measurement::PROD_SIGNER`.

use anyhow::{Context, bail};
use quid_crypto::rng::SysRng;
use quid_sgxs_sign::KeyPair;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let out = match args.get(1) {
        Some(path) => path,
        None => bail!("usage: gen-signer <out.der>"),
    };

    let mut rng = SysRng::new();
    eprintln!("sampling a 3072-bit RSA (exp=3) key — this takes a few seconds…");
    let key = KeyPair::from_rng(&mut rng);

    let der = key.serialize_pkcs8_der();
    std::fs::write(out, &der)
        .with_context(|| format!("failed to write key DER to {out}"))?;

    let mrsigner = key.signer_measurement();
    println!("wrote PKCS#8 DER signing key -> {out} ({} bytes)", der.len());
    println!("MRSIGNER (signer measurement) = {mrsigner}");
    Ok(())
}
