---
name: task-workflow
description: "Explicitly delegated delivery: implement the agreed direction, verify, independently review, and hand back staged changes. Use only when the user requests this skill or a supplied brief explicitly selects it, not merely because a conversation involves coding."
---

# Task Workflow

Take agreed work through implementation, verification, independent review, and a user-review-ready handoff. This skill can be invoked at the start or midway through a conversation. It does not require a task note or a new session.

## Establish the brief

- Use the current conversation as the primary brief, plus any supplied note, repository instructions, and existing worktree changes. A launcher-supplied snapshot is sufficient; do not hunt for its original file or resolve its links as a bootstrap step.
- Briefly state the outcome, important boundaries, and intended verification. Preserve user-specified APIs, names, behavior, and other locked details.
- Clear authorization to proceed is sufficient: do not demand a scope packet, an exact approval phrase, or another approval after the user has already agreed. Ask only about material ambiguity or missing authorization. For substantial or risky work, make the consequential choices and boundaries explicit before implementing.
- Follow the human-selected worktree and applicable repository safety/delivery rules. Do not create a plan file, task note, or workflow-state log merely to run this skill.

## Deliver autonomously

- Prefer the smallest maintainable solution. Once authorized, continue through implementation, affected verification, and review without waiting for prompts between steps.
- Stop for a material decision or blocker: changing an agreed API or boundary, entering an undisclosed subsystem, taking a different implementation direction, or substantially increasing complexity, maintenance burden, operational machinery, or verification requirements. Explain the trade-off before building the larger solution.
- Keep discoveries and follow-up suggestions in chat. Create or update durable notes only when requested or required by repository guidance; capture useful context, not a running transcript.
- A code change does not require a documentation change. Update docs only for changed operational instructions, safety constraints or important non-obvious rationale; prefer rationale beside the code. Do not add implementation narratives, architecture/helper inventories, coverage lists or verification transcripts. Delete obsolete documentation rather than preserving migration history.

## Verify and review

- Assume bugs exist. Exercise the actual behavioral risks, not just whether the code builds. Prefer the furthest practical authorized proof point; distinguish isolated tests, downstream deployment, and live runtime pickup. Never mark user/manual checks passed yourself.
- Load and follow the review skill for independent read-only diff review. Review is expected unless the change is mechanically tiny, has an obvious narrow blast radius, and verification decisively covers its risk. State explicitly when review is skipped or cannot run, and why.
- Fix clearly required in-scope correctness, security, and regression findings, then rerun affected verification. Findings do not authorize scope expansion: pause when a fix requires a materially different or more complex approach.
- Normally rerun review after a material fix. Do not restart full review/build/deployment cycles for evidence-only corrections. Repeated findings or progressively broader defenses are a signal to reconsider the whole approach and simplify, not to add machinery indefinitely.
- Do not silently accept unresolved findings. Fix them, obtain explicit user disposition, or report them as unresolved and pause. When affected checks pass, no actionable findings remain, and evidence/limitations are stable, proceed to handoff.

## Handoff

- Stage intended changes by default; do not automatically commit. Use checkpoint commits only when genuinely useful or requested.
- Summarize what changed, preserved boundaries, strongest verification evidence and its implementation identity, review outcome, staged/committed state, and residual limitations or manual checks.
- Invite user review and yield. This is not permission to merge, push, activate, close the task, or clean up the worktree. Do not continue iterating without a later request.

## After user review

When the user explicitly approves a commit, recheck the staged scope and identify anything left outside it, choose a concise message, and commit through the normal repository workflow. Do not create an empty commit if already committed. If hooks fail or materially change the reviewed result, stop and report it. Commit approval alone does not authorize merge, push, PR delivery, or activation; follow repository finish guidance only when that later action is authorized.
