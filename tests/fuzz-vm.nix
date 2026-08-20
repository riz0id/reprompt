# QEMU/NixOS VM factory: one dedicated extensional-equality fuzz check
# per transform, keyed by the transform's source specification.
#
# The guest is deliberately minimal: the source and target commands under
# test, plus the shell utilities the checker itself needs (bash,
# coreutils, diffutils, findutils, gnugrep) — no racket, no network, no
# services. Generation and translation already happened on the HOST
# (tests/run-fuzz.sh runs tests/fuzz/gen-corpus.rkt with fresh system
# entropy on every invocation — there are no seeds anywhere); the guest
# only executes the two real binaries over the mounted corpus and
# compares. The corpus directory crosses the boundary once, via the test
# driver's shared-directory copy: the runner exports
# REPROMPT_FUZZ_CORPUS, and the test script copies that tree into the
# guest before running tests/fuzz/check-cases.sh against it.
{
  pkgs,
  nixpkgs,
  name,
  tools,
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
      environment.systemPackages = tools pkgs ++ [
        pkgs.bash
        pkgs.coreutils
        pkgs.diffutils
        pkgs.findutils
        pkgs.gnugrep
      ];

      environment.etc."reprompt/check-cases.sh".source = ./fuzz/check-cases.sh;

      virtualisation.vlans = [ ];
      virtualisation.cores = 2;
      virtualisation.memorySize = 1024;
      virtualisation.graphics = false;
    };

  testScript = ''
    import os

    corpus = os.environ.get("REPROMPT_FUZZ_CORPUS")
    assert corpus, (
        "REPROMPT_FUZZ_CORPUS is not set; run this test through "
        "tests/run-fuzz.sh (nix run .#fuzz-test-${name}), which generates "
        "a fresh corpus first"
    )

    machine.wait_for_unit("multi-user.target")
    machine.copy_from_host(corpus, "/tmp/corpus")
    machine.succeed(
        "REPROMPT_FUZZ_CORPUS=/tmp/corpus REPROMPT_FUZZ_WORK=/tmp/fuzz-work"
        " bash /etc/reprompt/check-cases.sh >&2",
        timeout=1800,
    )
  '';
}
