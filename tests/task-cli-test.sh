#!/usr/bin/env bash
#
# Teste de contrato para o CLI de task lifecycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/src/task-cli.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

export AGENT_GUARD_REPO_ROOT="${TMP_DIR}"
mkdir -p "${TMP_DIR}/.agent-guard/tasks"
chmod 700 "${TMP_DIR}/.agent-guard"
chmod 700 "${TMP_DIR}/.agent-guard/tasks"

echo "1) task init cria nota estruturada"
_task_cli_init "kimi2" --topic "Test topic" --branch "ia-kimi2/ia-a/test-task"
note_path="${TMP_DIR}/.agent-guard/tasks/kimi2.md"
[[ -f "${note_path}" ]] || { echo "FAIL: nota não criada"; exit 1; }
state="$(_task_get_field "${note_path}" "state")"
[[ "${state}" == "planning" ]] || { echo "FAIL state=${state}"; exit 1; }
topic="$(_task_get_field "${note_path}" "topic")"
[[ "${topic}" == "Test topic" ]] || { echo "FAIL topic=${topic}"; exit 1; }
branch="$(_task_get_field "${note_path}" "branch")"
[[ "${branch}" == "ia-kimi2/ia-a/test-task" ]] || { echo "FAIL branch=${branch}"; exit 1; }
echo "   OK"

echo "2) task show exibe nota"
output="$(_task_cli_show "kimi2" 2>/dev/null)"
[[ "${output}" == *"Test topic"* ]] || { echo "FAIL show"; exit 1; }
echo "   OK"

echo "3) task set-state transiciona estado"
_task_cli_set_state "kimi2" "coding"
state="$(_task_get_field "${note_path}" "state")"
[[ "${state}" == "coding" ]] || { echo "FAIL state=${state}"; exit 1; }
echo "   OK"

echo "4) task set-state com reason em blocked"
_task_cli_set_state "kimi2" "blocked" --reason "aguardando review"
state="$(_task_get_field "${note_path}" "state")"
reason="$(_task_get_field "${note_path}" "blocked_reason")"
[[ "${state}" == "blocked" ]] || { echo "FAIL state=${state}"; exit 1; }
[[ "${reason}" == "aguardando review" ]] || { echo "FAIL reason=${reason}"; exit 1; }
echo "   OK"

echo "5) task set-state rejeita transição inválida"
if _task_cli_set_state "kimi2" "planning" 2>/dev/null; then
    echo "FAIL: deveria rejeitar blocked -> planning"
    exit 1
fi
echo "   OK"

echo "6) task list lista notas"
_task_cli_init "kimi3" --topic "Another task" --branch "ia-kimi3/ia-a/another"
output="$(_task_cli_list 2>/dev/null)"
[[ "${output}" == *"kimi2"* ]] || { echo "FAIL list missing kimi2"; exit 1; }
[[ "${output}" == *"kimi3"* ]] || { echo "FAIL list missing kimi3"; exit 1; }
[[ "${output}" == *"blocked"* ]] || { echo "FAIL list missing state"; exit 1; }
echo "   OK"

echo "7) task init rejeita --topic ausente"
if _task_cli_init "kimi4" 2>/dev/null; then
    echo "FAIL: deveria rejeitar topic ausente"
    exit 1
fi
echo "   OK"

echo "8) task show rejeita identidade inexistente"
if _task_cli_show "nao-existe" 2>/dev/null; then
    echo "FAIL: deveria rejeitar identidade inexistente"
    exit 1
fi
echo "   OK"

echo ""
echo "Todos os testes de task CLI passaram."
