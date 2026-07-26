//! SPV proof shaping for `BTCChannels` — produce the `(rawLegacyTx, blockHash,
//! merkleBranch, txIndex)` that `SPVGateway.checkTxInclusion` → `TxMerkleProof`
//! verifies. The header chain + raw tx + block txids come from `quid_ln::esplora`
//! in the hop service; this module owns the merkle folding (internal byte order,
//! matching the contract: txId = raw double-sha256, root = header merkleRoot LE).

use bitcoin::hashes::{sha256d, Hash};

/// Block hash in the BE/display byte order the `SPVGateway` keys headers by
/// (`parseBlockHeader(true)`): `to_byte_array()` is the internal sha256d order,
/// so the gateway-facing form is its reverse. EVERY block hash sent to the
/// contracts (`OpenParams.fundingBlockHash`, `recordClose` blockHash, lookups
/// via `isInMainchain`/`getBlockStatus`) must go through this; txids and the
/// merkle branch stay INTERNAL order (the contract folds those raw).
pub fn block_hash_be(h: &bitcoin::BlockHash) -> [u8; 32] {
    let mut be = h.to_byte_array();
    be.reverse();
    be
}

fn hash_pair(a: &[u8; 32], b: &[u8; 32]) -> [u8; 32] {
    let mut buf = [0u8; 64];
    buf[..32].copy_from_slice(a);
    buf[32..].copy_from_slice(b);
    sha256d::Hash::hash(&buf).to_byte_array()
}

/// Merkle branch + root for the tx at `index`, given all block txids (internal
/// byte order). Bitcoin duplicates the last node on odd layers. The branch is the
/// sibling at each level — what the contract folds with the txid using txIndex bits.
pub fn merkle_branch(txids: &[[u8; 32]], index: usize) -> (Vec<[u8; 32]>, [u8; 32]) {
    assert!(!txids.is_empty() && index < txids.len(), "index out of range");
    let mut layer: Vec<[u8; 32]> = txids.to_vec();
    let mut idx = index;
    let mut branch = Vec::new();
    while layer.len() > 1 {
        if layer.len() % 2 == 1 {
            let last = *layer.last().unwrap();
            layer.push(last);
        }
        branch.push(layer[idx ^ 1]);
        let mut next = Vec::with_capacity(layer.len() / 2);
        let mut i = 0;
        while i < layer.len() {
            next.push(hash_pair(&layer[i], &layer[i + 1]));
            i += 2;
        }
        layer = next;
        idx /= 2;
    }
    (branch, layer[0])
}

/// Mirror of the contract's `TxMerkleProof.verify`: fold `txid` with the branch
/// using `index` bits and compare to `root`. Lets the hop self-validate a proof
/// the way Solidity will, before submitting.
pub fn verify_branch(txid: &[u8; 32], branch: &[[u8; 32]], index: usize, root: &[u8; 32]) -> bool {
    let mut h = *txid;
    let mut idx = index;
    for sib in branch {
        h = if idx & 1 == 0 { hash_pair(&h, sib) } else { hash_pair(sib, &h) };
        idx >>= 1;
    }
    &h == root
}

#[cfg(test)]
mod tests {
    use super::*;
    fn d(b: u8) -> [u8; 32] { [b; 32] }

    #[test]
    fn branch_verifies_for_each_index() {
        let txids: Vec<[u8; 32]> = (1u8..=5).map(d).collect(); // 5 txs → odd-layer dup
        let (_, root) = merkle_branch(&txids, 0);
        for i in 0..txids.len() {
            let (branch, r) = merkle_branch(&txids, i);
            assert_eq!(r, root);
            assert!(verify_branch(&txids[i], &branch, i, &root), "verify idx {i}");
        }
        let (b0, _) = merkle_branch(&txids, 0);
        assert!(!verify_branch(&d(99), &b0, 0, &root));
    }

    // Sweep every tx count (odd-layer duplication at many layers) and every
    // index: the branch always folds to a stable root, a forged leaf never
    // verifies. Guards the odd-count duplication (CVE-2012-2459 shape).
    #[test]
    fn merkle_branch_round_trips_all_counts_and_indices() {
        for n in 1u8..=40 {
            let txids: Vec<[u8; 32]> = (1..=n)
                .map(|b| {
                    let mut x = [0u8; 32];
                    x[0] = b;
                    x[1] = b.wrapping_mul(7);
                    x
                })
                .collect();
            let (_, root) = merkle_branch(&txids, 0);
            for i in 0..txids.len() {
                let (branch, r) = merkle_branch(&txids, i);
                assert_eq!(r, root, "root stable n={n} i={i}");
                assert!(verify_branch(&txids[i], &branch, i, &root), "verify n={n} i={i}");
                assert!(!verify_branch(&[0xEEu8; 32], &branch, i, &root), "forgery n={n} i={i}");
            }
        }
    }
}
