#!/usr/bin/env bash
#
# tab.sh — helpers de terminal para titulo de aba com status da IA.
# Modulo do agent-guard-core (migrado de .kiro/shell/hmvip-tab/ na F1 da spec
# agent-guard-tab-unification-20260805). Nomes de funcoes _hmvip_tab_*
# preservados para compatibilidade com os consumidores existentes.
#
# Sourceado pelo ~/.bashrc (instalado por `agent-guard tab install`) ou pelo
# subcomando `agent-guard tab`. Segue as regras de shell-safety do HMVIP:
# NAO altera flags do shell, NAO faz cd, NAO usa exit, apenas define funcoes.
#
# Uso:
#   hmvip tab "corrigir paywall"   # nome manual do trabalho nesta aba
#   hmvip tab auto                 # volta ao titulo automatico
#   hmvip tab test                 # demo: cicla as bolinhas na aba atual
#   hmvip tabs                     # cockpit: estado de todas as sessoes Kimi
#

HMVIP_TAB_DIR="${HMVIP_TAB_DIR:-${HOME}/.kimi-code/tab-sessions}"
# Hook de re-render: prefere o nome novo (agent-guard-tab.sh); cai para o
# legado (kimi-tab-hook.sh) em instalacoes antigas ate o install novo rodar
# (fallback de migracao — remover na demolicao F3.5 da spec).
HMVIP_TAB_HOOK="${HMVIP_TAB_HOOK:-}"
if [ -z "${HMVIP_TAB_HOOK}" ]; then
    if [ -x "${HOME}/.kimi-code/hooks/agent-guard-tab.sh" ]; then
        HMVIP_TAB_HOOK="${HOME}/.kimi-code/hooks/agent-guard-tab.sh"
    else
        HMVIP_TAB_HOOK="${HOME}/.kimi-code/hooks/kimi-tab-hook.sh"
    fi
fi
# Separador entre status/slot e titulo. Padrao " | " evita glifos quebrados
# em fontes que nao renderizam U+00B7 (Middle Dot) corretamente.
HMVIP_TAB_SEPARATOR="${HMVIP_TAB_SEPARATOR:- | }"

# TTY atual sem o prefixo /dev/ (ex: pts/12). Vazio fora de terminal.
function _hmvip_tab_tty() {
    local t
    t="$(tty 2>/dev/null || true)"
    case "${t}" in
        /dev/*) printf '%s' "${t#/dev/}" ;;
        *)      printf '' ;;
    esac
}

# Monta "bolinhas slot | titulo" a partir de um arquivo de estado JSON.
function _hmvip_tab_line() {
    local file="$1" json state bg slot title manual dots
    command -v jq >/dev/null 2>&1 || return 1
    json="$(cat "${file}" 2>/dev/null)" || return 1
    state="$(jq -r '.state // "idle"' <<<"${json}" 2>/dev/null)"
    bg="$(jq -r '.bg // 0' <<<"${json}" 2>/dev/null)"
    slot="$(jq -r '.slot // "?"' <<<"${json}" 2>/dev/null)"
    title="$(jq -r '.title_auto // ""' <<<"${json}" 2>/dev/null)"
    manual="${file%.json}.title"
    if [ -f "${manual}" ]; then
        local m
        m="$(head -n1 "${manual}" 2>/dev/null | tr -d '\000-\037\177')"
        [ -n "${m}" ] && title="${m}"
    fi
    [ -z "${title}" ] && title="livre"
    dots=""
    [ "${bg}" -gt 0 ] 2>/dev/null && dots="🔵"
    case "${state}" in
        working)   dots="${dots}🟢" ;;
        attention) dots="${dots}🟡" ;;
        error)     dots="${dots}🔴" ;;
        *)         dots="${dots}⚪" ;;
    esac
    printf '%s %s%s%s' "${dots}" "${slot}" "${HMVIP_TAB_SEPARATOR}" "${title}"
}

# Escreve OSC 0 no tty atual (best-effort).
function _hmvip_tab_write() {
    local t dest
    t="$(_hmvip_tab_tty)"
    if [ -n "${t}" ]; then
        dest="/dev/${t}"
    else
        dest="/dev/tty"
    fi
    [ -w "${dest}" ] && printf '\033]0;%s\007' "$1" >"${dest}" 2>/dev/null
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
        tmux rename-window -t "${TMUX_PANE}" "$1" >/dev/null 2>&1
    fi
    return 0
}

# Acha o estado da sessao Kimi dona deste tty (o mais recente, se houver).
function _hmvip_tab_find_session() {
    local t f newest=""
    t="$(_hmvip_tab_tty)"
    [ -d "${HMVIP_TAB_DIR}" ] || return 1
    for f in "${HMVIP_TAB_DIR}"/*.json; do
        [ -f "${f}" ] || continue
        if [ -n "${t}" ] && [ "$(jq -r '.tty // ""' "${f}" 2>/dev/null)" = "${t}" ]; then
            newest="${f}"
        fi
    done
    [ -n "${newest}" ] && printf '%s' "${newest}" && return 0
    return 1
}

# Acha o estado de uma sessao por slot (ex: kimi3); prefere processo vivo.
function _hmvip_tab_find_by_slot() {
    local slot="$1" f best=""
    [ -d "${HMVIP_TAB_DIR}" ] || return 1
    for f in "${HMVIP_TAB_DIR}"/*.json; do
        [ -f "${f}" ] || continue
        [ "$(jq -r '.slot // ""' "${f}" 2>/dev/null)" = "${slot}" ] || continue
        if [ -z "${best}" ]; then
            best="${f}"
        fi
        local pid
        pid="$(jq -r '.pid // 0' "${f}" 2>/dev/null)"
        if [ "${pid}" -gt 0 ] 2>/dev/null && kill -0 "${pid}" 2>/dev/null; then
            best="${f}"
            break
        fi
    done
    [ -n "${best}" ] && printf '%s' "${best}" && return 0
    return 1
}

# Conta sessoes com processo vivo (para o fallback de "unica sessao viva").
function _hmvip_tab_single_live_session() {
    local f count=0 last=""
    [ -d "${HMVIP_TAB_DIR}" ] || return 1
    for f in "${HMVIP_TAB_DIR}"/*.json; do
        [ -f "${f}" ] || continue
        local pid
        pid="$(jq -r '.pid // 0' "${f}" 2>/dev/null)"
        if [ "${pid}" -gt 0 ] 2>/dev/null && kill -0 "${pid}" 2>/dev/null; then
            count=$((count + 1))
            last="${f}"
        fi
    done
    [ "${count}" -eq 1 ] && printf '%s' "${last}" && return 0
    return 1
}

function _hmvip_tab_usage() {
    cat <<'EOF'
hmvip tab — titulo de aba com status da IA

  hmvip tab "nome do trabalho"     fixa o nome exibido nesta aba
  hmvip tab --em kimi3 "nome"      fixa o nome na aba da sessao do slot
  hmvip tab auto [--em kimi3]      remove o nome manual (volta ao automatico)
  hmvip tab new "prompt"           forca novo titulo automatico a partir do texto
  hmvip tab compact [--em kimi3]   resume o titulo atual e adiciona /compact
  hmvip tab clear [--em kimi3]     reseta o titulo para "livre"
  hmvip tab suggest "prompt"       mostra qual titulo seria gerado (preview)
  hmvip tab test                   demo das bolinhas na aba atual
  hmvip tabs                       cockpit: estado de todas as sessoes Kimi

Comandos slash no prompt tambem funcionam:
  /new, /compact, /clear, /tab, /skill, /goal, /deploy, /pr, /review, /continue

Bolinhas: 🟢 processando  🟡 aguardando voce  🔴 erro  ⚪ parada  🔵 background
EOF
}

# Resolve a sessao alvo: --em <slot>, ou tty atual, ou unica sessao viva.
function _hmvip_tab_resolve_target() {
    local slot="$1"
    local f=""
    if [ -n "${slot}" ]; then
        f="$(_hmvip_tab_find_by_slot "${slot}")" || {
            echo "Nenhuma sessao Kimi registrada para o slot '${slot}'." >&2
            return 1
        }
    else
        f="$(_hmvip_tab_find_session)" || f="$(_hmvip_tab_single_live_session)" || {
            echo "Nenhuma sessao Kimi neste tty. Use: hmvip tab --em <slot> \"nome\"" >&2
            _hmvip_tab_list 2>/dev/null || true
            return 1
        }
    fi
    printf '%s' "${f}"
    return 0
}

# Chama o summarizer Python (best-effort).
function _hmvip_tab_summarize_text() {
    local prompt="$1" current="${2:-}"
    local summarizer="${HOME}/.kimi-code/hooks/summarize-prompt.py"
    [ -x "${summarizer}" ] || { echo "summarizer nao encontrado"; return 1; }
    HMVIP_TAB_TITLE_CHARS="${HMVIP_TAB_TITLE_CHARS:-32}" \
        printf '%s' "${prompt}" | "${summarizer}" - "${current}" 2>/dev/null
}

# Forca novo titulo automatico a partir de um texto (equivale a /new).
function _hmvip_tab_new() {
    local slot="" prompt="" f json title
    if [ "${1:-}" = "--em" ]; then
        slot="${2:-}"
        shift 2
        prompt="$*"
    else
        prompt="$*"
    fi
    f="$(_hmvip_tab_resolve_target "${slot}")" || return 1
    [ -n "${prompt}" ] || { echo "Uso: hmvip tab new [--em SLOT] 'texto'" >&2; return 1; }
    json="$(_hmvip_tab_summarize_text "/new ${prompt}")" || return 1
    title="$(printf '%s' "${json}" | jq -r '.title // ""' 2>/dev/null)"
    rm -f "${f%.json}.title"
    _hmvip_tab_set_title_auto "${f}" "${title}"
    echo "Novo titulo: ${title} ($(jq -r '.slot // "?"' "${f}" 2>/dev/null))"
}

# Compacta o titulo atual manualmente.
function _hmvip_tab_compact() {
    local slot="" f json title current
    [ "${1:-}" = "--em" ] && slot="${2:-}"
    f="$(_hmvip_tab_resolve_target "${slot}")" || return 1
    current="$(_hmvip_tab_get_title_auto "${f}")"
    json="$(_hmvip_tab_summarize_text "/compact" "${current}")" || return 1
    title="$(printf '%s' "${json}" | jq -r '.title // ""' 2>/dev/null)"
    rm -f "${f%.json}.title"
    _hmvip_tab_set_title_auto "${f}" "${title}"
    echo "Titulo compactado: ${title} ($(jq -r '.slot // "?"' "${f}" 2>/dev/null))"
}

# Limpa o titulo.
function _hmvip_tab_clear() {
    local slot="" f
    [ "${1:-}" = "--em" ] && slot="${2:-}"
    f="$(_hmvip_tab_resolve_target "${slot}")" || return 1
    rm -f "${f%.json}.title"
    _hmvip_tab_set_title_auto "${f}" "livre"
    echo "Titulo limpo ($(jq -r '.slot // "?"' "${f}" 2>/dev/null))."
}

# Preview do titulo que seria gerado.
function _hmvip_tab_suggest() {
    local prompt="$*"
    [ -n "${prompt}" ] || { echo "Uso: hmvip tab suggest 'texto'" >&2; return 1; }
    _hmvip_tab_summarize_text "${prompt}"
}

# Le/gra o titulo automatico no JSON de estado (usado pelos helpers acima).
function _hmvip_tab_get_title_auto() {
    local f="$1"
    jq -r '.title_auto // ""' "${f}" 2>/dev/null
}

function _hmvip_tab_set_title_auto() {
    local f="$1" title="$2"
    local tmp
    tmp="${f}.tmp.$$"
    jq --arg title "${title}" '.title_auto = $title' "${f}" 2>/dev/null >"${tmp}" && mv "${tmp}" "${f}" 2>/dev/null || rm -f "${tmp}"
    _hmvip_tab_rerender "${f}"
}

function _hmvip_tab_cmd() {
    local sub="${1:-}"
    case "${sub}" in
        ""|-h|--help|ajuda)
            _hmvip_tab_usage
            ;;
        auto)
            local slot="" f
            [ "${2:-}" = "--em" ] && slot="${3:-}"
            f="$(_hmvip_tab_resolve_target "${slot}")" || return 1
            rm -f "${f%.json}.title"
            _hmvip_tab_rerender "${f}"
            echo "Titulo automatico restaurado ($(basename "${f}" .json))."
            ;;
        new)
            shift
            _hmvip_tab_new "$@"
            ;;
        compact)
            shift
            _hmvip_tab_compact "$@"
            ;;
        clear|limpar)
            shift
            _hmvip_tab_clear "$@"
            ;;
        suggest|preview)
            shift
            _hmvip_tab_suggest "$@"
            ;;
        test)
            _hmvip_tab_test
            ;;
        --em)
            local slot="${2:-}"
            shift 2
            _hmvip_tab_cmd_named "${slot}" "$*"
            ;;
        *)
            _hmvip_tab_cmd_named "" "$*"
            ;;
    esac
    return 0
}

function _hmvip_tab_cmd_named() {
    local slot="$1" nome="$2" f
    if [ -z "${nome}" ]; then
        _hmvip_tab_usage
        return 1
    fi
    f="$(_hmvip_tab_resolve_target "${slot}")" || return 1
    printf '%s\n' "${nome}" >"${f%.json}.title"
    _hmvip_tab_rerender "${f}"
    echo "Aba renomeada: ${nome} ($(jq -r '.slot // "?"' "${f}" 2>/dev/null))"
    return 0
}

# Re-renderiza chamando o hook instalado com o estado atual da sessao.
function _hmvip_tab_rerender() {
    local f="$1" sid cwd
    [ -x "${HMVIP_TAB_HOOK}" ] || return 0
    sid="$(jq -r '.session_id // ""' "${f}" 2>/dev/null)"
    cwd="$(jq -r '.cwd // ""' "${f}" 2>/dev/null)"
    printf '{"session_id":"%s","cwd":"%s","hook_event_name":"Manual"}' "${sid}" "${cwd}" \
        | "${HMVIP_TAB_HOOK}" render >/dev/null 2>&1 || true
    return 0
}

# Demo: cicla as bolinhas na aba atual.
function _hmvip_tab_test() {
    local seq=("🟢 processando…" "🟡 aguardando voce…" "🔴 erro!" "🔵🟢 background + processando…" "⚪ parada")
    local saved
    saved="$(ps -o comm= -p $$ 2>/dev/null)"
    local i
    for i in "${seq[@]}"; do
        _hmvip_tab_write "demo ${i}"
        sleep 1
    done
    _hmvip_tab_write "✅ demo ok — hmvip tab"
    echo "Demo concluido. Estado real sera restaurado no proximo evento da IA (ou rode: hmvip tab auto)."
    return 0
}

# Cockpit: todas as sessoes Kimi conhecidas.
function _hmvip_tab_list() {
    [ -d "${HMVIP_TAB_DIR}" ] || { echo "Sem sessoes registradas ainda."; return 0; }
    local f found=0 now
    now="$(date +%s)"
    printf '%-14s %-7s %-4s %-36s %-8s %s\n' "STATUS" "SLOT" "MOD" "TRABALHO" "IDADE" "LOCAL"
    for f in "${HMVIP_TAB_DIR}"/*.json; do
        [ -f "${f}" ] || continue
        found=1
        local line slot cwd updated pid age alive mode
        line="$(_hmvip_tab_line "${f}")"
        slot="$(jq -r '.slot // "?"' "${f}" 2>/dev/null)"
        cwd="$(jq -r '.cwd // "?"' "${f}" 2>/dev/null)"
        updated="$(jq -r '.updated // 0' "${f}" 2>/dev/null)"
        pid="$(jq -r '.pid // 0' "${f}" 2>/dev/null)"
        alive="✕"
        [ "${pid}" -gt 0 ] 2>/dev/null && kill -0 "${pid}" 2>/dev/null && alive="●"
        age="$(( (now - updated) / 60 ))m"
        mode="A"
        [ -f "${f%.json}.title" ] && mode="M"
        printf '%-14s %-7s %-4s %-36s %-8s %s %s\n' "${line%% *}" "${slot}" "${mode}" "${line#*"${HMVIP_TAB_SEPARATOR}"}" "${age}" "${alive}" "${cwd##*/}"
    done
    [ "${found}" -eq 0 ] && echo "Sem sessoes registradas ainda."
    echo
    echo "● = processo vivo   ✕ = processo morto (rode: rm -i ~/.kimi-code/tab-sessions/<sid>.json)"
    echo "A = titulo automatico   M = override manual"
    return 0
}

# Instala/renova os hooks do hmvip-tab no ambiente local.
# Idempotente: pode rodar quantas vezes quiser. Copia agent-guard-tab.sh e
# summarize-prompt.py para ~/.kimi-code/hooks/, reescreve o bloco marcado no
# config.toml apontando para o hook novo, e garante source unico do tab.sh e
# grid.sh do agent-guard-core no ~/.bashrc.
function _hmvip_tab_install() {
    local core_dir hooks_dir config_toml bashrc
    core_dir="${HMVIP_AGENT_GUARD_CORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)}"
    if [ ! -d "${core_dir}/src" ] || [ ! -f "${core_dir}/wrappers/kimi/hooks/agent-guard-tab.sh" ]; then
        echo "❌ Nao encontrei o agent-guard-core em ${core_dir}" >&2
        return 1
    fi

    hooks_dir="${KIMI_CODE_HOME:-${HOME}/.kimi-code}/hooks"
    config_toml="${KIMI_CODE_HOME:-${HOME}/.kimi-code}/config.toml"
    bashrc="${HOME}/.bashrc"

    mkdir -p "${hooks_dir}"
    install -m 0755 "${core_dir}/wrappers/kimi/hooks/agent-guard-tab.sh" "${hooks_dir}/agent-guard-tab.sh"
    install -m 0755 "${core_dir}/wrappers/kimi/hooks/summarize-prompt.py" "${hooks_dir}/summarize-prompt.py"
    echo "✔ hooks instalados em ${hooks_dir}"

    local mark_begin mark_end hook_path block
    mark_begin="# >>> hmvip-tab-hooks >>>"
    mark_end="# <<< hmvip-tab-hooks <<<"
    hook_path="${hooks_dir}/agent-guard-tab.sh"

    read -r -d '' block <<EOF || true
${mark_begin}
[[hooks]]
event = "UserPromptSubmit"
command = "${hook_path} working"
timeout = 5

[[hooks]]
event = "PreToolUse"
command = "${hook_path} working"
timeout = 5

[[hooks]]
event = "SubagentStart"
command = "${hook_path} working"
timeout = 5

[[hooks]]
event = "PermissionRequest"
command = "${hook_path} attention"
timeout = 5

[[hooks]]
event = "PermissionResult"
command = "${hook_path} working"
timeout = 5

[[hooks]]
event = "Stop"
command = "${hook_path} attention"
timeout = 5

[[hooks]]
event = "StopFailure"
command = "${hook_path} error"
timeout = 5

[[hooks]]
event = "Interrupt"
command = "${hook_path} attention"
timeout = 5

[[hooks]]
event = "Notification"
matcher = "task\\\\."
command = "${hook_path} notification"
timeout = 5

[[hooks]]
event = "SessionStart"
command = "${hook_path} session-start"
timeout = 5

[[hooks]]
event = "SessionEnd"
command = "${hook_path} session-end"
timeout = 5
${mark_end}
EOF

    HMVIP_TAB_HOOKS_BLOCK="${block}" HMVIP_TAB_CONFIG="${config_toml}" python3 - <<'PY'
import os, re

config_path = os.environ["HMVIP_TAB_CONFIG"]
block = os.environ["HMVIP_TAB_HOOKS_BLOCK"]
begin = "# >>> hmvip-tab-hooks >>>"
end = "# <<< hmvip-tab-hooks <<<"

try:
    with open(config_path, "r", encoding="utf-8") as f:
        text = f.read()
except FileNotFoundError:
    text = ""

# Remove bloco marcado anterior (idempotencia).
pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", re.DOTALL)
text = pattern.sub("", text)

# Remove entradas [[hooks]] legadas do kimi-status-hook.sh e do kimi-tab-hook.sh.
lines = text.split("\n")
out = []
i = 0
removed_legacy = 0
while i < len(lines):
    if lines[i].strip() == "[[hooks]]":
        chunk = [lines[i]]
        i += 1
        while i < len(lines) and not lines[i].strip().startswith("["):
            chunk.append(lines[i])
            i += 1
        if any("kimi-status-hook.sh" in c or "kimi-tab-hook.sh" in c for c in chunk):
            removed_legacy += 1
            continue
        out.extend(chunk)
    else:
        out.append(lines[i])
        i += 1
text = "\n".join(out)

# Anexa o novo bloco ao final.
text = text.rstrip() + "\n\n" + block + "\n"

with open(config_path, "w", encoding="utf-8") as f:
    f.write(text)

print(f"✔ config.toml atualizado ({config_path})" + (f" — {removed_legacy} hook(s) legado(s) removido(s)" if removed_legacy else ""))
PY

    # Bashrc: substitui sources legados pelos novos do core, ou adiciona se ausente.
    local tab_line grid_line
    tab_line="source ${core_dir}/src/tab.sh"
    grid_line="source ${core_dir}/src/grid.sh"

    if [ ! -f "${bashrc}" ]; then
        touch "${bashrc}"
    fi

    # Se houver source legado de hmvip-tab.sh ou hmvip-kitty-grid.sh, migra.
    if grep -qE 'source[[:space:]]+.*hmvip-tab\.sh' "${bashrc}"; then
        sed -i -E "s|#?[[:space:]]*source[[:space:]]+[^[:space:]]*hmvip-tab\.sh.*|${tab_line}|" "${bashrc}"
        echo "✔ source do tab.sh migrado no ${bashrc}"
    elif ! grep -qF "${tab_line}" "${bashrc}"; then
        {
            echo ""
            echo "# hmvip-tab: titulo de aba com status da IA (agent-guard core)"
            echo "${tab_line}"
        } >> "${bashrc}"
        echo "✔ source do tab.sh adicionado ao ${bashrc}"
    else
        echo "✔ ${bashrc} ja contem source do tab.sh"
    fi

    if grep -qE 'source[[:space:]]+.*hmvip-kitty-grid\.sh' "${bashrc}"; then
        sed -i -E "s|#?[[:space:]]*source[[:space:]]+[^[:space:]]*hmvip-kitty-grid\.sh.*|${grid_line}|" "${bashrc}"
        echo "✔ source do grid.sh migrado no ${bashrc}"
    elif ! grep -qF "${grid_line}" "${bashrc}"; then
        {
            echo ""
            echo "# hmvip-grid: grade 2x2 de kitty nos monitores extras (agent-guard core)"
            echo "${grid_line}"
        } >> "${bashrc}"
        echo "✔ source do grid.sh adicionado ao ${bashrc}"
    else
        echo "✔ ${bashrc} ja contem source do grid.sh"
    fi

    echo ""
    echo "Instalado. Abra um NOVO terminal para carregar os novos sources."
    echo "Teste com: hmvip tab test"
    return 0
}

# Integracao com o dispatcher `hmvip` existente (hmvip tab / hmvip tabs).
function hmvip_tab() {
    _hmvip_tab_cmd "$@"
}

