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
order, to each Bash command — the output of one transformer is the input to
the next. The hook is total: a missing `racket`, a transformer that exits
non-zero, or an empty collection all leave the command unchanged.

The collection is currently empty, so the default hook is a pure identity.
Drop a `.rkt` transformer here and it is loaded automatically; the `artifacts`
entry in `pyproject.toml` ships `.rkt` files inside the installed package.
