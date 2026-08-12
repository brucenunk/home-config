<!-- Managed by brucenunk/home-config. Edit there, not here. -->

# Denote Task Guidance

Read this document when work involves a Denote task identifier or the user asks to create, defer, resolve, or complete a task.

## Task Identity and Resolution

Denote task links use `denote:[identifier]`, for example `denote:20260129T180405`. Treat the identifier as the stable identity and resolve its current path at the point of use:

```bash
emacsclient -e '(denote-get-path-by-id "IDENTIFIER")'
```

The result is the full path or `nil` for an invalid identifier. Task files live under `~/work/tasks/`.

## Default Task System

When a user says “task,” default to the Denote task system. When asked to create or defer one, create the task file directly under `~/work/tasks/` using:

```text
{identifier}=={signature}--{title-slug}.md
```

- **identifier**: `YYYYMMDDTHHMMSS` timestamp, for example `20260304T153250`
- **signature**: `todo` for a new task
- **title-slug**: lowercase with hyphens for spaces

Example: `20260304T153250==todo--add-denote-task-template.md`

## New Task Template

```markdown
---
title:      "task title"
date:       2026-03-04T15:32:50+11:00
tags:       []
identifier: "20260304T153250"
signature:  "todo"
repo:       brucenunk/home-config
skill:      task-workflow-v3
---

## Dependencies

-

## Context

Initial thoughts, background, and links for future pickup.

## Goals

-

## Non-Goals

-

## Constraints

- Durable constraints, locked details, or invariants that should survive session handoff.
```

The template is a floor, not a ceiling. Fill it with concrete handoff context rather than leaving placeholders. Include:

- **Why the task exists now** — its trigger and any parent task/session context that will not be obvious later.
- **Desired outcome** — the concrete change or investigation expected.
- **Current state** — what is known, decided, attempted, or intentionally deferred.
- **Relevant pointers** — repo slug, files, symbols, commands, logs, screenshots, links, or dependencies needed for fast pickup.
- **Boundaries** — explicit non-goals, constraints, and locked details that should not be casually reconsidered.
- **Verification target** — the evidence the next agent should aim to produce.

For a task spawned from another active task, include the parent `denote:` dependency and summarize the relevant findings and decisions in the new note; do not assume the next agent can see the previous chat.

## Fields and Dependencies

- `title` — human-readable title
- `date` — ISO 8601 with timezone offset
- `identifier` — matches the filename identifier
- `signature` — `todo` for new tasks
- `repo` — GitHub slug in `owner/repo` form
- `skill` — normally `task-workflow-v3` for the standard chat-first structured workflow

Use `task-workflow-v3` when the desired workflow is a chat-first scope gate followed by autonomous build, verification, review, and a staged-or-committed handoff. Other workflow-specific note shapes are special cases, not the generic meaning of “task.”

Use `-` under `## Dependencies` when there are none. Otherwise every dependency must use exactly:

```markdown
- [ ] [denote:{task identity}](task title)
```

This format is required so `my/task-finish` can parse and check dependencies off.

## Completing Tasks

Never rename or move task files directly. Complete a task through Emacs:

```bash
emacsclient -e '(my/task-finish "IDENTIFIER")'
```
