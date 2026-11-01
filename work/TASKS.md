<!-- Managed by brucenunk/home-config. Edit there, not here. -->

# Follow-up Notes and Agent Launches

Start most work directly with Emacs's `my/agent-session-start-new-worktree` and compose the brief in agent-shell, where file completion is project-relative. Use `my/agent-session-start-in-directory` for an existing directory. Neither launch chooses a workflow or sends an initial prompt.

Task notes are optional durable context, useful for parking a follow-up without distracting from the current conversation. They are ordinary Denote Org files under `~/work/docs/tasks/`, optionally grouped into subdirectories. There is no custom task capture command, Denote template, task status, dependency enforcement, or agent lifecycle.

## Creating a useful follow-up

Create a note when the user requests one or repository guidance requires it, not as a prerequisite for implementation or an automatic response to every discovery. Otherwise, summarize follow-up suggestions in chat.

Use Denote's naming convention, `{identifier}--{title-slug}.org`, with a unique `YYYYMMDDTHHMMSS` identifier and lowercase hyphenated title. A minimal example is:

```org
#+title: Investigate the follow-up
#+date: [2026-11-01 Sun 15:24]
#+filetags:
#+identifier: 20261101T152443
#+repo: owner/repository

Why this deserves attention, what we already learned, and what remains undecided.
```

Capture the minimum context needed to resume without repeating investigation: the desired outcome, relevant findings/files, genuine constraints, and unresolved choices. Add headings or verification suggestions only when useful; do not leave template placeholders, prescribe phases, or turn suggestions into approved requirements. For work spawned from another conversation, summarize the source context; a link alone may be inaccessible to the next agent.

No skill is selected by default. Request `task-workflow` in chat when ready to delegate implementation, verification, independent review, and a staged handoff. A well-understood brief may explicitly select it or another skill such as `bump-nix` from the outset.

## Optional launch hints

Keep metadata in a contiguous opening Org keyword header followed by a blank line. Keyword names are case-insensitive; supplied values must be non-empty literal single-line strings, without YAML quoting. Duplicate title/launch fields are rejected; body keywords do not supply launch metadata.

- `repo`: catalogue repository name; a valid hint skips repository selection.
- `machine`: a catalogue key displayed as an annotation, not an automatic machine selection.
- `model` and `thinking`: independent optional overrides applied before submission. Omit them to use Pi's configured defaults. Unsupported overrides withhold automatic submission.
- `skill`: an explicitly chosen skill name; appends a skill-loading instruction. Omit it for an ordinary exploratory conversation.

Do not invent launch values or copy example values blindly. Use the generated catalogue and intended repository when hints are useful. Model references preserve additional slashes after the provider. Legacy `base-ref` metadata is ignored; the launcher confirms the base ref.

## Human-operated launches

- `my/agent-session-start-new-worktree`: select a repository and eligible machine, confirm the base ref, and start a new ad hoc conversation in a sibling worktree.
- `my/agent-session-start-in-directory`: select a machine and directory, then start a new conversation in that exact directory without creating a worktree.
- `my/agent-session-start-from-file`: select a saved Denote Org follow-up under the task root, including subdirectories. Create a new worktree and send the complete saved snapshot plus any explicitly selected skill instruction. The optional Lisp FILE argument skips completion, not validation.

All choices precede Git mutation or startup. Multiple eligible machines require explicit selection without a default; a sole machine is automatic. Worktree base refs are always confirmed. Commands do not manage other agents, task statuses, delivery, or cleanup. Worktrees/branches are retained after failures; nothing is automatically removed or resent. Transcripts live outside worktrees under `~/work/agent-shell/transcripts/` on the Emacs host.

Launchers use the trusted generated `emacs/agent-catalogue.el` loaded at startup. After authorized inventory deployment, explicitly run `my/agent-catalogue-reload` or restart Emacs. Missing inventory stops launch, not ordinary note browsing.

## Agent context and existing files

A launcher-supplied snapshot is sufficient bootstrap context. Its provenance path and Denote links do not imply that the original note is accessible on the agent host. Do not hunt for that file or resolve its identifiers as a bootstrap step. If a requested edit needs an inaccessible original, ask the local owner rather than editing a substitute.

Use ordinary Denote/Dired for browsing and file operations. Existing notes, including signed filenames, Markdown documents, legacy skill/session metadata, and dependency text, remain untouched. File-based launching supports Org only; Markdown remains available through ordinary Denote browsing and links. File operations do not stop sessions, deliver changes, or delete worktrees/branches. Follow repository delivery guidance separately.
