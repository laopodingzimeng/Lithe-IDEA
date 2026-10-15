import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { seal, verify, safePath, manifestName } from '../../../scripts/pi-runtime-package.mjs';

async function fixture(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'pi-runtime-manifest-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  for (const name of ['src/main.mjs', 'platform/macos.sb', 'bin/node', 'package.json', 'package-lock.json', 'node_modules/@earendil-works/pi-coding-agent/package.json']) {
    const file = path.join(root, name);
    await mkdir(path.dirname(file), { recursive: true });
    await writeFile(file, name.endsWith('package.json') ? '{"version":"1.2.0"}' : 'fixture');
  }
  const metadata = { schemaVersion: 1, protocolVersion: 1, version: '1.0.0', sdkVersion: '1.2.0', nodeVersion: '24.1.0', platform: 'darwin', architecture: 'arm64' };
  await seal(root, metadata);
  return root;
}

test('runtime manifests are reproducible and reject incompatible hosts', async t => {
  const root = await fixture(t), before = await readFile(path.join(root, manifestName));
  const metadata = await verify(root, 'darwin', 'arm64');
  await seal(root, metadata);
  assert.deepEqual(await readFile(path.join(root, manifestName)), before);
  await assert.rejects(verify(root, 'win32', 'arm64'), /Incompatible/);
  await assert.rejects(verify(root, 'darwin', 'x64'), /Incompatible/);
  await writeFile(path.join(root, manifestName), JSON.stringify({ ...metadata, protocolVersion: 2 }));
  await assert.rejects(verify(root, 'darwin', 'arm64'), /Incompatible/);
});

test('runtime rejects altered, missing and extra payloads', async t => {
  const root = await fixture(t), file = path.join(root, 'src/main.mjs');
  await writeFile(file, 'changed');
  await assert.rejects(verify(root, 'darwin', 'arm64'), /content changed/);
  await writeFile(file, 'fixture');
  await writeFile(path.join(root, 'extra'), 'extra');
  await assert.rejects(verify(root, 'darwin', 'arm64'), /content changed/);
  await rm(path.join(root, 'extra'));
  await rm(file);
  await assert.rejects(verify(root, 'darwin', 'arm64'), /content changed/);
});

test('runtime rejects path aliases and symlink payloads', async t => {
  const root = await fixture(t);
  for (const name of ['/absolute', '../parent', 'a/../b', 'a//b', 'C:/drive', 'a\\b', '.git/config', 'a\nfile']) assert.equal(safePath(name), false);
  await symlink('src/main.mjs', path.join(root, 'alias'));
  await assert.rejects(verify(root, 'darwin', 'arm64'), /symbolic links/);
});

test('runtime validates the actual SDK version rather than its label', async t => {
  const root = await fixture(t);
  const metadata = await verify(root, 'darwin', 'arm64');
  await writeFile(path.join(root, 'node_modules/@earendil-works/pi-coding-agent/package.json'), '{"version":"9.0.0"}');
  await assert.rejects(seal(root, metadata), /SDK version differs/);
});
