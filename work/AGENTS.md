<!-- Managed by brucenunk/home-config. Edit there, not here. -->

# Worktree Workflow

Repositories under `~/work` use `~/work/{owner}/{repo}/{worktree}`. The primary clone is the default-branch worktree (`main` or `master`); linked task worktrees are usually named `a`–`f`. Task tooling selects the current worktree and branch.

Before bootstrapping a repository, adding worktrees, or relying on owner/repository mappings, read `~/work/REPO-SETUP.md`. It owns the generic topology and setup procedure while keeping repository inventory host-local.

## Tools

- **UI screenshots**: Use `screencapture` on macOS or `niri msg action screenshot` in a Niri session when exact UI state matters.
- **Search and path discovery**: Prefer `rg` for content and `fd` for paths; use `find` only when `fd` cannot express the query.
- **Structured data**: Prefer `jq` for JSON and `yq` for YAML or TOML rather than ad hoc text parsing.
- **GNU text tools**: GNU `sed` and `awk` are installed via Nix and available on `$PATH`.

For Emacs debugging, live evaluation, UI inspection, or a wedged `emacsclient`, read `~/work/EMACS-SERVER.md` before acting.

## Style Preferences

- **YAML formatting**: Use 2 spaces for indentation, never tabs. After creating or editing YAML files, run `yq -i -P <filename>` to keep formatting consistent.
- **File references**: When discussing files in the current repo/worktree, use worktree-relative filesystem paths such as `terraform/platform/network/vpc-cells-sharing/v2/share/main.tf`. Add `:{line}` only when the line number materially helps the reader jump to a specific location, for example `terraform/platform/network/vpc-cells-sharing/v2/share/main.tf:56`. Avoid repeating the same file reference multiple times in nearby prose; cite it once where it is most useful, then refer to the file normally. Do not use GitHub URLs for local repo file references unless the user explicitly asks for a GitHub link or the target is genuinely outside the local worktree/repo context.
- **Temporary files**: For transient logs, plans, patches, or scratch artifacts, prefer a temp directory created with `mktemp` instead of writing ad hoc files into the worktree. Do not assume `/tmp`; use `mktemp` so the platform chooses an appropriate location.

## Rules

- **Always use absolute paths** with the `cwd` parameter (e.g., `/Users/alice/work/owner/repository/a`), never `~/work/...`
- **Do not implement task changes in the default branch worktree** (`main`, `master`). Keep it as a clean reference except for repo- or owner-prescribed update, finish, merge, deploy, and verification commands.
- **One task per feature worktree** — do not mix unrelated changes.
- **Serialize state-mutating git operations** such as add, commit, fetch, merge, and other writes sharing the repository gitdir. Parallelize only safe read-only inspection.
- **Do not create or switch branches manually** — task/worktree tooling has selected the branch. Never run branch-creating or branch-switching checkout/switch commands.
- **Do not rewrite existing commits by default.** Do not amend, rebase, or squash task history unless explicitly requested or the applicable repo workflow prescribes a specific verification operation. Owner-prescribed squash merges are finish operations, not permission to rewrite feature history.
- **Do not push unless explicitly requested or required by an approved finish workflow.** Never force-push without explicit instruction for that specific action.

## Response Style

Default to concise, high-signal responses that reduce human reading effort and fatigue. This is a reading preference, not token-count optimization: preserve accuracy, caveats, and useful context when they matter.

- Lead with the direct answer or outcome before background.
- Match the length to the user's question; for narrow follow-ups, answer only the specific detail unless more context is necessary.
- Prefer short bullets for reviews, investigations, and handoffs.
- Avoid broad context, implementation logs, or restating obvious facts unless they change the decision.
- When a topic is complex, give the smallest useful answer first and offer to expand.

## High-volume Command Output

When a command can emit large amounts of refresh, render, build, or generated output, keep that output out of the user session by default and summarize the meaningful result after the run completes.

- Treat commands such as Terraform plans, Bazel renders, large test suites, and other bulky runs as high-volume by default.
- Do any interactive auth or setup steps first when possible, then run the noisy command separately so it can finish without repeated chat polling.
- Prefer capturing stdout/stderr to a file for later inspection rather than streaming or repeatedly polling the live session.
- Report concise results after completion: errors, resource counts, changed objects, output artifact paths, or a short tail section when that is enough to show the outcome.
- When inspecting captured output, use targeted summary markers or short tail/head reads instead of broad searches across the whole file that can pull large noisy sections back into chat.

## Verification Boundaries

Keep these verification modes distinct when planning, implementing, and reporting evidence:

- **Isolated worktree verification** checks code from the current feature worktree without claiming anything about merged, deployed, or live shared runtime state. Typical examples include local tests, batch-mode checks, static analysis, or inspecting generated artifacts in the worktree.
- **Downstream verification** checks a later delivery stage such as merged code, deployed artifacts, applied configuration, CI, git-ops reconciliation, or another system that now carries the change. This is often the strongest currently available proof point.
- **Runtime pickup verification** checks whether a long-lived shared process or live environment has actually loaded and is executing the updated deployed code or configuration. This is narrower than deployment success and should only be claimed when that live pickup was verified directly.

Do not collapse deployment or apply success into runtime pickup success unless repo-specific guidance explicitly says they are equivalent. When runtime pickup matters, follow the most specific applicable `AGENTS.md` for the safe procedure and boundaries.

## Task Guidance

When you need to resolve a Denote task identifier or create, defer, inspect, edit, link dependencies for, or complete a task, read `~/work/TASKS.md` before acting. It owns task identity, file format, handoff content, dependencies, and completion mechanics.
