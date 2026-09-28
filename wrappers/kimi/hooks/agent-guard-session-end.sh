#!/usr/bin/env bash
#
# Agent Guard SessionEnd hook for Kimi Code.
# Attempts to auto-release the current slot when the conversation ends,
# but only if the worktree is clean and there are no open PRs.
#
# Safety: this script is sourced by Kimi Code hooks. It must not leak strict
# mode or change the caller's working directory.

_AG_SE_OLD_FLAGS="$(set +o)"
_ag_se_restore_flags() {
    eval "${_AG_SE_OLD_FLAGS}" 2>/dev/null || true
}

function _ag_session_end_main() {
    set -euo pipefail

    local repo_root=""
    repo_root="$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "${repo_root}" || ! -f "${repo_root}/agent-guard.yaml" ]]; then
        return 0
    fi

    # Kimi CLI self-updates replace <bin_dir>/kimi with the raw binary, usually
    # when a session exits. Restore the Agent Guard wrapper now (best-effort,
    # no-op when intact) so the next launch never finds an unwrapped binary —
    # the periodic cron recovery leaves a window of several minutes in which a
    # relaunch would bypass slot isolation entirely.
    local recovery_script="${repo_root}/packages/agent-guard-core/wrappers/kimi/recovery.sh"
    if [[ -f "${recovery_script}" ]]; then
        bash "${recovery_script}" --repo-root "${repo_root}" >/dev/null 2>&1 || true
    fi

    local init_stub="${repo_root}/.hmvip-agent-init"
    if [[ ! -f "${init_stub}" ]]; then
        return 0
    fi

    # Skip wrapper recovery here: this hook already ran recovery.sh above, and
    # re-running it inside init.sh would add latency to SessionEnd/shutdown.
    AGENT_GUARD_FUNCTIONS_ONLY=1
    AGENT_GUARD_SKIP_WRAPPER_RECOVERY=1
    # shellcheck source=/dev/null
    if ! source "${init_stub}" >/dev/null 2>&1; then
        return 0
    fi

    local worktree_name identity
    worktree_name="$(basename "${PWD}" 2>/dev/null || true)"
    identity="$(_detect_identity_from_worktree_name "${worktree_name}" 2>/dev/null | awk '{print $1 $2}' || true)"
    if [[ -z "${identity}" ]]; then
        return 0
    fi

    # Decisao de "sessao ativa" via facade publica (F5C) — nao via
    # _load_session_field (READ proibido neste hook). Fail-open: facade
    # indisponivel/ausente == inativo == retorno silencioso, como antes.
    # Root = mesma derivacao do kernel (git-common-dir): a facade le o MESMO
    # storage que _get_session_file/_auto_release_if_safe usam.
    local _se_main_repo _gd
    _gd="$(git -C "${PWD}" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "${_gd}" = /* ]]; then
        _se_main_repo="$(dirname "${_gd}")"
    else
        _se_main_repo="$(cd "${PWD}/${_gd}/.." 2>/dev/null && pwd || echo "${PWD}")"
    fi
    local _slots_bin="${_se_main_repo}/packages/agent-guard-core/bin/agent-guard-slots"
    if [[ -x "${_slots_bin}" ]]; then
        local _ag_py
        _ag_py="$(bash "${_se_main_repo}/packages/agent-guard-core/bin/agent-guard-python" 2>/dev/null || echo "python3")"
        session_status="$(AGENT_GUARD_REPO_ROOT="${_se_main_repo}" bash "${_slots_bin}" --identity "${identity}" 2>/dev/null | "${_ag_py}" -c '
import json, sys
try:
    slots = json.load(sys.stdin).get("slots", [])
except Exception:
    slots = []
print(slots[0].get("status", "") if slots else "")
' 2>/dev/null || true)"
    else
        session_status=""
    fi
    [[ "${session_status}" == "active" ]] || return 0

    local worktree_path
    worktree_path="$(_get_worktree_path "${identity}" 2>/dev/null || true)"
    [[ -n "${worktree_path}" ]] || return 0

    # Only auto-release when safe; failures are silent to avoid blocking Kimi shutdown,
    # but _auto_release_if_safe now records audit events in the session journal and in
    # the slot task note so blocked slots are visible to admins.
    _auto_release_if_safe "${identity}" "${worktree_path}" "session-end" "session_end_blocked" >/dev/null 2>&1 || true

    # Clear tab state from the lease even if the slot could not be released
    # (dirty worktree / open PRs). The cockpit reads tab_* from the lease.
    _save_session_field "${identity}" "tab_state" "" >/dev/null 2>&1 || true
    _save_session_field "${identity}" "tab_title" "" >/dev/null 2>&1 || true
    _save_session_field "${identity}" "tab_bg" "" >/dev/null 2>&1 || true
    _save_session_field "${identity}" "tab_tty" "" >/dev/null 2>&1 || true
    _save_session_field "${identity}" "tab_updated" "" >/dev/null 2>&1 || true

    return 0
}

_ag_session_end_main "$@" || true
_ag_se_restore_flags
