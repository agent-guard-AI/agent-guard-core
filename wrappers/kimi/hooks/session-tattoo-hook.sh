#!/usr/bin/env bash
#
# session-tattoo-hook.sh — hook do Kimi Code para a tatuagem de sessao
# (Ecosystem Guardian, Fase 7 / H6 — spec specs-ecosystem-guardian-20260802).
#
# Registrado nos eventos Stop e SessionEnd do ~/.kimi-code/config.toml.
# Recebe o evento como $1 e o payload JSON via stdin (contrato oficial dos
# hooks do Kimi — mesmo padrao do kimi-tab-hook.sh), e repassa para o gerador
# packages/agent-guard-core/session-tattoo/tattoo.sh do worktree da sessao
# (fallback: repo principal).
#
# ENDURECER NUNCA LIMITAR: observacao-pura — NUNCA escreve em stdout (stdout
# vira contexto do modelo) e SEMPRE sai 0, mesmo se o gerador nao existir,
# falhar ou estourar o timeout. Falha na tatuagem jamais quebra a sessao.
#
set -u
umask 077

PAYLOAD=""
if [ ! -t 0 ]; then
    PAYLOAD="$(cat 2>/dev/null || true)"
fi

CWD=""
if [ -n "${PAYLOAD}" ] && command -v jq >/dev/null 2>&1; then
    CWD="$(printf '%s' "${PAYLOAD}" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -z "${CWD}" ] && CWD="${PWD:-}"

TATTOO=""
for base in "${CWD}" /home/hmvip-dev/hmvip; do
    candidate="${base}/packages/agent-guard-core/session-tattoo/tattoo.sh"
    if [ -f "${candidate}" ]; then
        TATTOO="${candidate}"
        break
    fi
done

if [ -n "${TATTOO}" ]; then
    printf '%s' "${PAYLOAD}" | timeout 4 bash "${TATTOO}" "${1:-stop}" >/dev/null 2>&1 || true
fi

exit 0
