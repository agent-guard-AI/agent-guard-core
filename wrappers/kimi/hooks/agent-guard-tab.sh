#!/usr/bin/env bash
#
# agent-guard-tab.sh — handler de hooks do Kimi Code CLI para titulo de aba.
#
# Migrado de .kiro/shell/hmvip-tab/kimi-tab-hook.sh na F1 da spec
# agent-guard-tab-unification-20260805. Conteudo preservado (nomes de funcoes
# e comportamento), apenas o path e o header mudam. O path antigo continua
# existindo como shim ate a demolicao F3.5.
#
# Recebe o estado como $1 (working|attention|error|notification|session-start|session-end)
# e o payload JSON do evento via stdin (formato oficial dos hooks do Kimi Code).
#
# Mantem ~/.kimi-code/tab-sessions/<session_id>.json e reescreve o titulo da
# aba/janela do terminal (OSC 0) no TTY da sessao, com bolinhas de status:
#
#   🟢 processando   🟡 aguardando humano   🔴 erro   ⚪ parada   🔵 background
#
# Contrato dos hooks do Kimi Code: exit 0 = allow, 2 = block. Este handler e
# observacao-pura: NUNCA escreve em stdout (stdout vira contexto do modelo) e
# SEMPRE sai com codigo 0 (fail-open) para jamais bloquear o CLI.
#
set -u
umask 077

TAB_DIR="${HMVIP_TAB_DIR:-${HOME}/.kimi-code/tab-sessions}"
LOG_FILE="${TAB_DIR}/hook.log"
MAX_TITLE_CHARS="${HMVIP_TAB_TITLE_CHARS:-32}"
# Separador entre status/slot e titulo. Padrao " | " evita glifos quebrados
# em fontes que nao renderizam U+00B7 (Middle Dot) corretamente.
SEPARATOR="${HMVIP_TAB_SEPARATOR:- | }"
SUMMARIZER="${HMVIP_TAB_SUMMARIZER:-${HOME}/.kimi-code/hooks/summarize-prompt.py}"

mkdir -p "${TAB_DIR}" 2>/dev/null || true

_log() {
    # Log best-effort, nunca quebra o hook.
    printf '%s %s\n' "$(date +%H:%M:%S 2>/dev/null)" "$1" >>"${LOG_FILE}" 2>/dev/null || true
    # Rotacao simples: mantem o log pequeno.
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
    # $1 = expressao jq com alternativas, ex: '.a // .b // ""'
    if [ -n "${PAYLOAD}" ] && command -v jq >/dev/null 2>&1; then
        printf '%s' "${PAYLOAD}" | jq -r "$1" 2>/dev/null || true
    fi
}

_summarize_prompt() {
    # $1 = prompt do usuario; $2 = titulo atual (opcional)
    local prompt="$1" current="${2:-}"
    if [ -z "${prompt}" ]; then
        return 1
    fi
    if [ ! -x "${SUMMARIZER}" ] && [ -f "${SUMMARIZER}" ]; then
        chmod +x "${SUMMARIZER}" 2>/dev/null || true
    fi
    [ -x "${SUMMARIZER}" ] || return 1
    HMVIP_TAB_TITLE_CHARS="${MAX_TITLE_CHARS}" \
        printf '%s' "${prompt}" | "${SUMMARIZER}" - "${current}" 2>/dev/null
}

SESSION_ID="$(_jq_get '.session_id // .sessionId // ""')"
CWD="$(_jq_get '.cwd // ""')"
[ -z "${CWD}" ] && CWD="${PWD:-}"

# Fallback quando session_id nao vem no payload: hash do cwd (estavel).
if [ -z "${SESSION_ID}" ]; then
    SESSION_ID="cwd-$(printf '%s' "${CWD}" | cksum 2>/dev/null | cut -d' ' -f1)"
fi

STATE_FILE="${TAB_DIR}/${SESSION_ID}.json"
TITLE_FILE="${TAB_DIR}/${SESSION_ID}.title"

# ---------------------------------------------------------------------------
# Estado anterior (defaults tolerantes via jq).
# ---------------------------------------------------------------------------
_prev() {
    [ -f "${STATE_FILE}" ] && command -v jq >/dev/null 2>&1 \
        && jq -r "$1" "${STATE_FILE}" 2>/dev/null || true
}

STATE="$(_prev '.state // "idle"')"
BG="$(_prev '.bg // 0')"
TITLE_AUTO="$(_prev '.title_auto // ""')"
[ -z "${BG}" ] && BG=0

# Auto-cura: versoes antigas gravaram o prompt como JSON cru quando o CLI
# passou a enviar array de blocos de conteudo. Descarta para re-derivar.
case "${TITLE_AUTO}" in
    \[*|\{*) TITLE_AUTO="" ;;
esac

# Marca de quando o estado atual comecou (para o selo "esperando desde" e
# para notificacoes so em transicao real de estado).
PREV_STATE="${STATE}"
STATE_SINCE="$(_prev '.state_since // 0')"
[ -z "${STATE_SINCE}" ] && STATE_SINCE=0

# ---------------------------------------------------------------------------
# Derivacao de slot e titulo.
# ---------------------------------------------------------------------------
_slot_from_cwd() {
    local base
    base="$(basename "${CWD}" 2>/dev/null || echo "${CWD}")"
    case "${base}" in
        hmvip-ia-*) printf '%s' "${base#hmvip-ia-}" ;;
        *)          printf '%s' "${base}" ;;
    esac
}

_sanitize_title() {
    # Remove bytes de controle (injetam escape sequences no terminal!) e corta
    # em fronteira de palavra.
    printf '%s' "$1" \
        | tr '\n\t' '  ' \
        | tr -d '\000-\037\177' \
        | sed 's/  */ /g; s/^ //; s/ $//' \
        | cut -c1-"$((MAX_TITLE_CHARS + 8))" \
        | awk -v max="${MAX_TITLE_CHARS}" '{
            if (length($0) <= max) { print $0; exit }
            cut = substr($0, 1, max)
            sub(/ [^ ]*$/, "", cut)
            if (length(cut) < 8) cut = substr($0, 1, max)
            print cut "…"
        }' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Transicoes de estado.
# ---------------------------------------------------------------------------
EVENT="$(_jq_get '.hook_event_name // ""')"
ACTION="${1:-}"

case "${ACTION}" in
    working)
        STATE="working"
        # Titulo automatico: derivado no primeiro prompt, mas comandos slash
        # (/new, /compact, /skill, /goal, /tab, /clear, /continue) podem
        # renomear a qualquer momento.
        if [ "${EVENT}" = "UserPromptSubmit" ]; then
            # O campo prompt pode vir como string (legado) ou como array de
            # blocos de conteudo [{"type":"text","text":"..."}, ...].
            PROMPT="$(_jq_get '
                (.prompt // .user_prompt // .message // "") as $p
                | if ($p | type) == "array" then
                      [$p[] | select(type == "object" and .type == "text") | .text // ""] | join(" ")
                  elif ($p | type) == "string" then $p
                  else "" end
            ')"
            if [ -n "${PROMPT}" ] && command -v jq >/dev/null 2>&1; then
                SUMMARY_JSON="$(_summarize_prompt "${PROMPT}" "${TITLE_AUTO}")" || SUMMARY_JSON=""
                if [ -n "${SUMMARY_JSON}" ]; then
                    _new_title="$(printf '%s' "${SUMMARY_JSON}" | jq -r '.title // ""' 2>/dev/null)"
                    _is_reset="$(printf '%s' "${SUMMARY_JSON}" | jq -r '.reset // false' 2>/dev/null)"
                    _is_compact="$(printf '%s' "${SUMMARY_JSON}" | jq -r '.compact // false' 2>/dev/null)"
                    _is_manual="$(printf '%s' "${SUMMARY_JSON}" | jq -r '.manual // false' 2>/dev/null)"
                    _has_cmd="$(printf '%s' "${SUMMARY_JSON}" | jq -r '(.command != null)' 2>/dev/null)"
                    _log "summary cmd=${_has_cmd} reset=${_is_reset} compact=${_is_compact} manual=${_is_manual} title=${_new_title}"
                    if [ "${_is_manual}" = "true" ]; then
                        # /tab <nome> => override manual rapido
                        printf '%s\n' "${_new_title}" >"${TITLE_FILE}"
                    elif [ "${_is_reset}" = "true" ]; then
                        # /new, /clear, /skill, /goal, /deploy, /pr, /review ...
                        rm -f "${TITLE_FILE}"
                        TITLE_AUTO="${_new_title}"
                    elif [ "${_is_compact}" = "true" ]; then
                        # /compact => resume e marca
                        rm -f "${TITLE_FILE}"
                        TITLE_AUTO="${_new_title}"
                    elif [ -z "${TITLE_AUTO}" ] && [ ! -f "${TITLE_FILE}" ]; then
                        # primeiro prompt sem comando slash
                        TITLE_AUTO="${_new_title}"
                    fi
                fi
            fi
        fi
        ;;
    attention)
        STATE="attention"
        ;;
    error)
        STATE="error"
        ;;
    notification)
        NTYPE="$(_jq_get '.notification_type // .type // .notification.type // ""')"
        _log "notification type=${NTYPE} payload=$(printf '%s' "${PAYLOAD}" | head -c 300)"
        case "${NTYPE}" in
            task.started|task.created|task.running|task.progress)
                BG=$((BG + 1))
                [ "${BG}" -gt 9 ] && BG=9
                ;;
            task.*)
                # completed, failed, stopped, terminated, timed_out, abort...
                BG=$((BG - 1))
                [ "${BG}" -lt 0 ] && BG=0
                ;;
        esac
        ;;
    session-start)
        [ -z "${STATE}" ] && STATE="idle"
        [ "${STATE}" = "error" ] && STATE="idle"
        ;;
    session-end)
        rm -f "${STATE_FILE}" "${TITLE_FILE}" 2>/dev/null || true
        _log "session-end ${SESSION_ID} cwd=${CWD}"
        ;;
    render)
        # Apenas re-renderiza (usado por 'hmvip tab' apos override manual).
        ;;
    *)
        _log "acao desconhecida: ${ACTION}"
        ;;
esac

_log "event=${EVENT:-${ACTION}} state=${STATE} bg=${BG} sid=${SESSION_ID}"

NOW="$(date +%s 2>/dev/null || echo 0)"
if [ "${STATE}" != "${PREV_STATE}" ] || [ "${STATE_SINCE}" -le 0 ] 2>/dev/null; then
    STATE_SINCE="${NOW}"
fi

# ---------------------------------------------------------------------------
# Persistencia atomica do estado.
# ---------------------------------------------------------------------------
SLOT="$(_slot_from_cwd)"

# TTY: sobe a cadeia de PPIDs ate achar um processo com controlling terminal
# (o CLI pode rodar o hook em process group sem tty proprio). No caminho,
# captura o PID do processo do CLI (comm contendo 'kimi') para o cockpit
# poder checar se a sessao esta viva.
TTY_NAME=""
CLI_PID=""
_pid=$$
_hops=0
while [ "${_hops}" -lt 8 ]; do
    _t="$(ps -o tty= -p "${_pid}" 2>/dev/null | tr -d ' ' || true)"
    if [ -n "${_t}" ] && [ "${_t}" != "?" ] && [ -z "${TTY_NAME}" ]; then
        TTY_NAME="${_t}"
    fi
    if [ -z "${CLI_PID}" ]; then
        _comm="$(ps -o comm= -p "${_pid}" 2>/dev/null || true)"
        case "${_comm}" in
            *kimi*) CLI_PID="${_pid}" ;;
        esac
    fi
    if [ -n "${TTY_NAME}" ] && [ -n "${CLI_PID}" ]; then
        break
    fi
    _pid="$(ps -o ppid= -p "${_pid}" 2>/dev/null | tr -d ' ' || true)"
    if [ -z "${_pid}" ] || [ "${_pid}" = "0" ] || [ "${_pid}" = "1" ]; then
        break
    fi
    _hops=$((_hops + 1))
done
[ -z "${CLI_PID}" ] && CLI_PID="${PPID:-0}"

# ---------------------------------------------------------------------------
# Fallback de slot por lease (sessao sem wrapper / lease mid-session).
# Sessao lancada sem o wrapper Agent Guard (ex: na janela entre self-update
# do Kimi e o recovery) ou que adquiriu o slot depois do launch (ex: `source
# .hmvip-agent-init` via tool) tem cwd fora do worktree — mas o lease em
# .kiro/locks/agent-sessions/<id>.json carrega o PID do CLI. Casa o CLI_PID
# com o pid do lease ativo e usa a identidade como slot.
# ---------------------------------------------------------------------------
case "$(basename "${CWD}" 2>/dev/null)" in
    hmvip-ia-*) : ;; # cwd ja identifica o slot
    *)
        _repo_root="$(git -C "${CWD}" rev-parse --show-toplevel 2>/dev/null || true)"
        _locks_dir="${_repo_root}/.kiro/locks/agent-sessions"
        if [ -n "${_repo_root}" ] && [ -d "${_locks_dir}" ] && command -v jq >/dev/null 2>&1; then
            for _sf in "${_locks_dir}"/*.json; do
                [ -f "${_sf}" ] || continue
                _pair="$(jq -r 'select(.status=="active") | "\(.pid // 0) \(.identity // "")"' "${_sf}" 2>/dev/null || true)"
                [ -n "${_pair}" ] || continue
                if [ "${_pair%% *}" = "${CLI_PID}" ]; then
                    _lease_identity="${_pair#* }"
                    if [ -n "${_lease_identity}" ]; then
                        SLOT="${_lease_identity}"
                        _log "slot via lease fallback: ${SLOT} (pid ${CLI_PID})"
                    fi
                    break
                fi
            done
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# Replicar estado da tab nos campos tab_* do lease do agent-guard.
# O cockpit unificado (hmvip status / hmvip tabs) le do lease, nao do arquivo
# de sessao da tab, para nao depender de ~/.kimi-code/tab-sessions/ estar
# acessivel no worktree correto.
# ---------------------------------------------------------------------------
_persist_tab_to_lease() {
    local _identity="$1"
    case "${_identity}" in
        kimi[1-9]|kimi[1-9][0-9]|claude[1-9]|claude[1-9][0-9]|gemini[1-9]|gemini[1-9][0-9]|grok[1-9]|grok[1-9][0-9]) ;;
        *) return 0 ;;
    esac

    local _repo_root
    _repo_root="$(git -C "${CWD}" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "${_repo_root}" ] || return 0
    local _init_stub="${_repo_root}/packages/agent-guard-core/src/init.sh"
    [ -f "${_init_stub}" ] || return 0

    AGENT_GUARD_FUNCTIONS_ONLY=1
    # shellcheck source=/dev/null
    source "${_init_stub}" >/dev/null 2>&1 || return 0

    local _session_file
    _session_file="$(_get_session_file "${_identity}" 2>/dev/null || true)"
    [ -f "${_session_file}" ] || return 0
    local _session_status
    _session_status="$(_load_session_field "${_identity}" "status" 2>/dev/null || true)"
    [ "${_session_status}" = "active" ] || return 0

    _save_session_field "${_identity}" "tab_state" "${STATE}" >/dev/null 2>&1 || true
    _save_session_field "${_identity}" "tab_title" "${TITLE_WORK}" >/dev/null 2>&1 || true
    _save_session_field "${_identity}" "tab_bg" "${BG}" >/dev/null 2>&1 || true
    _save_session_field "${_identity}" "tab_tty" "${TTY_NAME}" >/dev/null 2>&1 || true
    _save_session_field "${_identity}" "tab_updated" "${NOW}" >/dev/null 2>&1 || true
}

_clear_tab_lease_fields() {
    local _identity="$1"
    case "${_identity}" in
        kimi[1-9]|kimi[1-9][0-9]|claude[1-9]|claude[1-9][0-9]|gemini[1-9]|gemini[1-9][0-9]|grok[1-9]|grok[1-9][0-9]) ;;
        *) return 0 ;;
    esac

    local _repo_root
    _repo_root="$(git -C "${CWD}" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "${_repo_root}" ] || return 0
    local _init_stub="${_repo_root}/packages/agent-guard-core/src/init.sh"
    [ -f "${_init_stub}" ] || return 0

    AGENT_GUARD_FUNCTIONS_ONLY=1
    # shellcheck source=/dev/null
    source "${_init_stub}" >/dev/null 2>&1 || return 0

    local _session_file
    _session_file="$(_get_session_file "${_identity}" 2>/dev/null || true)"
    [ -f "${_session_file}" ] || return 0

    _save_session_field "${_identity}" "tab_state" "" >/dev/null 2>&1 || true
    _save_session_field "${_identity}" "tab_title" "" >/dev/null 2>&1 || true
    _save_session_field "${_identity}" "tab_bg" "" >/dev/null 2>&1 || true
    _save_session_field "${_identity}" "tab_tty" "" >/dev/null 2>&1 || true
    _save_session_field "${_identity}" "tab_updated" "" >/dev/null 2>&1 || true
}

if [ "${ACTION}" = "session-end" ]; then
    _clear_tab_lease_fields "${SLOT}"
elif [ "${ACTION}" != "session-end" ]; then
    TMP="${STATE_FILE}.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg sid "${SESSION_ID}" \
            --arg cwd "${CWD}" \
            --arg slot "${SLOT}" \
            --arg state "${STATE}" \
            --arg title_auto "${TITLE_AUTO}" \
            --arg tty "${TTY_NAME}" \
            --argjson bg "${BG}" \
            --argjson pid "${CLI_PID}" \
            --argjson state_since "${STATE_SINCE}" \
            --argjson updated "${NOW}" \
            '{session_id:$sid,cwd:$cwd,slot:$slot,state:$state,bg:$bg,title_auto:$title_auto,tty:$tty,pid:$pid,state_since:$state_since,updated:$updated}' \
            >"${TMP}" 2>/dev/null && mv "${TMP}" "${STATE_FILE}" 2>/dev/null || rm -f "${TMP}"
    fi
fi

# ---------------------------------------------------------------------------
# Renderizacao do titulo no TTY.
# ---------------------------------------------------------------------------
_dots() {
    local dots=""
    [ "${BG}" -gt 0 ] && dots="🔵"
    case "${STATE}" in
        working)   dots="${dots}🟢" ;;
        attention) dots="${dots}🟡" ;;
        error)     dots="${dots}🔴" ;;
        *)         dots="${dots}⚪" ;;
    esac
    printf '%s' "${dots}"
}

# Override manual vence o titulo automatico.
TITLE_WORK="${TITLE_AUTO}"
if [ -f "${TITLE_FILE}" ]; then
    _manual="$(head -n1 "${TITLE_FILE}" 2>/dev/null || true)"
    [ -n "${_manual}" ] && TITLE_WORK="$(_sanitize_title "${_manual}")"
fi
[ -z "${TITLE_WORK}" ] && TITLE_WORK="$(_sanitize_title "$(git -C "${CWD}" branch --show-current 2>/dev/null | awk -F/ '{print $NF}')")"
[ -z "${TITLE_WORK}" ] && TITLE_WORK="livre"

# Replicar titulo final no lease para o cockpit unificado.
if [ "${ACTION}" != "session-end" ]; then
    _persist_tab_to_lease "${SLOT}"
fi

if [ "${ACTION}" = "session-end" ]; then
    FINAL_TITLE="${SLOT}${SEPARATOR}livre"
else
    # Selo "esperando desde HH:MM" em attention/error: estatico, nao mente
    # (o hook so roda em eventos, entao uma idade "(23m)" ficaria congelada).
    AGE_SUFFIX=""
    case "${STATE}" in
        attention|error)
            if [ "${STATE_SINCE}" -gt 0 ] 2>/dev/null; then
                AGE_SUFFIX="${SEPARATOR}⏳ $(date -d "@${STATE_SINCE}" +%H:%M 2>/dev/null)"
            fi
            ;;
    esac
    FINAL_TITLE="$(_dots) ${SLOT}${SEPARATOR}${TITLE_WORK}${AGE_SUFFIX}"
fi

# Notificacao desktop ao ENTRAR em attention/error (so na transicao, para
# nao duplicar a cada evento). Desligar: HMVIP_TAB_NOTIFY=0.
_notify_attention() {
    [ "${HMVIP_TAB_NOTIFY:-1}" = "1" ] || return 0
    case "${STATE}" in
        attention|error) ;;
        *) return 0 ;;
    esac
    [ "${PREV_STATE}" != "${STATE}" ] || return 0
    [ "${ACTION}" != "render" ] || return 0
    if [ -n "${HMVIP_TAB_NOTIFY_OUT:-}" ]; then
        # Testes: captura a notificacao em arquivo.
        printf '%s\n' "${FINAL_TITLE}" >>"${HMVIP_TAB_NOTIFY_OUT}" 2>/dev/null || true
        return 0
    fi
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "hmvip ${SLOT}" "${FINAL_TITLE}" >/dev/null 2>&1 || true
    elif [ -n "${KITTY_WINDOW_ID:-}" ] && [ -n "${TTY_NAME}" ] && [ "${TTY_NAME}" != "?" ]; then
        printf '\033]99;i=hmvip-%s;d=1;%s\033\\' "${SESSION_ID}" "${FINAL_TITLE}" >"/dev/${TTY_NAME}" 2>/dev/null || true
    fi
    return 0
}
_notify_attention

_write_tty() {
    # $1 = destino (ex: /dev/pts/12 ou /dev/tty)
    [ -w "$1" ] || return 0
    printf '\033]0;%s\007' "${FINAL_TITLE}" >"$1" 2>/dev/null || true
    # tmux: renomeia a janela do painel quando detectavel.
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
        tmux set-window-option -t "${TMUX_PANE}" automatic-rename off >/dev/null 2>&1 || true
        tmux rename-window -t "${TMUX_PANE}" "${FINAL_TITLE}" >/dev/null 2>&1 || true
    fi
}

# Testes: HMVIP_TAB_OUT aponta para um arquivo que recebe o titulo final.
if [ -n "${HMVIP_TAB_OUT:-}" ]; then
    printf '%s\n' "${FINAL_TITLE}" >>"${HMVIP_TAB_OUT}" 2>/dev/null || true
elif [ -n "${TTY_NAME}" ] && [ "${TTY_NAME}" != "?" ]; then
    _write_tty "/dev/${TTY_NAME}"
else
    _write_tty "/dev/tty"
fi

exit 0
