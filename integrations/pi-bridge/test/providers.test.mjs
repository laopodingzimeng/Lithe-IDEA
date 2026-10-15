import test from 'node:test';
import assert from 'node:assert/strict';
import { configuration, controllerFixture, providerFixture } from './fixtures.mjs';

for (const authentication of ['bearer', 'apiKey', 'none']) test(`real Pi Anthropic adapter routes ${authentication} authentication literally`, async t => {
  const provider = await providerFixture(t, entry => {
    entry.response.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const events = [
      { type: 'message_start', message: { id: 'msg_fixture', type: 'message', role: 'assistant', model: 'fixture-model', content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 12, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
      { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Anthropic fixture' } },
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 4 } },
      { type: 'message_stop' },
    ];
    for (const value of events) entry.response.write(`event: ${value.type}\ndata: ${JSON.stringify(value)}\n\n`);
    entry.response.end();
  });
  const config = configuration(provider.url, 'presentation', 'anthropic-fixture-key');
  config.model.api = 'anthropic-messages';
  config.model.authentication = authentication;
  const { box, prompt } = await controllerFixture(t, config);
  await prompt();
  assert.equal((await box.wait(value => value.type === 'run_finished')).outcome, 'completed');
  assert.equal(provider.requests[0].headers['x-api-key'], authentication === 'apiKey' ? 'anthropic-fixture-key' : undefined);
  assert.equal(provider.requests[0].authorization, authentication === 'bearer' ? 'Bearer anthropic-fixture-key' : undefined);
  assert.ok(box.events.some(value => value.text === 'Anthropic fixture'));
});

for (const authentication of ['bearer', 'apiKey', 'none']) test(`real Pi Responses adapter routes ${authentication} authentication literally`, async t => {
  const provider = await providerFixture(t, entry => {
    entry.response.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const item = { id: 'msg_fixture', type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: 'Responses fixture', annotations: [] }] };
    const response = { id: 'resp_fixture', object: 'response', status: 'completed', model: 'fixture-model', output: [item], usage: { input_tokens: 10, output_tokens: 3, total_tokens: 13, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } };
    const events = [
      { type: 'response.created', response: { ...response, output: [], status: 'in_progress' } },
      { type: 'response.output_item.added', output_index: 0, item: { ...item, content: [], status: 'in_progress' } },
      { type: 'response.content_part.added', output_index: 0, content_index: 0, item_id: item.id, part: { type: 'output_text', text: '', annotations: [] } },
      { type: 'response.output_text.delta', output_index: 0, content_index: 0, item_id: item.id, delta: 'Responses fixture' },
      { type: 'response.output_text.done', output_index: 0, content_index: 0, item_id: item.id, text: 'Responses fixture' },
      { type: 'response.content_part.done', output_index: 0, content_index: 0, item_id: item.id, part: item.content[0] },
      { type: 'response.output_item.done', output_index: 0, item },
      { type: 'response.completed', response },
    ];
    for (const value of events) entry.response.write(`event: ${value.type}\ndata: ${JSON.stringify(value)}\n\n`);
    entry.response.end();
  });
  const config = configuration(provider.url, 'presentation', 'responses-fixture-key');
  config.model.api = 'openai-responses';
  config.model.authentication = authentication;
  const { box, prompt } = await controllerFixture(t, config);
  await prompt();
  assert.equal((await box.wait(value => value.type === 'run_finished')).outcome, 'completed');
  assert.equal(provider.requests[0].authorization, authentication === 'bearer' ? 'Bearer responses-fixture-key' : undefined);
  assert.equal(provider.requests[0].headers['x-api-key'], authentication === 'apiKey' ? 'responses-fixture-key' : undefined);
  assert.ok(box.events.some(value => value.text === 'Responses fixture'));
});
