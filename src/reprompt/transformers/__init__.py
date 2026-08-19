"""Default rewrite hook: load and chain every Rash syntax transformer here.

reprompt uses this as its rewrite function whenever a configuration does not
name its own ``rewrite`` hook, so the transformers collected in this package
directory are applied by default. For each Bash tool call, the *enclosing
call* is rendered as ``Bash(<command>)`` and piped through every ``.rkt``
file in this directory in sorted filename order: each transformer is invoked
as ``racket <transformer>.rkt <call>`` and its stdout becomes the call handed
to the next one. A transformer answers with one call form:

- ``Bash(<command'>)`` — still a shell call; chaining continues with it;
- ``<server>.<tool>(<json-object>)`` — an MCP call; chaining stops (a tool
  call is terminal) and the tool-call body is retargeted onto the backend
  tool, which the proxy middleware routes like any other call. The
  ``<server>`` segment names the configured backend; with a single mounted
  backend the proxy exposes the tool under its bare name, which is what the
  retargeted body uses.

Total by contract — a raised exception would kill the proxied call, so this
never raises. A missing ``racket``, a transformer that exits non-zero, a
transformer that prints nothing or prints an unrecognized call form, or an
empty collection all leave the call unchanged. With no ``.rkt`` files
present the hook is a pure identity and adds no behavior.
"""

import json
import os
import re
import subprocess
from typing import Any

Body = dict[str, Any]

_DIR = os.path.dirname(os.path.abspath(__file__))
_RACKET = os.environ.get("REPROMPT_RACKET", "racket")

_BASH_CALL = re.compile(r"^Bash\((.*)\)$", re.DOTALL)
_MCP_CALL = re.compile(r"^([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\((.*)\)$", re.DOTALL)


def _transformer_paths() -> list[str]:
    """Every .rkt transformer in this directory, in sorted filename order."""
    try:
        names = sorted(name for name in os.listdir(_DIR) if name.endswith(".rkt"))
    except OSError:
        return []
    return [os.path.join(_DIR, name) for name in names]


def _apply(transformer: str, call: str) -> str | None:
    """Run one transformer on the call; None if it did not rewrite."""
    try:
        completed = subprocess.run(
            [_RACKET, transformer, call],
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


def _parse_mcp_call(out: str) -> Body | None:
    """A retargeted body for a <server>.<tool>(<json>) call form, or None."""
    match = _MCP_CALL.match(out)
    if match is None:
        return None
    _server, tool, args_json = match.groups()
    try:
        arguments = json.loads(args_json)
    except ValueError:
        return None
    if not isinstance(arguments, dict):
        return None
    return {"name": tool, "arguments": arguments}


def rewrite(body: Body) -> Body:
    """Chain every Rash transformer over a Bash call; total, in place."""
    if body.get("name") != "Bash":
        return body
    arguments = body.get("arguments")
    if not isinstance(arguments, dict):
        return body
    command = arguments.get("command")
    if not isinstance(command, str) or not command.strip():
        return body

    call = f"Bash({command})"
    for transformer in _transformer_paths():
        out = _apply(transformer, call)
        if out is None:
            continue
        if _BASH_CALL.match(out) is not None:
            call = out
            continue
        retargeted = _parse_mcp_call(out)
        if retargeted is not None:
            return retargeted
        # Unrecognized output: keep the call as it stands.

    inner = _BASH_CALL.match(call)
    if inner is not None:
        arguments["command"] = inner.group(1)
    return body
