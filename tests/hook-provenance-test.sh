#!/usr/bin/env bash
#
# hook-provenance-test.sh
#
# Verifies that post-commit attaches the worktree-origin git note in normal,
# amend, and soft-reset commit scenarios, and that hook exit codes are respected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

FAKE_REPO="${TMPDIR}/repo"
mkdir -p "${FAKE_REPO}/packages/agent-guard-core/bin"
mkdir -p "${FAKE_REPO}/packages/agent-guard-core/src"
mkdir -p "${FAKE_REPO}/packages/agent-guard-core/hooks"

cp "${REPO_ROOT}/bin/agent-guard-config" "${FAKE_REPO}/packages/agent-guard-core/bin/agent-guard-config"
cp "${REPO_ROOT}/hooks/post-commit" "${FAKE_REPO}/packages/agent-guard-core/hooks/post-commit"

cat > "${FAKE_REPO}/agent-guard.yaml" <<'YAML'
identities:
  test:
    worktree_prefix: repo-ia-test
git:
  notes_ref: refs/notes/hmvip-worktree
YAML

FAKE_WORKTREE="${FAKE_REPO}-ia-test1"
mkdir -p "${FAKE_WORKTREE}"

git -C "${FAKE_WORKTREE}" init -q
git -C "${FAKE_WORKTREE}" config user.email "agent-test1@example.com"
git -C "${FAKE_WORKTREE}" config user.name "Test Agent"

# Install the agent-guard post-commit hook.
cp "${FAKE_REPO}/packages/agent-guard-core/hooks/post-commit" "${FAKE_WORKTREE}/.git/hooks/post-commit"
chmod +x "${FAKE_WORKTREE}/.git/hooks/post-commit"

echo "init" > "${FAKE_WORKTREE}/file.txt"
git -C "${FAKE_WORKTREE}" add file.txt
git -C "${FAKE_WORKTREE}" commit -q -m "initial"

git -C "${FAKE_WORKTREE}" checkout -q -b ia-test1/ia-a/task-provenance

# Add config so the post-commit hook can resolve identity.
cp -r "${FAKE_REPO}/packages" "${FAKE_WORKTREE}/"
cp "${FAKE_REPO}/agent-guard.yaml" "${FAKE_WORKTREE}/"
git -C "${FAKE_WORKTREE}" add .
git -C "${FAKE_WORKTREE}" commit -q -m "add agent-guard files"

_have_note() {
    git -C "${FAKE_WORKTREE}" notes --ref=refs/notes/hmvip-worktree show HEAD >/dev/null 2>&1
}

# Test 1: normal commit provenance.
echo "line1" >> "${FAKE_WORKTREE}/file.txt"
git -C "${FAKE_WORKTREE}" add file.txt
git -C "${FAKE_WORKTREE}" commit -q -m "normal commit"
if _have_note; then
    pass "normal commit has worktree note"
else
    fail "normal commit missing worktree note"
fi

# Test 2: amend provenance.
git -C "${FAKE_WORKTREE}" commit -q --amend -m "amended commit"
if _have_note; then
    pass "amend has worktree note"
else
    fail "amend missing worktree note"
fi

# Test 3: soft-reset + commit provenance.
git -C "${FAKE_WORKTREE}" checkout -q -b ia-test1/ia-a/soft-reset-provenance
for i in 1 2; do
    echo "soft${i}" >> "${FAKE_WORKTREE}/file.txt"
    git -C "${FAKE_WORKTREE}" add file.txt
    git -C "${FAKE_WORKTREE}" commit -q -m "soft commit ${i}"
done
git -C "${FAKE_WORKTREE}" reset --soft HEAD~2
git -C "${FAKE_WORKTREE}" commit -q -m "soft-squashed"
if _have_note; then
    pass "soft-reset + commit has worktree note"
else
    fail "soft-reset + commit missing worktree note"
fi

# Test 4: hook exit codes.
# pre-commit exit 1 blocks commit
cat > "${FAKE_WORKTREE}/.git/hooks/pre-commit" <<'HOOK'
#!/bin/bash
exit 1
HOOK
chmod +x "${FAKE_WORKTREE}/.git/hooks/pre-commit"
echo "blocked" >> "${FAKE_WORKTREE}/file.txt"
git -C "${FAKE_WORKTREE}" add file.txt
if git -C "${FAKE_WORKTREE}" commit -q -m "should-block" 2>/dev/null; then
    fail "pre-commit exit 1 did not block commit"
else
    pass "pre-commit exit 1 blocks commit"
fi
git -C "${FAKE_WORKTREE}" checkout -- file.txt
rm "${FAKE_WORKTREE}/.git/hooks/pre-commit"

if [[ ${ERRORS} -gt 0 ]]; then
    echo ""
    echo "❌ ${ERRORS} test(s) failed."
    exit 1
fi

echo ""
echo "✅ All hook provenance tests passed."
