"""reprompt meta hook: tag Bash calls, and only Bash calls.

Matches solely on the tool name in the intercepted body — deliberately never
on the command string — so every Bash invocation gets the tag and no other
tool ever does. reprompt records the returned mapping (or null) per call in
record.jsonl, which is what the host-side assertions read after the VM
closes.
"""

from typing import Any

Body = dict[str, Any]


def attach_meta(body: Body) -> dict[str, Any] | None:
    """Return {"tag": "BashCommand"} for Bash tool calls, None otherwise."""
    if body.get("name") == "Bash":
        return {"tag": "BashCommand"}
    return None
