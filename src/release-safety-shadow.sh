#!/usr/bin/env bash
#
# agent-guard-core — RELEASE-SAFETY SHADOW ADAPTER (F6B3A, 2026-09-05)
#
# Integra a candidata RELEASE-SAFETY (src/release-safety.sh, COMPUTE-ONLY)
# aos callers REAIS de release em SHADOW MODE:
#
#   1. manual release  — init.sh seção "--release"
#   2. auto release    — release-helpers.sh::_auto_release_if_safe
#
# FEATURE FLAG temporária e explícita (F6B3A §1):
#
#   AGENT_GUARD_RELEASE_SAFETY_SHADOW=1   → shadow ON (observa/compara/diagnostica)
#   unset ou != 1                          → shadow OFF (byte-semântico ao baseline;
#                                          candidate NÃO é avaliada, zero diagnóstico,
#                                          zero escrita, zero custo)
#
# Default: OFF. Sem configuração persistida no yaml nesta fase.
#
# AUTORIDADE: LEGACY CONTINUA 100% AUTHORITATIVE. Esta adapter:
#   - observa, calcula, compara, diagnostica;
#   - NUNCA bloqueia/libera release, executa checkout/shim, altera branch,
#     policy, storage, journal ou task note, ou muda a decisão do legado;
#   - ZERO persistência (sem journal/session/task-note — diagnóstico vai a
#     stderr no formato AG_RELEASE_SHADOW, capturável por harness).
#
# Arquitetura (F6B3A §2):
#
#   CALLER (init.sh --release | _auto_release_if_safe)
#     ↓ _ag_rshadow_begin  (captura PRE-SHIM, PRE-transição)
#   SHADOW ADAPTER (este módulo)
#     ├─ resolve worktree identity (_detect_identity_from_worktree_name)
#     ├─ candidate compute-only (_release_safety_evaluate)
#     └─ snapshot candidate decision/reason
#     ↓ _ag_rshadow_report (nos pontos de decisão legados)
#   LEGACY AUTHORITATIVE (decisão, checkout, shim, clear — inalterados)
#     ↓ comparação safety-only emitida em stderr
#
# Anti-regressão (F6B3A §9): esta adapter NÃO pode depender de gh/GitHub/
# AGENT_GUARD_PR_PROVIDER/Slack/task-lifecycle/network. Task notes entram
# somente como detecção read-only do COMPATIBILITY_SAFETY_SHIM.

# ---------------------------------------------------------------------------
# Flag gate — tudo é no-op quando OFF.
# ---------------------------------------------------------------------------
_ag_rshadow_enabled() {
    [[ "${AGENT_GUARD_RELEASE_SAFETY_SHADOW:-0}" == "1" ]]
}

# ---------------------------------------------------------------------------
# Lazy-load do evaluator (a candidata NÃO é sourceada por init.sh; só entra
# em memória quando o shadow está ON e o primeiro begin roda).
# ---------------------------------------------------------------------------
_ag_rshadow_load_evaluator() {
    if command -v _release_safety_evaluate >/dev/null 2>&1; then
        return 0
    fi
    local _mod_dir
    _mod_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${_mod_dir}/release-safety.sh" ]]; then
        # shellcheck source=release-safety.sh
        source "${_mod_dir}/release-safety.sh"
    fi
    command -v _release_safety_evaluate >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _ag_rshadow_begin <surface> <worktree_path> <claimed_identity> <main_repo>
#
# Captura o snapshot PRE-SHIM/PRE-transição da candidata. Deve ser chamado
# pelo caller REAL o mais cedo possível (após resolver worktree/identity,
# antes de qualquer gate legado que possa retornar). No manual: antes do gate
# MAIN_REPO (F6B3A §4). No auto: antes de _worktree_release_blockers.
# ---------------------------------------------------------------------------
_ag_rshadow_begin() {
    _ag_rshadow_enabled || return 0
    _AG_RSHADOW_SURFACE="${1:-unknown}"
    _AG_RSHADOW_WT="${2:-}"
    _AG_RSHADOW_CLAIMED="${3:-}"
    _AG_RSHADOW_MAIN="${4:-}"
    _AG_RSHADOW_DEC=""
    _AG_RSHADOW_RSN=""
    _AG_RSHADOW_RESOLVED=""

    _ag_rshadow_load_evaluator || {
        _AG_RSHADOW_DEC="UNKNOWN"
        _AG_RSHADOW_RSN="EVALUATOR_UNAVAILABLE"
        return 0
    }

    # Identity layer (F6B3A §3): o adapter resolve a identidade REAL do
    # worktree com o resolver EXISTENTE do Kernel; o evaluator puro valida a
    # consistência claimed x resolved. Nunca substituir claimed por resolved.
    if [[ -n "${_AG_RSHADOW_WT}" ]] \
        && command -v _detect_identity_from_worktree_name >/dev/null 2>&1; then
        _AG_RSHADOW_RESOLVED="$(_detect_identity_from_worktree_name "$(basename "${_AG_RSHADOW_WT}")" 2>/dev/null | awk '{print $1 $2}')"
    fi

    local out
    out="$(_release_safety_evaluate "${_AG_RSHADOW_WT}" "${_AG_RSHADOW_CLAIMED}" "${_AG_RSHADOW_RESOLVED}" ${_AG_RSHADOW_MAIN:+"${_AG_RSHADOW_MAIN}"} 2>/dev/null)"
    _AG_RSHADOW_DEC="$(printf '%s\n' "${out}" | sed -n 's/^DECISION=//p' | head -1)"
    _AG_RSHADOW_RSN="$(printf '%s\n' "${out}" | sed -n 's/^REASON=//p' | head -1)"
    [[ -n "${_AG_RSHADOW_DEC}" ]] || { _AG_RSHADOW_DEC="UNKNOWN"; _AG_RSHADOW_RSN="EMPTY_EVALUATOR_OUTPUT"; }
    return 0
}

# ---------------------------------------------------------------------------
# Detecção read-only de "drift notes-only ainda presente" — usada para
# distinguir SHIM_FAILURE (o shim legado não conseguiu commitar) de
# CANDIDATE_WEAKER. Espelha o filtro do shim legado (mesmo regex/pathspec).
# ---------------------------------------------------------------------------
_ag_rshadow_notes_only_drift_remains() {
    local wt="${_AG_RSHADOW_WT:-}"
    [[ -n "${wt}" && -e "${wt}/.git" ]] || return 1
    local task_notes all_count note_count
    task_notes="$(git -C "${wt}" status --porcelain -- .agent-guard/tasks/*.md 2>/dev/null \
        | grep -E '^( M|M |MM|A |AM|\?\?) \.agent-guard/tasks/[^/]+\.md$' \
        || true)"
    [[ -n "${task_notes}" ]] || return 1
    all_count="$(git -C "${wt}" status --porcelain 2>/dev/null | grep -c . || true)"
    note_count="$(printf '%s\n' "${task_notes}" | grep -c . || true)"
    [[ "${all_count}" -eq "${note_count}" ]]
}

# ---------------------------------------------------------------------------
# _ag_rshadow_report <legacy_decision> <legacy_reason> <legacy_domain> [note]
#
# Ponto de comparação, chamado EXATAMENTE nos pontos de decisão legados
# (nunca em transições I8 como neutral checkout). legacy_domain:
#   caller  — gates do próprio caller (MAIN_REPO, IDENTITY_UNKNOWN)
#   safety  — decisão de safety legada (validate/blockers/shim)
#   policy  — block de POLICY (PRs/task); legacy_decision aqui é a decisão
#             SAFETY subjacente (ALLOW quando só a policy bloqueou)
# Nunca altera o fluxo do caller; sempre retorna 0; zero stdout.
#
# Classificação (hard gates F6B3A §11):
#   legacy BLOCK + candidate ALLOW|ALLOW_AFTER_COMPATIBILITY_SHIM
#       => CANDIDATE_WEAKER  (FAIL) — EXCETO falha concreta do shim
#          (drift notes-only ainda presente) => SHIM_FAILURE
#   legacy BLOCK + candidate BLOCK => PARITY
#   legacy ALLOW + candidate ALLOW|ALLOW_AFTER_COMPATIBILITY_SHIM => PARITY
#   legacy ALLOW + candidate BLOCK => CANDIDATE_STRICTER (registrar, não esconder)
#   candidate UNKNOWN => UNKNOWN (FAIL para readiness)
# ---------------------------------------------------------------------------
_ag_rshadow_report() {
    _ag_rshadow_enabled || return 0
    local legacy_dec="${1:-UNKNOWN}"
    local legacy_rsn="${2:-UNKNOWN}"
    local legacy_dom="${3:-safety}"
    local note="${4:-}"

    local cand_dec="${_AG_RSHADOW_DEC:-UNKNOWN}"
    local cand_rsn="${_AG_RSHADOW_RSN:-UNKNOWN}"
    local surface="${_AG_RSHADOW_SURFACE:-unknown}"

    local classification
    case "${cand_dec}" in
        UNKNOWN)
            classification="UNKNOWN"
            ;;
        BLOCK)
            if [[ "${legacy_dec}" == "BLOCK" ]]; then
                classification="PARITY"
            else
                classification="CANDIDATE_STRICTER"
                if [[ "${cand_rsn}" == "MAIN_REPO" && "${surface}" == "auto" ]]; then
                    # F6B3A §8: assimetria legada documentada — o auto legado
                    # não tem gate explícito MAIN_REPO; a candidata tem. Não
                    # mascarar, não alterar nenhum dos dois.
                    note="${note:+$note,}auto_main_repo_legacy_asymmetry"
                fi
            fi
            ;;
        ALLOW|ALLOW_AFTER_COMPATIBILITY_SHIM)
            if [[ "${legacy_dec}" == "ALLOW" ]]; then
                classification="PARITY"
            else
                if [[ "${cand_dec}" == "ALLOW_AFTER_COMPATIBILITY_SHIM" ]] \
                    && _ag_rshadow_notes_only_drift_remains; then
                    # F6B3A §6: o shim legado deveria ter commitado e não
                    # commitou — falha concreta do COMPATIBILITY_SAFETY_SHIM,
                    # não falha do evaluator.
                    classification="SHIM_FAILURE"
                else
                    classification="CANDIDATE_WEAKER"
                fi
            fi
            ;;
        *)
            classification="UNKNOWN"
            ;;
    esac

    {
        printf 'AG_RELEASE_SHADOW surface=%s legacy=%s legacy_reason=%s legacy_domain=%s candidate=%s candidate_reason=%s classification=%s' \
            "${surface}" "${legacy_dec}" "${legacy_rsn}" "${legacy_dom}" "${cand_dec}" "${cand_rsn}" "${classification}"
        [[ -n "${note}" ]] && printf ' note=%s' "${note}"
        printf '\n'
    } >&2
    return 0
}
