import React, { useState, useEffect, useCallback, useRef } from 'react';
import { render, Box, Text, useInput, useApp, useStdout } from 'ink';
import { randomUUID } from 'crypto';
import { GatewayClient } from './gateway.js';
import { loadConfig } from './config.js';

const h = React.createElement;

// FIXME(v1): session key hardcoded; v1 multi-agent story needs this configurable
const SESSION_KEY = 'agent:main:main';
const HISTORY_LIMIT = 50;
const MAX_INPUT_ROWS = 5;

// Gateway deltas are cumulative — each delta payload contains the full text so
// far, not just the newest fragment. Callers must slice to get the increment.
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

// Rough line-count estimate for a string at a given terminal width.
function estimateLines(text, cols) {
  if (!text) return 0;
  const usable = Math.max(cols - 4, 20); // 2-space indent + margin
  return text.split('\n').reduce((n, line) => n + Math.max(1, Math.ceil(line.length / usable)), 0);
}

// --- Components ---

function ThinkingDots({ state }) {
  const [frame, setFrame] = useState(0);
  const frames = ['●', '●●', '●●●'];
  useEffect(() => {
    if (state !== 'thinking' && state !== 'streaming') return;
    const t = setInterval(() => setFrame(f => (f + 1) % frames.length), 400);
    return () => clearInterval(t);
  }, [state]);
  if (state !== 'thinking' && state !== 'streaming') return null;
  const label = state === 'thinking' ? 'thinking' : 'streaming';
  return h(Text, { dimColor: true }, `${label} ${frames[frame]}`);
}

function MessageBlock({ role, text }) {
  if (role === 'system') {
    return h(Box, { flexDirection: 'column', marginBottom: 1 },
      h(Box, { paddingLeft: 2 },
        h(Text, { dimColor: true, wrap: 'wrap' }, text ?? '')
      )
    );
  }
  const label = role === 'user' ? 'You' : 'Bob';
  return h(Box, { flexDirection: 'column', marginBottom: 1 },
    h(Text, { bold: true }, label),
    h(Box, { paddingLeft: 2 },
      h(Text, { wrap: 'wrap' }, text ?? '')
    )
  );
}

function App({ gw, sessionId: initialSessionId, history, loginShell }) {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const termRows = stdout?.rows ?? 24;
  const termCols = stdout?.columns ?? 80;

  const [messages, setMessages] = useState(history);
  const [inputText, setInputText] = useState('');
  const [inputRows, setInputRows] = useState(1);
  const [status, setStatus] = useState('idle'); // idle | thinking | streaming | error | disconnected
  const [statusMsg, setStatusMsg] = useState('');
  const [scrollOffset, setScrollOffset] = useState(0); // messages from end to skip
  const [sessionId] = useState(initialSessionId);
  const activeRunIdRef = useRef(null);

  // Gateway event wiring
  useEffect(() => {
    const onEvent = (frame) => {
      if (frame.event !== 'chat') return;
      const evt = frame.payload;
      if (!evt || evt.sessionKey !== SESSION_KEY) return;

      if (evt.state === 'delta') {
        const text = extractText(evt.message);
        if (!text) return;
        setMessages(prev => {
          const idx = prev.findIndex(m => m.runId === evt.runId);
          if (idx === -1) {
            // New streaming block
            return [...prev, { id: evt.runId, role: 'assistant', text, runId: evt.runId, isStreaming: true }];
          }
          const next = [...prev];
          // Deltas are cumulative — only advance if payload is longer
          if (text.length > (next[idx].text?.length ?? 0)) {
            next[idx] = { ...next[idx], text };
          }
          return next;
        });
        setStatus('streaming');
        setScrollOffset(0);
      }

      if (evt.state === 'final') {
        const text = extractText(evt.message);
        setMessages(prev => {
          const idx = prev.findIndex(m => m.runId === evt.runId);
          if (idx === -1) return prev;
          const next = [...prev];
          next[idx] = { ...next[idx], text: text || next[idx].text, isStreaming: false };
          return next;
        });
        setStatus('idle');
        setStatusMsg('');
        activeRunIdRef.current = null;
        setScrollOffset(0);
      }

      if (evt.state === 'aborted') {
        setMessages(prev => prev.map(m =>
          m.runId === evt.runId ? { ...m, text: (m.text ?? '') + ' [aborted]', isStreaming: false } : m
        ));
        setStatus('idle');
        setStatusMsg('');
        activeRunIdRef.current = null;
      }

      if (evt.state === 'error') {
        setMessages(prev => prev.map(m =>
          m.runId === evt.runId ? { ...m, isStreaming: false } : m
        ));
        setStatus('error');
        setStatusMsg(evt.errorMessage || 'run error');
        activeRunIdRef.current = null;
      }
    };

    const onClose = () => {
      setStatus('disconnected');
      setStatusMsg('gateway unreachable — retrying…');
    };

    const onReconnect = () => {
      setStatus('idle');
      setStatusMsg('');
    };

    gw.on('event', onEvent);
    gw.on('close', onClose);
    gw.on('reconnect', onReconnect);
    return () => { gw.off('event', onEvent); gw.off('close', onClose); gw.off('reconnect', onReconnect); };
  }, [gw]);

  const addSystemMessage = useCallback((text) => {
    setMessages(prev => [...prev, { id: randomUUID(), role: 'system', text }]);
    setScrollOffset(0);
  }, []);

  const handleSlashCommand = useCallback((raw) => {
    // First word after the slash, lower-cased. Args ignored in v0.
    const cmd = raw.slice(1).split(/\s+/)[0].toLowerCase();

    if (cmd === 'clear') {
      setMessages([]);
      setScrollOffset(0);
      return;
    }

    if (cmd === 'help') {
      addSystemMessage(
        '/clear   clear visible transcript\n' +
        '/model   show current model and gateway status\n' +
        '/help    show this message\n' +
        '/exit    exit civitas-shell\n' +
        '  tip: prefix / with \\ to send literally to agent (e.g. \\/help)'
      );
      return;
    }

    if (cmd === 'exit') {
      if (loginShell) {
        addSystemMessage('/exit is disabled in login-shell mode');
        return;
      }
      exit();
      return;
    }

    if (cmd === 'model') {
      const gwStatus = status === 'disconnected' ? 'disconnected' : 'connected';
      gw.request('session.status', { sessionKey: SESSION_KEY }, { timeoutMs: 5_000 })
        .then(info => {
          const model = info?.model || info?.agentModel || info?.runtime?.model || 'unknown';
          addSystemMessage(`gateway: ${gwStatus}  session: ${SESSION_KEY}  model: ${model}`);
        })
        .catch(() => {
          addSystemMessage(`gateway: ${gwStatus}  session: ${SESSION_KEY}  model: unknown`);
        });
      return;
    }

    addSystemMessage(`unknown command: ${raw}  (type /help for commands)`);
  }, [gw, status, loginShell, exit, addSystemMessage]);

  const sendMessage = useCallback(() => {
    const raw = inputText.trim();
    if (!raw) return;

    // Slash command: starts with / but not \/ (escaped literal)
    if (raw.startsWith('/') && !raw.startsWith('\\/')) {
      setInputText('');
      setInputRows(1);
      handleSlashCommand(raw);
      return;
    }

    if (status === 'thinking' || status === 'streaming') return;

    // Unescape \/ → / before sending to agent
    const text = raw.startsWith('\\/') ? raw.slice(1) : raw;

    const idempotencyKey = randomUUID();
    activeRunIdRef.current = idempotencyKey;

    setMessages(prev => [...prev, { id: idempotencyKey + ':user', role: 'user', text }]);
    setInputText('');
    setInputRows(1);
    setStatus('thinking');
    setScrollOffset(0);

    gw.request('chat.send', {
      sessionKey: SESSION_KEY,
      sessionId,
      message: text,
      idempotencyKey,
    }, { timeoutMs: 30_000 }).catch((err) => {
      setStatus('error');
      setStatusMsg(err.message);
    });
  }, [inputText, status, gw, sessionId, handleSlashCommand]);

  const abortRun = useCallback(() => {
    const runId = activeRunIdRef.current;
    if (!runId) return;
    gw.request('chat.abort', { sessionKey: SESSION_KEY, runId }, { timeoutMs: 5_000 }).catch(() => {});
    setStatus('idle');
    setStatusMsg('');
    activeRunIdRef.current = null;
  }, [gw]);

  useInput((input, key) => {
    // Ctrl-C: abort in-flight generation; do not exit
    if (key.ctrl && input === 'c') {
      if (status === 'thinking' || status === 'streaming') abortRun();
      return;
    }
    // Ctrl-L: clear visible transcript (gateway history unaffected)
    if (key.ctrl && input === 'l') {
      setMessages([]);
      setScrollOffset(0);
      return;
    }
    // Ctrl-D on empty: no-op
    if (key.ctrl && input === 'd') return;

    // PgUp / PgDn (scroll in message units)
    if (key.pageUp) { setScrollOffset(o => o + 4); return; }
    if (key.pageDown) { setScrollOffset(o => Math.max(0, o - 4)); return; }

    // Shift-Enter: insert newline, grow input up to MAX_INPUT_ROWS
    if (key.return && key.shift) {
      setInputText(t => t + '\n');
      setInputRows(r => Math.min(r + 1, MAX_INPUT_ROWS));
      return;
    }
    // Enter: send or dispatch slash command
    if (key.return) { sendMessage(); return; }

    // Backspace / Delete
    if (key.backspace || key.delete) {
      setInputText(t => t.slice(0, -1));
      // shrink input rows if we deleted a newline
      setInputRows(r => {
        const newlines = inputText.slice(0, -1).split('\n').length;
        return Math.max(1, Math.min(r, newlines));
      });
      return;
    }

    // Printable character
    if (input && !key.ctrl && !key.meta) setInputText(t => t + input);
  });

  // --- Viewport calculation ---
  const hasStatus = status !== 'idle';
  const statusHeight = hasStatus ? 1 : 0;
  // input: prompt line + extra rows beyond first
  const inputHeight = inputRows;
  const transcriptHeight = Math.max(3, termRows - inputHeight - statusHeight - 1);

  // Build a line-count-aware visible slice from the end of messages,
  // respecting scrollOffset (in message units).
  const endIdx = messages.length - scrollOffset;
  let startIdx = endIdx;
  let linesUsed = 0;
  while (startIdx > 0) {
    const m = messages[startIdx - 1];
    // system messages: no label line, just content
    const labelLines = m.role === 'system' ? 0 : 1;
    const mLines = labelLines + 1 + estimateLines(m.text, termCols); // label + blank + content
    if (linesUsed + mLines > transcriptHeight) break;
    linesUsed += mLines;
    startIdx--;
  }
  const visibleMessages = messages.slice(Math.max(0, startIdx), Math.max(0, endIdx));

  // Input display: show last line of multi-line input with a block cursor
  const inputLines = inputText.split('\n');
  const displayInput = inputLines[inputLines.length - 1] + '█';

  return h(Box, { flexDirection: 'column' },
    // Transcript
    h(Box, { flexDirection: 'column', height: transcriptHeight, overflow: 'hidden' },
      ...visibleMessages.map(m =>
        h(MessageBlock, { key: m.id, role: m.role, text: m.text })
      )
    ),
    // Status overlay (thinking animation or error)
    hasStatus && h(Box, null,
      status === 'thinking' || status === 'streaming'
        ? h(ThinkingDots, { state: status })
        : h(Text, { color: 'red' }, statusMsg)
    ),
    // Input row
    h(Box, null,
      h(Text, { color: 'green' }, '> '),
      h(Text, null, displayInput)
    )
  );
}

export async function launchTUI(opts = {}) {
  const cfg = loadConfig();
  const gw = new GatewayClient({
    url: cfg.gatewayUrl,
    token: cfg.token,
    password: cfg.password,
    timeoutMs: null,
  });

  await gw.connect();

  const histResult = await gw.request('chat.history', {
    sessionKey: SESSION_KEY,
    limit: HISTORY_LIMIT,
  });
  const sessionId = histResult?.sessionId;

  const history = (histResult?.messages ?? [])
    .filter(m => m.role === 'user' || m.role === 'assistant')
    .map((m, i) => ({
      id: String(i),
      role: m.role,
      text: extractText(m),
      isStreaming: false,
    }));

  const { waitUntilExit } = render(
    h(App, { gw, sessionId, history, loginShell: opts.loginShell ?? false }),
    { exitOnCtrlC: false }
  );
  await waitUntilExit();
  gw.close();
}
