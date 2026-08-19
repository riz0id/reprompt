"""Hermetic check of the default rewrite hook's call-envelope protocol.

Drives ``reprompt.transformers.rewrite`` on tool-call bodies and asserts
the three behaviors of the Bash(...) protocol: a grep command is
rewritten in place through the transformer chain, an in-domain rg
file-discovery call is retargeted onto the filesystem MCP server's
search_files tool, and everything outside the mappings' domains passes
through unchanged. Needs ``racket`` (REPROMPT_RACKET or PATH) and
``reprompt`` importable (PYTHONPATH); no network, no server.
"""

import sys
from typing import Any

from reprompt.transformers import rewrite

Body = dict[str, Any]


def check(label: str, body: Body, expect: Body) -> bool:
    out = rewrite(body)
    passed = out == expect
    print(("PASS " if passed else "FAIL ") + label)
    if not passed:
        print(f"  expected: {expect!r}")
        print(f"  got:      {out!r}")
    return passed


def main() -> int:
    ok = True
    ok &= check(
        "rg file discovery retargets to filesystem.search_files",
        {
            "name": "Bash",
            "arguments": {"command": "rg --files --hidden --no-ignore -g *.c src/"},
        },
        {"name": "search_files", "arguments": {"path": "src/", "pattern": "*.c"}},
    )
    ok &= check(
        "grep chains to rg and stays Bash",
        {"name": "Bash", "arguments": {"command": "grep -rn foo src/"}},
        {
            "name": "Bash",
            "arguments": {"command": "rg --line-number --hidden --no-ignore foo src/"},
        },
    )
    ok &= check(
        "rg content search is untouched",
        {"name": "Bash", "arguments": {"command": "rg foo file.txt"}},
        {"name": "Bash", "arguments": {"command": "rg foo file.txt"}},
    )
    ok &= check(
        "out-of-domain grep is untouched",
        {"name": "Bash", "arguments": {"command": "grep -z foo f"}},
        {"name": "Bash", "arguments": {"command": "grep -z foo f"}},
    )
    ok &= check(
        "non-Bash calls are untouched",
        {"name": "Write", "arguments": {"path": "x", "content": "y"}},
        {"name": "Write", "arguments": {"path": "x", "content": "y"}},
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
