#!/usr/bin/env bash
#
# Agent Guard — Prime Agent Leash
#
# Wrapper/leash for Prime Agent sessions inside the HMVIP monorepo.
# Unlike Kimi/CodeWhale wrappers, this does NOT replace a CLI binary;
# it is sourced before launching a Prime Agent so the agent inherits a
# valid Agent Guard lease, worktree and Git author.
#
# Usage (from the HMVIP repo root):
#   source packages/agent-guard-core/wrappers/prime/leash.sh [prime<N>] [role] [--rename-topic "new topic"]
#
# Examples:
#   source packages/agent-guard-core/wrappers/prime/leash.sh prime1 ia-a
#   source packages/agent-guard-core/wrappers/prime/leash.sh prime1 ia-a --rename-topic "fix dead PID in adopt"
#
# The script will:
#   1. Detect the HMVIP repo root by walking up from $PWD.
#   2. Source .hmvip-agent-init to lease the requested slot.
#   3. Optionally rename the session topic.
#   4. cd into the leased worktree.
#   5. Export all Agent Guard environment variables.
#   6. Update the terminal tab/window title (OSC 0) with slot + task.
#
# During a live session, call `prime_agent_update_tab` to refresh the title
# without re-sourcing the leash.
#
# Important: do NOT execute this script; always source it, otherwise the
# lease and cd are lost in a subshell.

# Save caller's shell flags and options so we can restore them before returning.
# This script is meant to be sourced, so we must not leak 'set -euo pipefail'.
if [ -n "${BASH_VERSION:-}" ]; then
    _AG_PRIME_OLD_FLAGS="$-"
    _AG_PRIME_OLDOPTS="$(set +o)"
else
    _AG_PRIME_OLD_FLAGS=""
    _AG_PRIME_OLDOPTS=""
fi

# If being executed rather than sourced, refuse.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "❌ Prime Agent leash must be sourced, not executed." >&2
    echo "   Run: source ${BASH_SOURCE[0]} [prime<N>] [role] [--rename-topic \"new topic\"]" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Public helper: update the tab title on demand during a live session.
# ---------------------------------------------------------------------------
function prime_agent_update_tab() {
    local slot="${PRIME_AGENT_GUARD_IDENTITY:-${1:-prime1}}"
    local topic="${PRIME_AGENT_GUARD_TOPIC:-${2:-}}"

    # If no explicit topic, derive from branch.
    if [ -z "${topic}" ]; then
        topic="${PRIME_AGENT_GUARD_BRANCH:-}"
        topic="${topic#ia-${slot}/ia-a/}"
        topic="${topic#ia-${slot}/}"
        topic="${topic%/*}"
    fi

    # Try to enrich title from the slot note (context + next step).
    local worktree="${PRIME_AGENT_GUARD_WORKTREE:-${3:-${PWD}}}"
    local slot_note="${worktree}/.agent-guard/tasks/${slot}.md"
    local context="" next_step=""
    if [ -f "${slot_note}" ]; then
        context="$(grep -m1 '^## Contexto' "${slot_note}" 2>/dev/null | sed 's/^## Contexto[[:space:]]*//' | head -c 40)"
        next_step="$(grep -m1 '^## Próximo passo' "${slot_note}" 2>/dev/null | sed 's/^## Próximo passo[[:space:]]*//' | head -c 40)"
    fi

    local title="${slot}"
    [ -n "${topic}" ] && title="${title}${HMVIP_TAB_SEPARATOR:- | }${topic}"
    [ -n "${context}" ] && title="${title}${HMVIP_TAB_SEPARATOR:- | }${context}"
    [ -n "${next_step}" ] && title="${title}${HMVIP_TAB_SEPARATOR:- | }${next_step}"

    # Trim to avoid overflowing tab title.
    local max_chars="${HMVIP_TAB_TITLE_CHARS:-60}"
    if [ "${#title}" -gt "${max_chars}" ]; then
        title="${title:0:${max_chars}}…"
    fi

    # Prefer agent-guard-core tab helpers if available.
    local repo_root="${PRIME_AGENT_GUARD_REPO_ROOT:-}"
    if [ -z "${repo_root}" ]; then
        repo_root="${PWD}"
        while [[ "${repo_root}" != "/" && ! -f "${repo_root}/.hmvip-agent-init" ]]; do
            repo_root="$(dirname "${repo_root}")"
        done
    fi
    local tab_sh="${repo_root}/packages/agent-guard-core/src/tab.sh"
    if [ -f "${tab_sh}" ]; then
        # shellcheck source=/dev/null
        source "${tab_sh}" 2>/dev/null || true
        if command -v _hmvip_tab_write >/dev/null 2>&1; then
            _hmvip_tab_write "${title}" >/dev/null 2>&1 || true
            return 0
        fi
    fi

    # Fallback: write OSC 0 directly to the current TTY.
    local tty_dest="/dev/tty"
    local tty_name="$(tty 2>/dev/null || true)"
    [ -n "${tty_name}" ] && tty_dest="${tty_name}"
    if [ -w "${tty_dest}" ]; then
        printf '\033]0;%s\007' "${title}" >"${tty_dest}" 2>/dev/null || true
    fi
}
export -f prime_agent_update_tab 2>/dev/null || true

# ---------------------------------------------------------------------------
# Main routine
# ---------------------------------------------------------------------------
function main() {
    # Enable strict mode only inside this function.
    set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
_RENAME_TOPIC=""
_POSITIONAL_ARGS=()

# Handle --rename-topic anywhere in args; collect remaining positionals.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rename-topic)
            if [[ -n "${2:-}" ]]; then
                _RENAME_TOPIC="$2"
                shift 2
            else
                echo "❌ --rename-topic requires a value." >&2
                return 1
            fi
            ;;
        --rename-topic=*)
            _RENAME_TOPIC="${1#--rename-topic=}"
            shift
            ;;
        *)
            _POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

_IDENTITY="${_POSITIONAL_ARGS[0]:-prime1}"
_ROLE="${_POSITIONAL_ARGS[1]:-ia-a}"

# Validate identity prefix
if [[ ! "${_IDENTITY}" =~ ^prime[0-9]+$ ]]; then
    echo "❌ Invalid Prime identity '${_IDENTITY}'. Use prime1, prime2, ..." >&2
    return 1
fi

# Find repo root (look for .hmvip-agent-init)
_REPO_ROOT="${PWD}"
while [[ "${_REPO_ROOT}" != "/" && ! -f "${_REPO_ROOT}/.hmvip-agent-init" ]]; do
    _REPO_ROOT="$(dirname "${_REPO_ROOT}")"
done
if [[ ! -f "${_REPO_ROOT}/.hmvip-agent-init" ]]; then
    echo "❌ Could not locate HMVIP repo root (no .hmvip-agent-init found)." >&2
    return 1
fi

cd "${_REPO_ROOT}"

# Lease the slot. This sources the official stub and exports all needed envs.
# shellcheck source=/dev/null
source .hmvip-agent-init "${_IDENTITY}" "${_ROLE}"

# The init script already cd'd to the worktree. Export convenience envs in
# case the caller needs them.
export PRIME_AGENT_GUARD_IDENTITY="${AGENT_GUARD_IDENTITY:-${_IDENTITY}}"
export PRIME_AGENT_GUARD_WORKTREE="${AGENT_GUARD_WORKTREE_PATH:-${PWD}}"
export PRIME_AGENT_GUARD_BRANCH="${AGENT_GUARD_BRANCH:-}"
export PRIME_AGENT_GUARD_REPO_ROOT="${_REPO_ROOT}"

# Prime Agent built-in provider 'kimi-coding' expects KIMI_API_KEY, but the
# HMVIP environment only guarantees KIMI_API_KEY_A/B. Alias the leased
# slot's key so subagents and CLI calls inherit a valid credential.
export KIMI_API_KEY="${KIMI_API_KEY_A:-${KIMI_API_KEY:-}}"

# Handle --rename-topic by renaming the current branch and updating env.
if [ -n "${_RENAME_TOPIC}" ]; then
    source .hmvip-agent-init --rename-topic "${_RENAME_TOPIC}" >/dev/null 2>&1 || true
    export PRIME_AGENT_GUARD_BRANCH="${AGENT_GUARD_BRANCH:-}"
    export PRIME_AGENT_GUARD_TOPIC="${_RENAME_TOPIC}"
fi

# ---------------------------------------------------------------------------
# Prime Agent tab title (OSC 0) — best-effort integration with hmvip-tab
# ---------------------------------------------------------------------------
prime_agent_update_tab

echo "✅ Prime Agent leashed: ${_IDENTITY} on ${PRIME_AGENT_GUARD_WORKTREE} (${PRIME_AGENT_GUARD_BRANCH})"
echo "   Tip: run 'prime_agent_update_tab' anytime to refresh the tab title."
}

# Restore caller's shell flags/options and run main.
# If main fails, still restore flags before returning.
main "$@"
_AG_PRIME_MAIN_EXIT=$?

if [ -n "${_AG_PRIME_OLDOPTS:-}" ]; then
    eval "${_AG_PRIME_OLDOPTS}" 2>/dev/null || true
fi
if [ -n "${_AG_PRIME_OLD_FLAGS:-}" ]; then
    set +${_AG_PRIME_OLD_FLAGS//[^eimux]/} 2>/dev/null || true
    set -${_AG_PRIME_OLD_FLAGS//[^eimux]/} 2>/dev/null || true
fi

return ${_AG_PRIME_MAIN_EXIT}
