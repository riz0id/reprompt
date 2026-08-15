#!/usr/bin/env bash
# Host-side assertions for the bash-metadata integration test: the meta hook
# tags Bash calls — and only Bash calls — with meta.tag == "BashCommand" in
# record.jsonl, matching solely on the tool name.
# Invoked by tests/run.sh as: assert_bash_meta.sh <artifact_dir>.
# Exits non-zero on failure after printing diagnostics; run.sh then keeps
# the artifact directory.

set -euo pipefail

artifact_dir="$1"
record_file="$artifact_dir/record.jsonl"
foobar_file="$artifact_dir/work/foobar.txt"

log() { printf '\033[1m[assert-bash-meta]\033[0m %s\n' "$*" >&2; }
fail() {
  printf '\033[1;31m[assert-bash-meta] error:\033[0m %s\n' "$*" >&2
  if [ -f "$record_file" ]; then
    log "recorded calls:"
    cat "$record_file" >&2
  fi
  exit 1
}

[ -f "$record_file" ] || fail "the proxy recorded no calls"

# At least one Bash call carries the BashCommand tag ...
jq -e -s '[.[] | select(.tool == "Bash" and .meta.tag == "BashCommand")]
          | length >= 1' "$record_file" >/dev/null ||
  fail "no Bash call with meta.tag == \"BashCommand\" was recorded"

# ... and the tag appears on NOTHING but Bash calls (robust to the model
# making extra calls; jq's `all` on an empty array is true, which the
# existence check above rules out).
jq -e -s '[.[] | select(.meta.tag == "BashCommand") | .tool]
          | all(. == "Bash")' "$record_file" >/dev/null ||
  fail "a non-Bash call carries meta.tag == \"BashCommand\""

# Explicitly: no Write call carries the tag.
jq -e -s '[.[] | select(.tool == "Write")]
          | all(.meta.tag != "BashCommand")' "$record_file" >/dev/null ||
  fail "a Write call carries meta.tag == \"BashCommand\""

# Sanity: the tagged Bash call really was the echo command (lenient on the
# model's exact quoting).
jq -e -s '[.[] | select(.tool == "Bash"
                        and (.arguments.command // "" | contains("echo"))
                        and (.arguments.command // "" | contains("hello world")))]
          | length >= 1' "$record_file" >/dev/null ||
  fail "no Bash call ran the echo hello world command"

# Sanity: foobar.txt was written via the Write tool with content fizz.
jq -e -s '[.[] | select(.tool == "Write"
                        and (.arguments.path // "" | contains("foobar")))]
          | length >= 1' "$record_file" >/dev/null ||
  fail "no Write call for foobar.txt was recorded"
[ -f "$foobar_file" ] || fail "foobar.txt was not written"
foobar_content=$(cat "$foobar_file")
[ "$foobar_content" = "fizz" ] || fail "foobar.txt content is \
'$foobar_content', expected 'fizz'"

log "PASS: only the Bash call carries the BashCommand metadata (checked \
after the VM closed)"
