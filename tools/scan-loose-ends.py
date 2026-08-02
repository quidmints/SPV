#!/usr/bin/env python3
"""Session close-out scanner, calibrated for SPV.

Adapted from ibiza's `tools/scan-loose-ends.py`. The transcript half is kept almost verbatim —
its insight (a finding STATED in a reply but never lifted into a task is recorded somewhere and
actionable nowhere) applies identically here. The CODE half is rewritten, because ibiza's was
tuned for Noir/ZK and mis-fires badly on this repo:

  1. Its `unsafe {` section says "in a ZK circuit each is an UNCONSTRAINED, prover-supplied value".
     SPV has no circuits. Every `unsafe` it flagged is ordinary Rust in VENDORED upstream crates.
  2. Its marker scan reported 248 hits dominated by `TODO(phlip9)` / `TODO(max)` — upstream LDK/lexe
     authors' notes in vendored code. Ours are a different thing and were buried.
  3. It cross-checks bookings against `TODO.md` / `README.md`. SPV books work in
     `docs/actionable/QUEUE.md` (+ `CLAUDE.md` for rules), so everything read as unbooked.

What replaces the ZK section are the four failure modes THIS repo actually produced, each of which
cost real time and none of which a TODO-grep finds:

  • MOCKS on the money path      — the standing rule is "don't mock". `MockSPV.checkTxInclusion`
                                   returned true unconditionally and hid an entire unexercised SPV
                                   path (opens AND splices) behind a green suite.
  • FABRICATED consensus params  — `bytes32(uint(0x100 + seed))` as a Bitcoin block hash. Passes
                                   against a mock, is rejected by the real gateway.
  • SILENT SKIPS                 — `vm.skip` reached through a swallowed failure. Two ffi tests
                                   skipped in EVERY run for the life of the project because a broken
                                   harness and an absent one emitted the same token.
  • ASSERTION-FREE tests         — a test that cannot fail. §A.46's residue.

Usage:
    python3 tools/scan-loose-ends.py --transcript ~/.claude/projects/<proj>/<session>.jsonl
    python3 tools/scan-loose-ends.py                # code-only

⚠️ Read the RULES at the bottom of every run. The one that matters most here: RUN THE CONTROL
   BEFORE CONCLUDING. Three wrong conclusions in one SPV session came from skipping it.
"""
import argparse, json, os, re, sys
from collections import OrderedDict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Where SPV actually books work. A candidate whose key terms appear here is already tracked.
BOOKING_FILES = [
    "docs/actionable/QUEUE.md",
    "docs/actionable/BUILD-QUEUE-AND-107.md",
    "CLAUDE.md",
]

SKIP_DIRS = ("node_modules", "/lib/", "/build/", "/target/", "/.git/", "/out/", "/cache/",
             "/broadcast/", "/.bitcoin-core/", "/.lnd", "/docs/")

# Vendored upstream: their TODOs are not our loose ends. Reported separately, not mixed in.
VENDOR_MARK = re.compile(r"TODO\((?:phlip9|max)\)")
VENDOR_PATHS = ("/quid-ln/lib/", "/rust-lightning/", "/rust-sgx/")

CODE_EXTS = (".sol", ".rs", ".py", ".sh", ".ts", ".toml")
CODE_MARKERS = re.compile(r"\b(TODO|FIXME|HACK|XXX|WIP|PLACEHOLDER|NOT IMPLEMENTED|unimplemented)\b")

# ── the four SPV-specific structural probes ────────────────────────────────────────────────────
PROBES = OrderedDict([
    ("MOCK ON A REAL PATH — the standing rule is DON'T MOCK",
     re.compile(r"\bnew\s+Mock[A-Z]\w*\s*\(|\bvm\.mockCall\s*\(")),
    ("FABRICATED CONSENSUS PARAMS — a real gateway rejects these",
     re.compile(r"(fundingBlockHash|blockHash)\s*[:=]\s*bytes32\(uint\(0x|fundingBlockHeight\s*[:=]\s*\d{5,}")),
    ("SILENT SKIP — can a FAILURE reach this, not just an absence?",
     re.compile(r"vm\.skip\s*\(\s*true")),
    ("SWALLOWED FAILURE — try/catch or `|| echo` collapsing error into a sentinel",
     re.compile(r"\bcatch\s*\{\s*\}|\|\|\s*echo\s+-?n?\s*SKIP")),
])

FAMILIES = OrderedDict([
    ("INCOMPLETE",  r"\b(haven'?t|hasn'?t|not yet|still need|remains?|left to do|didn'?t (?:get|have) (?:to|time))\b"),
    ("DEFERRED",    r"\b(defer\w*|later|follow[- ]up|next (?:pass|thread|session)|revisit|for now|punt\w*)\b"),
    ("DISMISSAL",   r"\b(ignore\w*|skip\w*|out of scope|not worth|won'?t (?:do|bother)|leave (?:it|that))\b"),
    ("ABSENCE",     r"\b(no test|never (?:run|tested|verified|executed)|untested|unexercised|nothing (?:covers|tests))\b"),
    ("DECISION",    r"\b(your call|up to you|decide|decision (?:needed|for you)|which (?:do you|would you))\b"),
    ("RISK",        r"\b(risk\w*|danger\w*|footgun|armed|hazard|could break|blast radius)\b"),
    ("UNVERIFIED",  r"\b(unverified|assum\w+|I think|probably|should be|believe|likely)\b"),
    ("OUGHTTO",     r"\b(should (?:be|have|probably)|ought to|would be better|ideally)\b"),
    ("SECURITY",    r"\b(secret|token|key|credential|rotate|leak\w*|plaintext|exposed)\b"),
])

RULES = """
RULES THIS REPO'S FAILURES TAUGHT — read before acting on anything above.
 1. RUN THE CONTROL BEFORE CONCLUDING. Ask: would this measurement look the same if I were wrong?
    (An externality identical at three prices was not LVR; it was a flat haircut.)
 2. AN EMPTY GREP PROVES NOTHING. And never grep a file you JUST edited to confirm your own edit —
    diff against the pre-change revision instead.
 3. A COMMENT DESCRIBES PAST STATE. Audit by structure, never by a name; a name matches its obituary.
 4. ENUMERATE THE CONTAINERS FIRST. "Is everything tracked?" was answered wrong twice by auditing
    the surface already in view. `ls docs/actionable/` was the whole answer.
 5. A TOLERANCE, GUARD OR SKIP THAT MAKES A TEST PASS is the tell that the defect is still there.
"""


def booked(text):
    """True if this candidate's distinctive terms already appear in a booking file."""
    keys = [w for w in re.findall(r"[A-Za-z_][A-Za-z0-9_.]{4,}", text)][:12]
    if not keys:
        return False
    for bf in BOOKING_FILES:
        p = os.path.join(ROOT, bf)
        if not os.path.exists(p):
            continue
        body = open(p, errors="ignore").read()
        if sum(1 for k in keys if k in body) >= max(2, len(keys) // 4):
            return True
    return False


def walk_code():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        if any(s in dirpath + "/" for s in SKIP_DIRS):
            continue
        for fn in filenames:
            if fn.endswith(CODE_EXTS):
                yield os.path.join(dirpath, fn)


def scan_code():
    ours, vendor, probes = [], [], OrderedDict((k, []) for k in PROBES)
    for path in walk_code():
        rel = os.path.relpath(path, ROOT)
        if rel == os.path.join("tools", "scan-loose-ends.py"):
            continue   # it describes the very patterns it hunts; matching itself is pure noise
        try:
            lines = open(path, errors="ignore").read().split("\n")
        except OSError:
            continue
        is_vendor = any(v in "/" + rel for v in VENDOR_PATHS)
        for i, line in enumerate(lines, 1):
            if CODE_MARKERS.search(line):
                (vendor if (is_vendor or VENDOR_MARK.search(line)) else ours).append(
                    f"{rel}:{i}: {line.strip()[:120]}")
            for name, rx in PROBES.items():
                if rx.search(line):
                    probes[name].append(f"{rel}:{i}: {line.strip()[:120]}")

    print("=" * 78)
    print("CODE SCAN — the transcript cannot see these. Do not skip.")
    print("=" * 78)
    print(f"\n[{len(ours)}] OUR unresolved markers")
    for h in ours[:40]:
        print("   ", h)
    print(f"\n[{len(vendor)}] VENDORED upstream markers (TODO(phlip9)/TODO(max), lib/) — NOT ours.")
    print("     Listed so they stop drowning the signal; do not action without a reason.")

    for name, hits in probes.items():
        print(f"\n[{len(hits)}] {name}")
        for h in hits[:20]:
            print("   ", h)
    return probes


def scan_transcript(path):
    try:
        raw = open(path, errors="ignore").read().split("\n")
    except OSError as e:
        print(f"(transcript unreadable: {e})")
        return
    texts = []
    for line in raw:
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        msg = ev.get("message") or {}
        content = msg.get("content")
        if isinstance(content, str):
            texts.append(content)
        elif isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    texts.append(c.get("text", ""))

    print("\n" + "=" * 78)
    print(f"TRANSCRIPT SCAN — {len(texts)} messages. What was SAID and may never have been BOOKED.")
    print("=" * 78)
    print("⚠️ A long session JSONL spans MANY compactions, so most hits are already-resolved")
    print("   history. Treat counts as a prompt to look, never as a defect list.")
    for fam, pat in FAMILIES.items():
        rx = re.compile(pat, re.I)
        hits = []
        for t in texts:
            for sent in re.split(r"(?<=[.!?])\s+", t):
                if rx.search(sent) and 40 < len(sent) < 400:
                    hits.append(sent.strip())
        uniq, seen = [], set()
        for h in hits:
            k = h[:80].lower()
            if k not in seen:
                seen.add(k)
                uniq.append(h)
        unb = [h for h in uniq if not booked(h)]
        print(f"\n--- {fam}: {len(uniq)} distinct, {len(unb)} not obviously booked ---")
        for h in unb[:5]:
            print("  •", h[:200])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcript")
    a = ap.parse_args()
    scan_code()
    if a.transcript:
        scan_transcript(a.transcript)
    print(RULES)


if __name__ == "__main__":
    main()
