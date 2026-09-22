#!/usr/bin/env bash
#
# agent-guard-core — RELEASE-SAFETY CANDIDATE (F6B2, 2026-09-04; F6B2-fix
# identity consistency apos revisao adversarial da kimi4)
#
# SHADOW / COMPUTE-ONLY. NAO integrado ao runtime: init.sh NAO source este
# modulo; o release de producao continua 100% LEGACY (release-helpers.sh).
# Ver ADR-0058 e audit f6-release-boundary.md.
#
# Proposito: implementacao candidata dos gates KERNEL_SAFETY do release
# (identity/worktree consistency, branch/worktree ownership, dirty/staged/
# MM/untracked, runtime artifacts excluidos, stash safety, main-repo
# protection, deteccao read-only do COMPATIBILITY_SAFETY_SHIM de task-notes)
# para paridade diferencial contra o legado (F6B2). A candidata NAO executa
# o shim — apenas prevê o caso "task-note-only drift" como
# ALLOW_AFTER_COMPATIBILITY_SHIM.
#
# HARD REQUIREMENTS (F6B2 §2/§9):
#   - READ-ONLY: somente git rev-parse / branch / status --porcelain /
#     stash list. Proibido: checkout/switch/add/commit/stash push|pop|drop,
#     rm/mv em runtime state, clear_session, heartbeat, reconcile, journal,
#     task-note auto-commit, persistencia, network.
#   - SEM dependencia de policy: nada de gh/GitHub/AGENT_GUARD_PR_PROVIDER/
#     task-lifecycle/Slack/network/config. Task notes sao excecao SOMENTE
#     como deteccao read-only (espelha o filtro do shim legado).
#   - SEM identity resolution interna (F6B2-fix): o evaluator NAO parseia
#     basename, NAO carrega agent-guard.yaml, NAO chama
#     _detect_identity_from_worktree_name. A identidade do worktree vem
#     RESOLVIDA do caller/adapter:
#
#         caller / integration adapter
#             ↓ resolve worktree identity (ex.: _detect_identity_from_worktree_name)
#         release-safety evaluator
#             ↓ valida consistencia claimed x resolved
#         decision/result
#
# CONTRATO (resultado interno deterministico, maquina):
#
#   _release_safety_evaluate <worktree_path> <claimed_identity> \
#       <resolved_worktree_identity> [main_repo]
#
#   stdout:
#     DECISION=ALLOW|BLOCK|ALLOW_AFTER_COMPATIBILITY_SHIM|UNKNOWN
#     REASON=<codigo unico primario|NONE>
#
#   Razoes: WORKTREE_PATH_UNKNOWN, NOT_A_GIT_WORKTREE, MAIN_REPO,
#   IDENTITY_UNKNOWN, WORKTREE_IDENTITY_UNKNOWN, IDENTITY_WORKTREE_MISMATCH,
#   FOREIGN_BRANCH, DIRTY_WORKTREE, OWN_STASH, GIT_UNAVAILABLE, NONE.
#
# ORDEM DOS GATES (espelha a composicao legada caller+helper):
#   1. WORKTREE_PATH_UNKNOWN       (path vazio)
#   2. NOT_A_GIT_WORKTREE          (sem .git)
#   3. MAIN_REPO                   (wt == main_repo; gate do caller legado)
#   4. IDENTITY_UNKNOWN            (claimed vazia — fail-closed; o caller
#                                   legado bloqueia "Cannot determine
#                                   identity" antes de qualquer ALLOW)
#   5. WORKTREE_IDENTITY_UNKNOWN   (resolved vazia — fail-closed)
#   6. IDENTITY_WORKTREE_MISMATCH  (claimed != resolved — fail-closed; no
#                                   legado o mesmo estado se manifesta via
#                                   self-derivacao em _branch_is_current_agent_task)
#   7. FOREIGN_BRANCH              (branch != develop / ia-<claimed>/* / _released/<claimed>)
#   8. DIRTY_WORKTREE              (porcelain menos .agent-guard/ nao vazio)
#   9. OWN_STASH                   (stash "On ia-<claimed>/" ou "On <branch>:")
#  10. SHIM-PREDICT                (notes-only -> ALLOW_AFTER_COMPATIBILITY_SHIM;
#                                   notes+runtime-only -> ALLOW, LEGACY_SEMANTIC)
#  11. ALLOW/NONE
#
# ORDEM stash-antes-shim (correcao F6B3A, achado em shadow caller integration):
# sem isso, o caso "stash primeiro, note depois" produzia
# ALLOW_AFTER_COMPATIBILITY_SHIM no avaliador enquanto o legado bloqueia
# OWN_STASH (o shim legado commita a note e so depois o caller checa stash)
# - CANDIDATE_WEAKER real. Com o stash check antes, decisao e razao batem
# com o legado em qualquer ordem de criacao.
#
# HARD GATE (revisao adversarial F6B2-fix): CANDIDATE_WEAKER_THAN_LEGACY = 0.
# "Legacy BLOCK + candidate ALLOW" NUNCA e aceitavel. Diferenca de REASON
# com a MESMA decisao pode ser EXPECTED_NORMALIZATION documentada; decisao
# divergente nao. Candidata mais estrita que o helper isolado e aceitavel
# quando o gate extra vive no caller legado (documentado por cenario).

# ---------------------------------------------------------------------------
# Emit resultado normalizado.
# ---------------------------------------------------------------------------
_rsafety_result() {
    printf 'DECISION=%s\n' "$1"
    printf 'REASON=%s\n' "$2"
}

# ---------------------------------------------------------------------------
# Gate helpers (read-only, git apenas).
# ---------------------------------------------------------------------------
_rsafety_current_branch() {
    git -C "$1" branch --show-current 2>/dev/null || printf ''
}

_rsafety_is_task_branch() {
    local branch="$1" identity="$2"
    [[ -n "${identity}" && "${branch}" == "ia-${identity}/"* ]]
}

_rsafety_is_neutral_branch() {
    local branch="$1" identity="$2"
    [[ -n "${identity}" && "${branch}" == "_released/${identity}" ]]
}

# Espelha o dirty check legado: porcelain sem qualquer linha .agent-guard/.
_rsafety_dirty_files() {
    git -C "$1" status --porcelain 2>/dev/null | grep -v '\.agent-guard/' || true
}

# Espelha a coleta de task notes do shim legado (mesmo regex, mesmo pathspec).
_rsafety_dirty_task_notes() {
    git -C "$1" status --porcelain -- .agent-guard/tasks/*.md 2>/dev/null \
        | grep -E '^( M|M |MM|A |AM|\?\?) \.agent-guard/tasks/[^/]+\.md$' \
        || true
}

# ---------------------------------------------------------------------------
# Avaliacao principal (READ-ONLY).
# ---------------------------------------------------------------------------
_release_safety_evaluate() {
    local worktree_path="$1"
    local claimed_identity="${2:-}"
    local resolved_worktree_identity="${3:-}"
    local main_repo="${4:-}"

    if ! command -v git >/dev/null 2>&1; then
        _rsafety_result UNKNOWN GIT_UNAVAILABLE
        return 0
    fi

    # 1. path vazio
    if [[ -z "${worktree_path}" ]]; then
        _rsafety_result BLOCK WORKTREE_PATH_UNKNOWN
        return 0
    fi

    # 2. nao e worktree git
    if [[ ! -e "${worktree_path}/.git" ]]; then
        _rsafety_result BLOCK NOT_A_GIT_WORKTREE
        return 0
    fi

    # 3. main-repo protection (gate do caller legado, init.sh release block)
    if [[ -n "${main_repo}" ]]; then
        local wt_norm mr_norm
        wt_norm="${worktree_path%/}"
        mr_norm="${main_repo%/}"
        if [[ "${wt_norm}" == "${mr_norm}" ]]; then
            _rsafety_result BLOCK MAIN_REPO
            return 0
        fi
    fi

    # 4-6. consistencia de identidade (FAIL-CLOSED, F6B2-fix)
    if [[ -z "${claimed_identity}" ]]; then
        _rsafety_result BLOCK IDENTITY_UNKNOWN
        return 0
    fi
    if [[ -z "${resolved_worktree_identity}" ]]; then
        _rsafety_result BLOCK WORKTREE_IDENTITY_UNKNOWN
        return 0
    fi
    if [[ "${claimed_identity}" != "${resolved_worktree_identity}" ]]; then
        _rsafety_result BLOCK IDENTITY_WORKTREE_MISMATCH
        return 0
    fi
    local identity="${claimed_identity}"

    local current_branch
    current_branch="$(_rsafety_current_branch "${worktree_path}")"

    # 7. branch ownership
    if [[ "${current_branch}" != "develop" ]] \
        && ! _rsafety_is_task_branch "${current_branch}" "${identity}" \
        && ! _rsafety_is_neutral_branch "${current_branch}" "${identity}"; then
        _rsafety_result BLOCK FOREIGN_BRANCH
        return 0
    fi

    # 8. dirty check (exclui runtime artifacts .agent-guard/)
    local dirty_files
    dirty_files="$(_rsafety_dirty_files "${worktree_path}")"
    if [[ -n "${dirty_files}" ]]; then
        _rsafety_result BLOCK DIRTY_WORKTREE
        return 0
    fi

    # 9. stash safety (apenas stashes da identidade/branch bloqueiam).
    #    ANTES do shim-predict: ver cabecalho "ORDEM stash-antes-shim".
    local stash_count
    stash_count="$(git -C "${worktree_path}" stash list 2>/dev/null | grep -cE "^stash@\\{[0-9]+\\}: On (ia-${identity}/|${current_branch}:)" || true)"
    if [[ "${stash_count}" -gt 0 ]]; then
        _rsafety_result BLOCK OWN_STASH
        return 0
    fi

    # 10. shim-predict (COMPATIBILITY_SAFETY_SHIM — deteccao read-only).
    #    Espelha _auto_commit_task_notes_if_only_drift: so e caso de shim
    #    quando as task notes sao O UNICO drift do repo (conta total).
    local task_notes all_dirty_count task_note_count
    task_notes="$(_rsafety_dirty_task_notes "${worktree_path}")"
    if [[ -n "${task_notes}" ]]; then
        all_dirty_count="$(git -C "${worktree_path}" status --porcelain 2>/dev/null | grep -c . || true)"
        task_note_count="$(printf '%s\n' "${task_notes}" | grep -c . || true)"
        if [[ "${all_dirty_count}" -eq "${task_note_count}" ]]; then
            _rsafety_result ALLOW_AFTER_COMPATIBILITY_SHIM NOTES_ONLY_DRIFT
            return 0
        fi
        # LEGACY_SEMANTIC: shim legado pula silenciosamente quando ha outro
        # drift .agent-guard/ (ex.: runtime artifacts). Release segue ALLOW
        # e as notes ficam para tras — paridade, nao correcao (F6B2 §7).
    fi

    # 11. limpo
    _rsafety_result ALLOW NONE
    return 0
}
