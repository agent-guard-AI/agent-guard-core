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
#   HMVIP_WRAPPER_BYPASS=1 kimi ...  # legacy alias
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Emergency bypass (canonical env var + legacy alias)
# ---------------------------------------------------------------------------
if [[ "${AG_WRAPPER_BYPASS:-}" == "1" || "${HMVIP_WRAPPER_BYPASS:-}" == "1" ]]; then
    # REAL_KIMI is resolved later; bypass is handled after config load.
    # We need it now, so perform a minimal resolution.
    _AG_REAL_KIMI="${AG_KIMI_REAL:-${HMVIP_KIMI_REAL:-}}"
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
# 1. Resolve current working directory
# ---------------------------------------------------------------------------
CWD="$(pwd -P 2>/dev/null || pwd)"

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

if ! _ag_load_config; then
    # Not in an Agent Guard managed repository; pass through unchanged.
    # We still need a real binary. Try to find it.
    _AG_REAL_KIMI="${AG_KIMI_REAL:-${HMVIP_KIMI_REAL:-}}"
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

    if [[ "${AG_ALLOW_DIRTY_WORKTREE:-}" != "1" && "${HMVIP_ALLOW_DIRTY_WORKTREE:-}" != "1" ]]; then
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

_ag_worktree_has_live_agent() {
    local worktree="$1"
    local own_pid="$$"

    if ! command -v lsof >/dev/null 2>&1; then
        local pid
        for pid in /proc/[0-9]*; do
            [[ -d "${pid}" ]] || continue
            local pid_num="${pid#/proc/}"
            [[ "${pid_num}" == "${own_pid}" ]] && continue
            local cwd_link
            cwd_link="$(readlink "${pid}/cwd" 2>/dev/null || true)"
            if [[ "${cwd_link}" == "${worktree}" ]]; then
                local comm
                comm="$(cat "${pid}/comm" 2>/dev/null || true)"
                case "${comm}" in
                    kimi-code|claude|gemini|grok|cursor|antigravity|kiro)
                        return 0
                        ;;
                esac
            fi
        done
        return 1
    fi

    local pids
    pids="$(lsof +D "${worktree}" 2>/dev/null | awk '$1 ~ /^(kimi-code|claude|gemini|grok|cursor|antigravity|kiro)$/ {print $2}' | sort -u | grep -v "^${own_pid}$" || true)"
    [[ -n "${pids}" ]]
}

_ag_find_free_kimi_worktree() {
    local session_dir
    session_dir="${_AG_MAIN_REPO}/$(bash "${_AG_CONFIG_BIN}" get paths.session_storage ".agent-guard/sessions")"
    for prefix in ${_AG_KNOWN_IDENTITIES}; do
        [[ "${prefix}" == "kimi" ]] || continue
        local wt_prefix
        wt_prefix="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.worktree_prefix" '' 2>/dev/null || true)"
        [[ -z "${wt_prefix}" ]] && continue
        local slots
        slots="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.slots" '1' 2>/dev/null || echo '1')"
        for n in $(seq 1 "${slots}"); do
            local identity="${prefix}${n}"
            local worktree="${_AG_BASE_DIR}/${wt_prefix}${n}"
            local session_file="${session_dir}/${identity}.json"

            [[ ! -d "${worktree}" ]] && continue

            local is_free=true
            if [[ -f "${session_file}" ]]; then
                local status pid
                status="$(python3 -c "import json,sys; d=json.load(open('${session_file}')); print(d.get('status','free'))" 2>/dev/null || echo free)"
                pid="$(python3 -c "import json,sys; d=json.load(open('${session_file}')); print(d.get('pid',''))" 2>/dev/null || echo '')"
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

    if [[ "${CWD}" == "${_AG_MAIN_REPO}" ]]; then
        _AG_FREE_WORKTREE="$(_ag_find_free_kimi_worktree 2>/dev/null || true)"
        if [[ -z "${_AG_FREE_WORKTREE}" ]]; then
            echo "❌ AG WRAPPER: no free kimi worktree available." >&2
            echo "   Release an existing session with: source agent-guard release" >&2
            exit 1
        fi
        cd "${_AG_FREE_WORKTREE}" || exit 1
        CWD="${_AG_FREE_WORKTREE}"
    else
        if _ag_worktree_has_live_agent "${CWD}"; then
            echo "❌ AG WRAPPER: worktree '${CWD}' already has a live agent session." >&2
            echo "   Start kimi from ${_AG_MAIN_REPO} to get a free worktree," >&2
            echo "   or explicitly attach to your branch with: source agent-guard attach <branch>" >&2
            exit 1
        fi
    fi

    ORIGINAL_ARGS=("$@")
    set --
    if ! source "${_AG_INIT_SCRIPT}" >/tmp/ag-wrapper-lease.log 2>&1; then
        echo "❌ AG WRAPPER: failed to acquire agent lease." >&2
        echo "   Log: /tmp/ag-wrapper-lease.log" >&2
        cat /tmp/ag-wrapper-lease.log >&2
        exit 1
    fi
    set -- "${ORIGINAL_ARGS[@]}"

    # In reuse mode the init script exports the configured identity variable
    # (and legacy HMVIP_IA_IDENTITY alias for older projects).
    _AG_IDENTITY_VALUE="$(eval echo "\${${_AG_IDENTITY_VAR}:-}")"
    export _AG_WORKTREE="${AG_WORKTREE_PATH:-${HMVIP_IA_WORKTREE_PATH:-}}"
    export _AG_IDENTITY="${_AG_IDENTITY_VALUE:-${HMVIP_IA_IDENTITY:-}}"
    export _AG_BRANCH="${AG_BRANCH:-${HMVIP_IA_BRANCH:-}}"
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
# 13. Execute real Kimi
# ---------------------------------------------------------------------------
exec "${_AG_REAL_KIMI}" "$@"
