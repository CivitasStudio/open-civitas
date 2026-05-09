#!/usr/bin/env bash
# Optional: install Claude Code CLI and walk through OAuth.
# Sourced by install.sh.
set -euo pipefail

CLAUDE_JSON="${HOME}/.claude.json"

is_claude_authenticated() {
    # Presence of ~/.claude.json with a non-empty oauthAccount is the reliable indicator.
    if [[ -f "$CLAUDE_JSON" ]] && grep -q '"oauthAccount"' "$CLAUDE_JSON" 2>/dev/null; then
        return 0
    fi
    return 1
}

install_claude_cli() {
    if command -v claude &>/dev/null; then
        log_info "Claude Code CLI already installed ($(claude --version 2>/dev/null | head -1)), skipping npm install."
    else
        log_info "Installing @anthropic-ai/claude-code globally…"
        sudo npm install -g @anthropic-ai/claude-code
        log_info "Claude Code CLI installed: $(claude --version 2>/dev/null | head -1)"
    fi

    if is_claude_authenticated; then
        log_info "Claude OAuth already authenticated, skipping login."
        return 0
    fi

    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Claude OAuth login"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Run the following command, complete the browser flow,"
    log_info "  then press Enter here to continue."
    log_info ""
    log_info "    claude login --claudeai"
    log_info ""

    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        log_info "  [non-interactive mode] Skipping OAuth wait. Run 'claude login --claudeai' manually after install."
        return 0
    fi

    read -r -p "  Press Enter once OAuth is complete… " _
    log_info ""

    if is_claude_authenticated; then
        log_info "OAuth authentication confirmed."
    else
        log_warn "OAuth state not detected in $CLAUDE_JSON. You may need to run 'claude login --claudeai' manually."
    fi
}
