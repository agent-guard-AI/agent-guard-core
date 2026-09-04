#!/usr/bin/env bash
#
# continue-all.sh — ranking de slots com trabalho em andamento + grade kitty.
#
# Modulo do agent-guard-core (spec agent-guard-tab-unification-20260805, F3).
# Sourceado por `agent-guard continuar-tudo` e pelo dispatcher `hmvip`.
#
# Segue shell-safety do HMVIP: NAO altera flags do shell chamador, NAO faz cd,
# NAO usa exit — apenas define funcoes. O dispatcher que chama pode usar
# strict mode internamente, mas restaura as flags ao retornar.
#
# Uso:
#   agent-guard continuar-tudo          # abre grade kitty com slots pendentes
#   agent-guard continuar-tudo --dry-run # mostra fila sem abrir janelas
#   agent-guard ct                      # alias
#

# Diretorio base do agent-guard-core (usado para localizar init.sh quando
# sourceado diretamente, sem passar pelo dispatcher).
_HMVIP_CONTINUE_ALL_CORE_DIR="${HMVIP_AGENT_GUARD_CORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)}"
_HMVIP_CONTINUE_ALL_REPO_ROOT="${HMVIP_REPO_ROOT:-/home/hmvip-dev/hmvip}"
_HMVIP_CONTINUE_ALL_SESSION_DIR="${_HMVIP_CONTINUE_ALL_REPO_ROOT}/.kiro/locks/agent-sessions"
_HMVIP_CONTINUE_ALL_GUARD_FILE="${_HMVIP_CONTINUE_ALL_REPO_ROOT}/agent-guard.yaml"

# Garante acesso as funcoes helpers do init.sh (_get_worktree_path).
# Quando chamado pelo dispatcher, init.sh ja foi sourceado; quando chamado
# diretamente, sourceamos com AGENT_GUARD_FUNCTIONS_ONLY=1.
function _hmvip_continue_all_ensure_helpers() {
    if ! declare -F _get_worktree_path >/dev/null 2>&1; then
        if [[ -f "${_HMVIP_CONTINUE_ALL_CORE_DIR}/src/init.sh" ]]; then
            AGENT_GUARD_FUNCTIONS_ONLY=1
            # shellcheck disable=SC1091
            source "${_HMVIP_CONTINUE_ALL_CORE_DIR}/src/init.sh"
            unset AGENT_GUARD_FUNCTIONS_ONLY
        fi
    fi
    # Load task lifecycle helpers for structured notes.
    # task-lifecycle.sh enables strict mode; restore caller flags after sourcing.
    if ! declare -F _task_read_frontmatter >/dev/null 2>&1; then
        if [[ -f "${_HMVIP_CONTINUE_ALL_CORE_DIR}/src/task-lifecycle.sh" ]]; then
            local _old_flags
            _old_flags="$(set +o)"
            # shellcheck disable=SC1091
            source "${_HMVIP_CONTINUE_ALL_CORE_DIR}/src/task-lifecycle.sh" || true
            eval "${_old_flags}" 2>/dev/null || true
        fi
    fi
}

# Le um campo do lease JSON do slot. Usa o session_dir configuravel para
# permitir testes em sandbox.
function _hmvip_continue_all_load_session_field() {
    local identity="$1"
    local field="$2"
    local session_file="${_HMVIP_CONTINUE_ALL_SESSION_DIR}/${identity}.json"
    if [[ -f "${session_file}" ]]; then
        python3 -c "import json,sys; d=json.load(open('${session_file}')); print(d.get('${field}',''))" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Verifica se um processo esta vivo.
function _hmvip_continue_all_pid_alive() {
    local pid="$1"
    [[ -n "${pid}" && "${pid}" != "0" && -e "/proc/${pid}" ]]
}

# Extrai o proximo passo da nota do slot. Procura linha "Próximo passo:".
function _hmvip_continue_all_next_step_from_note() {
    local identity="$1"
    local note="${_HMVIP_CONTINUE_ALL_REPO_ROOT}/.agent-guard/tasks/${identity}.md"
    if [[ ! -f "${note}" ]]; then
        return 1
    fi
    local line
    # grep case-insensitivo, ancora no inicio da linha, captura apos os dois pontos.
    line="$(grep -iE '^[[:space:]]*Próximo passo[[:space:]]*:[[:space:]]*' "${note}" 2>/dev/null | head -n1 || true)"
    if [[ -z "${line}" ]]; then
        return 1
    fi
    # Remove o prefixo e espacos.
    printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Le task metadata estruturada da nota do slot (YAML frontmatter).
# Retorna JSON com topic, next_step, state ou vazio se não houver frontmatter.
function _hmvip_continue_all_task_from_note() {
    local identity="$1"
    local note="${_HMVIP_CONTINUE_ALL_REPO_ROOT}/.agent-guard/tasks/${identity}.md"
    if [[ ! -f "${note}" ]]; then
        return 1
    fi
    if ! declare -F _task_read_frontmatter >/dev/null 2>&1; then
        return 1
    fi
    local json
    json="$(_task_read_frontmatter "${note}" 2>/dev/null || true)"
    if [[ -z "${json}" ]]; then
        return 1
    fi
    local state
    state="$(echo "${json}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("state","legacy"))' 2>/dev/null || echo "legacy")"
    if [[ "${state}" == "legacy" ]]; then
        return 1
    fi
    echo "${json}"
}

# Lista todas as identidades configuradas em agent-guard.yaml.
function _hmvip_continue_all_list_identities() {
    if [[ ! -f "${_HMVIP_CONTINUE_ALL_GUARD_FILE}" ]]; then
        return 1
    fi
    python3 - "${_HMVIP_CONTINUE_ALL_GUARD_FILE}" <<'PY'
import yaml, sys, os
guard_file = sys.argv[1]
try:
    with open(guard_file) as f:
        guard = yaml.safe_load(f) or {}
except Exception:
    guard = {}
identities = guard.get('identities', {})
for prefix, cfg in sorted(identities.items()):
    slots = int(cfg.get('slots', 0) or 0)
    max_slots = int(cfg.get('max_slots', slots) or slots)
    for i in range(1, max_slots + 1):
        print(f"{prefix}{i}")
PY
}

# Verifica se a identidade tem PRs abertos de branches ia-<identidade>/*.
# Replica o helper do init.sh para nao depender de funcoes internas de _agent_guard_init_main.
function _hmvip_continue_all_has_open_prs() {
    local identity="$1"
    local worktree_path="$2"
    if ! command -v gh >/dev/null 2>&1; then
        return 1
    fi
    local pr_count
    pr_count="$(cd "${worktree_path}" 2>/dev/null && gh pr list --state open --limit 100 \
        --json number,headRefName \
        --jq ".[] | select(.headRefName | startswith(\"ia-${identity}/\")) | .number" 2>/dev/null | wc -l || true)"
    [[ "${pr_count}" -gt 0 ]]
}

# Decide se um slot deve entrar no ranking.
# Retorna 0 e preenche _HM_REASON se incluido.
function _hmvip_continue_all_should_include() {
    local identity="$1"
    _HM_REASON=""

    local session_file worktree
    session_file="${_HMVIP_CONTINUE_ALL_SESSION_DIR}/${identity}.json"
    worktree="$(_hmvip_continue_all_load_session_field "${identity}" "worktree_path" 2>/dev/null || true)"
    if [[ -z "${worktree}" ]]; then
        _hmvip_continue_all_ensure_helpers
        worktree="$(_get_worktree_path "${identity}" 2>/dev/null || echo "/home/hmvip-dev/hmvip-ia-${identity}")"
    fi

    local status branch pid tab_title tab_updated last_activity
    status="$(_hmvip_continue_all_load_session_field "${identity}" "status" 2>/dev/null || true)"
    branch="$(_hmvip_continue_all_load_session_field "${identity}" "branch" 2>/dev/null || true)"
    pid="$(_hmvip_continue_all_load_session_field "${identity}" "pid" 2>/dev/null || true)"
    tab_title="$(_hmvip_continue_all_load_session_field "${identity}" "tab_title" 2>/dev/null || true)"
    tab_updated="$(_hmvip_continue_all_load_session_field "${identity}" "tab_updated" 2>/dev/null || true)"
    last_activity="$(_hmvip_continue_all_load_session_field "${identity}" "last_activity" 2>/dev/null || true)"

    local health="dead"
    if _hmvip_continue_all_pid_alive "${pid}"; then
        health="live"
    fi

    # Camada A: criterios objetivos de inclusao.
    # 1) lease active mas processo morto (sessao quebrou).
    if [[ "${status}" == "active" && "${health}" == "dead" ]]; then
        _HM_REASON="lease dead"
    # 2) PRs abertos da identidade.
    elif _hmvip_continue_all_has_open_prs "${identity}" "${worktree}"; then
        _HM_REASON="open PRs"
    # 3) branch de task da identidade (nao released).
    elif [[ "${branch}" == "ia-${identity}/"* ]]; then
        _HM_REASON="task branch"
    else
        return 1
    fi

    # Camada B: titulo declarado na nota do slot.
    # Prioriza YAML frontmatter; fallback para grep legado se nao houver.
    local title="" reason_b=""
    local task_json=""
    task_json="$(_hmvip_continue_all_task_from_note "${identity}" 2>/dev/null || true)"
    if [[ -n "${task_json}" ]]; then
        title="$(echo "${task_json}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("next_step","") or json.load(sys.stdin).get("topic",""))' 2>/dev/null || true)"
        [[ -n "${title}" ]] && reason_b="note"
    fi
    if [[ -z "${title}" ]]; then
        title="$(_hmvip_continue_all_next_step_from_note "${identity}" 2>/dev/null || true)"
        [[ -n "${title}" ]] && reason_b="note"
    fi
    if [[ -z "${title}" && -n "${tab_title}" && "${tab_title}" != "null" ]]; then
        title="${tab_title}"
        reason_b="tab_title"
    fi
    if [[ -z "${title}" ]]; then
        title="trabalho pendente"
        reason_b="fallback"
    fi

    # Pontuacao para ordenacao (maior = mais prioritario).
    # score1: B presente (1) vs ausente (0)
    # score2: tem PRs abertos (1) vs nao (0)
    # score3: timestamp mais recente
    local score_b=0 score_prs=0 ts=0
    [[ "${reason_b}" == "note" ]] && score_b=10
    if _hmvip_continue_all_has_open_prs "${identity}" "${worktree}"; then
        score_prs=5
    fi
    if [[ "${last_activity}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        ts="${last_activity%.*}"
    elif [[ "${tab_updated}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        ts="${tab_updated%.*}"
    fi
    [[ -z "${ts}" ]] && ts=0

    # Emite JSON do slot em uma unica linha (acumulado pelo chamador).
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${identity}" \
        "${title}" \
        "${worktree}" \
        "${_HM_REASON}" \
        "${score_b}" \
        "${score_prs}" \
        "${ts}"
    return 0
}

# Constroi o ranking e imprime JSON array.
function _hmvip_continue_all_ranking_json() {
    _hmvip_continue_all_ensure_helpers

    local identity
    local lines=""
    while IFS= read -r identity; do
        [[ -n "${identity}" ]] || continue
        local rec
        rec="$(_hmvip_continue_all_should_include "${identity}" 2>/dev/null || true)"
        [[ -n "${rec}" ]] || continue
        lines="${lines}${rec}\n"
    done <<<"$(_hmvip_continue_all_list_identities 2>/dev/null || true)"

    if [[ -z "${lines}" ]]; then
        echo '[]'
        return 0
    fi

    # Ordena: score_b desc, score_prs desc, ts desc.
    # Usa tab como separador; sort -t$'\t' -k5,5nr -k6,6nr -k7,7nr
    printf '%b' "${lines}" | sort -t$'\t' -k5,5nr -k6,6nr -k7,7nr | python3 -c '
import json, sys
out = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) < 7:
        continue
    out.append({
        "slot": parts[0],
        "title": parts[1],
        "worktree": parts[2],
        "reason": parts[3],
        "score_b": int(parts[4] or 0),
        "score_prs": int(parts[5] or 0),
        "ts": int(parts[6] or 0),
    })
print(json.dumps(out, ensure_ascii=False))
'
}

# Modo dry-run: imprime a fila em formato legivel.
function _hmvip_continue_all_dry_run() {
    local json
    json="$(_hmvip_continue_all_ranking_json)"
    local count
    count="$(python3 - "${json}" <<'PY' 2>/dev/null
import json, sys
try:
    print(len(json.loads(sys.argv[1])))
except Exception:
    print(0)
PY
)"
    if [[ "${count}" == "0" ]]; then
        echo "Nenhum slot com trabalho em andamento encontrado."
        return 0
    fi

    echo "============================================================"
    echo "🛡️  HMVIP — Slots com trabalho em andamento (${count})"
    echo "============================================================"
    printf '%-10s %-14s %-30s %s\n' "SLOT" "MOTIVO" "TITULO" "WORKTREE"
    python3 - "${json}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
for item in data:
    title = item['title'][:28]
    wt = item['worktree'].replace('/home/hmvip-dev/', '~/.../')
    print(f"{item['slot']:<10} {item['reason']:<14} {title:<30} {wt}")
PY
    echo ""
    echo "Modo dry-run: nenhuma janela foi aberta."
    echo "Rode sem --dry-run para abrir cada slot em um quadrante kitty."
    return 0
}

# Verifica se um slot ja esta ocupado por sessao viva.
function _hmvip_continue_all_slot_is_live() {
    local identity="$1"
    local pid
    pid="$(_hmvip_continue_all_load_session_field "${identity}" "pid" 2>/dev/null || true)"
    _hmvip_continue_all_pid_alive "${pid}"
}

# Abre a grade kitty com os slots do ranking.
function _hmvip_continue_all_open_grid() {
    local json
    json="$(_hmvip_continue_all_ranking_json)"

    local count
    count="$(python3 - "${json}" <<'PY' 2>/dev/null
import json, sys
try:
    print(len(json.loads(sys.argv[1])))
except Exception:
    print(0)
PY
)"
    if [[ "${count}" == "0" ]]; then
        echo "Nenhum slot com trabalho em andamento."
        return 0
    fi

    # Gera argumentos --slots para o grid.sh.
    # Formato: --slots '<json>' (uma unica string JSON).
    # O grid.sh vai iterar sobre os itens e abrir uma janela por slot.
    if ! declare -F _hmvip_grid_cmd >/dev/null 2>&1; then
        if [[ -f "${_HMVIP_CONTINUE_ALL_CORE_DIR}/src/grid.sh" ]]; then
            # shellcheck disable=SC1091
            source "${_HMVIP_CONTINUE_ALL_CORE_DIR}/src/grid.sh"
        else
            echo "❌ Modulo grid.sh nao encontrado em ${_HMVIP_CONTINUE_ALL_CORE_DIR}/src/grid.sh" >&2
            return 1
        fi
    fi

    # Filtra slots ja vivos (sessao ativa) para nao adoptar forçado.
    local filtered skip_reasons=""
    filtered="$(python3 - "${json}" <<'PY'
import json, sys
print(json.dumps(json.loads(sys.argv[1])))
PY
)"

    # Itera e decide skip/pulado antes de chamar o grid.
    # Isso mantem o grid generico (ele nao sabe de lease).
    local to_open="[]"
    local skipped=0
    while IFS= read -r item; do
        [[ -n "${item}" ]] || continue
        local identity worktree title
        identity="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['slot'])" "${item}" 2>/dev/null || true)"
        worktree="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['worktree'])" "${item}" 2>/dev/null || true)"
        title="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['title'])" "${item}" 2>/dev/null || true)"
        if _hmvip_continue_all_slot_is_live "${identity}"; then
            echo "⚠️  ${identity}: sessao ja esta viva; pulando."
            skipped=$((skipped + 1))
            continue
        fi
        if [[ ! -d "${worktree}" ]]; then
            echo "⚠️  ${identity}: worktree ${worktree} nao existe; pulando."
            skipped=$((skipped + 1))
            continue
        fi
        to_open="$(python3 - "${to_open}" "${identity}" "${worktree}" "${title}" <<'PY'
import json, sys
arr = json.loads(sys.argv[1])
arr.append({
    "slot": sys.argv[2],
    "worktree": sys.argv[3],
    "title": sys.argv[4],
})
print(json.dumps(arr))
PY
)"
    done <<<"$(python3 - "${filtered}" <<'PY'
import json, sys
for item in json.loads(sys.argv[1]):
    print(json.dumps(item))
PY
)"

    local open_count
    open_count="$(python3 - "${to_open}" <<'PY' 2>/dev/null
import json, sys
try:
    print(len(json.loads(sys.argv[1])))
except Exception:
    print(0)
PY
)"
    if [[ "${open_count}" == "0" ]]; then
        echo "Nenhuma janela para abrir (${skipped} slot(s) pulado(s))."
        return 0
    fi

    echo "Abrindo ${open_count} slot(s) em quadrantes kitty (${skipped} pulado(s))..."
    _hmvip_grid_cmd --slots "${to_open}"
    local rc=$?
    echo ""
    echo "Resumo: ${open_count} janela(s) aberta(s), ${skipped} slot(s) pulado(s)."
    return ${rc}
}

# Entrypoint do subcomando.
function _hmvip_continue_all_cmd() {
    local dry_run=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n) dry_run=1 ;;
            -h|--help|ajuda)
                cat <<'EOF'
hmvip continuar-tudo — abre slots com trabalho em andamento em grade kitty

  agent-guard continuar-tudo          abre janelas para slots pendentes
  agent-guard continuar-tudo --dry-run mostra a fila sem abrir janelas
  agent-guard ct                       alias curto

Ranking (dupla camada):
  Camada A: lease dead, PRs abertos ou branch ia-<slot>/* nao released.
  Camada B: titulo vem de "Próximo passo:" da nota .agent-guard/tasks/<slot>.md.
EOF
                return 0
                ;;
            *) echo "Opcao desconhecida: $1" >&2; return 1 ;;
        esac
        shift
    done

    if [[ "${dry_run}" == "1" ]]; then
        _hmvip_continue_all_dry_run
    else
        _hmvip_continue_all_open_grid
    fi
}
