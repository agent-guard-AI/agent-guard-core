#!/usr/bin/env bash
#
# Teste das camadas de consciência do boot cache (ADR-0052).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPDIR="$(mktemp -d)"
trap "rm -rf ${TMPDIR}" EXIT

export AG_PYTHON="${AG_PYTHON:-python3}"
source "${SCRIPT_DIR}/../src/boot-cache.sh"

passed=0
failed=0

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "${actual}" = "${expected}" ]; then
        echo "✅ ${msg}"
        passed=$((passed + 1))
    else
        echo "❌ ${msg}"
        echo "   Esperado: ${expected}"
        echo "   Obtido:   ${actual}"
        failed=$((failed + 1))
    fi
}

echo "Running boot-cache layer tests..."

# Test 1: classificação K3 -> camada 2
assert_eq "$(_boot_state_classify_task "cria spec" "k3")" "2" "K3 -> camada 2"
assert_eq "$(_boot_state_classify_task "analisa bug" "k3-high")" "2" "k3-high -> camada 2"

# Test 2: classificação K2.7 rotineira -> camada 0
assert_eq "$(_boot_state_classify_task "enfileira PR" "k2.7")" "0" "K2.7 rotineiro -> camada 0"
assert_eq "$(_boot_state_classify_task "atualiza nota do slot" "k2.7")" "0" "K2.7 rotineiro -> camada 0"

# Test 3: palavras-chave forçam camada 2
assert_eq "$(_boot_state_classify_task "corrige vazamento P0" "k2.7")" "2" "P0/vazamento -> camada 2"
assert_eq "$(_boot_state_classify_task "refatora cache de tier" "k2.7")" "2" "refator/cross-plugin -> camada 2"

# Test 4: palavras-chave forçam camada 1
assert_eq "$(_boot_state_classify_task "corrige bug de notice" "k2.7")" "1" "bug -> camada 1"
assert_eq "$(_boot_state_classify_task "verifica council" "k2.7")" "1" "council -> camada 1"

# Test 5: camadas esperadas
assert_eq "$(_boot_state_layers_for_consciousness 0)" "lease token-economy todo alerts-recent" "Camada 0 contém layers mínimas"
assert_eq "$(_boot_state_layers_for_consciousness 1)" "lease token-economy todo alerts-recent council guardian incident-log" "Camada 1 contém guardian/incident-log"
assert_eq "$(_boot_state_layers_for_consciousness 2)" "lease token-economy todo alerts-recent council guardian incident-log contract discovery domain-skill" "Camada 2 contém discovery/contrato"

# Test 6: save/load de camada 0
worktree="${TMPDIR}/wt"
mkdir -p "${worktree}"
echo "alerta recente" > "${worktree}/ALERTAS-RECENT.md"

layers0="$(_boot_state_layers_for_consciousness 0)"
artifacts0="$(_boot_state_artifacts_for_consciousness 0 "${worktree}")"
_boot_state_save "kimi7" "${worktree}" "ia-test" "${layers0}" "${artifacts0}"

if HMVIP_BOOT_CACHE_VALID=""; _boot_state_load "kimi7" "${worktree}" "lease token-economy todo alerts-recent"; then
    echo "✅ Camada 0 carrega com layers corretas"
    passed=$((passed + 1))
else
    echo "❌ Camada 0 não carregou"
    failed=$((failed + 1))
fi

# Test 7: camada 0 não satisfaz requisição de camada 2
if ! _boot_state_load "kimi7" "${worktree}" "contract discovery"; then
    echo "✅ Camada 0 não satisfaz requisição de camada 2"
    passed=$((passed + 1))
else
    echo "❌ Camada 0 deveria falhar para camada 2"
    failed=$((failed + 1))
fi

# Test 8: camada 2 satisfaz todas as layers
layers2="$(_boot_state_layers_for_consciousness 2)"
artifacts2="$(_boot_state_artifacts_for_consciousness 2 "${worktree}")"
# Criar artefatos extras necessários
mkdir -p "${worktree}/.agent-guard" "${worktree}/.kiro/agents"
echo "digest" > "${worktree}/.agent-guard/council-digest.md"
echo "incidentes" > "${worktree}/.kiro/agents/incident-log.md"
_boot_state_save "kimi7" "${worktree}" "ia-test" "${layers2}" "${artifacts2}"

if _boot_state_load "kimi7" "${worktree}" "lease token-economy todo alerts-recent council guardian incident-log contract discovery domain-skill"; then
    echo "✅ Camada 2 satisfaz todas as layers"
    passed=$((passed + 1))
else
    echo "❌ Camada 2 não satisfaz todas as layers"
    failed=$((failed + 1))
fi

echo ""
echo "Results: ${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
