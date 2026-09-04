#!/usr/bin/env bash
#
# Teste de contrato para o parser de task lifecycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Hermeticidade: nao consulta PRs reais do GitHub durante os testes.
export AGENT_GUARD_PR_PROVIDER="true"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/src/task-lifecycle.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

note_path="${TMP_DIR}/kimi2.md"

echo "1) Nota inexistente retorna state=legacy"
json="$(_task_read_frontmatter "${note_path}")"
[[ "$(echo "${json}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["state"])')" == "legacy" ]] || { echo "FAIL"; exit 1; }
echo "   OK"

echo "2) Nota legada (sem frontmatter) retorna state=legacy e preserva corpo"
{
    echo "# Tarefa do slot"
    echo ""
    echo "Próximo passo: fazer algo."
} > "${note_path}"
json="$(_task_read_frontmatter "${note_path}")"
[[ "$(echo "${json}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["state"])')" == "legacy" ]] || { echo "FAIL state"; exit 1; }
[[ "$(echo "${json}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["body"].strip())')" == *"Próximo passo:"* ]] || { echo "FAIL body"; exit 1; }
echo "   OK"

echo "3) Escrita e leitura de nota estruturada"
_task_create "kimi2" "Test task lifecycle" "ia-kimi2/ia-a/test-task-lifecycle-20260830" "${note_path}"
json="$(_task_read_frontmatter "${note_path}")"
[[ "$(echo "${json}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["state"])')" == "planning" ]] || { echo "FAIL state"; exit 1; }
[[ "$(echo "${json}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["topic"])')" == "Test task lifecycle" ]] || { echo "FAIL topic"; exit 1; }
[[ "$(echo "${json}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["branch"])')" == "ia-kimi2/ia-a/test-task-lifecycle-20260830" ]] || { echo "FAIL branch"; exit 1; }
echo "   OK"

echo "4) Transição planning -> coding permitida"
_task_set_state "${note_path}" "coding"
[[ "$(_task_get_field "${note_path}" "state")" == "coding" ]] || { echo "FAIL"; exit 1; }
echo "   OK"

echo "5) Transição coding -> review permitida"
_task_set_state "${note_path}" "review"
[[ "$(_task_get_field "${note_path}" "state")" == "review" ]] || { echo "FAIL"; exit 1; }
echo "   OK"

echo "6) Transição review -> done permitida"
_task_set_state "${note_path}" "done"
[[ "$(_task_get_field "${note_path}" "state")" == "done" ]] || { echo "FAIL"; exit 1; }
echo "   OK"

echo "7) Transição done -> planning recusada"
if _task_set_state "${note_path}" "planning" 2>/dev/null; then
    echo "FAIL: deveria recusar done -> planning"
    exit 1
fi
echo "   OK"

echo "8) Estado inválido é rejeitado"
if _task_set_state "${note_path}" "foo" 2>/dev/null; then
    echo "FAIL: deveria rejeitar estado foo"
    exit 1
fi
echo "   OK"

echo "9) Backup da nota legada é criado antes da primeira escrita"
legacy_note="${TMP_DIR}/legacy.md"
{
    echo "# Legado"
    echo "Corpo antigo."
} > "${legacy_note}"
_task_create "legacy" "Migrate legacy" "ia-legacy/ia-a/migrate" "${legacy_note}"
# O backup deve existir.
ls "${legacy_note}".legacy.* >/dev/null 2>&1 || { echo "FAIL: backup não encontrado"; exit 1; }
# O conteúdo legado deve estar preservado no corpo.
[[ "$(_task_get_field "${legacy_note}" "body")" == *"Corpo antigo."* ]] || { echo "FAIL: corpo legado perdido"; exit 1; }
echo "   OK"

echo "10) Permissões da nota são 0o600"
stat -c '%a' "${note_path}" | grep -q '^600$' || { echo "FAIL permissões"; exit 1; }
echo "   OK"

echo ""
echo "Todos os testes de task lifecycle passaram."
