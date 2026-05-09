# Development Guide

## Local Testing

### Prerequisites

- Bash 4+
- Git
- Access to a test Ubuntu 26.04 VM (local or Forge)
- `jq` (for config validation)

### Quick Test Locally

If you have a Ubuntu 26.04 VM available (local libvirt, Proxmox, etc.):

```bash
# Copy installer to the VM
scp install.sh user@vm:/tmp/

# SSH in and run
ssh user@vm
/tmp/install.sh --non-interactive \
  --agent-name "TestAgent" \
  --agent-role "Development test" \
  --user "testuser" \
  --claude-cli n \
  --ollama n

# Run smoke test
/tmp/scripts/smoke-test.sh
```

### Testing on Forge

Forge is the official testing environment. It has libvirt + Docker for fresh-VM testing.

#### Setup (one-time)

```bash
ssh forge
cd /home/wayland/open-civitas
```

#### Create a test VM

```bash
# Create a fresh Ubuntu 26.04 VM (takes ~2 min)
virt-install \
  --name test-ubuntu-2604-$(date +%s) \
  --memory 2048 \
  --vcpus 2 \
  --disk size=20 \
  --os-type linux \
  --os-variant ubuntu24.04 \
  --network bridge=br0 \
  --location http://archive.ubuntu.com/ubuntu/dists/noble-updates/main/installer-amd64/ \
  --nographics \
  --console pty,target_type=serial

# Wait for install to complete. Then:
virsh start test-ubuntu-2604-XXXX
```

#### Run the installer

```bash
# Get the VM's IP
virsh domifaddr test-ubuntu-2604-XXXX

# SCP installer
scp install.sh root@<vm-ip>:/tmp/

# SSH in and run with passwordless sudo pre-configured
ssh root@<vm-ip>
/tmp/install.sh --non-interactive \
  --agent-name "Forge Test" \
  --agent-role "CI test build" \
  --user "forge" \
  --claude-cli n \
  --ollama n
```

#### Run smoke test

```bash
scp scripts/smoke-test.sh root@<vm-ip>:/tmp/
ssh root@<vm-ip> bash /tmp/smoke-test.sh
```

#### Destroy test VM

```bash
virsh destroy test-ubuntu-2604-XXXX
virsh undefine test-ubuntu-2604-XXXX
```

## Code Changes

### Structure

```
install.sh              # Main entry point
lib/
  detect.sh            # OS, Node, GPU detection
  install-substrate.sh # Core substrate: Node, OpenClaw, systemd, linger
  workspace.sh         # Workspace skeleton + openclaw.json generation
  install-claude-cli.sh
  install-ollama.sh
templates/
  workspace/
    AGENTS.md.tmpl
    SOUL.md.tmpl
    IDENTITY.md.tmpl
    USER.md.tmpl
    MEMORY.md.tmpl
    HEARTBEAT.md
systemd/
  openclaw-gateway.service
scripts/
  smoke-test.sh        # Non-interactive validator
```

### Making Changes

1. **Edit the relevant lib file** (e.g., `lib/install-substrate.sh` for substrate changes).
2. **Test locally or on Forge** per instructions above.
3. **Update `docs/` if the user journey changes** (e.g., new prompts, new dependencies).
4. **Add test coverage to `scripts/smoke-test.sh` if you add new assertions**.

### Common Edits

**Adding a new optional component (e.g., "Install X?"):**
1. Create `lib/install-x.sh` with an `install_x()` function.
2. Add a `--x [y|n]` flag to `install.sh`.
3. Add a prompt in `gather_optional_installs()`.
4. Call `install_x` in `main()` if the user chose yes.
5. Add smoke-test assertion if the install should be validated.

**Changing workspace templates:**
1. Edit the `.tmpl` files in `templates/workspace/`.
2. Check that `lib/workspace.sh`'s `render_template()` function covers all placeholders.
3. Add new placeholders as needed (e.g., `{{NEW_VAR}}`).

**Changing the config shape:**
1. Edit `lib/workspace.sh`'s `generate_openclaw_json()` function (it's hardcoded JSON).
2. Update `docs/reference/openclaw.json.example` to match.
3. Add a smoke-test assertion if the config structure is critical.

## Debugging

### Check install logs

```bash
tail -200 ~/.openclaw/install.log
```

### Check gateway logs

```bash
journalctl --user -u openclaw-gateway -n 100
```

### Inspect config

```bash
cat ~/.openclaw/openclaw.json | jq .
```

### Inspect workspace

```bash
ls -la ~/.openclaw/workspace/
cat ~/.openclaw/workspace/AGENTS.md
```

## CI / Automated Testing

For phase 2+, we'll add GitHub Actions CI that:
1. Spins up a fresh Forge VM.
2. Runs the installer in non-interactive mode.
3. Runs `scripts/smoke-test.sh`.
4. Tears down the VM.

For now, manual testing on Forge is the standard.

## Versioning

Open Civitas follows the upstream OpenClaw versioning pattern. v0 = MVP. Phase 1 = current. Versions ship as git tags (e.g., `v0.1.0`).

## Gotchas to Watch

- **Workspace path must be absolute.** The spec explicitly forbids placeholders like `<user>`. `lib/workspace.sh` validates this before writing.
- **Idempotency is hard.** Every step must detect "already done" state and skip cleanly. Test re-running the installer on a non-fresh VM.
- **HEARTBEAT.md empty by default.** An empty file signals OpenClaw to skip heartbeat API calls. Don't accidentally add content unless that's intentional.
- **GPIO/hardware.**If testing Ollama, make sure the test VM has access to GPU if you enabled GPU detection. Fallback to CPU-only (`gemma4:e4b`) works but is slower.

## Questions?

Ask on GitHub issues: https://github.com/civitasstudio/open-civitas/issues
