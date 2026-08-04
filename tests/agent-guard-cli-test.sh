#!/usr/bin/env bash
#
# Smoke tests for the agent-guard CLI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/bin"

ERRORS=0

fail() {
    echo "❌ FAIL: $1" >&2
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "✅ PASS: $1"
}

# The CLI must be sourced, not executed.
if bash "${BIN_DIR}/agent-guard" --help >/dev/null 2>&1; then
    fail "agent-guard should refuse direct execution"
else
    pass "agent-guard refuses direct execution"
fi

# Sourcing without arguments in a non-worktree environment should fail gracefully
# and print a helpful message (it must not crash the caller's shell).
CLI_OUTPUT=$(mktemp)
(
    # shellcheck disable=SC1091
    source "${BIN_DIR}/agent-guard" >"${CLI_OUTPUT}" 2>&1 || true
)
if grep -qE "(Not inside an agent worktree|Provide prefix and role|Usage|agent-guard)" "${CLI_OUTPUT}"; then
    pass "agent-guard produces readable help output when sourced outside a worktree"
else
    cat "${CLI_OUTPUT}" >&2
    fail "agent-guard did not produce expected help output"
fi
rm -f "${CLI_OUTPUT}"

# Verify that all subcommand scripts referenced by agent-guard exist.
for script in init.sh journal.sh session_trace.sh; do
    if [[ -f "${REPO_ROOT}/src/${script}" ]]; then
        pass "src/${script} exists"
    else
        fail "src/${script} is missing"
    fi
done

# Verify that the config helper resolves PHP syntax.
if php -l "${REPO_ROOT}/src/Config.php" >/dev/null 2>&1; then
    pass "Config.php has valid PHP syntax"
else
    fail "Config.php has PHP syntax errors"
fi

echo ""
if [[ ${ERRORS} -gt 0 ]]; then
    echo "❌ ${ERRORS} test(s) failed."
    exit 1
fi

echo "✅ Agent Guard CLI tests passed."
