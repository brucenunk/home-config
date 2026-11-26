<!-- Managed by brucenunk/home-config. Edit there, not here. -->

# For agents

## Tooling

- Prefer `rg` for content, `fd` for paths, and `jq`/`yq` for structured data.
- Use `web_search`/`web_fetch` for public web research, not shell HTTP clients.

## Git

- Use `gh`/`gh api` to access Github.
- Push only when explicitly requested; force-push requires explicit authorization for that action.
- When pushing to remote, use `jamesl/` prefix and a meaningful suffix.
- Keep primary clones at `~/work/<repo>` and new linked worktrees at `~/worktrees/<repo>/<worktree>`. Use Git to discover existing checkouts rather than inferring their paths.
- Merge locally only when explicitly requested. Commit the reviewed feature first. Identify the default branch (for example via `origin/HEAD`) and find its checkout with `git worktree list --porcelain`; ask if unclear. In that checkout, pull with `git pull --ff-only`, squash-merge the feature branch, and commit. Don't switch branches in the feature worktree or rewrite its commits.

## Context management

- Put scratch artifacts and captured logs in a `mktemp` directory outside the worktree; do not assume `/tmp`.
- Capture bulky command output to a file rather than streaming to preserve the context window.

## Coding style

- Prefer the simplest solution.
- Prioritise readability, both for maintenance and review.
- Use spacing to breakup sections of code.
- Prefer lexical sorting of variables where no other grouping makes sense.
- Match variable name length to variable scope.
- Be idiomatic.
- Be pragmatic, don't attempt to cover every possible scenario at the expense of readability.
- When writing tests, add comments to walk the reader through the scenario.
- When writing tests, prefer setup, execute, assert style tests.
- When writing tests, prefer simple in-memory fakes over mocks.

## Formatting

- Format YAML with 2-space indentation, no tabs; run `yq -i -P <filename>` after edits.
- Before creating or restyling `.excalidraw` diagrams, read the selected palette under `${XDG_CONFIG_HOME:-~/.config}/excali/palettes/`.
