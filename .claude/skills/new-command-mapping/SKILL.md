---
name: new-command-mapping
description: >-
  Define a specification mapping between the command-line interface
  specifications of two commands (cli/mappings/<src>-<tgt>.rkt), wire
  its dedicated VM fuzz test, and iterate until the fuzz tests pass.
  Use when asked to add a command mapping, an inter-interface
  specification, or a syntax-transformer translation between two
  commands. The arguments are the source and target command names.
---

# Define a specification mapping between two command interfaces

You are creating the mapping `$ARGUMENTS` in
`src/reprompt/transformers/cli/mappings/`, plus its dedicated VM fuzz
test. **The mapping is not complete until the mapping specification
exists and its VM fuzz tests pass** — see the completion criterion at
the end; do not report success before it is met.

## 1. Prerequisites

Both per-command interface specifications must exist in `cli/specs/`.
If either is missing, run the `new-command-interface` skill for it
first. Identify the nixpkgs packages providing the two real tools —
the equivalence oracle runs them in the guest VM.

## 2. Read the model and the exemplar

- `src/reprompt/transformers/cli/MAPPING-PLAN.md` — the formal model:
  what the constructor checks enforce (the mapping is surjective on its
  domain up to declared `identify` equivalences: disjoint claims and
  emissions, value witnesses, the measure-decrease check on
  identifies), and what only fuzzing can check (the semantic truth of
  every declared equivalence and claimed rule).
- `cli/README.md`, the command-mappings section — clause forms and the
  test standard.
- `cli/mappings/grep-rg.rkt` — the exemplar: identifies as owned
  semantic assertions, `same`/`rename`/`split` clauses, and a domain
  predicate whose every condition carries a comment naming the
  divergence it excludes.

## 3. Author `cli/mappings/<src>-<tgt>.rkt`

- Domain predicates are defined *before* the `define-command-mapping`
  form (`#:domain` is evaluated at definition time).
- `#:from`/`#:to` name the two interface values; `#:heads` maps the
  surviving head names; clauses relate keyword ids only — concrete
  spellings never appear in a mapping.
- `identify` clauses declare source-side equivalences (head aliases,
  spelling synonyms, bare-value defaults, arguments the target's
  defaults absorb). Each must strictly decrease the measure — the
  interface specs' declaration order is what makes that check pass, so
  a failing measure check usually means the identify is written in the
  wrong direction.
- `same`/`rename` relabel ids; `value ... #:forward g #:witness g-inv`
  transforms values (the witness is mandatory — it is the clause's
  correctness obligation, re-checked per translated value at runtime);
  `split` distributes one source id across several target ids.
- **Start narrow.** Claim only what you can defend; partiality is the
  tool for everything else — an unclaimed id or a domain condition
  means the original command runs unmodified, which is always correct.
  Known divergence classes to check against the exemplar before the
  first fuzz run: stdin behavior and labels, exit-code conventions,
  default file filtering, output-mode precedence, colored output,
  regex/value dialects, options applied differently to explicit versus
  traversed paths.
- The constructor raises on any violated check; fix at definition time
  until the module compiles
  (`nix build .#racket-with-rash`, then `racket -e '(require (file
  ".../cli/mappings/<src>-<tgt>.rkt"))'`).

## 4. Wire the dedicated VM test

One registry entry in `flake.nix`:

```nix
fuzzTests = {
  <src>-<tgt> = {
    mappingModule = "cli/mappings/<src>-<tgt>.rkt";
    mappingId = "<src>-><tgt>";
    guestPackages = pkgs: [ pkgs.<srcPkg> pkgs.<tgtPkg> ];
    count = 500;
  };
};
```

That entry generates `checks.<system>.fuzz-<src>-<tgt>`,
`fuzzGuests.<src>-<tgt>`, and `apps.<system>.fuzz-test-<src>-<tgt>`
via `tests/fuzz-vm.nix` — no test code is written; the test derives
from the mapping and its source interface spec. `git add` every new
file: the git flake only sees tracked or staged files.

## 5. Fuzz, triage, repeat — trial and error is the method

Run the dedicated VM test: `nix run .#fuzz-test-<src>-<tgt>`. Runs are
seedless-random; every failure report is self-contained (both
commands, both exit codes, the diff, and the corpus file contents
inline) — triage from the report alone.

For each failure, the fix is a **hand edit to the mapping, never to
the test**:

- a wrong `identify` (the declared equivalence is semantically false)
  → fix or remove the clause;
- an over-claimed behavior → narrow the domain predicate (with a
  comment naming the divergence) or unclaim the id;
- a value transform breaking its witness → fix the forward/witness
  pair.

You may not weaken the generator or the oracle to make a mapping pass;
the shared test infrastructure changes only for defects that affect
every mapping, and only with evidence the divergence is test-induced
rather than real. After each fix, re-run. Expect several rounds — the
grep→rg mapping took multiple fuzz-fix cycles, and each surviving
domain condition is one of its findings.

## 6. Completion criterion — all three, or it is not done

1. The mapping module compiles with every constructor check passing.
2. The `fuzzTests` entry exists and the generated check/app evaluate.
3. **At least two consecutive VM fuzz runs pass with zero failures
   under fresh randomness.**

Until all three hold, the task is in progress: report the remaining
failures and the triage state, never a completed mapping. When they
hold, summarize the claimed domain, every domain condition with the
divergence it excludes, and the final run results; leave committing to
the user unless asked.
