#!/usr/bin/env bash
#
# add-worktree-note.sh
#
# Adiciona uma git note ao commit atual com metadados de origem do worktree.
# Usado pelo hook post-commit para permitir auditoria server-side de onde o
# commit foi criado (repo principal vs worktree de IA).
#
# Uso:
#   bash packages/agent-guard-core/ci/add-worktree-note.sh
#

set -euo pipefail

# Só executa dentro de um repositório git
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

WORKTREE_PATH="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -z "${WORKTREE_PATH}" ]]; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_BIN="${SCRIPT_DIR}/../bin/agent-guard-config"

# Detecta se estamos em um worktree de IA usando os prefixos configurados.
WORKTREE_NAME="$(basename "${WORKTREE_PATH}")"
IDENTITY=""
for prefix in $(bash "${CONFIG_BIN}" keys identities 2>/dev/null); do
    wt_prefix="$(bash "${CONFIG_BIN}" get "identities.${prefix}.worktree_prefix" "")"
    if [[ -n "${wt_prefix}" && "${WORKTREE_NAME}" =~ ^${wt_prefix}([0-9]+)$ ]]; then
        IDENTITY="${prefix}${BASH_REMATCH[1]}"
        break
    fi
done

if [[ -z "${IDENTITY}" ]]; then
    # Repo principal ou outro worktree nao-IA: nao adiciona metadados de IA
    exit 0
fi

BRANCH="$(git branch --show-current 2>/dev/null || echo "")"
SESSION_STORAGE="$(bash "${CONFIG_BIN}" get paths.session_storage ".agent-guard/sessions")"
SESSION_FILE="${WORKTREE_PATH}/${SESSION_STORAGE}/${IDENTITY}.json"
if [[ ! -f "${SESSION_FILE}" ]]; then
    # Fallback para caminho absoluto relativo ao repo principal
    REPO_ROOT="$(bash "${CONFIG_BIN}" get paths.main_repo "")"
    if [[ -n "${REPO_ROOT}" ]]; then
        SESSION_FILE="${REPO_ROOT}/${SESSION_STORAGE}/${IDENTITY}.json"
    fi
fi

SESSION_ID=""
if [[ -f "${SESSION_FILE}" ]]; then
    SESSION_ID="$(python3 -c "import json,sys; d=json.load(open('${SESSION_FILE}')); print(d.get('session_id',''))" 2>/dev/null || echo "")"
fi

NOTE_CONTENT="worktree:${WORKTREE_PATH}
identity:${IDENTITY}
branch:${BRANCH}"
if [[ -n "${SESSION_ID}" ]]; then
    NOTE_CONTENT="${NOTE_CONTENT}
session_id:${SESSION_ID}"
fi

NOTES_REF="$(bash "${CONFIG_BIN}" get git.notes_ref "refs/notes/agent-guard-worktree")"

# Adiciona a nota de forma idempotente (sobrescreve se ja existir para HEAD)
git notes --ref="${NOTES_REF}" add -f -m "${NOTE_CONTENT}" HEAD >/dev/null 2>&1 || true
