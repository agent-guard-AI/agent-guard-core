#!/usr/bin/env bash
#
# Agent Guard — Release / Reuse / Cooldown Test
#
# Validates that:
#   1. _clear_session records released_at.
#   2. A slot released in the last 60s is skipped on the first acquire pass
#      (cooldown), unless it is the only free slot.
#   3. A released worktree parked on _released/<identity> is NOT reused when
#      init is sourced again from inside it; a fresh slot is acquired instead.
#
# Usage: bash tests/agent-guard/agent-guard-release-reuse-test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INIT_SCRIPT="${REPO_ROOT}/packages/agent-guard-core/src/init.sh"
CONFIG_BIN="${REPO_ROOT}/packages/agent-guard-core/bin/agent-guard-config"

ERRORS=0

fail() {
    echo "❌ FAIL: $1" >&2
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "✅ PASS: $1"
}

TMP_DIR=""
cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}
trap cleanup EXIT

TMP_DIR="$(mktemp -d /tmp/agent-guard-release-reuse-test-XXXXXX)"
MAIN_REPO="${TMP_DIR}/hmvip"
BASE_DIR="${TMP_DIR}"
SESSION_DIR="${MAIN_REPO}/.kiro/locks/agent-sessions"

mkdir -p "${MAIN_REPO}"
cd "${MAIN_REPO}"
git init -q
git config user.email "test@hmvip.dev"
git config user.name "Test Agent"

# Create develop branch with an initial commit.
git checkout -q -b develop
echo "init" > README.md
git add README.md
git commit -q -m "initial"

# Agent guard config for this temp repo.
cat > agent-guard.yaml <<YAML
---
project:
  name: hmvip-test
  domain: hmvip-test.dev
paths:
  main_repo: ${MAIN_REPO}
  base_dir: ${BASE_DIR}
  package_root: packages/agent-guard-core
  session_storage: .kiro/locks/agent-sessions
  init_script: .hmvip-agent-init
identities:
  testia:
    slots: 4
    max_slots: 4
    auto_expand: false
    worktree_prefix: hmvip-ia-testia
    author_email: agent-testia{n}@hmvip-test.dev
    author_name: HMVIP Testia{n} Agent
git:
  protected_branches:
    - develop
  notes_ref: refs/notes/hmvip-worktree
  hooks_path: .githooks
  base_branch: develop
commit:
  author_template: agent-{identity}@{domain}
  message_pattern: '^(feat|fix|docs|refactor|chore|test|ci|hotfix)(\\(.+\\))?: .+'
  require_conventional: false
  identity_env_var: AGENT_GUARD_IDENTITY
YAML

mkdir -p packages/agent-guard-core/src packages/agent-guard-core/bin
cp "${INIT_SCRIPT}" packages/agent-guard-core/src/init.sh
cp "${CONFIG_BIN}" packages/agent-guard-core/bin/agent-guard-config
chmod +x packages/agent-guard-core/bin/agent-guard-config

# Stub init script matching .hmvip-agent-init semantics.
# It mocks the global lock helpers so tests do not depend on flock(1) fd
# availability inside nested subshells.
cat > .hmvip-agent-init <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script must be sourced, not executed directly." >&2
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AGENT_GUARD_FROM_STUB=1
export AGENT_GUARD_INIT_NAME=".hmvip-agent-init"
source "${SCRIPT_DIR}/packages/agent-guard-core/src/init.sh" "$@"

# Mock lock helpers for isolated testing.
_ag_flock_acquire() { echo "mock"; }
_ag_flock_release() { true; }
STUB
chmod +x .hmvip-agent-init

mkdir -p "${SESSION_DIR}"

# Helper to write a session file.
write_session() {
    local identity="$1"
    local status="$2"
    local released_at="${3:-null}"
    local pid="${4:-12345}"
    cat > "${SESSION_DIR}/${identity}.json" <<JSON
{
  "identity": "${identity}",
  "status": "${status}",
  "role": null,
  "branch": "",
  "pid": ${pid},
  "timestamp": 0,
  "worktree_path": "${BASE_DIR}/hmvip-ia-${identity}",
  "impact_plugins": [],
  "released_at": ${released_at}
}
JSON
}

# Helper to source init and capture stdout/stderr plus exit code.
run_init() {
    local cwd="$1"
    shift
    (
        cd "${cwd}"
        # shellcheck disable=SC1091
        source "${MAIN_REPO}/.hmvip-agent-init" "$@" 2>&1
    ) || true
}

# Redefine global lock helpers to no-ops for tests that call _acquire_slot.
mock_lock() {
    _ag_flock_acquire() { echo "mock"; }
    _ag_flock_release() { true; }
}

# ---------------------------------------------------------------------------
# Test 1: _clear_session records released_at
# ---------------------------------------------------------------------------
write_session "testia1" "active" "null"
(
    cd "${MAIN_REPO}"
    # shellcheck disable=SC1091
    source packages/agent-guard-core/src/init.sh --release >/dev/null 2>&1 || true
) || true
# _clear_session needs current worktree to be an agent worktree; release will
# fail because we are in the main repo, but it still calls _clear_session when
# validation fails? No — it returns early. Instead call _clear_session directly.
(
    cd "${MAIN_REPO}"
    # shellcheck disable=SC1091
    source packages/agent-guard-core/src/init.sh --status >/dev/null 2>&1 || true
    _clear_session "testia1"
)
released_at="$(python3 -c "import json; print(json.load(open('${SESSION_DIR}/testia1.json')).get('released_at',''))")"
if [[ -n "${released_at}" && "${released_at}" != "None" && "${released_at}" != "null" ]]; then
    pass "_clear_session records released_at (${released_at})"
else
    fail "_clear_session did not record released_at (got '${released_at}')"
fi

# ---------------------------------------------------------------------------
# Test 2: recently released slot is skipped in first acquire pass
# ---------------------------------------------------------------------------
# testia1 active, testia2 recently released, testia3/testia4 free.
write_session "testia1" "active" "null" "$$"
write_session "testia2" "free" "$(python3 -c 'import time; print(int(time.time()))')"
write_session "testia3" "free" "null"
write_session "testia4" "free" "null"

result="$(
    cd "${MAIN_REPO}"
    # shellcheck disable=SC1091
    source packages/agent-guard-core/src/init.sh --status >/dev/null 2>&1 || true
    mock_lock
    _acquire_slot "testia" "ia-a" ""
)"
selected="$(echo "${result}" | sed -n '1p')"
if [[ "${selected}" == "testia3" ]]; then
    pass "recently released slot testia2 skipped, selected ${selected}"
else
    fail "expected testia3 to be selected, got '${selected}'"
fi

# ---------------------------------------------------------------------------
# Test 3: only recently released slot available is reused in fallback pass
# ---------------------------------------------------------------------------
write_session "testia1" "active" "null" "$$"
write_session "testia2" "free" "$(python3 -c 'import time; print(int(time.time()))')"
write_session "testia3" "active" "null" "$$"
write_session "testia4" "active" "null" "$$"

result="$(
    cd "${MAIN_REPO}"
    # shellcheck disable=SC1091
    source packages/agent-guard-core/src/init.sh --status >/dev/null 2>&1 || true
    mock_lock
    _acquire_slot "testia" "ia-a" ""
)"
selected="$(echo "${result}" | sed -n '1p')"
if [[ "${selected}" == "testia2" ]]; then
    pass "fallback pass selects recently released slot testia2 when it is the only free one"
else
    fail "expected testia2 to be selected in fallback, got '${selected}'"
fi

# ---------------------------------------------------------------------------
# Test 4: _released/<identity> worktree is not reused
# ---------------------------------------------------------------------------
# Create worktree for testia1 parked on _released/testia1.
WT1="${BASE_DIR}/hmvip-ia-testia1"
git worktree add -q "${WT1}" -b "_released/testia1" develop
# testia1 is free but recently released (cooldown), so acquisition must
# skip it and pick testia2 instead.
write_session "testia1" "free" "$(python3 -c 'import time; print(int(time.time()))')"
write_session "testia2" "free" "null"
write_session "testia3" "active" "null" "$$"
write_session "testia4" "active" "null" "$$"

output="$(run_init "${WT1}" testia ia-a)"
if echo "${output}" | grep -q "acquiring a fresh slot"; then
    pass "released worktree is not reused"
else
    fail "expected message about acquiring fresh slot, got: ${output}"
fi

if echo "${output}" | grep -q "Identity:   testia2"; then
    pass "fresh slot testia2 acquired after release"
else
    fail "expected testia2 to be acquired, got: ${output}"
fi

echo ""
if [[ ${ERRORS} -gt 0 ]]; then
    echo "❌ ${ERRORS} test(s) failed."
    exit 1
fi

echo "✅ All release/reuse/cooldown tests passed."
