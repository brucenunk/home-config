# Hephaestus

Hephaestus allocates, resumes, and releases worktrees in the fixed
`~/work/{owner}/{repo}/{worktree}` layout.

## Git environment

Hephaestus accepts two deployment-facing environment variables:

- `HEPHAESTUS_GIT` selects the Git-compatible executable. It defaults to `git`
  from `PATH` and may be an absolute path.
- `HEPHAESTUS_VFS_MODE` selects worktree discovery. It defaults to `none`;
  set it to `edenfs` for a bare backing repository plus mounted default
  worktree layout. Other values are rejected.

In `edenfs` mode, Hephaestus discovers the non-bare registered worktree attached
to the remote default branch. Bare entries from `git worktree list --porcelain`
are never eligible for allocation, resume, or release.

Hephaestus does not override `core.fsmonitor`. The selected Git executable and
repository configuration retain control of filesystem monitoring and any VFS
reconciliation behavior.
