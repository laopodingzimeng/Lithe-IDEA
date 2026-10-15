import { createAgentSession, createExtensionRuntime, ModelRuntime, SessionManager, SettingsManager } from '@earendil-works/pi-coding-agent';
import { boundedInteger, object, requireValue } from './protocol.mjs';

export function validateConfiguration(input) {
  requireValue(object(input));
  requireValue(['development', 'presentation', 'planning', 'review', 'completion'].includes(input.role));
  requireValue(object(input.model));
  const model = input.model;
  requireValue(['openai-completions', 'openai-responses', 'anthropic-messages'].includes(model.api));
  requireValue(typeof model.id === 'string' && model.id.length > 0 && model.id.length <= 256);
  requireValue(typeof model.apiKey === 'string' && model.apiKey.length > 0 && model.apiKey.length <= 16_384);
  let endpoint;
  try { endpoint = new URL(model.baseUrl); } catch { requireValue(false); }
  requireValue(endpoint.protocol === 'https:' || (endpoint.protocol === 'http:' && model.allowInsecureHTTP === true), 'insecure_endpoint');
  requireValue(!endpoint.username && !endpoint.password && !endpoint.search && !endpoint.hash);
  requireValue(!model.baseUrl.startsWith('!') && !model.baseUrl.includes('$'));
  requireValue(model.headers === undefined || (object(model.headers) && Object.keys(model.headers).length <= 16));
  for (const [name, value] of Object.entries(model.headers ?? {})) {
    requireValue(/^[A-Za-z0-9-]{1,128}$/.test(name) && typeof value === 'string' && value.length <= 4096);
    // Pi config values support command/environment expansion. This boundary only
    // accepts literal headers; credentials enter the public CredentialStore.
    requireValue(!/[\r\n$]/.test(value) && !value.startsWith('!'), 'nonliteral_header');
    requireValue(!/^(host|content-length|connection|authorization|x-api-key)$/i.test(name), 'reserved_header');
  }
  requireValue(typeof input.systemPrompt === 'string' && input.systemPrompt.length <= 64_000);
  return { ...input, model: { ...model,
    contextWindow: boundedInteger(model.contextWindow, 128_000, 4096, 2_000_000),
    maxTokens: boundedInteger(model.maxTokens, 8192, 128, 64_000),
  }, runTimeoutMs: boundedInteger(input.runTimeoutMs, 600_000, 1000, 3_600_000) };
}

class EphemeralCredentials {
  #values = new Map();
  async read(id) { return this.#values.get(id); }
  async list() { return [...this.#values.entries()].map(([providerId, value]) => ({ providerId, type: value.type })); }
  async modify(id, fn) {
    // fn is synchronous per the CredentialStore contract; no await between read/write.
    const result = fn(this.#values.get(id));
    if (result === undefined) this.#values.delete(id); else this.#values.set(id, result);
    return result;
  }
  async delete(id) { this.#values.delete(id); }
}

export async function createSession(configuration, broker, stateDirectory) {
  const { model: config, role } = configuration;
  const provider = 'lithe-configured';
  const runtime = await ModelRuntime.create({ credentials: new EphemeralCredentials(), modelsPath: null,
    allowModelNetwork: false, refreshOnCreate: false });
  runtime.registerProvider(provider, {
    baseUrl: config.baseUrl, api: config.api, headers: config.headers,
    models: [{ id: config.id, name: config.id, input: ['text'], reasoning: false,
      // SDK metadata requires cost. Host accounting treats unknown pricing as
      // unknown and never displays these placeholder zeros as a free model.
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: config.contextWindow, maxTokens: config.maxTokens,
      ...(config.api === 'openai-completions' ? { compat: { supportsStore: false, supportsDeveloperRole: false } } : {}),
    }],
  });
  await runtime.setRuntimeApiKey(provider, config.apiKey);
  const model = runtime.getModel(provider, config.id);
  requireValue(model, 'model_unavailable');
  const loader = {
    getExtensions: () => ({ extensions: [], errors: [], runtime: createExtensionRuntime() }),
    getSkills: () => ({ skills: [], diagnostics: [] }),
    getPrompts: () => ({ prompts: [], diagnostics: [] }),
    getThemes: () => ({ themes: [], diagnostics: [] }),
    getAgentsFiles: () => ({ agentsFiles: [] }),
    getSystemPrompt: () => configuration.systemPrompt,
    getSystemPromptSource: () => undefined,
    getAppendSystemPrompt: () => [], getAppendSystemPromptSources: () => [],
    extendResources: () => {}, reload: async () => {},
  };
  const customTools = broker.tools(role);
  const result = await createAgentSession({ cwd: stateDirectory, agentDir: stateDirectory,
    modelRuntime: runtime, model, thinkingLevel: 'off',
    resourceLoader: loader, noTools: 'builtin', tools: customTools.map(tool => tool.name), customTools,
    sessionManager: SessionManager.inMemory(stateDirectory),
    settingsManager: SettingsManager.inMemory({
      cacheWarming: 'off', compaction: { enabled: false },
      retry: { enabled: false, provider: { maxRetries: 0, timeoutMs: 60_000, maxRetryDelayMs: 0 } },
      images: { blockImages: true }, httpIdleTimeoutMs: 60_000,
      enableAnalytics: false, enableInstallTelemetry: false,
      packages: [], extensions: [], skills: [], prompts: [],
    }),
  });
  return result.session;
}
