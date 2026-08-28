pub fn priv_to_pub(priv: Field) -> (Field, Field){
    let base_x = 5299619240641551281634865583518297030282874472190772894086521144482721001553;
    let base_y = 16950150798460657717958625567821834550301663161624707787222815936182638968203;

    let priv_bits: [Field; 254] = crate::utils::bits_to_field(priv.to_be_bits::<254>());

    let mut result_x = base_x * (priv_bits[0] as Field);
    let mut result_y = base_y * (priv_bits[0] as Field);

    for i in 1..254{
        let tmp_double = add_zero(result_x, result_y, result_x, result_y);

        let tmp_add = add_zero(tmp_double.0, tmp_double.1, base_x * (priv_bits[i] as Field), base_y * (priv_bits[i] as Field));

        result_x = tmp_add.0;
        result_y = tmp_add.1;

    }


    (result_x, result_y)

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

#[test]
fn test_distinct_keys_give_distinct_points() {
    // If this failed, distinct identities could collide onto one holderRoot.
    let a = priv_to_pub(1234);
    let b = priv_to_pub(1235);
    assert((a.0 != b.0) | (a.1 != b.1), "two different scalars produced the same public point");
}
