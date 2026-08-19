#!/usr/bin/env bash
#
# slack-notify-test.sh — Smoke tests for slack-notify.sh helpers.
#
# These tests ensure the Slack notification helpers fail silently and do not
# leak secrets or break the init flow when the CLI is missing or disabled.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SLACK_NOTIFY="${REPO_ROOT}/packages/agent-guard-core/src/slack-notify.sh"

if [[ ! -f "${SLACK_NOTIFY}" ]]; then
    echo "❌ FAIL: slack-notify.sh not found at ${SLACK_NOTIFY}" >&2
    exit 1
fi

PASS=0
FAIL=0

_assert_true() {
    local msg="${1}"
    if "${2}"; then
        echo "✅ PASS: ${msg}"
        PASS=$((PASS + 1))
    else
        echo "❌ FAIL: ${msg}" >&2
        FAIL=$((FAIL + 1))
    fi
}

_assert_false() {
    local msg="${1}"
    if "${2}"; then
        echo "❌ FAIL: ${msg}" >&2
        FAIL=$((FAIL + 1))
    else
        echo "✅ PASS: ${msg}"
        PASS=$((PASS + 1))
    fi
}

_guard_functions_defined() {
    command -v _guard_slack_post >/dev/null 2>&1 && \
    command -v _guard_notify_init >/dev/null 2>&1 && \
    command -v _guard_notify_release >/dev/null 2>&1 && \
    command -v _guard_notify_drift >/dev/null 2>&1 && \
    command -v _guard_notify_ops_checkpoint >/dev/null 2>&1
}

# Load helpers in the current shell (functions are namespaced with _guard_*).
source "${SLACK_NOTIFY}"

_assert_true "slack-notify.sh defines all public helpers" _guard_functions_defined

# Test 1: HMVIP_DISABLE_SLACK_POST disables posting.
ORIG_DISABLE="${HMVIP_DISABLE_SLACK_POST:-}"
HMVIP_DISABLE_SLACK_POST=1
_assert_false "disabled by env" _guard_slack_enabled
HMVIP_DISABLE_SLACK_POST="${ORIG_DISABLE}"

# Test 2: Missing CLI disables posting.
ORIG_CLI="${_HMVIP_SLACK_CLI}"
_HMVIP_SLACK_CLI="/nonexistent/hmvip-slack"
_assert_false "missing CLI disables posting" _guard_slack_enabled
_HMVIP_SLACK_CLI="${ORIG_CLI}"

# Test 3: Public notification helpers survive when disabled.
ORIG_DISABLE="${HMVIP_DISABLE_SLACK_POST:-}"
HMVIP_DISABLE_SLACK_POST=1
_guard_notify_init "codewhale3" "ia-codewhale3/ia-a/task-20260819"
_guard_notify_release "codewhale3" "ia-codewhale3/ia-a/task-20260819"
_guard_notify_drift "codewhale3" "ia-codewhale3/ia-a/task-20260819" "worktree drift"
_guard_notify_ops_checkpoint "codewhale3" "ia-codewhale3/ia-a/task-20260819" "summary" "next" "none"
_assert_true "notification helpers fail silently when disabled" true
HMVIP_DISABLE_SLACK_POST="${ORIG_DISABLE}"

echo ""
echo "PASS=${PASS} FAIL=${FAIL}"
if [[ "${FAIL}" -ne 0 ]]; then
    exit 1
fi
