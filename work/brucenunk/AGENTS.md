---
finish-mode: merge-local
---

# brucenunk Repos

Finish mode is **merge-local**: squash-merge locally and push, only when authorized. Commit approval alone does not authorize merge, push or activation.

First commit the reviewed feature result; for `task-workflow`, follow its post-review commit gate. In the existing default-branch worktree (use `cwd` or `git -C`, not `git switch` in the feature worktree), run:

1. `git pull --ff-only`
2. `git merge --squash {feature-branch}`
3. `git commit -m "{message}"`
4. `git push`

Never amend or manually squash feature-branch commits; the finish operation produces the single default-branch commit.
