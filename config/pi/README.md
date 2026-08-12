# Personal Pi assets

Themes and extensions in this directory are public-safe personal assets. The
generic Home Manager deployment module is `flake-modules/features/pi.nix`; it
does not define provider or transport policy.

Extensions under `config/pi/extensions/` are deployed globally and
auto-discovered by Pi. They are active by default unless extension or tool
discovery is disabled or an explicit tool allowlist excludes them. Existing
sessions need `/reload` after deployment; new Pi processes load them at startup.

## Apply Patch

`apply-patch` registers an `apply_patch` tool that emulates [OpenAI's documented
file-operation shape and headerless V4A diff
behavior](https://developers.openai.com/api/docs/guides/tools-apply-patch) for
`create_file`, `update_file`, and `delete_file`. Pi exposes it as a custom
function tool rather than the Responses API's native `apply_patch` tool type,
so equivalent model behavior is not guaranteed.

The V4A diff implementation is adapted from OpenAI Agents JS under the bundled
MIT license. The tool uses Pi's shared file-mutation queue, refuses to overwrite
existing files during creation, and atomically publishes updates from a unique
private staging directory created beside the target on the same filesystem.
Updates preserve the target's permission bits,
owner, and group, except that setuid and setgid bits are cleared after content
modification. Temporary content remains inside the owner-only staging directory
until publication, including after its final mode is applied.
Updates through a symlink replace its referent while retaining the symlink.
Files with multiple hard links are rejected rather than breaking
their shared inode relationship. Inode-specific metadata that cannot be carried
by Node's portable filesystem API, such as ACLs and extended attributes, is not
retained after a successful replacement. Errors before the atomic rename leave
target bytes, inode identity, ownership, mode, size, and modification time
unchanged; reading and validating the target may update its access time. Normal
success and failure paths attempt to remove temporary artifacts. Cleanup is
best-effort: a cleanup error does not mask the publication result and can leave
the private staging directory behind. Cancellation is honored before
publication. An uncatchable interruption can also leave a temporary artifact,
but the target is always wholly old or wholly new. Pi's built-in `edit` and
`write` tools remain available as fallbacks.

Atomic update requires both write access to the target and permission to create
and rename files in its parent directory. It does not use directory permissions
to bypass a read-only target. The updater must also be able to reproduce the
target owner and group; otherwise it fails before publication. Non-sticky
group- or world-writable parent directories are rejected. The mutation queue is
keyed by the resolved referent so Pi updates through aliases serialize, and a
final identity, metadata, permission, symlink-target, and content check rejects
concurrent changes observed before rename. That check is best effort rather than
a filesystem compare-and-swap: external writers that do not use Pi's mutation
queue must still be coordinated separately.

## Settings defaults

When configured, settings defaults are merged into mutable
`~/.pi/agent/settings.json` during Home Manager activation. Missing settings
start from an empty object. Configured defaults retain the module's existing
precedence over conflicting mutable values. If an existing settings file is
invalid JSON, activation fails with a diagnostic and preserves the invalid file
byte for byte rather than replacing it with an empty object. Settings and
defaults must each contain exactly one JSON object; JSON streams and non-object
values are rejected. For an initially missing settings path, publication uses
an atomic no-clobber hard link and fails without modifying a file created
concurrently. For an existing file, activation merges a validated snapshot and
refuses publication when it observes that the mutable path changed while the
merge was running.
That existing-file check is a best-effort guard, not a portable filesystem
compare-and-swap or coordination with a concurrently running Pi or editor.
Settings symlinks, including dangling symlinks, are rejected unchanged.
Existing settings retain their owner, group, and permission bits; a newly
created settings file uses mode `0600`.
