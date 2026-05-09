# Uninstallation

This document covers how to cleanly remove OpenClaw and related components if needed.

## Quick Uninstall

To stop the agent and remove systemd integration:

```bash
systemctl --user stop openclaw-gateway
systemctl --user disable openclaw-gateway
rm ~/.config/systemd/user/openclaw-gateway.service
systemctl --user daemon-reload

# Disable linger (optional)
sudo loginctl disable-linger $USER
```

## Full Removal

To remove everything including workspace files, OpenClaw, Node, Ollama, etc.:

### 1. Stop and disable the gateway

```bash
systemctl --user stop openclaw-gateway
systemctl --user disable openclaw-gateway
systemctl --user daemon-reload
```

### 2. Remove global packages

```bash
# OpenClaw
sudo npm uninstall -g openclaw

# Claude Code CLI (if installed)
sudo npm uninstall -g @anthropic-ai/claude-code

# Ollama (if installed)
sudo systemctl stop ollama
sudo systemctl disable ollama
sudo rm -rf /opt/ollama ~/ollama ~/.cache/ollama
```

### 3. Remove Node (if you installed it just for OpenClaw)

If you added the NodeSource repository and don't need Node for anything else:

```bash
sudo apt-get remove -y nodejs
sudo rm /etc/apt/sources.list.d/nodesource.list
sudo apt-get update
```

### 4. Remove workspace and config

```bash
# Archive before deleting (optional backup)
mkdir -p ~/openclaw-archives
mv ~/.openclaw ~/openclaw-archives/openclaw-backup-$(date +%s)

# Or delete directly
rm -rf ~/.openclaw

# Remove symlink
rm -f ~/CLAUDE.md

# Remove OAuth state (if using Claude CLI elsewhere, preserve this)
# rm -rf ~/.claude ~/.claude.json
```

### 5. Disable linger

```bash
sudo loginctl disable-linger $USER
```

## Archiving Instead of Deleting

To preserve your workspace for later recovery:

```bash
mkdir -p ~/agent-archives
mv ~/.openclaw ~/agent-archives/openclaw-$(date +%Y-%m-%d-%s)
```

Later, restore:

```bash
mv ~/agent-archives/openclaw-YYYY-MM-DD-* ~/.openclaw
systemctl --user restart openclaw-gateway
```

## Cleanup Notes

- **Don't delete systemd user services manually** — use `systemctl --user` to disable first.
- **Ollama data** — model cache lives in `~/.cache/ollama/` and `/opt/ollama/`. Removing `~/.cache/ollama` will force re-download on next pull; removing `/opt/ollama` is more aggressive.
- **Claude OAuth** — if you're using Claude CLI elsewhere, preserve `~/.claude` and `~/.claude.json`.
- **Workspace archives** — keep backups in `~/agent-archives/` if you might recover the agent later.
