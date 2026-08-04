#!/usr/bin/env bash
#
# Agent Guard Core installer tests (upstream root layout).
#
# This test runs against the standalone agent-guard-core repository layout,
# where the package root is the repository root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

ERRORS=0

fail() {
    echo "❌ FAIL: $1" >&2
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "✅ PASS: $1"
}

TMP_DIR=$(mktemp -d)
_cleanup_tmp() {
    rm -rf "${TMP_DIR}"
}
trap _cleanup_tmp EXIT

(
    cd "${TMP_DIR}"
    git init -q
    git config user.email "test@example.dev"
    git config user.name "Test Agent"
)

if bash "${INSTALL_SCRIPT}" --target "${TMP_DIR}" --package-root agent-guard-core --skip-wrapper --yes >/tmp/install-test.log 2>&1; then
    pass "install.sh succeeds in a fresh Git repo"
else
    cat /tmp/install-test.log >&2
    fail "install.sh should succeed in a fresh Git repo"
fi

if [[ -f "${TMP_DIR}/.agent-guard-init" ]]; then
    pass "Init stub created at repo root"
else
    fail "Init stub not found"
fi

if [[ -f "${TMP_DIR}/agent-guard.yaml" ]]; then
    pass "agent-guard.yaml created from example"
else
    fail "agent-guard.yaml not found"
fi

if [[ -d "${TMP_DIR}/agent-guard-core" ]]; then
    pass "Package copied to target repo"
else
    fail "Package not copied"
fi

if [[ -f "${TMP_DIR}/.gitignore" ]] && grep -qxF ".agent-guard/" "${TMP_DIR}/.gitignore" && grep -qxF ".githooks/" "${TMP_DIR}/.gitignore"; then
    pass "Runtime artifacts added to .gitignore"
else
    fail ".gitignore missing Agent Guard entries"
fi

if [[ -f "${TMP_DIR}/.gitattributes" ]]; then
    pass ".gitattributes created for LF line endings"
else
    fail ".gitattributes not created"
fi

if [[ ! -d "${TMP_DIR}/agent-guard-core/shell" ]]; then
    pass "No dangling 'shell' directory copied by installer"
else
    fail "Installer copied a non-existent 'shell' directory"
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo ""
    echo "❌ ${ERRORS} test(s) failed."
    exit 1
fi

echo ""
echo "✅ All installer tests passed."
