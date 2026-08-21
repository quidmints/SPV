//! K-of-N seed shares for a family plan — recovery without a custodian and without a roster.
//!
//! # What this is for
//!
//! §M1#2 phase 1c gave an individual LP a single written-down mnemonic. That is the right
//! artefact for one operator and the wrong one for a family: it concentrates the whole secret in
//! one place, so whoever holds that sheet of paper holds every channel, and losing it loses
//! everything. A family plan (`HostingRole::Family`) has several people already; splitting the
//! seed across them removes both the single point of loss and the single point of theft.
//!
//! Recovery reconstructs the seed from any K shares, and — because the import path accepts the
//! shares directly — **no member ever handles the whole seed**, not even the one who collects
//! them. That is the property sharding buys that a shared mnemonic cannot.
//!
//! # Why not the msig this repo already has
//!
//! `quid_hop::migration` verifies k-of-n EIP-712 owner signatures, and its header says the
//! primitive was meant to serve family plans too: *"operator and family msigs verify identically
//! … just a different pinned Safe"*. It is built, tested, and needs no new dependency. It still
//! cannot do this job, for a reason worth writing down so nobody re-derives it:
//!
//! 🔴 **MIGRATION REQUIRES THE OLD ENCLAVE TO BE RUNNING.** It is the *old* enclave that exports
//! the seed to the new one over the attested channel. That makes it an UPGRADE path — new
//! MRENCLAVE, same machine, node alive. If the disk is gone there is no old enclave to export
//! from, and the authorization is authorization to do nothing. **Loss and upgrade are different
//! failures and they need different mechanisms.**
//!
//! ⚠️ It is also the route that would cost the anonymity: a Safe publishes its owner set, so the
//! family's addresses are co-listed on-chain and linked to each other for anyone who looks. (The
//! interim mode verifies against a sealed-config snapshot rather than an RPC read, so that much
//! could stay local — but the target design is an on-chain owner-set proof.)
//!
//! # How this stays anonymous
//!
//! Nothing about the family is written anywhere but the shares themselves, and a share carries
//! **an index, a threshold, and 32 bytes of field element**. There is no roster, no coordinator,
//! no on-chain artefact, no key exchange, and no record of who received which share — the
//! operator hands them out off-range and that is the whole protocol. Two shares cannot be
//! recognised as belonging to the same family without K of them, and even then what they yield is
//! a seed, not a membership list. **Set size is not published either**: `count` is not recorded
//! in a share, only `threshold`, which is what recovery needs.
//!
//! # ⚠️ The trade, stated plainly
//!
//! K members who collude can reconstruct the seed and spend the node's channel half. Sharding
//! does not remove trust, it SPREADS it: it converts "one person can steal, one accident can
//! lose" into "K can steal, N−K+1 must be lost". Choose K above half for that reason, and choose
//! the holders as people the operator would already trust with the paper.
//!

use std::{fmt, str::FromStr};

use anyhow::{Context, bail, ensure};
use quid_crypto::rng::Crng;
use secrecy::{ExposeSecret, Secret, Zeroize};

use crate::root_seed::RootSeed;

/// The default split. Deliberately the same shape as `quid_hop::migration::MIGRATION_THRESHOLD`'s 2-of-3 operator
/// quorum, so the two thresholds in this system are not gratuitously different numbers.
///
pub const DEFAULT_THRESHOLD: u8 = 2;
/// See [`DEFAULT_THRESHOLD`].
pub const DEFAULT_COUNT: u8 = 3;

/// Tag opening every share line, so a share is self-identifying in a text file or a photo — and
/// so the seed-import path can tell a share set from a plain mnemonic without guessing.
pub const SHARE_TAG: &str = "quid-seed-share";

/// Domain-separated commitment to the reconstructed seed, carried in every share.
const COMMITMENT_LABEL: &[u8] = b"QUID-REALM::SeedShare::commitment";
/// Bytes of that commitment kept in the share line.
const COMMITMENT_LEN: usize = 4;

/// One share of a split [`RootSeed`].
///
/// The 32-byte payload is rendered as a BIP39 sentence, which is not decoration: it is the same
/// transcription-checked encoding the whole-seed backup uses, so a family member copying a share
/// by hand gets the same protection against a slipped word, and the same recovery instructions
/// apply to both artefacts.
pub struct SeedShare {
    /// Shamir's x-coordinate. Not secret, and not an identity — it says which POINT this is, not
    /// who holds it.
    index: u8,
    /// How many shares reconstruct the seed. Carried per-share because recovery needs it and
    /// because it lets [`combine`] REFUSE an under-sized set rather than interpolate one.
    threshold: u8,
    /// First [`COMMITMENT_LEN`] bytes of a domain-separated hash of the seed. See [`combine`].
    commitment: [u8; COMMITMENT_LEN],
    /// The Shamir y-values: 32 field elements, one per seed byte.
    payload: Secret<[u8; RootSeed::LENGTH]>,
}

impl SeedShare {
    /// Which point this is. Shares are handed out off-range, so this is the only handle an
    /// operator has for saying "you have number 2" — it names nothing about the holder.
    pub fn index(&self) -> u8 {
        self.index
    }

    /// How many shares [`combine`] will require.
    pub fn threshold(&self) -> u8 {
        self.threshold
    }
}

fn commit_to(seed: &RootSeed) -> [u8; COMMITMENT_LEN] {
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    ctx.update(COMMITMENT_LABEL);
    ctx.update(seed.expose_secret());
    let digest = ctx.finish();
    let mut out = [0u8; COMMITMENT_LEN];
    out.copy_from_slice(&digest.as_ref()[..COMMITMENT_LEN]);
    out
}

fn payload_to_words(payload: &[u8; RootSeed::LENGTH]) -> bip39::Mnemonic {
    bip39::Mnemonic::from_entropy_in(bip39::Language::English, payload)
        .expect("always succeeds for 256 bits")
}

/// Split `seed` into `count` shares, any `threshold` of which reconstruct it.
///
/// The RNG is supplied rather than taken from the crate, so the entropy source is the same
/// [`Crng`] the seed itself came from — inside an enclave
/// that matters, and it is also what makes the tests deterministic.
pub fn split<R: Crng>(
    seed: &RootSeed,
    threshold: u8,
    count: u8,
    rng: &mut R,
) -> anyhow::Result<Vec<SeedShare>> {
    // A 1-of-N "split" is N copies of the secret wearing a costume, and a threshold above the
    // share count can never be met. Both are configuration mistakes that would otherwise be
    // discovered at recovery time, which is the worst possible moment.
    ensure!(threshold >= 2, "a seed split needs a threshold of at least 2 (got {threshold})");
    ensure!(
        count >= threshold,
        "cannot make {count} shares with a threshold of {threshold} — the seed would be \
         unrecoverable from the moment it is split",
    );

    let commitment = commit_to(seed);
    let dealer = sharks::Sharks(threshold);

    let mut out = Vec::with_capacity(count as usize);
    for share in dealer.dealer_rng(seed.expose_secret(), rng).take(count as usize) {
        let mut bytes: Vec<u8> = Vec::from(&share);
        // sharks lays a share out as `x ‖ y…`, so a 32-byte secret yields 33 bytes.
        ensure!(
            bytes.len() == RootSeed::LENGTH + 1,
            "unexpected share width {} from the dealer",
            bytes.len(),
        );
        let mut payload = [0u8; RootSeed::LENGTH];
        payload.copy_from_slice(&bytes[1..]);
        out.push(SeedShare {
            index: bytes[0],
            threshold,
            commitment,
            payload: Secret::new(payload),
        });
        bytes.zeroize();
    }
    Ok(out)
}

/// Reconstruct the seed from `shares`.
///
/// 🔑 **THREE REFUSALS, AND EACH REPLACES A SILENT WRONG ANSWER.** Lagrange interpolation is
/// total: give it too few points, or points from two different splits, or the same point twice,
/// and it returns a perfectly well-formed 32 bytes that are not the seed. A node booted on those
/// bytes looks healthy and holds nothing, which is indistinguishable from "my channels are gone".
///
/// So: the shares must agree on a threshold, there must be at least that many DISTINCT indices,
/// and the reconstruction must match the commitment every share carries. The commitment is 4
/// bytes of a domain-separated SHA-256 of the seed — enough to make a wrong reconstruction
/// essentially certain to be caught, and far too little to help anyone attack a 256-bit secret.
pub fn combine(shares: &[SeedShare]) -> anyhow::Result<RootSeed> {
    let first = shares.first().context("no shares supplied")?;
    let threshold = first.threshold;

    ensure!(
        shares.iter().all(|s| s.threshold == threshold),
        "these shares disagree about the threshold, so they are not from one split",
    );
    ensure!(
        shares.iter().all(|s| s.commitment == first.commitment),
        "these shares commit to different seeds — they are from different splits, and mixing \
         them would reconstruct neither",
    );

    let mut indices: Vec<u8> = shares.iter().map(|s| s.index).collect();
    indices.sort_unstable();
    let distinct = {
        let mut d = indices.clone();
        d.dedup();
        d.len()
    };
    ensure!(
        distinct == shares.len(),
        "duplicate share index — {} shares were supplied but only {distinct} are distinct \
         points, and a repeat adds no information",
        shares.len(),
    );
    ensure!(
        distinct >= threshold as usize,
        "need {threshold} shares to recover this seed, got {distinct}",
    );

    let recoverable: Vec<sharks::Share> = shares
        .iter()
        .map(|s| {
            let mut bytes = Vec::with_capacity(RootSeed::LENGTH + 1);
            bytes.push(s.index);
            bytes.extend_from_slice(s.payload.expose_secret());
            let share = sharks::Share::try_from(bytes.as_slice())
                .map_err(|e| anyhow::anyhow!("malformed share {}: {e}", s.index));
            bytes.zeroize();
            share
        })
        .collect::<anyhow::Result<_>>()?;

    let mut secret = sharks::Sharks(threshold)
        .recover(recoverable.as_slice())
        .map_err(|e| anyhow::anyhow!("could not recover the seed from these shares: {e}"))?;

    let seed = RootSeed::try_from(secret.as_slice())
        .context("recovered bytes are not a valid root seed")?;
    secret.zeroize();

    ensure!(
        commit_to(&seed) == first.commitment,
        "the reconstructed seed does not match what these shares commit to — one of them is \
         corrupt or belongs to a different split",
    );
    Ok(seed)
}

/// `quid-seed-share <index>/<threshold> <commitment-hex> <24 words>`
///
/// One line, so a share survives being pasted, photographed, or read down a phone. The words come
/// last because that is the part being transcribed.
impl fmt::Display for SeedShare {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{SHARE_TAG} {}/{} {} {}",
            self.index,
            self.threshold,
            quid_hex::hex::encode(&self.commitment),
            payload_to_words(self.payload.expose_secret()),
        )
    }
}

/// ⚠️ Deliberately NOT `Debug`-derived: the derive would print the payload through
/// `Secret`'s own guard only if every field cooperated, and this type is written to files.
impl fmt::Debug for SeedShare {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SeedShare({}/{}, ..)", self.index, self.threshold)
    }
}

impl FromStr for SeedShare {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let s = s.trim();
        let rest = s
            .strip_prefix(SHARE_TAG)
            .with_context(|| format!("a share line must begin with `{SHARE_TAG}`"))?;

        let mut parts = rest.split_whitespace();
        let position = parts.next().context("share line is missing `<index>/<threshold>`")?;
        let commitment_hex = parts.next().context("share line is missing its commitment")?;
        let words: Vec<&str> = parts.collect();
        ensure!(
            words.len() == 24,
            "a share carries 24 words, this line has {}",
            words.len(),
        );

        let (index, threshold) = position
            .split_once('/')
            .context("expected `<index>/<threshold>`")?;
        let index: u8 = index.parse().context("share index must be 0-255")?;
        let threshold: u8 = threshold.parse().context("share threshold must be 0-255")?;

        let mut commitment = [0u8; COMMITMENT_LEN];
        quid_hex::hex::decode_to_slice(commitment_hex, &mut commitment)
            .map_err(|e| anyhow::anyhow!("share commitment is not {COMMITMENT_LEN}-byte hex: {e}"))?;

        let sentence = words.join(" ");
        let mnemonic =
            bip39::Mnemonic::parse_in_normalized(bip39::Language::English, &sentence)
                .map_err(|e| {
                    anyhow::anyhow!(
                        "share {index} did not parse as BIP39 (check for a mistyped or \
                         transposed word — the checksum is enforced): {e}"
                    )
                })?;
        let (entropy, len) = mnemonic.to_entropy_array();
        let entropy = secrecy::zeroize::Zeroizing::new(entropy);
        ensure!(len == RootSeed::LENGTH, "share payload must be 32 bytes, got {len}");

        let mut payload = [0u8; RootSeed::LENGTH];
        payload.copy_from_slice(&entropy[..RootSeed::LENGTH]);

        Ok(SeedShare { index, threshold, commitment, payload: Secret::new(payload) })
    }
}

/// Parse a whole set of shares from text: one share per line, blanks and `#` comments ignored.
///
/// This is what the import path hands the operator's pasted-together shares to, which is why it
/// tolerates the shape a human actually produces — a file with headers, or three lines pasted one
/// after another.
pub fn parse_share_set(text: &str) -> anyhow::Result<Vec<SeedShare>> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        out.push(SeedShare::from_str(line)?);
    }
    if out.is_empty() {
        bail!("no share lines found (each must begin with `{SHARE_TAG}`)");
    }
    Ok(out)
}

#[cfg(test)]
mod test {
    use quid_crypto::rng::FastRng;

    use super::*;

    fn split_fixture(threshold: u8, count: u8) -> (RootSeed, Vec<SeedShare>) {
        let mut rng = FastRng::from_u64(0x5EED);
        let seed = RootSeed::from_rng(&mut rng);
        let shares = split(&seed, threshold, count, &mut rng).unwrap();
        (seed, shares)
    }

    #[test]
    fn any_threshold_subset_recovers_the_seed() {
        let (seed, shares) = split_fixture(2, 3);
        assert_eq!(shares.len(), 3);

        // Every 2-subset, not just the first — an off-by-one in index handling would recover
        // from one pair and not another.
        for (i, j) in [(0, 1), (0, 2), (1, 2)] {
            let subset = vec![
                SeedShare::from_str(&shares[i].to_string()).unwrap(),
                SeedShare::from_str(&shares[j].to_string()).unwrap(),
            ];
            let got = combine(&subset).unwrap();
            assert_eq!(got.as_bytes(), seed.as_bytes(), "pair ({i},{j}) failed");
        }
    }

    /// The share set round-trips through TEXT, because text is what actually gets carried
    /// between machines — on paper, in a photo, down a phone line.
    #[test]
    fn shares_round_trip_through_their_written_form() {
        let (seed, shares) = split_fixture(3, 5);
        let text = shares
            .iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
            .join("\n# a comment an operator might add\n");

        let parsed = parse_share_set(&text).unwrap();
        assert_eq!(parsed.len(), 5);
        assert_eq!(combine(&parsed[..3]).unwrap().as_bytes(), seed.as_bytes());
    }

    /// 🔴 THE REFUSAL THAT MATTERS MOST. Below the threshold, Lagrange interpolation still
    /// RETURNS 32 well-formed bytes — it does not fail. Without this check an operator who
    /// gathered K−1 shares would boot a healthy node holding none of their channels.
    #[test]
    fn too_few_shares_is_refused_rather_than_interpolated() {
        let (_seed, shares) = split_fixture(3, 5);
        let err = combine(&shares[..2]).unwrap_err();
        assert!(
            format!("{err:#}").contains("need 3 shares"),
            "expected a threshold refusal, got: {err:#}",
        );
    }

    /// Mixing splits is the other silent-garbage path: both sets are valid, and interpolating
    /// across them yields neither seed. The commitment is what makes it loud.
    #[test]
    fn shares_from_different_splits_are_refused() {
        let (_a, shares_a) = split_fixture(2, 3);
        let mut rng = FastRng::from_u64(0xD1FF);
        let seed_b = RootSeed::from_rng(&mut rng);
        let shares_b = split(&seed_b, 2, 3, &mut rng).unwrap();

        let mixed = vec![
            SeedShare::from_str(&shares_a[0].to_string()).unwrap(),
            SeedShare::from_str(&shares_b[1].to_string()).unwrap(),
        ];
        let err = combine(&mixed).unwrap_err();
        assert!(
            format!("{err:#}").contains("different seeds"),
            "expected a commitment mismatch, got: {err:#}",
        );
    }

    /// A repeated share is not a second point. Supplying the same one twice must not be read as
    /// meeting the threshold.
    #[test]
    fn a_duplicated_share_does_not_count_twice() {
        let (_seed, shares) = split_fixture(2, 3);
        let doubled = vec![
            SeedShare::from_str(&shares[0].to_string()).unwrap(),
            SeedShare::from_str(&shares[0].to_string()).unwrap(),
        ];
        let err = combine(&doubled).unwrap_err();
        assert!(
            format!("{err:#}").contains("duplicate share index"),
            "expected a duplicate refusal, got: {err:#}",
        );
    }

    /// A transposed word inside a share must be caught by BIP39's checksum, exactly as it is for
    /// the whole-seed backup.
    #[test]
    fn a_mistyped_share_is_refused() {
        let (_seed, shares) = split_fixture(2, 3);
        let line = shares[0].to_string();
        let mut parts: Vec<&str> = line.split_whitespace().collect();
        let n = parts.len();
        parts.swap(n - 1, n - 2);
        SeedShare::from_str(&parts.join(" "))
            .expect_err("a transposed word must fail the share's checksum");
    }

    /// Configuration mistakes are caught at SPLIT time, not at recovery time — the moment when
    /// discovering them is useless.
    #[test]
    fn a_degenerate_split_is_refused_up_front() {
        let mut rng = FastRng::from_u64(3);
        let seed = RootSeed::from_rng(&mut rng);

        split(&seed, 1, 3, &mut rng).expect_err("1-of-N is N copies of the secret");
        split(&seed, 4, 3, &mut rng).expect_err("a threshold above the count is unrecoverable");
    }

    /// ⚠️ ANONYMITY IS A PROPERTY OF THE ARTEFACT, so it is asserted on the artefact. A share
    /// line must carry no roster, no holder, and no set size — only which point it is and how
    /// many are needed. `count` is deliberately absent: 2/3 and 2/7 splits are indistinguishable.
    #[test]
    fn a_share_line_reveals_nothing_but_the_point_and_the_threshold() {
        let mut rng = FastRng::from_u64(0x5EED);
        let seed = RootSeed::from_rng(&mut rng);

        // The SAME seed and threshold, split into two DIFFERENT family sizes. If a share
        // disclosed N, these would be distinguishable — and a share is a thing that gets
        // photographed, so its contents are the whole disclosure surface.
        let small = split(&seed, 2, 3, &mut rng).unwrap();
        let large = split(&seed, 2, 9, &mut rng).unwrap();

        for (from_small, from_large) in small.iter().zip(large.iter()) {
            let sa = from_small.to_string();
            let sb = from_large.to_string();
            let fa: Vec<&str> = sa.split_whitespace().collect();
            let fb: Vec<&str> = sb.split_whitespace().collect();

            // tag + index/threshold + commitment + 24 words, identically in both.
            assert_eq!(fa.len(), 27, "unexpected share layout: {sa}");
            assert_eq!(fb.len(), 27, "unexpected share layout: {sb}");
            assert_eq!(fa[0], SHARE_TAG);
            assert_eq!(fb[0], SHARE_TAG);
            assert_eq!(
                fa[1].split('/').nth(1),
                fb[1].split('/').nth(1),
                "the threshold field must be all a share says about the set",
            );
        }

        // And nothing anywhere in the type can answer "how many of us are there?".
        assert_eq!(small[0].threshold(), large[0].threshold());
    }
}
