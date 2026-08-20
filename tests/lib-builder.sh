# Shared Linux-builder bootstrap for the reprompt test runners.
#
# Sourced (not executed) by tests/run.sh on Darwin
# hosts, where the Linux guest closure of a VM test cannot be built
# locally. The sequence (design.md section 8):
#   1. keep state (disk image, SSH keys) in the state directory;
#   2. boot the nixpkgs darwin.linux-builder VM with run-builder -- the
#      builder reads the client public key from the shared 9p keys
#      directory, so no credentials are installed anywhere;
#   3. build the guest closure on the builder as the invoking user
#      (nix build --store ssh-ng://..., NIX_SSHOPTS carries port and key --
#      the Nix daemon and its root SSH configuration play no part);
#   4. import the result (nix copy --no-check-sigs; needs trusted-users);
#   5. stop the builder VM (trap, and eagerly after the import).
#
# Provides: log, die, port_free, builder_cleanup, and
# builder_bootstrap GUEST_ATTR. The caller sets the globals flake and
# host_system before calling builder_bootstrap.
#
# Environment consumed:
#   REPROMPT_LOG_TAG           Prefix for log lines (default reprompt-test).
#   REPROMPT_RUN_BUILDER       run-builder script of the builder VM.
#   REPROMPT_BUILDER_STATE     State directory
#                              (default ~/.cache/reprompt/linux-builder).
#   REPROMPT_BUILDER_SSH_PORT  Host TCP port for the builder SSH
#                              (default: first free port from 31122).
#   REPROMPT_PRECOPY_ATTR      Optional flake attribute (indexed by host
#                              system) built locally and pre-copied to the
#                              builder before the guest build -- used for
#                              content-addressed artifacts like model
#                              weights that the builder should not
#                              re-download.

nix_cmd=(nix --extra-experimental-features "nix-command flakes")

log() {
  printf '\033[1m[%s]\033[0m %s\n' "${REPROMPT_LOG_TAG:-reprompt-test}" "$*" >&2
}
die() {
  printf '\033[1;31m[%s] error:\033[0m %s\n' "${REPROMPT_LOG_TAG:-reprompt-test}" "$*" >&2
  exit 1
}

builder_pid=""
qemu_pidfile=""
lock_dir=""

builder_cleanup() {
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

builder_bootstrap() {
  guest_attr_arg="$1"

  run_builder="${REPROMPT_RUN_BUILDER:-}"
  [ -n "$run_builder" ] || die "REPROMPT_RUN_BUILDER is not set; run this \
script through its flake app"

  state="${REPROMPT_BUILDER_STATE:-${XDG_CACHE_HOME:-$HOME/.cache}/reprompt/linux-builder}"
  case "$state" in
    *" "*) die "the builder state directory path must not contain spaces: $state" ;;
  esac
  mkdir -p "$state"

  trap builder_cleanup EXIT INT TERM

  # One builder VM per state directory: the VM writes the disk image
  # ($state/nixos.qcow2) and a concurrent second VM would corrupt it.
  lock_dir="$state/lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    lock_path="$lock_dir"
    lock_dir=""
    die "another builder-based test run appears to be active ($lock_path \
exists). If no other run is active, remove that directory and retry."
  fi

  # SSH key pair for the builder. The public key is staged alone in a
  # separate shared directory: run-builder copies the whole shared
  # directory into the world-readable Nix store, so the private key must
  # not be in it. The name builder_ed25519.pub matches the builder VM
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

  # Choose the host port for the builder SSH. The embedded builder has no
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
  log "waiting for the builder SSH (this takes a few minutes on first boot)"
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
    [ $((i % 12)) = 0 ] && log "still waiting for the builder SSH..."
    sleep 5
  done
  [ -n "$ssh_ready" ] || die "the builder SSH did not become ready within \
15 minutes; see $state/builder.log"
  log "builder is up"

  export NIX_SSHOPTS="$ssh_opts"
  builder_store="ssh-ng://builder@localhost"

  # Optional pre-copy of a content-addressed local artifact (e.g. model
  # weights): build it locally, copy it over, and the guest build finds
  # the path valid instead of re-downloading it.
  if [ -n "${REPROMPT_PRECOPY_ATTR:-}" ]; then
    log "ensuring $REPROMPT_PRECOPY_ATTR is local and on the builder"
    precopy_path=$(
      "${nix_cmd[@]}" build --no-link --print-out-paths \
        "$flake#$REPROMPT_PRECOPY_ATTR.$host_system"
    )
    "${nix_cmd[@]}" copy --to "$builder_store" --no-check-sigs "$precopy_path"
  fi

  # Build the Linux part of the test -- the guest system closure -- on the
  # builder, as the invoking user.
  log "building the Linux guest closure on the builder (remote build)"
  guest_path=$(
    "${nix_cmd[@]}" build \
      --store "$builder_store" --eval-store auto \
      --no-link --print-out-paths \
      "$flake#$guest_attr_arg.$host_system"
  )
  [ -n "$guest_path" ] || die "the remote build produced no output path"
  log "guest closure built: $guest_path"

  # Import the guest closure into the local store. The paths are unsigned,
  # so the local Nix daemon only accepts them from a trusted user.
  log "importing the guest closure into the local store"
  if ! "${nix_cmd[@]}" copy --from "$builder_store" --no-check-sigs \
    "$guest_path"; then
    die "importing the unsigned guest closure was refused. Your user must \
be in the Nix daemon trusted-users on this host (nix-darwin: \
nix.settings.trusted-users; plain nix: trusted-users in /etc/nix/nix.conf), \
then restart the daemon and retry."
  fi

  # The builder has served its purpose; stop it before the driver runs so
  # its memory is free for the test VM.
  log "stopping the builder VM"
  builder_cleanup
  trap - EXIT INT TERM
}
