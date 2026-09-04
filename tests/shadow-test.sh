#!/usr/bin/env bash
#
# Session Shadow / Liveness API (F4) tests.
# Hermetic: no GitHub, AWS or network calls.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INIT_SCRIPT="${REPO_ROOT}/packages/agent-guard-core/src/init.sh"

PASS=0
FAIL=0
ok() { local desc="$1"; PASS=$((PASS + 1)); printf '✅ PASS: %s\n' "${desc}"; }
bad() { local desc="$1" got="$2"; FAIL=$((FAIL + 1)); printf '❌ FAIL: %s\n     got: %s\n' "${desc}" "${got}"; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"; [[ -n "${SLEEP_PID:-}" ]] && kill "${SLEEP_PID}" 2>/dev/null || true' EXIT

# Copy kernel into temp dir so we can source init.sh standalone.
mkdir -p "${TMP_DIR}/packages"
cp -r "${REPO_ROOT}/packages/agent-guard-core" "${TMP_DIR}/packages/agent-guard-core"

# Minimal agent-guard.yaml (same fixture as status-json-test).
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

    for n in 1 2 3; do
        git branch "base-kimi${n}" develop
        git worktree add "hmvip-ia-kimi${n}" "base-kimi${n}" >/dev/null 2>&1
    done
)

SESSION_DIR="${TMP_DIR}/.kiro/locks/agent-sessions"
SHADOW_DIR="${TMP_DIR}/.agent-guard/session/shadow"
mkdir -p "${SESSION_DIR}"

# Helper: run _shadow_cmd in a clean subshell (functions-only, like bin/agent-guard shadow).
run_shadow() {
    (
        cd "${TMP_DIR}/hmvip-ia-kimi1"
        unset AGENT_GUARD_IDENTITY AGENT_GUARD_WORKTREE_PATH AGENT_GUARD_BRANCH
        unset AGENT_GUARD_IMPACT_PLUGINS AGENT_GUARD_SESSION_PID AGENT_GUARD_REPO_ROOT
        AGENT_GUARD_FUNCTIONS_ONLY=1
        source "${TMP_DIR}/packages/agent-guard-core/src/init.sh"
        unset AGENT_GUARD_FUNCTIONS_ONLY
        _shadow_cmd "$@"
    ) 2>&1
}

run_status_json() {
    (
        cd "${TMP_DIR}/hmvip-ia-kimi1"
        unset AGENT_GUARD_IDENTITY AGENT_GUARD_WORKTREE_PATH AGENT_GUARD_BRANCH
        unset AGENT_GUARD_IMPACT_PLUGINS AGENT_GUARD_SESSION_PID AGENT_GUARD_REPO_ROOT
        source "${TMP_DIR}/packages/agent-guard-core/src/init.sh" --status --json 2>/dev/null
    )
}

NOW="$(date +%s)"

# ---------------------------------------------------------------------------
# 1. Zero sessions: empty shadows array, schema_version 1
# ---------------------------------------------------------------------------
output="$(run_shadow)"
if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('schema_version')==1 and d.get('shadows')==[] else 1)"; then
    ok "zero sessions yields empty shadows array"
else
    bad "zero sessions yields empty shadows array" "${output}"
fi

if [[ ! -d "${SHADOW_DIR}" ]]; then
    ok "on-demand shadow does not create shadow dir (read-only)"
else
    bad "on-demand shadow does not create shadow dir (read-only)" "shadow dir created"
fi

# ---------------------------------------------------------------------------
# 2. Live session with agent in tree (pid=$$ self-matches by design)
# ---------------------------------------------------------------------------
cat > "${SESSION_DIR}/kimi1.json" <<EOF
{"identity":"kimi1","status":"active","role":"ia-a","branch":"ia-kimi1/ia-a/task-active","pid":$$,"timestamp":${NOW},"last_activity":${NOW},"worktree_path":"${TMP_DIR}/hmvip-ia-kimi1"}
EOF
(
    cd "${TMP_DIR}/hmvip-ia-kimi1"
    git checkout -q -b ia-kimi1/ia-a/task-active
)

output="$(run_shadow --identity kimi1)"
if echo "${output}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
s=d['shadows'][0]
sys.exit(0 if s['identity']=='kimi1' and s['status']=='active' and s['health']=='live'
    and s['pid_live'] is True and s['agent_in_tree'] is True
    and s['shell_pinned'] is False and s['stale'] is False
    and s['branch']=='ia-kimi1/ia-a/task-active'
    and s['worktree_path']=='${TMP_DIR}/hmvip-ia-kimi1'
    and s['source']=='on_demand' and s['snapshot_at'] else 1)"; then
    ok "live session shadow has liveness flags"
else
    bad "live session shadow has liveness flags" "${output}"
fi

# ---------------------------------------------------------------------------
# 3. Dead session: pid_live false, agent_in_tree null
# ---------------------------------------------------------------------------
cat > "${SESSION_DIR}/kimi2.json" <<EOF
{"identity":"kimi2","status":"active","role":"ia-a","branch":"ia-kimi2/ia-a/task-dead","pid":999999,"timestamp":${NOW},"last_activity":${NOW},"worktree_path":"${TMP_DIR}/hmvip-ia-kimi2"}
EOF
output="$(run_shadow --identity kimi2)"
if echo "${output}" | python3 -c "
import sys,json
s=json.load(sys.stdin)['shadows'][0]
sys.exit(0 if s['health']=='dead' and s['pid_live'] is False and s['agent_in_tree'] is None else 1)"; then
    ok "dead session shadow: agent_in_tree is null"
else
    bad "dead session shadow: agent_in_tree is null" "${output}"
fi

# ---------------------------------------------------------------------------
# 4. Live non-agent PID with fresh heartbeat: agent_in_tree false, not pinned
# ---------------------------------------------------------------------------
sleep 300 &
SLEEP_PID=$!
cat > "${SESSION_DIR}/kimi3.json" <<EOF
{"identity":"kimi3","status":"active","role":"ia-a","branch":"ia-kimi3/ia-a/task-sleep","pid":${SLEEP_PID},"timestamp":${NOW},"last_activity":${NOW},"worktree_path":"${TMP_DIR}/hmvip-ia-kimi3"}
EOF
(
    cd "${TMP_DIR}/hmvip-ia-kimi3"
    git checkout -q -b ia-kimi3/ia-a/task-sleep
)
output="$(run_shadow --identity kimi3)"
if echo "${output}" | python3 -c "
import sys,json
s=json.load(sys.stdin)['shadows'][0]
sys.exit(0 if s['health']=='live' and s['agent_in_tree'] is False and s['shell_pinned'] is False else 1)"; then
    ok "non-agent live PID: agent_in_tree false, not pinned"
else
    bad "non-agent live PID: agent_in_tree false, not pinned" "${output}"
fi

# ---------------------------------------------------------------------------
# 5. Shell-pinned lease: live non-agent PID + heartbeat past grace (15 min)
# ---------------------------------------------------------------------------
OLD_ACTIVITY=$((NOW - 3600))
cat > "${SESSION_DIR}/kimi3.json" <<EOF
{"identity":"kimi3","status":"active","role":"ia-a","branch":"ia-kimi3/ia-a/task-sleep","pid":${SLEEP_PID},"timestamp":${NOW},"last_activity":${OLD_ACTIVITY},"worktree_path":"${TMP_DIR}/hmvip-ia-kimi3"}
EOF
output="$(run_shadow --identity kimi3)"
if echo "${output}" | python3 -c "
import sys,json
s=json.load(sys.stdin)['shadows'][0]
sys.exit(0 if s['health']=='pinned' and s['shell_pinned'] is True
    and s['agent_in_tree'] is False and s['stale'] is False else 1)"; then
    ok "shell-pinned lease detected in shadow"
else
    bad "shell-pinned lease detected in shadow" "${output}"
fi

# ---------------------------------------------------------------------------
# 6. Stale session: heartbeat past 24h threshold
# ---------------------------------------------------------------------------
STALE_ACTIVITY=$((NOW - 90000))
cat > "${SESSION_DIR}/kimi3.json" <<EOF
{"identity":"kimi3","status":"active","role":"ia-a","branch":"ia-kimi3/ia-a/task-sleep","pid":${SLEEP_PID},"timestamp":${NOW},"last_activity":${STALE_ACTIVITY},"worktree_path":"${TMP_DIR}/hmvip-ia-kimi3"}
EOF
output="$(run_shadow --identity kimi3)"
if echo "${output}" | python3 -c "
import sys,json
s=json.load(sys.stdin)['shadows'][0]
sys.exit(0 if s['health']=='stale' and s['stale'] is True else 1)"; then
    ok "stale session flagged in shadow"
else
    bad "stale session flagged in shadow" "${output}"
fi
kill "${SLEEP_PID}" 2>/dev/null || true
SLEEP_PID=""

# ---------------------------------------------------------------------------
# 7. Machine API v3: status --json carries schema_version 3 + shadows
# ---------------------------------------------------------------------------
output="$(run_status_json)"
if echo "${output}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('schema_version')==3 and isinstance(d.get('shadows'),list) and len(d['shadows'])>=3 else 1)"; then
    ok "status --json is schema_version 3 with shadows"
else
    bad "status --json is schema_version 3 with shadows" "${output}"
fi

if echo "${output}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
s=[x for x in d['shadows'] if x['identity']=='kimi2'][0]
sess=[x for x in d['sessions'] if x['identity']=='kimi2'][0]
sys.exit(0 if s['health']==sess['health'] and s['pid_live']==sess['pid_live'] else 1)"; then
    ok "shadow health agrees with sessions[] in Machine API"
else
    bad "shadow health agrees with sessions[] in Machine API" "${output}"
fi

# status --json must not create the persisted shadow dir.
if [[ ! -d "${SHADOW_DIR}" ]]; then
    ok "status --json does not create shadow dir (read-only)"
else
    bad "status --json does not create shadow dir (read-only)" "shadow dir created"
fi

# ---------------------------------------------------------------------------
# 8. --refresh persists snapshot atomically; free slot removes stale file
# ---------------------------------------------------------------------------
refresh_out="$(run_shadow --refresh --identity kimi1)"
shadow_file="${SHADOW_DIR}/kimi1.json"
if [[ -f "${shadow_file}" ]] && echo "${refresh_out}" | grep -q "kimi1"; then
    ok "shadow --refresh persists snapshot file"
else
    bad "shadow --refresh persists snapshot file" "${refresh_out}"
fi

if python3 -c "
import json,sys
d=json.load(open('${shadow_file}'))
sys.exit(0 if d['identity']=='kimi1' and d['source']=='refresh' and d['snapshot_at'] else 1)"; then
    ok "persisted snapshot has source=refresh"
else
    bad "persisted snapshot has source=refresh" "$(cat "${shadow_file}" 2>/dev/null)"
fi

# A slot with no session state gets its snapshot removed (obsolete cleanup).
rm -f "${SESSION_DIR}/kimi3.json"
refresh_out="$(run_shadow --refresh --identity kimi3 || true)"
if [[ ! -f "${SHADOW_DIR}/kimi3.json" ]]; then
    ok "refresh on slot without relevant state removes obsolete snapshot"
else
    bad "refresh on slot without relevant state removes obsolete snapshot" "file still exists"
fi

# ---------------------------------------------------------------------------
# 9. _shadow_read returns the persisted snapshot
# ---------------------------------------------------------------------------
read_out="$(
    cd "${TMP_DIR}/hmvip-ia-kimi1"
    unset AGENT_GUARD_IDENTITY AGENT_GUARD_WORKTREE_PATH AGENT_GUARD_BRANCH
    unset AGENT_GUARD_IMPACT_PLUGINS AGENT_GUARD_SESSION_PID AGENT_GUARD_REPO_ROOT
    AGENT_GUARD_FUNCTIONS_ONLY=1
    source "${TMP_DIR}/packages/agent-guard-core/src/init.sh"
    unset AGENT_GUARD_FUNCTIONS_ONLY
    _shadow_read kimi1
)"
if echo "${read_out}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('identity')=='kimi1' and d.get('source')=='refresh' else 1)"; then
    ok "_shadow_read returns persisted snapshot"
else
    bad "_shadow_read returns persisted snapshot" "${read_out}"
fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
    echo "✅ All shadow tests passed (${PASS} checks)."
    exit 0
else
    echo "❌ ${FAIL} shadow test(s) failed (${PASS} passed)."
    exit 1
fi
