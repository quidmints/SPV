#!/usr/bin/env python3
"""§E247 — the builder↔allowlist gate for the enclave's EVM signing policy.

`EvmTxPolicy` FAILS CLOSED: a transaction whose selector is not derived from
`HOP_SIGNED_FN_SIGS` (∪ `HOP_BTCCHANNELS_SIGS`) is refused at the signing
chokepoint. `check-client-abis.py` catches a listed selector that drifted from
the CONTRACT, but nothing gated the other seam: a selector the keepers BUILD
that is absent from the POLICY. That absence is invisible from either file
alone, and it has now happened twice in opposite directions (§E237 listed a
dead selector; §E247 omitted four live ones — `compound`, `rebalanceMany`,
`repay`, and `rebalanceWbtc`, the last re-lost by the 1inch revert one commit
after it was first fixed).

What this does, mechanically:
  1. parses the hand-written `HOP_SIGNED_FN_SIGS` entries out of
     `evm_validating_signer.rs` (the codec's `HOP_BTCCHANNELS_SIGS` half is
     derived from the SAME constants the calldata is built with, so it cannot
     drift from what is sent and is folded in here for the membership test);
  2. enumerates every signature-shaped string literal in production Rust under
     `quid-ln/` — NOT just `selector4("…")` call sites: builders also take the
     signature through helpers (`encode_batch`, `send_leg`), so the literal is
     the invariant, the helper name is not. Test modules (`#[cfg(test)]`),
     `tests/` dirs, vendored `lib/`, and the two declaration files themselves
     are excluded;
  3. forces every literal into exactly one class:
       • hop-signed  → must be in the allowlist, else FAIL (it would be
                       refused at the chokepoint — the §E247 class);
       • READ_ONLY   → eth_call/view surface; never reaches the signer.
                       Declared below, with the burden on the author: an
                       UNCLASSIFIED literal FAILS until it is either allowed
                       or waived here, which is the decision §E247 lacked;
     and, in the reverse direction,
       • an allowlist entry with NO production builder FAILS as an ORPHAN
         (the `repackNFT` class: signable surface nothing sends).

Event topics (CamelCase with a lowercase letter) are skipped — they are
`eth_getLogs` filters, not calls. ALL-CAPS accessors (`COLLATERAL()`) are
functions and stay in scope.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QUID_LN = ROOT / "quid-ln"
SIGNER_RS = QUID_LN / "quid-bridge" / "src" / "evm_validating_signer.rs"
CODEC_RS = QUID_LN / "quid-hop" / "src" / "evm_codec.rs"

# ── the read-only waiver set ────────────────────────────────────────────────
# Signatures that appear in production builders but are ONLY ever `eth_call`'d
# (reads never pass through the signer — the allowlist header says so). Adding
# a name here is a claim that no code path sends it as a transaction; if a
# literal you just added trips the gate, decide which side it belongs on
# rather than widening this list by reflex.
READ_ONLY = {
    # bridge / channel state reads
    "swapInUsed(bytes32)",
    "getMainchainHeight()",
    "blockExists(bytes32)",
    "channels(bytes32)",
    "btcRecipientOf(address)",
    "pendingOnchainSwapOut(bytes32)",
    "migrationNonceUsed(bytes32)",
    "freshnessSeq(bytes32)",
    "managerFreshnessSeq(address)",
    # lev keeper position/venue reads
    "pos(address)",
    "openLpAt(uint256)",
    "openLevCount()",
    "liqThresholdBps()",
    "ilTargetLtvBps(address)",
    "ilLtvBps(address)",
    "getCurrentLtvBps(address)",
    "collValueUsd(uint256)",
    "netEquity(address)",
    "netEquityUsd(address)",
    "debtDeltaToTarget(address)",
    "leverSupply(uint256)",
    "immatureBalanceOf(address)",
    "pendingRewards(address)",
    "balanceOf(address)",
    "COLLATERAL()",
}

SIG_RE = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*)\(([a-z0-9\[\],]*)\)"')
ARG_RE = re.compile(r"^(address|uint\d*|int\d*|bytes\d*|bool|string)(\[\])?$")


def is_signature(name: str, args: str) -> bool:
    """A plausible Solidity function signature: every arg parses as a type,
    and the name is not an event (CamelCase containing a lowercase letter)."""
    if name[0].isupper() and any(c.islower() for c in name):
        return False  # event topic, not a call
    if args == "":
        return True
    return all(ARG_RE.match(a) for a in args.split(","))


def strip_test_modules(src: str) -> str:
    """Remove `#[cfg(test)] mod … { … }` bodies by brace counting."""
    out, i = [], 0
    while True:
        m = re.search(r"#\[cfg\(test\)\]", src[i:])
        if not m:
            out.append(src[i:])
            break
        start = i + m.start()
        out.append(src[i:start])
        brace = src.find("{", start)
        if brace == -1:
            break  # attribute on a non-block item at EOF
        depth, j = 1, brace + 1
        while j < len(src) and depth:
            if src[j] == "{":
                depth += 1
            elif src[j] == "}":
                depth -= 1
            j += 1
        i = j
    return "".join(out)


def parse_allowlist() -> set[str]:
    src = SIGNER_RS.read_text()
    m = re.search(r"HOP_SIGNED_FN_SIGS:\s*&\[&str\]\s*=\s*&\[(.*?)\];", src, re.S)
    if not m:
        sys.exit("FATAL: HOP_SIGNED_FN_SIGS not found — the parser or the file moved")
    body = re.sub(r"//[^\n]*", "", m.group(1))  # comments may quote dead sigs
    return {f"{n}({a})" for n, a in SIG_RE.findall(body)}


def parse_codec_sigs() -> set[str]:
    src = CODEC_RS.read_text()
    consts = dict(
        re.findall(r'const\s+(SIG_[A-Z_0-9]+):\s*&str\s*=\s*"([^"]+)"', src)
    )
    m = re.search(r"HOP_BTCCHANNELS_SIGS:\s*&\[&str\]\s*=\s*&\[(.*?)\];", src, re.S)
    if not m:
        sys.exit("FATAL: HOP_BTCCHANNELS_SIGS not found in evm_codec.rs")
    names = re.findall(r"SIG_[A-Z_0-9]+", m.group(1))
    missing = [n for n in names if n not in consts]
    if missing:
        sys.exit(f"FATAL: HOP_BTCCHANNELS_SIGS names consts with no string: {missing}")
    return {consts[n] for n in names}


def production_literals() -> dict[str, list[str]]:
    """signature → [file:line] across production Rust."""
    found: dict[str, list[str]] = {}
    for path in sorted(QUID_LN.rglob("*.rs")):
        rel = path.relative_to(ROOT)
        parts = rel.parts
        if "target" in parts or "tests" in parts:
            continue
        if len(parts) > 1 and parts[1] == "lib":
            continue  # vendored rust-lightning
        if path in (SIGNER_RS, CODEC_RS):
            continue  # the declaration files themselves
        try:
            src = path.read_text()
        except UnicodeDecodeError:
            continue
        src = strip_test_modules(src)
        for lineno, line in enumerate(src.splitlines(), 1):
            for name, args in SIG_RE.findall(line):
                if not is_signature(name, args):
                    continue
                sig = f"{name}({args})"
                found.setdefault(sig, []).append(f"{rel}:{lineno}")
    return found


def main() -> int:
    hand = parse_allowlist()
    codec = parse_codec_sigs()
    allowed = hand | codec
    built = production_literals()

    failures = []

    # direction 1: built but neither allowed nor waived → refused at the chokepoint
    for sig in sorted(built):
        if sig in allowed or sig in READ_ONLY:
            continue
        sites = ", ".join(built[sig][:3])
        failures.append(
            f"UNCLASSIFIED  {sig}  built at {sites} — if it is SENT AS A TRANSACTION "
            f"add it to HOP_SIGNED_FN_SIGS (else the enclave refuses it); if it is "
            f"only ever eth_call'd, add it to READ_ONLY in this script with that claim."
        )

    # sanity: a signature both waived and allowed is a contradiction
    for sig in sorted(READ_ONLY & allowed):
        failures.append(
            f"CONTRADICTION {sig} is in READ_ONLY here AND in the allowlist — "
            f"one of the two claims is wrong."
        )

    # direction 2: hand-listed but never built → signable surface nothing sends
    for sig in sorted(hand):
        if sig not in built:
            failures.append(
                f"ORPHAN        {sig}  in HOP_SIGNED_FN_SIGS with no production builder "
                f"(the repackNFT class). Delete it, or point at the builder this misses."
            )

    n_ok = sum(1 for s in built if s in allowed)
    print(
        f"checked {len(built)} production signature literals: "
        f"{n_ok} hop-signed, {sum(1 for s in built if s in READ_ONLY)} read-only; "
        f"allowlist = {len(hand)} hand + {len(codec)} codec-derived"
    )
    if failures:
        print()
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print("clean — every built selector is signable, every listed selector is built")
    return 0


if __name__ == "__main__":
    sys.exit(main())
