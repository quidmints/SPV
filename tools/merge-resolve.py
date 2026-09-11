#!/usr/bin/env python3
"""Resolve merge-conflict hunks by asking the MERGE BASE which side is the newer work.

WHY THIS EXISTS. On 2026-09-11 merging lane/CUT into main produced 70 genuine conflict
hunks across 23 paths, because main had stripped every comment from evm/src while the lane
had not, so every hunk in 16 files collided and git could not see which differences were
real. Resolving 70 hunks by eye is how a merge quietly drops another session's work --
`--ours` would have discarded the lane's 2,700 lines of kernel removal, `--theirs` would
have discarded a peer's landed security check. The base answers it mechanically.

THE RULE:
    main's text IS in the base   => the other side DELETED it   => take the other side
    other's text IS in the base  => main CHANGED it             => take main
    main's side is EMPTY         => ask the base again (see the bug below)
    anything else                => LEAVE CONFLICTED and report

⛔ THE BUG THIS SCRIPT EXISTS TO NOT REPEAT, AND IT BROKE `main`. The first version read an
empty main side as "main deleted it, which is newer work, so take main". An empty main side
has TWO causes and that rule assumed one of them:
    (a) main deleted something the base had        -> take main
    (b) the OTHER SIDE ADDED something new         -> take the other side
It fired on case (b) exactly once, for `LevMath._repayAndPullPooled`: the lane added the
declaration AND two call sites, the rule threw the declaration away and kept a call site, and
`main` stopped compiling with `Error (7576): Undeclared identifier`. A peer was ~minutes from
pushing it. The discriminator is whether the OTHER side's text is in the base.

⚠️ AND STRIP BOTH SIDES' COMMENTS BEFORE COMPARING, or the whole thing silently under-resolves.
A comment-free side never matches an unstripped base wherever a comment sat inside the block,
which is most blocks. That single fix took the unresolved count from 31 to 4.

ACCEPTANCE TEST -- the known positive, not a clean run:
    python3 tools/merge-resolve.py --self-test
It reconstructs the case (b) hunk and requires the added declaration to SURVIVE.

USAGE:
    python3 tools/merge-resolve.py --base <sha> <conflicted file>...
Then read the report: any file with `unresolved>0` needs a human, and that is the point.
"""
import argparse
import os
import re
import subprocess
import sys

SOL_COMMENT = re.compile(r'//[^\n]*|/\*.*?\*/', re.S)


def norm(s):
    return re.sub(r'\s+', ' ', s).strip()


def decomment(s):
    """Good enough for a SIMILARITY test, and deliberately not a rewriter.

    This is only ever used to compare a hunk against the base, never to edit a file, so a
    naive strip that would also eat a `//` inside a string literal is harmless here. Do NOT
    reuse it to rewrite source -- that needs the string-aware walker.
    """
    return SOL_COMMENT.sub('', s)


def base_text(base, path):
    r = subprocess.run(['git', 'show', f'{base}:{path}'], capture_output=True, text=True)
    return norm(decomment(r.stdout)) if r.returncode == 0 else None


def split_hunks(lines):
    """Yield ('text', line) or ('conflict', ours, theirs) in order."""
    i = 0
    while i < len(lines):
        if not lines[i].startswith('<<<<<<<'):
            yield ('text', lines[i])
            i += 1
            continue
        j = i + 1
        ours = []
        while j < len(lines) and not lines[j].startswith('======='):
            ours.append(lines[j])
            j += 1
        k = j + 1
        theirs = []
        while k < len(lines) and not lines[k].startswith('>>>>>>>'):
            theirs.append(lines[k])
            k += 1
        yield ('conflict', ours, theirs)
        i = k + 1


def decide(ours, theirs, bt):
    """Return 'ours' | 'theirs' | None (leave conflicted)."""
    o, t = norm(decomment('\n'.join(ours))), norm(decomment('\n'.join(theirs)))
    if o and o in bt:
        return 'theirs'          # main's text predates the base => other side removed it
    if t and t in bt:
        return 'ours'            # other's text predates the base => main changed it
    if not o:
        # THE CASE THAT BROKE main. Empty main side is ambiguous; ask the base.
        return 'ours' if t in bt else 'theirs'
    if not t:
        return None              # other side deleted, main's text is new -> a human decides
    return None


def resolve(path, base, label):
    src = open(path).read().split('\n')
    bt = base_text(base, path)
    if bt is None:
        return None, 'no base version of this path'
    out = []
    took = {'ours': 0, 'theirs': 0}
    unresolved = 0
    for item in split_hunks(src):
        if item[0] == 'text':
            out.append(item[1])
            continue
        _, ours, theirs = item
        d = decide(ours, theirs, bt)
        if d == 'ours':
            out.extend(ours)
            took['ours'] += 1
        elif d == 'theirs':
            out.extend(theirs)
            took['theirs'] += 1
        else:
            out.append('<<<<<<< HEAD')
            out.extend(ours)
            out.append('=======')
            out.extend(theirs)
            out.append(f'>>>>>>> {label}')
            unresolved += 1
    return '\n'.join(out), f"main={took['ours']} other={took['theirs']} unresolved={unresolved}"


def self_test():
    """The known positive: an addition on the OTHER side must survive."""
    base = norm(decomment('contract C { function keep() public {} }'))
    ours, theirs = [], ['    function _added() private {}']
    got = decide(ours, theirs, base)
    if got != 'theirs':
        sys.exit('🔴 SELF-TEST FAILED: an empty main side against an addition resolved to '
                 f'{got!r}, not "theirs". That is the bug that broke main -- LevMath'
                 '._repayAndPullPooled was discarded and one call site kept.')
    # and the genuine deletion case still resolves the other way
    base2 = norm(decomment('contract C { function gone() private {} }'))
    if decide([], ['    function gone() private {}'], base2) != 'ours':
        sys.exit('🔴 SELF-TEST FAILED: a real main-side deletion did not resolve to "ours".')
    if decide(['    uint a;'], ['    uint b;'], base) is not None:
        sys.exit('🔴 SELF-TEST FAILED: a two-sided change must be LEFT for a human.')
    print('✅ self-test: addition survives, deletion still applies, two-sided change left alone.')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', help='merge base sha (default: git merge-base HEAD MERGE_HEAD)')
    ap.add_argument('--label', default='other', help='label for any conflict left behind')
    ap.add_argument('--self-test', action='store_true')
    ap.add_argument('paths', nargs='*')
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    base = a.base
    if not base:
        head = subprocess.run(['git', 'rev-parse', 'MERGE_HEAD'], capture_output=True, text=True)
        if head.returncode != 0:
            sys.exit('no --base given and no merge in progress')
        base = subprocess.run(['git', 'merge-base', 'HEAD', head.stdout.strip()],
                              capture_output=True, text=True).stdout.strip()
    print(f'base {base[:8]}')
    for p in a.paths:
        if not os.path.exists(p):
            print(f'{p:<44} SKIP (missing)')
            continue
        txt, note = resolve(p, base, a.label)
        if txt is None:
            print(f'{p:<44} SKIP ({note})')
            continue
        open(p, 'w').write(txt)
        print(f'{p:<44} {note}')
    print('\n⚠️ A declaration census is NOT optional after this. Run:\n'
          '   for f in <files>; do compare `function|error|event|struct` names in each parent\n'
          '   against the merge result, minus the base; anything present in a parent and absent\n'
          '   in the result was DROPPED. That census is what caught _repayAndPullPooled.')


if __name__ == '__main__':
    main()
