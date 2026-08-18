#!/usr/bin/env bash
# Extensional-equivalence oracle for spec-derived fuzz cases.
#
# Reads the manifest produced by gen-cases.rkt (REPROMPT_FUZZ_OUT/cases.tsv)
# and, for every translated case, runs the source command and the target
# command in the corpus directory of the case under LC_ALL=C. The check is
# two-stage, applied identically to every row:
#
#   1. exit codes must match exactly (0 match, 1 no match, 2 error);
#   2. stdout must be byte-equal, or else equal as sorted line multisets
#      after dropping bare -- group-separator lines.
#
# Stage 2 is the declared observational normalization: the target tool may
# parallelize across files, so cross-file interleaving is expected
# nondeterminism, and group-separator placement is order-dependent;
# content lines keep their file/line prefixes, so the multiset comparison
# stays strong. Single-file outputs virtually always match at stage 1,
# where ordering is genuinely deterministic and genuinely checked. stderr
# is never compared (message texts legitimately differ). REJECT rows only
# get counted: an untranslated command runs unmodified.
#
# There is no seed, so a failing run cannot be regenerated; every failure
# report is self-contained instead: the case id, both commands, both exit
# codes, the diff, and the complete contents of the corpus directory of
# the case. Recreating those files and running both printed commands
# reproduces the divergence by hand. Uses bash and coreutils only.

set -euo pipefail

out="${REPROMPT_FUZZ_OUT:?set REPROMPT_FUZZ_OUT to the gen-cases.rkt --out directory}"
manifest="$out/cases.tsv"
[ -f "$manifest" ] || {
  echo "no manifest at $manifest" >&2
  exit 2
}

strip_separators() {
  # Drop bare -- group-separator lines; bash-only so the guest needs no
  # extra tools. The || guard keeps the final line when the input does
  # not end in a newline (command substitution strips it).
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "--" ] || printf '%s\n' "$line"
  done
}

dump_tree() {
  # Recursive corpus dump without globstar (absent from older bash).
  local p line
  for p in "$1"/* "$1"/.[!.]*; do
    [ -e "$p" ] || continue
    if [ -d "$p" ]; then
      dump_tree "$p" "$2"
    elif [ -f "$p" ]; then
      printf -- '----- corpus file: %s -----\n' "${p#"$2"/}"
      while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line"
      done <"$p"
    fi
  done
}

dump_corpus() {
  # Print every file of a corpus directory inline, so the failure report
  # alone reproduces the run.
  dump_tree "$1" "$1"
  printf -- '----- end of corpus -----\n'
}

# stdin for executed commands is an empty regular file, not /dev/null: a
# command without file operands must not read this loop's manifest from
# inherited stdin, and some target tools treat a null-device stdin as "no
# input at all" and fall back to searching the working directory, where a
# regular file at EOF is read as empty input by both sides -- the
# pipeline-at-end-of-input environment the equivalence is declared over.
empty="$out/.stdin-empty"
: >"$empty"

ran=0
rejects=0
fails=0

while IFS=$'\t' read -r id corpus gcmd rcmd; do
  [ -n "$id" ] || continue
  if [ "$rcmd" = "REJECT" ]; then
    rejects=$((rejects + 1))
    continue
  fi
  dir="$out/$corpus"

  set +e
  gout=$(cd "$dir" && LC_ALL=C bash -c "$gcmd" <"$empty" 2>/dev/null)
  gst=$?
  rout=$(cd "$dir" && LC_ALL=C bash -c "$rcmd" <"$empty" 2>/dev/null)
  rst=$?
  set -e

  ok=1
  if [ "$gst" != "$rst" ]; then
    ok=0
  elif [ "$gout" != "$rout" ]; then
    gnorm=$(printf '%s' "$gout" | strip_separators | LC_ALL=C sort)
    rnorm=$(printf '%s' "$rout" | strip_separators | LC_ALL=C sort)
    [ "$gnorm" = "$rnorm" ] || ok=0
  fi

  if [ "$ok" = 0 ]; then
    echo "FAIL case $id (corpus $corpus)"
    echo "  source: $gcmd  [exit $gst]"
    echo "  target: $rcmd  [exit $rst]"
    diff <(printf '%s\n' "$gout") <(printf '%s\n' "$rout") || true
    dump_corpus "$dir"
    fails=$((fails + 1))
  fi
  ran=$((ran + 1))
done <"$manifest"

echo "check-cases: $ran executed, $rejects rejected, $fails failed"
[ "$fails" = 0 ]
