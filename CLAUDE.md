# SPV — working rules and environment facts

This file exists because these facts were living **only** in one machine's agent-memory directory.
`docs/actionable/QUEUE.md` tracks *what to build*; this file tracks *how to work here* and *what the
environment actually is*. Every line below was verified in-repo, not recalled.

## Standing rules (from the repo owner; they apply to every task, not just the one that prompted them)

1. **No unreachable code.** If a branch can't be hit, delete it — don't leave it "for safety".
2. **One declaration per interface, in a shared file.** `src/imports/Interfaces.sol` is canonical.
   No per-file `IFoo_` variants.
3. **Minimise clamps that give a false sense of safety.** Attack the cause, not the symptom.
   *Inverse:* a check **earns** its place when violating it would be **silent** and produce
   plausible-but-wrong output. The discriminator is whether the failure announces itself.
4. **Never mask the question.** A tolerance, guard, or skip that makes a test pass is the tell that
   the real defect is still there.
5. **Don't mock.** Use real addresses. Inherited or vendored code is not exempt from testing.
6. **Fix on detect.** Don't file a follow-up for something you can fix now.
7. **No cryptic names.**
8. **Don't hand-roll** what an existing library or tool already does.
9. **Price every fix on every axis** before calling it done: correctness (tested, not reasoned),
   cost/frequency, blast radius, second-order effects, other callers, reversibility. The regression
   is always on the axis nobody measured. If an axis can't be measured yet, say so explicitly.
10. **One money-path change per test run**, with a falsifiable prediction stated first. Two at once
    and failures can't be attributed.
11. **Commit every completed unit immediately**, and commit *before* starting a long-running build or
    test — a command chained to its own commit dies on the tool timeout, the edit lands, the record
    is lost.

12. **Lift a finding to a task IN THE SAME TURN, or it does not exist.** If you write "worth
    checking", "still needs", "I didn't" — book it before sending the message. A finding in prose
    dies with the context window. Four real items were lost this way on 2026-08-02, each already
    written down somewhere: recorded somewhere, actionable nowhere.
13. **A dismissal is a conclusion.** "That's a false positive" needs the same evidence as a finding.
    Twice in one day a real finding was waved away with a plausible explanation that was never
    checked — and the second time the dismissal had already been committed to a document.
14. **Another thread may be in this tree.** Check `git status` before staging. **Never `git add -A`,
    never commit with `-a`** — stage your own files by name, or you will sweep someone else's
    staged work into your commit. If there is an unpushed commit that is not yours, do not amend or
    rebase it; pushing it is fine and backs it up.
15. **Never commit an unverified change on a money or proof path.** A plausible-but-wrong constraint
    is worse than a documented open hole, because it looks fixed. One was committed on 2026-08-02
    and broke `main`. If the verification run has not finished, say it is in flight and wait.

## Verification discipline

- **An empty grep proves nothing.** Never assert absence from a search. **Run the CONTROL before
  concluding: would this measurement look the same if I were wrong?** On 2026-08-02, "35 verifiers
  are unreferenced, therefore dead" collapsed when the LIVE verifiers scored identically — they are
  wired by address, not by symbol, so the metric could not distinguish dead from unwired.
- **A comment describes past state.** Audit by structure (`^interface`, `^function`), never by a type
  name — a name matches its own obituary.
- **Report pass/fail from a single run.** Capture once to a file; never enumerate one run's failures
  with a second invocation.
- **Line count is not identity.** Same-named, same-sized files can be complementary halves — `diff`
  before calling anything a duplicate, and find the *live* copy before editing.
- **Check the mechanism before building around it.** The fix is usually smaller, or somewhere else.
- **After any Solidity change, run `tools/check-client-abis.py`.** `forge` + `tsc` both green does
  **not** mean the TypeScript clients still work.

## Build environment

| | |
|---|---|
| solc | `0.8.30`, optimizer on, **200 runs** (`evm/foundry.toml`) |
| `via_ir` | **`false`, deliberately.** Stack-too-deep is solved by moving locals into struct fields (one memory pointer costs less stack than two values), not by turning on the IR pipeline. |
| remappings | `evm/remappings.txt` only — there is deliberately no `remappings = [...]` in `foundry.toml` |
| **EIP-170** | `forge test` does **not** enforce the 24,576-byte limit. Only `forge build --sizes` does. Run it after any change to `SwapLib`, `LevMath`, or `LevManager` — all three sit within ~150 bytes of the ceiling. |
| library bodies | Delegatecalled library functions must be `external`/`public`. That is why the external surface is large; it is not accidental API. |
| fork tests | `FOUNDRY_RPC_ENDPOINTS_MAINNET=<url> FORK_BLOCK=<n> forge test` — the env var overrides `foundry.toml` with no file edit. Public nodes are not archival; a stale `FORK_BLOCK` fails to fetch rather than failing a test. |
| Rust (`quid-ln`) | **Does not build on macOS at all** — `quid-cvm` is Linux-only and transitive. Use the image: `docker build -t quid-ln:dev quid-ln` then `docker run --rm -v "$PWD/quid-ln":/w -w /w quid-ln:dev`. **VERIFIED GREEN: 532 passed / 0 failed.** `quid-ln/Dockerfile` is the single source for the commands — it pins rust 1.90 to `rust-toolchain.toml` and bakes Bitcoin Core **30.2, the same version `regtest/env.sh` uses** (a split would mean Docker and host harnesses disagreeing on consensus). |
| Docker VM memory | `docker info` MemTotal is a **VM allocation, not host free RAM** — closing apps does nothing. Default is ~2 GB; **raised to ~5 GB 2026-08-02.** Change at Docker Desktop → Settings → Resources → Memory. **Not scriptable:** `~/Library/Group Containers/group.com.docker/settings.json` is TCC-protected, so a shell gets `Operation not permitted` even as its owner without Full Disk Access. ⚠️ **Under-memory `rustc` is OOM-killed with NO diagnostic** — just `process didn't exit successfully`, no error code or span. That reads exactly like a compile error and is not one. Escape hatch: `-e CARGO_BUILD_JOBS=1 -e RUSTFLAGS="-C debuginfo=0"`. |

## Decimal bases — the single most common source of bugs here

Three bases coexist: **6** (USD stables), **8** (sats/WBTC), **18** (ETH/QU!D/internal USD).

The WBTC price carries a **×1e10 lift** (`usd·1e28`), which closes the 8↔18 gap — so a flat `/1e30`
or `1e18` scale is correct for **both** assets, and adding a second `×1e10` somewhere "to fix BTC"
double-counts it.

**Never infer a stable's decimals from its slot index.** A positional divisor
(`i < 4 || i == 11 ? 1e12 : 1`) shipped once and broke when a 6-dec stable joined at a later slot;
`IERC20(stable).decimals()` is the fix, not the complexity (`src/imports/BasketLib.sol:282`).

## Cross-repo

- **`../ibiza` consumes SPV as a pinned git submodule** and depends on exactly four Vogue/Basket
  signatures staying permissionless and stable. Changing them is a breaking change for a repo that
  isn't in this working tree.
- `docs/informational/` **contradicts the contracts in ~10 verified places** (the band is ±0.2%, not
  ±2%; the short leg, `baseRate`, CRE, and the swap-in bonus are gone; the stable count moved).
  Never quote it without checking the code.
- `docs/actionable/BUILD-QUEUE-AND-107.md` is an **append-only archive**: its evidence (traces,
  `file:line`, measurements) is authoritative, its **status markers are not**. Current status lives in
  `docs/actionable/QUEUE.md` and is updated in place. Some of its citations point at `/home/rico`
  paths from a different machine and cannot be opened from here.
