# Human-operated agent-shell launches

Three explicit commands are autoloaded by `init.el` and implemented in
`config/emacs/my-lisp/my-agent-session.el`, separately from task capture/list
packages. Each creates a **new Pi conversation**, never a reused project
conversation. They require the generated [catalogue](agent-catalogue.md), the
pinned agent-shell/ACP packages, and `pi-acp` on the selected machine.

## Interaction

### `M-x my/agent-session-start-from-file`

Globally, **`C-c a f`** invokes this command with its normal task picker. The
`C-c a` agent prefix leaves `d`, `w` and `r` unbound for future commands.

Select a todo task note recursively under `~/work/tasks/`, including epic
subdirectories. Only Denote Markdown filenames with the exact `==todo--`
signature qualify; done/discarded notes, unrelated files, backups and lock
files are excluded. Completion uses styled, readable filename titles plus
epic/date annotations, without reading note bodies. Duplicate titles retain
distinct file identities and normal completion narrowing applies.

Use a valid task repository hint, otherwise select a configured repository.
Select an eligible machine, **always confirm the base ref**, then create a new
sibling worktree. Wait for initialization, apply supplied task overrides, and
submit the complete saved snapshot and any skill instruction to that exact
shell. Unsaved editor changes are not part of the snapshot.

The optional Lisp argument `FILE` bypasses completion, not saved-task validation:
`(my/agent-session-start-from-file file)`. The task-list action below supplies
that argument directly. There is no direct-directory task path or generic
prompt-file mode.

#### Launch from the task list

In a task-list buffer, **`C-c a f`** runs `my/task-list-start-agent`: launch the
saved todo task **at point**, without selecting the task again. Dired marks are
ignored; this is not a batch action. The exact Dired path is passed to the public
launcher, so duplicate display titles do not change file identity.

Move to an existing Denote Markdown file with the exact `==todo--` filename
signature. Header/empty lines, directories, unrelated files, backups and other
signatures are rejected before launch, even if a broader list filter displays
them. The action preserves epic/regex filters, sorting and marks. Ordinary Dired
opening/navigation and the `C-c t` task/filter bindings are unchanged; other
global agent-prefix bindings are inherited.

The wrapper neither saves nor reverts visiting task buffers. If a task buffer
differs from disk, the launcher asks you to save or revert before launching;
resolve that deliberately and invoke the action again. Repository/machine/base
choices, worktree creation, overrides, task/skill submission and failure handling
remain exclusively in the launcher. Capture remains file-only.

### `M-x my/agent-session-start-new-worktree`

Select a configured repository, then an eligible machine. **Always confirm the
base ref**, create a new sibling worktree, and start ad hoc. There is no initial
prompt, model/thinking override, or description/name question.

### `M-x my/agent-session-start-in-directory`

Select a machine, then browse from its configured `:directory`. Start ad hoc in
the exact chosen directory without creating a worktree. There is no repository,
base-ref, description, name, model or thinking question, and no initial prompt.

For all three commands, a sole eligible machine is automatic. Multiple machines
always require explicit selection without a default/preselection, regardless of
task `machine` hints or locality. The catalogue base ref is the initial default
for worktrees; legacy task `base-ref` is ignored. Confirming the ref is also where
you can select a preceding PR's branch for a train. There is no combined entry
point, synthetic ad hoc candidate, mode selector, or compatibility alias.

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
  before initialization. Ordinary launches outside these commands are unchanged.
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
  RPC implements both process APIs. Agent-shell-tramp maps agent paths; the
  transcript policy below keeps both local and remote transcripts external.
  Explicit Git operations, including fetch, are
  synchronous and interruptible; no background inventory scan or refresh runs.

## Transcripts

All agent-shell sessions, including ordinary launches outside these commands, use
`~/work/agent-shell/transcripts/` on the **machine running Emacs**. A remote
session never stores its transcript on the agent host or in its worktree.
Each transcript is a timestamped, randomized Markdown file **directly under the
root**, with no machine/project or per-session subdirectories. Existing filenames
and dangling symlinks are skipped. Random names separate concurrent/same-second
sessions without a registry or atomic file reservation. Filename generation
creates neither files nor directories; agent-shell creates the root when needed
and writes its normal header, which carries working-directory/session metadata.

The configuration uses public `agent-shell-transcript-file-path-function`.
The pinned `agent-shell-tramp-mode` replaces this customization when enabled,
so a mode hook reapplies our policy after enabling/disabling it, leaving its
remote path resolver intact. This does not patch either package.

Ordinary startup/submission creates neither `.agent-shell/` nor Git exclusions
or repository files. Existing transcripts under `~/work/agent-shell-transcripts/`
and existing worktrees are not moved or deleted. Clean-worktree prerequisites
remain unchanged.

## Screenshots and clipboard images

Capture on the **machine running Emacs**, then attach in viewport compose:

| Host | Native capture to clipboard | Attach without sending |
| --- | --- | --- |
| macOS | `Ctrl+Cmd+Shift+4`, select a region | `C-c C-y` |
| Wampa (Niri/Wayland) | `Print`, select and confirm in Niri's capture UI | `C-c C-y` |

`C-c C-y` runs public `agent-shell-send-clipboard-image`. The pinned command
requires graphical Emacs and selects the first available clipboard handler.
Wampa already declares wl-clipboard (`wl-paste`); Niri's existing screenshot
bindings/configuration are unchanged, including its separate save to Pictures.
Woowoo needs `pngpaste`, installed separately through the private
`canvanauts/jamesl-home-config` configuration. Until that package is deployed
and visible to GUI Emacs, clipboard attachment on macOS reports a missing tool.
No screenshot or clipboard packages are added by this public change.

On macOS, `C-c C-s` runs public `agent-shell-send-screenshot` using the existing
`/usr/sbin/screencapture -i` default. Select the capture region, or press Escape
to cancel. macOS may require Screen Recording permission for the application
hosting Emacs; check **System Settings → Privacy & Security → Screen & System
Audio Recording** (called **Screen Recording** on older releases), and restart
the affected application if requested. Permission behavior needs a human check;
it was not tested by capturing the screen. Linux has no direct-capture binding:
the upstream X11 ImageMagick default is not configured or installed here.

Both attachment commands append to the current compose draft. Add explanatory
text and send explicitly with `C-c C-c`; attaching never submits a prompt.
They are also available through `M-x`. Capture/tool errors and an empty or
non-image clipboard report an error without changing the draft. A cancelled
capture with no output also leaves the draft intact. Empty external directories
or failed capture files may remain; there is no cleanup/retention system.

Public `agent-shell-dot-subdir-function` redirects artifact subdirectories to
`~/work/agent-shell/` on the Emacs host. Captures and clipboard PNGs go directly
under `screenshots/`, including for remote RPC conversations. There is no
per-session directory, reservation or artifact registry. Native image previews,
@file attachment semantics, and transcript naming remain unchanged. Upstream
image filenames have one-second precision: avoid repeated captures of the same
kind within one second, which can overwrite a previous attachment (or reuse it
if a subsequent capture exits successfully without producing a file). This
upstream limitation is deliberately retained rather than adding capture machinery.

### Image delivery and verification boundaries

The inspected installed versions are agent-shell `20261013.250`, ACP `0.17.1`
and Pi ACP `0.0.34`. With the agent's image capability advertised, agent-shell
reads an attached local PNG and embeds its base64 bytes and MIME type in an ACP
image block. Pi ACP's translator forwards those bytes to Pi, rather than opening
the block's file URI. Thus a remote Pi agent does not need access to the
Emacs-local image path. This depends on the actual remote adapter/version and
advertised capabilities: a plain @path or resource link is not proof of image
delivery, and a different agent may not support this path.

Isolated ERT uses a synthetic PNG and mocked capture/clipboard processes. It
checks destination paths, macOS/Wayland handler selection, failures, cancellation,
draft-preserving native insertion, clean Git worktrees/exclusions and image bytes
for local and simulated RPC CWDs. The remote CWD fixture is not a live RPC
connection or remote delivery test. Actual clipboard contents, screenshots and
model submissions are never used in these automated checks.

A separate isolated check of the installed Pi ACP `0.0.34` translator preserved
the fixture's PNG bytes and MIME type with a deliberately unusable file URI.
It evaluated only the adapter's pure translation function, without starting Pi
or uploading the fixture; live local/remote model delivery remains unverified.

After approved deployment and runtime pickup, a human should check:

1. On macOS, `executable-find` finds pngpaste in GUI Emacs. Capture a harmless
   region to the clipboard, attach with `C-c C-y`, and confirm the existing draft
   remains editable and unsent. Repeat with direct `C-c C-s`, then cancellation.
2. On Wampa, verify `niri --version`, `wl-paste --version` and graphical Emacs's
   tool visibility, then use Print and `C-c C-y`. Check empty/non-image clipboard
   errors leave the draft intact. Wampa's installed versions remain unverified
   while SSH is unavailable.
3. In approved disposable local Pi and remote RPC conversations, attach a harmless
   image and explicitly send a question about its contents. Confirm the agent
   receives the image, not just its filename. Do not copy it to the remote host
   manually as a substitute for verifying embedded delivery.
4. Confirm new images and transcripts are under `~/work/agent-shell/` on the
   Emacs host, old transcripts are untouched, and the project remains Git-clean
   with no `.agent-shell/` or exclusion edits.

These human checks are pending; package deployment, activation and runtime
pickup are separate proof points. Never load feature-worktree code into the
shared daemon to perform them.

## Attention notifications

New agent-shell sessions enable local attention cues via
`my-agent-shell-notifications.el`. Nix pins `agent-shell-notifications` at
`fbf7a6b8c16326242d6e07430b7a8f5e84442466`, using our existing pinned
agent-shell. We retain its event filtering, delayed delivery and acknowledgement
with a local audio-only provider. KnockKnock is not needed or installed by this
integration. There is no runtime package installation.

- A finished turn or permission request produces one soft two-note chime,
  with no visual notification. A finished turn means a response is
  ready, not that a task is complete. Cancelled turns do not notify.
- The selected session counts as active only when its frame has input focus
  and Emacs input was less than ten seconds ago. Active sessions delay the cue
  ten seconds; interaction in the shell or either viewport acknowledges it and
  cancels delivery. Merely leaving a session visible while AFK does not suppress
  notification. Focus detection that returns unknown errs toward notifying.
- Other sessions chime immediately. Waiting-session state persists separately.
- `M-x my/agent-notification-visit-waiting` offers completion over live waiting
  sessions and uses their existing viewport when available. Visiting/interaction
  acknowledges a finished response; permission requests remain listed until
  answered. There is no new global binding, RET takeover, mode-line indicator,
  tab bar, desktop notification or automatic focus change.
- The adapter loads no visual backend. Unused synchronous icon fetching is
  disabled. Acknowledgement cancels pending delivery but does not interrupt an
  already-playing half-second chime.

`config/emacs/sounds/generate-attention.py` is the committed sound recipe. Nix
builds its half-second, mono, 24 kHz/16-bit WAV with integer-only synthesis and
checks its SHA-256; Home Manager links it at
`~/.config/emacs/sounds/agent-attention.wav`. No binary WAV is committed and
activation does not generate audio. Playback is asynchronous via `/usr/bin/afplay`
on macOS and `paplay` (installed by the Emacs module) on Linux, at the existing
system volume. Playback belongs to the **Emacs host**, including
for remote devbox sessions. Set `my/agent-notification-sound-file` to nil to mute.

The `emacs-agent-shell` check includes isolated ERT tests for filtering,
active/AFK decisions, delayed session labels, viewport acknowledgement,
audio-only delivery, provider IDs, navigation and local playback invocation on both
platform branches. `emacs-agent-attention-sound` realizes the deterministic WAV
on the native platform. These are not GUI or real audio playback evidence.

After separately approved deployment and runtime pickup, manually check on
both macOS and Linux: a background session's audible chime with no popup; a visible
AFK session; suppression during active interaction; cancelled turns; choosing
waiting sessions; and two simultaneous sessions. Confirm typing/RET and focus
are unchanged, and audition the chime at ordinary listening volume. Include a
remote devbox conversation to confirm delivery stays local. These manual checks
remain pending; do not load feature-worktree code into the shared Emacs daemon.

## Automatic session cleanup

`my-agent-shell.el` enables `agent-shell-gc-mode` automatically. Nix installs
agent-shell-gc 0.1.0 at `e3b5e1d62187bc7dd3b1d34bdfe7b571ffb1efae`, sharing
the pinned agent-shell/ACP dependencies; there is no runtime package download.

| Policy | Setting |
| --- | --- |
| Close idle sessions | `agent-shell-gc-idle-session-ttl`: 4 days |
| Remove idle worktrees | Disabled: `agent-shell-gc-idle-worktree-ttl` is `nil` |
| Delete branches | Disabled: `agent-shell-gc-delete-worktree-branch` is `nil` |
| Dry-run | Off: eligible session buffers/processes are actually collected |

Sweeps run every 60 seconds, with a 300-second grace period after enabling,
Desktop restoration or a detected forward clock jump. Activity is persisted in
`agent-shell-gc/state.eld` under `user-emacs-directory`; time spent asleep or with
Emacs closed counts towards expiry. Agent output/tool activity, submitted input,
typing and selecting a shell/viewport refresh session activity. Idle is not task
completion; unsent work and in-flight requests are protected as described below.

Sessions are protected while busy, waiting for a permission/elicitation response,
holding unsent queued prompts or shell/viewport text (including a stashed
viewport draft), or explicitly pinned. Unknown/erroring session status is
protected conservatively.
Merely leaving a shell or viewport visible does **not** protect it indefinitely.

Session collection closes the shell, its viewport and associated tool-call diff
buffers, and shuts down its ACP client without a confirmation prompt. It does
not explicitly delete agent-persisted sessions or the external Markdown
transcripts; resumability still depends on the agent. Native agent-shell
temporary sessions additionally remove their explicitly marked temporary
directory when closed. The three launch commands above do not set that marker;
closing their sessions leaves worktrees and branches intact.

Worktree/branch collection is deliberately disabled: this package revision's
worktree resolver mishandles RPC Git paths and bare-source layouts such as
`repo/master.git`. Worktree/branch cleanup needs a separate solution; none is
configured here.

The package still performs best-effort worktree bookkeeping even with deletion
disabled. An unavailable remote filesystem can interrupt a sweep before session
collection. A signalled directory-probe failure preserves the tracking entry;
a nil result is treated as absence and drops that record without deleting
anything remotely. Isolated tests exercise both outcomes; pinned RPC propagates
a simulated transport connection error. This is not live network evidence.

No routine manual command is required. Optional controls:

- `M-x agent-shell-gc-toggle-keep`: pin/unpin the current session from its shell
  or viewport. Pins are buffer-local and do not survive Emacs restarts.
- `M-x agent-shell-gc-list`: inspect idle times and protection reasons. Reports
  and cleanup failures go to `*agent-shell-gc*` by default, not popup prompts.
- `M-x agent-shell-gc-now`: request a sweep now. TTLs and protections still
  apply; it clears grace, although clock-jump detection can establish new grace.
- `M-x agent-shell-gc-mode`: disable/re-enable the global tracking/sweeper.

## Launch failures

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

The launch commands do no cleanup, task-status management, completion monitoring
or agent-to-agent control. GC above is separate idle housekeeping, not a launch
failure rollback or task-completion signal. Launching another conversation does
not grant the agent tools to operate it.

## Viewport typography

Normal `agent-shell-mode` buffers and both viewport modes keep the configured
header style and its model/state/context indicators, but suppress `header-line`
and (when available)
`header-line-inactive` underlines through buffer-local face remapping. This
avoids the gapped line beneath the graphical header's embedded SVG without
changing the renderer, global faces, mode lines or spacious-padding's subtle
lines in unrelated buffers (including ordinary Comint, Markdown and programming
buffers).

Conversation view (`agent-shell-viewport-view-mode`) uses the same mixed-pitch
and Fontaine policy as Markdown buffers: variable-pitch prose, fixed-pitch
inline code, rendered fenced code and tables. The renderer's base faces cover
syntax-highlighted code, source labels, table headers, borders and zebra rows
through face composition/inheritance. Fontaine preset changes refresh active
mixed-pitch buffers. Ordinary shell/tool buffers are not opted into mixed pitch.
The echoed user prompt also uses the variable-pitch family, retaining its native
colour/slant. This is a conversation-buffer remapping of
`agent-shell-viewport-prompt`, not a global change to `font-lock-doc-face`.
Within conversation view, unfenced tool-result text has no dedicated fixed-pitch
face and follows the variable-pitch default too. Whitespace-aligned raw logs or
source in those results may not align; only rendered code/table regions are
explicitly kept monospaced. This is an accepted limitation of the viewport-wide
typography policy, not a renderer change.
An unfinished streamed fence remains raw until the renderer can close it; this
configuration does not change that rendering lifecycle.

Compose (`agent-shell-viewport-edit-mode`) also enables mixed-pitch, but deliberately
without Markdown-aware fontification: prose, raw inline/fenced code and draft
tables all use variable pitch. The mode derives from `text-mode` and does not
supply Markdown faces while typing. The installed Markdown package installs its
fontification together with its major-mode syntax/editing setup, not through a
standalone fontification minor mode. We accept variable-pitch raw code/tables in
drafts rather than copy Markdown internals, add a parser or replace agent-shell's
major mode. Native completion, indentation and composition setup remain in place;
the cursor follows the existing mixed-pitch cursor policy. Rendered conversation
code and tables remain monospaced independently of this compose compromise.

Rainbow-delimiters in rendered fences is deferred. The pinned renderer fontifies
code in temporary language buffers with mode hooks delayed, so the configured
programming-mode hook does not enable rainbow-delimiters there. It has no dedicated
public hook for augmenting that code-fontification step. Its external-renderer
hook is for claiming/rendering regions, not simply augmenting built-in code
fontification. A focused upstream integration point is preferable to running
arbitrary mode hooks, advising private functions or taking over fenced rendering.
Enabling rainbow-delimiters over the whole viewport is not a solution.

The focused UI ERT suite in `emacs-agent-shell` checks local header underline
remapping in normal agent-shell buffers and both viewport modes, repeatable
setup and mode switches, mode-hook scope, fixed-pitch
remappings, raw variable-pitch compose content and native editing setup,
representative rendered code/table faces, streamed fence completion, and refresh
across font-family and Doric theme changes in normal agent-shell buffers,
Markdown and both viewport modes. This is isolated
configuration evidence, not proof of visual alignment or editing behaviour.
After approved downstream deployment and Emacs pickup, check the graphical
header in normal agent-shell buffers and both viewport modes: the header/context data
should remain visible without underline gaps, including inactive windows, while
other buffers retain their subtle lines. Also compare prose, inline code,
labelled/nested fenced code and tables in conversation view, including
streamed updates and unfenced tool output. Check that switching to compose gives
variable-pitch drafts (including raw code/tables), the expected mixed-pitch cursor,
and working indentation/completion, and that existing Markdown buffers remain
unchanged. These human checks are not marked passed by batch tests.

## Completion in compose and other editable buffers

Normal completion-at-point offers Cape filesystem completion for explicit
`./`, `../`, `~/` and absolute directory paths such as `/tmp/`. Relative paths
use the buffer's `default-directory`, including TRAMP/RPC directories; delayed
candidate/location queries retain that base. Cape uses native file handlers and
non-essential lookups, not a project scan or an extra remote transport probe.
This is not live remote performance evidence.

Native/mode-specific providers run first. The guarded file provider is a global
fallback before the existing three-character dabbrev fallback; it does not
replace local CAPF lists. A mode that omits the global fallback marker `t` does
not inherit these providers. Ordinary prose, URLs, @ mentions, relative paths
without an explicit prefix, and slash-command-like tokens (`/`, `/help`, `/usr`)
are not claimed by the file fallback. Add the directory slash (`/usr/`) for an
absolute path. Bare root and root-level filename completion remain available
through `C-c p f`, which retains its optional prefix-argument base-directory
prompt. Cape's filename-token boundaries still apply; candidates can contain
spaces, but this does not add parsing of already-typed whitespace-containing
paths in prose.

Corfu automatic completion is enabled in compose with the existing 0.1-second
delay and two-character threshold, as in programming and Eshell buffers. Cape's
prefix metadata allows `./` to offer candidates immediately at that prefix.
Other prose buffers retain manual completion, and conversation view does not
enable automatic completion. Native @file/slash-command providers, word
completion and editing setup remain intact. Plain paths stay ordinary prompt
text, not attachments or rewritten @ mentions.

The pinned-package completion ERT suite exercises temporary filesystem fixtures,
provider precedence, automatic candidate selection and mocked remote file-handler
dispatch. After approved downstream input update/activation and Emacs runtime
pickup, manually check automatic `./` suggestions, @file/slash commands, prose
word completion, and proportional echoed replies alongside monospaced rendered
code/tables. Batch success is not evidence of popup appearance, actual font
selection, or shared-daemon pickup.

## Verification, activation and smoke tests

`emacs-agent-shell` runs ERT with the pinned packages: temporary real repositories
exercise bare/ordinary/linked sources, local/fetched bases and collisions;
simulated remote file/process boundaries and asynchronous agents exercise
selection, path routing, overrides, readiness and failure handling. A pinned
startup/insertion/viewport regression simulates only ACP initialization/transport
and checks task conversation view versus ad hoc compose mode. Filename-only
completion tests check filtering, narrowing and duplicate titles. Command tests
cover optional file arguments, prompt order, explicit machine selection and
cancellation before mutation. Native transcript tests cover flat paths,
same-second pending sessions, filename collisions, external directory creation
and TRAMP-mode toggles; remote writes simulate only the CWD
existence boundary. A native task-startup/submission fixture leaves its new Git
worktree clean, with unchanged exclusions and no `.agent-shell/`. These are
isolated worktree checks, not proof of live RPC/authentication behavior.

The GC policy suite runs in disposable state with pinned packages. It checks
actual mode enablement/settings, busy and permission/elicitation waits,
queued input, shell/viewport/stashed drafts, activity and pins, visible-session
collection, ACP process shutdown, native temporary-directory cleanup, transcript
and saved-session preservation, worktree/branch retention in ordinary and bare
layouts, and best-effort remote bookkeeping failure handling. Unrelated launcher
tests suppress GC enablement so their simulated remote paths are not probed by
the automatic tracking hooks.

The catalogue/capture/list ERT suite also mocks the public launcher to check
at-point file identity versus marks, invalid targets, cancellation/failure
propagation, untouched unsaved task buffers and list state, and the global/local
agent-prefix bindings. These tests never create live agent sessions.

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

1. Local **start-from-file**: select a non-default base, verify sibling path,
   local branch, full-title display and exactly one task/skill submission.
2. Local **start-new-worktree**: verify repository-before-machine order,
   `adhoc-...`, no description/model/name
   questions and no initial prompt.
3. **start-in-directory**: browse outside owner directories, including
   a project subdirectory; verify the exact CWD and no created worktree.
4. **Remote RPC + local task**: verify destination selection, remote sibling path
   and Git branch, remote ACP CWD, local transcript, and snapshot delivery without
   requiring the task path to exist remotely.
5. Task overrides: model-only, thinking-only, both and neither; verify active
   settings before task submission. Use an unsupported value to confirm submission
   is withheld and the worktree is retained for manual inspection.
6. Check task completion has no synthetic candidates, task titles are readable
   and narrow normally, duplicate titles select distinct notes, and
   done/discarded notes are absent. Verify local/remote transcripts appear directly under the external
   Emacs-side root, including two same-second sessions; ordinary task submission
   must leave Git clean and create no `.agent-shell/` or exclusions.
7. Cancel at each selector/base prompt: no worktree appears. Inspect a startup
   failure and uncertain delivery without deleting work or automatically resending.
8. From a filtered task list, mark a different task, then use `C-c a f` on a saved
   todo note. Verify there is no second task picker and only the note at point
   launches; return to the list and check filters, sort and marks. Try a header,
   directory or non-todo note and confirm rejection. With an unsaved visiting task
   buffer, confirm the save/revert diagnostic leaves edits intact. Outside the
   task list, confirm `C-c a f` uses the normal task picker.

Record build, activation and actual runtime-pickup evidence separately. Live
checks above are not marked passed by the isolated suite.

For GC runtime pickup after authorized activation, use deployed files in a
fresh Emacs process: confirm GC mode is enabled with a four-day session TTL,
dry-run off and worktree/branch deletion disabled. In a disposable conversation, check
`agent-shell-gc-list` and pin/unpin from its viewport. Do not shorten global TTLs
or run collection against real user sessions to smoke-test deployment; any
destructive smoke check needs its own disposable process/worktrees and approval.

Downstream `canvanauts/jamesl-home-config` configurations need a separately
coordinated update of their public home-config input to the landed revision,
followed by their machine-specific build/activation procedure. No private
adapter or input update is included here. Neither a public build
nor an input update proves that the deployed Emacs process has picked it up.