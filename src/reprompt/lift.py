"""Offline lifting of recorded Bash commands into a #lang rash module.

Reads the JSON Lines record that RepromptMiddleware appends per intercepted
tool call and emits a Racket/Rash module containing ONLY the Bash commands.
Selection is by tool identity — entry["tool"] == "Bash" — never by the
command string, mirroring how the proxy's meta hook distinguishes Bash
calls. When the proxy rewrote a call, the EXECUTED (rewritten) body decides
both the selection and the emitted command — the module replays what
actually ran, not what was requested. Each lifted command becomes one raw
rash pipeline line, in record order, duplicates preserved.
"""

import json
from typing import Iterable


def lift_record(lines: Iterable[str], source: str) -> str:
    """Turn record.jsonl lines into the text of a #lang rash module.

    Only successful Bash tool calls are lifted: entries whose executed tool
    (the rewritten body's name when a rewrite is recorded, the entry's tool
    otherwise) is not "Bash" are ignored, and entries with a recorded error
    are skipped
    silently (replaying a command that never completed is wrong). A Bash
    entry without a usable command string, or whose command contains a
    newline (unrepresentable as one raw rash line), is skipped with a
    warning comment in the module so the artifact documents the gap. A
    malformed JSON line raises ValueError: the record is reprompt's own
    output, so corruption is a fault, not data to tolerate.
    """
    out = ["#lang rash", f";; lifted by reprompt from {source}"]
    for number, raw in enumerate(lines, start=1):
        line = raw.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"{source}:{number}: invalid JSON: {error}") from error
        if not isinstance(entry, dict):
            continue
        rewrite = entry.get("rewrite")
        if isinstance(rewrite, dict):
            executed = rewrite.get("rewritten_body")
            if not isinstance(executed, dict):
                continue
            name = executed.get("name")
            arguments = executed.get("arguments")
        else:
            name = entry.get("tool")
            arguments = entry.get("arguments")
        if name != "Bash":
            continue
        if entry.get("error") is not None:
            continue
        command = arguments.get("command") if isinstance(arguments, dict) else None
        if not isinstance(command, str) or not command.strip():
            out.append(
                f";; skipped {source}:{number}: Bash call without a command string"
            )
            continue
        if "\n" in command:
            out.append(
                f";; skipped {source}:{number}: multi-line command cannot be "
                "one raw rash line"
            )
            continue
        out.append(command)
    return "\n".join(out) + "\n"


def lift_record_file(record_path: str) -> str:
    """Read record_path and return the lifted module text."""
    with open(record_path, "r", encoding="utf-8") as record_file:
        return lift_record(record_file, record_path)
