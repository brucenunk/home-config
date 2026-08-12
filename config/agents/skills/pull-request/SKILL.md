---
name: pull-request
description: "Prepare and deliver a human-reviewed GitHub pull request in repositories with finish-mode: pull-request. Use when asked to push review-ready work, draft a PR description, create a PR, or update its body."
---

# Pull Request

Simple human-reviewed PR handoff for work that has already been implemented, verified, reviewed, and committed.

## Boundaries

- Confirm the applicable repository policy declares `finish-mode: pull-request`. Otherwise follow that repository's finish workflow.
- Preserve the task-selected local branch. Never create, rename, or switch a local branch.
- Do not force-push unless the user explicitly requests it for that exact push. Do not otherwise rewrite history.
- Never merge or enable auto-merge.
- Push, PR creation, and later PR updates each require an explicit user request. An explicit request to raise, create, or deliver a PR authorizes the ordinary initial push required for that delivery, but does not bypass the PR-body review below or authorize any later update.
- If intended changes are still staged or uncommitted, return to the active implementation workflow's commit step. This skill does not stage or commit them.
- Perform only the requested operation. A request only to draft a PR body, commit work, or otherwise prepare without delivering does not authorize a push.

## 1. Push the reviewed work

Recenter on the branch, status, and reviewer-relevant diff. Confirm the intended work is committed, identify the reviewed commit, and ensure unrelated local state will not be included.

Determine whether the user's current request authorizes a push:

- An explicit request to push or to raise, create, or deliver the PR does. Proceed without asking for another push approval.
- A drafting-only, commit-only, or other preparation request does not. Ask for explicit approval before pushing, then pause.

Choose a concise, human-readable remote branch matching `jamesl-<topic>`. Check that it is not already in use, select another safe name if needed, and do not ask the user to approve the name.

Immediately before pushing, recheck that `HEAD` is the reviewed commit, the worktree status is still safe, and the selected remote branch remains absent. Stop if any check fails. Push current `HEAD` with an explicit refspec and without `-u`:

```bash
git push origin HEAD:refs/heads/jamesl-<topic>
```

Do not rename, switch, or change the upstream of the local branch. Do not force-push.

## 2. Draft the PR body

For full delivery, draft after the push. For a standalone drafting request, first inspect the supplied task context and relevant diff or PR so the text is grounded in the actual change.

Create the body outside the repository:

```bash
body_dir="$(mktemp -d)"
body_file="$body_dir/pr-body.md"
: > "$body_file"
printf '%s\n' "$body_file"
```

Write a short draft with this structure:

```markdown
## Context

Why this change is needed now.

## Intent

What outcome and design choices the change introduces.

## Changes

The meaningful reviewer-facing behavioral changes.
```

Keep it decision-focused:

- Explain behavior and design choices, not a file list or implementation log.
- Summarize generated or mechanical diff volume by its meaningful effect.
- Omit verification unless it materially helps reviewers assess risk.
- Preserve user-written wording and make only requested edits.

Show the user the temporary file's full path and the complete draft. Ask them to edit that file directly, then pause. Do not create the PR yet.

## 3. Create the PR

Only after the user confirms their edits are complete and explicitly asks to create the PR:

1. Read the same file without silently rewriting it.
2. Check that a PR does not already exist and that the remote branch still points to the commit that was reviewed and pushed. Stop if it changed; keep this check internal unless there is a problem.
3. Create the PR using the edited file:

   ```bash
   gh pr create \
     --base <base> \
     --head jamesl-<topic> \
     --title "<title>" \
     --body-file <literal-body-file-path>
   ```

Report the PR URL. Do not merge or enable auto-merge.

## Later body updates

Reuse the same temporary file while it exists, but first fetch the PR's current body. If it differs from the file, show both versions and ask the user to reconcile them rather than overwriting the live edit.

1. Show the file's path and current contents.
2. Ask the user to edit it directly, then pause.
3. After explicit confirmation, fetch the live body once more. If it changed while the user was editing, stop for reconciliation; otherwise update the identified PR:

   ```bash
   gh pr edit <pr-number-or-url> --body-file <literal-body-file-path>
   ```

If the file no longer exists, create a new temporary directory with `mktemp -d`, fetch the PR's current body into `pr-body.md` within it, and repeat the edit-and-confirm step. Update the existing PR; never create a second one for a body edit.
