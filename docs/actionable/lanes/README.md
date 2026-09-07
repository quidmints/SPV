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

## ⛔ THE CENSUS: §LANES NAMES 10 OF THE 24 CORE FILES. FOURTEEN ARE OWNED BY NOBODY (2026-09-07)

**`evm/src` is 199 `.sol` files: 24 core, 3 spv, and 172 identity.** The partition names ten.

| unowned core file | importing files | | unowned core file | importing files |
|---|---|---|---|---|
| `imports/Interfaces.sol` | **21** | | `Basket.sol` | 4 |
| `imports/Types.sol` | **20** | | `Shares.sol` | 2 |
| `imports/BasketLib.sol` | 7 | | `imports/BtcLib.sol` | 2 |
| `imports/FeeLib.sol` | 5 | | `Vault.sol` · `VBtc.sol` · `imports/OracleLib.sol` | 1 each |
| `imports/RangeLib.sol` | 5 | | `BtcLevManager.sol` · `imports/LevVenueBase.sol` | 0 |
| `Aux.sol` | 4 | | | |

🔴 **AND TWO OF THEM ARE UNDER ACTIVE WORK AS THIS IS WRITTEN, which is the point of taking the
census rather than assuming the two headers we tripped over were the whole set:**
- **`Aux.sol` (4 importers, no lane)** is the target of §SETTER-FOLD — *"25 deploy-time setter calls
  become one `Aux.configure`"* (`4082b54d`). A fold of that shape is exactly a signature change.
- **`Vault.sol` (no lane)** was uncommitted in the shared tree all afternoon.

⚠️ **`Interfaces.sol`'s 21 importers reach it through 56 separate import statements** — `QuidLib`
alone pulls from it on ten lines. **21 is the blast radius; 56 is the coupling surface.** Both are
real and they answer different questions; the lane question is the file count.

📌 **AND THE 172 IDENTITY FILES ARE OUTSIDE THE PARTITION ENTIRELY** — 86% of the tree, no lane, no
`serialiser` column. That is consistent with the identity fold arriving late (SPRINT.md's handoff
block: 59 suites and ~470 tests *"had never been run in this tree at all"*), but it means **"two
items may run concurrently iff they cannot touch the same file" is currently unanswerable for most
of `evm/src`.** Not a crisis — nothing in §MASTER-ORDER is routing work there — but do not read the
seven-lane table as covering the repo. It covers the money path.

✅ **DON'T TRUST THIS TABLE'S AGE — REGENERATE IT.** `tools/blast-radius.py <file>` answers the
question for one file against the CURRENT tree, parses the lane table above as its single source of
truth, and **exits 1 with a FATAL rather than printing an empty map** if that table stops parsing.

▶️ **One command before you touch any header:** `grep -rl 'imports/<TheFile>' evm/src --include='*.sol'`
— if it names another lane's file, you are serial with that lane. Full note: SPRINT.md §LANES.

**Setup:** `tools/lane.sh L<n>` — worktree + **branch** `lane/L<n>` (not `--detach`: git then refuses
a double checkout, so two lanes cannot share a branch), warm artifacts, `evm/.env`, and the 11 forge
submodules `worktree add` leaves empty. `HEAD` excludes another lane's uncommitted work by construction.
🛤️ **The lane gets no copy of `CLAUDE.md` or `SPRINT.md` — they are symlinks to the parent**, because
37% of commits touch those two and a lane went 26 commits stale in one morning. Nothing to sync.
⚠️ Never `git checkout <branch> -- CLAUDE.md` in a lane: it swaps the symlink for a stale-able copy.

**Stage by name. Never `git add -A`, never `commit -a`** (rule 14, and a hook refuses the bulk flags).
