# Open Civitas Phase 4 — Bootable ISO Spec

**Status:** Draft v1 — awaiting Alex review.
**Author:** Wayland
**Date:** 2026-05-15
**Scope:** Bootable Ubuntu 26.04 LTS ISO with a 3-question pre-flight TUI, Subiquity autoinstall, and first-boot brain provisioning. v0 = single-user agent appliance; cloud-init and multi-user out of scope.

---

## Mission

Phase 4 makes Open Civitas installable by anyone with a USB stick. The operator boots the ISO, answers 3 questions, watches Subiquity do the rest, and reboots directly into `civitas-shell` talking to their named agent on their chosen brain. No post-install configuration should be needed for local (Ollama) brains. API/OAuth brains surface their one required step as the agent's first chat turn.

---

## 1. Pre-flight TUI

### 1.1 Design

A three-question fullscreen TUI that runs before Subiquity starts. It captures:

1. **Language** — `[English ▼]` (default; list includes any language Subiquity supports; v0 ships English + a handful of common options; more added iteratively)
2. **Name** — free text input, validated: 3–32 chars, `[a-z][a-z0-9-]*`, lowercase-enforced. Becomes both the Linux username and the agent name.
3. **Brain** — dropdown (see §1.2). One item selected; annotation shown inline.

After answers are collected, the screen shows a summary and two buttons:

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   Open Civitas Installer                                         │
│                                                                  │
│   Language:  English                                             │
│   Name:      alice                                               │
│   Brain:     Anthropic Claude CLI  [OAuth required after boot]   │
│                                                                  │
│      [ Install ]       [ Advanced (Subiquity) ]                  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**Install** — writes answers to `/run/civitas/preflight.json`, then launches Subiquity in fully automated mode using the generated `autoinstall.yaml`.

**Advanced (Subiquity)** — drops the user into Subiquity's interactive installer. Answers from the pre-flight screen are pre-populated where Subiquity has equivalents (hostname = `<name>`, username = `<name>`); brain choice is written to `/run/civitas/preflight.json` for the post-install firstboot script to consume.

### 1.2 Brain Dropdown

Full provider list, one entry per row, annotation shown in a dimmed column to the right:

| Option | Display string | Annotation (shown inline) |
|---|---|---|
| `anthropic-cli` | Anthropic Claude CLI | `[OAuth required after boot]` |
| `anthropic-api` | Anthropic API | `[API key required after boot]` |
| `openai` | OpenAI | `[API key required after boot]` |
| `gemini` | Google Gemini | `[API key required after boot]` |
| `mistral` | Mistral | `[API key required after boot]` |
| `cohere` | Cohere | `[API key required after boot]` |
| `ollama+gemma-local` | Local Gemma (Ollama) | `[~8 GB download at first boot; no key]` |

Default selection: `ollama+gemma-local` — it's the only option that works out of the box after the first-boot pull.

"Annotate" means the annotation text is always visible in the dropdown row, not hidden in a tooltip. The operator reads it before committing.

### 1.3 TUI Technology — Proposal

**Proposal: Python + `dialog` (pre-Subiquity systemd service)**

Rationale:
- `dialog` is available in the Ubuntu live environment without additional packages. It produces POSIX-standard TUI forms (ncurses-backed) and handles navigation, input validation, and button selection cleanly with a minimal script.
- Alternatives considered:
  - **Subiquity interactive section** — Subiquity supports `interactive-sections` in `autoinstall.yaml`, but the documented hook surface is thin, the Python internals are complex, and adding custom screens requires forking Subiquity or writing a Subiquity plugin. Fragile against upstream upgrades.
  - **Node/ink (our existing stack)** — clean rendering, but Node is not present in the Ubuntu live/installer environment and adding it bloats the initrd. Not worth it for a 3-question form.
  - **Python + urwid / textual** — richer than `dialog` but adds a dependency that isn't in the Ubuntu live environment by default.

**Mechanism:**

A systemd service `civitas-preflight.service` added to the live environment with `Before=subiquity.service After=getty@tty1.service`. It runs `/usr/lib/civitas/preflight.py` on tty1, captures answers into `/run/civitas/preflight.json`, then exits — Subiquity starts normally after it.

```
/usr/lib/civitas/preflight.py     # TUI script
/usr/lib/civitas/generate-autoinstall.py  # reads preflight.json → writes /run/civitas/autoinstall.yaml
```

Subiquity is invoked with `autoinstall ds=nocloud;s=/run/civitas/` on the kernel cmdline when **Install** is chosen.

---

## 2. ISO Build Approach

### 2.1 Base and Build Method

- **Base:** Ubuntu 26.04 LTS Server (live installer ISO, not the mini ISO — live ISO includes Subiquity).
- **Method:** Extract the base ISO, inject a civitas overlay into the squashfs (and/or the ISO filesystem for GRUB/kernel cmdline changes), repack with `xorriso`.

No bespoke build system (cubic, live-build, ubuntu-image). Reason: a shell script + xorriso is auditable, has no extra runtime deps on Forge, and matches the complexity of what we're actually doing (adding files to a known-good Ubuntu ISO).

### 2.2 `tools/build-iso.sh` Interface

```
tools/build-iso.sh [OPTIONS]

Options:
  --base-iso <path>    Path to Ubuntu 26.04 LTS server ISO (downloaded if absent)
  --output <path>      Output ISO path (default: dist/opencivitas-v0-<date>.iso)
  --no-download        Fail if base ISO is not present (CI mode)
  --version <tag>      opencivitas version tag to embed (default: git describe)
  -h, --help
```

The script:
1. Verifies or downloads the base Ubuntu 26.04 LTS server ISO (checksum verified against SHA256SUMS from releases.ubuntu.com).
2. Mounts the ISO (loop mount, read-only).
3. Copies ISO contents to a staging directory.
4. Extracts and modifies the squashfs:
   - Adds `/usr/lib/civitas/` overlay (preflight TUI scripts, firstboot scripts, systemd units).
   - Adds `civitas-preflight.service` and `civitas-firstboot.service`.
   - Installs `dialog` into the squashfs (via `chroot apt-get install -y dialog` or pre-downloaded deb).
5. Updates GRUB menu: adds an `Open Civitas` entry with `autoinstall ds=nocloud;s=/run/civitas/` — and retains the default Ubuntu installer entry as fallback.
6. Repacks squashfs, updates `md5sum.txt`, calls `xorriso` to produce the output ISO.

All staging under `/tmp/civitas-iso-build-<pid>/`, cleaned up on exit.

### 2.3 Artifact Size and Publishing

**Size target:** ≤ 2.5 GB. Ubuntu server ISO is ~1.5 GB; our overlay is kilobytes. No brain model is baked in — `ollama+gemma-local` pulls at first boot.

**Publishing — v0:** GitHub release asset on the `open-civitas` repo. The build script's `--output` feeds directly into a GitHub release workflow. No CDN or separate hosting for v0. Skip publishing infrastructure entirely for the spec PR; implement in a sub-step alongside the build script.

---

## 3. First-Boot Bootstrap

### 3.1 Autoinstall → OS State

The generated `autoinstall.yaml` creates:
- User `<name>` with the chosen username; `sudo` group; no password (SSH key or manual `passwd` expected, but v0 doesn't enforce it — note this as a v1 hardening item).
- Hostname `<name>` (e.g., `alice`).
- `/etc/civitas/preflight.json` written by the installer from `/run/civitas/preflight.json` — persists across reboot, holds `{name, brain, language}`.
- `civitas-firstboot.service` enabled; runs once on first boot, marks itself done.

### 3.2 Auto-login and Shell

`civitas-firstboot.service` (or the autoinstall `late-commands`) configures:
- `getty@tty1.service` overridden with a drop-in that adds `--autologin <name>`.
- `<name>`'s login shell set to `civitas-shell --login-shell` via `chsh` in `late-commands`.

Result: first console boot lands directly in `civitas-shell`. No login prompt.

### 3.3 Brain Provisioning at First Boot

`civitas-firstboot.service` reads `/etc/civitas/preflight.json` and:

1. Writes `~/.openclaw/openclaw.json` with the appropriate `defaultModel` / provider block for the chosen brain.
2. Runs provider-specific setup:

| Brain | First-boot action |
|---|---|
| `ollama+gemma-local` | `ollama serve &` then `ollama pull gemma4:26b` in background; writes a sentinel `/var/lib/civitas/model-pulling` |
| `anthropic-cli` | Writes `openclaw.json` with `claude-cli` provider; no OAuth yet — deferred to first chat turn |
| `anthropic-api` | Writes `openclaw.json` with `anthropic` provider, placeholder `ANTHROPIC_API_KEY`; deferred to first chat turn |
| `openai` | Same pattern as anthropic-api |
| `gemini` | Same pattern as anthropic-api |
| `mistral` | Same pattern as anthropic-api |
| `cohere` | Same pattern as anthropic-api |

3. Installs `civitas-shell` if not already present (`npm install -g @civitasstudio/civitas-shell`; Node is installed by the main `install.sh` which runs in `late-commands`).
4. Removes `civitas-firstboot.service` from the enabled units (runs once, never again).

### 3.4 First Chat Turn Wording

**Case: Anthropic CLI (OAuth required)**

The agent's SOUL.md is pre-written with `name` and `brain` from `preflight.json`. `openclaw.json` is configured for `anthropic-cli` but no OAuth has been done. When OpenClaw tries to invoke the model it will fail. The agent's greeting turn (generated by civitas-shell's first `chat.history` call, or as the first message from the system prompt) should not assume connectivity.

Instead, `civitas-shell --login-shell` detects the `civitas.pendingAuth` flag in `openclaw.json` (written by firstboot) and **before** connecting to the gateway, prints a framed one-time prompt directly to the terminal:

```
┌──────────────────────────────────────────────────────────────────┐
│  One-time setup                                                  │
│                                                                  │
│  Hi, I'm <Name>. To finish setup, authenticate with Anthropic:  │
│                                                                  │
│    Type /bash, then run:                                         │
│      claude login --claudeai                                     │
│    Then type exit to come back.                                  │
│                                                                  │
│  Press Enter to continue.                                        │
└──────────────────────────────────────────────────────────────────┘
```

After the operator completes OAuth and returns via `exit`, civitas-shell clears `civitas.pendingAuth` in `openclaw.json` and proceeds normally. This turn is rendered by civitas-shell, not the agent — the gateway never sees it, so no model call happens before auth is complete.

**Case: API-key brains**

Same framed prompt, different body:

```
│  Hi, I'm <Name>. To finish setup, set your API key:             │
│                                                                  │
│    Type /bash, then run:                                         │
│      openclaw config set providers.<provider>.apiKey <YOUR_KEY> │
│    Then type exit to come back.                                  │
```

(Exact `openclaw config set` syntax TBD during 4e implementation; verify against gateway config schema at that time.)

**Case: Ollama+Gemma (model still pulling)**

civitas-shell checks `/var/lib/civitas/model-pulling` on launch. If present, it shows a non-blocking status line instead of the auth frame:

```
│  Still downloading Gemma (~8 GB). Check progress: /bash → ollama ps  │
│  I'll be ready when the pull completes. Come back in a few minutes.   │
```

Shell is still usable — the operator can `/bash` to monitor `ollama ps` or just wait. civitas-shell polls `/var/lib/civitas/model-pulling` (file is removed by a watcher when `ollama pull` exits 0) and updates the status line automatically.

---

## 4. Test Plan

**Verification target: fresh libvirt VM on Forge. Not Bob.**

Bob stays up; test installs use a fresh ephemeral VM to prove ISO correctness, not incidentally work because Bob's environment is known-good.

### 4.1 Manual Verification Steps (per sub-step)

For each sub-step (4b–4f), Alex runs an independent manual verification on Forge. Wayland runs a scripted check first; Alex runs the final sign-off.

**E2E flow (4f):**
1. `tools/build-iso.sh --output dist/opencivitas-test.iso` on Forge.
2. `tests/e2e/install-test.sh` (see §4.2) boots a fresh libvirt VM from the ISO.
3. Automation drives the pre-flight TUI (3 answers: English, `testuser`, `ollama+gemma-local`).
4. Subiquity runs unattended, VM reboots.
5. Script waits for first-boot to complete (polls SSH availability).
6. Checks:
   - `ssh testuser@<vm-ip> 'pgrep civitas-shell || echo FAIL'`
   - `ssh testuser@<vm-ip> 'civitas-shell --noninteractive --send "Who are you?"'` → response identifies as `testuser`.
   - `/var/lib/civitas/model-pulling` is gone (Gemma pull completed).
   - No non-loopback traffic from civitas-shell during the session.
7. VM is torn down.

### 4.2 Libvirt Automation Script

`tests/e2e/install-test.sh` interface:

```
tests/e2e/install-test.sh [OPTIONS]

Options:
  --iso <path>         ISO to test (required)
  --name <vm-name>     libvirt domain name (default: test-civitas-<date>-<rand>)
  --brain <brain>      Brain to select in TUI (default: ollama+gemma-local)
  --agent-name <name>  Agent name to enter in TUI (default: testuser)
  --keep               Don't destroy the VM after test (for inspection)
  -h, --help
```

The script uses `virt-install` to create the VM, then drives the pre-flight TUI via `virsh console` + `expect` (or Python `pexpect`) to send keystrokes and read output. After install:
- Polls for SSH readiness (`ssh-keyscan` with timeout).
- Runs verification commands over SSH.
- Prints PASS/FAIL with the failing check if any.
- Destroys and undefines the VM unless `--keep`.

VM naming convention: `test-civitas-<YYYY-MM-DD>-<agent-name>`. Cleanup discipline: `tests/e2e/list-vms.sh` lists all test VMs on Forge; teardown is explicit via `--keep` absence.

### 4.3 Alex Sign-off Per Sub-step

Same pattern as Phase 3: Wayland pings Alex at end of each sub-step; Alex re-runs the sub-step's verification independently on Forge; sign-off file lands in `~/.openclaw/workspace/inbox/`.

---

## 5. Sub-step Breakdown

Five sub-steps, each ending with a verifiable artifact and an inbox sign-off. Ordered to build bottom-up: TUI first (testable standalone), then ISO plumbing, then integration, then firstboot, then E2E.

### 4b — Pre-flight TUI (standalone, ~1 day)

**Scope:**
- `scripts/preflight/preflight.py` — `dialog`-based 3-question TUI (language, name, brain) with inline annotations.
- `scripts/preflight/generate-autoinstall.py` — reads `preflight.json`, writes `autoinstall.yaml`.
- Unit-testable without ISO: run `preflight.py --test-mode` on Forge, drive it with `expect`, verify `preflight.json` output.
- `civitas-preflight.service` unit file (not yet injected into an ISO).

**Verify:**
- Run `python3 preflight.py --test-mode` on Forge (no live ISO needed). `expect` script drives it: selects English, enters `testuser`, selects `ollama+gemma-local`. Checks output JSON. Then selects `anthropic-cli` — verifies `[OAuth required after boot]` annotation appears on that row.
- `generate-autoinstall.py` reads the output, emits valid `autoinstall.yaml`.

---

### 4c — ISO build tooling (~1–2 days)

**Scope:**
- `tools/build-iso.sh` (full interface per §2.2).
- Downloads and checksums Ubuntu 26.04 LTS server ISO if not present.
- Injects civitas overlay into squashfs, updates GRUB menu entry, repacks with `xorriso`.
- Produces a bootable ISO at `dist/`.
- Does NOT yet include firstboot scripts or pre-flight TUI — those are in the overlay, but they can be stubs.

**Verify:**
- `tools/build-iso.sh --output dist/test.iso` on Forge completes without error.
- `xorriso -indev dist/test.iso -report_el_torito plain` — confirms bootable ISO structure.
- Boot the ISO in a libvirt VM (`virt-install` one-liner): GRUB menu appears with Open Civitas entry. Boot into it — Ubuntu installer starts.
- Confirm `civitas-preflight.service` is in `systemctl list-unit-files` in the live environment (even if the script is a stub that immediately exits).

---

### 4d — Autoinstall integration (~1 day)

**Scope:**
- Real `preflight.py` wired into the live environment: runs on tty1 before Subiquity, writes `/run/civitas/preflight.json`, then Subiquity starts with the generated `autoinstall.yaml`.
- `autoinstall.yaml` template: creates user `<name>`, sets hostname `<name>`, writes `/etc/civitas/preflight.json` via `late-commands`, enables `civitas-firstboot.service`, runs `install.sh --with-civitas-shell` via `late-commands`.
- `chsh` + getty autologin drop-in configured in `late-commands`.

**Verify:**
- Fresh libvirt VM from the ISO.
- Automation drives the pre-flight TUI (3 questions) → clicks Install.
- Subiquity runs unattended. VM reboots.
- `ssh testuser@<vm-ip> 'id'` → `uid=1000(testuser)`.
- `ssh testuser@<vm-ip> 'getent passwd testuser | cut -d: -f7'` → `/usr/bin/civitas-shell`.
- `ssh testuser@<vm-ip> 'cat /etc/civitas/preflight.json'` → correct JSON.
- `civitas-firstboot.service` still enabled (not yet run in this sub-step — firstboot is 4e).

---

### 4e — First-boot bootstrap (~1–2 days)

**Scope:**
- `civitas-firstboot.service` + `scripts/firstboot.sh` — reads `/etc/civitas/preflight.json`, writes `openclaw.json`, does brain-specific provisioning, disables itself.
- Ollama + Gemma pull flow (background pull, `/var/lib/civitas/model-pulling` sentinel, watcher).
- `civitas.pendingAuth` flag in `openclaw.json` for OAuth/API-key brains.
- `civitas-shell` changes: reads `pendingAuth` on launch, renders framed one-time setup prompt; polls `model-pulling` sentinel with status-line updates.

**Verify (Ollama+Gemma path):**
- Boot the 4d VM (or a fresh one) all the way through. Wait for firstboot to complete.
- `ssh testuser@<vm-ip> 'systemctl --user status openclaw-gateway'` → active.
- `ssh testuser@<vm-ip> 'civitas-shell --noninteractive --send "Who are you?"'` → response identifies as `testuser`, mentions Gemma/Ollama.
- `/var/lib/civitas/model-pulling` is absent (pull complete).

**Verify (anthropic-cli path — requires a real Anthropic CLI token):**
- Can be tested with a mock: `civitas-shell --noninteractive --preflight-check` (new flag, emits the pending-auth text to stdout without connecting). Confirms the framing is correct.
- Full OAuth path tested manually by Alex (he has an Anthropic account).

---

### 4f — E2E test + libvirt automation (~1 day)

**Scope:**
- `tests/e2e/install-test.sh` (full interface per §4.2).
- `tests/e2e/list-vms.sh` — lists all test VMs on Forge by naming convention.
- CI documentation in `DEVELOPMENT.md`: how to run the E2E suite on Forge.

**Verify:**
- `tests/e2e/install-test.sh --iso dist/opencivitas-v0-<date>.iso` passes end-to-end (§4.1 flow) on Forge.
- VM is torn down automatically after PASS.
- Alex runs the same script independently with `--keep`, inspects the live VM, drops sign-off.

---

**Estimated total:** ~6–7 days across 4b–4f.

---

## Locked Decisions (from kickoff)

- All brain providers in dropdown (table in §1.2), with inline annotations.
- MIT license, Ubuntu 26.04 LTS, latest stable OpenClaw at install time.
- Single-user, user = agent.
- Cloud-init out of scope.
- "Wrap openclaw TUI instead" pivot shelved — not in scope.

---

## Open Items (pre-code gates)

These must be resolved before 4b implementation begins. Alex signs off on each.

1. **`dialog` availability in Ubuntu 26.04 live environment** — verify that `dialog` is present by default in the Ubuntu 26.04 server live ISO squashfs, or confirm we can reliably install it in the overlay without network access during install. If absent, propose alternatives (Python curses only, or bundle the deb). *(Wayland to verify on Forge before 4b starts.)*

2. **`civitas.pendingAuth` config field** — confirm the field name and path in `openclaw.json` with Alex, so civitas-shell and firstboot.sh agree. The gateway config schema may already have a hook point; check before inventing a new field. *(Wayland to check `openclaw.json` schema and gateway config docs; Alex final call.)*

3. **Anthropic CLI path verification owner** — Alex has an Anthropic account for the OAuth path. Confirm he will run the manual OAuth verification step in 4e. *(Agree before 4e starts.)*

---

## References

- Phase 0 spec: [`docs/v0-spec.md`](v0-spec.md)
- Phase 2 spec: [`docs/v0-phase2-bob-spec.md`](v0-phase2-bob-spec.md)
- Phase 3 spec: [`docs/v0-phase3-civitas-shell-spec.md`](v0-phase3-civitas-shell-spec.md)
- OpenClaw essentials: `~/.openclaw/workspace/handbook/openclaw-essentials.md`
- `dialog` man page: https://invisible-island.net/dialog/dialog.html
- Ubuntu autoinstall reference: https://canonical-subiquity.readthedocs.io/en/latest/reference/autoinstall-reference.html
- xorriso: https://www.gnu.org/software/xorriso/
