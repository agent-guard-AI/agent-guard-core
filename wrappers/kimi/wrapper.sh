#!/usr/bin/env bash
#
# Agent Guard — Kimi CLI Wrapper
#
# Mandatory agent isolation enforcement for the Kimi Code CLI.
# Every invocation of `kimi` inside an Agent Guard managed repository is
# routed through here, ensuring that:
#
#   1. No agent works directly in the main repository.
#   2. No agent reuses another agent's worktree.
#   3. A valid agent-guard lease is acquired before any work.
#   4. Dirty foreign work is detected and blocked at session start.
#
# The wrapper reads its configuration from agent-guard.yaml (SSOT) in the
# repository it is invoked from. Project-specific paths are no longer hardcoded.
#
# Installation:
#   mv <bin_dir>/kimi <bin_dir>/kimi.real
#   cp <path-to>/wrappers/kimi/wrapper.sh <bin_dir>/kimi
#   chmod +x <bin_dir>/kimi
#
# Emergency bypass (use only for debugging/recovery):
#   AG_WRAPPER_BYPASS=1 kimi ...
#   AG_WRAPPER_BYPASS=1 kimi ...  # legacy alias
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Emergency bypass (canonical env var + legacy alias)
# ---------------------------------------------------------------------------
if [[ "${AG_WRAPPER_BYPASS:-}" == "1" || "${AG_WRAPPER_BYPASS:-}" == "1" ]]; then
    # REAL_KIMI is resolved later; bypass is handled after config load.
    # We need it now, so perform a minimal resolution.
    _AG_REAL_KIMI="${AG_KIMI_REAL:-${AG_KIMI_REAL:-}}"
    if [[ -z "${_AG_REAL_KIMI}" ]]; then
        # Try common locations.
        _AG_REAL_KIMI_CANDIDATES=("${HOME}/.kimi-code/bin/kimi.real" "$(command -v kimi.real 2>/dev/null || true)")
        for candidate in "${_AG_REAL_KIMI_CANDIDATES[@]}"; do
            if [[ -n "${candidate}" && -x "${candidate}" ]]; then
                _AG_REAL_KIMI="${candidate}"
                break
            fi
        done
    fi
    if [[ -z "${_AG_REAL_KIMI}" || ! -x "${_AG_REAL_KIMI}" ]]; then
        echo "❌ AG WRAPPER: cannot locate real kimi binary for bypass." >&2
        exit 1
    fi
    exec "${_AG_REAL_KIMI}" "$@"
fi

# ---------------------------------------------------------------------------
# 0.5 Explicit slot selection: --slot <identity> or AGENT_GUARD_SLOT
# ---------------------------------------------------------------------------
# Allows starting the agent directly into a specific slot in one command:
#
#   kimi --slot kimi3            # acquire (or adopt) slot kimi3, then launch
#   AGENT_GUARD_SLOT=kimi3 kimi  # same, via environment variable
#
# The flag is consumed by the wrapper and never forwarded to the real CLI.
# If the Kimi CLI ever introduces its own --slot flag, use AGENT_GUARD_SLOT.
_AG_SLOT="${AGENT_GUARD_SLOT:-}"
if [[ $# -gt 0 ]]; then
    _AG_REMAINING_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slot)
                if [[ -z "${2:-}" ]]; then
                    echo "❌ AG WRAPPER: --slot requires an identity (ex: kimi3)." >&2
                    exit 1
                fi
                _AG_SLOT="$2"
                shift 2
                ;;
            --slot=*)
                _AG_SLOT="${1#--slot=}"
                shift
                ;;
            *)
                _AG_REMAINING_ARGS+=("$1")
                shift
                ;;
        esac
    done
    if [[ "${#_AG_REMAINING_ARGS[@]}" -gt 0 ]]; then
        set -- "${_AG_REMAINING_ARGS[@]}"
    else
        set --
    fi
fi

# ---------------------------------------------------------------------------
# 1. Resolve current working directory
# ---------------------------------------------------------------------------
CWD="$(pwd -P 2>/dev/null || pwd)"

# Pin the lease anchor PID to this wrapper process: the init script is
# sourced below (non-interactive shell) and this same PID survives the final
# `exec` into kimi.real, so the lease stays bound to the agent process
# instead of the wrapper's parent shell (see _ag_session_pid in init.sh).
# Unset first to avoid inheriting a stale pin from a parent Agent Guard session
# (e.g. a nested `source .hmvip-agent-init` inside another leased worktree).
unset AGENT_GUARD_SESSION_PID
export AGENT_GUARD_SESSION_PID="$$"

# Never inherit lease state from a parent Agent Guard session (e.g. a nested
# `kimi` invocation from inside an existing agent session): these variables
# are produced by THIS wrapper after the init script runs. A stale inherited
# value would make _ag_have_lease short-circuit the lease acquisition below
# with the parent session's identity/worktree/branch.
unset _AG_WORKTREE _AG_IDENTITY _AG_BRANCH
unset _HMVIP_WORKTREE _HMVIP_IDENTITY _HMVIP_BRANCH
unset AG_WORKTREE_PATH AG_BRANCH
unset AGENT_GUARD_WORKTREE_PATH AGENT_GUARD_IDENTITY AGENT_GUARD_BRANCH

# Resolve a usable Python interpreter cross-platform.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AG_PYTHON="$(bash "${SCRIPT_DIR}/bin/agent-guard-python" 2>/dev/null || echo "python3")"
export AG_PYTHON

# ---------------------------------------------------------------------------
# 2. Load repository configuration from agent-guard.yaml
# ---------------------------------------------------------------------------
_AG_CONFIG_LOADED="false"
_AG_REPO_ROOT=""
_AG_PACKAGE_ROOT=""
_AG_CONFIG_BIN=""
_AG_MAIN_REPO=""
_AG_BASE_DIR=""
_AG_BIN_DIR=""
_AG_REAL_BIN_NAME=""
_AG_REAL_KIMI=""
_AG_IDENTITY_VAR=""
_AG_KNOWN_IDENTITIES=""

try_source_real_kimi() {
    local bin_dir="$1"
    local real_name="$2"
    if [[ -n "${bin_dir}" && -n "${real_name}" && -x "${bin_dir}/${real_name}" ]]; then
        echo "${bin_dir}/${real_name}"
        return 0
    fi
    return 1
}

_ag_load_config() {
    local git_root
    git_root="$(git -C "${CWD}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "${git_root}" ]]; then
        return 1
    fi

    # The SSOT configuration file must exist. Without it we cannot determine
    # main repo, base dir, identities or wrapper paths safely.
    if [[ ! -f "${git_root}/agent-guard.yaml" ]]; then
        return 1
    fi

    local package_root
    package_root="$(bash "${git_root}/packages/agent-guard-core/bin/agent-guard-config" get paths.package_root 'packages/agent-guard-core' 2>/dev/null || echo 'packages/agent-guard-core')"
    local config_bin="${git_root}/${package_root}/bin/agent-guard-config"
    if [[ ! -f "${config_bin}" ]]; then
        return 1
    fi

    _AG_REPO_ROOT="${git_root}"
    _AG_PACKAGE_ROOT="${package_root}"
    _AG_CONFIG_BIN="${config_bin}"
    _AG_MAIN_REPO="$(bash "${config_bin}" get paths.main_repo "${git_root}" 2>/dev/null || echo "${git_root}")"
    _AG_BASE_DIR="$(bash "${config_bin}" get paths.base_dir "$(dirname "${_AG_MAIN_REPO}")" 2>/dev/null || echo "$(dirname "${_AG_MAIN_REPO}")")"
    _AG_BIN_DIR="$(bash "${config_bin}" get wrappers.kimi.bin_dir "${HOME}/.kimi-code/bin" 2>/dev/null || echo "${HOME}/.kimi-code/bin")"
    _AG_REAL_BIN_NAME="$(bash "${config_bin}" get wrappers.kimi.real_bin 'kimi.real' 2>/dev/null || echo 'kimi.real')"
    _AG_IDENTITY_VAR="$(bash "${config_bin}" get commit.identity_env_var 'AGENT_GUARD_IDENTITY' 2>/dev/null || echo 'AGENT_GUARD_IDENTITY')"
    _AG_INIT_SCRIPT_NAME="$(bash "${config_bin}" get paths.init_script '.agent-guard-init' 2>/dev/null || echo '.agent-guard-init')"
    _AG_KNOWN_IDENTITIES="$(bash "${config_bin}" keys identities 2>/dev/null || true)"
    _AG_STARTUP_DAILY_CHECK_ENABLED="$(bash "${config_bin}" get wrappers.kimi.startup_daily_check.enabled 'false' 2>/dev/null || echo 'false')"
    _AG_STARTUP_DAILY_CHECK_BACKGROUND="$(bash "${config_bin}" get wrappers.kimi.startup_daily_check.background 'true' 2>/dev/null || echo 'true')"
    _AG_STARTUP_DAILY_CHECK_SCRIPT="$(bash "${config_bin}" get wrappers.kimi.startup_daily_check.script_path '.agent/scripts/hmvip-luna-daily-issue-digest.sh' 2>/dev/null || echo '.agent/scripts/hmvip-luna-daily-issue-digest.sh')"

    # Resolve real kimi binary.
    if ! _AG_REAL_KIMI="$(try_source_real_kimi "${_AG_BIN_DIR}" "${_AG_REAL_BIN_NAME}")"; then
        # Fallback: search in PATH.
        local path_candidate
        path_candidate="$(command -v "${_AG_REAL_BIN_NAME}" 2>/dev/null || true)"
        if [[ -n "${path_candidate}" && -x "${path_candidate}" ]]; then
            _AG_REAL_KIMI="${path_candidate}"
        fi
    fi

    _AG_CONFIG_LOADED="true"
    return 0
}

# Heuristic: is CWD a git repository that looks like an Agent Guard main repo
# but whose config could not be loaded? This usually means the main repo is on
# a detached/neutral branch (e.g. _released/*) or is missing agent-guard.yaml.
_ag_looks_like_main_repo() {
    if ! git -C "${CWD}" rev-parse --show-toplevel >/dev/null 2>&1; then
        return 1
    fi
    # Presence of the package or init stubs strongly indicates the main repo.
    if [[ -d "${CWD}/packages/agent-guard-core" || -f "${CWD}/.agent-guard-init" || -f "${CWD}/.hmvip-agent-init" ]]; then
        return 0
    fi
    return 1
}

if ! _ag_load_config; then
    if _ag_looks_like_main_repo; then
        echo "❌❌❌ AG WRAPPER: main repository is not in a leasable state." >&2
        echo "" >&2
        echo "   The wrapper could not load agent-guard.yaml from:" >&2
        echo "     ${CWD}" >&2
        echo "" >&2
        echo "   Common causes:" >&2
        echo "     - The main repo is on a neutral branch (e.g. _released/*)." >&2
        echo "     - The main repo is outdated and missing agent-guard.yaml." >&2
        echo "     - agent-guard.yaml was deleted or renamed." >&2
        echo "" >&2
        echo "   Required actions (run as the repo owner, not as an AI agent):" >&2
        echo "     cd ${CWD}" >&2
        echo "     git checkout develop" >&2
        echo "     git pull origin develop" >&2
        echo "     # ensure agent-guard.yaml exists" >&2
        echo "" >&2
        echo "   Emergency bypass (use only for recovery):" >&2
        echo "     AG_WRAPPER_BYPASS=1 kimi ..." >&2
        exit 1
    fi

    # Not in an Agent Guard managed repository; pass through unchanged.
    # We still need a real binary. Try to find it.
    _AG_REAL_KIMI="${AG_KIMI_REAL:-${AG_KIMI_REAL:-}}"
    if [[ -z "${_AG_REAL_KIMI}" ]]; then
        for candidate in "${HOME}/.kimi-code/bin/kimi.real" "$(command -v kimi.real 2>/dev/null || true)" "$(command -v kimi 2>/dev/null || true)"; do
            if [[ -n "${candidate}" && -x "${candidate}" ]]; then
                _AG_REAL_KIMI="${candidate}"
                break
            fi
        done
    fi
    if [[ -n "${_AG_REAL_KIMI}" && -x "${_AG_REAL_KIMI}" ]]; then
        exec "${_AG_REAL_KIMI}" "$@"
    fi
    echo "❌ AG WRAPPER: cannot locate real kimi binary." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. If not inside this ecosystem, pass through unchanged
# ---------------------------------------------------------------------------
if [[ "${CWD}" != "${_AG_MAIN_REPO}"* ]]; then
    _AG_INSIDE_WORKTREE="false"
    for prefix in ${_AG_KNOWN_IDENTITIES}; do
        _AG_WT_PREFIX="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.worktree_prefix" '' 2>/dev/null || true)"
        if [[ -n "${_AG_WT_PREFIX}" && "${CWD}" == "${_AG_BASE_DIR}/${_AG_WT_PREFIX}"* ]]; then
            _AG_INSIDE_WORKTREE="true"
            break
        fi
    done
    if [[ "${_AG_INSIDE_WORKTREE}" != "true" ]]; then
        if [[ -n "${_AG_REAL_KIMI}" && -x "${_AG_REAL_KIMI}" ]]; then
            exec "${_AG_REAL_KIMI}" "$@"
        fi
        echo "❌ AG WRAPPER: cannot locate real kimi binary." >&2
        exit 1
    fi
fi

if [[ -z "${_AG_REAL_KIMI}" || ! -x "${_AG_REAL_KIMI}" ]]; then
    echo "❌ AG WRAPPER: real kimi binary not found at ${_AG_BIN_DIR}/${_AG_REAL_BIN_NAME}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Management/read-only commands do not require a lease
# ---------------------------------------------------------------------------
_ag_is_management_command() {
    for arg in "$@"; do
        case "${arg}" in
            --version|-V|--help|-h|update|upgrade|doctor|login|provider|export|migrate|acp)
                return 0
                ;;
        esac
    done
    return 1
}

if _ag_is_management_command "$@"; then
    exec "${_AG_REAL_KIMI}" "$@"
fi

# ---------------------------------------------------------------------------
# 5. Helper: check whether a lease is already active for this shell
# ---------------------------------------------------------------------------
_ag_have_lease() {
    [[ -n "${_AG_WORKTREE:-}" && -n "${_AG_IDENTITY:-}" && -n "${_AG_BRANCH:-}" ]]
}

# ---------------------------------------------------------------------------
# 6. Helper: detect if current directory is inside a foreign worktree
# ---------------------------------------------------------------------------
_ag_is_foreign_worktree() {
    local current_worktree
    current_worktree="${_AG_WORKTREE:-}"

    # If cwd is main repo, it is not a worktree path
    if [[ "${CWD}" == "${_AG_MAIN_REPO}" ]]; then
        return 1
    fi

    # If cwd is exactly our leased worktree, OK
    if [[ "${CWD}" == "${current_worktree}" ]]; then
        return 1
    fi

    # If cwd is inside another agent worktree, it is foreign
    for prefix in ${_AG_KNOWN_IDENTITIES}; do
        local wt_prefix
        wt_prefix="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.worktree_prefix" '' 2>/dev/null || true)"
        if [[ -n "${wt_prefix}" && "${CWD}" == "${_AG_BASE_DIR}/${wt_prefix}"* ]]; then
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# 7. Helper: verify leased worktree is not dirty with foreign work
# ---------------------------------------------------------------------------
_ag_check_worktree_clean() {
    local worktree="$1"
    local identity="$2"

    if [[ ! -d "${worktree}" ]]; then
        echo "❌ AG WRAPPER: leased worktree does not exist: ${worktree}" >&2
        return 1
    fi

    local status_output
    status_output="$(git -C "${worktree}" status --porcelain=v1 2>/dev/null || true)"

    if [[ -z "${status_output}" ]]; then
        return 0
    fi

    if [[ "${AG_ALLOW_DIRTY_WORKTREE:-}" != "1" && "${AG_ALLOW_DIRTY_WORKTREE:-}" != "1" ]]; then
        echo "❌ AG WRAPPER: worktree ${worktree} has uncommitted changes." >&2
        echo "   Identity: ${identity}" >&2
        echo "   Resolve before starting a new session (commit, stash, or run with AG_ALLOW_DIRTY_WORKTREE=1 for recovery)." >&2
        echo "" >&2
        echo "   git status:" >&2
        git -C "${worktree}" status --short >&2
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# 8. Acquire lease if needed
# ---------------------------------------------------------------------------
_ag_worktree_is_dirty() {
    local worktree="$1"
    local output
    output="$(git -C "${worktree}" status --porcelain=v1 2>/dev/null || true)"
    [[ -n "${output}" ]]
}

# Return 0 if the PID refers to a healthy, runnable process.
# Mirrors _is_pid_alive in init.sh: checks signal ability and rejects
# traced/stopped/zombie/dead states. This prevents a zombie PID from being
# treated as a live session holder (incident 2026-08-04).
_ag_pid_is_alive() {
    local pid="$1"
    [[ -z "${pid}" ]] && return 1
    if ! kill -0 "${pid}" 2>/dev/null; then
        return 1
    fi
    local proc_stat
    proc_stat="$(sed -n 's/.*) \([A-Za-z]\).*/\1/p' "/proc/${pid}/stat" 2>/dev/null || echo "")"
    case "${proc_stat}" in
        T|Z|X|x)
            return 1
            ;;
    esac
    return 0
}

# Caches for the single process scan performed per wrapper invocation.
# With hundreds of thousands of threads on the host, scanning /proc multiple
# times in shell is the dominant cost of opening a slot. We use `ps` (C
# implementation) once, identify agent processes and their descendants, then
# read cwd only for those candidates.
_AG_PROC_SCAN_AGENT_PIDS=""
_AG_PROC_SCAN_WORKTREE_PIDS=""
_AG_PROC_SCAN_PPID_MAP=""

# Perform one fast scan and cache the result.
_ag_scan_proc_once() {
    [[ -n "${_AG_PROC_SCAN_AGENT_PIDS:-}" ]] && return 0

    local wt_prefixes="" prefix
    for prefix in ${_AG_KNOWN_IDENTITIES}; do
        local wt_prefix
        wt_prefix="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.worktree_prefix" '' 2>/dev/null || true)"
        if [[ -n "${wt_prefix}" ]]; then
            wt_prefixes="${wt_prefixes}${wt_prefixes:+,}${_AG_BASE_DIR}/${wt_prefix}"
        fi
    done

    local parsed
    parsed="$(ps -eo pid,ppid,comm,args 2>/dev/null | tail -n +2 | awk '
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

    _AG_PROC_SCAN_PPID_MAP="$(printf '%s' "${parsed}" | grep '^P' | cut -c2- | tr '\n' ' ')"
    local candidates="$(printf '%s' "${parsed}" | grep '^C' | cut -c2- | tr '\n' ' ')"

    local agent_pids="" worktree_pids=""
    local pid_num cwd_link
    for pid_num in ${candidates}; do
        [[ -n "${pid_num}" ]] || continue
        agent_pids="${agent_pids}${agent_pids:+ }${pid_num}"
        cwd_link="$(readlink "/proc/${pid_num}/cwd" 2>/dev/null || true)"
        if [[ -n "${cwd_link}" && -n "${wt_prefixes}" ]]; then
            case ",${wt_prefixes}," in
                *,"${cwd_link}"/*,*|*,"${cwd_link}",*)
                    worktree_pids="${worktree_pids}${worktree_pids:+ }${pid_num}"
                    ;;
            esac
        fi
    done

    _AG_PROC_SCAN_AGENT_PIDS="${agent_pids}"
    _AG_PROC_SCAN_WORKTREE_PIDS="${worktree_pids}"
}

# Walk the parent chain using the cached PPID map and return the top-most
# (root) agent process that owns this process tree. We keep walking instead of
# stopping at the first agent because args-based detection can flag the current
# shell/wrapper itself as an agent (e.g. its argv contains a .kimi-code path);
# the meaningful session owner is the IDE/agent root at the top of the chain.
_ag_find_agent_ancestor() {
    local start_pid="$1"
    local current_pid="${start_pid}"
    local visited=""
    local root_agent=""

    while [[ -n "${current_pid}" && "${current_pid}" != "1" ]]; do
        if [[ "${visited}" =~ (^|[[:space:]])${current_pid}([[:space:]]|$) ]]; then
            break
        fi
        visited="${visited} ${current_pid}"

        # Is this PID itself an agent? Track the highest one we find.
        if [[ " ${_AG_PROC_SCAN_AGENT_PIDS} " =~ [[:space:]]${current_pid}[[:space:]] ]]; then
            root_agent="${current_pid}"
        fi

        current_pid="$(printf '%s' "${_AG_PROC_SCAN_PPID_MAP}" | tr ' ' '\n' | grep "^${current_pid}:" | head -n1 | cut -d: -f2)"
    done

    if [[ -n "${root_agent}" ]]; then
        echo "${root_agent}"
        return 0
    fi
    return 1
}

_ag_worktree_has_live_agent() {
    local worktree="$1"

    _ag_scan_proc_once

    # Identify the agent IDE/session that owns this wrapper invocation. Processes
    # belonging to the same agent session are ignored; any other agent session in
    # the worktree counts as a live occupant.
    local own_agent_ancestor
    own_agent_ancestor="$(_ag_find_agent_ancestor "$$")"

    # _AG_PROC_SCAN_WORKTREE_PIDS contains agent/descendant candidates whose cwd
    # is inside some agent worktree. Narrow to the target worktree and exclude
    # candidates that belong to our own agent session.
    local pid_num
    for pid_num in ${_AG_PROC_SCAN_WORKTREE_PIDS}; do
        local cwd_link
        cwd_link="$(readlink "/proc/${pid_num}/cwd" 2>/dev/null || true)"
        [[ "${cwd_link}" != "${worktree}" ]] && continue

        local cand_agent_ancestor
        cand_agent_ancestor="$(_ag_find_agent_ancestor "${pid_num}")"
        if [[ -n "${own_agent_ancestor}" && "${cand_agent_ancestor}" == "${own_agent_ancestor}" ]]; then
            continue
        fi

        return 0
    done

    return 1
}

# Per-invocation log file. Using a slot-specific path prevents parallel wrapper
# invocations from clobbering each other's lease output in /tmp.
_AG_WRAPPER_LOG="/tmp/ag-wrapper-lease-${_AG_SLOT:-$$}.log"

# ---------------------------------------------------------------------------
# Public session snapshot (F5B) — leitura unica do session storage via facade
# agent-guard-slots. Substitui leituras diretas de
# .kiro/locks/agent-sessions/*.json. O snapshot fica em cache pela vida do
# wrapper. Fail-open: se a facade falhar, o snapshot fica vazio e todos os
# consumidores abaixo se comportam exatamente como com arquivo de sessao
# ausente (comportamento anterior preservado).
_AG_SLOTS_SNAPSHOT=""
_ag_slots_snapshot() {
    if [[ -z "${_AG_SLOTS_SNAPSHOT}" ]]; then
        # Resolve the facade from the repo's package copy (next to the config
        # bin), not from SCRIPT_DIR: the installed wrapper lives outside the
        # package (e.g. ~/.kimi-code/bin/kimi), where SCRIPT_DIR/../.. is not
        # the package root.
        local _slots_bin
        _slots_bin="$(dirname "${_AG_CONFIG_BIN}")/agent-guard-slots"
        _AG_SLOTS_SNAPSHOT="$(AGENT_GUARD_REPO_ROOT="${_AG_MAIN_REPO}" bash "${_slots_bin}" 2>/dev/null || true)"
        if [[ -z "${_AG_SLOTS_SNAPSHOT}" ]] || ! printf '%s' "${_AG_SLOTS_SNAPSHOT}" | ${AG_PYTHON} -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
            _AG_SLOTS_SNAPSHOT='{"schema_version":3,"command":"slots","slots":[]}'
        fi
    fi
    printf '%s' "${_AG_SLOTS_SNAPSHOT}"
}

# _ag_slot_field <identity> <field> — valor de um campo no snapshot publico.
# Vazio quando a identidade nao tem entrada (equivale a arquivo ausente).
_ag_slot_field() {
    local _field_id="$1" _field_name="$2"
    printf '%s' "$(_ag_slots_snapshot)" | ${AG_PYTHON} -c '
import json, sys
_id, field = sys.argv[1], sys.argv[2]
try:
    slots = json.load(sys.stdin).get("slots", [])
except Exception:
    slots = []
for s in slots:
    if s.get("identity") == _id:
        v = s.get(field, "")
        print("" if v is None else v)
        break
' "${_field_id}" "${_field_name}" 2>/dev/null || true
}

# Return the most recent resumable worktree for a given identity prefix.
# Reads the newest entries from the Agent Guard journal and, for the newest
# identity matches ${prefix}<number>, checks whether the recorded worktree is
# available and not held by another live agent process.
# This enables "sticky sessions" without reading a multi-MB journal in full.
_ag_find_resumable_worktree() {
    local prefix="$1"
    local journal_path
    journal_path="${_AG_MAIN_REPO}/$(bash "${_AG_CONFIG_BIN}" get journal.path ".agent-guard/journal/agent-guard.jsonl" 2>/dev/null || echo ".agent-guard/journal/agent-guard.jsonl")"
    [[ ! -f "${journal_path}" ]] && return 1

    # Identify the agent IDE/session that owns this wrapper invocation so the
    # Python helper can ignore processes from the same session.
    local own_agent_ancestor
    _ag_scan_proc_once
    own_agent_ancestor="$(_ag_find_agent_ancestor "$$")"

    local slots_snapshot
    slots_snapshot="$(_ag_slots_snapshot)"

    ${AG_PYTHON} - "${journal_path}" "${prefix}" "${slots_snapshot}" "${own_agent_ancestor}" "${_AG_PROC_SCAN_AGENT_PIDS}" "${_AG_PROC_SCAN_WORKTREE_PIDS}" "${_AG_PROC_SCAN_PPID_MAP}" <<'PY'
import json, sys, os, re, subprocess
journal_path, prefix, slots_json, own_agent_ancestor, agent_pids_str, worktree_pids_str, ppid_map_str = sys.argv[1:8]
identity_re = re.compile(rf'^{re.escape(prefix)}\\d+$')

# Public session snapshot (identity -> slot record) from the agent-guard-slots
# facade. A missing identity equals a missing session file (fail-open).
slot_map = {}
try:
    for _s in json.loads(slots_json).get('slots', []):
        if _s.get('identity'):
            slot_map[_s['identity']] = _s
except Exception:
    pass

# Reuse the single /proc scan performed by the bash wrapper.
agent_pids = set(agent_pids_str.split())
worktree_pids = set(worktree_pids_str.split())
ppid_map = {}
for entry in ppid_map_str.split():
    if ':' in entry:
        pid, ppid = entry.split(':', 1)
        ppid_map[pid] = ppid

def find_agent_ancestor(start_pid):
    """Return the first ancestor (or start_pid itself) that is an agent."""
    current = str(start_pid)
    visited = set()
    while current and current != '1' and current not in visited:
        visited.add(current)
        if current in agent_pids:
            return current
        current = ppid_map.get(current)
    return None

def worktree_has_live_agent(worktree, own_agent_ancestor, ppid_map):
    """Return True if an agent process from another session holds worktree.

    The wrapper pre-filters worktree_pids to agent processes and their
    descendants whose cwd is inside some agent worktree. We confirm the cwd
    matches the target worktree, then compare agent ancestors to exclude
    processes belonging to this wrapper's own agent session.
    """
    try:
        for pid in worktree_pids:
            try:
                cwd = os.readlink(f'/proc/{pid}/cwd')
            except (OSError, FileNotFoundError):
                continue
            if cwd != worktree:
                continue

            cand_agent_ancestor = find_agent_ancestor(pid)
            if own_agent_ancestor and cand_agent_ancestor == own_agent_ancestor:
                continue
            return True
    except Exception:
        pass
    return False

# Only read the newest journal entries; old entries cannot represent a session
# that should be resumed ahead of more recent ones. 2000 lines covers several
# days of heavy usage.
MAX_JOURNAL_LINES = 2000
try:
    import subprocess as sp
    proc = sp.run(['tail', '-n', str(MAX_JOURNAL_LINES), journal_path],
                  capture_output=True, text=True, encoding='utf-8', errors='replace')
    raw_lines = proc.stdout.splitlines()
except Exception:
    with open(journal_path, 'r', encoding='utf-8', errors='replace') as f:
        raw_lines = f.readlines()

events = []
for line in raw_lines:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except json.JSONDecodeError:
        continue
    if e.get('action') not in ('init', 'attach'):
        continue
    ident = e.get('identity', '')
    if not identity_re.match(ident):
        continue
    events.append(e)

# Most recent first.
events.reverse()

for e in events:
    worktree = e.get('worktree', '')
    branch = e.get('branch', '')
    identity = e.get('identity', '')

    if not worktree or not branch or not os.path.isdir(worktree):
        continue
    # Never resume a worktree parked on its neutral post-release branch.
    if branch.startswith('_released/'):
        continue
    if not os.path.isdir(os.path.join(worktree, '.git')) and \
       not os.path.isfile(os.path.join(worktree, '.git')):
        continue

    # Verify the branch still exists locally.
    try:
        with open(os.devnull, 'w') as devnull:
            rc = subprocess.call(
                ['git', '-C', worktree, 'show-ref', '--verify', '--quiet', f'refs/heads/{branch}'],
                stdout=devnull, stderr=devnull
            )
        if rc != 0:
            continue
    except Exception:
        continue

    # If the public session snapshot shows this identity active with a live
    # PID, the session is still held by a running process and must not be
    # hijacked. A missing entry equals a missing session file (fail-open).
    sess = slot_map.get(identity)
    if sess and sess.get('status') == 'active':
        pid = sess.get('pid')
        if pid and os.path.isdir(f'/proc/{pid}'):
            continue

    # Even when the session file is missing or stale, refuse to resume a
    # worktree that currently hosts another live agent process.
    if worktree_has_live_agent(worktree, own_agent_ancestor, ppid_map):
        continue

    print(worktree)
    sys.exit(0)

sys.exit(1)
PY
}

_ag_find_free_kimi_worktree() {
    for prefix in ${_AG_KNOWN_IDENTITIES}; do
        [[ "${prefix}" == "kimi" ]] || continue
        local wt_prefix
        wt_prefix="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.worktree_prefix" '' 2>/dev/null || true)"
        [[ -z "${wt_prefix}" ]] && continue

        # Respect optional dynamic slot expansion configured in agent-guard.yaml.
        local initial_slots max_slots
        initial_slots="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.slots" '1' 2>/dev/null || echo '1')"
        max_slots="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.max_slots" "${initial_slots}" 2>/dev/null || echo "${initial_slots}")"
        [[ "${max_slots}" -lt "${initial_slots}" ]] && max_slots="${initial_slots}"

        for n in $(seq 1 "${max_slots}"); do
            local identity="${prefix}${n}"
            local worktree="${_AG_BASE_DIR}/${wt_prefix}${n}"

            # The wrapper does not create missing worktrees here; creation is
            # delegated to the init script when expansion is required.
            [[ ! -d "${worktree}" ]] && continue

            local is_free=true
            local current_branch
            current_branch="$(git -C "${worktree}" branch --show-current 2>/dev/null || true)"

            # A worktree parked on its neutral _released/<identity> branch must not
            # be selected as "free" for automatic reuse. It is in cooldown/post-release
            # state and should only be reacquired through explicit allocation.
            if [[ "${current_branch}" == "_released/${identity}" ]]; then
                is_free=false
            fi

            # Session state comes from the public snapshot (F5B). Entry absent
            # == session file absent; status "unknown" (malformed) == previous
            # "free" fallback. Only active+live-PID marks the slot as held.
            if [[ "${is_free}" == "true" ]]; then
                local status pid
                status="$(_ag_slot_field "${identity}" status)"
                pid="$(_ag_slot_field "${identity}" pid)"
                if [[ "${status}" == "active" && -n "${pid}" && -d "/proc/${pid}" ]]; then
                    is_free=false
                fi
            fi

            if [[ "${is_free}" == "true" ]] && _ag_worktree_is_dirty "${worktree}"; then
                is_free=false
            fi

            if [[ "${is_free}" == "true" ]] && _ag_worktree_has_live_agent "${worktree}"; then
                is_free=false
            fi

            if [[ "${is_free}" == "true" ]]; then
                echo "${worktree}"
                return 0
            fi
        done
    done
    return 1
}

if ! _ag_have_lease; then
    _AG_INIT_SCRIPT="${_AG_MAIN_REPO}/${_AG_INIT_SCRIPT_NAME}"
    if [[ ! -f "${_AG_INIT_SCRIPT}" ]]; then
        echo "❌ AG WRAPPER: ${_AG_INIT_SCRIPT} not found." >&2
        exit 1
    fi

    _AG_SKIP_INIT="false"

    # -----------------------------------------------------------------------
    # 8a. Explicit slot requested: skip CWD heuristics and go straight to the
    # requested slot. The wrapper decides between three outcomes:
    #
    #   1. REFUSE  — a live agent process (or live lease PID) holds the slot.
    #   2. ADOPT   — the slot's session is stale (dead PID) AND its worktree
    #                has uncommitted work; delegates to the init --adopt flow,
    #                which preserves and surfaces the previous session's work.
    #   3. ACQUIRE — free slot (or stale lease with a clean worktree, which
    #                the init clears itself); delegates to init --slot.
    # -----------------------------------------------------------------------
    if [[ -n "${_AG_SLOT}" ]]; then
        if [[ ! "${_AG_SLOT}" =~ ^[a-z]+[0-9]+$ ]]; then
            echo "❌ AG WRAPPER: invalid slot '${_AG_SLOT}' (expected e.g. kimi3)." >&2
            exit 1
        fi

        _ag_slot_prefix="${_AG_SLOT%%[0-9]*}"
        _ag_slot_num="${_AG_SLOT##*[a-z]}"

        # Each wrapper family manages its own identity prefix (the Kimi wrapper
        # takes kimiN slots, never claudeN/geminiN). The expected prefix is
        # configurable for upstream projects with different naming.
        _ag_wrapper_prefix="$(bash "${_AG_CONFIG_BIN}" get "wrappers.kimi.identity_prefix" "kimi" 2>/dev/null || echo "kimi")"
        if [[ "${_ag_slot_prefix}" != "${_ag_wrapper_prefix}" ]]; then
            echo "❌ AG WRAPPER: slot '${_AG_SLOT}' does not belong to the '${_ag_wrapper_prefix}' family." >&2
            echo "   Use the matching agent CLI wrapper for that identity prefix." >&2
            exit 1
        fi

        _ag_wt_prefix="$(bash "${_AG_CONFIG_BIN}" get "identities.${_ag_slot_prefix}.worktree_prefix" '' 2>/dev/null || true)"
        if [[ -z "${_ag_wt_prefix}" ]]; then
            echo "❌ AG WRAPPER: no worktree_prefix configured for identity '${_ag_slot_prefix}'." >&2
            exit 1
        fi
        _ag_slot_worktree="${_AG_BASE_DIR}/${_ag_wt_prefix}${_ag_slot_num}"

        # 1. Refuse takeover of a slot with a live agent process.
        if [[ -d "${_ag_slot_worktree}" ]] && _ag_worktree_has_live_agent "${_ag_slot_worktree}"; then
            echo "❌ AG WRAPPER: slot '${_AG_SLOT}' already has a live agent session." >&2
            echo "   Close that session first, or pick another slot." >&2
            exit 1
        fi

        # 2. Decide adopt vs acquire from the public session snapshot (F5B).
        # Entry absent == session file absent; "unknown" (malformed) behaves
        # like the previous "free" fallback.
        _ag_slot_mode="acquire"
        if [[ -d "${_ag_slot_worktree}" ]]; then
            _ag_sess_status="$(_ag_slot_field "${_AG_SLOT}" status)"
            _ag_sess_pid="$(_ag_slot_field "${_AG_SLOT}" pid)"
            if [[ "${_ag_sess_status}" == "active" && -n "${_ag_sess_pid}" ]]; then
                if _ag_pid_is_alive "${_ag_sess_pid}"; then
                    echo "❌ AG WRAPPER: slot '${_AG_SLOT}' is held by live PID ${_ag_sess_pid}." >&2
                    echo "   Close that session first, or pick another slot." >&2
                    exit 1
                fi
                # Stale lease: the session file points to a dead/zombie PID.
                # Adopt only when the worktree carries uncommitted work from the
                # dead session; a clean stale worktree is handled by the normal
                # acquire path (init clears the stale lease).
                echo "🧹 AG WRAPPER: slot '${_AG_SLOT}' has a stale lease (PID ${_ag_sess_pid} is dead); clearing..." >&2
                if _ag_worktree_is_dirty "${_ag_slot_worktree}"; then
                    _ag_slot_mode="adopt"
                fi
            fi
        fi

        # Explicit slot request on a dirty worktree: prefer adopt so the user
        # can inspect and continue the previous session's work. Without this,
        # slots that were released with uncommitted changes (a drift condition
        # reported by --status) become unreachable via `hmvip go <slot>`.
        if [[ "${_ag_slot_mode}" == "acquire" && -d "${_ag_slot_worktree}" ]] && _ag_worktree_is_dirty "${_ag_slot_worktree}"; then
            echo "🔄 AG WRAPPER: slot '${_AG_SLOT}' has uncommitted work; adopting for inspection..." >&2
            _ag_slot_mode="adopt"
        fi

        _ag_default_role="$(bash "${_AG_CONFIG_BIN}" get "wrappers.kimi.default_role" "ia-a" 2>/dev/null || echo "ia-a")"
        ORIGINAL_ARGS=("$@")
        set --
        if [[ "${_ag_slot_mode}" == "adopt" ]]; then
            echo "🔄 AG WRAPPER: slot '${_AG_SLOT}' has a stale session with uncommitted work; adopting..." >&2
            if ! source "${_AG_INIT_SCRIPT}" --adopt "${_AG_SLOT}" >"${_AG_WRAPPER_LOG}" 2>&1; then
                echo "❌ AG WRAPPER: failed to adopt slot '${_AG_SLOT}'." >&2
                echo "   Log: ${_AG_WRAPPER_LOG}" >&2
                cat "${_AG_WRAPPER_LOG}" >&2
                exit 1
            fi
            # Adopt output lists uncommitted work and stashes left by the dead
            # session; it must stay visible to the user.
            cat "${_AG_WRAPPER_LOG}"
            # The adopted worktree legitimately carries the dead session's
            # uncommitted work (surfaced above). The generic cleanliness guard
            # must not block the launch it just adopted; AG_ALLOW_DIRTY_WORKTREE
            # is scoped to this process and documented as the recovery escape.
            export AG_ALLOW_DIRTY_WORKTREE=1
        else
            if ! source "${_AG_INIT_SCRIPT}" "${_ag_slot_prefix}" "${_ag_default_role}" --slot "${_AG_SLOT}" >"${_AG_WRAPPER_LOG}" 2>&1; then
                echo "❌ AG WRAPPER: failed to acquire slot '${_AG_SLOT}'." >&2
                echo "   Log: ${_AG_WRAPPER_LOG}" >&2
                cat "${_AG_WRAPPER_LOG}" >&2
                exit 1
            fi
        fi
        set -- "${ORIGINAL_ARGS[@]}"
        CWD="$(pwd)"
        _AG_SKIP_INIT="true"
    fi

    if [[ "${CWD}" == "${_AG_MAIN_REPO}" ]]; then
        # Try to resume the most recent active session before allocating a new slot.
        _AG_RESUMABLE_WORKTREE="$(_ag_find_resumable_worktree "kimi" 2>/dev/null || true)"
        if [[ -n "${_AG_RESUMABLE_WORKTREE}" ]]; then
            echo "🔄 AG WRAPPER: resuming last active session at ${_AG_RESUMABLE_WORKTREE}" >&2
            cd "${_AG_RESUMABLE_WORKTREE}" || exit 1
            CWD="${_AG_RESUMABLE_WORKTREE}"
        else
            _AG_FREE_WORKTREE="$(_ag_find_free_kimi_worktree 2>/dev/null || true)"
            if [[ -n "${_AG_FREE_WORKTREE}" ]]; then
                cd "${_AG_FREE_WORKTREE}" || exit 1
                CWD="${_AG_FREE_WORKTREE}"
            else
                # No existing worktree is free.  Ask the init script to allocate
                # a new slot, which will expand beyond the configured initial
                # slots when auto_expand is enabled.
                default_role="$(bash "${_AG_CONFIG_BIN}" get "wrappers.kimi.default_role" "ia-a" 2>/dev/null || echo "ia-a")"
                echo "🔄 AG WRAPPER: no free worktree available; allocating new slot..." >&2
                ORIGINAL_ARGS=("$@")
                set --
                if ! source "${_AG_INIT_SCRIPT}" kimi "${default_role}" >"${_AG_WRAPPER_LOG}" 2>&1; then
                    echo "❌ AG WRAPPER: failed to acquire agent lease." >&2
                    echo "   Log: ${_AG_WRAPPER_LOG}" >&2
                    cat "${_AG_WRAPPER_LOG}" >&2
                    exit 1
                fi
                set -- "${ORIGINAL_ARGS[@]}"
                CWD="$(pwd)"
                _AG_SKIP_INIT="true"
            fi
        fi
    else
        if _ag_worktree_has_live_agent "${CWD}"; then
            echo "❌ AG WRAPPER: worktree '${CWD}' already has a live agent session." >&2
            echo "   Start kimi from ${_AG_MAIN_REPO} to get a free worktree," >&2
            echo "   or explicitly attach to your branch with: source agent-guard attach <branch>" >&2
            exit 1
        fi
    fi

    if [[ "${_AG_SKIP_INIT}" != "true" ]]; then
        ORIGINAL_ARGS=("$@")
        set --
        if ! source "${_AG_INIT_SCRIPT}" >"${_AG_WRAPPER_LOG}" 2>&1; then
            echo "❌ AG WRAPPER: failed to acquire agent lease." >&2
            echo "   Log: ${_AG_WRAPPER_LOG}" >&2
            cat "${_AG_WRAPPER_LOG}" >&2
            exit 1
        fi
        set -- "${ORIGINAL_ARGS[@]}"
    fi

    # In reuse mode the init script exports the configured identity variable
    # (and legacy AGENT_GUARD_IDENTITY alias for older projects).
    _AG_IDENTITY_VALUE="$(eval echo "\${${_AG_IDENTITY_VAR}:-}")"
    export _AG_WORKTREE="${AG_WORKTREE_PATH:-${AGENT_GUARD_WORKTREE_PATH:-}}"
    export _AG_IDENTITY="${_AG_IDENTITY_VALUE:-${AGENT_GUARD_IDENTITY:-}}"
    export _AG_BRANCH="${AG_BRANCH:-${AGENT_GUARD_BRANCH:-}}"

    # Legacy aliases used by older Kimi CLI builds and by the Kimi Status
    # Indicator extension. Keeping them avoids regressions in consumers that
    # expect the old HMVIP-specific variable names.
    export _HMVIP_WORKTREE="${_AG_WORKTREE}"
    export _HMVIP_IDENTITY="${_AG_IDENTITY}"
    export _HMVIP_BRANCH="${_AG_BRANCH}"
fi

# ---------------------------------------------------------------------------
# 8.5 Session trace initialization (best-effort)
# ---------------------------------------------------------------------------
# Initialize a local trace directory for this worktree and record that the
# wrapper was invoked. Heartbeats are written on subsequent invocations when
# enough time has passed, so a crashed frontend still leaves a recoverable
# trail of metadata even if no explicit checkpoint was committed.
_ag_session_trace_dir="${_AG_WORKTREE}/.agent-guard/session"
_ag_session_trace_script="${_AG_REPO_ROOT}/${_AG_PACKAGE_ROOT:-packages/agent-guard-core}/src/session_trace.sh"
if [[ -f "${_ag_session_trace_script}" && -n "${_AG_WORKTREE:-}" && -n "${_AG_IDENTITY:-}" && -n "${_AG_BRANCH:-}" ]]; then
    AGENT_GUARD_REPO_ROOT="${_AG_REPO_ROOT}"
    AGENT_GUARD_WORKTREE_PATH="${_AG_WORKTREE}"
    AGENT_GUARD_IDENTITY="${_AG_IDENTITY}"
    AGENT_GUARD_BRANCH="${_AG_BRANCH}"
    AGENT_GUARD_SESSION_DIR="${_ag_session_trace_dir}"
    export AGENT_GUARD_REPO_ROOT AGENT_GUARD_WORKTREE_PATH AGENT_GUARD_IDENTITY AGENT_GUARD_BRANCH AGENT_GUARD_SESSION_DIR

    (
        source "${_ag_session_trace_script}" >/dev/null 2>&1
        _trace_init >/dev/null 2>&1 || true
        _trace_write_event "wrapper_invoke" "$(printf '{"argv":%s}' "$(printf '%s ' "$@" | ${AG_PYTHON} -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '""')" 2>/dev/null || true)" >/dev/null 2>&1 || true

        # Heartbeat if enough time elapsed since last recorded heartbeat.
        heartbeat_interval="${AGENT_GUARD_HEARTBEAT_INTERVAL_SECONDS:-300}"
        last_heartbeat=0
        if [[ -f "${_ag_session_trace_dir}/current/.last_heartbeat" ]]; then
            last_heartbeat="$(cat "${_ag_session_trace_dir}/current/.last_heartbeat" 2>/dev/null || echo 0)"
        fi
        now="$(date +%s)"
        if [[ $((now - last_heartbeat)) -ge ${heartbeat_interval} ]]; then
            _trace_heartbeat "wrapper periodic heartbeat" >/dev/null 2>&1 || true
            date +%s > "${_ag_session_trace_dir}/current/.last_heartbeat" 2>/dev/null || true
        fi
    )

    # Start a background watcher to snapshot Kimi session metadata (title,
    # lastPrompt, sessionId) while the frontend process is alive. This captures
    # conversation context even if the frontend crashes before writing an
    # explicit checkpoint. The watcher is best-effort and never blocks Kimi.
    watch_interval="${AGENT_GUARD_KIMI_WATCH_INTERVAL_SECONDS:-60}"
    if [[ "${watch_interval}" -gt 0 && -n "${_AG_WORKTREE:-}" ]]; then
        # Detach all file descriptors so the background watcher never keeps the
        # caller's pipes (e.g. command substitution $(...)) open after the real
        # Kimi process exits. This is a best-effort trace; losing its output is
        # acceptable.
        (
            # Change cwd so a surviving watcher is not mistaken for a live agent
            # session inside the worktree after the parent wrapper exits.
            cd / >/dev/null 2>&1 || true
            source "${_ag_session_trace_script}" >/dev/null 2>&1
            _trace_watch_kimi_session "$$" "${_AG_WORKTREE}" "${_ag_session_trace_dir}" "${watch_interval}" "${AGENT_GUARD_KIMI_WATCH_CHECKPOINT_INTERVAL_SECONDS:-900}" >/dev/null 2>&1
        ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------------------
# 9. Validate lease variables
# ---------------------------------------------------------------------------
if [[ -z "${_AG_WORKTREE:-}" || -z "${_AG_IDENTITY:-}" || -z "${_AG_BRANCH:-}" ]]; then
    echo "❌ AG WRAPPER: lease is incomplete. Run 'source agent-guard init' manually." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 10. Foreign worktree guard
# ---------------------------------------------------------------------------
if _ag_is_foreign_worktree; then
    echo "❌ AG WRAPPER: current directory '${CWD}' is a foreign worktree." >&2
    echo "   Your assigned worktree is: ${_AG_WORKTREE}" >&2
    echo "   Your identity is: ${_AG_IDENTITY}" >&2
    echo "   Change to your worktree or start kimi from ${_AG_MAIN_REPO}." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 11. Worktree cleanliness guard
# ---------------------------------------------------------------------------
if ! _ag_check_worktree_clean "${CWD}" "${_AG_IDENTITY}"; then
    exit 1
fi

# ---------------------------------------------------------------------------
# 12. If launched from main repo, switch to leased worktree
# ---------------------------------------------------------------------------
if [[ "${CWD}" == "${_AG_MAIN_REPO}" ]]; then
    cd "${_AG_WORKTREE}"
fi

# ---------------------------------------------------------------------------
# 12.5 Optional startup daily-check hook (Luna issue digest)
# ---------------------------------------------------------------------------
# When enabled, run a configured script once per session startup. The script
# itself uses flock to avoid duplicate work when many slots start at the same
# time; only the first slot per day posts the digest to Slack.
if [[ "${_AG_STARTUP_DAILY_CHECK_ENABLED:-false}" =~ ^([Tt]rue|1)$ && -n "${_AG_STARTUP_DAILY_CHECK_SCRIPT:-}" ]]; then
    _AG_STARTUP_SCRIPT_PATH="${_AG_MAIN_REPO}/${_AG_STARTUP_DAILY_CHECK_SCRIPT}"
    if [[ -f "${_AG_STARTUP_SCRIPT_PATH}" ]]; then
        _AG_STARTUP_LOG="/tmp/hmvip-luna-daily-issue-digest-${_AG_IDENTITY:-unknown}.log"
        if [[ "${_AG_STARTUP_DAILY_CHECK_BACKGROUND:-true}" =~ ^([Tt]rue|1)$ ]]; then
            (
                bash "${_AG_STARTUP_SCRIPT_PATH}" >"${_AG_STARTUP_LOG}" 2>&1 || true
            ) &
        else
            bash "${_AG_STARTUP_SCRIPT_PATH}" >"${_AG_STARTUP_LOG}" 2>&1 || true
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 13. Execute real Kimi
# ---------------------------------------------------------------------------
exec "${_AG_REAL_KIMI}" "$@"
