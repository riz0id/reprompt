# cli — command interfaces for syntax transformers

A library for writing **command interfaces**: declarative Racket
specifications of a bash command's CLI. An interface drives three things a
transformer needs — parsing an intercepted command's words into a structured
invocation, querying and editing that structure, and rendering it back to a
faithful command string. The library's scope is only command interfaces;
transformer plumbing (argv, exit codes) stays in the transformer scripts.

Transformers require `cli/main.rkt` plus the specs they use:

```racket
(require "cli/main.rkt" "cli/specs/grep.rkt")

(define registry (make-spec-registry (list grep-cli)))
(transform-line command registry
                (lambda (spec inv)
                  (and (invocation-has-flag? inv 'recursive)
                       (invocation-set-head (invocation-remove-flag inv 'recursive)
                                            "rg"))))
;; -> the rewritten command string, or #f when nothing changed or the
;;    line was rejected
```

## Writing an interface

Interfaces are authored in the external
[`cli-spec`](https://github.com/riz0id/cli-syntax) language and lowered
into this library's internal model by `command->interface` (`lower.rkt`):

```racket
(require (prefix-in cli: cli-spec) "cli/main.rkt")

(define grep-cli
  (command->interface
   (cli:cmd 'grep
     (cli:flag 'recursive #:aliases '(-r --recursive))       ; switch, clusterable
     (cli:flag 'pattern 'string #:aliases '(-e --regexp)
               #:repeat 'list)                               ; valued, repeatable
     (cli:flag 'color (cli:enum "never" "auto" "always")     ; enumerated value
               #:aliases '(--color) #:arity '?)              ; value optional, attached only
     (cli:arg 'args 'string #:arity '*)                      ; operands: 1 | '? | '*
     (cli:subcommand 'restart                                ; systemctl-style
       (cli:arg 'units 'string #:arity '*)))))
```

The lowering accepts the subset of `cli-spec` the transformers give
semantics to and raises on anything outside it (see `lower.rkt`'s header
for the full table):

- A command has **one head**: `(cli:cmd 'grep ...)` describes `grep` and
  nothing else — a command's head uniquely identifies it, so `egrep` or
  `gawk` would be commands (and specs) of their own.
- A `cli:flag` with no type is a boolean switch; with a type it takes a
  value. Only `'string` and `cli:enum` types lower; `#:repeat 'list`
  marks a repeatable option; `#:arity '?` makes the value optional, and
  an optional value never consumes the next word (`--color=x` / `-i.bak`
  attached forms only).
- Aliases are given explicitly as symbols and keep their declared order
  (edited arguments render as the first long alias, else the first
  short). `-x` is a short alias (clusterable, attachable value), `--xxx`
  a long one; `cli-spec` admits no other shape, so literal-alias dialects
  like find's `-name`/`!` are out of scope.
- Operand slots are filled in declared order; at most one slot may be
  variadic, and a single `'*` slot absorbs the surplus words. There are
  no operand guards: when which-word-is-which depends on the flags
  present (grep's pattern vs. its first file), the spec declares one
  slot and let the consumer draw the boundary over the slot's words.
- `cli:subcommand` nests to any depth (`gh issue list`), may carry
  `#:aliases` (gh's `ls`, which parses verbatim but names the canonical
  path), and the enclosing interfaces' flags and options stay matchable
  after the subcommand words.
- Spec mistakes are caught at construction: `cli:cmd` runs `cli-spec`'s
  coherence pass (duplicate names, colliding spellings, two variadic
  positionals), and the lowering rejects every construct it cannot give
  faithful semantics to.

Bundled interfaces live in `specs/` — grep, rg, cd, ls, curl, sed,
awk, launchctl, systemctl, wc, git, gh — with `specs/all.rkt` providing
`all-interfaces` and a ready-made `default-registry`. They stress the
model: nested subcommands (gh), subcommands with top-level globals
(systemctl), attached-only optional values (sed `-i`), enumerated values
(grep `--color`), and heavily repeatable options (curl).

## Guarantees

- **Reject, never corrupt.** Every parsing layer returns a `reject` value
  instead of guessing. A transformer maps rejection to a non-zero exit, so
  the original command is preserved whenever the library is not certain it
  can reproduce the command faithfully.
- **Verbatim fidelity.** Each parsed word carries its exact source
  substring; untouched arguments render byte-for-byte (`007` stays `007`),
  and a structural coverage check over source locations rejects any line the
  linea reader silently truncated or rewrote. Only synthesized or edited
  arguments render canonically (first long alias, else first short).
- **Unknown arguments reject by default.** An unknown `-x` might consume
  the word after it — the exact ambiguity that corrupts commands. The
  `'permissive` policy passes through nothing but self-contained `--x=v`
  words.
- Pipelines (`|`), connector chains (`&&`, `||`), a trailing `&`, and
  redirects (`> f`, `>out`, `2>&1`) are handled around the specs:
  transformers see per-stage argument words, and redirects re-attach on
  render (after the stage's arguments, original relative order preserved).

## Known-reject constructs

The linea reader mangles some shell syntax silently, so the safe reader
refuses it up front; commands containing these are left unrewritten:

| construct | reason |
|---|---|
| `'single quotes'`, `` `backticks` `` | read as Racket quote forms that can swallow following words |
| `;` | comments out the rest of the line |
| `\` (outside `\"`/`\\` in strings) | escapes are consumed by the reader |
| `(` `)` `[` `]` `{` `}` `«` `»` | become nested structure, not words |
| `$(...)`, `${...}` | split into `$` + structure (bare `$VAR` is fine) |
| `#` | datum syntax or a read error |
| embedded newlines | only one line is read |
| `a & b` | `&` separates commands (a trailing `&` is fine) |

Practical consequences: single-quoted awk/sed
programs always reject (safely — the command runs unmodified); double-quoted
arguments, `$VAR`, globs, and URLs all round-trip.

## Modules

| module | provides |
|---|---|
| `words.rkt` | `safe-read-line`, `word`/`reject` structs, `text->word`, `render-words` |
| `line.rkt` | `parse-line`, `render-line`, `stage`/`pipeline`/`cmd-line`, `stage-head`, `map-stages` |
| `spec.rkt` | internal interface structs, runtime constructors and validation, `make-spec-registry` |
| `lower.rkt` | `command->interface` — lowers a `cli-spec` command into the internal model |
| `parse.rkt` | `parse-invocation`, arg structs, invocation queries (`invocation-has-flag?`, ...) |
| `invocation.rkt` | edits (`invocation-set-head`, `-add/remove/set-option`, `-rename-arg`) and `render-invocation` |
| `toolcall.rkt` | `parse-bash-envelope`, `render-bash-call`, `render-mcp-call` |
| `main.rkt` | facade re-exporting all of the above plus `transform-line` |
