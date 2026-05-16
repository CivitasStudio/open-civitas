#!/usr/bin/env python3
"""
Open Civitas pre-flight TUI.

Asks three questions (language, agent name, brain), writes answers to
OUTPUT_PATH as JSON, then exits 0 (Install) or 2 (Advanced / Subiquity).

Exit codes:
  0  Install  — caller should invoke Subiquity with autoinstall seed
  2  Advanced — caller should invoke Subiquity interactively
  1  Cancelled / error
"""

import argparse
import json
import os
import re
import subprocess
import sys

DEFAULT_OUTPUT = "/run/civitas/preflight.json"
TEST_OUTPUT = "/tmp/civitas-preflight-test.json"

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{2,31}$")

LANGUAGES = [
    ("en", "English (default)"),
    ("es", "Español"),
    ("fr", "Français"),
    ("de", "Deutsch"),
    ("pt", "Português"),
    ("zh", "中文 (Simplified)"),
    ("ja", "日本語"),
    ("ar", "العربية"),
]

# (id, display_name, annotation)
BRAINS = [
    ("ollama+gemma-local", "Local Gemma (Ollama)",  "~8 GB download at first boot; no key"),
    ("anthropic-cli",      "Anthropic Claude CLI",  "OAuth required after boot"),
    ("anthropic-api",      "Anthropic API",          "API key required after boot"),
    ("openai",             "OpenAI",                 "API key required after boot"),
    ("gemini",             "Google Gemini",          "API key required after boot"),
    ("mistral",            "Mistral",                "API key required after boot"),
    ("cohere",             "Cohere",                 "API key required after boot"),
]


def _dialog(*args):
    """Run dialog, return (returncode, selection-string).

    dialog opens /dev/tty internally for its curses rendering; we inherit
    stdin/stdout from the parent so expect(1) can drive us through a PTY.
    The selected value goes to stderr (dialog's default output channel).
    """
    result = subprocess.run(
        ["dialog"] + list(args),
        stderr=subprocess.PIPE,
    )
    return result.returncode, result.stderr.decode().strip()


def ask_language():
    items = []
    for code, label in LANGUAGES:
        default = " (default)" if code == "en" else ""
        items += [code, label + default]
    rc, val = _dialog(
        "--title", "Open Civitas Installer",
        "--backtitle", "Step 1 of 3",
        "--default-item", "en",
        "--menu", "Select installation language:", "18", "60", "8",
        *items,
    )
    if rc != 0:
        sys.exit(1)
    return val or "en"


def ask_name():
    while True:
        rc, val = _dialog(
            "--title", "Open Civitas Installer",
            "--backtitle", "Step 2 of 3",
            "--inputbox",
            "Enter agent name (3–32 chars, lowercase letters, digits, hyphens).\n"
            "This becomes your Linux username and agent name.",
            "10", "60", "",
        )
        if rc != 0:
            sys.exit(1)
        name = val.strip().lower()
        if NAME_RE.match(name):
            return name
        _dialog(
            "--title", "Invalid name",
            "--msgbox",
            f"'{name}' is not valid.\n\n"
            "Requirements: 3–32 characters, start with a letter,\n"
            "only lowercase letters, digits, and hyphens.",
            "10", "60",
        )


def ask_brain():
    items = []
    for bid, label, annotation in BRAINS:
        display = f"{label:<26}[{annotation}]"
        items += [bid, display]
    rc, val = _dialog(
        "--title", "Open Civitas Installer",
        "--backtitle", "Step 3 of 3",
        "--default-item", "ollama+gemma-local",
        "--menu", "Select AI brain:", "18", "76", "7",
        *items,
    )
    if rc != 0:
        sys.exit(1)
    return val or "ollama+gemma-local"


def confirm_and_choose(language, name, language_label, brain, brain_label, brain_annotation):
    lang_display = language_label
    brain_display = f"{brain_label}  [{brain_annotation}]"
    msg = (
        f"  Language : {lang_display}\n"
        f"  Name     : {name}\n"
        f"  Brain    : {brain_display}\n\n"
        "Choose Install to proceed with these settings,\n"
        "or Advanced to continue in Subiquity's full installer."
    )
    rc, _ = _dialog(
        "--title", "Open Civitas — Ready to install",
        "--yes-label", "Install",
        "--no-label", "Advanced (Subiquity)",
        "--yesno", msg, "14", "70",
    )
    # rc 0 = Install, rc 1 = Advanced
    return rc


def main():
    parser = argparse.ArgumentParser(description="Open Civitas pre-flight TUI")
    parser.add_argument(
        "--output", default=None,
        help="Path to write preflight.json (default: /run/civitas/preflight.json)",
    )
    parser.add_argument(
        "--test-mode", action="store_true",
        help=f"Write output to {TEST_OUTPUT} instead of the default path",
    )
    args = parser.parse_args()

    output = args.output or (TEST_OUTPUT if args.test_mode else DEFAULT_OUTPUT)

    language = ask_language()
    language_label = next((l for c, l in LANGUAGES if c == language), language)

    name = ask_name()

    brain = ask_brain()
    brain_entry = next((b for b in BRAINS if b[0] == brain), BRAINS[0])
    brain_label, brain_annotation = brain_entry[1], brain_entry[2]

    mode = confirm_and_choose(language, name, language_label, brain, brain_label, brain_annotation)
    # mode 0 = Install, 1 = Advanced

    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
    with open(output, "w") as f:
        json.dump({
            "language": language,
            "name": name,
            "brain": brain,
            "mode": "install" if mode == 0 else "advanced",
        }, f, indent=2)
        f.write("\n")

    sys.exit(0 if mode == 0 else 2)


if __name__ == "__main__":
    main()
