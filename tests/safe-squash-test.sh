#!/usr/bin/env bash
#
# safe-squash functional test
#
# Verifies that agent-guard safe-squash preserves the worktree-origin git note
# required by CI Worktree Origin Audit.

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

# Verify the three commits have notes.
NOTE_COUNT_BEFORE="$(git -C "${FAKE_WORKTREE}" notes --ref=refs/notes/hmvip-worktree list | wc -l | tr -d ' ')"
if [[ "${NOTE_COUNT_BEFORE}" -eq 3 ]]; then
    pass "all pre-squash commits have worktree notes"
else
    fail "expected 3 pre-squash notes, got ${NOTE_COUNT_BEFORE}"
fi

# Run safe-squash from inside the fake worktree.
(
    cd "${FAKE_WORKTREE}"
    source "${FAKE_WORKTREE}/packages/agent-guard-core/bin/agent-guard" safe-squash 3 -m "squashed"
)

# After squash the new HEAD must have a worktree-origin note.
NOTE_CONTENT="$(git -C "${FAKE_WORKTREE}" notes --ref=refs/notes/hmvip-worktree show HEAD 2>/dev/null || true)"
if [[ -n "${NOTE_CONTENT}" ]]; then
    pass "squashed commit HEAD has a worktree note"
else
    fail "post-squash HEAD is missing worktree note"
fi

# Verify the note content.
if echo "${NOTE_CONTENT}" | grep -q "identity:test1"; then
    pass "post-squash note contains expected identity"
else
    fail "post-squash note missing expected identity"
fi

if echo "${NOTE_CONTENT}" | grep -q "worktree:${FAKE_WORKTREE}"; then
    pass "post-squash note contains expected worktree"
else
    fail "post-squash note missing expected worktree"
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo ""
    echo "❌ ${ERRORS} test(s) failed."
    exit 1
fi

echo ""
echo "✅ All safe-squash tests passed."
