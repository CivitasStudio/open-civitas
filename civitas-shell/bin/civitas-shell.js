#!/usr/bin/env node
import { noninteractiveSend } from '../src/noninteractive.js';
import { launchTUI } from '../src/tui.js';

const args = process.argv.slice(2);

function usage() {
  process.stderr.write('Usage: civitas-shell [--noninteractive --send <message>]\n');
  process.exit(1);
}

const niIdx = args.indexOf('--noninteractive');

if (niIdx !== -1) {
  // Non-interactive mode
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
  // Interactive TUI mode (default)
  launchTUI().catch((err) => {
    process.stderr.write(`Error: ${err.message}\n`);
    process.exit(1);
  });
}
