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
     `docs/actionable/SPRINT.md §FROM-QUEUE` (+ `CLAUDE.md` for rules), so everything read as unbooked.

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
# ⚠️ THE ARCHIVE IS **NOT** A BOOKING FILE. `BUILD-QUEUE-AND-107.md` is append-only and its own
# header declares its STATUS markers non-authoritative — it is evidence only. Including it here (as
# this file did until 2026-08-03) meant anything ever MENTIONED in the archive scored as "booked",
# so a live item recorded there and never carried into QUEUE.md read as tracked. That is exactly how
# the `registerBtcLp`/`resizeBtcLp` rename ("booked as 13c") hid: 13c appears 1× in the archive and
# 0× in QUEUE.md. Status lives in QUEUE.md; nowhere else counts.
BOOKING_FILES = [
    "docs/actionable/SPRINT.md §FROM-QUEUE",
    "CLAUDE.md",
]

SKIP_DIRS = ("node_modules", "/lib/", "/build/", "/target/", "/.git/", "/out/", "/cache/",
             "/broadcast/", "/.bitcoin-core/", "/.lnd", "/docs/",
             # 🔴 AGENT WORKTREES ARE COPIES OF THIS TREE, AND WITHOUT THIS LINE THEY WERE **86% OF
             # THE OUTPUT** — measured 2026-08-28: 81 of 94 hits came from
             # `.claude/worktrees/agent-…`, 13 from the real tree. Every one was a duplicate or a
             # stale copy of a loose end already listed, so the report read as ~7x worse than the
             # tree actually is, and the real 13 were buried under them. A scanner that walks `ROOT`
             # will find any checkout living under `ROOT`.
             "/.claude/")

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
    # ── the original nine ────────────────────────────────────────────────────────────────────
    # ⚠️ UNCONTRACTED FORMS. `haven'?t` matches "havent"/"haven't" but NOT "have not" — the
    #    uncontracted form was invisible to ALL 16 families until 2026-08-03. "What I have not done
    #    and would want before any change here:" is exactly how unfinished work gets flagged in prose,
    #    and it matched nothing. Always cover both spellings.
    ("INCOMPLETE",  r"\b(have|has|had) not\b|\b(haven'?t|hasn'?t|did ?n'?o?t|not yet|still need|"
                    r"remains?|left to do|didn'?t (?:get|have) (?:to|time))\b"),
    ("DEFERRED",    r"\b(defer\w*|later|follow[- ]up|next (?:pass|thread|session)|revisit|for now|punt\w*)\b"),
    ("DISMISSAL",   r"\b(ignore\w*|skip\w*|out of scope|not worth|won'?t (?:do|bother)|leave (?:it|that))\b"),
    # ⚠️ PAST TENSE, added 2026-08-04. `never (?:run|tested)` matched the passive "it was never run"
    #    but NOT the active "I never ran it" — and the active voice is how the admission is actually
    #    written, because it is the author confessing, not describing. 54 such statements existed in
    #    a single session's transcript and the family caught a minority of them. Widened to the past
    #    tense of every verb that means "this was not exercised", plus the "didn't actually X" frame,
    #    where the word "actually" is itself a reliable tell that a claim is being walked back.
    ("ABSENCE",     r"\b(no test|untested|unexercised|nothing (?:covers|tests)|"
                    r"never (?:actually |really |once |even |properly |fully )?"
                    r"(?:run|ran|tested|verified|executed|exercised|compiled|built|opened|read|"
                    r"looked|measured|tried|deployed|called|reached)|"
                    r"(?:was|were|has|have|had) never (?:run|built|opened|read|measured|exercised|called)|"
                    r"did ?n'?o?t (?:actually )?(?:run|ran|build|open|read|measure|try|execute|compile)|"
                    r"(?:has|have|had) not (?:been )?(?:run|tested|executed|exercised|measured))\b"),
    ("DECISION",    r"\b(your call|up to you|decide|decision (?:needed|for you)|which (?:do you|would you))\b"),
    ("RISK",        r"\b(risk\w*|danger\w*|footgun|armed|hazard|could break|blast radius)\b"),
    # ⚠️ The first-person hedges below were added 2026-08-04. The original list caught the
    #    IMPERSONAL forms ("probably", "likely") but not the ones a reply actually uses to
    #    disclaim its own confidence — "I am not sure", "I could be wrong". Those are the
    #    sentences where the writer KNOWS the claim is soft, so they are the highest-value
    #    hits in the whole scan, and every one of them was invisible.
    ("UNVERIFIED",  r"\b(unverified|assum\w+|I think|probably|should be|believe|likely|"
                    r"(?:I am|I'?m|we are|we'?re) not (?:sure|certain|confident)|not confident|"
                    r"(?:I|we|this) (?:could|may|might) be wrong|pending verification|"
                    r"left as an exercise|no(?:t)? (?:hard )?evidence (?:for|that)|"
                    r"taking (?:it|this|that) on faith|reasoned, not (?:tested|measured))\b"),
    ("OUGHTTO",     r"\b(should (?:be|have|probably)|ought to|would be better|ideally)\b"),
    ("SECURITY",    r"\b(secret|token|key|credential|rotate|leak\w*|plaintext|exposed)\b"),
    # ── added 2026-08-02: nine was NOT exhaustive. Each of these named a real class the
    #    originals missed, and "things to return to" is mostly phrased in THESE, not in TODO.
    ("PROVISIONAL", r"\b(for now|temporar\w+|stop[- ]?gap|interim|first cut|rough(?:ly)?|"
                    r"approximat\w+|good enough|naive|simplif\w+|placeholder)\b"),
    ("WORKAROUND",  r"\b(work[- ]?around|hack|bypass|side[- ]?step|width[- ]?aid|for the moment|"
                    r"escape hatch|in the meantime|until (?:we|it|that))\b"),
    ("LIMITATION",  r"\b(only (?:works|handles|covers)|doesn'?t handle|breaks? (?:when|if)|fails? (?:when|if)|"
                    r"cannot (?:yet|currently)|no (?:support|coverage) for|limited to|does not (?:cover|track))\b"),
    ("FUTURE",      r"\b(eventually|some ?day|once we|when we|after we|down the (?:line|road)|"
                    r"in (?:a )?future|pre[- ]mainnet|before (?:mainnet|launch|shipping))\b"),
    ("UNKNOWN",     r"\b(unclear|ambiguous|not obvious|unsure|can'?t tell|don'?t know|"
                    r"remains? open|open question|needs? (?:investigation|a look)|worth (?:a )?look)\b"),
    ("CONDITIONAL", r"\b(if it turns out|should it (?:ever|turn)|in case|unless|"
                    r"if that (?:changes|happens|breaks)|watch (?:for|out))\b"),
    # Added 2026-08-03 — the CAVEAT frame. A reply that ends "what I have not done / would want
    # before acting" is the single most reliable signal of unfinished work, and NO other family
    # caught it: not INCOMPLETE (uncontracted), not OUGHTTO, not FUTURE ("before mainnet" only).
    ("CAVEAT",      r"\b(would (?:want|need|prefer)|before (?:any|acting|changing|touching|shipping|"
                    r"relying|trusting)|what I have not|have not (?:done|checked|read|verified|run)|"
                    r"not (?:established|certified|confirmed)|treat (?:as|this as)|do not (?:trust|"
                    r"act on)|unverified|hypothesis, not)\b"),
    ("REGRESSION",  r"\b(re[- ]?introduc\w+|regress\w+|came back|broke again|un[- ]?fix\w*|"
                    r"stale|outdated|drift\w*|no longer (?:true|matches))\b"),
    # Added 2026-08-04 — the PROMISED CHECK. Distinct from DEFERRED ("later", "next pass"), which
    # postpones work with no commitment, and from UNKNOWN ("open question"), which admits ignorance
    # without naming a next move. This frame NAMES A SPECIFIC CHECK and implies it is about to
    # happen — "that's the next thing to check, and it's short" — which is precisely why it never
    # gets booked: it reads as already-in-hand, so it is not written down, and then the context
    # window ends. Four such promises were made in one session; ONE was never performed (whether the
    # legacy repo's own Rover.sol handles the case differently — it exists, 537 lines, never read).
    # The tell is the future tense on a verb of verification. If a scan hits this family, the only
    # acceptable answers are "checked, here is the result" or a booked task — never silence.
    # Added 2026-08-05 — the DEBT frame, and the largest single blind spot found so far: 65 hits in
    # one session's transcript, of which the other 18 families caught ZERO. Nothing else covers it
    # because the vocabulary is financial, not technical — work is described as owed, outstanding,
    # promised, or on the hook, and no family was looking for a ledger.
    #
    # It is the highest-value family precisely because the debt frame is what a writer reaches for
    # when they KNOW something is unfinished and are being honest about it: "5e pin now owed",
    # "I promised a vacuous-test sweep", "that part of the audit is owed on a Linux host and I'm
    # not claiming it as done", "the outstanding debt is one clean forge test". Every one of those
    # is a self-reported IOU that then evaporated with the context window.
    #
    # ⚠️ KNOWN NOISE, deliberately accepted: "outstanding" is also a DOMAIN term here (outstanding
    # vBTC, outstanding supply) meaning issued-and-unredeemed, not owed-as-work. The lookahead below
    # filters the common nouns; anything it misses is triage cost, and under-matching a debt is
    # worse than over-matching a balance sheet.
    # Added 2026-08-05 — STILL OPEN. 69 hits in one session; the only ones any family caught were
    # "remains open", and only by accident (INCOMPLETE's bare `remains?`). "still open" itself,
    # "left open", "reopened", "not closed", "open item", "unresolved" and "still pending" all
    # matched nothing at all.
    #
    # This is the status-column vocabulary — how a summary reports what did not get done, as opposed
    # to how prose confesses it. That makes it the natural pair to OWED: OWED catches the debt when
    # it is incurred, OPEN catches it when it is being reported forward. The repo's own closure rule
    # ("mark ✅ only if no later decision can reopen it") is written in exactly this register, so a
    # thread summarising its state uses these words and nothing was reading them.
    #
    # ⚠️ DOMAIN SENSE, filtered: an "open position" / "open channel" / "open order" is a live
    # financial object, not unfinished work — "position stays open for the keeper to re-lever" must
    # not fire. Lookbehind + lookahead handle the common shapes; verified by control probe.
    ("OPEN",        r"\b(?:still (?:open|live|unresolved|pending|unsettled|undecided)|"
                    r"(?<!position )(?:remains?|stays?|left|kept|leave) open"
                    r"(?! (?:position|channel|order|source|interest|width|market))|"
                    r"re[- ]?open(?:ed|s|ing)?|not (?:closed|settled|resolved|decided)|"
                    r"open (?:item|question|issue|fork|point|end|hole)s?|"
                    r"unresolved|unsettled|genuinely (?:open|remain))\b"),
    ("OWED",        r"\b(?:owed?\b|(?:I|we) (?:still )?owe|promised\b|"
                    r"outstanding(?! (?:vBTC|BTC|supply|balance|shares|principal|amount|liabilit|"
                    r"piece|example))|on the hook|"
                    r"said (?:I|we)'?(?:d|ll| would| will)|committed to (?:run|check|do|verif|test)|"
                    r"(?:verification|test|proof) debt|owe (?:you|it) (?:a|an|the)|"
                    r"my own (?:outstanding|open) (?:action )?item)\b"),
    ("PROMISED CHECK",
                    r"\b(?:(?:next|first|last|other) thing to check|thing to check (?:is|next)|"
                    r"next to check|(?:need|want|going|have) to (?:check|confirm|verify|measure|"
                    r"read|look at)|(?:I'?ll|I will|let me|we'?ll|we will) (?:check|confirm|verify|"
                    r"measure|read|look|test|run|diff|trace)|should be checked|worth checking|"
                    r"remains? to (?:be )?(?:checked|verified|confirmed)|before I (?:can|could) say|"
                    r"(?:that|this) (?:is|would be) (?:the |a )?(?:quick|short|cheap|easy) (?:check|test))\b"),
])

# Failure signatures that only ever appear in TOOL OUTPUT — never in prose.
TOOL_SIGS = re.compile(
    r"\[FAIL:\s*([^\]\n]{0,70})|Error \(\d+\):\s*([^\n]{0,70})|error\[E\d+\]:\s*([^\n]{0,70})|"
    r"panicked at ([^\n]{0,70})|(Compiler run failed)|Warning \((\d{4})\)", re.I)

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
    texts, tool_out = [], []
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
                if not isinstance(c, dict):
                    continue
                # `text` AND `thinking`: a concern reasoned about but never written into a reply
                # lives ONLY in thinking, and is exactly the loose end nothing else can see.
                if c.get("type") in ("text", "thinking"):
                    texts.append(c.get("text") or c.get("thinking") or "")
                # tool_result is a SEPARATE surface: compiler warnings, panics and failing
                # assertions never appear in prose. Scanning only `text` misses all of it —
                # this JSONL had 2,285 text blocks against 3,212 tool_results.
                # tool_use INPUTS: commands, not prose — but a comment written INSIDE one
                # (a heredoc, a python -c, a commit body) never appears anywhere else. This was
                # the last unscanned block type; without it the scan reads ~55% of the record.
                elif c.get("type") == "tool_use":
                    inp = c.get("input")
                    if isinstance(inp, dict):
                        for v in inp.values():
                            if isinstance(v, str) and len(v) > 60:
                                tool_out.append(v)
                elif c.get("type") == "tool_result":
                    v = c.get("content")
                    s = v if isinstance(v, str) else (" ".join(
                        d.get("text", "") for d in v if isinstance(d, dict)) if isinstance(v, list) else "")
                    if s:
                        tool_out.append(s)

    # ── TOOL OUTPUT, collapsed by REASON TYPE ────────────────────────────────────────────────
    # Collapsing by fragment is WRONG and hides the shape: 85 instances of one
    # `VenueUnavailable()` read as 82 separate findings until grouped by reason.
    import collections as _c
    blob = "\n".join(tool_out)
    kinds = _c.Counter()
    for mm in TOOL_SIGS.finditer(blob):
        g = next((x for x in mm.groups() if x), "")
        if g:
            kinds[re.sub(r"\s+", " ", g).strip()[:70]] += 1
    print("\n" + "=" * 78)
    print(f"TOOL OUTPUT — {len(tool_out)} result blocks, {len(kinds)} DISTINCT failure/warning types")
    print("=" * 78)
    print("⚠️ A type here is only a loose end if it STILL occurs. Re-run the suite and diff:")
    print("   most of these were driven to green during the session.")
    for k, n in kinds.most_common(20):
        print(f"  {n:>5}x  {k}")

    print("\n" + "=" * 78)
    print(f"TRANSCRIPT SCAN — {len(texts)} text+thinking blocks. What was SAID and may never have been BOOKED.")
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


def scan_prompts(path, doc):
    """PER-PROMPT coverage pass — the piece the family scan structurally cannot do.

    WHY THIS EXISTS. The family scan scores PASSAGES. A user prompt can therefore be 100% unbooked
    and still never surface, because its individual sentences each look like ordinary prose. That is
    exactly how the Rover design intent ("the NFT guarantees liquidity won't be pulled out … balanced
    … large enough for instant conversion") sat unbooked through a 454-prompt discussion: no sentence
    in it tripped a vocabulary family, and a keyword filter on "rover|weeth" dropped every contextual
    follow-up ("run it", "model it", "prove it") because the subject was implicit.

    So: score EVERY user prompt against a target doc by token coverage, and report the worst. This is
    deliberately noisy — it is a READING LIST, not a defect list. Read every row; do not sample.
    """
    D = doc.lower()
    msgs = []
    for line in open(path, errors="ignore"):
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        m = ev.get("message") or {}
        if m.get("role") != "user":
            continue
        c = m.get("content")
        s = c if isinstance(c, str) else (" ".join(
            x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
            if isinstance(c, list) else "")
        s = s.strip()
        if (not s or s.startswith("[SYSTEM") or s.startswith("<task-notification")
                or "<system-reminder>" in s[:60] or s.startswith("[Request interrupted")):
            continue
        msgs.append(s)
    STOP = {"should","because","through","there","which","would","could","really","thread","context",
            "before","without","against","message","between","another","already","something",
            "anything","everything","nothing","continue","understand"}
    rows = []
    for i, s in enumerate(msgs):
        toks = {t for t in re.findall(r"[a-zA-Z_][a-zA-Z0-9_]{5,}", s.lower()) if t not in STOP}
        if len(toks) < 4:
            continue
        miss = sum(1 for t in toks if t not in D)
        rows.append((miss / len(toks), i, s))
    rows.sort(reverse=True)
    print("\n" + "=" * 78)
    print(f"PER-PROMPT COVERAGE — {len(msgs)} prompts vs the target doc")
    print("=" * 78)
    print("⚠️ A READING LIST, not a defect list. Read EVERY row — sampling the top five is how the")
    print("   Rover design intent stayed unbooked through 454 prompts.")
    for r, i, s in rows[:60]:
        print(f"\n[{i}] uncovered={r:.2f}\n   {re.sub(chr(10),' ',s)[:240]}")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcript")
    ap.add_argument("--against", help="doc to score PER-PROMPT coverage against (e.g. docs/actionable/SPRINT.md §FROM-QUEUE)")
    a = ap.parse_args()
    scan_code()
    if a.transcript:
        scan_transcript(a.transcript)
        if a.against:
            scan_prompts(a.transcript, open(os.path.join(ROOT, a.against), errors="ignore").read())
    print(RULES)


if __name__ == "__main__":
    main()
