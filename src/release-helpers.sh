#!/usr/bin/env bash
#
# agent-guard-core — Release helpers
#
# Functions used by release, stale cleanup, orphan rescue and the Kimi
# SessionEnd hook. Sourced by src/init.sh at the global scope so they are
# available even when AGENT_GUARD_FUNCTIONS_ONLY=1.
#
# Safety: this script is sourced. It must not leak strict mode to the caller.

# Resolve the directory of this script.
_RH_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load journal helpers if available. Preserve caller shell flags because
# journal.sh enables strict mode internally.
if [[ -f "${_RH_CORE_DIR}/src/journal.sh" ]]; then
    _RH_OLD_SHELL_FLAGS="$(set +o)"
    # shellcheck source=/dev/null
    source "${_RH_CORE_DIR}/src/journal.sh" || true
    eval "${_RH_OLD_SHELL_FLAGS}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Helper: check whether the worktree is on the identity's own task branch.
# ---------------------------------------------------------------------------
_branch_is_current_agent_task() {
    local worktree_path="$1"
    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"
    local wt_name identity expected_prefix
    wt_name="$(basename "${worktree_path}")"
    identity="$(_detect_identity_from_worktree_name "${wt_name}" | awk '{print $1 $2}')"
    [[ -n "${identity}" ]] || return 1
    expected_prefix="ia-${identity}/"
    [[ "${current_branch}" == "${expected_prefix}"* ]]
}

# ---------------------------------------------------------------------------
# Helper: check whether the worktree is parked on its neutral post-release
# branch (_released/<identity>).
# ---------------------------------------------------------------------------
_branch_is_neutral_released() {
    local worktree_path="$1"
    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"
    local wt_name identity
    wt_name="$(basename "${worktree_path}")"
    identity="$(_detect_identity_from_worktree_name "${wt_name}" | awk '{print $1 $2}')"
    [[ -n "${identity}" ]] || return 1
    [[ "${current_branch}" == "_released/${identity}" ]]
}

# ---------------------------------------------------------------------------
# Helper: append a structured note to the slot task file.
# Usage: _note_slot_event <identity> <section-title> <body-lines...>
# ---------------------------------------------------------------------------
_note_slot_event() {
    local identity="$1"
    local section="$2"
    shift 2

    local repo_root="${MAIN_REPO:-${_AG_REPO_ROOT:-}}"
    [[ -n "${repo_root}" ]] || return 0

    local note_file="${repo_root}/.agent-guard/tasks/${identity}.md"
    [[ -d "$(dirname "${note_file}")" ]] || mkdir -p "$(dirname "${note_file}")"

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    {
        echo ""
        echo "## ${section} — ${timestamp}"
        printf '%s\n' "$@"
    } >> "${note_file}"
}

# ---------------------------------------------------------------------------
# Helper: check whether blocked-release notifications are enabled.
# ---------------------------------------------------------------------------
_blocked_event_notifications_enabled() {
    local kind="${1:-journal}"
    local enabled
    enabled="$(_guard_get_str "session.blocked_event_notifications.enabled" "true" 2>/dev/null || echo "true")"
    enabled="${enabled,,}"
    [[ "${enabled}" == "true" || "${enabled}" == "1" || "${enabled}" == "yes" ]] || return 1

    local kind_enabled
    kind_enabled="$(_guard_get_str "session.blocked_event_notifications.${kind}" "true" 2>/dev/null || echo "true")"
    kind_enabled="${kind_enabled,,}"
    [[ "${kind_enabled}" == "true" || "${kind_enabled}" == "1" || "${kind_enabled}" == "yes" ]]
}

# ---------------------------------------------------------------------------
# PR cache helpers
#
# Open PR lookups are the dominant network cost during release/stale cleanup.
# We keep a small per-identity cache in .agent-guard/pr-cache/ so repeated
# checks within the same minute hit disk instead of the GitHub API.
# ---------------------------------------------------------------------------
_pr_cache_dir() {
    local repo_root="${MAIN_REPO:-${_AG_REPO_ROOT:-}}"
    [[ -n "${repo_root}" ]] || return 0
    echo "${repo_root}/.agent-guard/pr-cache"
}

_pr_cache_file() {
    local identity="$1"
    local cache_dir
    cache_dir="$(_pr_cache_dir)"
    [[ -n "${cache_dir}" ]] || return 0
    echo "${cache_dir}/${identity}.json"
}

_pr_cache_ttl_seconds() {
    local ttl
    ttl="$(_guard_get_str "session.pr_cache_ttl_seconds" "60" 2>/dev/null || echo "60")"
    [[ -z "${ttl}" || "${ttl}" == "None" || ! "${ttl}" =~ ^[0-9]+$ ]] && ttl=60
    # Floor of 1s keeps tests fast and avoids zero-TTL loops in production.
    if [[ "${ttl}" -lt 1 ]]; then
        ttl=1
    fi
    echo "${ttl}"
}

_pr_api_timeout_seconds() {
    local timeout
    timeout="$(_guard_get_str "session.pr_api_timeout_seconds" "5" 2>/dev/null || echo "5")"
    [[ -z "${timeout}" || "${timeout}" == "None" || ! "${timeout}" =~ ^[0-9]+$ ]] && timeout=5
    if [[ "${timeout}" -lt 1 ]]; then
        timeout=1
    fi
    echo "${timeout}"
}

_pr_cache_is_fresh() {
    local identity="$1"
    local cache_file
    cache_file="$(_pr_cache_file "${identity}")"
    [[ -f "${cache_file}" ]] || return 1

    local ttl now mtime
    ttl="$(_pr_cache_ttl_seconds)"
    now="$(date +%s)"
    mtime="$(stat -c %Y "${cache_file}" 2>/dev/null || stat -f %m "${cache_file}" 2>/dev/null || echo "0")"
    [[ "${mtime}" -gt 0 ]] || return 1
    [[ $((now - mtime)) -le ${ttl} ]]
}

_pr_cache_read() {
    local identity="$1"
    local cache_file
    cache_file="$(_pr_cache_file "${identity}")"
    [[ -f "${cache_file}" ]] || return 1
    cat "${cache_file}" 2>/dev/null
}

_pr_cache_write() {
    local identity="$1"
    local content="$2"
    local cache_dir cache_file
    cache_dir="$(_pr_cache_dir)"
    [[ -n "${cache_dir}" ]] || return 1
    mkdir -p "${cache_dir}" || return 1
    cache_file="${cache_dir}/${identity}.json"
    printf '%s' "${content}" > "${cache_file}"
}

_pr_cache_invalidate() {
    local identity="$1"
    local cache_file
    cache_file="$(_pr_cache_file "${identity}")"
    [[ -f "${cache_file}" ]] && rm -f "${cache_file}"
}

# ---------------------------------------------------------------------------
# Helper: list open PRs for an identity, using a short-lived local cache and
# a bounded API timeout. Prints one PR line per line; empty means none.
#
# Exit codes:
#   0 = data obtained (cache hit or successful API call), even if the list is empty
#   1 = could not obtain data (gh missing, timeout, query failed)
# ---------------------------------------------------------------------------
_pr_list_open_for_identity() {
    local identity="$1"
    local worktree_path="${2:-$(pwd)}"

    [[ -n "${identity}" ]] || return 1

    # 1. Cache hit: return immediately without touching the network.
    if _pr_cache_is_fresh "${identity}"; then
        _pr_cache_read "${identity}"
        return 0
    fi

    # 2. gh not available: nothing to list, cache stays absent.
    if ! command -v gh >/dev/null 2>&1; then
        return 1
    fi

    local timeout_seconds
    timeout_seconds="$(_pr_api_timeout_seconds)"

    local pr_lines=""
    local query_rc=0
    # Use a bounded timeout so a slow GitHub API cannot stall the release.
    # 'timeout' is part of coreutils on Linux and available on macOS via gtimeout.
    local timeout_cmd=""
    if command -v timeout >/dev/null 2>&1; then
        timeout_cmd="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        timeout_cmd="gtimeout"
    fi

    if [[ -n "${timeout_cmd}" ]]; then
        pr_lines="$(cd "${worktree_path}" 2>/dev/null && ${timeout_cmd} "${timeout_seconds}" gh pr list --state open --limit 100 \
            --json number,title,headRefName \
            --jq ".[] | select(.headRefName | startswith(\"ia-${identity}/\")) | \"#\\(.number) \\(.headRefName) — \\(.title)\"" 2>/dev/null)" || query_rc=$?
    else
        pr_lines="$(cd "${worktree_path}" 2>/dev/null && gh pr list --state open --limit 100 \
            --json number,title,headRefName \
            --jq ".[] | select(.headRefName | startswith(\"ia-${identity}/\")) | \"#\\(.number) \\(.headRefName) — \\(.title)\"" 2>/dev/null)" || query_rc=$?
    fi

    # 3. Persist to cache only on a real successful fetch, so a slow/failed API
    #    is not retried on every blocker check within the TTL window.
    if [[ "${query_rc}" -eq 0 ]]; then
        _pr_cache_write "${identity}" "${pr_lines}"
        printf '%s' "${pr_lines}"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Helper: return a list of release blockers for a worktree.
# Prints one blocker per line (empty output means releasable).
# Reuses the same logic as _validate_worktree_release_ready and the PR guard.
# ---------------------------------------------------------------------------
_worktree_release_blockers() {
    local worktree_path="$1"
    local identity="${2:-}"

    if [[ -z "${worktree_path}" ]]; then
        echo "worktree_path_unknown"
        return 0
    fi

    if [[ ! -e "${worktree_path}/.git" ]]; then
        echo "not_a_git_worktree"
        return 0
    fi

    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"
    if [[ "${current_branch}" != "develop" ]] && ! _branch_is_current_agent_task "${worktree_path}" && ! _branch_is_neutral_released "${worktree_path}"; then
        echo "branch_not_releasable:${current_branch:-<detached>}"
    fi

    local dirty_files
    dirty_files="$(git -C "${worktree_path}" status --porcelain 2>/dev/null || true)"
    if [[ -n "${dirty_files}" ]]; then
        echo "dirty_worktree"
    fi

    local stash_count
    local wt_name
    wt_name="$(basename "${worktree_path}")"
    identity="${identity:-$(_detect_identity_from_worktree_name "${wt_name}" | awk '{print $1 $2}')}"
    if [[ -n "${identity}" ]]; then
        stash_count="$(git -C "${worktree_path}" stash list 2>/dev/null | grep -cE "^stash@\\{[0-9]+\\}: On (ia-${identity}/|${current_branch}:)" || true)"
    else
        stash_count="$(git -C "${worktree_path}" stash list 2>/dev/null | grep -c "On ${current_branch}:" || true)"
    fi
    if [[ "${stash_count}" -gt 0 ]]; then
        echo "own_stashes"
    fi

    # PR guard: list open PRs from this identity (cached + bounded timeout).
    if [[ -n "${identity}" ]]; then
        local pr_lines pr_count
        pr_lines="$(_pr_list_open_for_identity "${identity}" "${worktree_path}")"
        pr_count=0
        if [[ -n "${pr_lines}" ]]; then
            pr_count="$(printf '%s\n' "${pr_lines}" | grep -c . || true)"
        fi
        if [[ "${pr_count}" -gt 0 ]]; then
            echo "open_prs:${pr_count}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Helper: validate worktree is in a neutral state before release
# ---------------------------------------------------------------------------
_validate_worktree_release_ready() {
    local worktree_path="$1"

    if [[ -z "${worktree_path}" ]]; then
        echo "❌ Cannot determine worktree path." >&2
        return 1
    fi

    if [[ ! -e "${worktree_path}/.git" ]]; then
        echo "❌ Worktree '${worktree_path}' does not appear to be a git worktree." >&2
        return 1
    fi

    local current_branch
    current_branch="$(git -C "${worktree_path}" branch --show-current 2>/dev/null || echo "")"
    if [[ "${current_branch}" != "develop" ]] && ! _branch_is_current_agent_task "${worktree_path}" && ! _branch_is_neutral_released "${worktree_path}"; then
        echo "" >&2
        echo "❌❌❌ ERROR: WORKTREE NOT RELEASABLE ❌❌❌" >&2
        echo "" >&2
        echo "   Current branch: ${current_branch:-<detached>}" >&2
        echo "   Release is only allowed when the worktree is on 'develop'," >&2
        echo "   on its own agent task branch (ia-<identity>/...), or on its" >&2
        echo "   neutral '_released/<identity>' branch (release is idempotent)." >&2
        echo "" >&2
        echo "   Required actions before release:" >&2
        echo "     1. Commit or stash any unfinished work on your task branch." >&2
        echo "     2. Push your branch and ensure PR is open/merged." >&2
        echo "     3. If the branch was already merged via squash, release directly" >&2
        echo "        from the task branch — do not force a checkout to develop." >&2
        echo "" >&2
        return 1
    fi

    local dirty_files
    dirty_files="$(git -C "${worktree_path}" status --porcelain 2>/dev/null || true)"
    if [[ -n "${dirty_files}" ]]; then
        echo "" >&2
        echo "❌❌❌ ERROR: WORKING TREE DIRTY ❌❌❌" >&2
        echo "" >&2
        echo "${dirty_files}" | sed 's/^/   /' >&2
        echo "" >&2
        echo "   Commit, stash, or remove these changes before releasing." >&2
        echo "" >&2
        return 1
    fi

    local stash_count
    # Stashes sao globais ao repo: so bloqueiam o release os que pertencem
    # a ESTA identidade (criados em branch ia-<identity>/... ou na branch
    # atual). Stash de outro agente vivo nao pode travar este slot
    # (incidente 2026-07-12: stash do kimi2 bloqueou release de todos).
    local wt_name identity
    wt_name="$(basename "${worktree_path}")"
    identity="$(_detect_identity_from_worktree_name "${wt_name}" | awk '{print $1 $2}')"
    if [[ -n "${identity}" ]]; then
        stash_count="$(git -C "${worktree_path}" stash list 2>/dev/null | grep -cE "^stash@\\{[0-9]+\\}: On (ia-${identity}/|${current_branch}:)" || true)"
    else
        stash_count="$(git -C "${worktree_path}" stash list 2>/dev/null | grep -c "On ${current_branch}:" || true)"
    fi
    if [[ "${stash_count}" -gt 0 ]]; then
        echo "" >&2
        echo "❌❌❌ ERROR: WORKTREE HAS STASHES ❌❌❌" >&2
        echo "" >&2
        if [[ -n "${identity}" ]]; then
            git -C "${worktree_path}" stash list 2>/dev/null | grep -E "^stash@\\{[0-9]+\\}: On (ia-${identity}/|${current_branch}:)" | sed 's/^/   /' >&2
        else
            git -C "${worktree_path}" stash list 2>/dev/null | grep "On ${current_branch}:" | sed 's/^/   /' >&2
        fi
        echo "" >&2
        echo "   Apply, drop, or move these stashes before releasing." >&2
        echo "   Stash is not a trash can — inspect with: git stash show -p stash@{<n>}" >&2
        echo "" >&2
        return 1
    fi

    # Aviso nao-bloqueante: stashes de OUTRAS identidades presentes no repo
    local foreign_count
    foreign_count="$(git -C "${worktree_path}" stash list 2>/dev/null | grep -c '^stash@{' || true)"
    if [[ "${foreign_count}" -gt 0 ]]; then
        echo "ℹ️  ${foreign_count} stash(es) de outra(s) identidade(s) no repo — nao bloqueiam este release." >&2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Helper: pending-work guard (protocolo 2026-07-17)
# ---------------------------------------------------------------------------
_release_pending_work_guard() {
    local identity="$1"
    local worktree_path="$2"
    local force="${3:-false}"

    if [[ -z "$(type -P gh 2>/dev/null || true)" ]]; then
        echo "⚠️  gh CLI indisponível — verificação de PRs abertos pulada (release segue)." >&2
        if _blocked_event_notifications_enabled "journal" && command -v _journal_write_event >/dev/null 2>&1; then
            _journal_write_event "pr_guard_skipped" "{\"reason\": \"gh_cli_missing\", \"identity\": \"${identity}\", \"worktree\": \"${worktree_path}\"}" "${MAIN_REPO:-${_AG_REPO_ROOT:-}}"
        fi
        return 0
    fi

    local pr_lines=""
    local pr_query_ok=0
    if ! pr_lines="$(_pr_list_open_for_identity "${identity}" "${worktree_path}" 2>/dev/null)"; then
        pr_query_ok=1
    fi

    if [[ "${pr_query_ok}" -ne 0 ]]; then
        echo "⚠️  Falha ao consultar PRs abertos via gh — verificação pulada (release segue)." >&2
        if _blocked_event_notifications_enabled "journal" && command -v _journal_write_event >/dev/null 2>&1; then
            _journal_write_event "pr_guard_skipped" "{\"reason\": \"gh_query_failed\", \"identity\": \"${identity}\", \"worktree\": \"${worktree_path}\"}" "${MAIN_REPO:-${_AG_REPO_ROOT:-}}"
        fi
        return 0
    fi

    local pr_count=0
    if [[ -n "${pr_lines}" ]]; then
        pr_count="$(printf '%s\n' "${pr_lines}" | grep -c . || true)"
    fi

    if [[ "${pr_count}" -eq 0 ]]; then
        return 0
    fi

    if [[ "${force}" == "true" ]]; then
        echo "⚠️  Liberando com ${pr_count} PR(s) aberto(s) de ia-${identity}/* (--force; exige autorização prévia do usuário):" >&2
        printf '%s\n' "${pr_lines}" | sed 's/^/   /' >&2
        return 0
    fi

    # Humano em TTY: pergunta explícita em vez de bloqueio seco.
    if [[ -t 0 ]]; then
        echo "" >&2
        echo "⚠️  ${pr_count} PR(s) aberto(s) de ia-${identity}/*:" >&2
        printf '%s\n' "${pr_lines}" | sed 's/^/   /' >&2
        local answer=""
        read -r -p "   Liberar o slot mesmo assim? [y/N] " answer || answer=""
        if [[ "${answer}" =~ ^[yY]([eE][sS])?$ ]]; then
            return 0
        fi
        echo "🔒 Release cancelado pelo usuário." >&2
        return 1
    fi

    echo "" >&2
    echo "❌❌❌ RELEASE BLOQUEADO: ${pr_count} PR(s) aberto(s) de ia-${identity}/* ❌❌❌" >&2
    echo "" >&2
    printf '%s\n' "${pr_lines}" | sed 's/^/   /' >&2
    echo "" >&2
    echo "   Protocolo (2026-07-17): finalizar tarefa/spec/correção NÃO libera o" >&2
    echo "   slot — a maioria das sessões ainda tem PRs em andamento (CI, merge" >&2
    echo "   queue, correções). Antes de liberar:" >&2
    echo "     1. Apresente os PRs acima ao usuário." >&2
    echo "     2. Só prossiga com autorização explícita dele, usando:" >&2
    echo "        source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} --release --force" >&2
    echo "" >&2
    return 1
}

# ---------------------------------------------------------------------------
# Helper: move a worktree to its neutral post-release branch on top of the
# configured base ref. Returns 0 on success, 1 on failure. Never clears the
# session — this helper only manipulates git state.
# ---------------------------------------------------------------------------
_move_worktree_to_neutral_branch() {
    local worktree_path="$1"
    local identity="$2"

    if [[ -z "${worktree_path}" || ! -e "${worktree_path}/.git" ]]; then
        return 1
    fi

    local neutral_branch="_released/${identity}"
    local base_ref=""
    if git -C "${worktree_path}" rev-parse --verify --quiet "origin/develop" >/dev/null 2>&1; then
        base_ref="origin/develop"
    elif git -C "${worktree_path}" rev-parse --verify --quiet "develop" >/dev/null 2>&1; then
        base_ref="develop"
    fi

    if [[ -z "${base_ref}" ]]; then
        return 1
    fi

    # Guard: if the neutral branch is already checked out in another worktree,
    # refuse to move. `checkout -B` would silently steal the branch from the
    # other worktree, leaving two worktrees claiming the same branch.
    local existing_worktree
    existing_worktree="$(git -C "${worktree_path}" for-each-ref --format='%(worktreepath)' "refs/heads/${neutral_branch}" 2>/dev/null || true)"
    if [[ -n "${existing_worktree}" && "${existing_worktree%/}" != "${worktree_path%/}" ]]; then
        return 1
    fi

    # Create/reset the neutral branch on top of the base ref. Fail hard on
    # error so the caller can keep the session active.
    if git -C "${worktree_path}" checkout -B "${neutral_branch}" "${base_ref}" >/dev/null 2>&1; then
        return 0
    fi

    # Fallback: detached HEAD on the base ref. This still protects 'develop'
    # from being held by an idle worktree.
    if git -C "${worktree_path}" checkout --detach "${base_ref}" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Helper: attempt to release a stale/session-end session only when safe.
# When release is blocked, records audit events to the session journal and to
# the slot task note so admins are not left in the dark.
# ---------------------------------------------------------------------------
_auto_release_if_safe() {
    local identity="$1"
    local worktree_path="$2"
    local reason="${3:-stale}"
    local event_action="${4:-auto_release_blocked}"

    local blockers
    blockers="$(_worktree_release_blockers "${worktree_path}" "${identity}")"

    if [[ -n "${blockers}" ]]; then
        # Build a compact JSON payload of blockers.
        local payload
        payload="$(${AG_PYTHON} -c "
import json, sys
lines = [l for l in sys.argv[1].splitlines() if l]
print(json.dumps({'reason': '${reason}', 'blockers': lines, 'worktree': '${worktree_path}'}))
" "${blockers}" 2>/dev/null || echo \"{\"reason\": \"${reason}\", \"blockers\": []}\")"

        if _blocked_event_notifications_enabled "journal" && command -v _journal_write_event >/dev/null 2>&1; then
            _journal_write_event "${event_action}" "${payload}" "${MAIN_REPO:-${_AG_REPO_ROOT:-}}"
        fi

        if _blocked_event_notifications_enabled "slot_note"; then
            _note_slot_event "${identity}" "Bloqueio de liberação automática" \
                "Evento: ${event_action}" \
                "Motivo: ${reason}" \
                "Bloqueios detectados:" \
                "$(printf '  - %s\n' ${blockers})" \
                "Ação sugerida: resolver os bloqueios acima e rodar \`source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} --release\`"
        fi

        return 1
    fi

    # ATOMIC RELEASE: move the worktree to the neutral branch BEFORE clearing
    # the session. If the checkout fails, the session stays active and the
    # failure is audited (prevents slots marked free while the worktree still
    # holds a task branch).
    if ! _move_worktree_to_neutral_branch "${worktree_path}" "${identity}"; then
        local atomic_blocker="neutral_branch_failed: worktree could not be moved to _released/${identity}"
        local payload
        payload="$(${AG_PYTHON} -c "
import json
print(json.dumps({'reason': '${reason}', 'blockers': ['${atomic_blocker}'], 'worktree': '${worktree_path}'}))
" 2>/dev/null || echo \"{\"reason\": \"${reason}\", \"blockers\": [\"neutral_branch_failed\"]}\")"

        if _blocked_event_notifications_enabled "journal" && command -v _journal_write_event >/dev/null 2>&1; then
            _journal_write_event "${event_action}" "${payload}" "${MAIN_REPO:-${_AG_REPO_ROOT:-}}"
        fi

        if _blocked_event_notifications_enabled "slot_note"; then
            _note_slot_event "${identity}" "Bloqueio de liberação automática" \
                "Evento: ${event_action}" \
                "Motivo: ${reason}" \
                "Bloqueios detectados:" \
                "  - ${atomic_blocker}" \
                "Ação sugerida: verificar o estado do worktree e rodar \`source ${AGENT_GUARD_INIT_NAME:-.agent-guard-init} --release\`"
        fi

        return 1
    fi

    _clear_session "${identity}"

    if command -v _journal_release >/dev/null 2>&1; then
        _journal_release
    fi

    echo "🔓 Auto-released ${identity} (${reason})"
    return 0
}

# ---------------------------------------------------------------------------
# Helper: detect slots sharing the same live PID (usually one IDE process that
# acquired multiple leases and never released the secondary ones). Keep the
# most recently active identity and auto-release the others if safe.
# ---------------------------------------------------------------------------
_cleanup_shared_pid_sessions() {
    local dry_run="${1:-}"
    local identity_list prefix i identity pid last_activity
    declare -A pid_to_idents

    identity_list="$(bash "${AGENT_GUARD_CONFIG_BIN}" keys identities 2>/dev/null || true)"
    for prefix in ${identity_list}; do
        [[ -z "${prefix}" ]] && continue
        local base_slots max_slots
        base_slots="$(_guard_get "identities.${prefix}.slots" 2>/dev/null || echo "0")"
        max_slots="$(_guard_get "identities.${prefix}.max_slots" "${base_slots}" 2>/dev/null || echo "${base_slots}")"
        for i in $(seq 1 "${max_slots}"); do
            identity="${prefix}${i}"
            local sess_status sess_pid sess_last
            sess_status="$(_load_session_field "${identity}" "status")"
            sess_pid="$(_load_session_field "${identity}" "pid")"
            sess_last="$(_load_session_field "${identity}" "last_activity")"

            [[ "${sess_status}" == "active" ]] || continue
            [[ -n "${sess_pid}" ]] || continue
            _is_pid_alive "${sess_pid}" || continue

            pid_to_idents["${sess_pid}"]="${pid_to_idents[${sess_pid}]:-}${pid_to_idents[${sess_pid}]:+,}${identity}:${sess_last}"
        done
    done

    local released=0 skipped=0 inspected=0
    for pid in "${!pid_to_idents[@]}"; do
        local entries="${pid_to_idents[${pid}]}"
        local count
        count="$(echo "${entries}" | tr ',' '\n' | wc -l)"
        [[ "${count}" -gt 1 ]] || continue

        inspected=$((inspected + 1))
        # Sort by last_activity descending (most recent first); format is identity:timestamp.
        local sorted keeper
        sorted="$(echo "${entries}" | tr ',' '\n' | LC_ALL=C sort -t':' -k2 -nr)"
        keeper="$(echo "${sorted}" | head -n1 | cut -d':' -f1)"

        echo "🧩 Shared PID ${pid} held by ${count} slots; keeping ${keeper} (most recent activity)." >&2

        local entry
        while IFS= read -r entry; do
            identity="$(echo "${entry}" | cut -d':' -f1)"
            [[ -z "${identity}" ]] && continue
            local worktree_path
            worktree_path="$(_get_worktree_path "${identity}")"

            if [[ "${dry_run}" == "--dry-run" ]]; then
                echo "   [dry-run] would auto-release ${identity}" >&2
                continue
            fi

            if _auto_release_if_safe "${identity}" "${worktree_path}" "shared_pid" "shared_pid_cleanup_blocked"; then
                released=$((released + 1))
            else
                echo "   🔒 ${identity} shares PID ${pid} but cannot be auto-released." >&2
                skipped=$((skipped + 1))
            fi
        done < <(echo "${sorted}" | tail -n +2)
    done

    if [[ "${dry_run}" != "--dry-run" ]]; then
        echo "🧹 Shared-PID cleanup complete: ${inspected} groups inspected, ${released} released, ${skipped} skipped." >&2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Helper: scan all slots and auto-release stale ones that are safe to release.
# ---------------------------------------------------------------------------
_cleanup_stale_sessions() {
    local identity_list prefix i identity worktree_path
    local released=0 skipped=0

    # First, release secondary slots that share a live PID with another slot.
    # This must happen before stale cleanup so a freshly-released slot is not
    # immediately re-scanned as stale.
    _cleanup_shared_pid_sessions

    identity_list="$(bash "${AGENT_GUARD_CONFIG_BIN}" keys identities 2>/dev/null || true)"
    for prefix in ${identity_list}; do
        [[ -z "${prefix}" ]] && continue
        local base_slots max_slots
        base_slots="$(_guard_get "identities.${prefix}.slots" 2>/dev/null || echo "0")"
        max_slots="$(_guard_get "identities.${prefix}.max_slots" "${base_slots}" 2>/dev/null || echo "${base_slots}")"
        for i in $(seq 1 "${max_slots}"); do
            identity="${prefix}${i}"
            worktree_path="$(_get_worktree_path "${identity}")"

            local sess_status sess_pid
            sess_status="$(_load_session_field "${identity}" "status")"
            sess_pid="$(_load_session_field "${identity}" "pid")"

            [[ "${sess_status}" == "active" ]] || continue

            local pid_alive="true"
            if [[ -z "${sess_pid}" ]] || ! _is_pid_alive "${sess_pid}"; then
                pid_alive="false"
            fi

            # Dead PID: the session is stale by definition and must not remain
            # "active" forever in the lease file. Live PID: only stale (24h+)
            # or shell-pinned leases are eligible for auto-release.
            if [[ "${pid_alive}" == "false" ]]; then
                echo "🧹 ${identity}: session PID ${sess_pid} is dead; checking for safe auto-release..." >&2
            elif ! _is_session_stale "${identity}" && ! _lease_is_shell_pinned "${identity}"; then
                continue
            fi

            if _auto_release_if_safe "${identity}" "${worktree_path}" "stale" "stale_cleanup_blocked"; then
                released=$((released + 1))
            else
                echo "🔒 ${identity} is stale but cannot be auto-released (dirty worktree or open PRs)." >&2
                skipped=$((skipped + 1))
            fi
        done
    done

    echo ""
    echo "🧹 Cleanup complete: ${released} released, ${skipped} skipped."
    return 0 2>/dev/null || exit 0
}
