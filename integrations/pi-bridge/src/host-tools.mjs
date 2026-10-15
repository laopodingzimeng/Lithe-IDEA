import { Type } from 'typebox';
import { BridgeError, LIMITS, object, relativePath, requireValue } from './protocol.mjs';

const Path = Type.String({ minLength: 1, maxLength: 4096 });
const Text = Type.String({ maxLength: LIMITS.textChars });
const Target = Type.Union([
  Type.Object({ kind: Type.Literal('file'), path: Path }, { additionalProperties: false }),
  Type.Object({ kind: Type.Literal('javaMethod'), path: Path, typeName: Text, signature: Text }, { additionalProperties: false }),
]);

const definitions = [
  {
    name: 'workspace_list', label: '列出项目文件',
    description: 'List visible project files through the IDE. Results are bounded; use the returned cursor for more. Paths are workspace-relative.',
    parameters: Type.Object({ directory: Type.Optional(Path), cursor: Type.Optional(Type.String({ maxLength: 256 })) }, { additionalProperties: false }),
  },
  {
    name: 'workspace_read', label: '读取代码',
    description: 'Read a file or exact granted Java method through the IDE. Returns content, revision and truncation. Use exact expectedText for writes; never write a truncated snapshot.',
    parameters: Type.Object({ target: Target }, { additionalProperties: false }),
  },
  {
    name: 'workspace_search', label: '查找代码',
    description: 'Search literal text in visible project files. No shell or regular expression evaluation. Returns bounded matches with file and one-based line.',
    parameters: Type.Object({ query: Type.String({ minLength: 1, maxLength: 512 }), directory: Type.Optional(Path) }, { additionalProperties: false }),
  },
  {
    name: 'workspace_apply', label: '修改授权代码',
    description: 'Apply changes within the confirmed AI-owned step. The IDE checks grants, dirty editors and expected text, journals every write, then returns a receipt. Human-owned logic is protected. A rejection never grants broader scope. null denotes an absent file.',
    parameters: Type.Object({ changes: Type.Array(Type.Object({
      target: Target, expectedText: Type.Union([Text, Type.Null()]), replacement: Type.Union([Text, Type.Null()]),
    }, { additionalProperties: false }), { minItems: 1, maxItems: 100 }) }, { additionalProperties: false }),
  },
  {
    name: 'workspace_verify', label: '运行项目验证',
    description: 'Request an IDE-owned, previously authorized verification action by its actionId. No executable, command line or environment can be supplied. Only the host result establishes test success.',
    parameters: Type.Object({ actionId: Type.String({ minLength: 1, maxLength: 128 }) }, { additionalProperties: false }),
  },
];

export const TOOL_NAMES = Object.freeze(definitions.map(tool => tool.name));

export class HostToolBroker {
  #send;
  #pending = new Map();
  #run;
  #count = 0;
  #timeout;
  constructor(send, timeoutMs = LIMITS.toolTimeoutMs) { this.#send = send; this.#timeout = timeoutMs; }
  start(runId) { requireValue(!this.#run, 'busy'); this.#run = runId; this.#count = 0; }
  cancel() {
    this.#run = undefined;
    for (const call of [...this.#pending.values()]) call.reject(new BridgeError('cancelled'));
  }
  resolve(message) {
    const call = this.#pending.get(message.toolCallId);
    if (!call || message.runId !== this.#run || message.runId !== call.runId) return false;
    requireValue(typeof message.ok === 'boolean');
    if (message.ok) {
      requireValue(object(message.result));
      call.resolve(message.result);
    } else {
      // Host error codes are stable and contain no raw process/provider output.
      const code = /^[a-z_]{1,64}$/.test(message.code ?? '') ? message.code : 'tool_failed';
      call.reject(new BridgeError(code));
    }
    return true;
  }
  async call(toolCallId, name, params, signal) {
    requireValue(this.#run && !signal?.aborted, 'cancelled');
    requireValue(!this.#pending.has(toolCallId), 'duplicate_tool_call');
    requireValue(++this.#count <= LIMITS.toolCalls, 'tool_budget_exceeded');
    if (params.directory !== undefined) requireValue(relativePath(params.directory), 'invalid_path');
    if (params.target) requireValue(relativePath(params.target.path), 'invalid_path');
    if (params.changes) for (const change of params.changes) requireValue(relativePath(change.target.path), 'invalid_path');
    const runId = this.#run;
    return new Promise((resolve, reject) => {
      const finish = (callback, value) => {
        clearTimeout(timer);
        signal?.removeEventListener('abort', abort);
        this.#pending.delete(toolCallId);
        callback(value);
      };
      const abort = () => finish(reject, new BridgeError('cancelled'));
      const timer = setTimeout(() => finish(reject, new BridgeError('tool_timeout')),
        name === 'workspace_verify' ? LIMITS.verificationTimeoutMs : this.#timeout);
      this.#pending.set(toolCallId, { runId, resolve: value => finish(resolve, value), reject: error => finish(reject, error) });
      signal?.addEventListener('abort', abort, { once: true });
      try { this.#send({ type: 'tool_request', runId, toolCallId, name, arguments: params }); }
      catch (error) { finish(reject, error); }
    });
  }
  tools(role) {
    // Only development executes writes/tests. Presentation receives immutable
    // evidence in its prompt and cannot read the moving live workspace.
    const allowed = role === 'development' ? definitions :
      role === 'planning' || role === 'review' ? definitions.slice(0, 3) : [];
    return allowed.map(definition => ({ ...definition, executionMode: 'sequential',
      execute: async (id, params, signal) => {
        const result = await this.call(id, definition.name, params, signal);
        return { content: [{ type: 'text', text: JSON.stringify(result) }], details: result };
      },
    }));
  }
}
