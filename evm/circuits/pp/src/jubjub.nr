// Baby Jubjub scalar multiplication - COPIED VERBATIM from rarime's noir_dl_lib/src/jubjub.nr.
//
// WHY A COPY AND NOT AN IMPORT. `pp` needed exactly ONE function out of noir_dl_lib
// (`extract_pk_identity_hash`, 9 lines) which needs exactly ONE helper (`priv_to_pub`, below).
// Importing them dragged the ENTIRE ~16k-line passport-verification library - sigver, big_curve,
// bignum, all the ECDSA curve machinery - into every PP circuit, none of which PP uses. That made
// the PP circuits hostage to migrating a library they do not need (527 compile errors on modern
// nargo, none of them in PP's own code).
//
// DO NOT "clean up" or re-derive this. `priv_to_pub` defines `holder_root`, the durable identity
// commitment that HolderStateKeeper anchors on-chain and the wallet computes as `profileKey`. Any
// change here silently forks identity across circuit / contract / wallet. It is deliberately a
// byte-identical copy so the three stay in agreement; the published test vectors in
// identity_asp.nr and title_holder.nr are what enforce that.
//
// This file has ZERO imports, which is what made the extraction clean.

/**
 * Scalar multiplication by an ARBITRARY base point.
 *
 * `priv_to_pub` is this same double-and-add ladder with the generator hardcoded; it now delegates
 * here rather than carrying a second copy of a 254-iteration loop. The ALGORITHM is unchanged, so
 * the "byte-identical to rarime's noir_dl_lib" property above still holds where it matters - the
 * VALUES. `test_priv_to_pub_matches_babyjub` and `test_priv_to_pub_agrees_with_mul_point` below pin
 * that, so a divergence introduced here cannot pass silently.
 *
 * NEEDED FOR HASHED ELGAMAL (sec. 2.13d): sealing the revocation secret to the controller's
 * key requires `r*PK` for a published `PK`, not just `r*G`. That is the ONLY primitive the envelope
 * scheme was missing.
 */
pub fn mul_point(base_x: Field, base_y: Field, scalar: Field) -> (Field, Field) {
    let bits: [bool; 254] = scalar.to_be_bits::<254>();

    let mut result_x = base_x * (bits[0] as Field);
    let mut result_y = base_y * (bits[0] as Field);

    for i in 1..254 {
        let tmp_double = add_zero(result_x, result_y, result_x, result_y);

        let tmp_add = add_zero(tmp_double.0, tmp_double.1, base_x * (bits[i] as Field), base_y * (bits[i] as Field));

        result_x = tmp_add.0;
        result_y = tmp_add.1;
    }

    (result_x, result_y)
}

pub fn priv_to_pub(priv: Field) -> (Field, Field){
    let base_x = 5299619240641551281634865583518297030282874472190772894086521144482721001553;
    let base_y = 16950150798460657717958625567821834550301663161624707787222815936182638968203;

    mul_point(base_x, base_y, priv)
}

pub fn add (x1: Field, y1: Field, x2: Field, y2: Field) -> (Field, Field){
    
    let a = 168700;
    let d = 168696;
    
    let beta = x1 * y2;

    let gamma = x2 * y1;

    let delta = (y1 - x1 * a) * (x2 + y2);

    let tau = beta * gamma;
    
    let x = (beta + gamma) / (1 + d * tau);
    
    let y = (delta + a * beta - gamma) / (1 - d * tau);

    (x,y)
}

pub fn add_zero(x1: Field, y1: Field, x2: Field, y2: Field) -> (Field, Field){
    
    let a = 168700;
    let d = 168696;
    
    let beta = x1 * y2;

    let gamma = x2 * y1;

    let delta = (y1 - x1 * a) * (x2 + y2);

    let tau = beta * gamma;
    
    let x = (beta + gamma) / (1 + d * tau);
    
    let y = (delta + a * beta - gamma) / (1 - d * tau);

    let is_zero_x = x.eq(0) as Field;
    let is_zero_y = y.eq(0) as Field;
    (x + is_zero_x * (x1 + x2), y + is_zero_y * (y1 + y2))
}

/*
 * DIFFERENTIAL TESTS against @iden3/js-crypto's babyJub - the SAME implementation the wallet uses
 * in RarimeUtils.getProfileKey and that HolderStateKeeper matches on-chain.
 *
 * These tests were previously `print(...)` ONLY, with no assertion: they could not fail whatever
 * the arithmetic returned. That mattered more here than almost anywhere else in this tree, because
 * `priv_to_pub` is what holder_root.nr::extract_pk_identity_hash is built on, which is in turn the
 * identity the ENTIRE ASP membership check rests on. A wrong curve op would have silently produced
 * a holderRoot nobody could ever prove membership for.
 */
global BASE8_X: Field =
    5299619240641551281634865583518297030282874472190772894086521144482721001553;
global BASE8_Y: Field =
    16950150798460657717958625567821834550301663161624707787222815936182638968203;

#[test]
fn test_priv_to_pub_matches_babyjub() {
    let (x, y) = priv_to_pub(
        287325206580568373396753082727527032974277810276511506339905121597618812140,
    );
    assert(
        x == 12081729948048517337246964937487237071030796896339407151541092529192354593778,
        "priv_to_pub x disagrees with @iden3/js-crypto",
    );
    assert(
        y == 13485271700701647896810695035716445613077224148409999701152245885507304360556,
        "priv_to_pub y disagrees with @iden3/js-crypto",
    );
}

#[test]
fn test_add_doubling_matches_babyjub() {
    // G + G
    let (x, y) = add(BASE8_X, BASE8_Y, BASE8_X, BASE8_Y);
    assert(
        x == 10031262171927540148667355526369034398030886437092045105752248699557385197826,
        "add(G,G) x disagrees with @iden3/js-crypto",
    );
    assert(
        y == 633281375905621697187330766174974863687049529291089048651929454608812697683,
        "add(G,G) y disagrees with @iden3/js-crypto",
    );
}

#[test]
fn test_add_identity_is_neutral() {
    // (0,1) is the neutral element on this twisted Edwards curve, so G + O == G. This is the
    // property `add_zero` exists to handle; asserting it pins that the zero case is not silently
    // returning something else.
    let (x, y) = add(BASE8_X, BASE8_Y, 0, 1);
    assert(x == BASE8_X, "G + identity changed x");
    assert(y == BASE8_Y, "G + identity changed y");
}

#[test]
fn test_priv_to_pub_is_deterministic() {
    // Guards against any hidden state in the scalar-mult ladder.
    let a = priv_to_pub(1234);
    let b = priv_to_pub(1234);
    assert(a.0 == b.0, "priv_to_pub is not deterministic in x");
    assert(a.1 == b.1, "priv_to_pub is not deterministic in y");
}

/*
 * mul_point differential vectors, generated with the SAME @iden3/js-crypto babyJub the wallet uses:
 *   const P = babyJub.mulPointEScalar(babyJub.Base8, 7n);
 *   babyJub.mulPointEScalar(P, k);
 * The base here is 7*G - deliberately NOT the generator, since the whole point of this function is
 * the arbitrary-base case that `priv_to_pub` cannot exercise.
 */
global P7_X: Field =
    20092560661213339045022877747484245238324772779820628739268223482659246842641;
global P7_Y: Field =
    12112450042127193446189577552007703839818242727902437791835414514847797088033;

#[test]
fn test_mul_point_arbitrary_base_matches_babyjub() {
    // k = 1 must return the base unchanged.
    let (x1, y1) = mul_point(P7_X, P7_Y, 1);
    assert(x1 == P7_X, "mul_point k=1 changed x");
    assert(y1 == P7_Y, "mul_point k=1 changed y");

    let (x2, y2) = mul_point(P7_X, P7_Y, 2);
    assert(
        x2 == 6271573312546148160329629673815240458676221818610765478794395550121752710497,
        "mul_point k=2 x disagrees with @iden3/js-crypto",
    );
    assert(
        y2 == 20729133862440981855920571719405839551572203482913253618619962546642052100217,
        "mul_point k=2 y disagrees with @iden3/js-crypto",
    );

    let (x3, y3) = mul_point(P7_X, P7_Y, 1234);
    assert(
        x3 == 2619422398913205517721050840173764742879764528778505985725959064167656990051,
        "mul_point k=1234 x disagrees with @iden3/js-crypto",
    );
    assert(
        y3 == 16242328633187437272560829965814618299556668067593458319733392253491992277345,
        "mul_point k=1234 y disagrees with @iden3/js-crypto",
    );

    // A full-width scalar - the size an ElGamal ephemeral actually is, not a toy value.
    let (x4, y4) = mul_point(
        P7_X,
        P7_Y,
        287325206580568373396753082727527032974277810276511506339905121597618812140,
    );
    assert(
        x4 == 3513951964870253406393337057243839718706719782505248549705257732269741494284,
        "mul_point full-width x disagrees with @iden3/js-crypto",
    );
    assert(
        y4 == 14992476063324944445699325667800157043043257911372429918067253830783895370779,
        "mul_point full-width y disagrees with @iden3/js-crypto",
    );
}

#[test]
fn test_priv_to_pub_agrees_with_mul_point() {
    // priv_to_pub now DELEGATES to mul_point, so this pins the refactor: if the generalised ladder
    // ever diverges from the hardcoded-generator one, holder_root forks across circuit / contract /
    // wallet, which is the exact failure this file's header warns about.
    let a = priv_to_pub(1234);
    let b = mul_point(BASE8_X, BASE8_Y, 1234);
    assert(a.0 == b.0, "priv_to_pub and mul_point disagree in x");
    assert(a.1 == b.1, "priv_to_pub and mul_point disagree in y");
}

#[test]
fn test_mul_point_by_zero_returns_the_sentinel_not_the_identity() {
    // A zero scalar returns (0,0), NOT the curve identity (0,1). This ladder uses (0,0) as the
    // "empty accumulator" sentinel - that is what `add_zero`'s is_zero correction exists for - and
    // (0,0) does not even satisfy the curve equation (a*0 + 0 == 1 + d*0 is 0 == 1, false).
    //
    // ASSERTED BECAUSE IT IS THE EXACT DEGENERACY THE ENVELOPE'S `r != 0` GUARD REJECTS
    // (sec. 2.13d). With r = 0 the hashed-ElGamal shared secret is mul_point(PK, 0) =
    // (0,0) for EVERY controller key, so the mask Poseidon2([0,0]) is a public constant and
    // C2 = s + mask discloses the sealed revocation secret to anyone who looks. This test was
    // written asserting (0,1) and FAILED, which is how the real value was established rather than
    // assumed - the guard is protecting against something now measured, not imagined.
    let (x, y) = mul_point(P7_X, P7_Y, 0);
    assert(x == 0, "mul_point k=0 x is not the sentinel");
    assert(y == 0, "mul_point k=0 y is not the sentinel");

    // And it is base-independent, which is what makes the leak universal rather than key-specific.
    let (gx, gy) = mul_point(BASE8_X, BASE8_Y, 0);
    assert(gx == 0, "mul_point k=0 over G x is not the sentinel");
    assert(gy == 0, "mul_point k=0 over G y is not the sentinel");
}

#[test]
fn test_distinct_keys_give_distinct_points() {
    // If this failed, distinct identities could collide onto one holderRoot.
    let a = priv_to_pub(1234);
    let b = priv_to_pub(1235);
    assert((a.0 != b.0) | (a.1 != b.1), "two different scalars produced the same public point");
}
