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
DECL = re.compile(r"^\s*(?:abstract\s+)?(?:contract|library|interface)\s+(\w+)", re.M)


def sol_index() -> dict[str, Path]:
    """contract/library name -> file, plus file stem -> file."""
    idx = {}
    for f in SRC.rglob("*.sol"):
        idx[f.stem] = f
        for n in DECL.findall(f.read_text(errors="ignore")):
            idx[n] = f
    return idx


def suites_for(files: set[Path], idx: dict[str, Path]) -> set[str]:
    syms = set()
    for f in files:
        syms |= set(DECL.findall(f.read_text(errors="ignore"))) | {f.stem}
    hit = set()
    for tf in TEST.rglob("*.t.sol"):
        text = tf.read_text(errors="ignore")
        if any(re.search(rf"\b{re.escape(s)}\b", text) for s in syms):
            hit.add(tf.name)
    return hit


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
            body += "\n" + secs.get(tag, "")[:6000]
        it["text"] = body
        names = set(re.findall(r"`([A-Za-z_]\w*)(?:\.sol)?[`.:]", it["text"]))
        it["files"] = {idx[n] for n in names if n in idx}
        it["rust"] = set(RUST.findall(it["text"]))
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
        byset = defaultdict(list)
        for i in g:
            key = ("RUST", tuple(sorted(i["rust"]))) if i["rust"] and not i["files"] \
                else ("NOBUILD",) if not i["files"] \
                else ("SOL", tuple(sorted(i["suites"])))
            byset[key].append(i)
        print(f"## GATE {gate}  ({len(g)} items)")
        for key, group in sorted(byset.items(), key=lambda kv: -len(kv[1])):
            tags = " ".join(i["tag"] for i in group)
            if key[0] == "NOBUILD":
                print(f"   NO BUILD  x{len(group):<2}  {tags}")
            elif key[0] == "RUST":
                runs += 1
                print(f"   1 cargo   x{len(group):<2}  {tags}   [{' '.join(key[1])}]")
            else:
                runs += 1
                print(f"   1 run     x{len(group):<2}  {tags}   ({len(key[1])} suites)")
        print()
    print(f"# TOTAL BUILD+TEST RUNS: {runs}   (against {len(its)} items = one run each)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
