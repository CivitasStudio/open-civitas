# Installation Guide

## Prerequisites

- **Ubuntu 26.04 LTS Server** (only supported OS in v0).
- **Passwordless sudo** — add your user to sudoers with `NOPASSWD`:
  ```bash
  echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/99-$USER
  ```
- **Internet connection** — installer fetches packages and OpenClaw from npm.

## Running the Installer

### Option 1: Pipe from GitHub (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/civitasstudio/open-civitas/main/install.sh | bash
```

The installer runs interactively — you'll be prompted for:
- Agent name (display name for your agent)
- Agent role (one-line description of what it does)
- Your name (the principal/owner)
- Whether to install Claude Code CLI
- Whether to install Ollama

### Option 2: Clone and Run

```bash
git clone https://github.com/civitasstudio/open-civitas.git
cd open-civitas
./install.sh
```

### Option 3: Non-Interactive (CI/Automation)

```bash
./install.sh --non-interactive \
  --agent-name "TestAgent" \
  --agent-role "Smoke test agent" \
  --user "CI" \
  --claude-cli n \
  --ollama n
```

## What Happens During Install

1. **Preflight checks** — detects OS, validates passwordless sudo. If `~/.openclaw/` exists, archives it to `~/.openclaw.bak.<timestamp>`.

2. **Substrate** — installs Node LTS, OpenClaw, systemd user unit, and enables linger (persistent login session).

3. **Workspace** — creates `~/.openclaw/workspace/` with:
   - `AGENTS.md` — operations manual (your notes)
   - `SOUL.md` — agent persona/voice
   - `IDENTITY.md` — factual identity table
   - `USER.md` — information about you (principal)
   - `MEMORY.md` — long-term memory index
   - `HEARTBEAT.md` — heartbeat task (empty by default = no API calls)
   - `openclaw.json` — auto-generated config (workspace path is explicit + absolute)

4. **Claude Code CLI** (optional) — installs CLI and walks through OAuth login. Skipped if already authenticated.

5. **Ollama** (optional) — installs Ollama, detects GPU, suggests and pulls a model (`gemma4:26b` for ≥16GB VRAM, `gemma4:e4b` otherwise).

6. **Gateway start** — starts `openclaw-gateway.service` and validates health endpoint (`http://localhost:18789/health` → 200).

7. **Hand-off** — prints next step: `openclaw setup` to configure your channel and provider.

## Logs

All output is logged to `~/.openclaw/install.log`. If something goes wrong, check this file:

```bash
tail -100 ~/.openclaw/install.log
```

## Verifying the Install

After the installer completes, check:

```bash
# Gateway status
systemctl --user status openclaw-gateway

# Linger enabled
loginctl show-user $USER | grep Linger

# Workspace files
ls ~/.openclaw/workspace/

# Health check
curl -s http://localhost:18789/health

# Config validity
cat ~/.openclaw/openclaw.json | jq .
```

Run the smoke test script:

```bash
./scripts/smoke-test.sh
```

## Next Steps

1. **Configure your channel and provider:**
   ```bash
   openclaw setup
   ```

   Choose Telegram, WhatsApp, web, or another channel. Then select your provider (Anthropic Claude, Ollama, OpenAI, etc.).

2. **(Optional) Edit your workspace files** to shape your agent's identity:
   - Edit `~/.openclaw/workspace/SOUL.md` to define voice/values.
   - Edit `~/.openclaw/workspace/USER.md` to tell the agent about yourself.
   - Edit `~/.openclaw/workspace/AGENTS.md` to add operational notes.

3. **Test your agent** — send it a message via your chosen channel. It should reply with awareness of its identity (test on Sonnet, not haiku — haiku's identity is unreliable per known gotchas).

## Idempotency

The installer is safe to re-run. It will:
- Skip installing packages if already present.
- Preserve existing workspace files.
- Preserve existing `openclaw.json`.
- Archive `~/.openclaw` if it exists before overwriting (you choose to proceed or abort).

## Troubleshooting

**"ERROR: Open Civitas v0 requires Ubuntu 26.04 LTS"**
Only Ubuntu 26.04 is supported. If you're on a different distro, v0 is not for you. Phase 3 will expand to other platforms.

**"ERROR: passwordless sudo is required"**
Add your user to sudoers:
```bash
sudo visudo
# Add: $USER ALL=(ALL) NOPASSWD:ALL
```

**Gateway won't start:**
Check systemd logs:
```bash
journalctl --user -u openclaw-gateway -n 100
```

**openclaw.json has `<user>` placeholder:**
This shouldn't happen — the installer generates it programmatically. If it does, delete `~/.openclaw/openclaw.json` and re-run the installer.

**Heartbeats fail with ECONNREFUSED:**
If you installed Ollama, your network/firewall may be blocking port 11434. Open TCP/11434 from the agent's VLAN to the Ollama host, then wait for the next heartbeat cycle (or test immediately: `curl -s http://<ollama-host>:11434/api/tags`).

## Support

For bugs or questions, file an issue at https://github.com/civitasstudio/open-civitas/issues.
