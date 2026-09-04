#!/usr/bin/env bash
#
# hmvip-hook-dispatcher.sh — Dispatcher unificado dos hooks do Kimi Code CLI
# para o ecossistema HMVIP (ADR-0052).
#
# Propósito: reduzir forks duplicados por evento. O Kimi Code dispara este
# handler uma única vez por evento; este script delega para os handlers
# existentes (tab, heartbeat, tattoo) conforme necessário.
#
# Recebe:
#   $1 = ação/evento sugerido (opcional, fallback para .hook_event_name no stdin)
#   stdin = payload JSON do evento (formato oficial dos hooks do Kimi Code)
#
# Contrato dos hooks do Kimi Code: exit 0 = allow, 2 = block. Este dispatcher
# é observação-pura: NUNCA escreve em stdout (stdout vira contexto do modelo) e
# SEMPRE sai com código 0 (fail-open) para jamais bloquear o CLI.
#
set -u
umask 077

DISPATCHER_DIR="${HMVIP_DISPATCHER_DIR:-${HOME}/.agent-guard/session}"
LOG_FILE="${DISPATCHER_DIR}/hook-dispatcher.log"
HEARTBEAT_THROTTLE_FILE="${DISPATCHER_DIR}/heartbeat-throttle.json"
COST_GUARD_THROTTLE_FILE="${DISPATCHER_DIR}/cost-guard-throttle.json"

# Caminhos dos handlers legados (podem ser sobrescritos por env)
TAB_HANDLER="${HMVIP_TAB_HANDLER:-${HOME}/.kimi-code/hooks/agent-guard-tab.sh}"
HEARTBEAT_HANDLER="${HMVIP_HEARTBEAT_HANDLER:-${HOME}/.kimi-code/hooks/agent-guard-heartbeat.sh}"
TATTOO_HANDLER="${HMVIP_TATTOO_HANDLER:-${HOME}/.kimi-code/hooks/session-tattoo-hook.sh}"
COST_GUARD_HANDLER_NAME="hmvip-session-cost-guard.sh"
BOOT_CACHE_PERSIST_HANDLER_NAME="hmvip-boot-cache-persist.sh"

mkdir -p "${DISPATCHER_DIR}" 2>/dev/null || true

_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" >>"${LOG_FILE}" 2>/dev/null || true
    if [ -f "${LOG_FILE}" ] && [ "$(wc -c <"${LOG_FILE}" 2>/dev/null || echo 0)" -gt 65536 ]; then
        tail -n 200 "${LOG_FILE}" 2>/dev/null >"${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "${LOG_FILE}" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Leitura do payload (stdin). Tolerante a campos ausentes.
# ---------------------------------------------------------------------------
PAYLOAD=""
if [ ! -t 0 ]; then
    PAYLOAD="$(cat 2>/dev/null || true)"
fi

_jq_get() {
    if [ -n "${PAYLOAD}" ] && command -v jq >/dev/null 2>&1; then
        printf '%s' "${PAYLOAD}" | jq -r "$1" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Derivação do evento e da ação do tab.
# ---------------------------------------------------------------------------
EVENT="$(_jq_get '.hook_event_name // ""')"
if [ -z "${EVENT}" ] && [ -n "${1:-}" ]; then
    EVENT="$1"
fi

# Ação do tab derivada do evento.
TAB_ACTION=""
case "${EVENT}" in
    UserPromptSubmit)        TAB_ACTION="working" ;;
    PermissionRequest|Stop|Interrupt) TAB_ACTION="attention" ;;
    PermissionResult)        TAB_ACTION="working" ;;
    StopFailure)             TAB_ACTION="error" ;;
    Notification)            TAB_ACTION="notification" ;;
    SessionStart)            TAB_ACTION="session-start" ;;
    SessionEnd)              TAB_ACTION="session-end" ;;
    *)
        _log "evento desconhecido: ${EVENT}"
        exit 0
        ;;
esac

_log "event=${EVENT} tab_action=${TAB_ACTION}"

# ---------------------------------------------------------------------------
# Handler de tab.
# ---------------------------------------------------------------------------
_dispatch_tab() {
    if [ -x "${TAB_HANDLER}" ]; then
        printf '%s' "${PAYLOAD}" | "${TAB_HANDLER}" "${TAB_ACTION}" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Handler de heartbeat com throttle.
# Atualiza o throttle em todo UserPromptSubmit e executa o heartbeat quando:
#   - passaram 60s desde a última execução, OU
#   - ocorreram 5 prompts desde a última execução.
# Wakeup alerts continuam sendo processados em todo heartbeat no handler
# original; este dispatcher apenas evita chamá-lo desnecessariamente.
# ---------------------------------------------------------------------------
_read_throttle_field_from() {
    local throttle_file="$1" field="$2" default="${3:-0}"
    if [ -f "${throttle_file}" ] && command -v jq >/dev/null 2>&1; then
        jq -r "${field} // ${default}" "${throttle_file}" 2>/dev/null || printf '%s' "${default}"
    else
        printf '%s' "${default}"
    fi
}

_read_throttle_field() {
    _read_throttle_field_from "${HEARTBEAT_THROTTLE_FILE}" "$1" "$2"
}

_dispatch_heartbeat() {
    [ "${EVENT}" = "UserPromptSubmit" ] || return 0
    [ -x "${HEARTBEAT_HANDLER}" ] || return 0

    local now_epoch
    now_epoch="$(date +%s 2>/dev/null || echo 0)"

    local last_run prompt_count
    last_run="$(_read_throttle_field_from "${HEARTBEAT_THROTTLE_FILE}" '.last_run' '0')"
    prompt_count="$(_read_throttle_field_from "${HEARTBEAT_THROTTLE_FILE}" '.prompt_count' '0')"
    prompt_count=$((prompt_count + 1))

    local run_heartbeat=0
    if [ "${last_run}" -le 0 ] || [ "$((now_epoch - last_run))" -ge 60 ]; then
        run_heartbeat=1
    elif [ "${prompt_count}" -ge 5 ]; then
        run_heartbeat=1
    fi

    if [ "${run_heartbeat}" -eq 1 ]; then
        _log "heartbeat executado (prompt_count=${prompt_count})"
        "${HEARTBEAT_HANDLER}" >/dev/null 2>&1 || true
        prompt_count=0
        last_run="${now_epoch}"
    fi

    local tmp_file="${HEARTBEAT_THROTTLE_FILE}.tmp.$$"
    jq -n \
        --argjson prompt_count "${prompt_count}" \
        --argjson last_run "${last_run}" \
        '{prompt_count:$prompt_count,last_run:$last_run}' >"${tmp_file}" 2>/dev/null && mv "${tmp_file}" "${HEARTBEAT_THROTTLE_FILE}" 2>/dev/null || rm -f "${tmp_file}"
}

# ---------------------------------------------------------------------------
# Handler de tattoo.
# ---------------------------------------------------------------------------
_dispatch_tattoo() {
    case "${EVENT}" in
        Stop|SessionEnd)
            if [ -x "${TATTOO_HANDLER}" ]; then
                local tattoo_arg
                case "${EVENT}" in
                    Stop) tattoo_arg="stop" ;;
                    SessionEnd) tattoo_arg="session-end" ;;
                esac
                printf '%s' "${PAYLOAD}" | "${TATTOO_HANDLER}" "${tattoo_arg}" >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Handler de cost guard com throttle.
# Executa a cada 10 prompts ou 60s para alertar sobre sessões longas.
# ---------------------------------------------------------------------------
_dispatch_cost_guard() {
    [ "${EVENT}" = "UserPromptSubmit" ] || return 0

    local cwd session_dir
    cwd="$(_jq_get '.cwd // ""')"
    session_dir="$(_jq_get '.sessionDir // .session_dir // ""')"
    if [ -z "${session_dir}" ]; then
        return 0
    fi

    local handler_path
    handler_path="${cwd}/.agent/scripts/${COST_GUARD_HANDLER_NAME}"
    if [ ! -x "${handler_path}" ]; then
        handler_path="${HOME}/.kimi-code/scripts/${COST_GUARD_HANDLER_NAME}"
        if [ ! -x "${handler_path}" ]; then
            return 0
        fi
    fi

    local now_epoch
    now_epoch="$(date +%s 2>/dev/null || echo 0)"

    local last_run prompt_count
    last_run="$(_read_throttle_field_from "${COST_GUARD_THROTTLE_FILE}" '.cost_guard.last_run' '0')"
    prompt_count="$(_read_throttle_field_from "${COST_GUARD_THROTTLE_FILE}" '.cost_guard.prompt_count' '0')"
    prompt_count=$((prompt_count + 1))

    local run_guard=0
    if [ "${last_run}" -le 0 ] || [ "$((now_epoch - last_run))" -ge 60 ]; then
        run_guard=1
    elif [ "${prompt_count}" -ge 10 ]; then
        run_guard=1
    fi

    if [ "${run_guard}" -eq 1 ]; then
        local session_log
        session_log="${session_dir}/logs/kimi-code.log"
        if [ -f "${session_log}" ]; then
            _log "cost-guard executado (prompt_count=${prompt_count})"
            "${handler_path}" "${session_log}" >/dev/null 2>&1 || true
        fi
        prompt_count=0
        last_run="${now_epoch}"
    fi

    local tmp_file="${COST_GUARD_THROTTLE_FILE}.tmp.$$"
    # Preserva o throttle do heartbeat se existir.
    if [ -f "${COST_GUARD_THROTTLE_FILE}" ]; then
        jq --argjson prompt_count "${prompt_count}" \
           --argjson last_run "${last_run}" \
           '.cost_guard = {prompt_count:$prompt_count,last_run:$last_run}' \
           "${COST_GUARD_THROTTLE_FILE}" >"${tmp_file}" 2>/dev/null && mv "${tmp_file}" "${COST_GUARD_THROTTLE_FILE}" 2>/dev/null || rm -f "${tmp_file}"
    else
        jq -n \
            --argjson prompt_count "${prompt_count}" \
            --argjson last_run "${last_run}" \
            '{cost_guard:{prompt_count:$prompt_count,last_run:$last_run}}' >"${tmp_file}" 2>/dev/null && mv "${tmp_file}" "${COST_GUARD_THROTTLE_FILE}" 2>/dev/null || rm -f "${tmp_file}"
    fi
}

# ---------------------------------------------------------------------------
# Persistência do boot cache (ADR-0051/0052).
# O init.sh da branch do worktree pode estar desatualizado. Garantimos que
# o boot-state.json seja escrito em todo SessionStart via script auxiliar.
# ---------------------------------------------------------------------------
_dispatch_boot_cache_persist() {
    [ "${EVENT}" = "SessionStart" ] || return 0

    local cwd session_dir worktree_path
    cwd="$(_jq_get '.cwd // ""')"
    session_dir="$(_jq_get '.sessionDir // .session_dir // ""')"
    worktree_path="${cwd}"
    if [ -z "${worktree_path}" ] && [ -n "${session_dir}" ]; then
        worktree_path="$(dirname "${session_dir}")"
    fi
    if [ -z "${worktree_path}" ]; then
        return 0
    fi

    local handler_path
    handler_path="${worktree_path}/.agent/scripts/${BOOT_CACHE_PERSIST_HANDLER_NAME}"
    if [ ! -x "${handler_path}" ]; then
        handler_path="${HOME}/.kimi-code/scripts/${BOOT_CACHE_PERSIST_HANDLER_NAME}"
        if [ ! -x "${handler_path}" ]; then
            return 0
        fi
    fi

    if "${handler_path}" "${worktree_path}" >/dev/null 2>&1; then
        _log "boot-cache persistido para ${worktree_path}"
    fi
}

# ---------------------------------------------------------------------------
# Orquestração.
# ---------------------------------------------------------------------------
_dispatch_tab
_dispatch_heartbeat
_dispatch_tattoo
_dispatch_cost_guard
_dispatch_boot_cache_persist

exit 0
