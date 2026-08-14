
# Test

## Integration Test

One command runs the full QEMU/NixOS VM test (design.md section 8):

```bash
ANTHROPIC_API_KEY=sk-ant-... nix run .#integration-test
```

`CLAUDE_CODE_OAUTH_TOKEN` works in place of `ANTHROPIC_API_KEY`.

No manual step exists: no `sudo`, no `/etc` file, no separate builder
terminal. On macOS the runner boots its own `darwin.linux-builder` VM,
builds the Linux guest closure on it over user-owned SSH, imports the
result, and then builds and runs the test driver locally. The builder
state (disk image, SSH keys) lives in `~/.cache/reprompt/linux-builder`
and is reused on later runs.

Host prerequisites (design.md section 7):

- Nix 2.19 or later with the `nix-command` and `flakes` features.
- Your user in the Nix daemon's `trusted-users` (the unsigned store-path
  import needs it).
- Network access: the test runs a real `claude` session against
  `api.anthropic.com`.
