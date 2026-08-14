"""RepromptMiddleware: intercepts each tools/call in the proxy pipeline."""

import copy
import json
from typing import Any

import mcp.types as mt
from fastmcp.exceptions import ToolError
from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from fastmcp.tools.tool import ToolResult

from reprompt.hook import Body, MetaFn, RewriteFn, make_rewrite_record
from reprompt.report import append_report, report_text


class RepromptMiddleware(Middleware):
    """Intercept each tools/call: rewrite, attach metadata, report, record."""

    def __init__(
        self,
        rewrite: RewriteFn,
        meta_fn: MetaFn | None = None,
        record_path: str | None = None,
    ):
        self._rewrite = rewrite
        self._meta_fn = meta_fn
        self._record_path = record_path

    async def on_call_tool(
        self,
        context: MiddlewareContext[mt.CallToolRequestParams],
        call_next: CallNext[mt.CallToolRequestParams, ToolResult],
    ) -> ToolResult:
        original_body: Body = {
            "name": context.message.name,
            "arguments": copy.deepcopy(context.message.arguments) or {},
        }
        rewritten_body = _validated(self._rewrite(copy.deepcopy(original_body)))

        record: dict[str, Any] | None = None
        if rewritten_body != original_body:
            record = make_rewrite_record(original_body, rewritten_body)
            context.message.name = rewritten_body["name"]
            context.message.arguments = rewritten_body["arguments"]

        try:
            result = await call_next(context)
        except ToolError as error:
            self._record_call(original_body, record, None, None, str(error))
            if record is None:
                raise
            # A backend error result (isError: true) surfaces here as a
            # ToolError. FastMCP turns the message into the single content
            # block of the error result, so the report must travel inside
            # the message to stay in-band.
            raise ToolError(f"{error}\n\n{report_text(record)}") from error

        if record is not None:
            append_report(result, record)

        meta: dict[str, Any] | None = None
        if self._meta_fn is not None:
            meta = self._meta_fn(copy.deepcopy(original_body))
            if meta:
                merged = dict(result.meta or {})
                merged.update(meta)
                result.meta = merged

        self._record_call(original_body, record, result, meta, None)
        return result

    def _record_call(
        self,
        original_body: Body,
        rewrite_record: dict[str, Any] | None,
        result: ToolResult | None,
        meta: dict[str, Any] | None,
        error: str | None,
    ) -> None:
        """Append one JSON line describing this intercepted call."""
        if self._record_path is None:
            return
        result_texts: list[str] = []
        if result is not None:
            for block in result.content or []:
                text = getattr(block, "text", None)
                if isinstance(text, str):
                    result_texts.append(text)
        entry = {
            "tool": original_body["name"],
            "arguments": original_body["arguments"],
            "rewrite": rewrite_record,
            "result_texts": result_texts,
            "meta": meta,
            "error": error,
        }
        with open(self._record_path, "a", encoding="utf-8") as record_file:
            record_file.write(json.dumps(entry, default=str) + "\n")
            record_file.flush()


def _validated(body: Any) -> Body:
    """Check the shape of the body that the user rewrite function returned."""
    if (
        not isinstance(body, dict)
        or not isinstance(body.get("name"), str)
        or not isinstance(body.get("arguments"), dict)
    ):
        raise ToolError(
            "reprompt: the rewrite function must return a dict with a "
            "'name' string and an 'arguments' dict"
        )
    return {"name": body["name"], "arguments": body["arguments"]}
