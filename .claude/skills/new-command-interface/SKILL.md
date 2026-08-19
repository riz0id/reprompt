---
name: new-command-interface
description: >-
  Author a per-command interface specification (cli/specs/<command>.rkt)
  for a given command and register it in the spec set. Use when asked to
  add a command-line interface specification, CLI spec, or command
  interface for a tool. The argument is the command name.
---

# Author a per-command interface specification

You are adding a declarative interface spec for `$ARGUMENTS` to
`src/reprompt/transformers/cli/specs/`. The spec is the vocabulary
everything downstream targets: command mappings relate its keyword ids,
and the derived VM fuzz tests sample commands from it. Follow the six
steps in order.

## 1. Ground truth first

Never author from memory. Establish the CLI of the *pinned*
implementation:

- `nix run nixpkgs#<package> -- --help` (find the package with the
  nixos MCP server if the attribute name is unclear);
- `nix shell nixpkgs#<package> -c man <command>` for the full option
  list, value syntax, and enumerated vocabularies.

Record which implementation this is (GNU vs BSD vs a multi-call binary)
and list every option where implementations disagree about whether it
takes a value — those are omitted in step 3.

## 2. Read the language and two exemplars

The language reference is `src/reprompt/transformers/cli/README.md`
(clause forms, alias-shape classification, guarantees, known-reject
constructs). Then read the two bundled specs closest to the command's
shape:

| shape | exemplar |
|---|---|
| flags/options with operand guards and `#:values` enums | `specs/grep.rkt` |
| literal aliases and operators (`-name`, `!`) | `specs/find.rkt` |
| subcommand commands | `specs/systemctl.rkt`, `specs/launchctl.rkt` |
| back-anchored operands (`SRC... DEST`) | `specs/mv.rkt` |
| attached-only optional values (`-i.bak`) | `specs/sed.rkt` |

## 3. Author `cli/specs/<command>.rkt`

Module shape: `#lang racket/base`, `(require "../main.rkt")`,
`(provide <command>-cli)`, one `define-command-interface` form, with a
header comment stating the scope and what is deliberately omitted.

The checklist — each item is load-bearing:

- **Omit, never guess.** Any option whose value-taking behavior differs
  between implementations is left out entirely so commands using it
  reject and run unmodified (the grep `-Z` precedent).
  Reject-never-corrupt extends to authoring.
- **Ids** are kebab-case symbols derived from the long alias
  (`--files-with-matches` → `files-with-matches`; short-only options
  get a descriptive name). List aliases short, then long, then literal;
  the alias *shape* determines its class (`-x` short and clusterable,
  `--xxx` long with separate or `=`-attached value, anything else a
  whole-word literal).
- **Declaration order is semantic.** The order of `#:names` and of
  flag/option clauses defines the head- and id-ranks used by the
  mapping language's termination measure. Primary command name first;
  ids in man-page order.
- **Value behavior**: `#:repeatable` where repetition accumulates;
  `#:optional-value` only where the value is genuinely omissible (needs
  a long alias or `#:attached-only`); `#:attached-only` for values that
  only ride the alias; and `#:values (...)` for **every** enumerated
  value vocabulary — downstream value compatibility is derived from
  these enumerations at parse and re-parse time, so an undeclared enum
  silently widens the accepted language.
- **Operands** in positional order with arity `one`, `optional`, or
  `many` (at most one `many` per level); use `#:when`/`#:unless` guards
  over the invocation for slots whose presence depends on other
  arguments (grep's pattern operand vs `-e`). Subcommand commands use
  `subcommand` clauses and take no top-level operands.

## 4. Register the spec

- `cli/specs/all.rkt`: add the require, the provide, and the
  `all-interfaces` entry.
- Append the command to the bundled-interfaces lists in
  `cli/README.md` and `src/reprompt/transformers/README.md`.

## 5. Validate proportionately

A spec alone has no VM test; validation is compile plus round-trip:

- compile: `nix build .#racket-with-rash --no-link --print-out-paths`,
  then `<store-path>/bin/racket -e '(require (file ".../cli/specs/<command>.rkt"))'`;
- round-trip a handful of representative real command lines through
  `parse-invocation` and `render-invocation`, one per tricky feature
  the spec uses: a short cluster, an `=`-attached value, a guarded
  operand, a literal alias or subcommand as applicable. Keep example
  lines inside the safe reader's language (no single quotes,
  backslashes, `;`, parens, or braces outside double-quoted strings).

## 6. State the follow-on; do not do it

The new spec earns a derived VM test only when a hand-written mapping
names it (`define-command-mapping` with `#:from`/`#:to`) and a
`fuzzTests` entry is added in `flake.nix`. That is a separate task —
say so in your summary and stop after registration and validation.
