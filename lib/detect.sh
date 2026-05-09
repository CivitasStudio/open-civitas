#!/usr/bin/env bash
# Detection helpers — sourced by install.sh and lib/*.sh.
# All functions print to stdout and return 0 on success, non-zero on failure.
set -euo pipefail

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        echo "UNKNOWN"
        return 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "${ID:-UNKNOWN}:${VERSION_ID:-UNKNOWN}"
}

assert_ubuntu_2604() {
    local os_info
    os_info=$(detect_os)
    local distro version
    distro="${os_info%%:*}"
    version="${os_info##*:}"
    if [[ "$distro" != "ubuntu" || "$version" != "26.04" ]]; then
        echo "ERROR: Open Civitas v0 requires Ubuntu 26.04 LTS. Detected: $os_info" >&2
        return 1
    fi
}

assert_passwordless_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo "ERROR: passwordless sudo is required. Add '$USER ALL=(ALL) NOPASSWD:ALL' to /etc/sudoers." >&2
        return 1
    fi
}

detect_node_version() {
    if command -v node &>/dev/null; then
        node --version 2>/dev/null || echo ""
    else
        echo ""
    fi
}

detect_openclaw_version() {
    if command -v openclaw &>/dev/null; then
        openclaw --version 2>/dev/null | head -1 || echo ""
    else
        echo ""
    fi
}

# GPU detection — prints one of: nvidia, amd, none
detect_gpu() {
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        echo "nvidia"
        return 0
    fi
    if command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null; then
        echo "amd"
        return 0
    fi
    # Fallback: check lspci for common GPU strings
    if command -v lspci &>/dev/null; then
        if lspci 2>/dev/null | grep -iq "nvidia"; then
            echo "nvidia"
            return 0
        fi
        if lspci 2>/dev/null | grep -iq "amd\|radeon"; then
            echo "amd"
            return 0
        fi
    fi
    echo "none"
}

# VRAM in MiB (0 if unknown / no GPU)
detect_vram_mib() {
    local gpu
    gpu=$(detect_gpu)
    case "$gpu" in
        nvidia)
            if command -v nvidia-smi &>/dev/null; then
                nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
                    | awk '{s+=$1} END {print int(s)}' || echo 0
            else
                echo 0
            fi
            ;;
        amd)
            if command -v rocm-smi &>/dev/null; then
                # rocm-smi reports in bytes; convert to MiB
                rocm-smi --showmeminfo vram --csv 2>/dev/null \
                    | awk -F',' '/[0-9]/{s+=$2} END {printf "%d", s/1048576}' || echo 0
            else
                echo 0
            fi
            ;;
        *)
            echo 0
            ;;
    esac
}

# Suggest an Ollama model based on available VRAM.
# Prints model name to stdout.
suggest_ollama_model() {
    local vram_mib
    vram_mib=$(detect_vram_mib)
    # 16 GiB = 16384 MiB
    if [[ "$vram_mib" -ge 16384 ]]; then
        echo "gemma4:26b"
    else
        echo "gemma4:e2b"
    fi
}
