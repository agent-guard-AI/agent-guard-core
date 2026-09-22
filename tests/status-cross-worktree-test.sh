#!/usr/bin/env bash
#
# F0-F S2 FIX2 — `agent-guard --status` global entre worktrees.
#
# Blocker 1 da independent review: a nota do slot (task_id/run_seq) é gravada
# no WORKTREE do claimant, mas `--status` lia apenas
# <repo_root>/.agent-guard/tasks/<slot>.md — um contexto não enxergava a
# TASK/run corrente de outro slot. Aqui provamos, com dois linked worktrees
# reais, que uma única execução de `--status` mostra TASK-A#run do kimi2 e
# TASK-B#run do kimi3, resolvendo cada nota pelo worktree da session/lease.
#
# Hermético: sem GitHub, AWS ou rede.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INIT_SCRIPT_SRC="${REPO_ROOT}/packages/agent-guard-core/src/init.sh"
CLAIM_SH_SRC="${REPO_ROOT}/packages/agent-guard-core/src/claim.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Copia o kernel para o temp dir (mesmo padrão do status-json-test.sh).
mkdir -p "${TMP_DIR}/packages"
cp -r "${REPO_ROOT}/packages/agent-guard-core" "${TMP_DIR}/packages/agent-guard-core"
INIT_SCRIPT="${TMP_DIR}/packages/agent-guard-core/src/init.sh"
CLAIM_SH="${TMP_DIR}/packages/agent-guard-core/src/claim.sh"

cat > "${TMP_DIR}/agent-guard.yaml" <<'EOF'
---
project:
  name: test
  domain: example.com

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
    author_email: agent-kimi{n}@example.com
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

# Repo principal + 2 linked worktrees (kimi2, kimi3).
(
    cd "${TMP_DIR}"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test Agent"
    echo "init" > README.md
    git add README.md agent-guard.yaml
    git commit -q -m "initial"
    git branch develop
    for n in 2 3; do
        git branch "base-kimi${n}" develop
        git worktree add "hmvip-ia-kimi${n}" "base-kimi${n}" >/dev/null 2>&1
    done
)

WT2="${TMP_DIR}/hmvip-ia-kimi2"
WT3="${TMP_DIR}/hmvip-ia-kimi3"
SESSION_DIR="${TMP_DIR}/.kiro/locks/agent-sessions"
mkdir -p "${SESSION_DIR}"

# Sessions/leases: kimi2 -> WT2, kimi3 -> WT3 (worktree_path real da lease).
for n in 2 3; do
    cat > "${SESSION_DIR}/kimi${n}.json" <<EOF
{"status": "active", "worktree_path": "${TMP_DIR}/hmvip-ia-kimi${n}", "pid": 999999, "branch": "ia-kimi${n}/ia-a/status-test", "role": "ia-a"}
EOF
done

# TASKs (uma por slot; base_ref=HEAD resolve no worktree).
make_task() {
    local wt="$1" task_id="$2"
    mkdir -p "${wt}/.kiro/tasks/202609"
    cat > "${wt}/.kiro/tasks/202609/${task_id}.md" <<EOF
---
task_id: ${task_id}
owner: kimi
objective: "objetivo ${task_id}"
done_criteria:
  - "criterio 1"
boundaries:
  - "sem deploy"
base_ref: HEAD
context_refs: []
budget:
  max_turns: 10
  max_time: 1h
risk_class: low
---
EOF
}
make_task "${WT2}" "TASK-A"
make_task "${WT3}" "TASK-B"

run_claim() {
    local wt="$1" identity="$2"; shift 2
    (
        cd "${wt}"
        export AGENT_GUARD_CLAIM_IDENTITY="${identity}"
        export AGENT_GUARD_CLAIM_SESSION_DIR="${SESSION_DIR}"
        export AGENT_GUARD_REPO_ROOT="${TMP_DIR}"
        # shellcheck source=/dev/null
        source "${CLAIM_SH}"
        _claim_cli_main "$@"
    )
}

echo "1) kimi2 claim TASK-A; kimi3 claim TASK-B (worktrees distintos)"
run_claim "${WT2}" "kimi2" "TASK-A" --branch ia-kimi2/status-test >/dev/null
run_claim "${WT3}" "kimi3" "TASK-B" --branch ia-kimi3/status-test >/dev/null
[[ -f "${WT2}/.agent-guard/tasks/kimi2.md" ]] || { echo "FAIL: nota kimi2 fora do WT2"; exit 1; }
[[ -f "${WT3}/.agent-guard/tasks/kimi3.md" ]] || { echo "FAIL: nota kimi3 fora do WT3"; exit 1; }
# Nota NÃO pode existir no repo principal (sem duplicar estado canônico).
[[ ! -e "${TMP_DIR}/.agent-guard/tasks" ]] || { echo "FAIL: nota duplicada no repo principal"; exit 1; }
echo "   OK"

echo "2) agent-guard --status a partir de um único contexto mostra TASK/run de cada slot"
status_output="$(
    cd "${TMP_DIR}"
    unset AGENT_GUARD_CLAIM_IDENTITY AGENT_GUARD_CLAIM_SESSION_DIR AGENT_GUARD_REPO_ROOT 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${INIT_SCRIPT}" --status 2>/dev/null
)"
line_kimi2="$(printf '%s\n' "${status_output}" | grep -E "^kimi2 " || true)"
line_kimi3="$(printf '%s\n' "${status_output}" | grep -E "^kimi3 " || true)"
[[ -n "${line_kimi2}" ]] || { echo "FAIL: linha kimi2 ausente no --status"; printf '%s\n' "${status_output}" | head -20; exit 1; }
[[ -n "${line_kimi3}" ]] || { echo "FAIL: linha kimi3 ausente no --status"; printf '%s\n' "${status_output}" | head -20; exit 1; }
[[ "${line_kimi2}" == *"TASK-A#01"* ]] \
    || { echo "FAIL: linha kimi2 sem TASK-A#01: ${line_kimi2}"; exit 1; }
[[ "${line_kimi3}" == *"TASK-B#01"* ]] \
    || { echo "FAIL: linha kimi3 sem TASK-B#01: ${line_kimi3}"; exit 1; }
echo "   OK"
echo "   kimi2: ${line_kimi2}"
echo "   kimi3: ${line_kimi3}"

echo "3) slot sem worktree/nota continua fail-soft (kimi1 = free, sem TASK)"
line_kimi1="$(printf '%s\n' "${status_output}" | grep -E "^kimi1 " || true)"
[[ -n "${line_kimi1}" ]] || { echo "FAIL: linha kimi1 ausente"; exit 1; }
[[ "${line_kimi1}" != *"TASK-"* ]] || { echo "FAIL: kimi1 sem nota não deve mostrar TASK: ${line_kimi1}"; exit 1; }
echo "   OK"

echo "ALL CROSS-WORKTREE STATUS TESTS PASSED"
