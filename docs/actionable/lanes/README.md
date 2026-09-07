# Lane books — one file per lane, folded into SPRINT.md at the end of the day

`SPRINT.md` is 52,714 lines and every lane wants to write it. That is the collision that let
`fe9720ac` swallow a 228-line `§MASTER-ORDER` restructuring whose message never mentioned it
(§SESS-17 U6), and it is CLAUDE.md rule 14 arriving through a shared file rather than a shared index.

⇒ **Book your finding in `L<n>.md` in the same turn you find it (rule 12), never in `SPRINT.md`.**
One merge pass folds them. A lane's commit then cannot swallow another lane's work, because no two
lanes stage the same path.

| lane | owns | serialiser |
|---|---|---|
| L1 | `.md` + comment-only edits in `evm/src` | none — no compile |
| L2 | `quid-ln/`, `quid-hop`, `quid-bridge`, `quid-enclave` | separate toolchain |
| L3 | `BTCChannels.sol`, `ChannelLib.sol`, `BitcoinTx.sol` | GATE 3 is one attempt |
| L4 | `LevManager.sol`, `LevMath.sol`, `LevBase.sol` | **227 bytes** — strictly serial, **and serial with L5** ⬇️ |
| L5 | `Quid.sol`, `Core.sol`, `SwapLib.sol`, `QuidLib.sol` | **1,172 bytes** + rule 10 — strictly serial, **and serial with L4** ⬇️ |
| L6 | `evm/test/` only | additive |
| L7 | read-only | none |

## 🔴 THE TABLE IS CUT ON FILES; THE COMPILER IS NOT (2026-09-07)

**Two lanes that stage no common path can still compile a common header, and that break merges CLEAN
and lands in the PARENT.** `imports/LevMath.sol` is L4's, and **three of L5's four files import it**
(`Quid.sol`, `imports/SwapLib.sol`, `imports/QuidLib.sol`) — so L4 and L5 are serial with respect to
each other whatever their `owns` columns say. It already happened: CLAUDE.md §MANY-THREADS books
*"four `LevMath` signatures had changed under me mid-edit"*, **caught by `SendMessage`, not by git**.

⛔ **And the hottest headers are in NOBODY's column:** `Interfaces.sol` (21 importers), `Types.sol`
(20), `BasketLib.sol` (7), `RangeLib.sol` (5), `FeeLib.sol` (5). **Editing one is a parent-tree
action, one author** — they have no lane because they belong to every lane.

▶️ **One command before you touch any header:** `grep -rl 'imports/<TheFile>' evm/src --include='*.sol'`
— if it names another lane's file, you are serial with that lane. Full note: SPRINT.md §LANES.

**Setup:** `tools/lane.sh L<n>` — worktree + **branch** `lane/L<n>` (not `--detach`: git then refuses
a double checkout, so two lanes cannot share a branch), warm artifacts, `evm/.env`, and the 11 forge
submodules `worktree add` leaves empty. `HEAD` excludes another lane's uncommitted work by construction.
🛤️ **The lane gets no copy of `CLAUDE.md` or `SPRINT.md` — they are symlinks to the parent**, because
37% of commits touch those two and a lane went 26 commits stale in one morning. Nothing to sync.
⚠️ Never `git checkout <branch> -- CLAUDE.md` in a lane: it swaps the symlink for a stale-able copy.

**Stage by name. Never `git add -A`, never `commit -a`** (rule 14, and a hook refuses the bulk flags).
