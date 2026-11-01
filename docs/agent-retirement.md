# Retired launcher cleanup

Herdr and Herdsman are no longer installed by this flake. Downstream consumers
must remove their module imports, option assignments, package/helper references
and custom startup wiring before updating. Keep the independent `machines`,
`agent-catalogue`, Git and Pi configuration where used.

Removing declarations does **not** stop live processes or unregister mutable
plugins. Cleanup completion is not established by this document. Coordinate
with users before stopping services: stopping Herdsman can cancel active work
and discard its in-memory queue. Use [activation.md](activation.md) for approved
Wampa deployment.

With explicit coordination and approval:

- Linux: inspect `systemctl --user status herdsman.service`; arrange stop/disable
  and removal from the user manager. Verify inactivity and absence of its
  startup link after activation.
- Darwin: inspect `org.brucenunk.herdsman` in the user's GUI launchd domain;
  arrange unloading and removal of its managed plist. It used `RunAtLoad` and
  `KeepAlive`.
- Before losing access to the old Herdr CLI, inspect its plugin removal command
  and unlink **only** `brucenunk.herdsman`. The mutable registry is
  `$XDG_CONFIG_HOME/herdr/plugins.json`; preserve other plugins and coordinate
  any live reload separately.
- Check removal of managed Herdr/Herdsman configuration, themes, catalogue and
  plugin, the `prefix+t` action and `~/.pi/agent/extensions/herdr-agent-state.ts`.
  Already-running processes may retain these until an approved reload/restart.
- Audit user-owned shell/login/autostart hooks and private services separately.
  Public removal does not update downstream input pins or deployed generations.

Leave task notes, transcripts, worktrees, branches, session data, the plugin
registry, caches, sockets and logs intact by default. Potential remnants include
`$XDG_RUNTIME_DIR/herdsman/`, `$XDG_CACHE_HOME/herdsman/`, and Darwin's
`~/Library/Caches/herdsman/` and `~/Library/Logs/herdsman.log`. Their existence
is not permission to delete them. Do not restart shared sessions just to test
removal; verify each host separately when cleanup is authorized.
