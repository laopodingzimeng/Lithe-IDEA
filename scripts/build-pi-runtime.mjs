#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, cp, rm, rename, readdir, lstat, chmod, utimes } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { seal, sha256, verify, manifestName, safePath } from './pi-runtime-package.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const args = process.argv.slice(2);
function option(name, fallback) {
  const index = args.indexOf(name);
  return index < 0 ? fallback : args[index + 1];
}
const platform = option('--platform', process.platform), architecture = option('--arch', process.arch);
const configuration = JSON.parse(await readFile(path.join(root, 'integrations/pi-bridge/runtime.json'), 'utf8'));
const identity = `${platform}-${architecture}`, archive = configuration.archives[identity];
if (!archive || !['darwin', 'linux'].includes(process.platform)) throw new Error('Build on macOS/Linux for a configured runtime target');
const output = path.resolve(option('--output', path.join(root, '.artifacts/pi-runtime', identity)));
if (args.includes('--reseal')) {
  const current = JSON.parse(await readFile(path.join(output, manifestName), 'utf8'));
  await seal(output, current);
  console.log(output);
} else {
  const allowed = path.join(root, '.artifacts') + path.sep;
  if (!output.startsWith(allowed)) throw new Error('Build output must be inside this worktree .artifacts');
  const downloads = path.join(root, '.artifacts/pi-downloads');
  await mkdir(downloads, { recursive: true });
  const cachedArchive = path.join(downloads, archive.name);
  let cached = false;
  try { cached = await sha256(cachedArchive) === archive.sha256; } catch {}
  if (!cached) {
    const temporary = path.join(downloads, `${archive.name}.${process.pid}.tmp`);
    try {
      // Match the repository's downloader: curl honors build-machine proxy
      // configuration while keeping time and size bounds outside the SDK.
      execFileSync('curl', ['--fail', '--location', '--silent', '--show-error', '--connect-timeout', '10',
        '--max-time', '120', '--max-filesize', String(128 * 1024 * 1024), '--output', temporary,
        `https://nodejs.org/dist/v${configuration.nodeVersion}/${archive.name}`], { timeout: 125_000, stdio: 'pipe' });
      if (await sha256(temporary) !== archive.sha256) throw new Error('Node archive checksum mismatch');
      await rename(temporary, cachedArchive);
    } finally { await rm(temporary, { force: true }); }
  }
  await mkdir(path.dirname(output), { recursive: true });
  const temporary = await mkdtemp(path.join(path.dirname(output), '.pi-build-'));
  try {
    const unpacked = path.join(temporary, 'upstream'), directory = path.join(temporary, 'runtime');
    await mkdir(unpacked); await mkdir(directory);
    // Only the pinned, checksum-verified official archive reaches the extractor.
    if (archive.name.endsWith('.zip')) {
      execFileSync('unzip', ['-q', cachedArchive, '-d', unpacked], { timeout: 60_000, stdio: 'pipe' });
    } else {
      execFileSync('tar', ['-xf', cachedArchive, '-C', unpacked], { timeout: 60_000, stdio: 'pipe' });
    }
    const upstream = path.join(unpacked, archive.name.replace(/\.tar\.gz$|\.zip$/, ''));
    const source = path.join(root, 'integrations/pi-bridge');
    for (const entry of ['src', 'platform', 'package.json', 'package-lock.json']) {
      await cp(path.join(source, entry), path.join(directory, entry), { recursive: true });
    }
    execFileSync('npm', ['ci', '--prefix', directory, '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund'],
      { timeout: 180_000, stdio: 'pipe' });
    // The worker never launches dependency commands. npm's convenience symlinks
    // are excluded so every installed payload is an ordinary owned file.
    async function removeCommandLinks(relative) {
      for (const name of await readdir(relative)) {
        const file = path.join(relative, name), stat = await lstat(file);
        if (name === '.bin' && stat.isDirectory()) await rm(file, { recursive: true });
        else if (stat.isDirectory()) await removeCommandLinks(file);
      }
    }
    await removeCommandLinks(path.join(directory, 'node_modules'));
    await mkdir(path.join(directory, 'bin'));
    await cp(path.join(upstream, platform === 'win32' ? 'node.exe' : 'bin/node'), path.join(directory, 'bin', platform === 'win32' ? 'node.exe' : 'node'));
    await mkdir(path.join(directory, 'licenses'));
    await cp(path.join(upstream, 'LICENSE'), path.join(directory, 'licenses/Node.txt'));
    const { archives, ...metadata } = configuration;
    await seal(directory, { ...metadata, platform, architecture });
    const timestamp = new Date('2000-01-01T00:00:00Z');
    async function normalize(relative = '') {
      for (const name of (await readdir(path.join(directory, relative))).sort()) {
        const key = relative ? `${relative}/${name}` : name;
        if (!safePath(key)) throw new Error('Unsafe runtime archive path');
        const file = path.join(directory, key), stat = await lstat(file);
        if (stat.isSymbolicLink()) throw new Error('Runtime contains a symbolic link');
        if (stat.isDirectory()) await normalize(key);
        await chmod(file, stat.isDirectory() || key === 'bin/node' || key === 'bin/node.exe' ? 0o755 : 0o644);
        await utimes(file, timestamp, timestamp);
      }
    }
    await normalize();
    await verify(directory, platform, architecture);
    // Replace only this task's designated build output after a complete staged
    // validation; installed runtime directories are never accepted as outputs.
    const old = path.join(temporary, 'previous');
    try { await rename(output, old); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    try { await rename(directory, output); }
    catch (error) { try { await rename(old, output); } catch {} throw error; }
    console.log(output);
  } finally { await rm(temporary, { recursive: true, force: true }); }
}
