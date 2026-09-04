#!/usr/bin/env bash
#
# release-task-note-drift functional test
#
# Verifies that release-helpers auto-commit modified .agent-guard/tasks/*.md
# notes when they are the only remaining drift, preventing "released session
# with active work" caused by filemode or content changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASE_HELPERS="${REPO_ROOT}/src/release-helpers.sh"

ERRORS=0

fail() {
    echo "❌ FAIL: $1" >&2
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "✅ PASS: $1"
}

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

FAKE_WORKTREE="${TMPDIR}/hmvip-ia-kimi1"
mkdir -p "${FAKE_WORKTREE}"

git -C "${FAKE_WORKTREE}" init -q
git -C "${FAKE_WORKTREE}" config user.email "agent-test1@example.com"
git -C "${FAKE_WORKTREE}" config user.name "Test Agent"

# Initial commit on develop.
echo "init" > "${FAKE_WORKTREE}/file.txt"
git -C "${FAKE_WORKTREE}" add file.txt
git -C "${FAKE_WORKTREE}" commit -q -m "initial"

# Create and checkout a task branch.
git -C "${FAKE_WORKTREE}" checkout -q -b ia-kimi1/ia-a/task-drift-test

# Mock identity detection so the helper can build a conventional commit message.
_detect_identity_from_worktree_name() {
    local name="$1"
    case "${name}" in
        hmvip-ia-kimi1) echo "kimi 1" ;;
        *) echo "" ;;
    esac
}
export -f _detect_identity_from_worktree_name

# Source the helpers.  journal/task-lifecycle are optional; silence warnings.
# shellcheck source=/dev/null
source "${RELEASE_HELPERS}" 2>/dev/null || true

# Helper to reset to a known clean state.
_reset_clean() {
    git -C "${FAKE_WORKTREE}" checkout -- .
    git -C "${FAKE_WORKTREE}" clean -fdq
}

# Test 1: modified task note (filemode/content) is auto-committed when alone.
_reset_clean
mkdir -p "${FAKE_WORKTREE}/.agent-guard/tasks"
echo "# Task note" > "${FAKE_WORKTREE}/.agent-guard/tasks/kimi1.md"
git -C "${FAKE_WORKTREE}" add .agent-guard/tasks/kimi1.md
git -C "${FAKE_WORKTREE}" commit -q -m "add task note"

# Simulate runtime filemode/content drift.
echo "" >> "${FAKE_WORKTREE}/.agent-guard/tasks/kimi1.md"
chmod 0600 "${FAKE_WORKTREE}/.agent-guard/tasks/kimi1.md"

if ! _auto_commit_task_notes_if_only_drift "${FAKE_WORKTREE}" >/dev/null 2>&1; then
    fail "auto-commit should succeed when task note is the only drift"
fi

if git -C "${FAKE_WORKTREE}" status --porcelain 2>/dev/null | grep -q .; then
    fail "worktree should be clean after auto-commit"
fi

last_msg="$(git -C "${FAKE_WORKTREE}" log -1 --format=%s)"
if [[ "${last_msg}" != "chore(agent-guard): [IA-kimi1] auto-commit task notes before release" ]]; then
    fail "unexpected commit message: ${last_msg}"
fi
pass "auto-commits task note when it is the only drift"

# Test 2: task note drift is NOT auto-committed when other files are dirty.
_reset_clean
mkdir -p "${FAKE_WORKTREE}/.agent-guard/tasks"
echo "# Task note" > "${FAKE_WORKTREE}/.agent-guard/tasks/kimi1.md"
git -C "${FAKE_WORKTREE}" add .agent-guard/tasks/kimi1.md
git -C "${FAKE_WORKTREE}" commit -q -m "add task note"

echo "" >> "${FAKE_WORKTREE}/.agent-guard/tasks/kimi1.md"
echo "other" >> "${FAKE_WORKTREE}/file.txt"

if ! _auto_commit_task_notes_if_only_drift "${FAKE_WORKTREE}" >/dev/null 2>&1; then
    fail "helper should return 0 without auto-committing when other files are dirty"
fi

if git -C "${FAKE_WORKTREE}" status --porcelain 2>/dev/null | grep -q 'file\.txt'; then
    : # expected
else
    fail "other dirty file should remain uncommitted"
fi
pass "does not auto-commit when non-task files are dirty"

# Test 3: clean worktree is a no-op.
_reset_clean
if ! _auto_commit_task_notes_if_only_drift "${FAKE_WORKTREE}" >/dev/null 2>&1; then
    fail "helper should return 0 on clean worktree"
fi
pass "no-op on clean worktree"

# Test 4: _validate_worktree_release_ready triggers the auto-commit.
_reset_clean
mkdir -p "${FAKE_WORKTREE}/.agent-guard/tasks"
echo "# Task note" > "${FAKE_WORKTREE}/.agent-guard/tasks/kimi1.md"
git -C "${FAKE_WORKTREE}" add .agent-guard/tasks/kimi1.md
git -C "${FAKE_WORKTREE}" commit -q -m "add task note"

echo "" >> "${FAKE_WORKTREE}/.agent-guard/tasks/kimi1.md"
chmod 0600 "${FAKE_WORKTREE}/.agent-guard/tasks/kimi1.md"

if ! _validate_worktree_release_ready "${FAKE_WORKTREE}" >/dev/null 2>&1; then
    fail "release should be ready after auto-committing task note"
fi
pass "_validate_worktree_release_ready auto-commits task note drift"

if [[ "${ERRORS}" -gt 0 ]]; then
    echo ""
    echo "❌ ${ERRORS} test(s) failed." >&2
    exit 1
fi

echo ""
echo "✅ All release-task-note-drift tests passed."
