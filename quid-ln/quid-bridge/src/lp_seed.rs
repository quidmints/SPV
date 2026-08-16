//! (§M1#2 phase 1c) THE LP'S SEED BACKUP — the one moment it can be taken.
//!
//! # The hole this closes
//!
//! `quid-lp-daemon` provisions its seed through the same `load_or_provision_from_env` path the
//! fleet uses, and that path's default is [`SeedSource::BornInEnclave`][born]: the seed is
//! sampled, sealed to disk, and **never shown to anybody**. For the fleet that is the whole
//! point — the operator is not supposed to see it, because an operator who has seen it is a
//! custody downgrade.
//!
//! For an LP it is the opposite. Phase 1b moved the vault onto the LP's machine precisely so
//! that the LP, not the fleet, holds its half of every channel's 2-of-2. That half now exists in
//! exactly one place: one sealed file, on one disk. **Lose the disk and the LP's half of every
//! channel is gone**, and no amount of fleet cooperation brings it back — that is what "the
//! fleet cannot derive it" means, read from the other side.
//!
//! `quid_hop::seed` already accepts a seed back in (`QUID_SEED`, hex or mnemonic). What was
//! missing is any moment at which the LP is GIVEN something to put there. There is exactly one
//! such moment — the boot on which the seed is born — and this module is it.
//!
//! # Why the export is gated on the backend rather than on a flag
//!
//! Writing a plaintext mnemonic next to a sealed seed is either free or catastrophic, and which
//! one it is depends on whether the seal means anything on that machine:
//!
//! * **No TEE** (`Backend::None`, the ordinary LP laptop or VPS). `platform.rs` says the
//!   off-TEE seal "provides no security whatsoever" and `machine_id()` is `MachineId::MOCK`, so
//!   anyone who can read the data directory can already unseal the seed. The mnemonic file adds
//!   **no exposure that did not already exist**, and it adds the only recovery path there is.
//! * **A custody-ready TEE** (SGX / SEV-SNP). The seal is hardware-bound and the host genuinely
//!   cannot read it. Exporting the plaintext would **defeat the seal on purpose** — it hands the
//!   host the secret the enclave exists to keep. Those deployments recover through attested
//!   provisioning (`provision_seed`), not through a file.
//!
//! So the discriminator is [`Backend::custody_ready`], the same predicate
//! `require_backend_for_role` uses. It is a property of the machine, not a knob: an operator
//! cannot turn the export on for a TEE, and cannot turn it off for a box that has no other
//! recovery path.
//!
//! # ⚠️ What the mnemonic does NOT restore — state this before anyone assumes otherwise
//!
//! The seed is the root of the LP's **keys**: the BDK wallet, the node key, the channel key
//! material, the payout script `BTCChannels._lpFinalBalance` measures. It is **not** the channel
//! **monitors**, which are what a node needs in order to know which commitment is current and to
//! respond within a CSV window. Those live beside the sealed seed — `lp-store.json` and the
//! `vault/` subdirectory — in the SAME data directory, so a lost disk loses both, and restoring
//! from words alone gives back a node that holds the right keys and knows nothing about its
//! channels.
//!
//! ⇒ **This backup bounds the damage; it does not make disk loss a non-event.** The seed is the
//! part that is irreplaceable (nothing else in the system can regenerate it); the monitors are
//! the part that ordinary backup of the data directory covers, and an LP should be doing that
//! too. The escape that is supposed to survive a dead LP entirely is §E165's pre-signed exit
//! ladder — but that is armed at open and, until the on-chain arming lands, is not public, so it
//! is not yet a substitute for either. See §M1#2-PHASE-1C in the queue.
//!
//! ⚠️ **AND IT NEVER FIRES TWICE.** The file is created with `create_new`, so an existing backup
//! is an error rather than an overwrite, and the decision requires that no sealed seed existed
//! before this boot. A backup that silently rewrote itself would be worse than none: the LP's
//! written-down words and the file on disk could disagree with nothing to say which is live.
//!
//! [born]: quid_hop::seed::SeedSource::BornInEnclave

use std::path::{Path, PathBuf};

use anyhow::Context;
use quid_common::root_seed::RootSeed;
use quid_common::seed_shares;
use quid_crypto::rng::Crng;
use quid_enclave::enclave::{Backend, HostingRole};

/// Filename of the one-time plaintext mnemonic backup, inside the LP's data dir.
///
/// Named for what it is rather than for where it lives, because the first thing an operator does
/// with it is copy it somewhere else.
pub const LP_SEED_BACKUP_FILENAME: &str = "SEED-BACKUP-WRITE-THIS-DOWN.txt";

/// Whether this boot is the one that can hand the operator their seed, and if not, why not.
///
/// Every `Skip` is a REASON, not a failure — each names a different thing that is already true,
/// and the caller logs it rather than treating it as an error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackupDecision {
    /// The seed was born on this boot, on a machine whose seal protects nothing, and the
    /// operator has no other copy. Write it.
    Write,
    /// As [`Write`][Self::Write], but the node serves a FAMILY, so the seed is split K-of-N
    /// instead of written down whole. Same trigger, different artefact: a family already has
    /// several people, and handing all of them the same sheet of paper would multiply the
    /// theft surface by N while leaving the loss surface at one.
    WriteShares { threshold: u8, count: u8 },
    /// A sealed seed already existed, so nothing was born here and any backup was taken on the
    /// boot that did create it.
    SkipAlreadyProvisioned,
    /// The operator supplied the seed themselves (`QUID_SEED`), so they demonstrably already
    /// hold it. Writing it again would only add a copy.
    SkipOperatorSuppliedSeed,
    /// A custody-ready TEE seals it in hardware; exporting the plaintext would defeat that.
    SkipCustodyReadyBackend,
}

/// Decide whether to take the one-time backup. Pure, so the ORDER of the reasons is assertable.
///
/// The order matters and is not arbitrary: "nothing was born" comes first because it is a fact
/// about this boot, "the operator already has it" second because it is a fact about the seed,
/// and the backend check last because it is the only one that is a judgement about exposure.
/// Read the other way round, a re-boot on a TEE would report the TEE as the reason no backup was
/// taken, when the real reason is that there was nothing new to back up.
pub fn decide(
    sealed_seed_existed_before: bool,
    operator_supplied_seed: bool,
    backend: Backend,
    role: HostingRole,
    split: (u8, u8),
) -> BackupDecision {
    if sealed_seed_existed_before {
        BackupDecision::SkipAlreadyProvisioned
    } else if operator_supplied_seed {
        BackupDecision::SkipOperatorSuppliedSeed
    } else if backend.custody_ready() {
        BackupDecision::SkipCustodyReadyBackend
    } else if matches!(role, HostingRole::Family) {
        // ⚠️ KEYED ON `Family` ALONE, not on a separate opt-in. A node that declared it serves a
        // group HAS a group, which is the only thing sharding needs — asking the operator to
        // turn it on again would just be a way for the default to be wrong.
        BackupDecision::WriteShares { threshold: split.0, count: split.1 }
    } else {
        BackupDecision::Write
    }
}

/// Write the 24-word mnemonic for `seed` into `data_dir`, refusing to clobber an existing one.
///
/// Returns the path so the caller can name it in a log line. The words themselves are never
/// logged: a data directory is one machine's problem, whereas logs get shipped, aggregated and
/// retained by whatever the operator points them at.
pub fn write_mnemonic_backup(
    data_dir: &Path,
    seed: &RootSeed,
) -> anyhow::Result<PathBuf> {
    use std::io::Write;

    let path = data_dir.join(LP_SEED_BACKUP_FILENAME);

    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    // Owner-only from the moment it exists. `create_new` + `mode` is the pair that matters:
    // creating first and chmod-ing after leaves a window in which the file is world-readable.
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }

    let mut f = opts.open(&path).with_context(|| {
        format!(
            "refusing to write the seed backup at {}: it already exists (a seed was born on \
             this boot, so an existing backup belongs to a DIFFERENT seed — move it aside \
             deliberately rather than letting this overwrite it)",
            path.display(),
        )
    })?;

    // The header is part of the artefact. Whoever finds this file later — possibly the operator,
    // possibly not — needs to know in one line what it is and what to do about it.
    writeln!(
        f,
        "# QuidMint LP seed backup.\n\
         #\n\
         # These 24 words ARE your half of every Lightning channel this node opens.\n\
         # Anyone who reads them can spend your channel funds. Nobody else has a copy:\n\
         # not the fleet, not QuidMint, nobody.\n\
         #\n\
         # 1. Write them on paper. 2. Store the paper somewhere the disk is not.\n\
         # 3. Delete this file.\n\
         #\n\
         # To restore onto a new machine: set QUID_SEED to this sentence and boot\n\
         # quid-lp-daemon with an EMPTY data directory.\n"
    )
    .context("write seed backup header")?;
    writeln!(f, "{}", seed.to_mnemonic()).context("write seed backup mnemonic")?;
    f.sync_all().context("fsync seed backup")?;

    Ok(path)
}

/// Filename of share `i`. The threshold is in the name so an operator holding one file knows how
/// many they need without opening it; **the count is not**, because a filename gets photographed
/// alongside the share and the set size is the one thing the artefact deliberately withholds.
pub fn share_filename(index: u8, threshold: u8) -> String {
    format!("SEED-SHARE-{index}-NEED-{threshold}.txt")
}

/// Split `seed` K-of-N and write one file per share, each 0600 and each refusing to clobber.
///
/// Returns the paths in share order. **The files are written into the SAME data directory**,
/// which is not where they may stay: a family plan whose N shares all sit on one disk has the
/// original single point of failure back, plus N copies of the risk. That is why the caller logs
/// a distribution instruction rather than treating this as done.
pub fn write_seed_shares<R: Crng>(
    data_dir: &Path,
    seed: &RootSeed,
    threshold: u8,
    count: u8,
    rng: &mut R,
) -> anyhow::Result<Vec<PathBuf>> {
    use std::io::Write;

    let shares = seed_shares::split(seed, threshold, count, rng)
        .context("split the seed into family shares")?;

    let mut paths = Vec::with_capacity(shares.len());
    for share in &shares {
        let path = data_dir.join(share_filename(share.index(), share.threshold()));

        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f = opts.open(&path).with_context(|| {
            format!(
                "refusing to write share {} at {}: it already exists (a seed was born on this \
                 boot, so an existing share belongs to a DIFFERENT split — move it aside \
                 deliberately rather than letting this overwrite it)",
                share.index(),
                path.display(),
            )
        })?;

        writeln!(
            f,
            "# QuidMint family seed share {} — {} of these recover the node.\n\
             #\n\
             # This share ALONE reveals nothing: fewer than {} of them are worthless, so a\n\
             # single lost or stolen share is not a loss and not a theft.\n\
             # But {} holders acting together CAN reconstruct the seed and spend the node's\n\
             # channel funds. Give them to people you would already trust with the whole thing.\n\
             #\n\
             # 1. Give this to exactly ONE holder. 2. Do not keep a copy.\n\
             # 3. Delete this file once it has been handed over.\n\
             #\n\
             # To recover: collect any {} shares, set QUID_SEED to their lines pasted together,\n\
             # and boot with an EMPTY data directory. Whoever collects them never sees the seed.\n",
            share.index(),
            share.threshold(),
            share.threshold(),
            share.threshold(),
            share.threshold(),
        )
        .context("write share header")?;
        writeln!(f, "{share}").context("write share line")?;
        f.sync_all().context("fsync share")?;

        paths.push(path);
    }
    Ok(paths)
}

#[cfg(test)]
mod test {
    // ChaCha20 rather than `FastRng`: same determinism from a hardcoded seed, but a REAL
    // CSPRNG, so it satisfies `RootSeed::from_rng`'s `Crng` bound without enabling
    // quid-crypto's `test-utils` in the shipping graph. See the dev-dependency note.
    use rand_chacha::rand_core::SeedableRng;
    use rand_chacha::ChaCha20Rng;
    use secrecy::ExposeSecret;

    use super::*;

    const SOLO: HostingRole = HostingRole::Individual;
    const SPLIT: (u8, u8) = (seed_shares::DEFAULT_THRESHOLD, seed_shares::DEFAULT_COUNT);

    #[test]
    fn a_fresh_seed_on_an_ordinary_box_is_backed_up() {
        assert_eq!(decide(false, false, Backend::None, SOLO, SPLIT), BackupDecision::Write);
    }

    /// Each skip must be reported for the RIGHT reason, which is what pins the order. A reboot
    /// on an SGX box has three of the four conditions true at once; the honest answer is
    /// "nothing was born", not "the TEE holds it".
    #[test]
    fn the_reasons_are_reported_in_precedence_order() {
        assert_eq!(
            decide(true, true, Backend::Sgx, SOLO, SPLIT),
            BackupDecision::SkipAlreadyProvisioned,
        );
        assert_eq!(
            decide(false, true, Backend::Sgx, SOLO, SPLIT),
            BackupDecision::SkipOperatorSuppliedSeed,
        );
        assert_eq!(
            decide(false, false, Backend::Sgx, SOLO, SPLIT),
            BackupDecision::SkipCustodyReadyBackend,
        );
    }

    /// ⚠️ THE CASE THE BACKEND GATE EXISTS FOR, ASSERTED BOTH WAYS. A TEE whose sealing is
    /// detected but NOT yet wired (`Tdx` / `Nitro`) is not custody-ready, so it falls back to the
    /// mock seal — and a node whose seal protects nothing needs the backup exactly as much as a
    /// bare laptop does. If `custody_ready` ever starts returning true for these, this test says
    /// so instead of the export silently disappearing on those platforms.
    #[test]
    fn a_detected_but_unwired_tee_still_gets_a_backup() {
        for b in [Backend::Tdx, Backend::Nitro, Backend::None] {
            assert_eq!(
                decide(false, false, b, SOLO, SPLIT),
                BackupDecision::Write,
                "{} seals with the mock, so its seed needs a backup",
                b.as_str(),
            );
        }
        for b in [Backend::Sgx, Backend::SevSnp] {
            assert_eq!(
                decide(false, false, b, SOLO, SPLIT),
                BackupDecision::SkipCustodyReadyBackend,
                "{} seals in hardware, so exporting would defeat it",
                b.as_str(),
            );
        }
    }

    /// The round trip end to end: what lands on disk must be readable back into the same seed by
    /// the same parser `QUID_SEED` uses. Asserting on the FILE rather than on `to_mnemonic()`
    /// is the point — a header line or a stray newline that broke parsing would be invisible to
    /// a test that only checked the API.
    #[test]
    fn the_written_file_restores_the_same_seed() {
        let dir = tempfile::tempdir().unwrap();
        let mut rng = ChaCha20Rng::seed_from_u64(0xB17C0);
        let seed = RootSeed::from_rng(&mut rng);

        let path = write_mnemonic_backup(dir.path(), &seed).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();

        let words = text
            .lines()
            .find(|l| !l.starts_with('#') && !l.trim().is_empty())
            .expect("the file must carry exactly one non-comment line");
        let restored = RootSeed::from_mnemonic_str(words).unwrap();
        assert_eq!(restored.expose_secret(), seed.expose_secret());
    }

    /// A second call must FAIL rather than overwrite. The failure mode this prevents is quiet:
    /// two seeds, one file, and no way to tell which sentence the live node answers to.
    #[test]
    fn a_second_write_refuses_rather_than_clobbering() {
        let dir = tempfile::tempdir().unwrap();
        let mut rng = ChaCha20Rng::seed_from_u64(1);
        let first = RootSeed::from_rng(&mut rng);
        let second = RootSeed::from_rng(&mut rng);

        let path = write_mnemonic_backup(dir.path(), &first).unwrap();
        write_mnemonic_backup(dir.path(), &second)
            .expect_err("an existing backup must not be overwritten");

        let text = std::fs::read_to_string(&path).unwrap();
        let words = text
            .lines()
            .find(|l| !l.starts_with('#') && !l.trim().is_empty())
            .unwrap();
        assert_eq!(
            RootSeed::from_mnemonic_str(words).unwrap().expose_secret(),
            first.expose_secret(),
            "the ORIGINAL seed must still be the one on disk",
        );
    }

    /// A family gets SHARES on the same trigger a solo LP gets a whole mnemonic — the role is
    /// the only difference, and it is not a separate opt-in.
    #[test]
    fn a_family_gets_shares_where_a_solo_lp_gets_the_whole_mnemonic() {
        assert_eq!(
            decide(false, false, Backend::None, HostingRole::Family, (2, 3)),
            BackupDecision::WriteShares { threshold: 2, count: 3 },
        );
        assert_eq!(
            decide(false, false, Backend::None, HostingRole::Individual, (2, 3)),
            BackupDecision::Write,
        );
        // The skips still outrank the role: a family on a TEE exports nothing either.
        assert_eq!(
            decide(false, false, Backend::Sgx, HostingRole::Family, (2, 3)),
            BackupDecision::SkipCustodyReadyBackend,
        );
    }

    /// The family artefact end to end: N files land, any K of them restore the seed through the
    /// SAME parser `QUID_SEED` uses, and — the point of the whole exercise — K−1 do not.
    #[test]
    fn any_threshold_of_the_written_shares_restores_the_seed() {
        let dir = tempfile::tempdir().unwrap();
        let mut rng = ChaCha20Rng::seed_from_u64(0xFA1);
        let seed = RootSeed::from_rng(&mut rng);

        let paths = write_seed_shares(dir.path(), &seed, 2, 3, &mut rng).unwrap();
        assert_eq!(paths.len(), 3);

        for (i, j) in [(0, 1), (0, 2), (1, 2)] {
            let pasted = format!(
                "{}\n{}",
                std::fs::read_to_string(&paths[i]).unwrap(),
                std::fs::read_to_string(&paths[j]).unwrap(),
            );
            let shares = seed_shares::parse_share_set(&pasted).unwrap();
            assert_eq!(
                seed_shares::combine(&shares).unwrap().expose_secret(),
                seed.expose_secret(),
                "shares {i}+{j} did not restore the seed",
            );
        }

        let one = std::fs::read_to_string(&paths[0]).unwrap();
        let shares = seed_shares::parse_share_set(&one).unwrap();
        seed_shares::combine(&shares)
            .expect_err("one share of a 2-of-3 must not reconstruct anything");
    }

    /// ⚠️ THE FILENAME IS PART OF THE DISCLOSURE SURFACE — it gets photographed with the share.
    /// It may say how many are NEEDED, because a holder must know that; it must not say how many
    /// EXIST, which is the set size the share body deliberately withholds.
    #[test]
    fn a_share_filename_names_the_threshold_and_not_the_set_size() {
        let dir = tempfile::tempdir().unwrap();
        let mut rng = ChaCha20Rng::seed_from_u64(5);
        let seed = RootSeed::from_rng(&mut rng);

        let small = tempfile::tempdir().unwrap();
        let paths_3 = write_seed_shares(small.path(), &seed, 2, 3, &mut rng).unwrap();
        let paths_9 = write_seed_shares(dir.path(), &seed, 2, 9, &mut rng).unwrap();

        let name = |p: &PathBuf| p.file_name().unwrap().to_string_lossy().into_owned();
        // The first three shares of a 2-of-3 and a 2-of-9 are named identically.
        for k in 0..3 {
            assert_eq!(name(&paths_3[k]), name(&paths_9[k]), "filenames disclose N");
        }
        assert!(name(&paths_3[0]).contains("NEED-2"), "{}", name(&paths_3[0]));
    }

    /// The file holds a spendable secret; it must not be readable by other users on the box.
    #[cfg(unix)]
    #[test]
    fn the_backup_is_owner_readable_only() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let mut rng = ChaCha20Rng::seed_from_u64(2);
        let path =
            write_mnemonic_backup(dir.path(), &RootSeed::from_rng(&mut rng)).unwrap();

        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "seed backup mode was {:o}", mode & 0o777);
    }
}
