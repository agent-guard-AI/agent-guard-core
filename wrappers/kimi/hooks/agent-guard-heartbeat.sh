#!/usr/bin/env bash
#
# Agent Guard heartbeat hook for Kimi Code.
# Triggered on every UserPromptSubmit to keep last_activity fresh.
#
# Safety: this script is sourced by Kimi Code hooks. It must not leak strict
# mode or change the caller's working directory.

_AG_HB_OLD_FLAGS="$(set +o)"
_ag_hb_restore_flags() {
    eval "${_AG_HB_OLD_FLAGS}" 2>/dev/null || true
}

function _ag_heartbeat_main() {
    set -euo pipefail

    # Resolve the repository root from CWD.
    local repo_root=""
    repo_root="$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "${repo_root}" || ! -f "${repo_root}/agent-guard.yaml" ]]; then
        return 0
    fi

    local init_stub="${repo_root}/.hmvip-agent-init"
    if [[ ! -f "${init_stub}" ]]; then
        return 0
    fi

    # Load Agent Guard helpers only (no session acquisition side effects).
    # Skip wrapper recovery in the heartbeat path: it runs on every prompt and
    # must stay lightweight; recovery is handled by SessionEnd and by cron.
    local _ag_functions_loaded=""
    AGENT_GUARD_FUNCTIONS_ONLY=1
    AGENT_GUARD_SKIP_WRAPPER_RECOVERY=1
    # shellcheck source=/dev/null
    if ! source "${init_stub}" >/dev/null 2>&1; then
        return 0
    fi
    _ag_functions_loaded="1"

    if [[ -z "${_ag_functions_loaded}" ]]; then
        return 0
    fi

    local worktree_name identity
    worktree_name="$(basename "${PWD}" 2>/dev/null || true)"
    identity="$(_detect_identity_from_worktree_name "${worktree_name}" 2>/dev/null | awk '{print $1 $2}' || true)"
    if [[ -z "${identity}" ]]; then
        return 0
    fi

    _update_last_activity "${identity}" >/dev/null 2>&1 || true
    return 0
}

_ag_heartbeat_main "$@" || true
_ag_hb_restore_flags
