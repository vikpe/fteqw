# Workflow rules

## After every code change: run the sync script

After any change that produces a fresh build artifact (engine `ftewebgl.{js,wasm}`
or `hub_addon/csaddon.dat`), run `.claude/scripts/sync-fte-to-slipgate.sh`
so the slipgate web app serves the updated build.

**Why:** the script is configured as a PostToolUse hook keyed on the build
command pattern (`gl-rel.*LINK_EZHUD` or `make.*hub_addon`). On this
machine the hook auto-fires after matching builds, but the user wants
explicit runs as a belt-and-braces guarantee — sync drift means the
website silently serves a stale binary.

**How to apply:**

- After `make -j... gl-rel LINK_EZHUD=1 LINK_OPENSSL=1` (engine):
  invoke the script with a stub stdin that satisfies the regex, then
  verify the slipgate destination timestamp matches the build output.
- After `make` in `hub_addon/` (CSQC): same pattern; the script's
  addon branch copies `csaddon.dat`.
- Invocation (works on any machine with matching paths):

  ```bash
  echo '{"tool_input":{"command":"make gl-rel LINK_EZHUD=1"}}' \
    | bash .claude/scripts/sync-fte-to-slipgate.sh
  ```

  (Use `make hub_addon` in the JSON for addon-only syncs.)

- Verify with `ls -la <slipgate-public-fte>/ftewebgl.wasm` —
  timestamps should match the freshly built file.

The script silently no-ops if the source paths don't exist (per-machine
layout differences), so running it on a machine without a slipgate
checkout is harmless.
