#!/usr/bin/env python3
"""Find GHOST TESTS: functions that look like coverage and assert nothing that can fail.

⛔ A grep cannot do this. Every symbol in a ghost test resolves; what is missing is a
   FALSIFIABLE claim. The classes below were each observed in this tree.

ACCEPTANCE TEST (run it, per the known-positive rule): `--self-test` prints the four
shapes it must catch. If any prints MISSED, the detector is broken, not the tree.

CLASSES
  A  no assertion at all, directly or one level into a same-file helper
  B  only existence assertions -- assertGt(x, 0) / assertTrue(x != 0) and nothing else.
     A bug that makes x huge passes; a bug that makes it 1 wei passes.
  C  only a ONE-SIDED bound (assertLt/assertLe/assertGt/assertGe) with no equality or
     range pin -- vacuous when the defect drives the value toward the asserted side.
  D  asserts only on a literal it computed itself in the same function (self-fulfilling).
"""
import re, sys, pathlib

ASSERT = re.compile(r'\b(assert[A-Za-z]*)\s*\(')
FN     = re.compile(r'^\s*function\s+(test[A-Za-z0-9_]*)\s*\(', re.M)

def bodies(src):
    out=[]
    for m in FN.finditer(src):
        i=src.index('{', m.end()-1); d=0
        for j in range(i,len(src)):
            if src[j]=='{': d+=1
            elif src[j]=='}':
                d-=1
                if d==0: out.append((m.group(1), src[i:j])); break
    return out

def helpers(src):
    h={}
    for m in re.finditer(r'^\s*function\s+(_[A-Za-z0-9_]*)\s*\(', src, re.M):
        i=src.index('{', m.end()-1); d=0
        for j in range(i,len(src)):
            if src[j]=='{': d+=1
            elif src[j]=='}':
                d-=1
                if d==0: h[m.group(1)]=src[i:j]; break
    return h

def classify(body, hp):
    reach = body
    # ⛔ FALSE-POSITIVE CLASS, NAMED PER THE SWEEP RULE: a test with no assert* is NOT
    #    assertion-free if it uses vm.expectRevert (the revert IS the assertion) or is a
    #    deliberate "did not revert" acceptance test. Both were observed here and both are
    #    legitimate. What survives the filter is an INSTRUMENT: it logs and claims nothing.
    if 'expectRevert' in body or 'expectEmit' in body: return None, -1
    for name, hb in hp.items():
        if re.search(r'\b'+re.escape(name)+r'\s*\(', body): reach += hb
    a = ASSERT.findall(reach)
    if not a: return 'A', 0
    kinds = set(a)
    exist = re.findall(r'assertGt\s*\([^,]+,\s*0\s*[,)]|assertTrue\s*\([^)]*!=\s*0', reach)
    if len(exist) == len(a): return 'B', len(a)
    oneside = {'assertLt','assertLe','assertGt','assertGe'}
    if kinds and kinds <= oneside: return 'C', len(a)
    return None, len(a)

# ── CLASS E: THE NAME CLAIMS AN ADVERSARY THE BODY NEVER PRODUCES ──────────────
# CLAUDE.md's worst-case shape, measured: `test_MEV_OracleFloorRejectsSandwich` passed
# `1e30` as the KEEPER'S OWN minOut and asserted an impossible floor reverts -- no
# attacker, no price movement, and the oracle floor its name credits was never touched.
# "A green test named for the property STOPS people looking, forever."
CLAIM = re.compile(r'MEV|Sandwich|Attack|Adversar|Rejects|Refuses|Cannot|Never|Blocks|'
                   r'Gated|Unauthori|Steal|Drain|Grind|Manipul|Frontrun|Hijack', re.I)
# ⛔ FALSE-POSITIVE CLASS, FOUND BY READING THE HITS RATHER THAN BY TRUSTING THE COUNT:
#    AN ADVERSARY NEED NOT BE AN ACTOR. It can be a hostile INPUT.
#    `test_TheGenericDescriptorCannotDivertThePayout` builds a 1inch descriptor with an
#    attacker address in the dstReceiver word and asserts it did not survive `_retarget` --
#    a real attack, with no prank anywhere. `test_rejects_a_substituted_key` is the same
#    shape in the crypto tests: the malformed key IS the attacker.
#    ⇒ 11 raw hits were almost entirely this. Counting them as ghosts would have deleted the
#      single best security test in the tree, which is the exact inversion this tool exists
#      to prevent.
ADVERSARY = re.compile(
    r'vm\.prank|vm\.startPrank|expectRevert'          # a second actor, or a refusal
    r'|attacker|malicious|hostile|evil|adversar|poison|bad[A-Z]'   # a hostile INPUT
    r'|assertNotEq'                                     # "the attack did not survive"
    , re.I)

# ── CLASS F: CAN EXIT BEFORE ASSERTING ────────────────────────────────────────
SKIP = re.compile(r'vm\.skip\s*\(|^\s*return\s*;', re.M)

def claim_without_adversary(name, body):
    if not CLAIM.search(name): return False
    return not ADVERSARY.search(body)

def can_exit_early(body):
    a = ASSERT.search(body)
    if not a: return False
    return bool(SKIP.search(body[:a.start()]))

def main(paths):
    tot=0; flagged={'A':[], 'B':[], 'C':[], 'E':[], 'F':[]}
    for p in paths:
        src=pathlib.Path(p).read_text(); hp=helpers(src)
        for name, body in bodies(src):
            tot+=1
            k,n = classify(body, hp)
            if k: flagged[k].append((p, name, n))
            if claim_without_adversary(name, body): flagged['E'].append((p, name, 0))
            if can_exit_early(body):                flagged['F'].append((p, name, 0))
    print(f"control: parsed {tot} test functions across {len(paths)} files")
    if tot==0: print("PARSER BROKE — zero tests parsed is not a clean tree"); return 1
    for k, label in [('A','NO ASSERTION AT ALL'),
                     ('B','ONLY EXISTENCE (assertGt(x,0)) — a 1-wei bug passes'),
                     ('C','ONLY A ONE-SIDED BOUND — vacuous if the defect pushes that way'),
                     ('E','NAME CLAIMS AN ADVERSARY THE BODY NEVER PRODUCES'),
                     ('F','CAN RETURN/SKIP BEFORE IT ASSERTS ANYTHING')]:
        rows=flagged[k]
        print(f"\n=== CLASS {k}: {label} — {len(rows)} ===")
        for p,n,c in sorted(rows)[:40]:
            print(f"  {pathlib.Path(p).name:38} {n}")
    return 0

if __name__=='__main__':
    args=[a for a in sys.argv[1:] if not a.startswith('--')]
    sys.exit(main(args))
