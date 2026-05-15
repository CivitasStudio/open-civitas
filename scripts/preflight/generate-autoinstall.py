#!/usr/bin/env python3
"""
Read preflight.json and write a Subiquity autoinstall.yaml.

Usage:
  generate-autoinstall.py --preflight <path> --output <path>

Defaults:
  --preflight  /run/civitas/preflight.json
  --output     /run/civitas/autoinstall.yaml
"""

import argparse
import json
import os
import sys

DEFAULT_PREFLIGHT = "/run/civitas/preflight.json"
DEFAULT_OUTPUT = "/run/civitas/user-data"  # nocloud datasource expects this filename

LOCALE_MAP = {
    "en": "en_US.UTF-8",
    "es": "es_ES.UTF-8",
    "fr": "fr_FR.UTF-8",
    "de": "de_DE.UTF-8",
    "pt": "pt_BR.UTF-8",
    "zh": "zh_CN.UTF-8",
    "ja": "ja_JP.UTF-8",
    "ar": "ar_SA.UTF-8",
}

KEYBOARD_MAP = {
    "en": "us",
    "es": "es",
    "fr": "fr",
    "de": "de",
    "pt": "br",
    "zh": "us",
    "ja": "jp",
    "ar": "ara",
}

# Template — rendered as a plain string to avoid a PyYAML dependency.
# %(...) placeholders filled by % operator.  Use %% for a literal %.
TEMPLATE = """\
version: 1
locale: %(locale)s
keyboard:
  layout: %(keyboard)s
identity:
  hostname: %(name)s
  username: %(name)s
  # Locked password — no interactive password login.  Auto-login via tty1
  # drop-in (configured in late-commands) provides console access.
  # civitas-firstboot.service presents an optional passwd dialog at first boot.
  password: '!'
  realname: %(name)s
ssh:
  install-server: false
storage:
  layout:
    name: lvm
packages: []
late-commands:
  # Persist preflight config in the installed system.
  - mkdir -p /target/etc/civitas
  - cp /run/civitas/preflight.json /target/etc/civitas/preflight.json
  # Copy civitas scripts from the live-env overlay into the target so that
  # curtin in-target can find them inside the chroot.
  - cp -a /usr/lib/civitas /target/usr/lib/civitas
  # Run the civitas installer (Node + OpenClaw + civitas-shell) inside the
  # target as root with HOME pointing at the agent user's home directory.
  - 'curtin in-target -- env HOME=/home/%(name)s bash /usr/lib/civitas/install.sh --non-interactive --agent-name %(name)s --agent-role %(name)s --user %(name)s --with-civitas-shell'
  # Register civitas-shell as a valid login shell, then set it for the agent user.
  - 'curtin in-target -- bash -c "grep -qxF /usr/bin/civitas-shell /etc/shells || echo /usr/bin/civitas-shell >> /etc/shells"'
  - curtin in-target -- chsh -s /usr/bin/civitas-shell %(name)s
  # Enable civitas-firstboot.service so it runs on the first real boot.
  - curtin in-target -- systemctl enable civitas-firstboot.service
  # Auto-login on tty1 as the agent user.
  - mkdir -p /target/etc/systemd/system/getty@tty1.service.d
  - |
    cat > /target/etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOLOGIN'
    [Service]
    ExecStart=
    ExecStart=-/sbin/agetty --autologin %(name)s --noclear %%I $TERM
    AUTOLOGIN
"""


def render(preflight: dict) -> str:
    language = preflight.get("language", "en")
    name = preflight["name"]
    locale = LOCALE_MAP.get(language, "en_US.UTF-8")
    keyboard = KEYBOARD_MAP.get(language, "us")
    return TEMPLATE % {"locale": locale, "keyboard": keyboard, "name": name}


def main():
    parser = argparse.ArgumentParser(description="Generate Subiquity autoinstall.yaml from preflight.json")
    parser.add_argument("--preflight", default=DEFAULT_PREFLIGHT, help="Path to preflight.json")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="Path to write autoinstall.yaml")
    args = parser.parse_args()

    try:
        with open(args.preflight) as f:
            preflight = json.load(f)
    except FileNotFoundError:
        print(f"error: preflight file not found: {args.preflight}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"error: invalid JSON in {args.preflight}: {e}", file=sys.stderr)
        sys.exit(1)

    required = {"language", "name", "brain"}
    missing = required - set(preflight)
    if missing:
        print(f"error: preflight.json missing fields: {', '.join(sorted(missing))}", file=sys.stderr)
        sys.exit(1)

    yaml_content = render(preflight)

    out_dir = os.path.dirname(args.output) or "."
    os.makedirs(out_dir, exist_ok=True)
    with open(args.output, "w") as f:
        f.write(yaml_content)

    # nocloud datasource also requires a meta-data file (may be empty).
    meta = os.path.join(out_dir, "meta-data")
    if not os.path.exists(meta):
        open(meta, "w").close()

    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
