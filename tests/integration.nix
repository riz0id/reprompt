# QEMU/NixOS VM integration test for reprompt.
#
# The guest contains a fully local model stack: Qwen3-4B-Instruct (GGUF,
# Apache-2.0) served by llama-server, driven by tests/agent.py — an MCP agent
# that fetches its tools from the reprompt proxy on the HOST through the QEMU
# user-network gateway 10.0.2.2:8383 (= host 127.0.0.1:8383). tests/run.sh
# starts the proxy, the meta hook, the recorder, and the filesystem backend
# on the host, so every pass/fail artifact (hello_world.txt, recalled.txt,
# record.jsonl) exists on the host when the VM closes.
#
# The test needs no API, no token, and no Internet egress: the only permitted
# guest egress is TCP 8383 to the host gateway.
{
  pkgs,
  nixpkgs,
  mkReprompt,
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
  name = "reprompt-integration";

  node.pkgs = lib.mkForce guestPkgs;

  nodes.machine =
    { pkgs, ... }:
    let
      agentPython = pkgs.python3.withPackages (ps: [ ps.fastmcp ]);

      # Qwen3-4B-Instruct-2507, Q4_K_M quantization (~2.4 GiB), Apache-2.0.
      # Defined with the GUEST pkgs so the derivation is aarch64-linux and
      # buildable on the Linux builder. The output path is content-addressed
      # (name + hash), so it is identical to the host-side
      # `integrationModel` flake output, which run.sh builds locally and
      # pre-copies to the builder — the builder then never downloads it.
      qwenModel = pkgs.fetchurl {
        url = "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf";
        sha256 = "15z5cx6bqcv59jlwhilf3nscsfkfwcm1nv2gskm4mdick0xq019n";
      };
    in
    {
      users.users.agent = {
        isNormalUser = true;
        home = "/home/agent";
      };

      environment.etc."reprompt/agent.py".source = ./agent.py;

      # Local model server: OpenAI-compatible chat API with tool calling
      # (--jinja uses the GGUF's chat template, which for Qwen3 defines
      # function calling).
      systemd.services.llama = {
        description = "llama-server with Qwen3-4B-Instruct";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "agent";
          Group = "users";
          ExecStart =
            "${pkgs.llama-cpp}/bin/llama-server"
            + " -m ${qwenModel}"
            + " --host 127.0.0.1 --port 8080"
            + " --jinja -c 8192 --no-webui";
          Restart = "on-failure";
        };
      };

      environment.systemPackages = [
        agentPython
        pkgs.curl
      ];

      # ---- controlled egress ------------------------------------------------
      # Drop the inter-VM vlan NIC; eth0 stays the QEMU user-mode NAT (SLiRP)
      # NIC. The only permitted egress is the host gateway port of the
      # reprompt proxy; the guest needs no DNS and no Internet.
      virtualisation.vlans = [ ];

      networking.useDHCP = false;
      networking.interfaces.eth0.ipv4.addresses = [
        {
          address = "10.0.2.15";
          prefixLength = 24;
        }
      ];
      networking.defaultGateway = "10.0.2.2";

      networking.nftables.enable = true;
      networking.nftables.tables.reprompt-egress = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy drop;
            oifname "lo" accept
            ct state established,related accept
            ip daddr 10.0.2.2 tcp dport 8383 accept
            counter reject
          }
        '';
      };

      virtualisation.cores = 4;
      virtualisation.memorySize = 6144;
      # Headless: no host display window; serial console only.
      virtualisation.graphics = false;
    };

  # ---- test procedure ------------------------------------------------------
  # The Python lives in tests/test_script.py, not inline in this Nix
  # expression; it defines run_test(machine, subtest) and is appended here
  # with the call that hands over the driver objects.
  testScript = ''
    ${builtins.readFile ./test_script.py}

    run_test(machine, subtest)
  '';
}
