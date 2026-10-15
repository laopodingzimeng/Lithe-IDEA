#!/usr/bin/env node
import { run } from 'node:test';
import { mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { writeTestReportArtifacts } from '../.agents/skills/write-stable-tests/scripts/generate-test-report.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const testDirectory = path.join(root, 'integrations/pi-bridge/test');
const files = readdirSync(testDirectory).filter(name => name.endsWith('.test.mjs')).sort().map(name => path.join(testDirectory, name));
const records = [];
const stream = run({ files, concurrency: 1, timeout: 10_000 });
for await (const event of stream) {
  if (!['test:pass', 'test:fail'].includes(event.type)) continue;
  const data = event.data;
  records.push({ name: data.name, suite: 'Pi SDK bridge', status: data.skip ? 'skipped' : event.type === 'test:pass' ? 'passed' : 'failed',
    durationMs: data.details.duration_ms, details: data.details.error?.stack ?? '' });
  console.log(`${event.type === 'test:pass' ? 'PASS' : 'FAIL'} ${data.name} (${data.details.duration_ms.toFixed(1)} ms)`);
  if (event.type === 'test:fail' || data.details.duration_ms >= 10_000) process.exitCode = 1;
}
const output = path.join(root, '.artifacts/test-stability/pi-bridge.json');
mkdirSync(path.dirname(output), { recursive: true });
writeFileSync(output, JSON.stringify({ runner: 'Node · Pi SDK', warnMs: 1000, maxMs: 10_000, tests: records }, null, 2) + '\n');
writeTestReportArtifacts(output);
if (!records.length) process.exitCode = 1;
