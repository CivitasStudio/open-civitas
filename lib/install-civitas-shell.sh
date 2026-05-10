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
        # Pack into a tarball first — "npm install -g <dir>" on modern npm
        # (≥v7) symlinks the source dir rather than copying it, which breaks
        # dep resolution when source node_modules/ isn't populated.  Installing
        # from a tarball forces a real copy with deps resolved from the registry.
        log_info "Packing civitas-shell from local checkout…"
        local tarball
        tarball=$(cd "${local_pkg}" && npm pack --json 2>/dev/null \
            | grep '"filename"' \
            | sed 's/.*"filename":[[:space:]]*"\([^"]*\)".*/\1/' \
            | head -1)
        if [[ -z "$tarball" ]]; then
            log_error "npm pack did not produce a tarball filename."
            return 1
        fi
        local tarball_path="${local_pkg}/${tarball}"
        log_info "Installing civitas-shell from packed tarball…"
        sudo npm install -g "${tarball_path}"
        rm -f "${tarball_path}"
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
