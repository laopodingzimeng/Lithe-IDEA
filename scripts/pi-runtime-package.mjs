import { createHash } from 'node:crypto';
import { createReadStream, readdirSync, lstatSync, openSync, readSync, closeSync } from 'node:fs';
import { lstat, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

export const manifestName = 'lithe-pi-runtime.json';
export const maximumBytes = 512 * 1024 * 1024;
export const maximumEntries = 20_000;
export function safePath(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 1024 &&
    !/[\\:\x00-\x1f\x7f]/.test(value) && value.split('/').every(part => part && part !== '.' && part !== '..' && part !== '.git');
}
export async function sha256(file) {
  const digest = createHash('sha256');
  let size = 0;
  for await (const chunk of createReadStream(file, { highWaterMark: 1024 * 1024 })) {
    size += chunk.length;
    if (size > maximumBytes) throw new Error('Runtime file exceeds size limit');
    digest.update(chunk);
  }
  return digest.digest('hex');
}
export async function inventory(directory) {
  const files = {};
  const pending = [];
  let count = 0, total = 0;
  if (!(await lstat(directory)).isDirectory()) throw new Error('Invalid runtime directory');
  async function visit(relative) {
    for (const name of readdirSync(path.join(directory, relative)).sort()) {
      const key = relative ? `${relative}/${name}` : name;
      if (!safePath(key) || ++count > maximumEntries) throw new Error('Invalid or oversized runtime tree');
      const file = path.join(directory, key), stat = lstatSync(file);
      if (stat.isSymbolicLink()) throw new Error('Runtime symbolic links are not supported');
      if (stat.isDirectory()) { await visit(key); continue; }
      if (!stat.isFile()) throw new Error('Runtime contains a special file');
      total += stat.size;
      if (total > maximumBytes) throw new Error('Runtime exceeds size limit');
      if (key !== manifestName) pending.push({ key, file, bytes: stat.size });
    }
  }
  await visit('');
  // A small bounded I/O pool avoids one stream startup per serial dependency
  // file. Sorting afterward preserves reproducible manifests regardless of I/O.
  let cursor = 0;
  const hashed = await Promise.allSettled(Array.from({ length: 8 }, async () => {
    while (cursor < pending.length) {
      const entry = pending[cursor++];
      let hash;
      if (entry.bytes <= 1024 * 1024) {
        // Most SDK files are tiny. Bounded direct reads avoid tens of thousands
        // of stream allocations in this build-time validator, with a spare byte
        // to detect growth instead of reading an arbitrarily changed file.
        const fd = openSync(entry.file, 'r'), bytes = Buffer.alloc(entry.bytes + 1);
        try {
          let offset = 0, count;
          while (offset < bytes.length && (count = readSync(fd, bytes, offset, bytes.length - offset, null)) > 0) offset += count;
          if (offset !== entry.bytes) throw new Error('Runtime file size changed during validation');
          hash = createHash('sha256').update(bytes.subarray(0, offset)).digest('hex');
        } finally { closeSync(fd); }
      } else hash = await sha256(entry.file);
      files[entry.key] = { sha256: hash, bytes: entry.bytes };
    }
  }));
  const failure = hashed.find(result => result.status === 'rejected');
  if (failure) throw failure.reason;
  return Object.fromEntries(Object.keys(files).sort().map(key => [key, files[key]]));
}
export function validateMetadata(value, platform, architecture) {
  if (value.schemaVersion !== 1 || value.protocolVersion !== 1 ||
      !/^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$/.test(value.version ?? '') ||
      !/^\d+\.\d+\.\d+$/.test(value.sdkVersion ?? '') ||
      !/^24\.\d+\.\d+$/.test(value.nodeVersion ?? '') ||
      !['darwin', 'win32'].includes(platform) || !['arm64', 'x64'].includes(architecture) ||
      value.platform !== platform || value.architecture !== architecture ||
      !value.files || typeof value.files !== 'object' || Array.isArray(value.files)) throw new Error('Incompatible Pi runtime manifest');
  const entries = Object.entries(value.files);
  if (!entries.length || entries.length > maximumEntries) throw new Error('Invalid Pi runtime inventory');
  let total = 0;
  for (const [key, file] of entries) {
    if (!safePath(key) || key === manifestName || !file || !/^[0-9a-f]{64}$/.test(file.sha256) ||
        !Number.isSafeInteger(file.bytes) || file.bytes < 0) throw new Error('Invalid Pi runtime file');
    total += file.bytes;
  }
  const required = ['src/main.mjs', 'package.json', 'package-lock.json',
    'node_modules/@earendil-works/pi-coding-agent/package.json', platform === 'win32' ? 'bin/node.exe' : 'bin/node'];
  if (platform === 'darwin') required.push('platform/macos.sb');
  if (total > maximumBytes || required.some(file => !Object.hasOwn(value.files, file))) throw new Error('Incomplete Pi runtime');
}
export async function verify(directory, platform, architecture) {
  const manifestFile = path.join(directory, manifestName);
  const stat = await lstat(manifestFile);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 4 * 1024 * 1024) throw new Error('Invalid Pi runtime manifest');
  const value = JSON.parse(await readFile(manifestFile, 'utf8'));
  validateMetadata(value, platform, architecture);
  const files = await inventory(directory);
  const expected = Object.keys(value.files).sort(), actual = Object.keys(files).sort();
  if (JSON.stringify(expected) !== JSON.stringify(actual) || actual.some(key =>
    value.files[key].bytes !== files[key].bytes || value.files[key].sha256 !== files[key].sha256)) throw new Error('Pi runtime content changed');
  const sdk = JSON.parse(await readFile(path.join(directory, 'node_modules/@earendil-works/pi-coding-agent/package.json'), 'utf8'));
  if (sdk.version !== value.sdkVersion) throw new Error('Pi SDK version differs from the manifest');
  return value;
}
export async function seal(directory, metadata) {
  const value = { ...metadata, files: await inventory(directory) };
  validateMetadata(value, value.platform, value.architecture);
  await writeFile(path.join(directory, manifestName), JSON.stringify(value, null, 2) + '\n');
  await verify(directory, value.platform, value.architecture);
  return value;
}
