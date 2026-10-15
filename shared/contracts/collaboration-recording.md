# Collaboration facts and playback v1

The host records critical facts in the same workspace `session.json` as the plan
and receipts. A fact contains `id`, opaque `workspaceID`, `planVersion`, `runID`,
`taskID`, monotonic `sourceSequence`, nullable `recordedAt`, `kind`, `title`, optional
`summary`, `receiptID` and `verificationID`. Imported legacy receipts have unknown
time (`null`), never an invented timestamp. Model tokens are temporary UI output;
model narration is not a fact. Examples: [pi-events-v1.json](../fixtures/collaboration/pi-events-v1.json).

Every successful tool write has its own host `operationId`. That optional field
is journal metadata and is removed before calling the strict Core v1 reverse
schema. Pending tool intents have `continuesStep: true`: committing a tool does
not complete the current step. Cancellation preserves the recorded partial writes.

Undo moves the original receipt into `archivedReceipts` and adds the inverse
receipt under a distinct deterministic history key. Reconciliation deduplicates
facts by receipt key; replay keeps both original and inverse snapshots. Read-only
history resolves receipt keys only and never substitutes current file contents.
The total authoritative session budget remains 16 MiB, with at most 2,000 facts;
capacity failures are explicit and prevent subsequent unsafe writes. Clearing the
current plan is an explicit user action, not automatic history eviction.

All facts immediately have host-generated basic chapters. The independent Pi
presentation session receives bounded source samples, source event IDs and a
snapshot ID. Only validated `CollaborationNarration` JSON can augment a chapter:
the source ID set and snapshot ID must match the requested chapter; action paths
must occur in that snapshot; one-based highlight ranges must exist. Allowed
actions are display suggestions (`show_file`, `show_diff`, `highlight_lines`).
No narration command mutates source, approves a plan or determines test status.
Text is visibly labelled AI narration and actual state stays host-owned.

At most one automatic narration runs at a time, eight automatic requests and
eight queued chapters per configuration epoch. Remaining chapters retain basic
facts and can be explained explicitly. Narration has a 60-second request budget.
User questions run on the presentation role, interrupt automatic narration and
never wait for development to finish. Provider/key/model bindings are independently
resolved per role and captured when each request starts. Shared provider accounts
may still share upstream rate limits.

Live observation, selected historical chapter, prepared narration and acknowledged
viewing are distinct. Selecting/preparing a chapter does not mark it viewed; the
history view acknowledges rendering the selected chapter. Paused/replay selection
stays fixed as new development facts arrive. Late model output augments its own
chapter without moving the cursor. Human takeover pauses automatic navigation.

`playback.json` stores only narration and viewing state, separately from the
authoritative journal. Saves are serialized with a monotonic revision. Damage or
storage failure in this index does not block development; basic chapters rebuild
from facts/receipts. The index is capped at 8 MiB and lives alongside `session.json`
in platform Application Support, never inside the installed package or shared cache.

Java verification reuses the host's test subsystem in a bounded temporary Maven
workspace snapshot. `executionID`, `actionID`, `sourceRevision`, `outcome`, optional
`exitCode` and bounded output are host evidence. `sourceRevision` hashes the exact
copied source set; the result does not assert freshness for subsequent live edits.
The source copy, private Maven repository and all descendant writes stay inside
the per-execution cache directory and are removed after process cleanup. The
worker can request `java-tests` only when the host has authorized automatic checks.
