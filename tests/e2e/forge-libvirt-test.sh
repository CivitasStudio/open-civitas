#!/usr/bin/env bash
# End-to-end test on Forge libvirt.
# Creates a fresh Ubuntu 26.04 VM, runs the installer, and validates via smoke test.
# Usage: ./forge-libvirt-test.sh [--preserve-on-fail]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$SCRIPT_DIR"
PRESERVE_ON_FAIL=0

[[ "${1:-}" == "--preserve-on-fail" ]] && PRESERVE_ON_FAIL=1

# ── Setup ──────────────────────────────────────────────────────────────────

VM_NAME="test-ubuntu-2604-opencivitas-$(date +%s)"
VM_USER="root"
CLOUD_INIT_ISO="/tmp/${VM_NAME}-cloud-init.iso"

log() { echo "[test] $*"; }
err() { echo "[test] ERROR: $*" >&2; exit 1; }

# ── Create cloud-init metadata for passwordless sudo ──────────────────────

create_cloud_init_iso() {
    log "Creating cloud-init ISO for passwordless sudo…"
    local tmpdir
    tmpdir=$(mktemp -d)

    cat > "$tmpdir/meta-data" <<'EOF'
instance-id: iid-local01
local-hostname: ubuntu
EOF

    cat > "$tmpdir/user-data" <<'EOF'
#cloud-config
users:
  - name: root
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
EOF

    mkisofs -output "$CLOUD_INIT_ISO" -volid cidata -joliet -rock \
        "$tmpdir/user-data" "$tmpdir/meta-data" 2>/dev/null
    rm -rf "$tmpdir"
    log "Cloud-init ISO created: $CLOUD_INIT_ISO"
}

# ── Create VM ──────────────────────────────────────────────────────────────

create_vm() {
    log "Creating VM: $VM_NAME"
    # Note: This is a simplified libvirt create. Adjust disk size, memory, CPU as needed for your Forge setup.
    virt-install \
        --name "$VM_NAME" \
        --memory 2048 \
        --vcpus 2 \
        --disk size=20 \
        --os-type linux \
        --os-variant ubuntu24.04 \
        --network bridge=br0 \
        --location "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-26.04-server-cloudimg-amd64.img" \
        --cloud-init user-data=/tmp/cloud-init.txt \
        --nographics \
        --console pty,target_type=serial \
        --wait=0 \
        2>&1 | grep -v "^$" || true

    log "VM creation queued. Waiting for network…"
    sleep 30
}

# ── Get VM IP ──────────────────────────────────────────────────────────────

get_vm_ip() {
    local max_retries=30
    local retry=0
    while [[ $retry -lt $max_retries ]]; do
        local ip
        ip=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep ipv4 | awk '{print $NF}' | cut -d/ -f1 || echo "")
        if [[ -n "$ip" && "$ip" != "127.0.0.1" ]]; then
            echo "$ip"
            return 0
        fi
        sleep 2
        (( retry++ )) || true
    done
    err "Could not get VM IP after $max_retries retries."
}

# ── Copy installer and run ─────────────────────────────────────────────────

run_installer() {
    local vm_ip="$1"
    log "Copying installer to $vm_ip…"
    scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "$REPO_ROOT/install.sh" \
        "$VM_USER@$vm_ip:/tmp/" || err "Failed to copy installer."

    log "Running installer on VM…"
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "$VM_USER@$vm_ip" \
        bash /tmp/install.sh --non-interactive \
        --agent-name "Forge Test" \
        --agent-role "E2E test build" \
        --user "ci" \
        --claude-cli n \
        --ollama n \
        || err "Installer failed."

    log "Installer completed."
}

# ── Copy and run smoke test ────────────────────────────────────────────────

run_smoke_test() {
    local vm_ip="$1"
    log "Copying smoke test to $vm_ip…"
    scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "$REPO_ROOT/scripts/smoke-test.sh" \
        "$VM_USER@$vm_ip:/tmp/" || err "Failed to copy smoke test."

    log "Running smoke test on VM…"
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "$VM_USER@$vm_ip" \
        bash /tmp/smoke-test.sh \
        || err "Smoke test failed."

    log "Smoke test passed!"
}

# ── Cleanup ────────────────────────────────────────────────────────────────

cleanup_vm() {
    local preserve="$1"
    if [[ $preserve -eq 1 ]]; then
        log "Preserving VM $VM_NAME for inspection."
        return 0
    fi

    log "Destroying VM $VM_NAME…"
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
    rm -f "$CLOUD_INIT_ISO"
    log "VM destroyed."
}

# ── Main ───────────────────────────────────────────────────────────────────

main() {
    log "Beginning E2E test on Forge libvirt…"

    create_cloud_init_iso
    create_vm
    local vm_ip
    vm_ip=$(get_vm_ip)
    log "VM IP: $vm_ip"

    if ! run_installer "$vm_ip"; then
        cleanup_vm "$PRESERVE_ON_FAIL"
        err "Installer failed."
    fi

    if ! run_smoke_test "$vm_ip"; then
        cleanup_vm "$PRESERVE_ON_FAIL"
        err "Smoke test failed."
    fi

    cleanup_vm 0
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "✓ E2E test passed."
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"
