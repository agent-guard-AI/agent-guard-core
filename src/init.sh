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
#   source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} --adopt <identity>
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

# Resolve a usable Python interpreter cross-platform.
AG_PYTHON="$(bash "${SCRIPT_DIR}/../bin/agent-guard-python" 2>/dev/null || echo "python3")"
export AG_PYTHON

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
    if ! kill -0 "${pid}" 2>/dev/null; then
        return 1
    fi
    # Reject processes that are alive in kernel terms but not actually runnable:
    # T (traced/stopped), Z (zombie), X/x (dead). These are common symptoms of
    # a crashed parent or a debugger left behind after a frontend/OS crash.
    local proc_stat
    proc_stat="$(sed -n 's/.*) \([A-Za-z]\).*/\1/p' "/proc/${pid}/stat" 2>/dev/null || echo "")"
    case "${proc_stat}" in
        T|Z|X|x)
            return 1
            ;;
    esac
    return 0
}

# Return 0 if the PID belongs to a healthy, runnable process.
# Differs from _is_pid_alive only in messaging intent; kept separate so callers
# can distinguish "kernel signal works" from "process is in a good state".
_is_pid_healthy() {
    _is_pid_alive "$1"
}

# Reconcile session file with the actual state of the worktree and process.
# Sets the following variables in the caller's scope:
#   _rec_status, _rec_role, _rec_pid, _rec_branch, _rec_worktree,
#   _rec_health, _rec_drift
# _rec_health is one of: live, dead, stale, orphan, drift, -
# _rec_drift is a short human-readable description of any inconsistency.
_status_reconcile_session() {
    local identity="$1"
    local session_file
    session_file="$(_get_session_file "${identity}")"

    _rec_status="$(_load_session_field "${identity}" "status")"
    _rec_role="$(_load_session_field "${identity}" "role")"
    _rec_pid="$(_load_session_field "${identity}" "pid")"
    _rec_branch="$(_load_session_field "${identity}" "branch")"
    _rec_worktree="$(_load_session_field "${identity}" "worktree_path")"
    _rec_health="-"
    _rec_drift=""

    local expected_worktree
    expected_worktree="$(_get_worktree_path "${identity}")"

    # If there is no session file at all, the slot is free regardless of
    # whether a worktree happens to exist on disk.
    if [[ ! -f "${session_file}" ]]; then
        _rec_status="free"
        return
    fi

    # If the session file claims the slot is free, trust it unless the
    # worktree is on a task branch or has dirty files — that is a drift.
    if [[ "${_rec_status}" != "active" ]]; then
        if [[ -e "${expected_worktree}/.git" ]]; then
            local actual_branch
            actual_branch="$(git -C "${expected_worktree}" branch --show-current 2>/dev/null || true)"
            local dirty
            dirty="$(git -C "${expected_worktree}" status --porcelain 2>/dev/null || true)"
            if [[ "${actual_branch}" == "ia-${identity}/"* || -n "${dirty}" ]]; then
                _rec_health="drift"
                _rec_drift="released session with active work"
                _rec_branch="${actual_branch}"
            fi
        fi
        return
    fi

    # Active session: validate process health.
    local pid_health="-"
    if [[ -n "${_rec_pid}" ]]; then
        if _is_pid_alive "${_rec_pid}"; then
            pid_health="live"
        else
            pid_health="dead"
        fi
    fi

    # Validate worktree path matches the configured path.
    local worktree_drift=""
    if [[ -n "${_rec_worktree}" && "${_rec_worktree}" != "${expected_worktree}" ]]; then
        worktree_drift="worktree path mismatch"
    fi

    # Validate branch matches the actual worktree branch.
    local branch_drift=""
    local actual_branch=""
    if [[ -e "${expected_worktree}/.git" ]]; then
        actual_branch="$(git -C "${expected_worktree}" branch --show-current 2>/dev/null || true)"
        if [[ -n "${actual_branch}" && "${actual_branch}" != "${_rec_branch}" ]]; then
            branch_drift="branch mismatch"
            # Reconcile the session file so subsequent reads are correct.
            if _save_session_field "${identity}" "branch" "${actual_branch}"; then
                _rec_branch="${actual_branch}"
            fi
        fi
    fi

    # Determine final health label.
    if [[ "${pid_health}" == "dead" ]]; then
        _rec_health="dead"
        _rec_drift="session PID is dead"
    elif [[ -n "${worktree_drift}" || -n "${branch_drift}" ]]; then
        _rec_health="drift"
        _rec_drift="${worktree_drift}${worktree_drift:+, }${branch_drift}"
    elif [[ "${pid_health}" == "live" ]]; then
        _rec_health="live"
    fi

    # If the worktree is on a task branch but the session file says released,
    # surface that as drift even if the PID field is empty.
    if [[ "${_rec_health}" == "-" && -e "${expected_worktree}/.git" ]]; then
        if [[ "${_rec_branch}" == "ia-${identity}/"* ]]; then
            _rec_health="drift"
            _rec_drift="released marker on task branch"
        fi
    fi
}

# Return 0 if the worktree currently hosts a live agent process other than
# the current session PID. Used in reuse mode to detect slot collapse when
# the lease file is missing or stale.
#
# Detection walks the ancestor chain of every process whose cwd is the worktree.
# This catches not only the main agent binary (kimi-code, claude, etc.) but also
# child processes such as MCP servers spawned via "npm exec" or "node" that have
# a generic name but are descendants of the agent session.
_worktree_has_other_live_agent() {
    local worktree_path="$1"
    local own_pid
    own_pid="$(_ag_session_pid "${worktree_path}")"

    # Build the set of known agent PIDs by inspecting comm/cmdline.
    local agent_pids=""
    local pid
    for pid in /proc/[0-9]*; do
        [[ -d "${pid}" ]] || continue
        local pid_num="${pid#/proc/}"
        local comm cmdline_argv0
        comm="$(cat "${pid}/comm" 2>/dev/null || true)"
        cmdline_argv0="$(tr '\0' '\n' < "${pid}/cmdline" 2>/dev/null | head -n1 || true)"
        case "${comm}|${cmdline_argv0}" in
            *kimi-code*|*claude*|*gemini*|*grok*|*cursor*|*antigravity*|*kiro*|*kimi*)
                agent_pids="${agent_pids} ${pid_num}"
                ;;
        esac
    done

    # For every process in the worktree, walk up the process tree looking for a
    # known agent ancestor. This detects MCP child processes (npm exec, node,
    # playwright-mcp, context7-mcp, etc.) whose own names do not contain the
    # agent identifier.
    for pid in /proc/[0-9]*; do
        [[ -d "${pid}" ]] || continue
        local pid_num="${pid#/proc/}"
        [[ "${pid_num}" == "${own_pid}" ]] && continue
        local cwd_link
        cwd_link="$(readlink "${pid}/cwd" 2>/dev/null || true)"
        [[ "${cwd_link}" != "${worktree_path}" ]] && continue

        # Collect this process's ancestor chain.
        local current_pid="${pid_num}"
        local ancestors=""
        local visited=""
        while [[ -n "${current_pid}" && "${current_pid}" != "1" ]]; do
            # Avoid infinite loops in malformed /proc entries.
            if [[ "${visited}" =~ (^|[[:space:]])${current_pid}([[:space:]]|$) ]]; then
                break
            fi
            visited="${visited} ${current_pid}"
            ancestors="${ancestors} ${current_pid}"
            current_pid="$(grep '^PPid:' "/proc/${current_pid}/status" 2>/dev/null | awk '{print $2}' || true)"
        done

        # If our own session is in the ancestor chain, this process is just our
        # own subprocess visiting the worktree (e.g. a test or build). Ignore it.
        if [[ "${ancestors}" =~ (^|[[:space:]])${own_pid}([[:space:]]|$) ]]; then
            continue
        fi

        # If any known agent is in the ancestor chain, the worktree is held by
        # another live session.
        for apid in ${agent_pids}; do
            if [[ "${ancestors}" =~ (^|[[:space:]])${apid}([[:space:]]|$) ]]; then
                return 0
            fi
        done
    done
    return 1
}

_load_session_field() {
    local identity="$1"
    local field="$2"
    local session_file
    session_file="$(_get_session_file "${identity}")"
    if [[ -f "${session_file}" ]]; then
        ${AG_PYTHON} -c "import json,sys; d=json.load(open('${session_file}')); print(d.get('${field}',''))" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Update a single field in the session file without rewriting the whole record.
# Used by --status and post-checkout to reconcile branch drift.
_save_session_field() {
    local identity="$1"
    local field="$2"
    local value="$3"
    local session_file
    session_file="$(_get_session_file "${identity}")"
    [[ -f "${session_file}" ]] || return 1

    ${AG_PYTHON} -c "
import json
with open('${session_file}') as f:
    d = json.load(f)
d['${field}'] = '${value}'
d['timestamp'] = __import__('time').time()
with open('${session_file}', 'w') as f:
    json.dump(d, f, indent=2)
" >/dev/null 2>&1
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

    ${AG_PYTHON} -c "
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
        ${AG_PYTHON} -c "
import json
with open('${session_file}') as f:
    d = json.load(f)
d.update({'status':'free','role':None,'branch':'','pid':None,'timestamp':None,'worktree_path':'','impact_plugins':[],'released_at':__import__('time').time()})
with open('${session_file}', 'w') as f:
    json.dump(d, f, indent=2)
" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------------------
# Helper: resolve the PID that anchors this session's lease.
#
# `$$` is the right anchor when init is sourced in an interactive terminal
# (the shell lives as long as the terminal) or in a long-lived wrapper that
# execs into the agent CLI — wrappers pin it via AGENT_GUARD_SESSION_PID.
# But agent CLIs (Kimi Code, etc.) source init from an ephemeral `bash -c`
# subshell whose $$ dies as soon as the command ends; the lease then looks
# stale and another session can steal the slot (slot race). In non-
# interactive shells without an explicit pin, anchor the lease to the parent
# process (the agent CLI), which lives for the whole session.
# ---------------------------------------------------------------------------
_ag_session_pid() {
    local expected_worktree="${1:-${AGENT_GUARD_WORKTREE_PATH:-${AG_WORKTREE_PATH:-$(pwd)}}}"

    # If a session PID pin exists and is alive, validate that it belongs to the
    # expected worktree. A stale pin can be inherited when a user sources init
    # from inside another active Agent Guard session (e.g. nested worktrees),
    # causing two slots to share the same PID and collide on lease checks.
    if [[ -n "${AGENT_GUARD_SESSION_PID:-}" && "${AGENT_GUARD_SESSION_PID}" != "1" ]] && kill -0 "${AGENT_GUARD_SESSION_PID}" 2>/dev/null; then
        local pid_cwd
        pid_cwd="$(readlink "/proc/${AGENT_GUARD_SESSION_PID}/cwd" 2>/dev/null || echo "")"
        if [[ -z "${expected_worktree}" || "${pid_cwd}" == "${expected_worktree}" ]]; then
            echo "${AGENT_GUARD_SESSION_PID}"
            return 0
        fi
    fi
    if [[ $- == *i* ]]; then
        echo "$$"
        return 0
    fi
    if [[ -n "${PPID:-}" && "${PPID}" != "1" ]] && kill -0 "${PPID}" 2>/dev/null; then
        echo "${PPID}"
        return 0
    fi
    echo "$$"
}

# ---------------------------------------------------------------------------
# 4. Helper: atomic slot allocation
# ---------------------------------------------------------------------------
_acquire_slot() {
    local prefix="$1"
    local role="$2"
    local impact_plugins="$3"
    local forced_identity="${4:-}"

    local initial_slots max_slots auto_expand
    initial_slots="$(_guard_get "identities.${prefix}.slots" 2>/dev/null || echo "")"
    if [[ -z "${initial_slots}" || "${initial_slots}" == "None" ]]; then
        echo "❌ Unknown prefix '${prefix}' or missing slots in agent-guard.yaml" >&2
        return 1
    fi

    # Optional dynamic expansion.  When auto_expand is true the guard may
    # allocate slots beyond the configured initial count up to max_slots.
    max_slots="$(_guard_get_str "identities.${prefix}.max_slots" "${initial_slots}")"
    auto_expand="$(_guard_get_str "identities.${prefix}.auto_expand" "false")"
    if [[ "${max_slots}" -lt "${initial_slots}" ]]; then
        max_slots="${initial_slots}"
    fi

    # Validate forced identity if requested.
    if [[ -n "${forced_identity}" ]]; then
        if [[ ! "${forced_identity}" =~ ^${prefix}[0-9]+$ ]]; then
            echo "❌ Forced identity '${forced_identity}' is not a valid '${prefix}' slot." >&2
            return 1
        fi
        local forced_slot="${forced_identity##*[a-z]}"
        if [[ "${forced_slot}" -lt 1 || "${forced_slot}" -gt "${max_slots}" ]]; then
            echo "❌ Forced identity '${forced_identity}' is outside the allowed range (1-${max_slots})." >&2
            return 1
        fi
    fi

    local global_lock
    global_lock="$(_get_global_lock)"
    touch "${global_lock}"

    # Open the lock descriptor in the CURRENT shell (not a subshell) and keep
    # it open for the whole critical section. Using command substitution to
    # capture output would close the descriptor when the subshell exits,
    # breaking atomicity and causing "flock: <fd>: invalid descriptor".
    local lock_fd=200
    eval "exec ${lock_fd}>\"${global_lock}\""

    # Acquire the global lock with a bounded retry loop.  The blocking variant
    # `flock -x` on util-linux 2.39+ spawns a helper process that can hang forever
    # if the lock is held by a dead/zombie process, leaving the terminal frozen.
    # Non-blocking `flock -n` avoids the helper process; we retry for up to 60s.
    local _lock_attempt=0
    while true; do
        if flock -n -x "${lock_fd}"; then
            break
        fi
        _lock_attempt=$((_lock_attempt + 1))

        # Recover from a stale lock file: if no live process holds the lock,
        # the file is leftover from a crashed/killed holder. Back it up and
        # recreate it, then retry immediately.
        if [[ $((_lock_attempt % 5)) -eq 0 ]]; then
            if ! lslocks | grep -qF "${global_lock}"; then
                echo "⚠️  Agent Guard: stale global lock detected; recovering..." >&2
                eval "exec ${lock_fd}>&-" 2>/dev/null || true
                mv "${global_lock}" "${global_lock}.stale.$(date +%s)" 2>/dev/null || true
                touch "${global_lock}"
                eval "exec ${lock_fd}>\"${global_lock}\""
                _lock_attempt=0
                continue
            fi
        fi

        if [[ "${_lock_attempt}" -ge 60 ]]; then
            echo "❌ Could not acquire global agent-guard lock after 60s." >&2
            echo "   Another process may be holding it. Check: lslocks | grep agent-sessions" >&2
            eval "exec ${lock_fd}>&-" 2>/dev/null || true
            return 1
        fi
        sleep 1
    done
    unset _lock_attempt

    # Ensure the lock is always released when this function returns.
    # The trap runs in the current shell, so we guard against lock_fd being
    # unset (e.g. if the trap fires after the function already returned).
    trap 'if [[ -n "${lock_fd:-}" ]]; then flock -u "${lock_fd}" 2>/dev/null || true; eval "exec ${lock_fd}>&-" 2>/dev/null || true; fi' EXIT

    local selected_identity=""

    # Helper: a slot is available when it is not held by a live process and,
    # if its worktree already exists, that worktree is clean and not occupied
    # by another live agent process.  Dirty worktrees are not silently recycled;
    # the user must release or clean them first.
    # A 60-second cooldown prevents a slot that was just released by this shell
    # from being immediately reacquired (e.g. user asks to continue right after
    # releasing). Pass "true" as second arg to bypass the cooldown.
    _slot_is_free() {
        local identity="$1"
        local ignore_cooldown="${2:-false}"
        local session_file worktree
        session_file="$(_get_session_file "${identity}")"
        worktree="$(_get_worktree_path "${identity}")"

        if [[ -f "${session_file}" ]]; then
            local sess_status sess_pid
            sess_status="$(_load_session_field "${identity}" "status")"
            sess_pid="$(_load_session_field "${identity}" "pid")"
            if [[ "${sess_status}" == "active" ]]; then
                if _is_pid_alive "${sess_pid}"; then
                    return 1
                fi
                _clear_session "${identity}"
            fi

            # Cooldown: slots released in the last 60s are treated as occupied
            # unless we are in the fallback pass (ignore_cooldown=true).
            if [[ "${ignore_cooldown}" != "true" ]]; then
                local released_at now
                released_at="$(_load_session_field "${identity}" "released_at")"
                if [[ -n "${released_at}" && "${released_at}" != "None" ]]; then
                    now="$(date +%s)"
                    released_at="${released_at%.*}"
                    if [[ $((now - released_at)) -lt 60 ]]; then
                        return 1
                    fi
                fi
            fi
        fi

        if [[ -d "${worktree}" ]]; then
            local dirty
            dirty="$(git -C "${worktree}" status --porcelain 2>/dev/null || true)"
            if [[ -n "${dirty}" ]]; then
                return 1
            fi

            # Even when the lease file is missing or stale, refuse to recycle a
            # worktree that currently hosts another live agent process.
            if _worktree_has_other_live_agent "${worktree}"; then
                return 1
            fi
        fi

        return 0
    }

    # Clean stale sessions while locked and find a free slot.
    # If a forced identity was requested, only that slot is considered.
    # Otherwise, search up to max_slots so that pre-created expanded worktrees
    # are reused before allocating a brand-new slot beyond the initial count.
    # First pass skips slots released in the last 60s; second pass allows them.
    local i identity
    if [[ -n "${forced_identity}" ]]; then
        identity="${forced_identity}"
        if _slot_is_free "${identity}"; then
            selected_identity="${identity}"
        elif _slot_is_free "${identity}" "true"; then
            selected_identity="${identity}"
        fi

        if [[ -z "${selected_identity}" ]]; then
            echo "❌ Slot '${forced_identity}' is not available (in use, dirty or on cooldown)." >&2
            echo "   Use 'source .hmvip-agent-init --status' to inspect slots." >&2
            return 1
        fi
    else
        for i in $(seq 1 "${max_slots}"); do
            identity="${prefix}${i}"
            if _slot_is_free "${identity}"; then
                selected_identity="${identity}"
                break
            fi
        done

        if [[ -z "${selected_identity}" ]]; then
            for i in $(seq 1 "${max_slots}"); do
                identity="${prefix}${i}"
                if _slot_is_free "${identity}" "true"; then
                    selected_identity="${identity}"
                    break
                fi
            done
        fi

        if [[ -z "${selected_identity}" ]]; then
            if [[ "${auto_expand,,}" == "true" ]]; then
                echo "❌ No free slots available for '${prefix}' (all ${max_slots} in use, auto_expand exhausted)." >&2
            else
                echo "❌ No free slots available for '${prefix}' (all ${initial_slots} in use). Enable auto_expand or release a session." >&2
            fi
            return 1
        fi
    fi

    # Build branch name
    local date_str
    date_str="$(date +%Y%m%d-%H%M)"
    local branch_name="ia-${selected_identity}/${role}/task-${date_str}"

    # Output via global variables so the caller can read the allocation without
    # command substitution (which would close the lock descriptor and break
    # atomicity). We also echo the values for compatibility with existing tests
    # and callers that still capture stdout.
    _AG_ALLOC_IDENTITY="${selected_identity}"
    _AG_ALLOC_BRANCH="${branch_name}"
    _AG_ALLOC_IMPACT_PLUGINS="${impact_plugins}"

    echo "${selected_identity}"
    echo "${branch_name}"
    echo "${impact_plugins}"

    # Trap releases the lock on return.
    return 0
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

# Create an empty task note for dynamically expanded slots so that every
# active session has a retomada document. Base slots are expected to have
# their template note committed in the repository already.
_ensure_task_note() {
    local identity="$1"
    local prefix="${identity%%[0-9]*}"
    local slot="${identity##*[a-z]}"
    local base_slots
    base_slots="$(_guard_get "identities.${prefix}.slots" 2>/dev/null || echo "0")"
    [[ -z "${base_slots}" || "${base_slots}" == "None" ]] && base_slots="0"

    if [[ "${slot}" -le "${base_slots}" ]]; then
        return 0
    fi

    local tasks_dir
    tasks_dir="${_AG_REPO_ROOT}/.agent-guard/tasks"
    mkdir -p "${tasks_dir}"
    local note_file="${tasks_dir}/${identity}.md"
    [[ -f "${note_file}" ]] && return 0

    local today
    today="$(date +%Y-%m-%d)"
    cat > "${note_file}" <<EOF
# Tarefa do slot \`${identity}\` — criada automaticamente em ${today}

> Arquivo lido por \`hmvip resume ${identity}\`. Atualizar via PR quando a tarefa do slot mudar.

## Tarefa ATUAL — ${today}
**Descreva aqui o trabalho em andamento.**

### Commits/PRs recentes
(nenhum)

### Próximo passo
(não definido)

### Como retomar
\`\`\`bash
hmvip resume ${identity}
\`\`\`
EOF
}

# ---------------------------------------------------------------------------
# Prune a free agent worktree safely.
# ---------------------------------------------------------------------------
# Removes the worktree directory and session file for an identity only when
# all safety checks pass. Base slots (1..initial_slots) are never pruned to
# preserve the configured capacity; only expanded slots can be removed.
#
# Usage:
#   _prune_identity <identity> [--dry-run]
#
# Returns 0 if pruned or dry-run would prune, 1 otherwise.
_prune_identity() {
    local identity="${1:-}"
    local dry_run="false"
    if [[ "${2:-}" == "--dry-run" ]]; then
        dry_run="true"
    fi

    if [[ -z "${identity}" ]]; then
        echo "❌ prune requires an identity (ex: kimi12)." >&2
        return 1
    fi

    local prefix="${identity%%[0-9]*}"
    local slot="${identity##*[a-z]}"
    if [[ -z "${prefix}" || -z "${slot}" || "${slot}" =~ [^0-9] ]]; then
        echo "❌ Invalid identity: ${identity}" >&2
        return 1
    fi

    local base_slots initial_slots
    base_slots="$(_guard_get "identities.${prefix}.slots" 2>/dev/null || echo "0")"
    [[ -z "${base_slots}" || "${base_slots}" == "None" ]] && base_slots="0"

    if [[ "${slot}" -le "${base_slots}" ]]; then
        echo "❌ Refusing to prune base slot ${identity} (base slots = ${base_slots})." >&2
        echo "   Base slots are part of the configured capacity and are never deleted." >&2
        return 1
    fi

    local session_file worktree_path
    session_file="$(_get_session_file "${identity}")"
    worktree_path="$(_get_worktree_path "${identity}")"

    # Check session is free.
    local status
    status="$(_load_session_field "${identity}" "status")"
    if [[ -f "${session_file}" && "${status}" != "free" && "${status}" != "" ]]; then
        echo "❌ Refusing to prune ${identity}: session status is '${status}', not free." >&2
        return 1
    fi

    # Check worktree exists.
    if [[ ! -e "${worktree_path}/.git" ]]; then
        echo "❌ Worktree for ${identity} does not exist at ${worktree_path}." >&2
        return 1
    fi

    # Check branch is the neutral post-release branch.
    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"
    if [[ "${current_branch}" != "_released/${identity}" ]]; then
        echo "❌ Refusing to prune ${identity}: branch is '${current_branch}', expected '_released/${identity}'." >&2
        return 1
    fi

    # Check working tree is clean.
    local dirty
    dirty="$(git -C "${worktree_path}" status --porcelain 2>/dev/null || true)"
    if [[ -n "${dirty}" ]]; then
        echo "❌ Refusing to prune ${identity}: working tree has uncommitted changes." >&2
        echo "   Resolve before pruning." >&2
        return 1
    fi

    # Check no stashes.
    local stash_list
    stash_list="$(git -C "${worktree_path}" stash list 2>/dev/null || true)"
    if [[ -n "${stash_list}" ]]; then
        echo "❌ Refusing to prune ${identity}: worktree has stashes." >&2
        return 1
    fi

    if [[ "${dry_run}" == "true" ]]; then
        echo "✅ Would prune ${identity}:"
        echo "   Worktree: ${worktree_path}"
        echo "   Session file: ${session_file}"
        return 0
    fi

    # Remove the worktree from git and delete the directory.
    if git -C "${_AG_REPO_ROOT}" worktree remove "${worktree_path}" 2>/dev/null || rm -rf "${worktree_path}"; then
        rm -f "${session_file}"
        echo "✅ Pruned ${identity}:"
        echo "   Removed worktree: ${worktree_path}"
        echo "   Removed session file: ${session_file}"
        return 0
    fi

    echo "❌ Failed to remove worktree for ${identity}." >&2
    return 1
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
ADOPT_IDENTITY=""
PREFIX=""
ROLE=""
IMPACT_PLUGINS=""
FORCED_IDENTITY=""
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
        --adopt)
            if [[ -n "${2:-}" ]]; then
                ADOPT_IDENTITY="$2"
                MODE="adopt"
                shift 2
            else
                echo "❌ --adopt requires an identity (ex: kimi3)." >&2
                return 1 2>/dev/null || exit 1
            fi
            ;;
        --slot)
            if [[ -n "${2:-}" ]]; then
                FORCED_IDENTITY="$2"
                shift 2
            else
                echo "❌ --slot requires an identity (ex: kimi3)." >&2
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
# Helper: check whether the current branch belongs to the agent identity that
# owns this worktree. This allows release directly from a task branch without
# forcing a checkout to develop, which is impossible when develop is already
# checked out in another worktree (e.g. the main repository).
_branch_is_current_agent_task() {
    local worktree_path="$1"
    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"
    local wt_name identity expected_prefix
    wt_name="$(basename "${worktree_path}")"
    identity="$(_detect_identity_from_worktree_name "${wt_name}" | awk '{print $1 $2}')"
    [[ -n "${identity}" ]] || return 1
    expected_prefix="ia-${identity}/"
    [[ "${current_branch}" == "${expected_prefix}"* ]]
}

# ---------------------------------------------------------------------------
# Helper: check whether the worktree is parked on its neutral post-release
# branch (_released/<identity>). Release switches the worktree to this branch
# at the end, so a second --release must be accepted as an idempotent no-op
# instead of failing validation.
# ---------------------------------------------------------------------------
_branch_is_neutral_released() {
    local worktree_path="$1"
    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"
    local wt_name identity
    wt_name="$(basename "${worktree_path}")"
    identity="$(_detect_identity_from_worktree_name "${wt_name}" | awk '{print $1 $2}')"
    [[ -n "${identity}" ]] || return 1
    [[ "${current_branch}" == "_released/${identity}" ]]
}

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
    if [[ "${current_branch}" != "develop" ]] && ! _branch_is_current_agent_task "${worktree_path}" && ! _branch_is_neutral_released "${worktree_path}"; then
        echo "" >&2
        echo "❌❌❌ ERROR: WORKTREE NOT RELEASABLE ❌❌❌" >&2
        echo "" >&2
        echo "   Current branch: ${current_branch:-<detached>}" >&2
        echo "   Release is only allowed when the worktree is on 'develop'," >&2
        echo "   on its own agent task branch (ia-<identity>/...), or on its" >&2
        echo "   neutral '_released/<identity>' branch (release is idempotent)." >&2
        echo "" >&2
        echo "   Required actions before release:" >&2
        echo "     1. Commit or stash any unfinished work on your task branch." >&2
        echo "     2. Push your branch and ensure PR is open/merged." >&2
        echo "     3. If the branch was already merged via squash, release directly" >&2
        echo "        from the task branch — do not force a checkout to develop." >&2
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
    # Stashes sao globais ao repo: so bloqueiam o release os que pertencem
    # a ESTA identidade (criados em branch ia-<identity>/... ou na branch
    # atual). Stash de outro agente vivo nao pode travar este slot
    # (incidente 2026-07-12: stash do kimi2 bloqueou release de todos).
    local wt_name identity
    wt_name="$(basename "${worktree_path}")"
    identity="$(_detect_identity_from_worktree_name "${wt_name}" | awk '{print $1 $2}')"
    if [[ -n "${identity}" ]]; then
        stash_count="$(git -C "${worktree_path}" stash list 2>/dev/null | grep -cE "^stash@\{[0-9]+\}: On (ia-${identity}/|${current_branch}:)" || true)"
    else
        stash_count="$(git -C "${worktree_path}" stash list 2>/dev/null | grep -c "On ${current_branch}:" || true)"
    fi
    if [[ "${stash_count}" -gt 0 ]]; then
        echo "" >&2
        echo "❌❌❌ ERROR: WORKTREE HAS STASHES ❌❌❌" >&2
        echo "" >&2
        if [[ -n "${identity}" ]]; then
            git -C "${worktree_path}" stash list 2>/dev/null | grep -E "^stash@\{[0-9]+\}: On (ia-${identity}/|${current_branch}:)" | sed 's/^/   /' >&2
        else
            git -C "${worktree_path}" stash list 2>/dev/null | grep "On ${current_branch}:" | sed 's/^/   /' >&2
        fi
        echo "" >&2
        echo "   Apply, drop, or move these stashes before releasing." >&2
        echo "   Stash is not a trash can — inspect with: git stash show -p stash@{<n>}" >&2
        echo "" >&2
        return 1
    fi

    # Aviso nao-bloqueante: stashes de OUTRAS identidades presentes no repo
    local foreign_count
    foreign_count="$(git -C "${worktree_path}" stash list 2>/dev/null | grep -c '^stash@{' || true)"
    if [[ "${foreign_count}" -gt 0 ]]; then
        echo "ℹ️  ${foreign_count} stash(es) de outra(s) identidade(s) no repo — nao bloqueiam este release." >&2
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

    if [[ "${CURRENT_WORKTREE}" == "${MAIN_REPO}" ]]; then
        echo "❌❌❌ ERROR: RELEASE BLOCKED ON MAIN REPOSITORY ❌❌❌" >&2
        echo "" >&2
        echo "   You are trying to release a session from the main repository:" >&2
        echo "     ${MAIN_REPO}" >&2
        echo "" >&2
        echo "   AI agents must NEVER operate on or release from the main repo." >&2
        echo "   If you intended to release an agent session, run --release from" >&2
        echo "   the agent's own worktree (e.g. /home/hmvip-dev/hmvip-ia-kimi1)." >&2
        echo "" >&2
        echo "   If the main repo ended up on a neutral branch (_released/*)," >&2
        echo "   switch it back to develop manually as the repo owner:" >&2
        echo "     cd ${MAIN_REPO}" >&2
        echo "     git checkout develop" >&2
        echo "     git pull origin develop" >&2
        echo "" >&2
        return 1 2>/dev/null || exit 1
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
    printf "%-12s | %-8s | %-6s | %-10s | %-6s | %-8s | %-40s\n" "Agent" "Status" "Role" "PID" "WT" "Health" "Branch"
    echo "----------------------------------------------------------"

    _rec_status="" _rec_role="" _rec_pid="" _rec_branch="" _rec_worktree="" _rec_health="" _rec_drift=""
    any_drift=""

    identity_list="$(bash "${AGENT_GUARD_CONFIG_BIN}" keys identities)"
    for prefix in ${identity_list}; do
        [[ -z "${prefix}" ]] && continue
        # Show all slots up to max_slots so expanded slots (kimi8+) are visible.
        base_slots="$(_guard_get "identities.${prefix}.slots")"
        max_slots="$(_guard_get "identities.${prefix}.max_slots" "${base_slots}")"
        for i in $(seq 1 "${max_slots}"); do
            identity="${prefix}${i}"
            worktree_path="$(_get_worktree_path "${identity}")"
            wt_ok="❌"
            [[ -e "${worktree_path}/.git" ]] && wt_ok="✅"

            _status_reconcile_session "${identity}"

            pid_col="${_rec_pid}"
            if [[ "${_rec_health}" == "live" ]]; then
                pid_col="${_rec_pid} (live)"
            elif [[ "${_rec_health}" == "dead" ]]; then
                pid_col="${_rec_pid} (dead)"
            fi

            printf "%-12s | %-8s | %-6s | %-10s | %-6s | %-8s | %-40s\n" \
                "${identity}" "${_rec_status:-free}" "${_rec_role:-}" \
                "${pid_col:-}" "${wt_ok}" "${_rec_health:-}" "${_rec_branch:-}"

            if [[ "${_rec_health}" != "-" && "${_rec_health}" != "live" ]]; then
                any_drift="${any_drift}\n  ${_rec_drift:-drift}: ${identity} -> ${_rec_branch:-<no branch>}"
            fi
        done
    done
    echo "=========================================================="
    if [[ -n "${any_drift}" ]]; then
        echo ""
        echo "⚠️  Issues detected:"
        echo -e "${any_drift}"
        echo ""
        echo "Use: source .hmvip-agent-init --adopt <identity>  to inspect/recover"
    fi
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

    impact_json="$(echo "${IMPACT_PLUGINS}" | ${AG_PYTHON} -c "import sys,json; print(json.dumps([p.strip() for p in sys.stdin.read().split(',') if p.strip()]))" 2>/dev/null || echo "[]")"
    _save_session "${IDENTITY_FROM_BRANCH}" "active" "${ROLE}" "${ATTACH_BRANCH}" "$(_ag_session_pid "${WORKTREE_PATH}")" "${WORKTREE_PATH}" "${impact_json}"

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
# 10b. --adopt mode (assume an idle/dirty slot from a previous session)
# ---------------------------------------------------------------------------
# Use case: a new day starts and yesterday's slots are still dirty — the
# normal acquire flow skips dirty worktrees, so the agent cannot resume the
# work. Adopt explicitly takes over the slot of a DEAD session, without
# deleting, stashing or committing anything. The agent inspects the state and
# decides how to continue.
#
# Safety rails:
#   - Refuses when the slot is held by a LIVE process.
#   - Refuses when the worktree is on a branch of another identity
#     (foreign work) or on a protected/neutral branch other than its own.
#   - Never cleans the worktree: dirty files and stashes are only reported.
if [[ "${MODE}" == "adopt" ]]; then
    if [[ ! "${ADOPT_IDENTITY}" =~ ^([a-z]+)([0-9]+)$ ]]; then
        echo "❌ --adopt identity must look like '<prefix><slot>' (ex: kimi3)." >&2
        return 1 2>/dev/null || exit 1
    fi
    ADOPT_PREFIX="${BASH_REMATCH[1]}"

    if [[ -z "$(bash "${AGENT_GUARD_CONFIG_BIN}" get "identities.${ADOPT_PREFIX}.slots" "" 2>/dev/null)" ]]; then
        echo "❌ Unknown identity prefix '${ADOPT_PREFIX}'. Check agent-guard.yaml." >&2
        return 1 2>/dev/null || exit 1
    fi

    WORKTREE_PATH="$(_get_worktree_path "${ADOPT_IDENTITY}")"
    if [[ ! -e "${WORKTREE_PATH}/.git" ]]; then
        echo "❌ Worktree for identity '${ADOPT_IDENTITY}' does not exist: ${WORKTREE_PATH}" >&2
        echo "   Nothing to adopt — acquire a fresh session instead." >&2
        return 1 2>/dev/null || exit 1
    fi

    # Refuse takeover of a live session.
    adopt_sess_status="$(_load_session_field "${ADOPT_IDENTITY}" "status")"
    adopt_sess_pid="$(_load_session_field "${ADOPT_IDENTITY}" "pid")"
    if [[ "${adopt_sess_status}" == "active" && -n "${adopt_sess_pid}" && "${adopt_sess_pid}" != "$(_ag_session_pid "${WORKTREE_PATH}")" ]]; then
        if _is_pid_alive "${adopt_sess_pid}"; then
            echo "" >&2
            echo "❌❌❌ ERROR: SLOT STILL IN USE ❌❌❌" >&2
            echo "" >&2
            echo "   Identity '${ADOPT_IDENTITY}' is held by live PID ${adopt_sess_pid}." >&2
            echo "   Adopt only works on slots whose previous session is dead." >&2
            echo "" >&2
            return 1 2>/dev/null || exit 1
        fi
        echo "🧹 Clearing stale session for ${ADOPT_IDENTITY} (PID ${adopt_sess_pid} is dead)." >&2
        _clear_session "${ADOPT_IDENTITY}"
    fi

    cd "${WORKTREE_PATH}" || return 1 2>/dev/null || exit 1
    git fetch origin >/dev/null 2>&1 || true

    ADOPT_BRANCH="$(git branch --show-current 2>/dev/null || echo "")"
    if [[ "${ADOPT_BRANCH}" != "ia-${ADOPT_IDENTITY}/"* && "${ADOPT_BRANCH}" != "_released/${ADOPT_IDENTITY}" ]]; then
        echo "" >&2
        echo "❌❌❌ ERROR: FOREIGN OR PROTECTED BRANCH ❌❌❌" >&2
        echo "" >&2
        echo "   Worktree ${WORKTREE_PATH} is on branch '${ADOPT_BRANCH:-<detached>}'." >&2
        echo "   Adopt only resumes this identity's own branches:" >&2
        echo "     ia-${ADOPT_IDENTITY}/... or _released/${ADOPT_IDENTITY}" >&2
        echo "" >&2
        echo "   If this is another agent's work, STOP and ask the user." >&2
        echo "" >&2
        return 1 2>/dev/null || exit 1
    fi

    echo ""
    echo "=========================================================="
    echo "🛡️  Agent Guard: ADOPTING slot ${ADOPT_IDENTITY}"
    echo "=========================================================="
    echo "   Worktree: ${WORKTREE_PATH}"
    echo "   Branch:   ${ADOPT_BRANCH}"

    DIRTY_FILES="$(git status --porcelain 2>/dev/null || true)"
    if [[ -n "${DIRTY_FILES}" ]]; then
        echo ""
        echo "⚠️⚠️⚠️  UNCOMMITTED WORK FROM PREVIOUS SESSION  ⚠️⚠️⚠️"
        echo ""
        echo "${DIRTY_FILES}" | sed 's/^/   /'
        echo ""
        echo "   Nothing was touched. Inspect before continuing:"
        echo "     git status && git diff"
        echo "   Decide: commit as WIP/checkpoint on this branch, or ask the user."
    fi

    ADOPT_STASHES="$(git stash list 2>/dev/null || true)"
    if [[ -n "${ADOPT_STASHES}" ]]; then
        echo ""
        echo "⚠️  Stashes present:"
        echo "${ADOPT_STASHES}" | sed 's/^/   /'
        echo "   Inspect with: git stash show -p stash@{<n>}"
    fi
    echo ""

    _set_git_author "${ADOPT_IDENTITY}" "${WORKTREE_PATH}"
    _export_session_env "${WORKTREE_PATH}" "${ADOPT_BRANCH}" "${IMPACT_PLUGINS}"

    _configure_hooks_path "${WORKTREE_PATH}"
    _anti_stale_check "${WORKTREE_PATH}"

    impact_json="$(echo "${IMPACT_PLUGINS}" | ${AG_PYTHON} -c "import sys,json; print(json.dumps([p.strip() for p in sys.stdin.read().split(',') if p.strip()]))" 2>/dev/null || echo "[]")"
    _save_session "${ADOPT_IDENTITY}" "active" "${ROLE}" "${ADOPT_BRANCH}" "$(_ag_session_pid "${WORKTREE_PATH}")" "${WORKTREE_PATH}" "${impact_json}"

    # Expanded slots (beyond the base count) must have a retomada note.
    _ensure_task_note "${ADOPT_IDENTITY}"

    if command -v _journal_adopt >/dev/null 2>&1; then
        _journal_adopt "${ADOPT_BRANCH}"
    fi
    if command -v _journal_checkpoint >/dev/null 2>&1; then
        _journal_checkpoint "session adopted" "${WORKTREE_PATH}" "${ADOPT_BRANCH}"
    fi

    echo "✅ Git author set to ${GIT_AUTHOR_EMAIL}"
    echo "✅ Session active on ${ADOPT_IDENTITY} — resumed from previous state."
    echo ""
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

# Early-out for callers that only need helper functions loaded (e.g. prune).
if [[ "${AGENT_GUARD_FUNCTIONS_ONLY:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# 12. Reuse branch when already inside an agent worktree
# ---------------------------------------------------------------------------
# If the user explicitly requested a different slot, do not reuse the current
# worktree; fall through to forced allocation.
if [[ -n "${FORCED_IDENTITY}" && "${FORCED_IDENTITY}" != "${CURRENT_IDENTITY}" ]]; then
    echo "🎯 Agent Guard: explicit slot '${FORCED_IDENTITY}' requested; not reusing current worktree." >&2
elif [[ -n "${CURRENT_IDENTITY}" && -n "${CURRENT_BRANCH}" && "${CURRENT_BRANCH}" != "_released/${CURRENT_IDENTITY}" ]]; then
    echo "🛡️  Agent Guard: reusing worktree ${CURRENT_WORKTREE}"
    echo "   Identity: ${CURRENT_IDENTITY}"
    echo "   Branch:   ${CURRENT_BRANCH}"

    # Guard against another live process already holding this worktree.
    # This can happen when a previous session released the lease file but
    # its process is still alive, or when the wrapper races between sessions.
    existing_pid="$(_load_session_field "${CURRENT_IDENTITY}" "pid")"
    existing_status="$(_load_session_field "${CURRENT_IDENTITY}" "status")"
    if [[ "${existing_status}" == "active" && -n "${existing_pid}" && "${existing_pid}" != "$(_ag_session_pid "${CURRENT_WORKTREE}")" ]]; then
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

    # Secondary guard: even if the lease file is missing or stale, detect any
    # other live agent process currently inside this worktree. This prevents
    # multiple independent sessions from collapsing into the same slot when the
    # lease state drifts (e.g. crash without release or stale session files).
    if _worktree_has_other_live_agent "${CURRENT_WORKTREE}"; then
        echo ""
        echo "❌❌❌ ERROR: WORKTREE ALREADY IN USE ❌❌❌" >&2
        echo "" >&2
        echo "   Another live agent process was detected in ${CURRENT_WORKTREE}." >&2
        echo "   Identity '${CURRENT_IDENTITY}' cannot be reused until it is released." >&2
        echo "" >&2
        echo "   Possible causes:" >&2
        echo "     - The lease file is missing or points to a dead PID." >&2
        echo "     - Another terminal/chat is using this worktree." >&2
        echo "" >&2
        echo "   Resolution:" >&2
        echo "     1. Find the other session and close it, OR" >&2
        echo "     2. Start from ${MAIN_REPO} to get a free worktree, OR" >&2
        echo "     3. Run agent-guard status to inspect stale sessions." >&2
        echo "" >&2
        return 1 2>/dev/null || exit 1
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

    impact_json="$(echo "${IMPACT_PLUGINS}" | ${AG_PYTHON} -c "import sys,json; print(json.dumps([p.strip() for p in sys.stdin.read().split(',') if p.strip()]))" 2>/dev/null || echo "[]")"
    _save_session "${CURRENT_IDENTITY}" "active" "${ROLE}" "${CURRENT_BRANCH}" "$(_ag_session_pid "${CURRENT_WORKTREE}")" "${CURRENT_WORKTREE}" "${impact_json}"

    if command -v _journal_init >/dev/null 2>&1; then
        _journal_init
    fi
    if command -v _journal_checkpoint >/dev/null 2>&1; then
        _journal_checkpoint "session acquired (reuse)" "${CURRENT_WORKTREE}" "${CURRENT_BRANCH}"
    fi

    echo "✅ Git author set to ${GIT_AUTHOR_EMAIL}"
    return 0 2>/dev/null || exit 0
elif [[ -n "${CURRENT_IDENTITY}" && -n "${CURRENT_BRANCH}" && "${CURRENT_BRANCH}" == "_released/${CURRENT_IDENTITY}" ]]; then
    # The worktree was released to its neutral branch. Do not silently reuse
    # it; fall through to acquire a fresh slot (respecting cooldown).
    echo "🛡️  Agent Guard: worktree ${CURRENT_WORKTREE} is on neutral branch '${CURRENT_BRANCH}'."
    echo "   It was released; acquiring a fresh slot instead of reusing it."
    echo ""
fi

# ---------------------------------------------------------------------------
# 13. New session: validate args and acquire slot
# ---------------------------------------------------------------------------
# When sourced only to load helper functions (e.g. from bin/agent-guard prune),
# skip the interactive/session acquisition flow.
if [[ "${AGENT_GUARD_FUNCTIONS_ONLY:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

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
if ! _acquire_slot "${PREFIX}" "${ROLE}" "${IMPACT_PLUGINS}" "${FORCED_IDENTITY}"; then
    return 1 2>/dev/null || exit 1
fi

IDENTITY="${_AG_ALLOC_IDENTITY}"
BRANCH_NAME="${_AG_ALLOC_BRANCH}"
IMPACT_PLUGINS="${_AG_ALLOC_IMPACT_PLUGINS}"
unset _AG_ALLOC_IDENTITY _AG_ALLOC_BRANCH _AG_ALLOC_IMPACT_PLUGINS

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

impact_json="$(echo "${IMPACT_PLUGINS}" | ${AG_PYTHON} -c "import sys,json; print(json.dumps([p.strip() for p in sys.stdin.read().split(',') if p.strip()]))" 2>/dev/null || echo "[]")"
_save_session "${IDENTITY}" "active" "${ROLE}" "${BRANCH_NAME}" "$(_ag_session_pid "${WORKTREE_PATH}")" "${WORKTREE_PATH}" "${impact_json}"

# Expanded slots (beyond the base count) must have a retomada note.
_ensure_task_note "${IDENTITY}"

if command -v _journal_init >/dev/null 2>&1; then
    _journal_init
fi
if command -v _journal_checkpoint >/dev/null 2>&1; then
    _journal_checkpoint "session acquired" "${WORKTREE_PATH}" "${BRANCH_NAME}"
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
