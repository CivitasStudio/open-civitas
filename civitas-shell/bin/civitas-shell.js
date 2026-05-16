#!/usr/bin/env node
import { noninteractiveSend } from '../src/noninteractive.js';
import { launchTUI } from '../src/tui.js';
import { loadConfig } from '../src/config.js';
import { checkPendingAuth, checkModelPulling, pendingAuthText, printModelPullingNotice } from '../src/setup.js';

const args = process.argv.slice(2);

function usage() {
  process.stderr.write(
    'Usage: civitas-shell [--login-shell] [--noninteractive --send <message>] [--preflight-check]\n'
  );
  process.exit(1);
}

// --preflight-check: print the pending-auth frame to stdout and exit.
// Used by the test harness to verify framing without connecting to the gateway.
if (args.includes('--preflight-check')) {
  let cfg;
  try { cfg = loadConfig(); } catch (err) {
    process.stderr.write(`Error: ${err.message}\n`);
    process.exit(1);
  }
  const agentName = cfg.civitas?.agentName ?? process.env.USER ?? 'agent';
  const lines = pendingAuthText(agentName, cfg.civitas);
  if (!lines) {
    process.stdout.write('No pending auth setup.\n');
  } else {
    const width = 68;
    const inner = width - 2;
    const pad = (s) => '│  ' + s.padEnd(inner - 2) + '  │';
    process.stdout.write('\n┌' + '─'.repeat(inner) + '┐\n');
    for (const line of lines) {
      process.stdout.write((line === '' ? pad('') : pad(line)) + '\n');
    }
    process.stdout.write('└' + '─'.repeat(inner) + '┘\n\n');
  }
  process.exit(0);
}

if (args.includes('--noninteractive')) {
  const sendIdx = args.indexOf('--send');
  if (sendIdx === -1) usage();
  const message = args[sendIdx + 1];
  if (!message) {
    process.stderr.write('Error: --send requires a message argument\n');
    usage();
  }
  noninteractiveSend(message).catch((err) => {
    process.stderr.write(`Error: ${err.message}\n`);
    process.exit(1);
  });
} else {
  const loginShell = args.includes('--login-shell');

  (async () => {
    if (loginShell) {
      // Show first-boot setup prompts if needed (blocking, before ink starts).
      let cfg;
      try { cfg = loadConfig(); } catch { cfg = {}; }
      const agentName = cfg.civitas?.agentName ?? process.env.USER ?? 'agent';
      await checkPendingAuth(agentName, cfg.civitas ?? {});
      if (checkModelPulling()) printModelPullingNotice();
    }
    launchTUI({ loginShell }).catch((err) => {
      process.stderr.write(`Error: ${err.message}\n`);
      process.exit(1);
    });
  })();
}
