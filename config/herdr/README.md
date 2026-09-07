# Herdr configuration

The reusable Home Manager `herdr` capability installs Herdr's configuration,
themes, Pi integration, and the `herdr-sync-workspaces` helper.

## Synchronizing managed workspaces

Run the helper with one repository **container**, not an individual checkout:

```console
$ herdr-sync-workspaces ~/work/brucenunk/home-config
```

For one-time setup across the existing managed repositories, use `fd` to find
repository containers at depth two and invoke the single-repository helper for
each one:

```console
$ while IFS= read -r -d '' repo; do
    if fd --hidden --quiet --type d --exact-depth 2 '^\.git$' "$repo"; then
      herdr-sync-workspaces "$repo"
    fi
  done < <(fd --type d --exact-depth 2 --print0 . "$HOME/work")
```

This scan is deliberately external to the helper; normal use still operates on
one explicitly selected repository. The inner `fd` check filters out unrelated
depth-two directories by requiring a primary checkout with a `.git` directory.

The container must follow the managed layout
`$HOME/work/<owner>/<repo>`. The helper discovers the repository's primary
checkout and Git worktree inventory, then synchronizes only linked worktrees
that are direct children of the container. A linked checkout such as
`~/work/brucenunk/home-config/a` gets the canonical Herdr Space label
`home-config/a`. This keeps the repository and reusable worktree slot visible
within Herdr's default sidebar width.

An already-open linked checkout is renamed when necessary. A linked checkout
without an open or canonically labelled Space gets a new unfocused Space.
Canonical labels remain stable identifiers if Herdr can no longer infer an
ordinary Space's checkout after its shell changes directory, so repeated runs
converge without creating duplicates. Sync operations are serialized because
Herdr does not provide an atomic create-if-missing operation; a concurrent run
exits rather than racing to create the same Space.

After synchronizing, the helper sorts every Space in the current Herdr session
lexically by label. Herdr has no configuration option for Space sorting, so the
helper uses the release-matched `workspace.move_block` socket API to apply the
complete order atomically. This intentionally gives manually created and
integration-created Spaces the same consistent ordering as managed worktrees.

The helper performs all topology, Git, Herdr connectivity, and JSON-response
preflight before changing Herdr state. It never creates, removes, attaches,
detaches, fetches, or switches Git worktrees or branches. It also never opens
the primary/default checkout, which remains a clean reference under the
managed worktree workflow.

Existing primary-checkout or stale Spaces are left untouched. The helper does
not close Spaces or terminate their processes.