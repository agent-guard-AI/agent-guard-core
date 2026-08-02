#!/usr/bin/env bash
#
# PAS — Protocolo de Ação Sensível: scan não-bloqueante do pre-push.
# SPEC-ECOSYSTEM-GUARDIAN H5 (task 3.3) — .kiro/specs/specs-ecosystem-guardian-20260802/
#
# REGRA DURA DO DONO (princípio "endurecer, nunca limitar"): este script
# NUNCA pode bloquear ou falhar um commit/push. Ele sempre sai 0 — qualquer
# erro interno é engolido com log em stderr ("[PAS]"). É chamado pelo
# hooks/pre-push com `|| true` no ponto de chamada (exceção intencional e
# documentada ao padrão fail-hard do G-HYGIENE, que não varre packages/).
#
# O que faz: para cada commit do range sendo pushado (lido do stdin no
# protocolo pre-push: "<local ref> <local sha> <remote ref> <remote sha>"),
# cruza `git diff-tree --name-only` com o inventário versionado
# .agent-guard/sensitive-paths.json e adiciona/atualiza a linha
# `sensitive: <categorias>` na git note do commit (mesma ref de notes do
# worktree origin audit — refs/notes/hmvip-worktree). O push das notes a
# seguir já carrega a anotação. Performance: máx. 50 commits no range;
# scan típico < 2s. Sem jq como dependência obrigatória: fallback python3;
# sem nenhum dos dois, pula com log.

# Deliberadamente SEM `set -e`/`set -u`: nenhum erro pode se propagar.

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "${REPO_ROOT}" ]]; then
    echo "[PAS] fora de um repositório git — scan pulado" >&2
    exit 0
fi

INVENTORY="${REPO_ROOT}/.agent-guard/sensitive-paths.json"
if [[ ! -f "${INVENTORY}" ]]; then
    echo "[PAS] inventário ${INVENTORY} ausente — scan pulado" >&2
    exit 0
fi

AGENT_GUARD_BIN="${REPO_ROOT}/packages/agent-guard-core/bin/agent-guard-config"
NOTES_REF="refs/notes/hmvip-worktree"
if [[ -f "${AGENT_GUARD_BIN}" ]]; then
    _cfg_ref="$(bash "${AGENT_GUARD_BIN}" get git.notes_ref "${NOTES_REF}" 2>/dev/null)"
    [[ -n "${_cfg_ref}" ]] && NOTES_REF="${_cfg_ref}"
fi

MAX_COMMITS=50

# ---------------------------------------------------------------------------
# Parse do inventário (jq → python3 → pula com log). Emite "categoria\tglob".
# ---------------------------------------------------------------------------
_pas_inventory_tsv() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.categories | to_entries[] | .key as $k | .value[] | [$k, .] | @tsv' "${INVENTORY}" 2>/dev/null
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "${INVENTORY}" <<'PYEOF' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    for cat, patterns in data.get("categories", {}).items():
        for pat in patterns:
            print(f"{cat}\t{pat}")
except Exception:
    pass
PYEOF
        return
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Glob git-style → regex bash: `**/` = zero+ diretórios, `**` = qualquer
# profundidade, `*` = dentro do segmento, `?` = 1 char fora de `/`.
# ---------------------------------------------------------------------------
_pas_glob_re() {
    local g="$1"
    # Escapa metacaracteres de regex (exceto * ? /).
    g="$(printf '%s' "${g}" | sed -e 's/[].[+^$(){}|\\]/\\&/g')"
    g="${g//\*\*\//__PASDS__}"
    g="${g//\*\*/.*}"
    g="${g//__PASDS__/(.*/)?}"
    g="${g//\*/[^/]*}"
    g="${g//\?/[^/]}"
    printf '%s' "${g}"
}

_pas_main() {
    local tsv
    tsv="$(_pas_inventory_tsv)"
    if [[ -z "${tsv}" ]]; then
        echo "[PAS] jq e python3 ausentes (ou inventário inválido) — scan pulado" >&2
        return 0
    fi

    # Pré-compila um regex combinado por categoria: ^(re1|re2|...)$.
    local -a cat_names=()
    local -A cat_re=()
    local cat pat re
    while IFS=$'\t' read -r cat pat; do
        [[ -n "${cat}" && -n "${pat}" ]] || continue
        re="$(_pas_glob_re "${pat}")"
        if [[ -z "${cat_re[${cat}]:-}" ]]; then
            cat_names+=("${cat}")
            cat_re["${cat}"]="${re}"
        else
            cat_re["${cat}"]="${cat_re[${cat}]}|${re}"
        fi
    done <<< "${tsv}"

    if [[ ${#cat_names[@]} -eq 0 ]]; then
        echo "[PAS] inventário sem categorias — scan pulado" >&2
        return 0
    fi

    # Lê o range do stdin (protocolo pre-push) e coleta os commits (máx. 50).
    local -a commits=()
    local local_ref local_sha remote_ref remote_sha sha
    while read -r local_ref local_sha remote_ref remote_sha; do
        [[ -n "${local_sha}" ]] || continue
        # Push de deleção (local sha zerado) não tem commits a anotar.
        [[ "${local_sha}" =~ ^0+$ ]] && continue
        if [[ -n "${remote_sha}" && ! "${remote_sha}" =~ ^0+$ ]]; then
            while read -r sha; do
                [[ -n "${sha}" ]] && commits+=("${sha}")
            done < <(git rev-list -n "${MAX_COMMITS}" "${remote_sha}..${local_sha}" 2>/dev/null)
        else
            # Branch nova no remoto: limita aos commits ainda não publicados.
            while read -r sha; do
                [[ -n "${sha}" ]] && commits+=("${sha}")
            done < <(git rev-list -n "${MAX_COMMITS}" "${local_sha}" --not --remotes=origin 2>/dev/null)
        fi
        [[ ${#commits[@]} -ge ${MAX_COMMITS} ]] && break
    done

    if [[ ${#commits[@]} -eq 0 ]]; then
        echo "[PAS] nenhum commit no range — nada a anotar" >&2
        return 0
    fi

    local -A seen=()
    local commit file note cats existing_sens merged
    for commit in "${commits[@]}"; do
        [[ -n "${seen[${commit}]:-}" ]] && continue
        seen["${commit}"]=1

        cats=""
        while read -r file; do
            [[ -n "${file}" ]] || continue
            for cat in "${cat_names[@]}"; do
                # Já marcada para este commit? Pula (micro-otimização).
                [[ ";${cats};" == *";${cat};"* ]] && continue
                if [[ "${file}" =~ ^(${cat_re[${cat}]})$ ]]; then
                    cats="${cats};${cat}"
                fi
            done
        done < <(git diff-tree --no-commit-id --name-only -r "${commit}" 2>/dev/null)
        cats="${cats#;}"

        [[ -z "${cats}" ]] && continue

        note="$(git notes --ref="${NOTES_REF}" show "${commit}" 2>/dev/null)"
        # Se a note já tem linha sensitive:, faz união das categorias.
        existing_sens="$(printf '%s\n' "${note}" | sed -n 's/^sensitive:[[:space:]]*//p' | head -1)"
        if [[ -n "${existing_sens}" ]]; then
            merged="$(printf '%s\n%s\n' "${existing_sens}" "${cats}" | tr ',;' '\n\n' | sed '/^$/d' | sort -u | paste -sd, -)"
            # Remove a linha sensitive: antiga do corpo da note.
            note="$(printf '%s\n' "${note}" | sed '/^sensitive:[[:space:]]*/d')"
        else
            merged="$(printf '%s\n' "${cats}" | tr ';' '\n' | sed '/^$/d' | sort -u | paste -sd, -)"
        fi

        note="${note%$'\n'}"
        git notes --ref="${NOTES_REF}" add -f -m "${note}
sensitive: ${merged}" "${commit}" >/dev/null 2>&1 \
            && echo "[PAS] commit ${commit:0:8} anotado: sensitive: ${merged}" >&2
    done

    return 0
}

# Qualquer falha interna é engolida: o PAS nunca bloqueia o push.
_pas_main || echo "[PAS] erro interno ignorado (scan não-bloqueante)" >&2
exit 0
