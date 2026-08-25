#!/usr/bin/env bash
#
# slack-notify.sh — Slack notification helpers for agent-guard-core.
#
# Purpose:
#   - Post session lifecycle events (init, checkpoint, release, drift) to
#     Slack channels via the hmvip-slack CLI.
#   - Fail silently when Slack is disabled, the CLI is unavailable, or the
#     network/webhook fails. Slack is an interface, not a source of truth.
#   - Never expose secrets, webhook URLs or bot tokens in logs.
#
# Usage: sourced by packages/agent-guard-core/src/init.sh

# ---------------------------------------------------------------------------
# Resolve the canonical Slack CLI path.
# Priority:
#   1. <repo-root>/.agent/scripts/hmvip-slack/.venv/bin/hmvip-slack
#   2. hmvip-slack in $PATH
# ---------------------------------------------------------------------------
_guard_resolve_slack_cli() {
    local repo_root
    repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [[ -n "${repo_root}" && -x "${repo_root}/.agent/scripts/hmvip-slack/.venv/bin/hmvip-slack" ]]; then
        echo "${repo_root}/.agent/scripts/hmvip-slack/.venv/bin/hmvip-slack"
        return 0
    fi
    if command -v hmvip-slack >/dev/null 2>&1; then
        command -v hmvip-slack
        return 0
    fi
    return 1
}

_HMVIP_SLACK_CLI="$(_guard_resolve_slack_cli || true)"

# ---------------------------------------------------------------------------
# Check whether Slack posting is enabled.
# Returns 0 if enabled, non-zero otherwise.
# ---------------------------------------------------------------------------
_guard_slack_enabled() {
    [[ -z "${HMVIP_DISABLE_SLACK_POST:-}" ]] || return 1
    [[ -n "${_HMVIP_SLACK_CLI}" && -x "${_HMVIP_SLACK_CLI}" ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Low-level post to a Slack channel.
# Args: channel text [color]
# ---------------------------------------------------------------------------
_guard_slack_post() {
    local channel="${1:-}"
    local text="${2:-}"
    local color="${3:-}"

    if ! _guard_slack_enabled; then
        return 0
    fi

    if [[ -z "${channel}" || -z "${text}" ]]; then
        return 0
    fi

    local cli_args=("post" "--channel" "${channel}" "--text" "${text}")
    if [[ -n "${color}" ]]; then
        cli_args+=("--color" "${color}")
    fi

    # Fail silently — Slack is interface, not source of truth.
    "${_HMVIP_SLACK_CLI}" "${cli_args[@]}" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Notify #ia-ops that an agent session has started or been adopted.
# Args: identity branch [event]
# ---------------------------------------------------------------------------
_guard_notify_init() {
    local identity="${1:-}"
    local branch="${2:-}"
    local event="${3:-started}"

    if [[ -z "${identity}" ]]; then
        return 0
    fi

    local text
    text="🛡️ *${identity}* ${event} session on \`${branch}\`"
    _guard_slack_post "ia-ops" "${text}" "good"
}

# ---------------------------------------------------------------------------
# Notify #ia-ops with a checkpoint summary.
# Args: identity branch summary next_step [blockers]
# ---------------------------------------------------------------------------
_guard_notify_ops_checkpoint() {
    local identity="${1:-}"
    local branch="${2:-}"
    local summary="${3:-}"
    local next_step="${4:-}"
    local blockers="${5:-}"

    if ! _guard_slack_enabled; then
        return 0
    fi

    if [[ -z "${identity}" || -z "${branch}" || -z "${summary}" || -z "${next_step}" ]]; then
        return 0
    fi

    local blockers_arg=""
    if [[ -n "${blockers}" ]]; then
        blockers_arg="--blockers"
    fi

    "${_HMVIP_SLACK_CLI}" checkpoint \
        --identity "${identity}" \
        --branch "${branch}" \
        --summary "${summary}" \
        --next-step "${next_step}" \
        ${blockers_arg:+"${blockers_arg}" "${blockers}"} \
        >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Notify #ia-ops that a session has been released.
# Args: identity branch
# ---------------------------------------------------------------------------
_guard_notify_release() {
    local identity="${1:-}"
    local branch="${2:-}"

    if [[ -z "${identity}" ]]; then
        return 0
    fi

    local text
    text="🔓 *${identity}* released session from \`${branch}\`"
    _guard_slack_post "ia-ops" "${text}" "good"
}

# ---------------------------------------------------------------------------
# Notify #hmvip-alerts and #ia-council about slot/worktree drift.
# Args: identity branch drift
# ---------------------------------------------------------------------------
_guard_notify_drift() {
    local identity="${1:-}"
    local branch="${2:-}"
    local drift="${3:-}"

    if [[ -z "${identity}" || -z "${drift}" ]]; then
        return 0
    fi

    # Deduplicação: não spammar o mesmo drift a cada --status.
    # TTL de 6h por identidade+drift.
    local drift_cache_dir="${HOME}/.cache/hmvip-agent-guard"
    local drift_cache_file="${drift_cache_dir}/drift-notify-cache.jsonl"
    mkdir -p "${drift_cache_dir}" 2>/dev/null || true

    local cache_key
    cache_key="${identity}:${drift}"
    local now_epoch
    now_epoch="$(date +%s)"
    local ttl_seconds=21600  # 6 horas

    local last_notified="0"
    if [[ -f "${drift_cache_file}" ]]; then
        local tmp_file="${drift_cache_file}.tmp.$$"
        : > "${tmp_file}"
        while IFS=$'\t' read -r k t rest; do
            [[ -z "${k}" ]] && continue
            if [[ "${k}" == "${cache_key}" ]]; then
                last_notified="${t}"
            fi
            # Mantém entradas ainda válidas (remove expiradas).
            if [[ -n "${t}" && $(( now_epoch - t )) -lt ${ttl_seconds} ]]; then
                printf '%s\t%s\n' "${k}" "${t}" >> "${tmp_file}"
            fi
        done < "${drift_cache_file}"
        mv -f "${tmp_file}" "${drift_cache_file}" 2>/dev/null || true
    fi

    if [[ -n "${last_notified}" && ${last_notified} -gt 0 && $(( now_epoch - last_notified )) -lt ${ttl_seconds} ]]; then
        return 0
    fi

    # Registra notificação atual.
    printf '%s\t%s\n' "${cache_key}" "${now_epoch}" >> "${drift_cache_file}" 2>/dev/null || true

    local text
    text="⚠️ Drift detected for *${identity}* on \`${branch}\`: ${drift}"
    _guard_slack_post "hmvip-alerts" "${text}" "warning"
}
