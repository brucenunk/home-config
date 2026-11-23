<!-- Managed by brucenunk/home-config. Edit there, not here. -->

# For agents

## Tooling

- Prefer `rg` for content, `fd` for paths, and `jq`/`yq` for structured data.
- Use `web_search`/`web_fetch` for public web research, not shell HTTP clients.

## Git

- Use `gh`/`gh api` to access Github.
- Push only when explicitly requested; force-push requires explicit authorization for that action.
- Keep primary clones at `~/work/<repo>` and new linked worktrees at `~/worktrees/<repo>/<worktree>`. Use Git to discover existing checkouts rather than inferring their paths.
- Merge locally only when explicitly requested. Commit the reviewed feature first. Identify the default branch (for example via `origin/HEAD`) and find its checkout with `git worktree list --porcelain`; ask if unclear. In that checkout, pull with `git pull --ff-only`, squash-merge the feature branch, and commit. Don't switch branches in the feature worktree or rewrite its commits.

## Context management

- Put scratch artifacts and captured logs in a `mktemp` directory outside the worktree; do not assume `/tmp`.
- Capture bulky command output to a file rather than streaming to preserve the context window.

## Formatting

- Format YAML with 2-space indentation, no tabs; run `yq -i -P <filename>` after edits.
- Before creating or restyling `.excalidraw` diagrams, read the selected palette under `${XDG_CONFIG_HOME:-~/.config}/excali/palettes/`.

## Coding style
