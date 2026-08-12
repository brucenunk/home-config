<!-- Managed by brucenunk/home-config. Edit there, not here. -->

# Worktree Topology and Repository Setup

Read this guide before bootstrapping a repository under `~/work`, adding its
standard worktrees, or relying on owner/repository mappings.

## Worktree layout

Repositories use this structure:

```text
~/work/{owner}/{repo}/{worktree}
```

- `~/work/{owner}/{repo}/{default-branch}` — primary clone and default-branch
  worktree, containing the shared `.git/` directory.
- `~/work/{owner}/{repo}/{a-f}` — detached linked worktrees reserved for tasks.
- `~/work/{owner}/AGENTS.md` — owner-level policy such as the finish workflow.

Use the exact remote owner and repository casing. Repository inventory and
owner mappings are host-local operational data; inspect the target remote rather
than maintaining a private repository list in this public guide.

## Choose fetch policy

Determine the remote's default branch before setup. Use full branch refspecs for
small repositories. For large repositories, fetch only the default branch and
the task branch namespace to reduce initial transfer and local metadata.

- Full: `+refs/heads/*:refs/remotes/origin/*`
- Selective default branch:
  `+refs/heads/{default-branch}:refs/remotes/origin/{default-branch}`
- Selective task branches:
  `+refs/heads/jamesl-*:refs/remotes/origin/jamesl-*`

## Git init recipe

Use `git init`, rather than `git clone`, when setting up the managed topology.
This permits the refspec and partial-clone configuration to be established
before the first fetch.

```sh
owner={owner}
repo={repo}
branch={default-branch}
fetch_policy=full # Set to selective for a large repository.
primary="$HOME/work/$owner/$repo/$branch"

mkdir -p "$primary"
git -C "$primary" init
git -C "$primary" remote add origin "https://github.com/$owner/$repo.git"

git -C "$primary" config --unset-all remote.origin.fetch || true
case "$fetch_policy" in
  full)
    git -C "$primary" config --add remote.origin.fetch \
      '+refs/heads/*:refs/remotes/origin/*'
    ;;
  selective)
    git -C "$primary" config --add remote.origin.fetch \
      "+refs/heads/$branch:refs/remotes/origin/$branch"
    git -C "$primary" config --add remote.origin.fetch \
      '+refs/heads/jamesl-*:refs/remotes/origin/jamesl-*'
    ;;
  *)
    printf 'unknown fetch policy: %s\n' "$fetch_policy" >&2
    exit 2
    ;;
esac

git -C "$primary" config remote.origin.partialclonefilter blob:none
git -C "$primary" config remote.origin.promisor true
git -C "$primary" fetch origin --filter=blob:none --no-tags
git -C "$primary" checkout -b "$branch" "origin/$branch"

for slot in a b c d e f; do
  git -C "$primary" worktree add "../$slot" --detach HEAD
done
```

After setup, use the deployed worktree helper to allocate, resume, and release
linked worktrees. Do not hand task work to the primary default-branch worktree.
