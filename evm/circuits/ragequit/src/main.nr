// Ragequit - reclaim a deposit WITHOUT proving ASP membership.
//
// WHY THIS CIRCUIT EXISTS AT ALL. PrivacyPool.ragequit and CommitmentVerifier.sol were both
// inherited from upstream PP, but the CIRCUIT SOURCE was not - nothing in this repo could produce a
// RagequitProof. That left a correctness hole rather than a missing feature: ragequit is the ONLY
// exit for a depositor the ASP declines to admit, since withdrawal requires membership. Without it
// a rejected depositor could neither withdraw nor reclaim, and sec. 2.13's argument that admission
// cannot become a trap rested on an exit that did not exist.
//
// PORTED TO NOIR rather than vendoring upstream's circom, so the whole fusion stays on ONE proving
// stack (nargo + bb, UltraHonk). The alternative was adding snarkjs/circom purely for this one
// circuit - a second toolchain to pin, audit and keep working, for ~15 lines of constraints.
//
// WHAT IT PROVES: "I know the secrets behind this commitment, and this is its nullifier."
// Nothing about the ASP, deliberately - that is the entire point of the escape hatch.
//
// WHAT IT DOES NOT PROVE, because the CONTRACT checks it and the circuit cannot: that the caller
// is the original depositor. PrivacyPool.ragequit enforces `depositors[label] == msg.sender`, which
// is what makes this an unlinkable-exit sacrifice rather than a theft primitive - the funds go back
// to whoever deposited them, giving up the anonymity the deposit bought.
//
// PUBLIC I/O pinned to ProofLib.RagequitProof.pubSignals (4 elements, order unchanged from
// upstream so the contract's accessors keep working):
//   [0] commitment_hash   [2] value
//   [1] nullifier_hash    [3] label
use pp::commitment::commitment_hasher;

fn main(
    commitment_hash: pub Field,
    nullifier_hash: pub Field,
    value: pub Field,
    label: pub Field,
    // The note's secrets. Knowing these IS the authorisation - together with the contract's
    // depositor check, nothing else is needed.
    nullifier: Field,
    secret: Field,
) {
    let c = commitment_hasher(value, label, nullifier, secret);

    // Both halves are asserted. Checking only the commitment would let a prover pass any
    // nullifier_hash they liked, and the contract spends THAT value - so a note could be
    // reclaimed repeatedly under different nullifiers, draining the pool.
    assert(c.commitment == commitment_hash);
    assert(c.nullifier_hash == nullifier_hash);
}

#[test]
fn test_matches_commitment_gadget() {
    // pp/src/commitment.nr's differential-tested vector (value 10, label 20, nullifier 30,
    // secret 40), whose commitment/nullifier_hash were cross-checked against poseidon-solidity.
    main(
        10718981984499290237711722178490140094119483277114902091282087901089143679380,
        7532086780038402662674345296860422071861903663404908958571451852914592667893,
        10,
        20,
        30,
        40,
    );
}

#[test(should_fail)]
fn test_rejects_wrong_nullifier_hash() {
    main(
        10718981984499290237711722178490140094119483277114902091282087901089143679380,
        7532086780038402662674345296860422071861903663404908958571451852914592667894, // +1
        10,
        20,
        30,
        40,
    );
}

#[test(should_fail)]
fn test_rejects_wrong_value() {
    // A prover claiming a larger value than the note holds must fail - the contract pays out
    // pubSignals[2] directly.
    main(
        10718981984499290237711722178490140094119483277114902091282087901089143679380,
        7532086780038402662674345296860422071861903663404908958571451852914592667893,
        11,
        20,
        30,
        40,
    );
}
