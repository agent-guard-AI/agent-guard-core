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
# Leitura: fronteira ADR-0057 — este hook NÃO lê nem parseia
# .kiro/locks/agent-sessions/*.json. Toda leitura vai pela primitiva
# pública read-only `bin/agent-guard-lease-probe` (bash puro, <=30 ms,
# sem reconcile/network). Override de teste: AGENT_GUARD_SESSION_DIR
# (honrado pela primitiva).

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

    # Primitiva pública read-only (ADR-0057) — mesma derivação de main repo e
    # mesmo parse tolerante do legado, encapsuladas no kernel boundary.
    # Sem source de init.sh, sem python/jq, sem reconcile, sem network.
    local probe_bin
    probe_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" 2>/dev/null && pwd)/agent-guard-lease-probe"
    if [[ ! -x "${probe_bin}" ]]; then
        # Fail-open aprovado pela ADR-0057 §4: primitiva ausente = sem leases.
        echo "⚠️  [GUARD] agent-guard-lease-probe ausente; guard L186 sem efeito" >&2
        return 0
    fi

    local probe_args=(--worktree "${worktree_root}")
    [[ -n "${identity}" ]] && probe_args+=(--identity "${identity}")

    local probe_out
    probe_out="$(bash "${probe_bin}" "${probe_args[@]}" 2>/dev/null)" || probe_out=""

    local owner status pid wt_path
    # Mesma tabela de decisão do legado (suíte L186 é o contrato):
    # bloqueio SOMENTE no quádruplo match — active + PID vivo +
    # worktree_path == toplevel + processo atual não descendente do dono.
    while IFS=$'\t' read -r owner status pid wt_path; do
        [[ -n "${owner}" ]] || continue
        [[ "${status}" == "active" ]] || continue
        [[ "${wt_path}" == "${worktree_root}" ]] || continue
        [[ "${pid}" =~ ^[0-9]+$ ]] || continue
        # Lease morto (sessão fechou sem release): permite — fluxo adopt/recovery.
        kill -0 "${pid}" 2>/dev/null || continue

        # Lease vivo neste worktree: exige ancestralidade de processo.
        # Se o processo atual É o próprio lease (sessão dona diretamente),
        # permite sem precisar subir a árvore de processos.
        if [[ "$$" == "${pid}" ]] || _lease_is_ancestor "${pid}"; then
            return 0
        fi

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
    done <<< "${probe_out}"

    return 0
}
