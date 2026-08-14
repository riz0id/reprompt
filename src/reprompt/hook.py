"""Load of the user rewrite function; rewrite records."""

import importlib
import os
import sys
from typing import Any, Callable

Body = dict[str, Any]
RewriteFn = Callable[[Body], Body]
# A metadata hook reads the tool-call body and returns the metadata to attach
# to the tool result (the JSON-RPC _meta field), or None to attach nothing.
MetaFn = Callable[[Body], dict[str, Any] | None]


def load_hook_function(spec: str) -> Callable[[Body], Any]:
    """Import the user hook function named as 'module:function'."""
    module_name, _, function_name = spec.partition(":")
    if not module_name or not function_name:
        raise ValueError(f"invalid rewrite spec {spec!r}: expected 'module:function'")

    # Let users keep their rewrite module next to the configuration file.
    cwd = os.getcwd()
    if cwd not in sys.path:
        sys.path.insert(0, cwd)

    module = importlib.import_module(module_name)
    try:
        function = getattr(module, function_name)
    except AttributeError:
        raise ValueError(
            f"module {module_name!r} has no attribute {function_name!r}"
        ) from None
    if not callable(function):
        raise ValueError(f"{spec!r} is not callable")
    return function


def make_rewrite_record(original_body: Body, rewritten_body: Body) -> dict[str, Any]:
    """Build the record that describes one rewrite."""
    return {
        "tool": original_body["name"],
        "original_body": original_body,
        "rewritten_body": rewritten_body,
    }
