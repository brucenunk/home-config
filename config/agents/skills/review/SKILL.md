---
name: review
description: "Run the standardized read-only Pi diff review flow. Use for /skill:review, ad hoc code review requests, and task-workflow review phases."
---

# Review

Canonical read-only Pi diff review workflow for implementing agents. Other workflows and repo guidance should delegate capture, basis selection, worker safety, launch mechanics, and output shape to this skill rather than restating them.

Use this skill when the user asks for a review, when a task workflow reaches a review phase, or when you need an independent Pi pass over a task diff. The audience is the implementing agent, not a broad PR reviewer: return only actionable findings about correctness, regressions, security, performance, or risky design issues. If there are no actionable findings, say so plainly.

## Safety contract

- Review is read-only. Do not edit files, stage changes, commit, merge, push, apply fixes, or mutate tool/session state as part of the review run.
- The only intentional git write allowed by this skill is `git fetch --prune origin` when you explicitly choose to refresh the remote-tracking default branch before capturing review inputs.
- Use an explicit repo-appropriate diff basis. Prefer a freshly fetched remote-tracking default branch such as `origin/main` or `origin/master`. If you use a local default branch such as `main` or `master`, first verify that its worktree/ref has been fast-forwarded and is not stale.
- Preserve the committed/staged/unstaged split. Do not run `git add`, `git reset`, or broad-stage just to feed review.
- Include untracked files only when they are task-relevant regular files selected explicitly. Never silently include every untracked file.
- Treat rename-limit warnings or unexpectedly huge patch files as bad review input. Stop and diagnose the diff basis before invoking Pi.
- The Pi review worker must use `--no-approve` to ignore project-local settings/resources, `--no-context-files` to ignore ambient `AGENTS.md`/`CLAUDE.md`, `--no-session`, `--no-extensions`, `--no-skills`, `--no-prompt-templates`, and read-only built-in tools only (`read,grep,find,ls`).
- Use the host's configured Pi provider and model defaults.
- If the review cannot run, say exactly why. Do not invent or imply a successful review.

## Workflow

1. Recenter on the worktree and intended review scope.
   - Run `git status --short`.
   - Identify whether the task has committed, staged, unstaged, and explicitly selected untracked changes.
   - Decide the diff basis and state it explicitly in chat or the handoff, for example `COMMITTED_BASIS=origin/main`.

2. Refresh the default-branch basis when freshness is not already known.
   - Prefer `git fetch --prune origin` followed by `origin/main` or `origin/master`.
   - If fetching is inappropriate for the repo/task, explain why and verify the chosen local basis is current enough before review.

3. Capture review inputs and launch the read-only Pi review worker.
   - Use the helper script when available:

     ```bash
     ~/.agents/skills/review/scripts/pi-review-diff --fetch --basis origin/main
     ```

   - If task-relevant untracked regular files need review, pass each one explicitly:

     ```bash
     ~/.agents/skills/review/scripts/pi-review-diff \
       --fetch \
       --basis origin/main \
       --include-untracked relative/path/to/file
     ```

   - If the deployed helper path is unavailable but this skill exists in a worktree, run the equivalent worktree-relative script path from that repo. Do not fall back to a different review shape that weakens the safety contract.

4. Interpret the result.
   - Summarize actionable findings tersely for the implementing agent.
   - If there are no actionable findings, say so plainly.
   - If the review flagged invalid inputs, stale basis, rename-limit warnings, or oversized diffs, fix the review setup and rerun rather than treating the review as complete.

## Helper script behavior

`scripts/pi-review-diff` implements the standard review shape:

- requires `--basis <ref>` or `COMMITTED_BASIS=<ref>`
- optionally runs `git fetch --prune origin` with `--fetch`
- captures:
  - `git status --short`
  - committed diff: `git diff --no-ext-diff "$basis...HEAD"`
  - staged diff: `git diff --cached --no-ext-diff`
  - unstaged diff: `git diff --no-ext-diff`
- checks diff stderr for rename-limit warnings
- aborts before Pi if any patch file exceeds 8 MiB
- passes only the captured status/diff files plus explicitly selected untracked regular files to Pi
- launches Pi with `--thinking high`, project trust and context-file loading disabled, no persistent session, no extensions, no ambient skills, no prompt templates, and read-only tools only
- preserves the Pi exit status while cleaning up temporary review inputs

## Output expectation

The review worker should produce one of these shapes:

```markdown
No actionable findings.
```

or findings-first bullets such as:

```markdown
- `path/to/file:line`: <actionable correctness/security/performance/regression risk and why it matters>. <Suggested fix when clear.>
```

Do not pad the result with compliments, implementation summaries, or low-confidence style nits.
