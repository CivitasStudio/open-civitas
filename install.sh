#!/usr/bin/env bash
# Open Civitas installer — turns a fresh Ubuntu 26.04 LTS Server into an OpenClaw substrate.
# Usage: curl -fsSL https://raw.githubusercontent.com/civitasstudio/open-civitas/main/install.sh | bash
#   or:  ./install.sh [--non-interactive --agent-name NAME --agent-role ROLE --user USER]
#
# Idempotent: safe to re-run. Existing state is preserved; missing pieces are filled in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Logging ──────────────────────────────────────────────────────────────────

OPENCLAW_LOG="${HOME}/.openclaw/install.log"

log_info()  {
    mkdir -p "$(dirname "$OPENCLAW_LOG")"
    echo "[open-civitas] $*" | tee -a "$OPENCLAW_LOG"
}
log_warn()  {
    mkdir -p "$(dirname "$OPENCLAW_LOG")"
    echo "[open-civitas] WARN: $*" | tee -a "$OPENCLAW_LOG" >&2
}
log_error() {
    mkdir -p "$(dirname "$OPENCLAW_LOG")"
    echo "[open-civitas] ERROR: $*" | tee -a "$OPENCLAW_LOG" >&2
}

# ── Argument parsing ──────────────────────────────────────────────────────────

NON_INTERACTIVE=0
AGENT_NAME=""
AGENT_ROLE=""
USER_NAME=""
INSTALL_CLAUDE_CLI=""   # "y", "n", or "" (ask)
INSTALL_OLLAMA=""       # "y", "n", or "" (ask)

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --non-interactive           Skip all prompts (requires --agent-name, --agent-role, --user)
  --agent-name NAME           Agent display name
  --agent-role ROLE           One-line agent role description
  --user USER                 Principal / owner name
  --claude-cli [y|n]          Install Claude Code CLI (default: ask)
  --ollama [y|n]              Install Ollama (default: ask)
  --help                      Show this help

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=1 ;;
        --agent-name)  AGENT_NAME="$2";  shift ;;
        --agent-role)  AGENT_ROLE="$2";  shift ;;
        --user)        USER_NAME="$2";   shift ;;
        --claude-cli)  INSTALL_CLAUDE_CLI="$2"; shift ;;
        --ollama)      INSTALL_OLLAMA="$2";     shift ;;
        --help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

export NON_INTERACTIVE AGENT_NAME AGENT_ROLE USER_NAME

# ── Source helpers ────────────────────────────────────────────────────────────

# shellcheck source=lib/detect.sh
source "${SCRIPT_DIR}/lib/detect.sh"
# shellcheck source=lib/install-substrate.sh
source "${SCRIPT_DIR}/lib/install-substrate.sh"
# shellcheck source=lib/workspace.sh
source "${SCRIPT_DIR}/lib/workspace.sh"
# shellcheck source=lib/install-claude-cli.sh
source "${SCRIPT_DIR}/lib/install-claude-cli.sh"
# shellcheck source=lib/install-ollama.sh
source "${SCRIPT_DIR}/lib/install-ollama.sh"

# ── Step 1: Preflight ─────────────────────────────────────────────────────────

preflight() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Open Civitas — OpenClaw Substrate Installer"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""

    assert_ubuntu_2604
    assert_passwordless_sudo

    # Archive existing ~/.openclaw if present (re-install protection).
    if [[ -d "${HOME}/.openclaw" ]]; then
        local archive_path="${HOME}/.openclaw.bak.$(date +%s)"
        log_warn "Existing ~/.openclaw detected."
        log_warn "It will be archived to: $archive_path"
        if [[ "$NON_INTERACTIVE" == "1" ]]; then
            log_info "[non-interactive] Auto-archiving existing state."
        else
            log_info ""
            read -r -p "  Press Enter to archive and continue, or Ctrl-C to abort… " _
        fi
        mv "${HOME}/.openclaw" "$archive_path"
        log_info "Archived existing state to $archive_path"
    fi

    mkdir -p "${HOME}/.openclaw"
    # Log file lives inside .openclaw, so mkdir must come before any log_info.
}

# ── Step 2: Prompts ───────────────────────────────────────────────────────────

gather_inputs() {
    if [[ "$NON_INTERACTIVE" == "1" ]]; then
        if [[ -z "$AGENT_NAME" || -z "$AGENT_ROLE" || -z "$USER_NAME" ]]; then
            log_error "--non-interactive requires --agent-name, --agent-role, and --user."
            exit 1
        fi
        return 0
    fi

    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Agent setup"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    while [[ -z "$AGENT_NAME" ]]; do
        read -r -p "  Agent name (e.g. Wayland): " AGENT_NAME
    done

    while [[ -z "$AGENT_ROLE" ]]; do
        read -r -p "  Agent role (one line, e.g. 'Build and package agent'): " AGENT_ROLE
    done

    while [[ -z "$USER_NAME" ]]; do
        read -r -p "  Your name (the principal this agent serves): " USER_NAME
    done

    log_info ""
}

gather_optional_installs() {
    if [[ "$NON_INTERACTIVE" == "1" ]]; then
        INSTALL_CLAUDE_CLI="${INSTALL_CLAUDE_CLI:-n}"
        INSTALL_OLLAMA="${INSTALL_OLLAMA:-n}"
        return 0
    fi

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Optional components"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ -z "$INSTALL_CLAUDE_CLI" ]]; then
        read -r -p "  Install Claude Code CLI (Anthropic provider via OAuth)? [Y/n]: " INSTALL_CLAUDE_CLI
        INSTALL_CLAUDE_CLI="${INSTALL_CLAUDE_CLI:-y}"
    fi

    if [[ -z "$INSTALL_OLLAMA" ]]; then
        read -r -p "  Install Ollama (local/offline models)? [y/N]: " INSTALL_OLLAMA
        INSTALL_OLLAMA="${INSTALL_OLLAMA:-n}"
    fi
    log_info ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    preflight
    gather_inputs
    gather_optional_installs

    log_info "Step 1/5: Installing substrate (Node, OpenClaw, systemd, linger)…"
    install_substrate

    log_info ""
    log_info "Step 2/5: Setting up workspace skeleton…"
    setup_workspace

    if [[ "${INSTALL_CLAUDE_CLI,,}" == "y"* ]]; then
        log_info ""
        log_info "Step 3/5: Installing Claude Code CLI…"
        install_claude_cli
    else
        log_info ""
        log_info "Step 3/5: Skipping Claude Code CLI."
    fi

    if [[ "${INSTALL_OLLAMA,,}" == "y"* ]]; then
        log_info ""
        log_info "Step 4/5: Installing Ollama…"
        install_ollama
    else
        log_info ""
        log_info "Step 4/5: Skipping Ollama."
    fi

    log_info ""
    log_info "Step 5/5: Starting OpenClaw gateway…"
    start_gateway

    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Substrate ready."
    log_info ""
    log_info "  Next step:"
    log_info "    openclaw setup"
    log_info ""
    log_info "  Choose your channel (Telegram, WhatsApp, web, …) and"
    log_info "  provider, then your agent will be live."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info ""
    log_info "Install log: $OPENCLAW_LOG"
}

main "$@"
