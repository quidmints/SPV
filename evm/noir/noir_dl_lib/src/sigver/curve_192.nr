use std::ops::Add;
use std::ops::Mul;
use crate::bignum::BigNumTrait;
use crate::bignum::{BigNum, params::{BigNumParams, BigNumParamsGetter}};

global TWO_POWER_120: Field = 1329227995784915872903807060280344576;

global SECP192R1_GENERATOR: [[Field; 2]; 2] = [[0xbf20eb43a18800f4ff0afd82ff1012, 0x188da80eb03090f67c],
[0x1011ed6b24cdd573f977a11e794811, 0x7192b95ffc8da7863]];

// beta.26 ICEs evaluating this at global scope (see NOIR-DL-PORT.md).
pub fn Secp192r1_Fq_PARAMS() -> BigNumParams<2, 192> {
    BigNumParams::new(
    true,
    [0xfffffffffffffeffffffffffffffff, 0xffffffffffffffffff],
    [0x100000000000000010, 0x10000000000000000000]
)
}

pub struct Secp192r1_Fq_Params {}

impl BigNumParamsGetter<2, 192> for Secp192r1_Fq_Params {
    fn get_params() -> BigNumParams<2, 192> {
        Secp192r1_Fq_PARAMS()
    }
}

pub struct Secp192r1_Fr_Params {}

impl BigNumParamsGetter<2, 192> for Secp192r1_Fr_Params {
    fn get_params() -> BigNumParams<2, 192> {
        Secp192r1_Fr_PARAMS()
    }
}

// beta.26 ICEs evaluating this at global scope (see NOIR-DL-PORT.md).
pub fn Secp192r1_Fr_PARAMS() -> BigNumParams<2, 192> {
    BigNumParams::new(
    true,
    [0xffffff99def836146bc9b1b4d22831, 0xffffffffffffffffff],
    [0x662107c9eb94364e4b2dd7cf2, 0x10000000000000000000]
)
}


global a: BigNum<2, 192, Secp192r1_Fq_Params> = BigNum {
    limbs: [0xfffffffffffffefffffffffffffffc, 0xffffffffffffffffff]
};

global b: BigNum<2, 192, Secp192r1_Fq_Params> = BigNum {
    limbs: [0xa7e9ab72243049feb8deecc146b9b1, 0x64210519e59c80e70f]
};

pub fn curve_add(in1: [[Field; 2];2], in2: [[Field; 2];2]) -> [[Field; 2]; 2]{

    let x1: BigNum<2, 192, Secp192r1_Fq_Params> = BigNum {
        limbs: {
            in1[0]
        },
    };

    let y1: BigNum<2, 192, Secp192r1_Fq_Params> = BigNum {
        limbs: {
            in1[1]
        },
    };

    let x2: BigNum<2, 192, Secp192r1_Fq_Params> = BigNum {
        limbs: {
            in2[0]
        },
    };

    let y2: BigNum<2, 192, Secp192r1_Fq_Params> = BigNum {
        limbs: {
            in2[1]
        },
    };

    let lambda = unsafe { x1
        .__add(x2.__neg())
        .__invmod()
        .__mul(
            y1.add(
                y2.__neg()
                )
            ) };

    // lambda = (y2 - y1) / (x2 - x1) =>
    // lambda * (x2 - x1) - y2 + y1 === 0
    BigNum::evaluate_quadratic_expression(
            [[lambda]],
            [[false]],
            [[x2, x1]],
            [[false, true]],
            [y2, y1],
            [true, false],
        );

    let x3 = unsafe { lambda
        .__mul(lambda)
        .__add(
            x1.__neg()
        )
        .__add(
            x2.__neg()
        ) };
    
    let y3 = unsafe { lambda
        .__mul(
            x1.__add(
                x3.__neg()
            )
        )
        .__add(
            y1.__neg()
        ) };

    BigNum::evaluate_quadratic_expression(
        [[lambda]],
        [[false]],
        [[lambda]],
        [[false]],
        [x3, x2, x1],
        [true, true, true],
    );

    BigNum::evaluate_quadratic_expression(
        [[lambda]],
        [[false]],
        [[x3, x1]],
        [[false, true]],
        [y3, y1],
        [false, false],
    );

    [x3.limbs, y3.limbs]
    
}

pub fn curve_double(in1: [[Field; 2];2]) -> [[Field; 2]; 2]{
    
    let x1: BigNum<2, 192, Secp192r1_Fq_Params> = BigNum {
        limbs: {
            in1[0]
        },
    };

    let y1: BigNum<2, 192, Secp192r1_Fq_Params> = BigNum {
        limbs: {
            in1[1]
        },
    };

    let lambda = unsafe { BigNum::one()
        .__add(
            BigNum::one().__add(BigNum::one())
        )
        .__mul(
            x1.__mul(x1)
        )
        .__add(a)
        .__mul(
            y1.__add(y1)
                .__invmod()
        ) };

    // -lambda * 2y + 3*x*x + a = 0
    BigNum::evaluate_quadratic_expression(
        [[x1, x1, x1], [y1, y1, BigNum::new()]],
        [[false, false, false], [false, false, false]],
        [[x1], [lambda]],
        [[false], [true]],
        [a],
        [false],
    );

    let x3 = unsafe { lambda
        .__mul(lambda)
        .__add(
            x1.__add(x1).__neg()
        ) };
    
    let y3 = unsafe { lambda
        .__mul(
            x1.__add(x3.__neg())
        )
        .__add(
            y1.__neg()
        ) };

    BigNum::evaluate_quadratic_expression(
        [[lambda]],
        [[false]],
        [[lambda]],
        [[false]],
        [x3, x1, x1],
        [true, true, true],
    );

    BigNum::evaluate_quadratic_expression(
        [[lambda]],
        [[false]],
        [[x3, x1]],
        [[false, true]],
        [y3, y1],
        [false, false],
    );

    [x3.limbs, y3.limbs]
}

pub fn curve_mult(in1: [[Field; 2];2], scalar: Field) -> [[Field; 2]; 2]{
    let scalar_bits: [Field; 192] = crate::utils::bits_to_field(scalar.to_be_bits::<192>());

    let mut res = in1;
    let mut found_first_bit= false;

    for i in 0..192{
        if (found_first_bit){
            res = curve_double(res);
            if (scalar_bits[i] as Field).eq(1){
                res = curve_add(res, in1);
            }
        }
        if ((scalar_bits[i] as Field).eq(1) & !found_first_bit){
            found_first_bit = true;
        }
    }
    res
}

pub fn curve_precompute_table(p1: [[Field; 2]; 2], p2: [[Field; 2]; 2]) -> [[[[Field; 2]; 2]; 4]; 4]{
    let p1_double = curve_double(p1);
    let p2_double = curve_double(p2);
    let p1_triple = curve_add(p1, p1_double);
    let p2_triple = curve_add(p2, p2_double);

    let mut res: [[[[Field; 2]; 2]; 4]; 4] = [[[[0; 2]; 2]; 4]; 4];

    res[0][1] = p2;
    res[0][2] = p2_double;
    res[0][3] = p2_triple;

    res[1][0] = p1;
    res[2][0] = p1_double;
    res[3][0] = p1_triple;

    res[2][2] = curve_add(p1_double, p2_double);
    res[1][2] = curve_add(p1, p2_double);
    res[1][1] = curve_add(p1, p2);
    res[2][1] = curve_add(p1_double, p2);

    res[3][1] = curve_add(p1_triple, p2);
    res[3][2] = curve_add(p1_triple, p2_double);
    res[3][3] = curve_add(p1_triple, p2_triple);
    res[2][3] = curve_add(p1_double, p2_triple);
    res[1][3] = curve_add(p1, p2_triple);

    res
}   

pub fn get_val_from_table(table: [[[[Field; 2]; 2]; 4]; 4], x: u32, y: u32) -> [[Field; 2]; 2]{
    table[x][y]
}

pub fn curve_two_mult(p1: [[Field; 2];2], p2: [[Field; 2];2], scalars:[Field; 2]) -> [[Field; 2]; 2]{
    let table = curve_precompute_table(p1, p2);

    let s1_bits = scalars[0].to_be_bits::<192>();
    let s2_bits = scalars[1].to_be_bits::<192>();

    let mut res = [[0; 2];2];
    let mut found_first_bit = false;
    for i in 0..96{

        if (found_first_bit){
            res = curve_double(curve_double(res));
            if (!(s1_bits[2*i] as Field * 2 + s1_bits[2*i+1] as Field + s2_bits[2*i] as Field * 2 + s2_bits[2*i+1] as Field).eq(0)){
                res = curve_add(res, get_val_from_table(table,(s1_bits[2*i] as u32 * 2 + s1_bits[2*i+1] as u32), (s2_bits[2*i] as u32 * 2 + s2_bits[2*i+1] as u32)));
            }
        }

        if !(s1_bits[2*i] as Field * 2 + s1_bits[2*i+1] as Field + s2_bits[2*i] as Field * 2 + s2_bits[2*i+1] as Field).eq(0) & !found_first_bit {
            found_first_bit = true;
            res = get_val_from_table(table, (s1_bits[2*i] as u32 * 2 + s1_bits[2*i+1] as u32), (s2_bits[2*i] as u32 * 2 + s2_bits[2*i+1] as u32));
        }
    }

    res
}   

pub fn ecdsa_ver(sig: [[Field; 2]; 2], pk: [[Field; 2]; 2], hashed: [u8; 20]) {
    let mut extended_hadhed = [0; 24];
    for i in 0..20{
        extended_hadhed[i+4] = hashed[i];
    }

    let h: BigNum<2, 192, Secp192r1_Fr_Params> = BigNum::from_be_bytes::<24>(extended_hadhed);

    let r: BigNum<2, 192, Secp192r1_Fr_Params> = BigNum{
        limbs: sig[0]
    };

    let s: BigNum<2, 192, Secp192r1_Fr_Params> = BigNum{
        limbs: sig[1]
    };

    let s_inv = unsafe { s.__invmod() };
    assert(s_inv.mul(s) == BigNum::one(), "");

    let hs = s_inv.mul(h);
    let rs = s_inv.mul(r);

    let mut scalars = [0; 2];
    scalars[0] = hs.limbs[0] + hs.limbs[1] * TWO_POWER_120;
    scalars[1] = rs.limbs[0] + rs.limbs[1] * TWO_POWER_120;

    let r_point = curve_two_mult(SECP192R1_GENERATOR, pk, scalars);

    assert(r_point[0][0] == sig[0][0], "");
    assert(r_point[0][1] == sig[0][1], "");

}   





// #[test]
// fn test_2_mult(){
//     print(
//         curve_two_mult(
//             [[0x3c1d356c21122343280d6115c1d21, 0xb70e0cbd6bb4bf7f321390b94a],[0x4375a05a07476444d5819985007e34, 0xbd376388b5f723fb4c22dfe6cd]], 
//             [[0xcb2bba8f6e37e45621789743cd6633, 0x25a4b8ef0ae112d28aa95742d5],[0x8713800a75730121b92a8740249441, 0x9acf510689f8654b9e1866ae24]],
//             [0x21695a86c5d1c5b572ec36da8bbe5818188492e672a64a0f09cb3f95, 0x9cdf6edcbed49fd11fdfe5b3eeea9b1b472d50625919db29c85c5751]
//     ));
// }

#[test]
fn test_ecdsa(){
    ecdsa_ver(
    [
            [0x1a9431f728880790e1254cadb1303a, 0xd11b917a7ca8ca1aa],
            [0x66feb65c55b5a50bf21d5b2ef573dc, 0x85a546b59fab76c141]
        ],
    [
            [0xd30c77054172f04148fe39091495a0, 0x170b554d3623c7b19c],
            [0x252a3b0920adb0992cb830f93ae0c4, 0xcd20ab289cdefc0e83]
        ],
[124, 28, 16, 40, 230, 60, 31, 188, 223, 45, 206, 163, 158, 209, 112, 220, 125, 117, 74, 213]
    );
}

/*
 * DIFFERENTIAL TESTS against an independent affine short-Weierstrass reference (plain integer
 * arithmetic over secp192r1's parameters - deliberately NOT this implementation).
 *
 * These were print(...) with no assertion and could not fail whatever the arithmetic returned.
 * Limbs are little-endian and 120 bits wide.
 */
#[test]
fn test_double_matches_reference() {
    let got = curve_double(SECP192R1_GENERATOR);
    assert(got[0] == [0x5534631588a3f629a70fb16982a888, 0xdafebf5828783f2ad3], "2G.x wrong");
    assert(got[1] == [0xb27bbc141b868f59331afa5c7e93ab, 0xdd6bda0d993da0fa46], "2G.y wrong");
}

#[test]
fn test_add_matches_reference() {
    // The point below IS 2G, so this is 2G + G = 3G.
    let two_g = [
        [0x5534631588a3f629a70fb16982a888, 0xdafebf5828783f2ad3],
        [0xb27bbc141b868f59331afa5c7e93ab, 0xdd6bda0d993da0fa46],
    ];
    let got = curve_add(two_g, SECP192R1_GENERATOR);
    assert(got[0] == [0xd283201fb2b9aadfd0d359cbb263da, 0x76e32a2557599e6edc], "3G.x wrong");
    assert(got[1] == [0x62e0fed121d49ef3b543660cfd05fd, 0x782c37e372ba4520aa], "3G.y wrong");
}

#[test]
fn test_mult_matches_reference() {
    let got = curve_mult(SECP192R1_GENERATOR, 0x03);
    assert(got[0] == [0xd283201fb2b9aadfd0d359cbb263da, 0x76e32a2557599e6edc], "3G.x wrong");
    assert(got[1] == [0x62e0fed121d49ef3b543660cfd05fd, 0x782c37e372ba4520aa], "3G.y wrong");
}

/// Cross-check between the three primitives: scalar mult by 3 must equal double-then-add.
/// Catches a consistent-but-wrong ladder that per-op vectors alone could miss.
#[test]
fn test_mult_agrees_with_double_then_add() {
    let via_ladder = curve_mult(SECP192R1_GENERATOR, 0x03);
    let via_ops = curve_add(curve_double(SECP192R1_GENERATOR), SECP192R1_GENERATOR);
    assert(via_ladder[0] == via_ops[0], "mult(3) disagrees with double+add in x");
    assert(via_ladder[1] == via_ops[1], "mult(3) disagrees with double+add in y");
}
