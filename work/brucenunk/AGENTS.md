---
finish-mode: merge-local
---

# brucenunk Repos

Personal repositories. Finish mode is **merge-local** (squash-merge locally and push).

## Git Finish Workflow (merge-local)

When finishing a task on a merge-local repo, first ensure the reviewed feature result is committed. For a `task-workflow-v3` task, use its post-review commit gate; commit approval does not authorize the later merge or push.

Then:

1. Switch to the default branch worktree (e.g., `~/work/brucenunk/home-config/main`)
2. Pull latest: `git pull --ff-only`
3. Squash-merge the feature branch: `git merge --squash {feature-branch}`
4. Commit: `git commit -m "{message}"`
5. Push: `git push`

All commands run **in the default branch worktree directory** (use `cwd` or `git -C`). Do NOT `git switch` in the feature worktree.

## Commit Hygiene

- Never amend or manually squash feature-branch commits. Keep useful checkpoints separate for review; the prescribed `git merge --squash` finish step produces the single default-branch commit.
