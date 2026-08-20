#!/usr/bin/env bash
# Guest-side extensional-equality check for the differential fuzz tests.
# For every manifest row, run the source command and the rewritten target
# command over pristine copies of the case's fixture tree and require
# equal stdout: stage 1 (byte equality) or stage 2 (sorted-line
# multisets, dropping bare `--` group separators) -- stage 2 exists only
# to forgive rg's nondeterministic inter-file output ordering (parallel
# search); file:line: prefixes survive sorting, so the comparison stays
# strong.
#
# Only the output is compared. Exit codes are NOT checked (the tools'
# exit taxonomies legitimately differ -- e.g. sed exits 0 on no match
# where rg exits 1); both codes are still captured and shown in failure
# reports as context.
#
# stderr is never compared (message texts legitimately differ). stdin is
# an empty regular file: a closed or /dev/null stdin flips rg into
# search-the-tree mode and a terminal stdin flips color defaults, so an
# empty regular file is the only stdin under which "same command, same
# inputs" is well-defined for both tools.
#
# There is no seed anywhere, so a failing run cannot be regenerated; the
# failure report is self-contained instead: case id, both commands, both
# exit codes, the output diff, and the case's complete fixture tree with
# file contents inline.
#
# Environment:
#   REPROMPT_FUZZ_CORPUS  corpus directory (cases.tsv + case-*/); required
#   REPROMPT_FUZZ_WORK    scratch workspace root (default: mktemp -d)

set -euo pipefail

corpus="${REPROMPT_FUZZ_CORPUS:?corpus directory required}"
work="${REPROMPT_FUZZ_WORK:-$(mktemp -d)}"
manifest="$corpus/cases.tsv"

[ -f "$manifest" ] || {
  echo "check-cases: no manifest at $manifest" >&2
  exit 2
}

export LC_ALL=C
export TERM=dumb
unset GREP_COLORS GREP_OPTIONS RIPGREP_CONFIG_PATH || true

mkdir -p "$work"
empty="$work/.stdin-empty"
: >"$empty"

# Print a file's contents indented, without relying on non-harness tools.
print_file() {
  local f="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '      | %s\n' "$line"
  done <"$f"
}

report_fixtures() {
  local src="$1"
  (
    cd "$src"
    find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
      if [ -d "$p" ]; then
        printf '    dir  %s/\n' "${p#./}"
      else
        printf '    file %s:\n' "${p#./}"
        print_file "$p"
      fi
    done
  )
}

# Run a command in a pristine copy of the fixture tree; captures stdout
# to $2 and the exit code into REPLY_EXIT.
run_case() {
  local cmd="$1" out="$2" src="$3" ws="$4"
  rm -rf "$ws"
  mkdir -p "$ws"
  cp -R "$src/." "$ws/"
  set +e
  (cd "$ws" && eval "$cmd") <"$empty" >"$out" 2>/dev/null
  REPLY_EXIT=$?
  set -e
}

# Stage-2 normalization: drop bare `--` separator lines, sort.
normalize() {
  # grep exits 1 when everything (or nothing) is filtered; that is not a
  # failure here, and pipefail would otherwise abort the whole run. -a
  # forces text mode: --null-data cases produce NUL-bearing outputs that
  # grep would otherwise reduce to a "binary file matches" line.
  { grep -a -v -x -e '--' "$1" || true; } | LC_ALL=C sort
}

ran=0
fails=0

while IFS=$'\t' read -r id dir scmd tcmd; do
  [ -n "$id" ] || continue
  src="$corpus/$dir"

  run_case "$scmd" "$work/out-src" "$src" "$work/ws"
  s_exit=$REPLY_EXIT
  run_case "$tcmd" "$work/out-tgt" "$src" "$work/ws"
  t_exit=$REPLY_EXIT

  ok=1
  reason=""
  if ! cmp -s "$work/out-src" "$work/out-tgt"; then
    normalize "$work/out-src" >"$work/norm-src"
    normalize "$work/out-tgt" >"$work/norm-tgt"
    if ! cmp -s "$work/norm-src" "$work/norm-tgt"; then
      ok=0
      reason="stdout differs (beyond inter-file ordering)"
    fi
  fi

  if [ "$ok" = 0 ]; then
    fails=$((fails + 1))
    {
      echo "FAIL case $id: $reason"
      echo "  source: $scmd   (exit $s_exit)"
      echo "  target: $tcmd   (exit $t_exit)"
      echo "  --- stdout diff, source vs target ---"
      diff -u --label source "$work/out-src" --label target "$work/out-tgt" || true
      echo "  --- fixture tree ($dir) ---"
      report_fixtures "$src"
    } >&2
  fi
  ran=$((ran + 1))
done <"$manifest"

echo "check-cases: $ran executed, $fails failed"
[ "$fails" = 0 ]
