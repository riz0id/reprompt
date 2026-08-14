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
#   REPROMPT_BUILDER_SSH_PORT  Host TCP port for the builder's SSH
#                              (default: first free port from 31122).
#
# On a Darwin host the Linux guest closure of the VM test cannot be built
# locally. The sequence here (design.md section 8):
#   1. keep state (disk image, SSH keys) in the state directory;
#   2. boot the nixpkgs darwin.linux-builder VM with run-builder — the
#      builder reads the client public key from the shared 9p keys
#      directory, so no credentials are installed anywhere;
#   3. build the guest closure on the builder as the invoking user
#      (nix build --store ssh-ng://..., NIX_SSHOPTS carries port and key —
#      the Nix daemon and its root SSH configuration play no part);
#   4. import the result (nix copy --no-check-sigs; needs trusted-users);
#   5. build the Darwin test driver locally and exec it;
#   6. stop the builder VM (trap, and eagerly after the import).
#
# On a Linux host steps 1-4 and 6 are unnecessary: the driver builds
# locally and is exec'ed directly.

set -euo pipefail

log() { printf '\033[1m[integration-test]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[integration-test] error:\033[0m %s\n' "$*" >&2
  exit 1
}

nix_cmd=(nix --extra-experimental-features "nix-command flakes")

# ---------------------------------------------------------------------------
# Inputs

script_dir=$(cd "$(dirname "$0")" && pwd)
flake="${REPROMPT_FLAKE:-$(dirname "$script_dir")}"
host_system="${REPROMPT_HOST_SYSTEM:-$("${nix_cmd[@]}" eval --impure --raw --expr builtins.currentSystem)}"

case "$host_system" in
  *-darwin) needs_builder=1 ;;
  *) needs_builder=0 ;;
esac

# ---------------------------------------------------------------------------
# Builder lifecycle (Darwin hosts only)

builder_pid=""
qemu_pidfile=""
lock_dir=""

cleanup() {
  if [ -n "$qemu_pidfile" ] && [ -f "$qemu_pidfile" ]; then
    qemu_pid=$(cat "$qemu_pidfile" 2>/dev/null || true)
    if [ -n "$qemu_pid" ]; then
      kill "$qemu_pid" 2>/dev/null || true
    fi
    rm -f "$qemu_pidfile"
  fi
  if [ -n "$builder_pid" ]; then
    kill "$builder_pid" 2>/dev/null || true
    builder_pid=""
  fi
  if [ -n "$lock_dir" ]; then
    rmdir "$lock_dir" 2>/dev/null || true
    lock_dir=""
  fi
}

port_free() {
  # /dev/tcp connect probe: a successful connect means something listens.
  ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

if [ "$needs_builder" = 1 ]; then
  run_builder="${REPROMPT_RUN_BUILDER:-}"
  [ -n "$run_builder" ] || die "REPROMPT_RUN_BUILDER is not set; run this \
script through the flake app: nix run .#integration-test"

  state="${REPROMPT_BUILDER_STATE:-${XDG_CACHE_HOME:-$HOME/.cache}/reprompt/linux-builder}"
  case "$state" in
    *" "*) die "the builder state directory path must not contain spaces: $state" ;;
  esac
  mkdir -p "$state"

  trap cleanup EXIT INT TERM

  # One builder VM per state directory: the VM writes the disk image
  # ($state/nixos.qcow2) and a concurrent second VM would corrupt it.
  lock_dir="$state/lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    lock_path="$lock_dir"
    lock_dir=""
    die "another integration-test run appears to be active ($lock_path \
exists). If no other run is active, remove that directory and retry."
  fi

  # SSH key pair for the builder. The public key is staged alone in a
  # separate shared directory: run-builder copies the whole shared
  # directory into the world-readable Nix store, so the private key must
  # not be in it. The name builder_ed25519.pub matches the builder VM's
  # services.openssh.authorizedKeysFiles pattern /var/keys/%u_ed25519.pub
  # for the user `builder`.
  mkdir -p "$state/keys"
  chmod 700 "$state/keys"
  key="$state/keys/builder_ed25519"
  if [ ! -f "$key" ]; then
    log "generating the builder SSH key pair"
    ssh-keygen -q -t ed25519 -N "" -C reprompt-linux-builder -f "$key"
  fi
  shared_keys="$state/shared-keys"
  mkdir -p "$shared_keys"
  install -m 644 "$key.pub" "$shared_keys/builder_ed25519.pub"

  # Choose the host port for the builder's SSH. The embedded builder has no
  # baked-in port forward (flake.nix removes the stock tcp :31022 forward,
  # which would abort QEMU whenever another builder runs), so the forward
  # chosen here is the only one.
  if [ -n "${REPROMPT_BUILDER_SSH_PORT:-}" ]; then
    ssh_port="$REPROMPT_BUILDER_SSH_PORT"
    port_free "$ssh_port" || die "REPROMPT_BUILDER_SSH_PORT=$ssh_port is \
already in use; pick a free port or stop the process that holds it"
  else
    ssh_port=""
    for p in $(seq 31122 31221); do
      if port_free "$p"; then
        ssh_port="$p"
        break
      fi
    done
    [ -n "$ssh_port" ] || die "no free TCP port found in 31122-31221; set \
REPROMPT_BUILDER_SSH_PORT to a free port"
  fi

  if [ -e "$state/nixos.qcow2" ]; then
    log "reusing the builder disk image $state/nixos.qcow2"
  else
    log "first start: the builder disk image will be created in $state"
  fi

  log "starting the Linux builder VM (SSH on 127.0.0.1:$ssh_port)"
  qemu_pidfile="$state/qemu.pid"
  rm -f "$qemu_pidfile"
  (
    cd "$state"
    KEYS="$shared_keys" \
      QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:${ssh_port}-:22" \
      QEMU_OPTS="-pidfile $qemu_pidfile" \
      exec "$run_builder" >"$state/builder.log" 2>&1
  ) &
  builder_pid=$!

  # SSH options shared by the readiness probe, nix build, and nix copy.
  # The connection belongs to the invoking user; no daemon, no root SSH
  # configuration, no /etc/ssh host alias.
  ssh_opts="-p $ssh_port -i $key \
-o UserKnownHostsFile=$state/known_hosts \
-o StrictHostKeyChecking=accept-new \
-o IdentitiesOnly=yes -o BatchMode=yes"

  # Wait for SSH readiness. Probe with a real SSH exec, not a TCP connect:
  # QEMU holds the forwarded port open long before sshd accepts logins.
  log "waiting for the builder's SSH (this takes a few minutes on first boot)"
  ssh_ready=""
  for i in $(seq 1 180); do
    if ! kill -0 "$builder_pid" 2>/dev/null; then
      die "the builder VM exited before SSH came up; see $state/builder.log \
(a common cause: the chosen host port $ssh_port was taken meanwhile)"
    fi
    # shellcheck disable=SC2086
    if ssh $ssh_opts -o ConnectTimeout=5 "builder@localhost" true \
      2>/dev/null; then
      ssh_ready=1
      break
    fi
    [ $((i % 12)) = 0 ] && log "still waiting for the builder's SSH..."
    sleep 5
  done
  [ -n "$ssh_ready" ] || die "the builder's SSH did not become ready within \
15 minutes; see $state/builder.log"
  log "builder is up"

  export NIX_SSHOPTS="$ssh_opts"
  builder_store="ssh-ng://builder@localhost"

  # The model weights are content-addressed and already in the local store
  # (or a cached download away). Pre-copy them to the builder so the Linux
  # guest build finds the path valid instead of downloading 2.4 GiB.
  log "ensuring the model weights are local and on the builder"
  model_path=$(
    "${nix_cmd[@]}" build --no-link --print-out-paths \
      "$flake#integrationModel.$host_system"
  )
  "${nix_cmd[@]}" copy --to "$builder_store" --no-check-sigs "$model_path"

  # Build the Linux part of the test — the guest system closure — on the
  # builder, as the invoking user.
  log "building the Linux guest closure on the builder (remote build)"
  guest_path=$(
    "${nix_cmd[@]}" build \
      --store "$builder_store" --eval-store auto \
      --no-link --print-out-paths \
      "$flake#integrationGuest.$host_system"
  )
  [ -n "$guest_path" ] || die "the remote build produced no output path"
  log "guest closure built: $guest_path"

  # Import the guest closure into the local store. The paths are unsigned,
  # so the local Nix daemon only accepts them from a trusted user.
  log "importing the guest closure into the local store"
  if ! "${nix_cmd[@]}" copy --from "$builder_store" --no-check-sigs \
    "$guest_path"; then
    die "importing the unsigned guest closure was refused. Your user must \
be in the Nix daemon's trusted-users on this host (nix-darwin: \
nix.settings.trusted-users; plain nix: trusted-users in /etc/nix/nix.conf), \
then restart the daemon and retry."
  fi

  # The builder has served its purpose; stop it before the driver runs so
  # its memory is free for the test VM.
  log "stopping the builder VM"
  cleanup
  trap - EXIT INT TERM
fi

# ---------------------------------------------------------------------------
# Driver build and run (all Linux inputs are now valid local store paths)

log "building the test driver"
driver_path=$(
  "${nix_cmd[@]}" build --no-link --print-out-paths \
    "$flake#checks.$host_system.integration"
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
# Pass/fail, entirely on host artifacts.

hello_file="$artifact_dir/work/hello_world.txt"
recalled_file="$artifact_dir/work/recalled.txt"
record_file="$artifact_dir/record.jsonl"

[ -f "$hello_file" ] || die "hello_world.txt was not written; artifacts kept \
in $artifact_dir"
hello_content=$(cat "$hello_file")
[ "$hello_content" = "hello world!" ] || die "hello_world.txt content is \
'$hello_content', expected 'hello world!'; artifacts kept in $artifact_dir"
log "hello_world.txt has the expected content"

[ -f "$record_file" ] || die "the proxy recorded no calls; artifacts kept in \
$artifact_dir"
number=$(jq -r 'select(.meta.number != null) | .meta.number' "$record_file" \
  | sort -u)
[ -n "$number" ] || die "no random number appears in the record; artifacts \
kept in $artifact_dir"
case "$number" in
  *$'\n'*) die "more than one random number appears in the record; artifacts \
kept in $artifact_dir" ;;
esac

if [ -f "$recalled_file" ] && grep -qF -- "$number" "$recalled_file"; then
  log "PASS: the model recalled the random number ($number) from the MCP \
tool response (checked after the VM closed)"
  rm -rf "$artifact_dir"
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
  die "FAIL: the model did not recall the random number; artifacts kept in \
$artifact_dir"
fi
