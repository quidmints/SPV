#!/usr/bin/env python3
"""Find near-identical Solidity function bodies across files.

Only BODIES can fund a bytecode-extraction target: interface declarations and
struct definitions emit no deployed code.  This normalises whitespace and
comments, then reports pairs of functions whose bodies are highly similar.

Usage:  find-duplicate-bodies.py <file.sol> [<file.sol> ...]

A positive control is printed first: the tool re-reports the number of
functions it parsed per file.  A zero there means the parser broke, not that
the file has no functions -- an empty result from a dead pipeline and an empty
result from a clean tree are indistinguishable without it.
"""

import re
import sys
from difflib import SequenceMatcher
from pathlib import Path

FUNCTION_HEAD = re.compile(r"\bfunction\s+([A-Za-z_]\w*)\s*\(")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")


def blank_out(match) -> str:
    """Replace a comment with whitespace of identical length.

    Deleting comments outright shifts every later offset, which silently
    corrupts the reported line numbers -- the body is then quoted against the
    wrong function name.  Preserving length keeps offsets in the cleaned text
    aligned with the original source.
    """
    return re.sub(r"[^\n]", " ", match.group(0))


def strip_comments(text: str) -> str:
    return LINE_COMMENT.sub(blank_out, BLOCK_COMMENT.sub(blank_out, text))


def normalise(body: str) -> str:
    """Collapse formatting so only structure remains."""
    return re.sub(r"\s+", " ", strip_comments(body)).strip()


def extract_functions(path: Path):
    """Return [(name, signature, normalised_body, line_no)] via brace matching."""
    source = path.read_text(encoding="utf-8", errors="replace")
    clean = strip_comments(source)
    found = []

    for match in FUNCTION_HEAD.finditer(clean):
        name = match.group(1)
        # Walk forward to the opening brace of the body (or ';' for a decl).
        cursor = match.end()
        depth = 1
        while cursor < len(clean) and depth:
            if clean[cursor] == "(":
                depth += 1
            elif clean[cursor] == ")":
                depth -= 1
            cursor += 1
        header_end = cursor
        while cursor < len(clean) and clean[cursor] not in "{;":
            cursor += 1
        if cursor >= len(clean) or clean[cursor] == ";":
            continue  # declaration only -- no bytecode, skip

        start = cursor
        depth = 0
        while cursor < len(clean):
            if clean[cursor] == "{":
                depth += 1
            elif clean[cursor] == "}":
                depth -= 1
                if depth == 0:
                    break
            cursor += 1

        body = clean[start : cursor + 1]
        if len(normalise(body)) < 120:
            continue  # one-line forwarders cannot fund an extraction
        signature = normalise(clean[match.start() : header_end])
        line_no = source[: match.start()].count("\n") + 1
        found.append((name, signature, normalise(body), line_no))

    return found


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1

    catalogue = {}
    print("=== control: functions parsed per file ===")
    for arg in argv[1:]:
        path = Path(arg)
        functions = extract_functions(path)
        catalogue[path] = functions
        print(f"  {path.name:24s} {len(functions):4d} bodies >=120 chars")
    print()

    entries = [(p, f) for p, fns in catalogue.items() for f in fns]
    print(f"=== body pairs at >=70% similarity ({len(entries)} bodies) ===")
    hits = 0
    for i, (path_a, fn_a) in enumerate(entries):
        for path_b, fn_b in entries[i + 1 :]:
            # Length is a cheap upper bound on similarity: two bodies whose
            # sizes differ by >30% cannot reach a 0.70 ratio, so skip the
            # expensive comparison entirely.  Without this the whole-tree run
            # is quadratic over ~400 bodies and does not finish.
            len_a, len_b = len(fn_a[2]), len(fn_b[2])
            if min(len_a, len_b) / max(len_a, len_b) < 0.70:
                continue
            matcher = SequenceMatcher(None, fn_a[2], fn_b[2])
            if matcher.quick_ratio() < 0.70:
                continue
            ratio = matcher.ratio()
            if ratio < 0.70:
                continue
            hits += 1
            size = (len(fn_a[2]) + len(fn_b[2])) // 2
            print(
                f"  {ratio:5.1%}  ~{size:5d} chars  "
                f"{path_a.name}:{fn_a[3]} {fn_a[0]}  <->  "
                f"{path_b.name}:{fn_b[3]} {fn_b[0]}"
            )
    if not hits:
        print("  (none -- and the control above proves the parser ran)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
