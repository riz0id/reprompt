#!/usr/bin/env bash
# Host-side assertions for the rewrite integration test: the host proxy's
# Racket/Rash syntax transformer replaced `touch <observed>` with
# `touch <hidden>`; hidden originated inside the proxy and never existed
# guest-ward beforehand. Also checks that `reprompt lift` emits the
# executed (rewritten) command and that the lifted module replays it under
# racket-with-rash. Invoked by tests/run.sh as: assert_rewrite.sh
# <artifact_dir>. Exits non-zero on failure after printing diagnostics;
# run.sh then keeps the artifact directory.

set -euo pipefail

artifact_dir="$1"
record_file="$artifact_dir/record.jsonl"
observed_file="$artifact_dir/observed"
module_file="$artifact_dir/lifted.rkt"
work="$artifact_dir/work"

log() { printf '\033[1m[assert-rewrite]\033[0m %s\n' "$*" >&2; }
fail() {
  printf '\033[1;31m[assert-rewrite] error:\033[0m %s\n' "$*" >&2
  if [ -f "$record_file" ]; then
    log "recorded calls:"
    cat "$record_file" >&2
  fi
  if [ -f "$module_file" ]; then
    log "lifted module:"
    cat "$module_file" >&2
  fi
  exit 1
}

[ -f "$record_file" ] || fail "the proxy recorded no calls"
[ -f "$observed_file" ] || fail "the observed file was not written by run.sh"
observed=$(cat "$observed_file")
[ -n "$observed" ] || fail "observed is empty"

# The intercepted Bash call whose rewrite executed a touch command.
executed=$(jq -r -s '
  [ .[]
    | select(.tool == "Bash" and (.rewrite != null))
    | .rewrite.rewritten_body.arguments.command
    | select(startswith("touch ")) ]
  | .[0] // empty' "$record_file")
[ -n "$executed" ] || fail "no rewritten touch command was recorded"
hidden=${executed#touch }
[ -n "$hidden" ] || fail "hidden is empty"
[ "$hidden" != "$observed" ] || fail "hidden equals observed ($hidden)"

# The original (model-issued) command targeted observed, not hidden.
original=$(jq -r -s '
  [ .[]
    | select(.tool == "Bash" and (.rewrite != null))
    | .rewrite.original_body.arguments.command ]
  | .[0] // empty' "$record_file")
case "$original" in
  *"$observed"*) : ;;
  *) fail "original command '$original' does not mention observed $observed" ;;
esac

# The executed touch created work/<hidden> and NOT work/<observed>.
[ -f "$work/$hidden" ] ||
  fail "work/$hidden was not created (the rewrite did not execute)"
[ ! -e "$work/$observed" ] ||
  fail "work/$observed exists (the observed command ran unrewritten)"

# reprompt lift emits the executed command, not the observed one.
"$REPROMPT_BIN" lift "$record_file" -o "$module_file" ||
  fail "reprompt lift failed on $record_file"
grep -F "touch $hidden" "$module_file" >/dev/null ||
  fail "the lifted module lacks the executed command touch $hidden"
if grep -F "$observed" "$module_file" >/dev/null; then
  fail "the lifted module leaks the observed number $observed"
fi

# The lifted module runs under rash and creates <hidden> in a fresh cwd.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/reprompt-rewrite-lift.XXXXXX")
(cd "$scratch" && HOME="$artifact_dir" racket "$module_file") ||
  fail "racket failed to execute the lifted module"
[ -f "$scratch/$hidden" ] ||
  fail "running the module did not create $hidden in the scratch dir"
rm -rf "$scratch"

log "PASS: the proxy rewrote touch $observed into touch $hidden and lift \
replays the executed command"
