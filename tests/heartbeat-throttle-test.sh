#!/usr/bin/env bash
#
# heartbeat-throttle-test.sh — testa o throttle do agent-guard-heartbeat.sh (ADR-0051).
#
#   bash packages/agent-guard-core/tests/heartbeat-throttle-test.sh
#
# Cobre: primeira chamada atualiza, chamadas subsequentes sao throttled,
#        contador de prompts incrementa, limiar de tempo (60s) e de contagem (5)
#        disparam atualizacao, e wakeup alert ainda e processado mesmo throttled.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HERE}/../wrappers/kimi/hooks/agent-guard-heartbeat.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

FAKE_REPO="${SANDBOX}/hmvip-ia-kimi7"
mkdir -p "${FAKE_REPO}/.agent-guard/session"
mkdir -p "${FAKE_REPO}/.agent-guard/wakeup"
# Git repo minimo para rev-parse funcionar.
git -C "${FAKE_REPO}" init -q 2>/dev/null

# Stub do .hmvip-agent-init: so carrega as funcoes necessarias.
cat > "${FAKE_REPO}/.hmvip-agent-init" <<'EOF'
# Stub para testes de heartbeat.
function _detect_identity_from_worktree_name() {
    case "$1" in
        hmvip-ia-kimi7) echo "kimi7" ;;
        *) echo "" ;;
    esac
}
function _update_last_activity() {
    local identity="$1"
    local stamp_file="${PWD}/.agent-guard/session/last-activity-log"
    printf '%s\n' "${identity}:$(date +%s)" >> "${stamp_file}"
}
# shellcheck source=/dev/null
[ -n "${AGENT_GUARD_FUNCTIONS_ONLY:-}" ] && return 0
EOF

# agent-guard.yaml vazio (apenas para passar a existencia).
touch "${FAKE_REPO}/agent-guard.yaml"

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf 'ok   %s\n' "$1"
}

bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n     got: %s\n' "$1" "$2"
}

run_heartbeat() {
    (
        cd "${FAKE_REPO}"
        bash "${HOOK}" >/dev/null 2>&1
    )
}

activity_count() {
    wc -l < "${FAKE_REPO}/.agent-guard/session/last-activity-log" 2>/dev/null || echo 0
}

throttle_value() {
    jq -r "$1" "${FAKE_REPO}/.agent-guard/session/heartbeat-throttle.json" 2>/dev/null || echo ""
}

echo "== throttle por contagem =="

run_heartbeat
[[ "$(activity_count)" == "1" ]] \
    && ok "primeira chamada atualiza last_activity" \
    || bad "primeira chamada" "$(activity_count) atualizacoes"

run_heartbeat
run_heartbeat
run_heartbeat
[[ "$(activity_count)" == "1" ]] \
    && ok "4 chamadas em menos de 60s => apenas 1 atualizacao" \
    || bad "throttle curto" "$(activity_count) atualizacoes"

# Chamadas 5 e 6: a 5a ainda e throttled; a 6a dispara update (a cada 5 prompts).
run_heartbeat
[[ "$(activity_count)" == "1" ]] \
    && ok "5a chamada ainda throttled" \
    || bad "5a chamada" "$(activity_count) atualizacoes"

run_heartbeat
[[ "$(activity_count)" == "2" ]] \
    && ok "6a chamada (5o prompt) dispara nova atualizacao" \
    || bad "limiar de 5 prompts" "$(activity_count) atualizacoes"

prompts_since="$(throttle_value '.prompts_since')"
[[ "${prompts_since}" == "0" ]] \
    && ok "contador reiniciado apos atualizacao" \
    || bad "reinicio do contador" "prompts_since=${prompts_since}"

echo "== throttle por tempo =="

# Forca o arquivo de throttle para 65s atras.
now="$(date +%s)"
jq --argjson t "$((now - 65))" '.last_update = $t | .prompts_since = 2' \
    "${FAKE_REPO}/.agent-guard/session/heartbeat-throttle.json" > "${SANDBOX}/tmp.json" \
    && mv "${SANDBOX}/tmp.json" "${FAKE_REPO}/.agent-guard/session/heartbeat-throttle.json"

run_heartbeat
[[ "$(activity_count)" == "3" ]] \
    && ok "atualizacao apos 60s mesmo com prompts_since < 5" \
    || bad "limiar de tempo" "$(activity_count) atualizacoes"

echo "== wakeup alert nao e throttled =="

# Cria um wakeup alert.
cat > "${FAKE_REPO}/.agent-guard/wakeup/kimi7.json" <<'EOF'
{"title":"test wake","severity":"P1","summary":"resumo do alerta","source":"#test"}
EOF

# Forca throttle recente para garantir que heartbeat estaria throttled.
now="$(date +%s)"
jq --argjson t "${now}" '.last_update = $t | .prompts_since = 0' \
    "${FAKE_REPO}/.agent-guard/session/heartbeat-throttle.json" > "${SANDBOX}/tmp.json" \
    && mv "${SANDBOX}/tmp.json" "${FAKE_REPO}/.agent-guard/session/heartbeat-throttle.json"

output="$(cd "${FAKE_REPO}" && bash "${HOOK}" 2>&1 >/dev/null)"
[[ -f "${FAKE_REPO}/.agent-guard/wakeup/kimi7.json.ack" ]] \
    && ok "wakeup alert e processado mesmo quando last_activity e throttled" \
    || bad "wakeup nao processado" "${output}"

# Atividade nao deve ter sido atualizada (ainda throttled).
[[ "$(activity_count)" == "3" ]] \
    && ok "wakeup processado sem atualizar last_activity" \
    || bad "last_activity atualizada no wakeup" "$(activity_count) atualizacoes"

echo "== troca de identidade reseta throttle =="

# Simula troca de identidade no mesmo worktree (caso raro, mas defensivo).
jq '.identity = "kimi1" | .last_update = 999999999 | .prompts_since = 0' \
    "${FAKE_REPO}/.agent-guard/session/heartbeat-throttle.json" > "${SANDBOX}/tmp.json" \
    && mv "${SANDBOX}/tmp.json" "${FAKE_REPO}/.agent-guard/session/heartbeat-throttle.json"

run_heartbeat
[[ "$(activity_count)" == "4" ]] \
    && ok "identidade diferente no throttle dispara atualizacao imediata" \
    || bad "troca de identidade" "$(activity_count) atualizacoes"

identity="$(throttle_value '.identity')"
[[ "${identity}" == "kimi7" ]] \
    && ok "throttle e regravado com identidade correta" \
    || bad "identidade no throttle" "${identity}"

echo
echo "PASS=${PASS} FAIL=${FAIL}"
[ "${FAIL}" -eq 0 ]
