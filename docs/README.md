# Open Civitas

**Substrate installer for personal OpenClaw agents on Ubuntu 26.04 LTS Server.**

Turns a fresh Ubuntu 26.04 box into a running OpenClaw gateway in ~5 minutes. Idempotent. Bash. MIT license.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/civitasstudio/open-civitas/main/install.sh | bash
```

or clone and run:

```bash
git clone https://github.com/civitasstudio/open-civitas.git
cd open-civitas
./install.sh
```

The installer will:
1. Detect OS (Ubuntu 26.04 required).
2. Install Node LTS and OpenClaw via npm.
3. Create a workspace skeleton with your agent's identity.
4. Enable systemd user unit + linger (survives reboot).
5. Optionally install Claude Code CLI (OAuth).
6. Optionally install Ollama for local models.
7. Start the gateway and validate health.

**End result:** You have a running OpenClaw gateway. Next step: `openclaw setup` to choose your channel and provider.

## Options

```bash
./install.sh --non-interactive \
  --agent-name "MyAgent" \
  --agent-role "Your role here" \
  --user "Your name" \
  --claude-cli [y|n] \
  --ollama [y|n]
```

For interactive mode (default), just run `./install.sh` and answer the prompts.

## What Gets Installed

- **Node LTS** — via NodeSource package repo.
- **OpenClaw** — latest stable, installed globally via npm.
- **Workspace skeleton** — `~/.openclaw/workspace/` with AGENTS.md, SOUL.md, IDENTITY.md, USER.md, MEMORY.md, HEARTBEAT.md, and a generated `openclaw.json`.
- **systemd user unit** — `~/.config/systemd/user/openclaw-gateway.service` (auto-starts on reboot).
- **Claude Code CLI** — (optional) `@anthropic-ai/claude-code` + OAuth walk-through.
- **Ollama** — (optional) local LLM runtime with GPU detection and model pull.

## Non-Goals (Phase 0)

- No channel/provider configuration — `openclaw setup` owns that.
- No cloud-init / VM provisioning — see Phase 2.
- No Docker, Unraid CA, or Windows support — Phase 3.
- No multi-agent per host — explicit non-goal for v0.

## Troubleshooting

**Gateway won't start:**
```bash
journalctl --user -u openclaw-gateway -n 50
```

**Workspace path issues:**
Check `~/.openclaw/openclaw.json` and verify `agents.defaults.workspace` is set to an absolute path. If stale sessions exist, archive them:
```bash
mv ~/.openclaw/agents/main/sessions/* ~/agent-archives/stale-$(date +%s)/
```

**Heartbeat fails with ECONNREFUSED:**
If you installed Ollama, open TCP/11434 in your firewall to the Ollama host. Test:
```bash
curl -s http://<ollama-host>:11434/api/tags
```

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for building and testing on Forge.

## License

MIT — same as OpenClaw upstream.
