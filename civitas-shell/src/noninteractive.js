import { randomUUID } from 'crypto';
import { GatewayClient } from './gateway.js';
import { loadConfig } from './config.js';

// FIXME(v1): session key hardcoded; v1 multi-agent story needs this configurable
const SESSION_KEY = 'agent:main:main';

function extractText(message) {
  if (!message) return '';
  const content = message.content;
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .filter(b => b.type === 'text' && typeof b.text === 'string')
      .map(b => b.text)
      .join('');
  }
  return '';
}

export async function noninteractiveSend(text) {
  const cfg = loadConfig();
  const gw = new GatewayClient({ url: cfg.gatewayUrl, token: cfg.token, password: cfg.password });

  await gw.connect();

  // fetch sessionId for persistent session reuse
  const historyResult = await gw.request('chat.history', {
    sessionKey: SESSION_KEY,
    limit: 1,
  });
  const sessionId = historyResult?.sessionId ?? undefined;

  // idempotencyKey becomes the runId in chat events — used for precise filtering
  const idempotencyKey = randomUUID();

  let lastText = '';
  let exitResolve, exitReject;
  const done = new Promise((res, rej) => { exitResolve = res; exitReject = rej; });

  gw.on('close', () => {
    exitReject(new Error('gateway connection closed before run completed'));
  });

  gw.on('event', (frame) => {
    if (frame.event !== 'chat') return;
    const evt = frame.payload;
    if (!evt || evt.sessionKey !== SESSION_KEY) return;
    if (evt.runId !== idempotencyKey) return;

    if (evt.state === 'delta') {
      const text = extractText(evt.message);
      // Gateway deltas are cumulative, not incremental — each delta contains
      // the full text so far. Only write the newly-appended portion.
      if (text && text.length > lastText.length) {
        process.stdout.write(text.slice(lastText.length));
        lastText = text;
      }
    }
    if (evt.state === 'final') {
      const text = extractText(evt.message);
      if (text && text.length > lastText.length) {
        process.stdout.write(text.slice(lastText.length));
      }
      process.stdout.write('\n');
      exitResolve();
    }
    if (evt.state === 'aborted') {
      process.stdout.write('\n[aborted]\n');
      exitResolve();
    }
    if (evt.state === 'error') {
      exitReject(new Error(evt.errorMessage ?? 'run error'));
    }
  });

  // Fire chat.send — gateway may ACK with {status:"accepted"} then stream events.
  // Don't await the final frame; drive completion via the event stream instead.
  gw.request('chat.send', {
    sessionKey: SESSION_KEY,
    sessionId,
    message: text,
    idempotencyKey,
  }, { timeoutMs: 30_000 }).catch((err) => exitReject(err));

  await done;
  gw.close();
}
