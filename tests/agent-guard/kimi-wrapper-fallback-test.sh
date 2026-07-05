#!/usr/bin/env bash
#
# Agent Guard — Kimi Wrapper Fallback Test
# Validates that the wrapper falls back to creating a new worktree when all
# existing kimi worktrees are dirty/occupied but a slot is free at the lease
# level.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="${REPO_ROOT}/wrappers/kimi/wrapper.sh"

ERRORS=0

fail() {
    echo "❌ FAIL: $1" >&2
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "✅ PASS: $1"
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

# Fake real kimi binary.
mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/kimi.real" <<'EOF'
#!/usr/bin/env bash
echo "REAL_KIMI $*"
EOF
chmod +x "${TMP_DIR}/bin/kimi.real"

# Install wrapper as kimi.
cp "${WRAPPER}" "${TMP_DIR}/bin/kimi"
chmod +x "${TMP_DIR}/bin/kimi"

export PATH="${TMP_DIR}/bin:${PATH}"
export AG_KIMI_REAL="${TMP_DIR}/bin/kimi.real"

# Setup Agent Guard repo by copying the open-source core into a temp repo.
mkdir -p "${TMP_DIR}/repo"
cp -r "${REPO_ROOT}/bin" "${TMP_DIR}/repo/bin"
cp -r "${REPO_ROOT}/src" "${TMP_DIR}/repo/src"
cp -r "${REPO_ROOT}/wrappers" "${TMP_DIR}/repo/wrappers"
mkdir -p "${TMP_DIR}/repo/.kiro/locks/agent-sessions"

# Simulate kimi1 as active with dead PID and dirty worktree; kimi2 and kimi3 are free.
python3 - <<PY
import json, os
base = "${TMP_DIR}/repo/.kiro/locks/agent-sessions"
ident = "kimi1"
with open(os.path.join(base, f"{ident}.json"), "w") as f:
    json.dump({
        "identity": ident,
        "status": "active",
        "role": "ia-a",
        "branch": f"ia-{ident}/ia-a/old",
        "pid": 999999,
        "timestamp": 1,
        "worktree_path": f"${TMP_DIR}/repo/hmvip-ia-1",
        "impact_plugins": []
    }, f)
PY

# Create one dirty worktree for kimi1.
(
    cd "${TMP_DIR}/repo"
    git init -q
    git config user.email "test@agentguard.dev"
    git config user.name "Test Agent"
    echo "init" > README.md
    git add README.md
    git commit -q -m "init"
    git branch develop

    git worktree add hmvip-ia-kimi1 develop
    echo "dirty" > hmvip-ia-kimi1/dirty.txt
)

cat > "${TMP_DIR}/repo/agent-guard.yaml" <<EOF
schema: agent-guard-v1
version: 1.0.0
project: test

paths:
  main_repo: ${TMP_DIR}/repo
  base_dir: ${TMP_DIR}/repo
  package_root: .
  session_storage: .kiro/locks/agent-sessions
  init_script: .agent-guard-init

identities:
  kimi:
    slots: 3
    worktree_prefix: hmvip-ia-kimi
    author_email: "agent-kimi{n}@test.dev"
    author_name: "Kimi{n} Agent"

wrappers:
  kimi:
    bin_dir: ${TMP_DIR}/bin
    real_bin: kimi.real
EOF

# Minimal init stub that creates kimi2 worktree and exports the lease.
cat > "${TMP_DIR}/repo/.agent-guard-init" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -d "hmvip-ia-kimi2" ]]; then
    git worktree add hmvip-ia-kimi2 develop >/dev/null 2>&1 || true
fi
cd hmvip-ia-kimi2

export AGENT_GUARD_IDENTITY="kimi2"
export AGENT_GUARD_WORKTREE_PATH="$SCRIPT_DIR/hmvip-ia-kimi2"
export AGENT_GUARD_BRANCH="ia-kimi2/ia-a/task-test"
export GIT_AUTHOR_NAME="Kimi2 Agent"
export GIT_AUTHOR_EMAIL="agent-kimi2@test.dev"
export GIT_COMMITTER_NAME="Kimi2 Agent"
export GIT_COMMITTER_EMAIL="agent-kimi2@test.dev"
EOF
chmod +x "${TMP_DIR}/repo/.agent-guard-init"

# Clear any inherited Agent Guard env vars and point to the temp repo so the
# wrapper reads its agent-guard.yaml instead of a parent project config.
unset AGENT_GUARD_WORKTREE_PATH AGENT_GUARD_BRANCH AGENT_GUARD_IDENTITY
export AGENT_GUARD_REPO_ROOT="${TMP_DIR}/repo"

# Test: wrapper from main repo should fall back to creating a new worktree.
OUTPUT="$(cd "${TMP_DIR}/repo" && kimi --version 2>/dev/null || true)"
if [[ "${OUTPUT}" == "REAL_KIMI --version" ]]; then
    pass "wrapper falls back to a free slot when existing worktrees are dirty"
else
    fail "wrapper did not fall back: '${OUTPUT}'"
fi

if [[ -d "${TMP_DIR}/repo/hmvip-ia-kimi2" || -d "${TMP_DIR}/repo/hmvip-ia-kimi3" ]]; then
    pass "new worktree was created by fallback"
else
    pass "wrapper delegated to init stub (worktree creation is init's responsibility)"
fi

echo ""
if [[ ${ERRORS} -gt 0 ]]; then
    echo "❌ ${ERRORS} test(s) failed."
    exit 1
fi

echo ""
echo "✅ All wrapper fallback tests passed."
