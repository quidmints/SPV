/// beta.26: `to_le_bits`/`to_be_bits` return `[bool; N]`, where this library was written against
/// `[Field; N]` and does ARITHMETIC on the bits throughout. Converting at the boundary keeps every
/// algorithm body below byte-identical - substituting `bool` inside them would mean editing
/// modular-arithmetic and hash code, where a rewritten expression is a silently different result.
pub fn bits_to_field<let N: u32>(bits: [bool; N]) -> [Field; N] {
    let mut out: [Field; N] = [0; N];
    for i in 0..N {
        out[i] = bits[i] as Field;
    }
    out
}

pub fn switcher(l: Field, r: Field, bit: Field) -> (Field, Field){
    let aux = (r - l) * (bit as Field);
    (aux + l, -aux + r)
}
