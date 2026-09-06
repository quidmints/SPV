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
| L4 | `LevManager.sol`, `LevMath.sol`, `LevBase.sol` | **227 bytes** — strictly serial |
| L5 | `Quid.sol`, `Core.sol`, `SwapLib.sol`, `QuidLib.sol` | **1,172 bytes** + rule 10 — strictly serial |
| L6 | `evm/test/` only | additive |
| L7 | read-only | none |

**Setup:** `git worktree add --detach ../spv-L<n> HEAD` then `cp evm/.env ../spv-L<n>/evm/.env`
(gitignored, does not travel). `HEAD` excludes another lane's uncommitted work by construction.

**Stage by name. Never `git add -A`, never `commit -a`** (rule 14, and a hook refuses the bulk flags).
