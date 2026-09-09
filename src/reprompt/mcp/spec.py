"""MCP interface specifications as a Python AST.

This module mirrors transformers/cli/mcp/mcp-spec.rkt: the same
structure (operators with typed, possibly-optional arguments and a
typed return) and the same static checks that check-operator performs,
so a specification file means the same thing to both languages. The
.rkt source is interpreted structurally — read as s-expressions and
walked form by form — never evaluated.
"""

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from reprompt.mcp.sexp import Keyword, Quoted, Sexp, Symbol, read_forms

KNOWN_ATOMS: Final[frozenset[str]] = frozenset(
    {
        "string",
        "int",
        "nat",
        "float",
        "bool",
        "path",
        "file",
        "dir",
        "glob",
        "regex",
        "date",
        "duration",
        "host",
        "port",
        "url",
    }
)

_METHOD_NAME = r"[A-Za-z0-9_./-]+"


class _NoDefault:
    """Sentinel type for 'no #:default was supplied'."""

    def __repr__(self) -> str:
        return "NO_DEFAULT"


NO_DEFAULT: Final[_NoDefault] = _NoDefault()


def snake_name(name: str) -> str:
    """Kebab-case spec name to snake_case Python name."""
    return name.replace("-", "_")


@dataclass(frozen=True)
class AtomType:
    """A built-in atom type such as 'int or 'path."""

    name: str


@dataclass(frozen=True)
class EnumType:
    """A cli:enum value vocabulary."""

    values: tuple[str, ...]


@dataclass(frozen=True)
class ListOfType:
    """A cli:list-of separated sequence."""

    inner: "McpType"
    sep: str


@dataclass(frozen=True)
class PairOfType:
    """A cli:pair-of KEY<sep>VALUE pairing."""

    left: "McpType"
    right: "McpType"
    sep: str


@dataclass(frozen=True)
class OrType:
    """A cli:or-type first-success alternation."""

    alternatives: tuple["McpType", ...]


@dataclass(frozen=True)
class CustomType:
    """A cli:custom type, opaque to Python: its parser is a Racket procedure."""

    name: str


McpType = AtomType | EnumType | ListOfType | PairOfType | OrType | CustomType


@dataclass(frozen=True)
class McpArgument:
    """One named, typed, possibly-optional operator argument."""

    name: str
    type: McpType
    optional: bool
    default: object
    doc: str | None

    @property
    def has_default(self) -> bool:
        """Whether a #:default was supplied."""
        return not isinstance(self.default, _NoDefault)


@dataclass(frozen=True)
class McpOperator:
    """One named MCP method with arguments and a typed return."""

    name: str
    method: str
    arguments: tuple[McpArgument, ...]
    return_type: McpType
    doc: str | None


@dataclass(frozen=True)
class McpInterface:
    """One interface file's operators and provide list."""

    name: str
    operators: tuple[McpOperator, ...]
    provides: tuple[str, ...]

    def provided_operators(self) -> tuple[McpOperator, ...]:
        """Operators named in the provide list, in provide order."""
        by_name = {op.name: op for op in self.operators}
        return tuple(by_name[name] for name in self.provides)


_DIR = os.path.dirname(os.path.abspath(__file__))
_BUNDLED_DIR = os.path.join(os.path.dirname(_DIR), "transformers", "cli", "mcp")


def load_bundled(name: str) -> McpInterface:
    """Load a bundled interface from transformers/cli/mcp/<name>.rkt."""
    return load_interface(os.path.join(_BUNDLED_DIR, f"{name}.rkt"))


def load_interface(path: str | Path) -> McpInterface:
    """Load a .rkt MCP interface file; the interface name is the file stem."""
    text = Path(path).read_text(encoding="utf-8")
    return _parse(text, source=str(path), name=Path(path).stem)


def parse_interface(text: str, name: str) -> McpInterface:
    """Parse MCP interface source text into its AST."""
    return _parse(text, source=name, name=name)


def _parse(text: str, source: str, name: str) -> McpInterface:
    """Walk an interface file's top-level forms into an McpInterface.

    An interface file holds only require, provide, and define-mcp
    forms; anything else (a plain define, an aggregator such as
    all.rkt) is rejected.
    """
    operators: list[McpOperator] = []
    provides: list[str] = []
    for form in read_forms(text, source):
        if not isinstance(form, list) or not form:
            raise ValueError(f"{source}: unsupported top-level form: {form!r}")
        head = form[0]
        if head == Symbol("require") and isinstance(head, Symbol):
            continue
        if head == Symbol("provide") and isinstance(head, Symbol):
            for item in form[1:]:
                if not isinstance(item, Symbol):
                    raise ValueError(f"{source}: unsupported provide form: {item!r}")
                provides.append(str(item))
            continue
        if head == Symbol("define-mcp") and isinstance(head, Symbol):
            operators.append(_parse_define_mcp(form, source))
            continue
        raise ValueError(f"{source}: unsupported top-level form '{head}'")
    seen_names: set[str] = set()
    seen_methods: set[str] = set()
    for op in operators:
        if op.name in seen_names:
            raise ValueError(f"{source}: duplicate operator '{op.name}'")
        seen_names.add(op.name)
        if op.method in seen_methods:
            raise ValueError(f"{source}: {op.name}: duplicate method '{op.method}'")
        seen_methods.add(op.method)
    for provided in provides:
        if provided not in seen_names:
            raise ValueError(f"{source}: provide of undefined operator '{provided}'")
    return McpInterface(name, tuple(operators), tuple(provides))


def _parse_define_mcp(form: list[Sexp], source: str) -> McpOperator:
    """Parse one (define-mcp name option* argument*) form."""
    if len(form) < 2 or not isinstance(form[1], Symbol):
        raise ValueError(f"{source}: define-mcp needs a name symbol: {form!r}")
    op_name = str(form[1])
    options, clauses = _split_options(
        form[2:], ("method", "returns", "doc"), (op_name,), source
    )
    method_datum = options.get("method", snake_name(op_name))
    if not isinstance(method_datum, str) or isinstance(method_datum, Symbol):
        raise ValueError(
            f"{source}: {op_name}: #:method must be a string: {method_datum!r}"
        )
    if not re.fullmatch(_METHOD_NAME, method_datum):
        raise ValueError(f"{source}: {op_name}: invalid method name: {method_datum!r}")
    doc = _doc_option(options, (op_name,), source)
    returns_expr = options.get("returns", Quoted(Symbol("string")))
    return_type = _parse_type(returns_expr, (op_name,), source)
    arguments: list[McpArgument] = []
    for clause in clauses:
        if (
            not isinstance(clause, list)
            or not clause
            or clause[0] != Symbol("argument")
        ):
            raise ValueError(f"{source}: {op_name}: invalid clause: {clause!r}")
        arguments.append(_parse_argument(clause, op_name, source))
    seen: set[str] = set()
    for arg in arguments:
        if arg.name in seen:
            raise ValueError(
                f"{source}: {op_name}: duplicate argument name '{arg.name}'"
            )
        seen.add(arg.name)
    return McpOperator(op_name, method_datum, tuple(arguments), return_type, doc)


def _parse_argument(form: list[Sexp], op_name: str, source: str) -> McpArgument:
    """Parse one (argument 'name [type] option*) clause."""
    if (
        len(form) < 2
        or not isinstance(form[1], Quoted)
        or not isinstance(form[1].datum, Symbol)
    ):
        raise ValueError(
            f"{source}: {op_name}: argument needs a quoted name symbol: {form!r}"
        )
    arg_name = str(form[1].datum)
    path = (op_name, arg_name)
    rest = form[2:]
    if rest and not isinstance(rest[0], Keyword):
        type_expr: Sexp = rest[0]
        rest = rest[1:]
    else:
        type_expr = Quoted(Symbol("string"))
    arg_type = _parse_type(type_expr, path, source)
    options, trailing = _split_options(
        rest, ("optional?", "default", "doc"), path, source
    )
    if trailing:
        raise ValueError(f"{source}: {_at(path)}: invalid clause: {trailing[0]!r}")
    optional = options.get("optional?", False)
    if not isinstance(optional, bool):
        raise ValueError(
            f"{source}: {_at(path)}: #:optional? must be #t or #f: {optional!r}"
        )
    default: object = options.get("default", NO_DEFAULT)
    if not isinstance(default, (_NoDefault, bool, int, float, str)) or isinstance(
        default, (Symbol, Keyword, Quoted)
    ):
        raise ValueError(
            f"{source}: {_at(path)}: unsupported default datum: {default!r}"
        )
    if not isinstance(default, _NoDefault) and not optional:
        raise ValueError(f"{source}: {_at(path)}: #:default requires #:optional? #t")
    doc = _doc_option(options, path, source)
    return McpArgument(arg_name, arg_type, optional, default, doc)


def _parse_type(expr: Sexp, path: tuple[str, ...], source: str) -> McpType:
    """Interpret a type expression: a quoted atom or a cli-type constructor."""
    if isinstance(expr, Quoted) and isinstance(expr.datum, Symbol):
        atom = str(expr.datum)
        if atom not in KNOWN_ATOMS:
            raise ValueError(f"{source}: {_at(path)}: unknown type atom '{atom}'")
        return AtomType(atom)
    if isinstance(expr, list) and expr and isinstance(expr[0], Symbol):
        head = str(expr[0])
        if head == "cli:enum":
            values = expr[1:]
            if len(values) < 2 or not all(
                isinstance(v, str) and not isinstance(v, Symbol) for v in values
            ):
                raise ValueError(f"{source}: {_at(path)}: malformed enum type")
            return EnumType(tuple(str(v) for v in values))
        if head == "cli:list-of":
            inner, sep = _compound_tail(expr[1:], 1, ",", path, source)
            return ListOfType(_parse_type(inner[0], path, source), sep)
        if head == "cli:pair-of":
            pair, sep = _compound_tail(expr[1:], 2, "=", path, source)
            return PairOfType(
                _parse_type(pair[0], path, source),
                _parse_type(pair[1], path, source),
                sep,
            )
        if head == "cli:or-type":
            if len(expr) < 3:
                raise ValueError(f"{source}: {_at(path)}: malformed or-type")
            return OrType(tuple(_parse_type(alt, path, source) for alt in expr[1:]))
        if head == "cli:custom":
            if (
                len(expr) < 2
                or not isinstance(expr[1], Quoted)
                or not isinstance(expr[1].datum, Symbol)
            ):
                raise ValueError(f"{source}: {_at(path)}: malformed custom type")
            return CustomType(str(expr[1].datum))
        raise ValueError(f"{source}: {_at(path)}: unknown type constructor '{head}'")
    raise ValueError(f"{source}: {_at(path)}: not a type: {expr!r}")


def _compound_tail(
    tail: list[Sexp],
    arity: int,
    default_sep: str,
    path: tuple[str, ...],
    source: str,
) -> tuple[list[Sexp], str]:
    """Split a cli:list-of / cli:pair-of tail into type exprs and a #:sep."""
    exprs = tail[:arity]
    rest = tail[arity:]
    sep = default_sep
    if rest:
        if (
            len(rest) != 2
            or rest[0] != Keyword("sep")
            or not isinstance(rest[1], str)
            or isinstance(rest[1], Symbol)
        ):
            raise ValueError(f"{source}: {_at(path)}: malformed type options")
        sep = str(rest[1])
    if len(exprs) != arity:
        raise ValueError(f"{source}: {_at(path)}: malformed compound type")
    return exprs, sep


def _split_options(
    items: list[Sexp],
    allowed: tuple[str, ...],
    path: tuple[str, ...],
    source: str,
) -> tuple[dict[str, Sexp], list[Sexp]]:
    """Consume leading #:keyword/datum pairs; return options and the rest."""
    options: dict[str, Sexp] = {}
    index = 0
    while index < len(items) and isinstance(items[index], Keyword):
        keyword = items[index]
        assert isinstance(keyword, Keyword)
        if keyword.name not in allowed:
            raise ValueError(f"{source}: {_at(path)}: unknown option #:{keyword.name}")
        if keyword.name in options:
            raise ValueError(
                f"{source}: {_at(path)}: duplicate option #:{keyword.name}"
            )
        if index + 1 >= len(items):
            raise ValueError(f"{source}: {_at(path)}: #:{keyword.name} needs a value")
        options[keyword.name] = items[index + 1]
        index += 2
    rest = items[index:]
    for item in rest:
        if isinstance(item, Keyword):
            raise ValueError(
                f"{source}: {_at(path)}: option #:{item.name} must precede "
                "argument clauses"
            )
    return options, rest


def _doc_option(
    options: dict[str, Sexp], path: tuple[str, ...], source: str
) -> str | None:
    """Extract a #:doc option, requiring a string literal."""
    doc = options.get("doc")
    if doc is None:
        return None
    if not isinstance(doc, str) or isinstance(doc, Symbol):
        raise ValueError(f"{source}: {_at(path)}: #:doc must be a string: {doc!r}")
    return str(doc)


def _at(path: tuple[str, ...]) -> str:
    """Render a spec path the way mcp-spec.rkt does."""
    return " → ".join(path)
