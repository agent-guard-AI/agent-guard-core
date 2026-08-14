#!/usr/bin/env bash
#
# Agent Guard — CodeWhale CLI Wrapper
#
# Mandatory agent isolation enforcement for the CodeWhale CLI.
# Every invocation of `codewhale` inside an Agent Guard managed repository is
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
#   mv <bin_dir>/codewhale <bin_dir>/codewhale.real
#   cp <path-to>/wrappers/codewhale/wrapper.sh <bin_dir>/codewhale
#   chmod +x <bin_dir>/codewhale
#
# Emergency bypass (use only for debugging/recovery):
#   AG_WRAPPER_BYPASS=1 codewhale ...
#   AG_WRAPPER_BYPASS=1 codewhale ...  # legacy alias
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Emergency bypass (canonical env var + legacy alias)
# ---------------------------------------------------------------------------
if [[ "${AG_WRAPPER_BYPASS:-}" == "1" || "${AG_WRAPPER_BYPASS:-}" == "1" ]]; then
    _AG_REAL_CW="${AG_CODEWHALE_REAL:-${AG_CODEWHALE_REAL:-}}"
    if [[ -z "${_AG_REAL_CW}" ]]; then
        _AG_REAL_CW_CANDIDATES=(
            "${HOME}/.npm-global/lib/node_modules/codewhale/bin/codewhale.js"
            "$(command -v codewhale.real 2>/dev/null || true)"
            "$(command -v codewhale 2>/dev/null || true)"
        )
        for candidate in "${_AG_REAL_CW_CANDIDATES[@]}"; do
            if [[ -n "${candidate}" && -f "${candidate}" ]]; then
                _AG_REAL_CW="${candidate}"
                break
            fi
        done
    fi
    if [[ -z "${_AG_REAL_CW}" || ! -f "${_AG_REAL_CW}" ]]; then
        echo "❌ AG WRAPPER: cannot locate real codewhale script for bypass." >&2
        exit 1
    fi
    exec node "${_AG_REAL_CW}" "$@"
fi

# ---------------------------------------------------------------------------
# 0.5 Explicit slot selection: --slot <identity> or AGENT_GUARD_SLOT
# ---------------------------------------------------------------------------
# Allows starting the agent directly into a specific slot in one command:
#
#   codewhale --slot codewhale1          # acquire (or adopt) slot codewhale1
#   AGENT_GUARD_SLOT=codewhale1 codewhale  # same, via environment variable
#
# The flag is consumed by the wrapper and never forwarded to the real CLI.
# If the CodeWhale CLI ever introduces its own --slot flag, use AGENT_GUARD_SLOT.
_AG_SLOT="${AGENT_GUARD_SLOT:-}"
if [[ $# -gt 0 ]]; then
    _AG_REMAINING_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slot)
                if [[ -z "${2:-}" ]]; then
                    echo "❌ AG WRAPPER: --slot requires an identity (ex: codewhale1)." >&2
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
# `exec` into the real CodeWhale process, so the lease stays bound to the agent
# process instead of the wrapper's parent shell.
unset AGENT_GUARD_SESSION_PID
export AGENT_GUARD_SESSION_PID="$$"

# Never inherit lease state from a parent Agent Guard session.
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
_AG_REAL_CW=""
_AG_IDENTITY_VAR=""
_AG_KNOWN_IDENTITIES=""
_AG_INIT_SCRIPT_NAME=""
_AG_SKIP_INIT="false"

try_source_real_codewhale() {
    local bin_dir="$1"
    local real_name="$2"
    local candidate="${bin_dir}/${real_name}"
    if [[ -n "${bin_dir}" && -n "${real_name}" && -f "${candidate}" ]]; then
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
    _AG_BIN_DIR="$(bash "${config_bin}" get wrappers.codewhale.bin_dir "${HOME}/.npm-global/bin" 2>/dev/null || echo "${HOME}/.npm-global/bin")"
    _AG_REAL_BIN_NAME="$(bash "${config_bin}" get wrappers.codewhale.real_bin 'codewhale.real' 2>/dev/null || echo 'codewhale.real')"
    _AG_IDENTITY_VAR="$(bash "${config_bin}" get commit.identity_env_var 'AGENT_GUARD_IDENTITY' 2>/dev/null || echo 'AGENT_GUARD_IDENTITY')"
    _AG_INIT_SCRIPT_NAME="$(bash "${config_bin}" get paths.init_script '.agent-guard-init' 2>/dev/null || echo '.agent-guard-init')"
    _AG_KNOWN_IDENTITIES="$(bash "${config_bin}" keys identities 2>/dev/null || true)"

    # Resolve real CodeWhale script. The npm wrapper is a Node.js launcher that
    # resolves the native binary relative to its own directory, so the real
    # target is the .js launcher, not the ELF.
    if ! _AG_REAL_CW="$(try_source_real_codewhale "${_AG_BIN_DIR}" "${_AG_REAL_BIN_NAME}")"; then
        local path_candidate
        path_candidate="$(command -v "${_AG_REAL_BIN_NAME}" 2>/dev/null || true)"
        if [[ -n "${path_candidate}" && -f "${path_candidate}" ]]; then
            _AG_REAL_CW="${path_candidate}"
        fi
    fi

    # Final fallback: the canonical npm package script.
    if [[ -z "${_AG_REAL_CW}" || ! -f "${_AG_REAL_CW}" ]]; then
        local npm_script="${_AG_BIN_DIR}/../lib/node_modules/codewhale/bin/codewhale.js"
        npm_script="$(cd "${_AG_BIN_DIR}" 2>/dev/null && realpath -m "${npm_script}" 2>/dev/null || echo "${npm_script}")"
        if [[ -f "${npm_script}" ]]; then
            _AG_REAL_CW="${npm_script}"
        fi
    fi

    _AG_CONFIG_LOADED="true"
    export AGENT_GUARD_REPO_ROOT="${_AG_REPO_ROOT}"
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
        echo "     # ensure agent-guard.yaml exists" >&2
        echo "" >&2
        echo "   Emergency bypass (use only for recovery):" >&2
        echo "     AG_WRAPPER_BYPASS=1 codewhale ..." >&2
        exit 1
    fi

    # Not in an Agent Guard managed repository; pass through unchanged.
    _AG_REAL_CW="${AG_CODEWHALE_REAL:-${AG_CODEWHALE_REAL:-}}"
    if [[ -z "${_AG_REAL_CW}" ]]; then
        for candidate in \
            "${HOME}/.npm-global/lib/node_modules/codewhale/bin/codewhale.js" \
            "$(command -v codewhale.real 2>/dev/null || true)" \
            "$(command -v codewhale 2>/dev/null || true)"; do
            if [[ -n "${candidate}" && -f "${candidate}" ]]; then
                _AG_REAL_CW="${candidate}"
                break
            fi
        done
    fi
    if [[ -n "${_AG_REAL_CW}" && -f "${_AG_REAL_CW}" ]]; then
        exec node "${_AG_REAL_CW}" "$@"
    fi
    echo "❌ AG WRAPPER: cannot locate real codewhale script." >&2
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
        if [[ -n "${_AG_REAL_CW}" && -f "${_AG_REAL_CW}" ]]; then
            exec node "${_AG_REAL_CW}" "$@"
        fi
        echo "❌ AG WRAPPER: cannot locate real codewhale script." >&2
        exit 1
    fi
fi

if [[ -z "${_AG_REAL_CW}" || ! -f "${_AG_REAL_CW}" ]]; then
    echo "❌ AG WRAPPER: real codewhale script not found at ${_AG_BIN_DIR}/${_AG_REAL_BIN_NAME}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Management/read-only commands do not require a lease
# ---------------------------------------------------------------------------
_ag_is_management_command() {
    for arg in "$@"; do
        case "${arg}" in
            --version|-V|--help|-h|update|upgrade|doctor|login|provider|export|migrate|auth)
                return 0
                ;;
        esac
    done
    return 1
}

if _ag_is_management_command "$@"; then
    exec node "${_AG_REAL_CW}" "$@"
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
    local current_worktree="${_AG_WORKTREE:-}"

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
if ! _ag_have_lease; then
    # If already inside a worktree, try to attach to its branch; otherwise
    # acquire a fresh lease via the official init script.
    if [[ "${CWD}" != "${_AG_MAIN_REPO}" ]]; then
        for prefix in ${_AG_KNOWN_IDENTITIES}; do
            _AG_WT_PREFIX="$(bash "${_AG_CONFIG_BIN}" get "identities.${prefix}.worktree_prefix" '' 2>/dev/null || true)"
            if [[ -z "${_AG_WT_PREFIX}" ]]; then
                continue
            fi
            if [[ "${CWD}" == "${_AG_BASE_DIR}/${_AG_WT_PREFIX}"[0-9]* || "${CWD}" == "${_AG_BASE_DIR}/${_AG_WT_PREFIX}"[0-9]*/* ]]; then
                # Inside a known worktree: try to reuse its lease if it is ours.
                local candidate_identity
                candidate_identity="$(basename "${CWD}" | sed "s/^${_AG_WT_PREFIX}//")"
                if [[ -n "${candidate_identity}" && "${candidate_identity}" =~ ^[0-9]+$ ]]; then
                    candidate_identity="${prefix}${candidate_identity}"
                else
                    candidate_identity="${prefix}1"
                fi
                if [[ -n "${_AG_SLOT}" && "${_AG_SLOT}" != "${candidate_identity}" ]]; then
                    echo "⚠️  AG WRAPPER: requested slot ${_AG_SLOT} differs from worktree ${candidate_identity}." >&2
                    echo "   Adopting the requested slot." >&2
                    candidate_identity="${_AG_SLOT}"
                fi
                source "${_AG_REPO_ROOT}/${_AG_INIT_SCRIPT_NAME}" --attach "${candidate_identity}" 2>/dev/null && _AG_SKIP_INIT="true" || true
                break
            fi
        done
    fi

    if [[ "${_AG_SKIP_INIT}" != "true" ]]; then
        # If an explicit slot was requested, use it; otherwise let init pick.
        if [[ -n "${_AG_SLOT}" ]]; then
            source "${_AG_REPO_ROOT}/${_AG_INIT_SCRIPT_NAME}" "${_AG_SLOT}" ia-a
        else
            source "${_AG_REPO_ROOT}/${_AG_INIT_SCRIPT_NAME}" codewhale ia-a
        fi
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
    echo "   Change to your worktree or start codewhale from ${_AG_MAIN_REPO}." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 11. Worktree cleanliness guard
# ---------------------------------------------------------------------------
if ! _ag_check_worktree_clean "${_AG_WORKTREE}" "${_AG_IDENTITY}"; then
    exit 1
fi

# ---------------------------------------------------------------------------
# 12. If launched from main repo, switch to leased worktree
# ---------------------------------------------------------------------------
if [[ "${CWD}" == "${_AG_MAIN_REPO}" ]]; then
    cd "${_AG_WORKTREE}"
fi

# ---------------------------------------------------------------------------
# 13. Execute real CodeWhale
# ---------------------------------------------------------------------------
exec node "${_AG_REAL_CW}" "$@"
