#!/usr/bin/env bash
#
# Migra notas de slot legadas (markdown livre) para o formato estruturado
# com YAML frontmatter usado pelo task lifecycle do agent-guard-core.
#
# Uso:
#   bash packages/agent-guard-core/migrate-slot-notes.sh [repo_root]
#
# Se repo_root não for informado, usa AGENT_GUARD_REPO_ROOT ou deduz via git.
# Notas já estruturadas são ignoradas. Cada nota legada recebe backup
# <nome>.legacy.<timestamp> antes da primeira escrita estruturada.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/src/task-lifecycle.sh"

repo_root="${1:-${AGENT_GUARD_REPO_ROOT:-}}"
if [[ -z "${repo_root}" ]]; then
    repo_root="$(_task_get_repo_root "")"
fi

tasks_dir="${repo_root}/.agent-guard/tasks"
if [[ ! -d "${tasks_dir}" ]]; then
    echo "Nenhum diretório de notas encontrado em ${tasks_dir}."
    exit 0
fi

migrated=0
skipped=0
failed=0

for note_path in "${tasks_dir}"/*.md; do
    [[ -f "${note_path}" ]] || continue

    identity="$(basename "${note_path}" .md)"

    # Ignora notas já estruturadas.
    if [[ "$(_task_has_frontmatter "${note_path}")" == "true" ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    # Extrai tópico da primeira linha de heading (# Título).
    topic="$(grep -m1 -E '^#[[:space:]]+' "${note_path}" 2>/dev/null | sed -E 's/^#[[:space:]]+//' || echo "${identity}")"
    topic="${topic:-${identity}}"

    # Extrai próximo passo, se houver.
    next_step="$(grep -iE '^[[:space:]]*Próximo passo[[:space:]]*:[[:space:]]*' "${note_path}" 2>/dev/null | head -n1 | sed -E 's/^[^:]*:[[:space:]]*//' || echo "")"

    # Tenta extrair branch mencionada na nota (formato ia-<identidade>/...).
    branch="$(grep -oE "ia-${identity}/[^[:space:]]+" "${note_path}" 2>/dev/null | head -n1 | tr -d '\`\\'\"' || echo "")"

    # Cria nota estruturada preservando corpo legado.
    if _task_create "${identity}" "${topic}" "${branch}" "${note_path}" >/dev/null 2>&1; then
        # Sobrescreve next_step se foi extraído.
        if [[ -n "${next_step}" ]]; then
            json="$(_task_read_frontmatter "${note_path}")"
            updated="$(_task_update_metadata "${json}" "next_step" "${next_step}")"
            updated="$(_task_update_metadata "${updated}" "state" "legacy")"
            body="$(_task_get_field "${note_path}" "body")"
            _task_write_note "${note_path}" "${updated}" "${body}" >/dev/null 2>&1 || true
        fi
        echo "📝 Migrada: ${identity} (${topic})"
        migrated=$((migrated + 1))
    else
        echo "❌ Falha ao migrar: ${identity}" >&2
        failed=$((failed + 1))
    fi
done

echo ""
echo "Resumo: ${migrated} migrada(s), ${skipped} já estruturada(s), ${failed} falha(s)."

if [[ "${failed}" -gt 0 ]]; then
    exit 1
fi
exit 0
