# Open Civitas Phase 2 — Bob Test Agent Spec

**Objective:** Stand up Bob, a long-lived test agent on Forge libvirt running local Ollama + Gemma4:e2b. Bob serves as the development target for Phase 3 (`civitas-shell` chat client) and validates Phase 1 `install.sh` end-to-end.

---

## VM Specifications

**Hardware (Forge libvirt):**
- vCPU: 4
- RAM: 8 GB
- Disk: 30 GB
- OS: Ubuntu 26.04 LTS Server
- Hostname: `bob`
- User: `bob` (passwordless sudo)

**Justification:** Gemma4:e2b (2B effective parameters, 5.1B with embeddings) runs comfortably on 8 GB RAM in quantized form (Q4_K_M, 7.2 GB model). 4 vCPU provides acceptable inference speed (~5-10 tokens/sec on CPU) for testing. 30 GB total disk accommodates OS, Ollama, and workspace.

---

## Ollama Model Selection

**Model:** `gemma4:e2b`

**Rationale:**
- **Tag availability:** `gemma4:e2b` is published and stable on Ollama Registry (https://ollama.com/library/gemma4:e2b).
- **Model size:** 7.2 GB (Q4_K_M quantization), fits comfortably on 30 GB disk with headroom.
- **Inference performance:** ~5-10 tokens/sec on 4-core CPU — acceptable latency for heartbeat + interactive testing.
- **Context window:** 128K tokens, sufficient for agent workspace + daily memory injection.
- **Capabilities:** Text, image, audio support (multimodal); structured function calling (agent workflows); 128K context.
- **Design target:** E2B ("Effective 2B") is explicitly optimized for edge deployment; proven low-resource footprint.

**Fallback:** If `gemma4:e2b` tag becomes unavailable, substitute `gemma4:e4b` (next-larger edge model, 4B effective parameters). Both E-series variants are designed for offline, CPU-only inference.

---

## Install.sh Invocation

**Base command (anticipated):**
```bash
curl https://raw.githubusercontent.com/CivitasStudio/open-civitas/main/install.sh | \
  bash -s -- \
    --agent-name Bob \
    --agent-role "test agent for Phase 2/3 development" \
    --user-name "Wayland/Alex" \
    --with-ollama \
    --ollama-model gemma4:e2b \
    --non-interactive
```

**Flags:**
- `--with-ollama`: Install and configure Ollama locally.
- `--ollama-model gemma4:e2b`: Pull and set as default for heartbeat.
- `--non-interactive`: Skip prompts; use defaults.

**Expected behaviors:**
- Validates Ubuntu 26.04 (passes; bob VM matches).
- Checks passwordless sudo (must be pre-configured on bob user).
- Archives any pre-existing `~/.openclaw` (for re-install safety).
- Installs Node LTS via NodeSource.
- Installs OpenClaw via npm.
- Installs systemd user unit + enables linger.
- Installs Ollama, pulls `gemma4:e2b`.
- Generates workspace skeleton + `openclaw.json` with local Ollama endpoint.
- Verifies gateway /health endpoint (30s timeout).

---

## Persona Configuration

**Workspace files (templated):**

- **AGENTS.md (AGENTS.md.tmpl):** Identity block naming Bob, his role, and stewards (Alex + Wayland). Operational context: Bob is test-only, runs offline, reachable via `agent-send bob "..."`.
- **SOUL.md (SOUL.md.tmpl):** Core values, reasoning style. Match Phase 1 template.
- **IDENTITY.md (IDENTITY.md.tmpl):** Concrete facts. Born 2026-05-09 on Forge. Offline agent (Gemma4:e2b, no external APIs). Test target.
- **USER.md (USER.md.tmpl):** Principals are Alex and Wayland. No external users.
- **MEMORY.md (MEMORY.md.tmpl):** Boot-time memory folder. Empty initially; will populate as Bob operates.
- **HEARTBEAT.md:** Populated with gentle cron-style task: "Every 23 minutes, fire a health ping via local Ollama. Report status to the logging system."

**openclaw.json (programmatic generation):**
```json
{
  "auth": {
    "profiles": {
      "anthropic:default": { "provider": "claude-cli", "mode": "local-only" }
    }
  },
  "gateway": {
    "mode": "local"
  },
  "agents": {
    "defaults": {
      "workspace": "/home/bob/.openclaw/workspace",
      "agentRuntime": { "id": "claude-cli" },
      "model": {
        "primary": "ollama/gemma4:e2b",
        "fallbacks": []
      },
      "heartbeat": { "every": "23m", "model": "ollama/gemma4:e2b" },
      "contextPruning": { "mode": "cache-ttl", "ttl": "1h" },
      "compaction": { "mode": "safeguard" },
      "timeoutSeconds": 300
    }
  },
  "channels": {}
}
```

**Key fields:**
- `workspace`: absolute path, prevents silent heartbeat failures.
- `model.primary`: `ollama/gemma4:e2b` (local Ollama endpoint, no fallbacks to external APIs).
- `heartbeat.every`: "23m" (match Penny's pattern, gentle for dev testing).
- `channels`: empty (Bob has no Telegram, WhatsApp, etc.; agent-send only).

---

## Validation Procedure

### 1. End-to-End agent-send Round-Trip
```bash
agent-send bob "Hello Bob, what's your name?"
```
**Expected:** Coherent response identifying Bob, acknowledgment of test-agent role, and mention of offline brain (Gemma4:e2b).

**Failure mode:** If response is generic Claude, check:
- `~/.openclaw/agents/main/sessions/sessions.json` → `systemPromptReport` (verify AGENTS.md etc. injected).
- Gateway log: `journalctl --user -u openclaw-gateway -n 50 | grep "system-prompt"`.

### 2. Heartbeat Fire + Health Probe
Manually trigger heartbeat:
```bash
openclaw system event --text "heartbeat-test" --mode now --json
```
**Expected:** Heartbeat completes within 10s, returns 200-level status, logs show Ollama connection success.

**Failure mode:** If heartbeat times out or fails:
- Check Ollama is running: `systemctl --user status ollama` (if user-mode) or `systemctl status ollama` (if system-wide).
- Test Ollama endpoint: `curl -s http://127.0.0.1:11434/api/tags` (should list models).
- Check firewall: `sudo ufw status | grep 11434`.

### 3. Offline Brain Verification
Monitor gateway log during heartbeat + agent-send operations:
```bash
journalctl --user -u openclaw-gateway -f
```
**Expected:** All LLM requests route to `http://127.0.0.1:11434`, no DNS lookups to remote providers (Anthropic, OpenAI, etc.).

**Failure mode:** If external API traffic appears:
- Check `openclaw.json` → `model.primary` (must be `ollama/gemma4:e2b`, not `anthropic/...`).
- Verify no `--fallbacks` to Anthropic in the model config.
- Confirm Ollama model `gemma4:e2b` is available: `curl -s http://127.0.0.1:11434/api/tags | jq '.models[] | .name'`.

---

## Install.sh Dogfood & Fixes

**Scope:** Phase 1's `install.sh` was tested on a ~20GB disk (resource-constrained). Phase 2 provisions a realistic 30GB VM, which may surface new issues or confirm robustness.

**Known issues from Phase 1 (already fixed in main):**
- ✅ Missing `gateway.mode = "local"` in generated `openclaw.json` (fixed, commit 68e93dc).
- ✅ systemd unit incorrectly used `gateway start` instead of `gateway run` (fixed, commit 68e93dc).

**Testing plan:**
1. Run `install.sh` end-to-end on bob VM. Log all output.
2. If install fails, categorize: OS detection, sudo validation, package install, Ollama pull, workspace generation, systemd, health check.
3. For each failure, determine if it's an `install.sh` bug (Phase 2 fix) or a VM misconfiguration (document and adjust Phase 2 provisioning steps).
4. For each fix committed during dogfood, update the main branch and document in `docs/DEVELOPMENT.md`.

**Potential issues to watch:**
- Ollama model pull timeout (if bandwidth to registry is slow).
- Systemd linger not persisting agent process across reboots (linger configuration).
- Workspace path resolution with `bob` user instead of `wayland`/`forge`.
- Gateway /health endpoint reachability (localhost:6789 vs public IP).

---

## Success Criteria (Phase 2 complete)

1. ✅ Bob VM boots, SSH access confirmed, hostname = `bob`, user = `bob`.
2. ✅ `install.sh` completes without error (or errors are documented + fixed in main).
3. ✅ Ollama `gemma4:e2b` model is pulled and available locally.
4. ✅ `agent-send bob "..."` returns a coherent, persona-aware response (identity test).
5. ✅ Heartbeat fires every 23 minutes, completes in <10s, logs show zero external API traffic.
6. ✅ Systemd user unit `openclaw-gateway.service` is active and auto-starts on reboot.
7. ✅ `~/.openclaw/workspace/` contains AGENTS.md, SOUL.md, IDENTITY.md, USER.md, MEMORY.md, HEARTBEAT.md, and `~/.openclaw/openclaw.json` with correct local Ollama configuration.

---

## References

- Ollama Registry: https://ollama.com/library/gemma4:e2b
- Gemma4 Specifications: https://gemma4.org/gemma-4-model-sizes
- Phase 1 Install: `docs/INSTALL.md` and `install.sh`
- Heartbeat Patterns (Penny reference): `handbook/install-gotchas.md` (line 59–66)
- Agent-to-agent comms: `~/alex-reference/agent-to-agent-comms-plan.md`
