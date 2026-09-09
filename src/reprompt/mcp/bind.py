"""Bind an MCP interface specification to a Python implementation module.

The specification is the single source of truth. Binding proves at
import time — via inspect.signature and typing.get_type_hints — that
the implementation module's functions match the spec exactly: one
function per provided operator (kebab-case names become snake_case),
parameters named and ordered like the spec's arguments, annotations
matching the spec's type mapping, and defaults matching the spec's
defaults. Dispatch then interprets wire payloads against the spec —
the Python analogue of mcp-spec.rkt's parse-operator-args, with the
same normalization and the same atom-parsing rules as the vendored
cli-spec collection — before invoking the matched function.
"""

import datetime
import importlib
import inspect
import re
import typing
import urllib.parse
from collections.abc import Callable
from functools import reduce
from operator import or_
from pathlib import Path
from types import ModuleType

from reprompt.mcp.spec import (
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
    snake_name,
)

_ATOM_ANNOTATIONS: dict[str, object] = {
    "string": str,
    "int": int,
    "nat": int,
    "float": float,
    "bool": bool,
    "path": Path,
    "file": Path,
    "dir": Path,
    "glob": str,
    "regex": re.Pattern[str],
    "date": datetime.date,
    "duration": float,
    "host": str,
    "port": int,
    "url": str,
}

_ATOM_DESCRIPTIONS: dict[str, str] = {
    "string": "a string",
    "int": "an integer",
    "nat": "a nonnegative integer",
    "float": "a number",
    "bool": "a boolean (true/false, yes/no, on/off, 1/0)",
    "path": "a path",
    "file": "a file path",
    "dir": "a directory path",
    "glob": "a glob pattern",
    "regex": "a regular expression",
    "date": "a date (YYYY-MM-DD)",
    "duration": "a duration (e.g. 500ms, 30s, 5m, 2h, 1d)",
    "host": "a hostname or address",
    "port": "a port number (0-65535)",
    "url": "a URL",
}

_HOSTNAME = re.compile(
    r"[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?"
    r"(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*"
)

_DURATION_UNITS = {"ms": 0.001, "s": 1.0, "m": 60.0, "h": 3600.0, "d": 86400.0}


class McpCallError(ValueError):
    """A payload rejected against the interface specification."""

    def __init__(self, kind: str, message: str) -> None:
        super().__init__(message)
        self.kind = kind


class _BadValue(Exception):
    """An atom or compound coercion failure, carrying the expectation."""

    def __init__(self, expected: str) -> None:
        super().__init__(expected)
        self.expected = expected


def annotation_for(mcp_type: McpType) -> object:
    """The Python annotation an implementation must use for a spec type."""
    if isinstance(mcp_type, AtomType):
        return _ATOM_ANNOTATIONS[mcp_type.name]
    if isinstance(mcp_type, EnumType):
        return str
    if isinstance(mcp_type, ListOfType):
        return list[annotation_for(mcp_type.inner)]  # type: ignore[misc]
    if isinstance(mcp_type, PairOfType):
        return tuple[  # type: ignore[misc]
            annotation_for(mcp_type.left), annotation_for(mcp_type.right)
        ]
    if isinstance(mcp_type, OrType):
        return reduce(or_, (annotation_for(t) for t in mcp_type.alternatives))
    raise ValueError(f"cannot bind custom type '{mcp_type.name}'")


def _annotation_for_argument(argument: McpArgument) -> object:
    """The annotation for one argument, folding in optionality."""
    base = annotation_for(argument.type)
    if argument.optional and not argument.has_default:
        return base | None  # type: ignore[operator]
    return base


def bind_interface(
    interface: McpInterface, module: ModuleType | str
) -> "BoundInterface":
    """Bind every provided operator to its function in the implementation module."""
    if isinstance(module, str):
        module = importlib.import_module(module)
    by_method: dict[str, tuple[McpOperator, Callable[..., object]]] = {}
    for op in interface.provided_operators():
        by_method[op.method] = (op, _checked(interface, op, module))
    return BoundInterface(interface, module, by_method)


def _checked(
    interface: McpInterface, op: McpOperator, module: ModuleType
) -> Callable[..., object]:
    """Look up an operator's function and prove its signature matches."""

    def fail(message: str) -> ValueError:
        return ValueError(f"{interface.name}: {op.name}: {message}")

    for arg in op.arguments:
        _refuse_custom(arg.type, f"{interface.name}: {op.name} → {arg.name}")
    _refuse_custom(op.return_type, f"{interface.name}: {op.name}")
    function_name = snake_name(op.name)
    function = getattr(module, function_name, None)
    if not callable(function):
        raise fail(f"module {module.__name__!r} has no function {function_name!r}")
    try:
        hints = typing.get_type_hints(function)
    except NameError as error:
        raise fail(f"unresolvable annotation: {error}") from error
    signature = inspect.signature(function)
    parameters = list(signature.parameters.values())
    for parameter in parameters:
        if parameter.kind is not inspect.Parameter.POSITIONAL_OR_KEYWORD:
            raise fail(f"parameter {parameter.name!r} must be positional-or-keyword")
    names = [parameter.name for parameter in parameters]
    wanted = [snake_name(arg.name) for arg in op.arguments]
    if names != wanted:
        raise fail(f"parameters {names!r} do not match spec arguments {wanted!r}")
    for arg, parameter in zip(op.arguments, parameters):
        expected = _annotation_for_argument(arg)
        actual = hints.get(parameter.name)
        if actual is None:
            raise fail(f"parameter {parameter.name!r} is missing an annotation")
        if actual != expected:
            raise fail(
                f"parameter {parameter.name!r} is annotated {actual!r}, "
                f"spec requires {expected!r}"
            )
        if arg.optional and arg.has_default:
            default = parameter.default
            if (
                default is inspect.Parameter.empty
                or type(default) is not type(arg.default)
                or default != arg.default
            ):
                raise fail(
                    f"parameter {parameter.name!r} must default to {arg.default!r}"
                )
        elif parameter.default is not inspect.Parameter.empty:
            raise fail(f"parameter {parameter.name!r} must not have a default")
    if "return" not in hints:
        raise fail("missing return annotation")
    expected_return = annotation_for(op.return_type)
    if hints["return"] != expected_return:
        raise fail(
            f"return is annotated {hints['return']!r}, "
            f"spec requires {expected_return!r}"
        )
    return function


def _refuse_custom(mcp_type: McpType, at: str) -> None:
    """Reject custom types anywhere in a bound operator's surface."""
    if isinstance(mcp_type, CustomType):
        raise ValueError(f"{at}: cannot bind custom type '{mcp_type.name}'")
    if isinstance(mcp_type, ListOfType):
        _refuse_custom(mcp_type.inner, at)
    if isinstance(mcp_type, PairOfType):
        _refuse_custom(mcp_type.left, at)
        _refuse_custom(mcp_type.right, at)
    if isinstance(mcp_type, OrType):
        for alternative in mcp_type.alternatives:
            _refuse_custom(alternative, at)


class BoundInterface:
    """A checked pairing of an interface with its implementation functions."""

    def __init__(
        self,
        interface: McpInterface,
        module: ModuleType,
        by_method: dict[str, tuple[McpOperator, Callable[..., object]]],
    ) -> None:
        self.interface = interface
        self.module = module
        self._by_method = by_method

    def call(self, method: str, payload: dict[str, object]) -> object:
        """Dispatch a wire-method call: coerce the payload, invoke the function.

        Payload keys are the spec's argument names verbatim (kebab-case,
        as on the wire). An omitted optional argument with no #:default
        is passed to the implementation explicitly as None — Python
        parameters cannot be left unbound the way an mcp-ok hash leaves
        an absent name out.
        """
        entry = self._by_method.get(method)
        if entry is None:
            known = ", ".join(sorted(self._by_method))
            raise McpCallError(
                "unknown-method", f"unknown method '{method}' (known: {known})"
            )
        op, function = entry
        normalized = _normalize_payload(op, payload)
        known_names = [arg.name for arg in op.arguments]
        for key in normalized:
            if key not in known_names:
                raise McpCallError(
                    "unknown-argument",
                    f"{op.name}: unknown argument '{key}' "
                    f"(known: {', '.join(known_names)})",
                )
        kwargs: dict[str, object] = {}
        for arg in op.arguments:
            raw = normalized.get(arg.name)
            if raw is not None:
                try:
                    kwargs[snake_name(arg.name)] = _coerce(arg.type, raw)
                except _BadValue as bad:
                    raise McpCallError(
                        "bad-value",
                        f"{op.name} → {arg.name}: invalid value '{raw}' for "
                        f"{arg.name}: expected {bad.expected}",
                    ) from None
            elif not arg.optional:
                raise McpCallError(
                    "missing-required",
                    f"{op.name}: missing required argument '{arg.name}'",
                )
            elif arg.has_default:
                kwargs[snake_name(arg.name)] = arg.default
            else:
                kwargs[snake_name(arg.name)] = None
        return function(**kwargs)


def _normalize_payload(op: McpOperator, payload: dict[str, object]) -> dict[str, str]:
    """Normalize a payload's values to the strings cli-spec types parse."""

    def bad(datum: object) -> McpCallError:
        return McpCallError(
            "bad-payload", f"{op.name}: malformed argument payload at {datum!r}"
        )

    if not isinstance(payload, dict):
        raise bad(payload)
    normalized: dict[str, str] = {}
    for key, value in payload.items():
        if not isinstance(key, str):
            raise bad(key)
        # bool before int: Python bool subclasses int.
        if isinstance(value, bool):
            normalized[key] = "true" if value else "false"
        elif isinstance(value, str):
            normalized[key] = value
        elif isinstance(value, int):
            normalized[key] = str(value)
        elif isinstance(value, float):
            normalized[key] = repr(value)
        else:
            raise bad(value)
    return normalized


def _coerce(mcp_type: McpType, raw: str) -> object:
    """Parse one raw string per the spec type, mirroring cli-spec's rules."""
    if isinstance(mcp_type, AtomType):
        return _coerce_atom(mcp_type.name, raw)
    if isinstance(mcp_type, EnumType):
        if raw in mcp_type.values:
            return raw
        raise _BadValue(f"one of: {', '.join(mcp_type.values)}")
    if isinstance(mcp_type, ListOfType):
        # str.split on an empty string yields [""], which may diverge
        # from Racket's (string-split s sep #:trim? #f) on edge cases.
        return [_coerce(mcp_type.inner, part) for part in raw.split(mcp_type.sep)]
    if isinstance(mcp_type, PairOfType):
        position = raw.find(mcp_type.sep)
        if position < 0:
            raise _BadValue(f"KEY{mcp_type.sep}VALUE")
        left = _coerce(mcp_type.left, raw[:position])
        right = _coerce(mcp_type.right, raw[position + len(mcp_type.sep) :])
        return (left, right)
    if isinstance(mcp_type, OrType):
        expectations: list[str] = []
        for alternative in mcp_type.alternatives:
            try:
                return _coerce(alternative, raw)
            except _BadValue as bad:
                expectations.append(bad.expected)
        raise _BadValue(" or ".join(expectations))
    raise _BadValue(f"a valid {mcp_type.name}")


def _coerce_atom(atom: str, raw: str) -> object:
    """Parse one atom-typed value; rules transcribed from cli-spec ast.rkt."""

    def bad() -> _BadValue:
        return _BadValue(_ATOM_DESCRIPTIONS[atom])

    if atom == "string":
        return raw
    if atom == "int":
        if re.fullmatch(r"[+-]?[0-9]+", raw):
            return int(raw)
        raise bad()
    if atom in ("nat", "port"):
        if re.fullmatch(r"[0-9]+", raw):
            value = int(raw)
            if atom == "nat" or value <= 65535:
                return value
        raise bad()
    if atom == "float":
        # Divergence from Racket's string->number: exact fractions such
        # as "1/2" are rejected, as are Python-only spellings (nan/inf,
        # underscores, surrounding whitespace).
        lowered = raw.casefold().lstrip("+-")
        if raw != raw.strip() or "_" in raw or lowered in ("nan", "inf", "infinity"):
            raise bad()
        try:
            return float(raw)
        except ValueError:
            raise bad() from None
    if atom == "bool":
        folded = raw.casefold()
        if folded in ("true", "yes", "on", "1"):
            return True
        if folded in ("false", "no", "off", "0"):
            return False
        raise bad()
    if atom in ("path", "file", "dir"):
        if raw:
            return Path(raw)
        raise bad()
    if atom == "glob":
        if raw:
            return raw
        raise bad()
    if atom == "regex":
        try:
            return re.compile(raw)
        except re.error:
            raise bad() from None
    if atom == "date":
        match = re.fullmatch(r"([0-9]{4})-([0-9]{2})-([0-9]{2})", raw)
        if match:
            try:
                return datetime.date(int(match[1]), int(match[2]), int(match[3]))
            except ValueError:
                raise bad() from None
        raise bad()
    if atom == "duration":
        match = re.fullmatch(r"([0-9]+)(ms|s|m|h|d)", raw)
        if match:
            return int(match[1]) * _DURATION_UNITS[match[2]]
        raise bad()
    if atom == "host":
        if _HOSTNAME.fullmatch(raw) or (
            re.fullmatch(r"[0-9A-Fa-f:]+", raw) and ":" in raw
        ):
            return raw
        raise bad()
    if atom == "url":
        try:
            parsed = urllib.parse.urlparse(raw)
        except ValueError:
            raise bad() from None
        if parsed.scheme:
            return raw
        raise bad()
    raise _BadValue(f"a valid {atom}")
