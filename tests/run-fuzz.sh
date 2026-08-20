#!/usr/bin/env bash
# Runner for one differential fuzz test: generate a FRESH corpus on the
# host, then drive the per-transform VM equivalence check over it.
# `nix run .#fuzz-test-<name>` wraps this script; the wrapper in flake.nix
# supplies the environment below.
#
# This is fuzzing, not generated unit testing: the corpus generator seeds
# from system entropy on every invocation, no seed is accepted or
# recorded, and every run explores new cases. A failing run cannot be
# regenerated — the checker's reports are self-contained instead, and the
# corpus directory is kept on failure.
#
# Environment (set by the flake app wrapper):
#   REPROMPT_FLAKE           Flake ref to evaluate (store copy of this repo).
#   REPROMPT_HOST_SYSTEM     Host system, e.g. aarch64-darwin.
#   REPROMPT_RUN_BUILDER     run-builder script of the (port-forward-free)
#                            darwin.linux-builder. Darwin hosts only.
#   REPROMPT_RACKET          Host racket-with-rash binary (runs gen-corpus).
#   REPROMPT_FUZZ_NAME       Registry entry name (e.g. grep).
#   REPROMPT_FUZZ_TRANSFORM  Transform module, relative to the transformers
#                            tree (e.g. cli/transforms/grep-to-rg.rkt).
#   REPROMPT_FUZZ_ID         Provided transformer id (e.g. grep->rg).
#   REPROMPT_FUZZ_COUNT      Number of equivalence cases to generate.
#
# Optional overrides:
#   REPROMPT_BUILDER_STATE, REPROMPT_BUILDER_SSH_PORT  (see lib-builder.sh)
#
# On a Darwin host the Linux guest closure is built on the builder VM
# (tests/lib-builder.sh); on a Linux host the driver builds locally.

set -euo pipefail

export REPROMPT_LOG_TAG="fuzz-${REPROMPT_FUZZ_NAME:?REPROMPT_FUZZ_NAME is not set}"

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib-builder.sh
. "$script_dir/lib-builder.sh"

flake="${REPROMPT_FLAKE:-$(dirname "$script_dir")}"
host_system="${REPROMPT_HOST_SYSTEM:-$("${nix_cmd[@]}" eval --impure --raw --expr builtins.currentSystem)}"
guest_attr="fuzzGuests.$REPROMPT_FUZZ_NAME"
check_attr="fuzz-$REPROMPT_FUZZ_NAME"

: "${REPROMPT_RACKET:?REPROMPT_RACKET is not set; run this script through the flake app: nix run .#fuzz-test-$REPROMPT_FUZZ_NAME}"
: "${REPROMPT_FUZZ_TRANSFORM:?REPROMPT_FUZZ_TRANSFORM is not set}"
: "${REPROMPT_FUZZ_ID:?REPROMPT_FUZZ_ID is not set}"
: "${REPROMPT_FUZZ_COUNT:?REPROMPT_FUZZ_COUNT is not set}"

case "$host_system" in
  *-darwin) builder_bootstrap "$guest_attr" ;;
esac

log "building the fuzz test driver"
driver_path=$(
  "${nix_cmd[@]}" build --no-link --print-out-paths \
    "$flake#checks.$host_system.$check_attr"
)

log "generating a fresh corpus ($REPROMPT_FUZZ_COUNT cases, seedless)"
corpus=$(mktemp -d "${TMPDIR:-/tmp}/reprompt-fuzz.XXXXXX")
"$REPROMPT_RACKET" "$script_dir/fuzz/gen-corpus.rkt" \
  --transforms "$flake/src/reprompt/transformers" \
  --transform "$REPROMPT_FUZZ_TRANSFORM" \
  --id "$REPROMPT_FUZZ_ID" \
  --count "$REPROMPT_FUZZ_COUNT" \
  --out "$corpus"

log "running the fuzz test driver"
if REPROMPT_FUZZ_CORPUS="$corpus" "$driver_path/bin/nixos-test-driver"; then
  log "PASS"
  rm -rf "$corpus"
else
  die "FAIL: equivalence failures reported above; corpus kept in $corpus"
fi
