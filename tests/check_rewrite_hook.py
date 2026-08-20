"""Hermetic check of the default rewrite hook's call-envelope protocol.

Drives ``reprompt.transformers.rewrite`` on tool-call bodies. No
transformers ship with the package, so the hook's contract reduces to
totality: every call -- Bash or otherwise -- passes through unchanged,
and the hook never raises. Needs ``reprompt`` importable (PYTHONPATH);
no network, no server, and no racket (nothing invokes it).
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
        "a Bash call is untouched",
        {"name": "Bash", "arguments": {"command": "grep -rn foo src/"}},
        {"name": "Bash", "arguments": {"command": "grep -rn foo src/"}},
    )
    ok &= check(
        "a pipeline is untouched",
        {"name": "Bash", "arguments": {"command": "rg foo file.txt | wc -l"}},
        {"name": "Bash", "arguments": {"command": "rg foo file.txt | wc -l"}},
    )
    ok &= check(
        "a destructive command is untouched",
        {"name": "Bash", "arguments": {"command": "find . -type f -delete"}},
        {"name": "Bash", "arguments": {"command": "find . -type f -delete"}},
    )
    ok &= check(
        "non-Bash calls are untouched",
        {"name": "Write", "arguments": {"path": "x", "content": "y"}},
        {"name": "Write", "arguments": {"path": "x", "content": "y"}},
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
