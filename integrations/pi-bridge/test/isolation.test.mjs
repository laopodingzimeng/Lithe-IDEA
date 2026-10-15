import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { JSONLines } from '../src/protocol.mjs';
import { configuration, inbox, providerFixture, textReply } from './fixtures.mjs';

const root = realpathSync(fileURLToPath(new URL('..', import.meta.url)));
const node = realpathSync(process.execPath);

function directories(t) {
  const directory = realpathSync(mkdtempSync(path.join(tmpdir(), 'lithe-pi-test-')));
  const state = path.join(directory, 'state');
  mkdirSync(state);
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return { directory, state };
}

function sandboxArguments(state) {
  return ['-D', `STATE=${state}`, '-D', `NODE=${node}`, '-f', path.join(root, 'platform/macos.sb'), node];
}

test('macOS sandbox denies source writes even in a descendant Node process', { skip: process.platform !== 'darwin' }, t => {
  const { directory, state } = directories(t);
  const sentinel = path.join(directory, 'human-source.txt');
  writeFileSync(sentinel, 'human-owned');
  const code = `const fs = require('node:fs');
    let denied = false;
    try { fs.writeFileSync(process.argv[1], 'modified'); } catch (e) { denied = e.code === 'EPERM' || e.code === 'EACCES'; }
    if (!denied) process.exit(2);
    fs.writeFileSync(process.argv[2], 'state-is-writable');`;
  const parent = `const cp = require('node:child_process');
    const result = cp.spawnSync(process.execPath, ['-e', ${JSON.stringify(code)}, process.argv[1], process.argv[2]], { timeout: 2000 });
    if (result.error || result.status !== 0) process.exit(3);`;
  // Deliberately omit Node permissions here: this verifies the OS boundary and
  // inherited descendant restrictions independently from Node's JS API guards.
  execFileSync('/usr/bin/sandbox-exec', [...sandboxArguments(state), '-e', code, sentinel, path.join(state, 'direct')], { timeout: 3000, stdio: 'pipe' });
  execFileSync('/usr/bin/sandbox-exec', [...sandboxArguments(state), '-e', parent, sentinel, path.join(state, 'child')], { timeout: 3000, stdio: 'pipe' });
  assert.equal(readFileSync(sentinel, 'utf8'), 'human-owned');
  assert.equal(readFileSync(path.join(state, 'child'), 'utf8'), 'state-is-writable');
});

test('isolated JSONL worker runs real Pi and exits after acknowledged shutdown', async t => {
  const { state } = directories(t);
  const provider = await providerFixture(t, entry => textReply(entry, 'snapshot explanation'));
  const args = ['--permission', `--allow-fs-read=${root}`, `--allow-fs-read=${state}`, `--allow-fs-write=${state}`, path.join(root, 'src/main.mjs')];
  const executable = process.platform === 'darwin' ? '/usr/bin/sandbox-exec' : node;
  const child = spawn(executable, process.platform === 'darwin' ? [...sandboxArguments(state), ...args] : args, {
    cwd: state, env: { PATH: path.dirname(node), HOME: state, TMPDIR: state }, stdio: ['pipe', 'pipe', 'pipe'], detached: process.platform !== 'win32',
  });
  const kill = () => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    try { if (process.platform === 'win32') child.kill('SIGKILL'); else process.kill(-child.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
  };
  const watchdog = setTimeout(kill, 7000);
  const exit = once(child, 'exit', { signal: AbortSignal.timeout(8000) });
  // Attach immediately so an early process failure cannot create an unhandled rejection.
  void exit.catch(() => {});
  const box = inbox();
  const parser = new JSONLines();
  let diagnostic = '';
  child.stderr.on('data', data => { diagnostic += data; });
  child.stdout.on('data', data => { for (const value of parser.push(data)) box.send(value); });
  t.after(async () => {
    clearTimeout(watchdog); kill();
    await exit;
    child.stdin.destroy(); child.stdout.destroy(); child.stderr.destroy(); box.close();
  });
  const send = value => child.stdin.write(JSON.stringify(value) + '\n');
  send({ type: 'initialize', requestId: 'init', protocolVersion: 1, configuration: configuration(provider.url, 'presentation') });
  await box.wait(value => value.type === 'ready');
  send({ type: 'prompt', requestId: 'prompt', runId: 'run', text: 'Explain snapshot r1' });
  const finish = await box.wait(value => value.type === 'run_finished');
  assert.equal(finish.outcome, 'completed', diagnostic);
  send({ type: 'shutdown', requestId: 'shutdown' });
  await box.wait(value => value.type === 'closed');
  assert.equal((await exit)[0], 0, diagnostic);
  assert.equal(provider.requests.length, 1);
});
