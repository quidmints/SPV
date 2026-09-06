#!/usr/bin/env python3
"""Cluster §MASTER-ORDER items by the test suites they impact, to minimise build/test runs.

The order in SPRINT.md is a DEPENDENCY order -- it says what must precede what. It says
nothing about what can SHARE A BUILD, and that is the axis the day is actually spent on:
a warm `forge build` plus a targeted `forge test` is the unit cost, and paying it once
per item is the difference between a day and a week.

This computes the other axis. For each item it resolves the files the item names, maps
those to impacted suites (same rule as tools/impacted-tests.py), and groups items whose
suite sets coincide. Items in one group are ONE build+test run.

  usage: python3 tools/batch-plan.py            # the plan
         python3 tools/batch-plan.py --items    # what each item resolved to (audit it)

⚠️ THE GATE ORDER IS A HARD CONSTRAINT AND THIS DOES NOT RELAX IT. Batching only ever
   merges items WITHIN a gate. Moving work across GATE 2 would build something an owner
   ruling may delete, which is the trap §MASTER-ORDER exists to prevent -- a cheaper
   test run is not worth re-doing the work.

⚠️ AND ITS FALSE-POSITIVE CLASS: an item is resolved from the FILES ITS PROSE NAMES. An
   item that says "the app must derive a basepoint" names no Solidity file and lands in
   NO-BUILD, which is correct; an item that names a file only as context will be over-
   assigned. Run --items and read the mapping before trusting a batch.
"""
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPRINT = ROOT / "docs/actionable/SPRINT.md"
SRC, TEST = ROOT / "evm/src", ROOT / "evm/test"

ITEM = re.compile(r"^(?:\*\*(\d+[a-z]?)\.\*\*|### (\d\.\d)|\| \*\*(0[a-d])\*\*|\| (1[a-h]) \|)")
GATE = re.compile(r"^## GATE (\d)")
RUST = re.compile(r"\b(quid-\w+)\b")
# Items a human has confirmed are prose-only. Empty until someone marks them: guessing
# this from the text produces wrong answers in both directions (see main()).
DOC_ONLY: set[str] = set()
DECL = re.compile(r"^\s*(?:abstract\s+)?(?:contract|library|interface)\s+(\w+)", re.M)


def sol_index() -> dict[str, Path]:
    """contract/library name -> file, plus file stem -> file."""
    idx = {}
    for f in SRC.rglob("*.sol"):
        idx[f.stem] = f
        for n in DECL.findall(f.read_text(errors="ignore")):
            idx[n] = f
    return idx


# 🔴 CACHED, BECAUSE THE FIRST VERSION WAS O(items x tests) AND WAS OOM-KILLED (exit 137).
# 58 items x 155 test files is ~9,000 reads of the same content, and the per-item text
# also grew by 6 KB per cited section. The fix is to read each corpus ONCE. Recorded
# because "the tool died" reads like a machine problem and was an algorithm problem.
_TESTS: dict[str, str] = {}
_SYMS: dict[Path, set[str]] = {}


def _tests() -> dict[str, str]:
    if not _TESTS:
        for tf in TEST.rglob("*.t.sol"):
            _TESTS[tf.name] = tf.read_text(errors="ignore")
    return _TESTS


def suites_for(files: set[Path], idx: dict[str, Path]) -> set[str]:
    syms = set()
    for f in files:
        if f not in _SYMS:
            _SYMS[f] = set(DECL.findall(f.read_text(errors="ignore"))) | {f.stem}
        syms |= _SYMS[f]
    pat = re.compile(r"\b(?:" + "|".join(re.escape(s) for s in sorted(syms)) + r")\b")
    return {name for name, text in _tests().items() if pat.search(text)}


def sections() -> dict[str, str]:
    """§TAG -> that section's body.

    🔴 THE GATE ITEMS DO NOT NAME FILES. They cite a section -- "4d. The force-close
    shortfall check (§BTC-2.4)" -- and the FILES live in §BTC-2.4, not in the item. A
    resolver that reads only the item text therefore resolves almost everything to
    NO-BUILD, which is how the first run of this tool put 43 of 58 items there and
    produced a plan that was obviously wrong on its face.
    """
    text = SPRINT.read_text(errors="ignore")
    out, tag, buf = {}, None, []
    for line in text.splitlines():
        m = re.match(r"^#{1,4} .*?(§[A-Za-z0-9._-]+)", line)
        if m:
            if tag:
                out[tag] = "\n".join(buf)
            tag, buf = m.group(1), []
        elif tag:
            buf.append(line)
    if tag:
        out[tag] = "\n".join(buf)
    return out


def items() -> list[dict]:
    lines = SPRINT.read_text(errors="ignore").splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith("# 🧭 §MASTER-ORDER"))
    end = next(i for i, l in enumerate(lines) if l.startswith("## ⛔ THE FIVE ORDERING TRAPS"))
    out, gate, cur = [], "0", None
    for l in lines[start:end]:
        g = GATE.match(l)
        if g:
            gate = g.group(1)
        m = ITEM.match(l)
        if m:
            tag = next(x for x in m.groups() if x)
            cur = {"gate": gate, "tag": tag, "text": l}
            out.append(cur)
        elif cur is not None and l.strip() and not l.startswith(("#", "|")):
            cur["text"] += " " + l
    return out


def main() -> int:
    idx = sol_index()
    show = "--items" in sys.argv
    its = items()

    secs = sections()
    for it in its:
        # follow every §TAG the item cites, and read THAT section for files too
        body = it["text"]
        for tag in set(re.findall(r"§[A-Za-z0-9._-]+", it["text"])):
            body += "\n" + secs.get(tag, "")[:4000]
        names = set(re.findall(r"`([A-Za-z_]\w*)(?:\.sol)?[`.:]", body))
        it["rust"] = set(RUST.findall(body))
        del body                       # do NOT retain: 58 items x N sections is the OOM
        it["files"] = {idx[n] for n in names if n in idx}
        it["suites"] = suites_for(it["files"], idx) if it["files"] else set()

    if show:
        for it in its:
            f = ",".join(sorted(p.stem for p in it["files"])) or "-"
            print(f"G{it['gate']} {it['tag']:<5} files={f:<44} suites={len(it['suites'])}")
        return 0

    print("# BATCH PLAN — items that can share ONE build+test run.")
    print("# Batching NEVER crosses a gate: the dependency order is a hard constraint.\n")
    runs = 0
    for gate in sorted({i["gate"] for i in its}):
        g = [i for i in its if i["gate"] == gate]
        print(f"## GATE {gate}  ({len(g)} items)")
        # ⭐ A COMMENT-ONLY ITEM NEEDS NO TEST RUN AT ALL, AND THIS IS CONFIG-VERIFIED
        # RATHER THAN ASSUMED: evm/foundry.toml sets bytecode_hash = "none" and
        # cbor_metadata = false, so solc appends NO source-hash trailer and a comment
        # edit yields BYTE-IDENTICAL deployed bytecode. (Checked in an artifact: the
        # runtime tail is real opcodes, not CBOR.) Behaviour cannot move, so no test
        # can fail. A documentation lane needs a COMPILE at most -- which is why GATE 9
        # collapses to zero test runs rather than four.
        # ⚠️ CLASSIFYING WHICH ITEMS ARE COMMENT-ONLY BY KEYWORD DOES NOT WORK, and the
        # attempt is recorded so it is not retried: matching /comment|docblock|prose/
        # tagged 7i (a real swapOutDeleverPooled reconciliation defect) because its text
        # quotes a docblock, and it would have exempted 9b, which RENAMES AN EVENT AND AN
        # ERROR -- ABI a client can act on, so very much code. Same false-positive class
        # as everywhere else in this repo: the word appears in the item without being its
        # subject. ⇒ the RULE is sound and lives in CLAUDE.md; the AUTO-DETECTION is not,
        # so a human marks doc-only work and this tool does not guess.
        doc = [i for i in g if i["tag"] in DOC_ONLY]
        docset = {i["tag"] for i in doc}
        g = [i for i in g if i["tag"] not in docset]
        if doc:
            print(f"   NO TEST   x{len(doc):<2}  {' '.join(i['tag'] for i in doc)}   (comment-only: bytecode identical)")
        nb = [i for i in g if not i["files"] and not i["rust"]]
        rs = [i for i in g if not i["files"] and i["rust"]]
        sol = sorted((i for i in g if i["files"]), key=lambda i: -len(i["suites"]))

        if nb:
            print(f"   NO BUILD  x{len(nb):<2}  {' '.join(i['tag'] for i in nb)}")
        if rs:
            runs += 1
            crates = sorted({c for i in rs for c in i["rust"]})
            print(f"   1 cargo   x{len(rs):<2}  {' '.join(i['tag'] for i in rs)}   [{' '.join(crates[:4])}]")

        # ⭐ GREEDY SET COVER, not exact-match grouping. Grouping on IDENTICAL suite sets
        # merged almost nothing (38 runs for 58 items) because no two items impact
        # exactly the same suites. What actually matters is CONTAINMENT: if item A's
        # suites are a superset of item B's, ONE run of A's set verifies both. Sorting
        # by set size descending and absorbing every remaining subset is the standard
        # greedy cover, and here it is near-optimal because the sets are strongly nested
        # (everything touching Quid contains most of what touches Core).
        taken = set()
        for i in sol:
            if i["tag"] in taken:
                continue
            absorbed = [j for j in sol
                        if j["tag"] not in taken and j["tag"] != i["tag"]
                        and j["suites"] <= i["suites"]]
            taken.add(i["tag"])
            taken |= {j["tag"] for j in absorbed}
            runs += 1
            tags = " ".join([i["tag"]] + [j["tag"] for j in absorbed])
            print(f"   1 run     x{1 + len(absorbed):<2}  {tags}   ({len(i['suites'])} suites)")
        print()
    print(f"# TOTAL BUILD+TEST RUNS: {runs}   (against {len(its)} items = one run each)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
