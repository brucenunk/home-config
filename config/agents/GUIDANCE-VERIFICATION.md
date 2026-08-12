# Agent Guidance Verification

Read this document when changing `AGENTS.md` routing, context composition, or extraction of conditional guidance. It is not required for typo fixes or inconsequential wording changes.

## Static Checks

1. Inspect the complete applicable `AGENTS.md` hierarchy, not only the edited file.
2. Confirm every extracted document has a contextual route naming both its trigger and why it must be read.
3. Check links, deployment mappings, formatting, and contradictory or duplicated requirements.
4. Compare before/after byte counts for the always-loaded hierarchy. Treat reduction as a useful signal, not a goal that overrides clarity or safety.

## Deployed Routing Probes

After the repository-required apply/deploy step, run fresh Pi probes from representative deployed worktree directories.

- Use ephemeral sessions (`--no-session`) and read-only tools.
- Preserve normal context-file discovery so the probe exercises the deployed hierarchy.
- Capture high-volume or JSON output in a directory created with `mktemp`, outside the worktree.
- Inspect actual tool calls as well as the final answer; an answer that guesses correctly without reading a required reference does not prove routing works.

Include:

1. A **negative probe** representing ordinary work. It should retain always-loaded safety and workflow constraints without reading unrelated conditional references.
2. A **positive probe for each changed route**. Its prompt should naturally trigger the extracted guidance, and the agent must read the intended document and preserve representative locked details.

Use questions or hypothetical scenarios that cannot mutate repositories or external systems. Do not ask the probe agents to perform the operation being described.

## Evidence Boundaries

- Static inspection and source-tree checks are isolated worktree verification.
- Apply plus inspection of deployed files is downstream deployed-state verification.
- A fresh Pi process that reads those deployed context files is runtime-pickup evidence for new sessions only; it says nothing about already-running sessions.

Summarize which probes ran, which files they read, representative constraints retained, and any routing failures. Do not paste full session transcripts into the task note or handoff.
