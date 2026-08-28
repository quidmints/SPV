use std::hash::Hasher;
use poseidon::poseidon::PoseidonHasher;
use super::utils::{switcher};

fn smt_hash1(
    key: Field,
    value: Field) -> Field{
    let mut hasher = PoseidonHasher::default();
    hasher.write(key);
    hasher.write(value);
    hasher.write(1);
    hasher.finish()
}


fn smt_hash2(
    l: Field,
    r: Field) -> Field{
    let mut hasher = PoseidonHasher::default();
    hasher.write(l);
    hasher.write(r);
    hasher.finish()
}

fn smt_level_ins<let N_LEVELS: u32>(
    siblings: [Field; N_LEVELS]) -> [Field; N_LEVELS]{
    let mut done: [Field; (N_LEVELS - 1)] = [0; N_LEVELS - 1];
    assert(siblings[N_LEVELS - 1].eq(0) as Field == 1, "SMT inner verification failure");
    let mut out = [0; N_LEVELS];

    out[N_LEVELS - 1] = 1 - siblings[N_LEVELS - 2].eq(0) as Field;
    done[N_LEVELS - 2] = out[N_LEVELS - 1];

    for i in 0..N_LEVELS - 2{
        out[N_LEVELS - 2 - i] = 
            (1 - done[N_LEVELS - 2 - i]) * 
            (1 - siblings[N_LEVELS - 3 - i].eq(0) as Field);
        done[N_LEVELS - 3 - i] = 
            out[N_LEVELS - 2 - i] + done[N_LEVELS - 2 - i];
    }
    out[0] = 1 - done[0];
    out
}

fn smt_verifier_sm(lev_ins: Field, prev_top: Field) -> (Field, Field){
    let st_inew = prev_top * lev_ins;
    (st_inew, prev_top - st_inew)
}

fn smt_verifier_level(
    st_top: Field,
    st_inew: Field,
    sibling: Field,
    new_1_leaf: Field,
    lrbit: Field,
    child: Field
) -> Field{

    let switcher = switcher(child, sibling, lrbit);
    let proof_hash = smt_hash2(switcher.0, switcher.1);
    let from_proof= proof_hash * st_top;

    from_proof + new_1_leaf * st_inew
}

pub fn smt_verifier<let N_LEVELS: u32>(
    root: Field,
    leaf: Field,
    key: Field,
    siblings: [Field; N_LEVELS]) -> Field{
    
    let hash1_new = smt_hash1(key, leaf);

    let key_bits: [Field; 254] = crate::utils::bits_to_field(key.to_le_bits());
    
    let smt_lev_ins_out = smt_level_ins::<N_LEVELS>(siblings);

    let mut sm_outs: [(Field, Field); N_LEVELS] = [(0,0); N_LEVELS];

    sm_outs[0] = smt_verifier_sm(smt_lev_ins_out[0], 1);

    for i in 1..N_LEVELS{
        sm_outs[i] = smt_verifier_sm(smt_lev_ins_out[i], sm_outs[i - 1].1);
    }

    let mut levels: [Field; N_LEVELS] = [0; N_LEVELS];

    levels[N_LEVELS - 1] = smt_verifier_level(sm_outs[N_LEVELS - 1].1, sm_outs[N_LEVELS - 1].0, siblings[N_LEVELS - 1], hash1_new, key_bits[N_LEVELS - 1], 0);
    for i in 1..N_LEVELS{
        levels[N_LEVELS - 1 - i] = smt_verifier_level(sm_outs[N_LEVELS - 1 - i].1, sm_outs[N_LEVELS - 1 - i].0, siblings[N_LEVELS - 1 - i], hash1_new, key_bits[N_LEVELS - 1 - i], levels[N_LEVELS - i]);
    }
    (levels[0] == root) as Field
}


/*
 * -- EXCLUSION (non-inclusion) support -----------------------------------------------------------
 *
 * The gadget above proves a key IS in the tree. sec. 2.5's revocation design needs the opposite -
 * "this identity is NOT on the revocation list" - and a LeanIMT cannot express absence at all,
 * which is why an SMT is used here.
 *
 * This is the rest of circomlib's SMTVerifier, which the port above had dropped: the `fnc`
 * selector and the `oldKey`/`oldValue`/`isOld0` inputs. Non-inclusion has exactly two shapes, and
 * both must be provable:
 *   - THE SLOT IS EMPTY (`is_old0 = 1`): the path to `key` terminates at a zero subtree.
 *   - ANOTHER LEAF SITS THERE (`is_old0 = 0`): the path terminates at a leaf for a DIFFERENT key,
 *     `old_key`, whose presence is what proves `key` cannot also be there.
 *
 * THE SOUNDNESS CONSTRAINT IS `assert_keys_ok`. Without it a prover could pass `old_key == key`
 * and "prove" a key is absent while it is demonstrably present - i.e. prove non-revocation while
 * revoked. It is the single most important line here.
 */

/// Full state machine, five states. `smt_verifier_sm` above is this with is0/fnc/iold/i0 dropped.
fn smt_verifier_sm_full(
    is0: Field,
    lev_ins: Field,
    fnc: Field,
    prev_top: Field,
    prev_i0: Field,
    prev_iold: Field,
    prev_inew: Field,
    prev_na: Field,
) -> (Field, Field, Field, Field, Field) {
    let prev_top_lev_ins = prev_top * lev_ins;
    let prev_top_lev_ins_fnc = prev_top_lev_ins * fnc;

    let st_top = prev_top - prev_top_lev_ins;
    let st_inew = prev_top_lev_ins - prev_top_lev_ins_fnc;
    let st_iold = prev_top_lev_ins_fnc * (1 - is0);
    let st_i0 = prev_top_lev_ins * is0;
    let st_na = prev_na + prev_inew + prev_iold + prev_i0;

    (st_top, st_i0, st_iold, st_inew, st_na)
}

/// Level hash with all four state contributions. An empty slot (`st_i0`) contributes NOTHING,
/// which is precisely what makes "the subtree here is zero" provable.
fn smt_verifier_level_full(
    st_top: Field,
    st_iold: Field,
    st_inew: Field,
    sibling: Field,
    old_1_leaf: Field,
    new_1_leaf: Field,
    lrbit: Field,
    child: Field,
) -> Field {
    let switcher = switcher(child, sibling, lrbit);
    let proof_hash = smt_hash2(switcher.0, switcher.1);

    proof_hash * st_top + old_1_leaf * st_iold + new_1_leaf * st_inew
}

/// The soundness constraint. Claiming exclusion (`fnc = 1`) against a NON-empty slot
/// (`is_old0 = 0`) requires `old_key != key`; otherwise the "absent" key is the very leaf being
/// pointed at. circomlib expresses this as `keysOk.out === 0` over
/// (fnc AND NOT isOld0 AND keysEqual).
fn assert_keys_ok(fnc: Field, is_old0: Field, old_key: Field, key: Field) {
    let keys_equal = (old_key == key) as Field;
    assert(
        fnc * (1 - is_old0) * keys_equal == 0,
        "SMT exclusion claimed for a key that is present (old_key == key)",
    );
}

/**
 * Verify inclusion (`fnc = 0`) or EXCLUSION (`fnc = 1`) of `key` under `root`.
 *
 * For inclusion, `value` is the leaf value and old_key/old_value/is_old0 are ignored.
 * For exclusion, supply the leaf actually found at the path end: either `is_old0 = 1` (empty), or
 * `is_old0 = 0` with the occupying leaf's `old_key`/`old_value`.
 */
pub fn smt_verifier_full<let N_LEVELS: u32>(
    root: Field,
    key: Field,
    value: Field,
    old_key: Field,
    old_value: Field,
    is_old0: Field,
    fnc: Field,
    siblings: [Field; N_LEVELS],
) -> Field {
    let fnc_f = fnc as Field;
    let is0_f = is_old0 as Field;

    assert_keys_ok(fnc_f, is0_f, old_key, key);

    let hash1_old = smt_hash1(old_key, old_value);
    let hash1_new = smt_hash1(key, value);

    let key_bits: [Field; 254] = crate::utils::bits_to_field(key.to_le_bits());
    let lev_ins = smt_level_ins::<N_LEVELS>(siblings);

    // (top, i0, iold, inew, na), seeded at "still traversing".
    let mut sm: [(Field, Field, Field, Field, Field); N_LEVELS] = [(0, 0, 0, 0, 0); N_LEVELS];
    sm[0] = smt_verifier_sm_full(is0_f, lev_ins[0], fnc_f, 1, 0, 0, 0, 0);
    for i in 1..N_LEVELS {
        let p = sm[i - 1];
        sm[i] = smt_verifier_sm_full(is0_f, lev_ins[i], fnc_f, p.0, p.1, p.2, p.3, p.4);
    }

    let mut levels: [Field; N_LEVELS] = [0; N_LEVELS];
    let last = N_LEVELS - 1;
    levels[last] = smt_verifier_level_full(
        sm[last].0,
        sm[last].2,
        sm[last].3,
        siblings[last],
        hash1_old,
        hash1_new,
        key_bits[last],
        0,
    );
    for i in 1..N_LEVELS {
        let j = last - i;
        levels[j] = smt_verifier_level_full(
            sm[j].0,
            sm[j].2,
            sm[j].3,
            siblings[j],
            hash1_old,
            hash1_new,
            key_bits[j],
            levels[j + 1],
        );
    }

    (levels[0] == root) as Field
}

/*
 * DIFFERENTIAL TESTS against circomlibjs - the implementation this file is a port of.
 *
 * The previous test here was `print(smt_verifier::<80>(...))` with NO ASSERTION: it could not
 * fail, whatever the gadget returned. So the port had never actually been checked against its
 * reference. Vectors below come from circomlibjs 0.1.7, tree built by inserting
 * (1,11), (2,22), (7,77), (9,99) into an empty SMT.
 */
global REF_ROOT: Field =
    518494836555806875742446376098343000486175381741467406929375446995815951571;

// Inclusion path for key=7, padded to 10 levels.
fn ref_siblings_key7() -> [Field; 10] {
    [
        3538372437315232912232383076351801231931604997820687320170917796819460581158,
        7219773115889511897248370091680383759521588836236378252329610603114958225446,
        0, 0, 0, 0, 0, 0, 0, 0,
    ]
}

#[test]
fn test_inclusion_matches_circomlibjs() {
    assert(
        smt_verifier::<10>(REF_ROOT, 77, 7, ref_siblings_key7()) == 1,
        "inclusion proof for key=7 was rejected",
    );
}

/*
 * NEGATIVE CONTROLS. Without these the test above proves nothing: a gadget that returned 1
 * unconditionally would pass it. Each perturbs exactly one input.
 */
#[test]
fn test_rejects_wrong_value() {
    assert(
        smt_verifier::<10>(REF_ROOT, 78, 7, ref_siblings_key7()) == 0,
        "a wrong VALUE was accepted",
    );
}

#[test]
fn test_rejects_wrong_key() {
    assert(
        smt_verifier::<10>(REF_ROOT, 77, 8, ref_siblings_key7()) == 0,
        "a wrong KEY was accepted",
    );
}

#[test]
fn test_rejects_wrong_root() {
    assert(
        smt_verifier::<10>(REF_ROOT + 1, 77, 7, ref_siblings_key7()) == 0,
        "a wrong ROOT was accepted",
    );
}

#[test]
fn test_rejects_tampered_sibling() {
    let mut sib = ref_siblings_key7();
    sib[0] = sib[0] + 1;
    assert(smt_verifier::<10>(REF_ROOT, 77, 7, sib) == 0, "a tampered SIBLING was accepted");
}

/*
 * EXCLUSION differential tests, same circomlibjs tree as above.
 * Both non-inclusion shapes are covered, because they exercise different states of the machine.
 */

#[test]
fn test_exclusion_empty_slot_matches_circomlibjs() {
    // key=5 is absent and the path terminates at an EMPTY subtree (isOld0 = 1).
    assert(
        smt_verifier_full::<10>(
            REF_ROOT, 5, 0, 5, 0, 1, 1,
            [
                3538372437315232912232383076351801231931604997820687320170917796819460581158,
                7623680454338960526645764969964785413027269598530557012829785131842723566171,
                12556884404771194108685558266628964754582687227852416218991473495993258837549,
                0, 0, 0, 0, 0, 0, 0,
            ],
        ) == 1,
        "exclusion proof for absent key=5 (empty slot) was rejected",
    );
}

#[test]
fn test_exclusion_other_leaf_matches_circomlibjs() {
    // key=1024 is absent because key=2 (value 22) occupies the slot the path leads to.
    assert(
        smt_verifier_full::<10>(
            REF_ROOT, 1024, 0, 2, 22, 0, 1,
            [
                14615772771365257397421554110268415743234227304552007892570694122567980124822,
                0, 0, 0, 0, 0, 0, 0, 0, 0,
            ],
        ) == 1,
        "exclusion proof for absent key=1024 (other leaf occupies slot) was rejected",
    );
}

#[test]
fn test_full_verifier_still_does_inclusion() {
    // fnc = 0 must reproduce the inclusion gadget's result exactly.
    assert(
        smt_verifier_full::<10>(REF_ROOT, 7, 77, 0, 0, 0, 0, ref_siblings_key7()) == 1,
        "smt_verifier_full rejected a valid INCLUSION proof",
    );
}

/*
 * THE SOUNDNESS TEST. Claiming a key is absent while pointing at that very key must be
 * impossible - otherwise a revoked identity could prove non-revocation. assert_keys_ok is what
 * stops it, and this is the only test that exercises that line.
 */
#[test(should_fail_with = "SMT exclusion claimed for a key that is present (old_key == key)")]
fn test_exclusion_cannot_claim_a_present_key() {
    let _ = smt_verifier_full::<10>(REF_ROOT, 7, 77, 7, 77, 0, 1, ref_siblings_key7());
}

#[test]
fn test_exclusion_rejects_wrong_root() {
    assert(
        smt_verifier_full::<10>(
            REF_ROOT + 1, 1024, 0, 2, 22, 0, 1,
            [
                14615772771365257397421554110268415743234227304552007892570694122567980124822,
                0, 0, 0, 0, 0, 0, 0, 0, 0,
            ],
        ) == 0,
        "exclusion accepted against a WRONG root",
    );
}

#[test]
fn test_exclusion_rejects_wrong_old_leaf() {
    // Same shape as the key=1024 case but the occupying leaf's value is wrong, so the recomputed
    // root must not match.
    assert(
        smt_verifier_full::<10>(
            REF_ROOT, 1024, 0, 2, 23, 0, 1,
            [
                14615772771365257397421554110268415743234227304552007892570694122567980124822,
                0, 0, 0, 0, 0, 0, 0, 0, 0,
            ],
        ) == 0,
        "exclusion accepted with a WRONG old_value",
    );
}
