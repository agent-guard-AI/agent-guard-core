#!/usr/bin/env bash
#
# Agent Guard Core — Test runner (upstream root layout).
#
# Orchestrates all package-level tests. Safe to run both inside the HMVIP
# monorepo (packages/agent-guard-core/) and in the standalone upstream repo
# where the package root is the repository root.
#
# Usage:
#   bash packages/agent-guard-core/tests/run-all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILED=0

run_test() {
    local test_script="$1"
    local label="$2"
    echo ""
    echo "▶️  ${label}: ${test_script}"
    if bash "${test_script}"; then
        echo "✅ ${label} passed"
    else
        echo "❌ ${label} failed" >&2
        FAILED=$((FAILED + 1))
    fi
}

run_test "${SCRIPT_DIR}/agent-guard-cli-test.sh" "CLI smoke tests"
run_test "${SCRIPT_DIR}/install-test.sh" "Installer tests"
run_test "${SCRIPT_DIR}/test-tab-hook.sh" "Tab hook tests"

echo ""
if [[ ${FAILED} -gt 0 ]]; then
    echo "❌ ${FAILED} test suite(s) failed."
    exit 1
fi

echo "✅ All agent-guard-core test suites passed."
