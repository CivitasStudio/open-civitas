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
DEFAULT_OUTPUT = "/run/civitas/autoinstall.yaml"

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
# %(...) placeholders filled by % operator.
TEMPLATE = """\
version: 1
locale: %(locale)s
keyboard:
  layout: %(keyboard)s
identity:
  hostname: %(name)s
  username: %(name)s
  # No password set here; civitas-firstboot.service presents the optional
  # password dialog before handing over the console.
  password: ''
  realname: %(name)s
ssh:
  install-server: false
storage:
  layout:
    name: lvm
packages: []
late-commands:
  # Write the preflight config into the installed system.
  - |
    mkdir -p /target/etc/civitas
    cp /run/civitas/preflight.json /target/etc/civitas/preflight.json
  # Run the civitas installer (install.sh --with-civitas-shell) inside the
  # installed target.  install.sh is baked into the ISO overlay.
  - curtin in-target -- bash /cdrom/civitas/install.sh --with-civitas-shell
  # Enable civitas-firstboot.service so it runs on the first real boot.
  - curtin in-target -- systemctl enable civitas-firstboot.service
  # Auto-login on tty1 as the agent user.
  - |
    mkdir -p /target/etc/systemd/system/getty@tty1.service.d
    cat > /target/etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
    [Service]
    ExecStart=
    ExecStart=-/sbin/agetty --autologin %(name)s --noclear %%I $TERM
    EOF
  # Set civitas-shell as the login shell for the agent user.
  - curtin in-target -- chsh -s /usr/bin/civitas-shell %(name)s
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

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w") as f:
        f.write(yaml_content)

    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
