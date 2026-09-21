#!/usr/bin/env python3
"""Extract the frozen jnb_* symbol names from include/jumpnbump.h.

Used by core/localize_abi_symbols.py's post-link objcopy
--keep-global-symbols pass (TASK-012.02): every name this prints is kept
global in the built static library; everything else gets localized. Strips
C block/line comments first so a name mentioned only in prose never leaks
into the keep-list, then matches identifiers of the form `jnb_[A-Za-z0-9_]+`
immediately followed by `(` -- the header's own function-declaration syntax.
"""

import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: generate_abi_symbols.py <path-to-jumpnbump.h>", file=sys.stderr)
        return 1

    text = open(sys.argv[1], encoding="utf-8").read()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    text = re.sub(r"//.*", "", text)

    names = sorted(set(re.findall(r"\b(jnb_[A-Za-z0-9_]+)\s*\(", text)))
    for name in names:
        print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
