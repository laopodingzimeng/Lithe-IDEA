import test from 'node:test';
import assert from 'node:assert/strict';
import { Writable } from 'node:stream';
import { JSONLines, JSONWriter, relativePath } from '../src/protocol.mjs';
import { HostToolBroker } from '../src/host-tools.mjs';
import { validateConfiguration } from '../src/session.mjs';
import { configuration, controllerFixture, providerFixture, textReply, toolReply } from './fixtures.mjs';

test('real Pi SDK completes a brokered write and continues using its actual host receipt', async t => {
  const provider = await providerFixture(t, (entry, index) => {
    if (index === 1) toolReply(entry, 'workspace_apply', { changes: [{ target: { kind: 'file', path: 'src/Dto.java' }, expectedText: null, replacement: 'class Dto {}' }] });
    else textReply(entry, 'Created the DTO. Validation is pending.');
  });
  const { controller, box, prompt } = await controllerFixture(t, configuration(provider.url));
  await prompt();
  const call = await box.wait(value => value.type === 'tool_request');
  assert.equal(call.name, 'workspace_apply');
  assert.equal(call.arguments.changes[0].target.path, 'src/Dto.java');
  await controller.accept({ type: 'tool_result', requestId: 'tool-result', runId: call.runId, toolCallId: call.toolCallId,
    ok: true, result: { receiptId: 'host-receipt', changedPaths: ['src/Dto.java'] } });
  const finish = await box.wait(value => value.type === 'run_finished');
  assert.equal(finish.outcome, 'completed');
  assert.equal(provider.requests.length, 2);
  assert.equal(provider.requests[0].authorization, 'Bearer fixture-only-key');
  assert.deepEqual(provider.requests[0].body.tools.map(value => value.function.name).sort(),
    ['workspace_apply', 'workspace_list', 'workspace_read', 'workspace_search', 'workspace_verify']);
  assert.ok(provider.requests[1].body.messages.some(value => value.role === 'tool' && value.content.includes('host-receipt')));
  assert.ok(box.events.findIndex(value => value.kind === 'settled') < box.events.indexOf(finish));
});

test('Pi read-only presentation has no live tools and uses its own credentials', async t => {
  const provider = await providerFixture(t, entry => textReply(entry, 'Snapshot r7 introduced the mapper.'));
  const { box, prompt } = await controllerFixture(t, configuration(provider.url, 'presentation', 'presentation-key'));
  await prompt('Explain immutable snapshot r7');
  assert.equal((await box.wait(value => value.type === 'run_finished')).outcome, 'completed');
  assert.equal(provider.requests[0].authorization, 'Bearer presentation-key');
  assert.equal(provider.requests[0].body.tools?.length ?? 0, 0);
});

test('a stalled presentation SDK session does not hold the independent development session', async t => {
  const slow = await providerFixture(t, () => {});
  const fast = await providerFixture(t, entry => textReply(entry, 'development completed'));
  const presentation = await controllerFixture(t, configuration(slow.url, 'presentation', 'presentation-key'));
  const development = await controllerFixture(t, configuration(fast.url, 'development', 'development-key'));
  await presentation.prompt('Explain the previous snapshot', 'presentation');
  await slow.arrived.wait(() => true);
  await development.prompt('Continue development', 'development');
  assert.equal((await development.box.wait(value => value.type === 'run_finished')).outcome, 'completed');
  assert.equal(presentation.box.events.some(value => value.type === 'run_finished'), false);
  await presentation.controller.accept({ type: 'cancel', requestId: 'cancel-presentation', runId: 'presentation' });
  assert.equal((await presentation.box.wait(value => value.type === 'run_finished')).outcome, 'cancelled');
});

test('cancel invalidates a pending tool before abort and rejects its late result', async t => {
  const provider = await providerFixture(t, entry => toolReply(entry, 'workspace_read', { target: { kind: 'file', path: 'src/Main.java' } }));
  const { controller, box, prompt } = await controllerFixture(t, configuration(provider.url));
  await prompt();
  const call = await box.wait(value => value.type === 'tool_request');
  await controller.accept({ type: 'cancel', requestId: 'cancel', runId: 'run' });
  await controller.accept({ type: 'tool_result', requestId: 'late-result', runId: 'run', toolCallId: call.toolCallId, ok: true, result: { text: 'late' } });
  assert.equal(box.events.find(value => value.type === 'run_finished').outcome, 'cancelled');
  assert.equal(box.events.find(value => value.type === 'tool_ack').accepted, false);
  assert.equal(provider.requests.length, 1);
});

test('real SDK provider failure is a failed run without disclosing raw error text', async t => {
  const provider = await providerFixture(t, entry => entry.response.writeHead(401, { 'Content-Type': 'application/json' }).end(JSON.stringify({ error: { message: 'fixture-only-key private provider detail', type: 'invalid_api_key' } })));
  const { box, prompt } = await controllerFixture(t, configuration(provider.url));
  await prompt();
  assert.equal((await box.wait(value => value.type === 'run_finished')).outcome, 'failed');
  assert.ok(!JSON.stringify(box.events).includes('private provider detail'));
});

test('path traversal is rejected before reaching the host and Pi can report the rejection', async t => {
  const provider = await providerFixture(t, (entry, index) => {
    if (index === 1) toolReply(entry, 'workspace_read', { target: { kind: 'file', path: '../private.txt' } });
    else textReply(entry, 'The read was rejected.');
  });
  const { box, prompt } = await controllerFixture(t, configuration(provider.url));
  await prompt();
  await box.wait(value => value.type === 'run_finished');
  assert.equal(box.events.filter(value => value.type === 'tool_request').length, 0);
  assert.ok(provider.requests[1].body.messages.some(value => value.role === 'tool' && value.content.includes('invalid_path')));
});

test('JSONL handles fragmented Unicode and literal line separators; truncated input fails', () => {
  const parser = new JSONLines();
  const bytes = Buffer.from(JSON.stringify({ type: 'prompt', text: '中\u2028文\u2029' }) + '\n');
  const values = [];
  for (const byte of bytes) values.push(...parser.push(Buffer.from([byte])));
  assert.equal(values[0].text, '中\u2028文\u2029');
  parser.finish();
  parser.push(Buffer.from('{'));
  assert.throws(() => parser.finish(), { code: 'truncated_frame' });
  for (const path of ['/tmp/a', '../a', 'a/../b', 'a\\b', 'C:/a', '.git/config', 'a//b']) assert.equal(relativePath(path), false);
});

test('writer redacts literal credentials including JSON metacharacters', () => {
  let output = '';
  const stream = new Writable({ write(chunk, _encoding, callback) { output += chunk.toString(); callback(); } });
  const writer = new JSONWriter(stream);
  writer.protect('key"\\secret');
  writer.send({ type: 'event', text: 'key"\\secret' });
  assert.equal(JSON.parse(output).text, '[redacted]');
  stream.end();
});

test('literal model credentials cannot become commands or environment expressions', () => {
  const config = configuration('https://models.example.test/v1', 'development', '!echo should-never-run');
  assert.equal(validateConfiguration(config).model.apiKey, '!echo should-never-run');
  config.model.headers = { 'X-Command': '!echo unsafe' };
  assert.throws(() => validateConfiguration(config), { code: 'nonliteral_header' });
  config.model.headers = {};
  config.model.allowInsecureHTTP = false;
  config.model.baseUrl = 'http://models.example.test/v1';
  assert.throws(() => validateConfiguration(config), { code: 'insecure_endpoint' });
});

test('broker cancellation drains ownership and rejects stale generation callbacks', async () => {
  let request;
  const broker = new HostToolBroker(value => { request = value; });
  broker.start('old');
  const pending = broker.call('call', 'workspace_read', { target: { path: 'src/A.java' } });
  const assertion = assert.rejects(pending, { code: 'cancelled' });
  broker.cancel();
  await assertion;
  broker.start('new');
  assert.equal(broker.resolve({ ...request, runId: 'old', ok: true, result: {} }), false);
  broker.cancel();
});
