# Pi worker protocol v1

The native host owns documents, permissions, process lifetime, credentials and
durable collaboration evidence. The worker reuses Pi AgentSession for model
streaming and its tool loop. Each worker has one immutable model/role binding;
development and presentation use independent workers. This protocol does not
replace the scoped Core preparation in [collaboration.md](collaboration.md).

## Transport and lifecycle

UTF-8 JSONL over separate stdin/stdout. Split only LF, never Unicode line
separators. Maximum line 4 MiB, pending output 8 MiB. stderr is diagnostic only;
host output buffers are bounded independently. Frames have `type`; host commands
have unique `requestId`. Worker responses include `protocolVersion: 1` and a
monotonic `sequence`. A worker cannot reuse a `runId`. The host binds every frame
to the originating process, workspace, plan version and document baseline.

| Command | Required payload | Response |
| --- | --- | --- |
| initialize | protocolVersion, configuration | ready (role, modelId, tools, runtimeVersion, sdkVersion) |
| prompt | runId, text | accepted, then event/tool_request, then run_finished |
| tool_result | runId, toolCallId, ok; result object or code | tool_ack (accepted false for stale calls) |
| cancel | runId | cancelled after pending tools and SDK work drain |
| shutdown | none | closed, then process exit |

The host waits for ready before prompting. Only one prompt may be active in a
worker; parallel tasks have separate workers. No auto-resume queue is exposed.
Cancellation invalidates host grants before sending cancel, then the worker
rejects pending tools, clears Pi's queue and aborts. Late results are rejected.
Host process-tree termination is the final bounded recovery path.

Configuration has `role` (`development`, `planning`, `review`, `presentation`,
`completion`), `systemPrompt`, `model` and optional `runTimeoutMs` (1–3600 seconds,
default 600). This is an explicit collaboration budget, not a change to ACP
conversation timeouts. Model fields are `api` (`openai-completions`,
`openai-responses`, `anthropic-messages`), `id`, `baseUrl`, `apiKey`, optional
literal `headers`, `allowInsecureHTTP`, `contextWindow`, `maxTokens`. Authentication
enters Pi's public in-memory credential store, never a config command expression.
No key is passed in argv/environment or persisted in a transcript. HTTPS is the
default; plaintext HTTP requires explicit user configuration. Provider discovery
and capability diagnostics are host operations, not worker initialization scans.

SDK built-in tools, extensions, MCP, skills, prompt templates and project/global
configuration discovery are disabled. The worker's cwd is an isolated writable
state directory, never a source checkout. In v1 sessions are memory-only; the
host's receipts/events provide recovery and replay, not a persisted Pi transcript.

## Tools and facts

`workspace_list`, `workspace_read`, `workspace_search` use bounded host inventories
and exact targets. Development additionally receives `workspace_apply` and
`workspace_verify`. Planning/review only receive the three read tools.
Presentation/completion have no tools: their supplied snapshots remain immutable.
The native host rechecks this allowlist; worker validation is defense in depth.

`tool_request` contains `runId`, `toolCallId`, `name`, `arguments`. Schemas are in
`integrations/pi-bridge/src/host-tools.mjs`. All paths are workspace-relative;
the host rejects traversal, symlinks, sensitive files and unconfirmed writes at
the actual I/O boundary. Search is literal. File/method edits use Core's
`target`, `expectedText`, `replacement` shapes and explicit null for absence.
Each write returns a durable receipt after guarded application, not a model's
claim. Verification takes an authorized host `actionId`, never shell commands.
No general shell, package installer or arbitrary process tool is exposed.

Host responses contain a bounded `result` object or stable error `code`.
Tool timeout is 60 seconds (180 seconds for isolated verification) and the call budget is 200 per run. Host actions that
outlive this response budget must use host job identities and explicit status;
the worker must not re-run an unknown outcome as a retry.

Events use `kind`: `text_delta`, `usage` (token counters only), `tool_started`,
`tool_finished`, `settled`. Private reasoning and cumulative SDK partial messages
are not forwarded. Unknown provider prices remain unknown in the host; SDK cost
placeholder zeros are not billing evidence. `run_finished.outcome` is `completed`,
`failed`, `cancelled` or `timeout`. Completed requires Pi's `agent_settled`, not
`agent_end`; it still does not imply tests passed or user acceptance.

Errors have stable codes without raw provider bodies or credentials. Transport
overflow fails the worker rather than discarding authoritative write receipts.
The host replays actual journaled snapshots even if the presentation worker fails.

## Isolation and verification

macOS launches under `platform/macos.sb`, supplying canonical state/Node paths,
and Node's permission flags. The OS profile denies writes outside state even to
descendants. Node additionally limits reads to runtime/state, denies child
processes/native addons, and the host supplies a minimal environment. The system
sandbox executable is deprecated; an unavailable or failing launch must fail
closed. Node permissions alone are not an OS sandbox. Windows requires its own
verified restricted host adapter; a Job Object only provides process lifetime.

`node scripts/test-pi-bridge.mjs` exercises the real pinned SDK against local
deterministic provider fixtures, tool roundtrips, cancellation, three protocols,
error redaction and an isolated worker. The macOS integration test independently
proves descendant write denial without Node permission flags. This is process
boundary evidence, not yet full desktop workflow or Windows verification.

`run_finished.text` contains the last complete assistant message (bounded by the
existing output limit). Earlier exploration commentary remains `text_delta`
events but is not part of the final JSON plan. Older workers may omit `text`;
the host's compatibility fallback is the collected stream.
