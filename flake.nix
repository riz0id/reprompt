{
  description = "Python project with Nix-managed dependencies, uv, black, and mypy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Claude Code hook: runs black + mypy on every Python file Claude writes.
    # Follows our nixpkgs so its black/mypy match the ones in this devShell.
    #
    # Local checkout for now. A relative "path:../claude-python-fix" does not
    # work here: this flake is a git flake, so relative path inputs resolve
    # against the store copy of the tree and cannot escape the repo. Once the
    # hook repo is pushed, replace this with:
    #   url = "github:<owner>/claude-python-fix";
    claude-python-fix = {
      url = "path:/Users/jake/Documents/Programming/Python/claude-python-fix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      claude-python-fix,
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Project dependencies live here, not in pyproject.toml.
      # Add packages from nixpkgs' python3Packages set.
      projectDeps =
        ps: with ps; [
          fastmcp
          pydantic
          pyyaml
        ];

      # One builder for every package set that needs reprompt: the host
      # package sets below and the Linux guest package set of the VM test.
      mkReprompt =
        pkgs:
        pkgs.python3Packages.buildPythonApplication {
          pname = "reprompt";
          version = "0.1.0";
          pyproject = true;
          src = ./.;
          build-system = [ pkgs.python3Packages.hatchling ];
          dependencies = projectDeps pkgs.python3Packages;
          meta.mainProgram = "reprompt";
        };

      # Systems that can host the QEMU/NixOS VM test. The NixOS test
      # framework pairs aarch64-darwin hosts with aarch64-linux guests;
      # x86_64-darwin has no such pairing.
      testSystems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];

      integrationTest =
        system:
        import ./tests/integration.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit nixpkgs mkReprompt;
        };
    in
    {
      packages = forAllSystems (pkgs: rec {
        default = reprompt;
        reprompt = mkReprompt pkgs;
      });

      apps = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        rec {
          default = reprompt;
          reprompt = {
            type = "app";
            program = "${self.packages.${system}.reprompt}/bin/reprompt";
          };
        }
        // nixpkgs.lib.optionalAttrs (builtins.elem system testSystems) {
          # One command runs the full test:
          #   nix run .#integration-test
          # No token and no API access: the model (Qwen3-4B-Instruct) runs
          # locally inside the guest. The runner still needs to run outside
          # the Nix sandbox (host proxy, builder VM, QEMU).
          #
          # On Darwin the app wraps tests/run.sh, which supplies its own
          # Linux builder VM: it remote-builds the guest closure
          # (.#integrationGuest) over user-owned SSH, imports it into the
          # local store, then builds and runs the driver locally. No sudo,
          # no /etc files, no separate builder terminal, no Nix-daemon
          # builder configuration. On Linux hosts the driver runs directly.
          integration-test =
            if pkgs.stdenv.hostPlatform.isDarwin then
              let
                # The stock nixpkgs builder VM, minus its baked host port
                # forward (tcp :31022): QEMU aborts at startup when another
                # builder VM already holds that port. The change is
                # host-side only — the Linux guest closure is unchanged and
                # stays substitutable from the public cache — and
                # tests/run.sh supplies the forward itself on a free port
                # through QEMU_NET_OPTS.
                linuxBuilder = pkgs.darwin.linux-builder.override {
                  modules = [ { virtualisation.forwardPorts = nixpkgs.lib.mkForce [ ]; } ];
                };
              in
              {
                type = "app";
                program = nixpkgs.lib.getExe (
                  pkgs.writeShellApplication {
                    name = "reprompt-integration-test";
                    runtimeInputs = [
                      pkgs.nix
                      pkgs.openssh
                      pkgs.coreutils
                      pkgs.gnugrep
                      pkgs.jq
                    ];
                    # The wrapper only wires store paths.
                    text = ''
                      export REPROMPT_FLAKE=${self}
                      export REPROMPT_HOST_SYSTEM=${system}
                      export REPROMPT_RUN_BUILDER=${nixpkgs.lib.getExe linuxBuilder.run-builder}
                      export REPROMPT_BIN=${nixpkgs.lib.getExe (mkReprompt pkgs)}
                      export REPROMPT_BACKEND_PYTHON=${pkgs.python3.withPackages (ps: [ ps.fastmcp ])}/bin/python
                      export REPROMPT_BACKEND=${self}/tests/backend.py
                      export REPROMPT_META_HOOK=${self}/tests/meta_hook.py
                      exec ${pkgs.runtimeShell} ${self}/tests/run.sh
                    '';
                  }
                );
              }
            else
              {
                type = "app";
                program = "${(integrationTest system).driver}/bin/nixos-test-driver";
              };
        }
      );

      # Build-only: the guest closure and the test driver. The test itself
      # needs network access (api.anthropic.com), so it cannot run in the
      # pure build sandbox; run it with `nix run .#integration-test`.
      checks = nixpkgs.lib.genAttrs testSystems (system: {
        integration = (integrationTest system).driver;
      });

      # Internal output for tests/run.sh (not part of the standard flake
      # schema): the Linux guest system closure of the VM test — the only
      # part of the test that needs a Linux builder. run.sh builds
      # .#integrationGuest.<hostSystem> on the builder VM over SSH and
      # imports the result, after which the test driver
      # (checks.<hostSystem>.integration) builds locally on Darwin.
      integrationGuest = nixpkgs.lib.genAttrs testSystems (
        system: (integrationTest system).nodes.machine.system.build.toplevel
      );

      # The model weights as a host-system derivation. The output path is
      # content-addressed and identical to the guest-side fetchurl in
      # tests/integration.nix; run.sh builds this locally (a cached download)
      # and pre-copies it to the builder VM so the Linux-side build never
      # downloads the 2.4 GiB file.
      integrationModel = nixpkgs.lib.genAttrs testSystems (
        system:
        nixpkgs.legacyPackages.${system}.fetchurl {
          url = "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf";
          sha256 = "15z5cx6bqcv59jlwhilf3nscsfkfwcm1nv2gskm4mdick0xq019n";
        }
      );

      devShells = forAllSystems (
        pkgs:
        let
          pythonEnv = pkgs.python3.withPackages projectDeps;

          # Shared by the hook binary below and by the settings.local.json the
          # shellHook writes, so both always refer to the same build.
          hookArgs = {
            inherit pkgs pythonEnv;
            targetVersion = "py312";
            projectScope = "src";
          };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pythonEnv
              pkgs.uv
              pkgs.black
              pkgs.mypy
              pkgs.jq # used by the shellHook below

              # Not needed on PATH — Claude invokes it by absolute store path —
              # but listing it makes the hook a dependency of this shell, so
              # nix-collect-garbage cannot delete the path settings.local.json
              # points at.
              (claude-python-fix.lib.mkHook hookArgs)
            ];

            env = {
              # Pin uv to the Nix-provided interpreter and keep it from
              # downloading its own Pythons or syncing a venv — Nix owns
              # the environment; uv is here for `uv run` / `uvx` tooling.
              UV_PYTHON = "${pythonEnv}/bin/python";
              UV_PYTHON_DOWNLOADS = "never";
              UV_NO_SYNC = "1";
            };

            # Point Pylance at the Python environment Nix just built. The store
            # path changes whenever projectDeps or nixpkgs move, so recompute it
            # on every shell entry and merge it into .vscode/settings.json,
            # leaving any other settings in that file untouched.
            shellHook = ''
              vscodeSettings=.vscode/settings.json

              desired=$(jq -n \
                --arg interpreter "${pythonEnv}/bin/python" \
                --arg sitePackages "${pythonEnv}/${pkgs.python3.sitePackages}" \
                '{
                   "python.defaultInterpreterPath": $interpreter,
                   "python.analysis.extraPaths": [ $sitePackages ]
                 }')

              if [ -f "$vscodeSettings" ]; then
                if ! merged=$(jq --argjson desired "$desired" '. * $desired' "$vscodeSettings" 2>/dev/null); then
                  echo "warning: $vscodeSettings is not valid JSON (comments?) — leaving it alone" >&2
                  merged=""
                fi
              else
                merged=$desired
              fi

              # Only write when the content actually changes, so VS Code's file
              # watcher does not reload on every `cd` into the project.
              if [ -n "$merged" ] && [ "$merged" != "$(cat "$vscodeSettings" 2>/dev/null)" ]; then
                mkdir -p .vscode
                printf '%s\n' "$merged" > "$vscodeSettings"
                echo "updated $vscodeSettings -> ${pythonEnv}"
              fi

              # Register the black + mypy hook with Claude Code. Same reasoning
              # as the block above: the hook's store path is machine-local and
              # moves with its inputs, so .claude/settings.local.json is
              # regenerated here rather than committed.
              ${claude-python-fix.lib.settingsHook hookArgs}
            '';
          };
        }
      );
    };
}
