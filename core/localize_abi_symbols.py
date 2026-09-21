#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.13,<3.14"
#
# [tool.uv]
# exclude-newer = "2026-09-21T00:00:00Z"
# ///

"""Post-link pass for `zig build abi`.

core/abi.zig transitively @imports every ported module (via
core/game_loop.zig), dragging each module's own pre-existing `export
fn`/`export var` (steer_players, rnd, is_server, player_anims, pogostick,
... -- a cross-module-linkage convention, non-jnb_-prefixed and predating
this ABI) into the same static archive. Zig's `export` keyword always emits
a default-visibility global symbol and there is no way to make one
file-local from inside Zig itself, so this demotes every defined global
symbol not matching the frozen jnb_ ABI surface to local. neo_snake never
needed an equivalent step: its own core/ modules never use bare `export fn`
outside abi.zig.

The archive has two members: abi.o (abi.zig plus everything it @imports)
and abi_globals.o (core/abi_globals.zig's real player_raw/objects_raw/
ban_map_raw/keyb/no_gore storage, kept as its own object rather than
@imported directly -- see that file's header comment). abi.o references
several of abi_globals.o's symbols (keyb, etc.) as `extern`, resolved only
when a later consumer links this archive -- .a members are never linked
against each other, just stored side by side. If symbols were demoted to
local per member (the original approach here), abi_globals.o's globals
would already be local by the time any consumer links against them, and a
local symbol in one object can never satisfy an extern reference from a
different object, archive or not (this hit us for real as a genuine
"undefined symbol: keyb" failure loading the GDExtension .so, even with
--whole-archive forcing both members into the link). So this merges every
member into one relocatable object first (ld -r), which resolves those
inter-member references immediately, then localizes the merged object's
remaining global symbols, then re-archives it as the single-member .a
`zig build abi`'s consumers already expect.

Zig's own archiver names each member by its full relative build-cache path
(e.g. ".zig-cache/o/<hash>/abi_globals.o"), not a flat basename. `ar x` in a
flat temp dir tries to recreate that path literally and fails with "No such
file or directory" on GNU ar (Linux) -- it never creates the member's
parent directory itself. Extracting by name instead (`ar p <archive>
<member>`) isn't a working alternative: GNU ar's long-member-name lookup
doesn't resolve names past its extended-name-table encoding, so `ar p`
silently reports "no entry ... in archive" (exit 0, empty output) for
these exact same long names `ar t` just listed. So this pre-creates every
member's parent directory from `ar t`'s listing, then lets a plain `ar x`
(whole archive, no name arg -- the one extraction mode that actually works
here) populate them, then locates the extracted objects by glob rather
than assuming a flat basename.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def find_objcopy() -> str:
    for candidate in ("objcopy", "llvm-objcopy", "gobjcopy"):
        if shutil.which(candidate):
            return candidate
    # GNU objcopy isn't part of Xcode/Command Line Tools on macOS (only
    # clang/lld's own toolchain), so on that platform this needs LLVM's
    # objcopy (`brew install llvm`, keg-only so not on PATH by default) or
    # Homebrew's GNU binutils (`brew install binutils`, whose `gobjcopy` is
    # unprefixed to avoid clashing with the system's own `as`/`ld`). Both
    # accept the same --keep-global-symbols flag GNU objcopy does.
    if shutil.which("brew"):
        llvm_prefix = subprocess.run(
            ["brew", "--prefix", "llvm"], capture_output=True, text=True
        ).stdout.strip()
        candidate_path = Path(llvm_prefix) / "bin" / "llvm-objcopy" if llvm_prefix else None
        if candidate_path and os.access(candidate_path, os.X_OK):
            return str(candidate_path)
    print(
        "error: no objcopy-compatible tool found (objcopy, llvm-objcopy, or gobjcopy).\n"
        "       on macOS: brew install llvm (or binutils), then retry.",
        file=sys.stderr,
    )
    sys.exit(1)


def generate_symbols(script_dir: Path, header: str) -> str:
    generate_script = script_dir / ".." / "tools" / "generate_abi_symbols.py"
    names = subprocess.run(
        [sys.executable, str(generate_script), header],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    # Mach-O symbol tables store C symbols with a leading underscore (the
    # platform's own name-mangling convention, e.g. `_jnb_step`), while
    # ELF's do not. --keep-global-symbols matches literal symbol-table
    # names, so on Darwin the generated jnb_* names need that underscore
    # prepended or every entry silently fails to match -- objcopy then
    # falls back to its default (no symbols preserved) and localizes the
    # jnb_ ABI surface right along with everything else. This bit us for
    # real: a macOS GDExtension link failed with every jnb_* symbol
    # "undefined", not just non-ABI ones.
    if sys.platform == "darwin":
        names = "".join(f"_{line}\n" for line in names.splitlines())
    return names


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <archive> <header>", file=sys.stderr)
        return 1
    archive, header = sys.argv[1], sys.argv[2]

    script_dir = Path(__file__).resolve().parent
    archive_abspath = Path(archive).resolve()
    objcopy = find_objcopy()

    # tempfile's default location (/tmp) isn't guaranteed writable/
    # executable in every sandbox this runs in; a sibling of the archive
    # itself always is (it was just written there).
    with tempfile.TemporaryDirectory(dir=archive_abspath.parent) as workdir_str:
        workdir = Path(workdir_str)

        symbols_file = workdir / "symbols.txt"
        symbols_file.write_text(generate_symbols(script_dir, header))

        members = subprocess.run(
            ["ar", "t", str(archive_abspath)], capture_output=True, text=True, check=True
        ).stdout.splitlines()
        for member in members:
            member = member.strip()
            if member:
                (workdir / member).parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["ar", "x", str(archive_abspath)], cwd=workdir, check=True)
        object_paths = sorted(workdir.rglob("*.o"))
        # Zig's own archiver stores members with mode 000 (readable via
        # `ar x` itself, since ar doesn't apply the stored mode to its own
        # reads, but not via any other tool touching the extracted files
        # directly).
        for path in object_paths:
            path.chmod(0o600)

        merged = workdir / "merged.o"
        subprocess.run(["ld", "-r", *map(str, object_paths), "-o", str(merged)], check=True)
        subprocess.run([objcopy, f"--keep-global-symbols={symbols_file}", str(merged)], check=True)

        archive_abspath.unlink()
        subprocess.run(["ar", "rcs", str(archive_abspath), "merged.o"], cwd=workdir, check=True)

    return 0


if __name__ == "__main__":
    sys.exit(main())
