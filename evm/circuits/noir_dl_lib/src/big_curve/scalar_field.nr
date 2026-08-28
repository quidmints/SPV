use crate::bignum::BigNum;
use crate::bignum::BigNumTrait;

/**
 * @brief ScalarField represents a scalar multiplier as a sequence of 4-bit slices
 * @details There is nuance to ScalarField, because twisted edwards curves generally have prime group orders that easily fit into a Field
 *          We can therefore obtain cheap conversions by simply summing up the bit slices and validate they equal the input scalar
 *          However...when converting arbitrary field elements (i.e. scalars that are multiples of a TE curve group order),
 *          we must perform additional checks when converting into 4-bit slices, as we must validate that the sum of the slices is smaller than the Field modulus (when evaluated over the integers)
 *          This is expensive and we would rather not do it! therefore ScalarField<N> is flexible.
 *          ScalarField<63> enables cheap bitslice converions for scalar multipliers that must be <2^{252}
 *          ScalarField<64> enables bitslice conversions for arbitrary field elements
 *
 *          N.B. ScalarField bit values are not constrained to be smaller than the TE curve group order.
 *          ScalarField is used when performing scalar multiplications, where all operations wrap modulo the curve order
 **/
pub struct ScalarField<let N: u32> {
    pub(crate) base4_slices: [u8; N],
    pub(crate) skew: bool,
}


/// Little-endian base-16 (nibble) decomposition of a Field.
///
/// `Field::to_le_radix` became private after nargo beta.1; `to_le_bytes` is the public
/// replacement, so nibbles are derived from bytes. A little-endian radix-16 array of length N
/// corresponds to the low ceil(N/2) little-endian bytes, with
///   nibble[2i]     = byte[i] & 0x0f   (low)
///   nibble[2i + 1] = byte[i] >> 4     (high)
///
/// Used only from `unconstrained` hint generators, whose output is constrained by the callers - a
/// wrong decomposition therefore fails loudly rather than silently producing a bad scalar.
unconstrained fn field_to_le_nibbles<let N: u32, let HALF: u32>(x: Field) -> [u8; N] {
    let bytes: [u8; HALF] = x.to_le_bytes();
    let mut out: [u8; N] = [0; N];
    for i in 0..HALF {
        if 2 * i < N {
            out[2 * i] = bytes[i] & 0x0f;
        }
        if 2 * i + 1 < N {
            out[2 * i + 1] = bytes[i] >> 4;
        }
    }
    out
}

// 1, 2, 3, 4
unconstrained fn get_wnaf_slices<let N: u32>(x: Field) -> ([u8; N], bool) {
    let mut result: [u8; N] = [0; N];
    let mut nibbles: [u8; N] = field_to_le_nibbles::<N, (N + 1) / 2>(x);

    let skew: bool = nibbles[0] & 1 == 0;
    nibbles[0] = nibbles[0] as u8 + (skew as u8);
    result[N - 1] = (nibbles[0] + 15) / 2;
    for i in 1..N {
        let mut nibble: u8 = nibbles[i];
        result[N - 1 - i] = (nibble + 15) / 2;
        if (nibble & 1 == 0) {
            result[N - 1 - i] += 1;
            result[N - i] -= 8;
        }
    }

    (result, skew)
}

unconstrained fn get_wnaf_slices2<let N: u32, BigNum>(x: BigNum) -> ([u8; N], bool)
where
    BigNum: BigNumTrait,
{
    let mut result: [u8; N] = [0; N];
    let mut nibbles: [[u8; 30]; (N / 30) + 1] = [[0; 30]; (N / 30) + 1];
    let x: [Field] = x.get_limbs_slice();
    for i in 0..x.len() {
        nibbles[i] = field_to_le_nibbles::<30, 15>(x[i]);
    }

    let skew: bool = nibbles[0][0] & 1 == 0;
    nibbles[0][0] = nibbles[0][0] as u8 + (skew as u8);
    result[N - 1] = (nibbles[0][0] + 15) / 2;

    for i in 1..N {
        let major_index = i / 30;
        let minor_index = i % 30;
        let mut nibble: u8 = nibbles[major_index][minor_index];
        result[N - 1 - i] = (nibble + 15) / 2;
        if (nibble & 1 == 0) {
            result[N - 1 - i] += 1;
            result[N - i] -= 8;
        }
    }

    (result, skew)
}

// unconstrained fn get_modulus_slices() -> (Field, Field) {
//     let bytes = std::field::modulus_be_bytes();
//     let num_bytes = (std::field::modulus_num_bits() / 8) + ((std::field::modulus_num_bits() % 8 != 0) as u64);
//     let mut lo: Field = 0;
//     let mut hi: Field = 0;
//     for i in 0..(num_bytes / 2) {
//         hi *= 256;
//         hi += bytes[i] as Field;
//         lo *= 256;
//         lo += bytes[i + (num_bytes/2)] as Field;
//     }
//     if (num_bytes & 1 == 1) {
//         lo *= 256;
//         lo += bytes[num_bytes - 1] as Field;
//     }
//     (lo, hi)
// }

// unconstrained fn get_borrow_flag(lhs_lo: Field, rhs_lo: Field) -> bool {
//     lhs_lo.lt(rhs_lo + 1)
// }

impl<let N: u32> std::convert::From<Field> for ScalarField<N> {

    /**
     * @brief construct from a field element
     * @details if N >= 64 we perform extra checks to ensure the slice decomposition represents the same integral value as the input
     *          (e.g. sum of slices != x + modulus)
     **/
    fn from(x: Field) -> Self {
        let mut result: Self = ScalarField { base4_slices: [0; N], skew: false };
        let (slices, skew): ([u8; N], bool) = unsafe { get_wnaf_slices(x) };
        result.base4_slices = slices;
        result.skew = skew;
        if (N < 64) {
            let mut acc: Field = (slices[0] as Field) * 2 - 15;
            for i in 1..N {
                acc *= 16;
                acc += (slices[i] as Field) * 2 - 15;
            }
            assert(acc - skew as Field == x);
        } else {
            // TODO fix! this does not work because we are assuming N slices is smaller than 256 bits
            // let mut lo: Field = slices[(N / 2)] as Field * 2 - 15;
            // let mut hi: Field = slices[0] as Field * 2 - 15;
            // let mut borrow_shift = 1;
            // for i in 1..(N / 2) {
            //     borrow_shift *= 16;
            //     lo *= 16;
            //     lo += (slices[(N/2) + i] as Field) * 2 - 15;
            //     hi *= 16;
            //     hi += (slices[i] as Field) * 2 - 15;
            // }
            // if ((N & 1) == 1) {
            //     borrow_shift *= 16;
            //     lo *= 16;
            //     lo += (slices[N-1] as Field) * 2 - 15;
            // }
            // // 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efffffff
            // // 0x2833e84879b9709143e1f593f0000001
            // // 0x8833e84879b9709143e1f593efffffff
            // lo -= skew as Field;
            // // Validate that the integer represented by (lo, hi) is smaller than the integer represented by (plo, phi)
            // let (plo, phi) = unsafe {
            //     get_modulus_slices()
            // };
            // let borrow = unsafe {
            //     get_borrow_flag(plo, lo) as Field
            // };
            // let rlo = plo - lo + borrow * borrow_shift - 1; // -1 because we are checking a strict <, not <=
            // let rhi = phi - hi - borrow;
            // let offset = (N & 1 == 1) as u32;
            // let hibits = (N / 2) * 4;
            // let lobits = hibits + offset * 4 + 1; // 1 extra bit to account for borrow
            // // 0x013833e84879b9709143e1f593f0000000
            // // rlo.assert_max_bit_size(lobits as u32);
            // // rhi.assert_max_bit_size(hibits as u32);
        }
        for i in 0..N {
            (result.base4_slices[i] as Field).assert_max_bit_size::<4>();
        }
        result
    }
}

impl<let N: u32> std::convert::Into<Field> for ScalarField<N> {
    /**
     * @brief construct from tuple of field elements
     * @details use this method instead of `new` if you know x/y is on the curve
     **/
    fn into(self: Self) -> Field {
        let mut acc: Field = 0;
        for i in 0..N {
            acc = acc * 16;
            acc = acc + (self.base4_slices[i] as Field) * 2 - 15;
        }
        acc -= self.skew as Field;
        acc
    }
}

pub trait ScalarFieldTrait {
    fn zero() -> Self;
    fn conditional_select(lhs: Self, rhs: Self, predicate: bool) -> Self;
    fn from_bignum<BigNum>(x: BigNum) -> Self
    where
        BigNum: BigNumTrait;
    fn into_bignum<BigNum>(self) -> BigNum
    where
        BigNum: BigNumTrait;
    fn new() -> Self;
    fn get(self, idx: u64) -> u8;
    fn len(self) -> u32;
}
impl<let N: u32> ScalarFieldTrait for ScalarField<N> {

    fn len(_: Self) -> u32 {
        N
    }
    fn zero() -> Self {
        let mut result: Self = ScalarField { base4_slices: [0; N], skew: true };

        result.base4_slices[0] = 8; // 8 = numeric value of 1, 0 = numeric value of -15
        result
    }

    fn conditional_select(lhs: Self, rhs: Self, predicate: bool) -> Self {
        let mut result = rhs;
        if (predicate) {
            result = lhs;
        }
        result
    }

    // Note: I can't propagate ModulusBits or NumLimbs from a generic that satisfies BigNumTrait due to bugs, so we have to pass NumLimbs and Params in directly. disgusting!
    fn from_bignum<BigNum>(x: BigNum) -> Self
    where
        BigNum: BigNumTrait,
    {
        x.validate_in_field();
        let mut (slices, skew): ([u8; N], bool) = unsafe { get_wnaf_slices2(x) };

        // CONSTRAIN THE HINT. `get_wnaf_slices2` is unconstrained, and these slices are fed
        // straight to `BigCurve::msm` (which indexes its point table with them and never re-derives
        // them) for BOTH ECDSA scalars in `sigver/ecdsa.nr`. Unchecked, a prover picks u1/u2 freely
        // and steers R = u1*G + u2*Q onto any point - signature forgery on every curve.
        //
        // `into_bignum` is NOT usable as the inverse here: it consumes
        // ceil((modulus_bits%120 or 120)/4) + 30*(num_limbs-1) slices, which is one FEWER than N for
        // secp256r1 (64 vs 65) and secp384r1 (96 vs 97). Asserting that round-trip fails those two
        // curves and passes secp521r1, where the counts coincide.
        //
        // So reconstruct over ALL N slices instead. The digits are signed (2*s - 15, i.e. -15..15),
        // which is what makes the BigNum form awkward and why upstream left `From<Field>`'s N>=64
        // branch commented out. Rearranging removes the sign entirely:
        //     sum_i (2*s_i - 15)*16^(N-1-i)  =  2*S - (16^N - 1),   S = sum_i s_i*16^(N-1-i)
        // so the identity to check is   x + skew + (16^N - 1) == 2*S   - both sides non-negative.
        let mut s_acc: BigNum = BigNum::new();
        let mut pow: BigNum = BigNum::one();
        // Built via set_limb, not repeated addition: a digit is 0..15 and 16 fits in limb 0, and a
        // runtime-bounded loop is rejected ("Could not determine loop bound at compile-time").
        let mut sixteen: BigNum = BigNum::new();
        sixteen.set_limb(0, 16);
        for i in 0..N {
            // RANGE-CHECK EVERY SLICE. `base4_slices` is [u8; N], so a prover could otherwise
            // supply 16..255 - the point table is 4-bit, and an out-of-range digit is the second
            // way to lie here, independent of the sum identity below.
            assert(slices[N - 1 - i] < 16, "wNAF slice out of range");
            let mut digit: BigNum = BigNum::new();
            digit.set_limb(0, slices[N - 1 - i] as Field);
            s_acc = s_acc + digit * pow;
            pow = pow * sixteen;
        }
        // pow is now 16^N; the identity is x + skew + (16^N - 1) == 2*S.
        let mut lhs: BigNum = x + pow - BigNum::one();
        if skew {
            lhs = lhs + BigNum::one();
        }
        assert(BigNumTrait::eq(lhs, s_acc + s_acc), "wNAF slices do not decode to the scalar");

        Self { base4_slices: slices, skew }
    }

    fn into_bignum<BigNum>(self) -> BigNum
    where
        BigNum: BigNumTrait,
    {
        let mut result = BigNum::new();
        let mut count: u64 = 0;
        {
            let mut acc = 0;
            let mut last_bits = (result.modulus_bits() % 120) as u64;
            if (last_bits == 0) {
                last_bits = 120;
            }
            let mut last_nibbles = (last_bits / 4) + (last_bits % 4 != 0) as u64;
            for _ in 0..last_nibbles {
                acc = acc * 16;
                acc = acc + (self.base4_slices[count as u32] as Field) * 2 - 15;
                count = count + 1;
            }
            result.set_limb(result.num_limbs() - 1, acc);
        }
        for i in 1..result.num_limbs() {
            let mut acc: Field = 0;
            for _ in 0..30 {
                acc = acc * 16;
                acc = acc + (self.base4_slices[count as u32] as Field) * 2 - 15;
                count = count + 1;
            }
            if acc.lt(0x1000000000000000000000000000000) == false {
                acc += 0x1000000000000000000000000000000;
                result.set_limb(
                    result.num_limbs() - i,
                    result.get_limb((result.num_limbs() - i)) - 1,
                );
            }
            result.set_limb(result.num_limbs() - 1 - i, acc);
        }
        result.set_limb(0, result.get_limb(0) - self.skew as Field);
        result
    }

    fn new() -> Self {
        Self { base4_slices: [0; N], skew: false }
    }
    fn get(self, idx: u64) -> u8 {
        self.base4_slices[idx as u32]
    }
}

