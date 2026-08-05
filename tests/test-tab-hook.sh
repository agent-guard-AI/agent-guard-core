#!/usr/bin/env bash
#
# test-tab-hook.sh — testes standalone do hmvip-tab (agent-guard-core).
#
#   bash packages/agent-guard-core/tests/test-tab-hook.sh
#
# Cobre: transicoes de estado, contagem de background, override manual,
# sanitizacao de titulo, isolamento de shell (skill hmvip-shell-safety).
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HERE}/../wrappers/kimi/hooks/agent-guard-tab.sh"
TAB_SH="${HERE}/../src/tab.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

export HMVIP_TAB_DIR="${SANDBOX}/tab-sessions"
export HMVIP_TAB_OUT="${SANDBOX}/titles.log"
# Notificacoes ficam desligadas por padrao nos testes; a secao propria as liga.
export HMVIP_TAB_NOTIFY=0
export HMVIP_TAB_SUMMARIZER="${HERE}/../wrappers/kimi/hooks/summarize-prompt.py"
SID="session_teste_123"
CWD="/home/hmvip-dev/hmvip-ia-kimi9"

PASS=0
FAIL=0

ok() {
    local desc="$1"
    PASS=$((PASS + 1))
    printf 'ok   %s\n' "${desc}"
}

bad() {
    local desc="$1" got="$2"
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n     got: %s\n' "${desc}" "${got}"
}

fire() {
    # $1 = acao do hook, $2 = json extra do payload
    printf '{"session_id":"%s","cwd":"%s","hook_event_name":"%s"%s}\n' \
        "${SID}" "${CWD}" "${3:-Manual}" "${2:-}" | bash "${HOOK}" "$1"
}

last_title() { tail -n1 "${HMVIP_TAB_OUT}" 2>/dev/null; }

echo "== transicoes de estado =="

fire working ',"prompt":"corrigir paywall de albuns duplicados no perfil"' UserPromptSubmit
TITLE="$(last_title)"
[[ "${TITLE}" == "🟢 kimi9 | fix paywall albuns duplicados…"* ]] \
    && ok "working => verde + titulo do prompt" \
    || bad "working => verde + titulo do prompt" "${TITLE}"

fire attention "" PermissionRequest
[[ "$(last_title)" == "🟡 kimi9 | "* ]] && ok "permission => amarelo" || bad "permission => amarelo" "$(last_title)"

fire working "" PermissionResult
[[ "$(last_title)" == "🟢 kimi9 | "* ]] && ok "permission result => verde de volta" || bad "permission result" "$(last_title)"

fire error "" StopFailure
[[ "$(last_title)" == "🔴 kimi9 | "* ]] && ok "stop failure => vermelho" || bad "stop failure" "$(last_title)"

fire working ',"prompt":"outra coisa"' UserPromptSubmit
T2="$(last_title)"
[[ "${T2}" == "🟢 kimi9 | fix paywall albuns duplicados…"* ]] \
    && ok "novo prompt limpa erro e MANTEM titulo original (estavel)" \
    || bad "titulo estavel" "${T2}"

echo "== background tasks =="

fire notification ',"notification_type":"task.started"' Notification
[[ "$(last_title)" == "🔵🟢 kimi9 | "* ]] && ok "task.started => azul+verde" || bad "task.started" "$(last_title)"

fire notification ',"notification_type":"task.completed"' Notification
[[ "$(last_title)" == "🟢 kimi9 | "* ]] && ok "task.completed => azul some" || bad "task.completed" "$(last_title)"

fire notification ',"notification_type":"task.completed"' Notification
STATE_BG="$(jq -r '.bg' "${HMVIP_TAB_DIR}/${SID}.json")"
[[ "${STATE_BG}" == "0" ]] && ok "bg nunca negativo (floor 0)" || bad "bg floor" "${STATE_BG}"

echo "== override manual =="

printf 'fix album paywall\n' > "${HMVIP_TAB_DIR}/${SID}.title"
fire render
[[ "$(last_title)" == "🟢 kimi9 | fix album paywall" ]] \
    && ok "override manual vence automatico" \
    || bad "override manual" "$(last_title)"

rm -f "${HMVIP_TAB_DIR}/${SID}.title"
fire render
[[ "$(last_title)" == "🟢 kimi9 | fix paywall albuns duplicados…"* ]] \
    && ok "remover override volta ao automatico" \
    || bad "volta automatico" "$(last_title)"

echo "== sanitizacao =="

SID="session_maliciosa"
fire working ',"prompt":"mal
cious 1b]0;PWNED titulo"' UserPromptSubmit
T3="$(last_title)"
if [[ "${T3}" != *$'\033'* ]] && [[ "${T3}" != *"PWNED"* ]]; then
    ok "escape sequence injetada no prompt e neutralizada"
else
    bad "sanitizacao de prompt" "${T3}"
fi
SID="session_teste_123"

echo "== prompt como array de blocos (formato novo do CLI) =="

SID="session_array_prompt"
fire working ',"prompt":[{"type":"text","text":"renomear tabs do kitty com icones"}]' UserPromptSubmit
T4="$(last_title)"
[[ "${T4}" == "🟢 kimi9 | rename tabs kitty"* ]] \
    && ok "prompt array de blocos => extrai o texto" \
    || bad "prompt array de blocos" "${T4}"

SID="session_array_imagem"
fire working ',"prompt":[{"type":"image_url","image_url":{"url":"data:image/png;base64,xx"}}]' UserPromptSubmit
T5="$(last_title)"
[[ "${T5}" != *'"type"'* ]] \
    && ok "prompt so com imagem => nao vaza JSON no titulo" \
    || bad "prompt so com imagem" "${T5}"

echo "== auto-cura de titulo envenenado (estado legado) =="

SID="session_envenenada"
cat > "${HMVIP_TAB_DIR}/${SID}.json" <<EOF
{"session_id":"${SID}","cwd":"${CWD}","slot":"kimi9","state":"working","bg":0,"title_auto":"[ { \"type\": \"text\", \"text\":…","tty":"","pid":0,"updated":0}
EOF
fire working ',"prompt":[{"type":"text","text":"titulo recuperado do json"}]' UserPromptSubmit
T6="$(last_title)"
[[ "${T6}" == *"titulo recuperado json"* ]] \
    && ok "title_auto legado em JSON e descartado e re-derivado" \
    || bad "auto-cura de titulo" "${T6}"
SID="session_teste_123"

echo "== selo de espera + notificacao desktop =="

export HMVIP_TAB_NOTIFY=1
export HMVIP_TAB_NOTIFY_OUT="${SANDBOX}/notify.log"

SID="session_espera"
fire working ',"prompt":"espera e notificacao"' UserPromptSubmit
fire attention "" PermissionRequest
T7="$(last_title)"
[[ "${T7}" == *"⏳"* && "${T7}" =~ [0-9]{2}:[0-9]{2} ]] \
    && ok "attention => selo 'esperando desde HH:MM' no titulo" \
    || bad "selo de espera" "${T7}"
[[ "$(wc -l < "${HMVIP_TAB_NOTIFY_OUT}" 2>/dev/null || echo 0)" == "1" ]] \
    && ok "transicao working=>attention notifica 1x" \
    || bad "notifica 1x" "$(cat "${HMVIP_TAB_NOTIFY_OUT}" 2>/dev/null)"

fire attention "" Stop
[[ "$(wc -l < "${HMVIP_TAB_NOTIFY_OUT}")" == "1" ]] \
    && ok "attention repetido (sem transicao) NAO re-notifica" \
    || bad "sem re-notificacao" "$(wc -l < "${HMVIP_TAB_NOTIFY_OUT}")"

fire working "" PermissionResult
fire error "" StopFailure
T8="$(last_title)"
[[ "${T8}" == "🔴 kimi9 | "* && "${T8}" == *"⏳"* ]] \
    && ok "error => vermelho + selo de espera" \
    || bad "error selo" "${T8}"
[[ "$(wc -l < "${HMVIP_TAB_NOTIFY_OUT}")" == "2" ]] \
    && ok "transicao working=>error notifica de novo" \
    || bad "notifica error" "$(wc -l < "${HMVIP_TAB_NOTIFY_OUT}")"

fire working "" UserPromptSubmit
[[ "$(last_title)" != *"⏳"* ]] \
    && ok "working remove o selo de espera" \
    || bad "working sem selo" "$(last_title)"

export HMVIP_TAB_NOTIFY=0
unset HMVIP_TAB_NOTIFY_OUT
SID="session_teste_123"

echo "== session-end =="

fire session-end "" SessionEnd
[[ ! -f "${HMVIP_TAB_DIR}/${SID}.json" ]] \
    && ok "session-end remove estado" \
    || bad "session-end remove estado" "arquivo ainda existe"
[[ "$(last_title)" == "kimi9 | livre" ]] \
    && ok "session-end reseta titulo para 'livre'" \
    || bad "titulo livre" "$(last_title)"

echo "== fail-open do hook =="

echo 'lixo nao-json' | bash "${HOOK}" working; RC=$?
[[ ${RC} -eq 0 ]] && ok "payload invalido => exit 0" || bad "payload invalido" "rc=${RC}"

bash "${HOOK}" acao-estranha </dev/null; RC=$?
[[ ${RC} -eq 0 ]] && ok "acao desconhecida => exit 0" || bad "acao desconhecida" "rc=${RC}"

echo "== isolamento de shell (hmvip-tab.sh sourceado) =="

OUT="$(
    bash -c '
        set +e
        source "'"${TAB_SH}"'"
        FALSE_REACHED=0
        hmvip_tab __inexistente__ >/dev/null 2>&1
        false
        MARKER_REACHED=1
        flags_after="$(set +o | grep -c "on")"
        echo "MARKER_REACHED=${MARKER_REACHED}"
        declare -F _hmvip_tab_cmd >/dev/null && echo "FUNC_OK=1"
    '
)"
[[ "${OUT}" == *"MARKER_REACHED=1"* ]] \
    && ok "source hmvip-tab.sh nao vaza set -e (shell sobrevive a false)" \
    || bad "isolamento de flags" "${OUT}"
[[ "${OUT}" == *"FUNC_OK=1"* ]] \
    && ok "funcao _hmvip_tab_cmd definida" \
    || bad "funcao definida" "${OUT}"

echo "== cockpit hmvip tabs =="

fire working ',"prompt":"/tab validar cockpit"' UserPromptSubmit
OUT="$(bash -c 'source "'"${TAB_SH}"'"; _hmvip_tab_list' 2>&1)"
[[ "${OUT}" == *"kimi9"* && "${OUT}" == *"validar cockpit"* ]] \
    && ok "cockpit lista sessao com titulo" \
    || bad "cockpit" "${OUT}"


echo "== resumo inteligente de prompt =="

SUMMARIZER="${HERE}/../wrappers/kimi/hooks/summarize-prompt.py"

T10="$(python3 "${SUMMARIZER}" 'corrigir bug de duplicacao de posts nativos no hmvip-media-pipeline' 2>/dev/null | jq -r '.title')"
[[ "${T10}" == *"media-pipeline"* ]] \
    && ok "resumo detecta plugin e acao" \
    || bad "resumo plugin+acao" "${T10}"

T11="$(python3 "${SUMMARIZER}" 'oi, pode me ajudar a revisar o PR de seguranca do hmvip-auth?' 2>/dev/null | jq -r '.title')"
[[ "${T11}" == *"review auth"* ]] \
    && ok "resumo remove saudacao e stopwords" \
    || bad "resumo saudacao" "${T11}"

T12="$(python3 "${SUMMARIZER}" 'veja porque o MCP serena parou e corrija' 2>/dev/null | jq -r '.title')"
[[ "${T12}" == *"serena"* && "${T12}" != *"PWNED"* ]] \
    && ok "resumo de prompt livre contem entidade principal" \
    || bad "resumo entidade" "${T12}"

echo "== comandos slash =="

SID="session_slash_new"
fire working ',"prompt":"/new refatorar cache de tier entre hmvip-content-shield e hmvip-media-manager"' UserPromptSubmit
T13="$(last_title)"
[[ "${T13}" == *"refactor"* && "${T13}" != *"refatorar"* ]] \
    && ok "/new gera titulo resumido e descarta titulo anterior" \
    || bad "/new" "${T13}"
SID="session_teste_123"

SID="session_slash_compact"
fire working ',"prompt":"corrigir cache de tier"' UserPromptSubmit
fire working ',"prompt":"/compact"' UserPromptSubmit
T14="$(last_title)"
[[ "${T14}" == *"/compact"* ]] \
    && ok "/compact adiciona selo /compact" \
    || bad "/compact" "${T14}"
SID="session_teste_123"

SID="session_slash_clear"
fire working ',"prompt":"/clear"' UserPromptSubmit
T15="$(last_title)"
[[ "${T15}" == *"livre"* ]] \
    && ok "/clear reseta titulo para livre" \
    || bad "/clear" "${T15}"
SID="session_teste_123"

SID="session_slash_tab"
fire working ',"prompt":"/tab deploy rescue"' UserPromptSubmit
T16="$(last_title)"
[[ "${T16}" == "🟢 kimi9 | deploy rescue" ]] \
    && ok "/tab fixa titulo manualmente" \
    || bad "/tab" "${T16}"
SID="session_teste_123"

SID="session_slash_skill"
fire working ',"prompt":"/skill hmvip-payment-system analisar webhook SozoPay"' UserPromptSubmit
T17="$(last_title)"
[[ "${T17}" == *"skill:"* ]] \
    && ok "/skill prefixa titulo com skill:" \
    || bad "/skill" "${T17}"
SID="session_teste_123"

SID="session_slash_goal"
fire working ',"prompt":"/goal refatorar cache de tier entre plugins"' UserPromptSubmit
T18="$(last_title)"
[[ "${T18}" == *"goal:"* && "${T18}" != *"refatorar"* ]] \
    && ok "/goal prefixa titulo e resume conteudo" \
    || bad "/goal" "${T18}"
SID="session_teste_123"


echo "== fallback de slot por lease (sessao sem wrapper / lease mid-session) =="

# Repo fake gerenciado cujo basename NAO e hmvip-ia-*: sem o fallback, o slot
# seria "hmvip". O lease ativo em .kiro/locks/agent-sessions/ carrega o pid do
# CLI; o hook deve casa-lo com o CLI_PID e usar a identidade como slot.
FAKE_REPO="${SANDBOX}/hmvip"
mkdir -p "${FAKE_REPO}/.kiro/locks/agent-sessions"
git -C "${FAKE_REPO}" init -q 2>/dev/null

CWD_SAVE="${CWD}"
CWD="${FAKE_REPO}"
SID="session_lease_fallback"

# Fase 1: sem lease, descobre o CLI_PID que o hook persistiu no estado.
fire working ',"prompt":"verificar saude do agent guard"' UserPromptSubmit
HOOK_CLI_PID="$(jq -r '.pid' "${HMVIP_TAB_DIR}/${SID}.json")"

# Fase 2: lease ativo com o pid do CLI => fallback para a identidade.
cat > "${FAKE_REPO}/.kiro/locks/agent-sessions/kimi7.json" <<EOF
{"identity":"kimi7","status":"active","pid":${HOOK_CLI_PID},"worktree_path":"/home/hmvip-dev/hmvip-ia-kimi7"}
EOF
fire working "" PermissionResult
SLOT_JSON="$(jq -r '.slot' "${HMVIP_TAB_DIR}/${SID}.json")"
[[ "${SLOT_JSON}" == "kimi7" ]] \
    && ok "cwd no repo principal + lease ativo => slot via fallback" \
    || bad "slot via fallback" "${SLOT_JSON}"
[[ "$(last_title)" == "🟢 kimi7 | "* ]] \
    && ok "titulo usa o slot do lease" \
    || bad "titulo usa o slot do lease" "$(last_title)"

# Lease com pid de outro processo => sem fallback.
cat > "${FAKE_REPO}/.kiro/locks/agent-sessions/kimi7.json" <<EOF
{"identity":"kimi7","status":"active","pid":999999,"worktree_path":"/home/hmvip-dev/hmvip-ia-kimi7"}
EOF
fire working "" PermissionResult
SLOT_JSON="$(jq -r '.slot' "${HMVIP_TAB_DIR}/${SID}.json")"
[[ "${SLOT_JSON}" == "hmvip" ]] \
    && ok "lease com pid alheio => sem fallback" \
    || bad "lease com pid alheio" "${SLOT_JSON}"

# Lease inativo => sem fallback.
cat > "${FAKE_REPO}/.kiro/locks/agent-sessions/kimi7.json" <<EOF
{"identity":"kimi7","status":"released","pid":${HOOK_CLI_PID},"worktree_path":"/home/hmvip-dev/hmvip-ia-kimi7"}
EOF
fire working "" PermissionResult
SLOT_JSON="$(jq -r '.slot' "${HMVIP_TAB_DIR}/${SID}.json")"
[[ "${SLOT_JSON}" == "hmvip" ]] \
    && ok "lease inativo => sem fallback" \
    || bad "lease inativo" "${SLOT_JSON}"

# Sessao em worktree real => fallback NAO interfere (cwd vence).
SID="session_lease_worktree"
CWD="/home/hmvip-dev/hmvip-ia-kimi5"
cat > "${FAKE_REPO}/.kiro/locks/agent-sessions/kimi7.json" <<EOF
{"identity":"kimi7","status":"active","pid":${HOOK_CLI_PID},"worktree_path":"/home/hmvip-dev/hmvip-ia-kimi7"}
EOF
# O repo git do CWD acima nao existe no sandbox; o fallback so roda quando o
# basename nao casa hmvip-ia-*, entao o slot deve ser kimi5 independentemente.
fire working "" PermissionResult
SLOT_JSON="$(jq -r '.slot' "${HMVIP_TAB_DIR}/${SID}.json")"
[[ "${SLOT_JSON}" == "kimi5" ]] \
    && ok "cwd em worktree => fallback nao interfere" \
    || bad "cwd em worktree" "${SLOT_JSON}"

CWD="${CWD_SAVE}"
SID="session_teste_123"


echo
echo "PASS=${PASS} FAIL=${FAIL}"
[ "${FAIL}" -eq 0 ]
