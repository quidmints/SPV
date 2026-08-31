#!/usr/bin/env python3
"""Fail when a `src/` function's ONLY callers are its own tests.

⭐ WHY THIS IS A GATE AND NOT A RULE. CLAUDE.md already carried the rule that would have caught
   this — line 315, *"Count self-caught vs prompted corrections… zero were caught by the author"* —
   written on 2026-08-09 from a session with the identical shape. On 2026-08-29 a session with that
   rule in context shipped THREE functions whose only callers were their own tests
   (`borrowRateRay`, `supplyHeadroom`, `slipBpsForTest`) and did not notice until the owner asked.
   ⇒ A rule that has already failed once at the exact thing it describes is not the instrument.
   The repo's eight `check-*.py` gates are, because they fail a build instead of asking to be read.

THE SIGNATURE THIS DETECTS — "built but unwired": the cheap measurement layer of a feature lands,
its tests are green and honest, and the expensive structural layer that would CONSUME it never
does. Nothing is broken, nothing is unreachable in the rule-1 sense, every test passes, and the
tree silently claims a capability it does not have. It is invisible to `forge build`, to
`forge test`, and to a name-grep (the name is there; it is the CALLER that is missing).

WHAT IT IS NOT. This is not dead-code detection. An `external` entrypoint called only by the Rust
keeper is correctly wired — so `quid-ln/`, `evm/script/` and `evm/test/utils/` all count as
production callers. The flag fires ONLY when the callers are exclusively test BODIES.

FALSE-POSITIVE CLASSES, NAMED (per the standing rule that a sweep is not a finding until they are):
  · interface members            — `interface I…{}` declares, never implements. Skipped.
  · keeper/script entrypoints    — referenced from Rust or deploy scripts. Counted as production.
  · test harness helpers         — `evm/test/utils/` is infrastructure, not a test body. Counted.
  · deliberate exceptions        — `tools/orphans-allow.txt`, one `name  # reason` per line. The
                                   reason is REQUIRED: an allowlist without one is how this rots.

Usage:  python3 tools/check-orphans.py [--list]
Exit 1 if any unallowed orphan is found.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC, TEST = os.path.join(ROOT, "evm", "src"), os.path.join(ROOT, "evm", "test")
PROD_DIRS = [SRC, os.path.join(ROOT, "quid-ln"), os.path.join(ROOT, "evm", "script"),
             os.path.join(ROOT, "evm", "test", "utils")]
ALLOW  = os.path.join(ROOT, "tools", "orphans-allow.txt")
IFACES = os.path.join(ROOT, "evm", "src", "imports", "Interfaces.sol")

DECL = re.compile(r"^\s*function\s+([A-Za-z_]\w*)\s*\(", re.M)
IFACE = re.compile(r"^\s*(?:interface|abstract\s+contract)\s+\w+", re.M)


def walk(d, exts=(".sol",)):
    for base, _, fs in os.walk(d):
        if "/out/" in base or "/lib/" in base or "/target/" in base or "/node_modules/" in base:
            continue
        for f in fs:
            if f.endswith(exts) or (d.endswith("quid-ln") and f.endswith(".rs")):
                yield os.path.join(base, f)


def iface_spans(text):
    """Byte ranges belonging to `interface` blocks — declarations there are not implementations."""
    spans, i = [], 0
    for m in IFACE.finditer(text):
        if text[m.start():m.end()].lstrip().startswith("abstract"):
            continue
        j, depth, seen = m.end(), 0, False
        while j < len(text):
            if text[j] == "{":
                depth += 1; seen = True
            elif text[j] == "}":
                depth -= 1
                if seen and depth == 0:
                    break
            j += 1
        spans.append((m.start(), j))
    return spans


def load_allow():
    allow = {}
    if os.path.exists(ALLOW):
        for ln in open(ALLOW):
            ln = ln.split("#")[0].strip(), ln.split("#", 1)[1].strip() if "#" in ln else ""
            if ln[0] and not ln[0].startswith("//"):
                allow[ln[0]] = ln[1]
    return allow


def main():
    allow = load_allow()
    # ⭐ THE UNIT IS AN INTERFACE MEMBER, NOT A FUNCTION. Scanning every `src/` declaration
    #    produced 40+ hits dominated by USER-FACING API (`totalAssets`, `root`, `withdrawBatch`) —
    #    an `external` entrypoint with no internal Solidity caller is CORRECT, external integrators
    #    are the caller. An INTERNAL interface is different: it exists so OUR code can call through
    #    it, so a member nothing calls is a seam built for a consumer that was never written.
    declared = {}                                   # name -> (file, line)
    text = open(IFACES, errors="ignore").read()
    for a, b in iface_spans(text):
        for m in DECL.finditer(text[a:b]):
            name = m.group(1)
            declared.setdefault(name, ("evm/src/imports/Interfaces.sol",
                                       text[:a + m.start()].count("\n") + 1))

    # the interface FILE itself declares each name once; that is not a call
    prod, tests = {}, {}
    for d in PROD_DIRS:
        if not os.path.isdir(d):
            continue
        for f in walk(d):
            for name, cnt in count_in(f, declared):
                prod[name] = prod.get(name, 0) + cnt
    for f in walk(TEST):
        if "/utils/" in f:
            continue
        for name, cnt in count_in(f, declared):
            tests[name] = tests.get(name, 0) + cnt

    orphans = []
    for name, (f, ln) in sorted(declared.items()):
        # a declaration references its own name once; production use means MORE than the decl
        if prod.get(name, 0) == 0:
            orphans.append((name, f, ln, tests.get(name, 0)))

    bad = [o for o in orphans if o[0] not in allow]
    if "--list" in sys.argv:
        for name, f, ln, t in orphans:
            tag = "ALLOWED" if name in allow else "ORPHAN "
            print(f"{tag} {name:34s} {f}:{ln}  ({t} test refs)")
    if bad:
        print(f"\n\033[31m{len(bad)} interface member(s) NOTHING in evm/src calls — built but unwired:\033[0m")
        for name, f, ln, t in bad:
            print(f"  {name:34s} {f}:{ln}   (src callers: 0, test refs: {t})")
        print("\nWire it to a production caller, delete it, or add it to tools/orphans-allow.txt")
        print("with a reason naming the work that will consume it.")
        return 1
    print(f"OK — {len(declared)} interface members in Interfaces.sol, {len(orphans)} with no src caller ({len(allow)} allowed).")
    return 0


CALL = re.compile(r"\b([A-Za-z_]\w*)\s*[({.]")


def count_in(f, declared):
    """ONE tokenising pass per file. A per-name regex over every file was O(names x files) and
    did not finish on this tree (~5k declarations, ~1.7k files)."""
    try:
        text = open(f, errors="ignore").read()
    except OSError:
        return
    text = re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)   # a MENTION is not a call
    # ⚠️ AND A DECLARATION IS NOT A CALL. `function borrowRateRay(` matches the call pattern, so
    #    both the interface declaration AND every implementation scored as a caller — which is why
    #    the first run of this gate reported 0 orphans on a tree that had three.
    text = re.sub(r"\bfunction\s+[A-Za-z_]\w*\s*\(", " (", text)
    seen = {}
    for m in CALL.finditer(text):
        n = m.group(1)
        if n in declared:
            seen[n] = seen.get(n, 0) + 1
    return seen.items()


if __name__ == "__main__":
    sys.exit(main())
