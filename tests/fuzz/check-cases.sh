#!/usr/bin/env bash
# Extensional-equivalence oracle for the grep->rg fuzz cases.
#
# Reads the manifest produced by gen-cases.rkt (REPROMPT_FUZZ_OUT/cases.tsv)
# and, for every translated case, runs the grep command and the rg command
# in the corpus directory of the case under LC_ALL=C, comparing stdout and
# exit code. sortable=1 rows (multi-file / recursive) compare the sorted
# line sequences -- rg parallelizes across files, so only the line multiset
# is deterministic; everything else compares byte-for-byte. stderr is not
# compared (message texts legitimately differ); the error class is compared
# through the exit code (0 match, 1 no match, 2 error). REJECT rows were
# already asserted at generation time and only get counted.
#
# On mismatch: print the case, both commands, both exit codes, and the
# diff, and fail the run. Every case is reproducible from the seed in
# REPROMPT_FUZZ_OUT/SEED plus the case id.

set -euo pipefail

out="${REPROMPT_FUZZ_OUT:?set REPROMPT_FUZZ_OUT to the gen-cases.rkt --out directory}"
manifest="$out/cases.tsv"
[ -f "$manifest" ] || {
  echo "no manifest at $manifest" >&2
  exit 2
}
seed=$(cat "$out/SEED")

ran=0
rejects=0
fails=0

while IFS=$'\t' read -r id corpus sortable gcmd rcmd; do
  [ -n "$id" ] || continue
  if [ "$rcmd" = "REJECT" ]; then
    rejects=$((rejects + 1))
    continue
  fi
  dir="$out/$corpus"

  set +e
  gout=$(cd "$dir" && LC_ALL=C bash -c "$gcmd" 2>/dev/null)
  gst=$?
  rout=$(cd "$dir" && LC_ALL=C bash -c "$rcmd" 2>/dev/null)
  rst=$?
  set -e

  if [ "$sortable" = 1 ]; then
    gcmp=$(printf '%s' "$gout" | LC_ALL=C sort)
    rcmp=$(printf '%s' "$rout" | LC_ALL=C sort)
  else
    gcmp=$gout
    rcmp=$rout
  fi

  if [ "$gst" != "$rst" ] || [ "$gcmp" != "$rcmp" ]; then
    echo "FAIL case $id (corpus $corpus, seed $seed)"
    echo "  grep: $gcmd  [exit $gst]"
    echo "  rg:   $rcmd  [exit $rst]"
    diff <(printf '%s\n' "$gcmp") <(printf '%s\n' "$rcmp") || true
    fails=$((fails + 1))
  fi
  ran=$((ran + 1))
done <"$manifest"

echo "check-cases: $ran executed, $rejects rejected, $fails failed"
[ "$fails" = 0 ]
