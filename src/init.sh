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

# Save the caller's shell flags BEFORE enabling strict mode so we can restore
# the original state before returning. Without this, strict mode leaks into the
# user's interactive shell and may kill the terminal on the next failing command
# (see hmvip-shell-safety, L222).
_AG_INIT_OLD_FLAGS="$(set +o)"
_ag_init_restore_shell_flags() {
    eval "${_AG_INIT_OLD_FLAGS}" 2>/dev/null || true
}

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
# 2. Helper: read values from agent-guard.yaml (SSOT)
# ---------------------------------------------------------------------------
# Cache the parsed config in memory to avoid spawning agent-guard-config
# (and its Python YAML parser) for every lookup. Each init invocation reads
# the YAML only once; subsequent _guard_get/_guard_get_keys calls reuse the
# cached JSON. This is the dominant cost in tests and CI.
_AG_CONFIG_JSON=""
_load_guard_config_once() {
    if [[ -n "${_AG_CONFIG_JSON:-}" ]]; then
        return 0
    fi
    local yaml_path="${AGENT_GUARD_REPO_ROOT}/agent-guard.yaml"
    if [[ -f "${yaml_path}" ]]; then
        _AG_CONFIG_JSON="$(${AG_PYTHON} -c 'import json, sys, yaml; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "${yaml_path}" 2>/dev/null || true)"
    fi
}

_guard_get_keys() {
    local key="${1:-}"
    _load_guard_config_once
    if [[ -z "${_AG_CONFIG_JSON:-}" ]]; then
        return 0
    fi
    ${AG_PYTHON} -c "
import json, sys
data = json.load(sys.stdin)
key = sys.argv[1]
if key:
    for part in key.split('.'):
        if not isinstance(data, dict) or part not in data:
            print('')
            sys.exit(0)
        data = data[part]
if isinstance(data, dict):
    print(' '.join(str(x) for x in data.keys()))
else:
    print('')
" "${key}" <<< "${_AG_CONFIG_JSON}" 2>/dev/null || true
}

_guard_get() {
    local key="$1"
    local default_value="${2:-}"
    _load_guard_config_once
    if [[ -z "${_AG_CONFIG_JSON:-}" ]]; then
        return 1
    fi
    ${AG_PYTHON} -c "
import json, sys
data = json.load(sys.stdin)
key = sys.argv[1]
default = sys.argv[2] if len(sys.argv) > 2 else ''
for part in key.split('.'):
    if not isinstance(data, dict) or part not in data:
        print(default)
        sys.exit(0)
    data = data[part]
if isinstance(data, list):
    print(' '.join(str(x) for x in data))
elif data is None:
    print(default)
else:
    print(data)
" "${key}" "${default_value}" <<< "${_AG_CONFIG_JSON}" 2>/dev/null || true
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
    for identity_name in $(_guard_get_keys "identities"); do
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
        for identity_name in $(_guard_get_keys "identities"); do
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

# Convert tab state (working|attention|error|idle|...) to compact status dots.
_tab_dot_for_state() {
    local tab_state="$1"
    local bg_count="${2:-0}"
    local dots=""
    [[ "${bg_count}" =~ ^[0-9]+$ ]] && [[ "${bg_count}" -gt 0 ]] && dots="🔵"
    case "${tab_state}" in
        working)   dots="${dots}🟢" ;;
        attention) dots="${dots}🟡" ;;
        error)     dots="${dots}🔴" ;;
        *)         dots="${dots}⚪" ;;
    esac
    printf '%s' "${dots}"
}

# Reconcile session file with the actual state of the worktree and process.
# Sets the following variables in the caller's scope:
#   _rec_status, _rec_role, _rec_pid, _rec_branch, _rec_worktree,
#   _rec_health, _rec_drift, _rec_tab_state, _rec_tab_title, _rec_tab_bg,
#   _rec_tab_updated
# _rec_health is one of: live, dead, stale, orphan, drift, pinned, -
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
    _rec_last_activity="$(_load_last_activity "${identity}")"
    _rec_tab_state="$(_load_session_field "${identity}" "tab_state")"
    _rec_tab_title="$(_load_session_field "${identity}" "tab_title")"
    _rec_tab_bg="$(_load_session_field "${identity}" "tab_bg")"
    _rec_tab_updated="$(_load_session_field "${identity}" "tab_updated")"
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
            elif [[ -n "${actual_branch}" ]] && ! _branch_belongs_to_identity_or_base "${expected_worktree}" "${identity}"; then
                _rec_health="orphan"
                _rec_drift="foreign branch ${actual_branch}"
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

    # Determine final health label. A live PID with no recent activity is
    # reported as stale so operators can recover slots left behind by idle
    # IDE tabs/conversations. A live PID that is not an agent process tree
    # (agent died, stray shell survived) is reported as pinned so operators
    # know adopt/init will auto-clear it.
    local stale_marker="" pinned_marker=""
    if [[ "${pid_health}" == "live" ]] && _is_session_stale "${identity}"; then
        stale_marker="stale"
    fi
    if [[ "${pid_health}" == "live" && -z "${stale_marker}" ]] && _lease_is_shell_pinned "${identity}"; then
        pinned_marker="pinned"
    fi

    if [[ "${pid_health}" == "dead" ]]; then
        _rec_health="dead"
        _rec_drift="session PID is dead"
    elif [[ -n "${worktree_drift}" || -n "${branch_drift}" ]]; then
        _rec_health="drift"
        _rec_drift="${worktree_drift}${worktree_drift:+, }${branch_drift}"
    elif [[ -n "${stale_marker}" ]]; then
        _rec_health="stale"
        _rec_drift="inactive since $(date -d "@${_rec_last_activity}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")"
    elif [[ -n "${pinned_marker}" ]]; then
        _rec_health="pinned"
        _rec_drift="lease held by stray non-agent PID ${_rec_pid} (auto-clear on adopt/init)"
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
# Detection walks the descendant tree of every known agent process looking for a
# process whose cwd is the worktree. This catches not only the main agent binary
# (kimi-code, claude, etc.) but also child processes such as MCP servers spawned
# via "npm exec" or "node" that have a generic name but are descendants of the
# agent session.
#
# Performance: iterating /proc directly in shell is too slow on hosts with many
# threads. We use `ps` (C implementation) once to get the process table, build a
# small descendant index for agent candidates, and readlink cwd only for those.
# Results are cached for a few seconds to avoid repeated scans during a single
# init invocation.
_AG_OTHER_AGENT_CACHE_TS=""
_AG_OTHER_AGENT_CACHE_WORKTREE=""
_AG_OTHER_AGENT_CACHE_RESULT=""

# Walk the cached PPID map and return the top-most (root) agent process that
# owns this process tree. We keep walking instead of stopping at the first
# agent because args-based detection can flag the current shell/wrapper itself
# as an agent (e.g. its argv contains a .kimi-code path); the meaningful
# session owner is the IDE/agent root at the top of the chain.
_ag_find_agent_ancestor() {
    local start_pid="$1"
    local agent_pids="$2"
    local ppid_map="$3"
    local current_pid="${start_pid}"
    local visited=""
    local root_agent=""

    while [[ -n "${current_pid}" && "${current_pid}" != "1" ]]; do
        if [[ "${visited}" =~ (^|[[:space:]])${current_pid}([[:space:]]|$) ]]; then
            break
        fi
        visited="${visited} ${current_pid}"

        if [[ " ${agent_pids} " =~ [[:space:]]${current_pid}[[:space:]] ]]; then
            root_agent="${current_pid}"
        fi

        current_pid="$(printf '%s' "${ppid_map}" | tr ' ' '\n' | grep "^${current_pid}:" | head -n1 | cut -d: -f2)"
    done

    if [[ -n "${root_agent}" ]]; then
        echo "${root_agent}"
        return 0
    fi
    return 1
}

_worktree_has_other_live_agent() {
    local worktree_path="$1"

    # Short-lived cache: many init paths call this helper for the same worktree
    # within milliseconds. Reuse the last answer if still fresh.
    local now
    now="$(date +%s)"
    if [[ "${_AG_OTHER_AGENT_CACHE_WORKTREE:-}" == "${worktree_path}" && -n "${_AG_OTHER_AGENT_CACHE_RESULT:-}" ]]; then
        if [[ $((now - _AG_OTHER_AGENT_CACHE_TS)) -lt 5 ]]; then
            return "${_AG_OTHER_AGENT_CACHE_RESULT}"
        fi
    fi

    # Snapshot process table: pid, ppid, comm, argv.
    local ps_output
    ps_output="$(ps -eo pid,ppid,comm,args 2>/dev/null | tail -n +2)"
    if [[ -z "${ps_output}" ]]; then
        _AG_OTHER_AGENT_CACHE_WORKTREE="${worktree_path}"
        _AG_OTHER_AGENT_CACHE_TS="${now}"
        _AG_OTHER_AGENT_CACHE_RESULT="1"
        return 1
    fi

    # Build children map, ppid map and identify agent PIDs from comm/args in one
    # awk pass. We then compute the transitive descendant set of all agent
    # processes; shell only reads cwd for those candidates.
    local candidates
    candidates="$(printf '%s' "${ps_output}" | awk '
    {
        pid=$1; ppid=$2; comm=$3;
        args=""; for (i=4; i<=NF; i++) args = args $i " ";
        children[ppid] = children[ppid] " " pid;
        ppid_map[pid] = ppid;
        if (comm == "kimi-code" || comm == "claude" || comm == "gemini" || comm == "grok" || comm == "cursor" || comm == "antigravity" || comm == "kiro" || comm == "kimi" || args ~ /(^|[^[:alnum:]_])(kimi-code|claude|gemini|grok|cursor|antigravity|kiro|kimi)([^[:alnum:]_]|$)/) {
            agents[pid] = 1;
        }
    }
    END {
        for (p in ppid_map) {
            print "P" p ":" ppid_map[p];
        }
        for (a in agents) {
            print "C" a;
            delete q;
            q[0] = a; qi = 0; qn = 1;
            while (qi < qn) {
                cur = q[qi++];
                if (children[cur] != "") {
                    n = split(children[cur], cands, " ");
                    for (j=1; j<=n; j++) {
                        cand = cands[j];
                        if (cand != "" && !seen[cand]) {
                            seen[cand] = 1;
                            q[qn++] = cand;
                            print "C" cand;
                        }
                    }
                }
            }
        }
    }')"

    # Extract ppid map and candidate PIDs.
    local ppid_map=""
    local candidate_pids=""
    local agent_pids=""
    ppid_map="$(printf '%s' "${candidates}" | grep '^P' | cut -c2- | tr '\n' ' ')"
    candidate_pids="$(printf '%s' "${candidates}" | grep '^C' | cut -c2- | tr '\n' ' ')"
    # Agent PIDs are the candidates that are agents themselves (the roots before
    # descendant expansion). We reconstruct this set from the first "C" entries
    # printed by awk before any children are enumerated.
    agent_pids="$(printf '%s' "${candidates}" | awk '
        /^C/ { pid=substr($0,2); if (!printed[pid]) { print pid; printed[pid]=1 } }
        !/^C/ { next }
    ' | tr '\n' ' ')"

    # Identify the agent IDE/session that owns this init invocation. Processes
    # belonging to the same agent session are ignored; any other agent session in
    # the worktree counts as a live occupant.
    local own_agent_ancestor
    own_agent_ancestor="$(_ag_find_agent_ancestor "$$" "${agent_pids}" "${ppid_map}")"

    # Check cwd for every agent and descendant candidate. Ignore candidates that
    # belong to our own agent session.
    local candidate
    for candidate in ${candidate_pids}; do
        local cwd_link
        cwd_link="$(readlink "/proc/${candidate}/cwd" 2>/dev/null || true)"
        [[ "${cwd_link}" != "${worktree_path}" ]] && continue

        local cand_agent_ancestor
        cand_agent_ancestor="$(_ag_find_agent_ancestor "${candidate}" "${agent_pids}" "${ppid_map}")"
        if [[ -n "${own_agent_ancestor}" && "${cand_agent_ancestor}" == "${own_agent_ancestor}" ]]; then
            continue
        fi

        _AG_OTHER_AGENT_CACHE_WORKTREE="${worktree_path}"
        _AG_OTHER_AGENT_CACHE_TS="${now}"
        _AG_OTHER_AGENT_CACHE_RESULT="0"
        return 0
    done

    _AG_OTHER_AGENT_CACHE_WORKTREE="${worktree_path}"
    _AG_OTHER_AGENT_CACHE_TS="${now}"
    _AG_OTHER_AGENT_CACHE_RESULT="1"
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

    # Pass value through the environment to avoid shell quoting/escaping issues
    # with emoji, apostrophes and JSON-like payloads.
    AG_SAVE_FIELD="${field}" AG_SAVE_VALUE="${value}" AG_SAVE_FILE="${session_file}" ${AG_PYTHON} -c "
import json, time, os
field = os.environ['AG_SAVE_FIELD']
value = os.environ['AG_SAVE_VALUE']
path = os.environ['AG_SAVE_FILE']
with open(path) as f:
    d = json.load(f)
d[field] = value
d['timestamp'] = time.time()
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
" >/dev/null 2>&1
}

# Update the last_activity timestamp for an active session.
# Called by Kimi hooks and the wrapper heartbeat.
_update_last_activity() {
    local identity="$1"
    local session_file
    session_file="$(_get_session_file "${identity}")"
    [[ -f "${session_file}" ]] || return 1

    ${AG_PYTHON} -c "
import json, time, os
with open('${session_file}') as f:
    d = json.load(f)
if d.get('status') != 'active':
    raise SystemExit(1)
d['last_activity'] = time.time()
with open('${session_file}', 'w') as f:
    json.dump(d, f, indent=2)
" >/dev/null 2>&1
}

# Load last_activity from a session file (empty if missing/not active).
_load_last_activity() {
    local identity="$1"
    ${AG_PYTHON} -c "
import json, sys
try:
    with open('$(_get_session_file "${identity}")') as f:
        d = json.load(f)
    if d.get('status') == 'active':
        print(d.get('last_activity', '') or d.get('timestamp', '') or '')
except Exception:
    pass
" 2>/dev/null
}

# Return the configured stale threshold in seconds (default 24h).
# Aplica um floor de 60s para evitar falsos positivos de stale quando o
# threshold esta muito baixo (ex: 0h em testes) e ha latencia entre o
# heartbeat e a checagem.
_stale_threshold_seconds() {
    local hours
    hours="$(_guard_get_str "session.stale_threshold_hours" "24" 2>/dev/null || echo "24")"
    if [[ -z "${hours}" || "${hours}" == "None" || ! "${hours}" =~ ^[0-9]+$ ]]; then
        hours=24
    fi
    local seconds=$((hours * 3600))
    if [[ "${seconds}" -lt 60 ]]; then
        seconds=60
    fi
    echo "${seconds}"
}

# Return true if the session is active but last_activity is older than the threshold.
_is_session_stale() {
    local identity="$1"
    local session_file
    session_file="$(_get_session_file "${identity}")"
    [[ -f "${session_file}" ]] || return 1

    local last_activity threshold now
    last_activity="$(_load_last_activity "${identity}")"
    [[ -n "${last_activity}" ]] || return 1
    threshold="$(_stale_threshold_seconds)"
    now="$(date +%s)"

    if [[ $((now - ${last_activity%.*})) -gt ${threshold} ]]; then
        return 0
    fi
    return 1
}

# Grace period (in seconds) without heartbeat before a live but non-agent
# lease PID may be treated as shell-pinned. Config: session.shell_pin_grace_minutes
# (default 15). A real agent session keeps the heartbeat fresh via the
# UserPromptSubmit hook, so anything past the grace period is suspicious.
_shell_pin_grace_seconds() {
    local minutes
    minutes="$(_guard_get_str "session.shell_pin_grace_minutes" "15" 2>/dev/null || echo "15")"
    if [[ -z "${minutes}" || "${minutes}" == "None" || ! "${minutes}" =~ ^[0-9]+$ ]]; then
        minutes=15
    fi
    local seconds=$((minutes * 60))
    if [[ "${seconds}" -lt 60 ]]; then
        seconds=60
    fi
    echo "${seconds}"
}

# Return true if the given PID exists and its process tree (itself plus all
# transitive descendants) contains a known agent process. Uses the same agent
# name/args predicate as _worktree_has_other_live_agent. A lease recorded
# against a plain interactive shell (e.g. a terminal tab left open after the
# agent died) fails this test, because no agent process survives in its tree.
_pid_tree_has_agent_process() {
    local root_pid="$1"
    [[ -n "${root_pid}" ]] || return 1
    [[ -d "/proc/${root_pid}" ]] || return 1

    # Own PID fails closed: our scan pipeline (ps/awk) carries the agent names
    # in its argv as part of the detection regex, so walking our own tree would
    # always self-match. Treating $$ as "has agent" keeps shared-PID cases
    # conservative (never auto-clear the caller's own lease).
    if [[ "${root_pid}" == "$$" ]]; then
        return 0
    fi

    ps -eo pid,ppid,comm,args 2>/dev/null | awk -v root="${root_pid}" '
    {
        pid=$1; ppid=$2; comm=$3;
        args=""; for (i=4; i<=NF; i++) args = args $i " ";
        children[ppid] = children[ppid] " " pid;
        is_agent[pid] = (comm == "kimi-code" || comm == "claude" || comm == "gemini" || comm == "grok" || comm == "cursor" || comm == "antigravity" || comm == "kiro" || comm == "kimi" || args ~ /(^|[^[:alnum:]_])(kimi-code|claude|gemini|grok|cursor|antigravity|kiro|kimi)([^[:alnum:]_]|$)/) ? 1 : 0;
    }
    END {
        q[0] = root; qi = 0; qn = 1;
        while (qi < qn) {
            cur = q[qi++];
            if (is_agent[cur]) { found = 1; break; }
            if (children[cur] != "") {
                n = split(children[cur], cands, " ");
                for (j=1; j<=n; j++) {
                    cand = cands[j];
                    if (cand != "" && !seen[cand]) {
                        seen[cand] = 1;
                        q[qn++] = cand;
                    }
                }
            }
        }
        exit(found ? 0 : 1);
    }'
}

# Return true when an active session's recorded PID is alive but is NOT an
# agent process tree AND no live agent process occupies the worktree AND the
# heartbeat is past the shell-pin grace period. Such leases are "shell-pinned":
# the agent died but the interactive shell that sourced init survived (e.g. an
# idle terminal tab sitting in the worktree), so the slot looks busy forever.
# Fails closed on any doubt (missing heartbeat, agent in tree, agent in
# worktree) — takeover of a real live session must stay impossible.
_lease_is_shell_pinned() {
    local identity="$1"
    local session_file sess_status sess_pid worktree last_activity grace now
    session_file="$(_get_session_file "${identity}")"
    [[ -f "${session_file}" ]] || return 1

    sess_status="$(_load_session_field "${identity}" "status")"
    [[ "${sess_status}" == "active" ]] || return 1
    sess_pid="$(_load_session_field "${identity}" "pid")"
    [[ -n "${sess_pid}" ]] || return 1
    _is_pid_alive "${sess_pid}" || return 1

    # The recorded PID itself (or any descendant) being an agent means a real
    # session is alive — never auto-clear.
    if _pid_tree_has_agent_process "${sess_pid}"; then
        return 1
    fi

    # Secondary guard: another live agent inside the worktree means real work.
    worktree="$(_get_worktree_path "${identity}")"
    if [[ -d "${worktree}" ]] && _worktree_has_other_live_agent "${worktree}"; then
        return 1
    fi

    # Heartbeat must exist and be past the grace period. Missing heartbeat
    # information fails closed.
    last_activity="$(_load_last_activity "${identity}")"
    [[ -n "${last_activity}" ]] || return 1
    grace="$(_shell_pin_grace_seconds)"
    now="$(date +%s)"
    [[ $((now - ${last_activity%.*})) -gt ${grace} ]]
}

# Build a map of active PIDs to identities. Print lines "pid identity".
_active_pid_identity_map() {
    local session_dir
    session_dir="$(dirname "$(_get_session_file "kimi1")")"
    [[ -d "${session_dir}" ]] || return 0

    for f in "${session_dir}"/*.json; do
        [[ -e "${f}" ]] || continue
        ${AG_PYTHON} -c "
import json, os, sys
try:
    with open('${f}') as fh:
        d = json.load(fh)
    if d.get('status') == 'active' and d.get('pid'):
        print(f\"{d['pid']} {d['identity']}\")
except Exception:
    pass
" 2>/dev/null
    done
}

# Return identities that share the same active PID as another slot.
_detect_shared_pids() {
    local duplicates=""
    declare -A pid_to_identity
    while read -r pid ident; do
        [[ -z "${pid}" || -z "${ident}" ]] && continue
        if [[ -n "${pid_to_identity[${pid}]:-}" ]]; then
            duplicates="${duplicates}${duplicates:+, }${pid_to_identity[${pid}]}&${ident}"
        else
            pid_to_identity["${pid}"]="${ident}"
        fi
    done < <(_active_pid_identity_map)
    echo "${duplicates}"
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
import json, os, time
role = os.environ.get('_AG_S_ROLE') or None
data = {
    'identity': os.environ['_AG_S_IDENTITY'],
    'status': os.environ['_AG_S_STATUS'],
    'role': role,
    'branch': os.environ['_AG_S_BRANCH'],
    'pid': int(os.environ['_AG_S_PID']),
    'timestamp': time.time(),
    'last_activity': time.time(),
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
        if [[ $((_lock_attempt % 10)) -eq 0 ]]; then
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
                    # A live but stale session is treated as free so idle IDE
                    # tabs/conversations do not permanently exhaust slots.
                    # The same applies to leases pinned to a stray non-agent
                    # shell (agent died, terminal tab survived).
                    if _is_session_stale "${identity}"; then
                        _clear_session "${identity}"
                    elif _lease_is_shell_pinned "${identity}"; then
                        echo "🧹 Slot ${identity} pinned to stray non-agent process (PID ${sess_pid}); auto-clearing." >&2
                        _clear_session "${identity}"
                    else
                        return 1
                    fi
                else
                    _clear_session "${identity}"
                fi
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

            # Never recycle a worktree that is on another agent's task or
            # neutral branch. Automatic allocation would orphan the foreign
            # branch by creating a new branch from the base ref. Such slots
            # must be adopted explicitly after confirming the previous session
            # is dead.
            if ! _branch_belongs_to_identity_or_base "${worktree}" "${identity}"; then
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
            echo "❌ Slot '${forced_identity}' is not available (in use, dirty, foreign branch or on cooldown)." >&2
            echo "   Use 'source .hmvip-agent-init --status' to inspect slots." >&2
            echo "   If the slot contains another agent's work, use --adopt only when its session is dead." >&2
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

# Ensure the worktree has up-to-date Git hook stubs that delegate to the
# versioned hooks in packages/agent-guard-core/hooks/. Missing or stale stubs
# are reinstalled from the main repository's .githooks template.
_ensure_hooks_installed() {
    local worktree_path="$1"
    local worktree_hooks_path="${worktree_path}/.githooks"
    local main_hooks_path="${_AG_REPO_ROOT}/.githooks"

    local required_hooks=(
        "pre-commit"
        "post-commit"
        "pre-push"
        "pre-checkout"
        "post-checkout"
        "commit-msg"
    )

    local needs_install=0
    if [[ ! -d "${worktree_hooks_path}" ]]; then
        needs_install=1
    else
        for hook_name in "${required_hooks[@]}"; do
            local stub="${worktree_hooks_path}/${hook_name}"
            if [[ ! -f "${stub}" ]]; then
                needs_install=1
                break
            fi
            # Detect legacy/non-delegating stubs (e.g. empty files or old templates).
            if ! grep -q "packages/agent-guard-core/hooks" "${stub}" 2>/dev/null; then
                needs_install=1
                break
            fi
        done
    fi

    if [[ "${needs_install}" -eq 0 ]]; then
        return 0
    fi

    if [[ ! -d "${main_hooks_path}" ]]; then
        echo "⚠️  Agent Guard: cannot reinstall hooks — main repo template missing at ${main_hooks_path}" >&2
        return 0
    fi

    echo "🔧 Agent Guard: installing/updating hooks in ${worktree_hooks_path}" >&2
    mkdir -p "${worktree_hooks_path}"

    for hook_name in "${required_hooks[@]}"; do
        local main_stub="${main_hooks_path}/${hook_name}"
        local target_stub="${worktree_hooks_path}/${hook_name}"
        if [[ -f "${main_stub}" ]]; then
            cp -p "${main_stub}" "${target_stub}" 2>/dev/null || true
            chmod +x "${target_stub}" 2>/dev/null || true
        fi
    done
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
        timeout 15s git fetch origin >/dev/null 2>&1 || true

        local current_wt_branch
        current_wt_branch="$(git branch --show-current 2>/dev/null || echo "")"
        local identity_prefix="ia-${identity}/"

        if [[ -n "${current_wt_branch}" && "${current_wt_branch}" == ${identity_prefix}* ]]; then
            echo "🔄 Reusing existing branch '${current_wt_branch}' (v4.0)." >&2
            branch_name="${current_wt_branch}"
        else
            # Safety net: refuse to create a new branch on top of another agent's
            # work. This should have been caught by _slot_is_free, but guard here
            # too in case the function is called directly or race conditions occur.
            if [[ -n "${current_wt_branch}" ]] && ! _branch_belongs_to_identity_or_base "${worktree_path}" "${identity}"; then
                echo "" >&2
                echo "❌❌❌ ERROR: FOREIGN BRANCH IN WORKTREE ❌❌❌" >&2
                echo "" >&2
                echo "   Worktree ${worktree_path} is on branch '${current_wt_branch}'," >&2
                echo "   which belongs to another agent or is not a safe base branch." >&2
                echo "" >&2
                echo "   The normal acquisition flow cannot recycle this worktree" >&2
                echo "   because it would orphan the existing branch." >&2
                echo "" >&2
                echo "   To take over this slot only if the previous session is dead:" >&2
                echo "     source .hmvip-agent-init --adopt ${identity}" >&2
                echo "" >&2
                return 1
            fi
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
    _ensure_hooks_installed "${worktree_path}"
    _anti_stale_check "${worktree_path}"
    _session_audit "${worktree_path}"

    echo "${worktree_path}"
    echo "${branch_name}"
}

# ---------------------------------------------------------------------------
# Main entry point: argument parsing + mode execution.
# Wrapped in a function so strict-mode flags can be restored before returning
# to the caller's shell (see hmvip-shell-safety, L222).
# ---------------------------------------------------------------------------
_agent_guard_init_main() {
    # Strict mode is already active at the script level.

# ---------------------------------------------------------------------------
# 6. Parse arguments
# ---------------------------------------------------------------------------
ATTACH_BRANCH=""
ADOPT_IDENTITY=""
PREFIX=""
ROLE=""
IMPACT_PLUGINS=""
FORCED_IDENTITY=""
FORCE_RELEASE="false"
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
        --force)
            FORCE_RELEASE="true"
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
        --cleanup-stale)
            MODE="cleanup-stale"
            shift
            ;;
        --orphan-sweep)
            MODE="orphan-sweep"
            ORPHAN_SWEEP_MODE="${2:---dry-run}"
            if [[ "${ORPHAN_SWEEP_MODE}" == "--auto" || "${ORPHAN_SWEEP_MODE}" == "--dry-run" ]]; then
                shift 2
            else
                shift
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
# Helper: check whether the current branch belongs to the identity that owns
# the worktree, or is a safe base branch (develop, main, etc.). Returns 1 when
# the worktree is on another agent's task/neutral branch.
# ---------------------------------------------------------------------------
_branch_belongs_to_identity_or_base() {
    local worktree_path="$1"
    local identity="$2"

    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"

    # Empty/detached is treated as safe; the worktree setup will create a new
    # branch from the base ref.
    [[ -z "${current_branch}" ]] && return 0

    # Own task branch or own neutral post-release branch.
    if [[ "${current_branch}" == "ia-${identity}/"* || "${current_branch}" == "_released/${identity}" ]]; then
        return 0
    fi

    # Configured base branch (usually develop) and common fallbacks.
    local base_branch
    base_branch="$(_guard_get_str "git.base_branch" "develop")"
    if [[ "${current_branch}" == "${base_branch}" || "${current_branch}" == "origin/${base_branch}" ]]; then
        return 0
    fi
    for fallback in develop main master; do
        if [[ "${current_branch}" == "${fallback}" || "${current_branch}" == "origin/${fallback}" ]]; then
            return 0
        fi
    done

    return 1
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
# Helper: pending-work guard (protocolo 2026-07-17)
#
# Finalizar uma tarefa/spec/correção NÃO libera o slot: na maioria das
# sessões ainda há PRs em andamento (CI, merge queue, correções), e a IA
# estava liberando antecipadamente. O release agora verifica PRs abertos da
# identidade (branches ia-<identity>/*) e:
#   - sem PRs abertos: segue normalmente;
#   - com PRs abertos + TTY (humano): pergunta explicitamente [y/N];
#   - com PRs abertos + não-TTY (IA): BLOQUEIA e exige --force, que só deve
#     ser usado após autorização explícita do usuário;
#   - gh indisponível/erro de rede: fail-open com aviso (guard é proteção
#     contra esquecimento, não trava de disponibilidade).
# ---------------------------------------------------------------------------
_release_pending_work_guard() {
    local identity="$1"
    local worktree_path="$2"
    local force="${3:-false}"

    if ! command -v gh >/dev/null 2>&1; then
        echo "⚠️  gh CLI indisponível — verificação de PRs abertos pulada (release segue)." >&2
        return 0
    fi

    local pr_lines
    if ! pr_lines="$(cd "${worktree_path}" 2>/dev/null && gh pr list --state open --limit 100 \
        --json number,title,headRefName \
        --jq ".[] | select(.headRefName | startswith(\"ia-${identity}/\")) | \"#\\(.number) \\(.headRefName) — \\(.title)\"" 2>/dev/null)"; then
        echo "⚠️  Falha ao consultar PRs abertos via gh — verificação pulada (release segue)." >&2
        return 0
    fi

    local pr_count=0
    if [[ -n "${pr_lines}" ]]; then
        pr_count="$(printf '%s\n' "${pr_lines}" | grep -c . || true)"
    fi

    if [[ "${pr_count}" -eq 0 ]]; then
        return 0
    fi

    if [[ "${force}" == "true" ]]; then
        echo "⚠️  Liberando com ${pr_count} PR(s) aberto(s) de ia-${identity}/* (--force; exige autorização prévia do usuário):" >&2
        printf '%s\n' "${pr_lines}" | sed 's/^/   /' >&2
        return 0
    fi

    # Humano em TTY: pergunta explícita em vez de bloqueio seco.
    if [[ -t 0 ]]; then
        echo "" >&2
        echo "⚠️  ${pr_count} PR(s) aberto(s) de ia-${identity}/*:" >&2
        printf '%s\n' "${pr_lines}" | sed 's/^/   /' >&2
        local answer=""
        read -r -p "   Liberar o slot mesmo assim? [y/N] " answer || answer=""
        if [[ "${answer}" =~ ^[yY]([eE][sS])?$ ]]; then
            return 0
        fi
        echo "🔒 Release cancelado pelo usuário." >&2
        return 1
    fi

    echo "" >&2
    echo "❌❌❌ RELEASE BLOQUEADO: ${pr_count} PR(s) aberto(s) de ia-${identity}/* ❌❌❌" >&2
    echo "" >&2
    printf '%s\n' "${pr_lines}" | sed 's/^/   /' >&2
    echo "" >&2
    echo "   Protocolo (2026-07-17): finalizar tarefa/spec/correção NÃO libera o" >&2
    echo "   slot — a maioria das sessões ainda tem PRs em andamento (CI, merge" >&2
    echo "   queue, correções). Antes de liberar:" >&2
    echo "     1. Apresente os PRs acima ao usuário." >&2
    echo "     2. Só prossiga com autorização explícita dele, usando:" >&2
    echo "        source ${AGENT_GUARD_INIT_NAME:-.hmvip-agent-init} --release --force" >&2
    echo "" >&2
    return 1
}

# ---------------------------------------------------------------------------
# Helper: attempt to release a stale session only when it is safe.
# Safe means: worktree is release-ready and there are no open PRs.
# Returns 0 if released, 1 otherwise (without emitting blocking errors).
# ---------------------------------------------------------------------------
_auto_release_if_safe() {
    local identity="$1"
    local worktree_path="$2"
    local reason="${3:-stale}"

    if ! _validate_worktree_release_ready "${worktree_path}" >/dev/null 2>&1; then
        return 1
    fi

    if ! _release_pending_work_guard "${identity}" "${worktree_path}" "false" >/dev/null 2>&1; then
        return 1
    fi

    _clear_session "${identity}"

    if command -v _journal_release >/dev/null 2>&1; then
        _journal_release
    fi

    local neutral_branch="_released/${identity}"
    local base_ref=""
    if git -C "${worktree_path}" rev-parse --verify --quiet "origin/develop" >/dev/null 2>&1; then
        base_ref="origin/develop"
    elif git -C "${worktree_path}" rev-parse --verify --quiet "develop" >/dev/null 2>&1; then
        base_ref="develop"
    fi

    if [[ -n "${base_ref}" ]]; then
        git -C "${worktree_path}" checkout -B "${neutral_branch}" "${base_ref}" >/dev/null 2>&1 || \
            git -C "${worktree_path}" checkout --detach "${base_ref}" >/dev/null 2>&1 || true
    fi

    echo "🔓 Auto-released ${identity} (${reason})"
    return 0
}

# ---------------------------------------------------------------------------
# Helper: scan all slots and auto-release stale ones that are safe to release.
# ---------------------------------------------------------------------------
_cleanup_stale_sessions() {
    local identity_list prefix i identity worktree_path
    local released=0 skipped=0

    identity_list="$(bash "${AGENT_GUARD_CONFIG_BIN}" keys identities 2>/dev/null || true)"
    for prefix in ${identity_list}; do
        [[ -z "${prefix}" ]] && continue
        local base_slots max_slots
        base_slots="$(_guard_get "identities.${prefix}.slots" 2>/dev/null || echo "0")"
        max_slots="$(_guard_get "identities.${prefix}.max_slots" "${base_slots}" 2>/dev/null || echo "${base_slots}")"
        for i in $(seq 1 "${max_slots}"); do
            identity="${prefix}${i}"
            worktree_path="$(_get_worktree_path "${identity}")"

            local sess_status sess_pid
            sess_status="$(_load_session_field "${identity}" "status")"
            sess_pid="$(_load_session_field "${identity}" "pid")"

            [[ "${sess_status}" == "active" ]] || continue
            _is_pid_alive "${sess_pid}" || continue
            # Stale (24h+) sessions and shell-pinned leases (agent died, stray
            # non-agent shell survived, heartbeat past grace) are eligible.
            if ! _is_session_stale "${identity}" && ! _lease_is_shell_pinned "${identity}"; then
                continue
            fi

            if _auto_release_if_safe "${identity}" "${worktree_path}" "stale"; then
                released=$((released + 1))
            else
                echo "🔒 ${identity} is stale but cannot be auto-released (dirty worktree or open PRs)." >&2
                skipped=$((skipped + 1))
            fi
        done
    done

    echo ""
    echo "🧹 Cleanup complete: ${released} released, ${skipped} skipped."
    return 0 2>/dev/null || exit 0
}

# ---------------------------------------------------------------------------
# Orphan Rescue Protocol helpers
# ---------------------------------------------------------------------------
# Return the configured orphan rescue TTL in days (default 7).
_orphan_rescue_ttl_days() {
    local days
    days="$(_guard_get_str "session.orphan_rescue.ttl_days" "7" 2>/dev/null || echo "7")"
    if [[ -z "${days}" || "${days}" == "None" || ! "${days}" =~ ^[0-9]+$ ]]; then
        days=7
    fi
    echo "${days}"
}

# Return whether orphan rescue sweep is enabled (default true).
_orphan_sweep_enabled() {
    local enabled
    enabled="$(_guard_get_str "session.orphan_rescue.enabled" "true" 2>/dev/null || echo "true")"
    enabled="${enabled,,}"
    [[ "${enabled}" == "true" || "${enabled}" == "1" || "${enabled}" == "yes" ]]
}

# Return true if the identity has open PRs from ia-<identity>/* branches.
_has_open_prs_for_identity() {
    local identity="$1"
    local worktree_path="$2"

    if ! command -v gh >/dev/null 2>&1; then
        # Fail-open when gh is unavailable: assume no PRs so sweep can proceed.
        return 1
    fi

    local pr_count
    pr_count="$(cd "${worktree_path}" 2>/dev/null && gh pr list --state open --limit 100 \
        --json number,headRefName \
        --jq ".[] | select(.headRefName | startswith(\"ia-${identity}/\")) | .number" 2>/dev/null | wc -l || true)"
    [[ "${pr_count}" -gt 0 ]]
}

# Check whether a slot qualifies for orphan rescue sweep.
# Returns 0 when the slot is an orphan with a dirty worktree that we can safely
# rescue and clean. Sets _OS_REASON with a human-readable classification.
_is_orphan_sweep_candidate() {
    local identity="$1"
    local worktree_path="$2"

    _OS_REASON=""

    if [[ ! -e "${worktree_path}/.git" ]]; then
        _OS_REASON="no worktree"
        return 1
    fi

    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"

    # Only process the identity's own branches or its neutral branch.
    if [[ "${current_branch}" != "ia-${identity}/"* && "${current_branch}" != "_released/${identity}" ]]; then
        _OS_REASON="foreign or protected branch: ${current_branch}"
        return 1
    fi

    # Session must be dead (or no session file). Live sessions are never orphans.
    local sess_status sess_pid
    sess_status="$(_load_session_field "${identity}" "status")"
    sess_pid="$(_load_session_field "${identity}" "pid")"
    if [[ "${sess_status}" == "active" && -n "${sess_pid}" ]]; then
        if _is_pid_alive "${sess_pid}"; then
            _OS_REASON="session PID ${sess_pid} is alive"
            return 1
        fi
    fi

    # No other live agent process inside the worktree.
    if _worktree_has_other_live_agent "${worktree_path}"; then
        _OS_REASON="live agent process detected in worktree"
        return 1
    fi

    # Must have uncommitted or untracked work; otherwise cleanup-stale handles it.
    local dirty
    dirty="$(git -C "${worktree_path}" status --porcelain 2>/dev/null || true)"
    if [[ -z "${dirty}" ]]; then
        _OS_REASON="worktree clean"
        return 1
    fi

    # Check for open PRs to avoid destroying work referenced by a PR.
    if _has_open_prs_for_identity "${identity}" "${worktree_path}"; then
        _OS_REASON="open PRs from ia-${identity}/*"
        return 1
    fi

    _OS_REASON="orphan dirty worktree"
    return 0
}

# Create a rescue branch with the current dirty state and push it to origin.
# Prints the rescue branch name on success, returns 1 on failure.
_rescue_orphan_slot() {
    local identity="$1"
    local worktree_path="$2"
    local timestamp
    timestamp="$(date -u +%Y%m%d-%H%M%S)"
    local rescue_branch="ia-${identity}/orphan-rescue/${timestamp}"

    git -C "${worktree_path}" fetch origin >/dev/null 2>&1 || true

    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"

    # Create the rescue branch from the current state.
    if ! git -C "${worktree_path}" checkout -b "${rescue_branch}" >/dev/null 2>&1; then
        echo "❌ Failed to create rescue branch ${rescue_branch}." >&2
        return 1
    fi

    # Stage and commit everything (tracked modifications, deletions, untracked).
    git -C "${worktree_path}" add -A >/dev/null 2>&1 || true
    local commit_msg="rescue(${identity}): orphan worktree snapshot before cleanup [AGENT-GUARD-ORPHAN]"
    if ! git -C "${worktree_path}" commit -m "${commit_msg}" >/dev/null 2>&1; then
        # Empty commit is fine (only untracked that vanished, etc.); abort branch.
        git -C "${worktree_path}" checkout "${current_branch}" >/dev/null 2>&1 || true
        git -C "${worktree_path}" branch -D "${rescue_branch}" >/dev/null 2>&1 || true
        echo "❌ Failed to commit rescue snapshot for ${identity} (no changes?)." >&2
        return 1
    fi

    # Push rescue branch to origin as immutable backup.
    if ! git -C "${worktree_path}" push -u origin "${rescue_branch}" >/dev/null 2>&1; then
        echo "⚠️  Rescue branch created locally but push to origin failed for ${identity}." >&2
        echo "   Branch: ${rescue_branch}" >&2
        return 1
    fi

    echo "${rescue_branch}"
    return 0
}

# Restore the worktree to its neutral post-release branch on top of origin/develop.
_cleanup_rescued_slot() {
    local identity="$1"
    local worktree_path="$2"

    local neutral_branch="_released/${identity}"
    local base_ref=""
    if git -C "${worktree_path}" rev-parse --verify --quiet "origin/develop" >/dev/null 2>&1; then
        base_ref="origin/develop"
    elif git -C "${worktree_path}" rev-parse --verify --quiet "develop" >/dev/null 2>&1; then
        base_ref="develop"
    fi

    if [[ -z "${base_ref}" ]]; then
        echo "❌ Cannot cleanup ${identity}: neither origin/develop nor develop exists." >&2
        return 1
    fi

    # Remove any leftover untracked files and reset to the base ref.
    git -C "${worktree_path}" clean -fd >/dev/null 2>&1 || true
    git -C "${worktree_path}" checkout -B "${neutral_branch}" "${base_ref}" >/dev/null 2>&1 || {
        echo "❌ Failed to reset ${identity} to ${neutral_branch} @ ${base_ref}." >&2
        return 1
    }

    return 0
}

# Append a rescue record to the slot task note.
_note_orphan_rescue() {
    local identity="$1"
    local rescue_branch="$2"
    local note_file="${_AG_REPO_ROOT}/.agent-guard/tasks/${identity}.md"
    if [[ ! -f "${note_file}" ]]; then
        return 0
    fi

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
        echo ""
        echo "## Orphan Rescue — ${timestamp}"
        echo "Slot foi detectado como órfão sujo e resgatado automaticamente."
        echo "Branch de resgate: \`${rescue_branch}\`"
        echo "Para retomar o trabalho resgatado: \`git checkout ${rescue_branch}\`"
    } >> "${note_file}"
}

# Rescue and clean a single orphan slot. Prints status messages.
# Returns 0 on success, 1 on failure.
_orphan_sweep_identity() {
    local identity="$1"
    local worktree_path="$2"
    local dry_run="${3:-false}"

    if ! _is_orphan_sweep_candidate "${identity}" "${worktree_path}"; then
        echo "   ${identity}: ${_OS_REASON} — skipped"
        return 1
    fi

    echo "🚨 ${identity} is an orphan dirty slot."

    if [[ "${dry_run}" == "true" ]]; then
        echo "   [dry-run] Would create rescue branch ia-${identity}/orphan-rescue/YYYYMMDD-HHMMSS"
        echo "   [dry-run] Would reset worktree to _released/${identity} @ origin/develop"
        return 0
    fi

    local rescue_branch
    rescue_branch="$(_rescue_orphan_slot "${identity}" "${worktree_path}")"
    if [[ -z "${rescue_branch}" ]]; then
        echo "❌ ${identity}: rescue branch creation failed — left untouched for manual inspection." >&2
        return 1
    fi

    echo "   🛟 Rescue branch created and pushed: ${rescue_branch}"

    if ! _cleanup_rescued_slot "${identity}" "${worktree_path}"; then
        echo "❌ ${identity}: cleanup after rescue failed." >&2
        echo "   Rescue branch ${rescue_branch} is safe on origin; worktree needs manual repair." >&2
        return 1
    fi

    _clear_session "${identity}"
    _note_orphan_rescue "${identity}" "${rescue_branch}"

    if command -v _journal_write_event >/dev/null 2>&1; then
        _journal_write_event "orphan_rescued" "{\"rescue_branch\":\"${rescue_branch}\",\"identity\":\"${identity}\",\"worktree\":\"${worktree_path}\"}" "${_AG_REPO_ROOT}"
    fi

    echo "   ✅ ${identity} rescued and cleaned."
    return 0
}

# Scan all slots and rescue/clean orphan dirty ones.
# Usage: _orphan_sweep [--dry-run | --auto]
_orphan_sweep() {
    local dry_run="true"
    if [[ "${1:-}" == "--auto" ]]; then
        dry_run="false"
    fi

    if ! _orphan_sweep_enabled; then
        echo "ℹ️  Orphan rescue sweep is disabled in agent-guard.yaml." >&2
        return 0 2>/dev/null || exit 0
    fi

    local identity_list prefix i identity worktree_path
    local rescued=0 skipped=0 failed=0

    identity_list="$(bash "${AGENT_GUARD_CONFIG_BIN}" keys identities 2>/dev/null || true)"
    for prefix in ${identity_list}; do
        [[ -z "${prefix}" ]] && continue
        local base_slots max_slots
        base_slots="$(_guard_get "identities.${prefix}.slots" 2>/dev/null || echo "0")"
        max_slots="$(_guard_get "identities.${prefix}.max_slots" "${base_slots}" 2>/dev/null || echo "${base_slots}")"
        for i in $(seq 1 "${max_slots}"); do
            identity="${prefix}${i}"
            worktree_path="$(_get_worktree_path "${identity}")"

            if _orphan_sweep_identity "${identity}" "${worktree_path}" "${dry_run}"; then
                rescued=$((rescued + 1))
            else
                # Distinguish between "not a candidate" (skipped) and real failure.
                if [[ "${_OS_REASON:-}" == "orphan dirty worktree" ]]; then
                    failed=$((failed + 1))
                else
                    skipped=$((skipped + 1))
                fi
            fi
        done
    done

    echo ""
    if [[ "${dry_run}" == "true" ]]; then
        echo "🔍 Orphan sweep (dry-run): ${rescued} would rescue, ${skipped} skipped, ${failed} failed."
    else
        echo "🧹 Orphan sweep complete: ${rescued} rescued, ${skipped} skipped, ${failed} failed."
    fi
    return 0 2>/dev/null || exit 0
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

    # Guarda de trabalho pendente: release nunca é automático com PRs abertos
    # da identidade — exige confirmação do usuário (TTY) ou --force explícito.
    if ! _release_pending_work_guard "${CURRENT_IDENTITY}" "${CURRENT_WORKTREE}" "${FORCE_RELEASE}"; then
        echo "🔒 Session NOT released. Apresente os PRs ao usuário; com autorização, use --release --force." >&2
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
    printf "%-12s | %-8s | %-6s | %-10s | %-6s | %-8s | %-18s | %-40s\n" "Agent" "Status" "Role" "PID" "WT" "Health" "Tab" "Branch"
    echo "------------------------------------------------------------------"

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
            elif [[ "${_rec_health}" == "stale" ]]; then
                pid_col="${_rec_pid} (stale)"
            fi

            _tab_text="$(_tab_dot_for_state "${_rec_tab_state}" "${_rec_tab_bg}")"
            if [[ -n "${_rec_tab_title}" ]]; then
                _tab_text="${_tab_text} ${_rec_tab_title}"
            fi
            # Keep the tab column narrow; emoji are wide, so truncate conservatively.
            _tab_text="$(${AG_PYTHON} -c "import sys; s=sys.argv[1]; print(s[:17]+'…' if len(s)>18 else s)" "${_tab_text}" 2>/dev/null || printf '%s' "${_tab_text}")"

            printf "%-12s | %-8s | %-6s | %-10s | %-6s | %-8s | %-18s | %-40s\n" \
                "${identity}" "${_rec_status:-free}" "${_rec_role:-}" \
                "${pid_col:-}" "${wt_ok}" "${_rec_health:-}" "${_tab_text}" "${_rec_branch:-}"

            if [[ "${_rec_health}" != "-" && "${_rec_health}" != "live" ]]; then
                any_drift="${any_drift}\n  ${_rec_drift:-drift}: ${identity} -> ${_rec_branch:-<no branch>}"
            fi
        done
    done
    echo "=========================================================="

    # Shared-PID guard: surface when one IDE process holds multiple leases.
    local shared_pids
    shared_pids="$(_detect_shared_pids)"
    if [[ -n "${shared_pids}" ]]; then
        echo ""
        echo "⚠️  Shared PID detected (one IDE process holding multiple slots):"
        echo "   ${shared_pids}"
        echo ""
    fi

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
# 8.5 --cleanup-stale mode
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "cleanup-stale" ]]; then
    _cleanup_stale_sessions
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# 8.6 --orphan-sweep mode
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "orphan-sweep" ]]; then
    _orphan_sweep "${ORPHAN_SWEEP_MODE:---dry-run}"
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
    timeout 15s git fetch origin >/dev/null 2>&1 || true

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
    _ensure_hooks_installed "${WORKTREE_PATH}"
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
    # NOTE: we intentionally do NOT compare the stored PID against the current
    # session's PID. A previous version of this guard allowed the current
    # process to adopt another slot when both happened to share the same PID
    # (e.g. multiple adopts sourced from the same shell / IDE process), which
    # violates the 1-slot-per-session invariant and causes slots to become
    # pinned to a single shared PID. Adopt is strictly for dead sessions.
    adopt_sess_status="$(_load_session_field "${ADOPT_IDENTITY}" "status")"
    adopt_sess_pid="$(_load_session_field "${ADOPT_IDENTITY}" "pid")"
    if [[ "${adopt_sess_status}" == "active" && -n "${adopt_sess_pid}" ]]; then
        if _is_pid_alive "${adopt_sess_pid}"; then
            # A live PID is not always a live session: when the agent dies but
            # the interactive shell that sourced init survives (idle terminal
            # tab sitting in the worktree), the lease stays pinned to that
            # shell and adopt would be blocked forever. Auto-clear only when
            # the PID tree has no agent process, no agent lives in the
            # worktree and the heartbeat is past the shell-pin grace period.
            if _lease_is_shell_pinned "${ADOPT_IDENTITY}"; then
                echo "🧹 Lease for ${ADOPT_IDENTITY} pinned to stray non-agent process (PID ${adopt_sess_pid}); auto-clearing." >&2
                _clear_session "${ADOPT_IDENTITY}"
            else
                echo "" >&2
                echo "❌❌❌ ERROR: SLOT STILL IN USE ❌❌❌" >&2
                echo "" >&2
                echo "   Identity '${ADOPT_IDENTITY}' is held by live PID ${adopt_sess_pid}." >&2
                echo "   Adopt only works on slots whose previous session is dead." >&2
                echo "" >&2
                return 1 2>/dev/null || exit 1
            fi
        else
            echo "🧹 Clearing stale session for ${ADOPT_IDENTITY} (PID ${adopt_sess_pid} is dead)." >&2
            _clear_session "${ADOPT_IDENTITY}"
        fi
    fi

    # Secondary guard: even if the session file is free/stale, refuse to adopt
    # when another live agent process is currently inside the worktree.
    if _worktree_has_other_live_agent "${WORKTREE_PATH}"; then
        echo "" >&2
        echo "❌❌❌ ERROR: WORKTREE HELD BY LIVE AGENT PROCESS ❌❌❌" >&2
        echo "" >&2
        echo "   Another live agent process was detected in ${WORKTREE_PATH}." >&2
        echo "   Adopt only works on slots whose previous session is dead." >&2
        echo "" >&2
        return 1 2>/dev/null || exit 1
    fi

    cd "${WORKTREE_PATH}" || return 1 2>/dev/null || exit 1
    timeout 15s git fetch origin >/dev/null 2>&1 || true

    ADOPT_BRANCH="$(git branch --show-current 2>/dev/null || echo "")"
    ADOPT_FOREIGN_BRANCH="false"
    if [[ "${ADOPT_BRANCH}" != "ia-${ADOPT_IDENTITY}/"* && "${ADOPT_BRANCH}" != "_released/${ADOPT_IDENTITY}" ]]; then
        if ! _branch_belongs_to_identity_or_base "${WORKTREE_PATH}" "${ADOPT_IDENTITY}"; then
            ADOPT_FOREIGN_BRANCH="true"
        else
            echo "" >&2
            echo "❌❌❌ ERROR: PROTECTED BRANCH ❌❌❌" >&2
            echo "" >&2
            echo "   Worktree ${WORKTREE_PATH} is on branch '${ADOPT_BRANCH:-<detached>}'." >&2
            echo "   Adopt only resumes this identity's own branches:" >&2
            echo "     ia-${ADOPT_IDENTITY}/... or _released/${ADOPT_IDENTITY}" >&2
            echo "   or a safe base branch." >&2
            echo "" >&2
            return 1 2>/dev/null || exit 1
        fi
    fi

    echo ""
    echo "=========================================================="
    if [[ "${ADOPT_FOREIGN_BRANCH}" == "true" ]]; then
        echo "🛡️  Agent Guard: ADOPTING ORPHAN slot ${ADOPT_IDENTITY}"
    else
        echo "🛡️  Agent Guard: ADOPTING slot ${ADOPT_IDENTITY}"
    fi
    echo "=========================================================="
    echo "   Worktree: ${WORKTREE_PATH}"
    echo "   Branch:   ${ADOPT_BRANCH}"
    if [[ "${ADOPT_FOREIGN_BRANCH}" == "true" ]]; then
        echo ""
        echo "⚠️  This worktree contains a branch from another agent/identity."
        echo "   The previous session was confirmed dead; you are adopting an orphan slot."
        echo "   Do not commit/push to this branch unless you have verified ownership."
    fi

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
    _ensure_hooks_installed "${WORKTREE_PATH}"
    _anti_stale_check "${WORKTREE_PATH}"

    impact_json="$(echo "${IMPACT_PLUGINS}" | ${AG_PYTHON} -c "import sys,json; print(json.dumps([p.strip() for p in sys.stdin.read().split(',') if p.strip()]))" 2>/dev/null || echo "[]")"
    _save_session "${ADOPT_IDENTITY}" "active" "${ROLE}" "${ADOPT_BRANCH}" "$(_ag_session_pid "${WORKTREE_PATH}")" "${WORKTREE_PATH}" "${impact_json}"

    # Expanded slots (beyond the base count) must have a retomada note.
    _ensure_task_note "${ADOPT_IDENTITY}"

    if command -v _journal_adopt >/dev/null 2>&1; then
        _journal_adopt "${ADOPT_BRANCH}"
    fi
    if command -v _journal_checkpoint >/dev/null 2>&1; then
        if [[ "${ADOPT_FOREIGN_BRANCH}" == "true" ]]; then
            _journal_checkpoint "session adopted (orphan foreign branch)" "${WORKTREE_PATH}" "${ADOPT_BRANCH}"
        else
            _journal_checkpoint "session adopted" "${WORKTREE_PATH}" "${ADOPT_BRANCH}"
        fi
    fi

    echo "✅ Git author set to ${GIT_AUTHOR_EMAIL}"
    if [[ "${ADOPT_FOREIGN_BRANCH}" == "true" ]]; then
        echo "✅ Session active on ${ADOPT_IDENTITY} — orphan slot adopted."
    else
        echo "✅ Session active on ${ADOPT_IDENTITY} — resumed from previous state."
    fi
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
    _ensure_hooks_installed "${CURRENT_WORKTREE}"
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
}

# ---------------------------------------------------------------------------
# Execute the main body unless this script was sourced only to load helpers.
# The caller's shell flags are always restored before returning.
# ---------------------------------------------------------------------------
_RC=0
if [[ "${AGENT_GUARD_FUNCTIONS_ONLY:-}" != "1" ]]; then
    _agent_guard_init_main "$@" || _RC=$?
fi
_ag_init_restore_shell_flags
return ${_RC}
