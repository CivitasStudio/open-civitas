// First-boot setup checks: pending-auth framed prompt + model-pulling status.
// Called from bin/civitas-shell.js before launchTUI() when in --login-shell mode.

import { existsSync } from 'fs';
import { createInterface } from 'readline';

const MODEL_PULLING = '/var/lib/civitas/model-pulling';

// Framed box prompt (printed to stdout, no ink/React required).
function frameBox(lines) {
  const width = 68;
  const inner = width - 2;
  const top    = '┌' + '─'.repeat(inner) + '┐';
  const bottom = '└' + '─'.repeat(inner) + '┘';
  const pad = (s) => '│  ' + s.padEnd(inner - 2) + '  │';
  const blank = pad('');

  process.stdout.write('\n');
  process.stdout.write(top + '\n');
  for (const line of lines) {
    if (line === '') {
      process.stdout.write(blank + '\n');
    } else {
      // Wrap long lines naively at inner - 4 chars.
      const max = inner - 4;
      if (line.length <= max) {
        process.stdout.write(pad(line) + '\n');
      } else {
        for (let i = 0; i < line.length; i += max) {
          process.stdout.write(pad(line.slice(i, i + max)) + '\n');
        }
      }
    }
  }
  process.stdout.write(bottom + '\n');
  process.stdout.write('\n');
}

function waitForEnter() {
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    rl.question('  Press Enter to continue... ', () => {
      rl.close();
      resolve();
    });
  });
}

// Returns the string that would be printed by --preflight-check, without
// prompting.  Used by the test harness to verify the framing text.
export function pendingAuthText(agentName, civitas) {
  const authType = civitas?.pendingAuth;
  const provider = civitas?.provider ?? '';
  if (!authType) return null;

  const lines = [];
  lines.push('One-time setup');
  lines.push('');
  if (authType === 'oauth') {
    lines.push(`Hi, I'm ${agentName}. To finish setup, authenticate with Anthropic:`);
    lines.push('');
    lines.push('  Type /bash, then run:');
    lines.push('    claude login --claudeai');
    lines.push('  Then type exit to come back.');
  } else {
    const providerLabel = provider || 'your provider';
    lines.push(`Hi, I'm ${agentName}. To finish setup, set your API key:`);
    lines.push('');
    lines.push('  Type /bash, then run:');
    lines.push(`    openclaw config set providers.${providerLabel}.apiKey YOUR_KEY`);
    lines.push('  Then type exit to come back.');
  }
  lines.push('');
  return lines;
}

export async function checkPendingAuth(agentName, civitas) {
  const lines = pendingAuthText(agentName, civitas);
  if (!lines) return;
  frameBox(lines);
  await waitForEnter();
}

export function checkModelPulling() {
  if (!existsSync(MODEL_PULLING)) return false;
  return true;
}

// Print the model-pulling notice (no blocking — just informational output).
export function printModelPullingNotice() {
  process.stdout.write(
    '\n  ⏳ Still downloading Gemma (~8 GB). Check progress: /bash → ollama ps\n' +
    '     I\'ll be ready when the pull completes.\n\n'
  );
}
