# Herdsman

`herdsman start` collects an optional local task file, a repository, and a
destination machine, then starts a new Pi session through the Herdr CLI. It
does not invoke a coordinator agent. The source lives in `go/herdsman/`.

The launcher can run outside Herdr, including an ordinary terminal or Emacs
terminal. A local Herdr server and any selected saved-machine server must
already be running. Hosts are managed: Git, Pi, Herdr and the normal repository
layout are assumed. Herdsman does not install tools, clone repositories, fetch,
or change project trust.

## Configuration

The dedicated `herdsman` Home Manager feature installs the program and seeds
`$XDG_CONFIG_HOME/herdsman/config.toml` (normally
`~/.config/herdsman/config.toml`) only if absent. The resulting file is writable:
edit inventory without rebuilding. Later activation does **not** update or
overwrite it, even when the initial host configuration changes.

Use `herdsman start --config PATH` for a different file.

```toml
agent_names = ["bushturkey", "binchicken", "possum", "quokka"]
tasks_dir = "~/work/tasks"
default_base = "main"

[theme]
mode = "auto"
light = "doric-marble"
dark = "doric-obsidian"

[machines.local]
repositories = ["brucenunk/home-config", "owner/legacy-repo"]

# Optional: must match an enabled saved Herdr machine label.
[machines.devbox]
repositories = ["brucenunk/home-config"]

[repositories."owner/legacy-repo"]
base = "master"
```

`tasks_dir` and `default_base` default to the values above. `local` is reserved
as the configuration/internal selector and is displayed as **Local** in the UI
and launch output;
other machine labels are case-sensitive Herdr labels. SSH targets, credentials,
and session selection remain in Herdr/OpenSSH, not this file.

`agent_names` is required and must be non-empty, with no duplicates. Names must
match Herdr's `[a-z][a-z0-9_-]{0,31}` rule. Wampa seeds the existing twelve names;
they are configuration, not a built-in Go pool. Changing the list needs no rebuild.
If an older writable config already exists, add this field manually: activation
deliberately does not migrate or overwrite existing inventory.

The repository picker shows the union of configured slugs. Task `repo` metadata
preselects a configured entry but can be overridden. The machine picker shows
only configured hosts for that repo which are Local or uniquely labelled,
enabled saved Herdr machines. There is no availability probing while navigating.

Sources are `$HOME/work/{owner}/{repo}/{base}` on the destination. Bases must be
single checkout directory names (`main`, `master`, etc.); custom PR-train refs
and alternative layouts are not supported in this first version.

An external Home Manager consumer imports `modules.homeManager.herdsman` and
may seed its initial inventory with:

```nix
brucenunk.homeManager.herdsman.initialConfig = {
  agentNames = [ "runner" "helper" ];
  defaultBase = "main";
  machines.local = [ "owner/repo" ];
  repositoryBases."owner/other-repo" = "master";
  tasksDir = "~/work/tasks";
  theme = {
    mode = "auto";
    light = "doric-marble";
    dark = "doric-obsidian";
  };
};
```

Like the other public modules, consumers must supply the shared `llm-agents`
package overlay.

## Styling and themes

The `[theme]` table assigns named palettes to light and dark terminals, like
Ghostty's `light:NAME,dark:NAME` selection. `mode` accepts `auto`, `light`, or
`dark`. Missing fields default to `auto`, `doric-marble`, and `doric-obsidian`,
respectively, so existing configs do not need migration. Theme names must use
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

- Confirmation: arrows/tab and Enter, or `y`/`n`.
- Task selector: type immediately to fuzzy-find relative filenames; arrows or
  Ctrl+N (down)/Ctrl+P (up) move through ranked matches and one Enter selects
  the highlighted file. All regular
  `.md` files whose basename contains `==todo--` are indexed recursively, including
  epic directories. Historic `==done--`/`==discarded--` notes and other Markdown
  files are excluded. Paths are relative, such as
  `epic/20260930T193614==todo--task.md`. Matching uses Bubbles' `list.DefaultFilter`
  entirely in memory; front matter and task bodies are not read during indexing.
  Escape offers an empty session or cancellation. Invalid task metadata stays
  in the selector with an error. Missing or unreadable directories report the
  failure and offer an empty session or cancellation.
- Repository/machine lists: arrows or Ctrl+N (down)/Ctrl+P (up) to navigate,
  `/` to filter, Enter to choose, Escape to clear the filter or go back.
- Ctrl+C cancels everywhere. Selection performs no launch mutations.

Tasks must be regular files. Reading them runs outside the TUI event loop, so
Escape and Ctrl+C remain responsive while loading.
Task files need YAML front matter with a non-empty, single-line `title`.
`repo` and `skill` are optional. The prompt preserves the complete body after
front matter. When a non-empty `skill` is declared, it must be a valid skill name
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

Task-based Pi sessions use the task title; empty sessions use the agent name and
receive no initial prompt. Agent names are picked randomly from `agent_names`,
excluding names on Local and **every enabled saved Herdr server**, including
servers absent from this inventory. An unreachable server stops launch because
global availability cannot be established. This policy is not a distributed
lock: simultaneous launchers can race; Herdr enforces names on its own server.

Herdsman uses Herdr's source resolver to select an existing non-linked source
workspace, renaming it to `owner/repo`, or creates that parent. This anchors the
repository group using the configured base checkout, not a hard-coded `main`.
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

Finish, model comparisons, plugin integration, and existing
workspace cleanup are intentionally deferred. Existing `start-task` and
`finish-task` commands remain available.