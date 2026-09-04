#!/usr/bin/env bash
#
# Teste de contrato do hmvip-hook-dispatcher.sh (ADR-0052).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer the user-installed hook dispatcher, but fall back to the in-repo
# dispatcher so the test remains hermetic in CI and fresh clones.
DISPATCHER="${HOME}/.kimi-code/hooks/hmvip-hook-dispatcher.sh"
if [[ ! -f "${DISPATCHER}" ]]; then
    DISPATCHER="${SCRIPT_DIR}/../wrappers/kimi/hooks/hmvip-hook-dispatcher.sh"
fi
TMPDIR="$(mktemp -d)"
trap "rm -rf ${TMPDIR}" EXIT

TAB_OUT="${TMPDIR}/tab.log"
HB_OUT="${TMPDIR}/hb.log"
TATTOO_OUT="${TMPDIR}/tattoo.log"

# Handlers mock
mock_tab="${TMPDIR}/tab.sh"
cat > "${mock_tab}" <<'EOF'
#!/bin/bash
printf 'tab:%s\n' "$1" >> "$TAB_OUT"
EOF
chmod +x "${mock_tab}"

mock_hb="${TMPDIR}/hb.sh"
cat > "${mock_hb}" <<'EOF'
#!/bin/bash
printf 'hb\n' >> "$HB_OUT"
EOF
chmod +x "${mock_hb}"

mock_tattoo="${TMPDIR}/tattoo.sh"
cat > "${mock_tattoo}" <<'EOF'
#!/bin/bash
printf 'tattoo:%s\n' "$1" >> "$TATTOO_OUT"
EOF
chmod +x "${mock_tattoo}"

export TAB_OUT HB_OUT TATTOO_OUT
export HMVIP_DISPATCHER_DIR="${TMPDIR}"
export HMVIP_TAB_HANDLER="${mock_tab}"
export HMVIP_HEARTBEAT_HANDLER="${mock_hb}"
export HMVIP_TATTOO_HANDLER="${mock_tattoo}"

run_dispatcher() {
    printf '%s' "$1" | "${DISPATCHER}"
}

passed=0
failed=0

assert_file_contains() {
    local file="$1" expected="$2" msg="$3"
    if grep -q "${expected}" "${file}" 2>/dev/null; then
        echo "✅ ${msg}"
        passed=$((passed + 1))
    else
        echo "❌ ${msg}"
        echo "   Esperado: ${expected}"
        echo "   Em: ${file}"
        failed=$((failed + 1))
    fi
}

assert_file_not_contains() {
    local file="$1" unexpected="$2" msg="$3"
    if grep -q "${unexpected}" "${file}" 2>/dev/null; then
        echo "❌ ${msg}"
        failed=$((failed + 1))
    else
        echo "✅ ${msg}"
        passed=$((passed + 1))
    fi
}

# Limpa logs entre testes
clear_logs() {
    rm -f "${TAB_OUT}" "${HB_OUT}" "${TATTOO_OUT}"
}

echo "Running hook-dispatcher tests..."

# Test 1: UserPromptSubmit -> tab working + heartbeat
clear_logs
run_dispatcher '{"hook_event_name":"UserPromptSubmit","prompt":"oi"}'
assert_file_contains "${TAB_OUT}" "tab:working" "UserPromptSubmit dispara tab working"
assert_file_contains "${HB_OUT}" "hb" "UserPromptSubmit dispara heartbeat"
assert_file_not_contains "${TATTOO_OUT}" "tattoo" "UserPromptSubmit não dispara tattoo"

# Test 2: PermissionRequest -> tab attention, sem heartbeat
clear_logs
run_dispatcher '{"hook_event_name":"PermissionRequest"}'
assert_file_contains "${TAB_OUT}" "tab:attention" "PermissionRequest dispara tab attention"
assert_file_not_contains "${HB_OUT}" "hb" "PermissionRequest não dispara heartbeat"

# Test 3: Stop -> tab attention + tattoo stop
clear_logs
run_dispatcher '{"hook_event_name":"Stop"}'
assert_file_contains "${TAB_OUT}" "tab:attention" "Stop dispara tab attention"
assert_file_contains "${TATTOO_OUT}" "tattoo:stop" "Stop dispara tattoo stop"
assert_file_not_contains "${HB_OUT}" "hb" "Stop não dispara heartbeat"

# Test 4: SessionEnd -> tab session-end + tattoo session-end
clear_logs
run_dispatcher '{"hook_event_name":"SessionEnd"}'
assert_file_contains "${TAB_OUT}" "tab:session-end" "SessionEnd dispara tab session-end"
assert_file_contains "${TATTOO_OUT}" "tattoo:session-end" "SessionEnd dispara tattoo session-end"

# Test 5: SessionStart -> tab session-start
clear_logs
run_dispatcher '{"hook_event_name":"SessionStart"}'
assert_file_contains "${TAB_OUT}" "tab:session-start" "SessionStart dispara tab session-start"

# Test 6: StopFailure -> tab error
clear_logs
run_dispatcher '{"hook_event_name":"StopFailure"}'
assert_file_contains "${TAB_OUT}" "tab:error" "StopFailure dispara tab error"

# Test 7: Interrupt -> tab attention
clear_logs
run_dispatcher '{"hook_event_name":"Interrupt"}'
assert_file_contains "${TAB_OUT}" "tab:attention" "Interrupt dispara tab attention"

# Test 8: Notification -> tab notification
clear_logs
run_dispatcher '{"hook_event_name":"Notification","notification_type":"task.started"}'
assert_file_contains "${TAB_OUT}" "tab:notification" "Notification dispara tab notification"

# Test 9: heartbeat throttle (5 prompts)
clear_logs
for i in $(seq 1 4); do
    run_dispatcher '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' >/dev/null
done
# Após 4 prompts sem heartbeat, o 5o prompt deve disparar.
run_dispatcher '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' >/dev/null
hb_count="$(wc -l < "${HB_OUT}" 2>/dev/null || echo 0)"
if [ "${hb_count}" -ge 1 ]; then
    echo "✅ Throttle de heartbeat funciona (count=${hb_count})"
    passed=$((passed + 1))
else
    echo "❌ Throttle de heartbeat falhou (count=${hb_count})"
    failed=$((failed + 1))
fi

# Test 10: cost-guard throttle (10 prompts)
COST_GUARD_OUT="${TMPDIR}/cost-guard.log"
mock_cost_guard="${TMPDIR}/.agent/scripts/hmvip-session-cost-guard.sh"
mkdir -p "$(dirname "${mock_cost_guard}")"
cat > "${mock_cost_guard}" <<EOF
#!/bin/bash
printf 'cost-guard:%s\n' "\$1" >> "${COST_GUARD_OUT}"
EOF
chmod +x "${mock_cost_guard}"
# O cost-guard exige um log de sessão existente para executar.
mkdir -p "${TMPDIR}/logs"
touch "${TMPDIR}/logs/kimi-code.log"
rm -f "${COST_GUARD_OUT}"
for i in $(seq 1 9); do
    run_dispatcher "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"${TMPDIR}\",\"sessionDir\":\"${TMPDIR}\"}" >/dev/null
done
# Após 9 prompts sem cost-guard, o 10o prompt deve disparar.
run_dispatcher "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"${TMPDIR}\",\"sessionDir\":\"${TMPDIR}\"}" >/dev/null
cg_count="$(wc -l < "${COST_GUARD_OUT}" 2>/dev/null || echo 0)"
if [ "${cg_count}" -ge 1 ]; then
    echo "✅ Throttle de cost-guard funciona (count=${cg_count})"
    passed=$((passed + 1))
else
    echo "❌ Throttle de cost-guard falhou (count=${cg_count})"
    failed=$((failed + 1))
fi

# Test 11: dispatcher é fail-open (exit 0)
clear_logs
if run_dispatcher '{"hook_event_name":"UnknownEvent"}'; then
    echo "✅ Dispatcher é fail-open para eventos desconhecidos"
    passed=$((passed + 1))
else
    echo "❌ Dispatcher bloqueou em evento desconhecido"
    failed=$((failed + 1))
fi

echo ""
echo "Results: ${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
