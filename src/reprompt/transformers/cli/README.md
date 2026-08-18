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

```racket
(define-command-interface grep-cli
  #:names ("grep" "egrep" "fgrep")
  #:unknown 'reject                                ; the default
  (flag recursive "-r" "--recursive")              ; boolean, clusterable
  (option pattern "-e" "--regexp" #:repeatable)    ; takes a value
  (option color "--color" #:optional-value)        ; value only as --color=x
  (option in-place "-i" #:optional-value #:attached-only)  ; sed -i.bak
  (operand pattern-operand #:arity one             ; one | optional | many
           #:unless (lambda (inv) (invocation-has-option? inv 'pattern)))
  (operand files #:arity many)
  (subcommand "restart" (operand units #:arity many)))  ; systemctl-style
```

- Aliases are classified by shape: `-x` is a **short** alias (clusterable:
  `-rn`, attachable value: `-C3`), `--xxx` a **long** alias (value separate
  or `=`-attached), and anything else — `-name`, `-print`, `!` — a
  **literal** alias matched only as a whole word, before any cluster
  decomposition.
- Operand slots are filled in declared order; a single `many` slot absorbs
  the surplus, so `(operand sources #:arity many) (operand dest #:arity one)`
  back-anchors `mv SRC... DEST`. A `#:when`/`#:unless` predicate over the
  invocation-so-far activates or deactivates a slot (grep's pattern operand
  is absent when `-e` supplied one).
- Subcommands nest an interface per subcommand word; the enclosing
  interface's flags and options stay matchable on both sides of it.
- Spec mistakes (duplicate ids, alias collisions, two `many` operands) are
  syntax errors at the offending clause.

Bundled interfaces live in `specs/` — grep, rg, cd, ls, curl, sed, find,
awk, mv, cp, launchctl, systemctl — with `specs/all.rkt` providing
`all-interfaces` and a ready-made `default-registry`. The twelve were chosen
to stress the model: subcommands (systemctl, launchctl), literal primaries
and operators (find), attached-only optional values (sed `-i`),
back-anchored operands (mv, cp), guarded operands (grep, sed, awk), and
heavily repeatable options (curl).

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

Practical consequences: `find ... -exec cmd {} \;` and single-quoted awk/sed
programs always reject (safely — the command runs unmodified); double-quoted
arguments, `$VAR`, globs, and URLs all round-trip.

## Command mappings

A second specification language, `define-command-mapping`, declares how
invocations of one interface translate to equivalent invocations of
another — one-directional, partial (anything unclaimed rejects the
stage), and injective on its domain up to declared source-side
equivalences. `identify` clauses canonicalize the source invocation
first (`fgrep` ≡ `grep -F`, a bare `--color` ≡ `--color=auto`); `same`,
`rename`, `value`, and `split` clauses then relabel each remaining
argument into the target interface, preserving multiplicity and values;
and the rendered result must re-parse against the target interface or
the stage rejects. See `MAPPING-PLAN.md` for the formal model (the
injectivity theorem and the checks that enforce it) and
`mappings/grep-rg.rkt` for the first instance:

```racket
(require "cli/main.rkt" "cli/specs/grep.rkt" "cli/mappings/grep-rg.rkt")

(define registry (make-spec-registry (list grep-cli)))
(transform-line command registry (mapping->transformer grep->rg))
```

## Modules

| module | provides |
|---|---|
| `words.rkt` | `safe-read-line`, `word`/`reject` structs, `text->word`, `render-words` |
| `line.rkt` | `parse-line`, `render-line`, `stage`/`pipeline`/`cmd-line`, `stage-head`, `map-stages` |
| `spec.rkt` | interface structs, runtime constructors and validation, `make-spec-registry` |
| `parse.rkt` | `parse-invocation`, arg structs, invocation queries (`invocation-has-flag?`, ...) |
| `invocation.rkt` | edits (`invocation-set-head`, `-add/remove/set-option`, `-rename-arg`) and `render-invocation` |
| `dsl.rkt` | `define-command-interface` |
| `mapping.rkt` | `make-command-mapping`, `mapping-forward`, `mapping->transformer` |
| `mapping-dsl.rkt` | `define-command-mapping` |
| `main.rkt` | facade re-exporting all of the above plus `transform-line` |
