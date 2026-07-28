{
  description = "Python project with Nix-managed dependencies, uv, black, and mypy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Project dependencies live here, not in pyproject.toml.
      # Add packages from nixpkgs' python3Packages set.
      projectDeps = ps: with ps; [
        requests
      ];
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.python3Packages.buildPythonApplication {
          pname = "myproject";
          version = "0.1.0";
          pyproject = true;
          src = ./.;
          build-system = [ pkgs.python3Packages.hatchling ];
          dependencies = projectDeps pkgs.python3Packages;
        };
      });

      devShells = forAllSystems (pkgs:
        let
          pythonEnv = pkgs.python3.withPackages projectDeps;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pythonEnv
              pkgs.uv
              pkgs.black
              pkgs.mypy
              pkgs.jq # used by the shellHook below
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
            '';
          };
        });
    };
}
