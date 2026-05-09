#!/usr/bin/env bash
# Optional: install Ollama and pull a recommended model.
# Sourced by install.sh — expects detect.sh functions to be available.
set -euo pipefail

OLLAMA_INSTALL_URL="https://ollama.ai/install.sh"

install_ollama() {
    if command -v ollama &>/dev/null; then
        log_info "Ollama already installed ($(ollama --version 2>/dev/null | head -1)), skipping."
    else
        log_info "Installing Ollama…"
        local setup_script
        setup_script=$(mktemp /tmp/ollama-install.XXXXXX.sh)
        curl -fsSL "$OLLAMA_INSTALL_URL" -o "$setup_script"
        bash "$setup_script"
        rm -f "$setup_script"
        log_info "Ollama installed: $(ollama --version 2>/dev/null | head -1)"
    fi

    # Ensure ollama service is running before we try to pull.
    if ! systemctl is-active --quiet ollama 2>/dev/null; then
        log_info "Starting ollama service…"
        sudo systemctl enable --now ollama 2>/dev/null || true
        sleep 3
    fi

    local gpu vram_mib suggested_model
    gpu=$(detect_gpu)
    vram_mib=$(detect_vram_mib)
    suggested_model=$(suggest_ollama_model)

    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Ollama model selection"
    log_info "  GPU detected: ${gpu} | VRAM: ${vram_mib} MiB"
    log_info "  Suggested model: ${suggested_model}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local chosen_model
    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        chosen_model="$suggested_model"
        log_info "  [non-interactive] Using suggested model: $chosen_model"
    else
        log_info "  Press Enter to accept the suggestion, or type a different model name."
        read -r -p "  Model to pull [$suggested_model]: " user_model
        chosen_model="${user_model:-$suggested_model}"
    fi

    # Check if model is already present.
    if ollama list 2>/dev/null | grep -q "^${chosen_model}"; then
        log_info "Model $chosen_model already present, skipping pull."
    else
        log_info "Pulling $chosen_model (this may take a while)…"
        ollama pull "$chosen_model"
        log_info "Model $chosen_model ready."
    fi

    # Remind about firewall if Ollama will be shared across VLANs.
    log_info ""
    log_info "  NOTE: If other agents on different VLANs will use this Ollama instance,"
    log_info "  open TCP/11434 in your firewall from those VLANs to this host."
    log_info "  Test connectivity: curl -s http://<this-host>:11434/api/tags"
    log_info ""
}
