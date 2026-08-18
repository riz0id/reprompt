#!/usr/bin/env bash
# Single-command runner for the reprompt integration test (design.md
# section 8). `nix run .#integration-test` wraps this script; the wrapper in
# flake.nix supplies the environment below. No sudo, no /etc file, no
# separate builder terminal, no Nix-daemon builder configuration.
#
# Environment (set by the flake app wrapper):
#   REPROMPT_FLAKE        Flake ref to evaluate (the store copy of this repo).
#   REPROMPT_HOST_SYSTEM  Host system, e.g. aarch64-darwin.
#   REPROMPT_RUN_BUILDER  run-builder script of the (port-forward-free)
#                         darwin.linux-builder. Darwin hosts only.
#
# Optional overrides:
#   REPROMPT_BUILDER_STATE     State directory
#                              (default ~/.cache/reprompt/linux-builder).
#   REPROMPT_BUILDER_SSH_PORT  Host TCP port for the builder SSH
#                              (default: first free port from 31122).
#   REPROMPT_GUEST_ATTR        Guest closure flake attribute
#                              (default integrationGuest).
#   REPROMPT_CHECK_ATTR        Test driver check attribute
#                              (default integration).
#   REPROMPT_ASSERT            Host-side assertion script, run with the
#                              artifact directory as its argument
#                              (default tests/assert_meta_recall.sh).
#   REPROMPT_REWRITE_HOOK      Optional rewrite hook module; when set, it is
#                              installed as rewrite_hook.py, the generated
#                              config gains a rewrite entry, and a per-run
#                              observed number is generated and exported as
#                              REPROMPT_OBSERVED for the test driver.
#   REPROMPT_REWRITE_TRANSFORMER  Racket transformer installed alongside the
#                              rewrite hook (required with it).
#   REPROMPT_RACKET            Racket binary the rewrite hook invokes
#                              (consumed by the hook, not by this script).
#
# On a Darwin host the Linux guest closure of the VM test cannot be built
# locally; tests/lib-builder.sh supplies the builder VM lifecycle (boot,
# remote guest build over user-owned SSH, import, stop). On a Linux host
# the driver builds locally and is exec'ed directly.

set -euo pipefail

export REPROMPT_LOG_TAG=integration-test

# ---------------------------------------------------------------------------
# Inputs

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib-builder.sh
. "$script_dir/lib-builder.sh"

flake="${REPROMPT_FLAKE:-$(dirname "$script_dir")}"
host_system="${REPROMPT_HOST_SYSTEM:-$("${nix_cmd[@]}" eval --impure --raw --expr builtins.currentSystem)}"
guest_attr="${REPROMPT_GUEST_ATTR:-integrationGuest}"
check_attr="${REPROMPT_CHECK_ATTR:-integration}"

case "$host_system" in
  *-darwin) needs_builder=1 ;;
  *) needs_builder=0 ;;
esac

# ---------------------------------------------------------------------------
# Builder lifecycle (Darwin hosts only): tests/lib-builder.sh. The model
# weights are content-addressed and already in the local store (or a cached
# download away); pre-copying them means the Linux guest build never
# downloads the 2.4 GiB file.

if [ "$needs_builder" = 1 ]; then
  REPROMPT_PRECOPY_ATTR=integrationModel builder_bootstrap "$guest_attr"
fi

# ---------------------------------------------------------------------------
# Driver build and run (all Linux inputs are now valid local store paths)

log "building the test driver"
driver_path=$(
  "${nix_cmd[@]}" build --no-link --print-out-paths \
    "$flake#checks.$host_system.$check_attr"
)

# ---------------------------------------------------------------------------
# Host-side reprompt proxy. claude inside the guest reaches it through the
# QEMU user-network gateway 10.0.2.2:8383 (= host 127.0.0.1:8383). The proxy
# runs the meta hook (random number in the tool response) and records every
# intercepted call to record.jsonl. All pass/fail artifacts are host files.

[ -n "${REPROMPT_BIN:-}" ] || die "REPROMPT_BIN is not set; run this script \
through the flake app: nix run .#integration-test"
[ -n "${REPROMPT_BACKEND_PYTHON:-}" ] || die "REPROMPT_BACKEND_PYTHON is not set"
[ -n "${REPROMPT_BACKEND:-}" ] || die "REPROMPT_BACKEND is not set"
[ -n "${REPROMPT_META_HOOK:-}" ] || die "REPROMPT_META_HOOK is not set"

proxy_port=8383
port_free "$proxy_port" || die "127.0.0.1:$proxy_port is already in use; the \
guest reaches the host proxy on this fixed port. Stop the process that holds \
it and retry."

artifact_dir=$(mktemp -d "${TMPDIR:-/tmp}/reprompt-test.XXXXXX")
mkdir -p "$artifact_dir/work"

# Rewrite tests get a per-run observed number. It is exported so the test
# driver (started later in this environment) can inject it into the guest;
# the file copy is for the host-side assertions.
if [ -n "${REPROMPT_REWRITE_HOOK:-}" ]; then
  observed=$(od -An -N4 -tu4 /dev/urandom | tr -cd '0-9')
  [ -n "$observed" ] || die "failed to generate the observed number"
  printf '%s' "$observed" >"$artifact_dir/observed"
  export REPROMPT_OBSERVED="$observed"
  log "observed number for this run: $observed"
fi
install -m 644 "$REPROMPT_META_HOOK" "$artifact_dir/meta_hook.py"
cat >"$artifact_dir/reprompt.yaml" <<EOF
listen:
  transport: http
  host: 127.0.0.1
  port: $proxy_port
backends:
  filesystem:
    command: ["$REPROMPT_BACKEND_PYTHON", "$REPROMPT_BACKEND", "$artifact_dir/work"]
meta: "meta_hook:attach_meta"
record: "$artifact_dir/record.jsonl"
EOF

# Optional rewrite hook: the hook and its Racket transformer live side by
# side in the artifact dir (the hook resolves the transformer relative to
# its own file), and the generated config gains the rewrite entry.
if [ -n "${REPROMPT_REWRITE_HOOK:-}" ]; then
  [ -n "${REPROMPT_REWRITE_TRANSFORMER:-}" ] ||
    die "REPROMPT_REWRITE_TRANSFORMER is not set"
  install -m 644 "$REPROMPT_REWRITE_HOOK" "$artifact_dir/rewrite_hook.py"
  install -m 644 "$REPROMPT_REWRITE_TRANSFORMER" "$artifact_dir/transform_touch.rkt"
  printf 'rewrite: "rewrite_hook:rewrite"\n' >>"$artifact_dir/reprompt.yaml"
fi

proxy_pid=""
stop_proxy() {
  if [ -n "$proxy_pid" ]; then
    kill "$proxy_pid" 2>/dev/null || true
    proxy_pid=""
  fi
}
trap stop_proxy EXIT INT TERM

log "starting the host reprompt proxy on 127.0.0.1:$proxy_port"
(
  cd "$artifact_dir"
  exec "$REPROMPT_BIN" run --config "$artifact_dir/reprompt.yaml" \
    >"$artifact_dir/reprompt.log" 2>&1
) &
proxy_pid=$!

proxy_ready=""
for _ in $(seq 1 60); do
  kill -0 "$proxy_pid" 2>/dev/null || die "the host reprompt proxy exited at \
startup; see $artifact_dir/reprompt.log"
  if ! port_free "$proxy_port"; then
    proxy_ready=1
    break
  fi
  sleep 1
done
[ -n "$proxy_ready" ] || die "the host reprompt proxy did not open port \
$proxy_port; see $artifact_dir/reprompt.log"

log "running the test driver"
"$driver_path/bin/nixos-test-driver"

# The VM is now closed; the proxy has served its purpose.
stop_proxy
trap - EXIT INT TERM

# ---------------------------------------------------------------------------
# Pass/fail, entirely on host artifacts. The assertion script is
# test-specific; each flake app exports REPROMPT_ASSERT, and the default
# reproduces the assertions of the original test for direct invocations.

assert_script="${REPROMPT_ASSERT:-$script_dir/assert_meta_recall.sh}"
log "running host-side assertions: $assert_script"
if bash "$assert_script" "$artifact_dir"; then
  log "PASS"
  rm -rf "$artifact_dir"
else
  die "FAIL: assertions failed; artifacts kept in $artifact_dir"
fi
