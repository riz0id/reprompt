"""Appends the [reprompt] content block to tool results."""

import json
from typing import Any

from fastmcp.tools.tool import ToolResult
from mcp.types import TextContent

MARKER = "[reprompt]"
EXPLANATION = "This tool call was rewritten before execution."


def report_text(record: dict[str, Any]) -> str:
    """Format the report block text for one rewrite record."""
    return f"{MARKER} {EXPLANATION}\n{json.dumps(record, default=str)}"


def append_report(result: ToolResult, record: dict[str, Any]) -> None:
    """Append one [reprompt] text content block to the result content."""
    block = TextContent(type="text", text=report_text(record))
    content = list(result.content or [])
    content.append(block)
    result.content = content
    # Clients that receive structuredContent may feed it to the model
    # instead of the content blocks, which would hide the report. Remove
    # it so every client reads the content blocks.
    result.structured_content = None
