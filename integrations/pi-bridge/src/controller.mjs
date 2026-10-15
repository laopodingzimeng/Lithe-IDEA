import { BridgeError, LIMITS, identifier, requireValue } from './protocol.mjs';
import { HostToolBroker } from './host-tools.mjs';
import { createSession, validateConfiguration } from './session.mjs';

// One worker owns one immutable role/model configuration. The native host starts
// development and presentation workers independently and owns their lifetimes.
export class WorkerController {
  #send;
  #directory;
  #broker;
  #session;
  #unsubscribe;
  #configuration;
  #active;
  #initializing = false;
  #closed = false;
  #ids = new Set();
  #runIds = new Set();
  constructor(send, stateDirectory) {
    this.#send = send;
    this.#directory = stateDirectory;
    this.#broker = new HostToolBroker(send);
  }
  async accept(message) {
    requireValue(!this.#closed, 'closed');
    requireValue(identifier(message.requestId));
    requireValue(!this.#ids.has(message.requestId), 'duplicate_request');
    requireValue(this.#ids.size < 10_000, 'request_budget_exceeded');
    this.#ids.add(message.requestId);
    switch (message.type) {
      case 'initialize': {
        requireValue(!this.#session && !this.#initializing, 'already_initialized');
        requireValue(message.protocolVersion === 1, 'incompatible_protocol');
        this.#initializing = true;
        try {
          this.#configuration = validateConfiguration(message.configuration);
          const session = await createSession(this.#configuration, this.#broker, this.#directory);
          if (this.#closed) { session.dispose(); throw new BridgeError('closed'); }
          this.#session = session;
          this.#unsubscribe = session.subscribe(event => this.#event(event));
          this.#send({ type: 'ready', requestId: message.requestId, role: this.#configuration.role,
            modelId: this.#configuration.model.id, tools: this.#broker.tools(this.#configuration.role).map(tool => tool.name),
            runtimeVersion: '1.0.0', sdkVersion: '1.2.0' });
        } finally { this.#initializing = false; }
        return;
      }
      case 'prompt': {
        requireValue(this.#session, 'not_initialized');
        requireValue(!this.#active, 'busy');
        requireValue(identifier(message.runId));
        requireValue(!this.#runIds.has(message.runId), 'duplicate_run');
        requireValue(typeof message.text === 'string' && message.text.length > 0 && message.text.length <= LIMITS.textChars);
        const active = { id: message.runId, cancelled: false, timedOut: false, failed: false, settled: false, chars: 0, finalText: '', done: undefined };
        this.#runIds.add(message.runId);
        this.#active = active;
        this.#broker.start(active.id);
        this.#send({ type: 'accepted', requestId: message.requestId, runId: active.id });
        active.done = this.#run(active, message.text);
        return;
      }
      case 'tool_result': {
        requireValue(identifier(message.runId) && typeof message.toolCallId === 'string');
        const accepted = this.#broker.resolve(message);
        this.#send({ type: 'tool_ack', requestId: message.requestId, runId: message.runId, accepted });
        return;
      }
      case 'cancel': {
        requireValue(identifier(message.runId));
        if (this.#active?.id === message.runId) await this.#cancel(this.#active);
        this.#send({ type: 'cancelled', requestId: message.requestId, runId: message.runId });
        return;
      }
      case 'shutdown': {
        await this.close();
        this.#send({ type: 'closed', requestId: message.requestId });
        return;
      }
      default: throw new BridgeError('unknown_command');
    }
  }
  async #run(active, text) {
    const timer = setTimeout(() => {
      active.timedOut = true;
      void this.#cancel(active).catch(() => { active.failed = true; });
    }, this.#configuration.runTimeoutMs);
    try {
      await this.#session.prompt(text, { expandPromptTemplates: false });
      await this.#session.waitForIdle();
    } catch { active.failed = true; }
    finally {
      clearTimeout(timer);
      this.#broker.cancel();
      if (this.#active === active) this.#active = undefined;
    }
    const outcome = active.timedOut ? 'timeout' : active.cancelled ? 'cancelled' :
      active.failed || !active.settled ? 'failed' : 'completed';
    this.#send({ type: 'run_finished', runId: active.id, outcome, text: active.finalText,
      ...(outcome === 'failed' ? { code: 'model_request_failed' } : {}) });
  }
  async #cancel(active) {
    active.cancelled = true;
    // Invalidate callbacks before awaiting upstream abort. No pending prompt may
    // restart automatically after a human takes over.
    this.#broker.cancel();
    this.#session.clearQueue();
    await this.#session.abort();
    await active.done;
  }
  #event(event) {
    const active = this.#active;
    if (!active || active.cancelled) return;
    const envelope = { type: 'event', runId: active.id };
    switch (event.type) {
      case 'message_update': {
        const delta = event.assistantMessageEvent;
        if (delta.type !== 'text_delta') return;
        active.chars += delta.delta.length;
        requireValue(active.chars <= LIMITS.textChars, 'output_budget_exceeded');
        this.#send({ ...envelope, kind: 'text_delta', text: delta.delta });
        return;
      }
      case 'message_end': {
        const message = event.message;
        if (message.role !== 'assistant') return;
        // Earlier exploration commentary is streamed, but is not the final JSON
        // plan/review result consumed by the host after the tool loop settles.
        active.finalText = message.content.filter(block => block.type === 'text').map(block => block.text).join('');
        requireValue(active.finalText.length <= LIMITS.textChars, 'output_budget_exceeded');
        if (message.stopReason === 'error' || message.stopReason === 'aborted') active.failed = true;
        const usage = message.usage;
        if (usage) {
          const tokens = {};
          for (const key of ['input', 'output', 'cacheRead', 'cacheWrite', 'totalTokens']) {
            if (Number.isFinite(usage[key]) && usage[key] >= 0) tokens[key] = usage[key];
          }
          this.#send({ ...envelope, kind: 'usage', tokens });
        }
        return;
      }
      case 'tool_execution_start':
        this.#send({ ...envelope, kind: 'tool_started', toolCallId: event.toolCallId, name: event.toolName });
        return;
      case 'tool_execution_end':
        this.#send({ ...envelope, kind: 'tool_finished', toolCallId: event.toolCallId, name: event.toolName, isError: event.isError === true });
        return;
      case 'agent_settled':
        active.settled = true;
        this.#send({ ...envelope, kind: 'settled' });
        return;
    }
  }
  async close() {
    this.#closed = true;
    if (this.#active) await this.#cancel(this.#active);
    this.#unsubscribe?.();
    this.#session?.dispose();
    this.#session = undefined;
    this.#configuration = undefined;
  }
}
