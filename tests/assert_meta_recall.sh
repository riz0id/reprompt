#!/usr/bin/env bash
# Host-side assertions for the meta-recall integration test (the default
# test): hello_world.txt has the expected content, exactly one random number
# appears in record.jsonl, and the model recalled it into recalled.txt.
# Invoked by tests/run.sh as: assert_meta_recall.sh <artifact_dir>.
# Exits non-zero on failure after printing diagnostics; run.sh then keeps
# the artifact directory.

set -euo pipefail

artifact_dir="$1"

log() { printf '\033[1m[assert-meta-recall]\033[0m %s\n' "$*" >&2; }
fail() {
  printf '\033[1;31m[assert-meta-recall] error:\033[0m %s\n' "$*" >&2
  exit 1
}

hello_file="$artifact_dir/work/hello_world.txt"
recalled_file="$artifact_dir/work/recalled.txt"
record_file="$artifact_dir/record.jsonl"

[ -f "$hello_file" ] || fail "hello_world.txt was not written"
hello_content=$(cat "$hello_file")
[ "$hello_content" = "hello world!" ] || fail "hello_world.txt content is \
'$hello_content', expected 'hello world!'"
log "hello_world.txt has the expected content"

[ -f "$record_file" ] || fail "the proxy recorded no calls"
number=$(jq -r 'select(.meta.number != null) | .meta.number' "$record_file" |
  sort -u)
[ -n "$number" ] || fail "no random number appears in the record"
case "$number" in
  *$'\n'*) fail "more than one random number appears in the record" ;;
esac

if [ -f "$recalled_file" ] && grep -qF -- "$number" "$recalled_file"; then
  log "PASS: the model recalled the random number ($number) from the MCP \
tool response (checked after the VM closed)"
else
  log "recorded calls:"
  cat "$record_file" >&2
  if [ -f "$recalled_file" ]; then
    log "recalled.txt content:"
    cat "$recalled_file" >&2
    printf '\n' >&2
  else
    log "recalled.txt was not written"
  fi
  fail "the model did not recall the random number"
fi
