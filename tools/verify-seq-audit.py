#!/usr/bin/env python3
"""Re-verify the §SEQ-AUDIT verdicts against code, in BOTH directions.

Six subagents marked ~395 SPRINT.md rows CLOSED on the strength of their own greps, and
those verdicts were written into the file before anyone checked them. Standing rule 16:
a ✅ is how the next thread decides what NOT to re-read, so a wrong one does not merely
mislead — it makes the error unreachable. Standing rule 13: a dismissal is a conclusion
and needs the same evidence as a finding.

So this checks the falsifiable half of every verdict itself:

  FALSE POSITIVE  = marked CLOSED but the symbol/file is still live  → the row was
                    crossed off while the work is real. The dangerous direction.
  FALSE NEGATIVE  = marked OPEN but the symbol/file is already gone  → we would rebuild
                    something that exists, or chase a defect already fixed.

⚠️ Declarations are NOT uses (CLAUDE.md records check-orphans.py reporting "0 orphans on
   a tree that had three" for exactly this), so `function foo(`, `error Foo(`, an
   interface line and a struct field are all subtracted before counting.
⚠️ Comments are NOT uses either — a symbol matches its own obituary, which is the whole
   reason these rows went stale in the first place.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (symbol, where, expectation) — expectation is what the audit CLAIMED.
#   "gone"  : the audit said this has zero live references
#   "live"  : the audit said this is present, and a row stays OPEN because of it
GONE_SOL = [
    "registerDelegation", "delegatedHop", "delegationVersion", "delegatedAuthority",
    "settleSwapIn", "settleSwapInBuffered", "settleSwapInSpliced", "parkProvenSats",
    "poolOwnedSats", "provenSatsAvailable", "InsufficientProvenSats",
    "MAX_WELL_SKEW", "reseatEpoch", "USD_FEES_BTC", "btcFeesOwedSats", "exitInstant",
    "IntentSellLegUnbuilt", "_unlockCallback", "vogueSyncHook", "calcFeeL1",
    "isValidSignatureNow", "setHopRegistry", "_requireAttested", "hopRegistry",
    "dust6", "_dustOf", "pushObservation", "registerFallback", "fallbackAuthority",
    "selfManaged", "oorBook", "repackNFT", "feeSettleSats", "outOfRange",
]
LIVE_SOL = [
    "settleSwapInProven", "registerChannelClaim", "_settleSellIntent", "termsCommitment",
    "borrowRateRay", "lpEthOf", "refillNeeded", "skewPremiumCum", "isTwoOfTwoOutputKey",
    "_requireRecipientPoP", "recordDeadManExit", "_armLadder",
]
GONE_RS = ["registerDelegation", "encode_register_delegation"]
LIVE_RS = ["presign_deadman_exit", "execute_sweep", "QUID_SWEEP_AUTH", "RoutingGate",
           "PINNED_DEPOSIT_INDEX", "FRESHNESS_SHARD"]
ABSENT_PATHS = [
    "evm/src/mock.sol", "docs/actionable/wip", "evm/src/AttestedHopRegistry.sol",
    "evm/test/BtcSelfManaged.t.sol", "evm/src/imports/SOR.sol", "evm/src/VEth.sol",
    "docs/actionable/QUEUE.md",
]
PRESENT_PATHS = [
    "evm/test/utils/ForkPin.sol", "evm/test/RefillKeeper.t.sol",
    "evm/test/PremiumIsCarryNotIncome.t.sol", "evm/src/Shares.sol",
    "evm/test/btc/DeadManExitVerify.t.sol", "quid-ln/quid-hop/src/liveness.rs",
]

DECL = re.compile(
    r"^\s*(?:abstract\s+)?(?:function|struct|enum|event|error|contract|library|interface|"
    r"mapping|uint\d*|int\d*|address|bytes\d*|bool|string|pub\s+fn|fn|const|static|"
    r"pub\s+const|pub\s+struct|pub\s+enum|use\s)"
)
COMMENT = ("//", "*", "/*", "///", "#")


def live_uses(sym: str, where: str) -> tuple[int, list[str]]:
    inc = "--include=*.sol" if where == "evm/src" else "--include=*.rs"
    out = subprocess.run(
        ["grep", "-rn", inc, rf"\b{sym}\b", str(ROOT / where)],
        capture_output=True, text=True).stdout
    hits = []
    for line in out.splitlines():
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        body = parts[2].strip()
        if body.startswith(COMMENT) or DECL.match(body):
            continue
        hits.append(f"{Path(parts[0]).name}:{parts[1]}")
    return len(hits), hits[:3]


def main() -> int:
    fp, fn, ok = [], [], 0

    for sym in GONE_SOL:
        n, ex = live_uses(sym, "evm/src")
        if n: fp.append(("SOL", sym, f"claimed GONE, {n} live use(s): {', '.join(ex)}"))
        else: ok += 1
    # 🔴 "IS IT GONE" AND "IS IT LIVE" NEED OPPOSITE QUERIES, AND USING ONE FOR BOTH IS
    # HOW THIS SCRIPT WAS WRONG ON ITS FIRST RUN. `settleSwapInProven`,
    # `registerChannelClaim`, `termsCommitment`, `borrowRateRay`, `lpEthOf`,
    # `refillNeeded` and `recordDeadManExit` all came back "claimed LIVE, zero live
    # uses" — because they are EXTERNAL ENTRYPOINTS whose only in-tree occurrence IS
    # the declaration, which the gone-check deliberately subtracts. An entrypoint has
    # no internal caller BY DESIGN; users call it.
    # ⇒ GONE means no use AND no declaration. LIVE means a DECLARATION EXISTS.
    #   Same trap as check-orphans.py, arriving inverted: there declarations were
    #   counted as callers, here subtracting them erased the subject entirely.
    for sym in LIVE_SOL:
        n, _ = live_uses(sym, "evm/src")
        decl = subprocess.run(
            ["grep", "-rn", "--include=*.sol", rf"\b{sym}\b", str(ROOT / "evm/src")],
            capture_output=True, text=True).stdout
        declared = any(
            DECL.match(l.split(":", 2)[2].strip())
            for l in decl.splitlines()
            if len(l.split(":", 2)) == 3 and not l.split(":", 2)[2].strip().startswith(COMMENT))
        if not n and not declared:
            fn.append(("SOL", sym, "claimed LIVE, but neither declared nor used"))
        else:
            ok += 1
    for sym in GONE_RS:
        n, ex = live_uses(sym, "quid-ln")
        if n: fp.append(("RS", sym, f"claimed GONE, {n} live use(s): {', '.join(ex)}"))
        else: ok += 1
    for sym in LIVE_RS:
        n, _ = live_uses(sym, "quid-ln")
        if not n: fn.append(("RS", sym, "claimed LIVE, zero live uses"))
        else: ok += 1
    for p in ABSENT_PATHS:
        if (ROOT / p).exists(): fp.append(("PATH", p, "claimed ABSENT, it exists"))
        else: ok += 1
    for p in PRESENT_PATHS:
        if not (ROOT / p).exists(): fn.append(("PATH", p, "claimed PRESENT, it is missing"))
        else: ok += 1

    total = ok + len(fp) + len(fn)
    print(f"# §SEQ-AUDIT verdict re-verification — {total} falsifiable claims re-run\n")
    print(f"  agreed with the audit          {ok}")
    print(f"  🔴 FALSE POSITIVES (wrongly closed) {len(fp)}")
    print(f"  🟡 FALSE NEGATIVES (wrongly open)   {len(fn)}\n")
    for kind, sym, why in fp:
        print(f"  🔴 [{kind}] {sym}: {why}")
    for kind, sym, why in fn:
        print(f"  🟡 [{kind}] {sym}: {why}")
    if not fp and not fn:
        print("  every falsifiable verdict holds.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
