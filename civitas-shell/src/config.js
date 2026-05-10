import { readFileSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';

export function loadConfig() {
  const cfgPath = join(homedir(), '.openclaw', 'openclaw.json');
  let raw;
  try {
    raw = JSON.parse(readFileSync(cfgPath, 'utf8'));
  } catch (err) {
    throw new Error(`Cannot read ${cfgPath}: ${err.message}`);
  }
  const token = raw?.gateway?.auth?.token ?? null;
  const password = raw?.gateway?.auth?.password ?? null;
  if (!token && !password) {
    throw new Error('No gateway.auth.token or gateway.auth.password in openclaw.json');
  }
  const gatewayUrl = raw?.gateway?.remote?.url ?? 'ws://127.0.0.1:18789';
  const model = raw?.agents?.defaults?.model?.primary ?? null;
  return { token, password, gatewayUrl, model };
}
