# Pi assets

These public themes and extensions are deployed by
`flake-modules/features/pi.nix`; provider and transport policy belong downstream.
Extensions are auto-discovered unless disabled or excluded by tool selection.
After deployment, use `/reload` for extensions; start a fresh process for changed
settings/environment defaults.

## Apply Patch

`apply_patch` accepts `create_file`, `update_file` and `delete_file` operations
with headerless V4A diffs. It is a custom function tool, not the Responses API's
native tool type. Pi's `edit` and `write` remain available as fallbacks.

Updates publish atomically and preserve ownership/permissions except setuid and
setgid bits. Symlinks update their referent; multi-hard-linked files are rejected.
**ACLs and extended attributes are not retained.** Updates need target write
access and parent-directory create/rename permission. Non-sticky group/world-
writable parents are rejected. Coordinate external writers separately: concurrent
change detection is best effort, not filesystem compare-and-swap.

Failures before publication leave target content unchanged. Interruption or
cleanup failure can leave a private staging directory beside the target. The
rendered preview is the submitted patch, not a computed filesystem diff.

## Settings and external editing

Shared defaults use regular terminal mode and add codemode with
`defaultTools: ["+codemode"]`. A plain-name allowlist replaces tool selection;
`+` preserves the usual tools. Host defaults can override shared values;
`settingsDefaults = null` disables settings activation.

Activation merges configured defaults **over conflicting mutable values** in
`~/.pi/agent/settings.json`. Invalid JSON and symlinks are rejected unchanged.
Existing owner/group/permissions are retained; new files use `0600`. Coordinate
concurrent editors/Pi processes rather than relying on the best-effort race guard.

`EDITOR` and `VISUAL` use `emacsclient -c`. Finish editing with **`C-x #`**
(`server-edit`) to return to Pi. This opens a frame on the selected server, not
an independent Emacs process. For headless/SSH editing, explicitly use
`emacsclient -t`, or override Pi's `externalEditor` setting.

See [web tools](extensions/web/README.md) for search/fetch limits and costs.
