#!/usr/bin/env bash
#
# Agent Guard CLI smoke tests (upstream root layout).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ERRORS=0

fail() {
    echo "❌ FAIL: $1" >&2
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "✅ PASS: $1"
}

if [[ -f "${REPO_ROOT}/bin/agent-guard" ]]; then
    pass "agent-guard CLI exists"
else
    fail "agent-guard CLI not found at ${REPO_ROOT}/bin/agent-guard"
fi

if bash -n "${REPO_ROOT}/bin/agent-guard"; then
    pass "agent-guard CLI has valid shell syntax"
else
    fail "agent-guard CLI has shell syntax errors"
fi

for script in src/init.sh src/journal.sh src/session_trace.sh hooks/install.sh hooks/lease-owner-check.sh src/safe-squash.sh; do
    if [[ -f "${REPO_ROOT}/${script}" ]]; then
        if bash -n "${REPO_ROOT}/${script}"; then
            pass "${script} has valid shell syntax"
        else
            fail "${script} has shell syntax errors"
        fi
    else
        fail "${script} not found"
    fi
done

# safe-squash command is registered in the agent-guard CLI.
if grep -qE 'safe-squash\|sq\)' "${REPO_ROOT}/bin/agent-guard"; then
    pass "safe-squash command is registered in agent-guard CLI"
else
    fail "safe-squash command is missing from agent-guard CLI"
fi

for script in "${REPO_ROOT}"/wrappers/*/wrapper.sh "${REPO_ROOT}"/wrappers/*/recovery.sh; do
    if [[ -f "${script}" ]]; then
        if bash -n "${script}"; then
            pass "${script} has valid shell syntax"
        else
            fail "${script} has shell syntax errors"
        fi
    fi
done

if [[ ${ERRORS} -gt 0 ]]; then
    echo ""
    echo "❌ ${ERRORS} test(s) failed."
    exit 1
fi

echo ""
echo "✅ All CLI smoke tests passed."
