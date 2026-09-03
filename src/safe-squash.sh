#!/usr/bin/env bash
#
# safe-squash.sh — Squash commits preserving agent-guard worktree metadata.
#
# Usage (sourced from bin/agent-guard):
#   source agent-guard safe-squash <count|--all|--base <ref>> [--message|-m <msg>]
#
# Problem it solves:
#   Plain `git reset --soft <base> && git commit` creates a new HEAD that never
#   runs the post-commit hook, so the worktree-origin git note required by CI
#   (`refs/notes/hmvip-worktree`) is missing. The next push is then blocked or
#   fails the CI Worktree Origin Audit.
#
# This command:
#   1. Determines the squash base.
#   2. Soft-resets to it.
#   3. Commits with the supplied or auto-generated message.
#   4. Explicitly adds the worktree-origin note to the new HEAD.
#
# Save the caller's shell flags BEFORE enabling strict mode so we can restore
# the original state before returning. Without this, strict mode leaks into the
# user's interactive shell and may kill the terminal on the next failing command
# (see hmvip-shell-safety, L222).
_AG_SAFE_SQUASH_OLD_FLAGS="$(set +o)"
_ag_safe_squash_restore_shell_flags() {
    eval "${_AG_SAFE_SQUASH_OLD_FLAGS}" 2>/dev/null || true
}

set -euo pipefail

function _safe_squash_main() {
    set -euo pipefail

    local count=""
    local base=""
    local message=""
    local auto_message=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                base="origin/develop"
                shift
                ;;
            --base)
                base="${2:-}"
                if [[ -z "${base}" ]]; then
                    echo "❌ safe-squash: --base requires a ref." >&2
                    return 1
                fi
                shift 2
                ;;
            -m|--message)
                message="${2:-}"
                if [[ -z "${message}" ]]; then
                    echo "❌ safe-squash: -m requires a message." >&2
                    return 1
                fi
                shift 2
                ;;
            -*)
                echo "❌ safe-squash: unknown option $1" >&2
                echo "   Usage: source agent-guard safe-squash <count|--all|--base <ref>> [-m <message>]" >&2
                return 1
                ;;
            *)
                if [[ -n "${count}" || -n "${base}" ]]; then
                    echo "❌ safe-squash: provide either a count, --all or --base." >&2
                    return 1
                fi
                count="$1"
                shift
                ;;
        esac
    done

    if [[ -z "${count}" && -z "${base}" ]]; then
        echo "❌ safe-squash: inform how many commits to squash (e.g. 3), --all, or --base <ref>." >&2
        return 1
    fi

    local WORKTREE_PATH
    WORKTREE_PATH="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [[ -z "${WORKTREE_PATH}" ]]; then
        echo "❌ safe-squash: not inside a git worktree." >&2
        return 1
    fi

    local git_common_dir
    git_common_dir="$(git -C "${WORKTREE_PATH}" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    local REPO_ROOT
    if [[ "${git_common_dir}" = /* ]]; then
        REPO_ROOT="$(cd "$(dirname "${git_common_dir}")" 2>/dev/null && pwd || echo "${WORKTREE_PATH}")"
    else
        REPO_ROOT="$(cd "${WORKTREE_PATH}/${git_common_dir}/.." 2>/dev/null && pwd || echo "${WORKTREE_PATH}")"
    fi

    local AGENT_GUARD_BIN="${REPO_ROOT}/packages/agent-guard-core/bin/agent-guard-config"
    if [[ ! -f "${AGENT_GUARD_BIN}" ]]; then
        echo "❌ safe-squash: agent-guard-config not found at ${AGENT_GUARD_BIN}" >&2
        return 1
    fi

    local NOTES_REF
    NOTES_REF="$(bash "${AGENT_GUARD_BIN}" get git.notes_ref 'refs/notes/agent-guard-worktree')"

    local WORKTREE_NAME
    WORKTREE_NAME="$(basename "${WORKTREE_PATH}")"
    local IDENTITY=""
    local IDENTITY_NAMES
    IDENTITY_NAMES="$(bash "${AGENT_GUARD_BIN}" keys identities 2>/dev/null || true)"
    for name in ${IDENTITY_NAMES}; do
        local prefix=""
        prefix="$(bash "${AGENT_GUARD_BIN}" get "identities.${name}.worktree_prefix" '')"
        if [[ -n "${prefix}" && "${WORKTREE_NAME}" =~ ^${prefix}[0-9]+(-[a-z0-9-]+)?$ ]]; then
            local slot_and_suffix="${WORKTREE_NAME#${prefix}}"
            IDENTITY="${name}${slot_and_suffix%%-*}"
            break
        fi
    done

    if [[ -z "${IDENTITY}" ]]; then
        echo "❌ safe-squash: current worktree '${WORKTREE_NAME}' is not an AI worktree." >&2
        return 1
    fi

    local BRANCH
    BRANCH="$(git branch --show-current 2>/dev/null || echo "")"
    if [[ -z "${BRANCH}" ]]; then
        echo "❌ safe-squash: detached HEAD; checkout a branch first." >&2
        return 1
    fi

    if [[ "${BRANCH}" != "ia-${IDENTITY}/"* && "${BRANCH}" != "_released/${IDENTITY}" ]]; then
        echo "❌ safe-squash: branch '${BRANCH}' does not belong to identity '${IDENTITY}'." >&2
        echo "   You may only squash on your own task branch." >&2
        return 1
    fi

    local base_ref=""
    if [[ -n "${base}" ]]; then
        base_ref="$(git rev-parse "${base}" 2>/dev/null || true)"
        if [[ -z "${base_ref}" ]]; then
            echo "❌ safe-squash: cannot resolve base '${base}'." >&2
            return 1
        fi
    else
        if ! [[ "${count}" =~ ^[0-9]+$ && "${count}" -gt 0 ]]; then
            echo "❌ safe-squash: count must be a positive integer, got '${count}'." >&2
            return 1
        fi
        base_ref="$(git rev-parse "HEAD~${count}" 2>/dev/null || true)"
        if [[ -z "${base_ref}" ]]; then
            echo "❌ safe-squash: HEAD~${count} does not exist." >&2
            return 1
        fi
    fi

    if [[ "${auto_message}" -eq 0 && -z "${message}" ]]; then
        # Build a default message from the squashed commits.
        local squashed_messages
        squashed_messages="$(git log --format='%s' "${base_ref}..HEAD" 2>/dev/null || true)"
        if [[ -n "${squashed_messages}" ]]; then
            message="$(echo "${squashed_messages}" | head -n 1)"
            local body
            body="$(echo "${squashed_messages}" | tail -n +2)"
            if [[ -n "${body}" ]]; then
                message="${message}

Squashed commits:
${body}"
            fi
        fi
    fi

    if [[ -z "${message}" ]]; then
        message="squash: consolidate commits on ${BRANCH}"
    fi

    echo "🛡️  safe-squash: squashing $(git rev-list --count "${base_ref}..HEAD") commit(s) on '${BRANCH}'..." >&2

    local original_head
    original_head="$(git rev-parse HEAD)"

    git reset --soft "${base_ref}"

    # Commit without running hooks (we will attach the note ourselves).
    git commit --no-verify -m "${message}"

    local new_head
    new_head="$(git rev-parse HEAD)"

    local NOTE_CONTENT="worktree:${WORKTREE_PATH}
identity:${IDENTITY}
branch:${BRANCH}"

    if ! git notes --ref="${NOTES_REF}" add -f -m "${NOTE_CONTENT}" "${new_head}" >/dev/null 2>&1; then
        echo "⚠️  [AGENT GUARD] Failed to add worktree origin note to squashed commit." >&2
        echo "   Reverting squash..." >&2
        git reset --hard "${original_head}"
        return 1
    fi

    echo "✅ safe-squash: created ${new_head::12} with worktree note preserved." >&2
    echo "   Push the note ref together with the branch:" >&2
    echo "     git push origin ${BRANCH}" >&2
    echo "     git push origin ${NOTES_REF}" >&2
}

_safe_squash_main "$@" || {
    local rc=$?
    _ag_safe_squash_restore_shell_flags
    return ${rc}
}
_ag_safe_squash_restore_shell_flags
