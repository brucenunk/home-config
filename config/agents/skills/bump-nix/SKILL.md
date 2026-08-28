---
name: bump-nix
description: "Bump default Nix flake inputs in tasks that explicitly set skill: bump-nix. Runs a direct update, verification, and repository-prescribed delivery workflow."
---

# Bump Nix Workflow

Use this skill only when the task front matter sets `skill: bump-nix`.

This workflow is intentionally direct and does not use the structured `task-workflow-v3` discovery, planning, review, routing, or handoff ceremony. Treat it as a cheap, disposable execution path: update, verify, and either deliver a successful bump or promptly restore and discard a broken one. A routine bump is not an open-ended upstream repair task.

## Scope

- Bump Nix by updating all default flake inputs/lockfile entries in the task worktree.
- Keep changes focused on the bump and required lockfile updates.
- Do not target only `nixpkgs` by default; routine bump tasks should let `nix flake update` advance every relevant input, including package-providing inputs such as `llm-agents`.
- Use targeted input updates only when the task explicitly asks for a narrower bump or the user approves narrowing scope.
- Keep a fix in scope only when it meets the fail-fast threshold below. Discard the bump rather than investigating a nontrivial failure.
- Authenticate Nix's GitHub requests with the active GitHub CLI token. Shared or public egress IPs can exhaust GitHub's unauthenticated API limit and make a routine update fail with HTTP 403 even when GitHub is otherwise reachable.

## Fail-fast threshold

Apply this threshold to failures from the update itself, evaluation or verification, builds, delivery, deployment, activation, and runtime checks.

A fix may remain in the routine bump only when **all** of these are true:

- the failure and root cause are immediately apparent from existing evidence, without exploratory debugging;
- the adjustment is repository-local, small, well understood, and low risk;
- it follows an existing repository pattern and does not introduce a new dependency, source override, pin, cache policy, packaging strategy, or operational mechanism;
- the affected behavior has a narrow targeted check that can be run before any required broader verification; and
- one fix attempt and one targeted verification retry are sufficient.

Examples that may qualify include a mechanical option rename called out by an upstream error or changelog, refreshing an expected hash, or removing a repository workaround whose explicit `TODO(bump-nix):` condition is now satisfied. The examples do not waive the full threshold.

Anything else is nontrivial breakage. Stop after the first useful failure capture; do not investigate speculative certificate, network, sandbox, cache, toolchain, or upstream packaging theories. Do not add or reprioritize substituters, narrow or pin inputs, carry an old package forward, patch upstream source, or repeatedly rerun a heavyweight command. Those actions require the user's explicit direction before the bump starts or promotion of the blocker into a separate repair task. A user-approved narrowed or pinned update is an override to the default full-update scope, not an automatic recovery tactic.

Do not pause a routine bump merely to solicit permission for deeper debugging after it fails. Preserve the evidence and discard it. The user can deliberately schedule or promote a separate repair task from that evidence.

## Authenticated GitHub access

Before running a direct Nix command that may contact GitHub, confirm `gh auth status --hostname github.com` succeeds. Acquire the token in a separate guarded step so a failed command substitution cannot still launch Nix with an empty token. Keep it only in a shell variable, pass it directly to Nix, preserve Nix's status, and unset it immediately afterward:

```bash
if ! github_token=$(gh auth token --hostname github.com) || [ -z "$github_token" ]; then
  unset github_token
  echo "GitHub authentication required" >&2
  exit 1
fi
nix --option extra-access-tokens "github.com=$github_token" <command>
nix_status=$?
unset github_token
exit "$nix_status"
```

Use this pattern for direct update, evaluation, build, and check commands. Do not run Nix if the hostname-qualified `gh auth status`, `gh auth token`, or nonempty-token check fails; stop and ask the user to authenticate rather than falling back to unauthenticated GitHub API requests.

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

For the single targeted retry permitted by the fail-fast threshold, retain both transient captures until reporting and compare them:

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

This evidence procedure does not authorize a retry. Use it only after the proposed fix independently meets every fail-fast condition or when an applicable repository rollback procedure requires an observed command.

## Worktree and staging safety

The bump starts from a completely clean task worktree and index. Before any update, require `git status --porcelain=v1 --untracked-files=all` to produce no output. Stop rather than stashing, deleting, staging, or incorporating pre-existing changes.

Before the update, record the pre-bump revision with `git rev-parse HEAD`. Maintain two explicit lists:

- **deliverable paths** changed by the update or an approved bump-related fix, further distinguishing paths present at the pre-bump revision from newly created deliverable files; and
- **cleanup-only paths** proven absent before the responsible command and then created by that command, such as a `result` symlink, that must never be committed.

Inspect each command's output behavior before running it. Require `--no-link` or an output path under `mktemp` when supported so verification artifacts do not enter the worktree. If a required command can only write a known worktree artifact, first require that exact path not to exist, including as an ignored path, and then add it to the cleanup-only list if the command creates it. Stop rather than overwrite, remove, or adopt a pre-existing artifact. Review every deliverable path before staging it. Stage only the deliverable list with `git add -- <path>...`; broad staging commands such as `git add .`, `git add -A`, and `git add -u` are forbidden in this workflow.

Before committing, verify all of the following:

- `git diff --cached --name-only` contains exactly the reviewed deliverable-path list.
- `git diff --cached --check` passes and the complete cached diff has been reviewed.
- There are no unstaged tracked changes or untracked files.

If any check fails, stop and resolve the discrepancy without broad staging. These rules also apply when a verification or delivery failure requires a follow-up fix.

### Discarding a failed bump

For nontrivial breakage before delivery, perform this cleanup immediately:

1. Stop retries and retain only a concise diagnostic summary. Record the failed phase or compatibility check, the command when applicable, updated input revisions, affected package or derivation, the first stable error signature or incompatibility finding, and any relevant realization/cache fact. Never record a token or secret. Summarize a transient structured log when available; the summary in the task note is the durable evidence, not the temporary log file.
2. Recheck both explicit path lists. Refuse cleanup and alert the user if status contains a path that is on neither list; it may predate or be unrelated to the bump.
3. Restore deliverable paths that existed at the pre-bump revision in both index and worktree with `git restore --source="$pre_bump_revision" --staged --worktree -- <pre-existing-deliverable-path>...`.
4. For newly created deliverable files and cleanup-only paths, first remove any staged entry with the exact-path command `git rm --cached --ignore-unmatch -- <created-path>...`, then remove only those worktree paths with `rm -- <created-path>...`. Stop on an index discrepancy; do not force removal or recursively remove directories.
5. Require `git status --porcelain=v1 --untracked-files=all` to be empty. Never use broad `git reset`, `git restore`, `git clean`, or staging commands as cleanup.
6. Add a short `## Outcome` to the task note headed **Failed bump — discard requested**, including the diagnostic summary and that the explicit changed paths were restored. Report that the failed bump was restored and is being discarded, without claiming teardown has succeeded. Then, as the terminal action, use the task system's discard operation (for the default Denote system, `emacsclient -e '(my/task-discard-run "<task-id>")'`). The resulting `discarded` task status distinguishes this failed bump from a successful no-op, but is not proof that every teardown action completed; do not require the agent process or task session to survive teardown for a follow-up edit or report, and do not report teardown success without separate evidence.

The explicit restore and clean check must happen before task-system teardown; teardown is not a substitute for safe cleanup.

If the bump has been committed only on its disposable task branch and no other worktree, ref, or remote has been changed, it is still undelivered. Restore pre-existing deliverable paths from the pre-bump revision and remove newly created committed deliverable paths with exact-path `git rm -- <path>...`. Remove cleanup-only paths separately as described above. Verify that the staged reversal contains exactly the deliverable paths and make a separate cleanup commit so the task worktree is clean; do not amend or reset the bump commit. Then continue directly with the clean check, outcome note, report, and terminal discard action above rather than trying to restore the same paths again.

Once delivery has mutated another worktree, ref, remote branch, deployed generation, or activated runtime, rollback takes precedence over the otherwise permitted small-fix path. Do not attempt a fix or retry, and do not pretend that cleaning the task worktree rolls back the delivered bump. Preserve the same diagnostics and follow only an applicable repository-prescribed rollback procedure, restricted to the reviewed bump paths. The procedure must restore and directly verify every mutated source/delivery state and every deployed or activated runtime state; source rollback alone is insufficient after activation. Confirm every affected worktree is clean afterward. If no such safe and complete procedure exists, stop and ask the user how to handle the delivered state; do not discard or finish the task, rewrite history, force-push, or invent a rollback.

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

## Ghostel prebuilt-module compatibility

Every bump must compare the Ghostel version resolved directly from nixpkgs before and after `flake update`, even when `flake.lock` does not visibly identify Ghostel. Before the update, record both values below; after the update, evaluate the same expressions as `new_ghostel_version` and `new_nixpkgs_path`. Run these Nix evaluations with the guarded GitHub token pattern from **Authenticated GitHub access**.

```bash
ghostel_version_expr='let f = builtins.getFlake (toString ./.); pkgs = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}; in pkgs.emacsPackages.ghostel.version'
nixpkgs_path_expr='let f = builtins.getFlake (toString ./.); in f.inputs.nixpkgs.outPath'
old_ghostel_version=$(nix --option extra-access-tokens "github.com=$github_token" eval --raw --impure --expr "$ghostel_version_expr")
old_nixpkgs_path=$(nix --option extra-access-tokens "github.com=$github_token" eval --raw --impure --expr "$nixpkgs_path_expr")
```

The repository's `pkgs/ghostel.nix` is deliberately a single supported version with one hash-pinned release asset per supported platform. Do not turn it into a fallback, retain the old nixpkgs package, or add another metadata lookup. Run the strict updater on every non-no-op bump, including when the two resolved versions are equal:

```bash
config/agents/skills/bump-nix/scripts/update-ghostel-module \
  --package pkgs/ghostel.nix \
  --old-version "$old_ghostel_version" \
  --new-version "$new_ghostel_version" \
  --dry-run
```

For an unchanged version, the updater validates that every supported platform still has a syntactically valid fixed hash and exits without GitHub access. For a version increase, it performs and prints these exact operations before showing the proposed hash-table edit:

```bash
gh api --method GET "repos/dakra/ghostel/releases/tags/v${new_ghostel_version}"
config/agents/skills/bump-nix/scripts/nix-with-gh-token -- \
  nix store prefetch-file --json \
  "https://github.com/dakra/ghostel/releases/download/v${new_ghostel_version}/ghostel-module-aarch64-macos.dylib"
config/agents/skills/bump-nix/scripts/nix-with-gh-token -- \
  nix store prefetch-file --json \
  "https://github.com/dakra/ghostel/releases/download/v${new_ghostel_version}/ghostel-module-x86_64-linux.so"
```

The helper accepts only the existing `aarch64-darwin` and `x86_64-linux` entries, exact immutable version-tagged download URLs, stable non-draft release metadata, and Nix SRI hashes. Review its dry-run diff, then repeat the same command without `--dry-run` to make the edit. The test-only `--fixture-dir` mode demonstrates the same commands and edit without network access; never use fixture mode for a real bump.

Before making that edit, compare
`pkgs/applications/editors/emacs/elisp-packages/manual-packages/ghostel/package.nix`
under `old_nixpkgs_path` and `new_nixpkgs_path`. Continue mechanically only when the package still exposes the same override interface (`zig`, `zigDeps`, `preBuild`, and `passthru.module`), expects the same module filename and version file, and its changes are limited to the expected Ghostel version/source/fixed hashes. A missing package file, changed build or install behavior, module/asset naming change, ABI or platform change, version downgrade, pre-bump resolved version that differs from `supportedVersion`, unsupported platform, missing release or asset, unexpected release URL/state, or prefetch failure is a non-mechanical compatibility finding. Apply **Discarding a failed bump** immediately; do not edit around it or attempt a source build.

After the activation-package build, evaluate the overridden Ghostel derivation with the actual `pkgs` exported by the selected Home Manager configuration, including its overlays and nixpkgs configuration, and with the same Emacs package set selected by `flake-modules/features/emacs.nix`. Do not substitute `inputs.nixpkgs.legacyPackages`. Capture its recursive derivation closure in the existing temporary log directory:

```bash
# Set this from the repository-prescribed activation target selected earlier.
home_configuration='james@wampa'
ghostel_drv_expr="let f = builtins.getFlake (toString ./.); c = builtins.getAttr \"${home_configuration}\" f.homeConfigurations; pkgs = c.pkgs; emacsCfg = c.config.programs.emacs; epkgs = (pkgs.emacsPackagesFor emacsCfg.package).overrideScope emacsCfg.overrides; in (import (f.outPath + \"/pkgs/ghostel.nix\") { inherit pkgs epkgs; }).drvPath"
ghostel_drv=$(nix --option extra-access-tokens "github.com=$github_token" eval --raw --impure --expr "$ghostel_drv_expr")
nix-store -qR "$ghostel_drv" >"$log_dir/ghostel-closure"
```

Require that closure to contain `ghostel-module-${new_ghostel_version}.drv` and the host's release-asset fetch derivation, and require it not to contain a derivation whose name starts with `zig-` or a Ghostel Zig dependency-fetch derivation. Inspect the asset fetch with `nix derivation show`: its single `.derivations[].structuredAttrs.urls[]` value must equal the exact versioned GitHub URL validated above, and its `.derivations[].outputs.out.hash` must equal the new lookup hash. A derivation filename alone does not prove either property. Then require the built activation package's recursive derivation closure to contain that exact `ghostel_drv`. Search derivation names (the part after the Nix store hash), not arbitrary `zig` substrings in store hashes. Together, these checks prove the activation build selected the hash-pinned prebuilt-module package; unrelated Zig consumers elsewhere in the full activation closure do not invalidate it.

Treat a failed Ghostel compatibility or closure check exactly like any other verification failure under the fail-fast threshold. Only a strict hash refresh made by this helper is the anticipated mechanical fix; packaging, ABI, platform, or dependency-closure changes are not.

## Steps

1. Confirm task context:
   - Read the task file.
   - Ensure front matter has `skill: bump-nix`.
   - Require a completely clean task worktree and index as described above.
   - Record the pre-bump revision and initialize the explicit deliverable-path and cleanup-only-path lists.
   - Record `old_ghostel_version` and `old_nixpkgs_path` as described in **Ghostel prebuilt-module compatibility** before changing the lock file. Run the strict updater with both version arguments set to `old_ghostel_version`; stop if the current package lacks complete hash coverage or has an unexpected version relationship.
2. Check for no-op:
   - Confirm GitHub CLI authentication with `gh auth status --hostname github.com`.
   - Acquire and validate the token separately as described above, then run the default full update as `nix --option extra-access-tokens "github.com=$github_token" flake update`, preserve its status, and unset the token.
   - If GitHub token acquisition fails before Nix starts, require the worktree to remain clean and ask the user to authenticate as described above; this prerequisite failure is neither a no-op nor a failed bump. For any other update-command failure, refresh both explicit path lists from status, classify the failure against the fail-fast threshold, and follow **Discarding a failed bump** unless one permitted repository-local fix clearly qualifies. A failed command is not a no-op even when it left `flake.lock` unchanged.
   - Check whether the full/default update changed `flake.lock`.
   - If the successful full/default `nix flake update` produces no lockfile changes, abort immediately:
     - Add a concise task-note outcome headed **No-op update** stating that the default full update produced no changes and was unnecessary.
     - Confirm the task worktree remains clean and report the no-op to the user.
     - Do not proceed with commit, merge, or deploy; finish the task with the task system's normal successful finish operation.
   - If lockfile changes are detected, proceed to step 3.
3. Implement bump:
   - Keep the `flake.lock` changes from the full/default `nix flake update`.
   - Evaluate `new_ghostel_version` and `new_nixpkgs_path`, compare the old and new nixpkgs Ghostel package definitions, and run the strict Ghostel updater as described in **Ghostel prebuilt-module compatibility**. Run it even when the resolved version is unchanged. Classify any non-mechanical finding before continuing.
   - Review `flake.lock` changes and keep only bump-related updates.
   - Do not revert non-`nixpkgs` input updates merely because they are not `nixpkgs`; inputs such as `llm-agents` are part of the intended package bump surface.
   - Search for and evaluate every `TODO(bump-nix):` breadcrumb as described above. Classify any required repository change against the fail-fast threshold before implementing it; a compatibility finding can require discard even when no command has failed.
   - If `llm-agents` updates Pi:
     - Determine the old and new Pi versions from the corresponding `llm-agents` revisions.
     - Read the Pi changelog for every intervening release before continuing. Treat breaking changes, migrations, removals, and behavior changes as required checks against the repository's Pi settings, themes, launchers, activation code, extensions, and agent workflows. Follow linked Pi documentation for entries that may affect the setup. Classify every required migration or fix against the fail-fast threshold before implementation; discard a nontrivial incompatibility based on the documented finding without waiting for a command to fail.
     - If the repository carries a custom `apply_patch` extension, check whether upstream Pi now provides that tool. Compare provider integration, schema, diff semantics, file-mutation serialization, failure behavior, rendering, and default activation. Document the compatibility decision and retain, adapt, or remove the custom extension based on the comparison; do not remove it solely because an upstream tool has the same name.
   - Build and review both explicit path lists. Every deliverable path must be attributable to the bump or an approved bump-related fix; every cleanup-only path must be an artifact created by a known workflow command.
4. Verify:
   - Run repo checks needed to validate the bump (for example an authenticated `nix flake check` or targeted build/eval command), using the separately guarded token pattern above.
   - After building the activation package, perform the Ghostel derivation-closure and activation-selection checks from **Ghostel prebuilt-module compatibility**. The Ghostel subtree must use the versioned prebuilt fetch and must not contain Ghostel's Zig dependency-fetch derivation.
   - Classify any failure against the fail-fast threshold. If every condition is met, make at most one fix attempt and run the narrow targeted check once before broader required verification. Otherwise follow **Discarding a failed bump** immediately.
   - Order work to find cheap failures before expensive realization: complete lockfile review, breadcrumb and changelog checks, evaluation/static checks, effective-configuration inspection, and the realization-plan preflight before a heavyweight build or apply.
   - Run one comprehensive check/build for each materially different source state. After a fix, rerun the failed or affected check first; repeat an already-successful heavyweight check only when the fix can affect it or repository policy requires a final rerun.
   - A cache hit proves only that an accepted binary was available. A source-build, source-fetch, toolchain, TLS, or upstream packaging failure is nontrivial unless the remedy independently meets every fail-fast condition. Do not add or rely on a substituter to conceal the failure, and do not disable substitution for an entire deployment merely to investigate one derivation.
   - Record proof in the task file when the task workflow in use expects verification notes.
5. Commit in task worktree:
   - Remove every cleanup-only path individually with `rm -- <path>...`, then verify each is absent with checks that detect dangling symlinks as well as existing files. Stop rather than recursively removing a directory or touching an unlisted path.
   - Stage only the explicit reviewed deliverable-path list with `git add -- <path>...`.
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
   - Before the first delivery-state mutation, classify failures such as precondition checks against the fail-fast threshold and permit at most the one small-fix path. After any other worktree, ref, remote, deployed generation, or runtime has been mutated, do not fix or retry: the rollback precedence in **Discarding a failed bump** applies even if a possible fix appears small.
   - Summarize the final deployment capture and compare retry captures when applicable. Distinguish substitutions/downloads, uploads or direction-unknown transfers, derivation builds, elapsed and cumulative times, slow derivations, genuinely repeated work, unknown outcomes, and unfinished closure work. Report build locality only when separate evidence establishes it.
   - If the repository-prescribed rollback succeeds and restores all delivered bump paths, refs, remotes, deployed generations, and activated runtime state, directly verify the required runtime pickup and confirm affected worktrees are clean. Then record **Failed bump — discard requested**, report that it is being discarded, and invoke task discard as the terminal action. If complete rollback or runtime verification is unavailable or unsafe, stop and alert the user with the blocker and delivered-state boundary.
7. Finish task:
   - Confirm the task worktree is clean with `git status --short`. If it is not empty, stop and resolve the worktree state before finishing.
   - Run `emacsclient -e '(my/task-finish "<task-id>")'` only after all required verification, including apply-time verification, is complete, or for the explicitly documented no-op outcome in step 2. Failed bumps use the discard path instead and must never be reported as no-ops.

## Completion report for Pi updates

When the `llm-agents` update changes Pi's version, include a concise Pi changelog and compatibility summary in the final user-facing completion report. Do not include this Pi-specific summary when Pi's version is unchanged.

The summary must:

- Name the old and new Pi versions.
- Distill the notable features, breaking changes, removals, migrations, behavior changes, and relevant fixes across every intervening release reviewed in step 3. Do not reproduce the full changelog.
- State which relevant repo surfaces were checked and the outcome for each, including SDK/API usage, model metadata, provider and proxy configuration, packaging or layout assumptions, and agent workflows.
- Clearly separate compatibility checks that found no repo impact from migrations, metadata refreshes, configuration changes, or fixes actually made.
- Mention targeted verification for any migration or fix, while leaving the workflow's broader verification and deployment evidence in the normal completion summary.

Prefer a compact structure such as **Pi old → new**, **Notable upstream changes**, **Compatibility checks (no changes required)**, and **Repo changes made**. Omit empty categories rather than adding boilerplate.
