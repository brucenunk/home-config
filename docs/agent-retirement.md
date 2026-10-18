# Herdr and Herdsman retirement

Herdr and the repository-owned Herdsman launcher are no longer installed or
configured by this flake. Their Home Manager modules/options, package exports,
`flake.lib.herdr.packageFor`, compatibility patch/version guard, build checks,
Go implementation/dependencies, themes, Pi state extension, and plugin/service
integration have been removed. No flake inputs were updated for this removal.

Pi, Emacs agent-shell, task capture/listing, Git maintenance, and the independent
machine/model/repository inventory and Emacs catalogue remain supported. Use the
three explicit [human-operated Emacs launch commands](agent-session.md).
They do not orchestrate other agents or perform automatic session/worktree
cleanup. Agents must not create branches/worktrees manually.

## Downstream consumers

This is an intentional breaking removal of `modules.homeManager.herdr`,
`modules.homeManager.herdsman`, their `brucenunk.homeManager` options,
`packages.<system>.herdr`, `packages.<system>.herdsman`, and the Herdr package
helper. Consumers must remove imports, option assignments, direct package/helper
references, custom service/launcher wiring, and obsolete check invocations
before updating their public input.

The private `canvanauts/jamesl-home-config` consumer owns Woowoo/Devbox policy.
It was not accessible to the retirement audit (GitHub API returned 404); its
owner must audit and verify both configurations separately. Updating this
public repository does not update private pins or deployed generations.
Keep `machines`, `agent-catalogue`, Git, and Pi imports where used, retaining
`brucenunk.homeManager.machines` inventory and explicit remote browsing
directories. Do not remove shared model/repository data with launcher options.
The machine name `local` is now an ordinary catalogue key, not a routing alias.

## Live cleanup is separate

Removing declarations and building an activation package do **not** stop live
processes, unlink a mutable plugin registration, activate configuration, or prove
runtime pickup. The pre-removal Wampa audit found `herdsman.service` enabled and
active, and its mutable registry contained an enabled `brucenunk.herdsman`
registration. Nothing was stopped or deleted from live state during implementation.

Before any approved deployment, coordinate with users of existing sessions and
inspect the active daemon/queue and Herdr processes. Stopping Herdsman can cancel
active work and discard its in-memory queue; do not stop it while work may be in
flight. Follow [activation.md](activation.md) for the exact source/target route.

Retirement follow-up, only with explicit coordination and approval:

- Linux: inspect `systemctl --user status herdsman.service`, then arrange its
  stop/disable and removal from the user manager. Verify both inactive state and
  absence of its startup link after activation; do not infer this from a build.
- Darwin consumers: inspect the launchd label `org.brucenunk.herdsman` in the
  user's GUI domain, then arrange unloading and removal of its managed plist.
  It previously used both `RunAtLoad` and `KeepAlive`.
- The former activation hook ran `herdr plugin link` for
  `brucenunk.herdsman`. Its registration is mutable in
  `$XDG_CONFIG_HOME/herdr/plugins.json` (normally
  `~/.config/herdr/plugins.json`); removing the hook and generated plugin does
  not unregister it. Before losing access to the old CLI, inspect its supported
  plugin removal command and unlink **only** that ID, preserving other plugins.
  Coordinate any live plugin reload/restart separately.
- Verify removal of the managed Herdr config/themes, Herdsman
  config/catalogue/themes/plugin, `prefix+t` plugin action, and
  `~/.pi/agent/extensions/herdr-agent-state.ts`. Already-running Pi or Herdr
  processes may retain loaded integration/configuration until separately
  coordinated reload or restart. Do not restart shared sessions just to test it.
- Audit user-owned shell/login/autostart hooks and private replacement services
  separately. The removed public startup paths were the Linux systemd unit,
  Darwin launchd agent, and plugin-registration activation hook; the plugin
  launcher itself was on-demand, not an autostart service.

Leave task notes, transcripts, worktrees, branches, Herdr session data/plugin
registry, Herdsman cache/socket/lock directories, and logs intact by default.
Potential remnants include `$XDG_RUNTIME_DIR/herdsman/`,
`$XDG_CACHE_HOME/herdsman/` (or `~/.cache/herdsman/`), and Darwin
`~/Library/Caches/herdsman/` and `~/Library/Logs/herdsman.log`. They are not
declarative configuration and are not a mandate to delete mutable state.

Verify installation/configuration removal, service state, and actual runtime
pickup separately on each affected host. A later full flake-input bump is a
separate task; this retirement does not retry or deliver one.
