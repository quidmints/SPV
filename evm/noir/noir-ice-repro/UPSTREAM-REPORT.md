# Upstream submission — ✅ FILED as noir-lang/noir#13440 (2026-08-02)

**https://github.com/noir-lang/noir/issues/13440**

Kept for the record: the reproduction, the narrowing table and the suggested patch below are what
was submitted. `noir-fix.patch` in this directory applies cleanly to tag `v1.0.0-beta.26` if a PR is
wanted as well — an issue was filed rather than a PR because that needs a fork of noir-lang/noir.

**Our accommodation stays until the fix ships in a RELEASE.** `noir_dl_lib` still converts its
`BigNumParams::new` globals to functions so the circuits build on stock beta.26; revert that when
upstream releases, not when the issue closes.

**WHY AN ISSUE AND NOT A PR.** A pull request to `noir-lang/noir` requires forking it under our
account; an issue does not, and nothing was forked. The issue carries the full patch inline, so a
maintainer can apply it directly. If a PR is wanted later, `noir-fix.patch` here applies cleanly to
tag `v1.0.0-beta.26` — fork, apply, push a branch, open the PR against `master`.

---

## Title

ICE: `all function ids should have metadata` when a generic operator-overload impl is evaluated in a `global`

## Body

### Description

`nargo compile` panics with an internal compiler error when a `global`'s initializer reaches a
generic operator-overload impl during comptime evaluation.

```
ice: all function ids should have metadata
compiler/noirc_frontend/src/node_interner/function.rs:176
```

### Minimal reproduction (14 lines, no dependencies)

```rust
pub struct U<let N: u32> { limbs: [Field; N] }

impl<let N: u32> std::ops::Add for U<N> {
    fn add(self, other: Self) -> Self {
        let mut r: [Field; N] = [0; N];
        for i in 0..N { r[i] = self.limbs[i] + other.limbs[i]; }
        U { limbs: r }
    }
}

fn build<let N: u32>(a: [Field; N]) -> [Field; N] {
    let u: U<N> = U { limbs: a };
    (u + u).limbs
}

global G: [Field; 2] = build([1, 2]);   // <-- ICE. Call `build` from `main` instead: compiles.

fn main(x: Field) -> pub Field { x + G[0] }
```

### Narrowed by elimination

| variant | result |
|---|---|
| as above | **ICE** |
| identical call made from `main` rather than a `global` | compiles |
| ordinary trait (`std::convert::From`) instead of an operator, still in a `global` | compiles |
| operator impl without the const generic | compiles |

So the trigger is specifically **generic operator overload + comptime global**.

### Version

`nargo 1.0.0-beta.26` (newest release at time of writing; also reproduced from a source build of
tag `v1.0.0-beta.26`).

### Cause

Comptime evaluation of a global reaches a trait method through an operator overload **before that
method has been elaborated**, so its `FuncMeta` does not exist yet. Three call sites demand it with
`expect`. Backtrace:

```
elaborate_global -> evaluate_let -> evaluate_infix -> resolve_trait_item
  -> record_impl_instantiation_bindings -> function_meta -> panic
```

and, once that one is handled, a second path:

```
Interpreter::call_function -> NodeInterner::get_trait_item_id -> function_meta -> panic
```

### Suggested fix

Three hunks, two files, all `function_meta` -> `try_function_meta`:

- `monomorphization/mod.rs::bind_trait_impl_func_generics_to_trait_func_generics` (2 sites) —
  return early. The function only *adds* bindings, so skipping degrades to "no extra bindings".
- `node_interner/mod.rs::get_trait_item_id` — yield `None`. It already returns `Option` and every
  caller handles `None`, so this is its existing contract rather than a new one.

This is safe by construction: behaviour is identical whenever the metadata exists, and where it does
not, the previous behaviour was a crash — so there is nothing to regress.

### Verification

- the reproduction above compiles
- a real-world case (a vendored `noir-bignum` fork whose curve parameter globals call
  `BigNumParams::new`, which uses an `Add` impl internally) compiles — this blocked 6 circuits
- `cargo test --release -p noirc_frontend`: **2223 passed, 0 failed**

  (Note for macOS: `tests::deeply_nested::deeply_nested_terms` overflows the default thread stack in
  a release build regardless of this change; run with `RUST_MIN_STACK=134217728`.)
