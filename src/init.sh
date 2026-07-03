#!/usr/bin/env bash
#
# Agent Guard Session Init — Universal entry point for AI agents.
#
# Purpose:
#   - Ensure every agent operates inside an isolated worktree.
#   - Allocate an identity slot atomically.
#   - Create the official worktree and a timestamped branch when starting fresh.
#   - Reuse the current ia-<identity> branch when re-entering the same worktree.
#   - Allow explicit reattachment to an existing ia-<identity> branch.
#   - Block if the worktree contains foreign/uncommitted work.
#
# Usage:
#   source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} [prefix] [role] [--impact plugin1,plugin2]
#   source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} --attach ia-<identity>/<role>/<branch>
#   source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} --release
#   source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} --status
#   source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} --triage <prefix>
#
#   prefix: kimi | claude | gemini | grok
#   role:   ia-a | ia-b | ia-c
#
# This script is designed to be respected by any AI/IDE that operates on this
# repository, including VSCode forks (Kiro, Antigravity, Cursor) and CLI agents.
#
# v2.0.0 — independent from legacy lease scripts

# Strict mode for init (do not apply to user's interactive shell after sourcing)
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Detect mode: sourced vs executed directly
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "❌ This script must be sourced, not executed directly." >&2
    echo "   source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} <prefix> <role> [--impact plugin1,plugin2]" >&2
    echo "   source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} --attach ia-<identity>/<role>/<branch>" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Resolve repository root and guard config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The guard config lives at the repository root. The init script is shipped
# inside packages/agent-guard-core/src, so we walk up from SCRIPT_DIR until we
# find a git repository that owns agent-guard.yaml.
_resolve_repo_root() {
    local dir="$1"
    while [[ "${dir}" != "/" && -n "${dir}" ]]; do
        if [[ -d "${dir}/.git" || -f "${dir}/.git" ]]; then
            if [[ -f "${dir}/agent-guard.yaml" ]]; then
                echo "${dir}"
                return 0
            fi
        fi
        dir="$(dirname "${dir}")"
    done
    # Fallback: git common-dir from SCRIPT_DIR.
    local git_common_dir
    git_common_dir="$(git -C "${SCRIPT_DIR}" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "${git_common_dir}" = /* ]]; then
        echo "$(cd "$(dirname "${git_common_dir}")" && pwd)"
    else
        echo "$(cd "${SCRIPT_DIR}/${git_common_dir}/.." && pwd)"
    fi
}

_AG_REPO_ROOT="$(_resolve_repo_root "${SCRIPT_DIR}")"

AGENT_GUARD_CONFIG_BIN="${SCRIPT_DIR}/../bin/agent-guard-config"
AGENT_GUARD_CONFIG_BIN="$(cd "$(dirname "${AGENT_GUARD_CONFIG_BIN}")" && pwd)/$(basename "${AGENT_GUARD_CONFIG_BIN}")"

if [[ ! -f "${AGENT_GUARD_CONFIG_BIN}" ]]; then
    echo "❌ agent-guard-config not found at ${AGENT_GUARD_CONFIG_BIN}" >&2
    return 1 2>/dev/null || exit 1
fi

# Detect where agent-guard.yaml lives: prefer the main repo, fall back to the
# current worktree (required while the YAML is being developed in a worktree
# before it reaches the shared main repository).
_detect_config_root() {
    local candidates=("${_AG_REPO_ROOT}")
    local worktree_root
    worktree_root="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [[ -n "${worktree_root}" && "${worktree_root}" != "${_AG_REPO_ROOT}" ]]; then
        candidates+=("${worktree_root}")
    fi
    local cwd_root
    cwd_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [[ -n "${cwd_root}" && "${cwd_root}" != "${_AG_REPO_ROOT}" && "${cwd_root}" != "${worktree_root}" ]]; then
        candidates+=("${cwd_root}")
    fi
    for candidate in "${candidates[@]}"; do
        if [[ -f "${candidate}/agent-guard.yaml" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
    # Last resort: walk up from current dir looking for the config file.
    local dir="$(pwd)"
    while [[ "${dir}" != "/" && -n "${dir}" ]]; do
        if [[ -f "${dir}/agent-guard.yaml" ]]; then
            echo "${dir}"
            return 0
        fi
        dir="$(dirname "${dir}")"
    done
    echo "${_AG_REPO_ROOT}"
}

AGENT_GUARD_REPO_ROOT="$(_detect_config_root)"
export AGENT_GUARD_REPO_ROOT

# ---------------------------------------------------------------------------
# 1.6. Load session journal service
# ---------------------------------------------------------------------------
JOURNAL_SCRIPT="${SCRIPT_DIR}/journal.sh"
if [[ -f "${JOURNAL_SCRIPT}" ]]; then
    source "${JOURNAL_SCRIPT}"
fi

# ---------------------------------------------------------------------------
# 1.5. Ensure Kimi CLI wrapper is in place
# ---------------------------------------------------------------------------
# The wrapper is the entrypoint that redirects sessions to isolated worktrees.
# Kimi CLI self-updates replace ~/.kimi-code/bin/kimi with the real binary,
# silently disabling isolation. We restore it automatically if a versioned
# recovery script is available.
_ensure_kimi_wrapper() {
    local package_root
    package_root="$(_guard_get_str "paths.package_root" "packages/agent-guard-core")"

    local kimi_bin_dir
    kimi_bin_dir="$(_guard_get_str "wrappers.kimi.bin_dir" "${HOME}/.kimi-code/bin")"
    local kimi_bin="${kimi_bin_dir}/kimi"
    local recovery=""

    # Recovery script shipped with the agent-guard-core package.
    local package_recovery="${_AG_REPO_ROOT}/${package_root}/wrappers/kimi/recovery.sh"
    if [[ -f "${package_recovery}" ]]; then
        recovery="${package_recovery}"
    fi

    [[ ! -f "${kimi_bin}" ]] && return 0
    [[ -z "${recovery}" ]] && return 0

    # If kimi is already the wrapper, nothing to do.
    if head -n 5 "${kimi_bin}" 2>/dev/null | grep -q "Agent Guard — Kimi CLI Wrapper"; then
        return 0
    fi

    echo "🛡️  Agent Guard: wrapper missing or overwritten; attempting recovery..." >&2
    if bash "${recovery}" --repo-root "${_AG_REPO_ROOT}" >/tmp/ag-wrapper-recovery.log 2>&1; then
        echo "✅ Wrapper recovered successfully." >&2
    else
        echo "⚠️  Wrapper recovery failed. Log: /tmp/ag-wrapper-recovery.log" >&2
        echo "   Isolation may be compromised; restore the wrapper manually." >&2
    fi
}

# ---------------------------------------------------------------------------
# 2. Helper: read values from agent-guard.yaml (SSOT) via agent-guard-config
# ---------------------------------------------------------------------------
_guard_get() {
    bash "${AGENT_GUARD_CONFIG_BIN}" get "$@"
}

_guard_get_str() {
    _guard_get "$@" 2>/dev/null | sed 's/^None$//'
}

# Detect the identity name and slot from a worktree directory name using the
# configured worktree_prefix values. Returns "<identity_name> <slot>" or empty.
_detect_identity_from_worktree_name() {
    local worktree_name="$1"
    local prefixes=""
    local prefix identity_name
    for identity_name in $(bash "${AGENT_GUARD_CONFIG_BIN}" keys identities 2>/dev/null); do
        prefix="$(_guard_get_str "identities.${identity_name}.worktree_prefix" "")"
        if [[ -n "${prefix}" ]]; then
            if [[ -n "${prefixes}" ]]; then
                prefixes="${prefixes}|${prefix}"
            else
                prefixes="${prefix}"
            fi
        fi
    done
    if [[ -z "${prefixes}" ]]; then
        return 0
    fi
    local regex="^(${prefixes})([0-9]+)$"
    if [[ "${worktree_name}" =~ ${regex} ]]; then
        local matched_prefix="${BASH_REMATCH[1]}"
        local slot="${BASH_REMATCH[2]}"
        for identity_name in $(bash "${AGENT_GUARD_CONFIG_BIN}" keys identities 2>/dev/null); do
            prefix="$(_guard_get_str "identities.${identity_name}.worktree_prefix" "")"
            if [[ "${prefix}" == "${matched_prefix}" ]]; then
                echo "${identity_name} ${slot}"
                return 0
            fi
        done
    fi
}

_ensure_kimi_wrapper
unset -f _ensure_kimi_wrapper

MAIN_REPO=$(_guard_get_str "paths.main_repo" "")
if [[ -z "${MAIN_REPO}" ]]; then
    MAIN_REPO=$(_guard_get_str "worktrees.main_repo" "")
fi
BASE_DIR=$(_guard_get_str "paths.base_dir" "")
if [[ -z "${BASE_DIR}" ]]; then
    BASE_DIR=$(_guard_get_str "worktrees.base_dir" "")
fi
SESSION_STORAGE=$(_guard_get_str "paths.session_storage" "")
if [[ -z "${SESSION_STORAGE}" ]]; then
    SESSION_STORAGE=$(_guard_get_str "session.session_storage" "")
fi
if [[ -z "${SESSION_STORAGE}" ]]; then
    SESSION_STORAGE=$(_guard_get_str "session.lease_storage" "")
fi
SESSION_STORAGE="${SESSION_STORAGE:-.agent-guard/sessions}"

# ---------------------------------------------------------------------------
# 3. Helpers: session files
# ---------------------------------------------------------------------------
_get_session_file() {
    local identity="$1"
    local git_common_dir
    git_common_dir="$(git -C "${_AG_REPO_ROOT}" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    local main_repo
    if [[ "${git_common_dir}" = /* ]]; then
        main_repo="$(cd "$(dirname "${git_common_dir}")" && pwd)"
    else
        main_repo="$(cd "${_AG_REPO_ROOT}/${git_common_dir}/.." && pwd)"
    fi
    echo "${main_repo}/${SESSION_STORAGE}/${identity}.json"
}

_get_global_lock() {
    local git_common_dir
    git_common_dir="$(git -C "${_AG_REPO_ROOT}" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    local main_repo
    if [[ "${git_common_dir}" = /* ]]; then
        main_repo="$(cd "$(dirname "${git_common_dir}")" && pwd)"
    else
        main_repo="$(cd "${_AG_REPO_ROOT}/${git_common_dir}/.." && pwd)"
    fi
    local dir="${main_repo}/${SESSION_STORAGE}"
    mkdir -p "${dir}"
    echo "${dir}/.global.lock"
}

_is_pid_alive() {
    local pid="$1"
    [[ -z "${pid}" ]] && return 1
    kill -0 "${pid}" 2>/dev/null
}

_load_session_field() {
    local identity="$1"
    local field="$2"
    local session_file
    session_file="$(_get_session_file "${identity}")"
    if [[ -f "${session_file}" ]]; then
        python3 -c "import json,sys; d=json.load(open('${session_file}')); print(d.get('${field}',''))" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

_save_session() {
    local identity="$1"
    local status="$2"
    local role="$3"
    local branch="$4"
    local pid="$5"
    local worktree_path="$6"
    local impact_plugins="$7"

    local session_file
    session_file="$(_get_session_file "${identity}")"
    local dir
    dir="$(dirname "${session_file}")"
    mkdir -p "${dir}"

    export _AG_S_IDENTITY="${identity}"
    export _AG_S_STATUS="${status}"
    export _AG_S_ROLE="${role}"
    export _AG_S_BRANCH="${branch}"
    export _AG_S_PID="${pid}"
    export _AG_S_WORKTREE="${worktree_path}"
    export _AG_S_IMPACT="${impact_plugins}"
    export _AG_S_SESSION_FILE="${session_file}"

    python3 -c "
import json, os
role = os.environ.get('_AG_S_ROLE') or None
data = {
    'identity': os.environ['_AG_S_IDENTITY'],
    'status': os.environ['_AG_S_STATUS'],
    'role': role,
    'branch': os.environ['_AG_S_BRANCH'],
    'pid': int(os.environ['_AG_S_PID']),
    'timestamp': __import__('time').time(),
    'worktree_path': os.environ['_AG_S_WORKTREE'],
    'impact_plugins': json.loads(os.environ.get('_AG_S_IMPACT','[]'))
}
with open(os.environ['_AG_S_SESSION_FILE'], 'w') as f:
    json.dump(data, f, indent=2)
" >/dev/null 2>&1
    local py_exit=$?
    unset _AG_S_IDENTITY _AG_S_STATUS _AG_S_ROLE _AG_S_BRANCH _AG_S_PID _AG_S_WORKTREE _AG_S_IMPACT _AG_S_SESSION_FILE
    return ${py_exit}
}

_clear_session() {
    local identity="$1"
    local session_file
    session_file="$(_get_session_file "${identity}")"
    if [[ -f "${session_file}" ]]; then
        python3 -c "
import json
with open('${session_file}') as f:
    d = json.load(f)
d.update({'status':'free','role':None,'branch':'','pid':None,'timestamp':None,'worktree_path':'','impact_plugins':[]})
with open('${session_file}', 'w') as f:
    json.dump(d, f, indent=2)
" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------------------
# 4. Helper: atomic slot allocation
# ---------------------------------------------------------------------------
_acquire_slot() {
    local prefix="$1"
    local role="$2"
    local impact_plugins="$3"

    local max_slots
    max_slots="$(_guard_get "identities.${prefix}.slots" 2>/dev/null || echo "")"
    if [[ -z "${max_slots}" || "${max_slots}" == "None" ]]; then
        echo "❌ Unknown prefix '${prefix}' or missing slots in agent-guard.yaml" >&2
        return 1
    fi

    local global_lock
    global_lock="$(_get_global_lock)"
    touch "${global_lock}"

    local selected_identity=""
    local lock_fd=200

    # Acquire exclusive lock
    eval "exec ${lock_fd}>\"${global_lock}\""
    flock -x "${lock_fd}"

    # Clean stale sessions while locked
    for i in $(seq 1 "${max_slots}"); do
        local identity="${prefix}${i}"
        local session_file
        session_file="$(_get_session_file "${identity}")"
        if [[ -f "${session_file}" ]]; then
            local sess_status sess_pid
            sess_status="$(_load_session_field "${identity}" "status")"
            sess_pid="$(_load_session_field "${identity}" "pid")"
            if [[ "${sess_status}" == "active" ]]; then
                if ! _is_pid_alive "${sess_pid}"; then
                    _clear_session "${identity}"
                fi
            fi
        fi
    done

    # Find a free slot
    for i in $(seq 1 "${max_slots}"); do
        local identity="${prefix}${i}"
        local session_file
        session_file="$(_get_session_file "${identity}")"
        local current_status="free"
        if [[ -f "${session_file}" ]]; then
            current_status="$(_load_session_field "${identity}" "status")"
        fi
        if [[ "${current_status}" != "active" ]]; then
            selected_identity="${identity}"
            break
        fi
    done

    flock -u "${lock_fd}"
    eval "exec ${lock_fd}>&-"

    if [[ -z "${selected_identity}" ]]; then
        echo "❌ No free slots available for '${prefix}' (all ${max_slots} in use)." >&2
        return 1
    fi

    # Build branch name
    local date_str
    date_str="$(date +%Y%m%d-%H%M)"
    local branch_name="ia-${selected_identity}/${role}/task-${date_str}"

    echo "${selected_identity}"
    echo "${branch_name}"
    echo "${impact_plugins}"
}

# ---------------------------------------------------------------------------
# 5. Helper: worktree / branch setup
# ---------------------------------------------------------------------------
_get_worktree_path() {
    local identity="$1"
    local prefix="${identity%%[0-9]*}"
    local worktree_prefix
    worktree_prefix="$(_guard_get_str "identities.${prefix}.worktree_prefix")"
    echo "${BASE_DIR}/${worktree_prefix}${identity##*[a-z]}"
}

_set_git_author() {
    local identity="$1"
    local worktree_path="${2:-$(pwd)}"
    local prefix="${identity%%[0-9]*}"
    local slot="${identity##*[a-z]}"
    local author_email author_name
    author_email="$(_guard_get_str "identities.${prefix}.author_email")"
    author_name="$(_guard_get_str "identities.${prefix}.author_name")"
    author_email="${author_email//\{n\}/${slot}}"
    author_name="${author_name//\{n\}/${slot}}"

    export GIT_AUTHOR_NAME="${author_name}"
    export GIT_AUTHOR_EMAIL="${author_email}"
    export GIT_COMMITTER_NAME="${author_name}"
    export GIT_COMMITTER_EMAIL="${author_email}"

    # Export the identity to the configured environment variable. The canonical
    # default is AGENT_GUARD_IDENTITY.
    local identity_env_var
    identity_env_var="$(_guard_get_str "commit.identity_env_var" "AGENT_GUARD_IDENTITY")"
    if [[ -n "${identity_env_var}" ]]; then
        eval "export ${identity_env_var}=\"${identity}\""
    fi

    # Persistir identidade no config do proprio worktree para agentes CLI
    # cujo shell nao persiste entre tool calls (variaveis de ambiente morrem).
    # Usa --worktree para isolar a identidade no worktree ativo, evitando
    # poluir o .git/config do repositorio principal (compartilhado entre IAs).
    if [[ -d "${worktree_path}/.git" || -f "${worktree_path}/.git" ]]; then
        # Habilita extensao worktreeConfig se ainda nao estiver ativa.
        git -C "${worktree_path}" config --local extensions.worktreeConfig true >/dev/null 2>&1 || true
        git -C "${worktree_path}" config --worktree user.name "${author_name}" >/dev/null 2>&1 || true
        git -C "${worktree_path}" config --worktree user.email "${author_email}" >/dev/null 2>&1 || true
    fi
}

# Export session environment variables using AGENT_GUARD_* canonical names.
_export_session_env() {
    local worktree_path="$1"
    local branch="$2"
    local impact_plugins="$3"

    export AGENT_GUARD_WORKTREE_PATH="${worktree_path}"
    export AGENT_GUARD_BRANCH="${branch}"
    export AGENT_GUARD_IMPACT_PLUGINS="${impact_plugins}"
}

# Ensure the Git worktreeConfig extension is enabled in the main repository.
# This must be done before per-worktree configs (like core.hooksPath) are set.
_ensure_worktree_config_extension() {
    local repo_root="$1"
    local enabled
    enabled="$(git -C "${repo_root}" config --local --get extensions.worktreeConfig 2>/dev/null || echo "")"
    if [[ "${enabled}" != "true" ]]; then
        git -C "${repo_root}" config --local extensions.worktreeConfig true >/dev/null 2>&1 || true
    fi
}

_configure_hooks_path() {
    local worktree_path="$1"
    local worktree_hooks_path="${worktree_path}/.githooks"
    local current_hooks_path

    # Ensure the extension is enabled before using --worktree config.
    _ensure_worktree_config_extension "${_AG_REPO_ROOT}"

    # Cada worktree deve usar seus proprios hooks (versionados no repo), nunca os
    # do repo principal, para garantir que atualizacoes de hooks via PR sejam
    # testadas no proprio worktree antes de afetar todos.
    current_hooks_path="$(git -C "${worktree_path}" config --worktree --get core.hooksPath 2>/dev/null || echo "")"
    if [[ "${current_hooks_path}" != "${worktree_hooks_path}" ]]; then
        git -C "${worktree_path}" config --worktree core.hooksPath "${worktree_hooks_path}" >/dev/null 2>&1 || true
        echo "🔒 core.hooksPath configured: ${worktree_hooks_path}" >&2
    fi
}

_anti_stale_check() {
    local worktree_path="$1"
    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"
    if [[ -z "${current_branch}" || "${current_branch}" == "develop" ]]; then
        return 0
    fi
    git -C "${worktree_path}" fetch origin develop >/dev/null 2>&1 || true
    local behind_count
    behind_count="$(git -C "${worktree_path}" rev-list --count "HEAD..origin/develop" 2>/dev/null || echo "0")"
    if [[ -n "${behind_count}" && "${behind_count}" -gt 10 ]]; then
        echo "" >&2
        echo "⚠️⚠️⚠️  ALERT: BRANCH STALE (>10 commits behind origin/develop)  ⚠️⚠️⚠️" >&2
        echo "" >&2
        echo "   Branch '${current_branch}' is ${behind_count} commits behind origin/develop." >&2
        echo "   Rule: rebase before continuing." >&2
        echo "" >&2
        echo "   Run:" >&2
        echo "     git fetch origin" >&2
        echo "     git rebase origin/develop" >&2
        echo "     git push --force-with-lease" >&2
        echo "" >&2
    fi
}

_session_audit() {
    local worktree_path="$1"
    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "unknown")"
    local stash_count
    stash_count="$(git -C "${worktree_path}" stash list 2>/dev/null | grep -c "On ${current_branch}:" || true)"
    if [[ "${stash_count}" -gt 0 ]]; then
        echo "" >&2
        echo "⚠️⚠️⚠️  WARNING: ${stash_count} STASH(ES) ON BRANCH '${current_branch}'  ⚠️⚠️⚠️" >&2
        echo "" >&2
        git -C "${worktree_path}" stash list | grep "On ${current_branch}:" | sed 's/^/   /' >&2
        echo "" >&2
        echo "   Inspect before continuing: git stash show -p stash@{<n>}" >&2
        echo "" >&2
    else
        echo "✅ No stashes on branch '${current_branch}'." >&2
    fi
}

# Resolve the best available base ref for creating worktrees/branches.
# Prefers origin/<base_branch>, then local <base_branch>, then common fallbacks.
_resolve_base_ref() {
    local base_branch
    base_branch="$(_guard_get_str "git.base_branch" "develop")"
    if git -C "${_AG_REPO_ROOT}" rev-parse --verify --quiet "origin/${base_branch}" >/dev/null 2>&1; then
        echo "origin/${base_branch}"
        return 0
    fi
    if git -C "${_AG_REPO_ROOT}" rev-parse --verify --quiet "${base_branch}" >/dev/null 2>&1; then
        echo "${base_branch}"
        return 0
    fi
    for fallback in develop main master; do
        if git -C "${_AG_REPO_ROOT}" rev-parse --verify --quiet "origin/${fallback}" >/dev/null 2>&1; then
            echo "origin/${fallback}"
            return 0
        fi
        if git -C "${_AG_REPO_ROOT}" rev-parse --verify --quiet "${fallback}" >/dev/null 2>&1; then
            echo "${fallback}"
            return 0
        fi
    done
    echo ""
}

_create_or_reuse_worktree() {
    local identity="$1"
    local branch_name="$2"

    local worktree_path
    worktree_path="$(_get_worktree_path "${identity}")"
    local base_ref
    base_ref="$(_resolve_base_ref)"
    if [[ -z "${base_ref}" ]]; then
        echo "❌ No base branch found to create worktree from." >&2
        echo "   Create at least one commit on the base branch configured in agent-guard.yaml." >&2
        return 1
    fi

    if [[ ! -e "${worktree_path}/.git" ]]; then
        echo "🌿 Creating isolated worktree: ${worktree_path}" >&2
        git -C "${_AG_REPO_ROOT}" worktree add "${worktree_path}" -b "${branch_name}" "${base_ref}" >/dev/null 2>&1 || \
            git -C "${_AG_REPO_ROOT}" worktree add "${worktree_path}" "${branch_name}" >/dev/null 2>&1
    else
        echo "🌿 Existing worktree found: ${worktree_path}" >&2
        cd "${worktree_path}" || return 1
        git fetch origin >/dev/null 2>&1 || true

        local current_wt_branch
        current_wt_branch="$(git branch --show-current 2>/dev/null || echo "")"
        local identity_prefix="ia-${identity}/"

        if [[ -n "${current_wt_branch}" && "${current_wt_branch}" == ${identity_prefix}* ]]; then
            echo "🔄 Reusing existing branch '${current_wt_branch}' (v4.0)." >&2
            branch_name="${current_wt_branch}"
        else
            echo "🌿 Creating new branch: ${branch_name}" >&2
            git checkout -b "${branch_name}" "${base_ref}" >/dev/null 2>&1 || git checkout "${branch_name}" >/dev/null 2>&1 || true
        fi
    fi

    cd "${worktree_path}" || return 1

    # Dirty check
    local dirty
    dirty="$(git status --porcelain 2>/dev/null || true)"
    if [[ -n "${dirty}" ]]; then
        echo "" >&2
        echo "❌❌❌ ERROR: WORKING TREE DIRTY ❌❌❌" >&2
        echo "" >&2
        echo "${dirty}" | sed 's/^/  /' >&2
        echo "" >&2
        echo "   Commit or stash before acquiring a session." >&2
        echo "" >&2
        return 1
    fi

    _configure_hooks_path "${worktree_path}"
    _anti_stale_check "${worktree_path}"
    _session_audit "${worktree_path}"

    echo "${worktree_path}"
    echo "${branch_name}"
}

# ---------------------------------------------------------------------------
# 6. Parse arguments
# ---------------------------------------------------------------------------
ATTACH_BRANCH=""
PREFIX=""
ROLE=""
IMPACT_PLUGINS=""
USE_WORKTREE="true"
MODE="acquire"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --attach)
            if [[ -n "${2:-}" ]]; then
                ATTACH_BRANCH="$2"
                MODE="attach"
                shift 2
            else
                echo "❌ --attach requires a branch name." >&2
                return 1 2>/dev/null || exit 1
            fi
            ;;
        --release)
            MODE="release"
            shift
            ;;
        --status)
            MODE="status"
            shift
            ;;
        --triage)
            if [[ -n "${2:-}" ]]; then
                PREFIX="$2"
                MODE="triage"
                shift 2
            else
                echo "❌ --triage requires a prefix." >&2
                return 1 2>/dev/null || exit 1
            fi
            ;;
        --impact)
            if [[ -n "${2:-}" ]]; then
                IMPACT_PLUGINS="$2"
                shift 2
            else
                echo "❌ --impact requires a comma-separated plugin list." >&2
                return 1 2>/dev/null || exit 1
            fi
            ;;
        --impact=*)
            IMPACT_PLUGINS="${1#--impact=}"
            shift
            ;;
        --no-worktree)
            USE_WORKTREE="false"
            shift
            ;;
        -*)
            echo "❌ Unknown option: $1" >&2
            return 1 2>/dev/null || exit 1
            ;;
        *)
            if [[ -z "${PREFIX}" ]]; then
                PREFIX="$1"
            elif [[ -z "${ROLE}" ]]; then
                ROLE="$1"
            fi
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helper: validate worktree is in a neutral state before release
# ---------------------------------------------------------------------------
_validate_worktree_release_ready() {
    local worktree_path="$1"

    if [[ -z "${worktree_path}" ]]; then
        echo "❌ Cannot determine worktree path." >&2
        return 1
    fi

    if [[ ! -e "${worktree_path}/.git" ]]; then
        echo "❌ Worktree '${worktree_path}' does not appear to be a git worktree." >&2
        return 1
    fi

    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"
    if [[ "${current_branch}" != "develop" ]]; then
        echo "" >&2
        echo "❌❌❌ ERROR: WORKTREE NOT ON 'develop' ❌❌❌" >&2
        echo "" >&2
        echo "   Current branch: ${current_branch:-<detached>}" >&2
        echo "   Release is only allowed when the worktree is on 'develop'." >&2
        echo "" >&2
        echo "   Required actions before release:" >&2
        echo "     1. Commit or stash any unfinished work on your task branch." >&2
        echo "     2. Push your branch and ensure PR is open/merged." >&2
        echo "     3. Run: git checkout develop" >&2
        echo "" >&2
        return 1
    fi

    local dirty_files
    dirty_files="$(git -C "${worktree_path}" status --porcelain 2>/dev/null || true)"
    if [[ -n "${dirty_files}" ]]; then
        echo "" >&2
        echo "❌❌❌ ERROR: WORKING TREE DIRTY ❌❌❌" >&2
        echo "" >&2
        echo "${dirty_files}" | sed 's/^/   /' >&2
        echo "" >&2
        echo "   Commit, stash, or remove these changes before releasing." >&2
        echo "" >&2
        return 1
    fi

    local stash_count
    stash_count="$(git -C "${worktree_path}" stash list 2>/dev/null | grep -c '^stash@{' || true)"
    if [[ "${stash_count}" -gt 0 ]]; then
        echo "" >&2
        echo "❌❌❌ ERROR: WORKTREE HAS STASHES ❌❌❌" >&2
        echo "" >&2
        git -C "${worktree_path}" stash list | sed 's/^/   /' >&2
        echo "" >&2
        echo "   Apply, drop, or move these stashes before releasing." >&2
        echo "   Stash is not a trash can — inspect with: git stash show -p stash@{<n>}" >&2
        echo "" >&2
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# 7. --release mode
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "release" ]]; then
    CURRENT_DIR="$(pwd)"
    CURRENT_IDENTITY=""
    CURRENT_WORKTREE=""
    if git -C "${CURRENT_DIR}" rev-parse --show-toplevel >/dev/null 2>&1; then
        CURRENT_WORKTREE="$(git -C "${CURRENT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "")"
        wt_name="$(basename "${CURRENT_WORKTREE}")"
        CURRENT_IDENTITY="$(_detect_identity_from_worktree_name "${wt_name}" | awk '{print $1 $2}')"
    fi

    if [[ -z "${CURRENT_IDENTITY}" ]]; then
        echo "❌ Cannot determine identity. Run from an agent worktree." >&2
        return 1 2>/dev/null || exit 1
    fi

    if ! _validate_worktree_release_ready "${CURRENT_WORKTREE}"; then
        echo "🔒 Session NOT released. Resolve the issues above and run --release again." >&2
        return 1 2>/dev/null || exit 1
    fi

    _clear_session "${CURRENT_IDENTITY}"

    # Record release in session journal for crash recovery.
    if command -v _journal_release >/dev/null 2>&1; then
        _journal_release
    fi

    # After releasing the lease, move the worktree to a neutral branch so
    # that 'develop' is not held by an idle worktree. Git does not allow the
    # same branch to be checked out in multiple worktrees; leaving 'develop'
    # behind blocks other agents from releasing their sessions.
    NEUTRAL_BRANCH="_released/${CURRENT_IDENTITY}"
    BASE_REF=""
    if git -C "${CURRENT_WORKTREE}" rev-parse --verify --quiet "origin/develop" >/dev/null 2>&1; then
        BASE_REF="origin/develop"
    elif git -C "${CURRENT_WORKTREE}" rev-parse --verify --quiet "develop" >/dev/null 2>&1; then
        BASE_REF="develop"
    fi

    if [[ -n "${BASE_REF}" ]]; then
        if ! git -C "${CURRENT_WORKTREE}" checkout -B "${NEUTRAL_BRANCH}" "${BASE_REF}" >/dev/null 2>&1; then
            git -C "${CURRENT_WORKTREE}" checkout --detach "${BASE_REF}" >/dev/null 2>&1 || true
        fi
    fi

    echo "🔓 Released session for ${CURRENT_IDENTITY}"
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# 8. --status mode
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "status" ]]; then
    echo ""
    echo "=========================================================="
    echo "🛡️  Agent Guard — Session Status"
    echo "=========================================================="
    printf "%-12s | %-8s | %-6s | %-8s | %-6s | %-40s\n" "Agent" "Status" "Role" "PID" "WT" "Branch"
    echo "----------------------------------------------------------"

    identity_list="$(bash "${AGENT_GUARD_CONFIG_BIN}" keys identities)"
    for prefix in ${identity_list}; do
        [[ -z "${prefix}" ]] && continue
        max_slots="$(_guard_get "identities.${prefix}.slots")"
        for i in $(seq 1 "${max_slots}"); do
            identity="${prefix}${i}"
            session_file="$(_get_session_file "${identity}")"
            if [[ -f "${session_file}" ]]; then
                status="$(_load_session_field "${identity}" "status")"
                role="$(_load_session_field "${identity}" "role")"
                pid="$(_load_session_field "${identity}" "pid")"
                branch="$(_load_session_field "${identity}" "branch")"
            else
                status="free"
                role=""
                pid=""
                branch=""
            fi
            worktree_path="$(_get_worktree_path "${identity}")"
            wt_ok="❌"
            [[ -e "${worktree_path}/.git" ]] && wt_ok="✅"
            pid_alive=""
            if [[ "${status}" == "active" && -n "${pid}" ]]; then
                if _is_pid_alive "${pid}"; then
                    pid_alive=" (live)"
                else
                    pid_alive=" (dead)"
                fi
            fi
            printf "%-12s | %-8s | %-6s | %-8s | %-6s | %-40s\n" \
                "${identity}" "${status:-free}" "${role:-}" "${pid}${pid_alive}" "${wt_ok}" "${branch:-}"
        done
    done
    echo "=========================================================="
    echo ""
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# 9. --triage mode
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "triage" ]]; then
    local triage_script="${_AG_REPO_ROOT}/${PACKAGE_ROOT}/ci/branch-triage.sh"
    if [[ -f "${triage_script}" ]]; then
        bash "${triage_script}" "${PREFIX}"
    else
        echo "⚠️  branch-triage.sh not found." >&2
        return 1 2>/dev/null || exit 1
    fi
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# 10. --attach mode
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "attach" ]]; then
    if [[ ! "${ATTACH_BRANCH}" =~ ^ia-[a-z]+[0-9]+/ ]]; then
        echo "❌ --attach branch must start with 'ia-<identity>/'." >&2
        return 1 2>/dev/null || exit 1
    fi

    IDENTITY_FROM_BRANCH="${ATTACH_BRANCH#ia-}"
    IDENTITY_FROM_BRANCH="${IDENTITY_FROM_BRANCH%%/*}"
    WORKTREE_PATH="$(_get_worktree_path "${IDENTITY_FROM_BRANCH}")"

    if [[ ! -d "${WORKTREE_PATH}" ]]; then
        echo "❌ Worktree for identity '${IDENTITY_FROM_BRANCH}' does not exist." >&2
        return 1 2>/dev/null || exit 1
    fi

    cd "${WORKTREE_PATH}" || return 1 2>/dev/null || exit 1
    git fetch origin >/dev/null 2>&1 || true

    if ! git show-ref --verify --quiet "refs/heads/${ATTACH_BRANCH}"; then
        echo "❌ Branch '${ATTACH_BRANCH}' does not exist locally." >&2
        return 1 2>/dev/null || exit 1
    fi

    git checkout "${ATTACH_BRANCH}"

    DIRTY_FILES="$(git status --porcelain 2>/dev/null || true)"
    if [[ -n "${DIRTY_FILES}" ]]; then
        echo ""
        echo "⚠️  Working tree has uncommitted changes:"
        echo "${DIRTY_FILES}" | sed 's/^/   /'
        echo ""
    fi

    _set_git_author "${IDENTITY_FROM_BRANCH}" "${WORKTREE_PATH}"
    _export_session_env "${WORKTREE_PATH}" "${ATTACH_BRANCH}" "${IMPACT_PLUGINS}"

    _configure_hooks_path "${WORKTREE_PATH}"
    _anti_stale_check "${WORKTREE_PATH}"
    _session_audit "${WORKTREE_PATH}"

    impact_json="$(echo "${IMPACT_PLUGINS}" | python3 -c "import sys,json; print(json.dumps([p.strip() for p in sys.stdin.read().split(',') if p.strip()]))" 2>/dev/null || echo "[]")"
    _save_session "${IDENTITY_FROM_BRANCH}" "active" "${ROLE}" "${ATTACH_BRANCH}" "$$" "${WORKTREE_PATH}" "${impact_json}"

    if command -v _journal_attach >/dev/null 2>&1; then
        _journal_attach "${ATTACH_BRANCH}"
    fi

    echo "🛡️  Agent Guard: attached to ${ATTACH_BRANCH}"
    echo "   Identity: ${IDENTITY_FROM_BRANCH}"
    echo "   Worktree: ${WORKTREE_PATH}"
    echo "✅ Git author set to ${GIT_AUTHOR_EMAIL}"
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# 11. Detect current worktree / identity from CWD (reuse mode)
# ---------------------------------------------------------------------------
CURRENT_DIR="$(pwd)"
CURRENT_WORKTREE=""
CURRENT_IDENTITY=""
CURRENT_BRANCH=""

if git -C "${CURRENT_DIR}" rev-parse --show-toplevel >/dev/null 2>&1; then
    CURRENT_WORKTREE="$(git -C "${CURRENT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "")"
    CURRENT_BRANCH="$(git -C "${CURRENT_DIR}" branch --show-current 2>/dev/null || echo "")"

    if [[ -n "${CURRENT_WORKTREE}" ]]; then
        wt_name="$(basename "${CURRENT_WORKTREE}")"
        CURRENT_IDENTITY="$(_detect_identity_from_worktree_name "${wt_name}" | awk '{print $1 $2}')"
    fi
fi

# ---------------------------------------------------------------------------
# 12. Reuse branch when already inside an agent worktree
# ---------------------------------------------------------------------------
if [[ -n "${CURRENT_IDENTITY}" && -n "${CURRENT_BRANCH}" ]]; then
    echo "🛡️  Agent Guard: reusing worktree ${CURRENT_WORKTREE}"
    echo "   Identity: ${CURRENT_IDENTITY}"
    echo "   Branch:   ${CURRENT_BRANCH}"

    # Guard against another live process already holding this worktree.
    # This can happen when a previous session released the lease file but
    # its process is still alive, or when the wrapper races between sessions.
    existing_pid="$(_load_session_field "${CURRENT_IDENTITY}" "pid")"
    existing_status="$(_load_session_field "${CURRENT_IDENTITY}" "status")"
    if [[ "${existing_status}" == "active" && -n "${existing_pid}" && "${existing_pid}" != "$$" ]]; then
        if _is_pid_alive "${existing_pid}"; then
            echo ""
            echo "❌❌❌ ERROR: WORKTREE ALREADY IN USE ❌❌❌" >&2
            echo "" >&2
            echo "   Identity '${CURRENT_IDENTITY}' is already held by PID ${existing_pid}." >&2
            echo "   Worktree: ${CURRENT_WORKTREE}" >&2
            echo "" >&2
            echo "   Possible causes:" >&2
            echo "     - A previous session released the lease but its process is still running." >&2
            echo "     - Another terminal/chat is using this worktree." >&2
            echo "" >&2
            echo "   Resolution:" >&2
            echo "     1. Find the other session and close it, OR" >&2
            echo "     2. Start from ${MAIN_REPO} to get a free worktree, OR" >&2
            echo "     3. Use --attach to explicitly reattach to your own branch." >&2
            echo "" >&2
            return 1 2>/dev/null || exit 1
        fi
    fi

    DIRTY_FILES="$(git -C "${CURRENT_WORKTREE}" status --porcelain 2>/dev/null || true)"
    if [[ -n "${DIRTY_FILES}" ]]; then
        echo ""
        echo "⚠️  Working tree has uncommitted changes:"
        echo "${DIRTY_FILES}" | sed 's/^/   /'
        echo ""
    fi

    _set_git_author "${CURRENT_IDENTITY}" "${CURRENT_WORKTREE}"
    _export_session_env "${CURRENT_WORKTREE}" "${CURRENT_BRANCH}" "${IMPACT_PLUGINS}"

    _configure_hooks_path "${CURRENT_WORKTREE}"
    _anti_stale_check "${CURRENT_WORKTREE}"
    _session_audit "${CURRENT_WORKTREE}"

    impact_json="$(echo "${IMPACT_PLUGINS}" | python3 -c "import sys,json; print(json.dumps([p.strip() for p in sys.stdin.read().split(',') if p.strip()]))" 2>/dev/null || echo "[]")"
    _save_session "${CURRENT_IDENTITY}" "active" "${ROLE}" "${CURRENT_BRANCH}" "$$" "${CURRENT_WORKTREE}" "${impact_json}"

    if command -v _journal_init >/dev/null 2>&1; then
        _journal_init
    fi

    echo "✅ Git author set to ${GIT_AUTHOR_EMAIL}"
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# 13. New session: validate args and acquire slot
# ---------------------------------------------------------------------------
if [[ -z "${PREFIX}" || -z "${ROLE}" ]]; then
    echo "❌ Not inside an agent worktree. Provide prefix and role:" >&2
    echo "   source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} <prefix> <role> [--impact plugin1,plugin2]" >&2
    return 1 2>/dev/null || exit 1
fi

if [[ "${ROLE}" != "ia-a" && "${ROLE}" != "ia-b" && "${ROLE}" != "ia-c" ]]; then
    echo "❌ Invalid role '${ROLE}'. Use ia-a, ia-b, or ia-c." >&2
    return 1 2>/dev/null || exit 1
fi

if [[ -z "$(bash "${AGENT_GUARD_CONFIG_BIN}" get "identities.${PREFIX}.slots" "")" ]]; then
    echo "❌ Unknown prefix '${PREFIX}'. Check agent-guard.yaml." >&2
    return 1 2>/dev/null || exit 1
fi

# Block direct work on main repo unless invoked through the official stub,
# which is the supported entry point for acquiring a new session.
if [[ "${CURRENT_WORKTREE}" == "${MAIN_REPO}" && "${AGENT_GUARD_FROM_STUB:-}" != "1" ]]; then
    echo "❌ Direct work on the main repository is reserved for humans and deploy." >&2
    echo "   Acquire a session to use an isolated worktree." >&2
    return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# 14. Acquire slot atomically
# ---------------------------------------------------------------------------
ALLOCATION="$(_acquire_slot "${PREFIX}" "${ROLE}" "${IMPACT_PLUGINS}")"
if [[ $? -ne 0 ]]; then
    echo "${ALLOCATION}" >&2
    return 1 2>/dev/null || exit 1
fi

IDENTITY="$(echo "${ALLOCATION}" | sed -n '1p')"
BRANCH_NAME="$(echo "${ALLOCATION}" | sed -n '2p')"
IMPACT_PLUGINS="$(echo "${ALLOCATION}" | sed -n '3p')"

# ---------------------------------------------------------------------------
# 15. Create / reuse worktree
# ---------------------------------------------------------------------------
if [[ "${USE_WORKTREE}" == "true" ]]; then
    WORKTREE_RESULT="$(_create_or_reuse_worktree "${IDENTITY}" "${BRANCH_NAME}")"
    if [[ $? -ne 0 ]]; then
        echo "${WORKTREE_RESULT}" >&2
        return 1 2>/dev/null || exit 1
    fi
    WORKTREE_PATH="$(echo "${WORKTREE_RESULT}" | sed -n '1p')"
    BRANCH_NAME="$(echo "${WORKTREE_RESULT}" | sed -n '2p')"
    cd "${WORKTREE_PATH}" || return 1 2>/dev/null || exit 1
else
    # Deprecated shared mode: create branch in current repo
    git -C "${_AG_REPO_ROOT}" checkout -b "${BRANCH_NAME}" origin/develop 2>/dev/null || \
        git -C "${_AG_REPO_ROOT}" checkout -b "${BRANCH_NAME}" 2>/dev/null
    WORKTREE_PATH="${_AG_REPO_ROOT}"
fi

# ---------------------------------------------------------------------------
# 16. Activate session and set author
# ---------------------------------------------------------------------------
_set_git_author "${IDENTITY}" "${WORKTREE_PATH}"
_export_session_env "${WORKTREE_PATH}" "${BRANCH_NAME}" "${IMPACT_PLUGINS}"

impact_json="$(echo "${IMPACT_PLUGINS}" | python3 -c "import sys,json; print(json.dumps([p.strip() for p in sys.stdin.read().split(',') if p.strip()]))" 2>/dev/null || echo "[]")"
_save_session "${IDENTITY}" "active" "${ROLE}" "${BRANCH_NAME}" "$$" "${WORKTREE_PATH}" "${impact_json}"


    if command -v _journal_init >/dev/null 2>&1; then
        _journal_init
    fi

# Soft-lock overlap warning
if [[ -n "${IMPACT_PLUGINS}" ]]; then
    echo "🔍 Checking for overlapping impact plugins..."
    session_dir="$(dirname "$(_get_session_file "${IDENTITY}")")"
    for other_file in "${session_dir}"/*.json; do
        [[ -e "${other_file}" ]] || continue
        other_identity="$(basename "${other_file}" .json)"
        [[ "${other_identity}" == "${IDENTITY}" ]] && continue
        [[ "${other_identity}" == ".global" ]] && continue
        other_status="$(_load_session_field "${other_identity}" "status")"
        [[ "${other_status}" != "active" ]] && continue
        other_plugins="$(_load_session_field "${other_identity}" "impact_plugins")"
        [[ -z "${other_plugins}" ]] && continue
        overlap="$(echo "${IMPACT_PLUGINS},${other_plugins}" | tr ',' '\n' | sort | uniq -d | tr '\n' ',' | sed 's/,$//')"
        if [[ -n "${overlap}" ]]; then
            echo "⚠️  Agent '${other_identity}' is also active on plugins: ${overlap}"
            echo "    Synchronize before committing to avoid regression."
        fi
    done
fi

echo ""
echo "=========================================================="
echo "🛡️  Agent Guard: session acquired"
echo "=========================================================="
echo "Identity:   ${IDENTITY}"
echo "Role:       ${ROLE}"
echo "Branch:     ${BRANCH_NAME}"
echo "Email:      ${GIT_AUTHOR_EMAIL}"
echo "Worktree:   ${WORKTREE_PATH}"
echo "=========================================================="
echo ""
echo "To release the session, run: source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} --release"
echo ""

return 0 2>/dev/null || exit 0
