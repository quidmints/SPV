# Upstream reports from regenerating every published passport profile

**Found:** 2026-08-10, regenerating all 78 `registerIdentity_*` profiles on a newer toolchain.
**Status:** ready to file, none filed — `gh` is not installed here and no upstream credentials are
configured.

⚠️ **THESE GO TO TWO DIFFERENT PROJECTS. Do not file them as one issue.**

| item | repo | summary |
|---|---|---|
| 1 | `rarimo/passport-zk-circuits-noir` | one profile cannot compile: AA key runs 8 bytes past `dg15` |
| 2 | `rarimo/passport-zk-circuits-noir` | **the same gap silently affects five profiles that DO ship** |
| 3 | `rarimo/passport-zk-circuits-noir` | optional: self-consistency checks for the generated tuples |
| 4 | **`AztecProtocol/barretenberg`** | **bb regression** — a circuit 5.1.0 builds, 6.0.0-nightly refuses by 0.4% |

Items 1–3 are independent of each other; (2) is the one with live consequences and stands alone.
Item 4 is a different project entirely and is the strongest of the four, because it has a clean
before/after in a single repository's history.

---

## 1. One profile cannot compile: the AA key runs past `dg15`
## (STILL VALID UPSTREAM — fixed locally, see the note at the end of this section)

`registerIdentity_20_256_3_5_336_248_25_2120_5_1816` (published in `v0.2.4`) does not compile on
nargo `1.0.0-beta.26`:

```
bug: Assertion is always false: Index out of bounds
    not_passports_zk_circuits.nr:672  in extract_dg15_pk_hash
...
circuit is unsatisfiable. An AssertZero opcode contains no variables but has a non-zero constant
```

It **does** compile on `1.0.0-beta.1`, which is what the published artifact was built with — the
newer compiler is not regressing, it is diagnosing something that was always there.

### The arithmetic

`extract_dg15_pk_hash` selects the AA key size from `AA_SIG_TYPE`:

```noir
let mut HASH_SIZE = 31;
let mut EC_FIELD_SIZE = 32;
if (AA_SIG_TYPE == 22) { EC_FIELD_SIZE = 40; }
if (AA_SIG_TYPE == 23) { EC_FIELD_SIZE = 24; HASH_SIZE = 24; }

let X_Y_SHIFT = EC_FIELD_SIZE - HASH_SIZE;
for j in 0..HASH_SIZE {
    x += (dg15[AA_SHIFT + (HASH_SIZE - 1 - j) + X_Y_SHIFT]) as Field * current;
    y += (dg15[AA_SHIFT + (HASH_SIZE - 1 - j) + X_Y_SHIFT + EC_FIELD_SIZE]) as Field * current;
    current *= 256;
}
```

This profile declares `AA_SIG_TYPE = 25`, which matches no branch, so it takes the 32-byte default.
With its published generics — `DG15_LEN = 283`, `AA_SHIFT = 227` — the highest `y` index is

```
AA_SHIFT + (HASH_SIZE-1) + X_Y_SHIFT + EC_FIELD_SIZE
  = 227 + 30 + 1 + 32
  = 290        against dg15: [u8; 283]      → 8 past the end
```

The generics are not in question: they are read verbatim from the artifact's own embedded `main.nr`
(`register_identity::<93, 283, 297, 74, 6, 256, 32, 32, 20, 31, 265, 42, 25, 227>`) and agree with its
ABI.

### What we did **not** do

We did not add a local `AA_SIG_TYPE == 25` branch. Solving `AA_SHIFT - 1 + 2*EC_FIELD_SIZE = DG15_LEN - 1`
gives `EC_FIELD_SIZE = 28`, which fits exactly — and every other ECDSA-AA profile does land exactly on
`DG15_LEN - 1`, so 28 is plausible. **But a local patch would make our verifier check a different
statement than your prover produces**, silently. It belongs here, from whoever knows what curve
`AA_SIG_TYPE 25` denotes.

---

## 2. ⚠️ CORRECTED — the gap affects ONE more type, not five profiles

**The original claim here was too broad and is fixed in place.** It said `AA_SIG_TYPE` 20, 21 and 24
all match no branch and are therefore wrong. **20 and 21 are 32-byte curves (secp256r1,
brainpoolP256r1), so the 32-byte default is CORRECT for them** — having no branch is not a defect
when the fall-through value is right.

The real defect is confined to types whose true coordinate width differs from 32:

| `AA_SIG_TYPE` | curve | true width | code used | verdict |
|---|---|---|---|---|
| 20 | secp256r1 | 32 | 32 | fine |
| 21 | brainpoolP256r1 | 32 | 32 | fine |
| 24 | secp224r1 | **28** | 32 | **wrong — both coordinates read from the wrong offsets** |
| 25 | brainpoolP384r1 | **48** | 32 | **wrong — same, and its only profile also fails to compile** |

⚠️ **Type 24 fails SILENTLY**, which is why it is the more dangerous of the two: the circuit builds,
proves, and verifies, while `dg15_pk_hash` commits to something that is not the Active Authentication
key. Type 25's profile at least refuses to compile.

The profiles that merely "have no branch" and are unaffected are listed below for completeness:

| profile | `AA_SIG_TYPE` |
|---|---|
| `registerIdentity_1_256_3_7_336_264_20_2760_6_2008` | 20 |
| `registerIdentity_25_384_3_5_576_248_20_3768_3_2008` | 20 |
| `registerIdentity_21_256_3_7_336_264_21_3072_6_2008` | 21 |
| `registerIdentity_2_256_3_6_336_264_21_2448_6_2008` | 21 |
| `registerIdentity_28_384_3_3_576_264_24_2024_4_2792` | 24 |

**If 32 bytes is not the correct key size for those curves, these verifiers read the wrong bytes of
`dg15` as the Active Authentication public key — with no error, at any stage.** The out-of-bounds on
`AA_SIG_TYPE 25` is the lucky case: it is the only one whose mistake was large enough to escape the
array and be caught by a compiler.

We cannot tell from outside whether 32 is right for 20, 21 and 24 — that needs the curve each value
denotes. If 32 is correct for all three, item 2 is a no-op and only 25 needs a branch. If it is not,
five shipped profiles are affected.

**Suggested minimum:** make the fall-through explicit rather than silent, e.g.

```noir
assert(AA_SIG_TYPE == 20 | AA_SIG_TYPE == 21 | AA_SIG_TYPE == 22
     | AA_SIG_TYPE == 23 | AA_SIG_TYPE == 24, "unhandled AA_SIG_TYPE");
```

so a new value fails loudly at compile time instead of inheriting a default.

---

## 3. Optional: a self-consistency check for the generated tuples

Three `v0.1.0` profiles are also uncompilable, from a different defect —
`registerIdentity_21_160_1_2_560_576_NA`, `registerIdentity_14_256_1_4_1752_576_1_1496_3_512`,
`registerIdentity_1_256_1_5_2376_336_1_2120_4_512` each declare `DG1_LEN = 0` (a circuit that reads no
MRZ) **and** `DG1_SHIFT == EC_LEN`, so `assert(dg1_hash[i] == ec[i + DG1_SHIFT])` reads past `ec`.
No profile outside these three has `DG1_SHIFT == EC_LEN`; working values lie in 23..33.

Every one of these defects is arithmetic on numbers already in the emitted tuple, checkable in
milliseconds without a document, a build, or a proving run:

- `DG1_LEN != 0`
- `DG1_SHIFT + DG_HASH_ALGO <= EC_LEN`
- `DG15_SHIFT + DG_HASH_ALGO <= EC_LEN` when `DG15_LEN > 0`
- `EC_SHIFT + HASH_ALGO <= SA_LEN`
- `AA_SHIFT + (HASH_SIZE-1) + X_Y_SHIFT + EC_FIELD_SIZE <= DG15_LEN - 1` when `AA_SIG_TYPE >= 20`

Our implementation is `tools/check-passport-profile-consistency.py`; it clears all 78 profiles we
build and refuses exactly the four above. Happy to port it to whatever form suits your generator.

---

# 4. ⚠ REGRESSION: a circuit bb 5.1.0 builds, bb 6.0.0-nightly.20260804 refuses by 0.4%

Separate from items 1–3, and the strongest of the four because there is a clean before/after.

**Same circuit, same nargo, same generics. Only bb changed.**

| bb | result |
|---|---|
| **5.1.0** | builds `registerIdentity_25_384_3_5_576_248_20_3768_3_2008` and `..._28_384_3_3_576_264_24_2024_4_2792` successfully |
| **6.0.0-nightly.20260804** | `write_vk` aborts |

Both verifiers are committed artifacts produced under `REQUIRED_BB="5.1.0"`; nargo was
`1.0.0-beta.26` in both cases and did not change.

### The failure

```
CircuitProve: Proving key computed in 2158032 ms (mem: 12494.55 MiB)
libc++abi: terminating due to uncaught exception of type std::runtime_error:
  Assertion failed: (aligned_local + bytes <= bound)
  Left   : 124990672
  Right  : 124518529
```

Note the proving key **succeeds**. The abort is in `write_vk` afterwards, and the overflow is
**472,143 bytes — 0.4%** of a ~124.5 MB bound.

### What we ruled out, by measurement

| | |
|---|---|
| host memory | not the cause — 32 GiB swapfile available, bb peaked at 12.4 GB, well under |
| thread count | `HARDWARE_CONCURRENCY` honoured, peak unchanged |
| `--slow_low_memory` | **helps and is worth noting**: with it the proving key computes, where without it bb aborts *before* reaching that point. Does not clear this second bound. |
| `--storage_budget` | **no effect at all.** `8g` and `512m` produce a **byte-identical** bound — `Left 124990672 / Right 124518529` both times. A 16× change moves it by zero. |

That invariance is the useful signal: the bound is **not** the FileBackedMemory budget it looks like.

### ⚠️ This is NOT the case fixed by #24249

`fix(bb): size Pippenger MSM arena for the non-GLV mid-band` (#24249, merged 2026-06-24, commit
`6deae818`) targets this exact assertion in `MsmArena::bump_alloc`. **That fix is already in our
build** — it is an ancestor of `next`, `next` is this repository's default branch, and our pin is
`6.0.0-nightly.20260804`, six weeks later. The assertion still fires.

#24249 addressed the non-GLV mid-band, 8,192–131,072 points, "around ~28,696 points". **This circuit
needs a 2^25 CRS**, far outside that band, and overshoots by 0.4% after the proving key has already
been computed. So it appears to be a second, larger-scale instance of the same arena-sizing class,
not a regression of the fix.

### Why it matters downstream

A verifier built under 5.1.0 does not accept proofs from a 6.0 prover (they fail at
`verification failed at reduction step`, with **zero VK constants differing** — so no key comparison
detects it). Consumers therefore cannot regenerate these two verifiers to match a 6.0 prover, and
cannot keep using the 5.1.0 ones either. The profiles become unusable rather than merely stale.

Happy to supply the exact circuit, generics tuple, and container recipe on request.

---

## ⚠️ RETRACTED — `14_256_1_4_1752_576_1_1496_3_512` is NOT unsatisfiable

**Do not send this. The original claim was wrong and is kept only so the error is not repeated.**

It read: the AA reader takes a fixed 128 bytes from `AA_SHIFT = 64`, forcing `DG15_LEN >= 192`, while
`DG15_BLOCK_NUMBER = 3` caps it at 183 after SHA-256 padding — therefore no input satisfies it.

**What is actually true:** the 128-byte read is OUR assumption, not the profile's. It is hardcoded in
`extract_dg15_pk_hash`, which treats every RSA Active Authentication key as 1024-bit. This profile's
key is **768-bit**: `AA_SHIFT(64) + modulus(96) + exponent(5) = 165 = DG15_LEN`, exactly, with zero
slack. The profile is fine; the reader was too narrow. It now selects on whether a 1024-bit key
physically fits, and the profile builds.

A supporting argument in the original was also wrong: that no DER layout puts a modulus at offset 64.
Our own table refutes it — every working ECDSA-AA profile sits far past its bare-SPKI offset (251 vs
~27, 349 vs ~26). A dg15 prefix is ordinary, so the offset was never evidence of anything.

**The lesson, since it recurred four times in one session:** a limit of our own vendored library read
as a property of the artifact. Before reporting a defect upstream, finish the sentence *"this is
impossible because \<file\> does \<thing\>"* — if that file is in our tree, it is a task, not a bug
report.

## rarimo — `extract_dg15_pk_hash` has no branch for `AA_SIG_TYPE 25` (BrainpoolP384r1)

**Severity:** latent wrong-key extraction; the one profile that would exercise it is also unsatisfiable.

`extract_dg15_pk_hash` sets `EC_FIELD_SIZE = 32` and overrides it only for `AA_SIG_TYPE 22` (40) and
`23` (24). `SIG_TYPE 25` is **BrainpoolP384r1** — confirmed by reading its `verify_signature` branch,
which builds `BrainpoolP384r1Fr` from four limbs — so its public-key coordinates are **48 bytes**.

With no branch, `AA_SIG_TYPE 25` falls through to 32. The extractor then reads

```
x = dg15[AA_SHIFT + (HASH_SIZE-1-j) + X_Y_SHIFT]
y = dg15[AA_SHIFT + (HASH_SIZE-1-j) + X_Y_SHIFT + EC_FIELD_SIZE]
```

with `X_Y_SHIFT = EC_FIELD_SIZE - HASH_SIZE = 1` instead of `48 - 31 = 17`, and reads `y` at an
offset 32 bytes after `x` rather than 48. Both coordinates are therefore taken from the wrong bytes,
and `dg15_pk_hash` does not commit to the actual AA key. It is latent only because
`20_256_3_5_336_248_25_2120_5_1816` is the sole profile using it.

That profile cannot be repaired by adding the branch, because it is independently unsatisfiable:

| | bytes |
|---|---|
| read extent with the correct 48-byte field | `AA_SHIFT(227) + 30 + 17 + 48` = **323** |
| `dg15` capacity, `DG15_BLOCK_NUMBER(5) * 64 - 9` padding | **311** |

So `DG15_LEN` would have to be at least 323 and at most 311. The published `DG15_LEN` of 283 does not
satisfy even the incorrect 32-byte read, which needs 291.

Separately, the geometry looks wrong regardless: a dg15 carrying a BrainpoolP384r1 key DER-encodes to
about 126 bytes with the point starting near byte 30, not byte 227.

**Suggested fix:** add `if (AA_SIG_TYPE == 25) { EC_FIELD_SIZE = 48; }`, and re-derive that profile's
`AA_SHIFT` and `DG15_BLOCK_NUMBER` — the branch alone does not make it buildable.

---

## Status of these reports (2026-08-13)

**None have been sent** — this repo has no `gh` credentials, so filing is a manual step for the
owner. What follows is what a reader should know before sending any of them.

| # | subject | still true upstream? | our tree |
|---|---|---|---|
| 1 | `AA_SIG_TYPE 25` profile does not compile | **yes** | fixed: branch added, `DG15_LEN` re-derived to 323, profile builds |
| 2 | AA coordinate widths (types 24 and 25) | **yes** | fixed: 24 → 28 bytes, 25 → 48 |
| 3 | a self-consistency checker for the tuples | yes, offered | `tools/check-passport-profile-consistency.py` |
| — | `14_256_1_4` "unsatisfiable" | **NO — retracted** | our reader was too narrow; the profile builds |
| 5 | `AA_SIG_TYPE 25` has no branch | **yes** | fixed |

⚠️ **Two of these were WRONG when written and are corrected above rather than deleted.** One claimed a
profile was unsatisfiable when the limitation was in our own reader; the other counted five affected
profiles when the fall-through value is correct for three of them. Both errors have the same shape — a
property of our code reported as a property of theirs — and a bug report is the worst place for it,
since the recipient cannot check our tree.
