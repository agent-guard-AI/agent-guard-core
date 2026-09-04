#!/usr/bin/env bash
#
# Machine API v1 tests for `agent-guard status --json`.
# Hermetic: no GitHub, AWS or network calls.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INIT_SCRIPT="${REPO_ROOT}/packages/agent-guard-core/src/init.sh"

PASS=0
FAIL=0
ok() { local desc="$1"; PASS=$((PASS + 1)); printf '✅ PASS: %s\n' "${desc}"; }
bad() { local desc="$1" got="$2"; FAIL=$((FAIL + 1)); printf '❌ FAIL: %s\n     got: %s\n' "${desc}" "${got}"; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Copy kernel into temp dir so we can source init.sh standalone.
mkdir -p "${TMP_DIR}/packages"
cp -r "${REPO_ROOT}/packages/agent-guard-core" "${TMP_DIR}/packages/agent-guard-core"

# Minimal agent-guard.yaml with only the identities we need for speed.
cat > "${TMP_DIR}/agent-guard.yaml" <<'EOF'
---
project:
  name: test
  domain: hmvip.dev

paths:
  main_repo: __TMP_DIR__
  base_dir: __TMP_DIR__
  package_root: packages/agent-guard-core
  session_storage: .kiro/locks/agent-sessions
  init_script: .hmvip-agent-init

identities:
  kimi:
    slots: 3
    worktree_prefix: hmvip-ia-kimi
    author_email: agent-kimi{n}@hmvip.dev
    author_name: HMVIP Kimi{n} Agent

git:
  protected_branches:
    - develop
    - main
  notes_ref: refs/notes/hmvip-worktree
  hooks_path: .githooks
  base_branch: develop

commit:
  author_template: agent-{identity}@{domain}
  message_pattern: '^(feat|fix|docs|refactor|chore|test|ci|hotfix)(\(.+\))?: .+'
  require_conventional: true
  identity_env_var: AGENT_GUARD_IDENTITY
  generic_agent_email_template: agent@{domain}
EOF
sed -i "s|__TMP_DIR__|${TMP_DIR}|g" "${TMP_DIR}/agent-guard.yaml"

# Initialize git repo and worktrees.
(
    cd "${TMP_DIR}"
    git init -q
    git config user.email "test@hmvip.dev"
    git config user.name "Test Agent"
    echo "init" > README.md
    git add README.md agent-guard.yaml
    git commit -q -m "initial"
    git branch develop

    # Create worktrees for kimi1/kimi2/kimi3 (each needs its own branch).
    for n in 1 2 3; do
        git branch "base-kimi${n}" develop
        git worktree add "hmvip-ia-kimi${n}" "base-kimi${n}" >/dev/null 2>&1
    done
)

SESSION_DIR="${TMP_DIR}/.kiro/locks/agent-sessions"
mkdir -p "${SESSION_DIR}"

# Helper to run status --json in a clean subshell.
run_status_json() {
    (
        cd "${TMP_DIR}/hmvip-ia-kimi1"
        unset AGENT_GUARD_IDENTITY AGENT_GUARD_WORKTREE_PATH AGENT_GUARD_BRANCH
        unset AGENT_GUARD_IMPACT_PLUGINS AGENT_GUARD_SESSION_PID AGENT_GUARD_REPO_ROOT
        source "${TMP_DIR}/packages/agent-guard-core/src/init.sh" --status --json 2>/dev/null
    )
}

run_status_human() {
    (
        cd "${TMP_DIR}/hmvip-ia-kimi1"
        unset AGENT_GUARD_IDENTITY AGENT_GUARD_WORKTREE_PATH AGENT_GUARD_BRANCH
        unset AGENT_GUARD_IMPACT_PLUGINS AGENT_GUARD_SESSION_PID AGENT_GUARD_REPO_ROOT
        source "${TMP_DIR}/packages/agent-guard-core/src/init.sh" --status
    ) 2>&1
}

# ---------------------------------------------------------------------------
# 1. Zero sessions: all identities free and schema_version == 3
# ---------------------------------------------------------------------------
output="$(run_status_json)"
if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('schema_version')==3 else 1)"; then
    ok "schema_version is 3"
else
    bad "schema_version is 3" "${output}"
fi

if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if len(d.get('identities',[]))==3 else 1)"; then
    ok "reports all 3 configured identities"
else
    bad "reports all 3 configured identities" "${output}"
fi

if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if len(d.get('sessions',[]))==0 else 1)"; then
    ok "zero sessions with zero session files"
else
    bad "zero sessions with zero session files" "${output}"
fi

# v3 adds a shadows array (F4); with zero sessions it must be empty.
if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('shadows')==[] else 1)"; then
    ok "shadows is an empty array with zero sessions"
else
    bad "shadows is an empty array with zero sessions" "${output}"
fi

# identities[] must NOT carry session fields (separation of concerns).
if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); bad=[i for i in d.get('identities',[]) if 'status' in i or 'pid' in i or 'branch' in i]; sys.exit(0 if len(bad)==0 else 1)"; then
    ok "identities[] does not carry session fields"
else
    bad "identities[] does not carry session fields" "${output}"
fi

# ---------------------------------------------------------------------------
# 2. Human status still works
# ---------------------------------------------------------------------------
human_output="$(run_status_human)"
if echo "${human_output}" | grep -q "Agent Guard"; then
    ok "human status header is present"
else
    bad "human status header is present" "${human_output:-empty}" 
fi

# ---------------------------------------------------------------------------
# 3. Active session is reported correctly in sessions[]
# ---------------------------------------------------------------------------
cat > "${SESSION_DIR}/kimi1.json" <<EOF
{"identity":"kimi1","status":"active","role":"ia-a","branch":"ia-kimi1/ia-a/task-active","pid":$$,"timestamp":$(date +%s),"last_activity":$(date +%s),"worktree_path":"${TMP_DIR}/hmvip-ia-kimi1"}
EOF
(
    cd "${TMP_DIR}/hmvip-ia-kimi1"
    git checkout -q -b ia-kimi1/ia-a/task-active
)

output="$(run_status_json)"
if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); s=[x for x in d.get('sessions',[]) if x['identity']=='kimi1'][0]; sys.exit(0 if s['status']=='active' and s['health']=='live' and s['pid_live'] else 1)"; then
    ok "active/live session reported in sessions[]"
else
    bad "active/live session reported in sessions[]" "${output}"
fi

# ---------------------------------------------------------------------------
# 4. Dead session is reported correctly in sessions[]
# ---------------------------------------------------------------------------
cat > "${SESSION_DIR}/kimi2.json" <<EOF
{"identity":"kimi2","status":"active","role":"ia-a","branch":"ia-kimi2/ia-a/task-dead","pid":999999,"timestamp":$(date +%s),"last_activity":$(date +%s),"worktree_path":"${TMP_DIR}/hmvip-ia-kimi2"}
EOF
output="$(run_status_json)"
if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); s=[x for x in d.get('sessions',[]) if x['identity']=='kimi2'][0]; sys.exit(0 if s['status']=='active' and s['health']=='dead' and not s['pid_live'] else 1)"; then
    ok "dead session reported in sessions[]"
else
    bad "dead session reported in sessions[]" "${output}"
fi

# F4 shadow for the same dead session: agent_in_tree must be null (no live tree).
if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); s=[x for x in d.get('shadows',[]) if x['identity']=='kimi2'][0]; sys.exit(0 if s['health']=='dead' and s['agent_in_tree'] is None and s['shell_pinned'] is False else 1)"; then
    ok "dead session shadow has agent_in_tree null"
else
    bad "dead session shadow has agent_in_tree null" "${output}"
fi

# ---------------------------------------------------------------------------
# 5. status --json is read-only even when branch diverges
# ---------------------------------------------------------------------------
# Deliberately make the worktree branch diverge from the session file.
(
    cd "${TMP_DIR}/hmvip-ia-kimi1"
    git checkout -q -b ia-kimi1/ia-a/diverged-branch
)
md5_before="$(md5sum "${SESSION_DIR}/kimi1.json" 2>/dev/null | awk '{print $1}')"
run_status_json >/dev/null
md5_after="$(md5sum "${SESSION_DIR}/kimi1.json" 2>/dev/null | awk '{print $1}')"
if [[ "${md5_before}" == "${md5_after}" ]]; then
    ok "status --json does not mutate session files"
else
    bad "status --json does not mutate session files" "session file changed"
fi

# And it surfaces the branch mismatch as drift without reconciling.
output="$(run_status_json)"
if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); s=[x for x in d.get('sessions',[]) if x['identity']=='kimi1'][0]; sys.exit(0 if 'branch mismatch' in s.get('drift','') else 1)"; then
    ok "branch mismatch reported as drift without reconciliation"
else
    bad "branch mismatch reported as drift without reconciliation" "${output}"
fi

# ---------------------------------------------------------------------------
# 6. Repository root points to main repo, not worktree
# ---------------------------------------------------------------------------
if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d['repository']['root']=='${TMP_DIR}' else 1)"; then
    ok "repository.root is the main repo"
else
    bad "repository.root is the main repo" "${output}"
fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
    echo "✅ All status JSON tests passed (${PASS} checks)."
    exit 0
else
    echo "❌ ${FAIL} status JSON test(s) failed (${PASS} passed)."
    exit 1
fi
