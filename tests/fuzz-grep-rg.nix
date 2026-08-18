# QEMU/NixOS VM test: extensional-equivalence fuzzing of the grep->rg
# command mapping.
#
# The guest contains GNU grep, ripgrep, and racket-with-rash plus the
# transformer tree; tests/fuzz/gen-cases.rkt generates random corpora and
# grep/egrep/fgrep command lines under a fresh seed drawn from system
# randomness each run (printed, and recorded in /tmp/fuzz/SEED, so a
# failure reproduces by passing --seed), translates each through the
# hand-written grep->rg mapping in-process, and tests/fuzz/check-cases.sh
# runs both commands and requires identical stdout (sorted line multisets
# for multi-file rows, byte-for-byte otherwise) and exit codes. The whole
# cycle is hermetic in one machine: no network, no host services.
{
  pkgs,
  nixpkgs,
  mkRacketWithRash,
  name ? "reprompt-fuzz-grep-rg",
  fuzzCount ? 500,
}:
let
  inherit (pkgs) lib;

  hostSystem = pkgs.stdenv.hostPlatform.system;
  guestSystem =
    if pkgs.stdenv.hostPlatform.isLinux then
      hostSystem
    else
      lib.replaceStrings [ "darwin" ] [ "linux" ] hostSystem;

  guestPkgs = import nixpkgs {
    system = guestSystem;
  };
in
pkgs.testers.runNixOSTest {
  inherit name;

  node.pkgs = lib.mkForce guestPkgs;

  nodes.machine =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.gnugrep
        pkgs.ripgrep
        pkgs.coreutils
        pkgs.bash
        (mkRacketWithRash pkgs)
      ];

      environment.etc."reprompt/transformers".source = ../src/reprompt/transformers;
      environment.etc."reprompt/fuzz".source = ./fuzz;

      # No network: the fuzz cycle talks to nothing.
      virtualisation.vlans = [ ];
      virtualisation.cores = 4;
      virtualisation.memorySize = 2048;
      virtualisation.graphics = false;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "racket /etc/reprompt/fuzz/gen-cases.rkt"
        " --transformers /etc/reprompt/transformers"
        " --count ${toString fuzzCount}"
        " --out /tmp/fuzz >&2",
        timeout=600,
    )
    machine.succeed(
        "REPROMPT_FUZZ_OUT=/tmp/fuzz bash /etc/reprompt/fuzz/check-cases.sh >&2",
        timeout=1800,
    )
  '';
}
