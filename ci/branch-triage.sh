#!/usr/bin/env bash
#
# Branch Triage Helper — Agent Guard
# Classifica branches remotas como seguras para deleção ou que precisam de revisão.
#
# Uso:
#   packages/agent-guard-core/ci/branch-triage.sh [prefixo-identidade]
# Exemplo:
#   packages/agent-guard-core/ci/branch-triage.sh ia-kimi1

set -euo pipefail

IDENTITY_PREFIX="${1:-ia-kimi1}"

echo "🔍 Triage de branches remotas com prefixo: $IDENTITY_PREFIX"
echo "================================================================"

# Atualiza referências
git fetch origin --prune >/dev/null 2>&1 || true

SAFE_DELETE=()
MERGE_ONLY=()
OBSOLETE=()
NEEDS_REVIEW=()
DIVERGED=()

for branch in $(git branch -r | grep "origin/${IDENTITY_PREFIX}" | sed 's/^  origin\///' | sort); do
    # Verifica se há merge base
    if ! git merge-base origin/develop origin/"$branch" >/dev/null 2>&1; then
        DIVERGED+=("$branch")
        continue
    fi

    # Commits da branch que não estão em develop
    new_commits=$(git log --oneline origin/develop..origin/"$branch" 2>/dev/null || true)

    if [ -z "$new_commits" ]; then
        # Nenhum commit novo vs develop → seguro deletar
        SAFE_DELETE+=("$branch")
        continue
    fi

    # Diff da branch vs develop
    diff_stat=$(git diff --stat origin/develop...origin/"$branch" 2>/dev/null || true)

    if [ -z "$diff_stat" ]; then
        # Commits existem, mas diff vazio → obsoleto (conteúdo já em develop de outra forma)
        OBSOLETE+=("$branch")
        continue
    fi

    # Verifica se é apenas merge commit
    commit_count=$(echo "$new_commits" | wc -l)
    first_msg=$(git log --format=%s -1 origin/"$branch")
    if [ "$commit_count" -eq 1 ] && echo "$first_msg" | grep -qiE "^Merge branch 'develop'"; then
        MERGE_ONLY+=("$branch")
        continue
    fi

    # Verifica conflitos potenciais: arquivos da branch também alterados em develop depois do merge-base
    merge_base=$(git merge-base origin/develop origin/"$branch")
    branch_files=$(git diff --name-only "${merge_base}...origin/${branch}" 2>/dev/null | sort || true)
    develop_files=$(git diff --name-only "${merge_base}...origin/develop" 2>/dev/null | sort || true)
    overlap=$(comm -12 <(echo "$branch_files") <(echo "$develop_files") || true)

    if [ -n "$overlap" ]; then
        NEEDS_REVIEW+=("$branch [conflito potencial] -> $(echo "$overlap" | wc -l) arquivo(s)")
    else
        NEEDS_REVIEW+=("$branch [sem conflito aparente]")
    fi
done

print_list() {
    local title="$1"
    shift
    local arr=("$@")
    echo ""
    echo "$title (${#arr[@]})"
    echo "----------------------------------------------------------------"
    if [ ${#arr[@]} -eq 0 ]; then
        echo "  (nenhuma)"
    else
        for item in "${arr[@]}"; do
            echo "  - $item"
        done
    fi
}

print_list "🗑️  Seguras para deletar (já mergeadas)" "${SAFE_DELETE[@]}"
print_list "🔄 Apenas merge commits (sem conteúdo)" "${MERGE_ONLY[@]}"
print_list "📦 Obsoletas (commits existem, mas diff vazio)" "${OBSOLETE[@]}"
print_list "⚠️  Precisam de revisão (conteúdo não integrado)" "${NEEDS_REVIEW[@]}"
print_list "🔥 Divergentes (sem merge base com develop)" "${DIVERGED[@]}"

echo ""
echo "================================================================"
echo "Resumo: ${#SAFE_DELETE[@]} seguras | ${#MERGE_ONLY[@]} merge-only | ${#OBSOLETE[@]} obsoletas | ${#NEEDS_REVIEW[@]} revisar | ${#DIVERGED[@]} divergentes"
