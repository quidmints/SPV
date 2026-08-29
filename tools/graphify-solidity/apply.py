#!/usr/bin/env python3
"""Re-apply this repo's Solidity support to an installed graphify.

graphify 0.9.51 has no Solidity grammar (upstream PRs #707, #1367 and #1874
have all been open since May 2026), so `graphify update` would file 363
first-party contracts as bare nodes with no functions, calls or inheritance.
This script installs `solidity.py` into the graphify package and makes the
four one-line registrations that wire it into dispatch.

Idempotent: safe to re-run, and the thing to run after `pip install -U
graphifyy`, which overwrites the package and silently reverts the patch. A
graph built from an unpatched graphify is not visibly broken -- it just has
no Solidity in it -- so verify with --check rather than by eyeballing output.

    python3 tools/graphify-solidity/apply.py            # patch
    python3 tools/graphify-solidity/apply.py --check    # report only

Point it at a non-default install with GRAPHIFY_PYTHON=/path/to/bin/python.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_PYTHON = Path.home() / ".local/share/graphify-venv/bin/python"

# (file, anchor, replacement) -- each `anchor` must appear exactly once, and
# each `replacement` must contain it, so applying twice is a no-op.
REGISTRATIONS = [
    (
        "detect.py",
        "CODE_EXTENSIONS = {'.py',",
        "CODE_EXTENSIONS = {'.sol', '.py',",
    ),
    (
        # Anchor on the whole line including its trailing `# noqa`. Anchoring on
        # the bare import splits that comment onto the inserted line and strips
        # it from sln's.
        "extract.py",
        "from graphify.extractors.sln import extract_sln  # noqa: F401\n",
        "from graphify.extractors.sln import extract_sln  # noqa: F401\n"
        "from graphify.extractors.solidity import extract_solidity  # noqa: F401  (local Solidity patch)\n",
    ),
    (
        "extract.py",
        '    ".rs": extract_rust,\n',
        '    ".rs": extract_rust,\n    ".sol": extract_solidity,\n',
    ),
    (
        "extract.py",
        '    ".rs": "rust",\n',
        '    ".rs": "rust",\n    ".sol": "solidity",\n',
    ),
    (
        "extractors/__init__.py",
        "from graphify.extractors.sql import extract_sql\n",
        "from graphify.extractors.solidity import extract_solidity\n"
        "from graphify.extractors.sql import extract_sql\n",
    ),
    (
        "extractors/__init__.py",
        '    "sql": extract_sql,',
        '    "solidity": extract_solidity,\n    "sql": extract_sql,',
    ),
]


def graphify_package(python: Path) -> Path:
    """Directory of the graphify package the given interpreter imports."""
    out = subprocess.run(
        [str(python), "-c", "import graphify, pathlib; print(pathlib.Path(graphify.__file__).parent)"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"cannot import graphify with {python}:\n{out.stderr.strip()}")
    return Path(out.stdout.strip())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="report whether the patch is applied; change nothing")
    args = parser.parse_args()

    python = Path(os.environ.get("GRAPHIFY_PYTHON", DEFAULT_PYTHON))
    if not python.exists():
        sys.exit(f"no interpreter at {python} (set GRAPHIFY_PYTHON)")
    package = graphify_package(python)

    installed = package / "extractors/solidity.py"
    source = HERE / "solidity.py"
    current = installed.read_text() if installed.exists() else None
    extractor_ok = current == source.read_text()

    pending = []
    for name, anchor, replacement in REGISTRATIONS:
        text = (package / name).read_text()
        if replacement in text:
            continue
        if text.count(anchor) != 1:
            sys.exit(f"{name}: anchor appears {text.count(anchor)}x, expected 1 "
                     f"-- graphify's source moved; re-derive this registration by hand")
        pending.append((name, anchor, replacement))

    if args.check:
        print(f"graphify package: {package}")
        print(f"  extractor:     {'up to date' if extractor_ok else 'MISSING or STALE'}")
        print(f"  registrations: {len(REGISTRATIONS) - len(pending)}/{len(REGISTRATIONS)} applied")
        grammar = subprocess.run(
            [str(python), "-c", "import tree_sitter_solidity"], capture_output=True)
        print(f"  grammar:       {'present' if grammar.returncode == 0 else 'MISSING -- pip install tree-sitter-solidity'}")
        ok = extractor_ok and not pending and grammar.returncode == 0
        print("PATCHED" if ok else "NOT FULLY PATCHED -- re-run without --check")
        return 0 if ok else 1

    if not extractor_ok:
        shutil.copy2(source, installed)
        print(f"installed {installed}")
    for name, anchor, replacement in pending:
        path = package / name
        path.write_text(path.read_text().replace(anchor, replacement, 1))
        print(f"registered in {name}")
    if extractor_ok and not pending:
        print("already patched; nothing to do")
    print("\nNow rebuild:  graphify update . --force")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
