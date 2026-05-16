#!/usr/bin/env bash
# Open Civitas first-boot provisioning.
#
# Runs once at first boot (enabled by autoinstall late-commands, disabled by
# itself when done).  Reads /etc/civitas/preflight.json, writes brain-specific
# openclaw.json, provisions the chosen brain, shows an optional password
# prompt, then disables civitas-firstboot.service so it never runs again.
#
# Dependencies available in the installed target: python3, bash, dialog,
# systemctl, curl, ollama (for ollama+gemma-local brain).

set -euo pipefail

PREFLIGHT="/etc/civitas/preflight.json"
SENTINEL_DIR="/var/lib/civitas"
MODEL_PULLING="$SENTINEL_DIR/model-pulling"
LOG="/var/log/civitas-firstboot.log"

log()  { echo "[civitas-firstboot] $*" | tee -a "$LOG"; }
die()  { echo "[civitas-firstboot] FATAL: $*" | tee -a "$LOG" >&2; exit 1; }

exec >> "$LOG" 2>&1
log "Starting — $(date --iso-8601=seconds)"

# ── Read preflight answers ────────────────────────────────────────────────────

[[ -f "$PREFLIGHT" ]] || die "preflight.json not found at $PREFLIGHT"

NAME=$(python3 -c "import json; print(json.load(open('$PREFLIGHT'))['name'])")
BRAIN=$(python3 -c "import json; print(json.load(open('$PREFLIGHT'))['brain'])")
[[ -n "$NAME" ]]  || die "preflight.json has no 'name' field"
[[ -n "$BRAIN" ]] || die "preflight.json has no 'brain' field"

HOME_DIR="/home/$NAME"
OPENCLAW_JSON="$HOME_DIR/.openclaw/openclaw.json"
WORKSPACE="$HOME_DIR/.openclaw/workspace"
MEMORY_DIR="$WORKSPACE/memory"

log "user=$NAME brain=$BRAIN"

[[ -f "$OPENCLAW_JSON" ]] || die "openclaw.json not found at $OPENCLAW_JSON (install.sh may have failed)"

# ── Update openclaw.json for chosen brain ─────────────────────────────────────

log "Updating openclaw.json for brain: $BRAIN"
python3 - <<PYEOF
import json, sys

with open('$OPENCLAW_JSON') as f:
    cfg = json.load(f)

brain = '$BRAIN'
defaults = cfg.setdefault('agents', {}).setdefault('defaults', {})
cfg.pop('civitas', None)  # clear any existing civitas namespace

if brain == 'ollama+gemma-local':
    defaults['agentRuntime'] = {'id': 'ollama'}
    defaults['model'] = {
        'primary': 'ollama/gemma4:26b',
        'fallbacks': ['ollama/gemma4:e2b'],
    }

elif brain == 'anthropic-cli':
    defaults['agentRuntime'] = {'id': 'claude-cli'}
    defaults['model'] = {
        'primary': 'anthropic/claude-sonnet-4-6',
        'fallbacks': ['anthropic/claude-haiku-4-5'],
    }
    cfg['civitas'] = {'pendingAuth': 'oauth'}

elif brain == 'anthropic-api':
    defaults['agentRuntime'] = {'id': 'anthropic-api'}
    defaults['model'] = {
        'primary': 'anthropic/claude-sonnet-4-6',
        'fallbacks': ['anthropic/claude-haiku-4-5'],
    }
    cfg['civitas'] = {'pendingAuth': 'api-key', 'provider': 'anthropic'}

elif brain == 'openai':
    defaults['agentRuntime'] = {'id': 'openai'}
    defaults['model'] = {'primary': 'openai/gpt-4o', 'fallbacks': ['openai/gpt-4o-mini']}
    cfg['civitas'] = {'pendingAuth': 'api-key', 'provider': 'openai'}

elif brain == 'gemini':
    defaults['agentRuntime'] = {'id': 'gemini'}
    defaults['model'] = {'primary': 'gemini/gemini-2.0-flash', 'fallbacks': []}
    cfg['civitas'] = {'pendingAuth': 'api-key', 'provider': 'gemini'}

elif brain == 'mistral':
    defaults['agentRuntime'] = {'id': 'mistral'}
    defaults['model'] = {'primary': 'mistral/mistral-large-latest', 'fallbacks': []}
    cfg['civitas'] = {'pendingAuth': 'api-key', 'provider': 'mistral'}

elif brain == 'cohere':
    defaults['agentRuntime'] = {'id': 'cohere'}
    defaults['model'] = {'primary': 'cohere/command-r-plus', 'fallbacks': []}
    cfg['civitas'] = {'pendingAuth': 'api-key', 'provider': 'cohere'}

else:
    print(f'Warning: unknown brain {brain!r} — leaving openclaw.json unchanged', flush=True)
    sys.exit(0)

import tempfile, os
tmp = '$OPENCLAW_JSON.tmp'
with open(tmp, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
os.chmod(tmp, 0o600)
os.replace(tmp, '$OPENCLAW_JSON')
print(f'openclaw.json updated for {brain}', flush=True)
PYEOF

# ── Brain-specific provisioning ───────────────────────────────────────────────

if [[ "$BRAIN" == "ollama+gemma-local" ]]; then
    log "Installing Ollama..."
    if ! command -v ollama &>/dev/null; then
        curl -fsSL https://ollama.ai/install.sh | bash
    else
        log "Ollama already installed: $(ollama --version 2>/dev/null | head -1)"
    fi

    log "Enabling and starting Ollama service..."
    systemctl enable --now ollama 2>/dev/null || true
    sleep 2  # brief settle before pull

    # Detect VRAM to choose model size
    MODEL="gemma4:26b"
    if command -v nvidia-smi &>/dev/null 2>&1; then
        VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
            | awk '{s+=$1} END {print int(s)}' || echo 0)
        [[ "$VRAM" -lt 16384 ]] && MODEL="gemma4:e2b"
    fi
    log "Pulling Ollama model: $MODEL (background)"

    mkdir -p "$SENTINEL_DIR"
    echo "$MODEL" > "$MODEL_PULLING"

    # Run pull in background; remove sentinel when done.
    (
        ollama pull "$MODEL" && rm -f "$MODEL_PULLING" \
            && echo "[civitas-firstboot] Gemma pull complete — $(date --iso-8601=seconds)" >> "$LOG"
        # Update openclaw.json primary model to reflect actual model pulled.
        python3 -c "
import json, os
with open('$OPENCLAW_JSON') as f: cfg = json.load(f)
cfg['agents']['defaults']['model']['primary'] = 'ollama/$MODEL'
tmp = '$OPENCLAW_JSON.tmp'
with open(tmp, 'w') as f: json.dump(cfg, f, indent=2); f.write('\n')
os.chmod(tmp, 0o600); os.replace(tmp, '$OPENCLAW_JSON')
"
    ) &
    disown $!
fi

# ── Optional password prompt (dialog on tty1) ─────────────────────────────────

if command -v dialog &>/dev/null; then
    DIALOG_RC=0
    dialog \
        --title "Open Civitas — Optional password" \
        --yes-label "Set password" \
        --no-label "Skip" \
        --yesno \
"Recommended if this machine is on a shared or external network.
You can skip and set one later with 'passwd'." \
        8 65 </dev/tty >/dev/tty 2>&1 || DIALOG_RC=$?

    if [[ "$DIALOG_RC" -eq 0 ]]; then
        log "User chose to set password"
        passwd "$NAME" </dev/tty >/dev/tty 2>&1 || {
            dialog --title "Error" \
                --msgbox "Password change failed.\nRun 'passwd $NAME' manually." \
                6 50 </dev/tty >/dev/tty 2>&1 || true
        }
    else
        log "User skipped password"
        echo "" >> /etc/motd
        echo "Tip: No system password set. Run 'passwd' from /bash to add one." >> /etc/motd
        mkdir -p "$MEMORY_DIR"
        cat >> "$MEMORY_DIR/firstboot-notes.md" << 'MEMEOF'
---
name: No system password set
description: No password was set at first boot — reminder to set one if needed
type: user
---

No system password was set at first boot. Run `passwd` from `/bash` to add one.
MEMEOF
        chown -R "$NAME:$NAME" "$MEMORY_DIR" 2>/dev/null || true
    fi
else
    log "Warning: dialog not available — skipping password prompt"
fi

# ── Disable self (run once only) ─────────────────────────────────────────────

log "Disabling civitas-firstboot.service"
systemctl disable civitas-firstboot.service 2>/dev/null || true

log "First-boot provisioning complete — $(date --iso-8601=seconds)"
