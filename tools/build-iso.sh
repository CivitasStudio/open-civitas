#!/usr/bin/env bash
# Build the Open Civitas bootable ISO.
#
# Takes a Ubuntu 26.04 LTS server base ISO, injects the civitas overlay
# (scripts + systemd units + bundled dialog deb), patches GRUB to add an
# Open Civitas menu entry, and produces a bootable ISO via xorriso.
#
# Overlay injection uses squashfs stacking: casper loads all *.squashfs files
# in casper/ in alphabetical order and merges them.  civitas.squashfs is
# applied after filesystem.squashfs without touching the base squashfs.
#
# Usage:
#   tools/build-iso.sh [OPTIONS]
#
# Options:
#   --base-iso  <path>   Path to Ubuntu 26.04 LTS server ISO.
#                        Downloaded to --cache-dir if absent.
#   --output    <path>   Output ISO path (default: dist/opencivitas-v0-<date>.iso)
#   --cache-dir <path>   Directory for downloaded base ISO (default: dist/cache)
#   --no-download        Fail if base ISO is not present (CI mode)
#   --version   <tag>    Version tag to embed (default: git describe or 'v0-dev')
#   --keep-staging       Don't delete the staging dir on exit (for debugging)
#   -h, --help
#
# Build host requirements (install via apt if absent):
#   xorriso, squashfs-tools, wget or curl
#   dialog (for bundling into overlay — apt-get download dialog)
#
# Exit codes:  0 success  1 error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── defaults ─────────────────────────────────────────────────────────────────

BASE_ISO=""
OUTPUT_ISO=""
CACHE_DIR="$REPO_ROOT/dist/cache"
NO_DOWNLOAD=0
VERSION=""
KEEP_STAGING=0

UBUNTU_ISO_URL="https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso"
UBUNTU_ISO_NAME="ubuntu-26.04-live-server-amd64.iso"
# SHA256 of the Ubuntu 26.04 LTS server ISO (verify at https://releases.ubuntu.com/26.04/SHA256SUMS)
UBUNTU_ISO_SHA256="PLACEHOLDER_VERIFY_AT_RELEASE_TIME"

# ── arg parsing ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-iso)   BASE_ISO="$2";   shift 2 ;;
        --output)     OUTPUT_ISO="$2"; shift 2 ;;
        --cache-dir)  CACHE_DIR="$2";  shift 2 ;;
        --no-download) NO_DOWNLOAD=1;  shift   ;;
        --version)    VERSION="$2";    shift 2 ;;
        --keep-staging) KEEP_STAGING=1; shift  ;;
        -h|--help)
            sed -n '2,/^# Exit/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "error: unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── derived values ────────────────────────────────────────────────────────────

if [[ -z "$VERSION" ]]; then
    VERSION=$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || echo "v0-dev")
fi

DATE=$(date +%Y-%m-%d)

if [[ -z "$OUTPUT_ISO" ]]; then
    mkdir -p "$REPO_ROOT/dist"
    OUTPUT_ISO="$REPO_ROOT/dist/opencivitas-v0-${DATE}.iso"
fi

# ── helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[build-iso] $*"; }
die()  { echo "[build-iso] error: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "required command not found: $1 (apt install $2)"
}

# ── dependency checks ─────────────────────────────────────────────────────────

require_cmd xorriso    xorriso
require_cmd mksquashfs squashfs-tools
require_cmd wget       wget

# ── staging dir ───────────────────────────────────────────────────────────────

STAGING=$(mktemp -d /tmp/civitas-iso-build-XXXXXX)
log "staging dir: $STAGING"

cleanup() {
    if [[ "$KEEP_STAGING" -eq 0 ]]; then
        rm -rf "$STAGING"
    else
        log "keeping staging dir: $STAGING"
    fi
}
trap cleanup EXIT

# ── step 1: locate or download base ISO ──────────────────────────────────────

if [[ -z "$BASE_ISO" ]]; then
    mkdir -p "$CACHE_DIR"
    BASE_ISO="$CACHE_DIR/$UBUNTU_ISO_NAME"
fi

if [[ ! -f "$BASE_ISO" ]]; then
    if [[ "$NO_DOWNLOAD" -eq 1 ]]; then
        die "base ISO not found: $BASE_ISO (--no-download set)"
    fi
    log "downloading Ubuntu 26.04 LTS server ISO to $BASE_ISO ..."
    wget --show-progress -O "$BASE_ISO.tmp" "$UBUNTU_ISO_URL"
    mv "$BASE_ISO.tmp" "$BASE_ISO"
fi

log "verifying base ISO: $BASE_ISO"
if [[ "$UBUNTU_ISO_SHA256" != "PLACEHOLDER_VERIFY_AT_RELEASE_TIME" ]]; then
    actual=$(sha256sum "$BASE_ISO" | awk '{print $1}')
    if [[ "$actual" != "$UBUNTU_ISO_SHA256" ]]; then
        die "SHA256 mismatch for base ISO (expected $UBUNTU_ISO_SHA256, got $actual)"
    fi
    log "SHA256 verified OK"
else
    log "warning: SHA256 placeholder not yet replaced — skipping checksum verification"
fi

# ── step 2: extract grub.cfg from ISO ────────────────────────────────────────

log "extracting grub.cfg from base ISO ..."
GRUB_CFG_ORIG="$STAGING/grub.cfg.orig"
xorriso -indev "$BASE_ISO" \
    -osirrox on \
    -extract /boot/grub/grub.cfg "$GRUB_CFG_ORIG" \
    -- 2>/dev/null \
    || die "could not extract /boot/grub/grub.cfg from ISO"

# ── step 3: patch grub.cfg ────────────────────────────────────────────────────

log "patching grub.cfg ..."
GRUB_CFG_PATCHED="$STAGING/grub.cfg"

# Build the Open Civitas menu entry.
# 'autoinstall' on the cmdline + 'ds=nocloud;s=/run/civitas/' tells Subiquity
# to read autoinstall.yaml from /run/civitas/ (written by our preflight TUI).
CIVITAS_ENTRY=$(cat <<'ENTRY'

menuentry "Open Civitas Installer" {
    set gfxpayload=keep
    linux   /casper/vmlinuz quiet autoinstall 'ds=nocloud;s=/run/civitas/' ---
    initrd  /casper/initrd
}
ENTRY
)

# Prepend the civitas entry before the first Ubuntu entry.
# If 'menuentry' isn't found (grub.cfg layout changed), append instead.
if grep -q '^menuentry' "$GRUB_CFG_ORIG"; then
    awk -v entry="$CIVITAS_ENTRY" '
        /^menuentry/ && !done { print entry; done=1 }
        { print }
    ' "$GRUB_CFG_ORIG" > "$GRUB_CFG_PATCHED"
else
    cat "$GRUB_CFG_ORIG" > "$GRUB_CFG_PATCHED"
    echo "$CIVITAS_ENTRY" >> "$GRUB_CFG_PATCHED"
fi

# ── step 4: build civitas overlay dir ────────────────────────────────────────

log "building civitas overlay ..."
OVL="$STAGING/overlay"

# /usr/lib/civitas/ — pre-flight TUI scripts
install -Dm755 "$REPO_ROOT/scripts/preflight/preflight.py" \
    "$OVL/usr/lib/civitas/preflight.py"
install -Dm755 "$REPO_ROOT/scripts/preflight/generate-autoinstall.py" \
    "$OVL/usr/lib/civitas/generate-autoinstall.py"

# Real install.sh + lib helpers — used by autoinstall late-commands (4d).
# curtin in-target copies /usr/lib/civitas into the target chroot and runs
# install.sh there; it sources lib/*.sh relative to SCRIPT_DIR.
install -Dm755 "$REPO_ROOT/install.sh" "$OVL/usr/lib/civitas/install.sh"
for lib_sh in "$REPO_ROOT/lib/"*.sh; do
    install -Dm755 "$lib_sh" "$OVL/usr/lib/civitas/lib/$(basename "$lib_sh")"
done

# systemd service unit required by install-substrate.sh
install -Dm644 "$REPO_ROOT/systemd/openclaw-gateway.service" \
    "$OVL/usr/lib/civitas/systemd/openclaw-gateway.service"

# civitas-shell source — install-civitas-shell.sh prefers the local checkout
# (npm pack + npm install -g tarball) over the registry.  We strip node_modules
# to keep the overlay small; npm pack resolves deps from the registry.
log "bundling civitas-shell source into overlay ..."
cp -r "$REPO_ROOT/civitas-shell" "$OVL/usr/lib/civitas/civitas-shell"
rm -rf "$OVL/usr/lib/civitas/civitas-shell/node_modules"

# Real firstboot.sh + civitas-firstboot.service (4e).
install -Dm755 "$REPO_ROOT/scripts/firstboot/firstboot.sh" \
    "$OVL/usr/lib/civitas/firstboot.sh"
install -Dm644 "$REPO_ROOT/systemd/civitas-firstboot.service" \
    "$OVL/usr/lib/civitas/systemd/civitas-firstboot.service"

# /usr/lib/civitas/debs/ — bundled packages for the live environment.
# dialog is not in the Ubuntu 26.04 live squashfs by default.
log "downloading dialog deb for bundling ..."
mkdir -p "$OVL/usr/lib/civitas/debs"
(cd "$OVL/usr/lib/civitas/debs" && apt-get download dialog 2>/dev/null) \
    || log "warning: could not download dialog deb — live env may lack dialog"

# Write the live-environment service unit directly.
# This version adds an ExecStartPre that installs dialog from the bundled deb
# if not already present.  The repo's systemd/civitas-preflight.service is the
# generic template; this is the ISO-specific instantiation.
install -dm755 "$OVL/etc/systemd/system" \
               "$OVL/etc/systemd/system/multi-user.target.wants"
cat > "$OVL/etc/systemd/system/civitas-preflight.service" <<'UNIT'
[Unit]
Description=Open Civitas pre-flight TUI
Before=subiquity.service
After=getty@tty1.service systemd-udevd.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

ExecStartPre=/bin/mkdir -p /run/civitas
ExecStartPre=/bin/touch /run/civitas/meta-data
ExecStartPre=/bin/sh -c 'dpkg -l dialog >/dev/null 2>&1 || dpkg -i /usr/lib/civitas/debs/dialog_*.deb'
ExecStart=/usr/lib/civitas/preflight.py
ExecStartPost=/usr/lib/civitas/generate-autoinstall.py

[Install]
WantedBy=multi-user.target
UNIT

ln -sf /etc/systemd/system/civitas-preflight.service \
    "$OVL/etc/systemd/system/multi-user.target.wants/civitas-preflight.service"

# ── step 5: pack civitas overlay into civitas.squashfs ───────────────────────

log "packing civitas.squashfs ..."
CIVITAS_SFS="$STAGING/civitas.squashfs"
mksquashfs "$OVL" "$CIVITAS_SFS" -comp xz -noappend -quiet

log "civitas.squashfs size: $(du -sh "$CIVITAS_SFS" | cut -f1)"

# ── step 6: build output ISO with xorriso ────────────────────────────────────

log "building output ISO: $OUTPUT_ISO ..."
mkdir -p "$(dirname "$OUTPUT_ISO")"

# xorriso options:
#  -boot_image any replay  — preserve all boot catalog entries from source ISO
#  -map                    — add/replace files at given ISO paths
#  -volid                  — set the volume label
xorriso \
    -indev "$BASE_ISO" \
    -outdev "$OUTPUT_ISO" \
    -boot_image any replay \
    -volid "OPENCIVITAS_V0" \
    -map "$GRUB_CFG_PATCHED"  "/boot/grub/grub.cfg" \
    -map "$CIVITAS_SFS"        "/casper/civitas.squashfs" \
    -end \
    2>&1 | grep -v '^xorriso : UPDATE' || true

# ── step 7: verify output ISO is bootable ────────────────────────────────────

log "verifying output ISO ..."
xorriso -indev "$OUTPUT_ISO" -report_el_torito plain 2>&1 \
    | grep -E "^(Boot|El Torito|Platform|Boot record)" \
    || log "warning: El Torito report empty — manual boot verify recommended"

ISO_SIZE=$(du -sh "$OUTPUT_ISO" | cut -f1)
log "done — output ISO: $OUTPUT_ISO ($ISO_SIZE)"
echo "$OUTPUT_ISO"
