<!-- Managed by brucenunk/home-config. Edit there, not here. -->

# Pi Working Agreements

## Tools and Files

- Prefer `rg` for content, `fd` for paths, and `jq`/`yq` for structured data.
- Use `web_search`/`web_fetch` for public web research, not shell HTTP clients. For GitHub, use `gh`/`gh api` instead; never bypass this with another HTTP client, even on failure. Report access limitations.
- For exact UI state, use `screencapture` on macOS or `niri msg action screenshot` in Niri.
- Before Emacs debugging, live evaluation, UI inspection, or troubleshooting a wedged `emacsclient`, read `~/work/EMACS-SERVER.md` for safe server access.
- Before creating or restyling `.excalidraw` diagrams, read `${XDG_CONFIG_HOME:-~/.config}/excali/README.md` and the selected palette under `excali/palettes/`. Ask if unavailable; do not invent colours. Preserve initial palette provenance and unrelated metadata.
- Format YAML with 2-space indentation, no tabs; run `yq -i -P <filename>` after edits.
- Cite local files using worktree-relative paths, with `:line` only when useful. Avoid repeated references and use GitHub links only when requested or for external files.
- Put scratch artifacts and captured logs in a `mktemp` directory outside the worktree; do not assume `/tmp`.
- Use absolute paths for `cwd` parameters, never `~/...`.

## Git

- Keep one task per feature worktree; do not mix unrelated changes.
- Serialize state-mutating Git operations sharing a gitdir, including fetch, add, commit and merge. Parallelize only read-only inspection.
- Do not amend, rebase or squash existing task history unless explicitly requested or a repository-prescribed verification operation requires it. An owner-prescribed squash merge is a finish operation, not permission to rewrite feature history.
- Push only when explicitly requested or required by an approved finish workflow. Force-push requires explicit authorization for that action.

## Documentation and Task Notes

Document only necessary operations, safety constraints or important non-obvious rationale; prefer rationale beside code. Do not add implementation summaries, inventories, coverage lists, verification reports, migration histories or audit reports unless requested. Keep task evidence in chat and delete obsolete prose.

Before creating or editing follow-up notes, read `~/work/TASKS.md` for note format and launch conventions. A launcher-supplied snapshot is sufficient context: do not hunt for its original file or resolve Denote identifiers at startup. The source may exist only on the Emacs host.

## Command Output and Verification

Capture bulky command output to a file rather than streaming or repeatedly polling it. Complete interactive setup first when possible; inspect targeted summaries and report errors, counts, changed objects or artifact paths after completion.

Distinguish isolated worktree checks, downstream delivery/deployment, and verified live runtime pickup. A build or deployment does not prove a long-lived process loaded the change. Follow the applicable repository procedure for live checks and claim only the stage directly verified.