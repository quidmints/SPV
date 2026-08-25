#!/usr/bin/env python3
"""§ROUTE-BLOCKED-24 — source AggregationRouterV6 calldata for a fork test.

Foundry cannot build a 1inch route: it is computed OFF-CHAIN by a solver. This is the
`vm.ffi` bridge that lets a test supply one, which is the single missing input behind
32 of the suite's 39 failures.

    fetch_1inch_route.py <src> <dst> <amount> <from> [slippage_pct]
        -> 0x-prefixed router calldata on stdout, nothing else (forge parses stdout)

⚠️ `disableEstimate=true` is REQUIRED: 1inch otherwise simulates eth_estimateGas FROM
   `from`, which on a fork has neither the tokens nor the approval until the flash loan
   is live, so every quote 404s. Same note as quid-bridge/src/oneinch.rs.
⚠️ THE KEY LIVES IN evm/.env (gitignored) AS ONEINCH_API_KEY. Never inline it here —
   this file is committed.
⚠️ THE ROUTE IS BUILT AGAINST *CURRENT* MAINNET STATE while the test runs at FORK_BLOCK.
   That is safe only because the pin is recent: pool ADDRESSES are stable, and the
   on-chain `minOut` (checked on the balance delta) is what actually bounds the fill.
   If FORK_BLOCK drifts far from head, expect routes to stop executing — that is the
   tell, not a contract defect.
"""
import os, sys, json, subprocess, pathlib

def _key():
    k = os.environ.get("ONEINCH_API_KEY")
    if k: return k
    env = pathlib.Path(__file__).resolve().parent.parent / "evm" / ".env"
    if env.exists():
        for ln in env.read_text().splitlines():
            if ln.startswith("ONEINCH_API_KEY="):
                return ln.split("=", 1)[1].strip().strip('"')
    return None

def main():
    a = sys.argv[1:]
    if len(a) < 4:
        print("0x", end=""); return 1
    src, dst, amount, frm = a[0], a[1], a[2], a[3]
    slip = a[4] if len(a) > 4 else "1"
    key = _key()
    if not key:
        # No key -> emit empty calldata. `_aggSwap` then reverts NoVolatileRoute(), which
        # is the HONEST pre-key behaviour rather than a fabricated route.
        print("0x", end=""); return 0
    url = (f"https://api.1inch.dev/swap/v6.0/1/swap?src={src}&dst={dst}&amount={amount}"
           f"&from={frm}&slippage={slip}&disableEstimate=true")
    # ⚠️ SHELL OUT TO `curl`, NOT `urllib`. MEASURED: the identical request via
    #    `urllib.request` returns **HTTP 403 Forbidden** while `curl` succeeds — the API
    #    rejects urllib's default User-Agent. Guessing headers is a worse bet than using
    #    the transport that demonstrably works, and `curl` is already a hard dependency of
    #    this repo's fixture tooling.
    try:
        out = subprocess.run(
            ["curl", "-s", "-m", "25",
             "-H", f"Authorization: Bearer {key}",
             "-H", "Accept: application/json", url],
            capture_output=True, text=True, timeout=30).stdout
        body = json.loads(out)
    except Exception:
        print("0x", end=""); return 0
    print(body.get("tx", {}).get("data", "0x"), end="")
    return 0

if __name__ == "__main__":
    sys.exit(main())
