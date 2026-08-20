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
everything downstream targets by its keyword ids. Follow the five
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
("Writing an interface": the `cli-spec` surface, the supported subset,
guarantees, known-reject constructs) plus the lowering table in
`cli/lower.rkt`'s header. Then read the two bundled specs closest to
the command's shape:

| shape | exemplar |
|---|---|
| flags/options with `#:values` enums | `specs/grep.rkt` |
| nested subcommands with aliases | `specs/gh.rkt` |
| subcommands with top-level globals | `specs/systemctl.rkt`, `specs/launchctl.rkt` |
| attached-only optional values (`-i.bak`) | `specs/sed.rkt` |

## 3. Author `cli/specs/<command>.rkt`

Module shape: `#lang racket/base`,
`(require (prefix-in cli: cli-spec) "../main.rkt")`,
`(provide <command>-cli)`, one
`(define <command>-cli (command->interface (cli:cmd '<command> ...)))`
form, with a header comment stating the scope and what is deliberately
omitted.

The checklist — each item is load-bearing:

- **Omit, never guess.** Any option whose value-taking behavior differs
  between implementations is left out entirely so commands using it
  reject and run unmodified (the grep `-Z` precedent).
  Reject-never-corrupt extends to authoring.
- **One head per command.** `cli:cmd` names exactly the command the
  spec describes; variant binaries (`egrep`, `gawk`) are not aliases of
  it. The lowering rejects specs that cannot be given faithful
  semantics — stay inside the subset in `lower.rkt`'s header ('string
  and `cli:enum` types, arities `1`/`'?`/`'*`, no guards, no groups,
  no rest clauses).
- **Ids** are kebab-case symbols derived from the long alias
  (`--files-with-matches` → `files-with-matches`; short-only options
  get a descriptive name). Give `#:aliases` explicitly, short then
  long; the alias *shape* determines its class (`-x` short and
  clusterable, `--xxx` long with separate or `=`-attached value — no
  other shape exists in `cli-spec`). Quote alias symbols that read as
  numbers (`|-i|`, `|-I|`, `|-0|`, `|-1|`, `|-#|`).
- **Declaration order matters.** Consumers see flags, options, and
  operand slots in declared order (canonical rendering, slot filling).
  Ids in man-page order.
- **Value behavior**: a `cli:flag` with no type is a switch; with a
  type it takes a value. `#:repeat 'list` where repetition
  accumulates; `#:arity '?` only where the value is genuinely
  omissible (the value then never consumes the next word — attached
  forms only); and a `cli:enum` type for **every** enumerated value
  vocabulary — downstream value compatibility is derived from these
  enumerations at parse and re-parse time, so an undeclared enum
  silently widens the accepted language.
- **Operands** (`cli:arg`, type `'string`) in positional order with
  arity `1`, `'?`, or `'*` (at most one variadic slot per level, and
  nothing required after it). There are no operand guards: when
  which-word-is-which depends on flags (grep's pattern vs its first
  file), declare one slot and let the consumer draw the boundary over
  the slot's words. Subcommand commands use `cli:subcommand` clauses
  (nesting allowed, `#:aliases` for alternate words) and take no
  operands at a level that has subcommands.

## 4. Register the spec

- `cli/specs/all.rkt`: add the require, the provide, and the
  `all-interfaces` entry.
- Append the command to the bundled-interfaces lists in
  `cli/README.md` and `src/reprompt/transformers/README.md`.

## 5. Validate proportionately

Validation is compile plus round-trip:

- compile: `nix build .#racket-with-rash --no-link --print-out-paths`,
  then `<store-path>/bin/racket -e '(require (file ".../cli/specs/<command>.rkt"))'`;
- round-trip a handful of representative real command lines through
  `parse-invocation` and `render-invocation`, one per tricky feature
  the spec uses: a short cluster, an `=`-attached value, an enum value,
  a subcommand (nested or aliased) as applicable. Keep example
  lines inside the safe reader's language (no single quotes,
  backslashes, `;`, parens, or braces outside double-quoted strings).
