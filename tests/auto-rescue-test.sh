#!/usr/bin/env bash
#
# Auto-Rescue Protocol functional test.
#
# Simulates a dead session that leaves uncommitted work in an identity
# worktree, then verifies that _ag_auto_rescue_dirty_worktree creates a
# rescue commit, tags it, updates the slot task note, and leaves the
# worktree clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_SCRIPT="${SCRIPT_DIR}/../src/init.sh"
ERRORS=0

fail() {
    echo "❌ FAIL: $1" >&2
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "✅ PASS: $1"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Copy the real agent-guard-core package into the temp repo so that sourcing
# init.sh from inside the temp repo resolves _AG_REPO_ROOT to TMP_DIR.
cp -R "${SCRIPT_DIR}/../.." "${TMP_DIR}/packages"
INIT_SCRIPT="${TMP_DIR}/packages/agent-guard-core/src/init.sh"

# ---------------------------------------------------------------------------
# 1. Build a minimal agent-guard repository.
# ---------------------------------------------------------------------------
cd "${TMP_DIR}"
git init --quiet
git config user.name "Test Agent"
git config user.email "agent-test@hmvip.dev"

mkdir -p .agent-guard/tasks
cat > .agent-guard/tasks/codewhale1.md <<'EOF'
# Tarefa do slot `codewhale1`

**Branch:** `ia-codewhale1/ia-a/task-test`
**Tópico:** `teste de auto-rescue`

## Tarefa ATUAL — 2026-08-16
Trabalho em andamento.

### Próximo passo
Continuar teste.
EOF

cat > agent-guard.yaml <<'EOF'
---
project:
  name: test
  domain: test.dev

paths:
  main_repo: /tmp/nonexistent
  base_dir: /tmp/nonexistent
  package_root: packages/agent-guard-core
  session_storage: .agent-guard/sessions
  init_script: .agent-guard-init

identities:
  codewhale:
    slots: 2
    max_slots: 10
    auto_expand: true
    worktree_prefix: hmvip-ia-codewhale
    author_email: agent-codewhale{n}@test.dev
    author_name: Test CodeWhale{n} Agent

git:
  protected_branches:
    - develop
    - main
  base_branch: develop
EOF

# Initial commit on develop.
git add agent-guard.yaml .agent-guard/tasks/codewhale1.md
git commit --quiet -m "chore(test): initial setup"

# Create the identity task branch.
git checkout --quiet -b ia-codewhale1/ia-a/task-test

# Simulate dead-session dirty work.
echo "important work in progress" > feature.txt
echo "another change" >> .agent-guard/tasks/codewhale1.md

# ---------------------------------------------------------------------------
# 2. Load agent-guard helper functions from the real source.
# ---------------------------------------------------------------------------
AGENT_GUARD_FUNCTIONS_ONLY=1
source "${INIT_SCRIPT}"

# ---------------------------------------------------------------------------
# 3. Run auto-rescue.
# ---------------------------------------------------------------------------
if ! _ag_auto_rescue_dirty_worktree "codewhale1" "${TMP_DIR}" "test dead session"; then
    fail "_ag_auto_rescue_dirty_worktree returned non-zero"
fi

# ---------------------------------------------------------------------------
# 4. Assertions.
# ---------------------------------------------------------------------------
if [[ -z "$(git status --porcelain)" ]]; then
    pass "worktree is clean after auto-rescue"
else
    fail "worktree still dirty after auto-rescue"
    git status --short
fi

RESCUE_COMMIT_MSG="$(git log --grep='auto-rescue from test dead session' --pretty=%B -1)"
if [[ -n "${RESCUE_COMMIT_MSG}" && "${RESCUE_COMMIT_MSG}" == *"auto-rescue from test dead session"* ]]; then
    pass "rescue commit message identifies the reason"
else
    fail "rescue commit message missing expected text"
    echo "Got latest: $(git log -1 --pretty=%B)"
fi

if [[ -n "${RESCUE_COMMIT_MSG}" && "${RESCUE_COMMIT_MSG}" == *"REVIEW REQUIRED"* ]]; then
    pass "rescue commit flags required review"
else
    fail "rescue commit missing REVIEW REQUIRED"
fi

RESCUE_TAG="$(git tag -l 'rescue-codewhale1-*' | head -n1)"
if [[ -n "${RESCUE_TAG}" ]]; then
    pass "rescue tag created: ${RESCUE_TAG}"
else
    fail "rescue tag not found"
fi

NOTE=".agent-guard/tasks/codewhale1.md"
if grep -q "Resgate automático pendente de revisão" "${NOTE}"; then
    pass "slot task note contains pending rescue review section"
else
    fail "slot task note missing pending rescue review section"
fi

if grep -q "feature.txt" "${NOTE}"; then
    pass "slot task note lists rescued files"
else
    fail "slot task note missing rescued file list"
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo ""
    echo "❌ ${ERRORS} test(s) failed."
    exit 1
fi

echo ""
echo "✅ All auto-rescue functional tests passed."
