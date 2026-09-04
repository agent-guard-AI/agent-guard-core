#!/usr/bin/env bash
#
# agent-guard-core — Task Lifecycle CLI
#
# Subcomandos:
#   agent-guard task list
#   agent-guard task show <identity>
#   agent-guard task set-state <identity> <state> [--reason <reason>]
#   agent-guard task init <identity> --topic <topic> [--branch <branch>]

set -euo pipefail

# Resolve o diretório deste script mesmo quando sourcado.
_TASK_CLI_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load task lifecycle service.
if [[ ! -f "${_TASK_CLI_CORE_DIR}/src/task-lifecycle.sh" ]]; then
    echo "❌ task-lifecycle.sh not found at ${_TASK_CLI_CORE_DIR}/src/task-lifecycle.sh" >&2
    return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
source "${_TASK_CLI_CORE_DIR}/src/task-lifecycle.sh"

# Resolve Python interpreter.
AG_PYTHON="$(bash "${_TASK_CLI_CORE_DIR}/bin/agent-guard-python" 2>/dev/null || echo "python3")"
export AG_PYTHON

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_task_cli_repo_root() {
    local repo_root="${1:-}"
    if [[ -n "${repo_root}" ]]; then
        echo "${repo_root}"
        return 0
    fi
    _task_get_repo_root
}

_task_cli_tasks_dir() {
    local repo_root
    repo_root="$(_task_cli_repo_root "${1:-}")"
    echo "${repo_root}/.agent-guard/tasks"
}

_task_cli_identity_from_worktree() {
    local worktree
    worktree="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    local git_email
    git_email="$(git -C "${worktree}" config --worktree user.email 2>/dev/null || git -C "${worktree}" config user.email 2>/dev/null || echo "")"
    if [[ "${git_email}" =~ ^agent-([a-z]+[0-9]+)@ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    basename "${worktree}" | sed 's/^hmvip-ia-//'
}

_task_cli_format_table() {
    local header="${1:-}"
    shift 2>/dev/null || true
    if [[ -n "${header}" ]]; then
        echo "${header}"
        echo "$(printf '%*s' "${#header}" '' | tr ' ' '-')"
    fi
    printf '%s\n' "$@"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

_task_cli_status() {
    local repo_root
    repo_root="$(_task_cli_repo_root "${1:-}")"
    local tasks_dir
    tasks_dir="$(_task_cli_tasks_dir "${repo_root}")"

    echo "============================================================"
    echo "🛡️  HMVIP — Tasks por slot"
    echo "============================================================"
    printf '%-12s %-12s %-30s %-20s %s\n' "IDENTITY" "STATE" "TOPIC" "PRS" "NEXT_STEP"
    echo "------------------------------------------------------------------------"

    if [[ ! -d "${tasks_dir}" ]]; then
        echo "Nenhuma nota de slot encontrada em ${tasks_dir}."
        return 0
    fi

    local notes
    notes="$(find "${tasks_dir}" -maxdepth 1 -type f -name '*.md' | sort)"
    if [[ -z "${notes}" ]]; then
        echo "Nenhuma nota de slot encontrada em ${tasks_dir}."
        return 0
    fi

    local note_path
    while IFS= read -r note_path; do
        [[ -f "${note_path}" ]] || continue
        local identity json state topic prs next_step prs_str
        identity="$(basename "${note_path}" .md)"
        json="$(_task_read_frontmatter "${note_path}")"
        state="$(echo "${json}" | ${AG_PYTHON} -c 'import sys,json; print(json.load(sys.stdin).get("state","legacy"))')"
        topic="$(echo "${json}" | ${AG_PYTHON} -c 'import sys,json; print(json.load(sys.stdin).get("topic","") or "—")')"
        next_step="$(echo "${json}" | ${AG_PYTHON} -c 'import sys,json; print(json.load(sys.stdin).get("next_step","") or "—")')"
        prs="$(echo "${json}" | ${AG_PYTHON} -c 'import sys,json; print(",".join(str(x) for x in json.load(sys.stdin).get("prs",[])))')"
        prs_str="${prs:-—}"
        printf '%-12s %-12s %-30s %-20s %s\n' \
            "${identity}" "${state}" "${topic:0:30}" "${prs_str:0:20}" "${next_step:0:50}"
    done <<< "${notes}"
    return 0
}

_task_cli_list() {
    local repo_root
    repo_root="$(_task_cli_repo_root "${1:-}")"
    local tasks_dir
    tasks_dir="$(_task_cli_tasks_dir "${repo_root}")"

    if [[ ! -d "${tasks_dir}" ]]; then
        echo "Nenhuma nota de slot encontrada em ${tasks_dir}."
        return 0
    fi

    local notes
    notes="$(find "${tasks_dir}" -maxdepth 1 -type f -name '*.md' | sort)"
    if [[ -z "${notes}" ]]; then
        echo "Nenhuma nota de slot encontrada em ${tasks_dir}."
        return 0
    fi

    local rows=()
    local note_path
    while IFS= read -r note_path; do
        [[ -f "${note_path}" ]] || continue
        local identity
        identity="$(basename "${note_path}" .md)"
        local json
        json="$(_task_read_frontmatter "${note_path}")"
        local state topic next_step
        state="$(echo "${json}" | ${AG_PYTHON} -c 'import sys,json; print(json.load(sys.stdin).get("state","legacy"))')"
        topic="$(echo "${json}" | ${AG_PYTHON} -c 'import sys,json; print(json.load(sys.stdin).get("topic","") or "—")')"
        next_step="$(echo "${json}" | ${AG_PYTHON} -c 'import sys,json; print(json.load(sys.stdin).get("next_step","") or "—")')"
        rows+=("$(printf '%-12s %-12s %-30s %s' "${identity}" "${state}" "${topic:0:30}" "${next_step:0:50}")")
    done <<< "${notes}"

    _task_cli_format_table "$(printf '%-12s %-12s %-30s %s' 'IDENTITY' 'STATE' 'TOPIC' 'NEXT_STEP')" "${rows[@]}"
}

_task_cli_show() {
    local identity="${1:-}"
    if [[ -z "${identity}" ]]; then
        echo "❌ show requires an identity (ex: kimi2)." >&2
        return 1
    fi

    local repo_root
    repo_root="$(_task_cli_repo_root "${2:-}")"
    local note_path
    note_path="$(_task_note_path "${identity}" "${repo_root}")"

    if [[ ! -f "${note_path}" ]]; then
        echo "❌ Nota não encontrada: ${note_path}" >&2
        return 1
    fi

    cat "${note_path}"
}

_task_cli_set_state() {
    local identity="${1:-}"
    local new_state="${2:-}"
    shift 2 2>/dev/null || true

    if [[ -z "${identity}" || -z "${new_state}" ]]; then
        echo "❌ Usage: agent-guard task set-state <identity> <state> [--reason <reason>]" >&2
        return 1
    fi

    local reason=""
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --reason)
                reason="${2:-}"
                shift 2
                ;;
            -*)
                echo "❌ Opção desconhecida: ${1}" >&2
                return 1
                ;;
            *)
                shift
                ;;
        esac
    done

    local repo_root
    repo_root="$(_task_cli_repo_root)"
    local note_path
    note_path="$(_task_note_path "${identity}" "${repo_root}")"

    if [[ ! -f "${note_path}" ]]; then
        echo "❌ Nota não encontrada: ${note_path}" >&2
        return 1
    fi

    local old_state
    old_state="$(_task_get_field "${note_path}" "state")"
    old_state="${old_state:-legacy}"

    if ! _task_set_state "${note_path}" "${new_state}" "${reason}" "${identity}" "${repo_root}"; then
        return 1
    fi

    echo "📝 Task ${identity}: ${old_state} → ${new_state}"

    if command -v _journal_write_event >/dev/null 2>&1; then
        _journal_write_event "task.state_changed" "{\"identity\":\"${identity}\",\"old_state\":\"${old_state}\",\"new_state\":\"${new_state}\",\"reason\":\"${reason}\",\"note_path\":\"${note_path}\"}" "${repo_root}"
    fi

    return 0
}

_task_cli_init() {
    local identity="${1:-}"
    if [[ -z "${identity}" ]]; then
        echo "❌ init requires an identity (ex: kimi2)." >&2
        return 1
    fi
    shift 2>/dev/null || true

    local topic=""
    local branch=""
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --topic)
                topic="${2:-}"
                shift 2
                ;;
            --branch)
                branch="${2:-}"
                shift 2
                ;;
            -*)
                echo "❌ Opção desconhecida: ${1}" >&2
                return 1
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ -z "${topic}" ]]; then
        echo "❌ --topic é obrigatório." >&2
        return 1
    fi

    if [[ -z "${branch}" ]]; then
        branch="$(git branch --show-current 2>/dev/null || echo "")"
    fi

    local repo_root
    repo_root="$(_task_cli_repo_root)"
    local note_path
    note_path="$(_task_note_path "${identity}" "${repo_root}")"

    _task_create "${identity}" "${topic}" "${branch}" "${note_path}"

    echo "📝 Task ${identity} criada: ${topic}"
    echo "   Branch: ${branch:-não definida}"
    echo "   Nota:   ${note_path}"

    if command -v _journal_write_event >/dev/null 2>&1; then
        _journal_write_event "task.created" "{\"identity\":\"${identity}\",\"topic\":\"${topic}\",\"branch\":\"${branch}\",\"note_path\":\"${note_path}\"}" "${repo_root}"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------

_task_cli_main() {
    local subcommand="${1:-}"
    shift 2>/dev/null || true

    case "${subcommand}" in
        list|ls|l)
            _task_cli_list "$@"
            return $?
            ;;
        show|s|cat)
            _task_cli_show "$@"
            return $?
            ;;
        set-state|state|set)
            _task_cli_set_state "$@"
            return $?
            ;;
        init|create|new)
            _task_cli_init "$@"
            return $?
            ;;
        help|--help|-h)
            cat <<'EOF'
Uso: agent-guard task <subcomando> [args]

Subcomandos:
  list                            Lista notas de slot com estado/tópico.
  show <identity>                 Exibe a nota completa de um slot.
  set-state <identity> <state> [--reason <reason>]
                                  Transiciona o estado de uma task.
  init <identity> --topic <topic> [--branch <branch>]
                                  Cria uma nota estruturada para um slot.
  help                            Mostra esta mensagem.

Estados válidos: planning, coding, review, blocked, done.
EOF
            return 0
            ;;
        "")
            echo "❌ Subcomando ausente. Use: agent-guard task help" >&2
            return 1
            ;;
        *)
            echo "❌ Subcomando desconhecido: ${subcommand}" >&2
            echo "   Use: agent-guard task help" >&2
            return 1
            ;;
    esac
}
