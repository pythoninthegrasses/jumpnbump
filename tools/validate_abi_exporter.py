#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.13,<3.14"
# ///

"""
Fails if any core/*.zig file other than core/abi.zig defines a jnb_-prefixed
export (TASK-012.02): include/jumpnbump.h's frozen ABI surface must have
exactly one exporter.

This is scoped to the jnb_ prefix rather than a blanket "no export fn outside
abi.zig" -- unlike neo_snake, whose core/ never uses `export fn` outside its
own abi.zig, jumpnbump's Phase 3 ported modules (core/steer.zig,
core/cpu_move.zig, core/objects.zig, core/flies.zig, core/collision.zig,
core/game_loop.zig, core/rnd.zig) legitimately `export fn`/`export var` their
own C-named symbols (steer_players, rnd, is_server, player_anims, ...) for
cross-module linkage under the no-@import-between-ported-modules rule
(docs/porting-playbook.md) and for the Tier-B differential harness --
predating this ABI and required for it to keep working. A literal "any
export fn" ban would immediately fail against that entirely legitimate,
already-shipped code. The real invariant -- that only abi.zig's build output
exposes the jnb_ symbol surface -- is enforced independently and more
strongly by core/localize_abi_symbols.py's post-link `nm -g` gate, which
catches every symbol regardless of source file; this script instead exists
so a future contributor who mistakenly adds a jnb_-named export somewhere
else in core/ gets a fast, source-level failure without waiting on a build.

core/abi_globals.zig is exempt: its `export var player_raw`/etc. back the
pre-existing (non-jnb_) extern-var surface those Phase 3 modules already
declare (see its own header comment for why it can't live inside abi.zig),
not the jnb_ ABI.
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CORE_DIR = REPO_ROOT / "core"

EXEMPT_FILES = {"abi.zig", "abi_globals.zig"}
EXEMPT_SUFFIXES = ("_difftest.zig",)
EXEMPT_PREFIXES = ("unit_",)

EXPORT_JNB_RE = re.compile(r"\bexport\s+(?:fn|var)\s+(jnb_[A-Za-z0-9_]*)\b")


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    text = re.sub(r"//.*", "", text)
    return text


def scan(path: Path) -> list[str]:
    text = strip_comments(path.read_text(encoding="utf-8"))
    return [m.group(1) for m in EXPORT_JNB_RE.finditer(text)]


def main() -> int:
    violations: dict[str, list[str]] = {}
    for path in sorted(CORE_DIR.glob("*.zig")):
        if path.name in EXEMPT_FILES:
            continue
        if path.name.endswith(EXEMPT_SUFFIXES) or path.name.startswith(EXEMPT_PREFIXES):
            continue
        names = scan(path)
        if names:
            violations[str(path.relative_to(REPO_ROOT))] = names

    if violations:
        print("jnb_-prefixed exports found outside core/abi.zig:", file=sys.stderr)
        for path, names in violations.items():
            for name in names:
                print(f"  {path}: export {name}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
