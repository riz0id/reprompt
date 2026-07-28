# python-project-template

Python project where Nix manages the dependencies. The dev shell provides
Python (with all project deps), `uv`, `black`, and `mypy`.

## Usage

```sh
nix develop        # or `direnv allow` if you use direnv
python -m myproject.main
black src
mypy
```

Build and run the packaged application:

```sh
nix build
./result/bin/myproject
```

## VS Code / Pylance

Entering the dev shell writes the current Nix Python environment's store path
into `.vscode/settings.json` (`python.defaultInterpreterPath` and
`python.analysis.extraPaths`), so Pylance resolves imports for everything in
`projectDeps`. That path changes whenever `projectDeps` or nixpkgs move, which
is why it is refreshed on every shell entry — with direnv this happens
automatically on `cd`.

Other keys in the file are preserved (the update is a JSON merge), and the file
is only rewritten when the path actually changes. Two caveats: the file must be
strict JSON — comments make the hook warn and skip rather than clobber your
settings — and it is gitignored, since store paths are machine-local. Reload the
VS Code window if Pylance does not pick up a change.

## Managing dependencies

Add runtime dependencies to `projectDeps` in `flake.nix` (they come from
nixpkgs' `python3Packages` set), then re-enter the shell. `dependencies` in
`pyproject.toml` intentionally stays empty; `uv` is pinned to the Nix
interpreter and never installs packages or Pythons itself — it is available
for `uv run` / `uvx` tooling.
