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

- `grep.rkt` — rewrites `grep`/`egrep`/`fgrep` pipeline stages as `rg`,
  driven by the `grep->rg` command mapping (`cli/mappings/grep-rg.rkt`)
  and leaving any invocation the mapping does not claim untouched.
- `rg.rkt` — retargets lone `rg --files --hidden --no-ignore` calls onto
  the filesystem MCP server's `search_files` tool, driven by the
  `rg->filesystem` command-to-tool mapping
  (`cli/mappings/rg-filesystem.rkt`); content search, pipelines,
  redirects, and filtered walks stay shell calls.

## The `cli/` library

`cli/` is not a transformer: it is the library the transformers are
written against, with two specification languages. A *command interface*
(`define-command-interface`) is a declarative Racket specification of a
bash command's CLI (flags, options, operands, subcommands) that drives
parsing an intercepted command into a structured invocation, querying
and editing it, and rendering it back to a faithful command string. A
*command mapping* (`define-command-mapping`) is an explicit
inter-interface specification: it depends on two per-command interface
specifications and relates their keyword ids — an surjective, partial
translation from one command's invocations to another's, with every
collapse it is allowed to make declared clause by clause. See
`cli/README.md` and `cli/MAPPING-PLAN.md`; bundled interfaces for grep,
rg, cd, ls, curl, sed, find, awk, mv, cp, launchctl, systemctl, and wc
live in `cli/specs/`, and mappings live in `cli/mappings/`.

Each mapping has a dedicated VM test derived from its source interface
specification and the mapping itself: `tests/fuzz/gen-cases.rkt` samples
random command lines from the interface spec, the mapping decides which
translate, and `tests/fuzz/check-cases.sh` requires the two real tools
to agree on stdout and exit code — hermetically inside a QEMU/NixOS VM,
under fresh randomness every run (no seeds; failures carry
self-contained reports). One `fuzzTests` entry in `flake.nix` per
mapping generates the `fuzz-<name>` check, the `fuzzGuests.<name>`
closure, and the `fuzz-test-<name>` app
(`nix run .#fuzz-test-grep-rg`; `fuzz-test` is its alias). Every
divergence a test surfaces is fixed by hand in the mapping, never by
teaching the test about the mapping.
