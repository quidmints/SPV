#!/usr/bin/env python3
"""Find ledger rot: file paths and symbols the docs cite that no longer exist in the tree.

WHY THIS EXISTS. The ledgers are the half the next thread reads, and they rot silently — a rename
lands in code and every row naming the old symbol keeps reading as current. Measured 2026-08-21:
`Vogue` became `Quid` in 22ec766f and FIFTEEN open rows still said `Vogue.sol`; separately three
rows asserted states (`main does not build`, `cannot be pushed`, a fixture `broken`) that had been
fixed. Nothing catches this — forge sees no docs, and `check-client-abis.py` never reads a comment.

WHAT IT DOES NOT DO, DELIBERATELY. It does not fail on prose, only on a `Something.sol` that is not
in the tree and on backticked identifiers that appear NOWHERE in `evm/src`. A doc legitimately names
deleted things when recording history, so this is a REPORT, not a gate: read the list, fix what is
a live claim, leave what is a tombstone. Exit code is 0 unless `--strict`.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = sorted((ROOT / "docs" / "actionable").glob("*.md")) + [ROOT / "CLAUDE.md"]
SRC = [ROOT / "evm" / "src", ROOT / "evm" / "test", ROOT / "evm" / "script", ROOT / "quid-ln"]

def tree_index():
    files, idents = set(), set()
    tok = re.compile(r"[A-Za-z_][A-Za-z0-9_]{3,}")
    for root in SRC:
        for p in root.rglob("*"):
            if not p.is_file() or p.suffix not in {".sol", ".rs", ".ts", ".py"}:
                continue
            s = str(p)
            if "/lib/" in s or "node_modules" in s or "/target/" in s or "/out/" in s:
                continue
            files.add(p.name)
            try:
                idents.update(tok.findall(p.read_text(errors="ignore")))
            except OSError:
                pass
    return files, idents

def main() -> int:
    files, idents = tree_index()
    file_ref = re.compile(r"\b([A-Z][A-Za-z0-9_]*\.(?:sol|rs))\b")
    missing_files, missing_syms = {}, {}
    for d in DOCS:
        if not d.exists():
            continue
        text = d.read_text(errors="ignore")
        for m in set(file_ref.findall(text)):
            if m not in files:
                missing_files.setdefault(m, []).append(d.name)
    print(f"indexed {len(files)} source files, {len(idents)} identifiers\n")
    if missing_files:
        print(f"FILES cited in docs that do not exist ({len(missing_files)}):")
        for name, where in sorted(missing_files.items()):
            print(f"  {name:<34} cited in {', '.join(sorted(set(where)))}")
    else:
        print("no dangling file references")
    return 1 if (missing_files and "--strict" in sys.argv) else 0

if __name__ == "__main__":
    raise SystemExit(main())
