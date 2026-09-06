#!/usr/bin/env python3
"""Route a change to the SMALLEST test set that can falsify it.

Why this exists: a full `forge test` is ~250s and a full `forge build` is ~105s warm
(~342s cold). Running either after every one of ~400 SPRINT.md items is ~2 days of
pure compile. But a change to `BTCChannels.sol` cannot be falsified by an identity
test, and 70 of 155 `.t.sol` files reference NO money-path contract at all.

  usage:  python3 tools/impacted-tests.py                 # uses `git diff --name-only`
          python3 tools/impacted-tests.py evm/src/Quid.sol ...
          python3 tools/impacted-tests.py --cmd           # print the forge command

⚠️ THIS IS A ROUTER, NOT A GATE. It selects what to run DURING a lane; the full suite
   still runs once before anything merges. CLAUDE.md's rule stands: a green targeted
   run says nothing about the suites it did not execute.

⚠️ WHY NOT `graphify affected` (CLAUDE.md rule 8, "don't hand-roll what a tool already does"):
   the graph is STALE BY DEFAULT -- measured 2026-09-06, built_at_commit 7c5bc10d against a HEAD
   of f3ac46bb. A router must read the LIVE tree or it routes around the file you just edited.
   The two AGREE on the known positive (both select LevCascade/LevYbReal/LeverageCrossSubsidy
   for LevManager), so use `graphify affected` to UNDERSTAND structure and this to ROUTE a change.

⚠️ AND ITS FALSE-NEGATIVE CLASS IS NAMED, per CLAUDE.md's sweep rule: it maps by SYMBOL
   REFERENCE, so it cannot see a test that reaches a contract only through an address,
   a raw slot read, or a deploy script. `UnificationControls.t.sol` reads mock addresses
   from RAW SLOTS and is therefore in ALWAYS below rather than matched.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC, TEST = ROOT / "evm/src", ROOT / "evm/test"

# Suites that must run for ANY evm/src change, because symbol matching cannot see how
# they reach the code. Each entry needs a reason -- an unexplained entry is a silent
# widening of every run, which is the cost this tool exists to avoid.
ALWAYS = {
    "UnificationControls.t.sol": "reads mock addresses from RAW SLOTS; coupled to Core's state ORDER, not to any symbol",
    "Alles.t.sol": "whole-system integration; reaches contracts through a deploy script rather than by name",
}

DECL = re.compile(r"^\s*(?:abstract\s+)?(?:contract|library|interface)\s+(\w+)", re.M)
IMPORT = re.compile(r'import\s+.*?["\']([^"\']+)["\']', re.S)


def changed_files() -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "diff", "--name-only", "HEAD"],
        capture_output=True, text=True,
    ).stdout
    return [l for l in out.splitlines() if l.strip()]


def symbols_of(path: Path) -> set[str]:
    """Every contract/library/interface a file declares, plus its own basename."""
    try:
        text = path.read_text(errors="ignore")
    except OSError:
        return set()
    return set(DECL.findall(text)) | {path.stem}


def reverse_importers(targets: set[Path]) -> set[Path]:
    """One level of reverse-import: a change to SwapLib impacts Aux's tests too.

    Deliberately ONE level, not transitive: in this tree Interfaces.sol is imported by
    nearly everything, so a transitive closure selects the whole suite and the tool
    stops discriminating -- which is the same 'sweep that does not name its
    false-positive class' failure CLAUDE.md records.
    """
    names = {t.stem for t in targets}
    hit = set()
    for f in SRC.rglob("*.sol"):
        if f in targets:
            continue
        text = f.read_text(errors="ignore")
        for imp in IMPORT.findall(text):
            if Path(imp).stem in names:
                hit.add(f)
                break
    return hit


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_cmd = "--cmd" in sys.argv
    files = args or changed_files()

    sol = [ROOT / f for f in files if f.startswith("evm/src/") and f.endswith(".sol")]
    rust = sorted({f.split("/")[1] for f in files if f.startswith("quid-ln/") and "/" in f[9:]})
    docs = [f for f in files if f.endswith((".md", ".txt"))]
    tests_touched = [f for f in files if f.startswith("evm/test/")]

    if not sol and not rust and not tests_touched:
        print("# NO BUILD NEEDED — prose/config only" if docs else "# no impacted targets")
        print(f"#   {len(docs)} doc file(s); a lane that only edits .md never compiles")
        return 0

    targets = set(sol) | reverse_importers(set(sol))
    syms = set()
    for t in targets:
        syms |= symbols_of(t)

    selected = {Path(f).name for f in tests_touched if f.endswith(".t.sol")}
    for tf in TEST.rglob("*.t.sol"):
        text = tf.read_text(errors="ignore")
        if any(re.search(rf"\b{re.escape(s)}\b", text) for s in syms):
            selected.add(tf.name)
    selected |= set(ALWAYS)

    total = sum(1 for _ in TEST.rglob("*.t.sol"))
    if as_cmd:
        pat = "|".join(sorted(re.escape(s) for s in selected))
        print(f"cd evm && forge build && FORK_BLOCK=$(cast block-number --rpc-url "
              f"https://ethereum-rpc.publicnode.com) forge test --match-path 'test/**/({pat})'")
        return 0

    print(f"# changed: {len(sol)} src + {len(tests_touched)} test"
          f"{f' + {len(rust)} rust crate(s)' if rust else ''}")
    print(f"# direct + 1-level reverse-import = {len(targets)} contract file(s)")
    print(f"# IMPACTED SUITES: {len(selected)} / {total}"
          f"  ({100 * len(selected) // max(total, 1)}%)")
    for s in sorted(selected):
        why = ALWAYS.get(s)
        print(f"    {s}{'   <- ALWAYS: ' + why if why else ''}")
    for c in rust:
        print(f"# rust: cargo test -p {c}    (NOT `cargo check` — it never builds test targets)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
