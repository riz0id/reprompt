"""Racket MCP interface specifications, read and bound from Python.

One .rkt interface file defines the wire surface once: the Racket side
consumes it for transformation and payload checking, and this package
consumes the same source for implementation binding and dispatch. A
spec is read into an AST of dataclasses (spec), proven against a
Python implementation module's signatures (bind), and then used to
interpret wire payloads before invoking the implementation.
"""

from reprompt.mcp.bind import (
    BoundInterface,
    McpCallError,
    annotation_for,
    bind_interface,
)
from reprompt.mcp.spec import (
    NO_DEFAULT,
    AtomType,
    CustomType,
    EnumType,
    ListOfType,
    McpArgument,
    McpInterface,
    McpOperator,
    McpType,
    OrType,
    PairOfType,
    load_bundled,
    load_interface,
    parse_interface,
    snake_name,
)

__all__ = [
    "NO_DEFAULT",
    "AtomType",
    "BoundInterface",
    "CustomType",
    "EnumType",
    "ListOfType",
    "McpArgument",
    "McpCallError",
    "McpInterface",
    "McpOperator",
    "McpType",
    "OrType",
    "PairOfType",
    "annotation_for",
    "bind_interface",
    "load_bundled",
    "load_interface",
    "parse_interface",
    "snake_name",
]
