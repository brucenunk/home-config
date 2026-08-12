---
name: bump-nix
description: "Bump default Nix flake inputs in tasks that explicitly set skill: bump-nix. Runs a direct update, verification, and repository-prescribed delivery workflow."
---

# Bump Nix Workflow

Use this skill only when the task front matter sets `skill: bump-nix`.

This workflow is intentionally direct and does not use the structured `task-workflow-v3` discovery, planning, review, routing, or handoff ceremony. Treat it as a straight-through execution path: update (abort on no-op), verify, commit, follow the applicable repository finish and deployment policy, then finish.

## Scope

- Bump Nix by updating all default flake inputs/lockfile entries in the task worktree.
- Keep changes focused on the bump and required lockfile updates.
- Do not target only `nixpkgs` by default; routine bump tasks should let `nix flake update` advance every relevant input, including package-providing inputs such as `llm-agents`.
- Use targeted input updates only when the task explicitly asks for a narrower bump or the user approves narrowing scope.
- If the update, verification, or repository-prescribed deployment exposes a fixable repository issue, fix it as part of the bump; only stop and alert the user when you cannot safely resolve the blocker.
- Authenticate Nix's GitHub requests with the active GitHub CLI token. Shared or public egress IPs can exhaust GitHub's unauthenticated API limit and make a routine update fail with HTTP 403 even when GitHub is otherwise reachable.

## Authenticated GitHub access

Before running a Nix command that may contact GitHub, confirm `gh auth status --hostname github.com` succeeds. Pass the token directly to Nix without printing or storing it:

```bash
nix --option extra-access-tokens "github.com=$(gh auth token --hostname github.com)" <command>
```

Use this form for direct update, evaluation, build, and check commands. If the hostname-qualified `gh auth status` or `gh auth token` fails, stop and ask the user to authenticate rather than falling back to unauthenticated GitHub API requests.

### Repository wrappers and nested Nix

When a required repository script invokes `nix` internally and cannot accept Nix global options, run it through this skill's `scripts/nix-with-gh-token` helper:

```bash
<bump-nix-skill-directory>/scripts/nix-with-gh-token -- ./repository-wrapper <args...>
```

The helper obtains the active token without displaying it and puts a credential-free, private temporary `nix` shim first on `PATH`. Each nested `nix` call receives the same command-line `extra-access-tokens` option as a direct command, preserving credentials already configured for other sources. The host's configuration files and existing environment remain in force; the helper does not synthesize or replace Nix configuration. It removes the shim on exit and propagates the wrapper's exact exit status.

This mechanism requires the repository wrapper to resolve `nix` through `PATH` and preserve its environment. Inspect the wrapper before use. Stop rather than claiming authenticated coverage if it invokes an absolute Nix path, resets `PATH`, clears the environment, or delegates to a boundary that does not inherit the shim.

Never solve nested authentication with a partial assignment such as:

```bash
# Forbidden: setting NIX_CONFIG can suppress system- or user-managed settings.
NIX_CONFIG="access-tokens = github.com=$(gh auth token --hostname github.com)" ./repository-wrapper
```

Adding a hand-written subset of `experimental-features`, substituters, or other observed values is also forbidden. It remains incomplete and can silently remove trusted keys, builders, plugins, sandbox settings, or future host-managed configuration. Do not put the token in a generated `nix.conf`, temporary file, shell trace, task note, or captured command line. Do not enable shell tracing around token acquisition or the helper.

## Realization preflight and performance evidence

Before an expensive check, build, apply, or deployment, inspect the settings that determine feature and cache behavior without printing secret-bearing settings:

```bash
nix show-config --json | jq '{
  experimentalFeatures: .["experimental-features"].value,
  substituters: .substituters.value,
  trustedSubstituters: .["trusted-substituters"].value,
  trustedPublicKeys: .["trusted-public-keys"].value,
  builders: .builders.value
}'
```

Treat this as a diagnostic snapshot, not a cache prescription. Do not add, remove, or prioritize a cache merely to make the bump faster. In particular, do not infer that one organization-specific cache accounts for all elapsed time.

When repository guidance routes deployment to a focused activation matrix or procedure, read it completely before selecting the realization command. Choose the row from the actual source machine and target, and follow its source identity, source-state, delivery, target-checkout, and runtime-pickup boundaries exactly. Do not bypass the procedure with a remembered wrapper or a command copied from another host. If it requires a direct activation-package command, invoke that exact installable with its lock-file safety flags. Run the authenticated helper and structured capture on the activation target, but keep their error handling in this skill rather than expanding the repository matrix into another deployment program.

Identify the installable or realization command underlying the repository's required deployment and run its authenticated `--dry-run` equivalent when Nix supports one. This is the expected realization plan: note what Nix says it will fetch and what it will build. Do not pass invented dry-run flags to an opaque deployment script, and do not treat a dry-run as verification, deployment, or runtime pickup.

For a heavyweight wrapper, keep the real command in the foreground while recording timestamped structured Nix events:

```bash
log_dir=$(mktemp -d)
<bump-nix-skill-directory>/scripts/nix-with-gh-token \
  --log-file "$log_dir/apply.jsonl" -- ./repository-wrapper <args...>
<bump-nix-skill-directory>/scripts/summarize-nix-log "$log_dir/apply.jsonl"
```

The helper keeps the command attached to the foreground terminal, renders meaningful Nix activity and messages as they occur, records the complete timestamped event stream without flooding the terminal with machine progress ticks, adds `--log-format internal-json` to nested Nix calls, structurally redacts GitHub access-token options on stderr, and preserves failure status. This satisfies foreground/direct-observation requirements; do not background, detach, or replace a repository-required direct run with log polling. Keep logs in a `mktemp` directory, do not commit them, and remove them after extracting the report.

Structured activity IDs are process-local, so logging mode deliberately rejects overlapping nested Nix invocations with exit status 75 rather than producing a misleading merged report. If a repository wrapper runs Nix concurrently, use an approved sequential mode for the observed deployment or stop and report that structured summarization is unavailable; do not silently drop the helper or claim accurate timings.

Before relying on the capture, inspect the repository wrapper for nested stderr redirection or capture, explicit `--log-format` options that could override the shim, conflicting access-token options, and background descendants that retain stderr. The helper rejects nested access-token options with status 64, concurrent logged Nix calls with status 75, and logged wrappers that leave descendants holding the capture with status 76. The helper can record only events that reach the wrapper's stderr. Treat a summary warning about missing invocation markers or missing structured activities as unavailable evidence, not as proof that no work occurred.

The summary separates substitutions/downloads, uploads, direction-unknown transfers, and derivation-build activities; reports command wall time and cumulative activity time; and lists the slowest derivations. Nix's generic internal events do not reliably identify whether a builder was local or remote, so do not label build activity as local unless separate evidence establishes locality. A stopped activity is not necessarily successful; only treat a prior stopped build as completed when its nested Nix invocation succeeded. Cumulative activity time can exceed wall time when work overlaps. Use event durations, not terminal line counts, to explain cost.

For a retry, retain both transient captures until reporting and compare them:

```bash
<bump-nix-skill-directory>/scripts/summarize-nix-log \
  "$log_dir/retry.jsonl" --previous "$log_dir/first.jsonl"
```

Report separately:

- derivations genuinely repeated after a successful prior nested Nix invocation;
- builds reattempted after a prior stop whose success is unknown;
- interrupted activities that remained active at the end of the first capture;
- newly attempted unfinished-closure work that the first run never reached; and
- prior proven-complete derivations not observed rebuilding in the retry, without inferring why they were absent;
- prior finished or unfinished work not observed before a failed retry, whose reuse cannot be proven.

Do not describe all output on a retry as repeated work. Nix normally reuses completed store paths while continuing the unrealized remainder of the closure.

Compare retries as unfinished-closure work only when the realization plan is materially unchanged. If a source or lockfile fix changes the plan, state that boundary and report newly attempted derivations without claiming they belonged to the first closure.

## Worktree and staging safety

The bump starts from a completely clean task worktree and index. Before any update, require `git status --porcelain=v1 --untracked-files=all` to produce no output. Stop rather than stashing, deleting, staging, or incorporating pre-existing changes.

Maintain an explicit list of every path produced by the update or by an approved bump-related fix. Review each path before staging it. Stage only that list with `git add -- <path>...`; broad staging commands such as `git add .`, `git add -A`, and `git add -u` are forbidden in this workflow.

Before committing, verify all of the following:

- `git diff --cached --name-only` contains exactly the reviewed path list.
- `git diff --cached --check` passes and the complete cached diff has been reviewed.
- There are no unstaged tracked changes or untracked files.

If any check fails, stop and resolve the discrepancy without broad staging. These rules also apply when a verification or delivery failure requires a follow-up fix.

## Bump-time breadcrumbs

Repository code may mark dependency workarounds and other bump-sensitive checks with a comment in this form:

```text
TODO(bump-nix): Check <condition>; take <action> when it is satisfied.
```

After a successful lockfile update, find every breadcrumb with:

```bash
rg -n 'TODO\(bump-nix\):' . \
  --glob '!**/.git/**' \
  --glob '!config/agents/skills/bump-nix/SKILL.md'
```

Treat every match as a required bump-time check. Follow its instructions when the condition is now satisfied; otherwise leave the marker in place. Do not remove a marker merely because it was inspected.

## Steps

1. Confirm task context:
   - Read the task file.
   - Ensure front matter has `skill: bump-nix`.
   - Require a completely clean task worktree and index as described above.
2. Check for no-op:
   - Confirm GitHub CLI authentication with `gh auth status --hostname github.com`.
   - Run the authenticated default full update command: `nix --option extra-access-tokens "github.com=$(gh auth token --hostname github.com)" flake update`.
   - Check whether the full/default update changed `flake.lock`.
   - If the full/default `nix flake update` produces no lockfile changes, abort immediately:
     - Document that the update is unnecessary (no changes to bump)
     - Do not proceed with commit, merge, or deploy
   - If lockfile changes are detected, proceed to step 3.
3. Implement bump:
   - Keep the `flake.lock` changes from the full/default `nix flake update`.
   - Review `flake.lock` changes and keep only bump-related updates.
   - Do not revert non-`nixpkgs` input updates merely because they are not `nixpkgs`; inputs such as `llm-agents` are part of the intended package bump surface.
   - Search for and evaluate every `TODO(bump-nix):` breadcrumb as described above.
   - If `llm-agents` updates Pi:
     - Determine the old and new Pi versions from the corresponding `llm-agents` revisions.
     - Read the Pi changelog for every intervening release before continuing. Treat breaking changes, migrations, removals, and behavior changes as required checks against the repository's Pi settings, themes, launchers, activation code, extensions, and agent workflows. Follow linked Pi documentation for entries that may affect the setup, implement required migrations, and add targeted verification where appropriate.
     - If the repository carries a custom `apply_patch` extension, check whether upstream Pi now provides that tool. Compare provider integration, schema, diff semantics, file-mutation serialization, failure behavior, rendering, and default activation. Document the compatibility decision and retain, adapt, or remove the custom extension based on the comparison; do not remove it solely because an upstream tool has the same name.
   - Build and review the explicit changed-path list. Every path must be attributable to the bump or an approved bump-related fix.
4. Verify:
   - Run repo checks needed to validate the bump (for example `nix --option extra-access-tokens "github.com=$(gh auth token --hostname github.com)" flake check` or an authenticated targeted build/eval command).
   - If verification reveals a fixable issue caused by the bump, fix it and rerun the relevant checks.
   - Order work to find cheap failures before expensive realization: complete lockfile review, breadcrumb and changelog checks, evaluation/static checks, effective-configuration inspection, and the realization-plan preflight before a heavyweight build or apply.
   - Run one comprehensive check/build for each materially different source state. After a fix, rerun the failed or affected check first; repeat an already-successful heavyweight check only when the fix can affect it or repository policy requires a final rerun.
   - A cache hit proves only that an accepted binary was available. If the bump exposes a genuine source-build failure, fix the source or packaging issue and rerun the narrow failing derivation from source where the host and repository policy support that test. Do not add or rely on a substituter to conceal the failure, and do not disable substitution for an entire deployment merely to prove one derivation.
   - Record proof in the task file when the task workflow in use expects verification notes.
5. Commit in task worktree:
   - Stage only the explicit reviewed path list with `git add -- <path>...`.
   - Run every worktree and staging safety check above.
   - `git commit -m "Bump flake inputs"`
   - Confirm the task worktree is clean after the commit.
6. Deliver and deploy:
   - Read and follow the applicable owner and repository guidance for finish mode, merge or pull-request delivery, pushing, deployment target and entry point, staging requirements, and host smoke tests.
   - If that guidance routes activation through a repository-local matrix or procedure, read it again after delivery, select its row from the machine where delivery is running and the declared target, and execute its exact source-safety and direct-activation sequence. Stop if no row matches; do not infer a route.
   - Do not infer a deployment command, target host, branch strategy, or smoke-test command from this reusable skill.
   - Before invoking repository-prescribed delivery, require every worktree that delivery will mutate, including a default-branch worktree when applicable, to have a clean index and worktree including no untracked files. Stop rather than absorbing, deleting, or overwriting unrelated content.
   - After any repository-prescribed merge or staging step and before its commit or push, inspect the complete staged diff and confirm it contains only the reviewed bump result. Never use broad staging to repair a discrepancy.
   - Inspect effective Nix settings and the expected realization plan before the expensive deployment. When the entry point invokes nested Nix, use the authenticated helper and structured capture described above.
   - Perform the repository-required final apply or deployment against the delivered result, then perform every prescribed fresh-login or runtime smoke test. Build success, delivery success, deployment success, and runtime pickup are distinct evidence; report only what was directly verified.
   - If delivery, deployment, or a prescribed smoke test reveals a fixable issue caused by the bump, fix it, restage as required, and rerun the narrow failing check before repeating the affected required delivery/deployment step. Do not rerun unrelated heavyweight checks unless the fix can affect them or policy requires it.
   - Summarize the final deployment capture and compare retry captures when applicable. Distinguish substitutions/downloads, uploads or direction-unknown transfers, derivation builds, elapsed and cumulative times, slow derivations, genuinely repeated work, unknown outcomes, and unfinished closure work. Report build locality only when separate evidence establishes it.
   - If you cannot safely fix the issue, stop and alert the user with the blocker.
7. Finish task:
   - Confirm the task worktree is clean with `git status --short`. If it is not empty, stop and resolve the worktree state before finishing.
   - Run `emacsclient -e '(my/task-finish "<task-id>")'` only after all required verification, including apply-time verification, is complete.

## Completion report for Pi updates

When the `llm-agents` update changes Pi's version, include a concise Pi changelog and compatibility summary in the final user-facing completion report. Do not include this Pi-specific summary when Pi's version is unchanged.

The summary must:

- Name the old and new Pi versions.
- Distill the notable features, breaking changes, removals, migrations, behavior changes, and relevant fixes across every intervening release reviewed in step 3. Do not reproduce the full changelog.
- State which relevant repo surfaces were checked and the outcome for each, including SDK/API usage, model metadata, provider and proxy configuration, packaging or layout assumptions, and agent workflows.
- Clearly separate compatibility checks that found no repo impact from migrations, metadata refreshes, configuration changes, or fixes actually made.
- Mention targeted verification for any migration or fix, while leaving the workflow's broader verification and deployment evidence in the normal completion summary.

Prefer a compact structure such as **Pi old → new**, **Notable upstream changes**, **Compatibility checks (no changes required)**, and **Repo changes made**. Omit empty categories rather than adding boilerplate.
