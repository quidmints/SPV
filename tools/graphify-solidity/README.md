# graphify Solidity support (local patch)

graphify builds the code knowledge graph at `graphify-out/graph.json`. As of
**0.9.51 it has no Solidity grammar** — upstream PRs
[#707](https://github.com/Graphify-Labs/graphify/pull/707),
[#1367](https://github.com/Graphify-Labs/graphify/pull/1367) and
[#1874](https://github.com/Graphify-Labs/graphify/pull/1874) have all been open
since May 2026. Unpatched, `graphify update` files all 363 first-party
contracts as bare file nodes: no contracts, no functions, no calls, no
inheritance. This directory is the patch that fixes that.

## Why it lives here and not as a fork

The patch adds **one file** (`solidity.py`) and **six lines** to graphify's own
source. Keeping it that small is deliberate: the whole thing re-applies
mechanically after an upgrade, and `git diff` on the graphify checkout stays
readable. Everything Solidity-specific — the tree-sitter config, foundry
remapping resolution, the inheritance/constructor pass — is inside
`solidity.py`. Nothing in `engine.py` is branched.

## Applying it

```bash
python3 tools/graphify-solidity/apply.py            # install / re-apply
python3 tools/graphify-solidity/apply.py --check    # report only, exit 1 if incomplete
```

Requires `tree-sitter-solidity` in the same environment:

```bash
~/.local/share/graphify-venv/bin/pip install tree-sitter-solidity
```

`apply.py` is idempotent and targets `~/.local/share/graphify-venv` by default;
override with `GRAPHIFY_PYTHON=/path/to/bin/python`.

**Re-run it after every `pip install -U graphifyy`.** An upgrade overwrites the
package and silently reverts the patch, and a graph built from an unpatched
graphify does not look broken — it just has no Solidity in it. `--check` is the
only cheap way to tell the difference; it also verifies the grammar is present.

If `apply.py` exits with `anchor appears 0x, expected 1`, upstream moved the
code the registration keys off. The six registrations are listed in
`REGISTRATIONS` at the top of the script with enough context to re-derive by
hand; that is the intended failure mode — refusing loudly beats patching the
wrong line.

## What it extracts

Driven by `_SOLIDITY_CONFIG` through graphify's shared `_extract_generic` core:

| Solidity | Graph |
|---|---|
| `contract` / `interface` / `library` / `struct` / `enum` | type node, `contains` from file |
| `function` / `modifier` | node, `method` edge from its type |
| `constructor` / `receive` / `fallback` | node (second pass — the grammar gives these no name) |
| `contract A is B` | `inherits` edge (second pass) |
| `import {X} from "./Y.sol"` | `imports_from` at file and symbol level |
| `a.b()` / `f()` | `calls` edge |
| state variables | node |

Two things needed the second pass rather than config: inheritance and the
unnamed special functions. `_extract_generic` gates both behind
`config.ts_module` checks in `engine.py`, so expressing them in a config alone
is impossible. Re-walking the AST costs one extra parse per file (~363 files,
negligible) and keeps `engine.py` untouched — so an upgrade can't silently drop
the behaviour: either it still applies or the import fails loudly.

Import specifiers resolve relatively first, then through the nearest
`remappings.txt`. Paths are made relative to the scan root before minting node
ids — an absolute path there would bake this checkout's location into the graph
and never match the target file's own node.

## Known gaps

- **Bases in `evm/lib` are not in the graph.** `.graphifyignore` excludes forge
  dependencies, so `Basket is ERC20` resolves to a node that does not exist and
  the build drops the edge. **333 of the 481 `is` clauses in the tree survive;
  the 148 that vanish are exactly the vendored bases** (`ERC20`, `Ownable`,
  `Script`, `Test`, `OApp`, …). So a contract's graph neighbourhood shows what
  it inherits *from us* and is silent about what it inherits from OpenZeppelin
  or forge-std — never read "no inherits edge" as "inherits nothing". For the
  vendored half use `evm/slither-out/` (inheritance-graph printer).
- **`using X for Y` is not an edge.** Parsed as a `using_directive`, ignored.
- **Assembly blocks are opaque.** Calls inside `assembly { }` are not extracted.
- **Noir (`.nr`, 128 files in `evm/noir`) is still unsupported** and has no
  upstream PR. Those files are bare nodes.
