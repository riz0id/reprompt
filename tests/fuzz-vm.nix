# QEMU/NixOS VM test factory: one dedicated extensional-equivalence fuzz
# test per command mapping.
#
# The test derives entirely from the mapping named by mappingModule /
# mappingId and the source command interface that mapping declares:
# tests/fuzz/gen-cases.rkt samples random command lines from the
# interface spec (heads, aliases, repeatability, optional and enumerated
# values), uses the mapping itself as the domain and translation oracle,
# and tests/fuzz/check-cases.sh runs both real tools on random corpora,
# requiring identical exit codes and stdout up to the declared
# normalization. Runs are seedless-random; failures are reproduced from
# the oracle's self-contained reports.
#
# The whole cycle is hermetic in one machine: no network, no host
# services. guestPackages supplies the two real tools the oracle runs.
{
  pkgs,
  nixpkgs,
  mkRacketWithRash,
  name,
  mappingModule,
  mappingId,
  guestPackages,
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
  name = "reprompt-fuzz-${name}";

  node.pkgs = lib.mkForce guestPkgs;

  nodes.machine =
    { pkgs, ... }:
    {
      environment.systemPackages = guestPackages pkgs ++ [
        pkgs.coreutils
        pkgs.bash
        (mkRacketWithRash pkgs)
      ];

      environment.etc."reprompt/transformers".source = ../src/reprompt/transformers;
      environment.etc."reprompt/fuzz".source = ./fuzz;

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
        " --mapping ${mappingModule}"
        " --id '${mappingId}'"
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
