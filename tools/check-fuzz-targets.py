#!/usr/bin/env python3
"""Verify every cargo-fuzz target still imports symbols that EXIST.

WHY THIS GATE EXISTS (2026-08-22, §FUZZ-WAS-DEAD). `quid-hop/fuzz` is in the workspace
`exclude = [...]` list — it is a detached nightly + sanitizer crate, deliberately outside
`cargo build` and `cargo test`. That is correct, and it has one consequence nobody planned for:

    A FUZZ TARGET THAT CANNOT COMPILE FAILS NOTHING.

`fuzz_targets/lp_auth.rs` imported `quid_hop::lp_auth::read_lp_auth` for three weeks after §E183
deleted that module. Every `cargo test -p quid-hop` was green throughout, because the crate the
broken file lives in is never built. It was also the ONLY target, so the repo had zero
coverage-guided fuzzing while appearing to have some — worse than none, because it reads as covered.

This gate closes that hole WITHOUT needing nightly or `cargo-fuzz`: it does not compile anything,
it checks that each `use <crate>::<path>` in a fuzz target resolves to a `pub` item that is still
declared in the crate's source. Cheap enough to run on every push, which is the whole point — the
previous target rotted precisely because the only thing that would have caught it needed a toolchain
CI does not install.

⚠️ It is a REFERENCE check, not a compile. It cannot catch a signature change, only a vanished
symbol. That is the failure that actually happened, and a stronger check that never runs is worth
less than a weak one that does.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FUZZ_DIRS = sorted(ROOT.glob("quid-ln/*/fuzz/fuzz_targets"))

# `use quid_hop::liveness::{recover_heartbeat, Heartbeat};` → crate, then the path segments.
USE_RE = re.compile(r"^\s*use\s+([a-z][a-z0-9_]*)\s*::\s*([^;]+);", re.M)


def crate_src(crate_underscored: str) -> Path | None:
    """`quid_hop` → quid-ln/quid-hop/src, if it exists."""
    hyphened = crate_underscored.replace("_", "-")
    p = ROOT / "quid-ln" / hyphened / "src"
    return p if p.is_dir() else None


def declared_symbols(src: Path) -> set[str]:
    """Every `pub` item name plus every module name declared under `src`."""
    out: set[str] = set()
    pub = re.compile(
        r"^\s*pub(?:\s*\([^)]*\))?\s+"
        r"(?:async\s+)?(?:unsafe\s+)?(?:const\s+)?(?:extern\s+\"[^\"]*\"\s+)?"
        r"(?:fn|struct|enum|trait|type|const|static|mod)\s+([A-Za-z_][A-Za-z0-9_]*)",
        re.M,
    )
    for f in src.rglob("*.rs"):
        text = f.read_text(encoding="utf-8", errors="replace")
        out.update(pub.findall(text))
        # a file IS a module: `liveness.rs` declares `liveness`
        out.add(f.stem)
    return out


def main() -> int:
    if not FUZZ_DIRS:
        print("no fuzz_targets directories found")
        return 0
    targets = 0
    missing: list[tuple[str, str, str]] = []
    for d in FUZZ_DIRS:
        for tgt in sorted(d.glob("*.rs")):
            targets += 1
            text = tgt.read_text(encoding="utf-8", errors="replace")
            for crate, rest in USE_RE.findall(text):
                src = crate_src(crate)
                if src is None:
                    continue  # external crate (libfuzzer_sys, alloy_primitives, …)
                have = declared_symbols(src)
                # split `liveness::{recover_heartbeat, Heartbeat}` into every named piece
                names = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", rest)
                for n in names:
                    if n not in have:
                        missing.append((tgt.name, f"{crate}::{n}", str(tgt.relative_to(ROOT))))
    print(f"checked {targets} fuzz target(s) across {len(FUZZ_DIRS)} directory(ies)\n")
    if missing:
        print(f"FUZZ TARGETS REFERENCING SYMBOLS THAT DO NOT EXIST ({len(missing)}):")
        for tgt, sym, where in missing:
            print(f"  {tgt:<20} {sym:<44} {where}")
        print("\nA fuzz crate is workspace-EXCLUDED, so this never fails a build. See §FUZZ-WAS-DEAD.")
        return 1
    print("every fuzz target's imports resolve")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
