// JSONL is the only worker/host transport. No credentials or raw provider errors
// are written to diagnostics; the host owns filesystem and process capabilities.
export const PROTOCOL_VERSION = 1;
export const LIMITS = Object.freeze({
  frameBytes: 4 * 1024 * 1024,
  pendingBytes: 8 * 1024 * 1024,
  textChars: 1_000_000,
  toolCalls: 200,
  toolTimeoutMs: 60_000,
  verificationTimeoutMs: 180_000,
  runTimeoutMs: 600_000,
});

export class BridgeError extends Error {
  constructor(code, message = code) { super(message); this.code = code; }
}

export function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

export function requireValue(condition, code = 'invalid_request') {
  if (!condition) throw new BridgeError(code);
}

export function identifier(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_.:-]{1,128}$/.test(value);
}

export function relativePath(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 4096 &&
    !/[\\:\x00-\x1f]/.test(value) &&
    value.split('/').every(part => part && part !== '.' && part !== '..' && part.toLowerCase() !== '.git');
}

export function boundedInteger(value, fallback, min, max) {
  if (value === undefined) return fallback;
  requireValue(Number.isSafeInteger(value) && value >= min && value <= max);
  return value;
}

// Split on LF only: U+2028/U+2029 may legitimately occur in source strings.
export class JSONLines {
  #pending = Buffer.alloc(0);
  push(chunk) {
    this.#pending = Buffer.concat([this.#pending, chunk]);
    const values = [];
    for (;;) {
      const end = this.#pending.indexOf(10);
      if (end < 0) break;
      requireValue(end <= LIMITS.frameBytes, 'frame_too_large');
      const line = this.#pending.subarray(0, end);
      this.#pending = this.#pending.subarray(end + 1);
      if (!line.length) continue;
      let value;
      try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line)); }
      catch { throw new BridgeError('invalid_json'); }
      requireValue(object(value) && typeof value.type === 'string');
      values.push(value);
    }
    requireValue(this.#pending.length <= LIMITS.frameBytes, 'frame_too_large');
    return values;
  }
  finish() { requireValue(this.#pending.length === 0, 'truncated_frame'); }
}

export class JSONWriter {
  #stream;
  #secrets = [];
  #sequence = 0;
  constructor(stream) { this.#stream = stream; }
  protect(secret) { if (secret) this.#secrets.push(secret); }
  send(value) {
    // Redact before JSON encoding so credentials with quotes/backslashes are safe.
    const sanitized = JSON.parse(JSON.stringify(value, (_key, entry) => {
      if (typeof entry !== 'string') return entry;
      for (const secret of this.#secrets) entry = entry.replaceAll(secret, '[redacted]');
      return entry;
    }));
    const data = JSON.stringify({ protocolVersion: PROTOCOL_VERSION, sequence: ++this.#sequence, ...sanitized }) + '\n';
    requireValue(Buffer.byteLength(data) <= LIMITS.frameBytes, 'frame_too_large');
    requireValue(this.#stream.writableLength + Buffer.byteLength(data) <= LIMITS.pendingBytes, 'transport_overflow');
    this.#stream.write(data);
  }
}
