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
    (cli:flag 'regexp 'regex #:aliases '(-e --regexp)
              #:repeat 'list)                               ; valued, repeatable
    (cli:flag 'color (cli:enum "never" "auto" "always")     ; enumerated value
              #:aliases '(--color) #:arity '?)              ; value optional, attached only
    (cli:arg 'pattern 'regex)                               ; operands: 1 | '? | '*
    (cli:arg 'files 'path #:arity '*)
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
- **Types are informative, not just `'string`.** cli-spec's atom
  vocabulary (`'regex`, `'path`, `'file`, `'dir`, `'glob`, `'nat`, ...)
  is used wherever it applies: patterns are `'regex`, operand paths are
  `'path`, context counts are `'nat`. Typed items reject bad values at
  parse (`grep -A banana` fails) and drive the fuzz suite's typed
  invocation generation (below). A value language of its own gets a
  `cli:custom` type — sed scripts are `'sed-script` in `sed.rkt`.
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

`grep.rkt` and `rg.rkt` name their operand roles as separate slots —
a required `pattern` then variadic `files`/`paths` — matching the
`CMD PATTERN [FILE...]` grammar, so transforms map into each role by
name and rendering order follows declaration order. When `-e`/`-f`
supplies the pattern the first file word fills the required slot
instead (a boundary guardless positionals cannot draw), but word
order is preserved either way, so rendering stays verbatim.

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
; ⇒ (xform-ok rg-cli '("--line-number" "--glob" "*.py" "todo" "src") '())
```

Bundled transforms:

- `transforms/grep-to-rg.rkt` — `grep->rg`, grep invocations onto
  ripgrep. Patterns cross verbatim (no regex-dialect translation);
  grep's filename filters merge into rg globs, `--color`/`--colour`
  collapse onto rg's mandatory-value `--color`, and everything rg does
  by default (`-r`, `-I`, `-d`/`-D`) is an explicit drop.
- `transforms/sed-to-rg.rkt` — `sed->rg`, the `sed -n '/pattern/p'`
  print-matching-lines idiom onto ripgrep. A `#:when` pattern guard
  admits only quiet-mode invocations with no `-e`/`-f`/`-i` and no
  `-z` (sed `-z` and rg `--null-data` frame NUL-separated output
  differently at the byte level), and requires at least one file
  operand — anything else is `xform-unmatched`. Two `#:value`
  functions narrow further at rewrite time, raising (treated as
  not-rewritable) when: the script is not exactly a `/regexp/p` print
  program whose pattern is dialect-neutral — identical meaning in GNU
  BRE, GNU ERE, POSIX mode, and rg's engine, since patterns cross
  verbatim with no dialect translation; or a file operand is a
  directory on the filesystem when the rewrite runs — sed read-errors
  there where rg recurses. Every rewrite carries `--no-filename` (an
  `emit` clause — cli-spec-transform's target-only-constant form):
  sed prints bare matched lines, and rg would otherwise prefix
  `file:` when given several paths.

## Differential fuzzing

Every transform claims semantic preservation: a rewritten command must
behave exactly like the original. The fuzz suite tests that claim
extensionally, per transform, inside a dedicated QEMU/NixOS VM
containing only the two real tools:

```
nix run .#fuzz-test-grep     # grep ~ (grep->rg grep)
nix run .#fuzz-test-sed      # sed  ~ (sed->rg sed)
```

1. **Generate** (host): `tests/fuzz/gen-corpus.rkt` samples random
   invocations of the source command from its spec via cli-spec's
   `random-invocation` interpretation — typed values from the declared
   types, path draws materializing fixture files/directories (or
   deliberately dangling), regex draws carrying witness strings that
   seed file contents. Each draw's fixture tree is materialized first
   and the transform then runs from inside it, so rewrite-time
   filesystem checks observe exactly the tree the commands will run
   over. The transform itself is the only domain oracle: refused draws
   (`xform-unmatched`, parse errors, raising `#:value` functions) are
   discarded — their fixture tree scrapped — and redrawn, so every
   corpus case is an equivalence case; accepted draws with drop
   warnings stay — each `(drop "reason")` is a semantic claim under
   test.
2. **Isolate**: the corpus is copied into a network-less guest VM whose
   packages are the source tool, the target tool, and the checker's
   shell utilities. Nothing else crosses the boundary.
3. **Check**: `tests/fuzz/check-cases.sh` runs both commands per case
   over pristine fixture copies with an empty-regular-file stdin and
   pinned environment, requiring equal stdout — byte-equal, or
   sorted-line multisets that forgive only rg's nondeterministic
   inter-file output ordering. Only the output is compared: exit codes
   are not checked (the tools' exit taxonomies legitimately differ —
   sed exits 0 on no match where rg exits 1), though both are shown in
   failure reports as context.

**There are no seeds.** The generator seeds from system entropy on
every run and records nothing; each run explores new cases, so this is
fuzzing rather than replayed unit cases. Failures cannot be
regenerated — every report is self-contained instead (both commands,
both exit codes, output diff, and the case's fixture tree with
contents inline), and the runner keeps the corpus directory on
failure. A red run is a real finding: either the transform's domain
must narrow (a `#:when` guard, or a raising `#:value`/`#:by` function
for value-dependent restrictions) or the divergence is documented and
the transform withdrawn.

Adding a transform's fuzz test is one entry in the `fuzzTests`
registry in `flake.nix`: the transform module and id, the two guest
tools, and a case count.
