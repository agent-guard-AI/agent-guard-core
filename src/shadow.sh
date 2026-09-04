#!/usr/bin/env bash
#
# shadow.sh — Session Shadow / Liveness API (SPEC F4)
#
# Snapshot leve e read-only de sessões ativas, consumível por Agent Ops / AOL
# para decisões de cleanup (ex: cleanup-stale, cockpit, wake-up).
#
# Contratos (contracts.md §6):
#   - Read-only por padrão: _shadow_compute nunca muta lease/session/branch.
#   - Sem polling, sem heartbeat, sem cleanup neste módulo (F4.4). O snapshot
#     é computado sob demanda; a persistência só ocorre via `_shadow_refresh`,
#     invocado explicitamente pela camada AOL (ex: hook de heartbeat).
#   - Toda inteligência de liveness é reutilizada de init.sh
#     (_status_inspect_session, _lease_is_shell_pinned, _pid_tree_has_agent_process);
#     este módulo não duplica detecção.
#
# Este arquivo define apenas funções; é seguro sourcear de init.sh ou do CLI.

# ---------------------------------------------------------------------------
# Compute — preenche _sh_* no escopo do caller (padrão _rec_* do init.sh).
# ---------------------------------------------------------------------------
# Emite shadow apenas quando há algo relevante: sessão não-livre ou health
# de drift/orphan/pinned (mesma regra de emissão de sessions[] na Machine API).
_shadow_compute() {
    local identity="$1"
    _sh_emit="false"
    _sh_identity="${identity}"
    _sh_status="free"
    _sh_health=""
    _sh_role=""
    _sh_pid=""
    _sh_pid_live="false"
    _sh_agent_in_tree=""
    _sh_shell_pinned="false"
    _sh_stale="false"
    _sh_branch=""
    _sh_worktree_path=""
    _sh_last_activity=""
    _sh_drift=""
    _sh_snapshot_at="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    _sh_source="${2:-on_demand}"

    _status_inspect_session "${identity}"

    _sh_status="${_rec_status:-free}"
    _sh_health="${_rec_health:-}"
    _sh_role="${_rec_role:-}"
    _sh_pid="${_rec_pid:-}"
    _sh_branch="${_rec_branch:-}"
    _sh_last_activity="${_rec_last_activity:-}"
    _sh_drift="${_rec_drift:-}"
    _sh_stale="${_rec_stale_flag:-false}"
    _sh_worktree_path="$(_get_worktree_path "${identity}")"

    if [[ "${_sh_status}" != "free" || ( -n "${_sh_health}" && "${_sh_health}" != "-" ) ]]; then
        _sh_emit="true"
    fi

    [[ -z "${_sh_pid}" ]] && return 0
    if ! _is_pid_alive "${_sh_pid}" 2>/dev/null; then
        return 0
    fi
    _sh_pid_live="true"

    # shell_pinned: reutiliza o resultado que o reconcile já computou quando
    # disponível; só avalia de novo quando ficou "não avaliado" (sessão stale,
    # em que o reconcile pula o pinned check).
    if [[ -n "${_rec_shell_pinned:-}" ]]; then
        _sh_shell_pinned="${_rec_shell_pinned}"
    elif _lease_is_shell_pinned "${identity}"; then
        _sh_shell_pinned="true"
    fi

    # agent_in_tree: side effect de _lease_is_shell_pinned quando executado;
    # senão, pergunta diretamente ao predicado (scan único de /proc).
    if [[ -n "${_lease_agent_in_tree:-}" ]]; then
        _sh_agent_in_tree="${_lease_agent_in_tree}"
    elif _pid_tree_has_agent_process "${_sh_pid}" 2>/dev/null; then
        _sh_agent_in_tree="true"
    else
        _sh_agent_in_tree="false"
    fi
}

# ---------------------------------------------------------------------------
# Writer — anexa o shadow computado como uma linha JSONL (env-var pattern,
# igual a _emit_status_json, para evitar quoting problems).
# Uso: AG_SH_*=<valores> _shadow_append_jsonl <arquivo.jsonl>
# ---------------------------------------------------------------------------
_shadow_append_jsonl() {
    local out_file="$1"
    AG_SH_IDENTITY="${_sh_identity}" \
    AG_SH_STATUS="${_sh_status}" \
    AG_SH_HEALTH="${_sh_health}" \
    AG_SH_ROLE="${_sh_role}" \
    AG_SH_PID="${_sh_pid}" \
    AG_SH_PID_LIVE="${_sh_pid_live}" \
    AG_SH_AGENT_IN_TREE="${_sh_agent_in_tree}" \
    AG_SH_SHELL_PINNED="${_sh_shell_pinned}" \
    AG_SH_STALE="${_sh_stale}" \
    AG_SH_BRANCH="${_sh_branch}" \
    AG_SH_WORKTREE="${_sh_worktree_path}" \
    AG_SH_LAST_ACTIVITY="${_sh_last_activity}" \
    AG_SH_DRIFT="${_sh_drift}" \
    AG_SH_SNAPSHOT_AT="${_sh_snapshot_at}" \
    AG_SH_SOURCE="${_sh_source}" \
    AG_SH_OUT_FILE="${out_file}" \
    "${AG_PYTHON:-python3}" - <<'PY'
import json, os

def env(name):
    return os.environ.get(name, "")

pid = env("AG_SH_PID")
agent_in_tree = env("AG_SH_AGENT_IN_TREE")

obj = {
    "identity": env("AG_SH_IDENTITY"),
    "status": env("AG_SH_STATUS"),
    "health": env("AG_SH_HEALTH"),
    "role": env("AG_SH_ROLE"),
    "pid": int(pid) if pid.isdigit() else None,
    "pid_live": env("AG_SH_PID_LIVE") == "true",
    # None quando o PID está morto (nenhuma árvore para inspecionar).
    "agent_in_tree": (agent_in_tree == "true") if agent_in_tree != "" else None,
    "shell_pinned": env("AG_SH_SHELL_PINNED") == "true",
    "stale": env("AG_SH_STALE") == "true",
    "branch": env("AG_SH_BRANCH"),
    "worktree_path": env("AG_SH_WORKTREE"),
    "last_activity": env("AG_SH_LAST_ACTIVITY"),
    "drift": env("AG_SH_DRIFT"),
    "snapshot_at": env("AG_SH_SNAPSHOT_AT"),
    "source": env("AG_SH_SOURCE"),
}

with open(env("AG_SH_OUT_FILE"), "a", encoding="utf-8") as f:
    f.write(json.dumps(obj, ensure_ascii=False) + "\n")
PY
}

# ---------------------------------------------------------------------------
# Listagem de identidades (mesma varredura de _emit_status_json).
# ---------------------------------------------------------------------------
_shadow_list_identities() {
    local identity_list prefix base_slots max_slots i
    identity_list="$(bash "${AGENT_GUARD_CONFIG_BIN}" keys identities 2>/dev/null || true)"
    for prefix in ${identity_list}; do
        [[ -z "${prefix}" ]] && continue
        base_slots="$(_guard_get "identities.${prefix}.slots")"
        max_slots="$(_guard_get "identities.${prefix}.max_slots" "${base_slots}")"
        for i in $(seq 1 "${max_slots}"); do
            echo "${prefix}${i}"
        done
    done
}

# Resolve o repositório principal (não o worktree) via git common-dir.
_shadow_repo_root() {
    local base="${AGENT_GUARD_REPO_ROOT:-${PWD}}"
    local git_common_dir
    git_common_dir="$(git -C "${base}" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "${git_common_dir}" = /* ]]; then
        (cd "$(dirname "${git_common_dir}")" && pwd)
    else
        (cd "${base}/${git_common_dir}/.." && pwd)
    fi
}

_shadow_dir() {
    echo "$(_shadow_repo_root)/.agent-guard/session/shadow"
}

_shadow_file() {
    echo "$(_shadow_dir)/$1.json"
}

# ---------------------------------------------------------------------------
# Refresh — computa e persiste o snapshot de forma atômica (tmp + mv).
# Existe para a camada AOL (ex: hook de heartbeat) manter o arquivo fresco;
# o kernel nunca invoca isso por conta própria (F4.4).
# ---------------------------------------------------------------------------
_shadow_refresh() {
    local identity="$1"
    local shadow_dir file tmp
    shadow_dir="$(_shadow_dir)"
    file="${shadow_dir}/${identity}.json"
    mkdir -p "${shadow_dir}"
    _shadow_compute "${identity}" "refresh"
    if [[ "${_sh_emit}" != "true" ]]; then
        # Sessão sem estado relevante: remove snapshot obsoleto se existir.
        rm -f "${file}"
        return 1
    fi
    tmp="$(mktemp "${shadow_dir}/.${identity}.XXXXXX")"
    : > "${tmp}"
    _shadow_append_jsonl "${tmp}"
    mv "${tmp}" "${file}"
    echo "${file}"
}

# ---------------------------------------------------------------------------
# Read — lê o snapshot persistido (consumo barato por Agent Ops).
# ---------------------------------------------------------------------------
_shadow_read() {
    local identity="$1"
    local file
    file="$(_shadow_file "${identity}")"
    if [[ -f "${file}" ]]; then
        cat "${file}"
    else
        echo "{\"error\": \"no shadow snapshot for ${identity}\", \"error_code\": \"NOT_FOUND\"}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# CLI — agent-guard shadow [--identity <id>] [--refresh] [--json]
#   default: JSON com todos os shadows computados on-demand (read-only).
#   --refresh: persiste snapshots (AOL) e lista os arquivos escritos.
#   --identity: restringe a uma identidade.
# ---------------------------------------------------------------------------
_shadow_cmd() {
    local identity="" refresh="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --identity|-i)
                identity="${2:-}"
                shift 2
                ;;
            --refresh|-r)
                refresh="true"
                shift
                ;;
            --json|-j)
                shift
                ;;
            --help|-h)
                echo "Usage: agent-guard shadow [--identity <id>] [--refresh]"
                echo "  Read-only session shadow / liveness snapshot (Machine API companion)."
                echo "  --refresh persists snapshots under .agent-guard/session/shadow/ (AOL layer)."
                return 0
                ;;
            *)
                echo "❌ Unknown shadow option: $1" >&2
                echo "   Usage: agent-guard shadow [--identity <id>] [--refresh]" >&2
                return 1
                ;;
        esac
    done

    local targets=""
    if [[ -n "${identity}" ]]; then
        targets="${identity}"
    else
        targets="$(_shadow_list_identities)"
    fi

    if [[ "${refresh}" == "true" ]]; then
        local t written
        for t in ${targets}; do
            written="$(_shadow_refresh "${t}" 2>/dev/null || true)"
            if [[ -n "${written}" ]]; then
                echo "💾 ${t} → ${written}"
            fi
        done
        return 0
    fi

    local tmp_dir shadows_file generated_at
    tmp_dir="$(mktemp -d)"
    shadows_file="${tmp_dir}/shadows.jsonl"
    touch "${shadows_file}"
    for t in ${targets}; do
        _shadow_compute "${t}" "on_demand"
        if [[ "${_sh_emit}" == "true" ]]; then
            _shadow_append_jsonl "${shadows_file}"
        fi
    done
    generated_at="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    SHADOWS_FILE="${shadows_file}" GENERATED_AT="${generated_at}" "${AG_PYTHON:-python3}" - <<'PY'
import json, os, sys

shadows = []
path = os.environ.get("SHADOWS_FILE", "")
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                shadows.append(json.loads(line))

print(json.dumps({
    "schema_version": 1,
    "generated_at": os.environ.get("GENERATED_AT", ""),
    "shadows": shadows,
}, indent=2, ensure_ascii=False))
PY
    rm -rf "${tmp_dir}"
}
