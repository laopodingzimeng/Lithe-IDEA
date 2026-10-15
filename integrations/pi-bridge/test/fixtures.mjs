import http from 'node:http';
import { once } from 'node:events';
import { WorkerController } from '../src/controller.mjs';

export function inbox() {
  const events = [];
  const waiters = new Set();
  return {
    events,
    send(value) {
      events.push(value);
      for (const waiter of [...waiters]) if (waiter.match(value)) waiter.resolve(value);
    },
    wait(match) {
      const existing = events.find(match);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { waiters.delete(waiter); reject(new Error('event deadline: ' + JSON.stringify(events))); }, 3000);
        const waiter = { match, resolve: value => { clearTimeout(timer); waiters.delete(waiter); resolve(value); } };
        waiters.add(waiter);
      });
    },
    close() { for (const waiter of [...waiters]) waiter.resolve(undefined); },
  };
}

export async function providerFixture(t, reply) {
  const requests = [];
  const arrived = inbox();
  const server = http.createServer(async (request, response) => {
    let data = '';
    for await (const chunk of request) data += chunk;
    const entry = { body: JSON.parse(data), authorization: request.headers.authorization, headers: request.headers, url: request.url, response };
    requests.push(entry);
    arrived.send(entry);
    try { reply(entry, requests.length); }
    catch { response.writeHead(500).end(); }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening', { signal: AbortSignal.timeout(3000) });
  t.after(() => {
    arrived.close();
    server.closeAllConnections();
    server.close();
  });
  return { requests, arrived, url: `http://127.0.0.1:${server.address().port}/v1` };
}

export function textReply(entry, text, totalTokens = 15) {
  entry.response.writeHead(200, { 'Content-Type': 'text/event-stream' });
  const chunk = delta => JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk', model: 'fixture-model', choices: [{ index: 0, delta, finish_reason: null }] });
  entry.response.write(`data: ${chunk({ role: 'assistant', content: text })}\n\n`);
  entry.response.write('data: ' + JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk', model: 'fixture-model', choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: totalTokens - 5, completion_tokens: 5, total_tokens: totalTokens } }) + '\n\n');
  entry.response.end('data: [DONE]\n\n');
}

export function toolReply(entry, name, params, commentary = undefined) {
  entry.response.writeHead(200, { 'Content-Type': 'text/event-stream' });
  const tool = { index: 0, id: 'call_fixture', type: 'function', function: { name, arguments: JSON.stringify(params) } };
  entry.response.write('data: ' + JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk', model: 'fixture-model', choices: [{ index: 0, delta: { role: 'assistant', content: commentary, tool_calls: [tool] }, finish_reason: null }] }) + '\n\n');
  entry.response.write('data: ' + JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk', model: 'fixture-model', choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] }) + '\n\n');
  entry.response.end('data: [DONE]\n\n');
}

export function configuration(url, role = 'development', apiKey = 'fixture-only-key') {
  return { role, model: { api: 'openai-completions', id: 'fixture-model', baseUrl: url, apiKey, allowInsecureHTTP: true }, systemPrompt: 'Use only IDE tools. Never claim unobserved test success.' };
}

export async function controllerFixture(t, config) {
  const box = inbox();
  const controller = new WorkerController(value => box.send(value), process.cwd());
  t.after(async () => { await controller.close(); box.close(); });
  await controller.accept({ type: 'initialize', protocolVersion: 1, requestId: 'init', configuration: config });
  return { controller, box, prompt: (text = 'Do the task', runId = 'run') => controller.accept({ type: 'prompt', requestId: `prompt-${runId}`, runId, text }) };
}
