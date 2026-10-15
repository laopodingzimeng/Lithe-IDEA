# Native collaboration workflows v1

A data-only package loaded explicitly by the native macOS Collaboration tool window.
It is separate from language plugins; pluginAPIVersion and marketplace installation do not apply.
Windows has not implemented this consumer. No browser server or Node runtime is needed.

UTF-8 JSON, at most 1 MiB. Required root fields:

| Field | Meaning |
| --- | --- |
| schemaVersion | Exactly 1; future versions are rejected |
| id | Nonempty ASCII letters/digits/dot/hyphen, at most 128 characters |
| version | Nonempty package version displayed in the panel |
| title, requirement | Nonempty display title and requirement |
| steps | 1–100 Core collaboration steps with unique IDs |
| prompts | Object mapping known step IDs to additional task text |

Steps use the `collaboration.md` shape: `id`, `title`, `owner` (`ai`/`human`),
`targets`, `acceptance`, `questions`, and `decisions`. Imported `decisions` must be `[]`;
answers are recorded by the user after import. Targets use normalized workspace-relative
paths and existing Core file/Java method shapes. Host confirmation additionally validates
Core ownership rules. Unknown JSON fields do not grant any capability and are not executed.

The host constructs a new draft ID/version/cursor. The package cannot supply an accepted
plan, source code payload, permission, command or executable UI. Imported snapshots stay
pinned until completion or explicit discard; rereading a file never silently revises active work.
Source files are opened via ordinary native document navigation, not a second editor.

Execution uses the existing tool-free HTTP provider. The model returns a workflow draft, a JSON changes array, or a read-only analysis. It cannot invoke Agent tools, execute shell or write files. Core prepares scoped edits; the native adapter validates paths/contents, preserves encoding and records a recovery intent before compare-and-write. Dirty editor buffers or stale plan versions block commit. Human acceptance remains explicit.

The native Java test action uses the existing test tool window and runner. It is an explicit user action, not a model tool. Analysis is never represented as compilation/test evidence. The ordinary Agent panel remains a separate capability whose tools are not constrained by this plan.

Installed data packages are versioned by (id, version); differing content at the same version is rejected. Older versions remain selectable after active work completes or is discarded. At most 30 packages / 4 MiB are retained in platform preferences. No executable package code or remote marketplace is supported; schemaVersion is the host compatibility gate.

Project state and receipts use platform Application Support, scoped by a SHA-256 of the canonical workspace path. `pending.json` is an atomic recovery intent; `session.json` is written before that intent is cleared. After a crash, the native panel can finalize an exact after-state or roll back exact before/after states. External changes block automatic recovery. Regular undo uses Core method-level inversion and preserves other methods.

Examples: `shared/fixtures/collaboration/spring-order.workflow.json` and `shared/fixtures/collaboration/maintenance-review.workflow.json`.
