//! Load the SBF ELF the way the runtime does and print WHY it is refused, if it is.
use std::sync::Arc;
use solana_program_runtime::invoke_context::InvokeContext;
use solana_sbpf::{elf::Executable, verifier::RequisiteVerifier};
use solana_syscalls::create_program_runtime_environment;

#[test]
fn elf_loads_and_verifies() {
    let elf = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/target/deploy/p3probe_sbf.so")).unwrap();
    let feature_set = agave_feature_set::FeatureSet::all_enabled();
    let budget = solana_compute_budget::compute_budget::ComputeBudget::new_with_defaults(true);
    let loader = create_program_runtime_environment(&feature_set.runtime_features(), &budget.to_budget(), false, false).unwrap();
    let exe = Executable::<InvokeContext>::load(&elf, (*loader).clone());
    match exe {
        Ok(exe) => match exe.verify::<RequisiteVerifier>() {
            Ok(()) => println!("ELF loads and verifies (sbpf version {:?})", exe.get_sbpf_version()),
            Err(e) => panic!("ELF loaded but failed verification: {e}"),
        },
        Err(e) => panic!("ELF failed to load: {e}"),
    }
}
