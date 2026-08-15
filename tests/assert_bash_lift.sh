#!/usr/bin/env bash
# Host-side assertions for the bash-lift integration test: first the base
# bash-metadata assertions, then `reprompt lift` turns record.jsonl into a
# #lang rash module that contains exactly the Bash commands and actually
# runs under racket (racket-with-rash on PATH via the flake app).
# Invoked by tests/run.sh as: assert_bash_lift.sh <artifact_dir>.
# Exits non-zero on failure after printing diagnostics; run.sh then keeps
# the artifact directory.

set -euo pipefail

artifact_dir="$1"
script_dir=$(cd "$(dirname "$0")" && pwd)
record_file="$artifact_dir/record.jsonl"
module_file="$artifact_dir/lifted.rkt"

log() { printf '\033[1m[assert-bash-lift]\033[0m %s\n' "$*" >&2; }
fail() {
  printf '\033[1;31m[assert-bash-lift] error:\033[0m %s\n' "$*" >&2
  if [ -f "$module_file" ]; then
    log "lifted module:"
    cat "$module_file" >&2
  fi
  exit 1
}

# The base bash-metadata assertions must still hold.
bash "$script_dir/assert_bash_meta.sh" "$artifact_dir"

# Lift the record into a rash module.
"$REPROMPT_BIN" lift "$record_file" -o "$module_file" ||
  fail "reprompt lift failed on $record_file"
[ -s "$module_file" ] || fail "reprompt lift produced an empty module"

# The module opens with the rash lang line.
IFS= read -r first_line <"$module_file"
[ "$first_line" = "#lang rash" ] ||
  fail "the module does not start with '#lang rash' (got '$first_line')"

# The recorded echo command was lifted (lenient on the model's exact
# quoting, like assert_bash_meta.sh).
grep -F "echo" "$module_file" | grep -F "hello world" >/dev/null ||
  fail "the module does not contain the echo hello world command"

# Nothing from the Write call leaked into the module.
if grep -F -e "foobar" -e "fizz" "$module_file" >/dev/null; then
  fail "the module contains content from the Write call"
fi

# The module actually runs under rash and replays the echo.
run_output=$(HOME="$artifact_dir" racket "$module_file") ||
  fail "racket failed to execute the lifted module"
case "$run_output" in
  *"hello world"*) : ;;
  *) fail "running the module printed '$run_output', expected 'hello world'" ;;
esac

log "PASS: the lifted rash module replays the recorded Bash command"
