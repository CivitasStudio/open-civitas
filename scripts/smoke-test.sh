#!/usr/bin/env bash
# Smoke test — validates installer output state on a fresh VM.
# Non-interactive; designed for Forge libvirt CI.
# Tests criteria 1-7 from v0-spec.md.
set -euo pipefail

PASSED=0
FAILED=0
FAILURES=()

test_assert() {
    local name="$1" cmd="$2"
    printf "%-60s" "Testing: $name… "
    if eval "$cmd" >/dev/null 2>&1; then
        echo "PASS"
        (( PASSED++ )) || true
        return 0
    else
        echo "FAIL"
        (( FAILED++ )) || true
        FAILURES+=("$name")
        return 1
    fi
}

# Test 1: openclaw-gateway.service is active
test_assert "openclaw-gateway.service is active" \
    'systemctl --user is-active openclaw-gateway | grep -q "^active"'

# Test 2: linger is enabled
test_assert "linger enabled for $USER" \
    'loginctl show-user "$USER" 2>/dev/null | grep -q "^Linger=yes"'

# Test 3: workspace files exist
for file in AGENTS SOUL IDENTITY USER HEARTBEAT MEMORY; do
    test_assert "~/.openclaw/workspace/${file}.md exists" \
        "[[ -f \"${HOME}/.openclaw/workspace/${file}.md\" ]]"
done

# Test 4: openclaw.json exists, contains "workspace" key with absolute path
test_assert "openclaw.json exists" \
    "[[ -f \"${HOME}/.openclaw/openclaw.json\" ]]"

test_assert "openclaw.json contains absolute workspace path" \
    "grep -q '\"workspace\": \"/' \"${HOME}/.openclaw/openclaw.json\" && \
     ! grep -q '{{' \"${HOME}/.openclaw/openclaw.json\""

# Test 5: ~/CLAUDE.md is a symlink
test_assert "~/CLAUDE.md is a symlink" \
    "[[ -L \"${HOME}/CLAUDE.md\" ]]"

test_assert "~/CLAUDE.md points to workspace AGENTS.md" \
    "[[ \"\$(readlink \"${HOME}/CLAUDE.md\")\" == \"${HOME}/.openclaw/workspace/AGENTS.md\" ]]"

# Test 6: gateway health endpoint returns 200
test_assert "GET http://localhost:18789/health returns 200" \
    'curl -s -o /dev/null -w "%{http_code}" http://localhost:18789/health | grep -q "^200"'

# Test 7 (optional): claude --version if CLI installed
if command -v claude &>/dev/null; then
    test_assert "claude --version works (optional)" \
        'claude --version >/dev/null 2>&1'
fi

# Test 8 (optional): ollama list if installed
if command -v ollama &>/dev/null; then
    test_assert "ollama list returns models (optional)" \
        'ollama list 2>/dev/null | grep -q "NAME"'
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Smoke Test Results"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"

if [[ $FAILED -gt 0 ]]; then
    echo ""
    echo "Failed assertions:"
    for failure in "${FAILURES[@]}"; do
        echo "  ✗ $failure"
    done
    exit 1
fi

echo ""
echo "✓ All smoke tests passed."
exit 0
