# Default Rash syntax transformers

This directory holds the Racket/Rash (`#lang rash`) syntax transformers that
reprompt loads by default. Each transformer parses an intercepted shell
command with the linea reader, transforms the command line structurally, and
renders it back to a command string — the same shape as the test transformer
in `tests/transform_touch.rkt`, but shipped as part of the `reprompt` package
so it is always available at runtime.

## Convention

- One `.rkt` file per transformer, `#lang racket/base`.
- Invoked by the default hook as `racket <transformer>.rkt COMMAND`, reading
  the command from `(current-command-line-arguments)` and printing the
  transformed command to stdout.
- Total by contract: on any parse failure, exit non-zero so the caller leaves
  the command unchanged. A transformer must never hang or crash the proxy.

## Loading

`reprompt.transformers.rewrite` (this package's `__init__.py`) is reprompt's
default rewrite hook: whenever a configuration does not name its own `rewrite`
(`src/reprompt/cli.py`), every `.rkt` file here is applied, in sorted filename
order, to each Bash call — the *enclosing call* is rendered as
`Bash(<command>)`, and each transformer answers with one call form:
`Bash(<command'>)` to stay a shell call (chaining continues), or
`<server>.<tool>(<json>)` to retarget the call onto an MCP backend tool
(chaining stops; the proxy middleware routes the retargeted body like any
other call, and its result becomes the Bash call's result). The hook is
total: a missing `racket`, a transformer that exits non-zero or prints an
unrecognized call form, or an empty collection all leave the call unchanged.
The `checks.<system>.rewrite-hook` flake check exercises the protocol
hermetically.

Only `.rkt` files directly in this directory are run as transformers — the
hook's listing is non-recursive, so library code in subdirectories is never
invoked on its own. Drop a `.rkt` transformer here and it is loaded
automatically; the `artifacts` entry in `pyproject.toml` ships `.rkt` files
(at any depth) inside the installed package.

## Transformers

None ship currently: the package carries the specification library and
the hook plumbing, and every call passes through unchanged until a
transformer `.rkt` is dropped into this directory.

## The `cli/` specifications

`cli/` is not a transformer: it holds *command interface
specifications* — declarative descriptions of bash commands' CLIs
(flags, options, operands, subcommands) written in the external
[`cli-spec`](https://github.com/riz0id/cli-syntax) language, from which
`cli-spec`'s interpretations (parsing, help) derive. See
`cli/README.md`; bundled specs for grep,
rg, cd, ls, curl, sed, find, awk, mv, cp, launchctl, systemctl, wc,
git, and gh live in `cli/specs/`. `cli/transforms/` holds checked
spec-to-spec mappings written in the external
[`cli-spec-transform`](https://github.com/riz0id/cli-syntax-transformer)
language (`grep->rg` currently); both collections are vendored into the
`racket-with-rash` Nix layer.
