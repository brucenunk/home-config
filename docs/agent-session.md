# Human-operated agent-shell launches

Run `M-x my/agent-session-start`. The command is autoloaded by `init.el` and
implemented in `config/emacs/my-lisp/my-agent-session.el`, separately from task
capture/list packages. It creates a **new Pi conversation**, never a reused
project conversation. It requires the generated [catalogue](agent-catalogue.md),
the pinned agent-shell/ACP packages, and `pi-acp` on the selected machine.

## Interaction

1. **Task-backed** selects a saved task file with YAML front matter; **Ad hoc**
   has no task, description or initial prompt. Generic prompt files are not an
   entry mode. Unsaved editor changes are not part of the saved snapshot.
2. Choose **New repository worktree** or **Existing directory**.
3. For worktrees, use a valid task repository hint or explicitly select a
   configured repository. A single eligible machine is automatic. Multiple
   machines always require explicit selection without a default/preselection,
   even when task metadata names a machine. Existing-directory sessions choose
   from all configured machines, then browse from that machine's `:directory`.
4. For worktrees, **always confirm the base ref**. The catalogue value is the
   initial default; legacy task `base-ref` is not used. This is the place to
   select a preceding PR's branch for a train.
5. Start the fresh shell, wait for initialization, apply supplied task
   overrides, and submit its task snapshot explicitly to that returned shell.
   Ad hoc sessions open without a prompt or configuration questions.

All choices precede Git mutation or agent startup. Browsing is unrestricted
within the selected machine, not limited to repository-owner directories.
The exact chosen directory is the shell CWD, even inside an existing project.
The catalogue's TRAMP connection, including RPC user/host/port information,
is retained for browsing, Git and ACP startup; machine names are not SSH aliases.

## Git and names

Configured sources may be ordinary worktrees, linked worktrees or bare Git
directories. Both `/path/repo/main` and `/path/repo/master.git` produce new
worktrees at `/path/repo/{name}`; no `~/work` path is reconstructed. The source
checkout is never switched or reset. Worktrees are not registered as remembered
Emacs projects.

Base refs are branch names, `refs/heads/...`, or `refs/remotes/...`. A configured
remote prefix such as `origin/train/part-one` fetches that exact branch into its
remote-tracking ref. Local branches, including slash-containing names, resolve
without fetching. Use `refs/heads/origin/example` to explicitly select a local
branch whose name begins with a remote name. Tags and revision expressions are
not accepted. Worktree creation uses the resolved commit, not an ambiguous ref.

Task-backed worktree paths and local branches use an ASCII title slug capped
at 40 characters, trimmed at a hyphen boundary, followed by Unix seconds in
base 36. A single word longer than the cap is truncated. Titles without ASCII
letters/digits use `task`. Ad hoc names are `adhoc-{base36-seconds}`. Exact branch
refs, existing paths and dangling symlinks are checked; collisions add `-1`,
`-2`, etc. A concurrent collision still fails safely at Git rather than deleting
or reusing the conflicting worktree.

The full task title is the Emacs shell display name, falling back to the task
filename. Ad hoc sessions use the selected directory/worktree basename. The
display name is not a slug or a persisted ACP session title. There is no naming
question or pre-session LLM request. An eventual remote `jamesl/{slug}` PR branch
is a separate agent/PR-time concern; the launcher publishes nothing.

## Task text and independent overrides

The task must have opening `---` front matter and a closing delimiter. Only
that initial block supplies launch metadata; body rules such as later `---`
lines do not delimit metadata. Standard YAML parsing handles custom scalar
fields (using string values so quoted titles such as `"123"` stay strings);
Denote's public metadata API retrieves the title. Saved task snapshots
are bounded to 256 KiB. Fields used for launch must be non-empty single-line
strings when supplied; a skill must be a simple skill name.

The entire saved task is sent as text, with provenance explicitly stating that
its original Emacs-side path may be inaccessible or uneditable on the agent
host. No remote file copy/access is required. A `skill` field appends
`Load the {skill} agent skill and follow instructions.` No field means no
injected skill instruction.

Submission uses the standard public `agent-shell-insert` API, like pasting the
task into agent-shell yourself. Its normal `@file` mention/attachment processing
still applies and may read additional files. The launcher does not escape or
rewrite task text, or promise literal byte-for-byte ACP output.

`model` and `thinking` are independent optional overrides. The launcher sends
neither field when absent, leaving Pi's own configured defaults intact. It
does not substitute catalogue defaults or confirm choices at launch. When both
are present, model is applied first, then thinking against the resulting model's
advertised capabilities. A thinking-only override applies to Pi's active default
model. Unsupported values and failed/readback-mismatched changes stop automatic
task submission with a clear diagnostic.

### Pinned APIs

The repository pins agent-shell `956a0be6b56e21b6de47a74a2a52fed0288b2abb`,
ACP 0.17.1, agent-shell-tramp `da17568f61c30133df1cf3fdf9d0fa4137cfd66e`, and
TRAMP RPC 0.15.0. The current Pi ACP package is 0.0.34.

- Public `agent-shell-start` always creates a fresh shell; binding the public
  session strategy to `new` prevents a resume/session-picker prompt. Startup
  bindings are established in a neutral temporary buffer so launching from a
  shell's buffer-local settings cannot fall back to the global resume strategy.
  Directory-local variables are skipped during this explicit startup: the pinned
  starter otherwise lets them replace the selected CWD or fresh-session policy
  before initialization. Ordinary launches outside this command are unchanged.
- Public `agent-shell-cwd-function` prevents project-root substitution. Its
  closure is retained buffer-locally for later ACP/file operations.
- `agent-shell-initialized-p` plus the `init-finished` event covers asynchronous
  readiness and initialization completing before subscription. The public agent
  config's client factory installs failure observers before ACP startup, including
  an error emitted before `agent-shell-start` returns. Success can submit only
  after that starter returns and viewport setup finishes. Launch-local guards
  stop callbacks after failure/closure and prevent duplicate submission; the
  task goes only to the exact newly returned shell.
- Public config-option inspection, setters, success/failure callbacks and
  value readback apply independent overrides. Pi ACP separately implements the
  `model` and `thought_level` options; thinking does not require a model override.
- Agent-shell's initialization-default handling may warn and continue after
  rejection. The launcher therefore uses explicit setters after initialization
  rather than treating initialization as proof that overrides succeeded.
- `agent-shell-insert` receives the returned shell explicitly for submission;
  viewport display also receives that exact buffer. No project-shell lookup is
  used to route the task. Task submission switches an empty viewport into the
  public conversation-view mode before sending, so asynchronous startup does not
  leave an empty compose view while the agent runs. A nonempty draft is preserved
  in compose mode; ad hoc launches also stay in compose mode. Nonempty editable
  input in the underlying shell stops automatic task submission rather than
  sending the unfinished draft with it. That draft is left untouched.
- There is no public ACP title setter in this pin. Public buffer-name formatting
  supplies the full Emacs display name; internal session-title state is untouched.
- Git uses `process-file` with a TRAMP `default-directory`, passing machine-local
  worktree paths as Git arguments. ACP 0.17.1 uses `make-process :file-handler`;
  RPC implements both process APIs. Agent-shell-tramp maps agent paths and keeps
  remote transcripts local. Explicit Git operations, including fetch, are
  synchronous and interruptible; no background inventory scan or refresh runs.

## Failures

Failures report the retained directory, branch and shell buffer when available
in an ordinary Emacs message. Nothing is automatically removed or resent. A
failed/interrupted Git operation may have partially applied: inspect the reported
path and branch rather than blindly creating another worktree. After resolving
the cause, open the retained directory and start agent-shell normally.

There is no retry command, retained task snapshot/context or special recovery UI.
Launch-local callbacks stop after failure or closure and release their task text
when finished. If submission may have reached the agent, inspect the conversation
before sending anything again. Even a locally accepted send is not proof of
remote processing.

There is no cleanup, task-status management, completion monitoring or
agent-to-agent control. Launching another conversation does not grant the agent
tools to operate it. Herdr/Herdsman's orchestration capabilities remain separate.

## Verification, activation and smoke tests

`emacs-agent-shell` runs ERT with the pinned packages: temporary real repositories
exercise bare/ordinary/linked sources, local/fetched bases and collisions;
simulated remote file/process boundaries and asynchronous agents exercise
selection, path routing, overrides, readiness and failure handling. A pinned
startup/insertion/viewport regression simulates only ACP initialization/transport
and checks task conversation view versus ad hoc compose mode. These are
isolated worktree checks, not proof of live RPC/authentication behavior.

Stage intended files, run the required Wampa build on x86_64 Linux, and follow
[activation.md](activation.md) when delivery is authorized. From Woowoo, Wampa
activation requires the reviewed source to have been merged and pushed; a
feature-worktree build does not authorize activation. Private machine composition
and deployment remain the separate deployment task.

Never load feature-worktree Lisp into the shared Emacs daemon. After authorized
activation, restart Emacs using deployed files and explicitly reload the catalogue
if needed. Activation alone is not runtime pickup evidence.

Run these human-observed checks only with approval for target machines,
disposable smoke-test worktrees/conversations and any cleanup:

1. Local **task + new worktree**: select a non-default base, verify sibling path,
   local branch, full-title display and exactly one task/skill submission.
2. Local **ad hoc + new worktree**: verify `adhoc-...`, no description/model/name
   questions and no initial prompt.
3. **Existing directory**, both modes: browse outside owner directories, including
   a project subdirectory; verify the exact CWD and no created worktree.
4. **Remote RPC + local task**: verify destination selection, remote sibling path
   and Git branch, remote ACP CWD, local transcript, and snapshot delivery without
   requiring the task path to exist remotely.
5. Task overrides: model-only, thinking-only, both and neither; verify active
   settings before task submission. Use an unsupported value to confirm submission
   is withheld and the worktree is retained for manual inspection.
6. Cancel at each selector/base prompt: no worktree appears. Inspect a startup
   failure and uncertain delivery without deleting work or automatically resending.

Record build, activation and actual runtime-pickup evidence separately. Live
checks above are not marked passed by the isolated suite.