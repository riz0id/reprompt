"""reprompt meta hook: attach a random number to each MCP tool response.

The number is generated in memory on the first intercepted call and stays the
same for the lifetime of the proxy process. It is never written to a file.
reprompt puts the returned mapping in the _meta field of the MCP tool
response, so the model receives the number only through that response. The
hook prints the number to stderr once; journald captures it, which gives the
test driver its ground truth.
"""

import secrets
import sys
from typing import Any

Body = dict[str, Any]

_number: str | None = None


def attach_meta(body: Body) -> dict[str, Any]:
    """Return {"number": N} for the tool result _meta; N is stable per run."""
    global _number
    del body  # The metadata does not depend on the call.
    if _number is None:
        _number = str(secrets.randbelow(10**12))
        print("reprompt random number: " + _number, file=sys.stderr, flush=True)
    return {"number": _number}
