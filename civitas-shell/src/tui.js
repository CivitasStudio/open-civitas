import React, { useState, useEffect, useCallback, useRef } from 'react';
import { render, Box, Text, useInput, useApp, useStdout } from 'ink';
import { randomUUID } from 'crypto';
import { existsSync, readFileSync } from 'fs';
import { spawn } from 'child_process';
import { homedir, userInfo } from 'os';
import { join } from 'path';
import { GatewayClient } from './gateway.js';
import { loadConfig, clearPendingAuth } from './config.js';
import { LABEL, STATUS, GREETING, DIM } from './theme.js';
import { checkModelPulling } from './setup.js';

const MODEL_PULLING = '/var/lib/civitas/model-pulling';
const MODEL_PULL_POLL_MS = 15_000;

const h = React.createElement;

const SESSION_KEY = 'agent:main:main';
const HISTORY_LIMIT = 50;
const MAX_INPUT_ROWS = 5;
const BRAILLE_FRAMES = ['⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏'];

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

function estimateLines(text, cols) {
  if (!text) return 0;
  const usable = Math.max(cols - 4, 20);
  return text.split('\n').reduce((n, line) => n + Math.max(1, Math.ceil(line.length / usable)), 0);
}

function readAgentName() {
  const base = join(homedir(), '.openclaw', 'workspace');

  // 1. Table-cell schema: | Name | Bob | in IDENTITY.md
  let identity = null;
  try {
    identity = readFileSync(join(base, 'IDENTITY.md'), 'utf8');
    const m = identity.match(/^\|\s*Name\s*\|\s*([^|\n]+?)\s*\|/m);
    if (m) return m[1].trim();
  } catch {}

  // 2. "I am <Name>" prose in SOUL.md
  try {
    const soul = readFileSync(join(base, 'SOUL.md'), 'utf8');
    const m = soul.match(/I am\s+([A-Z][A-Za-z0-9_-]*)/);
    if (m) return m[1];
  } catch {}

  // 3. First heading in IDENTITY.md — sanity-filter file-title headings
  if (identity) {
    const m = identity.match(/^#\s+(.+)$/m);
    if (m) {
      const name = m[1].trim();
      if (!/\.md|Profile|Factual|Document|File|Identity/i.test(name)) return name;
    }
  }

  try { return userInfo().username; } catch {}
  return 'agent';
}

async function spawnBash() {
  const shell = process.env.SHELL || '/bin/bash';
  if (process.stdin.isTTY) {
    try { process.stdin.setRawMode(false); } catch {}
  }
  process.stdin.pause();
  await new Promise((resolve) => {
    const child = spawn(shell, [], {
      stdio: 'inherit',
      env: { ...process.env, TERM: process.env.TERM || 'xterm-256color' },
    });
    const onWinch = () => { try { child.kill('SIGWINCH'); } catch {} };
    process.on('SIGWINCH', onWinch);
    const cleanup = () => { process.off('SIGWINCH', onWinch); resolve(); };
    child.on('exit', cleanup);
    child.on('error', cleanup);
  });
  process.stdin.resume();
}

// --- Components ---

function ThinkingSpinner({ state, startedAt }) {
  const [frame, setFrame] = useState(0);
  const [elapsed, setElapsed] = useState(0);
  useEffect(() => {
    if (state !== 'thinking' && state !== 'streaming') return;
    const spin = setInterval(() => setFrame(f => (f + 1) % BRAILLE_FRAMES.length), 80);
    const tick = setInterval(() => setElapsed(Math.floor((Date.now() - startedAt) / 1000)), 1000);
    return () => { clearInterval(spin); clearInterval(tick); };
  }, [state, startedAt]);
  if (state !== 'thinking' && state !== 'streaming') return null;
  const label = state === 'thinking' ? 'thinking' : 'streaming';
  return h(Text, { color: STATUS }, `${BRAILLE_FRAMES[frame]} ${label} • ${elapsed}s`);
}

function MessageBlock({ role, text }) {
  if (role === 'system') {
    return h(Box, { flexDirection: 'column', marginBottom: 1 },
      h(Box, { paddingLeft: 2 },
        h(Text, { color: DIM, wrap: 'wrap' }, text ?? '')
      )
    );
  }
  const label = role === 'user' ? 'You' : 'Bob';
  return h(Box, { flexDirection: 'column', marginBottom: 1 },
    h(Text, { bold: true, color: LABEL }, label),
    h(Box, { paddingLeft: 2 },
      h(Text, { wrap: 'wrap' }, text ?? '')
    )
  );
}

function GreetingBlock({ text }) {
  return h(Box, { flexDirection: 'column', marginBottom: 1 },
    h(Box, { paddingLeft: 2 },
      h(Text, { color: GREETING, wrap: 'wrap' }, text)
    )
  );
}

function ModelPullingBanner() {
  const [visible, setVisible] = useState(existsSync(MODEL_PULLING));
  useEffect(() => {
    if (!visible) return;
    const id = setInterval(() => {
      if (!existsSync(MODEL_PULLING)) setVisible(false);
    }, MODEL_PULL_POLL_MS);
    return () => clearInterval(id);
  }, [visible]);
  if (!visible) return null;
  return h(Box, { marginBottom: 1 },
    h(Text, { color: 'yellow' },
      '⏳ Gemma still downloading. Check progress: /bash → ollama ps')
  );
}

function App({ gw, sessionId: initialSessionId, history, loginShell, onBashEscape, greeting, greetingLines }) {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const termRows = stdout?.rows ?? 24;
  const termCols = stdout?.columns ?? 80;

  const [messages, setMessages] = useState(history);
  const [inputText, setInputText] = useState('');
  const [inputRows, setInputRows] = useState(1);
  const [status, setStatus] = useState('idle'); // idle | thinking | streaming | error | disconnected
  const [statusMsg, setStatusMsg] = useState('');
  const [scrollOffset, setScrollOffset] = useState(0);
  const [sessionId] = useState(initialSessionId);
  const [runStartedAt, setRunStartedAt] = useState(Date.now());
  const [exitConfirmAt, setExitConfirmAt] = useState(null);
  const exitConfirmTimerRef = useRef(null);
  const activeRunIdRef = useRef(null);
  const messagesRef = useRef(messages);
  useEffect(() => { messagesRef.current = messages; }, [messages]);

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

  const clearExitConfirm = useCallback(() => {
    if (exitConfirmTimerRef.current) clearTimeout(exitConfirmTimerRef.current);
    exitConfirmTimerRef.current = null;
    setExitConfirmAt(null);
  }, []);

  const addSystemMessage = useCallback((text) => {
    setMessages(prev => [...prev, { id: randomUUID(), role: 'system', text }]);
    setScrollOffset(0);
  }, []);

  const doExit = useCallback(() => {
    if (loginShell) {
      addSystemMessage('exit is disabled in login-shell mode');
      return;
    }
    exit();
  }, [loginShell, exit, addSystemMessage]);

  // Returns true if command was handled locally; false means forward to gateway.
  const handleSlashCommand = useCallback((raw) => {
    const cmd = raw.slice(1).split(/\s+/)[0].toLowerCase();

    if (cmd === 'clear') {
      // Alias to gateway /new — destructive reset, persists across launches.
      // Fire-and-forget; local clear always happens regardless.
      gw.request('chat.send', {
        sessionKey: SESSION_KEY,
        sessionId,
        message: '/new',
        idempotencyKey: randomUUID(),
      }, { timeoutMs: 10_000 }).catch(() => {});
      setMessages([]);
      setScrollOffset(0);
      return true;
    }

    if (cmd === 'exit') {
      doExit();
      return true;
    }

    if (cmd === 'bash') {
      onBashEscape(messagesRef.current);
      exit();
      return true;
    }

    return false; // pass through to gateway
  }, [gw, sessionId, doExit, exit, onBashEscape]);

  const sendMessage = useCallback(() => {
    const raw = inputText.trim();
    if (!raw) return;

    // Slash command: starts with / but not \/ (escaped literal)
    if (raw.startsWith('/') && !raw.startsWith('\\/')) {
      const handled = handleSlashCommand(raw);
      if (handled) {
        setInputText('');
        setInputRows(1);
        return;
      }
      // Not a local command — fall through to forward to gateway as-is
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
    setRunStartedAt(Date.now());
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
    if (key.ctrl && input === 'c') {
      if (status === 'thinking' || status === 'streaming') {
        abortRun();
        return;
      }
      // Idle: double Ctrl-C to exit
      const now = Date.now();
      if (exitConfirmAt !== null && now - exitConfirmAt < 2000) {
        clearExitConfirm();
        doExit();
      } else {
        clearExitConfirm();
        setExitConfirmAt(now);
        exitConfirmTimerRef.current = setTimeout(() => {
          setExitConfirmAt(null);
          exitConfirmTimerRef.current = null;
        }, 2000);
      }
      return;
    }

    // Any non-Ctrl-C key dismisses the exit-confirm hint
    if (exitConfirmAt !== null) clearExitConfirm();

    if (key.ctrl && input === 'l') {
      setMessages([]);
      setScrollOffset(0);
      return;
    }
    if (key.ctrl && input === 'd') return;

    if (key.pageUp) { setScrollOffset(o => o + 4); return; }
    if (key.pageDown) { setScrollOffset(o => Math.max(0, o - 4)); return; }

    if (key.return && key.shift) {
      setInputText(t => t + '\n');
      setInputRows(r => Math.min(r + 1, MAX_INPUT_ROWS));
      return;
    }
    if (key.return) { sendMessage(); return; }

    if (key.backspace || key.delete) {
      setInputText(t => t.slice(0, -1));
      setInputRows(r => {
        const newlines = inputText.slice(0, -1).split('\n').length;
        return Math.max(1, Math.min(r, newlines));
      });
      return;
    }

    if (input && !key.ctrl && !key.meta) setInputText(t => t + input);
  });

  // --- Viewport calculation ---
  const showingStatus = status !== 'idle' || exitConfirmAt !== null;
  const statusHeight = showingStatus ? 1 : 0;
  const inputHeight = inputRows;
  const greetingHeight = greetingLines + 1; // lines of text + marginBottom
  const transcriptHeight = Math.max(3, termRows - inputHeight - statusHeight - greetingHeight - 1);

  const endIdx = messages.length - scrollOffset;
  let startIdx = endIdx;
  let linesUsed = 0;
  while (startIdx > 0) {
    const m = messages[startIdx - 1];
    const labelLines = m.role === 'system' ? 0 : 1;
    const mLines = labelLines + 1 + estimateLines(m.text, termCols);
    if (linesUsed + mLines > transcriptHeight) break;
    linesUsed += mLines;
    startIdx--;
  }
  const visibleMessages = messages.slice(Math.max(0, startIdx), Math.max(0, endIdx));

  const inputLines = inputText.split('\n');
  const displayInput = inputLines[inputLines.length - 1] + '█';

  // Build status line content
  let statusContent = null;
  if (status === 'thinking' || status === 'streaming') {
    statusContent = h(ThinkingSpinner, { state: status, startedAt: runStartedAt });
  } else if (status === 'error' || status === 'disconnected') {
    statusContent = h(Text, { color: 'red' }, statusMsg);
  } else if (exitConfirmAt !== null) {
    statusContent = h(Text, { color: DIM }, '(Ctrl-C again to exit)');
  }

  return h(Box, { flexDirection: 'column' },
    h(GreetingBlock, { text: greeting }),
    h(ModelPullingBanner),
    h(Box, { flexDirection: 'column', height: transcriptHeight, overflow: 'hidden' },
      ...visibleMessages.map(m =>
        h(MessageBlock, { key: m.id, role: m.role, text: m.text })
      )
    ),
    showingStatus && h(Box, null, statusContent),
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
  // Clear civitas.pendingAuth on first successful connection — auth is done.
  if (cfg.civitas?.pendingAuth && cfg._cfgPath) {
    clearPendingAuth(cfg._cfgPath);
  }

  const histResult = await gw.request('chat.history', {
    sessionKey: SESSION_KEY,
    limit: HISTORY_LIMIT,
  });
  const sessionId = histResult?.sessionId;

  const agentName = readAgentName();
  const model = cfg.model ?? 'unknown';
  const greetingText =
    `Hi, I'm ${agentName}.\n\n` +
    `- Using: ${model}.\n` +
    `- Gateway: connected (${cfg.gatewayUrl}).\n` +
    `- Session: ${SESSION_KEY}, persisted across launches.`;
  const greetingLines = greetingText.split('\n').length;

  // currentMessages carries transcript across /bash escapes (ink unmount/remount).
  let currentMessages = (histResult?.messages ?? [])
    .filter(m => m.role === 'user' || m.role === 'assistant')
    // Collapse consecutive identical user messages (gateway LLM-idle retry artifacts)
    .reduce((acc, msg) => {
      if (acc.length > 0) {
        const last = acc[acc.length - 1];
        if (msg.role === 'user' && last.role === 'user' && extractText(msg) === extractText(last)) {
          return acc;
        }
      }
      acc.push(msg);
      return acc;
    }, [])
    .map((m, i) => ({
      id: String(i),
      role: m.role,
      text: extractText(m),
      isStreaming: false,
    }));

  while (true) {
    let bashEscaped = false;

    const { waitUntilExit } = render(
      h(App, {
        gw,
        sessionId,
        history: currentMessages,
        loginShell: opts.loginShell ?? false,
        onBashEscape: (msgs) => {
          bashEscaped = true;
          currentMessages = msgs;
        },
        greeting: greetingText,
        greetingLines,
      }),
      { exitOnCtrlC: false }
    );

    await waitUntilExit();

    if (!bashEscaped) break; // normal exit (/exit or double Ctrl-C)

    await spawnBash();
    // loop to re-render ink with preserved transcript
  }

  gw.close();
}
