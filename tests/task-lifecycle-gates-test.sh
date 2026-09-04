#!/usr/bin/env bash
#
# Testes de contrato para gates do task lifecycle:
# - transição para done bloqueada por worktree sujo / PRs abertos
# - release bloqueado por task state não-done
# - helpers de validação de worktree

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Hermeticidade: nao consulta PRs reais do GitHub durante os testes.
export AGENT_GUARD_PR_PROVIDER="true"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/src/task-lifecycle.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/src/release-helpers.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

export AGENT_GUARD_REPO_ROOT="${TMP_DIR}"
mkdir -p "${TMP_DIR}/.agent-guard/tasks"
chmod 700 "${TMP_DIR}/.agent-guard"
chmod 700 "${TMP_DIR}/.agent-guard/tasks"

PASS=0
FAIL=0
ok() { local desc="$1"; PASS=$((PASS + 1)); printf 'ok   %s\n' "${desc}"; }
bad() { local desc="$1" got="$2"; FAIL=$((FAIL + 1)); printf 'FAIL %s\n     got: %s\n' "${desc}" "${got}"; }

# Setup: cria nota em review pronta para done.
note_path="${TMP_DIR}/.agent-guard/tasks/kimi2.md"
_task_create "kimi2" "Task lifecycle gates" "ia-kimi2/ia-a/gates-test" "${note_path}"
_task_set_state "${note_path}" "coding"
_task_set_state "${note_path}" "review"

# Cria worktree simulado (apenas .git suficiente para git status).
worktree="${TMP_DIR}/hmvip-ia-kimi2"
mkdir -p "${worktree}"
git init "${worktree}" >/dev/null 2>&1
git -C "${worktree}" config user.email "agent-kimi2@hmvip.link" >/dev/null 2>&1
git -C "${worktree}" config user.name "Agent kimi2" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 1) done bloqueado quando worktree sujo
# ---------------------------------------------------------------------------
echo "1 arquivo sujo" > "${worktree}/dirty.txt"
if _task_set_state "${note_path}" "done" "" "kimi2" "${TMP_DIR}" 2>/dev/null; then
    bad "done bloqueado com worktree sujo" "transição permitida"
else
    ok "done bloqueado com worktree sujo"
fi
rm -f "${worktree}/dirty.txt"

# ---------------------------------------------------------------------------
# 2) done permitido quando worktree limpo e sem PRs
# ---------------------------------------------------------------------------
git -C "${worktree}" add -A >/dev/null 2>&1 || true
git -C "${worktree}" commit -m "initial" >/dev/null 2>&1 || true
if _task_set_state "${note_path}" "done" "" "kimi2" "${TMP_DIR}"; then
    ok "done permitido com worktree limpo"
else
    bad "done permitido com worktree limpo" "transição recusada"
fi

# ---------------------------------------------------------------------------
# 3) release bloqueado quando task state não é done
# ---------------------------------------------------------------------------
note_coding="${TMP_DIR}/.agent-guard/tasks/kimi2-coding.md"
_task_create "kimi2-coding" "Task state coding" "ia-kimi2/ia-a/coding-test" "${note_coding}"
_task_set_state "${note_coding}" "coding" >/dev/null 2>&1 || true
blocker="$(_release_task_state_blocker "kimi2-coding" "${worktree}")"
if [[ "${blocker}" == "task_state:coding" ]]; then
    ok "release bloqueado em task_state:coding"
else
    bad "release bloqueado em task_state:coding" "${blocker}"
fi

# ---------------------------------------------------------------------------
# 4) release não bloqueado quando task state é done
# ---------------------------------------------------------------------------
blocker="$(_release_task_state_blocker "kimi2" "${worktree}")"
if [[ -z "${blocker}" ]]; then
    ok "release liberado em task_state:done"
else
    bad "release liberado em task_state:done" "${blocker}"
fi

# ---------------------------------------------------------------------------
# 5) release não bloqueado quando nota é legada (state=legacy)
# ---------------------------------------------------------------------------
legacy_note="${TMP_DIR}/.agent-guard/tasks/kimi3.md"
{
    echo "# Slot kimi3"
    echo ""
    echo "Próximo passo: trabalho legado"
} > "${legacy_note}"
blocker="$(_release_task_state_blocker "kimi3" "${worktree}")"
if [[ -z "${blocker}" ]]; then
    ok "release liberado para nota legada"
else
    bad "release liberado para nota legada" "${blocker}"
fi

# ---------------------------------------------------------------------------
# 6) _task_worktree_is_clean retorna 1 com worktree sujo
# ---------------------------------------------------------------------------
echo "sujo" > "${worktree}/dirty2.txt"
if _task_worktree_is_clean "${note_path}" "${TMP_DIR}"; then
    bad "_task_worktree_is_clean detecta sujeira" "retornou limpo"
else
    ok "_task_worktree_is_clean detecta sujeira"
fi
rm -f "${worktree}/dirty2.txt"

# ---------------------------------------------------------------------------
# 7) _task_worktree_is_clean retorna 0 com worktree limpo
# ---------------------------------------------------------------------------
if _task_worktree_is_clean "${note_path}" "${TMP_DIR}"; then
    ok "_task_worktree_is_clean retorna limpo"
else
    bad "_task_worktree_is_clean retorna limpo" "retornou sujo"
fi

# ---------------------------------------------------------------------------
# 8) transição inválida para done (planning -> done) é recusada
# ---------------------------------------------------------------------------
_task_set_state "${note_path}" "review" >/dev/null 2>&1 || true
# Força estado para planning editando frontmatter.
json="$(_task_read_frontmatter "${note_path}")"
updated="$(_task_update_metadata "${json}" "state" "planning")"
body="$(_task_get_field "${note_path}" "body")"
_task_write_note "${note_path}" "${updated}" "${body}"
if _task_set_state "${note_path}" "done" "" "kimi2" "${TMP_DIR}" 2>/dev/null; then
    bad "planning -> done recusado" "transição permitida"
else
    ok "planning -> done recusado"
fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
    echo "✅ All task lifecycle gate tests passed (${PASS} checks)."
    exit 0
else
    echo "❌ ${FAIL} task lifecycle gate test(s) failed (${PASS} passed)."
    exit 1
fi
