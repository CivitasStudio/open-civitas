#!/usr/bin/env bash
# civitas-shell installation helper.
# Sourced by install.sh — expects OPENCLAW_LOG and SCRIPT_DIR to be set.
set -euo pipefail

install_civitas_shell() {
    if command -v civitas-shell &>/dev/null; then
        log_info "civitas-shell already installed, skipping."
        return 0
    fi

    # When running from a local repo checkout (./install.sh), prefer the
    # bundled package so the test doesn't depend on a registry publish.
    # On a curl-piped install SCRIPT_DIR won't have the subdir; fall back
    # to the npm registry.
    local local_pkg="${SCRIPT_DIR}/civitas-shell"
    if [[ -f "${local_pkg}/package.json" ]]; then
        log_info "Installing civitas-shell from local checkout…"
        sudo npm install -g "${local_pkg}"
    else
        log_info "Installing @civitasstudio/civitas-shell from npm registry…"
        sudo npm install -g @civitasstudio/civitas-shell
    fi

    if ! command -v civitas-shell &>/dev/null; then
        log_error "civitas-shell binary not found on PATH after install."
        return 1
    fi
    log_info "civitas-shell installed."
}
