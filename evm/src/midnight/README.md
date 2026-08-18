# `src/midnight` — Morpho Blue v2 (Midnight), vendored and minimally adapted

Upstream: `morpho-org/morpho-v2` @ `709dab35` (also present unmodified as the submodule
`evm/lib/morpho-v2`, which is the diff baseline — `diff -r lib/morpho-v2/src src/midnight`).

We deploy our OWN instance, so this is a fork, not a call-out to a deployed contract. Keep the
adaptation set as small as it is; every addition is code we own, must test, and must re-audit.

## The complete adaptation set — 3 pragma pins + 1 function body

| file | change | why |
|---|---|---|
| `Midnight.sol` | `pragma 0.8.34` → `0.8.30` | we pin solc 0.8.30 and solc 0.8.34 is not available to this toolchain (forge 1.5.1 cannot resolve it — upstream's own repo does not build here) |
| `ratifiers/SetterRatifier.sol` | same | same |
| `ratifiers/EcrecoverRatifier.sol` | same | same |
| `libraries/UtilsLib.sol` | `msb` body | `clz` is an **Osaka** opcode; we target cancun, and solc 0.8.30 has no `clz` builtin at ANY `evm_version` |

Nothing else differs. `interfaces/`, `libraries/` (bar `msb`), `IdLib`, `TickLib`, `EventsLib`,
`ConstantsLib`, `SafeTransferLib` and both ratifiers are byte-identical to upstream.

`periphery/` is deliberately NOT vendored: it imports Blue **v1** (`lib/morpho-blue`), a second
dependency we have not taken. `BlueBuyCallback` is the relend-while-committed primitive; see §E263
for the two conditions before adopting it.

## `msb` — the only semantic change

Upstream: `res := sub(255, clz(bitmap))`. Ours: smear-right then `countBits(x) - 1`, reusing the
SWAR popcount already defined directly above it, so it adds no new routine to the bytecode.

Verified by `test/MidnightMsb.t.sol` against an INDEPENDENT descending-scan reference (deliberately
not the same algorithm, so agreement is evidence rather than a tautology): all 128 single-bit
positions, all 127 smeared masks, and a 256-run fuzz. Upstream's undefined-input behaviour is
matched exactly — `sub(255, clz(0))` wraps to `type(uint256).max`, and so does `countBits(0) - 1`
under `unchecked`.

## Build settings — see the `compilation_restrictions` block in `evm/foundry.toml`

`via_ir = true` is REQUIRED (our global `via_ir = false` gives "Stack too deep", `LValue.cpp:54`,
at every optimizer_runs value). `optimizer_runs = 50` is the only measured value that fits EIP-170,
and the size curve is NOT monotonic in runs:

    runs=1 -> 24,508 (+68) | runs=50 -> 24,469 (+107) | runs=200 -> 24,650 (-74) | runs=466 -> 24,720 (-144)

Upstream fits at 466 only because Osaka's `clz` and 0.8.34's codegen are smaller. We have +107 bytes
of margin and this repo has already shipped an undeployable contract with a green suite, so run
`python3 tools/check-contract-sizes.py` after ANY change here — `forge build --sizes` is known to
omit contracts in this tree.
