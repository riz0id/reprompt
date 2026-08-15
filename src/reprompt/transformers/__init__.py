"""Default rewrite hook: load and chain every Rash syntax transformer here.

reprompt uses this as its rewrite function whenever a configuration does not
name its own ``rewrite`` hook, so the transformers collected in this package
directory are applied by default. For each Bash tool call, the command is
piped through every ``.rkt`` file in this directory in sorted filename order:
each transformer is invoked as ``racket <transformer>.rkt <command>`` and its
stdout becomes the command handed to the next one.

Total by contract — a raised exception would kill the proxied call, so this
never raises. A missing ``racket``, a transformer that exits non-zero, a
transformer that prints nothing, or an empty collection all leave the command
unchanged. With no ``.rkt`` files present the hook is a pure identity and adds
no behavior.
"""

import os
import subprocess
from typing import Any

Body = dict[str, Any]

_DIR = os.path.dirname(os.path.abspath(__file__))
_RACKET = os.environ.get("REPROMPT_RACKET", "racket")


def _transformer_paths() -> list[str]:
    """Every .rkt transformer in this directory, in sorted filename order."""
    try:
        names = sorted(name for name in os.listdir(_DIR) if name.endswith(".rkt"))
    except OSError:
        return []
    return [os.path.join(_DIR, name) for name in names]


def _apply(transformer: str, command: str) -> str | None:
    """Run one transformer on the command; None if it did not rewrite."""
    try:
        completed = subprocess.run(
            [_RACKET, transformer, command],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    rewritten = completed.stdout.strip()
    return rewritten or None


def rewrite(body: Body) -> Body:
    """Chain every Rash transformer over a Bash command; total, in place."""
    if body.get("name") != "Bash":
        return body
    arguments = body.get("arguments")
    if not isinstance(arguments, dict):
        return body
    command = arguments.get("command")
    if not isinstance(command, str) or not command.strip():
        return body
    for transformer in _transformer_paths():
        rewritten = _apply(transformer, command)
        if rewritten is not None:
            command = rewritten
    arguments["command"] = command
    return body
