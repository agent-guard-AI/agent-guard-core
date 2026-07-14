#!/usr/bin/env bash
#
# lease-owner-check.sh — validação de POSSE de worktree alugado (L186).
#
# Contexto: os guard hooks validavam apenas coerência estática autor↔prefixo
# de branch. Como o init grava user.email no config compartilhado do repo,
# qualquer processo dentro de um worktree alugado podia criar branches ia-*
# e commitar sem nunca ter feito init — mesmo com o lease de outra sessão
# vivo. Em 2026-07-13 um ator sem lease criou branch, commitou e mergeou PR
# dentro do worktree do kimi1 com o lease do kimi1 ativo (incidente L186).
#
# Regra: se existe session file ATIVO com PID VIVO cujo worktree_path é este
# worktree, somente processos DESCENDENTES desse PID podem escrever aqui.
# Lease morto, ausente ou de outro worktree → permitido (recovery/adopt).
#
# Uso:  source este arquivo; lease_owner_check [identity]
#   identity: identidade resolvida do autor (ex: kimi1). Vazio = valida
#             contra QUALQUER lease ativo deste worktree (modo pre-checkout).
# Retorno: 0 = permitido; 1 = bloqueado (mensagem em stderr).
#
# Bypass manual (humano em recuperação consciente):
#   HMVIP_AGENT_GUARD_BYPASS=1 git commit ...
#
# Override para testes: AGENT_GUARD_SESSION_DIR=<dir com JSONs de sessão>

# Caminha a cadeia de PPIDs procurando o PID do lease.
_lease_is_ancestor() {
    local target="$1" p="${PPID:-0}" n=0
    while [[ "${p}" =~ ^[0-9]+$ ]] && [[ "${p}" -gt 1 ]] && [[ ${n} -lt 64 ]]; do
        [[ "${p}" == "${target}" ]] && return 0
        p="$(ps -o ppid= -p "${p}" 2>/dev/null | tr -d '[:space:]')"
        n=$((n + 1))
    done
    return 1
}

lease_owner_check() {
    local identity="${1:-}"

    # Bypass manual explícito.
    if [[ "${HMVIP_AGENT_GUARD_BYPASS:-0}" == "1" ]]; then
        echo "⚠️  [GUARD] bypass manual ativo (HMVIP_AGENT_GUARD_BYPASS=1)" >&2
        return 0
    fi

    local worktree_root
    worktree_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
    [[ -n "${worktree_root}" ]] || return 0

    # Raiz do repo principal (worktrees compartilham o .git comum): os session
    # files vivem no repo principal, não no worktree.
    local common_dir main_root
    common_dir="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)" || return 0
    main_root="$(dirname "${common_dir}")"

    # Diretório de sessões: override de teste → config → default.
    local session_dir="${AGENT_GUARD_SESSION_DIR:-}"
    if [[ -z "${session_dir}" ]]; then
        local cfg="${worktree_root}/packages/agent-guard-core/bin/agent-guard-config"
        local rel=""
        if [[ -f "${cfg}" ]]; then
            rel="$(bash "${cfg}" get paths.session_storage '' 2>/dev/null)"
        fi
        session_dir="${main_root}/${rel:-.kiro/locks/agent-sessions}"
    fi
    [[ -d "${session_dir}" ]] || return 0

    local files=()
    if [[ -n "${identity}" ]]; then
        [[ -f "${session_dir}/${identity}.json" ]] && files=("${session_dir}/${identity}.json")
    else
        files=("${session_dir}"/*.json)
    fi

    local f status pid wt_path owner
    for f in "${files[@]}"; do
        [[ -f "${f}" ]] || continue
        status="$(sed -n 's/.*"status": *"\([^"]*\)".*/\1/p' "${f}" | head -1)"
        [[ "${status}" == "active" ]] || continue
        wt_path="$(sed -n 's/.*"worktree_path": *"\([^"]*\)".*/\1/p' "${f}" | head -1)"
        [[ "${wt_path}" == "${worktree_root}" ]] || continue
        pid="$(sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p' "${f}" | head -1)"
        [[ "${pid}" =~ ^[0-9]+$ ]] || continue
        # Lease morto (sessão fechou sem release): permite — fluxo adopt/recovery.
        kill -0 "${pid}" 2>/dev/null || continue

        # Lease vivo neste worktree: exige ancestralidade de processo.
        if _lease_is_ancestor "${pid}"; then
            return 0
        fi

        owner="$(basename "${f}" .json)"
        cat >&2 <<EOF
❌❌❌ BLOQUEADO: WORKTREE ALUGADO POR OUTRA SESSÃO ❌❌❌

Este worktree (${worktree_root}) está alugado pela sessão '${owner}'
(PID ${pid}, vivo) e este processo NÃO é descendente dessa sessão.

Cenário típico: sessão ou terminal sem lease operando em worktree alugado
— foi assim que commits de uma sessão caíram na branch de outra (L186).

O que fazer:
  • Nova sessão de IA: saia deste worktree e alugue sua identidade:
      source .hmvip-agent-init <prefixo> <papel>
    O init recusa slot com sessão viva — sem colisão possível.
  • A sessão dona travou/foi fechada: o lease expira sozinho com o PID morto;
    assuma com 'hmvip ad ${owner}' (adopt), que registra a posse.
  • Humano em recuperação consciente: HMVIP_AGENT_GUARD_BYPASS=1 <comando>
EOF
        return 1
    done

    return 0
}
