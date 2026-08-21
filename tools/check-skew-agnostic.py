#!/usr/bin/env python3
"""Fail if the skew path re-couples to Uniswap.

WHY THIS EXISTS. The skew became representation-agnostic on 2026-08-15 when the
observation ring stopped storing ticks. Measured that day: all eight skew functions
scored ZERO v4 references, and the skew's entire contract with the rest of the system is
eight PLAIN NUMBERS in our own units -- no PoolKey, no tick, no sqrtPrice, no
BalanceDelta.

That property is worth guarding rather than re-deriving, because it is invisible: nothing
fails, nothing reverts, and no test goes red if a `sqrtPriceX96` or a `tickLower` creeps
back into a skew helper. It simply re-welds the skew to a pool manager we are removing,
and the next person to try the extraction pays for it.

The check is structural on purpose. It reads function BODIES, not a symbol table, because
a comment mentioning a tick is fine and a line of code using one is not -- so comment
lines are stripped before matching. It also asserts the SEAM ITSELF has not grown: the
skew may read the eight accessors below and nothing else, since each new one is a fresh
thing the replacement pool manager must implement.

Exit 0 = clean. Exit 1 = a finding, printed with file:line.
"""
import re, sys, pathlib

SRC = pathlib.Path(__file__).resolve().parent.parent / "evm" / "src" / "imports" / "SwapLib.sol"

# The skew path: the curve, its inputs, its composer and its two entry points.
SKEW_FNS = ["skewWad", "_maxWellSkew", "_skewBasis", "wellSkew",
            "sellSkew", "retainSkewPremium", "_composePrice", "_sharedScarcityWad"]

# Uniswap-v4 concepts. If any appears in a skew body, the skew is coupled to the PM again.
V4_TOKENS = ["PoolKey", "IPoolManager", "poolManager", "sqrtPrice", "SqrtPrice", "TickMath",
             "tickLower", "tickUpper", "rangeTicks", "getSlot0", "Currency", "BalanceDelta",
             "tickCumulative", "PoolId", "unlock"]

# The seam: the ONLY Core surface the skew is allowed to read. Each entry is a plain
# number in our own units, so a replacement PM can back it without inheriting v4's model.
ALLOWED_SEAM = {
    # §ISBTC-SPLIT — `POOLED`, not `POOLED_ETH`/`POOLED_BTC`. The seam did NOT grow: one contract
    # held both ranges, so it needed a name per width; with an instance PER width there is one
    # `POOLED` and two of it. The old pair is REMOVED rather than kept alongside -- leaving dead
    # names in an allowlist is how a genuinely new accessor slips through wearing a retired one.
    "POOLED",                            # inventory, raw
    "flowEwmaUsd",                       # the target
    # §V4-ZERO — no longer v4-backed. This read "the only one still v4-BACKED (ring via getSlot0)",
    # which was true while the observation ring was seeded from a v4 pool's slot0. The ring is
    # seeded from CHAINLINK (`OracleLib.seedPrices`) and advanced by `_writeObservationPrice`, so
    # nothing in the seam is v4-backed any more -- the whole point of the gate is now satisfiable.
    "realizedVarianceWad",
    # §ISBTC-SPLIT — `rangeEquityUsd18`, was `btcRangeEquityUsd18`. Same accessor, same units; the
    # `btc` prefix existed only because ONE contract named the BTC width's figure either way.
    "committedUsd18", "rangeEquityUsd18",      # shared-scarcity coupling
    "recordSkewPremium", "skewPremiumCum",    # the premium ledger
}


def bodies(text):
    """Yield (name, start_line, body_lines) for each skew function, comments stripped."""
    lines = text.split("\n")
    for name in SKEW_FNS:
        pat = re.compile(r"^\s*function\s+" + re.escape(name) + r"\s*\(")
        start = next((i for i, l in enumerate(lines) if pat.match(l)), None)
        if start is None:
            yield name, 0, None          # signals "not found" -- reported, not skipped
            continue
        out, depth, seen = [], 0, False
        for i in range(start, len(lines)):
            raw = lines[i]
            code = re.sub(r"//.*$", "", re.sub(r"///.*$", "", raw))
            out.append((i + 1, code))
            depth += code.count("{") - code.count("}")
            if "{" in code:
                seen = True
            if seen and depth <= 0:
                break
        yield name, start + 1, out


def main():
    text = SRC.read_text(encoding="utf-8")
    findings, seam_seen, checked = [], set(), 0

    for name, ln, body in bodies(text):
        if body is None:
            findings.append(f"{SRC.name}: skew function `{name}` NOT FOUND — renamed or "
                            f"deleted. Update this checker deliberately; do not drop the entry.")
            continue
        checked += 1
        for lineno, code in body:
            for tok in V4_TOKENS:
                if tok in code:
                    findings.append(f"{SRC.name}:{lineno}  `{name}` uses v4 concept `{tok}`\n"
                                    f"      {code.strip()[:100]}")
            # digits matter here: `[A-Za-z_]+` truncates `committedUsd18` to `committedUsd`
            # and the seam then reports two phantom findings. A checker that misreports is
            # worse than no checker, so this is spelled out rather than left to habit.
            for m in re.finditer(r"ICore\(core\)\.([A-Za-z_0-9]+)", code):
                seam_seen.add(m.group(1))

    # A seam that GREW is a finding: every new accessor is another thing the replacement
    # pool manager has to provide, and it should be an explicit decision.
    for extra in sorted(seam_seen - ALLOWED_SEAM):
        findings.append(f"{SRC.name}: skew reads NEW Core accessor `{extra}` — the seam grew. "
                        f"Add it to ALLOWED_SEAM only if the replacement PM can back it.")

    print(f"checked {checked}/{len(SKEW_FNS)} skew functions; "
          f"seam is {len(seam_seen)} accessor(s)")
    if findings:
        print(f"\n{len(findings)} finding(s):\n")
        for f in findings:
            print("  " + f)
        return 1
    print("clean — the skew path is free of Uniswap concepts and the seam has not grown")
    return 0


if __name__ == "__main__":
    sys.exit(main())
