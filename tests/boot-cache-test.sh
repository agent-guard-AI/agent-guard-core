#!/usr/bin/env bash
#
# boot-cache-test.sh — Unit tests for the ADR-0051 boot cache.
#
# Safe to run standalone or via packages/agent-guard-core/tests/run-all.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/../src"
TMP_WORKTREE="$(mktemp -d)"

AG_PYTHON="${AG_PYTHON:-python3}"

PASS=0
FAIL=0

_cleanup() {
    rm -rf "${TMP_WORKTREE}"
}
trap _cleanup EXIT

fail() {
    echo "❌ $1" >&2
    FAIL=$((FAIL + 1))
}

pass() {
    echo "✅ $1"
    PASS=$((PASS + 1))
}

# Load boot-cache.sh in function-only mode to avoid side effects.
export AGENT_GUARD_FUNCTIONS_ONLY=1
if [[ -f "${SRC_DIR}/boot-cache.sh" ]]; then
    source "${SRC_DIR}/boot-cache.sh"
else
    echo "❌ boot-cache.sh not found at ${SRC_DIR}/boot-cache.sh" >&2
    exit 1
fi

# Create a fake worktree with a git repo and an ALERTAS.md artifact.
mkdir -p "${TMP_WORKTREE}/.agent-guard/session"
git init "${TMP_WORKTREE}" >/dev/null 2>&1
git -C "${TMP_WORKTREE}" checkout -b ia-kimi7/ia-a/task-test >/dev/null 2>&1 || true
printf 'P0 alert content\n' > "${TMP_WORKTREE}/ALERTAS.md"

echo "Running boot-cache tests..."

# ---------------------------------------------------------------------------
# Test 1: save then load returns valid cache
# ---------------------------------------------------------------------------
_boot_state_save "kimi7" "${TMP_WORKTREE}" "ia-kimi7/ia-a/task-test" "lease token-economy todo" "${TMP_WORKTREE}/ALERTAS.md" >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
    fail "Test 1: _boot_state_save should succeed"
else
    pass "Test 1: _boot_state_save succeeds"
fi

unset HMVIP_BOOT_CACHE_VALID HMVIP_BOOT_CACHE_LAYERS HMVIP_BOOT_CACHE_TIMESTAMP
if _boot_state_load "kimi7" "${TMP_WORKTREE}" "lease token-economy todo" >/dev/null 2>&1; then
    pass "Test 2: _boot_state_load succeeds for matching identity/branch"
else
    fail "Test 2: _boot_state_load should succeed for matching identity/branch"
fi

if [[ "${HMVIP_BOOT_CACHE_VALID:-}" == "1" ]]; then
    pass "Test 3: HMVIP_BOOT_CACHE_VALID is exported"
else
    fail "Test 3: HMVIP_BOOT_CACHE_VALID should be 1, got '${HMVIP_BOOT_CACHE_VALID:-}'"
fi

if [[ "${HMVIP_BOOT_CACHE_LAYERS:-}" == *"token-economy"* ]]; then
    pass "Test 4: HMVIP_BOOT_CACHE_LAYERS contains expected layer"
else
    fail "Test 4: HMVIP_BOOT_CACHE_LAYERS should contain token-economy, got '${HMVIP_BOOT_CACHE_LAYERS:-}'"
fi

# ---------------------------------------------------------------------------
# Test 5: load with different identity fails (isolation)
# ---------------------------------------------------------------------------
unset HMVIP_BOOT_CACHE_VALID HMVIP_BOOT_CACHE_LAYERS HMVIP_BOOT_CACHE_TIMESTAMP
if _boot_state_load "kimi1" "${TMP_WORKTREE}" "lease token-economy todo" >/dev/null 2>&1; then
    fail "Test 5: _boot_state_load should fail for different identity"
else
    pass "Test 5: _boot_state_load fails for different identity"
fi

# ---------------------------------------------------------------------------
# Test 6: load with missing layer fails
# ---------------------------------------------------------------------------
unset HMVIP_BOOT_CACHE_VALID HMVIP_BOOT_CACHE_LAYERS HMVIP_BOOT_CACHE_TIMESTAMP
if _boot_state_load "kimi7" "${TMP_WORKTREE}" "lease token-economy todo council" >/dev/null 2>&1; then
    fail "Test 6: _boot_state_load should fail when requested layer is missing"
else
    pass "Test 6: _boot_state_load fails when requested layer is missing"
fi

# ---------------------------------------------------------------------------
# Test 7: artifact digest invalidation
# ---------------------------------------------------------------------------
unset HMVIP_BOOT_CACHE_VALID HMVIP_BOOT_CACHE_LAYERS HMVIP_BOOT_CACHE_TIMESTAMP
_boot_state_save "kimi7" "${TMP_WORKTREE}" "ia-kimi7/ia-a/task-test" "lease token-economy todo" "${TMP_WORKTREE}/ALERTAS.md" >/dev/null 2>&1
printf 'P0 alert changed\n' >> "${TMP_WORKTREE}/ALERTAS.md"
if _boot_state_load "kimi7" "${TMP_WORKTREE}" "lease token-economy todo" >/dev/null 2>&1; then
    fail "Test 7: _boot_state_load should fail after artifact changes"
else
    pass "Test 7: _boot_state_load fails after artifact changes"
fi

# ---------------------------------------------------------------------------
# Test 8: TTL invalidation
# ---------------------------------------------------------------------------
unset HMVIP_BOOT_CACHE_VALID HMVIP_BOOT_CACHE_LAYERS HMVIP_BOOT_CACHE_TIMESTAMP
printf 'P0 alert content\n' > "${TMP_WORKTREE}/ALERTAS.md"
HMVIP_BOOT_CACHE_TTL_SECONDS=-1
_boot_state_save "kimi7" "${TMP_WORKTREE}" "ia-kimi7/ia-a/task-test" "lease token-economy todo" "${TMP_WORKTREE}/ALERTAS.md" >/dev/null 2>&1
if _boot_state_load "kimi7" "${TMP_WORKTREE}" "lease token-economy todo" >/dev/null 2>&1; then
    fail "Test 8: _boot_state_load should fail with expired TTL"
else
    pass "Test 8: _boot_state_load fails with expired TTL"
fi
HMVIP_BOOT_CACHE_TTL_SECONDS=3600

# ---------------------------------------------------------------------------
# Test 9: invalidate removes cache
# ---------------------------------------------------------------------------
unset HMVIP_BOOT_CACHE_VALID HMVIP_BOOT_CACHE_LAYERS HMVIP_BOOT_CACHE_TIMESTAMP
printf 'P0 alert content\n' > "${TMP_WORKTREE}/ALERTAS.md"
_boot_state_save "kimi7" "${TMP_WORKTREE}" "ia-kimi7/ia-a/task-test" "lease token-economy todo" "${TMP_WORKTREE}/ALERTAS.md" >/dev/null 2>&1
_boot_state_invalidate "${TMP_WORKTREE}" >/dev/null 2>&1
if [[ -f "${TMP_WORKTREE}/.agent-guard/session/boot-state.json" ]]; then
    fail "Test 9: boot-state.json should be removed after invalidate"
else
    pass "Test 9: boot-state.json removed after invalidate"
fi

# ---------------------------------------------------------------------------
# Test 10: AGENT_GUARD_FUNCTIONS_ONLY=1 produces no side effects
# ---------------------------------------------------------------------------
if command -v _boot_state_file_path >/dev/null 2>&1; then
    pass "Test 10: boot-cache functions loaded without side effects"
else
    fail "Test 10: boot-cache functions should be loadable"
fi

# ---------------------------------------------------------------------------
# Test 11: layer-0 helper includes ALERTAS-RECENT (init.sh default)
# ---------------------------------------------------------------------------
unset HMVIP_BOOT_CACHE_VALID HMVIP_BOOT_CACHE_LAYERS HMVIP_BOOT_CACHE_TIMESTAMP
rm -f "${TMP_WORKTREE}/.agent-guard/session/boot-state.json"
printf 'P0 alert content\n' > "${TMP_WORKTREE}/ALERTAS-RECENT.md"
_layer0="$(_boot_state_layers_for_consciousness 0)"
_artifacts0="$(_boot_state_artifacts_for_consciousness 0 "${TMP_WORKTREE}")"
_boot_state_save "kimi7" "${TMP_WORKTREE}" "ia-kimi7/ia-a/task-test" "${_layer0}" "${_artifacts0}" >/dev/null 2>&1
if _boot_state_load "kimi7" "${TMP_WORKTREE}" "lease token-economy todo alerts-recent" >/dev/null 2>&1; then
    pass "Test 11: layer 0 cache satisfies alerts-recent layer"
else
    fail "Test 11: layer 0 cache should satisfy alerts-recent layer (got '${HMVIP_BOOT_CACHE_LAYERS:-}')"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
