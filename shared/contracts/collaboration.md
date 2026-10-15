# Human/AI collaboration Core contract

These commands are deterministic preparations, not filesystem capabilities. They
use the existing Core JSON envelope and never start an Agent, run commands, save
documents or persist state. Both platforms must treat plans and receipts as
**host-owned data**. Passing model-supplied plans directly into these commands
does not enforce authorization.

## Commands

| Command | Input | Output |
| --- | --- | --- |
| `collaboration.transition` | `plan`, `expectedVersion`, `action` | Updated plan with incremented `version` |
| `collaboration.prepare` | Trusted `plan`, `expectedVersion`, `stepId`, current `files`, proposed `changes` | Prepared before/after snapshots and reversible changes |
| `collaboration.reverse` | Trusted applied `receipt`, current `files` | Prepared inverse with fresh before/after snapshots |

The executable example is [collaboration-v1.json](../fixtures/agent/collaboration-v1.json).
Malformed requests use `invalid_request`; stale state, changed target content,
ambiguous symbols and unauthorized actions use `permission_denied`. No failure
returns a partial change set. Cancellation uses the existing Core envelope.

## Plans and handoffs

A plan contains `id`, `version`, `requirement`, ordered `steps`, `currentStep`,
`phase` and `paused`. Each step has a unique `id`, `title`, `owner` (`human` or
`ai`), `targets`, nonempty `acceptance`, pending `questions` and recorded
`decisions` (defaults to an empty list). The order is the serial dependency order.
The cursor points to the current step, including the final step after completion.

| Action kind | Required phase | Result |
| --- | --- | --- |
| `confirm` | `draft` | `ready` |
| `start` | `ready`, questions resolved | `aiWorking` or `humanWorking` |
| `handoff` | `humanWorking` | `checking` (read-only analysis) |
| `workFinished` | `aiWorking` or `checking` | `review` |
| `accept` | `review` | Next step `ready`, or `complete` |
| `requestChanges` | `review` | Human step `humanWorking`, AI step `ready` |
| `resolveQuestions` | `ready` | Requires one nonempty `answers` entry per question; retains paired question/answer in `decisions` |
| `revise` | `draft`, `ready`, `review` | Replaces current and later steps using `steps` and `requirement`; retains earlier steps and requires confirmation again |
| `pause` | Any non-complete phase | Sets `paused`, invalidates in-flight work |
| `resume` | Paused | No automatic execution; interrupted AI work becomes `ready`, interrupted checks become `humanWorking` |

Every successful action increments the state version. Hosts must perform a
compare-and-swap against their stored version before adopting the result.
`workFinished` is a host notification after actual completion; `accept`, plan
confirmation, revisions, answers and handoff are human actions. Neither model
text nor an ACP plan/status update can perform them. A resumed interrupted step
must have its recorded partial writes reconciled before another execution.

One active plan per workspace, persisted approvals, test-result freshness and
execution cancellation belong to the host coordinator, not this stateless API.

## Targets and changes

Paths use normalized workspace-relative `/` separators. Absolute paths, traversal,
backslashes, colons, NULs, empty components and `.git` components are rejected.
Native hosts must additionally check canonical path containment, symlinks,
case aliases, native identity and read-only status at the actual write boundary.

- `{"kind":"file","path":"src/Dto.java"}` grants a whole file.
- `{"kind":"javaMethod","path":"src/Order.java","typeName":"Order","signature":"String map(int n)"}`
  grants only an existing method body, including braces. `typeName` is the lexical
  enclosing type path (`Outer.Inner`); `signature` is the exact declaration
  preceding the body with outer whitespace removed. Overloads must be explicit.

Java scopes use the repository's pinned Tree-sitter Java grammar, exclusively for
source-span verification. They do not establish Java symbol resolution, type
correctness, build state or runtime semantics. Those remain with JDT/project
tooling. Syntax errors, changed declarations, anonymous classes, ambiguous targets,
overlapping method edits and replacements escaping a method body are rejected.
Method scope does not permit imports, signatures or class-level changes. Those
need a newly confirmed scope; do not silently expand to a whole file. Whole-file
AI grants cannot override human-owned methods declared anywhere in the plan.

A change contains `target`, `expectedText` and `replacement`. Method text is the
complete body. File text is the entire file. For files, null means absence and
an empty string means an existing empty file. Method deletion is not supported.
Inputs are capped at 100 changes/files, 2 MiB per text and 16 MiB aggregate source
and change text. Results are sorted deterministically by path and target.

The prepared receipt includes `planId`, `planVersion`, `stepId`, `before`, `after`
and `changes`. The host applies it through document-owned compare-and-write,
recording a durable intent before the first write and recording completion only
after all writes succeed. A pure all-or-nothing preparation is **not** a
multi-file filesystem transaction. The host must implement recovery, including
partial failure and crash handling, before exposing an executable product action.

Reverse uses only host-recorded applied receipts. Method reversal requires the
same declaration and exact AI-produced body, preserving subsequent edits to other
methods. Changes inside the AI body conflict, without fuzzy substring matching.
Whole-file reversals require the complete AI-produced content to remain unchanged;
an AI-created file can only be removed while it still matches exactly. Reversal
itself returns a preparation and does not write or delete anything.

## Runtime boundary

`collaboration.previewSuggestion` accepts the same payload as `prepare`, but
requires the current, unpaused `humanWorking` step and exactly one existing human
target. Deletion, a stale version, changed source, and method-body escape are
rejected. It returns the same before/after projection without changing the plan
or granting AI write permission. The projection is not an applied receipt.

The completion role has no tools. The desktop shows the proposed change, and an
explicit acceptance rechecks workspace, plan, document identity, location and
edit revision. The live editor applies it as one undo group and acknowledges its
native mirror; it stays unsaved until the human saves. Reject, cancel or stale
results never write. The host must not route a suggestion through the AI journal
or count it as an AI-produced file write. See `human-suggestion-v1.json` in the
collaboration fixtures.

A successful preparation is not proof that an arbitrary ACP Agent cannot bypass
it through shell commands. Executable collaboration must use a provider that
cannot directly write the source workspace, or a verified isolation boundary
covering the process tree, helpers and build/test commands. An isolated checkout
alone is insufficient if the process can still write the original absolute path.
Native documents, transport results and receipts must be tied to the same
workspace, plan version, operation and document revision before applying results.

No runtime storage is introduced by this Core contract. Future native storage
must be workspace-scoped in platform Application Support/cache locations and must
not modify installed bundles or share mutable state between Git worktrees.

## `collaboration.schedule`

Input `{steps, dependsOn}` contains original Core steps and a complete map of
task IDs to direct prerequisites. The command validates all original ownership
rules, unique prerequisite IDs, graph completeness and acyclicity. It returns
`{steps, groups}`: deterministic serial wave steps and a wave-ID to original-task-ID
mapping. It performs no I/O and does not mutate an existing plan. See
[workflow v2](collaboration-workflows.md) for wave barriers and host concurrency.
