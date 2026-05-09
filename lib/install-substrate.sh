#!/usr/bin/env bash
# Substrate installation: Node LTS, OpenClaw, systemd user unit, linger.
# Sourced by install.sh — expects OPENCLAW_LOG and SCRIPT_DIR to be set.
set -euo pipefail

NODESOURCE_SETUP_URL="https://deb.nodesource.com/setup_lts.x"
SYSTEMD_UNIT_SRC="${SCRIPT_DIR}/systemd/openclaw-gateway.service"
SYSTEMD_UNIT_DST="${HOME}/.config/systemd/user/openclaw-gateway.service"

install_node() {
    local current_version
    current_version=$(node --version 2>/dev/null || echo "")

    if [[ -n "$current_version" ]]; then
        log_info "Node already installed ($current_version), skipping."
        return 0
    fi

    log_info "Installing Node LTS via NodeSource…"
    local setup_script
    setup_script=$(mktemp /tmp/nodesource-setup.XXXXXX.sh)
    curl -fsSL "$NODESOURCE_SETUP_URL" -o "$setup_script"
    sudo bash "$setup_script"
    rm -f "$setup_script"
    sudo apt-get install -y nodejs
    log_info "Node installed: $(node --version)"
}

install_openclaw() {
    local current_version
    current_version=$(openclaw --version 2>/dev/null | head -1 || echo "")

    if [[ -n "$current_version" ]]; then
        log_info "OpenClaw already installed ($current_version), skipping."
        return 0
    fi

    log_info "Installing OpenClaw (latest stable)…"
    sudo npm install -g openclaw@latest
    log_info "OpenClaw installed: $(openclaw --version 2>/dev/null | head -1)"
}

install_systemd_unit() {
    if [[ ! -f "$SYSTEMD_UNIT_SRC" ]]; then
        log_error "systemd unit not found at $SYSTEMD_UNIT_SRC"
        return 1
    fi

    mkdir -p "$(dirname "$SYSTEMD_UNIT_DST")"

    if [[ -f "$SYSTEMD_UNIT_DST" ]]; then
        if cmp -s "$SYSTEMD_UNIT_SRC" "$SYSTEMD_UNIT_DST"; then
            log_info "systemd unit already installed and current, skipping."
            return 0
        fi
        log_info "Updating systemd unit (changed)…"
        systemctl --user stop openclaw-gateway 2>/dev/null || true
    fi

    cp "$SYSTEMD_UNIT_SRC" "$SYSTEMD_UNIT_DST"
    systemctl --user daemon-reload
    log_info "systemd unit installed at $SYSTEMD_UNIT_DST"
}

enable_linger() {
    local linger_status
    linger_status=$(loginctl show-user "$USER" 2>/dev/null | grep "^Linger=" | cut -d= -f2 || echo "no")

    if [[ "$linger_status" == "yes" ]]; then
        log_info "Linger already enabled for $USER, skipping."
        return 0
    fi

    log_info "Enabling linger for $USER…"
    sudo loginctl enable-linger "$USER"
    log_info "Linger enabled."
}

start_gateway() {
    log_info "Enabling and starting openclaw-gateway…"
    systemctl --user enable openclaw-gateway
    systemctl --user start openclaw-gateway

    local deadline=$(( SECONDS + 30 ))
    local ok=0
    while [[ $SECONDS -lt $deadline ]]; do
        local status
        status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:18789/health 2>/dev/null || echo "000")
        if [[ "$status" == "200" ]]; then
            ok=1
            break
        fi
        sleep 1
    done

    if [[ $ok -eq 0 ]]; then
        log_error "Gateway did not come up within 30s. Check: journalctl --user -u openclaw-gateway -n 50"
        return 1
    fi
    log_info "Gateway is up (http://localhost:18789/health → 200)."
}

install_substrate() {
    install_node
    install_openclaw
    install_systemd_unit
    enable_linger
}
