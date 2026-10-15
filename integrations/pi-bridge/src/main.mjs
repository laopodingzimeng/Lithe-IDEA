import { JSONLines, JSONWriter, BridgeError, identifier } from './protocol.mjs';
import { WorkerController } from './controller.mjs';

const writer = new JSONWriter(process.stdout);
const frames = new JSONLines();
const controller = new WorkerController(value => writer.send(value), process.cwd());
let ending = false;

async function stop(exitCode) {
  if (ending) return;
  ending = true;
  process.stdin.pause();
  // The host also has a process-group watchdog. This deadline covers a broken SDK
  // abort, disconnected stdin or a peer that has stopped draining stdout.
  const watchdog = setTimeout(() => process.exit(exitCode || 1), 5000);
  try { await controller.close(); }
  finally {
    process.exitCode = exitCode;
    process.stdout.end(() => { clearTimeout(watchdog); process.exit(exitCode); });
  }
}

function fail(error, requestId) {
  try { writer.send({ type: 'error', ...(identifier(requestId) ? { requestId } : {}),
    code: error instanceof BridgeError ? error.code : 'worker_failed' }); }
  catch { void stop(1); }
}

process.stdin.on('data', chunk => {
  if (ending) return;
  try {
    for (const message of frames.push(chunk)) {
      if (message.type === 'initialize') {
        writer.protect(message.configuration?.model?.apiKey);
        for (const header of Object.values(message.configuration?.model?.headers ?? {})) writer.protect(header);
      }
      // prompt returns when accepted. Tool replies/cancel remain responsive while
      // Pi owns the asynchronous tool loop; no host command queue waits on it.
      void controller.accept(message).then(() => {
        if (message.type === 'shutdown') void stop(0);
      }).catch(error => fail(error, message.requestId));
    }
  } catch (error) { fail(error); void stop(1); }
});
process.stdin.on('end', () => {
  try { frames.finish(); void stop(0); }
  catch (error) { fail(error); void stop(1); }
});
process.stdin.on('error', () => void stop(1));
process.stdout.on('error', () => void stop(1));
process.on('SIGTERM', () => void stop(0));
process.on('SIGINT', () => void stop(0));
process.on('unhandledRejection', () => { fail(new BridgeError('worker_failed')); void stop(1); });
