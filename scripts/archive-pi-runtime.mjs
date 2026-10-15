#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile, rename, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verify, sha256, manifestName } from './pi-runtime-package.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const directory = path.resolve(process.argv[2] ?? '');
const metadata = JSON.parse(await readFile(path.join(directory, manifestName), 'utf8'));
const verified = await verify(directory, metadata.platform, metadata.architecture);
const identity = (await sha256(path.join(directory, manifestName))).slice(0, 12);
const output = path.join(root, '.artifacts/pi-packages');
await mkdir(output, { recursive: true });
const filename = `Lithe-Pi-${metadata.version}-${metadata.platform}-${metadata.architecture}-${identity}.zip`;
const archive = path.join(output, filename), temporary = path.join(output, `${process.pid}-${filename}`);
try {
  // -X excludes host-specific extra fields; the builder normalized file times
  // and permissions. Only a fully verified ordinary-file tree reaches zip.
  const entries = [...Object.keys(verified.files), manifestName].sort().map(file => `${path.basename(directory)}/${file}`);
  execFileSync('zip', ['-X', '-q', temporary, '-@'],
    { cwd: path.dirname(directory), input: entries.join('\n') + '\n', timeout: 120_000, stdio: 'pipe' });
  await verify(directory, metadata.platform, metadata.architecture);
  await rename(temporary, archive);
  await writeFile(`${archive}.sha256`, `${await sha256(archive)}  ${filename}\n`);
  console.log(archive);
} finally { await rm(temporary, { force: true }); }
