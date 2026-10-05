# Herdsman

Run `herdsman [--config PATH]` to choose **Start session** or **End session**.
Start session is selected by default. Use arrows, Tab, or h/l to switch, Enter to
confirm, or s/f to choose directly. Escape, q, or Ctrl+C cancels without
querying Herdr or starting/ending anything. This uses the same horizontal
prompt styling and navigation as “Start from a task file?”.

Start session collects a local task file or session description, a context, and a
destination machine, then queues a Pi launch. End session queues cleanup of one or
more existing sessions; it does not complete task notes or merge changes. The former
`start` and `finish` subcommands are removed. Neither operation invokes a coordinator
agent. The source lives in `go/herdsman/`.

The launcher can run outside Herdr, including an ordinary terminal or Emacs
terminal. A local Herdr server and any selected saved-machine server must
already be running. Hosts are managed: Git, Pi, Herdr and the normal repository
layout are assumed. Herdsman does not install tools, clone repositories, fetch,
or change project trust. Launch-time fetching is deferred.

## Configuration

### Herdr integration

The Herdsman Home Manager feature deploys a local plugin at
`$XDG_CONFIG_HOME/herdsman/plugin` and registers it with `herdr plugin link`
during activation. Registration uses the configured XDG directories and the
pinned CLI's offline path, without depending on a compatible running server.
The registry stays user-owned: other plugins are retained.
Each activation refreshes and enables `brucenunk.herdsman`; this plugin ID is
owned by the feature. Removing the feature does not automatically unregister
the plugin; run `herdr plugin unlink brucenunk.herdsman` if retiring it.

When Herdr is enabled in Home Manager, the feature also binds `prefix+t` to
the **Herdsman** action. This repository's Herdr feature sets the prefix to
**Ctrl+Space**: press and release Ctrl+Space, then press **t**. Use
**Ctrl+Space, ?** for the active keybinding help. Ctrl+Space is intercepted
by Herdr rather than passed to terminal applications; terminal/input-method
support can vary.

The action runs `herdsman-plugin`, a small shim that asks the invoking Herdr
binary to open the plugin's `launcher` popup. The popup runs the packaged
`herdsman`, offering Start session/End session with the same inventory and themes as terminal launches.
Its width and height are 80% of **Herdr's terminal area**, not the display.
It does not add a persistent tab or pane and closes after success or normal
cancellation. On failure, the popup keeps the diagnostic and recovery output
visible until you press Enter; it does not retry or perform additional cleanup.
Escape follows Herdsman's normal selection/back behavior; Ctrl+C cancels.
Both workflows are available through this popup; there is no automatic launch hook.

After activation, use a newly started Herdr server to check the plugin with
the commands below. Offline registration alone is not evidence that an
already-running server has loaded it.

```sh
herdr plugin action list --plugin brucenunk.herdsman
herdr plugin action invoke brucenunk.herdsman.start
```

The existing `start` action ID is retained for compatibility, but now opens the
Start session/End session menu. The pane ID remains `launcher`. Build checks validate
the generated plugin, offline registration/re-registration, registered action
routing, and the popup runner's success/failure acknowledgement behavior;
they do not prove popup interaction or focus behavior in a live Herdr session.

### Managed application configuration

The dedicated `herdsman` Home Manager feature installs the program and manages
`$XDG_CONFIG_HOME/herdsman/config.toml` (normally
`~/.config/herdsman/config.toml`) as a Nix-generated file. Change inventory,
repository paths/default branches, models and theme selection in the host's Nix configuration,
then rebuild and activate through that host's prescribed route. Do not edit the
managed TOML file directly. Restart the managed Herdsman daemon to load an updated
configuration and catalogue; opening a new picker does not reload daemon policy. Restart
after deploying a new executable too: the long-lived daemon executes launches.
The UI rejects
configuration or local Herdr routing that differs from the running daemon. Named
Herdr sessions and socket overrides must match the service environment; Herdsman
does not silently route them to the default server. Invalid Herdr session names
are rejected. Routing comparisons preserve literal absolute path spellings,
including symlink/parent components; different spellings are conservatively
rejected even if they happen to address the same socket.

`herdsman --config PATH` can use a separate, user-owned file when the daemon was
started with matching configuration. Its `catalogue.json` must be in the same
directory as `PATH`, not discovered on the destination or read from another
XDG directory. TOML and catalogue inventories must agree. Model references must
be unique case-insensitively, and each provider must have one consistent spelling:
Pi cannot distinguish case-only variants reliably. Provider names and model IDs
must not have surrounding whitespace, which Pi normalizes during lookup. Existing standalone
configs need `local_machine_name` and a matching catalogue; there is no inferred
machine-identity migration.

```toml
agent_names = ["runner", "helper"]
tasks_dir = "~/work/tasks"
local_machine_name = "machine-a"

[daemon]
refresh_interval = "30s"
queue_capacity = 32
refresh_concurrency = 4

[theme]
mode = "auto"
light = "doric-marble"
dark = "doric-obsidian"

[machines.local]
# Optional; must name a model in this machine's catalogue.
default_model = "example-provider/vendor/model"

[machines.local.repositories."example/project"]
path = "/home/example/work/example/project/main"
default_branch = "main"

# Must match an enabled saved Herdr label.
[machines.machine-b.repositories."example/project"]
path = "/srv/git/project.git"
default_branch = "master"
```

`tasks_dir` and the optional daemon/theme fields retain the defaults above.
Each machine's repository entry requires an absolute `path` on that machine;
`default_branch` defaults to `main`. Unknown configuration fields are rejected.
The source may be the primary checkout or a bare backing repository; a checked-out
default branch is not required. Herdr resolves the repository parent, and Herdsman
retains its check against unexpectedly resolving to another source.

`agent_names` is required and must be non-empty, with no duplicates. Names must
match Herdr's `[a-z][a-z0-9_-]{0,31}` rule. Wampa declares its twelve names;
they are configuration, not a built-in Go pool. For managed configuration,
declare this pool in Nix and rebuild.

Choosing **No** to “Start from a task file?” opens **Session description** before
context/machine selection. Enter a non-empty, single-line description and press
Enter to continue. Escape returns to the task-file question; backing out of
context returns to the description with its text preserved. The description
names the session only: it is never submitted as an initial prompt.

With a task file, the picker shows only the union of configured repository slugs.
Without a task file, **Select context** combines those slugs with their deduplicated
owners in one sorted, single-column list:

```text
Canva
Canva/k8s
brucenunk
brucenunk/home-config
brucenunk/other-repo
```

The slash distinguishes a repository from an owner. Selecting a repository
always creates a fresh worktree and branch, even without a task file; selecting
an owner starts directly at `$HOME/work/{owner}` without a worktree or branch.
Owner directories must already exist. Owners are derived from the configured
repository inventory, not filesystem discovery; there is no arbitrary path picker.

Without a repository hint, the picker opens with no selection. Navigate to
explicitly select a context before pressing Enter; filtering clears the selection.
Back-navigation preserves the selected context. The machine picker shows
only configured hosts for that repo which are Local or uniquely labelled,
enabled saved Herdr machines. There is no availability probing while navigating.
For an owner, it shows eligible hosts configured with any repository under that
owner. No additional owner configuration is required.

Source paths come directly from the selected machine's repository definition.
The initial worktree base ref is `origin/${defaultBranch}` for the selected
machine/repository. The base-ref form supports per-launch/task overrides;
they are not static repository policy. Herdsman never changes the branch or
files checked out at the source. New task worktrees still use `$HOME/work/{owner}/{repo}/{stamp}`,
and owner sessions still use `$HOME/work/{owner}`.

### Shared machine data

Hosts reuse Git/Pi definitions under `brucenunk.homeManager.herdsman.machines`,
keyed by machine name, without evaluating complete remote host configurations.
Import Git, Pi, and Herdsman explicitly with the shared `llm-agents` overlay.
For example, this fragment adds a synthetic second machine:

```nix
{ config, ... }:
let
  git = {
    repositories."example/project" = {
      path = "${config.home.homeDirectory}/work/example/project/main";
      defaultBranch = "main";
    };
  };
  piModels = { }; # Reuse the host's selected Pi models configuration here.
in
{
  brucenunk.homeManager = {
    inherit git;
    pi.models = piModels;
    herdsman = {
      machineName = "machine-a";
      machines = {
        "machine-a" = { repositories = git.repositories; models = piModels; };
        "machine-b".repositories."example/project" = {
          path = "/srv/git/project.git";
          defaultBranch = "master";
        };
      };
      config.agentNames = [ "runner" "helper" ];
    };
  };
}
```

`$XDG_CONFIG_HOME/herdsman/catalogue.json` is the generated view shared by Emacs
metadata editing and Herdsman's launch selection:
`localMachine` is the launcher's named machine key; each `machines.<name>` record
contains `repositories: [slugs]`, `defaultBaseRefs: {slug: ref}`, an effective
`defaultModel`, and `models: [{name, thinkingLevels, defaultThinking}]`.
Model names are exact `provider/model` references: split at the first slash only.
Thinking levels follow Pi's maps; only configured chat models are included.
Base refs project the per-machine Git branch defaults as `origin/${defaultBranch}`;
they contain no live reachability information. There are no Git paths, provider connection fields, credentials, display
names, or schema version. These are configured choices, not readiness checks;
task metadata provides defaults and Herdsman owns final selection.

Emacs `my/task-add` prompts for a repository and writes all five launch hints,
using catalogue defaults for ordinary capture. Prefix capture exposes choices
in the same order as Herdsman: repository, machine, base ref, model, thinking.
It skips a single eligible machine; thinking always uses the selected model's
supported levels. Missing/invalid catalogue data blocks capture, not listing.
See `work/TASKS.md` for capture details. Existing notes are not migrated.

The catalogue's effective model is the configured machine default, otherwise
the first model (or an empty string with no models). Thinking projects the
existing launch rule: `medium` when supported, otherwise `off`, otherwise an
empty default requiring explicit selection. Herdsman consumes these projected
defaults and validates their agreement with operational configuration. Standalone
older catalogues without capture defaults remain usable by Herdsman; Emacs
requires the generated capture data. No mutable Pi settings are consulted.

Only the current launcher TOML translates `machineName` to `local`; its
`local_machine_name` records the original catalogue key explicitly. JSON keeps
machine names, including the local machine's name. Task `machine` hints use
these keys, never the user-facing **Local** label or the TOML routing key `local`.
Remote names match saved
Herdr labels. Repository paths and default branches are per machine: shared slugs
may point to different checkouts or bare repositories.

Each machine may declare `brucenunk.homeManager.herdsman.machines.<name>.defaultModel`
as an exact `provider/model` reference. For the local machine, its option default
comes from `defaultProvider` and `defaultModel` in Pi's Nix `settingsDefaults` JSON
file, when both are provided. It does not read mutable `~/.pi/agent/settings.json`.
Remote records do not inherit the local Pi default; supply their default from
that machine's shared Nix Pi data if desired.

An explicit value overrides the inherited local default; explicit `null` disables
it and restores first-catalogue-model preselection. For example:

```nix
brucenunk.homeManager.herdsman.machines."machine-a".defaultModel = "example-provider/vendor/model";
```

The option is emitted into operational TOML as `machines.<destination>.default_model`;
catalogue JSON exposes the resulting effective model. Defaults must belong to the selected machine's
catalogue; Nix and standalone TOML loading reject unknown defaults. Rebuild,
activate, and restart the Herdsman daemon after changing this policy. Changing
Pi's mutable default alone does not change Herdsman's initial selection.

### Migration from writable or separately defined configuration

Replace old source-directory/root declarations with absolute `path` values and
static base refs with repository `defaultBranch` metadata. Move declarations to
`herdsman.machines`; its records reuse Git's repositories and Pi's models.
The removed `git-maintenance` module and `gitMaintenance.repositories` also move
to Git, which uses these paths for native Linux/Darwin schedules. Operational
Herdsman settings remain under `config`; no old-schema compatibility adapter is provided.

Before the first managed-file activation, inspect the existing writable TOML
and transfer any inventory, names, paths or theme edits into Nix. Preserve a
backup and move the old file out of the managed destination, or use the host's
approved Home Manager backup mechanism. Do this deliberately; the module uses
normal Home Manager collision protection, not `force`, and does not silently
overwrite or migrate a user-owned file. Subsequent activations manage the file
normally. Build checks do not perform that migration or activation.

## Styling and themes

The `[theme]` table assigns named palettes to light and dark terminals, like
Ghostty's `light:NAME,dark:NAME` selection. `mode` accepts `auto`, `light`, or
`dark`. Missing fields default to `auto`, `doric-marble`, and `doric-obsidian`,
respectively. Theme names must use
lowercase letters, digits, and hyphens; invalid names and modes are rejected
before entering the picker.

Auto detection uses Lip Gloss's terminal-background detection once at startup,
before Bubble Tea reads input. It queries the terminal, falls back to
`COLORFGBG` where available, and otherwise assumes a dark background. It does
not follow background changes while the picker is open. If detection is wrong
in your terminal, set `mode` explicitly. Colors respect the terminal's color
capabilities; selection borders/brackets remain usable without color.

Both palettes are generated from Doric by the `theme-builder` skill's
`herdsman` target. The color-only TOML files live in
`config/herdsman/themes/`; Home Manager deploys them to
`$XDG_CONFIG_HOME/herdsman/themes/`. They contain no light/dark classification:
the main config owns that mapping. Herdsman reads the selected named file from
a `themes/` directory beside its active config file, including when using
`--config PATH`.

The shipped names are `doric-marble` and `doric-obsidian`. You can copy one
under a new name and configure it as a light or dark palette. Shipped files
are Home Manager-managed; custom files are user-owned. Palette edits require
only restarting Herdsman, not rebuilding the executable. For example, a
`custom.toml` palette has this schema (the original seven colors are required;
the two filename colors are optional and default to `muted`):

```toml
[colors]
text = "#202020"
muted = "#4a4a4a"
accent = "#603d3a"
selection_background = "#e5d7c5"
selection_text = "#202020"
filename_secondary = "#404040"
filename_muted = "#595959"
match = "#603d3a"
error = "#a01010"
```

No palettes are embedded in the binary. If the selected file or theme directory
is absent, Herdsman uses terminal-native styling: bold/underline and selection
markers without custom colors. A misspelled theme name therefore also selects
neutral styling. Present but unreadable, malformed, or incomplete files are
errors rather than silently falling back; unknown palette fields are rejected.
Repository and machine rows have no blank spacer lines.

Themed selections use Doric's `bg-accent` (Emacs's `hl-line` and
`pulsar-generic` background): list selections fill the row without making the
whole filename bold; confirmation buttons have equal padding and spacing,
without brackets in colour-capable terminals. Colourless terminals retain
brackets to identify the selected choice. In the task picker,
Denote filenames follow Emacs's face distinctions: directories, signatures,
and keywords are bold in `fg-shadow-intense`; timestamps use the same colour
without bold; delimiters and extensions use `fg-shadow-subtle`; titles retain
the row's text colour. Fuzzy matches retain their accent and underline over
these styles. Ordinary filenames and terminal-native fallback are unchanged.

## Selection and launch

### Optional task hints and precedence

The start sequence is task/description → context → destination → base ref
(repositories only) → model → thinking. Every screen requires confirmation;
hints do not skip screens, trigger automatic launches, or edit task notes.

All five front-matter hints are optional:

```yaml
repo: example/project
machine: machine-a
model: example-provider/vendor/model
thinking: high
base-ref: upstream/train/next
```

Explicit final selections win over hints; hints win over initial launcher
defaults. Unknown or incompatible hints are shown at the affected screen, with
no selected replacement. Navigate to deliberately replace a list hint, or edit
the base-ref form; Enter alone does not silently accept a fallback. Hints with
unsafe control characters or oversized/non-UTF-8 values are rejected when read.
Old notes with no hints still work.

- `repo` preselects a configured repository. Without it, select a context by
  navigation. Owner contexts remain available for launches without a task file.
- `machine` preselects an eligible destination supporting that context. Without
  it, prefer Local when eligible, otherwise retain the existing first-destination
  default. Catalogue membership does not imply reachability or authentication.
- `base-ref` initializes the form **verbatim**, without prepending `origin/`.
  Without it, use `origin/${defaultBranch}`. Editing makes the field an explicit
  override; **Ctrl+R** resets it to the selected repository's default. Automatic
  defaults recompute on repository/destination changes; explicit overrides remain
  unchanged for correction or confirmation on the new destination.
- `model` is an exact destination-specific catalogue reference, split only at
  the first slash to identify its provider and model ID. Pi's CLI consumes one
  provider prefix before matching, so Herdsman adds that prefix to the canonical
  reference in `--model`; the resolver then receives the exact catalogue
  reference, even when the model ID itself starts with the provider name.
  The task hint and IPC selection remain unchanged. Without a hint, the machine's
  configured default model is initially selected, falling back to the first
  catalogue model only when no default is configured. A destination with no configured
  models cannot launch; choose another destination or update configuration.
- `thinking` is selected from that model's projected Pi-supported levels. Without
  a hint, select `medium` if supported, otherwise `off` if supported; otherwise
  require a deliberate selection. A thinking-only hint can preselect a compatible
  level after model selection. Explicit incompatible thinking is not reset when
  changing model. There are no “Pi default” model/thinking entries: final choices
  are passed explicitly.

Back-navigation preserves compatible choices. Repository/destination/model
changes revalidate dependent selections; incompatible explicit values remain
visible until corrected. Task hints are not re-applied over final selections.
The daemon validates final model, thinking, context and base-ref choices again,
independently of the task's original hints.

### Base-ref semantics

A slash means **remote/ref**, split at the first slash:

| Base ref | Queued execution |
| --- | --- |
| `origin/main` | Give Herdr `refs/remotes/origin/main`, using the existing remote-tracking ref. |
| `upstream/train/next` | Give Herdr `refs/remotes/upstream/train/next`, using the existing remote-tracking ref. |
| `main` | Give Herdr `refs/heads/main`, using the existing local branch without upstream inference. |

The form labels both local and remote refs as existing, unrefreshed choices. Slash-containing local
branch names, fully qualified `refs/...` forms, tags, commit IDs and revision
expressions are not supported. Explicit refs are not interpreted as paths or
used to name the new worktree. The field and daemon IPC value stay verbatim;
only the worktree creation argument is qualified to the selected namespace,
so a same-named tag or local branch cannot shadow a selected remote ref.

Herdsman validates ref syntax before workspace mutations. Herdr resolves the
qualified ref during worktree creation; Herdsman does not inspect its existence,
commit, symbolic-alias target, configured remote, or freshness beforehand.
A missing or unusable ref can therefore fail after parent workspace creation or
rename. Launch stops without starting Pi; inspect Herdr before retrying. There
is no automatic retry or cleanup.

Launch-time fetch, pre-mutation Git ref validation, and background “keep warm”
fetching are deferred. Ensure refs are updated separately on the destination.
Git maintenance prefetch warms `refs/prefetch/`; it does not update ordinary
`refs/remotes/` tracking refs. Herdsman adds no Git subprocess, transport override,
Git package dependency, or Git timeout setting. Source branch/files remain under
the existing Herdr lifecycle boundary. Owner sessions have no base-ref field or
base-ref launch argument.

### Picker controls

- Confirmation: arrows/tab and Enter, or `y`/`n`.
- Task selector: type immediately to fuzzy-find relative filenames; arrows or
  Ctrl+N (down)/Ctrl+P (up) move through ranked matches and one Enter selects
  the highlighted file. All regular
  `.md` files whose basename contains `==todo--` are indexed recursively, including
  epic directories. Historic `==done--`/`==discarded--` notes and other Markdown
  files are excluded. Paths are relative, such as
  `epic/20260930T193614==todo--task.md`. Matching uses Bubbles' `list.DefaultFilter`
  entirely in memory; front matter and task bodies are not read during indexing.
  Escape offers a session without a task file or cancellation. Invalid task metadata stays
  in the selector with an error. Missing or unreadable directories report the
  failure and offer a session without a task file or cancellation. Continuing
  without a task file still requires a session description.
- Context/repository/machine lists: arrows or Ctrl+N (down)/Ctrl+P (up) to navigate,
  `/` to filter, Enter to choose, Escape to clear the filter or go back.
- Model/thinking lists use the same controls. The base-ref form uses Enter to
  continue, Escape to go back, and Ctrl+R to reset to the repository default.
- Ctrl+C cancels everywhere. Selection performs no launch mutations.

Tasks must be regular files. Reading them runs outside the TUI event loop, so
Escape and Ctrl+C remain responsive while loading.
Task files need YAML front matter with a non-empty, single-line `title`.
`skill` and the five selection hints above are optional. Hints are not appended
to the prompt or converted into launch instructions. The prompt preserves the
complete body after front matter. When a non-empty `skill` is declared, it must be a valid skill name
and the prompt appends:

```text
Load the {skill} agent skill and follow instructions.
```

With missing or empty `skill`, only the body is sent, unchanged; no instruction
or extra separator text is appended.

Task files, including front matter, are limited to 256 KiB; reads are bounded
before parsing. Titles and complete prompts must be valid UTF-8, each fit within
120 KiB, and contain no NUL bytes, because the Herdr CLI carries them as individual
process arguments. Unsupported tasks are rejected before launch; their contents
are never truncated.
Task titles must not contain control characters. Filename and task-read error
controls are displayed as escaped text, never terminal commands; original paths
are retained for reading files.

Task-based Pi sessions use the task title. Sessions without a task file use the
entered description as the Pi title; repository workspaces use that same label.
Owner workspace labels put the description first, followed by the cleanup marker:
`{description} · herdsman: {agent} · {owner}`. This keeps sessions readable and
distinct while retaining snapshot-only cleanup discovery. All sessions without
a task file receive no initial prompt. Descriptions must be valid UTF-8, contain
no control characters, and fit the same 120 KiB CLI argument limit as task titles;
owner descriptions must also leave room for the marker in the workspace label.
Agent names are picked randomly from `agent_names`,
excluding names on Local and **every enabled saved Herdr server**, including
servers absent from this inventory. An unreachable server stops launch because
global availability cannot be established. This policy is not a distributed
lock: simultaneous launchers can race; Herdr enforces names on its own server.
Owner launches also exclude names whose owner-session marker remains
in the destination's workspace inventory, even if that workspace has no agent.
If those leftovers exhaust the pool, inspect and close them manually; Herdsman
does not automatically remove abandoned workspaces.

The picker uses cached machine profiles. When a queued start executes, the daemon
reloads profiles and verifies the selected machine ID, label, SSH target, remote
Herdr session, and enabled state. One live `herdr api snapshot` per enabled server supplies agent-name
availability and, on the destination, parent workspace inventory. Cached snapshots
never authorize launch mutations.

For repository contexts, Herdsman uses Herdr's source resolver to select an existing non-linked source
workspace, renaming it to `owner/repo`, or creates that parent at the configured
`gitdir`. The resolved source path must match the configured source directory;
an unrelated source or a linked checkout resolving to a different backing
repository is rejected before launch mutations. Configure the backing repository
itself for bare-backed layouts. This anchors the repository group independently
of the Git `base` ref used to create its task worktrees.
If multiple ordinary workspaces point at that same checkout, accepting Herdr's
first match is intentional: either can anchor the group. Herdsman does not scan
every ordinary workspace to enforce uniqueness or remove duplicate workspaces.
It creates a fresh sibling worktree named
with a UTC nanosecond timestamp and branch `jamesl/{timestamp}`, starts idle Pi,
submits the optional task prompt once, and focuses the agent. On remote hosts,
a bounded SSH call reads `$HOME`; all Herdr operations use the saved profile ID.
Ordinary calls are bounded at 30 seconds, Pi startup at 125 seconds (Herdr's
readiness timeout is 120 seconds).
Each local CLI invocation owns a separate process group; timeout/cancellation
terminates its CLI/SSH children, not the shared Herdr server or remote workspaces.

No separate repository-existence, origin, tool, or cleanliness prechecks are
performed: operation errors are authoritative. Pi trust/approval dialogs are
not bypassed. A blocked startup leaves its state in place for human inspection.

On failure, successful steps and the intended path/branch are reported. The
failing operation may also have applied, especially after a timeout or lost
remote connection. **Inspect Herdr before retrying.** Herdsman never automatically
retries, sends a second prompt, closes workspaces, or deletes worktrees.
Each deliberate invocation is a fresh launch, not task resumption.

### Owner-directory sessions

Each owner launch creates a new, session-scoped ordinary Herdr workspace at
`$HOME/work/{owner}`. A workspace is runtime pane/process state, not the directory
itself. Existing owner workspaces are not reused: two sessions at the same owner
have different agents, workspaces, and conversations, but share filesystem contents.
Concurrent edits can conflict; use repository worktrees for implementation work.
Owner launch skips source resolution and worktree creation, reusing the same global
agent-inventory snapshots. It validates that the owner path is a directory before
creating the workspace: locally with a filesystem check, remotely within the
existing SSH `$HOME` lookup, without an extra request. Herdr can otherwise silently
fall back to `$HOME` for an invalid working directory. This check is not a lock;
do not remove or replace the directory during launch.

Starting in the owner directory loads applicable ancestor/owner guidance, not
every descendant repository's `AGENTS.md`. Read repository-specific guidance
when entering a repository during research.

## Ending a session

Run `herdsman [--config PATH]` from an ordinary terminal or a Herdr
pane and choose **End session**. Both operations share configuration and themes. The sorted picker
lists workspace labels (the task title, or description for sessions without task files,
with owner sessions retaining their cleanup marker)
across Local and every enabled saved Herdr machine, including machines absent
from the configured repository inventory. Duplicate labels gain an agent/machine
prefix. An unreachable server retains its last successful cached inventory with
a stale/error warning; other machines remain visible. A machine with no successful
refresh is reported as loading/unavailable, not as having no sessions.

Only idle/done Pi agents in eligible linked-worktree workspaces or recognizable
Herdsman owner-session workspaces are offered. Owner workspaces must retain the
intact `herdsman: {agent} · {owner}` marker after the description, have no Git worktree metadata, contain
one pane in one tab, and have exactly one agent. Duplicate workspace IDs/labels
are excluded for owner sessions. Changing the agent name, removing/changing the
marker, or adding panes/tabs makes the owner session ineligible; close it manually
instead. Existing sessions with the older marker-only workspace label remain eligible.
Changing any selected owner's workspace label after selection stops cleanup.
The label is a discoverability convention, not a security or ownership token;
do not assign this pattern to unrelated workspaces. The pinned snapshot exposes
no stable ordinary-workspace root path, so owner classification does not rely
on current shell directories or additional remote lookups.

The daemon cache supplies agents and workspaces together. Opening the picker
does not query any remote server. The status check uses this cached inventory. Checkouts reported as shared by multiple agents are excluded; the
current session is not excluded. There is no special default selection or filtering.
Use arrows or Ctrl+N/Ctrl+P to navigate. Space toggles a row's selection mark
and advances to the next row, whether selecting or deselecting. At the final
row, it stays put without wrapping. The header shows the selected count.
Enter ends all marked sessions
in displayed order; if none are marked, it finishes only the highlighted row.
Escape or Ctrl+C cancels without cleanup, including when rows are marked.

Discovery is shared across the selection, but background cleanup is sequential.
Each session retains its own pre-quit revalidation, quit, wait, safety snapshots,
and removal; final safety snapshots are not shared. Successful steps and results
are logged. The first error stops that batch and logs the failed/possibly uncertain
session, the number completed, and unattempted sessions. Later independent queued
requests can still execute.

**Enter queues cleanup without another confirmation dialog.** Before `/quit`,
the daemon obtains a fresh snapshot and verifies that the original agent/session
and workspace identity still match and remain eligible (idle/done). A reused name,
changed checkout/label, busy agent, or additional occupant stops the request
without quitting. Revalidation is not a lock against concurrent external changes.

Herdsman uses `herdr agent wait PANE --until unknown --timeout 30000` on the
selected pane as the initial notification. Herdr reporting unknown
status or an absent/stopped agent is only a wakeup, not proof of safe cleanup.
A final snapshot must confirm the selected checkout still exists at the same
path and that no agent uses its workspace, checkout, or selected agent name.
Lifecycle release can precede process/inventory disappearance. If the exact
original session is still the sole occupant, Herdsman retries the safety snapshot
with a 100 ms delay between reads. Session identity includes the name, kind,
pane, workspace, and complete session reference; changed status alone is allowed.
Herdr can also briefly retain a draining record with the original name, pane,
and workspace but an empty kind and no session reference. This specific shape
permits read retries only; removal still requires complete absence. Other
identity changes, an additional occupant, a changed checkout, or an inspection
error stop cleanup immediately. Identity errors name the mismatched fields
without printing payloads. The Herdr wait and snapshot retries
share one 30-second exit-confirmation deadline. Only reads are retried: `/quit`
and removal are each sent at most once. Wait transport errors, timeouts, and
unexpected responses also stop cleanup. Removal has a separate timeout.
Execution reloads machine profiles and adds a pre-quit safety snapshot, followed
by quit, wait, final snapshot, and removal. An early wakeup adds snapshot reads
until the original session disappears or confirmation stops.
For worktree sessions, after the final safety checks, Herdsman calls
`herdr worktree remove --workspace ID --force`. Forced removal intentionally
discards uncommitted checkout contents and removes the task workspace. The
parent repository workspace, Git branch, and saved Pi transcript remain.
Finish runs no direct SSH commands; saved-machine routing belongs to Herdr.

For owner sessions, the same final snapshot must confirm the workspace still
has its original label, no worktree metadata, and one pane in one tab, and that
no agent uses the selected workspace, agent name, or pane. Original/draining
agent records permit the same bounded read retries. Other owner sessions in
separate workspaces do not block cleanup, even when rooted in the same directory.
Herdsman then calls `herdr workspace close ID`, never group closure or worktree
removal. This drops workspace/pane runtime state while retaining all directory
contents and the saved Pi transcript. Closure is sent at most once, with a
separate timeout; uncertainty requires manual inspection before retrying.
The owner end path uses the same pre-quit revalidation, then quit, wait, final
snapshot, and close.

Herdr submits `/quit` through Pi's editor without clearing it. An existing draft
can therefore be submitted instead of quitting. Check that the target session's
editor is empty before finishing; Herdsman intentionally leaves input untouched.

Shared-checkout detection is best-effort: it uses Herdr's workspace worktree
metadata and can miss an agent using the same checkout from an ordinary workspace
or after changing directories. You are responsible for ensuring that no other
session is using the checkout being finished.

Timeouts, lost contact, changed targets, and unexpected removal responses stop
cleanup without retrying mutations. Pi may already have quit, or removal may
already have applied: inspect Herdr before retrying. Rechecks are not a lock;
avoid concurrent changes to the selected workspace while finishing it.

## Daemon, cache, and queue

Home Manager manages a local daemon with systemd on Linux and launchd on macOS.
The foreground entry point is `herdsman daemon [--config PATH] [--debug]`.
The UI never auto-starts it and never calls Herdr or SSH. A missing daemon reports
an error with service/log guidance. Cancelling the initial menu does not contact
it either.

Local IPC is HTTP/JSON over a Unix socket in a user-owned private directory:
`$XDG_RUNTIME_DIR/herdsman/daemon.sock` when set, otherwise the platform user
cache directory (`$XDG_CACHE_HOME/herdsman/daemon.sock` or
`~/.cache/herdsman/daemon.sock` on Linux; normally
`~/Library/Caches/herdsman/daemon.sock` on macOS). UI and daemon must agree on
these environment settings. A file lock prevents multiple socket owners and
permits recovery of a stale socket after a crash. There is no TCP listener.

Profiles and per-machine snapshots are refreshed on startup and at the configured
`daemon.refresh_interval` (default `"30s"`). Snapshot reads use the configured
`daemon.refresh_concurrency` (default four), one in flight per machine
profile, so slow remote reads do not hold the cache lock or delay publishing other
completed reads. Failed refreshes preserve the last successful snapshot and its
timestamp. Removed/disabled profiles disappear from the picker inventory. Task
files and remote HOME lookups are not cached.

Each picker uses one stable cache view and a persistent inventory status line:
healthy inventory shows the oldest successful refresh age; stale or unavailable
entries identify the affected machines (or machine profiles). Age is time since
the last successful refresh, not the last attempt. A refresh error warns
immediately; otherwise a snapshot is stale after twice the configured interval.
The displayed age updates every second against the fixed picker snapshot, so
leaving a picker open can make its view stale even while the daemon refreshes.
Rows never change underneath a selection, and age updates perform no IPC or
remote calls. Detailed refresh failures are in daemon logs; no-target output also
lists cache warnings. Leave and reopen for an updated view. Start requires an initial
successful profile refresh; end-session discovery can use whichever machines
have loaded. No-target output distinguishes incomplete/stale inventory from a
successfully refreshed empty inventory. Fresh execution checks—not cached state—
authorize mutations. A completed or failed operation schedules a refresh of the
affected machine. Refreshes fetched before a mutation, or for a replaced machine profile/cache
entry, are discarded rather than published as new state.

Requests enter a bounded, in-memory FIFO (`daemon.queue_capacity`, default 32
pending requests) with one execution worker. A full queue is rejected immediately. All mutations issued by this daemon
are serial, including multi-session cleanup; external Git/Herdr activity is not
locked. The UI reports **Queued**, not Started/Ended, and exits after acknowledgement.
Closing the UI does not cancel accepted work. If acknowledgement is lost, acceptance
is uncertain: inspect logs before resubmitting.

The queue, cache, and results are not persisted. On daemon shutdown, active
subprocess work is cancelled and pending requests are discarded with log entries.
There is no restart replay, automatic mutation retry, or cleanup of uncertain
results. Herdr is the source of truth: inspect it after a failure/restart and
submit a new request if needed. There is no job-status command.

## Service operation and logs

Linux:

```sh
systemctl --user status herdsman.service
journalctl --user -u herdsman.service -f
systemctl --user restart herdsman.service
```

macOS:

```sh
launchctl print "gui/$(id -u)/org.brucenunk.herdsman"
tail -f ~/Library/Logs/herdsman.log
launchctl kickstart -k "gui/$(id -u)/org.brucenunk.herdsman"
```

Normal logs are timestamped JSON on stderr: daemon lifecycle; request acceptance,
selection, execution, success/failure and elapsed time; confirmed finish steps;
start result paths/branch/workspace and successful steps; and recovery guidance.
Internal request IDs correlate entries within one daemon lifetime. Refresh errors
are logged on change and recovery, not repeated on every unchanged failure.
Linux journal retention belongs to systemd; launchd appends to the log above,
without application-managed rotation. Neither log is a persisted queue.

The service wrapper loads Home Manager’s managed session environment, including
`home.sessionPath` with shell variable expansion (such as `$HOME/.local/bin`),
and includes managed profile tools. Put SSH ProxyCommand helpers such as Coder in those paths,
or use absolute paths in SSH configuration; interactive-shell-only PATH edits
are not available. Authentication, SSH agent availability, and saved-machine
routing remain Herdr/OpenSSH responsibilities.

For subprocess timings, enable `--debug` on the daemon, either by overriding
the native Home Manager service command or by stopping the managed service and
running it in the foreground. Do not run a second daemon against the same socket.
Debug entries report machine, tool, quoted sanitized arguments, elapsed time,
and subprocess status. A hung call logs only after it exits or times out. Timings
include CLI startup/transport, not individual remote-server phases. Expected
agent-disappearance responses can show `status=error` while safely waking the
finish checks; subprocess success alone is not application success.

Task bodies and initial prompts are never logged. Debug arguments redact prompts
except the fixed `/quit` command, and response payloads/stderr are excluded.
Daemon error diagnostics omit CLI stderr and API messages that might echo prompts,
retaining operation context, exit status or error code, and recovery guidance.
Machine labels, paths, workspace labels and other metadata remain visible;
inspect logs before sharing them.

## Task-directory snapshots

Entering the task selector takes one recursive filename snapshot. It does not
follow symlinked subdirectories or include non-regular files. A symlink used for
the configured root directory is resolved before indexing. There is no live
filesystem watcher; leave and reenter the selector for a fresh listing.

The previous Bubbles file picker could panic if a listed entry disappeared before
rendering. It has been replaced with a Bubbles List and owned filename snapshots:
rendering performs no filesystem calls. If an indexed file is renamed or deleted,
the stale row can still be displayed, but selecting it reports the read error
without crashing or launching anything. This path has a regression test.

## Development

```sh
cd go/herdsman
go test ./...
go test -race ./...
go vet ./...
go run . --help
```

`nix build .#herdsman --no-link` builds the package and runs its Go tests.
`checks.<system>.herdsman-home-manager-module` checks the feature wiring.
Repository verification additionally requires the staged Wampa Home Manager
build; see `AGENTS.md`. These checks do not activate configuration or demonstrate
a running Pi/remote server has loaded it.

Model comparisons, branch deletion, repository-parent pruning, and cleanup of
workspaces without a live agent are deferred. Use `herdsman` for session launch
and cleanup.