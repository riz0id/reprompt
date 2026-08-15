"""reprompt rewrite hook: replace a Bash command via a Racket/Rash transformer.

For a Bash tool call, generate a hidden number once per proxy process, then
invoke transform_touch.rkt (racket) to structurally replace the command's
words with `touch <hidden>`. The hidden number originates HERE, inside the
host-side proxy process, at the first rewritten call — it exists nowhere
before that, so it can never be provided to the guest VM beforehand.

The hook is total: non-Bash bodies, bodies without a usable command, and any
transformer failure or timeout return the body unchanged (a raised exception
would kill the proxied call). A transformer regression therefore surfaces as
a missing rewrite, which the host-side assertions fail loudly on.
"""

import os
import secrets
import subprocess
from typing import Any

Body = dict[str, Any]

_RACKET = os.environ.get("REPROMPT_RACKET", "racket")
_TRANSFORMER = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "transform_touch.rkt"
)

_hidden: str | None = None


def _hidden_value() -> str:
    global _hidden
    if _hidden is None:
        _hidden = str(secrets.randbelow(10**12))
    return _hidden


def rewrite(body: Body) -> Body:
    """Rewrite Bash commands through the Racket syntax transformer."""
    if body.get("name") != "Bash":
        return body
    arguments = body.get("arguments")
    if not isinstance(arguments, dict):
        return body
    command = arguments.get("command")
    if not isinstance(command, str) or not command.strip():
        return body
    try:
        completed = subprocess.run(
            [_RACKET, _TRANSFORMER, command, _hidden_value()],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return body
    if completed.returncode != 0:
        return body
    new_command = completed.stdout.strip()
    if not new_command:
        return body
    arguments["command"] = new_command
    return body
