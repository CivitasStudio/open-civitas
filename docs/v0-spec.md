# Open Civitas v0 Spec

**Status:** Approved (Alex 2026-05-09) — awaiting John's phase-boundary sign-off
**Author:** Wayland
**Date:** 2026-05-09
**Scope:** `install.sh` on Ubuntu 26.04 LTS Server only. No cloud-init, no Docker, no Unraid CA, no Windows.

---

## User Journey

**Who:** A person with a fresh Ubuntu 26.04 LTS Server VM, passwordless sudo, and an internet connection. No prior OpenClaw knowledge required.

**Entry point:**
```bash
curl -fsSL https://raw.githubusercontent.com/civitasstudio/open-civitas/main/install.sh | bash
# or: git clone … && ./install.sh
```

**What the installer does, in order:**

1. **Preflight** — Detects OS (must be Ubuntu 26.04), checks sudo. If `~/.openclaw/` already exists, the installer prints:
   ```
   Existing ~/.openclaw found. Archiving to ~/.openclaw.bak.<timestamp> before continuing.
   Press Enter to continue or Ctrl-C to abort.
   ```
   On Enter, renames `~/.openclaw` → `~/.openclaw.bak.$(date +%s)` (never deletes), then proceeds. This handles re-installs and stale-session recovery cleanly.

2. **Substrate install** — Idempotently installs: Node LTS via NodeSource, `npm install -g openclaw@latest`, linger (`loginctl enable-linger $USER`) + systemd user unit (`openclaw-gateway.service`). All steps skip cleanly if already present and at the correct version.

3. **Workspace skeleton** — Prompts: agent name, agent role (one line), and user/principal name. Writes `~/.openclaw/workspace/` with templates filled: AGENTS.md, SOUL.md, IDENTITY.md, USER.md, MEMORY.md. Writes a minimal HEARTBEAT.md as an empty file (comments only) — an empty HEARTBEAT.md causes OpenClaw to skip the heartbeat API call entirely, saving tokens for users who haven't configured a heartbeat task. Writes `openclaw.json` programmatically (see below).

4. **`openclaw.json` generation** — The installer generates `~/.openclaw/openclaw.json` directly from interpolated values, not from a user-editable template. Values are validated before writing (absolute path, non-empty fields). A human-readable reference showing the config shape lives at `docs/reference/openclaw.json.example`; a file comment in that example makes clear it is documentation, not an input file. No `.tmpl` file is shipped.

5. **Optional: Claude Code CLI** — `"Install Claude Code CLI? [Y/n]"` → installs `@anthropic-ai/claude-code` globally, prints `claude login --claudeai` and waits for the user to confirm OAuth completion. Skips if already authenticated (`~/.claude.json` present and valid).

6. **Optional: Ollama** — `"Install Ollama for local/offline models? [y/N]"` → installs Ollama via upstream script, detects GPU (NVIDIA/AMD via `nvidia-smi`/`rocm-smi`). Suggests `gemma4:26b` if ≥16 GB VRAM detected, `gemma4:e4b` otherwise. Pulls chosen model. Emits a reminder about firewall rules if Ollama will be shared across VLANs.

7. **Symlink** — Creates `~/CLAUDE.md → ~/.openclaw/workspace/AGENTS.md` so direct `claude` CLI invocations also pick up identity (CWD auto-discovery walks up looking for `CLAUDE.md`).

8. **Gateway start** — Starts `openclaw-gateway.service`. Polls `http://localhost:18789/health` (confirmed HTTP 200 on current release) for up to 30s. Fails with a clear message if the gateway doesn't come up.

9. **Hand-off** — Prints:
   ```
   Substrate ready. Run: openclaw setup
   to choose your channel (Telegram, WhatsApp, web, …) and provider.
   ```

**End state the user has:**
- OpenClaw gateway running and surviving reboot.
- Workspace files seeded with their agent's identity.
- `openclaw setup` is the next and only required step before the agent is useful.
- Claude CLI authenticated (if chosen), Ollama running with a model pulled (if chosen).

---

## Explicit Non-Goals for v0

| Not in v0 | Deferred to |
|---|---|
| Choosing channels or providers | OpenClaw's own `openclaw setup` onboarding |
| cloud-init / user-data template | Phase 2 |
| VM provisioning (ISO, libvirt, Terraform) | Phase 2 |
| Unraid CA template, Docker Compose, Windows installer | Phase 3 |
| Multi-agent on one host | Explicit non-goal (until single-agent is solid) |
| OpenClaw version pinning | `--openclaw-version` flag, add in Phase 1 if requested |
| Upgrading an existing OpenClaw install | Separate `update.sh`; out of scope for v0 |
| Ansible/Chef/Salt integration | No. Bash is the interface. |

---

## Success Criteria

v0 is done when all of the following are true on a **fresh Forge libvirt VM** (Ubuntu 26.04, no prior software):

1. `install.sh` runs to completion with no unhandled errors. Re-running it (idempotent test) produces no failures and no duplicate unit registrations.
2. `systemctl --user is-active openclaw-gateway` returns `active`.
3. `loginctl show-user $USER | grep Linger` returns `Linger=yes`.
4. `~/.openclaw/workspace/AGENTS.md` exists and contains the agent name entered during install.
5. `~/.openclaw/openclaw.json` contains `agents.defaults.workspace` set to an absolute path (non-empty, no un-substituted placeholders).
6. Gateway health: `curl -s -o /dev/null -w "%{http_code}" http://localhost:18789/health` returns `200`. (Endpoint verified against current release on 2026-05-09.)
7. `~/CLAUDE.md` is a symlink pointing to `~/.openclaw/workspace/AGENTS.md`.
8. After user completes `openclaw setup` (Telegram or web), sending a message and receiving a persona-consistent reply on **Sonnet** (not haiku — haiku identity is unreliable against the outer OpenClaw framing).
9. Smoke test script (`scripts/smoke-test.sh`) exits 0 for criteria 1–7 without any human intervention.

---

## Smoke Test Design

`scripts/smoke-test.sh` is a non-interactive script run by the Phase 1 CI loop on Forge. It tests installer output state only — not chat flow (channel-dependent) or heartbeat timing (timing-dependent).

**Assertions:**
```
1. PASS/FAIL: openclaw-gateway.service is active
2. PASS/FAIL: linger is enabled for current user
3. PASS/FAIL: ~/.openclaw/workspace/{AGENTS,SOUL,IDENTITY,USER,HEARTBEAT,MEMORY}.md all exist
4. PASS/FAIL: openclaw.json exists, contains "workspace" key, value is non-empty absolute path
5. PASS/FAIL: ~/CLAUDE.md is a symlink → ~/.openclaw/workspace/AGENTS.md
6. PASS/FAIL: GET http://localhost:18789/health returns HTTP 200
7. PASS/FAIL (if claude-cli installed): claude --version exits 0
8. PASS/FAIL (if ollama installed): ollama list returns at least one model
```

Emits `PASS`/`FAIL` per line, exits 1 on any failure.

**Forge integration:** `virt-install` spins up a throwaway `test-ubuntu-2604-open-civitas-YYYY-MM-DD` VM. Installs via `./install.sh --non-interactive --agent-name "TestAgent" --agent-role "Smoke test agent" --user "CI"`. SCPs and runs `smoke-test.sh`. VM destroyed on pass; preserved for triage on fail.
