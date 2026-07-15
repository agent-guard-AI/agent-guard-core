#!/usr/bin/env bash
#
# agent-guard-core — Session Journal Service
#
# Persiste eventos de sessão de IA em um arquivo JSONL central, permitindo
# recuperação de contexto após crash da IDE ou troca de slot/identidade.
#
# Uso (sourced):
#   source "${AGENT_GUARD_DIR}/src/journal.sh"
#   _journal_write_event "init" '{"branch":"ia-kimi1/ia-a/foo"}'
#
# Eventos padrão:
#   init, attach, release, checkpoint, commit, error, resume

set -euo pipefail

# Resolve o diretório deste script mesmo quando sourcado.
# This script lives in packages/agent-guard-core/src/; walk up to agent-guard-core root.
_JOURNAL_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve a usable Python interpreter cross-platform.
AG_PYTHON="$(bash "${_JOURNAL_CORE_DIR}/bin/agent-guard-python" 2>/dev/null || echo "python3")"
export AG_PYTHON

# -----------------------------------------------------------------------------
# Configuração
# -----------------------------------------------------------------------------

# Resolve repo root from current git worktree.
_journal_get_repo_root() {
    local repo_root="${1:-}"
    if [[ -n "${repo_root}" ]]; then
        echo "${repo_root}"
        return 0
    fi
    if [[ -n "${AGENT_GUARD_REPO_ROOT:-}" ]]; then
        echo "${AGENT_GUARD_REPO_ROOT}"
        return 0
    fi
    local git_common_dir
    git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "${git_common_dir}" = /* ]]; then
        cd "$(dirname "${git_common_dir}")" && pwd
    else
        cd "${_JOURNAL_CORE_DIR}/${git_common_dir}/.." && pwd
    fi
}

# Read a config value using agent-guard-config.
_journal_get_config() {
    local key="${1:-}"
    local default_value="${2:-}"

    local config_bin="${_JOURNAL_CORE_DIR}/bin/agent-guard-config"
    if [[ -f "${config_bin}" ]]; then
        local value
        value="$(bash "${config_bin}" get "${key}" "${default_value}" 2>/dev/null || echo "${default_value}")"
        if [[ -n "${value}" && "${value}" != "None" ]]; then
            echo "${value}"
            return 0
        fi
    fi

    echo "${default_value}"
}

# Retorna o caminho absoluto do journal.
# O journal fica no repositório principal (compartilhado entre worktrees).
_journal_get_path() {
    local repo_root
    repo_root="$(_journal_get_repo_root "${1:-}")"
    local journal_dir="${repo_root}/.agent-guard/journal"
    local configured
    configured="$(_journal_get_config "journal.path" "${journal_dir}/agent-guard.jsonl")"
    if [[ "${configured}" != /* ]]; then
        configured="${repo_root}/${configured}"
    fi
    echo "${configured}"
}

# Retém dias de retenção padrão.
_journal_get_retention_days() {
    _journal_get_config "journal.retention_days" "90"
}

# -----------------------------------------------------------------------------
# Escrita
# -----------------------------------------------------------------------------

# Escreve um evento no journal de forma atômica (flock).
# Args: action, payload_json, [repo_root]
_journal_write_event() {
    local action="${1:-unknown}"
    local payload="${2:-}"
    if [[ -z "${payload}" ]]; then
        payload="{}"
    fi
    local repo_root="${3:-}"

    local journal_path
    journal_path="$(_journal_get_path "${repo_root}")"
    local journal_dir
    journal_dir="$(dirname "${journal_path}")"
    mkdir -p "${journal_dir}"

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"

    local identity="${AGENT_GUARD_IDENTITY:-${AGENT_GUARD_IDENTITY:-}}"
    local branch="${AGENT_GUARD_BRANCH:-${AGENT_GUARD_BRANCH:-}}"
    local worktree="${AGENT_GUARD_WORKTREE_PATH:-${AGENT_GUARD_WORKTREE_PATH:-}}"
    local role="${AGENT_GUARD_ROLE:-}"

    # Fallbacks from git worktree when env vars are not set (e.g. manual
    # checkpoint after a shell restart or cross-tool call).
    if [[ -z "${worktree}" ]]; then
        worktree="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    if [[ -z "${branch}" ]]; then
        branch="$(git -C "${worktree}" branch --show-current 2>/dev/null || echo "")"
    fi
    if [[ -z "${identity}" && -n "${worktree}" ]]; then
        local git_email
        git_email="$(git -C "${worktree}" config --worktree user.email 2>/dev/null || git -C "${worktree}" config user.email 2>/dev/null || echo "")"
        if [[ "${git_email}" =~ ^agent-([a-z]+[0-9]+)@ ]]; then
            identity="${BASH_REMATCH[1]}"
        fi
    fi

    local entry
    entry="$(${AG_PYTHON} -c "
import json, os
entry = {
    'timestamp': '${timestamp}',
    'action': '${action}',
    'identity': '${identity}',
    'role': '${role}',
    'branch': '${branch}',
    'worktree': '${worktree}',
    'payload': json.loads('''${payload}''')
}
print(json.dumps(entry, ensure_ascii=False))
" 2>/dev/null || echo "{\"timestamp\":\"${timestamp}\",\"action\":\"${action}\",\"error\":\"json_encode_failed\"}")"

    local lock_file="${journal_dir}/.agent-guard-journal.lock"
    touch "${lock_file}"

    # flock exclusivo para serializar writes entre processos.
    # Fallback para lock atomico via mkdir no Git Bash/Windows.
    if command -v flock >/dev/null 2>&1; then
        local lock_fd=201
        {
            flock -x "${lock_fd}"
            printf '%s\n' "${entry}" >> "${journal_path}"
            flock -u "${lock_fd}"
        } {lock_fd}>"${lock_file}"
    else
        local lock_dir="${lock_file}.dir"
        while ! mkdir "${lock_dir}" 2>/dev/null; do
            sleep 0.1
        done
        printf '%s\n' "${entry}" >> "${journal_path}"
        rmdir "${lock_dir}" 2>/dev/null || true
    fi
}

# Alias semânticos para eventos comuns.
_journal_init() {
    _journal_write_event "init" "{\"message\":\"session acquired\"}"
}

_journal_attach() {
    local branch="${1:-}"
    _journal_write_event "attach" "{\"branch\":\"${branch}\"}"
}

_journal_adopt() {
    local branch="${1:-}"
    _journal_write_event "adopt" "{\"branch\":\"${branch}\"}"
}

_journal_release() {
    _journal_write_event "release" "{\"message\":\"session released\"}"
}

_journal_checkpoint() {
    local message="${1:-}"
    local worktree_path="${2:-${CURRENT_WORKTREE:-}}"
    local branch="${3:-${CURRENT_BRANCH:-}}"

    local head_sha=""
    local dirty_files=""
    local stash_list=""
    # In a git worktree .git is a file, not a directory; use -e.
    if [[ -n "${worktree_path}" && -e "${worktree_path}/.git" ]]; then
        head_sha="$(git -C "${worktree_path}" rev-parse --short HEAD 2>/dev/null || echo "")"
        dirty_files="$(git -C "${worktree_path}" status --porcelain 2>/dev/null || true)"
        stash_list="$(git -C "${worktree_path}" stash list 2>/dev/null || true)"
    fi

    local payload
    payload="$(${AG_PYTHON} -c "
import json, sys
print(json.dumps({
    'message': sys.argv[1],
    'branch': sys.argv[2] or None,
    'head': sys.argv[3] or None,
    'dirty': sys.argv[4].splitlines() if sys.argv[4] else [],
    'stashes': sys.argv[5].splitlines() if sys.argv[5] else []
}))
" "${message}" "${branch}" "${head_sha}" "${dirty_files}" "${stash_list}" 2>/dev/null || echo '{}')"
    _journal_write_event "checkpoint" "${payload}"
}

_journal_commit() {
    local sha="${1:-}"
    local message="${2:-}"
    local payload
    payload="$(${AG_PYTHON} -c "import json,sys; print(json.dumps({'sha': sys.argv[1], 'message': sys.argv[2]}))" "${sha}" "${message}" 2>/dev/null || echo "{}")"
    _journal_write_event "commit" "${payload}"
}

_journal_error() {
    local message="${1:-}"
    local payload
    payload="$(${AG_PYTHON} -c "import json,sys; print(json.dumps({'message': sys.argv[1]}))" "${message}" 2>/dev/null || echo "{}")"
    _journal_write_event "error" "${payload}"
}

# -----------------------------------------------------------------------------
# Leitura / Listagem
# -----------------------------------------------------------------------------

# Lista eventos do journal com filtros opcionais.
# Args: [--limit N] [--identity id] [--since ISO] [--action action]
_journal_list() {
    local limit=""
    local identity=""
    local since=""
    local action=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)
                limit="${2:-}"
                shift 2
                ;;
            --identity)
                identity="${2:-}"
                shift 2
                ;;
            --since)
                since="${2:-}"
                shift 2
                ;;
            --action)
                action="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    local journal_path
    journal_path="$(_journal_get_path)"
    if [[ ! -f "${journal_path}" ]]; then
        echo "No journal found at ${journal_path}"
        return 0
    fi

    ${AG_PYTHON} - "${journal_path}" "${limit}" "${identity}" "${since}" "${action}" <<'PY'
import json, sys
from datetime import datetime, timezone

path, limit, identity, since, action = sys.argv[1:6]
limit = int(limit) if limit else None

lines = []
with open(path, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if identity and e.get('identity') != identity:
            continue
        if action and e.get('action') != action:
            continue
        if since:
            try:
                ts = datetime.fromisoformat(e.get('timestamp', '').replace('Z', '+00:00'))
                ref = datetime.fromisoformat(since.replace('Z', '+00:00'))
                if ts < ref:
                    continue
            except Exception:
                continue
        lines.append(e)

# Mais recentes primeiro.
lines.reverse()
if limit:
    lines = lines[:limit]

for e in lines:
    ts = e.get('timestamp', '')
    ident = e.get('identity', '')
    act = e.get('action', '')
    branch = e.get('branch', '')
    payload = e.get('payload', {})
    msg = payload.get('message', '') if isinstance(payload, dict) else ''
    if len(msg) > 80:
        msg = msg[:77] + '...'
    print(f"{ts} | {ident:12s} | {act:10s} | {branch:50s} | {msg}")
PY
}

# Retorna o contexto de retomada de um evento.
# Args: [--last | --nth N | --branch branch]
_journal_resume() {
    local mode="last"
    local value=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --last)
                mode="last"
                shift
                ;;
            --nth)
                mode="nth"
                value="${2:-1}"
                shift 2
                ;;
            --branch)
                mode="branch"
                value="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    local journal_path
    journal_path="$(_journal_get_path)"
    if [[ ! -f "${journal_path}" ]]; then
        echo "No journal found at ${journal_path}"
        return 1
    fi

    ${AG_PYTHON} - "${journal_path}" "${mode}" "${value}" <<'PY'
import json, sys
path, mode, value = sys.argv[1:4]

with open(path, 'r', encoding='utf-8') as f:
    events = [json.loads(line.strip()) for line in f if line.strip()]

# Mais recentes primeiro.
events.reverse()

candidates = [e for e in events if e.get('action') in ('init', 'attach', 'checkpoint')]

selected = None
if mode == 'last':
    selected = candidates[0] if candidates else None
elif mode == 'nth':
    n = int(value) if value.isdigit() else 1
    selected = candidates[n - 1] if 0 < n <= len(candidates) else None
elif mode == 'branch':
    selected = next((e for e in candidates if e.get('branch') == value), None)

if not selected:
    print("No resumable session found.")
    sys.exit(1)

print(f"# Resume context")
print(f"timestamp: {selected.get('timestamp')}")
print(f"identity:  {selected.get('identity')}")
print(f"role:      {selected.get('role')}")
print(f"branch:    {selected.get('branch')}")
print(f"worktree:  {selected.get('worktree')}")
payload = selected.get('payload', {})
if isinstance(payload, dict) and payload.get('message'):
    print(f"message:   {payload['message']}")
print()
print("To resume:")
print(f"  cd {selected.get('worktree')}")
print(f"  source .agent-guard-init --attach {selected.get('branch')}")
PY
}

# -----------------------------------------------------------------------------
# Manutenção
# -----------------------------------------------------------------------------

# Remove entradas mais antigas que o período de retenção configurado.
_journal_rotate() {
    local repo_root="${1:-}"
    local journal_path
    journal_path="$(_journal_get_path "${repo_root}")"
    if [[ ! -f "${journal_path}" ]]; then
        return 0
    fi

    local retention_days
    retention_days="$(_journal_get_retention_days "${repo_root}")"
    local cutoff
    cutoff="$(date -u -d "-${retention_days} days" +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u -v-${retention_days}d +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || echo "1970-01-01T00:00:00.000Z")"

    local tmp_file
    tmp_file="${journal_path}.tmp"

    ${AG_PYTHON} - "${journal_path}" "${tmp_file}" "${cutoff}" <<'PY'
import json, sys
from datetime import datetime, timezone
src, dst, cutoff = sys.argv[1:4]
try:
    ref = datetime.fromisoformat(cutoff.replace('Z', '+00:00'))
except Exception:
    ref = datetime.min.replace(tzinfo=timezone.utc)

kept = 0
dropped = 0
with open(src, 'r', encoding='utf-8') as inf, open(dst, 'w', encoding='utf-8') as outf:
    for line in inf:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
            ts = datetime.fromisoformat(e.get('timestamp', '').replace('Z', '+00:00'))
            if ts >= ref:
                outf.write(line + '\n')
                kept += 1
            else:
                dropped += 1
        except Exception:
            dropped += 1

print(f"Rotated journal: kept={kept} dropped={dropped}")
PY

    mv "${tmp_file}" "${journal_path}"
}
