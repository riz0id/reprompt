#!/usr/bin/env bash
# Runner for the grep->rg extensional-equivalence fuzz test.
# `nix run .#fuzz-test` wraps this script; the wrapper in flake.nix
# supplies the environment below. Unlike tests/run.sh there is no host
# proxy, no model, and no backend: the whole fuzz cycle -- generate
# commands, translate them through the grep->rg mapping, run GNU grep and
# rg, compare -- happens inside the test VM.
#
# Environment (set by the flake app wrapper):
#   REPROMPT_FLAKE        Flake ref to evaluate (the store copy of this repo).
#   REPROMPT_HOST_SYSTEM  Host system, e.g. aarch64-darwin.
#   REPROMPT_RUN_BUILDER  run-builder script of the (port-forward-free)
#                         darwin.linux-builder. Darwin hosts only.
#
# Optional overrides:
#   REPROMPT_BUILDER_STATE, REPROMPT_BUILDER_SSH_PORT  (see lib-builder.sh)
#   REPROMPT_GUEST_ATTR   Guest closure flake attribute (default fuzzGuest).
#   REPROMPT_CHECK_ATTR   Test driver check attribute (default fuzz-grep-rg).
#
# On a Darwin host the Linux guest closure is built on the builder VM
# (tests/lib-builder.sh); on a Linux host the driver builds locally and is
# exec'ed directly.

set -euo pipefail

export REPROMPT_LOG_TAG="${REPROMPT_LOG_TAG:-fuzz-test}"

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib-builder.sh
. "$script_dir/lib-builder.sh"

flake="${REPROMPT_FLAKE:-$(dirname "$script_dir")}"
host_system="${REPROMPT_HOST_SYSTEM:-$("${nix_cmd[@]}" eval --impure --raw --expr builtins.currentSystem)}"
guest_attr="${REPROMPT_GUEST_ATTR:-fuzzGuests.grep-rg}"
check_attr="${REPROMPT_CHECK_ATTR:-fuzz-grep-rg}"

case "$host_system" in
  *-darwin) builder_bootstrap "$guest_attr" ;;
esac

log "building the fuzz test driver"
driver_path=$(
  "${nix_cmd[@]}" build --no-link --print-out-paths \
    "$flake#checks.$host_system.$check_attr"
)

log "running the fuzz test driver"
exec "$driver_path/bin/nixos-test-driver"
