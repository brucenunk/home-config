---
name: bump-nix
description: Update all Nix flake inputs, run repository bump checks, and verify the result. Use when requested in chat or selected in a task brief.
---

# Bump Nix

Run the update and verification without waiting for approval at each step. No task file is needed.

1. Start at the repository root with a clean worktree and index. Record the starting revision, read the repository guidance for bump-time requirements, and find the maintenance TODOs (no matches is fine):

   ```sh
   git grep -n -F 'TODO(bump-nix):' -- . ':(exclude,glob)**/bump-nix/SKILL.md'
   ```

2. If GitHub authentication is required by the repository or to fetch inputs, use Nix's configured GitHub token if present; otherwise get a nonempty token with `gh auth token --hostname github.com` and pass `--option extra-access-tokens "github.com=$github_token"` to Nix. If neither is available when required, stop and report the blocker. Don't log or save the token.
3. Record the versions or source revisions needed by the TODOs and repository guidance. Run `nix flake update` without input arguments and review the `flake.lock` diff. Don't silently narrow the update or add pins to get a passing build. If the update fails, diagnose it or report the blocker; an unchanged lockfile doesn't make a failed update a no-op.
4. Check every `TODO(bump-nix):` against the updated dependencies, even if the lockfile didn't change. Follow the comment when its condition is met, and leave it in place if it still applies. Use `gh` or `gh api` for GitHub lookups. If all checks are complete and there's nothing to change, report a no-op and stop.
5. Run `nix flake check --no-update-lock-file`, the repository's documented bump-time builds and checks, and targeted checks for TODO-driven changes. Use the same authentication if Nix needs to fetch inputs. Report which targets were verified; a build isn't activation.
6. Fix straightforward compatibility issues and rerun affected checks. If a blocker needs a larger repair or a required check can't be completed, report the bump as unverified and explain what's blocking it. Leave unrelated changes untouched.
7. Summarize input changes, TODO outcomes, and verification. Call out old → new versions or revisions for dependencies identified by the repository guidance and relevant upstream changes. Skip exhaustive changelogs. Leave the result in the worktree unless the user explicitly requests commit, merge, push, or activation; follow repo guidance for any requested delivery.
