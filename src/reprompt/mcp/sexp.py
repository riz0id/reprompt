"""S-expression reader for Racket interface-specification source.

reprompt reads MCP interface specifications (.rkt files) at Python
runtime, where racket may be absent: the transformers rewrite hook
already treats the REPROMPT_RACKET binary as optional. The source text
itself is therefore parsed. This reader covers exactly the lexical
subset the mcp-spec surface language uses — round parens, line and
block comments, the #lang line, booleans, strings, quoted data,
#:keywords, integers, floats, and symbols — and rejects everything
else loudly, with the source name and line number.
"""

import re
from dataclasses import dataclass


class Symbol(str):
    """A Racket symbol; a string distinguishable from string literals."""

    __slots__ = ()

    def __repr__(self) -> str:
        return f"Symbol({str.__repr__(self)})"


@dataclass(frozen=True)
class Keyword:
    """A #:keyword token."""

    name: str


@dataclass(frozen=True)
class Quoted:
    """A 'datum form."""

    datum: "Sexp"


# bool must be tested before int wherever a datum is type-switched:
# Python bool subclasses int, so isinstance(True, int) holds.
Sexp = Symbol | Keyword | Quoted | bool | int | float | str | list["Sexp"]

_DELIMITERS = " \t\r\n()[]{}\";'"

_INT = re.compile(r"[+-]?[0-9]+")
_FLOAT = re.compile(
    r"[+-]?(?:[0-9]+\.[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?"
    r"|[+-]?[0-9]+[eE][+-]?[0-9]+"
)

_STRING_ESCAPES = {"\\": "\\", '"': '"', "n": "\n", "t": "\t", "r": "\r"}


def read_forms(text: str, source: str = "<string>") -> list["Sexp"]:
    """Read every top-level form in Racket source text."""
    tokens = _tokenize(text, source)
    forms: list[Sexp] = []
    index = 0
    while index < len(tokens):
        form, index = _read(tokens, index, source)
        forms.append(form)
    return forms


def _error(source: str, line: int, message: str) -> ValueError:
    """Build a reader error carrying the source name and line."""
    return ValueError(f"{source}:{line}: {message}")


def _tokenize(text: str, source: str) -> list[tuple[str, "Sexp", int]]:
    """Split source text into (kind, value, line) tokens."""
    tokens: list[tuple[str, Sexp, int]] = []
    index = 0
    line = 1
    length = len(text)
    while index < length:
        char = text[index]
        if char == "\n":
            line += 1
            index += 1
        elif char in " \t\r":
            index += 1
        elif char == ";":
            while index < length and text[index] != "\n":
                index += 1
        elif char == "(":
            tokens.append(("open", "", line))
            index += 1
        elif char == ")":
            tokens.append(("close", "", line))
            index += 1
        elif char in "[]{}":
            raise _error(source, line, f"unsupported bracket '{char}'")
        elif char == "'":
            tokens.append(("quote", "", line))
            index += 1
        elif char == "|":
            raise _error(source, line, "pipe-quoted symbols are not supported")
        elif char == '"':
            value, index, line = _read_string(text, index, line, source)
            tokens.append(("datum", value, line))
        elif char == "#":
            index, line = _read_hash(text, index, line, source, tokens)
        else:
            start = index
            while index < length and text[index] not in _DELIMITERS:
                index += 1
            tokens.append(("datum", _classify(text[start:index]), line))
    return tokens


def _read_string(text: str, index: int, line: int, source: str) -> tuple[str, int, int]:
    """Read a string literal starting at the opening double quote."""
    start_line = line
    index += 1
    parts: list[str] = []
    while index < len(text):
        char = text[index]
        if char == '"':
            return "".join(parts), index + 1, line
        if char == "\\":
            if index + 1 >= len(text):
                break
            escape = text[index + 1]
            if escape not in _STRING_ESCAPES:
                raise _error(source, line, f"unsupported string escape '\\{escape}'")
            parts.append(_STRING_ESCAPES[escape])
            index += 2
        else:
            if char == "\n":
                line += 1
            parts.append(char)
            index += 1
    raise _error(source, start_line, "unterminated string")


def _read_hash(
    text: str,
    index: int,
    line: int,
    source: str,
    tokens: list[tuple[str, "Sexp", int]],
) -> tuple[int, int]:
    """Read a #-prefixed token, appending any produced datum token."""
    if text.startswith("#|", index):
        return _skip_block_comment(text, index, line, source)
    if text.startswith("#;", index):
        raise _error(source, line, "datum comments (#;) are not supported")
    start = index + 1
    index = start
    while index < len(text) and text[index] not in _DELIMITERS:
        index += 1
    word = text[start:index]
    if word in ("t", "true"):
        tokens.append(("datum", True, line))
    elif word in ("f", "false"):
        tokens.append(("datum", False, line))
    elif word.startswith(":") and len(word) > 1:
        tokens.append(("datum", Keyword(word[1:]), line))
    elif word == "lang":
        while index < len(text) and text[index] != "\n":
            index += 1
    else:
        raise _error(source, line, f"unsupported token '#{word}'")
    return index, line


def _skip_block_comment(
    text: str, index: int, line: int, source: str
) -> tuple[int, int]:
    """Skip a #| ... |# comment, honoring nesting."""
    start_line = line
    depth = 1
    index += 2
    while index < len(text):
        if text.startswith("#|", index):
            depth += 1
            index += 2
        elif text.startswith("|#", index):
            depth -= 1
            index += 2
            if depth == 0:
                return index, line
        else:
            if text[index] == "\n":
                line += 1
            index += 1
    raise _error(source, start_line, "unterminated block comment")


def _classify(token: str) -> "Sexp":
    """Interpret a bare atom token as an int, float, or symbol."""
    if _INT.fullmatch(token):
        return int(token)
    if _FLOAT.fullmatch(token):
        return float(token)
    return Symbol(token)


def _read(
    tokens: list[tuple[str, "Sexp", int]], index: int, source: str
) -> tuple["Sexp", int]:
    """Read one datum starting at tokens[index]."""
    kind, value, line = tokens[index]
    if kind == "datum":
        return value, index + 1
    if kind == "quote":
        if index + 1 >= len(tokens):
            raise _error(source, line, "quote at end of input")
        datum, index = _read(tokens, index + 1, source)
        return Quoted(datum), index
    if kind == "open":
        items: list[Sexp] = []
        index += 1
        while True:
            if index >= len(tokens):
                raise _error(source, line, "unterminated list")
            if tokens[index][0] == "close":
                return items, index + 1
            item, index = _read(tokens, index, source)
            items.append(item)
    raise _error(source, line, "unexpected ')'")
