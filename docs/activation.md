# Wampa activation matrix

Read this procedure when deploying
`homeConfigurations."james@wampa"`. Choose the row from the machine holding
the source checkout and the activation target.

| Source checkout | Target | Source state |
| --- | --- | --- |
| Wampa | Wampa | Clean commit or deliberately staged tree |
| Woowoo | Wampa | Clean commit already pushed to `origin/main` |

The Woowoo route uses the machine-local SSH alias `wampa`. Its address and
private-key path do not belong in this repository.

## Evidence boundaries

- `./scripts/check-home-configuration . 'james@wampa'` evaluates and builds the
  activation package without activating it.
- A successful activation command proves that Home Manager activated the
  selected source on Wampa.
- Activation does not prove that Emacs, Pi, or another long-lived process has
  loaded the new files. Verify runtime pickup separately when needed.

## Wampa to Wampa

Run this from the intended Wampa checkout. A staged activation is deliberate:
review `git diff --cached` first. The checks reject unstaged and untracked
source, print the base revision and intended tree, and confirm that activation
does not modify `flake.lock`.

```sh
(
  set -eu

  expected_origin='https://github.com/brucenunk/home-config.git'
  test "$(hostname -s | tr '[:upper:]' '[:lower:]')" = wampa
  test "$(id -un)" = james
  test "$(git remote get-url origin)" = "$expected_origin"

  git diff --quiet
  untracked=$(git ls-files --others --exclude-standard)
  test -z "$untracked"
  git diff --cached --check

  printf 'source=%s\nrevision=%s\ntree=%s\ntarget=wampa\n' \
    "$(git rev-parse --show-toplevel)" \
    "$(git rev-parse HEAD)" \
    "$(git write-tree)"

  lock_before=$(git hash-object flake.lock)
  nix run --no-update-lock-file \
    '.#homeConfigurations."james@wampa".activationPackage'
  test "$(git hash-object flake.lock)" = "$lock_before"
)
```

For a clean activation, `git diff --cached` is empty and `git write-tree`
equals `git rev-parse 'HEAD^{tree}'`.

## Woowoo to Wampa

Use this route only after the intended change has been committed, merged to
`main`, and pushed. It updates Woowoo's and Wampa's authoritative checkouts with
fast-forward-only pulls, then activates the exact commit observed on Woowoo.

```sh
(
  set -eu

  expected_origin='https://github.com/brucenunk/home-config.git'
  source_checkout="$HOME/work/brucenunk/home-config/main"

  test "$(uname -s)" = Darwin
  test "$(uname -m)" = arm64
  test "$(git -C "$source_checkout" remote get-url origin)" = "$expected_origin"
  test "$(git -C "$source_checkout" branch --show-current)" = main
  source_status=$(git -C "$source_checkout" status --porcelain=v1 --untracked-files=all)
  test -z "$source_status"

  git -C "$source_checkout" pull --ff-only origin main
  intended_revision=$(git -C "$source_checkout" rev-parse HEAD)
  intended_tree=$(git -C "$source_checkout" rev-parse 'HEAD^{tree}')
  test "$(git -C "$source_checkout" rev-parse FETCH_HEAD)" = \
    "$intended_revision"
  printf 'source=%s\nrevision=%s\ntree=%s\ntarget=wampa\n' \
    "$source_checkout" "$intended_revision" "$intended_tree"

  ssh wampa sh -s -- "$intended_revision" "$intended_tree" <<'WAMPA'
set -eu

intended_revision=$1
intended_tree=$2
expected_origin='https://github.com/brucenunk/home-config.git'
target_checkout="$HOME/work/brucenunk/home-config/main"

test "$(hostname -s | tr '[:upper:]' '[:lower:]')" = wampa
test "$(id -un)" = james
test "$HOME" = /home/james
test "$(git -C "$target_checkout" remote get-url origin)" = "$expected_origin"
test "$(git -C "$target_checkout" branch --show-current)" = main
target_status=$(git -C "$target_checkout" status --porcelain=v1 --untracked-files=all)
test -z "$target_status"

git -C "$target_checkout" pull --ff-only origin main
test "$(git -C "$target_checkout" rev-parse HEAD)" = "$intended_revision"
test "$(git -C "$target_checkout" rev-parse 'HEAD^{tree}')" = "$intended_tree"
target_status=$(git -C "$target_checkout" status --porcelain=v1 --untracked-files=all)
test -z "$target_status"

cd "$target_checkout"
lock_before=$(git hash-object flake.lock)
nix run --no-update-lock-file \
  '.#homeConfigurations."james@wampa".activationPackage' </dev/null
test "$(git hash-object flake.lock)" = "$lock_before"
WAMPA
)
```

A dirty checkout, unexpected origin or branch, failed fast-forward, or source
revision mismatch stops before activation. Resolve the mismatch; do not reset or
clean either checkout automatically.

## Bump workflow

`bump-nix` completes its commit, merge, and push before selecting the
Woowoo-to-Wampa row. On Wampa it may wrap the same `nix run` command with its
deployed authentication and structured-logging helper. The skill owns that
capture and failure reporting; this matrix remains authoritative for source,
target, revision, and checkout safety.
