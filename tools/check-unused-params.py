#!/usr/bin/env python3
"""Find NAMED function parameters that the body never reads.

WHY THIS EXISTS. On 2026-09-11 the same defect was found three times in one session, each time by
accident while deleting something else:

    wellSkew(address, uint, uint)      three parameters, all unnamed, body returned a constant
    WbtcCfg.twapWindow                 a struct field threaded through two construction sites, never read
    Core.setup(..., uint seedPrice)    dead the moment OracleLib.seedRing was deleted

Each was the residue of a real mechanism that had been deleted around it. None was caught by a
build -- solc warns about an unused LOCAL but an unused PARAMETER is legal and silent, and an
unnamed one does not even warn. They are the quiet half of a purge: the mechanism goes, the
signature keeps promising it, and every caller keeps computing an argument that lands nowhere.

⛔ THE FALSE-POSITIVE CLASSES ARE NAMED, per this repo's sweep rule, and they are why the output is
a QUESTION rather than a finding:
  1. INTERFACE / ABSTRACT declarations -- no body by construction. Skipped.
  2. An override or a callback whose signature is fixed by a base or an external protocol
     (onMorphoFlashLoan, _lzReceive, ERC-4626 previews). The parameter is part of a contract with
     someone else and cannot be dropped.
  3. A parameter kept for ABI stability on an `external` function a client encodes by signature.
  4. Assembly blocks -- this reads source text, not the AST, so a parameter used only inside
     `assembly { }` may read as unused. Verify before deleting.

⇒ a hit means "open the file", never "delete the argument".

USAGE
    python3 tools/check-unused-params.py [paths...]      # default: evm/src minus generated identity
    python3 tools/check-unused-params.py --self-test
"""
import os
import re
import sys

FN = re.compile(r'\bfunction\s+(\w+)\s*\(([^)]*)\)([^{;]*)([;{])', re.S)
PARAM = re.compile(r'^\s*([\w\[\]\.]+)\s+(?:calldata\s+|memory\s+|storage\s+|payable\s+)*(\w+)\s*$')
SKIP_DIRS = ('identity/generated', 'identity/verifier')


def body_of(src, open_brace_at):
    """Return the text of the function body starting at its opening brace."""
    depth, i, n = 0, open_brace_at, len(src)
    while i < n:
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return src[open_brace_at + 1:i]
        i += 1
    return ''


def scan(path):
    src = open(path, errors='ignore').read()
    out = []
    for m in FN.finditer(src):
        name, params, _mods, term = m.group(1), m.group(2), m.group(3), m.group(4)
        if term == ';':
            continue                       # a declaration, not a definition
        body = body_of(src, src.index('{', m.end() - 1))
        if not body.strip():
            continue                       # an empty body is a deliberate no-op, not a defect
        for p in params.split(','):
            pm = PARAM.match(p)
            if not pm:
                continue                   # unnamed -- already the strongest form, but not this tool's job
            pname = pm.group(2)
            if pname in ('memory', 'calldata', 'storage', 'payable'):
                continue
            if not re.search(r'\b' + re.escape(pname) + r'\b', body):
                line = src[:m.start()].count('\n') + 1
                out.append((line, name, pm.group(1), pname))
    return out


def self_test():
    """The known positives: the three found by hand on 2026-09-11."""
    import tempfile
    sample = '''
    contract T {
        function setup(address a, uint seedPrice) external { x = a; }
        function keeps(uint used) internal { y = used; }
        function decl(uint gone) external;
    }
    '''
    with tempfile.NamedTemporaryFile('w', suffix='.sol', delete=False) as f:
        f.write(sample)
        p = f.name
    hits = {h[3] for h in scan(p)}
    os.unlink(p)
    if 'seedPrice' not in hits:
        sys.exit('🔴 SELF-TEST FAILED: an unread parameter was not reported. That is the whole tool.')
    if 'used' in hits:
        sys.exit('🔴 SELF-TEST FAILED: a parameter the body DOES read was reported.')
    if 'gone' in hits:
        sys.exit('🔴 SELF-TEST FAILED: a bodiless DECLARATION was reported. Interfaces are not defects.')
    print('✅ self-test: unread reported, read not reported, declaration not reported.')


def main():
    if '--self-test' in sys.argv:
        return self_test()
    roots = [a for a in sys.argv[1:] if not a.startswith('-')] or ['evm/src']
    files, hits = 0, []
    for root in roots:
        for r, _d, fs in os.walk(root):
            if any(s in r for s in SKIP_DIRS):
                continue
            for n in sorted(fs):
                if n.endswith('.sol'):
                    files += 1
                    for h in scan(os.path.join(r, n)):
                        hits.append((os.path.join(r, n),) + h)
    for path, line, fn, typ, pname in hits:
        print(f'{path}:{line}  {fn}(… {typ} {pname} …)  <- never read in the body')
    print(f'\n{len(hits)} unread parameters across {files} files')
    print('⚠️  A hit is a QUESTION. Skip overrides, protocol callbacks, ABI-stable externals and\n'
          '    anything used only inside an assembly block — see this file\'s header.')


if __name__ == '__main__':
    main()
