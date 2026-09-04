#!/usr/bin/env bash
#
# safe-squash functional test
#
# Verifies that agent-guard safe-squash preserves the worktree-origin git note
# required by CI Worktree Origin Audit, and enforces F1 safety preconditions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AGENT_GUARD_BIN="${REPO_ROOT}/bin/agent-guard"

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

# Build a minimal fake agent-guard repo inside the temp dir.
FAKE_REPO="${TMPDIR}/repo"
mkdir -p "${FAKE_REPO}/packages/agent-guard-core/bin"
mkdir -p "${FAKE_REPO}/packages/agent-guard-core/src"
mkdir -p "${FAKE_REPO}/packages/agent-guard-core/hooks"

cp "${AGENT_GUARD_BIN}" "${FAKE_REPO}/packages/agent-guard-core/bin/agent-guard"
cp "${REPO_ROOT}/bin/agent-guard-config" "${FAKE_REPO}/packages/agent-guard-core/bin/agent-guard-config"
cp "${REPO_ROOT}/bin/agent-guard-python" "${FAKE_REPO}/packages/agent-guard-core/bin/agent-guard-python"
cp "${REPO_ROOT}/src/safe-squash.sh" "${FAKE_REPO}/packages/agent-guard-core/src/safe-squash.sh"
cp "${REPO_ROOT}/src/init.sh" "${FAKE_REPO}/packages/agent-guard-core/src/init.sh"

# Minimal agent-guard.yaml.
cat > "${FAKE_REPO}/agent-guard.yaml" <<'YAML'
identities:
  test:
    worktree_prefix: repo-ia-test
git:
  notes_ref: refs/notes/hmvip-worktree
YAML

# Create a fake worktree directory matching the prefix.
FAKE_WORKTREE="${FAKE_REPO}-ia-test1"
mkdir -p "${FAKE_WORKTREE}"

# Init git in the worktree.
git -C "${FAKE_WORKTREE}" init -q
git -C "${FAKE_WORKTREE}" config user.email "agent-test1@example.com"
git -C "${FAKE_WORKTREE}" config user.name "Test Agent"

# Add the fake repo as a remote so safe-squash can resolve config.
git -C "${FAKE_WORKTREE}" remote add origin "${FAKE_REPO}"

# Create initial commit on develop.
echo "init" > "${FAKE_WORKTREE}/file.txt"
git -C "${FAKE_WORKTREE}" add file.txt
git -C "${FAKE_WORKTREE}" commit -q -m "initial"

# Create and checkout a task branch.
git -C "${FAKE_WORKTREE}" checkout -q -b ia-test1/ia-a/task-safe-squash

# Add agent-guard files to the branch so config is discoverable from worktree.
cp -r "${FAKE_REPO}/packages" "${FAKE_WORKTREE}/"
cp "${FAKE_REPO}/agent-guard.yaml" "${FAKE_WORKTREE}/"
git -C "${FAKE_WORKTREE}" add .
git -C "${FAKE_WORKTREE}" commit -q -m "add agent-guard files"

# Simulate three commits made by the AI (with worktree notes from post-commit).
for i in 1 2 3; do
    echo "line${i}" >> "${FAKE_WORKTREE}/file.txt"
    git -C "${FAKE_WORKTREE}" add file.txt
    git -C "${FAKE_WORKTREE}" commit -q -m "dummy commit ${i}"
    # Manually add the note that post-commit would add.
    git -C "${FAKE_WORKTREE}" notes --ref=refs/notes/hmvip-worktree add -f -m "worktree:${FAKE_WORKTREE}
identity:test1
branch:ia-test1/ia-a/task-safe-squash" HEAD
done

_run_safe_squash() {
    (
        cd "${FAKE_WORKTREE}"
        source "${FAKE_WORKTREE}/packages/agent-guard-core/bin/agent-guard" safe-squash "$@"
    )
}

_note_at_head() {
    git -C "${FAKE_WORKTREE}" notes --ref=refs/notes/hmvip-worktree show HEAD 2>/dev/null || true
}

# Test 1: basic count squash preserves note.
_run_safe_squash 1 -m "squash-one"
NOTE_CONTENT="$(_note_at_head)"
if [[ -n "${NOTE_CONTENT}" ]]; then
    pass "squash count=1 preserves worktree note"
else
    fail "squash count=1 missing worktree note"
fi

# Test 2: --base explicit squash preserves note.
BASE_REF="$(git -C "${FAKE_WORKTREE}" rev-parse HEAD~2)"
_run_safe_squash --base "${BASE_REF}" -m "squash-base"
NOTE_CONTENT="$(_note_at_head)"
if echo "${NOTE_CONTENT}" | grep -q "identity:test1"; then
    pass "squash --base preserves identity in note"
else
    fail "squash --base missing identity in note"
fi

# Test 3: dirty working tree (unstaged) is blocked.
git -C "${FAKE_WORKTREE}" checkout -q -b ia-test1/ia-a/dirty-test
echo "dirty" >> "${FAKE_WORKTREE}/file.txt"
if _run_safe_squash 1 -m "dirty" 2>/dev/null; then
    fail "dirty unstaged working tree should be blocked"
else
    pass "dirty unstaged working tree blocked"
fi
git -C "${FAKE_WORKTREE}" checkout -- file.txt

# Test 4: staged change is blocked.
echo "staged" >> "${FAKE_WORKTREE}/file.txt"
git -C "${FAKE_WORKTREE}" add file.txt
if _run_safe_squash 1 -m "staged" 2>/dev/null; then
    fail "staged index should be blocked"
else
    pass "staged index blocked"
fi
git -C "${FAKE_WORKTREE}" reset HEAD file.txt
git -C "${FAKE_WORKTREE}" checkout -- file.txt

# Test 5: untracked file is blocked.
echo "untracked" > "${FAKE_WORKTREE}/untracked.txt"
if _run_safe_squash 1 -m "untracked" 2>/dev/null; then
    fail "untracked file should be blocked"
else
    pass "untracked file blocked"
fi
rm "${FAKE_WORKTREE}/untracked.txt"

# Test 6: stacked branch protection.
# parent-branch has a commit not in current branch; origin/develop points to parent.
git -C "${FAKE_WORKTREE}" checkout -q ia-test1/ia-a/task-safe-squash
git -C "${FAKE_WORKTREE}" checkout -q -b ia-test1/ia-a/parent-test
echo "parent" > "${FAKE_WORKTREE}/parent.txt"
git -C "${FAKE_WORKTREE}" add parent.txt
git -C "${FAKE_WORKTREE}" commit -q -m "parent commit"
git -C "${FAKE_WORKTREE}" checkout -q -b ia-test1/ia-a/child-test
echo "child" > "${FAKE_WORKTREE}/child.txt"
git -C "${FAKE_WORKTREE}" add child.txt
git -C "${FAKE_WORKTREE}" commit -q -m "child commit"
git -C "${FAKE_WORKTREE}" update-ref refs/remotes/origin/develop ia-test1/ia-a/parent-test
if _run_safe_squash --all -m "stacked" 2>/dev/null; then
    fail "--all should be rejected (removed option)"
else
    pass "--all rejected"
fi
# --base below merge-base should also be rejected.
MERGE_BASE="$(git -C "${FAKE_WORKTREE}" merge-base HEAD origin/develop)"
if _run_safe_squash --base "${MERGE_BASE}" -m "stacked-below" 2>/dev/null; then
    fail "squash at or below merge-base should be blocked"
else
    pass "squash at or below merge-base blocked"
fi
git -C "${FAKE_WORKTREE}" update-ref -d refs/remotes/origin/develop

# Test 7: rollback on note failure.
git -C "${FAKE_WORKTREE}" checkout -q ia-test1/ia-a/task-safe-squash
ORIGINAL_HEAD="$(git -C "${FAKE_WORKTREE}" rev-parse HEAD)"
mkdir -p "${FAKE_WORKTREE}/fakebin"
cat > "${FAKE_WORKTREE}/fakebin/git" <<'FAKE'
#!/bin/bash
if [[ "$*" == *"notes"*"add"* ]]; then
  echo "FAKE GIT NOTES FAILURE" >&2
  exit 1
fi
/usr/bin/git "$@"
FAKE
chmod +x "${FAKE_WORKTREE}/fakebin/git"
(
    cd "${FAKE_WORKTREE}"
    PATH="${FAKE_WORKTREE}/fakebin:${PATH}"
    source "${FAKE_WORKTREE}/packages/agent-guard-core/bin/agent-guard" safe-squash 1 -m "should-rollback" 2>/dev/null || true
)
CURRENT_HEAD="$(git -C "${FAKE_WORKTREE}" rev-parse HEAD)"
if [[ "${CURRENT_HEAD}" == "${ORIGINAL_HEAD}" ]]; then
    pass "rollback restores original HEAD on note failure"
else
    fail "rollback did not restore original HEAD"
fi
rm -rf "${FAKE_WORKTREE}/fakebin"

# Test 8: --no-verify opt-in runs without pre-commit.
git -C "${FAKE_WORKTREE}" checkout -q ia-test1/ia-a/task-safe-squash
mkdir -p "${FAKE_WORKTREE}/.git/hooks"
cat > "${FAKE_WORKTREE}/.git/hooks/pre-commit" <<'HOOK'
#!/bin/bash
echo "[pre-commit] blocking" >&2
exit 1
HOOK
chmod +x "${FAKE_WORKTREE}/.git/hooks/pre-commit"
if _run_safe_squash 1 -m "no-verify" --no-verify 2>/dev/null; then
    pass "--no-verify opt-in skips blocking pre-commit"
else
    fail "--no-verify opt-in should allow squash"
fi
rm "${FAKE_WORKTREE}/.git/hooks/pre-commit"

if [[ ${ERRORS} -gt 0 ]]; then
    echo ""
    echo "❌ ${ERRORS} test(s) failed."
    exit 1
fi

echo ""
echo "✅ All safe-squash tests passed."
