#!/usr/bin/env python3
"""Compare the SPA's hand-written ABI signatures against the compiled contract ABIs.

Catches the class of drift that shipped undetected as §A.5-D1: `spa/src/lib/abi.ts` declared
`get_deposits() returns (uint[13], uint[13], ...)` while the contract returns `uint[15]`. With static
arrays that shifts the head, so every field AFTER the arrays decodes from inside them — silently wrong
numbers on screen, no error anywhere.

Usage:  python3 tools/check-client-abis.py            (from the repo root)
Exit 1 if any signature drifts. Requires `forge build` to have been run.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT  = ROOT / "evm" / "out"
ABI  = ROOT / "spa" / "src" / "lib" / "abi.ts"

def split_args(s: str):
    """Split an arg list on TOP-LEVEL commas only. A naive `s.split(",")` splits inside
    `tuple(a, b, c)`, which mangles the key for EVERY function taking a struct — so every
    such function silently failed the `key in compiled` test below and was skipped as
    "not one of ours". That hid a real arity drift in openChannel (2026-08-07)."""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out

def type_of(a: str) -> str:
    """The TYPE of one declared arg. `a.split()[0]` is wrong for a struct: it yields
    `tuple(bytes32` and loses the rest. solc's ABI calls a struct input just "tuple"
    (fields live in `components`), so collapse the whole balanced group to that token,
    keeping any `[]` suffix."""
    a = a.strip()
    if a.startswith("tuple("):
        depth = 0
        for i, ch in enumerate(a):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    rest = a[i + 1:].strip()
                    # (E178) EXPANDED, matching `ty()` on the artifact side. This used to
                    # collapse to the bare token `tuple`, which only worked because the
                    # artifact side collapsed identically — two wrongs agreeing. Neither
                    # matched what the selector is actually computed over, so any client
                    # writing the real expanded form read as drift.
                    # RECURSIVE, and via `type_of` not a slice, so each component drops its
                    # PARAMETER NAME (`bytes32 fundingBlockHash` → `bytes32`) and nested
                    # structs expand too. A raw slice keeps the names and every struct
                    # signature mismatches on text that is not part of the selector.
                    inner = ",".join(
                        type_of(x) for x in split_args(a[len("tuple("):i]) if x.strip()
                    )
                    return f"({inner})" + (rest.split()[0] if rest.startswith("[") else "")
    return a.split()[0]

def norm(t: str) -> str:
    t = t.strip()

    t = re.sub(r"\buint\b(?!\d)", "uint256", t)
    t = re.sub(r"\bint\b(?!\d)", "int256", t)
    return re.sub(r"\s+", "", t)

def ty(c):
    """(E178) Canonical ABI type — struct params EXPANDED, not left as bare `tuple`.

    ⚠️ THIS USED TO RETURN `c["type"]`, i.e. the literal string `tuple` for every struct
    argument. That made the whole comparison blind on exactly the signatures that carry
    structs — `openChannel`, `splice`, `recordClose`, `deliverSwapOutOnchain` — because a
    client writing the real expanded form could never match `...,tuple,...`. The selector
    is computed over the EXPANDED form, so `tuple` is not what any caller encodes.

    It was survivable while only the SPA was checked (its declarations happened to sit in
    the branch that skips unmatched names), but it produced 16 FALSE POSITIVES the moment
    the Rust tree was added — and a gate that cries wolf is one people learn to ignore,
    which is worse than no gate.
    """
    if c.get("type", "").startswith("tuple"):
        inner = "(" + ",".join(ty(x) for x in c.get("components", [])) + ")"
        return inner + c["type"][len("tuple"):]      # keep any [] / [k] suffix
    return c["type"]

def sig_from_artifact(entry) -> str:
    return f'{entry["name"]}({",".join(norm(ty(i)) for i in entry.get("inputs", []))})'

def ret_from_artifact(entry) -> str:
    return ",".join(norm(ty(o)) for o in entry.get("outputs", []))

# ⛔ `forge build` NEVER PRUNES `evm/out`, SO GHOST ARTIFACTS ACCUMULATE AND SATISFY THIS GATE.
# Measured 2026-08-15: `settleSwapIn` was deleted from BTCChannels, yet 381 artifacts under
# `evm/out` still declared it — including `out/BTCChannels.sol/IAttestedHopRegistry.json`, whose
# whole contract had been deleted. The client kept a call to it (`quid-bridge/src/signer.rs:181`)
# and this checker reported `0 drifted, no ORPHAN`. That is the exact failure the ORPHAN rule was
# added to catch (§E154-client-ghosts, `Vogue.exitInstant`) — reintroduced through the CACHE
# rather than through the regex. An ORPHAN check that resolves against stale output cannot detect
# ANY deletion, which is the class it exists for.
# ⇒ Accept an artifact ONLY if its contract is STILL DECLARED in a source file that STILL EXISTS.
# Audit by STRUCTURE (`^contract`/`^interface`/`^library`), never by a name appearing anywhere in
# the file — a name matches its own obituary in a comment.
SRC_DIRS = [ROOT / "evm" / d for d in ("src", "test", "script", "lib")]
_src_paths: dict[str, list] = {}
for d in SRC_DIRS:
    if not d.is_dir():
        continue
    for sp in d.rglob("*.sol"):
        _src_paths.setdefault(sp.name, []).append(sp)

_declares_cache: dict[tuple, bool] = {}
def still_declared(src_name: str, contract: str) -> bool:
    """True if `contract` is declared in a live `src_name` source file."""
    key = (src_name, contract)
    if key in _declares_cache:
        return _declares_cache[key]
    pat = re.compile(
        r"^\s*(?:abstract\s+)?(?:contract|interface|library)\s+" + re.escape(contract) + r"\b",
        re.M)
    hit = any(pat.search(p.read_text(errors="ignore"))
              for p in _src_paths.get(src_name, []))
    _declares_cache[key] = hit
    return hit

# index every compiled function: name(argtypes) -> returns
compiled, ghosts = {}, 0
for f in OUT.rglob("*.json"):
    # `out/<Source>.sol/<Contract>.json` — both halves must still exist.
    if f.parent.name.endswith(".sol") and not still_declared(f.parent.name, f.stem):
        ghosts += 1
        continue
    try:
        art = json.loads(f.read_text())
    except Exception:
        continue
    for e in art.get("abi", []) or []:
        if e.get("type") != "function":
            continue
        compiled.setdefault(sig_from_artifact(e), set()).add(ret_from_artifact(e))

if not compiled:
    print("no compiled ABIs found under evm/out — run `forge build` first", file=sys.stderr)
    sys.exit(2)
# Print it: a filter whose effect is invisible is indistinguishable from one that never ran.
print(f"indexed {len(compiled)} compiled signatures; skipped {ghosts} GHOST artifacts "
      f"(contract no longer declared in a live source file)")

# Functions the SPA calls on contracts this repo does NOT compile (external protocols).
# Deliberately a dict, not a set: an entry must carry the REASON it is not ours, because an
# unmatched name is otherwise indistinguishable from one that was deleted from our contracts.
# Empty today — every unmatched name found on 2026-08-10 turned out to be ours-and-removed.
EXTERNAL_OK: dict = {}

drift, checked = [], 0
for raw in re.findall(r"'(function [^']+)'", ABI.read_text()):
    m = re.match(r"function\s+(\w+)\s*\((.*?)\)\s*(?:external|public|view|pure|returns|$)", raw)
    if not m:
        continue
    name, args = m.group(1), m.group(2)
    argtypes = [norm(type_of(a)) for a in split_args(args) if a.strip()]
    key = f'{name}({",".join(argtypes)})'
    if key not in compiled:
        # ⚠️ THE FIX THAT MATTERS. This used to `continue` unconditionally, so a signature
        # whose ARGUMENTS had drifted was indistinguishable from an ERC20 helper we never
        # compiled — the single most likely kind of drift was the one kind we could not see.
        # If the NAME exists on one of our contracts, an unmatched key IS drift.
        same_name = sorted(k for k in compiled if k.startswith(name + "("))
        if same_name:
            drift.append((key, "ARG DRIFT — no such signature", same_name))
        elif name not in EXTERNAL_OK:
            # ⚠️ THE SECOND HOLE, closed 2026-08-10 (E154). The `continue` below used to be
            # unconditional, on the assumption that a name matching NOTHING is an external
            # contract's. That assumption was false in both cases it covered: `exitInstant`
            # (deleted from Vogue 2026-08-09 — and the SPA still ENCODED A CALL to it, which
            # would hit the fallback and revert) and `recordSpliceOut` (never existed at all).
            # So the most severe drift — the function is GONE — was the one kind invisible here,
            # while mere argument drift was caught. Absence must be louder than mismatch, not
            # quieter. A genuine external belongs in EXTERNAL_OK with a reason.
            drift.append((key, "ORPHAN — no contract has a function of this name", []))
        continue
    checked += 1
    rm = re.search(r"returns\s*\((.*)\)\s*$", raw)
    declared = ",".join(norm(x.split()[0]) for x in rm.group(1).split(",")) if rm else ""
    if declared not in compiled[key]:
        drift.append((key, declared, sorted(compiled[key])))

# ─────────────────────────────────────────────────────────────────────────────────────
# (E178) THE RUST TREE — the blind spot that let a BROKEN MONEY PATH be committed.
#
# ⚠️ WHY THIS SECTION EXISTS. On 2026-08-11 `openChannel`, `recordClose` and
# `emitDeadManExit` all changed shape, and `quid-hop/src/evm_codec.rs` — the code that
# BUILDS the calldata the daemon sends — kept the OLD signature strings. `forge` was green,
# `tsc` was green, and this checker passed, because it only ever read `spa/`. The daemon
# would have encoded calls to selectors that no longer exist.
#
# ⚠️ AND THE SECOND COPY IS WORSE THAN THE FIRST. `quid-bridge/src/evm_validating_signer.rs`
# keeps a hand-written ALLOWLIST of the same signatures to bound what the hot key may sign.
# It drifted identically — so "fix the allowlist" would have made the enclave cheerfully
# sign calldata that reverts. An allowlist restating the ABI is a SECOND SOURCE OF TRUTH,
# and the drift is the tell that it should be DERIVED, not maintained (§E178).
#
# The Rust strings are already canonical Solidity signatures, so they compare directly.
RUST_ROOTS = [ROOT / "quid-ln"]
RUST_SKIP  = ("/lib/", "/target/", "graphify", "/.git/")
# `cast`-style strings carry a RETURN suffix — `synced()(bool)` — and are not call
# signatures. Matching them would report drift that does not exist.
rust_sig = re.compile(r'"([a-zA-Z_]\w*\([a-zA-Z0-9,\[\]()]*\))"')

rust_drift, rust_checked = [], 0
for base in RUST_ROOTS:
    for p in base.rglob("*.rs"):
        sp = str(p)
        if any(k in sp for k in RUST_SKIP):
            continue
        try:
            text = p.read_text(errors="ignore")
        except OSError:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            for m in rust_sig.finditer(line):
                key = m.group(1)
                if ")(" in key:          # cast-style return suffix, not a call signature
                    continue
                name = key.split("(")[0]
                same_name = sorted(k for k in compiled if k.startswith(name + "("))
                if not same_name:
                    continue            # not one of ours; the SPA rules do not apply here
                if key in compiled:
                    rust_checked += 1
                else:
                    rust_drift.append((key, f"{p.relative_to(ROOT)}:{i}", same_name))

for key, where, actual in rust_drift:
    print(f"RUST DRIFT  {key}\n   at: {where}")
    print(f"   contract has: {[f'{a}' for a in actual]}")
print(f"checked {rust_checked} Rust signatures against evm/out; {len(rust_drift)} drifted")

for key, declared, actual in drift:
    print(f"DRIFT  {key}\n   spa declares: ({declared})")
    print(f"   contract has: {[f'({a})' for a in actual] if actual else 'NOTHING — no function of this name exists'}")
print(f"\nchecked {checked} SPA signatures against evm/out; {len(drift)} drifted")
sys.exit(1 if (drift or rust_drift) else 0)
