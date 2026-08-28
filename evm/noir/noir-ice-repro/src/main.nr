// MINIMAL REPRODUCTION of the ICE that blocked six circuits on nargo 1.0.0-beta.26.
//
//   $ nargo compile --program-dir noir-ice-repro
//   ice: all function ids should have metadata
//   compiler/noirc_frontend/src/node_interner/function.rs:176
//
// TRIGGER: a GENERIC OPERATOR-OVERLOAD impl invoked during comptime evaluation of a `global`.
// Move the same call out of global scope (see `main` below) and it compiles. Remove the const
// generic, or use an ordinary trait such as `From` instead of an operator, and it compiles.
//
// This is a COMPILER bug, not misuse: 14 lines, no dependencies. beta.26 is the newest release and
// still has it.
//
// FIXED — see `noir-fix.patch` beside this file. Three hunks, two files: two `function_meta` calls
// in `bind_trait_impl_func_generics_to_trait_func_generics` and one in `get_trait_item_id` become
// `try_function_meta`. Comptime evaluation of a global reaches a trait method through an operator
// overload BEFORE it is elaborated, so its `FuncMeta` legitimately does not exist yet.
// Safe by construction: identical behaviour whenever the metadata exists, and where it does not the
// previous behaviour was a crash, so there is nothing to regress. `get_trait_item_id` already
// returns `Option` and every caller handles `None`.
//
// The patch is NOT applied to the pinned toolchain — this repo must build with released beta.26.
// Keep the accommodation in noir_dl_lib until the fix ships upstream. See NOIR-DL-PORT.md.
pub struct U<let N: u32> {
    limbs: [Field; N],
}

impl<let N: u32> std::ops::Add for U<N> {
    fn add(self, other: Self) -> Self {
        let mut r: [Field; N] = [0; N];
        for i in 0..N {
            r[i] = self.limbs[i] + other.limbs[i];
        }
        U { limbs: r }
    }
}

fn build<let N: u32>(a: [Field; N]) -> [Field; N] {
    let u: U<N> = U { limbs: a };
    (u + u).limbs
}

// ICE. Comment this out and call `build([1, 2])` from `main` instead: compiles clean.
global G: [Field; 2] = build([1, 2]);

fn main(x: Field) -> pub Field {
    x + G[0]
}
