#!/usr/bin/env python3
"""Extract every SPRINT.md task and CHECK ITS CLAIM AGAINST CODE, not against prose.

Standing rule 20: "never discharge a SPRINT.md question from prose -- go to the code."
Rule 20's own worked examples found THREE of FOUR rows wrong in a single four-row
table, every one of them closable-looking from a comment. At ~400 open slots that is
not a job anyone does by reading; it is a job for a machine that re-runs each row's
own falsifiable claim, which is what CLAUDE.md already prescribes:

    "grep the OPEN rows for their own falsifiable claims -- 'does not build', 'zero
     references', 'NOT BUILT', 'cannot', 'never' -- and re-run each. A row that states
     a testable fact is a row that can be tested; one that cannot be tested that way
     was never a status, it was an opinion."

  usage: python3 tools/sprint-audit.py            # census + auto-verdicts
         python3 tools/sprint-audit.py --stale    # only rows whose claim is FALSIFIED
         python3 tools/sprint-audit.py --plan     # cluster by impacted suites, for ordering

⚠️ WHAT THIS CANNOT DO, named up front per the sweep rule: it verifies claims of the
   form "X has zero references" / "X does not exist" / "X is never called", because
   those are greppable. It CANNOT verify a design judgement, an owner ruling, or a
   claim about behaviour under load. Those come back UNVERIFIABLE, which is a
   different verdict from UNVERIFIED and must not be read as "fine".
"""
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPRINT = ROOT / "docs/actionable/SPRINT.md"
SRC = ROOT / "evm/src"

# A row states a testable fact when it makes one of these claims about a SYMBOL.
# Each pattern captures the symbol in group 1.
CLAIMS = [
    (re.compile(r"`(\w+)`[^.\n]{0,60}\b(?:has|have) ZERO (?:code )?(?:references|occurrences)", re.I), "zero-refs"),
    (re.compile(r"`(\w+)`[^.\n]{0,60}\bzero callers", re.I), "zero-callers"),
    (re.compile(r"`(\w+)`[^.\n]{0,40}\b(?:does not exist|no longer exists|is DELETED)", re.I), "absent"),
    (re.compile(r"\bZERO occurrences in `evm/src`[^.\n]{0,40}`(\w+)`", re.I), "zero-refs"),
]


EMPH = re.compile(r"\*\*|__|~~")


def sym_count(sym: str, where: Path) -> int:
    """Live count in CODE. Comments are stripped, because a symbol matching its own
    obituary is the failure rule 20 exists to prevent."""
    try:
        out = subprocess.run(
            ["grep", "-rn", "--include=*.sol", rf"\b{sym}\b", str(where)],
            capture_output=True, text=True,
        ).stdout
    except OSError:
        return -1
    live = 0
    for line in out.splitlines():
        body = line.split(":", 2)[-1].strip()
        if body.startswith(("//", "*", "/*", "///")):
            continue
        # 🔴 SUBTRACT DECLARATIONS. CLAUDE.md records check-orphans.py reporting "0
        # orphans on a tree that had three" for exactly this: `function borrowRateRay(`
        # matches a call pattern, so EVERY DECLARATION COUNTED AS ITS OWN CALLER, and
        # an interface + an implementation gave every member two. This tool reproduced
        # that bug verbatim on its first run -- swapOutDeliverUnlevered's two "uses"
        # were its own `function` line and its `Interfaces.sol` declaration, so the
        # row's ZERO-CALLERS claim was TRUE and the tool called it stale.
        if re.match(r"(?:function|struct|enum|event|error|contract|library|interface)\s", body):
            continue
        if re.match(r"(?:mapping|uint|int|address|bytes|bool|string)\b.*\bpublic\b", body):
            continue
        live += 1
    return live


def rows() -> list[tuple[int, str]]:
    """Every line that looks like an actionable row: a gate item, a numbered action,
    or a table row carrying a status marker."""
    out = []
    for i, line in enumerate(SPRINT.read_text(errors="ignore").splitlines(), 1):
        if re.match(r"^\*\*\d+[a-z]?\.\*\*|^\d+[a-z]?\. |^\|\s*(?:\*\*)?[A-Z0-9#§]|^### \d\.\d", line):
            out.append((i, line))
    return out


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    all_rows = rows()

    checked, stale, unverifiable = [], [], 0
    seen: set[tuple[str, str]] = set()
    for ln, line in all_rows:
        hit = False
        flat = EMPH.sub("", line)          # markdown emphasis splits "has **ZERO"
        for pat, kind in CLAIMS:
            for sym in pat.findall(flat):
                if (sym, kind) in seen:
                    continue
                seen.add((sym, kind))
                hit = True
                n = sym_count(sym, SRC)
                ok = (n == 0)
                checked.append((ln, sym, kind, n, ok))
                if not ok:
                    stale.append((ln, sym, kind, n, line))
        if not hit:
            unverifiable += 1

    if mode == "--stale":
        print(f"# ROWS WHOSE OWN CLAIM IS FALSIFIED BY THE CODE: {len(stale)}")
        for ln, sym, kind, n, line in stale:
            print(f"\nSPRINT.md:{ln}  `{sym}` claimed {kind}, LIVE COUNT = {n}")
            print(f"    {line.strip()[:150]}")
        return 0

    print(f"# SPRINT.md actionable rows found:        {len(all_rows)}")
    print(f"# rows stating a MACHINE-CHECKABLE claim: {len(checked)}")
    print(f"#   of those, claim HOLDS:                {sum(1 for c in checked if c[4])}")
    print(f"#   of those, claim FALSIFIED (stale):    {len(stale)}   <- rule 20 targets")
    print(f"# rows with NO machine-checkable claim:   {unverifiable}")
    print(f"#   ^ UNVERIFIABLE != fine. Design judgements, owner rulings and")
    print(f"#     behaviour-under-load claims still need a human read.")
    if stale:
        print("\n# run --stale for the list")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
