#!/usr/bin/env bash
#
# agent-guard-core — Session Trace Service
#
# Captura rastros contínuos de sessões de IA e os persiste em uma ref Git
# dedicada (refs/agent-guard/sessions/v1), inspirado no Entire CLI.
#
# Uso (sourced):
#   source "${AGENT_GUARD_DIR}/src/session-trace.sh"
#   _trace_init
#   _trace_write_event "turn" '{"prompt":"..."}'
#   _trace_checkpoint "micro-passo concluído"
#
# O serviço é best-effort: falhas de trace nunca quebram o fluxo principal.

set -euo pipefail

# Resolve o diretório deste script mesmo quando sourcado.
_TRACE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve a usable Python interpreter cross-platform.
AG_PYTHON="$(bash "${_TRACE_CORE_DIR}/bin/agent-guard-python" 2>/dev/null || echo "python3")"
export AG_PYTHON

# Ref Git dedicada para metadados de sessão.
AGENT_GUARD_SESSION_REF="${AGENT_GUARD_SESSION_REF:-refs/agent-guard/sessions/v1}"
export AGENT_GUARD_SESSION_REF

# Diretório de trace no worktree (arquivos em construção + último checkpoint).
AGENT_GUARD_SESSION_DIR="${AGENT_GUARD_SESSION_DIR:-}"

# ---------------------------------------------------------------------------
# Helpers de ambiente
# ---------------------------------------------------------------------------

_trace_get_repo_root() {
    if [[ -n "${AGENT_GUARD_REPO_ROOT:-}" ]]; then
        echo "${AGENT_GUARD_REPO_ROOT}"
        return 0
    fi
    local git_common_dir
    git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "${git_common_dir}" = /* ]]; then
        cd "$(dirname "${git_common_dir}")" && pwd
    else
        cd "${_TRACE_CORE_DIR}/${git_common_dir}/.." && pwd
    fi
}

_trace_get_worktree() {
    if [[ -n "${AGENT_GUARD_WORKTREE_PATH:-}" ]]; then
        echo "${AGENT_GUARD_WORKTREE_PATH}"
        return 0
    fi
    if [[ -n "${AG_WORKTREE_PATH:-}" ]]; then
        echo "${AG_WORKTREE_PATH}"
        return 0
    fi
    git rev-parse --show-toplevel 2>/dev/null || pwd
}

_trace_get_identity() {
    if [[ -n "${AGENT_GUARD_IDENTITY:-}" ]]; then
        echo "${AGENT_GUARD_IDENTITY}"
        return 0
    fi
    local worktree
    worktree="$(_trace_get_worktree)"
    local git_email
    git_email="$(git -C "${worktree}" config --worktree user.email 2>/dev/null || git -C "${worktree}" config user.email 2>/dev/null || echo "")"
    if [[ "${git_email}" =~ ^agent-([a-z]+[0-9]+)@ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "unknown"
}

_trace_get_branch() {
    if [[ -n "${AGENT_GUARD_BRANCH:-}" ]]; then
        echo "${AGENT_GUARD_BRANCH}"
        return 0
    fi
    local worktree
    worktree="$(_trace_get_worktree)"
    git -C "${worktree}" branch --show-current 2>/dev/null || echo "unknown"
}

_trace_get_session_dir() {
    if [[ -n "${AGENT_GUARD_SESSION_DIR}" ]]; then
        echo "${AGENT_GUARD_SESSION_DIR}"
        return 0
    fi
    local worktree
    worktree="$(_trace_get_worktree)"
    echo "${worktree}/.agent-guard/session"
}

# ---------------------------------------------------------------------------
# Inicialização
# ---------------------------------------------------------------------------

_trace_init() {
    local session_dir
    session_dir="$(_trace_get_session_dir)"
    mkdir -p "${session_dir}/current"
    mkdir -p "${session_dir}/checkpoints"

    local identity branch worktree
    identity="$(_trace_get_identity)"
    branch="$(_trace_get_branch)"
    worktree="$(_trace_get_worktree)"

    local session_json
    session_json="$(${AG_PYTHON} -c "
import json, sys
print(json.dumps({
    'identity': sys.argv[1],
    'branch': sys.argv[2],
    'worktree': sys.argv[3],
    'session_ref': sys.argv[4],
    'started_at': sys.argv[5],
    'version': '0.1.0-poc'
}, ensure_ascii=False))
" "${identity}" "${branch}" "${worktree}" "${AGENT_GUARD_SESSION_REF}" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" 2>/dev/null || echo '{}')"

    echo "${session_json}" > "${session_dir}/current/session.json"
}

# ---------------------------------------------------------------------------
# Redação de secrets (best-effort)
# ---------------------------------------------------------------------------

_trace_redact_secrets() {
    local input_text="${1:-}"
    if [[ -z "${input_text}" ]]; then
        echo ""
        return 0
    fi

    ${AG_PYTHON} -c "
import re, sys
text = sys.argv[1]
# AWS keys / tokens
patterns = [
    (r'AKIA[0-9A-Z]{16}', 'AKIA****'),
    (r'ASIA[0-9A-Z]{16}', 'ASIA****'),
    (r'sk-[a-zA-Z0-9]{48}', 'sk-****'),
    (r'ghp_[a-zA-Z0-9]{36}', 'ghp_****'),
    (r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}', '****@****'),
]
for pat, repl in patterns:
    text = re.sub(pat, repl, text)
print(text)
" "${input_text}" 2>/dev/null || echo "${input_text}"
}

# ---------------------------------------------------------------------------
# Escrita de eventos no transcript local
# ---------------------------------------------------------------------------

_trace_write_event() {
    local action="${1:-unknown}"
    local payload="${2:-}"
    if [[ -z "${payload}" ]]; then
        payload="{}"
    fi

    local session_dir
    session_dir="$(_trace_get_session_dir)"
    mkdir -p "${session_dir}/current"

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"

    local identity branch
    identity="$(_trace_get_identity)"
    branch="$(_trace_get_branch)"

    # Redige payload bruto antes de persistir.
    local redacted_payload
    redacted_payload="$(_trace_redact_secrets "${payload}")"

    local entry
    entry="$(${AG_PYTHON} -c "
import json, sys
entry = {
    'timestamp': sys.argv[1],
    'action': sys.argv[2],
    'identity': sys.argv[3],
    'branch': sys.argv[4],
    'payload': json.loads(sys.argv[5])
}
print(json.dumps(entry, ensure_ascii=False))
" "${timestamp}" "${action}" "${identity}" "${branch}" "${redacted_payload}" 2>/dev/null || echo '{\"timestamp\":\"'"${timestamp}"'\",\"action\":\"'"${action}"'\",\"error\":\"json_encode_failed\"}')"

    printf '%s\n' "${entry}" >> "${session_dir}/current/transcript.jsonl"
}

# ---------------------------------------------------------------------------
# Captura de estado do worktree
# ---------------------------------------------------------------------------

_trace_capture_state() {
    local worktree
    worktree="$(_trace_get_worktree)"

    local head_sha dirty_files stash_list branch
    head_sha="$(git -C "${worktree}" rev-parse --short HEAD 2>/dev/null || echo "")"
    dirty_files="$(git -C "${worktree}" status --porcelain 2>/dev/null || true)"
    stash_list="$(git -C "${worktree}" stash list 2>/dev/null || true)"
    branch="$(git -C "${worktree}" branch --show-current 2>/dev/null || echo "")"

    ${AG_PYTHON} -c "
import json, sys
print(json.dumps({
    'head': sys.argv[1],
    'branch': sys.argv[2],
    'dirty': sys.argv[3].splitlines() if sys.argv[3] else [],
    'stashes': sys.argv[4].splitlines() if sys.argv[4] else []
}, ensure_ascii=False))
" "${head_sha}" "${branch}" "${dirty_files}" "${stash_list}" 2>/dev/null || echo '{}'
}

# ---------------------------------------------------------------------------
# Checkpoint na ref Git dedicada
# ---------------------------------------------------------------------------

_trace_checkpoint() {
    local message="${1:-checkpoint}"
    local repo_root worktree session_dir
    repo_root="$(_trace_get_repo_root)"
    worktree="$(_trace_get_worktree)"
    session_dir="$(_trace_get_session_dir)"

    _trace_init >/dev/null 2>&1 || true

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"

    # Garante transcript atualizado com o checkpoint.
    local state
    state="$(_trace_capture_state)"
    _trace_write_event "checkpoint" "${state}" >/dev/null 2>&1 || true

    local identity branch
    identity="$(_trace_get_identity)"
    branch="$(_trace_get_branch)"

    local checkpoint_id
    checkpoint_id="$(date -u +%s)-$(printf '%s' "${identity}-${branch}" | sha256sum | cut -c1-8)"

    local tmp_dir
    tmp_dir="$(mktemp -d -t ag-checkpoint-XXXXXX)"
    trap 'rm -rf "${tmp_dir}"' RETURN

    local cp_dir="${tmp_dir}/${checkpoint_id}"
    mkdir -p "${cp_dir}"

    # Copia arquivos do trace atual.
    if [[ -f "${session_dir}/current/session.json" ]]; then
        cp "${session_dir}/current/session.json" "${cp_dir}/session.json"
    fi
    if [[ -f "${session_dir}/current/transcript.jsonl" ]]; then
        cp "${session_dir}/current/transcript.jsonl" "${cp_dir}/transcript.jsonl"
    fi

    # Estado do worktree.
    echo "${state}" > "${cp_dir}/state.json"

    # Task note do slot, se existir.
    local task_note
    task_note="${repo_root}/.agent-guard/tasks/${identity}.md"
    if [[ -f "${task_note}" ]]; then
        cp "${task_note}" "${cp_dir}/tasks.md"
    fi

    # Cria objetos Git sem alterar o working tree atual.
    local tree_sha commit_sha parent_sha
    parent_sha=""
    if git -C "${repo_root}" rev-parse --verify --quiet "${AGENT_GUARD_SESSION_REF}" >/dev/null 2>&1; then
        parent_sha="$(git -C "${repo_root}" rev-parse "${AGENT_GUARD_SESSION_REF}" 2>/dev/null || echo "")"
    fi

    # hash-object para cada arquivo e monta tree.
    tree_sha="$(_trace_build_tree "${repo_root}" "${cp_dir}")"
    if [[ -z "${tree_sha}" ]]; then
        echo "❌ session-trace: failed to build checkpoint tree" >&2
        return 1
    fi

    local commit_message
    commit_message="checkpoint: ${identity}@${branch} — ${message}"

    if [[ -n "${parent_sha}" ]]; then
        commit_sha="$(git -C "${repo_root}" commit-tree "${tree_sha}" -p "${parent_sha}" -m "${commit_message}" 2>/dev/null || echo "")"
    else
        commit_sha="$(git -C "${repo_root}" commit-tree "${tree_sha}" -m "${commit_message}" 2>/dev/null || echo "")"
    fi

    if [[ -z "${commit_sha}" ]]; then
        echo "❌ session-trace: failed to create checkpoint commit" >&2
        return 1
    fi

    # Atualiza a ref dedicada.
    git -C "${repo_root}" update-ref "${AGENT_GUARD_SESSION_REF}" "${commit_sha}" "${parent_sha}" 2>/dev/null || {
        echo "❌ session-trace: failed to update ${AGENT_GUARD_SESSION_REF}" >&2
        return 1
    }

    # Salva cópia local do checkpoint para acesso rápido.
    cp -r "${cp_dir}" "${session_dir}/checkpoints/${checkpoint_id}"

    # Registra no journal central.
    if command -v _journal_write_event >/dev/null 2>&1; then
        _journal_write_event "trace_checkpoint" "$(echo "{}" | ${AG_PYTHON} -c "import json,sys; print(json.dumps({'checkpoint_id':'${checkpoint_id}','sha':'${commit_sha}','ref':'${AGENT_GUARD_SESSION_REF}','message':'${message}'}))" 2>/dev/null || echo '{}')" >/dev/null 2>&1 || true
    fi

    echo "${checkpoint_id}"
}

# Constroi uma tree Git a partir de arquivos em um diretório.
# Recebe: repo_root, source_dir. Retorna: tree_sha.
_trace_build_tree() {
    local repo_root="$1"
    local source_dir="$2"

    # git mktree espera entradas: "<mode> <type> <sha>\t<file>\n"
    ${AG_PYTHON} - "${repo_root}" "${source_dir}" <<'PY' 2>/dev/null
import os, sys, subprocess
repo_root, source_dir = sys.argv[1:3]
entries = []
for root, _dirs, files in os.walk(source_dir):
    for f in sorted(files):
        full = os.path.join(root, f)
        rel = os.path.relpath(full, source_dir)
        # Normaliza path separador para forward slash.
        rel = rel.replace(os.sep, '/')
        sha = subprocess.run(
            ['git', '-C', repo_root, 'hash-object', '-w', full],
            capture_output=True, text=True, check=False
        ).stdout.strip()
        if sha:
            entries.append(f"100644 blob {sha}\t{rel}\n")
if not entries:
    sys.exit(0)
result = subprocess.run(
    ['git', '-C', repo_root, 'mktree'],
    input=''.join(entries), text=True, capture_output=True, check=False
)
if result.returncode != 0:
    sys.exit(1)
print(result.stdout.strip())
PY
}

# ---------------------------------------------------------------------------
# Heartbeat: gradação leve para evitar perda total
# ---------------------------------------------------------------------------

_trace_heartbeat() {
    local message="${1:-heartbeat}"
    local session_dir
    session_dir="$(_trace_get_session_dir)"

    _trace_write_event "heartbeat" "$(echo '{}' | ${AG_PYTHON} -c "import json,sys; print(json.dumps({'message':'${message}'}))" 2>/dev/null || echo '{}')" >/dev/null 2>&1 || true

    # Cria checkpoint físico a cada N heartbeats ou se houver diff desde o último.
    local heartbeat_count=0
    local counter_file="${session_dir}/current/.heartbeat_count"
    if [[ -f "${counter_file}" ]]; then
        heartbeat_count="$(cat "${counter_file}" 2>/dev/null || echo 0)"
    fi
    heartbeat_count=$((heartbeat_count + 1))
    echo "${heartbeat_count}" > "${counter_file}"

    local checkpoint_interval
    checkpoint_interval="${AGENT_GUARD_HEARTBEAT_INTERVAL:-6}"
    if [[ "${heartbeat_count}" -ge "${checkpoint_interval}" ]]; then
        heartbeat_count=0
        echo "${heartbeat_count}" > "${counter_file}"
        _trace_checkpoint "auto heartbeat checkpoint" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Listagem e resumo de checkpoints
# ---------------------------------------------------------------------------

_trace_list_checkpoints() {
    local repo_root
    repo_root="$(_trace_get_repo_root)"

    if ! git -C "${repo_root}" rev-parse --verify --quiet "${AGENT_GUARD_SESSION_REF}" >/dev/null 2>&1; then
        echo "No session trace ref found (${AGENT_GUARD_SESSION_REF})."
        return 0
    fi

    git -C "${repo_root}" log --format='%h|%ai|%s' "${AGENT_GUARD_SESSION_REF}" 2>/dev/null | while IFS='|' read -r hash date subject; do
        printf '%s | %s | %s\n' "${hash}" "${date}" "${subject}"
    done
}

_trace_last_checkpoint() {
    local repo_root
    repo_root="$(_trace_get_repo_root)"

    if ! git -C "${repo_root}" rev-parse --verify --quiet "${AGENT_GUARD_SESSION_REF}" >/dev/null 2>&1; then
        echo "No session trace ref found."
        return 1
    fi

    local commit_sha
    commit_sha="$(git -C "${repo_root}" rev-parse "${AGENT_GUARD_SESSION_REF}" 2>/dev/null || echo "")"
    if [[ -z "${commit_sha}" ]]; then
        echo "No checkpoint available."
        return 1
    fi

    echo "Last checkpoint: ${commit_sha}"
    git -C "${repo_root}" show --stat --oneline "${commit_sha}" 2>/dev/null || true
}
