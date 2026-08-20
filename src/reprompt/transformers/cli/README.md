# cli — command interface specifications

Declarative specifications of bash commands' CLIs, written in the
external [`cli-spec`](https://github.com/riz0id/cli-syntax) language
(Racket collection `cli-spec`, vendored offline into the
`racket-with-rash` layer by `nix/racket-with-rash.nix`). A spec is a
complete, machine-readable description of one command's surface —
subcommands, typed flags, positionals — from which `cli-spec`'s
interpretations (`parse-argv`, `spec->help`, and whatever a consumer
builds over the AST) are derived.

```racket
(require (prefix-in cli: cli-spec)   ; prefix: cli-spec's `rest` shadows racket/list
         "specs/gh.rkt")

(cli:parse-argv gh-cli '("issue" "ls" "-s" "open"))
; ⇒ (parse-ok '(gh issue list) (hash 'state "open"))
```

## Writing a spec

```racket
(define grep-cli
  (cli:cmd 'grep
    (cli:flag 'recursive #:aliases '(-r --recursive))       ; switch, clusterable
    (cli:flag 'pattern 'string #:aliases '(-e --regexp)
              #:repeat 'list)                               ; valued, repeatable
    (cli:flag 'color (cli:enum "never" "auto" "always")     ; enumerated value
              #:aliases '(--color) #:arity '?)              ; value optional, attached only
    (cli:arg 'args 'string #:arity '*)                      ; operands: 1 | '? | '*
    (cli:subcommand 'restart                                ; systemctl-style
      (cli:arg 'units 'string #:arity '*))))
```

Conventions the bundled specs follow:

- **One head per command.** `(cli:cmd 'grep ...)` describes `grep` and
  nothing else — a command's head uniquely identifies it, so `egrep` or
  `gawk` would be commands (and specs) of their own.
- **Omit, never guess.** Any option whose value-taking behavior differs
  between implementations is left out entirely, so an invocation using
  it fails to parse instead of misparsing (the grep `-Z` precedent).
- Ids are kebab-case symbols derived from the long alias; aliases are
  given explicitly (short then long) and keep their declared order.
  Alias symbols that read as numbers are pipe-quoted (`|-i|`, `|-I|`,
  `|-0|`, `|-1|`, `|-#|`).
- A `cli:flag` with no type is a boolean switch; with a type it takes a
  value. `#:repeat 'list` marks a repeatable option; `#:arity '?` makes
  the value optional (attached forms only); `cli:enum` declares every
  enumerated value vocabulary.
- Operand slots fill in declared order; at most one may be variadic,
  and nothing required may follow it. `cli:subcommand` nests to any
  depth (`gh issue list`) and may carry `#:aliases` (gh's `ls`, which
  parses verbatim but names the canonical path).
- Spec mistakes are caught at construction: `cli:cmd` runs `cli-spec`'s
  coherence pass (duplicate names, colliding spellings, two variadic
  positionals) and raises with a path into the spec.

## Bundled specs

`specs/` holds grep, rg, cd, ls, curl, sed, find, awk, mv, cp,
launchctl, systemctl, wc, git, and gh — each `#lang racket/base`, requiring
`cli-spec`, providing one `<command>-cli` value, with a header comment
stating the scope and what is deliberately omitted. `specs/all.rkt`
re-exports them all plus the `all-interfaces` list.

## Transforms

`transforms/` holds checked mappings between bundled specs, written in
the external
[`cli-spec-transform`](https://github.com/riz0id/cli-syntax-transformer)
language (also vendored into the `racket-with-rash` layer). A
`define-transformer` form names one spec as source and another as
target and must say what happens to *every* source flag, positional,
and subcommand — mapped, merged, kept, or dropped with a reason — or it
fails to expand; `transform-argv` then rewrites a source invocation
into a target invocation, reporting any dropped item the invocation
used. Both spec modules are required at phases 0 and 1 via the
library's `for-transform` require form (in its own `require`, since a
require transformer cannot be used by the form that imports it):

```racket
(require cli-spec-transform)
(require (for-transform "../specs/grep.rkt" "../specs/rg.rkt"))

(transform-argv grep->rg '("-rn" "--include" "*.py" "todo" "src"))
; ⇒ (xform-ok '("--line-number" "--glob" "*.py" "todo" "src") '())
```

Bundled transforms:

- `transforms/grep-to-rg.rkt` — `grep->rg`, grep invocations onto
  ripgrep. Patterns cross verbatim (no regex-dialect translation);
  grep's filename filters merge into rg globs, `--color`/`--colour`
  collapse onto rg's mandatory-value `--color`, and everything rg does
  by default (`-r`, `-I`, `-d`/`-D`) is an explicit drop.
