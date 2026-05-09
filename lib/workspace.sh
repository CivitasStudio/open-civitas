#!/usr/bin/env bash
# Workspace skeleton creation and openclaw.json generation.
# Sourced by install.sh — expects SCRIPT_DIR, AGENT_NAME, AGENT_ROLE, USER_NAME to be set.
set -euo pipefail

WORKSPACE_DIR="${HOME}/.openclaw/workspace"
OPENCLAW_JSON="${HOME}/.openclaw/openclaw.json"
TEMPLATES_DIR="${SCRIPT_DIR}/templates/workspace"

# Replace {{PLACEHOLDER}} tokens in a template file and write output.
render_template() {
    local src="$1" dst="$2"
    local install_date
    install_date=$(date +%Y-%m-%d)

    sed \
        -e "s|{{AGENT_NAME}}|${AGENT_NAME}|g" \
        -e "s|{{AGENT_ROLE}}|${AGENT_ROLE}|g" \
        -e "s|{{USER_NAME}}|${USER_NAME}|g" \
        -e "s|{{HOSTNAME}}|$(hostname)|g" \
        -e "s|{{WORKSPACE_DIR}}|${WORKSPACE_DIR}|g" \
        -e "s|{{INSTALL_DATE}}|${install_date}|g" \
        "$src" > "$dst"
}

create_workspace_skeleton() {
    log_info "Creating workspace skeleton at $WORKSPACE_DIR…"
    mkdir -p "$WORKSPACE_DIR/memory"

    local tmpl dst
    for tmpl in AGENTS SOUL IDENTITY USER MEMORY; do
        dst="${WORKSPACE_DIR}/${tmpl}.md"
        if [[ -f "$dst" ]]; then
            log_info "  $tmpl.md already exists, skipping."
            continue
        fi
        render_template "${TEMPLATES_DIR}/${tmpl}.md.tmpl" "$dst"
        log_info "  Wrote ${tmpl}.md"
    done

    # HEARTBEAT.md is static (no substitution needed)
    if [[ ! -f "${WORKSPACE_DIR}/HEARTBEAT.md" ]]; then
        cp "${TEMPLATES_DIR}/HEARTBEAT.md" "${WORKSPACE_DIR}/HEARTBEAT.md"
        log_info "  Wrote HEARTBEAT.md"
    else
        log_info "  HEARTBEAT.md already exists, skipping."
    fi
}

generate_openclaw_json() {
    # Validate required values before writing anything.
    if [[ -z "${AGENT_NAME}" || -z "${WORKSPACE_DIR}" ]]; then
        log_error "AGENT_NAME and WORKSPACE_DIR must be non-empty before generating openclaw.json."
        return 1
    fi
    if [[ "${WORKSPACE_DIR}" != /* ]]; then
        log_error "WORKSPACE_DIR must be an absolute path (got: ${WORKSPACE_DIR})."
        return 1
    fi

    mkdir -p "$(dirname "$OPENCLAW_JSON")"

    if [[ -f "$OPENCLAW_JSON" ]]; then
        log_info "openclaw.json already exists — preserving existing file."
        log_info "  If you need to regenerate it, delete $OPENCLAW_JSON and re-run the installer."
        return 0
    fi

    log_info "Generating $OPENCLAW_JSON…"

    # Write via temp file then atomic rename to avoid a corrupt half-written config.
    local tmp
    tmp=$(mktemp "${HOME}/.openclaw/openclaw.json.XXXXXX")
    cat > "$tmp" <<JSONEOF
{
  "auth": {
    "profiles": {
      "anthropic:default": { "provider": "claude-cli", "mode": "oauth" }
    }
  },
  "gateway": {
    "mode": "local"
  },
  "agents": {
    "defaults": {
      "workspace": "${WORKSPACE_DIR}",
      "agentRuntime": { "id": "claude-cli" },
      "model": {
        "primary": "anthropic/claude-sonnet-4-6",
        "fallbacks": ["anthropic/claude-haiku-4-5"]
      },
      "heartbeat": { "every": "15m", "model": "ollama/gemma4:e4b" },
      "contextPruning": { "mode": "cache-ttl", "ttl": "1h" },
      "compaction": { "mode": "safeguard" },
      "timeoutSeconds": 300,
      "models": {
        "anthropic/claude-opus-4-7":  { "alias": "opus" },
        "anthropic/claude-sonnet-4-6": { "alias": "sonnet" },
        "anthropic/claude-haiku-4-5":  { "alias": "haiku" },
        "ollama/gemma4:26b":           { "alias": "gemma" },
        "ollama/gemma4:e4b":           { "alias": "gemma-e4b" }
      }
    }
  },
  "channels": {}
}
JSONEOF
    mv "$tmp" "$OPENCLAW_JSON"
    chmod 600 "$OPENCLAW_JSON"
    log_info "Generated $OPENCLAW_JSON (workspace: ${WORKSPACE_DIR})"
}

install_claude_md_symlink() {
    local target="${WORKSPACE_DIR}/AGENTS.md"
    local link="${HOME}/CLAUDE.md"

    if [[ -L "$link" ]]; then
        local current_target
        current_target=$(readlink "$link")
        if [[ "$current_target" == "$target" ]]; then
            log_info "~/CLAUDE.md symlink already correct, skipping."
            return 0
        fi
        log_info "Updating stale ~/CLAUDE.md symlink (was → $current_target)…"
        rm "$link"
    elif [[ -e "$link" ]]; then
        log_info "~/CLAUDE.md exists as a regular file — leaving it in place (not overwriting)."
        return 0
    fi

    ln -s "$target" "$link"
    log_info "Created ~/CLAUDE.md → $target"
}

setup_workspace() {
    create_workspace_skeleton
    generate_openclaw_json
    install_claude_md_symlink
}
