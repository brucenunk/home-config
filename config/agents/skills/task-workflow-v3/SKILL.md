---
name: task-workflow-v3
description: "Chat-first development task workflow. Align on scope in chat, then autonomously build, verify, review, and hand staged or committed changes back for user review. Load when task has skill: task-workflow-v3. Do not execute implementation work until this skill is loaded."
---

# Task Workflow V3

Chat-first delivery with one explicit approval gate before implementation and a review-ready handoff at the end.

The task note is a bootstrap artifact, not the main collaboration surface. Use chat for scope alignment and the worktree, verification evidence, and review output as implementation artifacts. Do not create or maintain a formal plan file for this workflow.

## Invariants

- **Branch management:** the task system has already selected the correct local branch (`jamesl-{task-id}`). Never create, rename, or switch local branches.
- **Pushing:** pushing is not part of the default handoff. Push only when explicitly requested or required by repo workflow, using the applicable finish guidance.
- **Waiting:** waiting means a blocking message has been sent and the agent is paused for user input. Do not use task waiting-marker commands or backend waiting hooks.
- **Task note:** read it as durable bootstrap context. Do not turn it into a running work log or add phase markers, status history, or dense verification transcripts.
- Edit the task note only when explicitly requested, dependencies need maintenance, a durable task-level constraint must survive later sessions, or repo guidance requires it.

## On Entry

1. Read the task note and extract its identifier and `repo` slug when present.
2. Read the applicable `AGENTS.md` hierarchy and load this skill before implementation.
3. Recenter from current chat, the task note, `git status --short`, and relevant diffs or recent commits.
4. If `## Dependencies` contains unchecked `denote:` targets that still resolve, stop and report the unresolved prerequisites. Mention and ignore unchecked targets that no longer resolve.
5. If prior approved scope is unclear, reconstruct the likely contract from the note and worktree, then ask the smallest necessary clarification.

## Phase 1 — Scope Conversation

Align in chat before building. Reduce material unknowns through focused questions or limited read-only investigation when the repository can answer them cheaply. Unknowns that can only be resolved during implementation or verification need not block approval when they are explicit, bounded, and safe to carry.

Work toward a shared contract covering:

- user-visible outcome
- likely file or component impact
- boundaries and non-goals
- risks and residual unknowns
- expected verification evidence
- locked API or behavior details

Treat user-specified names, flags, signatures, output shapes, invariants, and scope boundaries as **Locked API / Details**. If implementation later requires violating one, stop and rescope.

Before implementation, present a concise scope packet with:

- **Outcome**
- **Likely file impact**
- **Non-goals / boundaries**
- **Locked API / details** (omit only when none)
- **Risks / unknowns**
- **Verification plan**

For each material residual unknown, explain why it remains, how it will be handled, and why carrying it is acceptable. Resolve cheaply answerable unknowns before asking exactly: `Approve this scope?`

Do not implement until the user explicitly approves. After a long or exploratory conversation, first restate the approved contract in 5–7 bullets.

## Phase 2 — Build

1. Implement autonomously against the approved contract and codebase reality.
2. Do not create a formal scratch plan merely to track progress.
3. Stop and rescope before materially diverging. Material divergence includes:
   - entering an undisclosed subsystem or directory
   - creating or deleting files outside expected scope
   - invalidating a boundary or non-goal
   - changing a locked detail
   - materially increasing implementation size, complexity, operational machinery, or subsystem impact beyond the simplest design that satisfies the approved contract
   - turning a focused change into a generalized mechanism, architectural replacement, or new subsystem
   - requiring a meaningfully different verification strategy
4. Commit only when a checkpoint is genuinely useful or requested; do not create commits mechanically.

## Phase 3 — Verification

1. Assume bugs exist and execute the approved evidence plan, noting non-material adjustments in chat.
2. Prefer the furthest practical proof point and keep isolated worktree, downstream deployed/applied, and runtime-pickup evidence distinct.
3. Follow repo-specific deploy/apply and runtime-pickup guidance at the correct stage.
4. Present manual checks to the user; do not mark them passed yourself.
5. Summarize meaningful evidence in chat rather than copying a dense transcript into the task note.
6. Rerun only the proof points a change can affect. Substantive behavior changes require affected verification; evidence-only corrections require accuracy checks, not automatic redeployment, runtime-pickup, or rollback repetition.

## Phase 4 — Review

Review is normal unless the change is mechanically tiny, its blast radius is narrow and obvious, and verification decisively covers the actual risk.

Load and follow the reusable `review` skill. It is the canonical owner of review safety, diff capture, basis selection, Pi launch mechanics, and output shape. Repo- or task-specific guidance may add constraints but must not weaken that contract.

Review findings are evidence about risk, not amendments to the approved contract or permission to override locked details and non-goals. Before implementing a finding, compare the proposed fix—and the resulting implementation as a whole—with the simplest design that satisfies the approved outcome and its correctness, security, and operational requirements. Implement the fix autonomously only when it is proportionate and remains within the approved implementation direction. Stop and rescope in chat, leaving the finding explicitly unresolved, when the proposed fix would materially expand size, complexity, operational machinery, subsystem impact, or architecture; undermine a boundary or non-goal; or require a different implementation direction.

After review:

- summarize actionable findings tersely for the implementing agent
- treat an unresolved finding as actionable unless it is fixed or the user or owning task contract explicitly accepts or assigns it elsewhere; silence is not a disposition
- do not reopen an explicitly dispositioned finding unless a new variant or evidence materially changes its risk; state that changed basis when it does
- after the convergence check above, fix clearly required in-scope correctness, security, and regression findings autonomously, then rerun affected verification
- normally rerun review after a material fix; further full reviews require a material source or risk change, a new actionable finding, or a concrete regression reason
- if review is skipped or cannot run, state the reason exactly rather than implying success

Repeated material findings can show that the implementation direction is unstable rather than that it needs another layer of machinery. If fixes repeatedly introduce new actionable edge cases or require progressively broader defenses, stop the automatic fix-and-rereview loop. Re-evaluate the assumptions and whole design against the approved contract; prefer removing or rolling back speculative complexity and returning to a simpler in-scope approach. If no such approach resolves the findings, ask for scope alignment. Do not suppress or silently accept correctness or security findings merely to converge.

Converge by proceeding directly to Phase 5 handoff—not task finish or close—when no actionable findings remain, affected verification passes, and the required evidence and explicit residual limitations are stable. Use targeted inspection for evidence-only edits instead of restarting the full review and deployment cycle. Record evidence against a stable implementation identity such as its commit, tree, artifact, or generation, and identify later evidence-only commits separately; do not imply that an evidence-only commit was deployed.

## Phase 5 — Handoff

The endpoint is user-review-ready handoff, not task completion: do not describe the task as complete or closed, merge, push, finish it, or continue iterating without a later explicit request.

1. Stage the intended changes by default.
2. Mention any useful checkpoint commit; otherwise prefer staged changes over an automatic commit.
3. Provide a concise handoff covering:
   - what changed
   - preserved boundaries or non-goals
   - strongest verification evidence
   - review outcome
   - whether changes are staged or committed
   - remaining user decisions or manual checks
4. Invite user review before yielding.

## Post-review commit

The default handoff remains staged and uncommitted. When the user explicitly approves preparing it for delivery:

1. Recheck the staged changes and identify any unstaged or untracked files that will remain outside the commit.
2. Choose a concise commit message, confirm the staged scope has not changed, and commit it using the repository's normal commit workflow without requesting separate message approval.
3. If hooks fail or materially change the reviewed result, stop and report that before any push or merge.

If the reviewed result is already committed, do not create an empty commit. Commit approval does not authorize a push, merge, PR creation, or other finish mutation. Once committed, load the applicable finish guidance.

Unless explicitly requested, do not maintain phase state in the note, write PR or Jira text, merge, raise a PR, run `my/task-finish`, or close the worktree. Treat later landing or finish requests as follow-up work and load the relevant workflow guidance then. In a repository whose applicable policy declares `finish-mode: pull-request`, load the `pull-request` skill when the user asks to prepare or deliver the PR.
