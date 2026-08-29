"""Solidity extractor.

LOCAL PATCH — not upstream. Graphify has no Solidity grammar as of 0.9.51
(upstream PRs #707, #1367, #1874 all open since May 2026). This module adds
one, deliberately self-contained so it survives `pip install -U graphifyy`
with only the four one-line registrations to re-apply. See SOLIDITY-PATCH.md.

Contracts / interfaces / libraries, their functions, state variables, imports
and calls come from the shared ``_extract_generic`` core via ``_SOLIDITY_CONFIG``.
Two things that core keys off ``config.ts_module`` and so cannot express in a
config alone -- inheritance edges and unnamed ``constructor``/``receive``/
``fallback`` definitions -- are added by a second pass over the same AST rather
than by branching ``engine.py``. That keeps the whole language in one file.
"""
from __future__ import annotations

import importlib
import os
from pathlib import Path

from graphify.extractors.base import _file_stem, _make_id, _read_text
from graphify.extractors.engine import _extract_generic
from graphify.extractors.models import LanguageConfig

# Top-level declarations a Solidity file can export to an importer.
_SOLIDITY_DECLARATIONS = frozenset({
    "contract_declaration", "interface_declaration", "library_declaration",
    "struct_declaration", "enum_declaration", "error_declaration",
    "user_defined_type_definition", "event_definition",
})

_SOLIDITY_TYPE_DECLARATIONS = frozenset({
    "contract_declaration", "interface_declaration", "library_declaration",
})

# Cache: resolved .sol path -> its top-level declaration names. A bare
# `import "./X.sol"` names no symbols, so resolving an inherited base through
# it means reading X.sol. Corpora re-import the same handful of files from
# every contract, so this is parsed once per file per process.
_SOLIDITY_EXPORTS_CACHE: dict[str, frozenset[str]] = {}

# Cache: directory -> foundry remappings, longest prefix first.
_SOLIDITY_REMAPPINGS_CACHE: dict[str, tuple[tuple[str, str], ...]] = {}


def _solidity_parser():
    """Parser for tree-sitter-solidity, or None when the grammar is absent."""
    try:
        mod = importlib.import_module("tree_sitter_solidity")
        from tree_sitter import Language, Parser
        return Parser(Language(mod.language()))
    except Exception:
        return None


def _solidity_remappings(start: Path) -> tuple[tuple[str, str], ...]:
    """Foundry ``remappings.txt`` entries visible from *start*, longest first.

    Walks up to the nearest remappings.txt (foundry keeps it beside
    foundry.toml at the project root). Entries are ``prefix=target`` and are
    sorted longest-prefix-first so `@openzeppelin/contracts-upgradeable/`
    wins over `@openzeppelin/`.
    """
    key = str(start)
    if key in _SOLIDITY_REMAPPINGS_CACHE:
        return _SOLIDITY_REMAPPINGS_CACHE[key]
    entries: list[tuple[str, str]] = []
    root = start if start.is_dir() else start.parent
    for parent in [root, *root.parents]:
        candidate = parent / "remappings.txt"
        if candidate.is_file():
            try:
                for raw_line in candidate.read_text(
                    encoding="utf-8", errors="replace"
                ).splitlines():
                    line = raw_line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    prefix, _, target = line.partition("=")
                    prefix, target = prefix.strip(), target.strip()
                    if prefix and target:
                        entries.append((prefix, str(parent / target)))
            except OSError:
                pass
            break
    entries.sort(key=lambda kv: len(kv[0]), reverse=True)
    result = tuple(entries)
    _SOLIDITY_REMAPPINGS_CACHE[key] = result
    return result


def _resolve_solidity_import(raw: str, str_path: str) -> Path | None:
    """Resolve a Solidity import string to an on-disk .sol file, or None.

    Relative specifiers resolve against the importing file's directory;
    everything else is tried against foundry remappings. A specifier that
    resolves outside the indexed corpus (a forge dep under evm/lib) simply
    fails to hit an existing file here and returns None -- the caller then
    mints an unresolved ``ref`` target, which is the honest answer.
    """
    if not raw:
        return None
    here = Path(str_path).parent
    if raw.startswith("."):
        candidate = Path(os.path.normpath(here / raw))
        return candidate if candidate.is_file() else None
    for prefix, target in _solidity_remappings(Path(str_path)):
        if raw.startswith(prefix):
            candidate = Path(os.path.normpath(Path(target) / raw[len(prefix):]))
            if candidate.is_file():
                return candidate
    return None


def _corpus_relative(path: Path) -> Path | None:
    """*path* relative to the scan root, or None if it falls outside it.

    graphify hands extractors absolute paths during a real run and re-derives
    repo-relative ids afterwards from ``source_file`` -- a post-pass that only
    rewrites the ids it minted itself, not the import/inheritance targets
    synthesized here. Without this, a base contract resolved through a foundry
    remapping mints an id carrying the checkout location
    (``home_..._evm_lib_forge_std_..._script``), which is machine-specific and
    can never match the node the target file would produce. Anything outside
    the scan root is a genuine external and gets a ``ref`` id instead.
    """
    try:
        relative = Path(os.path.relpath(path, Path.cwd()))
    except ValueError:  # different drive on Windows
        return None
    return None if relative.parts and relative.parts[0] == os.pardir else relative


def _solidity_exports(path: Path) -> frozenset[str]:
    """Top-level declaration names *path* makes available to an importer."""
    key = str(path)
    cached = _SOLIDITY_EXPORTS_CACHE.get(key)
    if cached is not None:
        return cached
    names: set[str] = set()
    parser = _solidity_parser()
    if parser is not None:
        try:
            source = path.read_bytes()
            for node in parser.parse(source).root_node.children:
                if node.type in _SOLIDITY_DECLARATIONS:
                    name_node = node.child_by_field_name("name")
                    if name_node is not None:
                        names.add(_read_text(name_node, source))
        except (OSError, ValueError):
            pass
    result = frozenset(names)
    _SOLIDITY_EXPORTS_CACHE[key] = result
    return result


def _import_solidity(node, source: bytes, file_nid: str, stem: str, edges: list,
                     str_path: str, scope_stack: list[str] | None = None) -> None:
    """Emit file->file and file->symbol edges for one ``import_directive``.

    Handles all three Solidity import forms::

        import "./Types.sol";
        import {Types, BtcVaultPinned} from "./imports/Types.sol";
        import * as Types from "./Types.sol";
    """
    source_node = node.child_by_field_name("source")
    if source_node is None:
        source_node = next((c for c in node.children if c.type == "string"), None)
    if source_node is None:
        return
    raw = _read_text(source_node, source).strip("'\" ")
    if not raw:
        return

    line = node.start_point[0] + 1
    resolved = _resolve_solidity_import(raw, str_path)
    relative = _corpus_relative(resolved) if resolved is not None else None
    target_nid = (_make_id(str(relative)) if relative is not None
                  else _make_id("ref", raw))

    edge = {
        "source": file_nid,
        "target": target_nid,
        "relation": "imports_from",
        "context": "import",
        "confidence": "EXTRACTED",
        "source_file": str_path,
        "source_location": f"L{line}",
        "weight": 1.0,
    }
    if relative is not None:
        edge["target_file"] = str(relative)
    edges.append(edge)

    # Symbol-level edges. `import_name` is repeated once per named symbol;
    # they wire the importer straight onto the node _extract_generic minted
    # for the declaration in the target file.
    if relative is None:
        return
    target_stem = _file_stem(relative)
    for index in range(node.child_count):
        if node.field_name_for_child(index) != "import_name":
            continue
        symbol = _read_text(node.child(index), source)
        if not symbol:
            continue
        edges.append({
            "source": file_nid,
            "target": _make_id(target_stem, symbol),
            "relation": "imports_from",
            "context": "import symbol",
            "confidence": "EXTRACTED",
            "source_file": str_path,
            "source_location": f"L{line}",
            "target_file": str(relative),
            "weight": 1.0,
        })


_SOLIDITY_CONFIG = LanguageConfig(
    ts_module="tree_sitter_solidity",
    # A library is a type in every sense that matters to the graph (it holds
    # functions and is inherited-from via `using X for Y`), so it joins
    # contracts and interfaces rather than being flattened into the file.
    class_types=frozenset({
        "contract_declaration", "interface_declaration", "library_declaration",
        "struct_declaration", "enum_declaration",
    }),
    # constructor/receive/fallback carry no `name` field in this grammar and
    # are added by _solidity_second_pass instead.
    function_types=frozenset({"function_definition", "modifier_definition"}),
    import_types=frozenset({"import_directive"}),
    call_types=frozenset({"call_expression"}),
    call_function_field="function",
    call_accessor_node_types=frozenset({"member_expression"}),
    call_accessor_field="property",
    call_accessor_object_field="object",
    function_boundary_types=frozenset({
        "function_definition", "modifier_definition",
        "constructor_definition", "fallback_receive_definition",
    }),
    import_handler=_import_solidity,
)


def _solidity_second_pass(path: Path, result: dict) -> None:
    """Add inheritance edges and unnamed special functions to *result*.

    ``_extract_generic`` gates both behind ``config.ts_module`` checks in
    engine.py. Re-walking the AST here costs one extra parse per file and
    leaves engine.py untouched, so an upstream upgrade cannot silently drop
    this behaviour -- it either still applies or the import fails loudly.
    """
    parser = _solidity_parser()
    if parser is None:
        return
    try:
        source = path.read_bytes()
    except OSError:
        return
    tree = parser.parse(source)
    stem = _file_stem(path)
    str_path = str(path)
    nodes: list = result.setdefault("nodes", [])
    edges: list = result.setdefault("edges", [])
    known_ids = {n["id"] for n in nodes}

    # Names this file can resolve a base contract against: its own top-level
    # declarations, plus everything it imports.
    local_names = {
        _read_text(n.child_by_field_name("name"), source)
        for n in tree.root_node.children
        if n.type in _SOLIDITY_DECLARATIONS and n.child_by_field_name("name") is not None
    }
    imported: dict[str, Path] = {}
    wildcard: list[Path] = []
    for node in tree.root_node.children:
        if node.type != "import_directive":
            continue
        source_node = node.child_by_field_name("source")
        if source_node is None:
            continue
        target = _resolve_solidity_import(
            _read_text(source_node, source).strip("'\" "), str_path
        )
        if target is None:
            continue
        named = [
            _read_text(node.child(i), source)
            for i in range(node.child_count)
            if node.field_name_for_child(i) == "import_name"
        ]
        if named:
            for symbol in named:
                imported.setdefault(symbol, target)
        else:
            wildcard.append(target)

    def resolve_base(name: str) -> str:
        """Node id for an inherited base, preferring an in-corpus definition."""
        if name in local_names:
            return _make_id(stem, name)
        target = imported.get(name)
        if target is None:
            for candidate in wildcard:
                if name in _solidity_exports(candidate):
                    target = candidate
                    break
        if target is not None:
            relative = _corpus_relative(target)
            if relative is not None:
                return _make_id(_file_stem(relative), name)
        return _make_id("ref", name)

    def add_node(nid: str, label: str, line: int, node_type: str) -> None:
        if nid in known_ids:
            return
        known_ids.add(nid)
        nodes.append({
            "id": nid,
            "label": label,
            "type": node_type,
            "file_type": "code",
            "source_file": str_path,
            "source_location": f"L{line}",
        })

    def add_edge(src: str, tgt: str, relation: str, line: int) -> None:
        edges.append({
            "source": src,
            "target": tgt,
            "relation": relation,
            "confidence": "EXTRACTED",
            "source_file": str_path,
            "source_location": f"L{line}",
            "weight": 1.0,
        })

    stack = [(child, None) for child in tree.root_node.children]
    while stack:
        node, enclosing = stack.pop()
        next_enclosing = enclosing

        if node.type in _SOLIDITY_TYPE_DECLARATIONS:
            name_node = node.child_by_field_name("name")
            if name_node is not None:
                contract_name = _read_text(name_node, source)
                contract_nid = _make_id(stem, contract_name)
                next_enclosing = contract_nid
                line = node.start_point[0] + 1
                # `contract A is B, C` -- one inheritance_specifier per base.
                for descendant in node.children:
                    if descendant.type != "inheritance_specifier":
                        continue
                    ancestor = descendant.child_by_field_name("ancestor")
                    if ancestor is None:
                        continue
                    base = _read_text(ancestor, source).split(".")[-1].strip()
                    if base:
                        add_edge(contract_nid, resolve_base(base),
                                 "inherits", descendant.start_point[0] + 1)

        elif node.type in ("constructor_definition", "fallback_receive_definition"):
            # `constructor`, `receive() external payable`, `fallback()`. The
            # grammar gives these no name field, so label them by keyword.
            text = source[node.start_byte:node.end_byte].decode("utf-8", "replace")
            keyword = text.split("(")[0].split("{")[0].strip() or "constructor"
            keyword = keyword.split()[0] if keyword.split() else "constructor"
            line = node.start_point[0] + 1
            nid = _make_id(enclosing or stem, keyword)
            add_node(nid, f"{keyword}()", line, "function")
            add_edge(enclosing or _make_id(stem), nid, "contains", line)

        for child in node.children:
            stack.append((child, next_enclosing))


def extract_solidity(path: Path) -> dict:
    """Extract nodes and edges for one ``.sol`` file."""
    result = _extract_generic(path, _SOLIDITY_CONFIG)
    if not result.get("error"):
        _solidity_second_pass(path, result)
    return result
