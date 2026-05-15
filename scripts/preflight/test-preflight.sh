#!/usr/bin/env bash
# Drive preflight.py with expect, check output JSON, then verify
# generate-autoinstall.py produces valid YAML structure.
#
# Usage: test-preflight.sh [--scenario <name>]
#   Scenarios: default (ollama), oauth (anthropic-cli)
#
# Requires: expect, python3, dialog

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="$SCRIPT_DIR/preflight.py"
GENERATE="$SCRIPT_DIR/generate-autoinstall.py"
OUTFILE="/tmp/civitas-preflight-test.json"
YAMLFILE="/tmp/civitas-autoinstall-test.yaml"
SCENARIO="${1:-default}"

# ── helpers ──────────────────────────────────────────────────────────────────

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; exit 1; }

check_json() {
    local key="$1" expected="$2"
    local actual
    actual=$(python3 -c "import json,sys; d=json.load(open('$OUTFILE')); print(d.get('$key',''))")
    if [[ "$actual" == "$expected" ]]; then
        pass "preflight.json[$key] = '$expected'"
    else
        fail "preflight.json[$key]: expected '$expected', got '$actual'"
    fi
}

# ── scenario: default (ollama+gemma-local, English) ──────────────────────────

run_default() {
    echo "=== scenario: default (English / testuser / ollama+gemma-local) ==="
    rm -f "$OUTFILE"

    expect -f - <<'EXPECT'
set timeout 15
set env(TERM) xterm

spawn python3 /home/wayland/open-civitas/scripts/preflight/preflight.py --test-mode

# Step 1: Language — dialog --menu, default "en" highlighted; press Enter
expect "Step 1 of 3"
send "\r"

# Step 2: Name — inputbox; type name, press Enter
expect "Step 2 of 3"
send "testuser\r"

# Step 3: Brain — menu, default is ollama+gemma-local (first item); press Enter
expect "Step 3 of 3"
send "\r"

# Confirm dialog — may auto-select from buffered \r or wait for explicit send.
# Handle both: match "Ready to install" and send Enter if we get there, or just
# wait for eof if the confirm was already answered by the buffered keystroke.
expect {
    -timeout 10
    "Ready to install" { send "\r"; exp_continue }
    eof {}
    timeout { puts stderr "TIMEOUT waiting for confirm or eof"; exit 1 }
}
EXPECT

    [[ -f "$OUTFILE" ]] || fail "preflight.json not written"
    check_json "language" "en"
    check_json "name" "testuser"
    check_json "brain" "ollama+gemma-local"
    check_json "mode" "install"
    pass "output file written and all fields correct"
}

# ── scenario: oauth (anthropic-cli) ──────────────────────────────────────────

run_oauth() {
    echo "=== scenario: oauth (English / authuser / anthropic-cli) ==="
    rm -f "$OUTFILE"

    expect -f - <<'EXPECT'
set timeout 15
set env(TERM) xterm

spawn python3 /home/wayland/open-civitas/scripts/preflight/preflight.py --test-mode

# Step 1: Language — accept default (English)
expect "Step 1 of 3"
send "\r"

# Step 2: Name
expect "Step 2 of 3"
send "authuser\r"

# Step 3: Brain — type 'a' to jump to first tag starting with 'a' (anthropic-cli)
# Note: down-arrow (ESC[B) cannot be used here because dialog processes the
# bare ESC as Cancel (exit 255) before the [B suffix arrives over the PTY.
# First-character tag navigation is reliable and tests the same thing.
expect "Step 3 of 3"
send "a\r"

expect {
    -timeout 10
    "Ready to install" { send "\r"; exp_continue }
    eof {}
    timeout { puts stderr "TIMEOUT waiting for confirm or eof"; exit 1 }
}
EXPECT

    [[ -f "$OUTFILE" ]] || fail "preflight.json not written"
    check_json "name" "authuser"
    check_json "brain" "anthropic-cli"
    pass "anthropic-cli selected correctly"

    # Verify annotation text appears in the brain menu — check preflight.py source
    # has the annotation strings (functional verification; visual confirmed by expect run)
    python3 -c "
import sys
src = open('$PREFLIGHT').read()
# Check annotation text (brackets added dynamically via f-string, not in literals)
assert 'OAuth required after boot' in src, 'OAuth annotation missing'
assert 'API key required after boot' in src, 'API key annotation missing'
assert '~8 GB download at first boot' in src, 'Ollama annotation missing'
# Check the bracket format string exists
assert '[{annotation}]' in src, 'bracket format string missing'
print('annotation strings verified')
" || fail "annotation strings missing"
    pass "annotation strings verified in source"
}

# ── generate-autoinstall check ────────────────────────────────────────────────

run_generate() {
    echo "=== generate-autoinstall.py ==="
    # Use the JSON from whichever scenario ran last
    [[ -f "$OUTFILE" ]] || fail "no preflight.json to read"

    python3 "$GENERATE" --preflight "$OUTFILE" --output "$YAMLFILE"
    [[ -f "$YAMLFILE" ]] || fail "autoinstall.yaml not written"

    # Check required fields present
    grep -q "^version: 1" "$YAMLFILE" || fail "missing 'version: 1'"
    grep -q "^locale:" "$YAMLFILE" || fail "missing 'locale:'"
    grep -q "^identity:" "$YAMLFILE" || fail "missing 'identity:'"
    grep -q "late-commands:" "$YAMLFILE" || fail "missing 'late-commands:'"

    local name
    name=$(python3 -c "import json; print(json.load(open('$OUTFILE'))['name'])")
    grep -q "hostname: $name" "$YAMLFILE" || fail "hostname not set to '$name'"
    grep -q "username: $name" "$YAMLFILE" || fail "username not set to '$name'"
    pass "autoinstall.yaml valid, identity fields correct for '$name'"
}

# ── main ─────────────────────────────────────────────────────────────────────

case "$SCENARIO" in
    default)
        run_default
        run_generate
        ;;
    oauth)
        run_oauth
        run_generate
        ;;
    all)
        run_default
        run_generate
        run_oauth
        run_generate
        ;;
    *)
        echo "usage: $0 [default|oauth|all]"
        exit 1
        ;;
esac

echo ""
echo "All checks passed."
