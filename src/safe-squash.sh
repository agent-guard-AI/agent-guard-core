#!/usr/bin/env bash
#
# safe-squash.sh — Squash commits preserving agent-guard worktree metadata.
#
# Usage (sourced from bin/agent-guard):
#   source agent-guard safe-squash <count|--base <ref>> [--message|-m <msg>]
#
# Problem it solves:
#   Plain `git reset --soft <base> && git commit` may lose the worktree-origin
#   git note required by CI (`refs/notes/hmvip-worktree`) if the post-commit
#   hook fails or is skipped. This command deterministically attaches the note.
#
# This command:
#   1. Validates the working tree and index are clean.
#   2. Validates the squash base is safe (owned branch, not below merge-base).
#   3. Soft-resets to the base.
#   4. Commits with the supplied or auto-generated message.
#   5. Explicitly adds the worktree-origin note to the new HEAD.
#   6. Rolls back atomically if the note cannot be attached.
#
# Save the caller's shell flags BEFORE enabling strict mode so we can restore
# the original state before returning. Without this, strict mode leaks into the
# user's interactive shell and may kill the terminal on the next failing command.
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
    local no_verify=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
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
            --no-verify)
                no_verify=1
                shift
                ;;
            -h|--help)
                _safe_squash_usage
                return 0
                ;;
            -*)
                echo "❌ safe-squash: unknown option $1" >&2
                _safe_squash_usage >&2
                return 1
                ;;
            *)
                if [[ -n "${count}" || -n "${base}" ]]; then
                    echo "❌ safe-squash: provide either a count or --base." >&2
                    return 1
                fi
                count="$1"
                shift
                ;;
        esac
    done

    if [[ -z "${count}" && -z "${base}" ]]; then
        echo "❌ safe-squash: inform how many commits to squash (e.g. 3) or --base <ref>." >&2
        _safe_squash_usage >&2
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

    # F1 safety: require a clean working tree and index.
    if ! _safe_squash_worktree_is_clean; then
        return 1
    fi

    # F1 safety: stacked-branch protection.
    # Do not allow squashing below the merge-base with origin/develop unless
    # the user explicitly passes --base with a ref inside the branch's own history.
    local merge_base_with_develop
    merge_base_with_develop="$(git merge-base HEAD origin/develop 2>/dev/null || true)"
    if [[ -n "${merge_base_with_develop}" ]]; then
        if git merge-base --is-ancestor "${base_ref}" "${merge_base_with_develop}" 2>/dev/null; then
            echo "❌ safe-squash: base '${base:-HEAD~${count}}' is at or below the merge-base with origin/develop." >&2
            echo "   Squashing here would absorb commits from the parent branch." >&2
            echo "   If you really intend this, pass an explicit --base <ref> inside your branch history." >&2
            return 1
        fi
    fi

    if [[ -z "${message}" ]]; then
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

    local commit_count
    commit_count="$(git rev-list --count "${base_ref}..HEAD" 2>/dev/null || echo "0")"
    if [[ "${commit_count}" -eq 0 ]]; then
        echo "❌ safe-squash: no commits to squash in the requested range." >&2
        return 1
    fi

    echo "🛡️  safe-squash: squashing ${commit_count} commit(s) on '${BRANCH}'..." >&2

    local original_head
    original_head="$(git rev-parse HEAD)"

    # Stash any unexpected changes to preserve them through rollback.
    # Because we already verified the worktree is clean, this should be empty,
    # but it acts as a fail-safe against races or hook side-effects.
    local stash_ref=""
    if git diff --quiet HEAD && git diff --cached --quiet HEAD; then
        : # clean
    else
        stash_ref="$(git stash push -m "safe-squash auto-stash ${original_head}" 2>/dev/null || true)"
    fi

    local rollback_needed=0

    git reset --soft "${base_ref}"

    local commit_flags=()
    if [[ "${no_verify}" -eq 1 ]]; then
        commit_flags+=("--no-verify")
    fi

    if ! git commit "${commit_flags[@]}" -m "${message}"; then
        echo "⚠️  [AGENT GUARD] Commit failed during squash; reverting..." >&2
        rollback_needed=1
    else
        local new_head
        new_head="$(git rev-parse HEAD)"

        local NOTE_CONTENT="worktree:${WORKTREE_PATH}
identity:${IDENTITY}
branch:${BRANCH}"

        if ! git notes --ref="${NOTES_REF}" add -f -m "${NOTE_CONTENT}" "${new_head}" >/dev/null 2>&1; then
            echo "⚠️  [AGENT GUARD] Failed to add worktree origin note to squashed commit." >&2
            rollback_needed=1
        else
            # Verify the note is readable.
            if ! git notes --ref="${NOTES_REF}" show "${new_head}" >/dev/null 2>&1; then
                echo "⚠️  [AGENT GUARD] Note not readable after add; reverting..." >&2
                rollback_needed=1
            fi
        fi
    fi

    if [[ "${rollback_needed}" -eq 1 ]]; then
        git reset --hard "${original_head}"
        if [[ -n "${stash_ref}" && "${stash_ref}" != "No local changes to save" ]]; then
            git stash pop >/dev/null 2>&1 || true
        fi
        echo "❌ safe-squash: aborted and restored original HEAD ${original_head::12}." >&2
        return 1
    fi

    if [[ -n "${stash_ref}" && "${stash_ref}" != "No local changes to save" ]]; then
        git stash drop >/dev/null 2>&1 || true
    fi

    local final_head
    final_head="$(git rev-parse HEAD)"
    echo "✅ safe-squash: created ${final_head::12} with worktree note preserved." >&2
    echo "   Push the note ref together with the branch:" >&2
    echo "     git push origin ${BRANCH}" >&2
    echo "     git push origin ${NOTES_REF}" >&2
}

function _safe_squash_usage() {
    echo "Usage: source agent-guard safe-squash <count|--base <ref>> [-m <message>] [--no-verify]" >&2
    echo "  count       number of commits to squash from HEAD" >&2
    echo "  --base      explicit merge-base ref (safer for stacked branches)" >&2
    echo "  -m          commit message" >&2
    echo "  --no-verify skip pre-commit/commit-msg hooks (use with care)" >&2
}

function _safe_squash_worktree_is_clean() {
    if ! git diff --quiet HEAD; then
        echo "❌ safe-squash: working tree has unstaged changes. Commit or stash them first." >&2
        return 1
    fi
    if ! git diff --cached --quiet HEAD; then
        echo "❌ safe-squash: index has staged changes. Commit or stash them first." >&2
        return 1
    fi
    local untracked
    untracked="$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${untracked}" -gt 0 ]]; then
        echo "❌ safe-squash: working tree has ${untracked} untracked file(s). Commit or remove them first." >&2
        return 1
    fi
    return 0
}

_safe_squash_main "$@" || {
    local rc=$?
    _ag_safe_squash_restore_shell_flags
    return ${rc}
}
_ag_safe_squash_restore_shell_flags
