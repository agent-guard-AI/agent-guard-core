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

    # Throttle de heartbeat (ADR-0051): so atualiza last_activity a cada 5 prompts
    # ou 60s, o que vier primeiro. Reduz I/O e chamadas ao agent-guard em sessoes
    # ativas sem degradar a deteccao de stale/shell-pinned.
    local throttle_file throttle_now should_update=0
    throttle_file="${repo_root}/.agent-guard/session/heartbeat-throttle.json"
    throttle_now="$(date +%s)"
    should_update=1
    if [[ -f "${throttle_file}" ]]; then
        local last_update prompts_since last_identity
        last_update="$(jq -r '.last_update // 0' "${throttle_file}" 2>/dev/null || echo 0)"
        prompts_since="$(jq -r '.prompts_since // 0' "${throttle_file}" 2>/dev/null || echo 0)"
        last_identity="$(jq -r '.identity // ""' "${throttle_file}" 2>/dev/null || true)"
        if [[ "${last_identity}" == "${identity}" && "${last_update}" -gt 0 ]]; then
            # "a cada 5 prompts" => 4 prompts podem ser throttled; o 5o dispara update.
            if [[ "${prompts_since}" -lt 4 && "$((throttle_now - last_update))" -lt 60 ]]; then
                should_update=0
            fi
        fi
    fi

    if [[ "${should_update}" -eq 1 ]]; then
        _update_last_activity "${identity}" >/dev/null 2>&1 || true
        mkdir -p "$(dirname "${throttle_file}")"
        printf '{"identity":"%s","last_update":%s,"prompts_since":0}' "${identity}" "${throttle_now}" >"${throttle_file}.tmp" && mv "${throttle_file}.tmp" "${throttle_file}" || true
    else
        # Incrementa contador de prompts mesmo quando throttled.
        local new_prompts_since
        new_prompts_since="$(jq -r '.prompts_since // 0' "${throttle_file}" 2>/dev/null || echo 0)"
        new_prompts_since="$((new_prompts_since + 1))"
        jq --argjson n "${new_prompts_since}" '.prompts_since = $n' "${throttle_file}" >"${throttle_file}.tmp" 2>/dev/null && mv "${throttle_file}.tmp" "${throttle_file}" || true
    fi

    # Surface any pending wakeup alert for this identity.
    local wakeup_file="${repo_root}/.agent-guard/wakeup/${identity}.json"
    if [[ -f "${wakeup_file}" ]]; then
        local alert_title alert_severity alert_summary alert_source
        alert_title="$(jq -r '.title // "Wakeup"' "${wakeup_file}" 2>/dev/null || echo "Wakeup")"
        alert_severity="$(jq -r '.severity // "P1"' "${wakeup_file}" 2>/dev/null || echo "P1")"
        alert_summary="$(jq -r '.summary // ""' "${wakeup_file}" 2>/dev/null || true)"
        alert_source="$(jq -r '.source // ""' "${wakeup_file}" 2>/dev/null || true)"

        # Print a highly visible marker to stderr so the IA sees it.
        {
            echo ""
            echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
            echo "┃ 🚨 WAKEUP ALERT [${alert_severity}] para slot ${identity}"
            echo "┃ ${alert_title}"
            [[ -n "${alert_summary}" ]] && echo "┃ ${alert_summary}"
            [[ -n "${alert_source}" ]] && echo "┃ Fonte: ${alert_source}"
            echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
            echo ""
        } >&2

        # Move to acknowledged state so we do not spam every heartbeat.
        mv "${wakeup_file}" "${wakeup_file}.ack" >/dev/null 2>&1 || true
    fi

    return 0
}

_ag_heartbeat_main "$@" || true
_ag_hb_restore_flags
