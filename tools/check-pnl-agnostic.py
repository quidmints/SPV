#!/usr/bin/env python3
"""Ratchet on the P&L accumulators' independence from Uniswap v4.

WHY THIS SHAPE. Measured 2026-08-16, the de-association is NOT a broad sweep -- it is
exactly the four `POOLED_*` mirrors and nothing else:

    POOLED_ETH / POOLED_BTC / POOLED_USD_ETH / POOLED_USD_BTC   v4-COUPLED (BalanceDelta,
                                                                poolManager, getSlot0)
    skewPremiumETH / skewPremiumBTC                              already free
    _flowETH / _flowBTC / _premETH / _premBTC                    already free

A gate that simply failed on coupling would be red from day one, and a permanently-red gate
is noise that hides real regressions. So this is a RATCHET against a recorded baseline:

  * an accumulator listed as CLEAN that becomes coupled is a FAILURE -- that is the
    regression this exists to catch, and it is otherwise invisible because nothing reverts
    when a v4 type creeps into a write path;
  * an accumulator listed as COUPLED that becomes clean is PROGRESS -- reported, and the
    baseline should be tightened in the same commit so the ground gained is held.

WHAT "COUPLED" MEANS. The check reads the ENCLOSING FUNCTION of every write to an
accumulator and looks for v4 concepts in it, with comments stripped -- a comment naming
BalanceDelta is fine, a line using one is not.

⚠️ A CLEAN RESULT HERE IS NOT THE WHOLE PROPERTY. The flow/premium EWMAs write cleanly but
are FED from `_handleSwap`, which reads the leg off a v4 `BalanceDelta`. Write-path purity
and SOURCE purity are different claims; this tool checks the first. The owner's constraint
is that handle-delta survives for IMBALANCE CALCULATION ONLY, so once the cut lands the
`POOLED_*` writes must come from the settlement path and `_handleDelta` must no longer be
their source.

Exit 0 = no regression. Exit 1 = a clean accumulator became coupled, or the file moved.
"""
import re, sys, pathlib

SRC = pathlib.Path(__file__).resolve().parent.parent / "evm" / "src" / "Core.sol"

V4_TOKENS = ["BalanceDelta", "feesAccrued", "poolManager", "PoolKey", "CurrencySettler",
             "sqrtPrice", "TickMath", "getSlot0", "tickLower", "tickUpper", "PoolId"]

# Baseline measured 2026-08-16 against Core.sol. CLEAN entries are protected; COUPLED
# entries are the remaining work. Tighten COUPLED -> CLEAN in the same commit that frees one.
# §C27 — BASELINE UPDATED DELIBERATELY, with the evidence, per this file's own instruction
# ("update the baseline deliberately; do not drop the entry"). All six former entries had ZERO write
# sites, which this check correctly refused to pass over silently.
#   • skewPremiumETH / skewPremiumBTC -> `skewPremium`. A RENAME, not a removal: `Core.sol:346`
#     declares `uint public skewPremium` and `:358` writes `skewPremium += premiumUsd`. The ETH/BTC
#     suffix moved from the NAME to the INSTANCE (Core is deployed twice), which is the standing
#     "one name per concept, two instances" pattern -- so ONE entry now covers both books.
#   • _flowETH / _flowBTC / _premETH / _premBTC -> NO SUCCESSOR. Not renamed: there is no
#     `flow*`/`prem*` accumulator taking `+=`/`-=` anywhere in `evm/src`. The quantity is computed
#     and discarded rather than accumulated, which is precisely what §E320-SSRN books ("we compute
#     the sign on every swap and throw it away"). They are removed from the ratchet because the
#     symbol is gone, NOT because the check was inconvenient -- if a flow accumulator is ever added
#     back, it must be re-listed here.
CLEAN   = ["skewPremium"]
COUPLED = ["POOLED_ETH", "POOLED_BTC", "POOLED_USD_ETH", "POOLED_USD_BTC"]


# Accumulators are written two ways, and matching only the first is a checker bug I shipped
# once already: the plain uints are ASSIGNED, but the flow/premium registers are `Flow`
# STRUCTS mutated by reference inside `_bumpEwma(f, ...)`, so `acc =` never matches them and
# they read as "deleted". A checker that misreports is worse than no checker.
MUTATORS = ["_bumpEwma", "_bumpFlow", "_bumpPrem"]


def write_sites(lines, acc):
    """Lines where `acc` is assigned, OR handed to a known mutator by reference."""
    out = []
    for i, l in enumerate(lines, 1):
        code = re.sub(r"//.*$", "", l)
        if re.search(re.escape(acc) + r"\s*[+\-]?=[^=]", code):
            out.append(i); continue
        if acc in code and any(m + "(" in code for m in MUTATORS):
            out.append(i)
    return out


def enclosing_body(lines, lineno):
    """The function body containing `lineno`, comments stripped."""
    start = lineno
    while start > 1 and not re.match(r"^    function ", lines[start - 1]):
        start -= 1
    end = lineno
    while end < len(lines) and not re.match(r"^    \}", lines[end - 1]):
        end += 1
    return "\n".join(re.sub(r"//.*$", "", x) for x in lines[start - 1:end])


def coupling(lines, acc):
    found = set()
    sites = write_sites(lines, acc)
    for s in sites:
        body = enclosing_body(lines, s)
        for t in V4_TOKENS:
            if t in body:
                found.add(t)
    return sites, sorted(found)


def main():
    if not SRC.exists():
        print(f"FAIL: {SRC} not found — Core moved; update this checker deliberately.")
        return 1
    lines = SRC.read_text(encoding="utf-8").split("\n")
    failures, progress = [], []

    for acc in CLEAN:
        sites, found = coupling(lines, acc)
        if not sites:
            failures.append(f"`{acc}` has NO write sites — renamed or deleted. Update the "
                            f"baseline deliberately; do not drop the entry.")
        elif found:
            failures.append(f"REGRESSION: `{acc}` was v4-FREE and its write path now uses "
                            f"{', '.join(found)} (writes at lines {sites})")

    for acc in COUPLED:
        sites, found = coupling(lines, acc)
        if sites and not found:
            progress.append(f"`{acc}` is now v4-FREE — tighten the baseline in this commit")

    print(f"P&L accumulators: {len(CLEAN)} protected, {len(COUPLED)} still coupled")
    for p in progress:
        print("  PROGRESS: " + p)
    if failures:
        print(f"\n{len(failures)} finding(s):\n")
        for f in failures:
            print("  " + f)
        return 1
    print("clean — no protected accumulator has re-coupled to v4")
    return 0


if __name__ == "__main__":
    sys.exit(main())
