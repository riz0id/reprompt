---
name: new-command-transform
description: >-
  Author a cli-spec interface specification for a source command and a
  cli-spec-transform mapping it onto an existing target spec, then prove
  the mapping semantics-preserving with the differential fuzz suite. Use
  when asked to add a command transform, rewrite one command onto
  another, or map a command onto an existing specification. The
  arguments are the source command and the target command (the target's
  spec must already exist in cli/specs/).
---

# Author a command transform, spec through green fuzz run

You are mapping a source command onto `cli/specs/<target>.rkt` — a new
`cli/specs/<source>.rkt` if none exists, a new
`cli/transforms/<source>-to-<target>.rkt`, and a fuzz-test registry
entry. **Ground truth is the fuzz test**: it runs the pinned binaries
themselves over a fresh random corpus, so documentation only seeds
drafts and the VM run settles every claim. The process is a loop —
draft, fuzz, classify, fix — and it ends at green, not before.

## 1. Scope the equivalence claim

A transform need not cover the source's whole surface. Decide which
invocations the rewrite claims, by reading the two exemplar kinds:

| claim shape | exemplar |
|---|---|
| whole surface, flag-by-flag | `transforms/grep-to-rg.rkt` |
| one guarded idiom (`#:when`) | `transforms/sed-to-rg.rkt`, `transforms/awk-to-rg.rkt` |

Everything outside the claim must *refuse* (guard miss or raise), never
rewrite approximately — a refused invocation runs unmodified, which is
semantically safe by construction.

## 2. Draft the source spec (a hypothesis, not truth)

Skip if `cli/specs/<source>.rkt` exists; then only re-type it per the
checklist below. Otherwise establish the option surface of the *pinned*
implementation — `nix run nixpkgs#<pkg> -- --help`, `nix shell
nixpkgs#<pkg> -c man <command>` (find attributes with the nixos MCP
server) — knowing the fuzz run will falsify what the docs get wrong:
the sed `-a` precedent was a BSD-only flag the spec carried until the
corpus made GNU sed exit 1 on thirty cases.

Module shape: `#lang racket/base`,
`(require (prefix-in cli: cli-spec))`, `(provide <source>-cli)`, one
`(cli:cmd '<source> ...)`, a header comment stating scope and
deliberate omissions. The load-bearing conventions
(`cli/README.md` "Writing a spec" is the reference):

- **Omit, never guess.** An option whose value-taking behavior differs
  between implementations is left out so invocations using it reject
  and run as the real command.
- **One head per command**; ids kebab-case from the long alias, aliases
  explicit short-then-long, pipe-quoted when they read as numbers
  (`|-i|`, `|-0|`); declaration order is canonical order.
- **Types are informative, never lazily `'string`.** Patterns are
  `'regex`, operand paths `'path`, script files `'file`, counts `'nat`,
  filename filters `'glob`, every enumerated vocabulary a `cli:enum`.
  Typed items reject bad values at parse and drive the fuzz generator's
  typed invocation sampling. A value language of its own (sed scripts,
  awk programs) gets a `cli:custom` type — see `sed-script` in
  `specs/sed.rkt` and `awk-program` in `specs/awk.rkt`.
- `#:repeat 'list` where repetition accumulates; `#:arity '?` only for
  genuinely omissible, attached-only values; at most one variadic
  operand slot per level, nothing required after it.

Register it: `specs/all.rkt` (require, provide, `all-interfaces`) and
the bundled-interfaces lists in `cli/README.md` and
`src/reprompt/transformers/README.md`.

## 3. Divergence analysis before any clause

For the pairing, enumerate every way the two commands' *observable
output* can differ inside the claimed domain. Each divergence class has
exactly one correct lever; choosing levers is the whole design:

| divergence class | lever |
|---|---|
| flag whose presence leaves the claim (`-e`/`-f`/`-i`; awk `-v`, which can reset `RS`/`ORS`) | `#:when` guard exclusion — the invocation stays the source command |
| value-dependent condition: script shape, pattern dialect, a filesystem fact (an operand that is a directory; gawk's fatal abort on unopenable operands) | raising `#:value` function — raise means not-rewritable; the transform is arbitrary Racket and may inspect the filesystem at the moment the rewrite runs |
| target default differing from source behavior (rg's `file:` prefixes, recursion into directories, ignore rules) | `emit` a target flag that restores source-shaped output (`(emit (flag 'no-filename))`), or refuse when no flag restores it |
| regex/pattern dialect gaps | admission scanner in the `#:value`: patterns cross **verbatim, never translated**; admit only the dialect-neutral subset — copy `check-dialect-neutral` (BRE source, `sed-to-rg.rkt`) or `check-ere-neutral` (ERE source, `awk-to-rg.rkt`) and adjust |
| byte-framing with no restoring flag (sed `-z` vs `--null-data`) | guard exclusion |
| exit-code taxonomies | nothing — the suite compares stdout only |
| flag provably unable to change output in-domain (`-u`, `--posix`, awk `-F` when no fields are read) | `drop` with a reason — and note a drop still rewrites: the reason string is itself a semantic claim the fuzzer tests |

## 4. Write the transform

`cli/transforms/<source>-to-<target>.rkt`: `#lang racket/base`,
`(require cli-spec-transform)`,
`(require (for-transform "../specs/<source>.rkt" "../specs/<target>.rkt"))`
(its own `require` — a require transformer cannot be used by the form
importing it), `(provide <source>-><target>)`, helpers, then
`define-transformer`. The macro enforces totality: every source flag,
positional, rest clause, and subcommand is mapped (`(flag x => (flag
'y))`), kept, merged, dropped with a reason, or named by the guard —
or expansion fails. `emit` produces target-only constants and counts
toward the target's required surface. The header comment states the
claimed domain and every narrowing, in the style of `sed-to-rg.rkt`.

## 5. Wire the fuzz test

- Custom type in the spec ⇒ add its generator beside `gen-sed-script`
  in `tests/fuzz/gen-corpus.rkt` and register it in `custom-gens`:
  mostly the claimed shape with witnesses (`cli:random-regex` for
  embedded regexes, `/` escaped `\/`), a minority of must-reject shapes
  so refusal stays exercised. One hash serves all transforms.
- One `fuzzTests` entry in `flake.nix` — transform path, id, `tools =
  pkgs: [ pkgs.<source-pkg> pkgs.ripgrep-or-target ]`, `count = 300` —
  fans out into the check, the `fuzz-test-<name>` app, and the darwin
  builder path automatically.
- `git add` new files or no flake build can see them.
- Cheap sanity before the VM: probe `transform-argv` with the vendored
  `./result/bin/racket` once per branch — each accepted shape, each
  refusal, each guard miss. Probes are a smoke check, not the arbiter.

## 6. Fuzz to green — the arbiter

```
nix run .#fuzz-test-<name>
```

Fresh system-entropy corpus every run, real binaries in a network-less
VM, stdout equality (byte-equal, or sorted-line multisets forgiving only
rg-style inter-file ordering). Generation materializes each case's
fixture tree *before* translating, and translates from inside it, so
filesystem-inspecting `#:value` refusals see exactly the tree the
commands will run over.

On red, classify every failure and apply the matching fix — the
classification is the decision procedure:

- source command exiting "invalid option" with empty stdout on some
  flag ⇒ **spec bug**: the spec described an option the pinned binary
  does not have. Fix the spec (the `-a` precedent).
- stdout divergence on accepted rewrites ⇒ **transform domain defect**:
  return to the step-3 table and apply that class's lever. The sed->rg
  history is the worked example: `file:` prefixes ⇒ `emit
  --no-filename`; directory operands ⇒ raising `#:value`; dialect
  patterns ⇒ admission scanner; `-z` framing ⇒ guard.
- **Never** weaken the checker, pin a seed, or hand-pick a passing
  corpus — locked cases reduce fuzzing to unit tests and the claim to
  an assertion.

Watch liveness: draws-per-accepted-case against the 200×count budget.
Exhaustion means the domain admits almost nothing the spec can express
— the claim itself needs rethinking, not the budget.

Repeat until `N executed, 0 failed` / `PASS`. Green is the definition
of done: a transform without a passing fuzz run has an unsettled
semantics claim and does not ship.
