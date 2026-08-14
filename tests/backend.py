"""Minimal FastMCP filesystem backend for the integration test.

Runs on the host as a stdio child of the reprompt proxy. The root directory
is the first command-line argument (MCP clients spawn stdio children with a
sanitized environment, so an environment variable would not survive); the
server refuses every path that resolves outside that root.
"""

import sys
from pathlib import Path

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/agent/work").resolve()

mcp = FastMCP("filesystem")


def _resolve(path: str) -> Path:
    """Resolve a path against ROOT; refuse anything outside ROOT."""
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = ROOT / candidate
    resolved = candidate.resolve()
    if not (resolved == ROOT or resolved.is_relative_to(ROOT)):
        raise ToolError(f"refused: {path!r} is outside the root {ROOT}")
    return resolved


@mcp.tool
def read_file(path: str) -> str:
    """Read a text file inside the backend root."""
    target = _resolve(path)
    try:
        return target.read_text()
    except OSError as error:
        raise ToolError(f"read_file failed: {error}") from error


@mcp.tool
def Write(path: str, content: str) -> str:
    """Write a text file inside the backend root."""
    target = _resolve(path)
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    except OSError as error:
        raise ToolError(f"Write failed: {error}") from error
    return f"wrote {len(content)} characters to {target}"


if __name__ == "__main__":
    mcp.run()
