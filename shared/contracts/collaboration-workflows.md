# Native collaboration workflows v1 / v2

A data-only package loaded explicitly by the native macOS Collaboration tool window.
It is separate from language plugins; pluginAPIVersion and marketplace installation do not apply.
Windows has not implemented this consumer. Workflows are data only; execution uses the separately packaged Pi SDK worker.

UTF-8 JSON, at most 1 MiB. Required root fields:

| Field | Meaning |
| --- | --- |
| schemaVersion | 1 (serial legacy) or 2 (explicit dependency graph); other versions are rejected |
| id | Nonempty ASCII letters/digits/dot/hyphen, at most 128 characters |
| version | Nonempty package version displayed in the panel |
| title, requirement | Nonempty display title and requirement |
| steps | 1–100 Core collaboration steps with unique IDs |
| prompts | Object mapping known step IDs to additional task text |
| dependsOn (v2 required) | Map from every original task ID to its unique prerequisite IDs, including `[]` for roots |
| independentFiles (v1 optional) | Map from an AI step ID to its complete set of 2–8 distinct target file paths, explicitly confirmed as independent |

Steps use the `collaboration.md` shape: `id`, `title`, `owner` (`ai`/`human`),
`targets`, `acceptance`, `questions`, and `decisions`. Imported `decisions` must be `[]`;
answers are recorded by the user after import. Targets use normalized workspace-relative
paths and existing Core file/Java method shapes. Host confirmation additionally validates
Core ownership rules. Unknown JSON fields do not grant any capability and are not executed.

The host constructs a new draft ID/version/cursor. The package cannot supply an accepted
plan, source code payload, permission, command or executable UI. Imported snapshots stay
pinned until completion or explicit discard; rereading a file never silently revises active work.
Source files are opened via ordinary native document navigation, not a second editor.

Version 2 uses `collaboration.schedule` to validate the full dependency graph and
compile original tasks into serial human-accepted waves. Unknown prerequisites,
missing declarations, self-dependencies, cycles and human/AI scope overlap fail
before confirmation. Stable input order breaks ties. Up to eight ready AI tasks
with distinct file paths share a wave; tasks targeting the same file serialize,
even when their method scopes differ. A human task always occupies its own wave.
The wave's acceptance and questions retain original task titles. A dependency is
satisfied only when the previous wave has been accepted by the human. This
conservative barrier may delay a newly ready dependent until unrelated tasks in
that wave finish. Original tasks/prompts remain available through the returned
`groups` mapping; compiled waves do not expand authority.

Version 1 retains serial steps and its optional `independentFiles`: the complete
set of 2–8 distinct target paths for one AI step. Pi sessions use the same bounded
scheduler as v2. The host permits 1–8 concurrent sessions (default three), pins
one provider configuration for the wave, and restricts every tool callback to
that session's targets. All workspace tool callbacks share a lane through editor
holds, commit and durable receipt reconciliation. Cancellation invalidates all
sessions and drains them before another execution. A failed sibling stops the
wave but retains each already committed receipt; there is no all-or-nothing
claim for independent Pi writes. Legacy tool-free HTTP fixtures keep their old
single-batch semantics.

Planning uses Pi's read-only role and the existing visible workspace inventory
(at most 500 paths / 20,000 characters). The host read tools bound content and
exclude hidden/sensitive paths. Open editor context is explicitly supplied as
user data; the model explores existing source before returning a v2 draft.
Turning off source sharing supplies an empty catalog and no editor code. Every
write still requires confirmation of the resulting plan. The final settled
assistant message supplies the JSON draft; earlier streamed exploration text is
not concatenated into it.

Development previews consume actual Pi events and host receipts. Draft text is
never filesystem evidence. A host receipt, rather than a model's success claim,
establishes an edit. Completion and human acceptance remain separate.
Explicit human start/open actions may create an absent, confirmed human whole-file
target as an empty file through guarded native document writes. Existing code is
preserved and no AI receipt is invented. Parent directories must already exist.
Satellite previews are nonmodal and close with their owning workspace/execution.
Follow is suspended when the user edits or pins a task. Starting a step and
committing a generated file request ordinary editor navigation; missing planned
files remain previews until creation. Takeover invalidates the generation and
drains its children before another request can start. Restored sessions stay paused.

Production execution uses the Pi development or read-only review role; the
original tool-free HTTP generator remains for legacy compatibility. Core prepares
scoped edits, and native guarded writes preserve encoding and record a recovery
intent before compare-and-write. Dirty buffers and stale plan versions block
commit. Single-task execution may invoke the explicitly authorized isolated
`java-tests` action. Parallel sessions cannot launch competing validation jobs;
the user can run the normal test action after the wave settles. Test output is
separate evidence tied to the copied source revision, never inferred from analysis.
The ordinary Agent panel remains a separate capability whose tools are not
constrained by this plan.

Installed data packages are versioned by (id, version); differing content at the same version is rejected. Older versions remain selectable after active work completes or is discarded. At most 30 packages / 4 MiB are retained in platform preferences. No executable package code or remote marketplace is supported; schemaVersion is the host compatibility gate.

Project state and receipts use platform Application Support, scoped by a SHA-256 of the canonical workspace path. `pending.json` is an atomic recovery intent; `session.json` is written before that intent is cleared. After a crash, the native panel can finalize an exact after-state or roll back exact before/after states. External changes block automatic recovery. Regular undo uses Core method-level inversion and preserves other methods.

Examples: `shared/fixtures/collaboration/spring-order.workflow.json` and `shared/fixtures/collaboration/maintenance-review.workflow.json`.

Dependency fixture: `shared/fixtures/collaboration/schedule-v2.json`.
