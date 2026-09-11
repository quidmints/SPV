#!/usr/bin/env python3
"""Classify every `## ` section of docs/actionable/SPRINT.md as QUEUE or RECORD.

WHY THIS IS A SCRIPT AND NOT A PARAGRAPH. The 2026-09-11 cut took SPRINT.md from 55,027
lines to 5,855 and wrote its rule into the file as prose. Measured afterwards, against the
pre-cut file recovered from `4ae99cd6`:

    the published rule keeps        100 sections
    the cut actually kept            85
    open-marked WITH an imperative,
      cut anyway                     28   <- the rule said keep every one of these

A peer session hand-triaged those and found SIX still live (§THE-SLIPPAGE-WINDOW-IS-THE-LEAK,
§PARTIAL-TAKE-IS-DEBITED-IN-FULL, C3 vBTC asset(), A.5f, B6, §IMPACTED-TESTS-BASE-CLASS-BLINDSPOT).
So the rule was RIGHT and the execution did not follow it -- the cut used an earlier index whose
rule differed, and nothing announced the gap. CLAUDE.md's own ruling applies: "Never write prose
for something a gate can decide." This is that gate.

ACCEPTANCE TEST -- run it, do not trust a clean exit (the detector's acceptance test is the
KNOWN POSITIVE):

    python3 tools/sprint-actionable.py --self-test

It replays the pre-cut file and requires that §PARTIAL-TAKE-IS-DEBITED-IN-FULL and
§IMPACTED-TESTS-BASE-CLASS-BLINDSPOT both classify QUEUE. They were dropped by the cut and
both carry a ▶️, so a version of this script that does not surface them is the bug it exists
to prevent.

THE FALSE-NEGATIVE CLASS IS NAMED, PER THE SWEEP RULE, AND IT IS NOT SMALL: 132 sections are
open-marked, carry no closing marker, and phrase NO imperative anywhere in the body.
§THE-SLIPPAGE-WINDOW-IS-THE-LEAK is one -- it states a live money-path defect (SELL_SLIP_BPS is
still 100) and never asks for anything. A keyword rule cannot see those, so they are reported
SEPARATELY as REVIEW rather than silently dropped. Triage them against the CODE; that is the
only instrument that worked.
"""
import argparse, re, subprocess, sys

OPEN    = re.compile(r'🔴|🟡|🟠|⏸️')
CLOSED  = re.compile(r'✅|🪦|~~')
IMPERATIVE = re.compile(
    r'▶️'
    r'|\bmust (?:be |now )?(?:built|wired|measured|written|run|added|derived|decided)\b'
    r'|\bneeds? (?:a |an |to )?(?:fork test|measurement|ruling|decision|wiring)\b',
    re.I)

QUEUE, REVIEW, RECORD = 'QUEUE', 'REVIEW', 'RECORD'


def sections(lines):
    heads = [i for i, l in enumerate(lines) if l.startswith('## ')]
    for k, i in enumerate(heads):
        nxt = heads[k + 1] if k + 1 < len(heads) else len(lines)
        yield i + 1, nxt - i, lines[i], '\n'.join(lines[i:nxt])


def classify(heading, body):
    if not OPEN.search(heading) or CLOSED.search(heading):
        return RECORD
    return QUEUE if IMPERATIVE.search(body) else REVIEW


def run(lines):
    out = {QUEUE: [], REVIEW: [], RECORD: []}
    for ln, size, heading, body in sections(lines):
        out[classify(heading, body)].append((ln, size, heading[3:].strip()))
    return out


def self_test():
    """Replay the pre-cut file and require the two known positives."""
    try:
        blob = subprocess.run(
            ['git', 'show', '4ae99cd6:docs/actionable/SPRINT.md'],
            capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError:
        sys.exit('SELF-TEST INCONCLUSIVE: commit 4ae99cd6 is unreachable. '
                 'That is not a pass -- the acceptance test did not run.')
    res = run(blob.split('\n'))
    want = ['§PARTIAL-TAKE-IS-DEBITED-IN-FULL', '§IMPACTED-TESTS-BASE-CLASS-BLINDSPOT']
    titles = {t for _, _, t in res[QUEUE]}
    missing = [w for w in want if not any(w in t for t in titles)]
    print(f'replayed 4ae99cd6: QUEUE {len(res[QUEUE])}  REVIEW {len(res[REVIEW])}  '
          f'RECORD {len(res[RECORD])}')
    if missing:
        sys.exit(f'🔴 SELF-TEST FAILED: {missing} did not classify QUEUE. '
                 'They carry a ▶️ and were dropped by the cut; this is the known positive.')
    if len(res[REVIEW]) < 50:
        sys.exit(f'🔴 SELF-TEST FAILED: only {len(res[REVIEW])} REVIEW rows on the pre-cut '
                 'file. The false-negative class measured 132; a small number means the '
                 'imperative regex has widened and is now swallowing it silently.')
    print('✅ both known positives classify QUEUE, and the REVIEW class is still visible.')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path', nargs='?', default='docs/actionable/SPRINT.md')
    ap.add_argument('--self-test', action='store_true')
    ap.add_argument('--show', choices=[QUEUE, REVIEW, RECORD], help='list one class')
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    res = run(open(a.path, errors='ignore').read().split('\n'))
    for k in (QUEUE, REVIEW, RECORD):
        n = len(res[k]); ln = sum(s for _, s, _ in res[k])
        print(f'{k:<7} {n:>5} sections  {ln:>7,} lines')
    print('\nREVIEW is the class a keyword rule cannot decide: open marker, no closing marker,\n'
          'and no imperative phrased anywhere. Triage against the CODE, never against prose.')
    if a.show:
        print()
        for ln, size, t in res[a.show]:
            print(f'  {ln:>6} [{size:>3}] {t[:110]}')


if __name__ == '__main__':
    main()
