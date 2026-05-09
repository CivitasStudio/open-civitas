# E2E Testing on Forge

## Manual Test Procedure

This procedure creates a fresh Ubuntu 26.04 VM on Forge, runs the installer, and validates it with the smoke test.

### Prerequisites

- SSH access to `forge`
- `virt-install` and `virsh` available on Forge
- An Ubuntu 26.04 cloud image or ISO available

### Step 1: Create a fresh Ubuntu 26.04 VM

On Forge:

```bash
# Create a VM with a dated name
VM_NAME="test-ubuntu-2604-$(date +%Y%m%d-%s)"

virt-install \
  --name "$VM_NAME" \
  --memory 2048 \
  --vcpus 2 \
  --disk size=20 \
  --os-type linux \
  --os-variant ubuntu24.04 \
  --network bridge=br0 \
  --cdrom /path/to/ubuntu-26.04-server-amd64.iso \
  --nographics \
  --console pty,target_type=serial \
  --wait=0

# Wait for the VM to boot and get an IP
sleep 60
virsh domifaddr "$VM_NAME"
```

Alternatively, use a cloud image:

```bash
# This requires pre-configured cloud-init, which is beyond scope here.
# For now, use the ISO approach above.
```

### Step 2: Set up passwordless sudo on the VM

SSH into the VM and add your user to sudoers:

```bash
ssh root@<vm-ip>
echo "root ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
```

### Step 3: Copy and run the installer

```bash
scp install.sh root@<vm-ip>:/tmp/

ssh root@<vm-ip> \
  bash /tmp/install.sh --non-interactive \
  --agent-name "Forge Test" \
  --agent-role "E2E validation build" \
  --user "ci" \
  --claude-cli n \
  --ollama n
```

Check the installer log if anything fails:

```bash
ssh root@<vm-ip> tail -100 ~/.openclaw/install.log
```

### Step 4: Run the smoke test

```bash
scp scripts/smoke-test.sh root@<vm-ip>:/tmp/

ssh root@<vm-ip> bash /tmp/smoke-test.sh
```

Expected output:

```
Testing: openclaw-gateway.service is active… PASS
Testing: linger enabled for root… PASS
Testing: ~/.openclaw/workspace/AGENTS.md exists… PASS
...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Smoke Test Results
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PASSED: <N>
FAILED: 0

✓ All smoke tests passed.
```

### Step 5: Verify the agent identity (manual)

After the installer completes, you'd normally run `openclaw setup` to configure a channel and provider, then test the agent. This is out of scope for the automated smoke test but important for full validation.

### Step 6: Destroy the VM

```bash
virsh destroy "$VM_NAME"
virsh undefine "$VM_NAME" --remove-all-storage
```

If the test failed, preserve the VM for inspection:

```bash
virsh destroy "$VM_NAME"
# Don't undefine — leave it for inspection
# Later: virsh undefine "$VM_NAME" --remove-all-storage
```

## Automated Test Script (WIP)

`forge-libvirt-test.sh` is a work-in-progress automated test runner. It attempts to automate the above procedure but has dependencies on specific cloud-init and libvirt configurations. For now, the manual procedure above is more reliable.

## Debugging

If the smoke test fails, SSH into the VM and check:

```bash
# Installer log
tail -100 ~/.openclaw/install.log

# Gateway status
systemctl --user status openclaw-gateway
journalctl --user -u openclaw-gateway -n 100

# Workspace files
ls -la ~/.openclaw/workspace/
cat ~/.openclaw/openclaw.json | jq .

# Health endpoint
curl -s http://localhost:18789/health
```

## Success Criteria

The installer passes Phase 1 when:
1. Installation completes without errors on a fresh Ubuntu 26.04 VM.
2. All 7+ smoke-test assertions pass.
3. Gateway is active and responding on `/health`.
4. Workspace files are seeded with the correct values.
5. `openclaw.json` has `agents.defaults.workspace` set to an absolute path (no placeholders).
6. Idempotency: re-running the installer skips already-installed components and produces no errors.

## Reporting Results

After manual testing on Forge, update the daily memory file and notify Alex/John of the results.
