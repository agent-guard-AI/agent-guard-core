#!/usr/bin/env bash
#
# Agent Guard — Kiro CLI Wrapper
#
# Mandatory agent isolation enforcement for the Kiro CLI (kiro-cli).
# Every invocation of the Kiro launcher inside an Agent Guard managed
# repository is routed through here, ensuring that:
#
#   1. No agent works directly in the main repository.
#   2. No agent reuses another agent's worktree.
#   3. A valid agent-guard lease is acquired (or resumed) before any work.
#   4. Dirty foreign work is detected and blocked at session start.
#
# The wrapper reads its configuration from agent-guard.yaml (SSOT) in the
# repository it is invoked from. Project-specific paths are not hardcoded.
#
# RESILIENCE TO KIRO UPDATES (design goal):
#   The Kiro updater overwrites the real binary at ~/.local/bin/kiro-cli.
#   This wrapper NEVER renames or touches that binary. It lives in a
#   higher-precedence PATH dir (~/.local/hmvip/bin) OR is invoked by the
#   thin `kiro-hmvip` launcher, and resolves the real kiro-cli dynamically:
#   configured absolute path (wrappers.kiro.real_bin_path) → canonical
#   ~/.local/bin/kiro-cli → `command -v kiro-cli` on PATH. If a Kiro update
#   moves the binary, the PATH fallback still finds it. Every candidate is
#   checked against this wrapper's own path so recursion is impossible.
#
# Installation:
#   mkdir -p ~/.local/hmvip/bin
#   cp <path-to>/wrappers/kiro/wrapper.sh ~/.local/hmvip/bin/kiro-cli
#   chmod +x ~/.local/hmvip/bin/kiro-cli
#   # Keep ~/.local/hmvip/bin before ~/.local/bin in PATH.
#   # (The `kiro-hmvip` launcher may also call this wrapper directly.)
#
# Emergency bypass (use only for debugging/recovery):
#   AG_WRAPPER_BYPASS=1 kiro-cli ...
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Emergency bypass
# ---------------------------------------------------------------------------
if [[ "${AG_WRAPPER_BYPASS:-}" == "1" ]]; then
    # Wave E (ADR-0064): every emergency bypass is logged (auditability of
    # guard-disable events). Best effort — never block the bypass itself.
    _AG_EARLY_REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    mkdir -p "${_AG_EARLY_REPO}/.agent-guard/journal" 2>/dev/null || true
    printf '{"ts":%s,"event":"early-bypass","cwd":"%s"}\n' \
        "$(date +%s)" "$(basename "${_AG_EARLY_REPO}")" \
        >> "${_AG_EARLY_REPO}/.agent-guard/journal/guard-home-bypass.jsonl" 2>/dev/null || true
    _AG_REAL_KIRO="${AG_KIRO_REAL:-}"
    if [[ -z "${_AG_REAL_KIRO}" ]]; then
        _AG_REAL_KIRO_CANDIDATES=("${HOME}/.local/bin/kiro-cli")
        for candidate in "${_AG_REAL_KIRO_CANDIDATES[@]}"; do
            if [[ -n "${candidate}" && -x "${candidate}" ]]; then
                _AG_REAL_KIRO="${candidate}"
                break
            fi
        done
    fi
    _AG_BYPASS_WRAPPER="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
    _AG_BYPASS_REAL="$(readlink -f "${_AG_REAL_KIRO}" 2>/dev/null || printf '%s' "${_AG_REAL_KIRO}")"
    if [[ -z "${_AG_REAL_KIRO}" || ! -x "${_AG_REAL_KIRO}" || "${_AG_BYPASS_REAL}" == "${_AG_BYPASS_WRAPPER}" ]]; then
        echo "❌ AG WRAPPER: cannot locate real kiro-cli binary for bypass." >&2
        exit 1
    fi
    exec "${_AG_REAL_KIRO}" "$@"
fi

# ---------------------------------------------------------------------------
# 0.5 Explicit slot selection: --slot <identity> or AGENT_GUARD_SLOT
# ---------------------------------------------------------------------------
#   kiro-cli --slot kiro3            # acquire (or adopt) slot kiro3, then launch
#   AGENT_GUARD_SLOT=kiro3 kiro-cli  # same, via environment variable
#
# The flag is consumed by the wrapper and never forwarded to the real CLI.
# If the Kiro CLI ever introduces its own --slot flag, use AGENT_GUARD_SLOT.
_AG_SLOT="${AGENT_GUARD_SLOT:-}"
if [[ $# -gt 0 ]]; then
    _AG_REMAINING_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slot)
                if [[ -z "${2:-}" ]]; then
                    echo "❌ AG WRAPPER: --slot requires an identity (ex: kiro3)." >&2
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

unset AGENT_GUARD_SESSION_PID
export AGENT_GUARD_SESSION_PID="$$"

unset _AG_WORKTREE _AG_IDENTITY _AG_BRANCH
unset _HMVIP_WORKTREE _HMVIP_IDENTITY _HMVIP_BRANCH
unset AG_WORKTREE_PATH AG_BRANCH
unset AGENT_GUARD_WORKTREE_PATH AGENT_GUARD_IDENTITY AGENT_GUARD_BRANCH

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
_AG_REAL_KIRO=""
_AG_IDENTITY_VAR=""
_AG_KNOWN_IDENTITIES=""

_ag_is_wrapper_path() {
    local candidate="$1" wrapper_path candidate_path
    wrapper_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
    candidate_path="$(readlink -f "${candidate}" 2>/dev/null || printf '%s' "${candidate}")"
    [[ "${candidate_path}" == "${wrapper_path}" ]]
}

_ag_accept_real_kiro() {
    local candidate="$1"
    if [[ -n "${candidate}" && -x "${candidate}" ]] && ! _ag_is_wrapper_path "${candidate}"; then
        echo "${candidate}"
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
    _AG_BIN_DIR="$(bash "${config_bin}" get wrappers.kiro.bin_dir "${HOME}/.local/hmvip/bin" 2>/dev/null || echo "${HOME}/.local/hmvip/bin")"
    _AG_REAL_BIN_NAME="$(bash "${config_bin}" get wrappers.kiro.real_bin_path "${HOME}/.local/bin/kiro-cli" 2>/dev/null || echo "${HOME}/.local/bin/kiro-cli")"
    _AG_IDENTITY_VAR="$(bash "${config_bin}" get commit.identity_env_var 'AGENT_GUARD_IDENTITY' 2>/dev/null || echo 'AGENT_GUARD_IDENTITY')"
    _AG_INIT_SCRIPT_NAME="$(bash "${config_bin}" get paths.init_script '.agent-guard-init' 2>/dev/null || echo '.agent-guard-init')"
    _AG_KNOWN_IDENTITIES="$(bash "${config_bin}" keys identities 2>/dev/null || true)"

    # Resolution order: explicit override, configured path, canonical Kiro
    # installer path, then PATH. Every candidate is checked against this
    # wrapper (including symlink aliases) to make recursion impossible.
    local configured_real path_candidate candidate
    configured_real="${_AG_REAL_BIN_NAME/#\~/${HOME}}"
    path_candidate="$(command -v kiro-cli 2>/dev/null || true)"
    for candidate in "${AG_KIRO_REAL:-}" "${configured_real}" "${HOME}/.local/bin/kiro-cli" "${path_candidate}"; do
        if _AG_REAL_KIRO="$(_ag_accept_real_kiro "${candidate}" 2>/dev/null)"; then
            break
        fi
    done

    _AG_CONFIG_LOADED="true"

    # Guard Semantics Kernel (ADR-0064): canonical tri-state predicates shared
    # with init.sh. Sourcing is fail-open on purpose: if the lib is absent
    # (main repo not updated yet), wrappers fall back to their built-in
    # legacy checks below.
    _AG_SEMANTICS_LIB="${_AG_MAIN_REPO}/${package_root}/src/guard-semantics.sh"
    if [[ -r "${_AG_SEMANTICS_LIB}" ]]; then
        # shellcheck disable=SC1090
        . "${_AG_SEMANTICS_LIB}"
    fi
    return 0
}

_ag_looks_like_main_repo() {
    if ! git -C "${CWD}" rev-parse --show-toplevel >/dev/null 2>&1; then
        return 1
    fi
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
        echo "" >&2
        echo "   Emergency bypass (use only for recovery):" >&2
        echo "     AG_WRAPPER_BYPASS=1 kiro-cli ..." >&2
        exit 1
    fi

    # Not in an Agent Guard managed repository; pass through unchanged.
    _AG_REAL_KIRO=""
    for candidate in "${AG_KIRO_REAL:-}" "${HOME}/.local/bin/kiro-cli" "$(command -v kiro-cli 2>/dev/null || true)"; do
        if _AG_REAL_KIRO="$(_ag_accept_real_kiro "${candidate}" 2>/dev/null)"; then
            break
        fi
    done
    if [[ -n "${_AG_REAL_KIRO}" && -x "${_AG_REAL_KIRO}" ]]; then
        exec "${_AG_REAL_KIRO}" "$@"
    fi
    echo "❌ AG WRAPPER: cannot locate real kiro-cli binary." >&2
    exit 1
fi

# Wave E (ADR-0064): guard-home health check — fail-closed. Operating with a
# sick guard-home (wrong branch, mid-operation, bad yaml) means deciding on
# wrong config/code; the legacy fail-open is replaced by a refusal with an
# actionable diagnosis. Disable explicitly with AG_GUARD_HOME_CHECK=0
# (AG_WRAPPER_BYPASS=1 is intercepted earlier and logged there).
if [[ -n "${AGS_SEMANTICS_VERSION:-}" && "${AG_GUARD_HOME_CHECK:-1}" == "1" ]]; then
    _AG_GH_STATE="$(ags_guard_home_state "${_AG_MAIN_REPO}")" && _AG_GH_RC=0 || _AG_GH_RC=$?
    if [[ "${_AG_GH_RC}" -ne 0 ]]; then
        echo "❌ AG WRAPPER: guard-home is not in a healthy state: ${_AG_GH_STATE}" >&2
        echo "   Repo: ${_AG_MAIN_REPO}" >&2
        echo "   Fix: return the guard-home to '${AG_GUARD_HOME_REF:-develop}' with a clean git state," >&2
        echo "   or set AG_GUARD_HOME_CHECK=0 / AG_WRAPPER_BYPASS=1 for explicit recovery (logged)." >&2
        exit 1
    fi
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
        if [[ -n "${_AG_REAL_KIRO}" && -x "${_AG_REAL_KIRO}" ]]; then
            exec "${_AG_REAL_KIRO}" "$@"
        fi
        echo "❌ AG WRAPPER: cannot locate real kiro-cli binary." >&2
        exit 1
    fi
fi

if [[ -z "${_AG_REAL_KIRO}" || ! -x "${_AG_REAL_KIRO}" ]]; then
    echo "❌ AG WRAPPER: real kiro-cli binary not found (configured path: ${_AG_REAL_BIN_NAME})." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Management/read-only commands do not require a lease
# ---------------------------------------------------------------------------
_ag_is_management_command() {
    for arg in "$@"; do
        case "${arg}" in
            --version|-V|--help|-h|update|upgrade|login|logout|doctor|settings|diagnostic|version)
                return 0
                ;;
        esac
    done
    return 1
}

if _ag_is_management_command "$@"; then
    exec "${_AG_REAL_KIRO}" "$@"
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

    if [[ "${CWD}" == "${_AG_MAIN_REPO}" ]]; then
        return 1
    fi
    if [[ "${CWD}" == "${current_worktree}" ]]; then
        return 1
    fi
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

    if [[ -n "${AGS_SEMANTICS_VERSION:-}" ]]; then
        local _ag_state _ag_rc _ag_reason
        _ag_state="$(ag_worktree_state "${worktree}" "${identity}")"
        _ag_rc=$?
        case "${_ag_rc}" in
            0)
                return 0
                ;;
            2)
                echo "❌ AG WRAPPER: could not VERIFY worktree ${worktree} (git unreachable after retries)." >&2
                echo "   Identity: ${identity}" >&2
                echo "   Fix: check disk/.git health, then run 'git -C \"${worktree}\" status' manually." >&2
                return 1
                ;;
        esac
        # rc=1 → dirty_work or mid_operation (both block; bypass only covers dirty_work)
        _ag_reason="$(printf '%s\n' "${_ag_state}" | sed -n '2p')"
        if [[ "${_ag_state}" == mid_operation* ]]; then
            echo "❌ AG WRAPPER: worktree ${worktree} has a Git operation in progress (${_ag_reason})." >&2
            echo "   Finish or abort it first — 'git -C \"${worktree}\" status' shows how." >&2
            return 1
        fi
        if [[ "${AG_ALLOW_DIRTY_WORKTREE:-}" == "1" ]]; then
            return 0
        fi
        echo "❌ AG WRAPPER: worktree ${worktree} has uncommitted changes." >&2
        echo "   Identity: ${identity}" >&2
        echo "   Resolve before starting a new session (commit, stash, or run with AG_ALLOW_DIRTY_WORKTREE=1 for recovery)." >&2
        echo "" >&2
        echo "   git status:" >&2
        git -C "${worktree}" status --short >&2 || true
        return 1
    fi

    # Legacy fallback (lib absent): slot-note exemption only.
    local status_output
    status_output="$(git -C "${worktree}" status --porcelain=v1 2>/dev/null || true)"
    if [[ -n "${status_output}" && -n "${identity}" ]]; then
        status_output="$(printf '%s\n' "${status_output}" | grep -vE "^.. \\.agent-guard/tasks/${identity}\\.md\$" || true)"
    fi

    if [[ -z "${status_output}" ]]; then
        return 0
    fi

    if [[ "${AG_ALLOW_DIRTY_WORKTREE:-}" != "1" ]]; then
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
# 8. Acquire lease if needed — helpers
# ---------------------------------------------------------------------------
_ag_worktree_is_dirty() {
    local worktree="$1"
    local identity="${2:-}"
    if [[ -n "${AGS_SEMANTICS_VERSION:-}" && -n "${identity}" ]]; then
        ag_worktree_state "${worktree}" "${identity}" >/dev/null
        local _ag_rc=$?
        # fail-closed: indeterminate (2) counts as dirty — never acquire or
        # adopt over an unverifiable worktree state.
        [[ "${_ag_rc}" -ne 0 ]]
        return
    fi
    # Legacy fallback (lib absent): slot-note exemption only.
    local output
    output="$(git -C "${worktree}" status --porcelain=v1 2>/dev/null || true)"
    if [[ -n "${output}" && -n "${identity}" ]]; then
        output="$(printf '%s\n' "${output}" | grep -vE "^.. \\.agent-guard/tasks/${identity}\\.md\$" || true)"
    fi
    [[ -n "${output}" ]]
}

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

_AG_PROC_SCAN_AGENT_PIDS=""
_AG_PROC_SCAN_WORKTREE_PIDS=""
_AG_PROC_SCAN_PPID_MAP=""

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
        if (comm == "kimi-code" || comm == "claude" || comm == "gemini" || comm == "grok" || comm == "cursor" || comm == "antigravity" || comm == "kiro" || comm == "kiro-cli" || comm == "amp" || args ~ /(^|[^[:alnum:]_])(kimi-code|claude|gemini|grok|cursor|antigravity|kiro-cli|kiro|kimi|amp)([^[:alnum:]_]|$)/) {
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
    local own_agent_ancestor
    own_agent_ancestor="$(_ag_find_agent_ancestor "$$")"

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

_AG_WRAPPER_LOG="/tmp/ag-wrapper-lease-${_AG_SLOT:-$$}.log"

# Public session snapshot (F5B) via the agent-guard-slots facade. Fail-open.
_AG_SLOTS_SNAPSHOT=""
_ag_slots_snapshot() {
    if [[ -z "${_AG_SLOTS_SNAPSHOT}" ]]; then
        local _slots_bin
        _slots_bin="$(dirname "${_AG_CONFIG_BIN}")/agent-guard-slots"
        _AG_SLOTS_SNAPSHOT="$(AGENT_GUARD_REPO_ROOT="${_AG_MAIN_REPO}" bash "${_slots_bin}" 2>/dev/null || true)"
        if [[ -z "${_AG_SLOTS_SNAPSHOT}" ]] || ! printf '%s' "${_AG_SLOTS_SNAPSHOT}" | ${AG_PYTHON} -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
            _AG_SLOTS_SNAPSHOT='{"schema_version":3,"command":"slots","slots":[]}'
        fi
    fi
    printf '%s' "${_AG_SLOTS_SNAPSHOT}"
}

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

_ag_find_resumable_worktree() {
    local prefix="$1"
    local journal_path
    journal_path="${_AG_MAIN_REPO}/$(bash "${_AG_CONFIG_BIN}" get journal.path ".agent-guard/journal/agent-guard.jsonl" 2>/dev/null || echo ".agent-guard/journal/agent-guard.jsonl")"
    [[ ! -f "${journal_path}" ]] && return 1

    local own_agent_ancestor
    _ag_scan_proc_once
    own_agent_ancestor="$(_ag_find_agent_ancestor "$$")"

    local slots_snapshot
    slots_snapshot="$(_ag_slots_snapshot)"

    ${AG_PYTHON} - "${journal_path}" "${prefix}" "${slots_snapshot}" "${own_agent_ancestor}" "${_AG_PROC_SCAN_AGENT_PIDS}" "${_AG_PROC_SCAN_WORKTREE_PIDS}" "${_AG_PROC_SCAN_PPID_MAP}" <<'PY'
import json, sys, os, re, subprocess
journal_path, prefix, slots_json, own_agent_ancestor, agent_pids_str, worktree_pids_str, ppid_map_str = sys.argv[1:8]
identity_re = re.compile(rf'^{re.escape(prefix)}\d+$')

slot_map = {}
try:
    for _s in json.loads(slots_json).get('slots', []):
        if _s.get('identity'):
            slot_map[_s['identity']] = _s
except Exception:
    pass

agent_pids = set(agent_pids_str.split())
worktree_pids = set(worktree_pids_str.split())
ppid_map = {}
for entry in ppid_map_str.split():
    if ':' in entry:
        pid, ppid = entry.split(':', 1)
        ppid_map[pid] = ppid

def find_agent_ancestor(start_pid):
    current = str(start_pid)
    visited = set()
    while current and current != '1' and current not in visited:
        visited.add(current)
        if current in agent_pids:
            return current
        current = ppid_map.get(current)
    return None

def worktree_has_live_agent(worktree, own_agent_ancestor, ppid_map):
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

MAX_JOURNAL_LINES = 2000
try:
    proc = subprocess.run(['tail', '-n', str(MAX_JOURNAL_LINES), journal_path],
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

events.reverse()

for e in events:
    worktree = e.get('worktree', '')
    branch = e.get('branch', '')
    identity = e.get('identity', '')

    if not worktree or not branch or not os.path.isdir(worktree):
        continue
    # Never resume a worktree parked on its neutral post-release branch.
    # The journal records the branch at init time (a work branch), but the
    # worktree may have been released since. Trust the on-disk HEAD, not the
    # historical journal entry, so a released slot is treated as free (and
    # auto-allocated) instead of dead-ending in init.sh's neutral-branch guard.
    if branch.startswith('_released/'):
        continue
    if not os.path.isdir(os.path.join(worktree, '.git')) and \
       not os.path.isfile(os.path.join(worktree, '.git')):
        continue
    try:
        _cur_branch = subprocess.run(
            ['git', '-C', worktree, 'rev-parse', '--abbrev-ref', 'HEAD'],
            capture_output=True, text=True, encoding='utf-8', errors='replace'
        ).stdout.strip()
    except Exception:
        _cur_branch = ''
    if _cur_branch.startswith('_released/') or _cur_branch in ('', 'develop', 'HEAD'):
        continue

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

    sess = slot_map.get(identity)
    if sess and sess.get('status') == 'active':
        pid = sess.get('pid')
        if pid and os.path.isdir(f'/proc/{pid}'):
            continue

    if worktree_has_live_agent(worktree, own_agent_ancestor, ppid_map):
        continue

    print(worktree)
    sys.exit(0)

sys.exit(1)
PY
}

_ag_find_free_kiro_worktree() {
    for prefix in ${_AG_KNOWN_IDENTITIES}; do
        [[ "${prefix}" == "kiro" ]] || continue
        local wt_prefix
        wt_prefix="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.worktree_prefix" 'hmvip-ia-kiro' 2>/dev/null || echo 'hmvip-ia-kiro')"
        [[ -z "${wt_prefix}" ]] && continue

        local initial_slots max_slots
        initial_slots="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.slots" '1' 2>/dev/null || echo '1')"
        max_slots="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.max_slots" "${initial_slots}" 2>/dev/null || echo "${initial_slots}")"
        [[ "${max_slots}" -lt "${initial_slots}" ]] && max_slots="${initial_slots}"

        for n in $(seq 1 "${max_slots}"); do
            local identity="${prefix}${n}"
            local worktree="${_AG_BASE_DIR}/${wt_prefix}${n}"

            [[ ! -d "${worktree}" ]] && continue

            local is_free=true
            local current_branch
            current_branch="$(git -C "${worktree}" branch --show-current 2>/dev/null || true)"

            if [[ "${current_branch}" == "_released/${identity}" ]]; then
                is_free=false
            fi

            if [[ "${is_free}" == "true" ]]; then
                local status pid
                status="$(_ag_slot_field "${identity}" status)"
                pid="$(_ag_slot_field "${identity}" pid)"
                if [[ "${status}" == "active" && -n "${pid}" && -d "/proc/${pid}" ]]; then
                    is_free=false
                fi
            fi

            if [[ "${is_free}" == "true" ]] && _ag_worktree_is_dirty "${worktree}" "${identity}"; then
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

    # 8a. Explicit slot requested.
    if [[ -n "${_AG_SLOT}" ]]; then
        if [[ ! "${_AG_SLOT}" =~ ^[a-z]+[0-9]+$ ]]; then
            echo "❌ AG WRAPPER: invalid slot '${_AG_SLOT}' (expected e.g. kiro3)." >&2
            exit 1
        fi

        _ag_slot_prefix="${_AG_SLOT%%[0-9]*}"
        _ag_slot_num="${_AG_SLOT##*[a-z]}"

        _ag_wrapper_prefix="$(bash "${_AG_CONFIG_BIN}" get "wrappers.kiro.identity_prefix" "kiro" 2>/dev/null || echo "kiro")"
        if [[ "${_ag_slot_prefix}" != "${_ag_wrapper_prefix}" ]]; then
            echo "❌ AG WRAPPER: slot '${_AG_SLOT}' does not belong to the '${_ag_wrapper_prefix}' family." >&2
            echo "   Use the matching agent CLI wrapper for that identity prefix." >&2
            exit 1
        fi

        _ag_wt_prefix="$(bash "${_AG_CONFIG_BIN}" get "identities.${_ag_slot_prefix}.worktree_prefix" 'hmvip-ia-kiro' 2>/dev/null || echo 'hmvip-ia-kiro')"
        if [[ -z "${_ag_wt_prefix}" ]]; then
            echo "❌ AG WRAPPER: no worktree_prefix configured for identity '${_ag_slot_prefix}'." >&2
            exit 1
        fi
        _ag_slot_worktree="${_AG_BASE_DIR}/${_ag_wt_prefix}${_ag_slot_num}"

        if [[ -d "${_ag_slot_worktree}" ]] && _ag_worktree_has_live_agent "${_ag_slot_worktree}"; then
            echo "❌ AG WRAPPER: slot '${_AG_SLOT}' already has a live agent session." >&2
            echo "   Close that session first, or pick another slot." >&2
            exit 1
        fi

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
                echo "🧹 AG WRAPPER: slot '${_AG_SLOT}' has a stale lease (PID ${_ag_sess_pid} is dead); clearing..." >&2
                if _ag_worktree_is_dirty "${_ag_slot_worktree}" "${_AG_SLOT}"; then
                    _ag_slot_mode="adopt"
                fi
            fi
        fi

        if [[ "${_ag_slot_mode}" == "acquire" && -d "${_ag_slot_worktree}" ]] && _ag_worktree_is_dirty "${_ag_slot_worktree}" "${_AG_SLOT}"; then
            echo "🔄 AG WRAPPER: slot '${_AG_SLOT}' has uncommitted work; adopting for inspection..." >&2
            _ag_slot_mode="adopt"
        fi

        _ag_default_role="$(bash "${_AG_CONFIG_BIN}" get "wrappers.kiro.default_role" "ia-a" 2>/dev/null || echo "ia-a")"
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
            cat "${_AG_WRAPPER_LOG}"
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

    # Wave C (ADR-0064): transactional resume — DEFAULT ON since owner GO
    # 2026-09-27 (AG_RESUME_TX=0 reverts to the legacy path). AG_RESUME_SHADOW=1 records the
    # atomic selector's pick for divergence analysis without changing
    # behavior; AG_RESUME_TX=1 makes the atomic command the resume path.
    _AG_RESUME_BIN="${_AG_MAIN_REPO}/${_AG_PACKAGE_ROOT}/bin/agent-guard-resume"
    if [[ "${_AG_SKIP_INIT}" != "true" && "${CWD}" == "${_AG_MAIN_REPO}" && -x "${_AG_RESUME_BIN}" ]]; then
        if [[ "${AG_RESUME_SHADOW:-0}" == "1" ]]; then
            "${_AG_RESUME_BIN}" resume --prefix kiro --shadow >/dev/null 2>&1 || true
        fi
        if [[ "${AG_RESUME_TX:-1}" == "1" ]]; then
            _AG_RESUME_ENV="$("${_AG_RESUME_BIN}" resume --prefix kiro --print-env 2>/dev/null || true)"
            if [[ -n "${_AG_RESUME_ENV}" ]]; then
                eval "${_AG_RESUME_ENV}"
                cd "${AGENT_GUARD_WORKTREE_PATH}" || exit 1
                CWD="$(pwd)"
                export _AG_WORKTREE="${AGENT_GUARD_WORKTREE_PATH}"
                export _AG_IDENTITY="${AGENT_GUARD_IDENTITY}"
                export _AG_BRANCH="${AG_BRANCH}"
                export _HMVIP_WORKTREE="${_AG_WORKTREE}"
                export _HMVIP_IDENTITY="${_AG_IDENTITY}"
                export _HMVIP_BRANCH="${_AG_BRANCH}"
                _AG_SKIP_INIT="true"
            fi
        fi
    fi

    if [[ "${_AG_SKIP_INIT}" != "true" && "${CWD}" == "${_AG_MAIN_REPO}" ]]; then
        # Prefer resuming the most recent active session before allocating new.
        _AG_RESUMABLE_WORKTREE="$(_ag_find_resumable_worktree "kiro" 2>/dev/null || true)"
        if [[ "${AG_RESUME_SHADOW:-0}" == "1" ]]; then
            AG_SHADOW_LOG="${_AG_MAIN_REPO}/.agent-guard/journal/resume-shadow.jsonl" \
            AG_SHADOW_PICK="${_AG_RESUMABLE_WORKTREE:-}" \
            ${AG_PYTHON} -c '
import json, os, time
path = os.environ["AG_SHADOW_LOG"]
os.makedirs(os.path.dirname(path), exist_ok=True)
rec = {"ts": time.time(), "selector": "legacy", "pick": os.environ.get("AG_SHADOW_PICK") or None}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(rec) + "\n")
' >/dev/null 2>&1 || true
        fi
        if [[ -n "${_AG_RESUMABLE_WORKTREE}" ]]; then
            echo "🔄 AG WRAPPER: resuming last active session at ${_AG_RESUMABLE_WORKTREE}" >&2
            cd "${_AG_RESUMABLE_WORKTREE}" || exit 1
            CWD="${_AG_RESUMABLE_WORKTREE}"
        else
            _AG_FREE_WORKTREE="$(_ag_find_free_kiro_worktree 2>/dev/null || true)"
            if [[ -n "${_AG_FREE_WORKTREE}" ]]; then
                cd "${_AG_FREE_WORKTREE}" || exit 1
                CWD="${_AG_FREE_WORKTREE}"
            else
                default_role="$(bash "${_AG_CONFIG_BIN}" get "wrappers.kiro.default_role" "ia-a" 2>/dev/null || echo "ia-a")"
                echo "🔄 AG WRAPPER: no free worktree available; allocating new slot..." >&2
                ORIGINAL_ARGS=("$@")
                set --
                if ! source "${_AG_INIT_SCRIPT}" kiro "${default_role}" >"${_AG_WRAPPER_LOG}" 2>&1; then
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
    elif [[ "${_AG_SKIP_INIT}" != "true" ]]; then
        if _ag_worktree_has_live_agent "${CWD}"; then
            echo "❌ AG WRAPPER: worktree '${CWD}' already has a live agent session." >&2
            echo "   Start kiro-cli from ${_AG_MAIN_REPO} to get a free worktree," >&2
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

    _AG_IDENTITY_VALUE="$(eval echo "\${${_AG_IDENTITY_VAR}:-}")"
    export _AG_WORKTREE="${AG_WORKTREE_PATH:-${AGENT_GUARD_WORKTREE_PATH:-}}"
    export _AG_IDENTITY="${_AG_IDENTITY_VALUE:-${AGENT_GUARD_IDENTITY:-}}"
    export _AG_BRANCH="${AG_BRANCH:-${AGENT_GUARD_BRANCH:-}}"

    export _HMVIP_WORKTREE="${_AG_WORKTREE}"
    export _HMVIP_IDENTITY="${_AG_IDENTITY}"
    export _HMVIP_BRANCH="${_AG_BRANCH}"
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
    echo "   Change to your worktree or start kiro-cli from ${_AG_MAIN_REPO}." >&2
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
# 13. Execute real Kiro CLI (resolved dynamically; resilient to Kiro updates)
# ---------------------------------------------------------------------------
exec "${_AG_REAL_KIRO}" "$@"
