"""Filesystem backend plus a Bash tool, for the bash-metadata test.

Extends tests/backend.py by import: same FastMCP server object, same ROOT
(first command-line argument, resolved at backend.py import time), so the
read_file and Write tools are registered unchanged. Bash runs ON THE HOST as
the invoking user with cwd = ROOT; that is acceptable here because the only
client is the egress-locked guest VM driven by fixed prompts at temperature 0,
and ROOT is a throwaway per-run work directory.
"""

import subprocess

from fastmcp.exceptions import ToolError

from backend import ROOT, mcp


@mcp.tool
def Bash(command: str) -> str:
    """Run a shell command in the backend root and return its output."""
    try:
        completed = subprocess.run(
            command, shell=True, cwd=ROOT, capture_output=True, text=True, timeout=60
        )
    except subprocess.TimeoutExpired as error:
        raise ToolError(f"Bash timed out after 60s: {command!r}") from error
    output = completed.stdout
    if completed.stderr:
        output += ("\n" if output else "") + completed.stderr
    if completed.returncode != 0:
        raise ToolError(f"Bash exited {completed.returncode}: {output}")
    return output or "(no output)"


if __name__ == "__main__":
    mcp.run()
